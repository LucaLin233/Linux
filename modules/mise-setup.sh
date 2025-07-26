#!/bin/bash
# Mise 版本管理器配置模块 (修复版 v3.2)

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
    
    if [[ -f "$MISE_PATH" ]] && "$MISE_PATH" --version &>/dev/null; then
        local current_version
        current_version=$("$MISE_PATH" --version 2>/dev/null | head -1 || echo "未知")
        log "✓ Mise 已安装: $current_version" "info"
        
        read -p "是否更新到最新版本? [y/N]: " -r update_choice
        [[ ! "$update_choice" =~ ^[Yy]$ ]] && return 0
    fi
    
    log "开始安装 Mise..." "info"
    
    mkdir -p "$HOME/.local/bin" "$MISE_CONFIG_DIR"
    
    if curl -fsSL "$MISE_INSTALL_URL" | sh >/dev/null 2>&1; then
        log "✓ Mise 安装成功" "info"
    else
        log "✗ Mise 安装失败" "error"
        return 1
    fi
    
    if [[ -f "$MISE_PATH" ]] && "$MISE_PATH" --version &>/dev/null; then
        local version
        version=$("$MISE_PATH" --version 2>/dev/null | head -1 || echo "未知")
        log "  版本: $version" "info"
    else
        log "✗ Mise 验证失败" "error"
        return 1
    fi
}

# === 清理旧版本 ===
cleanup_old_python() {
    log "清理旧Python版本..." "info"
    
    local installed_versions
    installed_versions=$("$MISE_PATH" list python 2>/dev/null | grep -E "python" | awk '{print $1}' || echo "")
    
    if [[ -n "$installed_versions" ]]; then
        echo "发现已安装的Python版本:" >&2
        echo "$installed_versions" | sed 's/^/  /' >&2
        
        read -p "是否清理所有旧版本? [y/N]: " -r cleanup_choice >&2
        if [[ "$cleanup_choice" =~ ^[Yy]$ ]]; then
            echo "$installed_versions" | while read -r version; do
                if [[ -n "$version" ]]; then
                    log "卸载 $version..." "info"
                    "$MISE_PATH" uninstall "$version" 2>/dev/null || true
                fi
            done
        fi
    fi
}

# === 选择Python版本 (修复版) ===
select_python_version() {
    # 所有交互输出到stderr
    {
        echo
        echo "===================="
        log "选择 Python 版本:" "info"
        echo "===================="
        echo "1) Python 3.12 (最新稳定版，推荐)"
        echo "2) Python 3.11 (LTS版本)"
        echo "3) Python 3.10 (兼容性好)"
        echo "4) 自定义版本"
        echo "5) 跳过 Python 安装"
        echo
    } >&2
    
    read -p "请选择 [1-5, 默认1]: " -r choice >&2
    choice=${choice:-1}
    
    case "$choice" in
        1) echo "3.12" ;;
        2) echo "3.11" ;;
        3) echo "3.10" ;;
        4) 
            while true; do
                read -p "请输入Python版本 (如: 3.11.7): " -r custom_version >&2
                if [[ "$custom_version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
                    echo "$custom_version"
                    break
                else
                    echo "版本格式错误，请重新输入" >&2
                fi
            done
            ;;
        5) echo "skip" ;;
        *) echo "3.12" ;;
    esac
}

# === Python 配置模块 ===
setup_python() {
    local python_version="$1"
    
    log "配置 Python $python_version..." "info"
    
    # 清理旧版本
    cleanup_old_python
    
    # 安装指定版本
    log "安装 Python $python_version (这可能需要几分钟)..." "info"
    
    export PYTHON_CONFIGURE_OPTS="--enable-shared"
    
    # 先安装，再设置为全局
    if "$MISE_PATH" install "python@$python_version" && "$MISE_PATH" use -g "python@$python_version"; then
        log "✓ Python $python_version 安装完成" "info"
        
        sleep 2
        
        # 验证安装
        if "$MISE_PATH" which python &>/dev/null; then
            local python_path python_ver
            python_path=$("$MISE_PATH" which python 2>/dev/null || echo "未找到")
            
            if [[ -x "$python_path" ]]; then
                python_ver=$("$python_path" --version 2>/dev/null || echo "版本获取失败")
                log "  ✓ 安装版本: $python_ver" "info"
                log "  ✓ 可执行文件: $python_path" "info"
            else
                log "  ✗ Python可执行文件无效" "error"
                return 1
            fi
        else
            log "  ✗ Python安装验证失败" "error"
            return 1
        fi
    else
        log "✗ Python $python_version 安装失败" "error"
        return 1
    fi
}

# === 系统Python链接 ===
setup_system_python_links() {
    log "配置系统 Python 链接..." "info"
    
    read -p "是否创建系统级 Python 链接? (将覆盖 /usr/bin/python) [y/N]: " -r create_links
    [[ ! "$create_links" =~ ^[Yy]$ ]] && return 0
    
    local python_path
    python_path=$("$MISE_PATH" which python 2>/dev/null)
    
    if [[ -n "$python_path" ]] && [[ -x "$python_path" ]] && "$python_path" --version &>/dev/null; then
        # 备份现有链接
        [[ -L /usr/bin/python ]] && cp -P /usr/bin/python /usr/bin/python.backup 2>/dev/null || true
        [[ -L /usr/bin/python3 ]] && cp -P /usr/bin/python3 /usr/bin/python3.backup 2>/dev/null || true
        
        # 创建新链接
        ln -sf "$python_path" /usr/bin/python
        ln -sf "$python_path" /usr/bin/python3
        
        log "✓ 系统 Python 链接已创建" "info"
        log "  /usr/bin/python -> $python_path" "info"
        log "  /usr/bin/python3 -> $python_path" "info"
    else
        log "✗ 无法找到有效的 Python 路径" "error"
        return 1
    fi
}

# === Shell 集成配置 ===
setup_shell_integration() {
    log "配置 Shell 集成..." "info"
    
    local shells_configured=0
    
    # 配置 Bash
    local bashrc="$HOME/.bashrc"
    [[ ! -f "$bashrc" ]] && touch "$bashrc"
    
    if ! grep -q "mise activate bash" "$bashrc"; then
        echo -e "\n# Mise version manager\neval \"\$($MISE_PATH activate bash)\"" >> "$bashrc"
        log "  ✓ Bash 集成已添加" "info"
        ((shells_configured++))
    else
        log "  Bash: 已配置" "info"
        ((shells_configured++))
    fi
    
    # 配置 Zsh (如果可用)
    if command -v zsh &>/dev/null && [[ -f "$HOME/.zshrc" ]]; then
        if ! grep -q "mise activate zsh" "$HOME/.zshrc"; then
            echo -e "\n# Mise version manager\neval \"\$($MISE_PATH activate zsh)\"" >> "$HOME/.zshrc"
            log "  ✓ Zsh 集成已添加" "info"
            ((shells_configured++))
        else
            log "  Zsh: 已配置" "info"
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

# === 安装常用Python包 ===
install_common_packages() {
    log "安装常用 Python 包..." "info"
    
    read -p "是否安装常用Python包? (pip, virtualenv, etc.) [Y/n]: " -r install_packages
    [[ "$install_packages" =~ ^[Nn]$ ]] && return 0
    
    local python_path
    python_path=$("$MISE_PATH" which python 2>/dev/null)
    
    if [[ -z "$python_path" ]] || [[ ! -x "$python_path" ]]; then
        log "✗ 无法找到Python可执行文件" "error"
        return 1
    fi
    
    log "更新 pip..." "info"
    if "$python_path" -m pip install --upgrade pip; then
        log "✓ pip 更新成功" "info"
    else
        log "⚠ pip 更新失败" "warn"
    fi
    
    local packages=(setuptools wheel virtualenv pipenv)
    log "安装包: ${packages[*]}" "info"
    
    if "$python_path" -m pip install "${packages[@]}"; then
        log "✓ Python 包安装完成" "info"
    else
        log "⚠ 部分包安装失败" "warn"
    fi
}

# === 显示配置摘要 ===
show_mise_summary() {
    echo
    log "📋 Mise 配置摘要:" "info"
    
    if [[ -f "$MISE_PATH" ]]; then
        local version
        version=$("$MISE_PATH" --version 2>/dev/null | head -1 || echo "未知")
        log "  ✓ Mise: $version" "info"
    else
        log "  ✗ Mise: 未安装" "error"
        return 1
    fi
    
    local python_path
    python_path=$("$MISE_PATH" which python 2>/dev/null)
    
    if [[ -n "$python_path" ]] && [[ -x "$python_path" ]]; then
        local python_version
        python_version=$("$python_path" --version 2>/dev/null || echo "未知")
        log "  ✓ Python: $python_version" "info"
        log "    路径: $python_path" "info"
        
        if "$python_path" -m pip --version &>/dev/null; then
            local pip_version
            pip_version=$("$python_path" -m pip --version 2>/dev/null | awk '{print $2}' || echo "未知")
            log "    pip: $pip_version" "info"
        fi
    else
        log "  ✗ Python: 未配置" "warn"
    fi
    
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
    
    check_dependencies
    echo
    
    install_mise
    echo
    
    # 修复：确保只有版本号被捕获
    local python_version
    python_version=$(select_python_version)
    
    if [[ "$python_version" != "skip" ]]; then
        setup_python "$python_version"
        echo
        
        setup_system_python_links
        echo
        
        install_common_packages
        echo
    else
        log "跳过 Python 配置" "info"
        echo
    fi
    
    setup_shell_integration
    
    show_mise_summary
    
    log "🎉 Mise 配置完成!" "info"
    log "💡 使用提示:" "info"
    log "  查看工具: mise list" "info"
    log "  安装工具: mise install node@20" "info"
    log "  设置版本: mise use python@3.12" "info"
}

main "$@"
