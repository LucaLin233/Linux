#!/usr/bin/env bash
# Mise 版本管理器配置模块
# 功能：安装最新版 Mise、配置 Shell 集成、管理 Python/Node.js、每周自动更新

set -euo pipefail

# === 常量定义 ===
readonly MISE_BIN_DIR="$HOME/.local/bin"
readonly MISE_PATH="$MISE_BIN_DIR/mise"
readonly MISE_CONFIG_DIR="$HOME/.config/mise"
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

# === 日志函数 ===
log() {
    local msg="$1"
    local level="${2:-info}"
    local -A colors=(
        [info]="\033[0;36m"
        [warn]="\033[0;33m"
        [error]="\033[0;31m"
        [debug]="\033[0;35m"
        [success]="\033[0;32m"
    )

    if [[ "$level" == "debug" && "${DEBUG:-}" != "1" ]]; then
        return 0
    fi

    echo -e "${colors[$level]:-\033[0;32m}${msg}\033[0m"
}

debug_log() {
    log "DEBUG: $1" "debug"
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
            echo "$candidate"
            return 0
        fi
    done

    if command -v mise >/dev/null 2>&1; then
        command -v mise
        return 0
    fi

    return 1
}

get_mise_version() {
    local mise_cmd

    if ! mise_cmd=$(get_mise_executable); then
        echo "未安装"
        return 1
    fi

    "$mise_cmd" --version 2>/dev/null | head -n 1 || echo "未知"
}

get_current_tool_version() {
    local tool="$1"
    local mise_cmd
    local output

    mise_cmd=$(get_mise_executable) || return 1
    output=$("$mise_cmd" current "$tool" 2>/dev/null || true)

    [[ -n "$output" ]] || return 1

    # 常见输出格式：
    # python 3.14.6 /root/.config/mise/config.toml
    # node   24.12.0 /root/.config/mise/config.toml
    awk 'NR == 1 {print $2; exit}' <<< "$output"
}

get_global_tool_version() {
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

package_is_installed() {
    local tool="$1"
    local version="$2"
    local mise_cmd

    mise_cmd=$(get_mise_executable) || return 1

    "$mise_cmd" ls "$tool" 2>/dev/null |
        awk -v expected="$version" '
            $1 == tool && $2 == expected {found=1}
            END {exit !found}
        ' tool="$tool"
}

# === Mise 安装与更新 ===
run_mise_installer() {
    local installer
    local result=0

    if ! installer=$(mktemp); then
        log "无法创建 Mise 安装临时文件" "error"
        return 1
    fi

    debug_log "下载最新版 Mise 安装脚本"

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

    debug_log "执行 Mise 安装脚本"

    MISE_INSTALL_PATH="$MISE_PATH" sh "$installer" || result=$?
    rm -f "$installer"

    return "$result"
}

install_or_update_mise() {
    local mise_cmd
    local old_version
    local new_version
    local update_choice

    if mise_cmd=$(get_mise_executable); then
        old_version=$("$mise_cmd" --version 2>/dev/null | head -n 1 || echo "未知")
        echo "Mise 状态: 已安装（$old_version）"

        read -r -p "是否更新 Mise 到最新版？[y/N]: " update_choice
        update_choice="${update_choice:-N}"

        if [[ ! "$update_choice" =~ ^[Yy]$ ]]; then
            echo "Mise 更新: 跳过"
            return 0
        fi

        log "更新 Mise..." "info"

        if ! run_mise_installer; then
            log "Mise 更新失败，继续使用现有版本" "warn"
            return 1
        fi

        new_version=$(get_mise_version)
        echo "Mise 更新: ${old_version} → ${new_version}"
        return 0
    fi

    log "安装最新版 Mise..." "info"

    if ! run_mise_installer; then
        log "Mise 安装失败" "error"
        return 1
    fi

    if ! get_mise_executable >/dev/null; then
        log "Mise 安装后验证失败" "error"
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
# 缓存 activation 输出以减少新开 Zsh 的启动开销。

if [[ -x "$HOME/.local/bin/mise" ]]; then
  _mise_bin="$HOME/.local/bin/mise"
  _mise_cache="${XDG_CACHE_HOME:-$HOME/.cache}/mise_activate.zsh"

  if [[ ! -r "$_mise_cache" || "$_mise_bin" -nt "$_mise_cache" ]]; then
    mkdir -p "${XDG_CACHE_HOME:-$HOME/.cache}"
    "$_mise_bin" activate zsh > "$_mise_cache"
  fi

  source "$_mise_cache"
  unset _mise_bin _mise_cache
fi
EOF

    cat > "$MISE_BASH_ACTIVATE_FILE" <<'EOF'
# 由 mise-setup.sh 自动生成，请勿手动编辑。

if [[ -x "$HOME/.local/bin/mise" ]]; then
    eval "$("$HOME/.local/bin/mise" activate bash)"
fi
EOF

    chmod 644 "$MISE_ZSH_ACTIVATE_FILE" "$MISE_BASH_ACTIVATE_FILE"
}

ensure_loader_entry() {
    local shell_file="$1"
    local marker="$2"
    local loader_line="$3"

    [[ -f "$shell_file" ]] || touch "$shell_file"

    if grep -Fqx "$marker" "$shell_file" 2>/dev/null; then
        debug_log "Shell 加载入口已存在：$shell_file"
        return 0
    fi

    cat >> "$shell_file" <<EOF

$marker
$loader_line
EOF

    echo "Shell 集成: 已添加到 $shell_file"
}

configure_shell_integration() {
    write_activation_files

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

# === Python 管理 ===
get_installed_python_versions() {
    local mise_cmd

    mise_cmd=$(get_mise_executable) || return 0

    "$mise_cmd" ls python 2>/dev/null |
        awk '$1 == "python" && $2 ~ /^[0-9]+\.[0-9]+\.[0-9]+$/ {print $2}' |
        sort -V -u
}

choose_python_version() {
    local mise_cmd
    local latest_version
    local choice
    local custom_version

    mise_cmd=$(get_mise_executable) || return 1
    latest_version=$("$mise_cmd" latest python 2>/dev/null || true)
    latest_version="${latest_version:-3.13}"

    # 注意：此函数由命令替换调用。
    # 菜单与提示必须输出到 stderr，stdout 只能输出最终选择结果。
    echo >&2
    echo "Python 版本选择：" >&2
    echo "  1) 安装最新版本（Python $latest_version）" >&2
    echo "  2) 手动输入版本号" >&2
    echo "  3) 保持当前配置（默认）" >&2
    echo >&2

    read -r -p "请选择 [1-3]（默认 3）: " choice >&2
    choice="${choice:-3}"

    case "$choice" in
        1)
            echo "$latest_version"
            ;;
        2)
            read -r -p "输入 Python 版本号（如 3.13.1）: " custom_version >&2

            if [[ "$custom_version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
                echo "$custom_version"
            else
                log "版本号格式错误，保持当前配置" "warn" >&2
                echo "current"
            fi
            ;;
        *)
            echo "current"
            ;;
    esac
}

cleanup_old_python_versions() {
    local current_version="$1"
    local mise_cmd
    local versions
    local cleanup_choice
    local version

    mise_cmd=$(get_mise_executable) || return 0
    versions=$(get_installed_python_versions | grep -Fxv "$current_version" || true)

    [[ -n "$versions" ]] || return 0

    echo
    echo "检测到其他已安装的 Python 版本："

    while IFS= read -r version; do
        [[ -n "$version" ]] && echo "  - Python $version"
    done <<< "$versions"

    read -r -p "是否删除这些其他 Python 版本？[y/N]: " cleanup_choice
    cleanup_choice="${cleanup_choice:-N}"

    if [[ ! "$cleanup_choice" =~ ^[Yy]$ ]]; then
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
    local resolved_version

    mise_cmd=$(get_mise_executable) || {
        log "找不到 Mise 可执行文件" "error"
        return 1
    }

    current_version=$(get_global_tool_version "python" || true)

    if [[ -n "$current_version" ]]; then
        echo "当前 Mise Python: $current_version"
    else
        echo "当前 Mise Python: 未配置"
    fi

    selected_version=$(choose_python_version)

    if [[ "$selected_version" == "current" ]]; then
        echo "Python 配置: 保持当前"
        return 0
    fi

    log "安装 Python $selected_version..." "info"

    if ! "$mise_cmd" install "python@$selected_version"; then
        log "Python $selected_version 安装失败" "error"
        return 1
    fi

    log "设置 Mise 全局 Python 为 $selected_version..." "info"

    if ! "$mise_cmd" use -g "python@$selected_version"; then
        log "Python 已安装，但设置全局版本失败" "error"
        return 1
    fi

    resolved_version=$(get_current_tool_version "python" || true)
    resolved_version="${resolved_version:-$selected_version}"

    echo "Python 配置: $resolved_version 已安装并设为 Mise 全局版本"
    cleanup_old_python_versions "$resolved_version"
}

# === Node.js 管理 ===
get_installed_node_versions() {
    local mise_cmd

    mise_cmd=$(get_mise_executable) || return 0

    "$mise_cmd" ls node 2>/dev/null |
        awk '$1 == "node" && $2 ~ /^[0-9]+\.[0-9]+\.[0-9]+$/ {print $2}' |
        sort -V -u
}

choose_node_version() {
    local mise_cmd
    local latest_version
    local choice
    local custom_version

    mise_cmd=$(get_mise_executable) || return 1
    latest_version=$("$mise_cmd" latest node 2>/dev/null || true)
    latest_version="${latest_version:-lts}"

    # 注意：此函数由命令替换调用。
    # 菜单与提示必须输出到 stderr，stdout 只能输出最终选择结果。
    echo >&2
    echo "Node.js 版本选择：" >&2
    echo "  1) 安装最新版本（Node.js $latest_version）" >&2
    echo "  2) 安装最新 LTS 版本" >&2
    echo "  3) 手动输入版本号" >&2
    echo "  4) 保持当前配置（默认）" >&2
    echo >&2

    read -r -p "请选择 [1-4]（默认 4）: " choice >&2
    choice="${choice:-4}"

    case "$choice" in
        1)
            echo "$latest_version"
            ;;
        2)
            echo "lts"
            ;;
        3)
            read -r -p "输入 Node.js 版本号（如 22.14.0）: " custom_version >&2

            if [[ "$custom_version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
                echo "$custom_version"
            else
                log "版本号格式错误，保持当前配置" "warn" >&2
                echo "current"
            fi
            ;;
        *)
            echo "current"
            ;;
    esac
}

cleanup_old_node_versions() {
    local current_version="$1"
    local mise_cmd
    local versions
    local cleanup_choice
    local version

    mise_cmd=$(get_mise_executable) || return 0
    versions=$(get_installed_node_versions | grep -Fxv "$current_version" || true)

    [[ -n "$versions" ]] || return 0

    echo
    echo "检测到其他已安装的 Node.js 版本："

    while IFS= read -r version; do
        [[ -n "$version" ]] && echo "  - Node.js $version"
    done <<< "$versions"

    read -r -p "是否删除这些其他 Node.js 版本？[y/N]: " cleanup_choice
    cleanup_choice="${cleanup_choice:-N}"

    if [[ ! "$cleanup_choice" =~ ^[Yy]$ ]]; then
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
    local resolved_version

    mise_cmd=$(get_mise_executable) || {
        log "找不到 Mise 可执行文件" "error"
        return 1
    }

    current_version=$(get_global_tool_version "node" || true)

    if [[ -n "$current_version" ]]; then
        echo "当前 Mise Node.js: $current_version"
    else
        echo "当前 Mise Node.js: 未配置"
    fi

    selected_version=$(choose_node_version)

    if [[ "$selected_version" == "current" ]]; then
        echo "Node.js 配置: 保持当前"
        return 0
    fi

    log "安装 Node.js $selected_version..." "info"

    if ! "$mise_cmd" install "node@$selected_version"; then
        log "Node.js $selected_version 安装失败" "error"
        return 1
    fi

    log "设置 Mise 全局 Node.js 为 $selected_version..." "info"

    if ! "$mise_cmd" use -g "node@$selected_version"; then
        log "Node.js 已安装，但设置全局版本失败" "error"
        return 1
    fi

    resolved_version=$(get_current_tool_version "node" || true)
    resolved_version="${resolved_version:-$selected_version}"

    echo "Node.js 配置: $resolved_version 已安装并设为 Mise 全局版本"
    cleanup_old_node_versions "$resolved_version"
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

    command -v crontab >/dev/null 2>&1
}

configure_mise_cron() {
    local temp_cron
    local current_cron
    local cron_command

    ensure_cron_installed || {
        log "Cron 不可用，无法配置 Mise 自动更新" "error"
        return 1
    }

    if [[ ! -x "$MISE_PATH" ]]; then
        log "找不到 Mise：$MISE_PATH" "error"
        return 1
    fi

    touch "$MISE_UPDATE_LOG"
    chmod 600 "$MISE_UPDATE_LOG" 2>/dev/null || true

    cron_command="/usr/bin/flock -n $MISE_UPDATE_LOCK $MISE_PATH self-update >> $MISE_UPDATE_LOG 2>&1"

    if ! temp_cron=$(mktemp); then
        log "无法创建 Cron 临时文件" "error"
        return 1
    fi

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
    echo "更新日志: $MISE_UPDATE_LOG"
}

# === 摘要 ===
show_summary() {
    local mise_cmd
    local python_version
    local node_version
    local cron_status="未配置"

    echo
    log "🎯 Mise 配置摘要：" "info"

    if mise_cmd=$(get_mise_executable); then
        echo "  Mise: $("$mise_cmd" --version 2>/dev/null | head -n 1)"

        python_version=$(get_global_tool_version "python" || true)
        node_version=$(get_global_tool_version "node" || true)

        if [[ -n "$python_version" ]]; then
            echo "  Mise Python: $python_version"
        else
            echo "  Mise Python: 未配置"
        fi

        if [[ -n "$node_version" ]]; then
            echo "  Mise Node.js: $node_version"
        else
            echo "  Mise Node.js: 未配置"
        fi
    else
        echo "  Mise: 未安装"
    fi

    [[ -r "$MISE_ZSH_ACTIVATE_FILE" ]] &&
        echo "  Zsh 集成: 已配置" ||
        echo "  Zsh 集成: 未配置"

    [[ -r "$MISE_BASH_ACTIVATE_FILE" ]] &&
        echo "  Bash 集成: 已配置" ||
        echo "  Bash 集成: 未配置"

    if crontab -l 2>/dev/null | grep -Fq "$MISE_UPDATE_LOCK"; then
        cron_status="每周日 01:00 自动更新"
    fi

    echo "  自动更新: $cron_status"
    echo "  更新日志: $MISE_UPDATE_LOG"
}

# === 主流程 ===
main() {
    require_root

    local command_name
    for command_name in curl mktemp flock awk grep sort; do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            log "缺少必要命令: $command_name" "error"
            exit 1
        fi
    done

    log "📦 配置 Mise 版本管理器..." "info"

    echo
    install_or_update_mise || exit 1

    echo
    configure_shell_integration

    echo
    setup_python || log "Python 配置失败，可稍后单独重新运行 Mise 模块" "warn"

    echo
    setup_node || log "Node.js 配置失败，可稍后单独重新运行 Mise 模块" "warn"

    echo
    configure_mise_cron || log "Mise 自动更新任务配置失败" "warn"

    show_summary

    echo
    log "✅ Mise 配置完成" "success"
    echo "重新打开 Shell 或执行以下命令后生效："
    echo "  exec zsh"
}

trap 'log "Mise 配置脚本在第 $LINENO 行执行失败" "error"' ERR

main "$@"
