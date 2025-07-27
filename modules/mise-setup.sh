#!/bin/bash
# Mise 版本管理器配置模块 v4.0
# 功能: 安装Mise、配置Python、Shell集成
# 统一代码风格，简化逻辑

set -euo pipefail

# === 常量定义 ===
readonly MISE_PATH="$HOME/.local/bin/mise"
readonly MISE_BIN_DIR="$HOME/.local/bin"
readonly DEFAULT_PYTHON_VERSION="3.10"

# === 日志函数 ===
log() {
    local msg="$1" level="${2:-info}"
    local -A colors=([info]="\033[0;36m" [warn]="\033[0;33m" [error]="\033[0;31m")
    echo -e "${colors[$level]:-\033[0;32m}$msg\033[0m"
}

# === 核心函数 ===

# 安装或更新Mise
install_mise() {
    log "检查并安装 Mise..." "info"
    
    # 确保目录存在
    mkdir -p "$MISE_BIN_DIR"
    
    if [[ -f "$MISE_PATH" ]]; then
        local mise_version=$("$MISE_PATH" --version 2>/dev/null | awk '{print $2}' || echo "未知")
        log "Mise 已安装 (版本: $mise_version)" "info"
        
        echo
        read -p "是否更新 Mise 到最新版本? [y/N] (默认: N): " -r update_choice
        if [[ "$update_choice" =~ ^[Yy]$ ]]; then
            log "更新 Mise..." "info"
            curl -fsSL https://mise.run | sh
            log "✓ Mise 已更新" "info"
        fi
    else
        log "安装 Mise..." "info"
        if curl -fsSL https://mise.run | sh; then
            log "✓ Mise 安装完成" "info"
        else
            log "✗ Mise 安装失败" "error"
            exit 1
        fi
    fi
    
    # 验证安装
    if [[ ! -f "$MISE_PATH" ]]; then
        log "✗ Mise 安装验证失败" "error"
        exit 1
    fi
}

# 配置Python
setup_python() {
    log "配置 Python $DEFAULT_PYTHON_VERSION..." "info"
    
    # 检查是否已安装
    if "$MISE_PATH" list python 2>/dev/null | grep -q "$DEFAULT_PYTHON_VERSION"; then
        log "Python $DEFAULT_PYTHON_VERSION 已通过 Mise 安装" "info"
        
        echo
        read -p "是否重新安装 Python $DEFAULT_PYTHON_VERSION? [y/N] (默认: N): " -r reinstall_choice
        if [[ ! "$reinstall_choice" =~ ^[Yy]$ ]]; then
            return 0
        fi
    fi
    
    # 安装Python
    log "安装 Python $DEFAULT_PYTHON_VERSION..." "info"
    if "$MISE_PATH" use -g "python@$DEFAULT_PYTHON_VERSION"; then
        log "✓ Python $DEFAULT_PYTHON_VERSION 安装完成" "info"
    else
        log "✗ Python $DEFAULT_PYTHON_VERSION 安装失败" "warn"
        return 1
    fi
}

# 创建系统Python链接
link_python_globally() {
    log "创建系统Python链接..." "info"
    
    local python_path
    python_path=$("$MISE_PATH" which python 2>/dev/null || echo "")
    
    if [[ -x "$python_path" ]]; then
        log "创建 /usr/bin/python 链接..." "info"
        sudo ln -sf "$python_path" /usr/bin/python
        
        log "创建 /usr/bin/python3 链接..." "info"
        sudo ln -sf "$python_path" /usr/bin/python3
        
        log "✓ Python链接已创建" "info"
        log "  /usr/bin/python -> $python_path" "info"
        log "  /usr/bin/python3 -> $python_path" "info"
    else
        log "✗ 无法找到Mise管理的Python，跳过链接创建" "warn"
    fi
}

# 配置Shell集成
configure_shell_integration() {
    log "配置 Shell 集成..." "info"
    
    # Shell配置数组: shell名称:配置文件:激活命令
    local shells=(
        "bash:$HOME/.bashrc:eval \"\$(\$HOME/.local/bin/mise activate bash)\""
        "zsh:$HOME/.zshrc:eval \"\$(mise activate zsh)\""
    )
    
    for shell_info in "${shells[@]}"; do
        local shell_name="${shell_info%%:*}"
        local config_file="${shell_info#*:}"
        config_file="${config_file%%:*}"
        local activate_cmd="${shell_info##*:}"
        
        # 检查shell是否可用
        if ! command -v "$shell_name" &>/dev/null; then
            continue
        fi
        
        # 确保配置文件存在
        [[ ! -f "$config_file" ]] && touch "$config_file"
        
        # 检查是否已配置
        if grep -q "mise activate $shell_name" "$config_file"; then
            log "$shell_name 集成已存在" "info"
        else
            # 添加配置
            if [[ "$shell_name" == "bash" ]]; then
                echo -e "\n# Mise version manager\n$activate_cmd" >> "$config_file"
            else
                # 对于zsh，插入到mise注释后面（zsh-setup模块已经添加了注释）
                if grep -q "# mise 版本管理器配置" "$config_file"; then
                    sed -i "/# mise 版本管理器配置/a $activate_cmd" "$config_file"
                else
                    echo -e "\n# Mise version manager\n$activate_cmd" >> "$config_file"
                fi
            fi
            log "✓ Mise 已添加到 $config_file" "info"
        fi
    done
}

# 显示配置摘要
show_mise_summary() {
    echo
    log "🎯 Mise 配置摘要:" "info"
    
    # Mise版本
    if [[ -f "$MISE_PATH" ]]; then
        local mise_version=$("$MISE_PATH" --version 2>/dev/null | awk '{print $2}' || echo "未知")
        log "  ✓ Mise版本: $mise_version" "info"
        
        # Python状态
        if "$MISE_PATH" which python &>/dev/null; then
            local python_version=$("$MISE_PATH" which python | xargs -I {} {} --version 2>/dev/null || echo "版本获取失败")
            log "  ✓ Python: $python_version" "info"
        else
            log "  ✗ Python: 未配置" "info"
        fi
        
        # 全局工具列表
        local tools_count=$("$MISE_PATH" list 2>/dev/null | wc -l || echo "0")
        log "  📦 已安装工具: $tools_count 个" "info"
    else
        log "  ✗ Mise: 未安装" "error"
    fi
    
    # Shell集成状态
    if grep -q "mise activate" "$HOME/.bashrc" 2>/dev/null; then
        log "  ✓ Bash集成: 已配置" "info"
    fi
    
    if [[ -f "$HOME/.zshrc" ]] && grep -q "mise activate" "$HOME/.zshrc" 2>/dev/null; then
        log "  ✓ Zsh集成: 已配置" "info"
    fi
}

# === 主流程 ===
main() {
    log "🔧 配置 Mise 版本管理器..." "info"
    
    echo
    install_mise
    
    echo
    setup_python
    
    echo
    link_python_globally
    
    echo
    configure_shell_integration
    
    show_mise_summary
    
    echo
    log "🎉 Mise 配置完成!" "info"
    log "💡 提示: 运行 'source ~/.bashrc' 或重新登录以激活 Mise" "info"
    
    # 显示有用的命令
    if [[ -f "$MISE_PATH" ]]; then
        echo
        log "常用命令:" "info"
        log "  查看工具: $MISE_PATH list" "info"
        log "  安装工具: $MISE_PATH use -g <tool>@<version>" "info"
        log "  查看帮助: $MISE_PATH --help" "info"
    fi
}

main "$@"
