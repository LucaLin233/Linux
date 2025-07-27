#!/bin/bash
# Zsh Shell 环境配置模块 (优化版 v2.0)
# 优化: 模块化设计、用户选择、完善错误处理、配置模板

set -euo pipefail

# === 常量定义 ===
readonly ZSH_INSTALL_DIR="$HOME/.oh-my-zsh"
readonly ZSH_CUSTOM_DIR="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"
readonly ZSHRC_FILE="$HOME/.zshrc"
readonly P10K_CONFIG="$HOME/.p10k.zsh"
readonly TEMP_DIR="/tmp/zsh-setup"

# GitHub URLs
readonly OMZ_INSTALL_URL="https://raw.github.com/ohmyzsh/ohmyzsh/master/tools/install.sh"
readonly P10K_REPO="https://github.com/romkatv/powerlevel10k.git"

# 主题配置
declare -A THEMES=(
    ["powerlevel10k"]="romkatv/powerlevel10k|现代强大的主题，支持多种样式"
    ["agnoster"]="内置|经典箭头主题，需要 Powerline 字体"
    ["robbyrussell"]="内置|Oh My Zsh 默认主题，简洁实用"
    ["refined"]="内置|简洁优雅的主题"
)

# 插件配置
declare -A CORE_PLUGINS=(
    ["zsh-autosuggestions"]="https://github.com/zsh-users/zsh-autosuggestions|智能命令建议"
    ["zsh-syntax-highlighting"]="https://github.com/zsh-users/zsh-syntax-highlighting.git|语法高亮"
    ["zsh-completions"]="https://github.com/zsh-users/zsh-completions|额外补全功能"
)

declare -A OPTIONAL_PLUGINS=(
    ["git"]="内置|Git 命令别名和功能"
    ["sudo"]="内置|双击 ESC 添加 sudo"
    ["docker"]="内置|Docker 命令补全"
    ["kubectl"]="内置|Kubernetes 命令补全"
    ["web-search"]="内置|命令行网页搜索"
    ["colored-man-pages"]="内置|彩色 man 页面"
    ["command-not-found"]="内置|命令未找到提示"
)

# === 日志函数 (兼容性检查) ===
if ! command -v log &> /dev/null; then
    log() {
        local msg="$1" level="${2:-info}"
        local -A colors=([info]="\033[0;36m" [warn]="\033[0;33m" [error]="\033[0;31m")
        echo -e "${colors[$level]:-\033[0;32m}$msg\033[0m"
    }
fi

# === 核心函数 ===

# 清理函数
cleanup() {
    [[ -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

# 网络连接检查
check_network_connectivity() {
    log "检查网络连接..." "info"
    
    local test_urls=("github.com" "raw.githubusercontent.com")
    local failed=0
    
    for url in "${test_urls[@]}"; do
        if ! timeout 10 ping -c 1 "$url" &>/dev/null; then
            log "无法连接到 $url" "warn"
            ((failed++))
        fi
    done
    
    if [[ $failed -eq ${#test_urls[@]} ]]; then
        log "网络连接失败，请检查网络设置" "error"
        return 1
    fi
    
    log "✓ 网络连接正常" "info"
    return 0
}

# 安装基础软件
install_prerequisites() {
    log "安装基础软件..." "info"
    
    local packages=("zsh" "git" "curl")
    local missing_packages=()
    
    # 检查缺失的包
    for pkg in "${packages[@]}"; do
        if ! command -v "$pkg" &>/dev/null; then
            missing_packages+=("$pkg")
        fi
    done
    
    if [[ ${#missing_packages[@]} -gt 0 ]]; then
        log "安装缺失的软件包: ${missing_packages[*]}" "info"
        if ! apt update && apt install -y "${missing_packages[@]}"; then
            log "软件包安装失败" "error"
            return 1
        fi
    fi
    
    # 验证 zsh 安装
    if ! command -v zsh &>/dev/null; then
        log "Zsh 安装失败" "error"
        return 1
    fi
    
    local zsh_version=$(zsh --version | awk '{print $2}')
    log "✓ Zsh 已安装 (版本: $zsh_version)" "info"
    return 0
}

# 安装 Oh My Zsh
install_oh_my_zsh() {
    log "安装 Oh My Zsh..." "info"
    
    if [[ -d "$ZSH_INSTALL_DIR" ]]; then
        log "Oh My Zsh 已存在，跳过安装" "info"
        return 0
    fi
    
    # 备份现有配置
    [[ -f "$ZSHRC_FILE" ]] && cp "$ZSHRC_FILE" "${ZSHRC_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
    
    # 下载并安装
    if ! RUNZSH=no sh -c "$(curl -fsSL $OMZ_INSTALL_URL)" 2>/dev/null; then
        log "Oh My Zsh 安装失败" "error"
        return 1
    fi
    
    log "✓ Oh My Zsh 安装完成" "info"
    return 0
}

# 显示主题选择菜单
show_theme_options() {
    {
        echo
        echo "🎨 选择 Zsh 主题:"
        echo "  1) Powerlevel10k - 现代强大的主题，支持多种样式 (推荐)"
        echo "  2) Agnoster - 经典箭头主题，需要 Powerline 字体"
        echo "  3) Robbyrussell - Oh My Zsh 默认主题，简洁实用"
        echo "  4) Refined - 简洁优雅的主题"
        echo
    } >&2
}

# 获取主题选择
get_theme_choice() {
    local choice theme_name
    
    show_theme_options
    
    while true; do
        read -p "请选择主题 [1-4] (默认: 1): " choice </dev/tty >&2
        
        [[ -z "$choice" ]] && choice="1"
        
        case "$choice" in
            1) 
                theme_name="powerlevel10k/powerlevel10k"
                log "已选择: Powerlevel10k" "info" >&2
                break 
                ;;
            2) 
                theme_name="agnoster"
                log "已选择: Agnoster" "info" >&2
                break 
                ;;
            3) 
                theme_name="robbyrussell"
                log "已选择: Robbyrussell" "info" >&2
                break 
                ;;
            4) 
                theme_name="refined"
                log "已选择: Refined" "info" >&2
                break 
                ;;
            *) 
                log "无效选择 '$choice'，请输入1-4" "error" >&2
                ;;
        esac
    done
    
    echo "$theme_name"
}

# 安装主题 (修复版)
install_theme() {
    local theme_choice="$1"
    
    if [[ "$theme_choice" == "powerlevel10k/powerlevel10k" ]]; then
        log "安装 Powerlevel10k 主题..." "info"
        local theme_dir="${ZSH_CUSTOM_DIR}/themes/powerlevel10k"
        
        if [[ ! -d "$theme_dir" ]]; then
            if ! git clone --depth=1 "$P10K_REPO" "$theme_dir" 2>/dev/null; then
                log "Powerlevel10k 主题安装失败" "error"
                return 1
            fi
            log "✓ Powerlevel10k 主题安装完成" "info"
        else
            log "Powerlevel10k 主题已存在" "info"
        fi
        
        # 设置默认配置
        if [[ -f "${theme_dir}/config/p10k-rainbow.zsh" ]]; then
            cp "${theme_dir}/config/p10k-rainbow.zsh" "$P10K_CONFIG"
            log "✓ 应用 Rainbow 配置" "info"
        fi
    else
        log "✓ 使用内置主题: $theme_choice" "info"
    fi
    
    return 0
}

# 显示插件选择菜单
show_plugin_options() {
    {
        echo
        echo "🔧 选择插件配置:"
        echo "  1) 完整配置 - 所有推荐插件 (适合大多数用户)"
        echo "  2) 最小配置 - 仅核心插件 (性能优先)"
        echo "  3) 开发环境 - 开发相关插件"
        echo "  4) 自定义选择 - 手动选择插件"
        echo
    } >&2
}

# 获取插件配置
get_plugin_config() {
    local choice plugin_list
    
    show_plugin_options
    
    while true; do
        read -p "请选择插件配置 [1-4] (默认: 1): " choice </dev/tty >&2
        
        [[ -z "$choice" ]] && choice="1"
        
        case "$choice" in
            1) 
                plugin_list="git zsh-autosuggestions zsh-syntax-highlighting zsh-completions sudo colored-man-pages command-not-found web-search"
                log "已选择: 完整配置" "info" >&2
                break 
                ;;
            2) 
                plugin_list="git zsh-autosuggestions zsh-syntax-highlighting"
                log "已选择: 最小配置" "info" >&2
                break 
                ;;
            3) 
                plugin_list="git zsh-autosuggestions zsh-syntax-highlighting zsh-completions sudo docker kubectl colored-man-pages command-not-found"
                log "已选择: 开发环境" "info" >&2
                break 
                ;;
            4) 
                plugin_list=$(get_custom_plugins)
                log "已选择: 自定义配置" "info" >&2
                break 
                ;;
            *) 
                log "无效选择 '$choice'，请输入1-4" "error" >&2
                ;;
        esac
    done
    
    echo "$plugin_list"
}

# 自定义插件选择
get_custom_plugins() {
    local selected_plugins=("git")  # git 始终包含
    local choice
    
    {
        echo
        echo "请选择要安装的插件 (输入序号，多个用空格分隔，回车完成):"
        echo "核心插件:"
        echo "  1) zsh-autosuggestions - 智能命令建议"
        echo "  2) zsh-syntax-highlighting - 语法高亮"
        echo "  3) zsh-completions - 额外补全功能"
        echo "可选插件:"
        echo "  4) sudo - 双击 ESC 添加 sudo"
        echo "  5) docker - Docker 命令补全"
        echo "  6) kubectl - Kubernetes 命令补全"
        echo "  7) web-search - 命令行网页搜索"
        echo "  8) colored-man-pages - 彩色 man 页面"
        echo "  9) command-not-found - 命令未找到提示"
        echo
    } >&2
    
    read -p "请输入选择 (例: 1 2 3): " choice </dev/tty >&2
    
    # 解析选择
    for num in $choice; do
        case "$num" in
            1) selected_plugins+=("zsh-autosuggestions") ;;
            2) selected_plugins+=("zsh-syntax-highlighting") ;;
            3) selected_plugins+=("zsh-completions") ;;
            4) selected_plugins+=("sudo") ;;
            5) selected_plugins+=("docker") ;;
            6) selected_plugins+=("kubectl") ;;
            7) selected_plugins+=("web-search") ;;
            8) selected_plugins+=("colored-man-pages") ;;
            9) selected_plugins+=("command-not-found") ;;
        esac
    done
    
    echo "${selected_plugins[*]}"
}

# 安装插件
install_plugins() {
    local plugin_list="$1"
    log "安装 Zsh 插件..." "info"
    
    mkdir -p "${ZSH_CUSTOM_DIR}/plugins"
    
    # 需要下载的插件
    local plugins_to_download=("zsh-autosuggestions" "zsh-syntax-highlighting" "zsh-completions")
    
    for plugin in $plugin_list; do
        if [[ " ${plugins_to_download[*]} " =~ " $plugin " ]]; then
            local plugin_dir="${ZSH_CUSTOM_DIR}/plugins/$plugin"
            
            if [[ ! -d "$plugin_dir" ]]; then
                local repo_url
                case "$plugin" in
                    "zsh-autosuggestions") repo_url="https://github.com/zsh-users/zsh-autosuggestions" ;;
                    "zsh-syntax-highlighting") repo_url="https://github.com/zsh-users/zsh-syntax-highlighting.git" ;;
                    "zsh-completions") repo_url="https://github.com/zsh-users/zsh-completions" ;;
                esac
                
                if git clone "$repo_url" "$plugin_dir" 2>/dev/null; then
                    log "✓ 插件 $plugin 安装完成" "info"
                else
                    log "插件 $plugin 安装失败" "warn"
                fi
            else
                log "插件 $plugin 已存在" "info"
            fi
        fi
    done
    
    return 0
}

# 生成 .zshrc 配置 (最终修复版)
generate_zshrc_config() {
    local theme="$1"
    local plugins="$2"
    
    log "生成 .zshrc 配置..." "info"
    
    # 备份现有配置
    [[ -f "$ZSHRC_FILE" ]] && cp "$ZSHRC_FILE" "${ZSHRC_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
    
    cat > "$ZSHRC_FILE" << 'EOF'
# Oh My Zsh 配置
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="THEME_PLACEHOLDER"

# 更新配置
DISABLE_UPDATE_PROMPT="true"
UPDATE_ZSH_DAYS=7

# 插件配置
plugins=(PLUGINS_PLACEHOLDER)

# 加载 Oh My Zsh
source $ZSH/oh-my-zsh.sh
autoload -U compinit && compinit
export PATH="$HOME/.local/bin:$PATH"

# mise 版本管理器配置
command -v mise >/dev/null 2>&1 && eval "$(mise activate zsh)"

# 实用别名
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'
alias upgrade='apt update && apt full-upgrade -y'
alias update='apt update -y'
alias reproxy='cd /root/proxy && docker compose down && docker compose pull && docker compose up -d --remove-orphans'
alias autodel='docker system prune -a -f && apt autoremove -y'
alias copyall='cd /root/copy && ansible-playbook -i inventory.ini copyhk.yml && ansible-playbook -i inventory.ini copysg.yml && ansible-playbook -i inventory.ini copyother.yml'

# Powerlevel10k 配置
POWERLEVEL9K_DISABLE_CONFIGURATION_WIZARD=true
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh

# 个人配置
[[ -f ~/.zshrc.local ]] && source ~/.zshrc.local
EOF

    # 替换占位符
    sed -i "s|THEME_PLACEHOLDER|$theme|" "$ZSHRC_FILE"
    sed -i "s|PLUGINS_PLACEHOLDER|$plugins|" "$ZSHRC_FILE"
    
    log "✓ .zshrc 配置生成完成" "info"
    return 0
}

# 设置默认 Shell
setup_default_shell() {
    local current_shell zsh_path
    
    current_shell=$(getent passwd "$USER" | cut -d: -f7)
    zsh_path=$(command -v zsh)
    
    if [[ "$current_shell" != "$zsh_path" ]]; then
        echo >&2
        read -p "是否将 Zsh 设置为默认 Shell? [Y/n]: " choice </dev/tty >&2
        
        [[ -z "$choice" ]] && choice="y"
        
        if [[ "$choice" =~ ^[Yy]$ ]]; then
            if chsh -s "$zsh_path" "$USER"; then
                log "✓ Zsh 已设置为默认 Shell (重新登录后生效)" "info"
            else
                log "设置默认 Shell 失败" "warn"
            fi
        else
            log "保持当前 Shell 不变" "info"
        fi
    else
        log "Zsh 已是默认 Shell" "info"
    fi
}

# 验证安装 (最终修复版)
verify_installation() {
    log "验证安装..." "info"
    
    local errors=0
    
    # 检查关键文件和目录
    if [[ ! -d "$ZSH_INSTALL_DIR" ]]; then
        log "✗ Oh My Zsh 目录不存在" "error"
        ((errors++))
    fi
    
    if [[ ! -f "$ZSHRC_FILE" ]]; then
        log "✗ .zshrc 文件不存在" "error"
        ((errors++))
    fi
    
    # 只检查语法，不实际运行
    if [[ -f "$ZSHRC_FILE" ]] && ! zsh -n "$ZSHRC_FILE" 2>/dev/null; then
        log "✗ Zsh 配置文件语法错误" "error"
        ((errors++))
    fi
    
    if [[ $errors -eq 0 ]]; then
        log "✓ 安装验证通过" "info"
        log "💡 Zsh 环境已配置完成！" "info"
        return 0
    else
        log "安装验证失败，发现 $errors 个错误" "error"
        return 1
    fi
}

# === 主执行流程 ===
main() {
    log "🐚 配置 Zsh Shell 环境..." "info"
    
    # 创建临时目录
    mkdir -p "$TEMP_DIR"
    
    # 检查网络连接
    check_network_connectivity || exit 1
    
    # 安装基础软件
    install_prerequisites || exit 1
    
    echo
    
    # 安装 Oh My Zsh
    install_oh_my_zsh || exit 1
    
    echo
    
    # 选择主题
    local theme_choice
    theme_choice=$(get_theme_choice)
    
    # 安装主题
    install_theme "$theme_choice" || exit 1
    
    echo
    
    # 选择插件
    local plugin_config
    plugin_config=$(get_plugin_config)
    
    # 安装插件
    install_plugins "$plugin_config" || exit 1
    
    echo
    
    # 生成配置
    generate_zshrc_config "$theme_choice" "$plugin_config" || exit 1
    
    echo
    
    # 设置默认 Shell
    setup_default_shell
    
    echo
    
    # 验证安装
    verify_installation || exit 1
    
    echo
    log "🎉 Zsh 环境配置完成!" "info"
    log "💡 提示: 运行 'exec zsh' 立即体验新环境" "info"
    
    # 如果是 Powerlevel10k，提示配置
    if [[ "$theme_choice" == "powerlevel10k/powerlevel10k" ]]; then
        echo
        log "🎨 Powerlevel10k 提示:" "info"
        log "  - 首次启动会自动配置向导" "info"
        log "  - 运行 'p10k configure' 重新配置" "info"
    fi
}

# 执行主流程
main "$@"
