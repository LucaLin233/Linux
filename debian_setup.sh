#!/bin/bash

#=============================================================================
# Debian 系统部署脚本 v3.2.0
# 适用系统: Debian 12+, 作者: LucaLin233
# 功能: 模块化部署，智能依赖处理
#=============================================================================

set -euo pipefail

#--- 全局常量 ---
readonly SCRIPT_VERSION="3.2.0"
readonly MODULE_BASE_URL="https://raw.githubusercontent.com/LucaLin233/Linux/refs/heads/main/modules"
readonly TEMP_DIR="/tmp/debian-setup-modules"
readonly LOG_FILE="/var/log/debian-setup.log"
readonly SUMMARY_FILE="/root/deployment_summary.txt"

#--- 模块定义 (移除network-optimize) ---
declare -A MODULES=(
    ["system-optimize"]="系统优化 (Zram, 时区, 时间同步)"
    ["zsh-setup"]="Zsh Shell 环境"
    ["mise-setup"]="Mise 版本管理器"
    ["docker-setup"]="Docker 容器化平台"
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
    echo "1) 🚀 全部安装 (安装所有6个模块)"
    echo "2) 🎯 自定义选择 (按需选择模块)"
    echo
    
    read -p "请选择模式 [1-2]: " -r mode_choice
    
    case "$mode_choice" in
        1)
            SELECTED_MODULES=(system-optimize zsh-setup mise-setup docker-setup ssh-security auto-update-setup)
            log "选择: 全部安装"
            ;;
        2)
            custom_module_selection
            ;;
        *)
            log "无效选择，使用全部安装" "warn"
            SELECTED_MODULES=(system-optimize zsh-setup mise-setup docker-setup ssh-security auto-update-setup)
            ;;
    esac
}

#--- 改进的自定义模块选择 ---
custom_module_selection() {
    echo
    echo "可用模块："
    
    local module_list=(system-optimize zsh-setup mise-setup docker-setup ssh-security auto-update-setup)
    local module_descriptions=(
        "系统优化 (Zram, 时区设置)"
        "Zsh Shell 环境"
        "Mise 版本管理器"
        "Docker 容器化平台"
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
        if [[ "$num" =~ ^[1-6]$ ]]; then
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
    local all_modules=(system-optimize zsh-setup mise-setup docker-setup ssh-security auto-update-setup)
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
    
    if curl -fsSL --connect-timeout 10 "$MODULE_BASE_URL/${module}.sh" -o "$module_file" 2>/dev/null; then
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
get_system_status() {
    local cpu_cores
    cpu_cores=$(nproc 2>/dev/null || echo "未知")
    local mem_info
    mem_info=$(free -h 2>/dev/null | grep Mem | awk '{print $3"/"$2}' || echo "未知")
    local disk_usage
    disk_usage=$(df -h / 2>/dev/null | awk 'NR==2 {print $5}' || echo "未知")
    
    echo "CPU: ${cpu_cores}核心, 内存: $mem_info, 磁盘: $disk_usage"
    
    # 检查关键服务状态
    if command -v zsh &>/dev/null; then
        local zsh_default=""
        [[ "$(getent passwd root | cut -d: -f7)" == "$(which zsh)" ]] && zsh_default=" (已设为默认)"
        echo "Zsh: 已安装${zsh_default}"
    fi
    
    if command -v docker &>/dev/null; then
        local docker_status="已安装"
        systemctl is-active --quiet docker 2>/dev/null && docker_status="运行中" || docker_status="已安装但未运行"
        echo "Docker: $docker_status"
    fi
    
    if [[ -f "$HOME/.local/bin/mise" ]]; then
        echo "Mise: 已安装"
    fi
}

#--- 简化的部署摘要 ---
generate_summary() {
    log "生成部署摘要"
    
    local total_modules=$(( ${#EXECUTED_MODULES[@]} + ${#FAILED_MODULES[@]} + ${#SKIPPED_MODULES[@]} ))
    local success_rate=0
    if (( total_modules > 0 )); then
        success_rate=$(( ${#EXECUTED_MODULES[@]} * 100 / total_modules ))
    fi
    
    local total_time=$(( $(date +%s) - TOTAL_START_TIME ))
    
    echo
    print_line
    echo "Debian 系统部署完成摘要"
    print_line
    
    # 基本信息
    echo "📋 基本信息:"
    echo "   版本: $SCRIPT_VERSION | 时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "   主机: $(hostname) | 系统: $(grep 'PRETTY_NAME' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || echo 'Debian')"
    echo "   总耗时: ${total_time}秒"
    
    # 执行统计
    echo
    echo "📊 执行统计:"
    echo "   总模块: $total_modules | 成功: ${#EXECUTED_MODULES[@]} | 失败: ${#FAILED_MODULES[@]} | 成功率: ${success_rate}%"
    
    # 模块详情
    if (( ${#EXECUTED_MODULES[@]} > 0 )); then
        echo
        echo "✅ 成功模块:"
        for module in "${EXECUTED_MODULES[@]}"; do
            local exec_time=${MODULE_EXEC_TIME[$module]}
            echo "   $module (${exec_time}s)"
        done
    fi
    
    if (( ${#FAILED_MODULES[@]} > 0 )); then
        echo
        echo "❌ 失败模块:"
        for module in "${FAILED_MODULES[@]}"; do
            echo "   $module"
        done
    fi
    
    # 系统状态
    echo
    echo "🖥️ 系统状态:"
    get_system_status | sed 's/^/   /'
    
    # 保存摘要到文件
    {
        echo "Debian 系统部署摘要 - $(date '+%Y-%m-%d %H:%M:%S')"
        echo "版本: $SCRIPT_VERSION"
        echo "主机: $(hostname)"
        echo "总耗时: ${total_time}秒"
        echo "执行统计: 总模块 $total_modules, 成功 ${#EXECUTED_MODULES[@]}, 失败 ${#FAILED_MODULES[@]}"
        echo "成功模块: ${EXECUTED_MODULES[*]}"
        [[ ${#FAILED_MODULES[@]} -gt 0 ]] && echo "失败模块: ${FAILED_MODULES[*]}"
        echo "系统状态:"
        get_system_status
        echo "日志文件: $LOG_FILE"
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
    echo "   重新运行: bash <(curl -fsSL https://raw.githubusercontent.com/LucaLin233/Linux/refs/heads/main/debian_setup.sh)"
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
  system-optimize, zsh-setup, mise-setup, docker-setup, ssh-security, auto-update-setup

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
