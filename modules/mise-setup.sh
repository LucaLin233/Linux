#!/bin/bash
# Mise 版本管理器配置模块 v5.4 - 修正版
# 功能: 安装Mise、智能选择Python版本、Shell集成、智能链接管理、自动修复系统模块

set -euo pipefail

# === 错误追踪 ===
trap 'echo "❌ 脚本在第 $LINENO 行失败" >&2; exit 1' ERR

# === 常量定义 ===
readonly MISE_PATH="$HOME/.local/bin/mise"
readonly MISE_BIN_DIR="$HOME/.local/bin"

# === 日志函数 ===
log() {
    local msg="$1" level="${2:-info}"
    local -A colors=([info]="\033[0;36m" [warn]="\033[0;33m" [error]="\033[0;31m")
    echo -e "${colors[$level]:-\033[0;32m}$msg\033[0m"
}

# === 系统诊断和修复函数 ===

# 诊断系统包管理状态
diagnose_apt_system() {
    local broken_packages=""
    broken_packages=$(dpkg -l | grep -E '^[hi] [^i]|^.[^i]' | wc -l 2>/dev/null || echo "0")
    
    if [[ "$broken_packages" -gt 0 ]]; then
        return 1
    fi
    
    if [[ -f /var/lib/dpkg/lock-frontend ]] || [[ -f /var/lib/apt/lists/lock ]]; then
        if lsof /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || lsof /var/lib/apt/lists/lock >/dev/null 2>&1; then
            return 1
        fi
    fi
    
    if ! which python3 &>/dev/null || [[ ! -x /usr/bin/python3 ]]; then
        return 1
    fi
    
    return 0
}

# 修复dpkg状态
fix_dpkg_state() {
    if timeout 30 sudo dpkg --configure -a >/dev/null 2>&1; then
        return 0
    fi
    
    if timeout 45 sudo DEBIAN_FRONTEND=noninteractive apt-get -f install -y >/dev/null 2>&1; then
        return 0
    fi
    
    return 1
}

# 检测系统Python状态
detect_system_python() {
    local system_python_paths=(
        "/usr/bin/python3"
        "/usr/bin/python3.11"
        "/usr/bin/python3.10" 
        "/usr/bin/python3.9"
        "/usr/bin/python3.12"
    )
    
    for python_path in "${system_python_paths[@]}"; do
        if [[ -x "$python_path" ]]; then
            echo "$python_path"
            return 0
        fi
    done
    
    return 1
}

# 确保系统Python可用
ensure_system_python() {
    local system_python=""
    if system_python=$(detect_system_python); then
        if [[ ! -e "/usr/bin/python3" ]] && [[ "$system_python" != "/usr/bin/python3" ]]; then
            sudo ln -sf "$system_python" /usr/bin/python3 2>/dev/null || return 1
        fi
        return 0
    else
        if command -v apt &>/dev/null; then
            if timeout 120 sudo DEBIAN_FRONTEND=noninteractive apt update -qq && timeout 120 sudo DEBIAN_FRONTEND=noninteractive apt install -y python3 python3-apt python3-debconf >/dev/null 2>&1; then
                return 0
            fi
        fi
        return 1
    fi
}

# 检测当前Python链接状态 - 改进版本
detect_python_status() {
    if ! ensure_system_python; then
        return 1
    fi
    
    local link_status="正常" path_priority="正常" is_hijacked=false
    
    # 检查系统链接是否被直接劫持
    if [[ -L /usr/bin/python3 ]]; then
        local python3_target
        python3_target=$(readlink /usr/bin/python3 2>/dev/null || echo "")
        if [[ -n "$python3_target" && "$python3_target" == *"mise"* ]]; then
            link_status="劫持"
            is_hijacked=true
        fi
    fi
    
    # 检查PATH优先级 - 更智能的检测
    local which_python_clean which_python_current
    
    # 使用干净的PATH检查系统优先级
    which_python_clean=$(PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" which python3 2>/dev/null || echo "")
    # 使用当前PATH检查
    which_python_current=$(which python3 2>/dev/null || echo "")
    
    # 如果当前PATH和干净PATH指向不同位置，且当前指向mise，才认为被劫持
    if [[ "$which_python_current" == *"mise"* ]] && [[ "$which_python_clean" != "$which_python_current" ]]; then
        # 进一步检查：如果只是因为mise shell集成导致的，不算劫持
        # 检查是否是通过mise activate产生的临时效果
        if [[ -n "$MISE_SHELL" ]] || command -v mise >/dev/null && mise current python >/dev/null 2>&1; then
            # 这是正常的mise集成，不是劫持
            path_priority="mise集成"
        else
            # 这是真正的PATH劫持
            path_priority="劫持"
            is_hijacked=true
        fi
    fi
    
    echo "Python状态: 链接($link_status) PATH($path_priority)" >&2
    
    # 只有在真正被劫持时才返回0（需要修复）
    if $is_hijacked && [[ ! "${1:-}" == "allow_global" ]]; then
        return 0  # 需要修复
    else
        return 1  # 状态正常
    fi
}

# 智能的系统模块修复
fix_system_modules() {
    if /usr/bin/python3 -c "import apt_pkg; import debconf" >/dev/null 2>&1; then
        return 0
    fi
    
    # 尝试修复系统状态
    if ! diagnose_apt_system; then
        fix_dpkg_state || true
        if /usr/bin/python3 -c "import apt_pkg; import debconf" >/dev/null 2>&1; then
            return 0
        fi
    fi
    
    # 重装系统模块
    sudo apt clean >/dev/null 2>&1 || true
    if timeout 60 sudo DEBIAN_FRONTEND=noninteractive apt update >/dev/null 2>&1; then
        timeout 60 sudo DEBIAN_FRONTEND=noninteractive apt install --reinstall -y python3-apt python3-debconf >/dev/null 2>&1 || true
    fi
    
    # 强制重装python3包
    local python_packages=("python3-minimal" "python3" "python3-apt" "python3-debconf")
    for pkg in "${python_packages[@]}"; do
        timeout 30 sudo DEBIAN_FRONTEND=noninteractive apt install --reinstall -y "$pkg" >/dev/null 2>&1 || true
    done
    
    if /usr/bin/python3 -c "import apt_pkg; import debconf" >/dev/null 2>&1; then
        return 0
    else
        echo "系统模块修复: 部分成功，不影响mise正常使用"
        return 1
    fi
}

# 修复系统Python链接和PATH
fix_python_system_priority() {
    if ! ensure_system_python; then
        log "✗ 无法确保系统Python可用" "error"
        return 1
    fi
    
    # 修复系统链接
    if [[ -L /usr/bin/python3 ]]; then
        local python3_target
        python3_target=$(readlink /usr/bin/python3 2>/dev/null || echo "")
        if [[ -n "$python3_target" && "$python3_target" == *"mise"* ]]; then
            sudo cp -L /usr/bin/python3 /usr/bin/python3.mise.backup 2>/dev/null || true
            sudo rm /usr/bin/python3 2>/dev/null || true
            local system_python=""
            if system_python=$(detect_system_python); then
                sudo ln -sf "$system_python" /usr/bin/python3
            fi
        fi
    fi
    
    # 修复PATH配置
    configure_safe_path_priority
    
    # 立即应用修复
    export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$HOME/.local/bin"
    hash -r 2>/dev/null || true
    
    # 修复系统模块
    fix_system_modules >/dev/null 2>&1 || true
    
    echo "系统Python优先级: 已修复"
}

# 安全的PATH配置
configure_safe_path_priority() {
    local shells=("bash:$HOME/.bashrc" "zsh:$HOME/.zshrc")
    
    for shell_info in "${shells[@]}"; do
        local shell_name="${shell_info%%:*}"
        local config_file="${shell_info#*:}"
        
        if ! command -v "$shell_name" &>/dev/null; then
            continue
        fi
        
        [[ ! -f "$config_file" ]] && touch "$config_file"
        cp "$config_file" "${config_file}.mise.backup" 2>/dev/null || true
        
        sed -i '/# Mise PATH priority/,+1d' "$config_file" 2>/dev/null || true
        sed -i '/# Mise global mode PATH/,+1d' "$config_file" 2>/dev/null || true
        
        cat >> "$config_file" << 'EOF'

# Mise PATH priority - 确保系统工具使用系统Python
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$HOME/.local/bin"
EOF
    done
}

# 配置全局模式的PATH
configure_path_for_global_mode() {
    local shells=("bash:$HOME/.bashrc" "zsh:$HOME/.zshrc")
    
    for shell_info in "${shells[@]}"; do
        local shell_name="${shell_info%%:*}"
        local config_file="${shell_info#*:}"
        
        if ! command -v "$shell_name" &>/dev/null; then
            continue
        fi
        
        [[ ! -f "$config_file" ]] && touch "$config_file"
        
        sed -i '/# Mise PATH priority/,+1d' "$config_file" 2>/dev/null || true
        sed -i '/# Mise global mode PATH/,+1d' "$config_file" 2>/dev/null || true
        
        cat >> "$config_file" << 'EOF'

# Mise global mode PATH - mise Python 优先
export PATH="$HOME/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
EOF
    done
    
    export PATH="$HOME/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    hash -r 2>/dev/null || true
}

# === 核心功能函数 ===

# 获取Mise版本
get_mise_version() {
    local version_output
    version_output=$("$MISE_PATH" --version 2>/dev/null || echo "")
    if [[ "$version_output" =~ v?([0-9]+\.[0-9]+\.[0-9]+) ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo "未知"
    fi
}

# 安装或更新Mise
install_mise() {
    mkdir -p "$MISE_BIN_DIR"
    
    if [[ -f "$MISE_PATH" ]]; then
        local mise_version
        mise_version=$(get_mise_version)
        echo "Mise状态: 已安装 v$mise_version"
        
        read -p "是否更新到最新版本? [y/N]: " -r update_choice
        if [[ "$update_choice" =~ ^[Yy]$ ]]; then
            if curl -fsSL https://mise.run | sh >/dev/null 2>&1; then
                echo "Mise更新: 成功"
            else
                echo "Mise更新: 失败，继续使用现有版本"
            fi
        fi
    else
        echo "安装Mise中..."
        if curl -fsSL https://mise.run | sh >/dev/null 2>&1; then
            echo "Mise安装: 成功"
        else
            log "✗ Mise安装失败" "error"
            exit 1
        fi
    fi
    
    if [[ ! -f "$MISE_PATH" ]]; then
        log "✗ 安装验证失败" "error"
        exit 1
    fi
}

# 获取最新的三个Python主版本
get_top3_python_versions() {
    local default_versions=("3.11.9" "3.12.4" "3.13.0")
    local versions_output=""
    local major_versions=""
    local final_versions=()
    
    if ! versions_output=$("$MISE_PATH" ls-remote python 2>/dev/null); then
        printf '%s\n' "${default_versions[@]}"
        return
    fi
    
    if ! major_versions=$(echo "$versions_output" | grep -E "^[0-9]+\.[0-9]+\.[0-9]+$" | sed -E 's/^([0-9]+\.[0-9]+)\.[0-9]+$/\1/' | sort -V -u | tail -3 2>/dev/null); then
        printf '%s\n' "${default_versions[@]}"
        return
    fi
    
    while IFS= read -r major; do
        if [[ -n "$major" ]]; then
            local latest_patch=""
            if latest_patch=$(echo "$versions_output" | grep -E "^${major}\.[0-9]+$" | sort -V | tail -1 2>/dev/null); then
                if [[ -n "$latest_patch" ]]; then
                    final_versions+=("$latest_patch")
                fi
            fi
        fi
    done <<< "$major_versions"
    
    if [[ ${#final_versions[@]} -eq 0 ]]; then
        printf '%s\n' "${default_versions[@]}"
    else
        printf '%s\n' "${final_versions[@]}"
    fi
}

# 让用户选择Python版本 - 修正版本
choose_python_version() {
    local versions=()
    local version_output=""
    
    version_output=$(get_top3_python_versions)
    
    if [[ -n "$version_output" ]]; then
        while IFS= read -r line; do
            [[ -n "$line" ]] && versions+=("$line")
        done <<< "$version_output"
    fi
    
    if [[ ${#versions[@]} -eq 0 ]]; then
        versions=("3.11.9" "3.12.4" "3.13.0")
    fi
    
    local latest_version=""
    latest_version=$("$MISE_PATH" latest python 2>/dev/null || echo "")
    
    # 所有菜单输出重定向到stderr，确保用户能看到
    echo >&2
    echo "Python版本选择:" >&2
    for i in "${!versions[@]}"; do
        local version="${versions[$i]}"
        local label=""
        [[ -n "$latest_version" && "$version" == "$latest_version" ]] && label=" (latest)"
        echo "  $((i+1))) Python $version$label" >&2
    done
    echo "  4) 保持当前配置" >&2
    echo >&2
    
    local choice=""
    read -p "请选择 [1-4] (默认: 2): " choice >&2
    choice=${choice:-2}
    
    # 只返回结果到stdout，不包含其他输出
    case "$choice" in
        1|2|3) 
            local idx=$((choice-1))
            if [[ $idx -lt ${#versions[@]} ]]; then
                echo "${versions[$idx]}"
            else
                echo "3.12.4"
            fi
            ;;
        4) echo "current" ;;
        *) echo "3.12.4" ;;
    esac
}

# 获取已安装的Python版本列表
get_installed_python_versions() {
    "$MISE_PATH" ls python 2>/dev/null | awk '/^python/ {print $2}' | grep -E "^[0-9]+\.[0-9]+\.[0-9]+$" 2>/dev/null || true
}

# 清理旧版本Python
cleanup_old_python_versions() {
    local current_version="$1"
    local installed_versions=""
    
    installed_versions=$(get_installed_python_versions)
    if [[ -n "$installed_versions" ]]; then
        installed_versions=$(echo "$installed_versions" | grep -v "^$current_version$" || true)
    fi
    
    if [[ -n "$installed_versions" ]]; then
        echo
        echo "检测到其他Python版本:"
        echo "$installed_versions" | sed 's/^/  - Python /'
        
        read -p "是否删除其他版本? [y/N]: " -r cleanup_choice
        if [[ "$cleanup_choice" =~ ^[Yy]$ ]]; then
            while IFS= read -r version; do
                if [[ -n "$version" ]]; then
                    if "$MISE_PATH" uninstall "python@$version" >/dev/null 2>&1; then
                        echo "Python $version: 已删除"
                    else
                        echo "Python $version: 删除失败"
                    fi
                fi
            done <<< "$installed_versions"
        fi
    fi
}

# 配置Python - 修正版本
setup_python() {
    local current_version=""
    current_version=$("$MISE_PATH" current python 2>/dev/null || echo "")
    [[ -n "$current_version" ]] && echo "当前Python: $current_version"
    
    local selected_version=""
    selected_version=$(choose_python_version)
    
    # 修正：正确处理"current"选择
    if [[ "$selected_version" == "current" ]]; then
        echo "Python配置: 保持当前"
        return 0
    fi
    
    echo "安装Python $selected_version..."
    if "$MISE_PATH" use -g "python@$selected_version" >/dev/null 2>&1; then
        echo "Python $selected_version: 安装成功"
        cleanup_old_python_versions "$selected_version"
        return 0
    else
        log "✗ Python $selected_version 安装失败" "error"
        return 1
    fi
}

# 创建全局Python链接
link_python_globally() {
    local python_path=""
    python_path=$("$MISE_PATH" which python 2>/dev/null || echo "")
    
    if [[ -x "$python_path" ]]; then
        if [[ -L /usr/bin/python3 ]]; then
            sudo cp -L /usr/bin/python3 /usr/bin/python3.backup 2>/dev/null || true
        fi
        if [[ -e /usr/bin/python ]]; then
            sudo cp -L /usr/bin/python /usr/bin/python.backup 2>/dev/null || true
        fi
        
        sudo ln -sf "$python_path" /usr/bin/python
        sudo ln -sf "$python_path" /usr/bin/python3
        
        echo "全局Python链接: 已创建"
        echo "  /usr/bin/python -> $python_path"
        echo "  /usr/bin/python3 -> $python_path"
    else
        echo "全局Python链接: 失败，找不到mise Python"
    fi
}

# === 使用方式配置函数 ===

# 配置Python使用方式 - 改进版本
setup_python_usage() {
    echo
    local needs_fix=1
    if detect_python_status >/dev/null 2>&1; then
        needs_fix=0
    else
        needs_fix=1
    fi
    
    echo "Python使用方式:"
    echo "  1) 项目级使用 (推荐) - 系统工具用系统Python，项目用mise"
    echo "  2) 全局替换 - ⚠️ mise成为系统默认，可能影响apt等工具"
    
    # 只有在真正需要修复时才显示修复选项
    if [[ $needs_fix -eq 0 ]]; then
        echo "  3) 修复系统配置 - 🔧 检测到系统被劫持，推荐立即修复"
    fi
    echo
    
    local usage_choice=""
    local default_choice=1
    [[ $needs_fix -eq 0 ]] && default_choice=3
    
    local max_choice=2
    [[ $needs_fix -eq 0 ]] && max_choice=3
    
    read -p "请选择 [1-$max_choice] (默认: $default_choice): " -r usage_choice
    usage_choice=${usage_choice:-$default_choice}
    
    case "$usage_choice" in
        1)
            echo "配置模式: 项目级使用"
            # 如果检测到需要修复，先修复
            if [[ $needs_fix -eq 0 ]]; then
                fix_python_system_priority
            fi
            echo
            echo "使用指南:"
            echo "  • 系统级: 自动使用系统Python"
            echo "  • 项目级: cd project && mise use python@3.12.4"
            echo "  • 临时使用: mise exec python@3.12.4 -- python script.py"
            ;;
        2)
            echo
            log "⚠️ 警告: 全局替换会影响系统工具！" "warn"
            read -p "确认继续? [y/N]: " -r confirm_choice
            if [[ "$confirm_choice" =~ ^[Yy]$ ]]; then
                echo "配置模式: 全局替换"
                link_python_globally
                configure_path_for_global_mode
                echo "重要: 如遇系统工具报错，重新运行脚本选择修复"
            else
                echo "配置模式: 改为项目级使用"
                fix_python_system_priority
            fi
            ;;
        3)
            if [[ $needs_fix -eq 0 ]]; then
                echo "执行系统修复..."
                fix_python_system_priority
            else
                echo "配置模式: 项目级使用"
                fix_python_system_priority
            fi
            ;;
        *)
            echo "配置模式: 项目级使用"
            if [[ $needs_fix -eq 0 ]]; then
                fix_python_system_priority
            fi
            ;;
    esac
}

# 配置Shell集成
configure_shell_integration() {
    local shells=(
        "bash:$HOME/.bashrc:eval \"\$(\$HOME/.local/bin/mise activate bash)\""
        "zsh:$HOME/.zshrc:eval \"\$(mise activate zsh)\""
    )
    
    for shell_info in "${shells[@]}"; do
        local shell_name="${shell_info%%:*}"
        local config_file="${shell_info#*:}"
        config_file="${config_file%%:*}"
        local activate_cmd="${shell_info##*:}"
        
        command -v "$shell_name" &>/dev/null || continue
        [[ ! -f "$config_file" ]] && touch "$config_file"
        
        if grep -q "mise activate $shell_name" "$config_file" 2>/dev/null; then
            echo "$shell_name集成: 已存在"
        else
            if [[ "$shell_name" == "bash" ]]; then
                echo -e "\n# Mise version manager\n$activate_cmd" >> "$config_file"
            else
                if grep -q "# mise 版本管理器配置" "$config_file" 2>/dev/null; then
                    sed -i "/# mise 版本管理器配置/a $activate_cmd" "$config_file" 2>/dev/null || true
                else
                    echo -e "\n# Mise version manager\n$activate_cmd" >> "$config_file"
                fi
            fi
            echo "$shell_name集成: 已配置"
        fi
    done
}

# 显示配置摘要
show_mise_summary() {
    echo
    log "🎯 Mise配置摘要:" "info"
    
    if [[ -f "$MISE_PATH" ]]; then
        local mise_version=""
        mise_version=$(get_mise_version)
        echo "  Mise: v$mise_version"
        
        if "$MISE_PATH" which python &>/dev/null; then
            local current_version=""
            current_version=$("$MISE_PATH" current python 2>/dev/null || echo "未知")
            echo "  Mise Python: $current_version"
        else
            echo "  Mise Python: 未配置"
        fi
        
        local system_python_version=""
        system_python_version=$(/usr/bin/python3 --version 2>/dev/null || echo "无法获取")
        echo "  系统Python: $system_python_version"
        
        local which_python=""
        which_python=$(which python3 2>/dev/null || echo "")
        if [[ "$which_python" == *"mise"* ]]; then
            echo "  当前优先: mise Python"
        elif [[ "$which_python" == "/usr/bin/python3" ]]; then
            echo "  当前优先: 系统Python (推荐)"
        else
            echo "  当前优先: 异常状态"
        fi
        
        local apt_pkg_ok=false
        local debconf_ok=false
        if python3 -c "import apt_pkg" &>/dev/null 2>&1; then apt_pkg_ok=true; fi
        if python3 -c "import debconf" &>/dev/null 2>&1; then debconf_ok=true; fi
        
        if $apt_pkg_ok && $debconf_ok; then
            echo "  系统模块: 正常"
        else
            echo "  系统模块: 部分异常 (不影响mise使用)"
        fi
    else
        echo "  Mise: 未安装"
    fi
    
    if grep -q "mise activate" "$HOME/.bashrc" 2>/dev/null; then
        echo "  Bash集成: 已配置"
    fi
    if [[ -f "$HOME/.zshrc" ]] && grep -q "mise activate" "$HOME/.zshrc" 2>/dev/null; then
        echo "  Zsh集成: 已配置"
    fi
}

# === 主流程 ===
main() {
    log "🔧 配置Mise版本管理器..." "info"
    
    echo
    if [[ -f "$MISE_PATH" ]]; then
        detect_python_status >/dev/null 2>&1 || true
    fi
    
    install_mise
    
    echo
    if setup_python; then
        :
    else
        echo "Python配置失败，但继续执行..."
    fi
    
    setup_python_usage
    
    echo
    configure_shell_integration
    
    show_mise_summary
    
    echo
    log "✅ Mise配置完成!" "info"
    log "提示: 运行 'source ~/.bashrc' 或重新登录激活" "info"
    
    if [[ -f "$MISE_PATH" ]]; then
        echo
        log "常用命令:" "info"
        echo "  查看工具: mise list"
        echo "  项目使用: mise use python@3.12.4"
        echo "  全局设置: mise use -g python@3.12.4"
        echo "  查看当前: mise current"
    fi
}

main "$@"
