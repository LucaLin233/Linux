#!/bin/bash
# Zsh Shell 环境配置模块 v4.1 - 简化版
# 功能: 安装配置Zsh + Oh My Zsh + Powerlevel10k + 常用插件

set -euo pipefail

# === 常量定义 ===
readonly ZSH_DIR="$HOME/.oh-my-zsh"
readonly CUSTOM_DIR="${ZSH_CUSTOM:-$ZSH_DIR/custom}"
readonly THEME_DIR="$CUSTOM_DIR/themes/powerlevel10k"
readonly PLUGINS_DIR="$CUSTOM_DIR/plugins"

# === 日志函数 ===
log() {
    local msg="$1" level="${2:-info}"
    local -A colors=([info]="\033[0;36m" [warn]="\033[0;33m" [error]="\033[0;31m")
    echo -e "${colors[$level]:-\033[0;32m}$msg\033[0m"
}

# === 核心函数 ===

# 备份zshrc
backup_zshrc() {
    if [[ -f "$HOME/.zshrc" ]] && [[ ! -f "$HOME/.zshrc.backup" ]]; then
        cp "$HOME/.zshrc" "$HOME/.zshrc.backup"
    fi
}

# 安装基础组件
install_components() {
    local components=()
    local errors=()
    
    # 检查并安装zsh
    if ! command -v zsh &>/dev/null; then
        if apt install -y zsh git >/dev/null 2>&1; then
            components+=("Zsh")
        else
            errors+=("Zsh安装失败")
        fi
    fi
    
    # 安装Oh My Zsh
    if [[ ! -d "$ZSH_DIR" ]]; then
        if RUNZSH=no sh -c "$(curl -fsSL https://raw.github.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" >/dev/null 2>&1; then
            components+=("Oh-My-Zsh")
        else
            errors+=("Oh-My-Zsh安装失败")
        fi
    fi
    
    # 安装Powerlevel10k主题
    if [[ ! -d "$THEME_DIR" ]]; then
        if git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$THEME_DIR" >/dev/null 2>&1; then
            components+=("Powerlevel10k")
        else
            errors+=("Powerlevel10k主题安装失败")
        fi
    fi
    
    # 安装插件
    local new_plugins=0
    local failed_plugins=()
    mkdir -p "$PLUGINS_DIR"
    
    local plugins=(
        "zsh-autosuggestions|https://github.com/zsh-users/zsh-autosuggestions"
        "zsh-syntax-highlighting|https://github.com/zsh-users/zsh-syntax-highlighting.git"
        "zsh-completions|https://github.com/zsh-users/zsh-completions"
    )
    
    for plugin_info in "${plugins[@]}"; do
        local plugin_name="${plugin_info%%|*}"
        local plugin_url="${plugin_info##*|}"
        
        if [[ ! -d "$PLUGINS_DIR/$plugin_name" ]]; then
            if git clone "$plugin_url" "$PLUGINS_DIR/$plugin_name" >/dev/null 2>&1; then
                ((new_plugins++))
            else
                failed_plugins+=("$plugin_name")
            fi
        fi
    done
    
    [[ $new_plugins -gt 0 ]] && components+=("${new_plugins}个插件")
    [[ ${#failed_plugins[@]} -gt 0 ]] && errors+=("插件失败: ${failed_plugins[*]}")
    
    # 输出结果
    if (( ${#components[@]} > 0 )); then
        echo "安装组件: ${components[*]}"
    else
        echo "组件检查: 已是最新状态"
    fi
    
    # 输出错误
    if (( ${#errors[@]} > 0 )); then
        for error in "${errors[@]}"; do
            log "⚠️  $error" "warn"
        done
    fi
}

# 配置zshrc文件
configure_zshrc() {
    backup_zshrc
    
    cat > "$HOME/.zshrc" << 'EOF'
# Oh My Zsh 配置
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="powerlevel10k/powerlevel10k"

# 禁用自动更新提示
DISABLE_UPDATE_PROMPT="true"
UPDATE_ZSH_DAYS=7

plugins=(
    git
    zsh-autosuggestions
    zsh-syntax-highlighting
    zsh-completions
    sudo
    docker
    kubectl
    web-search
    history
    colored-man-pages
    command-not-found
)

source $ZSH/oh-my-zsh.sh
autoload -U compinit && compinit
export PATH="$HOME/.local/bin:$PATH"

# mise 版本管理器配置
command -v mise >/dev/null 2>&1 && eval "$(mise activate zsh)"

# Powerlevel10k 配置
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh

# 实用别名
alias upgrade='apt update && apt full-upgrade -y'
alias update='apt update -y'
alias reproxy='cd /root/proxy && docker compose down && docker compose pull && docker compose up -d --remove-orphans'
alias autodel='docker system prune -a -f && apt autoremove -y'
EOF
}

# 选择并配置主题
setup_theme() {
    echo "主题选择:" >&2
    echo "  1) LucaLin (推荐) - 精心调配的个人主题" >&2
    echo "  2) Rainbow - 彩虹主题，丰富多彩" >&2
    echo "  3) Lean - 精简主题，简洁清爽" >&2
    echo "  4) Classic - 经典主题，传统外观" >&2
    echo "  5) Pure - 纯净主题，极简风格" >&2
    echo "  6) 配置向导 - 交互式配置，功能最全" >&2
    echo >&2
    
    local choice
    read -p "请选择 [1-6] (默认1): " choice </dev/tty >&2
    choice=${choice:-1}
    
    case "$choice" in
        1)
            echo "主题: LucaLin (推荐配置)"
            if curl -fsSL "https://raw.githubusercontent.com/LucaLin233/Linux/refs/heads/main/p10k-config.zsh" -o "$HOME/.p10k.zsh" 2>/dev/null; then
                return 0
            else
                echo "主题: 配置向导 (下载失败，首次启动时配置)"
            fi
            ;;
        2)
            echo "主题: Rainbow (彩虹风格)"
            if curl -fsSL "https://raw.githubusercontent.com/romkatv/powerlevel10k/master/config/p10k-rainbow.zsh" -o "$HOME/.p10k.zsh" 2>/dev/null; then
                return 0
            else
                echo "主题: 配置向导 (下载失败，首次启动时配置)"
            fi
            ;;
        3)
            echo "主题: Lean (简洁风格)"
            if curl -fsSL "https://raw.githubusercontent.com/romkatv/powerlevel10k/master/config/p10k-lean.zsh" -o "$HOME/.p10k.zsh" 2>/dev/null; then
                return 0
            else
                echo "主题: 配置向导 (下载失败，首次启动时配置)"
            fi
            ;;
        4)
            echo "主题: Classic (经典风格)"
            if curl -fsSL "https://raw.githubusercontent.com/romkatv/powerlevel10k/master/config/p10k-classic.zsh" -o "$HOME/.p10k.zsh" 2>/dev/null; then
                return 0
            else
                echo "主题: 配置向导 (下载失败，首次启动时配置)"
            fi
            ;;
        5)
            echo "主题: Pure (极简风格)"
            if curl -fsSL "https://raw.githubusercontent.com/romkatv/powerlevel10k/master/config/p10k-pure.zsh" -o "$HOME/.p10k.zsh" 2>/dev/null; then
                return 0
            else
                echo "主题: 配置向导 (下载失败，首次启动时配置)"
            fi
            ;;
        6)
            echo "主题: 配置向导 (首次启动时配置)"
            ;;
        *)
            echo "主题: LucaLin (默认选择)"
            curl -fsSL "https://raw.githubusercontent.com/LucaLin233/Linux/refs/heads/main/p10k-config.zsh" -o "$HOME/.p10k.zsh" 2>/dev/null || true
            ;;
    esac
}

# 设置默认Shell
setup_default_shell() {
    local current_shell=$(getent passwd root | cut -d: -f7)
    local zsh_path=$(which zsh)
    
    if [[ "$current_shell" != "$zsh_path" ]]; then
        chsh -s "$zsh_path" root 2>/dev/null
        echo "默认Shell: Zsh (重新登录生效)"
    else
        echo "默认Shell: 已是Zsh"
    fi
}

# === 主流程 ===
main() {
    log "🐚 配置Zsh环境..." "info"
    
    echo
    install_components
    
    echo
    configure_zshrc
    echo "配置文件: .zshrc 已更新"
    
    echo
    setup_theme
    
    echo
    setup_default_shell
    
    echo
    log "✅ Zsh配置完成，运行 'exec zsh' 体验" "info"
}

main "$@"
