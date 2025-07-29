#!/bin/bash
# Zsh Shell 环境配置模块 v4.1
# 统一代码风格，优化备份策略，增加主题选择功能

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

# 智能备份zshrc
backup_zshrc() {
    if [[ -f "$HOME/.zshrc" ]]; then
        # 首次备份：保存原始配置
        if [[ ! -f "$HOME/.zshrc.original" ]]; then
            cp "$HOME/.zshrc" "$HOME/.zshrc.original"
            log "已备份原始配置: .zshrc.original" "info"
        fi
        
        # 最近备份：总是覆盖
        cp "$HOME/.zshrc" "$HOME/.zshrc.backup"
        log "已备份当前配置: .zshrc.backup" "info"
    fi
}

# 安装zsh
install_zsh() {
    log "检查并安装 Zsh..." "info"
    
    if ! command -v zsh &>/dev/null; then
        apt install -y zsh git
    fi
    
    if ! command -v zsh &>/dev/null; then
        log "✗ Zsh 安装失败" "error"
        exit 1
    fi
    
    local zsh_version=$(zsh --version | awk '{print $2}')
    log "✓ Zsh 已安装 (版本: $zsh_version)" "info"
}

# 安装Oh My Zsh
install_oh_my_zsh() {
    log "安装 Oh My Zsh..." "info"
    
    if [[ ! -d "$ZSH_DIR" ]]; then
        RUNZSH=no sh -c "$(curl -fsSL https://raw.github.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
        log "✓ Oh My Zsh 安装完成" "info"
    else
        log "Oh My Zsh 已存在" "info"
    fi
}

# 安装Powerlevel10k主题
install_powerlevel10k() {
    log "安装 Powerlevel10k 主题..." "info"
    
    if [[ ! -d "$THEME_DIR" ]]; then
        git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$THEME_DIR"
        log "✓ Powerlevel10k 主题安装完成" "info"
    else
        log "Powerlevel10k 主题已存在" "info"
    fi
}

# 安装zsh插件
install_zsh_plugins() {
    log "安装 Zsh 插件..." "info"
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
            if git clone "$plugin_url" "$PLUGINS_DIR/$plugin_name"; then
                log "✓ 插件 $plugin_name 安装完成" "info"
            else
                log "✗ 插件 $plugin_name 安装失败" "warn"
            fi
        fi
    done
}

# 显示主题配置选项
show_theme_options() {
    echo
    log "选择 Powerlevel10k 配置方式:" "info"
    echo
    echo "  1) 使用配置向导 (推荐) - 交互式配置，功能最全"
    echo "  2) 使用 Rainbow 预设 - 彩虹主题，丰富多彩"
    echo "  3) 使用 Lean 预设 - 精简主题，简洁清爽"
    echo "  4) 使用 Classic 预设 - 经典主题，传统外观"
    echo "  5) 使用 Pure 预设 - 纯净主题，极简风格"
    echo
}

# 选择主题配置方式
select_theme_option() {
    local choice=""
    
    show_theme_options
    
    while true; do
        read -p "请选择配置方式 [1-5] (默认: 1): " -r choice
        
        # 如果用户直接回车，使用默认选择
        if [[ -z "$choice" ]]; then
            choice="1"
        fi
        
        case "$choice" in
            1)
                log "已选择: 配置向导模式" "info"
                echo "wizard"
                break
                ;;
            2)
                log "已选择: Rainbow 预设主题" "info"
                echo "rainbow"
                break
                ;;
            3)
                log "已选择: Lean 预设主题" "info"
                echo "lean"
                break
                ;;
            4)
                log "已选择: Classic 预设主题" "info"
                echo "classic"
                break
                ;;
            5)
                log "已选择: Pure 预设主题" "info"
                echo "pure"
                break
                ;;
            *)
                log "无效选择，请输入 1-5 之间的数字" "warn"
                ;;
        esac
    done
}

# 配置zshrc文件
configure_zshrc() {
    log "配置 .zshrc 文件..." "info"
    
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
alias copyall='cd /root/copy && ansible-playbook -i inventory.ini copyhk.yml && ansible-playbook -i inventory.ini copysg.yml && ansible-playbook -i inventory.ini copyother.yml'
EOF
    
    log "✓ .zshrc 配置完成" "info"
}

# 配置Powerlevel10k主题
configure_powerlevel10k() {
    local config_mode="$1"
    
    if [[ "$config_mode" == "wizard" ]]; then
        log "配置 Powerlevel10k 配置向导模式..." "info"
        log "首次启动 zsh 时会自动运行配置向导" "info"
        
        # 创建提示文件
        cat > "$HOME/.p10k.zsh" << 'EOF'
# Powerlevel10k 配置文件
# 首次启动 zsh 时会自动运行配置向导
# 如需重新配置，请运行: p10k configure

# 启用即时提示模式
typeset -g POWERLEVEL9K_INSTANT_PROMPT=verbose
EOF
        log "✓ 配置向导模式设置完成" "info"
    else
        log "配置 Powerlevel10k $config_mode 预设主题..." "info"
        
        local preset_file="$THEME_DIR/config/p10k-$config_mode.zsh"
        
        if [[ -f "$preset_file" ]]; then
            cp "$preset_file" "$HOME/.p10k.zsh"
            log "✓ $config_mode 预设主题配置完成" "info"
        else
            log "$config_mode 预设配置文件不存在: $preset_file" "warn"
            log "将回退到配置向导模式" "info"
            
            # 回退到配置向导模式
            cat > "$HOME/.p10k.zsh" << 'EOF'
# Powerlevel10k 配置文件
# 预设配置文件不存在，首次启动时会运行配置向导
# 如需重新配置，请运行: p10k configure

# 启用即时提示模式  
typeset -g POWERLEVEL9K_INSTANT_PROMPT=verbose
EOF
        fi
    fi
}

# 设置默认Shell
setup_default_shell() {
    local current_shell=$(getent passwd root | cut -d: -f7)
    local zsh_path=$(which zsh)
    
    if [[ "$current_shell" != "$zsh_path" ]]; then
        echo
        read -p "是否将 Zsh 设置为默认 Shell? [y/N]: " -r set_default
        if [[ "$set_default" =~ ^[Yy]$ ]]; then
            chsh -s "$zsh_path" root
            log "✓ Zsh 已设置为默认 Shell (重新登录后生效)" "info"
        fi
    else
        log "Zsh 已是默认 Shell" "info"
    fi
}

# === 主流程 ===
main() {
    log "🐚 配置 Zsh Shell 环境..." "info"
    
    install_zsh
    install_oh_my_zsh
    install_powerlevel10k
    install_zsh_plugins
    configure_zshrc
    
    # 主题配置选择
    local theme_option=$(select_theme_option)
    configure_powerlevel10k "$theme_option"
    
    setup_default_shell
    
    echo
    log "🎉 Zsh 环境配置完成!" "info"
    log "💡 提示: 运行 'exec zsh' 立即体验新环境" "info"
    
    if [[ "$theme_option" == "wizard" ]]; then
        log "🎨 主题: 首次启动会自动运行配置向导" "info"
    fi
    log "🔧 配置: 如需重新配置主题，请运行 'p10k configure'" "info"
}

main "$@"
