#!/bin/bash
# Mise 版本管理器配置模块 (优化版 v3.0)
# 功能: Mise安装、Python配置、Shell集成

set -euo pipefail

# === 常量定义 ===
readonly MISE_INSTALL_URL="https://mise.run"
readonly MISE_PATH="$HOME/.local/bin/mise"
readonly MISE_CONFIG_DIR="$HOME/.config/mise"
readonly DEFAULT_PYTHON_VERSION="3.12"

# === 兼容性日志函数 ===
if ! command -v log &> /dev/null; then
    log() {
        local msg="$1" level="${2:-info}"
        local -A colors=([info]="\033[0;36m" [warn]="\033[0;33m" [error]="\033[0;31m")
        echo -e "${colors[$level]:-\033[0;32m}$msg\033[0m"
    }
fi

# === 系统依赖检查 ===
check_dependencies() {
    log "检查系统依赖..." "info"
    
    local required_deps=(curl build-essential libssl-dev zlib1g-dev libbz2-dev 
                         libreadline-dev libsqlite3-dev wget llvm libncurses5-dev 
                         libncursesw5-dev xz-utils tk-dev libffi-dev liblzma-dev)
    local missing_deps=()
    
    # 检查基础命令
    for cmd in curl wget tar gzip; do
        if ! command -v "$cmd" &>/dev/null; then
            missing_deps+=("$cmd")
        fi
    done
    
    # 检查编译依赖
    for dep in "${required_deps[@]}"; do
        if ! dpkg -l "$dep" &>/dev/null; then
            missing_deps+=("$dep")
        fi
    done
    
    if (( ${#missing_deps[@]} > 0 )); then
        log "安装缺失依赖: ${missing_deps[*]}" "info"
        apt-get update -qq
        apt-get install -y "${missing_deps[@]}"
        log "✓ 依赖安装完成" "info"
    else
        log "✓ 系统依赖检查通过" "info"
    fi
}

# === Mise 安装模块 ===
install_mise() {
    log "检查并安装 Mise..." "info"
    
    # 检查是否已安装
    if [[ -f "$MISE_PATH" ]] && command -v "$MISE_PATH" &>/dev/null; then
        local current_version
        current_version=$("$MISE_PATH" --version 2>/dev/null | head -1 || echo "未知")
        log "✓ Mise 已安装: $current_version" "info"
        
        read -p "是否更新到最新版本? [y/N]: " -r update_choice
        [[ ! "$update_choice" =~ ^[Yy]$ ]] && return 0
    fi
    
    log "开始安装 Mise..." "info"
    
    # 创建目录
    mkdir -p "$HOME/.local/bin" "$MISE_CONFIG_DIR"
    
    # 安全下载和安装
    local temp_script="/tmp/mise_install.sh"
    
    if curl -fsSL --connect-timeout 10 --max-time 30 "$MISE_INSTALL_URL" -o "$temp_script"; then
        # 检查脚本内容
        if grep -q "#!/" "$temp_script" && grep -q "mise" "$temp_script"; then
            log "执行 Mise 安装脚本..." "info"
            bash "$temp_script"
        else
            log "安装脚本内容异常" "error"
            rm -f "$temp_script"
            return 1
        fi
    else
        log "下载 Mise 安装脚本失败" "error"
        return 1
    fi
    
    # 清理临时文件
    rm -f "$temp_script"
    
    # 验证安装
    if [[ -f "$MISE_PATH" ]] && "$MISE_PATH" --version &>/dev/null; then
        local version
        version=$("$MISE_PATH" --version | head -1)
        log "✓ Mise 安装成功: $version" "info"
    else
        log "✗ Mise 安装失败" "error"
        return 1
    fi
}

# === Python 配置模块 ===
setup_python() {
    local python_version="${1:-$DEFAULT_PYTHON_VERSION}"
    
    log "配置 Python $python_version..." "info"
    
    # 检查是否已安装
    if "$MISE_PATH" list python 2>/dev/null | grep -q "$python_version"; then
        log "Python $python_version 已通过 Mise 安装" "info"
        read -p "是否重新安装? [y/N]: " -r reinstall
        [[ ! "$reinstall" =~ ^[Yy]$ ]] && return 0
    fi
    
    # 设置全局Python版本
    log "安装 Python $python_version (这可能需要几分钟)..." "info"
    
    if "$MISE_PATH" use -g "python@$python_version"; then
        log "✓ Python $python_version 安装完成" "info"
        
        # 验证安装
        if "$MISE_PATH" which python &>/dev/null; then
            local installed_version
            installed_version=$("$MISE_PATH" exec python -- --version 2>/dev/null || echo "版本获取失败")
            log "  安装版本: $installed_version" "info"
        fi
    else
        log "✗ Python $python_version 安装失败" "error"
        return 1
    fi
}

# === 选择Python版本 ===
select_python_version() {
    cat << 'EOF'

选择要安装的 Python 版本:
1) Python 3.12 (最新稳定版，推荐)
2) Python 3.11 (LTS版本)
3) Python 3.10 (兼容性好)
4) 自定义版本
5) 跳过 Python 安装

EOF
    
    read -p "请选择 [1-5, 默认1]: " -r choice
    choice=${choice:-1}
    
    case "$choice" in
        1) echo "3.12" ;;
        2) echo "3.11" ;;
        3) echo "3.10" ;;
        4) 
            while true; do
                read -p "请输入Python版本 (如: 3.11.7): " -r custom_version
                if [[ "$custom_version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
                    echo "$custom_version"
                    break
                else
                    log "版本格式错误，请重新输入" "error"
                fi
            done
            ;;
        5) echo "skip" ;;
        *) echo "3.12" ;;
    esac
}

# === 系统Python链接 ===
setup_system_python_links() {
    log "配置系统 Python 链接..." "info"
    
    read -p "是否创建系统级 Python 链接? (将覆盖 /usr/bin/python) [y/N]: " -r create_links
    [[ ! "$create_links" =~ ^[Yy]$ ]] && return 0
    
    local mise_python
    if mise_python=$("$MISE_PATH" which python 2>/dev/null); then
        # 备份现有链接
        [[ -L /usr/bin/python ]] && cp -P /usr/bin/python /usr/bin/python.backup 2>/dev/null || true
        [[ -L /usr/bin/python3 ]] && cp -P /usr/bin/python3 /usr/bin/python3.backup 2>/dev/null || true
        
        # 创建新链接
        ln -sf "$mise_python" /usr/bin/python
        ln -sf "$mise_python" /usr/bin/python3
        
        log "✓ 系统 Python 链接已创建" "info"
        log "  /usr/bin/python -> $mise_python" "info"
        log "  /usr/bin/python3 -> $mise_python" "info"
    else
        log "✗ 无法找到 Mise Python 路径" "error"
        return 1
    fi
}

# === Shell 集成配置 ===
setup_shell_integration() {
    log "配置 Shell 集成..." "info"
    
    local shells_configured=0
    
    # 配置 Bash
    if setup_bash_integration; then
        ((shells_configured++))
    fi
    
    # 配置 Zsh (如果可用)
    if command -v zsh &>/dev/null; then
        if setup_zsh_integration; then
            ((shells_configured++))
        fi
    fi
    
    if (( shells_configured > 0 )); then
        log "✓ Shell 集成配置完成" "info"
        log "  请运行 'source ~/.bashrc' 或重新登录以激活" "warn"
    else
        log "✗ Shell 集成配置失败" "error"
        return 1
    fi
}

setup_bash_integration() {
    local bashrc="$HOME/.bashrc"
    local mise_config="# Mise version manager
eval \"\$($MISE_PATH activate bash)\""
    
    [[ ! -f "$bashrc" ]] && touch "$bashrc"
    
    if grep -q "mise activate bash" "$bashrc"; then
        log "  Bash: 已配置" "info"
        return 0
    fi
    
    echo -e "\n$mise_config" >> "$bashrc"
    log "  ✓ Bash 集成已添加" "info"
    return 0
}

setup_zsh_integration() {
    local zshrc="$HOME/.zshrc"
    
    if [[ ! -f "$zshrc" ]]; then
        log "  Zsh: 配置文件不存在，跳过" "warn"
        return 1
    fi
    
    if grep -q "mise activate zsh" "$zshrc"; then
        log "  Zsh: 已配置" "info"
        return 0
    fi
    
    # 在合适位置添加mise配置
    if grep -q "# User configuration" "$zshrc"; then
        sed -i '/# User configuration/a\\neval "$(mise activate zsh)"' "$zshrc"
    else
        echo -e "\n# Mise version manager\neval \"\$(mise activate zsh)\"" >> "$zshrc"
    fi
    
    log "  ✓ Zsh 集成已添加" "info"
    return 0
}

# === 安装常用Python包 ===
install_common_packages() {
    log "安装常用 Python 包..." "info"
    
    read -p "是否安装常用Python包? (pip, virtualenv, etc.) [Y/n]: " -r install_packages
    [[ "$install_packages" =~ ^[Nn]$ ]] && return 0
    
    local packages=(pip setuptools wheel virtualenv pipenv poetry)
    
    log "更新 pip..." "info"
    "$MISE_PATH" exec python -- -m pip install --upgrade pip
    
    log "安装常用包: ${packages[*]}" "info"
    if "$MISE_PATH" exec python -- -m pip install "${packages[@]}"; then
        log "✓ Python 包安装完成" "info"
    else
        log "⚠ 部分包安装失败" "warn"
    fi
}

# === 显示配置摘要 ===
show_mise_summary() {
    echo
    log "📋 Mise 配置摘要:" "info"
    
    # Mise 版本
    if [[ -f "$MISE_PATH" ]]; then
        local version
        version=$("$MISE_PATH" --version 2>/dev/null | head -1 || echo "未知")
        log "  ✓ Mise: $version" "info"
    else
        log "  ✗ Mise: 未安装" "error"
        return 1
    fi
    
    # Python 状态
    if "$MISE_PATH" which python &>/dev/null; then
        local python_version python_path
        python_version=$("$MISE_PATH" exec python -- --version 2>/dev/null || echo "未知")
        python_path=$("$MISE_PATH" which python 2>/dev/null || echo "未知")
        log "  ✓ Python: $python_version" "info"
        log "    路径: $python_path" "info"
    else
        log "  ✗ Python: 未配置" "warn"
    fi
    
    # 已安装工具
    local tools
    tools=$("$MISE_PATH" list 2>/dev/null | head -5 || echo "无")
    log "  📦 已安装工具:" "info"
    echo "$tools" | sed 's/^/    /'
    
    # Shell 集成状态
    if grep -q "mise activate" "$HOME/.bashrc" 2>/dev/null; then
        log "  ✓ Bash 集成: 已配置" "info"
    fi
    
    if [[ -f "$HOME/.zshrc" ]] && grep -q "mise activate" "$HOME/.zshrc" 2>/dev/null; then
        log "  ✓ Zsh 集成: 已配置" "info"
    fi
}

# === 主执行流程 ===
main() {
    log "🔧 开始 Mise 版本管理器配置..." "info"
    
    # 检查系统依赖
    check_dependencies
    echo
    
    # 安装 Mise
    install_mise
    echo
    
    # Python 配置
    local python_version
    python_version=$(select_python_version)
    
    if [[ "$python_version" != "skip" ]]; then
        setup_python "$python_version"
        echo
        
        # 系统链接
        setup_system_python_links
        echo
        
        # 安装常用包
        install_common_packages
        echo
    else
        log "跳过 Python 配置" "info"
        echo
    fi
    
    # Shell 集成
    setup_shell_integration
    
    # 显示摘要
    show_mise_summary
    
    log "🎉 Mise 配置完成!" "info"
    log "💡 使用提示:" "info"
    log "  查看工具: mise list" "info"
    log "  安装工具: mise install node@20" "info"
    log "  设置版本: mise use python@3.12" "info"
}

# 执行主流程
main "$@"
