#!/usr/bin/env bash
# Mise 版本管理器配置模块
# 功能：安装或更新 Mise、配置 Shell 集成、管理 Python/Node.js、
#       升级运行时后迁移依赖，并配置每周自动更新。

set -euo pipefail

# === 路径与常量 ===
readonly MISE_BIN_DIR="$HOME/.local/bin"
readonly MISE_PATH="$MISE_BIN_DIR/mise"
readonly MISE_CONFIG_DIR="$HOME/.config/mise"
readonly MISE_DEPENDENCY_BACKUP_DIR="$MISE_CONFIG_DIR/dependency-backups"

readonly MISE_ZSH_ACTIVATE_FILE="$MISE_CONFIG_DIR/activate.zsh"
readonly MISE_BASH_ACTIVATE_FILE="$MISE_CONFIG_DIR/activate.bash"

readonly ZSHRC_FILE="$HOME/.zshrc"
readonly BASHRC_FILE="$HOME/.bashrc"
readonly ZSH_LOADER_MARKER="# Mise shell 集成：配置文件由 mise-setup.sh 维护。"
readonly BASH_LOADER_MARKER="# Mise shell 集成：配置文件由 mise-setup.sh 维护。"

readonly MISE_CRON_COMMENT="# Mise Weekly Auto Update"
readonly MISE_CRON_SCHEDULE="0 1 * * 0"
readonly MISE_UPDATE_LOG="/var/log/mise-update.log"
readonly MISE_UPDATE_LOCK="/var/lock/mise-self-update.lock"

# === 日志 ===
log() {
    local message="$1"
    local level="${2:-info}"
    local -A colors=(
        [info]="\033[0;36m"
        [warn]="\033[0;33m"
        [error]="\033[0;31m"
        [success]="\033[0;32m"
    )

    echo -e "${colors[$level]:-\033[0m]}${message}\033[0m"
}

require_root() {
    if (( EUID != 0 )); then
        log "需要 root 权限运行" "error"
        exit 1
    fi
}

# === Mise 基础函数 ===
get_mise_executable() {
    local candidate
    local candidates=(
        "$MISE_PATH"
        "$HOME/.local/share/mise/bin/mise"
        "/usr/local/bin/mise"
    )

    for candidate in "${candidates[@]}"; do
        if [[ -x "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    command -v mise 2>/dev/null || return 1
}

get_mise_version() {
    local mise_cmd

    if ! mise_cmd=$(get_mise_executable); then
        printf '%s\n' "未安装"
        return 1
    fi

    "$mise_cmd" --version 2>/dev/null | head -n 1
}

get_active_tool_version() {
    local tool="$1"
    local config_file="$MISE_CONFIG_DIR/config.toml"

    [[ -f "$config_file" ]] || return 1

    awk -v tool="$tool" '
        /^\[tools\][[:space:]]*$/ {
            in_tools = 1
            next
        }

        /^\[/ {
            in_tools = 0
        }

        in_tools {
            pattern = "^[[:space:]]*" tool "[[:space:]]*="
            if ($0 ~ pattern) {
                value = $0
                sub(/^[^=]*=[[:space:]]*/, "", value)
                gsub(/^[[:space:]]*"|"[[:space:]]*$/, "", value)
                gsub(/[[:space:]]*#.*/, "", value)
                print value
                exit
            }
        }
    ' "$config_file"
}

run_mise_installer() {
    local installer
    local result=0

    installer=$(mktemp) || {
        log "无法创建 Mise 安装临时文件" "error"
        return 1
    }

    if ! curl -fsSL \
        --connect-timeout 10 \
        --max-time 60 \
        "https://mise.run" \
        -o "$installer"; then
        rm -f "$installer"
        log "Mise 安装脚本下载失败" "error"
        return 1
    fi

    if [[ ! -s "$installer" ]]; then
        rm -f "$installer"
        log "Mise 安装脚本为空" "error"
        return 1
    fi

    MISE_INSTALL_PATH="$MISE_PATH" sh "$installer" || result=$?
    rm -f "$installer"

    return "$result"
}

install_or_update_mise() {
    local mise_cmd
    local old_version
    local new_version
    local choice

    if mise_cmd=$(get_mise_executable); then
        old_version=$("$mise_cmd" --version 2>/dev/null | head -n 1)
        echo "Mise 状态: 已安装（$old_version）"

        read -r -p "是否更新 Mise 到最新版？[y/N]: " choice
        choice="${choice:-N}"

        if [[ ! "$choice" =~ ^[Yy]$ ]]; then
            echo "Mise 更新: 跳过"
            return 0
        fi

        log "更新 Mise..." "info"

        if ! run_mise_installer; then
            log "Mise 更新失败，继续使用现有版本" "warn"
            return 1
        fi

        new_version=$(get_mise_version)
        echo "Mise 更新: ${old_version} -> ${new_version}"
        return 0
    fi

    log "安装最新版 Mise..." "info"

    if ! run_mise_installer; then
        log "Mise 安装失败" "error"
        return 1
    fi

    echo "Mise 安装: 成功（$(get_mise_version)）"
}

# === Shell 集成 ===
write_activation_files() {
    mkdir -p "$MISE_CONFIG_DIR"
    chmod 700 "$MISE_CONFIG_DIR" 2>/dev/null || true

    cat > "$MISE_ZSH_ACTIVATE_FILE" <<'EOF'
# 由 mise-setup.sh 自动生成，请勿手动编辑。

_mise_bin=""

for _mise_candidate in \
    "$HOME/.local/bin/mise" \
    "$HOME/.local/share/mise/bin/mise" \
    "/usr/local/bin/mise"; do
    if [[ -x "$_mise_candidate" ]]; then
        _mise_bin="$_mise_candidate"
        break
    fi
done

if [[ -z "$_mise_bin" ]]; then
    _mise_bin="$(command -v mise 2>/dev/null || true)"
fi

if [[ -n "$_mise_bin" && -x "$_mise_bin" ]]; then
    eval "$("$_mise_bin" activate zsh)"
fi

unset _mise_bin _mise_candidate
EOF

    cat > "$MISE_BASH_ACTIVATE_FILE" <<'EOF'
# 由 mise-setup.sh 自动生成，请勿手动编辑。

_mise_bin=""

for _mise_candidate in \
    "$HOME/.local/bin/mise" \
    "$HOME/.local/share/mise/bin/mise" \
    "/usr/local/bin/mise"; do
    if [[ -x "$_mise_candidate" ]]; then
        _mise_bin="$_mise_candidate"
        break
    fi
done

if [[ -z "$_mise_bin" ]]; then
    _mise_bin="$(command -v mise 2>/dev/null || true)"
fi

if [[ -n "$_mise_bin" && -x "$_mise_bin" ]]; then
    eval "$("$_mise_bin" activate bash)"
fi

unset _mise_bin _mise_candidate
EOF

    chmod 644 "$MISE_ZSH_ACTIVATE_FILE" "$MISE_BASH_ACTIVATE_FILE"
}

ensure_loader_entry() {
    local shell_file="$1"
    local marker="$2"
    local loader_line="$3"
    local temp_file

    [[ -f "$shell_file" ]] || touch "$shell_file"

    temp_file=$(mktemp) || {
        log "无法创建 Shell 配置临时文件" "error"
        return 1
    }

    # 只对脚本管理的两行做精确去重，不影响其他用户配置。
    awk -v marker="$marker" -v loader="$loader_line" '
        $0 == marker {
            if (marker_seen++) {
                next
            }
        }

        $0 == loader {
            if (loader_seen++) {
                next
            }
        }

        {
            print
        }
    ' "$shell_file" > "$temp_file"

    if ! cat "$temp_file" > "$shell_file"; then
        rm -f "$temp_file"
        log "无法更新 Shell 配置：$shell_file" "error"
        return 1
    fi

    rm -f "$temp_file"

    # 已经有实际加载命令，不需要再次追加。
    if grep -Fqx "$loader_line" "$shell_file" 2>/dev/null; then
        return 0
    fi

    # marker 可能存在但加载命令缺失。
    if ! grep -Fqx "$marker" "$shell_file" 2>/dev/null; then
        printf '\n%s\n' "$marker" >> "$shell_file"
    fi

    printf '%s\n' "$loader_line" >> "$shell_file"

    echo "Shell 集成: 已添加到 $shell_file"
}

configure_shell_integration() {
    write_activation_files || return 1

    ensure_loader_entry \
        "$ZSHRC_FILE" \
        "$ZSH_LOADER_MARKER" \
        '[[ -r "$HOME/.config/mise/activate.zsh" ]] && source "$HOME/.config/mise/activate.zsh"'

    ensure_loader_entry \
        "$BASHRC_FILE" \
        "$BASH_LOADER_MARKER" \
        '[[ -r "$HOME/.config/mise/activate.bash" ]] && source "$HOME/.config/mise/activate.bash"'

    echo "Shell 集成: 已配置"
}

# === 通用备份目录 ===
prepare_backup_dir() {
    mkdir -p "$MISE_DEPENDENCY_BACKUP_DIR"
    chmod 700 "$MISE_DEPENDENCY_BACKUP_DIR" 2>/dev/null || true
}

# === Python 依赖迁移 ===
get_installed_python_versions() {
    local mise_cmd

    mise_cmd=$(get_mise_executable) || return 0

    "$mise_cmd" ls python 2>/dev/null |
        awk '$1 == "python" && $2 ~ /^[0-9]+\.[0-9]+\.[0-9]+$/ { print $2 }' |
        sort -V -u
}

backup_python_packages() {
    local mise_cmd="$1"
    local version="$2"
    local backup_file="$MISE_DEPENDENCY_BACKUP_DIR/python-$version.txt"
    local temp_file

    prepare_backup_dir
    temp_file=$(mktemp "$MISE_DEPENDENCY_BACKUP_DIR/.python-$version.XXXXXX") || return 1

    if ! "$mise_cmd" exec "python@$version" -- \
        python -m pip freeze > "$temp_file"; then
        rm -f "$temp_file"
        log "无法导出 Python $version 的依赖，已取消升级" "error"
        return 1
    fi

    mv -f "$temp_file" "$backup_file"
    chmod 600 "$backup_file" 2>/dev/null || true

    PYTHON_PACKAGE_BACKUP="$backup_file"
    echo "Python 依赖: 已备份到 $backup_file"
}

restore_python_packages() {
    local mise_cmd="$1"
    local version="$2"
    local backup_file="$3"

    [[ -f "$backup_file" ]] || return 0

    if [[ -s "$backup_file" ]]; then
        log "恢复 Python 依赖到 $version..." "info"

        "$mise_cmd" exec "python@$version" -- \
            python -m pip install -r "$backup_file" || return 1
    else
        echo "Python 依赖: 旧版本没有额外第三方包，无需恢复"
    fi

    "$mise_cmd" exec "python@$version" -- python -m pip check
}

cleanup_old_python_versions() {
    local active_version="$1"
    local mise_cmd
    local versions
    local choice
    local version

    mise_cmd=$(get_mise_executable) || return 0
    versions=$(get_installed_python_versions | grep -Fxv "$active_version" || true)

    [[ -n "$versions" ]] || return 0

    echo
    echo "检测到其他已安装的 Python 版本："
    while IFS= read -r version; do
        [[ -n "$version" ]] && echo "  - Python $version"
    done <<< "$versions"

    read -r -p "依赖已恢复，是否删除这些旧 Python 版本？[y/N]: " choice
    choice="${choice:-N}"

    if [[ ! "$choice" =~ ^[Yy]$ ]]; then
        echo "Python 清理: 保留其他版本"
        return 0
    fi

    while IFS= read -r version; do
        [[ -z "$version" ]] && continue

        if "$mise_cmd" uninstall "python@$version"; then
            echo "Python $version: 已删除"
        else
            log "Python $version 删除失败" "warn"
        fi
    done <<< "$versions"
}

setup_python() {
    local mise_cmd
    local current_version
    local selected_version
    local active_version
    local PYTHON_PACKAGE_BACKUP=""

    mise_cmd=$(get_mise_executable) || {
        log "找不到 Mise 可执行文件" "error"
        return 1
    }

    current_version=$(get_active_tool_version "python" || true)

    if [[ -n "$current_version" ]]; then
        echo "当前 Mise Python: $current_version"
    else
        echo "当前 Mise Python: 未配置"
    fi

    echo
    echo "Python 版本选择："
    echo "  1) 安装最新版本"
    echo "  2) 手动输入版本号"
    echo "  3) 保持当前配置（默认）"

    local choice
    local selected_input
    read -r -p "请选择 [1-3]（默认 3）: " choice
    choice="${choice:-3}"

    case "$choice" in
        1)
            selected_version=$("$mise_cmd" latest python)
            ;;
        2)
            read -r -p "输入 Python 版本号（如 3.14.6）: " selected_input
            if [[ ! "$selected_input" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
                log "版本号格式错误，保持当前配置" "warn"
                return 0
            fi
            selected_version="$selected_input"
            ;;
        *)
            echo "Python 配置: 保持当前"
            return 0
            ;;
    esac

    if [[ -n "$current_version" ]]; then
        backup_python_packages "$mise_cmd" "$current_version" || return 1
    fi

    log "安装 Python $selected_version..." "info"

    if ! "$mise_cmd" install "python@$selected_version"; then
        log "Python $selected_version 安装失败" "error"
        return 1
    fi

    if ! "$mise_cmd" use -g "python@$selected_version"; then
        log "Python 已安装，但设置全局版本失败" "error"
        return 1
    fi

    active_version=$(get_active_tool_version "python" || true)
    active_version="${active_version:-$selected_version}"

    if [[ -n "$current_version" && "$active_version" != "$current_version" ]]; then
        if ! restore_python_packages \
            "$mise_cmd" \
            "$active_version" \
            "$PYTHON_PACKAGE_BACKUP"; then
            log "Python 依赖恢复失败，正在切回 $current_version" "error"
            "$mise_cmd" use -g "python@$current_version" || true
            log "新旧 Python 均已保留，未删除任何版本" "warn"
            return 1
        fi

        echo "Python 依赖: 已恢复并通过 pip check 检查"
    fi

    echo "Python 配置: $active_version 已设为全局版本"
    cleanup_old_python_versions "$active_version"
}

# === Node.js 全局 npm 包迁移 ===
ensure_node_runtime_dependencies() {
    if ldconfig -p 2>/dev/null | grep -Fq "libatomic.so.1"; then
        return 0
    fi

    log "安装 Node.js 运行依赖: libatomic1" "info"

    if ! apt-get install -y libatomic1; then
        log "libatomic1 安装失败，无法继续安装 Node.js" "error"
        return 1
    fi
}

get_installed_node_versions() {
    local mise_cmd

    mise_cmd=$(get_mise_executable) || return 0

    "$mise_cmd" ls node 2>/dev/null |
        awk '$1 == "node" && $2 ~ /^[0-9]+\.[0-9]+\.[0-9]+$/ { print $2 }' |
        sort -V -u
}

backup_node_packages() {
    local mise_cmd="$1"
    local version="$2"
    local backup_file="$MISE_DEPENDENCY_BACKUP_DIR/node-$version.txt"
    local temp_json
    local temp_file

    prepare_backup_dir
    temp_json=$(mktemp "$MISE_DEPENDENCY_BACKUP_DIR/.node-$version.XXXXXX.json") || return 1
    temp_file=$(mktemp "$MISE_DEPENDENCY_BACKUP_DIR/.node-$version.XXXXXX.txt") || {
        rm -f "$temp_json"
        return 1
    }

    if ! "$mise_cmd" exec "node@$version" -- \
        npm ls -g --depth=0 --json > "$temp_json"; then
        rm -f "$temp_json" "$temp_file"
        log "无法读取 Node.js $version 的全局 npm 包，已取消升级" "error"
        return 1
    fi

    if ! "$mise_cmd" exec "node@$version" -- \
        node -e '
            const fs = require("fs");
            const data = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
            const dependencies = data.dependencies || {};

            for (const [name, meta] of Object.entries(dependencies)) {
                if (name !== "npm" && name !== "corepack" && meta.version) {
                    console.log(`${name}@${meta.version}`);
                }
            }
        ' "$temp_json" > "$temp_file"; then
        rm -f "$temp_json" "$temp_file"
        log "无法解析 Node.js $version 的全局 npm 包，已取消升级" "error"
        return 1
    fi

    rm -f "$temp_json"
    mv -f "$temp_file" "$backup_file"
    chmod 600 "$backup_file" 2>/dev/null || true

    NODE_PACKAGE_BACKUP="$backup_file"
    echo "npm 全局包: 已备份到 $backup_file"
}

restore_node_packages() {
    local mise_cmd="$1"
    local version="$2"
    local backup_file="$3"
    local packages=()

    [[ -f "$backup_file" ]] || return 0
    mapfile -t packages < "$backup_file"

    if (( ${#packages[@]} == 0 )); then
        echo "npm 全局包: 旧版本没有额外全局包，无需恢复"
        return 0
    fi

    log "恢复 npm 全局包到 Node.js $version..." "info"

    "$mise_cmd" exec "node@$version" -- \
        npm install -g -- "${packages[@]}" || return 1

    "$mise_cmd" exec "node@$version" -- \
        npm ls -g --depth=0 >/dev/null
}

cleanup_old_node_versions() {
    local active_version="$1"
    local mise_cmd
    local versions
    local choice
    local version

    mise_cmd=$(get_mise_executable) || return 0
    versions=$(get_installed_node_versions | grep -Fxv "$active_version" || true)

    [[ -n "$versions" ]] || return 0

    echo
    echo "检测到其他已安装的 Node.js 版本："
    while IFS= read -r version; do
        [[ -n "$version" ]] && echo "  - Node.js $version"
    done <<< "$versions"

    read -r -p "全局 npm 包已恢复，是否删除这些旧 Node.js 版本？[y/N]: " choice
    choice="${choice:-N}"

    if [[ ! "$choice" =~ ^[Yy]$ ]]; then
        echo "Node.js 清理: 保留其他版本"
        return 0
    fi

    while IFS= read -r version; do
        [[ -z "$version" ]] && continue

        if "$mise_cmd" uninstall "node@$version"; then
            echo "Node.js $version: 已删除"
        else
            log "Node.js $version 删除失败" "warn"
        fi
    done <<< "$versions"
}

setup_node() {
    local mise_cmd
    local current_version
    local selected_version
    local active_version
    local NODE_PACKAGE_BACKUP=""

    mise_cmd=$(get_mise_executable) || {
        log "找不到 Mise 可执行文件" "error"
        return 1
    }

    current_version=$(get_active_tool_version "node" || true)

    if [[ -n "$current_version" ]]; then
        echo "当前 Mise Node.js: $current_version"
    else
        echo "当前 Mise Node.js: 未配置"
    fi

    echo
    echo "Node.js 版本选择："
    echo "  1) 安装最新版本"
    echo "  2) 安装最新 LTS 版本"
    echo "  3) 手动输入版本号"
    echo "  4) 保持当前配置（默认）"

    local choice
    local selected_input
    read -r -p "请选择 [1-4]（默认 4）: " choice
    choice="${choice:-4}"

    case "$choice" in
        1)
            selected_version=$("$mise_cmd" latest node)
            ;;
        2)
            selected_version="lts"
            ;;
        3)
            read -r -p "输入 Node.js 版本号（如 24.4.0）: " selected_input
            if [[ ! "$selected_input" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
                log "版本号格式错误，保持当前配置" "warn"
                return 0
            fi
            selected_version="$selected_input"
            ;;
        *)
            echo "Node.js 配置: 保持当前"
            return 0
            ;;
    esac

    if [[ -n "$current_version" ]]; then
        backup_node_packages "$mise_cmd" "$current_version" || return 1
    fi

    ensure_node_runtime_dependencies || return 1

    log "安装 Node.js $selected_version..." "info"

    if ! "$mise_cmd" install "node@$selected_version"; then
        log "Node.js $selected_version 安装失败" "error"
        return 1
    fi

    if ! "$mise_cmd" use -g "node@$selected_version"; then
        log "Node.js 已安装，但设置全局版本失败" "error"
        return 1
    fi

    active_version=$(get_active_tool_version "node" || true)
    active_version="${active_version:-$selected_version}"

    if [[ -n "$current_version" && "$active_version" != "$current_version" ]]; then
        if ! restore_node_packages \
            "$mise_cmd" \
            "$active_version" \
            "$NODE_PACKAGE_BACKUP"; then
            log "npm 全局包恢复失败，正在切回 Node.js $current_version" "error"
            "$mise_cmd" use -g "node@$current_version" || true
            log "新旧 Node.js 均已保留，未删除任何版本" "warn"
            return 1
        fi

        echo "npm 全局包: 已恢复并通过检查"
    fi

    echo "Node.js 配置: $active_version 已设为全局版本"
    cleanup_old_node_versions "$active_version"
}

# === Mise 自动更新 ===
ensure_cron_installed() {
    if command -v crontab >/dev/null 2>&1; then
        return 0
    fi

    log "安装 Cron 服务..." "info"

    if ! apt-get install -y cron; then
        log "Cron 服务安装失败" "error"
        return 1
    fi

    if ! systemctl enable --now cron >/dev/null 2>&1; then
        log "Cron 服务启动失败" "error"
        return 1
    fi
}

configure_mise_cron() {
    local temp_cron
    local current_cron
    local cron_command

    ensure_cron_installed || return 1

    touch "$MISE_UPDATE_LOG"
    chmod 600 "$MISE_UPDATE_LOG" 2>/dev/null || true

    cron_command="/usr/bin/flock -n $MISE_UPDATE_LOCK $MISE_PATH self-update >> $MISE_UPDATE_LOG 2>&1"
    temp_cron=$(mktemp) || return 1

    current_cron=$(crontab -l 2>/dev/null || true)

    {
        printf '%s\n' "$current_cron" |
            grep -Fv "$MISE_CRON_COMMENT" |
            grep -Fv "$MISE_UPDATE_LOCK" || true

        echo "$MISE_CRON_COMMENT"
        echo "$MISE_CRON_SCHEDULE $cron_command"
    } > "$temp_cron"

    if ! crontab "$temp_cron"; then
        rm -f "$temp_cron"
        log "Mise 自动更新任务配置失败" "error"
        return 1
    fi

    rm -f "$temp_cron"
    echo "Mise 自动更新: 已配置（每周日 01:00）"
}

# === 主流程 ===
main() {
    require_root

    local command_name
    for command_name in curl mktemp flock awk grep sort ldconfig; do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            log "缺少必要命令: $command_name" "error"
            exit 1
        fi
    done

    log "配置 Mise 版本管理器..." "info"

    echo
    install_or_update_mise || exit 1

    echo
    configure_shell_integration

    echo
    setup_python || log "Python 配置失败，可稍后重新运行此模块" "warn"

    echo
    setup_node || log "Node.js 配置失败，可稍后重新运行此模块" "warn"

    echo
    configure_mise_cron || log "Mise 自动更新任务配置失败" "warn"

    echo
    log "Mise 配置完成" "success"
    echo
    log "Mise 配置完成" "success"
    echo "当前 Shell 尚未重新加载 Mise 环境。"
    echo "请执行：exec zsh"
}

trap 'log "脚本在第 $LINENO 行执行失败" "error"' ERR

main "$@"
