#!/bin/bash

#=============================================================================
# Debian 系统部署脚本 (简化优化版本 v3.0.0)
# 适用系统: Debian 12+, 作者: LucaLin233 (Simplified Version)
# 功能: 模块化部署，智能依赖处理，简化交互
#=============================================================================

set -euo pipefail

#--- 全局常量 ---
readonly SCRIPT_VERSION="3.0.0"
readonly MODULE_BASE_URL="https://raw.githubusercontent.com/LucaLin233/Linux/refs/heads/main/modules"
readonly TEMP_DIR="/tmp/debian-setup-modules"
readonly LOG_FILE="/var/log/debian-setup.log"
readonly SUMMARY_FILE="/root/deployment_summary.txt"

#--- 模块定义 ---
declare -A MODULES=(
    ["system-optimize"]="系统优化 (Zram, 时区)"
    ["zsh-setup"]="Zsh Shell 环境"
    ["mise-setup"]="Mise 版本管理器"
    ["docker-setup"]="Docker 容器化平台"
    ["network-optimize"]="网络性能优化"
    ["ssh-security"]="SSH 安全配置"
    ["auto-update-setup"]="自动更新系统"
)

#--- 执行状态 ---
EXECUTED_MODULES=()
FAILED_MODULES=()
SKIPPED_MODULES=()

#--- 颜色常量 ---
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

#--- 日志函数 ---
log() {
    local msg="$1"
    local level="${2:-info}"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    case "$level" in
        "info")  echo -e "${GREEN}✓ $msg${NC}" ;;
        "warn")  echo -e "${YELLOW}⚠ $msg${NC}" ;;
        "error") echo -e "${RED}✗ $msg${NC}" ;;
        "title") echo -e "${BLUE}▶ $msg${NC}" ;;
    esac
    
    echo "[$timestamp] [$level] $msg" >> "$LOG_FILE"
}

#--- 错误处理 ---
cleanup() {
    local exit_code=$?
    [[ -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
    if (( exit_code != 0 )); then
        log "脚本异常退出，详细日志: $LOG_FILE" "error"
    fi
    exit $exit_code
}

trap cleanup EXIT INT TERM

#--- 基础检查 ---
check_system() {
    log "系统预检查" "title"
    
    # Root权限检查
    (( EUID == 0 )) || { log "需要 root 权限运行" "error"; exit 1; }
    
    # 系统检查
    [[ -f /etc/debian_version ]] || { log "仅支持 Debian 系统" "error"; exit 1; }
    
    # 磁盘空间检查 (至少1GB)
    local free_space_kb=$(df / | awk 'NR==2 {print $4}')
    if (( free_space_kb < 1048576 )); then
        log "磁盘空间不足 (可用: $(( free_space_kb / 1024 ))MB, 需要: 1GB)" "error"
        exit 1
    fi
    
    log "系统检查通过" "info"
}

#--- 网络检查 ---
check_network() {
    log "检查网络连接..." "info"
    if ! ping -c 1 -W 3 8.8.8.8 &>/dev/null; then
        log "网络连接异常，可能影响模块下载" "warn"
        read -p "继续执行? [y/N]: " -r choice
        [[ "$choice" =~ ^[Yy]$ ]] || exit 0
    fi
    log "网络连接正常" "info"
}

#--- 安装基础依赖 ---
install_dependencies() {
    log "检查系统依赖" "title"
    
    local required_deps=(curl wget git)
    local missing_deps=()
    
    for dep in "${required_deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            missing_deps+=("$dep")
        fi
    done
    
    if (( ${#missing_deps[@]} > 0 )); then
        log "安装缺失依赖: ${missing_deps[*]}" "info"
        apt-get update -qq && apt-get install -y "${missing_deps[@]}"
    fi
    
    log "依赖检查完成" "info"
}

#--- 系统更新 ---
system_update() {
    log "系统更新" "title"
    
    log "更新软件包列表..." "info"
    apt-get update || log "软件包列表更新失败" "warn"
    
    log "执行系统升级..." "info"
    apt-get upgrade -y
    
    # 基本系统修复
    local hostname=$(hostname)
    if ! grep -q "^127.0.1.1.*$hostname" /etc/hosts; then
        log "修复 hosts 文件" "info"
        sed -i "/^127.0.1.1/d" /etc/hosts
        echo "127.0.1.1 $hostname" >> /etc/hosts
    fi
    
    log "系统更新完成" "info"
}

#--- 部署模式选择 ---
select_deployment_mode() {
    log "选择部署模式" "title"
    
    echo
    echo "可选部署模式："
    echo "1) 🖥️  服务器模式 (推荐: system-optimize + network-optimize + ssh-security + auto-update)"
    echo "2) 💻 开发模式 (推荐: system-optimize + zsh-setup + mise-setup + docker-setup)"
    echo "3) 🚀 全部安装 (安装所有7个模块)"
    echo "4) 🎯 自定义选择 (逐个选择模块)"
    echo
    
    read -p "请选择模式 [1-4]: " -r mode_choice
    
    local selected_modules=()
    case "$mode_choice" in
        1)
            selected_modules=(system-optimize network-optimize ssh-security auto-update-setup)
            log "选择: 服务器模式" "info"
            ;;
        2)
            selected_modules=(system-optimize zsh-setup mise-setup docker-setup)
            log "选择: 开发模式" "info"
            ;;
        3)
            selected_modules=(system-optimize zsh-setup mise-setup docker-setup network-optimize ssh-security auto-update-setup)
            log "选择: 全部安装" "info"
            ;;
        4)
            selected_modules=$(custom_module_selection)
            ;;
        *)
            log "无效选择，使用服务器模式" "warn"
            selected_modules=(system-optimize network-optimize ssh-security auto-update-setup)
            ;;
    esac
    
    echo "${selected_modules[@]}"
}

#--- 自定义模块选择 ---
custom_module_selection() {
    local selected=()
    
    log "自定义模块选择 (system-optimize 建议安装)" "info"
    echo
    
    # system-optimize 特殊处理
    read -p "安装 system-optimize (系统优化) [Y/n]: " -r choice
    choice="${choice:-Y}"
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        selected+=(system-optimize)
    fi
    
    # 其他模块选择
    local other_modules=(zsh-setup mise-setup docker-setup network-optimize ssh-security auto-update-setup)
    for module in "${other_modules[@]}"; do
        echo
        echo "模块: ${MODULES[$module]}"
        read -p "是否安装 $module? [y/N]: " -r choice
        if [[ "$choice" =~ ^[Yy]$ ]]; then
            selected+=("$module")
        fi
    done
    
    echo "${selected[@]}"
}

#--- 依赖检查和解析 ---
resolve_dependencies() {
    local selected=("$@")
    local final_list=()
    local need_system_optimize=false
    local need_zsh_setup=false
    
    # 检查是否需要添加依赖
    for module in "${selected[@]}"; do
        case "$module" in
            "system-optimize")
                need_system_optimize=true
                ;;
            "zsh-setup")
                need_system_optimize=true
                need_zsh_setup=true
                ;;
            "mise-setup")
                need_system_optimize=true
                need_zsh_setup=true
                ;;
        esac
    done
    
    # 依赖提醒和确认
    local missing_deps=()
    
    if $need_system_optimize && [[ ! " ${selected[*]} " =~ " system-optimize " ]]; then
        missing_deps+=("system-optimize")
    fi
    
    if $need_zsh_setup && [[ ! " ${selected[*]} " =~ " zsh-setup " ]]; then
        missing_deps+=("zsh-setup")
    fi
    
    if (( ${#missing_deps[@]} > 0 )); then
        echo
        log "检测到依赖关系:" "warn"
        for dep in "${missing_deps[@]}"; do
            echo "  • $dep: ${MODULES[$dep]}"
        done
        echo
        read -p "是否自动添加依赖模块? [Y/n]: " -r choice
        choice="${choice:-Y}"
        if [[ "$choice" =~ ^[Yy]$ ]]; then
            selected+=("${missing_deps[@]}")
        fi
    fi
    
    # 按依赖顺序排序
    local all_modules=(system-optimize zsh-setup mise-setup docker-setup network-optimize ssh-security auto-update-setup)
    for module in "${all_modules[@]}"; do
        if [[ " ${selected[*]} " =~ " $module " ]]; then
            final_list+=("$module")
        fi
    done
    
    echo "${final_list[@]}"
}

#--- 下载模块 ---
download_module() {
    local module="$1"
    local module_file="$TEMP_DIR/${module}.sh"
    
    log "下载模块: $module" "info"
    
    if curl -fsSL --connect-timeout 10 "$MODULE_BASE_URL/${module}.sh" -o "$module_file"; then
        if [[ -s "$module_file" ]] && head -1 "$module_file" | grep -q "#!/bin/bash"; then
            chmod +x "$module_file"
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
    
    log "执行模块: ${MODULES[$module]}" "title"
    
    local start_time=$(date +%s)
    local exec_result=0
    
    # 执行模块
    bash "$module_file" || exec_result=$?
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    if (( exec_result == 0 )); then
        EXECUTED_MODULES+=("$module")
        log "模块 $module 执行成功 (耗时: ${duration}s)" "info"
        return 0
    else
        FAILED_MODULES+=("$module")
        log "模块 $module 执行失败 (耗时: ${duration}s)" "error"
        return 1
    fi
}

#--- 获取系统状态 ---
get_system_status() {
    local status_lines=()
    
    # Zsh 状态
    if command -v zsh &>/dev/null; then
        local root_shell=$(getent passwd root | cut -d: -f7)
        if [[ "$root_shell" == "$(which zsh)" ]]; then
            status_lines+=("Zsh Shell: 已安装并设为默认")
        else
            status_lines+=("Zsh Shell: 已安装但未设为默认")
        fi
    else
        status_lines+=("Zsh Shell: 未安装")
    fi
    
    # Docker 状态
    if command -v docker &>/dev/null; then
        local containers_count=$(docker ps -q 2>/dev/null | wc -l || echo "0")
        status_lines+=("Docker: 已安装 (容器: $containers_count)")
    else
        status_lines+=("Docker: 未安装")
    fi
    
    # Mise 状态
    if [[ -f "$HOME/.local/bin/mise" ]]; then
        status_lines+=("Mise: 已安装")
    else
        status_lines+=("Mise: 未安装")
    fi
    
    # SSH 配置
    local ssh_port=$(grep "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "22")
    status_lines+=("SSH 端口: $ssh_port")
    
    printf '%s\n' "${status_lines[@]}"
}

#--- 生成部署摘要 ---
generate_summary() {
    log "生成部署摘要" "title"
    
    local total_modules=$(( ${#EXECUTED_MODULES[@]} + ${#FAILED_MODULES[@]} + ${#SKIPPED_MODULES[@]} ))
    local success_rate=0
    if (( total_modules > 0 )); then
        success_rate=$(( ${#EXECUTED_MODULES[@]} * 100 / total_modules ))
    fi
    
    # 控制台输出
    echo
    log "═══════════════ 部署完成摘要 ═══════════════" "title"
    echo
    log "脚本版本: $SCRIPT_VERSION" "info"
    log "部署时间: $(date '+%Y-%m-%d %H:%M:%S')" "info"
    log "操作系统: $(grep 'PRETTY_NAME' /etc/os-release | cut -d= -f2 | tr -d '"' 2>/dev/null || echo 'Debian')" "info"
    echo
    log "📊 执行统计:" "title"
    log "总模块数: $total_modules" "info"
    log "成功执行: ${#EXECUTED_MODULES[@]} 个" "info"
    log "执行失败: ${#FAILED_MODULES[@]} 个" "info"
    log "跳过执行: ${#SKIPPED_MODULES[@]} 个" "info"
    log "成功率: ${success_rate}%" "info"
    
    if (( ${#EXECUTED_MODULES[@]} > 0 )); then
        echo
        log "✅ 成功执行的模块:" "info"
        for module in "${EXECUTED_MODULES[@]}"; do
            echo "   • $module: ${MODULES[$module]}"
        done
    fi
    
    if (( ${#FAILED_MODULES[@]} > 0 )); then
        echo
        log "❌ 执行失败的模块:" "error"
        for module in "${FAILED_MODULES[@]}"; do
            echo "   • $module: ${MODULES[$module]}"
        done
    fi
    
    echo
    log "🖥️ 当前系统状态:" "title"
    while IFS= read -r status_line; do
        echo "   • $status_line"
    done < <(get_system_status)
    
    # 保存到文件
    {
        echo "=== Debian 部署摘要 ==="
        echo "时间: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "版本: $SCRIPT_VERSION"
        echo "成功率: ${success_rate}%"
        echo ""
        echo "=== 成功执行的模块 ==="
        for module in "${EXECUTED_MODULES[@]}"; do
            echo "[$module] ${MODULES[$module]}"
        done
        echo ""
        echo "=== 当前系统状态 ==="
        get_system_status
        echo ""
        echo "=== 重要文件位置 ==="
        echo "日志文件: $LOG_FILE"
        echo "摘要文件: $SUMMARY_FILE"
    } > "$SUMMARY_FILE"
    
    echo
    log "📁 摘要已保存至: $SUMMARY_FILE" "info"
}

#--- 最终建议 ---
show_recommendations() {
    echo
    log "🎉 系统部署完成！" "title"
    
    # SSH 安全提醒
    if [[ " ${EXECUTED_MODULES[*]} " =~ " ssh-security " ]]; then
        local new_ssh_port=$(grep "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')
        if [[ "$new_ssh_port" != "22" ]] && [[ -n "$new_ssh_port" ]]; then
            echo
            log "⚠️  重要提醒: SSH 端口已更改为 $new_ssh_port" "warn"
            log "新连接命令: ssh -p $new_ssh_port user@$(hostname -I | awk '{print $1}')" "info"
        fi
    fi
    
    echo
    log "📖 常用命令:" "info"
    echo "   • 查看详细日志: tail -f $LOG_FILE"
    echo "   • 查看部署摘要: cat $SUMMARY_FILE"
    echo "   • 重新运行脚本: bash $0"
    
    echo
    log "感谢使用 Debian 系统部署脚本！" "title"
}

#--- 命令行参数处理 ---
handle_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --check-status)
                if [[ -f "$SUMMARY_FILE" ]]; then
                    cat "$SUMMARY_FILE"
                else
                    echo "未找到部署摘要文件"
                fi
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
                echo "未知参数: $1"
                echo "使用 --help 查看帮助"
                exit 1
                ;;
        esac
        shift
    done
}

#--- 帮助信息 ---
show_help() {
    cat << EOF
Debian 系统部署脚本 v$SCRIPT_VERSION

用法: $0 [选项]

选项:
  --check-status    查看最近的部署状态
  --help, -h        显示此帮助信息
  --version, -v     显示版本信息

功能模块:
  • system-optimize    系统优化 (Zram, 时区设置)
  • zsh-setup          Zsh Shell 环境配置
  • mise-setup         Mise 版本管理器安装
  • docker-setup       Docker 容器化平台
  • network-optimize   网络性能优化 (BBR)
  • ssh-security       SSH 安全加固
  • auto-update-setup  自动更新系统配置

特性:
  ✓ 智能依赖处理    ✓ 模块化部署
  ✓ 4种部署模式     ✓ 系统状态检查
  ✓ 摘要文件生成    ✓ 错误处理机制

文件位置:
  日志文件: $LOG_FILE
  摘要文件: $SUMMARY_FILE

示例:
  $0                  # 交互式部署
  $0 --check-status   # 查看部署状态
EOF
}

#--- 主程序 ---
main() {
    # 处理命令行参数
    handle_arguments "$@"
    
    # 初始化
    mkdir -p "$(dirname "$LOG_FILE")" "$TEMP_DIR"
    : > "$LOG_FILE"
    
    log "=== Debian 系统部署脚本启动 - 版本 $SCRIPT_VERSION ===" "title"
    
    # 基础检查
    check_system
    check_network
    install_dependencies
    system_update
    
    # 模块选择和执行
    local selected_modules
    selected_modules=$(select_deployment_mode)
    
    if [[ -z "$selected_modules" ]]; then
        log "未选择任何模块，退出" "warn"
        exit 0
    fi
    
    # 解析依赖
    local final_modules
    final_modules=$(resolve_dependencies $selected_modules)
    
    log "最终执行顺序: $final_modules" "info"
    echo
    read -p "确认执行? [Y/n]: " -r choice
    choice="${choice:-Y}"
    [[ "$choice" =~ ^[Yy]$ ]] || exit 0
    
    # 下载和执行模块
    local modules_array=($final_modules)
    local total=${#modules_array[@]}
    local current=0
    
    log "开始下载和执行 $total 个模块..." "title"
    
    for module in "${modules_array[@]}"; do
        current=$((current + 1))
        echo
        log "[$current/$total] 处理模块: ${MODULES[$module]}" "title"
        
        if download_module "$module"; then
            execute_module "$module" || log "继续执行其他模块..." "warn"
        else
            FAILED_MODULES+=("$module")
            log "跳过执行 $module" "warn"
        fi
    done
    
    # 生成摘要和建议
    generate_summary
    show_recommendations
    
    log "🎯 所有部署任务完成！" "title"
}

# 执行主程序
main "$@"
