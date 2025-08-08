#!/bin/bash
# 系统工具配置模块 v1.1
# 功能: 安装常用系统和网络工具

set -euo pipefail

# === 日志函数 ===
log() {
    local msg="$1" level="${2:-info}"
    local -A colors=([info]="\033[0;36m" [warn]="\033[0;33m" [error]="\033[0;31m")
    echo -e "${colors[$level]:-\033[0;32m}$msg\033[0m"
}

# === 工具定义 ===
# 格式: "工具名:检查命令:安装脚本URL或包名:描述"
readonly TOOLS=(
    "nexttrace:nexttrace -V:https://github.com/sjlleo/nexttrace/raw/main/nt_install.sh:网络路由追踪工具"
    "speedtest:speedtest --version:speedtest-cli:网络测速工具"
    "htop:htop --version:htop:增强版系统监控"
    "jq:jq --version:jq:JSON处理工具"
    "tree:tree --version:tree:目录树显示工具"
    "curl:curl --version:curl:数据传输工具"
    "wget:wget --version:wget:文件下载工具"
)

# === 核心函数 ===

# 获取工具版本
get_tool_version() {
    local tool_name="$1"
    local check_cmd="$2"
    
    case "$tool_name" in
        "nexttrace")
            local version_output
            version_output=$($check_cmd 2>&1 | head -n1 2>/dev/null || echo "")
            if [[ "$version_output" =~ v?([0-9]+\.[0-9]+\.[0-9]+) ]]; then
                echo "${BASH_REMATCH[1]}"
            else
                echo "未知"
            fi
            ;;
        "speedtest")
            local version_output
            version_output=$($check_cmd 2>/dev/null | head -n1 || echo "")
            if [[ "$version_output" =~ ([0-9]+\.[0-9]+\.[0-9]+) ]]; then
                echo "${BASH_REMATCH[1]}"
            else
                echo "未知"
            fi
            ;;
        *)
            local version_output
            version_output=$($check_cmd 2>/dev/null | head -n1 || echo "")
            if [[ "$version_output" =~ ([0-9]+\.[0-9]+(\.[0-9]+)?) ]]; then
                echo "${BASH_REMATCH[1]}"
            else
                echo "已安装"
            fi
            ;;
    esac
}

# 检查工具状态
check_tool_status() {
    local tool_name="$1"
    local check_cmd="$2"
    
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
}

# 安装单个工具
install_single_tool() {
    local tool_name="$1"
    local install_source="$2"
    
    if [[ "$install_source" == https://* ]]; then
        # 通过脚本安装
        if curl -fsSL "$install_source" | bash >/dev/null 2>&1; then
            return 0
        else
            return 1
        fi
    else
        # 通过包管理器安装
        if apt update -qq && apt install -y "$install_source" >/dev/null 2>&1; then
            return 0
        else
            return 1
        fi
    fi
}

# 显示工具选择菜单
show_tool_menu() {
    echo "可安装的工具:" >&2
    echo "  1) 全部安装 - 一次安装所有工具" >&2
    echo "  2) 网络工具 - NextTrace + SpeedTest" >&2
    echo "  3) 系统工具 - htop + tree + jq" >&2
    echo "  4) 基础工具 - curl + wget" >&2
    echo "  5) 自定义选择 - 手动选择要安装的工具" >&2
    echo "  6) 跳过安装" >&2
    echo "  7) 检查更新 - 重新安装已有工具到最新版本" >&2
    echo >&2
}

# 获取用户选择
get_user_choice() {
    show_tool_menu
    
    local choice
    read -p "请选择 [1-7] (默认: 1): " choice >&2
    choice=${choice:-1}
    
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
}

# 根据分类获取工具列表
get_tools_by_category() {
    local category="$1"
    
    case "$category" in
        "network") echo "nexttrace speedtest" ;;
        "system") echo "htop tree jq" ;;
        "basic") echo "curl wget" ;;
        "all"|"update") echo "nexttrace speedtest htop jq tree curl wget" ;;
        *) echo "" ;;
    esac
}

# 自定义选择工具
custom_tool_selection() {
    local selected_tools=()
    
    echo "选择要安装的工具 (多选用空格分隔，如: 1 3 5):" >&2
    for i in "${!TOOLS[@]}"; do
        local tool_info="${TOOLS[$i]}"
        local tool_name="${tool_info%%:*}"
        local description="${tool_info##*:}"
        echo "  $((i+1))) $tool_name - $description" >&2
    done
    echo >&2
    
    local choices
    read -p "请输入数字 (默认: 全选): " choices >&2
    
    if [[ -z "$choices" ]]; then
        echo "nexttrace speedtest htop jq tree curl wget"
        return
    fi
    
    for choice in $choices; do
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#TOOLS[@]} ]]; then
            local idx=$((choice-1))
            local tool_info="${TOOLS[$idx]}"
            local tool_name="${tool_info%%:*}"
            selected_tools+=("$tool_name")
        fi
    done
    
    echo "${selected_tools[*]}"
}

# 安装选定的工具
install_selected_tools() {
    local category="$1"
    local tools_to_install
    local force_install=false
    
    if [[ "$category" == "update" ]]; then
        force_install=true
        tools_to_install=$(get_tools_by_category "$category")
    elif [[ "$category" == "custom" ]]; then
        tools_to_install=$(custom_tool_selection)
    else
        tools_to_install=$(get_tools_by_category "$category")
    fi
    
    if [[ -z "$tools_to_install" ]]; then
        return 0
    fi
    
    local installed_count=0
    local failed_count=0
    local updated_count=0
    local installed_tools=()
    local failed_tools=()
    local updated_tools=()
    
    for tool_name in $tools_to_install; do
        # 查找工具信息
        local tool_found=false
        for tool_info in "${TOOLS[@]}"; do
            local info_name="${tool_info%%:*}"
            if [[ "$info_name" == "$tool_name" ]]; then
                local check_cmd=$(echo "$tool_info" | cut -d: -f2)
                local install_source=$(echo "$tool_info" | cut -d: -f3)
                
                local status=$(check_tool_status "$tool_name" "$check_cmd")
                local was_installed=false
                
                if [[ "$status" == installed:* ]]; then
                    local old_version="${status#installed:}"
                    was_installed=true
                    
                    if ! $force_install; then
                        # 普通安装模式：跳过已安装的工具
                        installed_tools+=("$tool_name($old_version)")
                        tool_found=true
                        break
                    fi
                fi
                
                # 执行安装（新安装或强制重装）
                if install_single_tool "$tool_name" "$install_source"; then
                    # 重新检查版本
                    sleep 1
                    local new_status=$(check_tool_status "$tool_name" "$check_cmd")
                    if [[ "$new_status" == installed:* ]]; then
                        local new_version="${new_status#installed:}"
                        
                        if $was_installed; then
                            # 这是更新
                            updated_tools+=("$tool_name($new_version)")
                            ((updated_count++))
                        else
                            # 这是新安装
                            installed_tools+=("$tool_name($new_version)")
                            ((installed_count++))
                        fi
                    else
                        failed_tools+=("$tool_name")
                        ((failed_count++))
                    fi
                else
                    failed_tools+=("$tool_name")
                    ((failed_count++))
                fi
                
                tool_found=true
                break
            fi
        done
        
        if ! $tool_found; then
            failed_tools+=("$tool_name")
            ((failed_count++))
        fi
    done
    
    # 输出结果
    if [[ ${#installed_tools[@]} -gt 0 ]]; then
        if $force_install; then
            echo "保持版本: ${installed_tools[*]}"
        else
            echo "工具状态: ${installed_tools[*]}"
        fi
    fi
    
    if [[ ${#updated_tools[@]} -gt 0 ]]; then
        echo "已更新工具: ${updated_tools[*]}"
    fi
    
    if [[ $failed_count -gt 0 ]]; then
        echo "安装失败: ${failed_tools[*]}"
    fi
    
    if [[ $installed_count -gt 0 ]]; then
        echo "新安装工具: ${installed_count}个"
    fi
    
    if [[ $updated_count -gt 0 ]]; then
        echo "更新工具: ${updated_count}个"
    fi
}

# 显示配置摘要
show_tools_summary() {
    echo
    log "🎯 系统工具摘要:" "info"
    
    local installed_tools=()
    local missing_tools=()
    
    for tool_info in "${TOOLS[@]}"; do
        local tool_name="${tool_info%%:*}"
        local check_cmd=$(echo "$tool_info" | cut -d: -f2)
        local description="${tool_info##*:}"
        
        local status=$(check_tool_status "$tool_name" "$check_cmd" || echo "missing:")
        if [[ "$status" == installed:* ]]; then
            local version="${status#installed:}"
            installed_tools+=("$tool_name($version)")
        else
            missing_tools+=("$tool_name")
        fi
    done
    
    if [[ ${#installed_tools[@]} -gt 0 ]]; then
        echo "  ✓ 已安装: ${installed_tools[*]}"
    fi
    
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        echo "  ✗ 未安装: ${missing_tools[*]}"
    fi
    
    # 显示常用命令 - 添加错误处理
    local available_commands=()
    command -v nexttrace >/dev/null 2>&1 && available_commands+=("nexttrace ip.sb")
    command -v speedtest >/dev/null 2>&1 && available_commands+=("speedtest")
    command -v htop >/dev/null 2>&1 && available_commands+=("htop")
    command -v tree >/dev/null 2>&1 && available_commands+=("tree /path")
    
    if [[ ${#available_commands[@]} -gt 0 ]]; then
        echo "  💡 常用命令: ${available_commands[*]}"
    fi
    
    return 0  # 确保这个函数总是成功返回
}

# === 主流程 ===
main() {
    log "🛠️ 配置系统工具..." "info"
    
    echo
    local choice=$(get_user_choice)
    
    if [[ "$choice" == "skip" ]]; then
        echo "工具安装: 跳过"
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
        
        install_selected_tools "$choice" || true  # 确保不会因为工具安装失败而退出
    fi
    
    show_tools_summary || true  # 确保摘要显示不会导致脚本失败
    
    echo
    log "✅ 系统工具配置完成!" "info"
    
    return 0  # 显式返回成功
}

main "$@"
