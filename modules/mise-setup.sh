#!/bin/bash
# Mise 版本管理器配置模块 v5.1 - 智能配置版
# 功能: 安装Mise、智能选择Python版本、Shell集成、智能链接管理、自动修复系统模块

set -euo pipefail

# === 常量定义 ===
readonly MISE_PATH="$HOME/.local/bin/mise"
readonly MISE_BIN_DIR="$HOME/.local/bin"

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
# 诊断系统包管理状态
diagnose_apt_system() {
    debug_log "诊断APT系统状态"
    local broken_packages=""
    broken_packages=$(dpkg -l | grep -E '^[hi] [^i]|^.[^i]' | wc -l 2>/dev/null || echo "0")
    
    if [[ "$broken_packages" -gt 0 ]]; then
        debug_log "发现 $broken_packages 个损坏包"
        return 1
    fi
    
    if [[ -f /var/lib/dpkg/lock-frontend ]] || [[ -f /var/lib/apt/lists/lock ]]; then
        if lsof /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || lsof /var/lib/apt/lists/lock >/dev/null 2>&1; then
            debug_log "APT锁定文件被占用"
            return 1
        fi
    fi
    
    if ! which python3 &>/dev/null || [[ ! -x /usr/bin/python3 ]]; then
        debug_log "系统Python3不可用"
        return 1
    fi
    
    debug_log "APT系统状态正常"
    return 0
}

# 修复dpkg状态
fix_dpkg_state() {
    debug_log "修复dpkg状态"
    if timeout 30 sudo dpkg --configure -a >/dev/null 2>&1; then
        debug_log "dpkg配置修复成功"
        return 0
    fi
    
    if timeout 45 sudo DEBIAN_FRONTEND=noninteractive apt-get -f install -y >/dev/null 2>&1; then
        debug_log "APT强制安装修复成功"
        return 0
    fi
    
    debug_log "dpkg状态修复失败"
    return 1
}

# 检测系统Python状态
detect_system_python() {
    debug_log "检测系统Python"
    local system_python_paths=(
        "/usr/bin/python3"
        "/usr/bin/python3.11"
        "/usr/bin/python3.10" 
        "/usr/bin/python3.9"
        "/usr/bin/python3.12"
    )
    
    for python_path in "${system_python_paths[@]}"; do
        if [[ -x "$python_path" ]]; then
            debug_log "找到系统Python: $python_path"
            echo "$python_path"
            return 0
        fi
    done
    
    debug_log "未找到可用的系统Python"
    return 1
}

# 确保系统Python可用
ensure_system_python() {
    debug_log "确保系统Python可用"
    local system_python=""
    if system_python=$(detect_system_python); then
        if [[ ! -e "/usr/bin/python3" ]] && [[ "$system_python" != "/usr/bin/python3" ]]; then
            debug_log "创建系统Python链接: $system_python -> /usr/bin/python3"
            sudo ln -sf "$system_python" /usr/bin/python3 2>/dev/null || {
                debug_log "创建Python链接失败"
                return 1
            }
        fi
        debug_log "系统Python已确保可用"
        return 0
    else
        debug_log "安装系统Python"
        if command -v apt &>/dev/null; then
            if timeout 120 sudo DEBIAN_FRONTEND=noninteractive apt update -qq && timeout 120 sudo DEBIAN_FRONTEND=noninteractive apt install -y python3 python3-apt python3-debconf >/dev/null 2>&1; then
                debug_log "系统Python安装成功"
                return 0
            fi
        fi
        debug_log "系统Python安装失败"
        return 1
    fi
}

# 检测当前Python链接状态
detect_python_status() {
    debug_log "检测Python状态"
    if ! ensure_system_python; then
        debug_log "系统Python不可用"
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
            debug_log "检测到系统Python链接被劫持"
        fi
    fi
    
    # 检查PATH优先级 - 修复检测逻辑
    local which_python_current=$(which python3 2>/dev/null || echo "")
    local which_python_clean
    which_python_clean=$(PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" which python3 2>/dev/null || echo "")
    
    debug_log "当前python3路径: $which_python_current"
    debug_log "系统python3路径: $which_python_clean"
    
    # 如果当前指向mise相关路径，且与系统路径不同，则认为被劫持
    if [[ "$which_python_current" == *"mise"* ]] && [[ "$which_python_current" != "$which_python_clean" ]]; then
        # 检查是否是mise shell集成造成的临时效果
        if [[ -z "$MISE_SHELL" ]] && ! (command -v mise >/dev/null && mise current python >/dev/null 2>&1 && [[ -n "$MISE_ACTIVATED" ]]); then
            # 不是mise集成，是PATH被劫持
            path_priority="劫持"
            is_hijacked=true
            debug_log "检测到PATH被mise劫持"
        else
            # 这可能是项目级使用但PATH配置不当
            path_priority="mise集成异常"
            is_hijacked=true
            debug_log "检测到mise集成PATH配置异常"
        fi
    fi
    
    echo "Python状态: 链接($link_status) PATH($path_priority)" >&2
    
    # 只要检测到劫持就返回0（需要修复）
    if $is_hijacked && [[ ! "${1:-}" == "allow_global" ]]; then
        debug_log "Python状态需要修复"
        return 0  # 需要修复
    else
        debug_log "Python状态正常"
        return 1  # 状态正常
    fi
}

# 智能的系统模块修复
fix_system_modules() {
    debug_log "修复系统模块"
    if /usr/bin/python3 -c "import apt_pkg; import debconf" >/dev/null 2>&1; then
        debug_log "系统模块正常，无需修复"
        return 0
    fi
    
    # 尝试修复系统状态
    if ! diagnose_apt_system; then
        debug_log "尝试修复dpkg状态"
        fix_dpkg_state || true
        if /usr/bin/python3 -c "import apt_pkg; import debconf" >/dev/null 2>&1; then
            debug_log "系统模块修复成功"
            return 0
        fi
    fi
    
    # 重装系统模块
    debug_log "重装系统模块"
    sudo apt clean >/dev/null 2>&1 || true
    if timeout 60 sudo DEBIAN_FRONTEND=noninteractive apt update >/dev/null 2>&1; then
        timeout 60 sudo DEBIAN_FRONTEND=noninteractive apt install --reinstall -y python3-apt python3-debconf >/dev/null 2>&1 || {
            debug_log "重装系统模块失败"
            true
        }
    fi
    
    # 强制重装python3包
    debug_log "强制重装Python3包"
    local python_packages=("python3-minimal" "python3" "python3-apt" "python3-debconf")
    for pkg in "${python_packages[@]}"; do
        timeout 30 sudo DEBIAN_FRONTEND=noninteractive apt install --reinstall -y "$pkg" >/dev/null 2>&1 || {
            debug_log "重装 $pkg 失败"
            true
        }
    done
    
    if /usr/bin/python3 -c "import apt_pkg; import debconf" >/dev/null 2>&1; then
        debug_log "系统模块完全修复成功"
        return 0
    else
        echo "系统模块修复: 部分成功，不影响mise正常使用"
        debug_log "系统模块部分修复成功"
        return 1
    fi
}

# 修复系统Python链接和PATH
fix_python_system_priority() {
    debug_log "修复系统Python优先级"
    if ! ensure_system_python; then
        log "✗ 无法确保系统Python可用" "error"
        return 1
    fi
    
    # 修复系统链接
    if [[ -L /usr/bin/python3 ]]; then
        local python3_target
        python3_target=$(readlink /usr/bin/python3 2>/dev/null || echo "")
        if [[ -n "$python3_target" && "$python3_target" == *"mise"* ]]; then
            debug_log "修复被劫持的系统Python链接"
            sudo cp -L /usr/bin/python3 /usr/bin/python3.mise.backup 2>/dev/null || true
            sudo rm /usr/bin/python3 2>/dev/null || true
            local system_python=""
            if system_python=$(detect_system_python); then
                sudo ln -sf "$system_python" /usr/bin/python3 || {
                    debug_log "重建Python链接失败"
                    return 1
                }
            fi
        fi
    fi
    
    # 修复PATH配置
    debug_log "配置安全PATH优先级"
    configure_safe_path_priority
    
    # 立即应用修复
    export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$HOME/.local/bin"
    hash -r 2>/dev/null || true
    
    # 修复系统模块
    fix_system_modules >/dev/null 2>&1 || true
    
    echo "系统Python优先级: 已修复"
    debug_log "系统Python优先级修复完成"
}

# 安全的PATH配置
configure_safe_path_priority() {
    debug_log "配置安全PATH优先级"
    local shells=("bash:$HOME/.bashrc" "zsh:$HOME/.zshrc")
    
    for shell_info in "${shells[@]}"; do
        local shell_name="${shell_info%%:*}"
        local config_file="${shell_info#*:}"
        
        if ! command -v "$shell_name" &>/dev/null; then
            debug_log "$shell_name 不存在，跳过配置"
            continue
        fi
        
        [[ ! -f "$config_file" ]] && touch "$config_file"
        cp "$config_file" "${config_file}.mise.backup" 2>/dev/null || true
        
        sed -i '/# Mise PATH priority/,+1d' "$config_file" 2>/dev/null || true
        sed -i '/# Mise global mode PATH/,+1d' "$config_file" 2>/dev/null || true
        
        debug_log "为 $shell_name 配置安全PATH"
        cat >> "$config_file" << 'EOF'

# Mise PATH priority - 确保系统工具使用系统Python
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$HOME/.local/bin"
EOF
    done
}

# 配置全局模式的PATH
configure_path_for_global_mode() {
    debug_log "配置全局模式PATH"
    local shells=("bash:$HOME/.bashrc" "zsh:$HOME/.zshrc")
    
    for shell_info in "${shells[@]}"; do
        local shell_name="${shell_info%%:*}"
        local config_file="${shell_info#*:}"
        
        if ! command -v "$shell_name" &>/dev/null; then
            debug_log "$shell_name 不存在，跳过配置"
            continue
        fi
        
        [[ ! -f "$config_file" ]] && touch "$config_file"
        
        sed -i '/# Mise PATH priority/,+1d' "$config_file" 2>/dev/null || true
        sed -i '/# Mise global mode PATH/,+1d' "$config_file" 2>/dev/null || true
        
        debug_log "为 $shell_name 配置全局模式PATH"
        cat >> "$config_file" << 'EOF'

# Mise global mode PATH - mise Python 优先
export PATH="$HOME/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
EOF
    done
    
    export PATH="$HOME/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    hash -r 2>/dev/null || true
}

# 获取Mise版本
get_mise_version() {
    debug_log "获取Mise版本"
    local version_output
    version_output=$("$MISE_PATH" --version 2>/dev/null || echo "")
    if [[ "$version_output" =~ v?([0-9]+\.[0-9]+\.[0-9]+) ]]; then
        debug_log "Mise版本: ${BASH_REMATCH[1]}"
        echo "${BASH_REMATCH[1]}"
    else
        debug_log "无法获取Mise版本"
        echo "未知"
    fi
}

# 获取最新的三个Python主版本
get_top3_python_versions() {
    debug_log "获取最新Python版本"
    local default_versions=("3.11.9" "3.12.4" "3.13.0")
    local versions_output=""
    local major_versions=""
    local final_versions=()
    
    if ! versions_output=$("$MISE_PATH" ls-remote python 2>/dev/null); then
        debug_log "获取远程Python版本失败，使用默认版本"
        printf '%s\n' "${default_versions[@]}"
        return
    fi
    
    if ! major_versions=$(echo "$versions_output" | grep -E "^[0-9]+\.[0-9]+\.[0-9]+$" | sed -E 's/^([0-9]+\.[0-9]+)\.[0-9]+$/\1/' | sort -V -u | tail -3 2>/dev/null); then
        debug_log "处理版本信息失败，使用默认版本"
        printf '%s\n' "${default_versions[@]}"
        return
    fi
    
    while IFS= read -r major; do
        if [[ -n "$major" ]]; then
            local latest_patch=""
            if latest_patch=$(echo "$versions_output" | grep -E "^${major}\.[0-9]+$" | sort -V | tail -1 2>/dev/null); then
                if [[ -n "$latest_patch" ]]; then
                    final_versions+=("$latest_patch")
                    debug_log "找到Python版本: $latest_patch"
                fi
            fi
        fi
    done <<< "$major_versions"
    
    if [[ ${#final_versions[@]} -eq 0 ]]; then
        debug_log "未找到可用版本，使用默认版本"
        printf '%s\n' "${default_versions[@]}"
    else
        printf '%s\n' "${final_versions[@]}"
    fi
}

# 获取已安装的Python版本列表
get_installed_python_versions() {
    debug_log "获取已安装Python版本"
    "$MISE_PATH" ls python 2>/dev/null | awk '/^python/ {print $2}' | grep -E "^[0-9]+\.[0-9]+\.[0-9]+$" 2>/dev/null || true
}
# === 辅助函数结束 ===

# === 核心功能函数 ===
# 安装或更新Mise
install_mise() {
    debug_log "开始安装或更新Mise"
    mkdir -p "$MISE_BIN_DIR" || {
        log "创建Mise目录失败" "error"
        return 1
    }
    
    if [[ -f "$MISE_PATH" ]] || command -v mise &>/dev/null; then
        local mise_version
        mise_version=$(get_mise_version)
        echo "Mise状态: 已安装 v$mise_version"
        
        read -p "是否更新到最新版本? [y/N]: " -r update_choice
        if [[ "$update_choice" =~ ^[Yy]$ ]]; then
            debug_log "更新Mise到最新版本"
            if curl -fsSL https://mise.run | sh >/dev/null 2>&1; then
                echo "Mise更新: 成功"
                debug_log "Mise更新成功"
                # 刷新命令缓存
                hash -r 2>/dev/null || true
                # 重新确保PATH包含mise目录
                export PATH="$MISE_BIN_DIR:$PATH"
            else
                echo "Mise更新: 失败，继续使用现有版本"
                debug_log "Mise更新失败"
            fi
        else
            debug_log "用户选择不更新Mise"
        fi
    else
        echo "安装Mise中..."
        debug_log "首次安装Mise"
        if curl -fsSL https://mise.run | sh >/dev/null 2>&1; then
            echo "Mise安装: 成功"
            debug_log "Mise安装成功"
            # 刷新命令缓存
            hash -r 2>/dev/null || true
            # 确保PATH包含mise目录
            export PATH="$MISE_BIN_DIR:$PATH"
        else
            log "✗ Mise安装失败" "error"
            debug_log "Mise安装失败"
            exit 1
        fi
    fi
    
    # 多种方式验证安装
    debug_log "开始验证Mise安装"
    debug_log "检查文件: $MISE_PATH"
    debug_log "检查命令: $(command -v mise 2>/dev/null || echo 'not found')"
    debug_log "当前PATH: $PATH"
    
    if [[ -f "$MISE_PATH" && -x "$MISE_PATH" ]]; then
        debug_log "Mise安装验证成功 (文件存在且可执行)"
    elif command -v mise &>/dev/null; then
        debug_log "Mise安装验证成功 (命令可用)"
        # 更新MISE_PATH变量为实际路径
        local actual_path=$(command -v mise)
        debug_log "实际Mise路径: $actual_path"
    else
        log "✗ 安装验证失败" "error"
        debug_log "验证失败 - 文件检查: $([[ -f "$MISE_PATH" ]] && echo 'exists' || echo 'missing')"
        debug_log "验证失败 - 权限检查: $([[ -x "$MISE_PATH" ]] && echo 'executable' || echo 'not executable')"
        debug_log "验证失败 - 命令检查: $(command -v mise &>/dev/null && echo 'found' || echo 'not found')"
        exit 1
    fi
    debug_log "Mise安装验证完成"
}

# 让用户选择Python版本
choose_python_version() {
    debug_log "用户选择Python版本"
    local versions=()
    local version_output=""
    
    version_output=$(get_top3_python_versions)
    
    if [[ -n "$version_output" ]]; then
        while IFS= read -r line; do
            [[ -n "$line" ]] && versions+=("$line")
        done <<< "$version_output"
    fi
    
    if [[ ${#versions[@]} -eq 0 ]]; then
        debug_log "使用默认Python版本列表"
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
    read -p "请选择 [1-4] (默认: 4): " choice >&2
    choice=${choice:-4}
    
    debug_log "用户选择: $choice"
    
    # 只返回结果到stdout，不包含其他输出
    case "$choice" in
        1|2|3) 
            local idx=$((choice-1))
            if [[ $idx -lt ${#versions[@]} ]]; then
                debug_log "选择Python版本: ${versions[$idx]}"
                echo "${versions[$idx]}"
            else
                debug_log "无效选择，使用默认版本3.12.4"
                echo "3.12.4"
            fi
            ;;
        4) 
            debug_log "保持当前Python配置"
            echo "current" 
            ;;
        *) 
            debug_log "无效选择，使用默认版本3.12.4"
            echo "3.12.4" 
            ;;
    esac
}

# 清理旧版本Python
cleanup_old_python_versions() {
    local current_version="$1"
    debug_log "清理旧Python版本，当前版本: $current_version"
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
            debug_log "用户选择删除其他Python版本"
            while IFS= read -r version; do
                if [[ -n "$version" ]]; then
                    debug_log "删除Python版本: $version"
                    if "$MISE_PATH" uninstall "python@$version" >/dev/null 2>&1; then
                        echo "Python $version: 已删除"
                        debug_log "Python $version 删除成功"
                    else
                        echo "Python $version: 删除失败"
                        debug_log "Python $version 删除失败"
                    fi
                fi
            done <<< "$installed_versions"
        else
            debug_log "用户选择保留其他Python版本"
        fi
    else
        debug_log "未发现其他Python版本"
    fi
}

# 配置Python
setup_python() {
    debug_log "开始配置Python"
    local current_version=""
    current_version=$("$MISE_PATH" current python 2>/dev/null || echo "")
    [[ -n "$current_version" ]] && echo "当前Python: $current_version"
    
    local selected_version=""
    selected_version=$(choose_python_version)
    
    # 修正：正确处理"current"选择
    if [[ "$selected_version" == "current" ]]; then
        echo "Python配置: 保持当前"
        debug_log "保持当前Python配置"
        return 0
    fi
    
    echo "安装Python $selected_version..."
    debug_log "安装Python版本: $selected_version"
    if "$MISE_PATH" use -g "python@$selected_version" >/dev/null 2>&1; then
        echo "Python $selected_version: 安装成功"
        debug_log "Python $selected_version 安装成功"
        cleanup_old_python_versions "$selected_version"
        return 0
    else
        log "✗ Python $selected_version 安装失败" "error"
        debug_log "Python $selected_version 安装失败"
        return 1
    fi
}

# 创建全局Python链接
link_python_globally() {
    debug_log "创建全局Python链接"
    local python_path=""
    python_path=$("$MISE_PATH" which python 2>/dev/null || echo "")
    
    if [[ -x "$python_path" ]]; then
        debug_log "找到mise Python路径: $python_path"
        if [[ -L /usr/bin/python3 ]]; then
            sudo cp -L /usr/bin/python3 /usr/bin/python3.backup 2>/dev/null || {
                debug_log "备份/usr/bin/python3失败"
                true
            }
        fi
        if [[ -e /usr/bin/python ]]; then
            sudo cp -L /usr/bin/python /usr/bin/python.backup 2>/dev/null || {
                debug_log "备份/usr/bin/python失败"
                true
            }
        fi
        
        if sudo ln -sf "$python_path" /usr/bin/python && sudo ln -sf "$python_path" /usr/bin/python3; then
            echo "全局Python链接: 已创建"
            echo "  /usr/bin/python -> $python_path"
            echo "  /usr/bin/python3 -> $python_path"
            debug_log "全局Python链接创建成功"
        else
            echo "全局Python链接: 创建失败"
            debug_log "全局Python链接创建失败"
        fi
    else
        echo "全局Python链接: 失败，找不到mise Python"
        debug_log "找不到mise Python路径"
    fi
}

# 配置Python使用方式
setup_python_usage() {
    debug_log "配置Python使用方式"
    echo
    local needs_fix=1
    if detect_python_status >/dev/null 2>&1; then
        needs_fix=0
        debug_log "检测到系统需要修复"
    else
        needs_fix=1
        debug_log "系统状态正常"
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
    
    debug_log "用户选择使用方式: $usage_choice"
    
    case "$usage_choice" in
        1)
            echo "配置模式: 项目级使用"
            debug_log "配置项目级使用模式"
            # 总是执行修复，确保系统优先
            fix_python_system_priority
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
                debug_log "配置全局替换模式"
                link_python_globally
                configure_path_for_global_mode
                echo "重要: 如遇系统工具报错，重新运行脚本选择修复"
            else
                echo "配置模式: 改为项目级使用"
                debug_log "用户取消全局替换，改为项目级使用"
                fix_python_system_priority
            fi
            ;;
        3)
            if [[ $needs_fix -eq 0 ]]; then
                echo "执行系统修复..."
                debug_log "执行系统修复"
                fix_python_system_priority
            else
                echo "配置模式: 项目级使用"
                debug_log "配置项目级使用（备用选项）"
                fix_python_system_priority
            fi
            ;;
        *)
            echo "配置模式: 项目级使用"
            debug_log "默认配置项目级使用"
            if [[ $needs_fix -eq 0 ]]; then
                fix_python_system_priority
            fi
            ;;
    esac
}

# 配置Shell集成
configure_shell_integration() {
    debug_log "配置Shell集成"
    local shells=(
        "bash:$HOME/.bashrc:eval \"\$(\$HOME/.local/bin/mise activate bash)\""
        "zsh:$HOME/.zshrc:eval \"\$(mise activate zsh)\""
    )
    
    for shell_info in "${shells[@]}"; do
        local shell_name="${shell_info%%:*}"
        local config_file="${shell_info#*:}"
        config_file="${config_file%%:*}"
        local activate_cmd="${shell_info##*:}"
        
        if ! command -v "$shell_name" &>/dev/null; then
            debug_log "$shell_name 不存在，跳过配置"
            continue
        fi
        
        [[ ! -f "$config_file" ]] && touch "$config_file"
        
        if grep -q "mise activate $shell_name" "$config_file" 2>/dev/null; then
            echo "$shell_name集成: 已存在"
            debug_log "$shell_name 集成已存在"
        else
            debug_log "为 $shell_name 配置集成"
            if [[ "$shell_name" == "bash" ]]; then
                echo -e "\n# Mise version manager\n$activate_cmd" >> "$config_file"
            else
                if grep -q "# mise 版本管理器配置" "$config_file" 2>/dev/null; then
                    sed -i "/# mise 版本管理器配置/a $activate_cmd" "$config_file" 2>/dev/null || {
                        debug_log "sed命令失败，使用追加方式"
                        echo -e "\n# Mise version manager\n$activate_cmd" >> "$config_file"
                    }
                else
                    echo -e "\n# Mise version manager\n$activate_cmd" >> "$config_file"
                fi
            fi
            echo "$shell_name集成: 已配置"
            debug_log "$shell_name 集成配置完成"
        fi
    done
}

# 显示配置摘要
show_mise_summary() {
    debug_log "显示配置摘要"
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
        
        # 使用系统Python检查版本
        local system_python_version=""
        system_python_version=$(/usr/bin/python3 --version 2>/dev/null || echo "无法获取")
        echo "  系统Python: $system_python_version"
        
        # 检查当前优先级 - 修复逻辑
        local which_python=""
        which_python=$(which python3 2>/dev/null || echo "")
        local system_python_path=$(PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" which python3 2>/dev/null || echo "")
        
        if [[ "$which_python" == *"mise"* ]]; then
            if [[ "$which_python" != "$system_python_path" ]]; then
                echo "  当前优先: mise Python (需要修复)"
            else
                echo "  当前优先: mise Python"
            fi
        elif [[ "$which_python" == "/usr/bin/python3" ]] || [[ "$which_python" == "$system_python_path" ]]; then
            echo "  当前优先: 系统Python (推荐)"
        else
            echo "  当前优先: 异常状态 ($which_python)"
        fi
        
        # 使用系统Python检查系统模块
        local apt_pkg_ok=false
        local debconf_ok=false
        if /usr/bin/python3 -c "import apt_pkg" &>/dev/null 2>&1; then apt_pkg_ok=true; fi
        if /usr/bin/python3 -c "import debconf" &>/dev/null 2>&1; then debconf_ok=true; fi
        
        if $apt_pkg_ok && $debconf_ok; then
            echo "  系统模块: 正常"
        else
            echo "  系统模块: 部分异常 (不影响mise使用)"
            debug_log "系统模块检查失败: apt_pkg=$apt_pkg_ok, debconf=$debconf_ok"
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
# === 核心功能函数结束 ===

# === 主流程 ===
main() {
    log "🔧 配置Mise版本管理器..." "info"
    
    echo
    if [[ -f "$MISE_PATH" ]]; then
        detect_python_status >/dev/null 2>&1 || true
    fi
    
    if ! install_mise; then
        log "Mise安装失败" "error"
        exit 1
    fi
    
    echo
    if setup_python; then
        debug_log "Python配置成功"
    else
        echo "Python配置失败，但继续执行..."
        debug_log "Python配置失败，继续执行"
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

# 错误处理
trap 'log "脚本执行出错，行号: $LINENO" "error"; exit 1' ERR

main "$@"
