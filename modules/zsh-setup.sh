#!/usr/bin/env bash
# linux-setup:name=Zsh Shell 环境
# linux-setup:order=40
# linux-setup:depends=
# linux-setup:enabled=true
# Zsh Shell 环境配置模块
# 功能：安装 Zsh、Oh My Zsh、Powerlevel10k 及常用插件

set -euo pipefail

# === 常量定义 ===
readonly RUN_COMMIT="${RUN_COMMIT:-}"
readonly ZSH_DIR="$HOME/.oh-my-zsh"
readonly CUSTOM_DIR="${ZSH_CUSTOM:-$ZSH_DIR/custom}"
readonly THEME_DIR="$CUSTOM_DIR/themes/powerlevel10k"
readonly PLUGINS_DIR="$CUSTOM_DIR/plugins"
readonly ZSHRC_FILE="$HOME/.zshrc"
readonly ZSHRC_INITIAL_BACKUP="$HOME/.zshrc.initial-backup"
readonly ZSHRC_PREVIOUS_BACKUP="$HOME/.zshrc.previous-backup"
readonly ZSHRC_INITIAL_ABSENT="$HOME/.zshrc.initial-absent"
readonly ZSHRC_INITIAL_UNKNOWN="$HOME/.zshrc.initial-unknown"
readonly ZSHRC_PREVIOUS_ABSENT="$HOME/.zshrc.previous-absent"
readonly P10K_FILE="$HOME/.p10k.zsh"
readonly ZSH_STATE_DIR="/var/lib/linux-setup/zsh"

# === 日志函数 ===
log() {
    local msg="$1"
    local level="${2:-info}"
    local -A colors=(
        [info]="\033[0;36m"
        [warn]="\033[0;33m"
        [error]="\033[0;31m"
        [debug]="\033[0;35m"
    )

    echo -e "${colors[$level]:-\033[0;32m}${msg}\033[0m"
}

debug_log() {
    if [[ "${DEBUG:-}" == "1" ]]; then
        log "DEBUG: $1" "debug" >&2
    fi
}

validate_run_commit() {
    [[ -z "$RUN_COMMIT" || "$RUN_COMMIT" =~ ^[0-9a-f]{40}$ ]]
}

# === 辅助函数 ===
backup_zshrc() {
    if [[ ! -e "$ZSHRC_INITIAL_BACKUP" && ! -e "$ZSHRC_INITIAL_ABSENT" &&
        ! -e "$ZSHRC_INITIAL_UNKNOWN" ]]; then
        if [[ -f "$ZSHRC_FILE" ]] && grep -Fq '此文件由 zsh-setup.sh 自动生成' "$ZSHRC_FILE"; then
            install -m 0600 /dev/null "$ZSHRC_INITIAL_UNKNOWN" || return 1
        elif [[ -f "$ZSHRC_FILE" ]]; then
            cp -a "$ZSHRC_FILE" "$ZSHRC_INITIAL_BACKUP" || return 1
        else
            install -m 0600 /dev/null "$ZSHRC_INITIAL_ABSENT" || return 1
        fi
    fi

    rm -f "$ZSHRC_PREVIOUS_BACKUP" "$ZSHRC_PREVIOUS_ABSENT"
    if [[ -f "$ZSHRC_FILE" ]]; then
        cp -a "$ZSHRC_FILE" "$ZSHRC_PREVIOUS_BACKUP" || return 1
        chmod 600 "$ZSHRC_PREVIOUS_BACKUP" 2>/dev/null || true
    else
        install -m 0600 /dev/null "$ZSHRC_PREVIOUS_ABSENT" || return 1
    fi
}

backup_zsh_auxiliary_state() {
    local current_shell

    install -d -m 0700 "$ZSH_STATE_DIR"
    if [[ -e "$ZSHRC_INITIAL_UNKNOWN" ]]; then
        [[ -e "$ZSH_STATE_DIR/p10k.initial-unknown" ]] || install -m 0600 /dev/null "$ZSH_STATE_DIR/p10k.initial-unknown"
        [[ -e "$ZSH_STATE_DIR/shell.initial-unknown" ]] || install -m 0600 /dev/null "$ZSH_STATE_DIR/shell.initial-unknown"
    fi
    if [[ ! -e "$ZSH_STATE_DIR/p10k.initial-backup" && ! -e "$ZSH_STATE_DIR/p10k.initial-absent" &&
        ! -e "$ZSH_STATE_DIR/p10k.initial-unknown" ]]; then
        if [[ -f "$P10K_FILE" ]]; then
            cp -a "$P10K_FILE" "$ZSH_STATE_DIR/p10k.initial-backup" || return 1
        else
            install -m 0600 /dev/null "$ZSH_STATE_DIR/p10k.initial-absent" || return 1
        fi
    fi
    rm -f "$ZSH_STATE_DIR/p10k.previous-backup" "$ZSH_STATE_DIR/p10k.previous-absent"
    if [[ -f "$P10K_FILE" ]]; then
        cp -a "$P10K_FILE" "$ZSH_STATE_DIR/p10k.previous-backup" || return 1
    else
        install -m 0600 /dev/null "$ZSH_STATE_DIR/p10k.previous-absent" || return 1
    fi

    current_shell=$(getent passwd root 2>/dev/null | cut -d: -f7)
    if [[ ! -f "$ZSH_STATE_DIR/shell.initial" && ! -f "$ZSH_STATE_DIR/shell.initial-unknown" ]]; then
        printf '%s
' "$current_shell" > "$ZSH_STATE_DIR/shell.initial"
        chmod 600 "$ZSH_STATE_DIR/shell.initial"
    fi
    printf '%s
' "$current_shell" > "$ZSH_STATE_DIR/shell.previous"
    chmod 600 "$ZSH_STATE_DIR/shell.previous"
}

install_oh_my_zsh() {
    local installer

    if [[ -d "$ZSH_DIR/.git" ]]; then
        if git -C "$ZSH_DIR" pull --ff-only >/dev/null 2>&1; then
            echo "Oh My Zsh: 已更新（commit: $(git -C "$ZSH_DIR" rev-parse --short HEAD)）"
            return 0
        fi

        log "Oh My Zsh 更新失败，保留当前可用版本" "warn"
        echo "Oh My Zsh: 保留版本（commit: $(git -C "$ZSH_DIR" rev-parse --short HEAD 2>/dev/null || echo 未知)）"
        return 0
    fi

    if [[ -e "$ZSH_DIR" ]]; then
        log "Oh My Zsh 目录存在但不是 Git 仓库，拒绝覆盖" "warn"
        return 1
    fi

    if ! installer=$(mktemp); then
        log "无法创建 Oh My Zsh 安装临时文件" "error"
        return 1
    fi

    debug_log "下载最新版 Oh My Zsh 安装脚本"

    if ! curl -fsSL \
        --connect-timeout 10 \
        --max-time 60 \
        "https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh" \
        -o "$installer"; then
        rm -f "$installer"
        log "Oh My Zsh 安装脚本下载失败" "error"
        return 1
    fi

    if [[ ! -s "$installer" ]]; then
        rm -f "$installer"
        log "Oh My Zsh 安装脚本为空" "error"
        return 1
    fi

    debug_log "安装最新版 Oh My Zsh"

    if ! RUNZSH=no CHSH=no ZSH="$ZSH_DIR" sh "$installer" --unattended \
        >/dev/null 2>&1; then
        rm -f "$installer"
        log "Oh My Zsh 安装失败" "error"
        return 1
    fi

    rm -f "$installer"
    return 0
}

clone_or_update_repository() {
    local repository="$1"
    local destination="$2"
    local description="$3"
    local commit

    if [[ -d "$destination/.git" ]]; then
        if git -C "$destination" pull --ff-only >/dev/null 2>&1; then
            commit=$(git -C "$destination" rev-parse --short HEAD)
            echo "$description: 已更新（commit: $commit）"
            return 0
        fi

        log "$description 更新失败，保留当前版本" "warn"
        return 1
    fi

    if [[ -e "$destination" ]]; then
        log "$description 目标路径已存在但不是 Git 仓库：$destination" "warn"
        return 1
    fi

    if git clone --depth=1 "$repository" "$destination" >/dev/null 2>&1; then
        commit=$(git -C "$destination" rev-parse --short HEAD)
        echo "$description: 已安装（commit: $commit）"
        return 0
    fi

    log "$description 安装失败" "warn"
    return 1
}

# === 核心功能函数 ===
install_components() {
    local installed=()
    local failed=()

    if ! command -v zsh >/dev/null 2>&1; then
        log "安装 Zsh 和 Git..." "info"

        if apt-get install -y zsh git >/dev/null 2>&1; then
            installed+=("Zsh")
        elif command -v zsh >/dev/null 2>&1 && command -v git >/dev/null 2>&1; then
            installed+=("Zsh" "Git")
            log "APT 返回错误，但 Zsh 与 Git 已安装；系统可能存在其他未配置完成的软件包" "warn"
        else
            failed+=("Zsh/Git")
        fi
    elif ! command -v git >/dev/null 2>&1; then
        log "安装 Git..." "info"

        if apt-get install -y git >/dev/null 2>&1; then
            installed+=("Git")
        elif command -v git >/dev/null 2>&1; then
            installed+=("Git")
            log "APT 返回错误，但 Git 已安装；系统可能存在其他未配置完成的软件包" "warn"
        else
            failed+=("Git")
        fi
    fi

    if ! command -v zsh >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
        log "缺少 Zsh 或 Git，无法继续安装组件" "error"
        return 1
    fi

    if install_oh_my_zsh; then
        [[ ! -d "$ZSH_DIR" ]] || installed+=("Oh My Zsh")
    else
        failed+=("Oh My Zsh")
    fi

    if mkdir -p "$THEME_DIR" "$PLUGINS_DIR" 2>/dev/null; then
        rmdir "$THEME_DIR" 2>/dev/null || true

        if clone_or_update_repository \
            "https://github.com/romkatv/powerlevel10k.git" \
            "$THEME_DIR" \
            "Powerlevel10k"; then
            [[ -d "$THEME_DIR/.git" ]] && installed+=("Powerlevel10k")
        else
            failed+=("Powerlevel10k")
        fi
    else
        failed+=("主题目录")
    fi

    local plugin_name
    local plugin_url
    local plugin_info
    local plugins=(
        "zsh-autosuggestions|https://github.com/zsh-users/zsh-autosuggestions.git"
        "zsh-syntax-highlighting|https://github.com/zsh-users/zsh-syntax-highlighting.git"
        "zsh-completions|https://github.com/zsh-users/zsh-completions.git"
    )

    for plugin_info in "${plugins[@]}"; do
        plugin_name="${plugin_info%%|*}"
        plugin_url="${plugin_info#*|}"

        if ! clone_or_update_repository \
            "$plugin_url" \
            "$PLUGINS_DIR/$plugin_name" \
            "$plugin_name"; then
            failed+=("$plugin_name")
        fi
    done

    if (( ${#installed[@]} > 0 )); then
        echo "安装组件: ${installed[*]}"
    else
        echo "组件状态: 已安装"
    fi

    if (( ${#failed[@]} > 0 )); then
        log "以下组件安装失败：${failed[*]}" "warn"
    fi

    [[ -d "$ZSH_DIR" ]] && [[ -d "$THEME_DIR" ]]
}

configure_zshrc() {
    debug_log "生成完整 .zshrc"

    cat > "$ZSHRC_FILE" <<'EOF'
# ============================================================
# 此文件由 zsh-setup.sh 自动生成。
# 手动修改会在下次运行脚本时被覆盖。
# 初始备份：~/.zshrc.initial-backup
# 上次备份：~/.zshrc.previous-backup
# ============================================================

# ============================================================
# 0. Powerlevel10k Instant Prompt
# 必须位于文件顶部，以减少终端启动时的视觉等待。
# ============================================================
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
    source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

# ============================================================
# 1. Oh My Zsh 基础配置
# ============================================================
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="powerlevel10k/powerlevel10k"

# 适用于 root 独占的个人 VPS。
# 缓存有效期内跳过补全目录权限扫描；每 24 小时执行一次完整检查。
export ZSH_DISABLE_COMPFIX="true"

# ============================================================
# 2. compinit 缓存
# ============================================================
function compinit() {
    unfunction compinit
    autoload -Uz compinit

    local dump="${ZDOTDIR:-$HOME}/.zcompdump"
    local -a expired_dump
    expired_dump=($dump(Nmh+24))

    if [[ ! -f "$dump" ]] || (( ${#expired_dump} )); then
        compinit "$@"
    else
        compinit -C "$@"
    fi
}

# ============================================================
# 3. Oh My Zsh 更新策略
# ============================================================
DISABLE_UPDATE_PROMPT=true
zstyle ':omz:update' mode auto
zstyle ':omz:update' frequency 7

# ============================================================
# 4. 插件
# docker 插件已提供 drs、dps、dpsa、dxc 等常用别名。
# zsh-syntax-highlighting 必须处于最后。
# ============================================================
plugins=(
    git
    sudo
    docker
    kubectl
    web-search
    history
    colored-man-pages
    zsh-completions
    zsh-autosuggestions
    zsh-syntax-highlighting
)

source "$ZSH/oh-my-zsh.sh"

# ============================================================
# 5. kubectl 延迟加载
# 首次执行 kubectl 时才加载补全，减少 Zsh 启动开销。
# ============================================================
function kubectl() {
    unfunction kubectl

    if ! command -v kubectl >/dev/null 2>&1; then
        print -u2 "kubectl 未安装"
        return 127
    fi

    source <(command kubectl completion zsh)
    command kubectl "$@"
}

# ============================================================
# 6. PATH
# 系统路径优先，并使用 Zsh 的唯一数组属性自动去除重复目录。
# ============================================================
typeset -U path PATH
path=(
    /usr/local/sbin
    /usr/local/bin
    /usr/sbin
    /usr/bin
    /sbin
    /bin
    "$HOME/.local/bin"
    $path
)
export PATH

# ============================================================
# 7. Mise Shell 集成
# activation 文件由 mise-setup.sh 维护。
# ============================================================
[[ -r "$HOME/.config/mise/activate.zsh" ]] &&
    source "$HOME/.config/mise/activate.zsh"

# ============================================================
# 8. Powerlevel10k 配置
# ============================================================
[[ -r "$HOME/.p10k.zsh" ]] && source "$HOME/.p10k.zsh"

# ============================================================
# 9. APT 别名
# ============================================================
alias aptu='apt update'
alias aptuf='apt update && apt full-upgrade -y'
alias autodel='docker system prune -a -f && apt autoremove -y && apt clean'

# ============================================================
# 10. Docker 别名
# ============================================================

# 普通容器日志。
alias dlog='docker logs -f'

# Compose 项目操作。
alias dc='docker compose'
alias dcd='docker compose down'
alias dcu='docker compose up -d'
alias dcr='docker compose restart'
alias dcpu='docker compose pull && docker compose up -d'
alias dcre='docker compose pull && docker compose up -d --force-recreate'
alias dcreup='docker compose down && docker compose pull && docker compose up -d --remove-orphans'

# docker 插件已经提供普通容器重启命令：
# drs <容器名>  -> docker container restart <容器名>

# ============================================================
# 11. Proxy Compose 项目
# 在子 Shell 中切换目录，执行后不会改变当前工作目录。
# ============================================================
dcreproxy() {
    (
        cd /root/proxy || return 1

        docker compose down &&
            docker compose pull &&
            docker compose up -d --remove-orphans
    )
}

# ============================================================
# 12. systemd 与日志
# ============================================================
alias sc='systemctl'
alias jc='journalctl'
EOF

    sed -i 's/\r$//' "$ZSHRC_FILE"
    chmod 644 "$ZSHRC_FILE"
    debug_log ".zshrc 已更新"
}

setup_theme() {
    debug_log "开始主题选择"

    echo "主题选择:" >&2
    echo "  1) LucaLin（推荐）" >&2
    echo "  2) Rainbow（彩虹风格）" >&2
    echo "  3) Lean（简洁风格）" >&2
    echo "  4) Classic（经典风格）" >&2
    echo "  5) Pure（极简风格，默认）" >&2
    echo "  6) 配置向导" >&2
    echo >&2

    local choice
    local config_url=""
    local repository_ref="${RUN_COMMIT:-main}"

    read -r -t 30 -p "请选择 [1-6]（默认 5）: " choice >&2 || choice="5"
    choice="${choice:-5}"

    case "$choice" in
        1)
            echo "主题: LucaLin"
            config_url="https://raw.githubusercontent.com/LucaLin233/Linux/${repository_ref}/p10k-config.zsh"
            ;;
        2)
            echo "主题: Rainbow"
            config_url="https://raw.githubusercontent.com/romkatv/powerlevel10k/master/config/p10k-rainbow.zsh"
            ;;
        3)
            echo "主题: Lean"
            config_url="https://raw.githubusercontent.com/romkatv/powerlevel10k/master/config/p10k-lean.zsh"
            ;;
        4)
            echo "主题: Classic"
            config_url="https://raw.githubusercontent.com/romkatv/powerlevel10k/master/config/p10k-classic.zsh"
            ;;
        5)
            echo "主题: Pure"
            config_url="https://raw.githubusercontent.com/romkatv/powerlevel10k/master/config/p10k-pure.zsh"
            ;;
        6)
            echo "主题: 配置向导（首次进入 Zsh 时启动）"
            rm -f "$P10K_FILE"
            return 0
            ;;
        *)
            log "无效选择，使用 Pure 主题" "warn"
            config_url="https://raw.githubusercontent.com/romkatv/powerlevel10k/master/config/p10k-pure.zsh"
            ;;
    esac

    if curl -fsSL \
        --connect-timeout 10 \
        --max-time 30 \
        "$config_url" \
        -o "$P10K_FILE"; then
        chmod 644 "$P10K_FILE" 2>/dev/null || true
        return 0
    fi

    log "主题配置下载失败，首次进入 Zsh 时可运行 p10k configure 配置" "warn"
    return 1
}

setup_default_shell() {
    local zsh_path
    local current_shell

    if ! zsh_path=$(command -v zsh); then
        log "找不到 zsh 可执行文件" "error"
        return 1
    fi

    current_shell=$(getent passwd root 2>/dev/null | cut -d: -f7)

    if [[ "$current_shell" == "$zsh_path" ]]; then
        echo "默认 Shell: 已是 Zsh"
        return 0
    fi

    if chsh -s "$zsh_path" root; then
        echo "默认 Shell: 已设置为 Zsh（重新登录后生效）"
        return 0
    fi

    log "设置 root 默认 Shell 失败" "error"
    return 1
}

# === 主流程 ===
main() {
    if ! validate_run_commit; then
        log "RUN_COMMIT 必须为空或 40 位小写 Git Commit" "error"
        exit 1
    fi

    if (( EUID != 0 )); then
        log "需要 root 权限运行" "error"
        exit 1
    fi

    log "🐚 配置 Zsh 环境..." "info"

    # 先备份，确保 Oh My Zsh 安装器或后续完整生成配置前，
    # 已保存本次执行前的 .zshrc。
    backup_zshrc || exit 1
    backup_zsh_auxiliary_state || exit 1

    echo
    if ! install_components; then
        log "核心组件安装失败，停止配置" "error"
        exit 1
    fi

    echo
    configure_zshrc
    echo "配置文件: $ZSHRC_FILE 已更新"
    echo "初始备份: $ZSHRC_INITIAL_BACKUP"
    echo "上次备份: $ZSHRC_PREVIOUS_BACKUP"

    echo
    setup_theme || true

    echo
    setup_default_shell || true

    echo
    log "✅ Zsh 配置完成，重新登录或执行 'exec zsh' 后生效" "info"
}

trap 'log "Zsh 配置脚本在第 $LINENO 行执行失败" "error"' ERR

main "$@"
