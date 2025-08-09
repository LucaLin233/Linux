#!/bin/bash
# Zsh Shell 环境配置模块 v5.0 - 智能配置版
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
    local -A colors=([info]="\033[0;36m" [warn]="\033[0;33m" [error]="\033[0;31m" [debug]="\033[0;35m")
    echo -e "${colors[$level]:-\033[0;32m}$msg\033[0m"
}

debug_log() {
    [[ "${DEBUG:-}" == "1" ]] && log "DEBUG: $1" "debug" >&2
}

# === 辅助函数 ===
# 检查网络连接
check_network() {
    debug_log "检查网络连接"
    if ! curl -s --connect-timeout 5 https://github.com >/dev/null 2>&1; then
        debug_log "网络连接检查失败"
        return 1
    fi
    debug_log "网络连接正常"
    return 0
}

# 备份zshrc
backup_zshrc() {
    debug_log "开始备份.zshrc文件"
    if [[ -f "$HOME/.zshrc" ]]; then
        if [[ ! -f "$HOME/.zshrc.backup" ]]; then
            if cp "$HOME/.zshrc" "$HOME/.zshrc.backup" 2>/dev/null; then
                debug_log "已备份现有.zshrc文件"
                return 0
            else
                log "备份.zshrc文件失败" "error"
                return 1
            fi
        else
            debug_log ".zshrc备份文件已存在，跳过备份"
        fi
    else
        debug_log "未找到现有.zshrc文件，无需备份"
    fi
    return 0
}

# 检查组件安装状态
check_component_status() {
    local component="$1"
    case "$component" in
        "zsh")
            command -v zsh &>/dev/null && return 0 || return 1
            ;;
        "oh-my-zsh")
            [[ -d "$ZSH_DIR" ]] && return 0 || return 1
            ;;
        "powerlevel10k")
            [[ -d "$THEME_DIR" ]] && return 0 || return 1
            ;;
        *)
            return 1
            ;;
    esac
}

# 检查插件是否已安装
check_plugin_installed() {
    local plugin_name="$1"
    [[ -d "$PLUGINS_DIR/$plugin_name" ]] && return 0 || return 1
}

# 下载主题配置文件
download_theme_config() {
    local theme_name="$1"
    local theme_url="$2"
    
    debug_log "下载主题配置: $theme_name"
    if curl -fsSL --connect-timeout 10 "$theme_url" -o "$HOME/.p10k.zsh" 2>/dev/null; then
        debug_log "主题配置下载成功: $theme_name"
        return 0
    else
        debug_log "主题配置下载失败: $theme_name"
        return 1
    fi
}
# === 辅助函数结束 ===

# === 核心功能函数 ===
# 安装Zsh基础包
install_zsh() {
    debug_log "开始安装Zsh"
    if check_component_status "zsh"; then
        debug_log "Zsh已安装，跳过"
        return 0
    fi
    
    if apt update -qq && apt install -y zsh git curl >/dev/null 2>&1; then
        debug_log "Zsh安装成功"
        return 0
    else
        log "Zsh安装失败" "error"
        return 1
    fi
}

# 安装Oh My Zsh
install_oh_my_zsh() {
    debug_log "开始安装Oh My Zsh"
    if check_component_status "oh-my-zsh"; then
        debug_log "Oh My Zsh已安装，跳过"
        return 0
    fi
    
    if ! check_network; then
        log "网络连接失败，无法安装Oh My Zsh" "error"
        return 1
    fi
    
    # 设置环境变量，避免自动切换shell和启动zsh
    export RUNZSH=no
    export KEEP_ZSHRC=yes
    
    if sh -c "$(curl -fsSL https://raw.github.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" >/dev/null 2>&1; then
        debug_log "Oh My Zsh安装成功"
        return 0
    else
        log "Oh My Zsh安装失败" "error"
        return 1
    fi
}

# 安装Powerlevel10k主题
install_powerlevel10k() {
    debug_log "开始安装Powerlevel10k主题"
    if check_component_status "powerlevel10k"; then
        debug_log "Powerlevel10k已安装，跳过"
        return 0
    fi
    
    if ! check_network; then
        log "网络连接失败，无法安装Powerlevel10k" "error"
        return 1
    fi
    
    # 确保目录存在
    mkdir -p "$(dirname "$THEME_DIR")" || {
        log "创建主题目录失败" "error"
        return 1
    }
    
    if git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$THEME_DIR" >/dev/null 2>&1; then
        debug_log "Powerlevel10k安装成功"
        return 0
    else
        log "Powerlevel10k安装失败" "error"
        return 1
    fi
}

# 安装Zsh插件
install_zsh_plugins() {
    debug_log "开始安装Zsh插件"
    
    if ! check_network; then
        log "网络连接失败，跳过插件安装" "warn"
        return 1
    fi
    
    # 确保插件目录存在
    mkdir -p "$PLUGINS_DIR" || {
        log "创建插件目录失败" "error"
        return 1
    }
    
    local plugins=(
        "zsh-autosuggestions|https://github.com/zsh-users/zsh-autosuggestions"
        "zsh-syntax-highlighting|https://github.com/zsh-users/zsh-syntax-highlighting.git"
        "zsh-completions|https://github.com/zsh-users/zsh-completions"
    )
    
    local installed_count=0
    local failed_plugins=()
    
    for plugin_info in "${plugins[@]}"; do
        local plugin_name="${plugin_info%%|*}"
        local plugin_url="${plugin_info##*|}"
        
        debug_log "检查插件: $plugin_name"
        
        if check_plugin_installed "$plugin_name"; then
            debug_log "插件已安装，跳过: $plugin_name"
            continue
        fi
        
        if git clone "$plugin_url" "$PLUGINS_DIR/$plugin_name" >/dev/null 2>&1; then
            debug_log "插件安装成功: $plugin_name"
            ((installed_count++))
        else
            debug_log "插件安装失败: $plugin_name"
            failed_plugins+=("$plugin_name")
        fi
    done
    
    # 输出安装结果
    if (( installed_count > 0 )); then
        echo "插件安装: ${installed_count}个新插件"
    fi
    
    if (( ${#failed_plugins[@]} > 0 )); then
        log "插件安装失败: ${failed_plugins[*]}" "warn"
        return 1
    fi
    
    return 0
}

# 安装所有组件
install_components() {
    local components=()
    local errors=()
    
    # 安装Zsh
    if install_zsh; then
        if ! check_component_status "zsh"; then
            components+=("Zsh")
        fi
    else
        errors+=("Zsh安装失败")
    fi
    
    # 安装Oh My Zsh
    if install_oh_my_zsh; then
        if ! check_component_status "oh-my-zsh"; then
            components+=("Oh-My-Zsh")
        fi
    else
        errors+=("Oh-My-Zsh安装失败")
    fi
    
    # 安装Powerlevel10k
    if install_powerlevel10k; then
        if ! check_component_status "powerlevel10k"; then
            components+=("Powerlevel10k")
        fi
    else
        errors+=("Powerlevel10k安装失败")
    fi
    
    # 安装插件
    if install_zsh_plugins; then
        # 插件安装函数内部已处理输出
        true
    else
        errors+=("部分插件安装失败")
    fi
    
    # 输出安装结果
    if (( ${#components[@]} > 0 )); then
        echo "新安装组件: ${components[*]}"
    else
        echo "组件检查: 已是最新状态"
    fi
    
    # 输出错误信息
    if (( ${#errors[@]} > 0 )); then
        for error in "${errors[@]}"; do
            log "⚠️  $error" "warn"
        done
        return 1
    fi
    
    return 0
}

# 生成zshrc配置文件
generate_zshrc_config() {
    debug_log "生成.zshrc配置文件"
    
    local temp_config
    temp_config=$(mktemp) || {
        log "无法创建临时配置文件" "error"
        return 1
    }
    
    cat > "$temp_config" << 'EOF'
# Oh My Zsh 配置
# Generated by zsh-setup module
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="powerlevel10k/powerlevel10k"

# 更新设置
DISABLE_UPDATE_PROMPT="true"
UPDATE_ZSH_DAYS=7

# 插件配置
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

# 加载Oh My Zsh
source $ZSH/oh-my-zsh.sh

# 自动补全初始化
autoload -U compinit && compinit

# PATH配置
export PATH="$HOME/.local/bin:$PATH"

# mise 版本管理器配置
command -v mise >/dev/null 2>&1 && eval "$(mise activate zsh)"

# Powerlevel10k 配置
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh

# 实用别名
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'
alias upgrade='apt update && apt full-upgrade -y'
alias update='apt update -y'
alias reproxy='cd /root/proxy && docker compose down && docker compose pull && docker compose up -d --remove-orphans'
alias autodel='docker system prune -a -f && apt autoremove -y'

# 历史记录配置
HISTSIZE=10000
SAVEHIST=10000
setopt HIST_EXPIRE_DUPS_FIRST
setopt HIST_IGNORE_DUPS
setopt HIST_IGNORE_ALL_DUPS
setopt HIST_SAVE_NO_DUPS
setopt HIST_FIND_NO_DUPS
EOF
    
    echo "$temp_config"
    return 0
}

# 配置zshrc文件
configure_zshrc() {
    debug_log "开始配置.zshrc文件"
    
    # 备份现有配置
    if ! backup_zshrc; then
        return 1
    fi
    
    # 生成新配置
    local temp_config
    if ! temp_config=$(generate_zshrc_config); then
        return 1
    fi
    
    # 应用配置
    if mv "$temp_config" "$HOME/.zshrc"; then
        debug_log ".zshrc配置文件更新成功"
        echo "配置文件: .zshrc 已更新"
        return 0
    else
        log ".zshrc配置文件更新失败" "error"
        rm -f "$temp_config"
        return 1
    fi
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
    read -p "请选择 [1-6] (默认1): " choice >&2
    choice=${choice:-1}
    
    local theme_name theme_url
    case "$choice" in
        1)
            theme_name="LucaLin (推荐配置)"
            theme_url="https://raw.githubusercontent.com/LucaLin233/Linux/refs/heads/main/p10k-config.zsh"
            ;;
        2)
            theme_name="Rainbow (彩虹风格)"
            theme_url="https://raw.githubusercontent.com/romkatv/powerlevel10k/master/config/p10k-rainbow.zsh"
            ;;
        3)
            theme_name="Lean (简洁风格)"
            theme_url="https://raw.githubusercontent.com/romkatv/powerlevel10k/master/config/p10k-lean.zsh"
            ;;
        4)
            theme_name="Classic (经典风格)"
            theme_url="https://raw.githubusercontent.com/romkatv/powerlevel10k/master/config/p10k-classic.zsh"
            ;;
        5)
            theme_name="Pure (极简风格)"
            theme_url="https://raw.githubusercontent.com/romkatv/powerlevel10k/master/config/p10k-pure.zsh"
            ;;
        6)
            echo "主题: 配置向导 (首次启动时配置)"
            debug_log "用户选择配置向导"
            return 0
            ;;
        *)
            theme_name="LucaLin (默认选择)"
            theme_url="https://raw.githubusercontent.com/LucaLin233/Linux/refs/heads/main/p10k-config.zsh"
            ;;
    esac
    
    debug_log "用户选择主题: $theme_name"
    
    if ! check_network; then
        echo "主题: 配置向导 (网络连接失败，首次启动时配置)" >&2
        return 0
    fi
    
    if download_theme_config "$theme_name" "$theme_url"; then
        echo "主题: $theme_name"
        return 0
    else
        echo "主题: 配置向导 (下载失败，首次启动时配置)" >&2
        log "主题配置下载失败，将使用配置向导" "warn"
        return 0
    fi
}

# 设置默认Shell
setup_default_shell() {
    debug_log "开始设置默认Shell"
    
    local current_user=$(whoami)
    local current_shell=$(getent passwd "$current_user" | cut -d: -f7)
    local zsh_path
    
    if ! zsh_path=$(which zsh 2>/dev/null); then
        log "未找到zsh可执行文件" "error"
        return 1
    fi
    
    debug_log "当前用户: $current_user, 当前Shell: $current_shell, Zsh路径: $zsh_path"
    
    if [[ "$current_shell" != "$zsh_path" ]]; then
        if chsh -s "$zsh_path" "$current_user" 2>/dev/null; then
            debug_log "默认Shell设置成功"
            echo "默认Shell: Zsh (重新登录生效)"
            return 0
        else
            log "设置默认Shell失败" "error"
            return 1
        fi
    else
        debug_log "默认Shell已是Zsh"
        echo "默认Shell: 已是Zsh"
        return 0
    fi
}

# 显示配置摘要
show_zsh_summary() {
    echo
    log "🎯 Zsh配置摘要:" "info"
    
    if check_component_status "zsh"; then
        echo "  Zsh: 已安装 ($(zsh --version | cut -d' ' -f2))"
    else
        echo "  Zsh: 未安装"
    fi
    
    if check_component_status "oh-my-zsh"; then
        echo "  Oh My Zsh: 已安装"
    else
        echo "  Oh My Zsh: 未安装"
    fi
    
    if check_component_status "powerlevel10k"; then
        echo "  Powerlevel10k: 已安装"
    else
        echo "  Powerlevel10k: 未安装"
    fi
    
    local installed_plugins=0
    local plugins=("zsh-autosuggestions" "zsh-syntax-highlighting" "zsh-completions")
    for plugin in "${plugins[@]}"; do
        if check_plugin_installed "$plugin"; then
            ((installed_plugins++))
        fi
    done
    echo "  插件: ${installed_plugins}/${#plugins[@]} 已安装"
    
    local current_user=$(whoami)
    local current_shell=$(getent passwd "$current_user" | cut -d: -f7)
    if [[ "$current_shell" == *"zsh"* ]]; then
        echo "  默认Shell: Zsh"
    else
        echo "  默认Shell: $current_shell (需要重新登录)"
    fi
}
# === 核心功能函数结束 ===

# === 主流程 ===
main() {
    # 基础检查
    if ! command -v curl &>/dev/null; then
        log "缺少curl命令，请先安装" "error"
        exit 1
    fi
    
    if ! command -v git &>/dev/null; then
        log "缺少git命令，正在安装..." "info"
        apt update -qq && apt install -y git >/dev/null 2>&1 || {
            log "git安装失败" "error"
            exit 1
        }
    fi
    
    log "🐚 配置Zsh环境..." "info"
    
    echo
    if ! install_components; then
        log "部分组件安装失败，继续配置" "warn"
    fi
    
    echo
    if ! configure_zshrc; then
        log "zshrc配置失败" "error"
        exit 1
    fi
    
    echo
    if ! setup_theme; then
        log "主题设置失败，将使用默认配置" "warn"
    fi
    
    echo
    if ! setup_default_shell; then
        log "默认Shell设置失败" "warn"
    fi
    
    show_zsh_summary
    
    echo
    log "✅ Zsh配置完成，运行 'exec zsh' 体验" "info"
}

# 错误处理
trap 'log "脚本执行出错，行号: $LINENO" "error"; exit 1' ERR

main "$@"
