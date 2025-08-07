#!/bin/bash
# Mise 版本管理器配置模块 v4.7.4
# 修复: 分离调试输出和函数返回值，避免数据污染

set -euo pipefail

trap 'echo "❌ 脚本在第 $LINENO 行失败，命令: $BASH_COMMAND" >&2; exit 1' ERR

readonly MISE_PATH="$HOME/.local/bin/mise"
readonly MISE_BIN_DIR="$HOME/.local/bin"

log() {
    local msg="$1" level="${2:-info}"
    local -A colors=([info]="\033[0;36m" [warn]="\033[0;33m" [error]="\033[0;31m" [debug]="\033[0;35m")
    echo -e "${colors[$level]:-\033[0;32m}$msg\033[0m" >&2  # 输出到stderr
}

debug() {
    log "🔍 DEBUG: $1" "debug"
}

# === 系统状态检测函数 ===
detect_python_status() {
    debug "开始检测Python状态..."
    local status_info="" link_status="正常"
    
    if [[ -L /usr/bin/python3 ]]; then
        local python3_target=$(readlink /usr/bin/python3 2>/dev/null || echo "")
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
    
    local which_python=$(which python3 2>/dev/null || echo "")
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
    
    local current_python_version=$(python3 --version 2>/dev/null || echo '无法获取版本')
    local system_python_version=$(/usr/bin/python3 --version 2>/dev/null || echo '系统Python不可用')
    log "  当前版本: $current_python_version" "info"
    log "  系统Python: $system_python_version" "info"
    
    local apt_pkg_status="不可用 ✗"
    local debconf_status="不可用 ✗"
    
    if /usr/bin/python3 -c "import apt_pkg" >/dev/null 2>&1; then
        apt_pkg_status="可用 ✓"
    fi
    
    if /usr/bin/python3 -c "import debconf" >/dev/null 2>&1; then
        debconf_status="可用 ✓"
    fi
    
    log "  系统模块: apt_pkg $apt_pkg_status, debconf $debconf_status" "info"
    
    if [[ "$link_status" == "劫持" || "$path_priority" == "劫持" ]] && [[ ! "${1:-}" == "allow_global" ]]; then
        return 0  # 需要修复
    else
        return 1  # 状态正常
    fi
}

# 自动修复系统模块
fix_system_modules() {
    debug "开始检查系统模块..."
    local apt_pkg_ok=false debconf_ok=false
    
    if /usr/bin/python3 -c "import apt_pkg" >/dev/null 2>&1; then
        apt_pkg_ok=true
    fi
    
    if /usr/bin/python3 -c "import debconf" >/dev/null 2>&1; then
        debconf_ok=true
    fi
    
    if $apt_pkg_ok && $debconf_ok; then
        return 0
    fi
    
    log "🔧 检测到系统模块缺失，正在自动修复..." "warn"
    
    if sudo apt install --reinstall python3-apt python3-debconf >/dev/null 2>&1; then
        log "✓ 系统模块修复成功" "info"
        return 0
    fi
    
    log "重装失败，尝试完全重新安装..." "info"
    sudo apt remove --purge python3-apt python3-debconf >/dev/null 2>&1 || true
    sudo apt autoremove >/dev/null 2>&1 || true
    
    if sudo apt install python3-apt python3-debconf >/dev/null 2>&1; then
        log "✓ 系统模块完全重装成功" "info"
        return 0
    else
        log "✗ 系统模块自动修复失败，请手动处理" "error"
        return 1
    fi
}

# 修复系统Python链接和PATH
fix_python_system_priority() {
    debug "开始修复系统Python优先级..."
    log "🔧 修复系统Python优先级..." "info"
    
    if [[ -L /usr/bin/python3 ]]; then
        local python3_target=$(readlink /usr/bin/python3 2>/dev/null || echo "")
        if [[ -n "$python3_target" && "$python3_target" == *"mise"* ]]; then
            log "修复被劫持的系统Python链接..." "info"
            sudo rm /usr/bin/python3 2>/dev/null || true
            
            if [[ -x /usr/bin/python3.11 ]]; then
                sudo ln -sf /usr/bin/python3.11 /usr/bin/python3
                log "✓ 已链接到系统Python 3.11" "info"
            elif [[ -x /usr/bin/python3.10 ]]; then
                sudo ln -sf /usr/bin/python3.10 /usr/bin/python3
                log "✓ 已链接到系统Python 3.10" "info"
            else
                log "✗ 未找到合适的系统Python版本" "error"
                return 1
            fi
        fi
    fi
    
    configure_path_priority
    export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$HOME/.local/bin"
    hash -r 2>/dev/null || true
    
    local new_which_python=$(which python3 2>/dev/null || echo "")
    if [[ "$new_which_python" == "/usr/bin/python3" ]]; then
        log "✓ PATH优先级修复成功，立即生效" "info"
        fix_system_modules || true
        
        if python3 -c "import apt_pkg" &>/dev/null 2>&1; then
            log "✓ 系统模块现在可用" "info"
        fi
    else
        log "⚠️ PATH修复异常，当前指向：$new_which_python" "warn"
    fi
    
    echo
    log "修复后状态:" "info"
    log "  系统链接: $(readlink /usr/bin/python3 2>/dev/null || echo '直接文件')" "info"
    log "  当前python3: $(which python3)" "info"
    log "  版本: $(python3 --version)" "info"
}

configure_path_priority() {
    local shells=("bash:$HOME/.bashrc" "zsh:$HOME/.zshrc")
    
    for shell_info in "${shells[@]}"; do
        local shell_name="${shell_info%%:*}"
        local config_file="${shell_info#*:}"
        
        command -v "$shell_name" &>/dev/null || continue
        [[ ! -f "$config_file" ]] && touch "$config_file"
        
        sed -i '/# Mise PATH priority/,+1d' "$config_file" 2>/dev/null || true
        sed -i '/# Mise global mode PATH/,+1d' "$config_file" 2>/dev/null || true
        
        cat >> "$config_file" << 'EOF'

# Mise PATH priority - 确保系统工具使用系统Python
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$HOME/.local/bin"
EOF
        log "✓ 已配置 $shell_name PATH优先级" "info"
    done
}

configure_path_for_global_mode() {
    local shells=("bash:$HOME/.bashrc" "zsh:$HOME/.zshrc")
    
    for shell_info in "${shells[@]}"; do
        local shell_name="${shell_info%%:*}"
        local config_file="${shell_info#*:}"
        
        command -v "$shell_name" &>/dev/null || continue
        [[ ! -f "$config_file" ]] && touch "$config_file"
        
        sed -i '/# Mise PATH priority/,+1d' "$config_file" 2>/dev/null || true
        sed -i '/# Mise global mode PATH/,+1d' "$config_file" 2>/dev/null || true
        
        cat >> "$config_file" << 'EOF'

# Mise global mode PATH - mise Python 优先
export PATH="$HOME/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
EOF
        log "✓ 已配置 $shell_name 全局模式PATH" "info"
    done
    
    export PATH="$HOME/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    hash -r 2>/dev/null || true
}

# === 核心功能函数 ===
get_mise_version() {
    local version_output=$("$MISE_PATH" --version 2>/dev/null || echo "")
    if [[ "$version_output" =~ v?([0-9]+\.[0-9]+\.[0-9]+) ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo "未知"
    fi
}

get_python_version() {
    local python_path=$("$MISE_PATH" which python 2>/dev/null || echo "")
    
    if [[ -x "$python_path" ]]; then
        echo "$($python_path --version 2>/dev/null || echo "")"
    else
        echo "$("$MISE_PATH" exec python -- --version 2>/dev/null || echo "版本获取失败")"
    fi
}

install_mise() {
    debug "开始安装或更新Mise..."
    log "检查并安装 Mise..." "info"
    mkdir -p "$MISE_BIN_DIR"
    
    if [[ -f "$MISE_PATH" ]]; then
        local mise_version=$(get_mise_version)
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
    
    [[ ! -f "$MISE_PATH" ]] && { log "✗ 安装验证失败" "error"; exit 1; }
}

# **关键修复：确保只输出版本号到stdout，调试信息到stderr**
get_top3_python_versions() {
    debug "开始获取Python版本列表..."
    
    local default_versions=("3.11.9" "3.12.4" "3.13.0")
    
    # 获取所有版本，调试信息输出到stderr
    local versions_output=""
    if ! versions_output=$("$MISE_PATH" ls-remote python 2>/dev/null); then
        debug "获取远程版本失败，使用默认版本"
        printf '%s\n' "${default_versions[@]}"
        return
    fi
    
    debug "远程版本获取成功"
    
    # 提取主版本号
    local major_versions=""
    if ! major_versions=$(echo "$versions_output" | grep -E "^[0-9]+\.[0-9]+\.[0-9]+$" | sed -E 's/^([0-9]+\.[0-9]+)\.[0-9]+$/\1/' | sort -V -u | tail -3 2>/dev/null); then
        debug "处理版本数据失败"
        printf '%s\n' "${default_versions[@]}"
        return
    fi
    
    debug "成功提取主版本号"
    
    # 获取每个主版本的最新patch版本
    local final_versions=()
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
    
    # 验证并输出结果（只输出版本号到stdout）
    if [[ ${#final_versions[@]} -eq 0 ]]; then
        debug "未获取到有效版本，使用默认版本"
        printf '%s\n' "${default_versions[@]}"
    else
        debug "成功获取 ${#final_versions[@]} 个版本"
        printf '%s\n' "${final_versions[@]}"
    fi
}

# **修复版本选择函数**
choose_python_version() {
    debug "开始版本选择流程..."
    
    # 获取版本列表（只获取版本号）
    local versions=()
    local version_output=""
    
    # 重要：从stdout获取版本，stderr的调试信息不会影响
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
    
    debug "最终版本列表: ${versions[*]}"
    
    # 获取latest标记
    local latest_version=$("$MISE_PATH" latest python 2>/dev/null || echo "")
    
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
    
    debug "用户选择: $choice"
    
    case "$choice" in
        1|2|3) 
            local idx=$((choice-1))
            if [[ $idx -lt ${#versions[@]} ]]; then
                echo "${versions[$idx]}"
                debug "返回版本: ${versions[$idx]}"
            else
                echo "3.12.4"
                debug "索引超出范围，返回默认版本"
            fi
            ;;
        4) 
            echo "current"
            debug "用户选择保持当前配置"
            ;;
        *) 
            echo "3.12.4"
            debug "无效选择，返回默认版本"
            ;;
    esac
}

get_installed_python_versions() {
    "$MISE_PATH" ls python 2>/dev/null | awk '/^python/ {print $2}' | grep -E "^[0-9]+\.[0-9]+\.[0-9]+$" 2>/dev/null || true
}

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

setup_python() {
    debug "开始配置Python..."
    log "配置 Python..." "info"
    
    local current_version=$("$MISE_PATH" current python 2>/dev/null || echo "")
    [[ -n "$current_version" ]] && log "当前Python版本: $current_version" "info"
    
    # 获取选择的版本
    local selected_version=$(choose_python_version)
    debug "选择的版本: '$selected_version'"
    
    if [[ "$selected_version" == "current" ]]; then
        log "保持当前Python配置" "info"
        return 0
    fi
    
    log "安装 Python $selected_version..." "info"
    debug "执行mise use命令: python@$selected_version"
    
    if "$MISE_PATH" use -g "python@$selected_version" 2>/dev/null; then
        log "✓ Python $selected_version 安装完成" "info"
        cleanup_old_python_versions "$selected_version" || true
    else
        log "✗ Python $selected_version 安装失败" "error"
        debug "mise use命令失败"
        return 1
    fi
}

# 其他函数保持简化版本...
show_project_usage_guide() {
    echo
    log "📝 项目级使用指南:" "info"
    local system_version=$(/usr/bin/python3 --version 2>/dev/null || echo '获取失败')
    log "  • 系统级: 自动使用系统Python ($system_version)" "info"
    log "  • 项目级: cd your_project && mise use python@3.12.11" "info"
    log "  • 临时使用: mise exec python@3.12.11 -- python script.py" "info"
    log "  • 查看当前: mise current python" "info"
    log "  • 全局设置: mise use -g python@3.12.11" "info"
}

confirm_global_replacement() {
    echo
    log "⚠️  警告: 即将进行全局Python替换！" "warn"
    read -p "确认要继续吗? [y/N]: " -r confirm_choice || confirm_choice="N"
    
    if [[ "$confirm_choice" =~ ^[Yy]$ ]]; then
        link_python_globally_original "allow_global"
        configure_path_for_global_mode
    else
        log "✓ 改为使用项目级模式" "info"
        fix_python_system_priority
        show_project_usage_guide
    fi
}

setup_python_usage() {
    log "配置 Python 使用方式..." "info"
    
    echo
    local needs_fix=1
    if detect_python_status > /dev/null 2>&1; then
        needs_fix=1
    else
        needs_fix=0
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
    
    case "$usage_choice" in
        1)
            log "✓ 配置为项目级使用模式（推荐）" "info"
            fix_python_system_priority
            show_project_usage_guide
            ;;
        2) confirm_global_replacement ;;
        3)
            if [[ $needs_fix -eq 0 ]]; then
                log "🔧 执行系统修复..." "info"
                fix_python_system_priority
                show_project_usage_guide
            else
                fix_python_system_priority
                show_project_usage_guide
            fi
            ;;
        *)
            fix_python_system_priority
            show_project_usage_guide
            ;;
    esac
}

link_python_globally_original() {
    log "创建系统Python链接..." "info"
    local python_path=$("$MISE_PATH" which python 2>/dev/null || echo "")
    
    if [[ -x "$python_path" ]]; then
        [[ -L /usr/bin/python3 ]] && sudo cp -L /usr/bin/python3 /usr/bin/python3.backup 2>/dev/null || true
        sudo ln -sf "$python_path" /usr/bin/python
        sudo ln -sf "$python_path" /usr/bin/python3
        log "✓ Python链接已创建" "info"
    fi
}

configure_shell_integration() {
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
            echo -e "\n# Mise version manager\n$activate_cmd" >> "$config_file"
            log "✓ Mise 已添加到 $config_file" "info"
        fi
    done
}

show_mise_summary() {
    echo
    log "🎯 Mise 配置摘要:" "info"
    
    if [[ -f "$MISE_PATH" ]]; then
        local mise_version=$(get_mise_version)
        log "  ✓ Mise版本: $mise_version" "info"
        
        if "$MISE_PATH" which python &>/dev/null; then
            local python_version=$(get_python_version)
            local current_version=$("$MISE_PATH" current python 2>/dev/null || echo "未知")
            log "  ✓ Mise Python: $python_version (当前: $current_version)" "info"
        else
            log "  ✗ Mise Python: 未配置" "info"
        fi
        
        local system_python_version=$(/usr/bin/python3 --version 2>/dev/null || echo "无法获取")
        log "  ✓ 系统Python: $system_python_version" "info"
        
        local which_python=$(which python3 2>/dev/null || echo "")
        if [[ "$which_python" == *"mise"* ]]; then
            log "  🛤️  PATH优先: mise Python" "warn"
        elif [[ "$which_python" == "/usr/bin/python3" ]]; then
            log "  🛤️  PATH优先: 系统Python (推荐)" "info"
        fi
        
        local tools_count=$("$MISE_PATH" list 2>/dev/null | wc -l || echo "0")
        log "  📦 已安装工具: $tools_count 个" "info"
        
        local system_module_status="正常可用 ✓"
        if ! python3 -c "import apt_pkg" &>/dev/null 2>&1; then
            system_module_status="有问题 ⚠️"
        fi
        log "  🧩 系统模块: $system_module_status" "info"
    fi
}

# === 主流程 ===
main() {
    debug "=== 脚本开始执行 ==="
    log "🔧 配置 Mise 版本管理器..." "info"
    
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
        debug "setup_python成功"
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
    
    if [[ -f "$MISE_PATH" ]]; then
        echo
        log "常用命令:" "info"
        log "  查看工具: $MISE_PATH list" "info"
        log "  项目使用: $MISE_PATH use python@3.12.11" "info"
        log "  全局设置: $MISE_PATH use -g python@3.12.11" "info"
        log "  查看当前: $MISE_PATH current" "info"
        log "  查看帮助: $MISE_PATH --help" "info"
    fi
    
    echo
    log "⚠️  重要提醒:" "warn"
    log "  • 如遇apt工具报错，重新运行此脚本选择'修复系统配置'" "info"
    log "  • 推荐使用项目级模式，避免影响系统工具" "info"
    
    local final_which_python=$(which python3 2>/dev/null || echo "")
    if [[ "$final_which_python" == *"mise"* ]] && [[ ! "${1:-}" == "allow_global" ]]; then
        echo
        log "🔄 PATH需要重新登录生效，或运行: source ~/.bashrc" "warn"
    fi
}

main "$@"
