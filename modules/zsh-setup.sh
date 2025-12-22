#!/bin/bash
# Zsh Shell 环境配置模块 v5.1 - 智能配置版
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
# 备份zshrc
backup_zshrc() { 
    debug_log "备份.zshrc文件" 
    if [[ -f "$HOME/.zshrc" ]] && [[ ! -f "$HOME/.zshrc.backup" ]]; then
        if cp "$HOME/.zshrc" "$HOME/.zshrc.backup" 2>/dev/null; then
            debug_log ".zshrc备份完成" 
            return 0
        else
            log "备份.zshrc失败" "error" 
            return 1
        fi
    fi
    debug_log ".zshrc备份检查完成" 
    return 0
} 
# === 辅助函数结束 ===

# === 核心功能函数 ===
# 安装基础组件
install_components() { 
    debug_log "开始安装组件" 
    local components=() 
    local errors=() 
    
    # 检查并安装zsh
    if ! command -v zsh &>/dev/null; then
        debug_log "安装Zsh和Git" 
        if apt install -y zsh git >/dev/null 2>&1; then
            components+=("Zsh") 
            debug_log "Zsh安装成功" 
        else
            errors+=("Zsh安装失败") 
            debug_log "Zsh安装失败" 
        fi
    else
        debug_log "Zsh已安装，跳过" 
    fi
    
    # 安装Oh My Zsh
    if [[ ! -d "$ZSH_DIR" ]]; then
        debug_log "安装Oh My Zsh" 
        # 【修改点】添加 < /dev/null 防止卡住
        if RUNZSH=no sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" < /dev/null >/dev/null 2>&1; then
            components+=("Oh-My-Zsh") 
            debug_log "Oh My Zsh安装成功" 
        else
            errors+=("Oh-My-Zsh安装失败") 
            debug_log "Oh My Zsh安装失败" 
        fi
    else
        debug_log "Oh My Zsh已安装，跳过" 
    fi
    
    # 安装Powerlevel10k主题
    if [[ ! -d "$THEME_DIR" ]]; then
        debug_log "安装Powerlevel10k主题" 
        if git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$THEME_DIR" >/dev/null 2>&1; then
            components+=("Powerlevel10k") 
            debug_log "Powerlevel10k安装成功" 
        else
            errors+=("Powerlevel10k主题安装失败") 
            debug_log "Powerlevel10k安装失败" 
        fi
    else
        debug_log "Powerlevel10k已安装，跳过" 
    fi
    
    # 安装插件
    local new_plugins=0
    local failed_plugins=() 
    
    if mkdir -p "$PLUGINS_DIR" 2>/dev/null; then
        debug_log "开始安装插件" 
        
        local plugins=( 
            "zsh-autosuggestions|https://github.com/zsh-users/zsh-autosuggestions" 
            "zsh-syntax-highlighting|https://github.com/zsh-users/zsh-syntax-highlighting.git" 
            "zsh-completions|https://github.com/zsh-users/zsh-completions" 
        ) 
        
        for plugin_info in "${plugins[@]}"; do
            local plugin_name="${plugin_info%%|*}" 
            local plugin_url="${plugin_info##*|}" 
            
            if [[ ! -d "$PLUGINS_DIR/$plugin_name" ]]; then
                debug_log "安装插件: $plugin_name" 
                if git clone "$plugin_url" "$PLUGINS_DIR/$plugin_name" >/dev/null 2>&1; then
                    ((new_plugins++)) 
                    debug_log "插件安装成功: $plugin_name" 
                else
                    failed_plugins+=("$plugin_name") 
                    debug_log "插件安装失败: $plugin_name" 
                fi
            else
                debug_log "插件已安装，跳过: $plugin_name" 
            fi
        done
        
        [[ $new_plugins -gt 0 ]] && components+=("${new_plugins}个插件") 
        [[ ${#failed_plugins[@]} -gt 0 ]] && errors+=("插件失败: ${failed_plugins[*]}") 
    else
        log "创建插件目录失败" "error" 
        errors+=("插件目录创建失败") 
    fi
    
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
    
    return 0  # 不让错误中断整个流程
} 

# 配置zshrc文件  
configure_zshrc() {   
    debug_log "开始配置.zshrc"   
      
    if ! backup_zshrc; then  
        return 1  
    fi  
      
    debug_log "写入.zshrc配置文件"   
    if ! cat > "$HOME/.zshrc" << 'EOF'; then  
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
# Zsh 脚本修复：确保 ~/.local/bin 在 PATH 末尾，系统工具优先
export PATH="$PATH:$HOME/.local/bin" 
  
# mise 版本管理器配置 (使用安全的 init -s 模式，只注入 Shell 函数和补全，不劫持 PATH)  
command -v mise >/dev/null 2>&1 && eval "$(mise init -s zsh)"   
  
# Powerlevel10k 配置  
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh  
  
# 实用别名  
alias upgrade='apt update && apt full-upgrade -y'   
alias update='apt update -y'   
alias reproxy='cd /root/proxy && docker compose down && docker compose pull && docker compose up -d --remove-orphans'   
alias dlog='docker logs -f'   
alias autodel='docker system prune -a -f && apt autoremove -y && apt clean'   
alias sstop='systemctl stop'   
alias sre='systemctl restart'   
alias sst='systemctl status'   
alias sdre='systemctl daemon-reload'   
EOF
        log ".zshrc配置写入失败" "error"   
        return 1  
    fi  
      
    debug_log ".zshrc配置完成"   
    return 0  
}

# 选择并配置主题
setup_theme() { 
    debug_log "开始主题选择" 
    echo "主题选择:" >&2
    echo "  1) LucaLin (推荐) - 精心调配的个人主题" >&2
    echo "  2) Rainbow - 彩虹主题，丰富多彩" >&2
    echo "  3) Lean - 精简主题，简洁清爽" >&2
    echo "  4) Classic - 经典主题，传统外观" >&2
    echo "  5) Pure - 纯净主题，极简风格" >&2
    echo "  6) 配置向导 - 交互式配置，功能最全" >&2
    echo >&2
    
    local choice
    # 【修改点】添加超时保护，防止卡住
    read -t 30 -p "请选择 [1-6] (默认1): " choice >&2 || choice=1
    choice=${choice:-1} 
    
    debug_log "用户选择主题选项: $choice" 
    
    case "$choice" in
        1) 
            echo "主题: LucaLin (推荐配置)" 
            debug_log "下载LucaLin主题配置" 
            if curl -fsSL "https://raw.githubusercontent.com/LucaLin233/Linux/refs/heads/main/p10k-config.zsh" -o "$HOME/.p10k.zsh" 2>/dev/null; then
                debug_log "LucaLin主题下载成功" 
            else
                echo "主题: 配置向导 (下载失败，首次启动时配置)" 
                debug_log "LucaLin主题下载失败" 
            fi
            ;; 
        2) 
            echo "主题: Rainbow (彩虹风格)" 
            debug_log "下载Rainbow主题配置" 
            if curl -fsSL "https://raw.githubusercontent.com/romkatv/powerlevel10k/master/config/p10k-rainbow.zsh" -o "$HOME/.p10k.zsh" 2>/dev/null; then
                debug_log "Rainbow主题下载成功" 
            else
                echo "主题: 配置向导 (下载失败，首次启动时配置)" 
                debug_log "Rainbow主题下载失败" 
            fi
            ;; 
        3) 
            echo "主题: Lean (简洁风格)" 
            debug_log "下载Lean主题配置" 
            if curl -fsSL "https://raw.githubusercontent.com/romkatv/powerlevel10k/master/config/p10k-lean.zsh" -o "$HOME/.p10k.zsh" 2>/dev/null; then
                debug_log "Lean主题下载成功" 
            else
                echo "主题: 配置向导 (下载失败，首次启动时配置)" 
                debug_log "Lean主题下载失败" 
            fi
            ;; 
        4) 
            echo "主题: Classic (经典风格)" 
            debug_log "下载Classic主题配置" 
            if curl -fsSL "https://raw.githubusercontent.com/romkatv/powerlevel10k/master/config/p10k-classic.zsh" -o "$HOME/.p10k.zsh" 2>/dev/null; then
                debug_log "Classic主题下载成功" 
            else
                echo "主题: 配置向导 (下载失败，首次启动时配置)" 
                debug_log "Classic主题下载失败" 
            fi
            ;; 
        5) 
            echo "主题: Pure (极简风格)" 
            debug_log "下载Pure主题配置" 
            if curl -fsSL "https://raw.githubusercontent.com/romkatv/powerlevel10k/master/config/p10k-pure.zsh" -o "$HOME/.p10k.zsh" 2>/dev/null; then
                debug_log "Pure主题下载成功" 
            else
                echo "主题: 配置向导 (下载失败，首次启动时配置)" 
                debug_log "Pure主题下载失败" 
            fi
            ;; 
        6) 
            echo "主题: 配置向导 (首次启动时配置)" 
            debug_log "用户选择配置向导" 
            ;; 
        *) 
            echo "主题: LucaLin (默认选择)" 
            debug_log "使用默认LucaLin主题" 
            curl -fsSL "https://raw.githubusercontent.com/LucaLin233/Linux/refs/heads/main/p10k-config.zsh" -o "$HOME/.p10k.zsh" 2>/dev/null || { 
                debug_log "默认主题下载失败" 
            } 
            ;; 
    esac
    
    return 0  # 主题下载失败不应该中断整个流程
} 

# 设置默认Shell
setup_default_shell() { 
    debug_log "设置默认Shell" 
    local zsh_path
    
    if ! zsh_path=$(which zsh 2>/dev/null); then
        log "找不到zsh可执行文件" "error" 
        return 1
    fi
    
    local current_shell=$(getent passwd root 2>/dev/null | cut -d: -f7 || echo "unknown") 
    debug_log "当前Shell: $current_shell, Zsh路径: $zsh_path" 
    
    if [[ "$current_shell" != "$zsh_path" ]]; then
        if chsh -s "$zsh_path" root 2>/dev/null; then
            echo "默认Shell: Zsh (重新登录生效)" 
            debug_log "默认Shell设置成功" 
        else
            log "设置默认Shell失败" "error" 
            return 1
        fi
    else
        echo "默认Shell: 已是Zsh" 
        debug_log "默认Shell已是Zsh" 
    fi
    
    return 0
} 
# === 核心功能函数结束 ===

# === 主流程 ===
main() { 
    log "🐚 配置Zsh环境..." "info" 
    
    echo
    install_components || { 
        log "组件安装出现问题，但继续执行" "warn" 
    } 
    
    echo
    if configure_zshrc; then
        echo "配置文件: .zshrc 已更新" 
    else
        log "zshrc配置失败" "error" 
        return 1
    fi
    
    echo
    setup_theme || { 
        log "主题设置出现问题，但不影响主要功能" "warn" 
    } 
    
    echo
    setup_default_shell || { 
        log "默认Shell设置失败" "warn" 
    } 
    
    echo
    log "✅ Zsh配置完成，运行 'exec zsh' 体验" "info" 
    
    return 0
} 

# 错误处理 - 修复版
trap 'echo "❌ Zsh配置脚本在第 $LINENO 行执行失败" >&2; exit 1' ERR

main "$@"
