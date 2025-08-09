#!/bin/bash

#=============================================================================
# Debian 系统部署脚本 v3.3.0
# 适用系统: Debian 12+, 作者: LucaLin233
# 功能: 模块化部署，智能依赖处理
#=============================================================================

set -euo pipefail

#--- 全局常量 ---
readonly SCRIPT_VERSION="3.3.0"
readonly MODULE_BASE_URL="https://raw.githubusercontent.com/LucaLin233/Linux/refs/heads/main/modules"
readonly TEMP_DIR="/tmp/debian-setup-modules"
readonly LOG_FILE="/var/log/debian-setup.log"
readonly SUMMARY_FILE="/root/deployment_summary.txt"

# 缓存控制参数
readonly CURL_CACHE_OPTS=(
    -H "Cache-Control: no-cache, no-store, must-revalidate"
    -H "Pragma: no-cache"
    -H "Expires: 0"
)

#--- 模块定义 (新增tools-setup) ---
declare -A MODULES=(
    ["system-optimize"]="系统优化 (Zram, 时区, 时间同步)"
    ["zsh-setup"]="Zsh Shell 环境"
    ["mise-setup"]="Mise 版本管理器"
    ["docker-setup"]="Docker 容器化平台"
    ["tools-setup"]="系统工具 (NextTrace, SpeedTest等)"
    ["ssh-security"]="SSH 安全配置"
    ["auto-update-setup"]="自动更新系统"
)

#--- 执行状态 ---
EXECUTED_MODULES=()
FAILED_MODULES=()
SKIPPED_MODULES=()
SELECTED_MODULES=()
declare -A MODULE_EXEC_TIME=()
TOTAL_START_TIME=0

#--- 简化的颜色系统 ---
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly WHITE='\033[1;37m'
readonly NC='\033[0m'

#--- 简化的日志函数 ---
log() {
    local msg="$1"
    local level="${2:-info}"
    local timestamp=$(date '+%H:%M:%S')
    
    case "$level" in
        "info")     echo -e "${GREEN}✅ $msg${NC}" ;;
        "warn")     echo -e "${YELLOW}⚠️  $msg${NC}" ;;
        "error")    echo -e "${RED}❌ $msg${NC}" ;;
        "success")  echo -e "${GREEN}🎉 $msg${NC}" ;;
    esac
    
    echo "[$timestamp] [$level] $msg" >> "$LOG_FILE" 2>/dev/null || true
}

#--- 简化的分隔线 ---
print_line() {
    echo "============================================================"
}

#--- 错误处理 ---
cleanup() {
    local exit_code=$?
    [[ -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR" 2>/dev/null || true
    if (( exit_code != 0 )); then
        log "脚本异常退出，日志: $LOG_FILE" "error"
    fi
    exit $exit_code
}
trap cleanup EXIT INT TERM

#--- 基础检查 ---
check_system() {
    log "系统预检查"
    
    if (( EUID != 0 )); then
        log "需要 root 权限运行" "error"
        exit 1
    fi
    
    if [[ ! -f /etc/debian_version ]]; then
        log "仅支持 Debian 系统" "error"
        exit 1
    fi
    
    local free_space_kb
    free_space_kb=$(df / | awk 'NR==2 {print $4}' 2>/dev/null || echo "0")
    if (( free_space_kb < 1048576 )); then
        log "磁盘空间不足 (需要至少1GB)" "error"
        exit 1
    fi
    
    log "系统检查通过"
}

#--- 网络检查 ---
check_network() {
    log "检查网络连接..."
    if ! ping -c 1 -W 3 8.8.8.8 &>/dev/null; then
        log "网络连接异常，可能影响模块下载" "warn"
        read -p "继续执行? [y/N]: " -r choice
        [[ "$choice" =~ ^[Yy]$ ]] || exit 0
    fi
    log "网络连接正常"
}

#--- 安装基础依赖 ---
install_dependencies() {
    log "检查系统依赖"
    
    local required_deps=(
        "curl:curl"
        "wget:wget" 
        "git:git"
        "jq:jq"
        "rsync:rsync"
        "sudo:sudo"
        "dig:dnsutils"
    )
    
    local missing_packages=()
    
    for dep_pair in "${required_deps[@]}"; do
        local check_cmd="${dep_pair%:*}"
        local package_name="${dep_pair#*:}"
        
        if ! command -v "$check_cmd" >/dev/null 2>&1; then
            missing_packages+=("$package_name")
        fi
    done
    
    if (( ${#missing_packages[@]} > 0 )); then
        log "安装缺失依赖: ${missing_packages[*]}"
        apt-get update -qq || log "软件包列表更新失败" "warn"
        apt-get install -y "${missing_packages[@]}" || {
            log "依赖安装失败" "error"
            exit 1
        }
    fi
    
    log "依赖检查完成"
}

#--- 系统更新 ---
system_update() {
    log "系统更新"
    
    apt-get update 2>/dev/null || log "软件包列表更新失败" "warn"
    apt-get upgrade -y 2>/dev/null || log "系统升级失败" "warn"
    
    # 修复hosts文件
    local hostname
    hostname=$(hostname 2>/dev/null || echo "localhost")
    if ! grep -q "^127.0.1.1.*$hostname" /etc/hosts 2>/dev/null; then
        sed -i "/^127.0.1.1/d" /etc/hosts 2>/dev/null || true
        echo "127.0.1.1 $hostname" >> /etc/hosts 2>/dev/null || true
    fi
    
    log "系统更新完成"
}

#--- 简化的部署模式选择 ---
select_deployment_mode() {
    log "选择部署模式"
    
    echo
    print_line
    echo "部署模式选择："
    echo "1) 🚀 全部安装 (安装所有7个模块)"
    echo "2) 🎯 自定义选择 (按需选择模块)"
    echo
    
    read -p "请选择模式 [1-2]: " -r mode_choice
    
    case "$mode_choice" in
        1)
            SELECTED_MODULES=(system-optimize zsh-setup mise-setup docker-setup tools-setup ssh-security auto-update-setup)
            log "选择: 全部安装"
            ;;
        2)
            custom_module_selection
            ;;
        *)
            log "无效选择，使用全部安装" "warn"
            SELECTED_MODULES=(system-optimize zsh-setup mise-setup docker-setup tools-setup ssh-security auto-update-setup)
            ;;
    esac
}

#--- 改进的自定义模块选择 ---
custom_module_selection() {
    echo
    echo "可用模块："
    
    local module_list=(system-optimize zsh-setup mise-setup docker-setup tools-setup ssh-security auto-update-setup)
    local module_descriptions=(
        "系统优化 (Zram, 时区设置)"
        "Zsh Shell 环境"
        "Mise 版本管理器"
        "Docker 容器化平台"
        "系统工具 (NextTrace等)"
        "SSH 安全配置"
        "自动更新系统"
    )
    
    for i in "${!module_list[@]}"; do
        local num=$((i + 1))
        echo "$num) ${module_list[$i]} - ${module_descriptions[$i]}"
    done
    
    echo
    echo "请输入要安装的模块编号 (用空格分隔，如: 1 3 5):"
    read -r selection
    
    local selected=()
    for num in $selection; do
        if [[ "$num" =~ ^[1-7]$ ]]; then
            local index=$((num - 1))
            selected+=("${module_list[$index]}")
        else
            log "跳过无效编号: $num" "warn"
        fi
    done
    
    if (( ${#selected[@]} == 0 )); then
        log "未选择有效模块，使用system-optimize" "warn"
        selected=(system-optimize)
    fi
    
    SELECTED_MODULES=("${selected[@]}")
    log "已选择: ${SELECTED_MODULES[*]}"
}

#--- 依赖检查和解析 ---
resolve_dependencies() {
    local selected=("${SELECTED_MODULES[@]}")
    local final_list=()
    local missing_deps=()
    
    # 检查依赖关系
    local need_system_optimize=false
    local need_zsh_setup=false
    
    for module in "${selected[@]}"; do
        case "$module" in
            "system-optimize")
                need_system_optimize=true
                ;;
            "zsh-setup"|"mise-setup")
                need_system_optimize=true
                [[ "$module" == "mise-setup" ]] && need_zsh_setup=true
                ;;
        esac
    done
    
    # 添加缺失的依赖
    if $need_system_optimize && [[ ! " ${selected[*]} " =~ " system-optimize " ]]; then
        missing_deps+=("system-optimize")
    fi
    
    if $need_zsh_setup && [[ ! " ${selected[*]} " =~ " zsh-setup " ]]; then
        missing_deps+=("zsh-setup")
    fi
    
    if (( ${#missing_deps[@]} > 0 )); then
        echo
        log "检测到依赖关系，需要添加: ${missing_deps[*]}" "warn"
        read -p "自动添加依赖模块? [Y/n]: " -r choice
        choice="${choice:-Y}"
        if [[ "$choice" =~ ^[Yy]$ ]]; then
            selected+=("${missing_deps[@]}")
        fi
    fi
    
    # 按依赖顺序排序
    local all_modules=(system-optimize zsh-setup mise-setup docker-setup tools-setup ssh-security auto-update-setup)
    for module in "${all_modules[@]}"; do
        if [[ " ${selected[*]} " =~ " $module " ]]; then
            final_list+=("$module")
        fi
    done
    
    SELECTED_MODULES=("${final_list[@]}")
}

#--- 下载模块 ---
download_module() {
    local module="$1"
    local module_file="$TEMP_DIR/${module}.sh"
    local timestamp=$(date +%s)
    
    if curl -fsSL --connect-timeout 10 "${CURL_CACHE_OPTS[@]}" \
        "$MODULE_BASE_URL/${module}.sh?v=$timestamp" \
        -o "$module_file" 2>/dev/null; then
        
        if [[ -s "$module_file" ]] && head -1 "$module_file" | grep -q "#!/bin/bash" 2>/dev/null; then
            chmod +x "$module_file" 2>/dev/null || true
            return 0
        fi
    fi
    
    log "模块 $module 下载失败" "error"
    return 1
}

#--- 执行模块 ---
execute_module() {
    local module="$1"
    local module_file="$TEMP_DIR/${module}.sh"
    
    if [[ ! -f "$module_file" ]]; then
        log "模块文件不存在: $module" "error"
        FAILED_MODULES+=("$module")
        return 1
    fi
    
    log "执行模块: ${MODULES[$module]}"
    
    local start_time
    start_time=$(date +%s 2>/dev/null || echo "0")
    local exec_result=0
    
    bash "$module_file" || exec_result=$?
    
    local end_time
    end_time=$(date +%s 2>/dev/null || echo "$start_time")
    local duration=$((end_time - start_time))
    MODULE_EXEC_TIME[$module]=$duration
    
    if (( exec_result == 0 )); then
        EXECUTED_MODULES+=("$module")
        log "模块 $module 执行成功 (${duration}s)" "success"
        return 0
    else
        FAILED_MODULES+=("$module")
        log "模块 $module 执行失败 (${duration}s)" "error"
        return 1
    fi
}

#--- 获取系统状态 ---
#--- 改进的系统状态获取 ---
get_system_status() {
    local status_lines=()
    
    # 基础系统信息
    local cpu_cores
    cpu_cores=$(nproc 2>/dev/null || echo "未知")
    local mem_info
    mem_info=$(free -h 2>/dev/null | grep Mem | awk '{print $3"/"$2}' || echo "未知")
    local disk_usage
    disk_usage=$(df -h / 2>/dev/null | awk 'NR==2 {print $5}' || echo "未知")
    local uptime_info
    uptime_info=$(uptime -p 2>/dev/null || echo "未知")
    local kernel
    kernel=$(uname -r 2>/dev/null || echo "未知")
    
    status_lines+=("💻 CPU: ${cpu_cores}核心 | 内存: $mem_info | 磁盘: $disk_usage")
    status_lines+=("⏰ 运行时间: $uptime_info")
    status_lines+=("🔧 内核: $kernel")
    
    # Zsh 状态和版本
    if command -v zsh &>/dev/null; then
        local zsh_version
        zsh_version=$(zsh --version 2>/dev/null | awk '{print $2}' || echo "未知")
        local root_shell
        root_shell=$(getent passwd root 2>/dev/null | cut -d: -f7 || echo "未知")
        if [[ "$root_shell" == "$(which zsh 2>/dev/null)" ]]; then
            status_lines+=("🐚 Zsh: v$zsh_version (已设为默认)")
        else
            status_lines+=("🐚 Zsh: v$zsh_version (已安装但未设为默认)")
        fi
    else
        status_lines+=("🐚 Zsh: 未安装")
    fi
    
    # Docker 状态和版本
    if command -v docker &>/dev/null; then
        local docker_version
        docker_version=$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',' || echo "未知")
        local containers_count
        containers_count=$(docker ps -q 2>/dev/null | wc -l || echo "0")
        local images_count
        images_count=$(docker images -q 2>/dev/null | wc -l || echo "0")
        
        if systemctl is-active --quiet docker 2>/dev/null; then
            status_lines+=("🐳 Docker: v$docker_version (运行中) | 容器: $containers_count | 镜像: $images_count")
        else
            status_lines+=("🐳 Docker: v$docker_version (已安装但未运行) | 容器: $containers_count | 镜像: $images_count")
        fi
    else
        status_lines+=("🐳 Docker: 未安装")
    fi
    
    # Mise 状态和版本
    if [[ -f "$HOME/.local/bin/mise" ]]; then
        local mise_version
        mise_version=$("$HOME/.local/bin/mise" --version 2>/dev/null | head -1 || echo "未知")
        status_lines+=("📦 Mise: v$mise_version")
    else
        status_lines+=("📦 Mise: 未安装")
    fi
    
    # 系统工具状态
    local tools_status=()
    command -v nexttrace &>/dev/null && tools_status+=("NextTrace")
    command -v speedtest &>/dev/null && tools_status+=("SpeedTest")
    command -v htop &>/dev/null && tools_status+=("htop")
    command -v tree &>/dev/null && tools_status+=("tree")
    command -v jq &>/dev/null && tools_status+=("jq")
    
    if (( ${#tools_status[@]} > 0 )); then
        status_lines+=("🛠️ 工具: ${tools_status[*]}")
    else
        status_lines+=("🛠️ 工具: 未安装")
    fi
    
    # SSH 配置
    local ssh_port
    ssh_port=$(grep "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "22")
    local ssh_root_login
    ssh_root_login=$(grep "^PermitRootLogin " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "默认")
    status_lines+=("🔒 SSH: 端口=$ssh_port | Root登录=$ssh_root_login")
    
    # 网络信息
    local network_ip
    network_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "未知")
    local network_interface
    network_interface=$(ip route 2>/dev/null | grep default | awk '{print $5}' | head -1 || echo "未知")
    status_lines+=("🌐 网络: $network_ip via $network_interface")
    
    printf '%s\n' "${status_lines[@]}"
}

#--- 简化的部署摘要 ---
#--- 改进摘要生成 ---
generate_summary() {
    log "生成部署摘要"
    
    local total_modules=$(( ${#EXECUTED_MODULES[@]} + ${#FAILED_MODULES[@]} + ${#SKIPPED_MODULES[@]} ))
    local success_rate=0
    if (( total_modules > 0 )); then
        success_rate=$(( ${#EXECUTED_MODULES[@]} * 100 / total_modules ))
    fi
    
    local total_time=$(( $(date +%s) - TOTAL_START_TIME ))
    local avg_time=0
    if (( ${#EXECUTED_MODULES[@]} > 0 )); then
        local sum_time=0
        for module in "${EXECUTED_MODULES[@]}"; do
            sum_time=$(( sum_time + ${MODULE_EXEC_TIME[$module]} ))
        done
        avg_time=$(( sum_time / ${#EXECUTED_MODULES[@]} ))
    fi
    
    echo
    print_line
    echo "Debian 系统部署完成摘要"
    print_line
    
    # 基本信息 (增加更多详情)
    echo "📋 基本信息:"
    echo "   🔢 脚本版本: $SCRIPT_VERSION"
    echo "   📅 部署时间: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "   ⏱️  总耗时: ${total_time}秒 | 平均耗时: ${avg_time}秒/模块"
    echo "   🏠 主机名: $(hostname 2>/dev/null || echo '未知')"
    echo "   💻 系统: $(grep 'PRETTY_NAME' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || echo 'Debian')"
    echo "   🌐 IP地址: $(hostname -I 2>/dev/null | awk '{print $1}' || echo '未知')"
    
    # 执行统计
    echo
    echo "📊 执行统计:"
    echo "   📦 总模块: $total_modules | ✅ 成功: ${#EXECUTED_MODULES[@]} | ❌ 失败: ${#FAILED_MODULES[@]} | 📈 成功率: ${success_rate}%"
    
    # 模块详情
    if (( ${#EXECUTED_MODULES[@]} > 0 )); then
        echo
        echo "✅ 成功模块:"
        for module in "${EXECUTED_MODULES[@]}"; do
            local exec_time=${MODULE_EXEC_TIME[$module]}
            echo "   🟢 $module: ${MODULES[$module]} (${exec_time}s)"
        done
    fi
    
    if (( ${#FAILED_MODULES[@]} > 0 )); then
        echo
        echo "❌ 失败模块:"
        for module in "${FAILED_MODULES[@]}"; do
            local exec_time=${MODULE_EXEC_TIME[$module]:-0}
            echo "   🔴 $module: ${MODULES[$module]} (${exec_time}s)"
        done
    fi
    
    # 系统状态 (现在更详细了)
    echo
    echo "🖥️ 当前系统状态:"
    while IFS= read -r status_line; do
        echo "   $status_line"
    done < <(get_system_status)
    
    # 保存摘要到文件 (也更新)
    {
        echo "==============================================="
        echo "Debian 系统部署摘要"
        echo "==============================================="
        echo "脚本版本: $SCRIPT_VERSION"
        echo "部署时间: $(date '+%Y-%m-%d %H:%M:%S %Z')"
        echo "总耗时: ${total_time}秒"
        echo "主机: $(hostname)"
        echo "系统: $(grep 'PRETTY_NAME' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || echo 'Debian')"
        echo "IP地址: $(hostname -I 2>/dev/null | awk '{print $1}' || echo '未知')"
        echo ""
        echo "执行统计:"
        echo "总模块: $total_modules, 成功: ${#EXECUTED_MODULES[@]}, 失败: ${#FAILED_MODULES[@]}, 成功率: ${success_rate}%"
        echo ""
        echo "成功模块:"
        for module in "${EXECUTED_MODULES[@]}"; do
            echo "  $module (${MODULE_EXEC_TIME[$module]}s)"
        done
        [[ ${#FAILED_MODULES[@]} -gt 0 ]] && echo "" && echo "失败模块: ${FAILED_MODULES[*]}"
        echo ""
        echo "系统状态:"
        get_system_status
        echo ""
        echo "文件位置:"
        echo "  日志: $LOG_FILE"
        echo "  摘要: $SUMMARY_FILE"
    } > "$SUMMARY_FILE" 2>/dev/null || true
    
    echo
    echo "📁 详细摘要已保存至: $SUMMARY_FILE"
    print_line
}

#--- 最终建议 ---
show_recommendations() {
    echo
    log "部署完成！" "success"
    
    # SSH安全提醒
    if [[ " ${EXECUTED_MODULES[*]} " =~ " ssh-security " ]]; then
        local new_ssh_port
        new_ssh_port=$(grep "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "22")
        if [[ "$new_ssh_port" != "22" ]]; then
            echo
            echo "⚠️  重要: SSH端口已更改为 $new_ssh_port"
            echo "   新连接: ssh -p $new_ssh_port user@$(hostname -I | awk '{print $1}')"
        fi
    fi
    
    echo
    echo "📚 常用命令:"
    echo "   查看日志: tail -f $LOG_FILE"
    echo "   查看摘要: cat $SUMMARY_FILE"
    echo "   重新运行: bash <(curl -fsSL -H \"Cache-Control: no-cache\" \"https://raw.githubusercontent.com/LucaLin233/Linux/refs/heads/main/debian_setup.sh?\$(date +%s)\")"
}

#--- 极简版帮助 ---
show_help() {
    cat << EOF
Debian 系统部署脚本 v$SCRIPT_VERSION

用法: $0 [选项]

选项:
  --check-status    查看部署状态
  --help, -h        显示帮助信息
  --version, -v     显示版本信息

功能模块: 
  system-optimize, zsh-setup, mise-setup, docker-setup, tools-setup, ssh-security, auto-update-setup

文件位置:
  日志: $LOG_FILE
  摘要: $SUMMARY_FILE
EOF
}

#--- 命令行参数处理 ---
handle_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --check-status)
                [[ -f "$SUMMARY_FILE" ]] && cat "$SUMMARY_FILE" || echo "❌ 未找到部署摘要文件"
                exit 0
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            --version|-v)
                echo "Debian 部署脚本 v$SCRIPT_VERSION"
                exit 0
                ;;
            *)
                echo "❌ 未知参数: $1"
                echo "使用 --help 查看帮助"
                exit 1
                ;;
        esac
        shift
    done
}

#--- 主程序 ---
main() {
    handle_arguments "$@"
    
    # 初始化
    mkdir -p "$(dirname "$LOG_FILE")" "$TEMP_DIR" 2>/dev/null || true
    : > "$LOG_FILE" 2>/dev/null || true
    TOTAL_START_TIME=$(date +%s 2>/dev/null || echo "0")
    
    # 启动
    clear 2>/dev/null || true
    print_line
    echo "Debian 系统部署脚本 v$SCRIPT_VERSION"
    print_line
    
    # 检查和准备
    check_system
    check_network
    install_dependencies
    system_update
    
    # 模块选择
    select_deployment_mode
    
    if (( ${#SELECTED_MODULES[@]} == 0 )); then
        log "未选择任何模块，退出" "warn"
        exit 0
    fi
    
    resolve_dependencies
    
    echo
    echo "最终执行计划: ${SELECTED_MODULES[*]}"
    read -p "确认执行? [Y/n]: " -r choice
    choice="${choice:-Y}"
    [[ "$choice" =~ ^[Yy]$ ]] || exit 0
    
    # 执行模块
    echo
    print_line
    log "开始执行 ${#SELECTED_MODULES[@]} 个模块"
    print_line
    
    for module in "${SELECTED_MODULES[@]}"; do
        echo
        echo "[$((${#EXECUTED_MODULES[@]} + ${#FAILED_MODULES[@]} + 1))/${#SELECTED_MODULES[@]}] 处理模块: ${MODULES[$module]}"
        
        if download_module "$module"; then
            execute_module "$module" || log "继续执行其他模块..." "warn"
        else
            FAILED_MODULES+=("$module")
        fi
    done
    
    # 完成
    generate_summary
    show_recommendations
}

# 执行主程序
main "$@"
