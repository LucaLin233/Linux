#!/bin/bash
# Mise 版本管理器配置模块 v5.2
# 功能: 安装Mise、智能选择Python版本、Shell集成、智能链接管理、自动修复系统模块
# 专业版本：完整的Debian/Ubuntu系统Mise配置解决方案（增强修复版）

set -euo pipefail

# === 错误追踪 ===
trap 'echo "❌ 脚本在第 $LINENO 行失败，命令: $BASH_COMMAND" >&2; exit 1' ERR

# === 常量定义 ===
readonly MISE_PATH="$HOME/.local/bin/mise"
readonly MISE_BIN_DIR="$HOME/.local/bin"

# === 日志函数 ===
log() {
    local msg="$1" level="${2:-info}"
    local -A colors=([info]="\033[0;36m" [warn]="\033[0;33m" [error]="\033[0;31m")
    echo -e "${colors[$level]:-\033[0;32m}$msg\033[0m" >&2
}

# === 系统诊断和修复函数 ===

# 诊断系统包管理状态
diagnose_apt_system() {
    log "🔍 诊断系统包管理状态..." "info"
    
    # 1. 检查dpkg状态
    local broken_packages=""
    broken_packages=$(dpkg -l | grep -E '^[hi] [^i]|^.[^i]' | wc -l 2>/dev/null || echo "0")
    if [[ "$broken_packages" -gt 0 ]]; then
        log "⚠️ 发现 $broken_packages 个异常包状态" "warn"
        dpkg -l | grep -E '^[hi] [^i]|^.[^i]' | head -5 || true
    fi
    
    # 2. 检查apt锁
    if [[ -f /var/lib/dpkg/lock-frontend ]] || [[ -f /var/lib/apt/lists/lock ]]; then
        if lsof /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || lsof /var/lib/apt/lists/lock >/dev/null 2>&1; then
            log "⚠️ 检测到apt进程锁，可能有其他apt进程在运行" "warn"
            return 1
        fi
    fi
    
    # 3. 检查python3链接状态
    local python3_issues=""
    if ! which python3 &>/dev/null; then
        python3_issues+="python3命令不可用; "
    fi
    
    if [[ ! -x /usr/bin/python3 ]]; then
        python3_issues+="/usr/bin/python3不存在或不可执行; "
    fi
    
    if [[ -n "$python3_issues" ]]; then
        log "⚠️ Python3问题: $python3_issues" "warn"
        return 1
    fi
    
    return 0
}

# 修复dpkg状态
fix_dpkg_state() {
    log "🔧 修复dpkg状态..." "info"
    
    # 1. 尝试配置所有未完成的包
    if timeout 30 sudo dpkg --configure -a >/dev/null 2>&1; then
        log "✓ dpkg状态修复成功" "info"
        return 0
    fi
    
    # 2. 尝试修复依赖
    if timeout 45 sudo DEBIAN_FRONTEND=noninteractive apt-get -f install -y >/dev/null 2>&1; then
        log "✓ 依赖问题修复成功" "info"
        return 0
    fi
    
    log "⚠️ dpkg状态修复超时，但继续执行" "warn"
    return 1
}

# 检测系统Python状态
detect_system_python() {
    # 检查常见的系统Python位置
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
        log "✓ 发现系统Python: $system_python" "info"
        
        # 如果/usr/bin/python3不存在但有其他版本，创建链接
        if [[ ! -e "/usr/bin/python3" ]] && [[ "$system_python" != "/usr/bin/python3" ]]; then
            log "创建系统Python3链接..." "info"
            sudo ln -sf "$system_python" /usr/bin/python3 2>/dev/null || {
                log "✗ 无法创建系统Python链接，可能需要手动安装python3" "error"
                return 1
            }
        fi
        return 0
    else
        log "✗ 未找到系统Python，正在安装..." "warn"
        
        # 尝试安装python3
        if command -v apt &>/dev/null; then
            log "安装 python3..." "info"
            if timeout 120 sudo DEBIAN_FRONTEND=noninteractive apt update -qq && timeout 120 sudo DEBIAN_FRONTEND=noninteractive apt install -y python3 python3-apt python3-debconf; then
                log "✓ Python3 安装完成" "info"
                return 0
            else
                log "✗ Python3 安装失败或超时" "error"
                return 1
            fi
        else
            log "✗ 无法安装Python3，请手动安装" "error"
            return 1
        fi
    fi
}

# 检测当前Python链接状态
detect_python_status() {
    local status_info="" link_status="正常"
    
    # 首先确保系统Python存在
    if ! ensure_system_python; then
        log "⚠️ 系统Python配置异常，请手动修复后重试" "error"
        return 1
    fi
    
    # 检查系统链接
    if [[ -L /usr/bin/python3 ]]; then
        local python3_target
        python3_target=$(readlink /usr/bin/python3 2>/dev/null || echo "")
        
        if [[ -n "$python3_target" ]]; then
            if [[ "$python3_target" == *"mise"* ]]; then
                status_info="系统链接被mise劫持"
                link_status="劫持"
            else
                status_info="使用系统Python链接"
            fi
        else
            status_info="链接损坏"
            link_status="异常"
        fi
    elif [[ -f /usr/bin/python3 ]]; then
        status_info="直接使用系统Python文件"
    else
        status_info="无python3链接"
        link_status="异常"
    fi
    
    # 检查PATH优先级
    local which_python
    which_python=$(which python3 2>/dev/null || echo "")
    
    local path_status="" path_priority="正常"
    
    if [[ -n "$which_python" ]]; then
        if [[ "$which_python" == *"mise"* ]]; then
            path_status="PATH中mise Python优先"
            path_priority="劫持"
        elif [[ "$which_python" == "/usr/bin/python3" ]]; then
            path_status="PATH中系统Python优先"
        else
            path_status="PATH配置异常: $which_python"
            path_priority="异常"
        fi
    else
        path_status="未找到python3"
        path_priority="异常"
    fi
    
    log "🔍 当前Python状态:" "info"
    log "  系统链接: $status_info" "info"  
    log "  PATH优先: $path_status" "info"
    
    # 获取版本信息
    local current_python_version
    current_python_version=$(python3 --version 2>/dev/null || echo '无法获取版本')
    local system_python_version
    system_python_version=$(/usr/bin/python3 --version 2>/dev/null || echo '系统Python不可用')
    log "  当前版本: $current_python_version" "info"
    log "  系统Python: $system_python_version" "info"
    
    # 检查系统模块可用性
    local apt_pkg_status="不可用 ✗"
    local debconf_status="不可用 ✗"
    
    if /usr/bin/python3 -c "import apt_pkg" >/dev/null 2>&1; then
        apt_pkg_status="可用 ✓"
    fi
    
    if /usr/bin/python3 -c "import debconf" >/dev/null 2>&1; then
        debconf_status="可用 ✓"
    fi
    
    log "  系统模块: apt_pkg $apt_pkg_status, debconf $debconf_status" "info"
    
    # 返回是否需要修复
    if [[ "$link_status" == "劫持" || "$path_priority" == "劫持" ]] && [[ ! "${1:-}" == "allow_global" ]]; then
        return 0  # 需要修复
    else
        return 1  # 状态正常
    fi
}

# 智能的系统模块修复（多策略）
fix_system_modules() {
    local apt_pkg_ok=false
    local debconf_ok=false
    
    # 检查模块状态
    if /usr/bin/python3 -c "import apt_pkg" >/dev/null 2>&1; then
        apt_pkg_ok=true
    fi
    
    if /usr/bin/python3 -c "import debconf" >/dev/null 2>&1; then
        debconf_ok=true
    fi
    
    # 如果模块都正常，直接返回
    if $apt_pkg_ok && $debconf_ok; then
        return 0
    fi
    
    log "🔧 检测到系统模块缺失，正在智能修复..." "warn"
    
    # 策略1: 诊断并修复基础系统状态
    if ! diagnose_apt_system; then
        log "发现系统问题，尝试修复..." "info"
        fix_dpkg_state || true
        
        # 再次检查模块
        if /usr/bin/python3 -c "import apt_pkg" >/dev/null 2>&1 && /usr/bin/python3 -c "import debconf" >/dev/null 2>&1; then
            log "✓ 系统修复后模块可用" "info"
            return 0
        fi
    fi
    
    # 策略2: 清理apt缓存并重装
    log "清理apt缓存..." "info"
    sudo apt clean >/dev/null 2>&1 || true
    
    if timeout 60 sudo DEBIAN_FRONTEND=noninteractive apt update >/dev/null 2>&1; then
        if timeout 60 sudo DEBIAN_FRONTEND=noninteractive apt install --reinstall -y python3-apt python3-debconf >/dev/null 2>&1; then
            log "✓ 系统模块重装成功" "info"
            return 0
        fi
    fi
    
    # 策略3: 强制重装相关python3包
    log "尝试强制修复python3相关包..." "info"
    local python_packages=("python3-minimal" "python3" "python3-apt" "python3-debconf")
    
    for pkg in "${python_packages[@]}"; do
        if timeout 30 sudo DEBIAN_FRONTEND=noninteractive apt install --reinstall -y "$pkg" >/dev/null 2>&1; then
            log "✓ $pkg 重装成功" "info"
        fi
    done
    
    # 最终检查
    if /usr/bin/python3 -c "import apt_pkg; import debconf" >/dev/null 2>&1; then
        log "✓ 系统模块最终修复成功" "info"
        return 0
    fi
    
    # 策略4: 提供详细的手动修复指导
    log "⚠️ 自动修复未完全成功，提供手动修复方案" "warn"
    log "  这不影响mise的正常使用，只是系统包管理可能有问题" "info"
    echo
    log "🔧 手动修复步骤：" "info"
    log "  1. sudo dpkg --configure -a" "info"
    log "  2. sudo apt-get -f install" "info"
    log "  3. sudo apt update && sudo apt upgrade" "info"
    log "  4. sudo apt install --reinstall python3-apt python3-debconf" "info"
    echo
    
    return 1
}

# 修复系统Python链接和PATH（增强安全版）
fix_python_system_priority() {
    log "🔧 修复系统Python优先级..." "info"
    
    # 首先确保系统Python存在
    if ! ensure_system_python; then
        log "✗ 无法确保系统Python可用，跳过修复" "error"
        return 1
    fi
    
    # 修复系统链接（如果被劫持）
    if [[ -L /usr/bin/python3 ]]; then
        local python3_target
        python3_target=$(readlink /usr/bin/python3 2>/dev/null || echo "")
        
        if [[ -n "$python3_target" && "$python3_target" == *"mise"* ]]; then
            log "修复被劫持的系统Python链接..." "info"
            
            # 先备份
            sudo cp -L /usr/bin/python3 /usr/bin/python3.mise.backup 2>/dev/null || true
            sudo rm /usr/bin/python3 2>/dev/null || true
            
            # 寻找合适的系统Python版本并链接
            local system_python=""
            if system_python=$(detect_system_python); then
                sudo ln -sf "$system_python" /usr/bin/python3
                log "✓ 已恢复系统Python链接: $system_python" "info"
            else
                log "✗ 未找到合适的系统Python版本" "error"
                return 1
            fi
        fi
    fi
    
    # 修复PATH配置（更安全的方法）
    configure_safe_path_priority
    
    # 验证修复结果
    local new_which_python
    new_which_python=$(PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$HOME/.local/bin" which python3 2>/dev/null || echo "")
    
    if [[ "$new_which_python" == "/usr/bin/python3" ]]; then
        log "✓ PATH优先级修复成功" "info"
        
        # 在新PATH环境中测试系统python
        if PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$HOME/.local/bin" python3 --version >/dev/null 2>&1; then
            # 立即应用修复的PATH
            export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$HOME/.local/bin"
            hash -r 2>/dev/null || true
            log "✓ PATH修复立即生效" "info"
            
            # 智能的系统模块修复
            fix_system_modules || {
                log "系统模块修复未完全成功，但不影响mise正常使用" "info"
            }
            
            # 验证系统模块
            local modules_ok=true
            if python3 -c "import apt_pkg" &>/dev/null 2>&1; then
                log "✓ 系统模块现在可用" "info"
            else
                modules_ok=false
            fi
            
            if python3 -c "import debconf" &>/dev/null 2>&1; then
                log "✓ debconf模块现在可用" "info"
            else
                modules_ok=false
            fi
            
            if ! $modules_ok; then
                log "💡 虽然部分系统模块仍有问题，但这不影响mise的正常使用" "info"
                log "   系统包管理功能可能受限，如需修复请参考上面的手动步骤" "info"
            fi
        else
            log "⚠️ 修复后的PATH中Python3仍有问题" "warn"
        fi
    else
        log "⚠️ PATH修复异常，当前指向：$new_which_python" "warn"
        log "手动修复命令: export PATH=\"/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:\$HOME/.local/bin\"" "info"
    fi
    
    # 显示当前状态
    echo
    log "修复后状态:" "info"
    local link_target
    if [[ -L /usr/bin/python3 ]]; then
        link_target=$(readlink /usr/bin/python3 2>/dev/null || echo '链接异常')
    else
        link_target='直接文件'
    fi
    log "  系统链接: $link_target" "info"
    
    local current_python3
    current_python3=$(which python3 2>/dev/null || echo "未找到")
    log "  当前python3: $current_python3" "info"
    
    if [[ "$current_python3" != "未找到" ]]; then
        local python_version
        python_version=$(python3 --version 2>/dev/null || echo "无法获取版本")
        log "  版本: $python_version" "info"
    fi
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
        
        # 备份配置文件
        cp "$config_file" "${config_file}.mise.backup" 2>/dev/null || true
        
        # 移除旧配置
        sed -i '/# Mise PATH priority/,+1d' "$config_file" 2>/dev/null || true
        sed -i '/# Mise global mode PATH/,+1d' "$config_file" 2>/dev/null || true
        
        # 添加安全的PATH配置
        cat >> "$config_file" << 'EOF'

# Mise PATH priority - 确保系统工具使用系统Python
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$HOME/.local/bin"
EOF
        log "✓ 已配置 $shell_name PATH优先级" "info"
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
        
        # 移除旧配置
        sed -i '/# Mise PATH priority/,+1d' "$config_file" 2>/dev/null || true
        sed -i '/# Mise global mode PATH/,+1d' "$config_file" 2>/dev/null || true
        
        # 为全局模式配置不同的PATH（mise优先）
        cat >> "$config_file" << 'EOF'

# Mise global mode PATH - mise Python 优先
export PATH="$HOME/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
EOF
        log "✓ 已配置 $shell_name 全局模式PATH" "info"
    done
    
    # 立即应用全局模式PATH
    log "立即应用全局模式PATH..." "info"
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

# 获取Python版本
get_python_version() {
    local python_path
    python_path=$("$MISE_PATH" which python 2>/dev/null || echo "")
    
    if [[ -x "$python_path" ]]; then
        local version
        version=$("$python_path" --version 2>/dev/null || echo "")
        echo "$version"
    else
        local version
        version=$("$MISE_PATH" exec python -- --version 2>/dev/null || echo "版本获取失败")
        echo "$version"
    fi
}

# 安装或更新Mise
install_mise() {
    log "检查并安装 Mise..." "info"
    mkdir -p "$MISE_BIN_DIR"
    
    if [[ -f "$MISE_PATH" ]]; then
        local mise_version
        mise_version=$(get_mise_version)
        log "Mise 已安装 (版本: $mise_version)" "info"
        
        echo
        read -p "是否更新 Mise 到最新版本? [y/N] (默认: N): " -r update_choice || update_choice="N"
        if [[ "$update_choice" =~ ^[Yy]$ ]]; then
            log "更新 Mise..." "info"
            if curl -fsSL https://mise.run | sh; then
                log "✓ Mise 已更新" "info"
            else
                log "⚠️ Mise 更新失败，继续使用现有版本" "warn"
            fi
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
    
    if [[ ! -f "$MISE_PATH" ]]; then
        log "✗ 安装验证失败" "error"
        exit 1
    fi
}

# 获取最新的三个Python主版本
get_top3_python_versions() {
    # 设置默认版本
    local default_versions=("3.11.9" "3.12.4" "3.13.0")
    
    # 尝试获取远程版本
    local versions_output=""
    local major_versions=""
    local final_versions=()
    
    # 步骤1: 获取所有版本
    if ! versions_output=$("$MISE_PATH" ls-remote python 2>/dev/null); then
        printf '%s\n' "${default_versions[@]}"
        return
    fi
    
    # 步骤2: 提取主版本号
    if ! major_versions=$(echo "$versions_output" | grep -E "^[0-9]+\.[0-9]+\.[0-9]+$" | sed -E 's/^([0-9]+\.[0-9]+)\.[0-9]+$/\1/' | sort -V -u | tail -3 2>/dev/null); then
        printf '%s\n' "${default_versions[@]}"
        return
    fi
    
    # 步骤3: 获取每个主版本的最新patch版本
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
    
    # 验证结果并输出
    if [[ ${#final_versions[@]} -eq 0 ]]; then
        printf '%s\n' "${default_versions[@]}"
    else
        printf '%s\n' "${final_versions[@]}"
    fi
}

# 让用户选择Python版本
choose_python_version() {
    # 获取版本列表
    local versions=()
    local version_output=""
    
    version_output=$(get_top3_python_versions)
    
    if [[ -n "$version_output" ]]; then
        while IFS= read -r line; do
            [[ -n "$line" ]] && versions+=("$line")
        done <<< "$version_output"
    fi
    
    # 确保至少有默认版本
    if [[ ${#versions[@]} -eq 0 ]]; then
        versions=("3.11.9" "3.12.4" "3.13.0")
    fi
    
    # 尝试获取最新版本标记
    local latest_version=""
    latest_version=$("$MISE_PATH" latest python 2>/dev/null || echo "")
    
    # 显示选项
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
    read -p "请选择 [1-4] (默认: 2): " choice || choice="2"
    choice=${choice:-2}
    
    # 返回选择的版本
    case "$choice" in
        1|2|3) 
            local idx=$((choice-1))
            if [[ $idx -lt ${#versions[@]} ]]; then
                echo "${versions[$idx]}"
            else
                echo "3.12.4"
            fi
            ;;
        4) 
            echo "current" 
            ;;
        *) 
            echo "3.12.4" 
            ;;
    esac
}

# 获取已安装的Python版本列表
get_installed_python_versions() {
    local result
    result=$("$MISE_PATH" ls python 2>/dev/null | awk '/^python/ {print $2}' | grep -E "^[0-9]+\.[0-9]+\.[0-9]+$" 2>/dev/null || true)
    echo "$result"
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
        log "检测到其他Python版本:" "info"
        echo "$installed_versions" | sed 's/^/  - Python /'
        
        echo
        read -p "是否删除其他版本? [y/N] (默认: N): " -r cleanup_choice || cleanup_choice="N"
        
        if [[ "$cleanup_choice" =~ ^[Yy]$ ]]; then
            while IFS= read -r version; do
                if [[ -n "$version" ]]; then
                    log "删除 Python $version..." "info"
                    if "$MISE_PATH" uninstall "python@$version" 2>/dev/null; then
                        log "✓ Python $version 已删除" "info"
                    else
                        log "✗ 删除 Python $version 失败" "warn"
                    fi
                fi
            done <<< "$installed_versions"
        fi
    else
        log "没有其他Python版本需要清理" "info"
    fi
}

# 配置Python
setup_python() {
    log "配置 Python..." "info"
    
    local current_version=""
    current_version=$("$MISE_PATH" current python 2>/dev/null || echo "")
    [[ -n "$current_version" ]] && log "当前Python版本: $current_version" "info"
    
    local selected_version=""
    selected_version=$(choose_python_version)
    
    if [[ "$selected_version" == "current" ]]; then
        log "保持当前Python配置" "info"
        return 0
    fi
    
    log "安装 Python $selected_version..." "info"
    
    if "$MISE_PATH" use -g "python@$selected_version" 2>/dev/null; then
        log "✓ Python $selected_version 安装完成" "info"
        cleanup_old_python_versions "$selected_version" || true
    else
        log "✗ Python $selected_version 安装失败" "error"
        return 1
    fi
}

# 创建全局Python链接（仅在用户选择时调用）
link_python_globally_original() {
    log "创建系统Python链接..." "info"
    
    local python_path=""
    python_path=$("$MISE_PATH" which python 2>/dev/null || echo "")
    
    if [[ -x "$python_path" ]]; then
        # 备份现有系统Python链接
        if [[ -L /usr/bin/python3 ]]; then
            log "备份现有系统Python链接..." "info"
            sudo cp -L /usr/bin/python3 /usr/bin/python3.backup 2>/dev/null || true
        fi
        if [[ -e /usr/bin/python ]]; then
            sudo cp -L /usr/bin/python /usr/bin/python.backup 2>/dev/null || true
        fi
        
        log "创建 /usr/bin/python 链接..." "info"
        sudo ln -sf "$python_path" /usr/bin/python
        
        log "创建 /usr/bin/python3 链接..." "info"
        sudo ln -sf "$python_path" /usr/bin/python3
        
        log "✓ Python链接已创建" "info"
        log "  /usr/bin/python -> $python_path" "info"
        log "  /usr/bin/python3 -> $python_path" "info"
        
        # 如果有备份，提醒用户
        if [[ -f /usr/bin/python3.backup ]]; then
            log "💡 原系统Python已备份为 python3.backup" "info"
        fi
    else
        log "✗ 无法找到Mise管理的Python，跳过链接创建" "warn"
    fi
}

# === 使用方式配置函数 ===

show_project_usage_guide() {
    echo
    log "📝 项目级使用指南:" "info"
    local system_version=""
    system_version=$(/usr/bin/python3 --version 2>/dev/null || echo '获取失败')
    log "  • 系统级: 自动使用系统Python ($system_version)" "info"
    log "  • 项目级: cd your_project && mise use python@3.12.11" "info"
    log "  • 临时使用: mise exec python@3.12.11 -- python script.py" "info"
    log "  • 查看当前: mise current python" "info"
    log "  • 全局设置: mise use -g python@3.12.11" "info"
}

confirm_global_replacement() {
    echo
    log "⚠️  警告: 即将进行全局Python替换！" "warn"
    log "这会影响所有系统工具，包括apt、dpkg、apt-listchanges等" "warn"
    log "如果系统工具报错，你需要手动修复或重新运行此脚本选择修复选项" "warn"
    echo
    read -p "确认要继续吗? 强烈建议选择'N' [y/N]: " -r confirm_choice || confirm_choice="N"
    
    if [[ "$confirm_choice" =~ ^[Yy]$ ]]; then
        log "执行全局替换..." "info"
        link_python_globally_original "allow_global"
        configure_path_for_global_mode
        echo
        log "⚠️  重要提醒:" "warn"
        log "  如遇系统工具报错，重新运行此脚本选择'修复系统配置'" "warn"
        log "  恢复命令: sudo ln -sf /usr/bin/python3.11 /usr/bin/python3" "warn"
    else
        log "✓ 明智的选择！改为使用项目级模式" "info"
        fix_python_system_priority
        show_project_usage_guide
    fi
}

# 配置Python使用方式
setup_python_usage() {
    log "配置 Python 使用方式..." "info"
    
    # 首先检测当前状态
    echo
    local needs_fix=1
    if detect_python_status > /dev/null 2>&1; then
        needs_fix=0  # 需要修复
    else
        needs_fix=1  # 状态正常
    fi
    
    echo
    echo "Python使用方式选择:"
    echo "  1) 仅项目级使用 (推荐)"
    echo "     - 系统工具使用系统Python，开发项目使用mise Python"
    echo "     - 自动修复PATH和链接问题，确保系统工具正常运行"
    echo
    echo "  2) 全局替换系统Python"
    echo "     - ⚠️  mise Python成为系统默认，可能影响apt等系统工具"
    echo "     - 适合高级用户，需要自行处理兼容性问题"
    echo
    
    if [[ $needs_fix -eq 0 ]]; then
        echo "  3) 修复系统Python配置"
        echo "     - 🔧 检测到系统被劫持，推荐选择此项立即修复"
        echo "     - 恢复系统工具的正常运行，修复立即生效"
        echo
    fi
    
    local usage_choice=""
    local default_choice=1
    [[ $needs_fix -eq 0 ]] && default_choice=3
    
    local max_choice=2
    [[ $needs_fix -eq 0 ]] && max_choice=3
    
    read -p "请选择 [1-$max_choice] (默认: $default_choice): " -r usage_choice || usage_choice="$default_choice"
    usage_choice=${usage_choice:-$default_choice}
    
    case "$usage_choice" in
        1)
            log "✓ 配置为项目级使用模式（推荐）" "info"
            fix_python_system_priority
            show_project_usage_guide
            ;;
        2)
            confirm_global_replacement
            ;;
        3)
            if [[ $needs_fix -eq 0 ]]; then
                log "🔧 执行系统修复..." "info"
                fix_python_system_priority
                log "✓ 系统Python配置已修复" "info"
                show_project_usage_guide
            else
                log "无效选择，使用项目级模式" "warn"
                fix_python_system_priority
                show_project_usage_guide
            fi
            ;;
        *)
            log "无效选择，使用项目级模式" "warn"
            fix_python_system_priority
            show_project_usage_guide
            ;;
    esac
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
        command -v "$shell_name" &>/dev/null || continue
        [[ ! -f "$config_file" ]] && touch "$config_file"
        
        # 检查是否已配置
        if grep -q "mise activate $shell_name" "$config_file" 2>/dev/null; then
            log "$shell_name 集成已存在" "info"
        else
            # 添加配置
            if [[ "$shell_name" == "bash" ]]; then
                echo -e "\n# Mise version manager\n$activate_cmd" >> "$config_file"
            else
                # 对于zsh，插入到mise注释后面（zsh-setup模块已经添加了注释）
                if grep -q "# mise 版本管理器配置" "$config_file" 2>/dev/null; then
                    sed -i "/# mise 版本管理器配置/a $activate_cmd" "$config_file" 2>/dev/null || true
                else
                    echo -e "\n# Mise version manager\n$activate_cmd" >> "$config_file"
                fi
            fi
            log "✓ Mise 已添加到 $config_file" "info"
        fi
    done
}

# 显示配置摘要（增强版）
show_mise_summary() {
    echo
    log "🎯 Mise 配置摘要:" "info"
    
    # Mise版本
    if [[ -f "$MISE_PATH" ]]; then
        local mise_version=""
        mise_version=$(get_mise_version)
        log "  ✓ Mise版本: $mise_version" "info"
        
        # Python状态
        if "$MISE_PATH" which python &>/dev/null; then
            local python_version=""
            python_version=$(get_python_version)
            local current_version=""
            current_version=$("$MISE_PATH" current python 2>/dev/null || echo "未知")
            log "  ✓ Mise Python: $python_version (当前: $current_version)" "info"
        else
            log "  ✗ Mise Python: 未配置" "info"
        fi
        
        # 系统Python状态
        local system_python_version=""
        system_python_version=$(/usr/bin/python3 --version 2>/dev/null || echo "无法获取")
        log "  ✓ 系统Python: $system_python_version" "info"
        
        # 检查系统链接状态
        if [[ -L /usr/bin/python3 ]]; then
            local python3_target=""
            python3_target=$(readlink /usr/bin/python3 2>/dev/null || echo "")
            if [[ "$python3_target" == *"mise"* ]]; then
                log "  🔗 系统链接: 链接到mise Python (全局模式)" "info"
            else
                log "  🔗 系统链接: 使用系统Python (推荐)" "info"
            fi
        fi
        
        # 实时检查PATH优先级
        local which_python=""
        which_python=$(which python3 2>/dev/null || echo "")
        if [[ "$which_python" == *"mise"* ]]; then
            log "  🛤️  PATH优先: mise Python" "warn"
        elif [[ "$which_python" == "/usr/bin/python3" ]]; then
            log "  🛤️  PATH优先: 系统Python (推荐)" "info"
        else
            log "  🛤️  PATH优先: 异常 ($which_python)" "error"
        fi
        
        # 全局工具列表
        local tools_count=""
        tools_count=$("$MISE_PATH" list 2>/dev/null | wc -l || echo "0")
        log "  📦 已安装工具: $tools_count 个" "info"
        
        # 智能的系统模块状态检查
        local apt_pkg_ok=false
        local debconf_ok=false
        
        if python3 -c "import apt_pkg" &>/dev/null 2>&1; then
            apt_pkg_ok=true
        fi
        
        if python3 -c "import debconf" &>/dev/null 2>&1; then
            debconf_ok=true
        fi
        
        if $apt_pkg_ok && $debconf_ok; then
            log "  🧩 系统模块: 完全正常 ✓" "info"
        elif $apt_pkg_ok || $debconf_ok; then
            log "  🧩 系统模块: 部分可用 ⚠️ (apt_pkg: $($apt_pkg_ok && echo "✓" || echo "✗"), debconf: $($debconf_ok && echo "✓" || echo "✗"))" "warn"
            log "    → 这不影响mise正常使用，系统包管理可能受限" "info"
        else
            log "  🧩 系统模块: 有问题 ⚠️ (apt_pkg ✗, debconf ✗)" "warn"
            if /usr/bin/python3 -c "import apt_pkg" &>/dev/null 2>&1; then
                log "    → 系统Python模块正常，问题是PATH优先级" "warn"
            else
                log "    → 系统包管理有问题，但不影响mise使用" "info"
            fi
        fi
        
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
    
    # 显示当前状态（如果mise已安装）
    echo
    if [[ -f "$MISE_PATH" ]]; then
        log "检测到现有mise安装，正在分析系统状态..." "info"
        detect_python_status > /dev/null 2>&1 || true
    fi
    
    echo
    install_mise
    
    echo
    log "开始配置Python..." "info"
    if setup_python; then
        :
    else
        log "Python配置失败，但继续执行..." "warn"
    fi
    
    echo
    setup_python_usage
    
    echo
    configure_shell_integration
    
    show_mise_summary
    
    echo
    log "🎉 Mise 配置完成!" "info"
    log "💡 提示: 运行 'source ~/.bashrc' 或重新登录以激活配置" "info"
    
    # 显示有用的命令
    if [[ -f "$MISE_PATH" ]]; then
        echo
        log "常用命令:" "info"
        log "  查看工具: $MISE_PATH list" "info"
        log "  项目使用: $MISE_PATH use python@3.12.11" "info"
        log "  全局设置: $MISE_PATH use -g python@3.12.11" "info"
        log "  查看当前: $MISE_PATH current" "info"
        log "  查看帮助: $MISE_PATH --help" "info"
    fi
    
    # 重要提醒
    echo
    log "⚠️  重要提醒:" "warn"
    log "  • 如遇apt工具报错，重新运行此脚本选择'修复系统配置'" "info"
    log "  • 推荐使用项目级模式，避免影响系统工具" "info"
    log "  • 系统模块问题不影响mise正常使用，只是包管理可能受限" "info"
    
    # 检查是否需要重新登录
    local final_which_python=""
    final_which_python=$(which python3 2>/dev/null || echo "")
    if [[ "$final_which_python" == *"mise"* ]] && [[ ! "${1:-}" == "allow_global" ]]; then
        echo
        log "🔄 检测到PATH可能需要手动生效，请运行:" "warn"
        log "   source ~/.bashrc  # 或重新登录" "info"
    fi
}

main "$@"
