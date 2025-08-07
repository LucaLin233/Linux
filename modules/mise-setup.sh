#!/bin/bash
# Mise 版本管理器配置模块 v4.7.3
# 功能: 安装Mise、智能选择Python版本、Shell集成、智能链接管理、自动修复系统模块
# 调试: 添加详细错误追踪，显示具体失败步骤

set -euo pipefail

# === 错误追踪 ===
trap 'echo "❌ 脚本在第 $LINENO 行失败，命令: $BASH_COMMAND" >&2; exit 1' ERR

# === 常量定义 ===
readonly MISE_PATH="$HOME/.local/bin/mise"
readonly MISE_BIN_DIR="$HOME/.local/bin"

# === 日志函数 ===
log() {
    local msg="$1" level="${2:-info}"
    local -A colors=([info]="\033[0;36m" [warn]="\033[0;33m" [error]="\033[0;31m" [debug]="\033[0;35m")
    echo -e "${colors[$level]:-\033[0;32m}$msg\033[0m"
}

debug() {
    log "🔍 DEBUG: $1" "debug"
}

# === 系统状态检测函数 ===

# 检测当前Python链接状态
detect_python_status() {
    debug "开始检测Python状态..."
    local status_info="" link_status="正常"
    
    # 检查系统链接
    if [[ -L /usr/bin/python3 ]]; then
        local python3_target
        python3_target=$(readlink /usr/bin/python3 2>/dev/null || echo "")
        debug "系统链接目标: $python3_target"
        
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
    debug "当前python3路径: $which_python"
    
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
    
    debug "检测完成，link_status=$link_status, path_priority=$path_priority"
    
    # 返回是否需要修复
    if [[ "$link_status" == "劫持" || "$path_priority" == "劫持" ]] && [[ ! "${1:-}" == "allow_global" ]]; then
        debug "需要修复"
        return 0  # 需要修复
    else
        debug "状态正常"
        return 1  # 状态正常
    fi
}

# 自动修复系统模块
fix_system_modules() {
    debug "开始检查系统模块..."
    local apt_pkg_ok=false
    local debconf_ok=false
    
    # 检查模块状态
    if /usr/bin/python3 -c "import apt_pkg" >/dev/null 2>&1; then
        apt_pkg_ok=true
        debug "apt_pkg模块正常"
    else
        debug "apt_pkg模块缺失"
    fi
    
    if /usr/bin/python3 -c "import debconf" >/dev/null 2>&1; then
        debconf_ok=true
        debug "debconf模块正常"
    else
        debug "debconf模块缺失"
    fi
    
    # 如果模块都正常，直接返回
    if $apt_pkg_ok && $debconf_ok; then
        debug "所有系统模块都正常"
        return 0
    fi
    
    log "🔧 检测到系统模块缺失，正在自动修复..." "warn"
    
    # 尝试重新安装
    debug "尝试重新安装python3-apt python3-debconf..."
    if sudo apt install --reinstall python3-apt python3-debconf >/dev/null 2>&1; then
        log "✓ 系统模块修复成功" "info"
        return 0
    fi
    
    # 如果重装失败，尝试完全重装
    log "重装失败，尝试完全重新安装..." "info"
    debug "移除现有包..."
    sudo apt remove --purge python3-apt python3-debconf >/dev/null 2>&1 || true
    sudo apt autoremove >/dev/null 2>&1 || true
    
    debug "重新安装包..."
    if sudo apt install python3-apt python3-debconf >/dev/null 2>&1; then
        log "✓ 系统模块完全重装成功" "info"
        return 0
    else
        log "✗ 系统模块自动修复失败，请手动处理:" "error"
        log "   sudo apt install --reinstall python3-apt python3-debconf" "error"
        return 1
    fi
}

# 修复系统Python链接和PATH
fix_python_system_priority() {
    debug "开始修复系统Python优先级..."
    log "🔧 修复系统Python优先级..." "info"
    
    # 修复系统链接
    if [[ -L /usr/bin/python3 ]]; then
        local python3_target
        python3_target=$(readlink /usr/bin/python3 2>/dev/null || echo "")
        debug "当前系统链接指向: $python3_target"
        
        if [[ -n "$python3_target" && "$python3_target" == *"mise"* ]]; then
            log "修复被劫持的系统Python链接..." "info"
            debug "删除被劫持的链接..."
            sudo rm /usr/bin/python3 2>/dev/null || true
            
            # 寻找合适的系统Python版本
            if [[ -x /usr/bin/python3.11 ]]; then
                debug "找到python3.11，创建链接..."
                sudo ln -sf /usr/bin/python3.11 /usr/bin/python3
                log "✓ 已链接到系统Python 3.11" "info"
            elif [[ -x /usr/bin/python3.10 ]]; then
                debug "找到python3.10，创建链接..."
                sudo ln -sf /usr/bin/python3.10 /usr/bin/python3
                log "✓ 已链接到系统Python 3.10" "info"
            elif [[ -x /usr/bin/python3.9 ]]; then
                debug "找到python3.9，创建链接..."
                sudo ln -sf /usr/bin/python3.9 /usr/bin/python3
                log "✓ 已链接到系统Python 3.9" "info"
            else
                log "✗ 未找到合适的系统Python版本" "error"
                return 1
            fi
        fi
    fi
    
    # 修复PATH配置
    debug "配置PATH优先级..."
    configure_path_priority
    
    # 立即生效
    debug "导出新的PATH..."
    export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$HOME/.local/bin"
    hash -r 2>/dev/null || true
    
    # 验证修复结果
    debug "验证修复结果..."
    local new_which_python
    new_which_python=$(which python3 2>/dev/null || echo "")
    debug "修复后python3路径: $new_which_python"
    
    if [[ "$new_which_python" == "/usr/bin/python3" ]]; then
        log "✓ PATH优先级修复成功，立即生效" "info"
        
        # 自动修复系统模块
        debug "尝试修复系统模块..."
        fix_system_modules || true  # 不让修复失败中断脚本
        
        # 验证系统模块
        if python3 -c "import apt_pkg" &>/dev/null 2>&1; then
            log "✓ 系统模块现在可用" "info"
        fi
    else
        log "⚠️ PATH修复异常，当前指向：$new_which_python" "warn"
    fi
    
    # 显示修复后状态
    echo
    log "修复后状态:" "info"
    local link_target
    link_target=$(readlink /usr/bin/python3 2>/dev/null || echo '直接文件')
    log "  系统链接: $link_target" "info"
    log "  当前python3: $(which python3)" "info"
    log "  版本: $(python3 --version)" "info"
}

# 配置PATH优先级
configure_path_priority() {
    debug "开始配置PATH优先级..."
    local shells=("bash:$HOME/.bashrc" "zsh:$HOME/.zshrc")
    
    for shell_info in "${shells[@]}"; do
        local shell_name="${shell_info%%:*}"
        local config_file="${shell_info#*:}"
        
        debug "检查shell: $shell_name"
        if ! command -v "$shell_name" &>/dev/null; then
            debug "$shell_name 不可用，跳过"
            continue
        fi
        
        [[ ! -f "$config_file" ]] && touch "$config_file"
        
        # 移除旧配置
        debug "移除旧的PATH配置..."
        sed -i '/# Mise PATH priority/,+1d' "$config_file" 2>/dev/null || true
        sed -i '/# Mise global mode PATH/,+1d' "$config_file" 2>/dev/null || true
        
        # 添加新配置
        debug "添加新的PATH配置到 $config_file"
        cat >> "$config_file" << 'EOF'

# Mise PATH priority - 确保系统工具使用系统Python
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$HOME/.local/bin"
EOF
        log "✓ 已配置 $shell_name PATH优先级" "info"
    done
}

# 配置全局模式PATH
configure_path_for_global_mode() {
    debug "开始配置全局模式PATH..."
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
        
        # 添加全局模式配置
        cat >> "$config_file" << 'EOF'

# Mise global mode PATH - mise Python 优先
export PATH="$HOME/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
EOF
        log "✓ 已配置 $shell_name 全局模式PATH" "info"
    done
    
    # 立即应用
    export PATH="$HOME/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    hash -r 2>/dev/null || true
}

# === 核心功能函数 ===

# 获取Mise版本
get_mise_version() {
    debug "获取Mise版本..."
    local version_output
    version_output=$("$MISE_PATH" --version 2>/dev/null || echo "")
    debug "Mise版本输出: $version_output"
    
    if [[ "$version_output" =~ v?([0-9]+\.[0-9]+\.[0-9]+) ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo "未知"
    fi
}

# 获取Python版本
get_python_version() {
    debug "获取Python版本..."
    local python_path
    python_path=$("$MISE_PATH" which python 2>/dev/null || echo "")
    debug "Python路径: $python_path"
    
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
    debug "开始安装或更新Mise..."
    log "检查并安装 Mise..." "info"
    mkdir -p "$MISE_BIN_DIR"
    
    if [[ -f "$MISE_PATH" ]]; then
        debug "Mise已存在，获取版本..."
        local mise_version
        mise_version=$(get_mise_version)
        log "Mise 已安装 (版本: $mise_version)" "info"
        
        echo
        read -p "是否更新 Mise 到最新版本? [y/N] (默认: N): " -r update_choice || update_choice="N"
        if [[ "$update_choice" =~ ^[Yy]$ ]]; then
            log "更新 Mise..." "info"
            debug "执行curl命令更新Mise..."
            if curl -fsSL https://mise.run | sh; then
                log "✓ Mise 已更新" "info"
                debug "Mise更新成功"
            else
                log "⚠️ Mise 更新失败，继续使用现有版本" "warn"
                debug "Mise更新失败"
            fi
        fi
    else
        log "安装 Mise..." "info"
        debug "执行curl命令安装Mise..."
        if curl -fsSL https://mise.run | sh; then
            log "✓ Mise 安装完成" "info"
            debug "Mise安装成功"
        else
            log "✗ Mise 安装失败" "error"
            exit 1
        fi
    fi
    
    debug "验证Mise安装..."
    if [[ ! -f "$MISE_PATH" ]]; then
        log "✗ 安装验证失败" "error"
        exit 1
    fi
    debug "Mise验证通过"
}

# 获取最新的三个Python主版本
get_top3_python_versions() {
    debug "开始获取Python版本列表..."
    log "获取可用Python版本..." "info"
    
    # 设置默认版本
    local default_versions=("3.11.9" "3.12.4" "3.13.0")
    debug "默认版本: ${default_versions[*]}"
    
    # 尝试获取远程版本
    local versions_output=""
    local major_versions=""
    local final_versions=()
    
    # 步骤1: 获取所有版本
    debug "步骤1: 获取所有远程版本..."
    if ! versions_output=$("$MISE_PATH" ls-remote python 2>/dev/null); then
        debug "获取远程版本失败，使用默认版本"
        log "⚠️ 无法获取远程版本，使用默认版本" "warn"
        printf '%s\n' "${default_versions[@]}"
        return
    fi
    
    debug "远程版本获取成功，版本数量: $(echo "$versions_output" | wc -l)"
    log "✓ 成功获取远程Python版本列表" "info"
    
    # 步骤2: 提取主版本号
    debug "步骤2: 提取主版本号..."
    if ! major_versions=$(echo "$versions_output" | grep -E "^[0-9]+\.[0-9]+\.[0-9]+$" | sed -E 's/^([0-9]+\.[0-9]+)\.[0-9]+$/\1/' | sort -V -u | tail -3 2>/dev/null); then
        debug "提取主版本号失败"
        log "⚠️ 处理版本数据失败，使用默认版本" "warn"
        printf '%s\n' "${default_versions[@]}"
        return
    fi
    
    debug "主版本号: $(echo "$major_versions" | tr '\n' ' ')"
    log "✓ 成功提取主版本号" "info"
    
    # 步骤3: 获取每个主版本的最新patch版本
    debug "步骤3: 获取最新patch版本..."
    while IFS= read -r major; do
        if [[ -n "$major" ]]; then
            debug "处理主版本: $major"
            local latest_patch=""
            if latest_patch=$(echo "$versions_output" | grep -E "^${major}\.[0-9]+$" | sort -V | tail -1 2>/dev/null); then
                if [[ -n "$latest_patch" ]]; then
                    debug "找到最新patch版本: $latest_patch"
                    final_versions+=("$latest_patch")
                fi
            fi
        fi
    done <<< "$major_versions"
    
    # 验证结果
    if [[ ${#final_versions[@]} -eq 0 ]]; then
        debug "未获取到任何有效版本，使用默认版本"
        log "⚠️ 无法获取有效版本，使用默认版本" "warn"
        printf '%s\n' "${default_versions[@]}"
    else
        debug "成功获取 ${#final_versions[@]} 个版本: ${final_versions[*]}"
        log "✓ 成功获取 ${#final_versions[@]} 个Python版本" "info"
        printf '%s\n' "${final_versions[@]}"
    fi
}

# 让用户选择Python版本
choose_python_version() {
    debug "开始版本选择流程..."
    log "准备版本选择..." "info"
    
    # 获取版本列表
    local versions=()
    local version_output=""
    
    debug "调用get_top3_python_versions..."
    if ! version_output=$(get_top3_python_versions 2>/dev/null); then
        debug "get_top3_python_versions调用失败"
        versions=("3.11.9" "3.12.4" "3.13.0")
        log "使用硬编码默认版本" "warn"
    else
        debug "版本输出: $version_output"
        while IFS= read -r line; do
            [[ -n "$line" ]] && versions+=("$line")
        done <<< "$version_output"
    fi
    
    # 确保至少有默认版本
    if [[ ${#versions[@]} -eq 0 ]]; then
        debug "versions数组为空，使用默认版本"
        versions=("3.11.9" "3.12.4" "3.13.0")
        log "使用默认Python版本列表" "info"
    fi
    
    debug "最终版本列表: ${versions[*]}"
    
    # 尝试获取最新版本标记
    debug "获取latest版本标记..."
    local latest_version=""
    latest_version=$("$MISE_PATH" latest python 2>/dev/null || echo "")
    debug "Latest版本: $latest_version"
    
    echo >&2
    echo "Python版本选择:" >&2
    
    for i in "${!versions[@]}"; do
        local version="${versions[$i]}"
        local label=""
        [[ -n "$latest_version" && "$version" == "$latest_version" ]] && label=" (latest)"
        echo "  $((i+1))) Python $version$label" >&2
        debug "显示选项 $((i+1)): $version$label"
    done
    
    echo "  4) 保持当前配置" >&2
    echo >&2
    
    local choice=""
    debug "等待用户输入..."
    read -p "请选择 [1-4] (默认: 2): " choice || choice="2"
    choice=${choice:-2}
    debug "用户选择: $choice"
    
    case "$choice" in
        1|2|3) 
            local idx=$((choice-1))
            if [[ $idx -lt ${#versions[@]} ]]; then
                debug "返回版本: ${versions[$idx]}"
                echo "${versions[$idx]}"
            else
                debug "索引超出范围，返回默认版本"
                echo "3.12.4"
            fi
            ;;
        4) 
            debug "用户选择保持当前配置"
            echo "current" 
            ;;
        *) 
            debug "无效选择，返回默认版本"
            echo "3.12.4" 
            ;;
    esac
}

# 获取已安装的Python版本列表
get_installed_python_versions() {
    debug "获取已安装的Python版本..."
    local result
    result=$("$MISE_PATH" ls python 2>/dev/null | awk '/^python/ {print $2}' | grep -E "^[0-9]+\.[0-9]+\.[0-9]+$" 2>/dev/null || true)
    debug "已安装版本: $result"
    echo "$result"
}

# 清理旧版本Python
cleanup_old_python_versions() {
    debug "开始清理旧Python版本..."
    local current_version="$1"
    debug "当前版本: $current_version"
    
    local installed_versions=""
    installed_versions=$(get_installed_python_versions)
    
    if [[ -n "$installed_versions" ]]; then
        installed_versions=$(echo "$installed_versions" | grep -v "^$current_version$" || true)
        debug "需要清理的版本: $installed_versions"
    fi
    
    if [[ -n "$installed_versions" ]]; then
        echo
        log "检测到其他Python版本:" "info"
        echo "$installed_versions" | sed 's/^/  - Python /'
        
        echo
        read -p "是否删除其他版本? [y/N] (默认: N): " -r cleanup_choice || cleanup_choice="N"
        debug "用户清理选择: $cleanup_choice"
        
        if [[ "$cleanup_choice" =~ ^[Yy]$ ]]; then
            while IFS= read -r version; do
                if [[ -n "$version" ]]; then
                    debug "删除版本: $version"
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
    debug "开始配置Python..."
    log "配置 Python..." "info"
    
    local current_version=""
    debug "获取当前Python版本..."
    current_version=$("$MISE_PATH" current python 2>/dev/null || echo "")
    debug "当前版本: $current_version"
    [[ -n "$current_version" ]] && log "当前Python版本: $current_version" "info"
    
    debug "调用choose_python_version..."
    local selected_version=""
    selected_version=$(choose_python_version)
    debug "选择的版本: $selected_version"
    
    if [[ "$selected_version" == "current" ]]; then
        log "保持当前Python配置" "info"
        debug "保持当前配置，退出setup_python"
        return 0
    fi
    
    log "安装 Python $selected_version..." "info"
    debug "执行mise use命令..."
    if "$MISE_PATH" use -g "python@$selected_version" 2>/dev/null; then
        log "✓ Python $selected_version 安装完成" "info"
        debug "Python安装成功，开始清理旧版本..."
        cleanup_old_python_versions "$selected_version" || true
    else
        log "✗ Python $selected_version 安装失败" "error"
        debug "Python安装失败"
        return 1
    fi
    debug "setup_python完成"
}

# 其余函数保持不变，添加相应的debug信息...
# [为了节省空间，我只展示关键的修改部分]

# === 主流程 ===
main() {
    debug "=== 脚本开始执行 ==="
    log "🔧 配置 Mise 版本管理器..." "info"
    
    # 显示当前状态
    echo
    if [[ -f "$MISE_PATH" ]]; then
        debug "检测到现有mise安装"
        log "检测到现有mise安装，正在分析系统状态..." "info"
        detect_python_status > /dev/null 2>&1 || true
    else
        debug "未检测到mise安装"
    fi
    
    echo
    debug "=== 步骤1: 安装mise ==="
    install_mise
    debug "install_mise完成"
    
    echo
    debug "=== 步骤2: 配置Python ==="
    log "开始配置Python..." "info"
    if setup_python; then
        debug "setup_python成功"
    else
        log "Python配置失败，但继续执行..." "warn"
        debug "setup_python失败但继续"
    fi
    
    echo
    debug "=== 步骤3: 配置使用方式 ==="
    setup_python_usage
    debug "setup_python_usage完成"
    
    echo
    debug "=== 步骤4: 配置Shell集成 ==="
    configure_shell_integration
    debug "configure_shell_integration完成"
    
    debug "=== 步骤5: 显示摘要 ==="
    show_mise_summary
    debug "show_mise_summary完成"
    
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
    log "  • 手动修复PATH: export PATH=\"/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:\$HOME/.local/bin\"" "info"
    
    # 检查是否需要重新登录
    local final_which_python
    final_which_python=$(which python3 2>/dev/null || echo "")
    if [[ "$final_which_python" == *"mise"* ]] && [[ ! "${1:-}" == "allow_global" ]]; then
        echo
        log "🔄 检测到PATH可能需要手动生效，请运行:" "warn"
        log "   source ~/.bashrc  # 或重新登录" "info"
    fi
    
    debug "=== 脚本执行完成 ==="
}

# 为了保持完整性，我需要添加其他函数的简化版本
show_project_usage_guide() {
    echo
    log "📝 项目级使用指南:" "info"
    local system_version
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
    echo
    read -p "确认要继续吗? 强烈建议选择'N' [y/N]: " -r confirm_choice || confirm_choice="N"
    
    if [[ "$confirm_choice" =~ ^[Yy]$ ]]; then
        log "执行全局替换..." "info"
        link_python_globally_original "allow_global"
        configure_path_for_global_mode
    else
        log "✓ 明智的选择！改为使用项目级模式" "info"
        fix_python_system_priority
        show_project_usage_guide
    fi
}

setup_python_usage() {
    debug "开始setup_python_usage..."
    log "配置 Python 使用方式..." "info"
    
    echo
    local needs_fix=1
    if detect_python_status > /dev/null 2>&1; then
        needs_fix=1  # 正常
    else
        needs_fix=0  # 需要修复
    fi
    
    echo
    echo "Python使用方式选择:"
    echo "  1) 仅项目级使用 (推荐)"
    echo "  2) 全局替换系统Python"
    
    if [[ $needs_fix -eq 0 ]]; then
        echo "  3) 修复系统Python配置"
    fi
    
    local usage_choice=""
    local default_choice=1
    [[ $needs_fix -eq 0 ]] && default_choice=3
    
    local max_choice=2
    [[ $needs_fix -eq 0 ]] && max_choice=3
    
    read -p "请选择 [1-$max_choice] (默认: $default_choice): " -r usage_choice || usage_choice="$default_choice"
    usage_choice=${usage_choice:-$default_choice}
    debug "用户选择使用方式: $usage_choice"
    
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
    debug "setup_python_usage完成"
}

link_python_globally_original() {
    log "创建系统Python链接..." "info"
    local python_path
    python_path=$("$MISE_PATH" which python 2>/dev/null || echo "")
    
    if [[ -x "$python_path" ]]; then
        [[ -L /usr/bin/python3 ]] && sudo cp -L /usr/bin/python3 /usr/bin/python3.backup 2>/dev/null || true
        sudo ln -sf "$python_path" /usr/bin/python
        sudo ln -sf "$python_path" /usr/bin/python3
        log "✓ Python链接已创建" "info"
    else
        log "✗ 无法找到Mise管理的Python，跳过链接创建" "warn"
    fi
}

configure_shell_integration() {
    debug "开始配置Shell集成..."
    log "配置 Shell 集成..." "info"
    
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
            log "$shell_name 集成已存在" "info"
        else
            if [[ "$shell_name" == "bash" ]]; then
                echo -e "\n# Mise version manager\n$activate_cmd" >> "$config_file"
            else
                echo -e "\n# Mise version manager\n$activate_cmd" >> "$config_file"
            fi
            log "✓ Mise 已添加到 $config_file" "info"
        fi
    done
    debug "Shell集成配置完成"
}

show_mise_summary() {
    debug "显示配置摘要..."
    echo
    log "🎯 Mise 配置摘要:" "info"
    
    if [[ -f "$MISE_PATH" ]]; then
        local mise_version
        mise_version=$(get_mise_version)
        log "  ✓ Mise版本: $mise_version" "info"
        
        if "$MISE_PATH" which python &>/dev/null; then
            local python_version
            python_version=$(get_python_version)
            local current_version
            current_version=$("$MISE_PATH" current python 2>/dev/null || echo "未知")
            log "  ✓ Mise Python: $python_version (当前: $current_version)" "info"
        else
            log "  ✗ Mise Python: 未配置" "info"
        fi
        
        local system_python_version
        system_python_version=$(/usr/bin/python3 --version 2>/dev/null || echo "无法获取")
        log "  ✓ 系统Python: $system_python_version" "info"
        
        local which_python
        which_python=$(which python3 2>/dev/null || echo "")
        if [[ "$which_python" == *"mise"* ]]; then
            log "  🛤️  PATH优先: mise Python" "warn"
        elif [[ "$which_python" == "/usr/bin/python3" ]]; then
            log "  🛤️  PATH优先: 系统Python (推荐)" "info"
        fi
        
        local tools_count
        tools_count=$("$MISE_PATH" list 2>/dev/null | wc -l || echo "0")
        log "  📦 已安装工具: $tools_count 个" "info"
    fi
}

main "$@"
