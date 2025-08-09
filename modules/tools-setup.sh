#!/bin/bash
# 系统工具配置模块 v2.1 - 智能配置版
# 功能: 安装常用系统和网络工具

set -euo pipefail

# === 常量定义 ===
readonly TOOLS=(
    "nexttrace:nexttrace --version:apt-nexttrace:网络路由追踪工具"
    "speedtest:speedtest --version:speedtest-cli:网络测速工具"
    "htop:htop --version:htop:增强版系统监控"
    "jq:jq --version:jq:JSON处理工具"
    "tree:tree --version:tree:目录树显示工具"
    "curl:curl --version:curl:数据传输工具"
    "wget:wget --version:wget:文件下载工具"
)

# === 日志函数 ===
log() {
    local msg="$1" level="${2:-info}"
    local -A colors=([info]="\033[0;36m" [warn]="\033[0;33m" [error]="\033[0;31m" [debug]="\033[0;35m")
    echo -e "${colors[$level]:-\033[0;32m}$msg\033[0m"
}

debug_log() {
    if [[ "${DEBUG:-}" == "1" ]]; then
        log "DEBUG: $1" "debug" >&2
    fi
    return 0
}

# === 辅助函数 ===
# 获取工具版本（简化版）
get_tool_version() {
    local tool_name="$1"
    local check_cmd="$2"
    
    debug_log "获取工具版本: $tool_name"
    
    local version_output
    version_output=$($check_cmd 2>/dev/null | head -n1 || echo "")
    
    # 统一的版本匹配逻辑
    if [[ "$version_output" =~ ([0-9]+\.[0-9]+(\.[0-9]+)?) ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo "已安装"
    fi
    return 0
}

# 检查工具状态
check_tool_status() {
    local tool_name="$1"
    local check_cmd="$2"
    
    debug_log "检查工具状态: $tool_name"
    
    if command -v "$tool_name" &>/dev/null; then
        if eval "$check_cmd" &>/dev/null; then
            local version=$(get_tool_version "$tool_name" "$check_cmd")
            echo "installed:$version"
        else
            echo "installed:未知版本"
        fi
    else
        echo "missing:"
    fi
    return 0
}

# 显示工具选择菜单
show_tool_menu() {
    debug_log "显示工具选择菜单"
    echo "可安装的工具:" >&2
    echo "  1) 全部安装 - 一次安装所有工具" >&2
    echo "  2) 网络工具 - NextTrace + SpeedTest" >&2
    echo "  3) 系统工具 - htop + tree + jq" >&2
    echo "  4) 基础工具 - curl + wget" >&2
    echo "  5) 自定义选择 - 手动选择要安装的工具" >&2
    echo "  6) 跳过安装" >&2
    echo "  7) 检查更新 - 重新安装已有工具到最新版本" >&2
    echo >&2
    return 0
}

# 根据分类获取工具列表
get_tools_by_category() {
    local category="$1"
    
    debug_log "获取工具分类: $category"
    
    case "$category" in
        "network") echo "nexttrace speedtest" ;;
        "system") echo "htop tree jq" ;;
        "basic") echo "curl wget" ;;
        "all"|"update") echo "nexttrace speedtest htop jq tree curl wget" ;;
        *) echo "" ;;
    esac
    return 0
}

# 处理现有nexttrace安装的迁移
handle_existing_nexttrace() {
    debug_log "检查现有nexttrace安装方式"
    
    # 刷新命令缓存，确保检测准确
    hash -r 2>/dev/null || true
    
    if ! command -v nexttrace >/dev/null 2>&1; then
        debug_log "未找到现有nexttrace"
        return 0  # 没有现有安装
    fi
    
    # 检查是否通过apt安装
    if dpkg-query -W -f='${Status}' nexttrace 2>/dev/null | grep -q "install ok installed"; then
        debug_log "检测到apt安装的nexttrace，跳过迁移"
        return 0  # 已经是apt安装，无需迁移
    fi
    
    # 备选检测方法
    if dpkg --get-selections 2>/dev/null | grep -q "nexttrace.*install"; then
        debug_log "检测到apt安装的nexttrace（备选方法），跳过迁移"
        return 0
    fi
    
    # 脚本安装的版本，需要迁移
    echo "检测到脚本安装的nexttrace，正在迁移到apt源..." >&2
    debug_log "开始迁移脚本安装的nexttrace到apt源"
    
    # 删除脚本安装的版本
    local nexttrace_paths=(
        "$(command -v nexttrace 2>/dev/null || true)"
        "/usr/local/bin/nexttrace"
        "/usr/bin/nexttrace"
    )
    
    for path in "${nexttrace_paths[@]}"; do
        if [[ -n "$path" && -f "$path" ]]; then
            debug_log "删除脚本安装的文件: $path"
            rm -f "$path" 2>/dev/null || true
        fi
    done
    
    # 清理PATH缓存
    hash -r 2>/dev/null || true
    return 1  # 返回1表示需要重新安装
}

# === 核心功能函数 ===
# 安装单个工具
install_single_tool() {
    local tool_name="$1"
    local install_source="$2"
    local force_reinstall="${3:-false}"
    
    debug_log "安装工具: $tool_name (强制重装: $force_reinstall)"
    
    if [[ "$install_source" == "apt-nexttrace" ]]; then
        # nexttrace专用的apt源安装
        debug_log "通过apt源安装nexttrace"
        
        # 先处理现有安装
        if ! handle_existing_nexttrace; then
            force_reinstall=true
            debug_log "脚本版本已清理，需要重新安装"
        fi
        
        if $force_reinstall; then
            debug_log "强制更新，先卸载现有apt版本"
            apt remove -y nexttrace >/dev/null 2>&1 || true
        fi
        
        # 添加官方apt源（如果不存在）
        if [[ ! -f /etc/apt/sources.list.d/nexttrace.list ]]; then
            debug_log "添加nexttrace官方apt源"
            echo "正在配置nexttrace官方源..." >&2
            if echo "deb [trusted=yes] https://github.com/nxtrace/nexttrace-debs/releases/latest/download ./" | \
                tee /etc/apt/sources.list.d/nexttrace.list >/dev/null 2>&1; then
                debug_log "nexttrace apt源配置成功"
            else
                debug_log "nexttrace apt源配置失败"
                return 1
            fi
        fi
        
        # 更新包列表并安装
        debug_log "更新包列表并安装nexttrace"
        if apt update -qq >/dev/null 2>&1 && apt install -y nexttrace >/dev/null 2>&1; then
            debug_log "nexttrace通过apt源安装成功"
            return 0
        else
            debug_log "nexttrace通过apt源安装失败"
            return 1
        fi
        
    elif [[ "$install_source" == https://* ]]; then
        # 其他工具的脚本安装
        debug_log "通过脚本安装: $tool_name"
        if curl -fsSL "$install_source" | bash >/dev/null 2>&1; then
            debug_log "脚本安装成功: $tool_name"
            return 0
        else
            debug_log "脚本安装失败: $tool_name"
            return 1
        fi
    else
        # 通过包管理器安装
        debug_log "通过包管理器安装: $tool_name"
        if apt update -qq >/dev/null 2>&1 && apt install -y "$install_source" >/dev/null 2>&1; then
            debug_log "包管理器安装成功: $tool_name"
            return 0
        else
            debug_log "包管理器安装失败: $tool_name"
            return 1
        fi
    fi
}

# 获取用户选择
get_user_choice() {
    debug_log "获取用户选择"
    show_tool_menu
    
    local choice
    read -p "请选择 [1-7] (默认: 1): " choice >&2 || choice="1"
    choice=${choice:-1}
    
    debug_log "用户选择: $choice"
    
    case "$choice" in
        1) echo "all" ;;
        2) echo "network" ;;
        3) echo "system" ;;
        4) echo "basic" ;;
        5) echo "custom" ;;
        6) echo "skip" ;;
        7) echo "update" ;;
        *) echo "all" ;;
    esac
    return 0
}

# 自定义选择工具
custom_tool_selection() {
    debug_log "进入自定义工具选择"
    echo "选择要安装的工具 (多选用空格分隔，如: 1 3 5):" >&2
    for i in "${!TOOLS[@]}"; do
        local tool_info="${TOOLS[$i]}"
        local tool_name="${tool_info%%:*}"
        local description="${tool_info##*:}"
        echo "  $((i+1))) $tool_name - $description" >&2
    done
    echo >&2
    
    local choices
    read -p "请输入数字 (默认: 全选): " choices >&2 || choices=""
    
    if [[ -z "$choices" ]]; then
        debug_log "用户未输入，默认全选"
        echo "nexttrace speedtest htop jq tree curl wget"
        return 0
    fi
    
    debug_log "用户选择: $choices"
    local selected_tools=()
    for choice in $choices; do
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#TOOLS[@]} ]]; then
            local idx=$((choice-1))
            local tool_info="${TOOLS[$idx]}"
            local tool_name="${tool_info%%:*}"
            selected_tools+=("$tool_name")
        fi
    done
    
    debug_log "最终选择的工具: ${selected_tools[*]}"
    echo "${selected_tools[*]}"
    return 0
}

# 安装选定的工具
install_selected_tools() {
    local category="$1"
    local force_install=false
    
    debug_log "开始安装工具，类别: $category"
    
    if [[ "$category" == "update" ]]; then
        force_install=true
    fi
    
    local tools_to_install
    if [[ "$category" == "custom" ]]; then
        tools_to_install=$(custom_tool_selection)
    else
        tools_to_install=$(get_tools_by_category "$category")
    fi
    
    if [[ -z "$tools_to_install" ]]; then
        debug_log "没有工具需要安装"
        return 0
    fi
    
    debug_log "准备安装的工具: $tools_to_install"
    
    local installed_count=0 failed_count=0 updated_count=0 skipped_count=0
    local installed_tools=() failed_tools=() updated_tools=() skipped_tools=()
    
    for tool_name in $tools_to_install; do
        debug_log "处理工具: $tool_name"
        local tool_found=false
        
        for tool_info in "${TOOLS[@]}"; do
            local info_name="${tool_info%%:*}"
            if [[ "$info_name" == "$tool_name" ]]; then
                local check_cmd=$(echo "$tool_info" | cut -d: -f2)
                local install_source=$(echo "$tool_info" | cut -d: -f3)
                
                local status=$(check_tool_status "$tool_name" "$check_cmd" || echo "missing:")
                local was_installed=false old_version=""
                
                if [[ "$status" == installed:* ]]; then
                    old_version="${status#installed:}"
                    was_installed=true
                    
                    # nexttrace特殊处理：检查是否需要迁移到apt源
                    if [[ "$tool_name" == "nexttrace" && "$install_source" == "apt-nexttrace" ]]; then
                        debug_log "检查nexttrace是否需要迁移到apt源"
                        if ! handle_existing_nexttrace; then
                            debug_log "nexttrace需要迁移到apt源"
                            echo "正在迁移nexttrace到apt源..."
                            # 继续执行安装逻辑
                        elif ! $force_install; then
                            debug_log "nexttrace已通过apt安装，跳过"
                            installed_tools+=("$tool_name($old_version)")
                            tool_found=true
                            break
                        fi
                    elif ! $force_install; then
                        debug_log "工具 $tool_name 已安装，版本: $old_version"
                        installed_tools+=("$tool_name($old_version)")
                        tool_found=true
                        break
                    fi
                fi
                
                # 执行安装
                debug_log "开始安装 $tool_name"
                if install_single_tool "$tool_name" "$install_source" "$force_install"; then
                    debug_log "工具 $tool_name 安装成功，重新检查版本"
                    hash -r 2>/dev/null || true
                    sleep 1  # 等待安装生效
                    
                    local new_status=$(check_tool_status "$tool_name" "$check_cmd" || echo "installed:已安装")
                    if [[ "$new_status" == installed:* ]]; then
                        local new_version="${new_status#installed:}"
                        
                        if $was_installed; then
                            if [[ "$new_version" != "$old_version" ]] && [[ "$new_version" != "已安装" ]] && [[ "$old_version" != "已安装" ]]; then
                                updated_tools+=("$tool_name($old_version→$new_version)")
                                ((updated_count++))
                            else
                                skipped_tools+=("$tool_name($new_version)")
                                ((skipped_count++))
                            fi
                        else
                            installed_tools+=("$tool_name($new_version)")
                            ((installed_count++))
                        fi
                    else
                        if $was_installed; then
                            skipped_tools+=("$tool_name($old_version)")
                            ((skipped_count++))
                        else
                            failed_tools+=("$tool_name")
                            ((failed_count++))
                        fi
                    fi
                else
                    debug_log "工具 $tool_name 安装失败"
                    if $was_installed; then
                        skipped_tools+=("$tool_name($old_version)")
                        ((skipped_count++))
                    else
                        failed_tools+=("$tool_name")
                        ((failed_count++))
                    fi
                fi
                
                tool_found=true
                break
            fi
        done
        
        if ! $tool_found; then
            debug_log "未找到工具定义: $tool_name"
            failed_tools+=("$tool_name")
            ((failed_count++))
        fi
    done
    
    # 输出结果
    if [[ ${#installed_tools[@]} -gt 0 ]]; then
        if $force_install; then
            echo "新安装工具: ${installed_tools[*]}"
        else
            echo "工具状态: ${installed_tools[*]}"
        fi
    fi
    
    [[ ${#updated_tools[@]} -gt 0 ]] && echo "版本更新: ${updated_tools[*]}"
    [[ ${#skipped_tools[@]} -gt 0 ]] && echo "重新安装: ${skipped_tools[*]}"
    [[ ${#failed_tools[@]} -gt 0 ]] && echo "安装失败: ${failed_tools[*]}"
    
    # 统计输出
    local success_operations=$((installed_count + updated_count + skipped_count))
    if [[ $success_operations -gt 0 ]]; then
        local operations=()
        [[ $installed_count -gt 0 ]] && operations+=("新装${installed_count}个")
        [[ $updated_count -gt 0 ]] && operations+=("更新${updated_count}个")
        [[ $skipped_count -gt 0 ]] && operations+=("重装${skipped_count}个")
        echo "操作完成: ${operations[*]}"
    fi
    return 0
}

# 显示配置摘要
show_tools_summary() {
    debug_log "显示工具摘要"
    echo
    log "🎯 系统工具摘要:" "info"
    
    local installed_tools=() missing_tools=()
    
    for tool_info in "${TOOLS[@]}"; do
        local tool_name="${tool_info%%:*}"
        local check_cmd=$(echo "$tool_info" | cut -d: -f2)
        
        local status=$(check_tool_status "$tool_name" "$check_cmd" || echo "missing:")
        if [[ "$status" == installed:* ]]; then
            local version="${status#installed:}"
            installed_tools+=("$tool_name($version)")
        else
            missing_tools+=("$tool_name")
        fi
    done
    
    [[ ${#installed_tools[@]} -gt 0 ]] && echo "  ✓ 已安装: ${installed_tools[*]}"
    [[ ${#missing_tools[@]} -gt 0 ]] && echo "  ✗ 未安装: ${missing_tools[*]}"
    
    # 显示常用命令
    echo "  💡 常用命令:"
    local has_commands=false
    
    local commands=(
        "nexttrace:网络追踪: nexttrace ip.sb"
        "speedtest:网速测试: speedtest"
        "htop:系统监控: htop"
        "tree:目录树: tree /path/to/dir"
        "jq:JSON处理: echo '{}' | jq ."
    )
    
    for cmd_info in "${commands[@]}"; do
        local cmd_name="${cmd_info%%:*}"
        local cmd_desc="${cmd_info#*:}"
        if command -v "$cmd_name" >/dev/null 2>&1; then
            echo "    $cmd_desc"
            has_commands=true
        fi
    done
    
    [[ $has_commands == false ]] && echo "    暂无可用工具"
    
    return 0
}

# === 主流程 ===
main() {
    log "🛠️ 配置系统工具..." "info"
    
    echo
    local choice=$(get_user_choice)
    
    if [[ "$choice" == "skip" ]]; then
        echo "工具安装: 跳过"
        debug_log "用户选择跳过工具安装"
    else
        echo
        case "$choice" in
            "all") echo "安装模式: 全部工具" ;;
            "network") echo "安装模式: 网络工具" ;;
            "system") echo "安装模式: 系统工具" ;;
            "basic") echo "安装模式: 基础工具" ;;
            "custom") echo "安装模式: 自定义选择" ;;
            "update") echo "更新模式: 检查更新已安装工具" ;;
        esac
        
        debug_log "开始安装选定工具"
        install_selected_tools "$choice" || {
            debug_log "工具安装过程中出现错误，但继续执行"
            true
        }
    fi
    
    debug_log "显示工具摘要"
    show_tools_summary || {
        debug_log "显示摘要失败，但继续执行"
        true
    }
    
    echo
    log "✅ 系统工具配置完成!" "info"
    
    return 0
}

# 错误处理
trap 'log "脚本执行出错，行号: $LINENO" "error"; exit 1' ERR

main "$@"
