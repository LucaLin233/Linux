#!/bin/bash

#=============================================================================
# Debian 系统部署脚本 (修复版本 v3.1.2)
# 适用系统: Debian 12+, 作者: LucaLin233 (Fixed Version)
# 功能: 模块化部署，智能依赖处理，丰富摘要显示
#=============================================================================

set -euo pipefail

#--- 全局常量 ---
readonly SCRIPT_VERSION="3.1.2"
readonly MODULE_BASE_URL="https://raw.githubusercontent.com/LucaLin233/Linux/refs/heads/main/modules"
readonly TEMP_DIR="/tmp/debian-setup-modules"
readonly LOG_FILE="/var/log/debian-setup.log"
readonly SUMMARY_FILE="/root/deployment_summary.txt"

#--- 模块定义 ---
declare -A MODULES=(
    ["system-optimize"]="系统优化 (Zram, 时区, 时间同步)"
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
SELECTED_MODULES=()
declare -A MODULE_EXEC_TIME=()
TOTAL_START_TIME=0

#--- 增强的颜色系统 ---
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly PURPLE='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly WHITE='\033[1;37m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# 背景色
readonly BG_GREEN='\033[42m'

#--- 增强的日志函数 ---
log() {
    local msg="$1"
    local level="${2:-info}"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    case "$level" in
        "info")     echo -e "${GREEN}✓ $msg${NC}" ;;
        "warn")     echo -e "${YELLOW}⚠️  $msg${NC}" ;;
        "error")    echo -e "${RED}❌ $msg${NC}" ;;
        "title")    echo -e "${BLUE}▶️  $msg${NC}" ;;
        "success")  echo -e "${BG_GREEN}${WHITE} ✅ $msg ${NC}" ;;
        "highlight") echo -e "${PURPLE}🔸 $msg${NC}" ;;
        "progress") echo -e "${CYAN}⏳ $msg${NC}" ;;
        "stats")    echo -e "${WHITE}📊 $msg${NC}" ;;
    esac
    
    echo "[$timestamp] [$level] $msg" >> "$LOG_FILE" 2>/dev/null || true
}

#--- 简化的进度条显示 ---
show_progress() {
    local current="$1"
    local total="$2"
    local task="${3:-处理中}"
    
    if (( total == 0 )); then
        echo -e "${CYAN}⏳ $task...${NC}"
        return 0
    fi
    
    local percent=$(( current * 100 / total ))
    echo -e "${CYAN}[$current/$total] ($percent%) $task${NC}"
}

#--- 修复的分隔符和边框 ---
print_separator() {
    local char="${1:-=}"
    local length="${2:-60}"
    local color="${3:-$BLUE}"
    
    echo -e "$color$(printf "%-${length}s" "" | tr " " "$char")$NC"
}

# 修复边框对齐问题 - 使用固定宽度
print_box() {
    local text="$1"
    local color="${2:-$BLUE}"
    local width=50  # 固定宽度
    
    echo -e "$color"
    printf "+%*s+\n" $((width-2)) "" | tr " " "-"
    printf "| %-*s |\n" $((width-4)) "$text"
    printf "+%*s+\n" $((width-2)) "" | tr " " "-"
    echo -e "$NC"
}

#--- 错误处理 ---
cleanup() {
    local exit_code=$?
    [[ -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR" 2>/dev/null || true
    if (( exit_code != 0 )); then
        log "脚本异常退出，详细日志: $LOG_FILE" "error"
        echo "Debug: 退出码 $exit_code" >&2
    fi
    exit $exit_code
}

trap cleanup EXIT INT TERM

#--- 基础检查 ---
check_system() {
    log "系统预检查" "title"
    
    # Root权限检查
    if (( EUID != 0 )); then
        log "需要 root 权限运行" "error"
        exit 1
    fi
    
    # 系统检查
    if [[ ! -f /etc/debian_version ]]; then
        log "仅支持 Debian 系统" "error"
        exit 1
    fi
    
    # 磁盘空间检查 (至少1GB)
    local free_space_kb
    free_space_kb=$(df / | awk 'NR==2 {print $4}' 2>/dev/null || echo "0")
    if (( free_space_kb < 1048576 )); then
        log "磁盘空间不足 (可用: $(( free_space_kb / 1024 ))MB, 需要: 1GB)" "error"
        exit 1
    fi
    
    log "系统检查通过 🎯" "success"
}

#--- 网络检查 ---
check_network() {
    log "检查网络连接..." "progress"
    if ! ping -c 1 -W 3 8.8.8.8 &>/dev/null; then
        log "网络连接异常，可能影响模块下载" "warn"
        read -p "继续执行? [y/N]: " -r choice
        [[ "$choice" =~ ^[Yy]$ ]] || exit 0
    fi
    log "网络连接正常 🌐" "success"
}

#--- 安装基础依赖 ---
install_dependencies() {
    log "检查系统依赖" "title"
    
    # 定义依赖：格式为 "检查命令:安装包名"
    local required_deps=(
        "curl:curl"
        "wget:wget" 
        "git:git"
        "jq:jq"
        "rsync:rsync"
        "sudo:sudo"
        "dig:dnsutils"  # 检查dig命令，但安装dnsutils包
    )
    
    local missing_packages=()
    local current=0
    
    for dep_pair in "${required_deps[@]}"; do
        current=$((current + 1))
        
        # 分割检查命令和包名
        local check_cmd="${dep_pair%:*}"
        local package_name="${dep_pair#*:}"
        
        show_progress "$current" "${#required_deps[@]}" "检查 $package_name"
        
        if ! command -v "$check_cmd" >/dev/null 2>&1; then
            missing_packages+=("$package_name")
        fi
    done
    
    if (( ${#missing_packages[@]} > 0 )); then
        log "安装缺失依赖: ${missing_packages[*]} 📦" "highlight"
        if ! apt-get update -qq; then
            log "软件包列表更新失败" "warn"
        fi
        if ! apt-get install -y "${missing_packages[@]}"; then
            log "依赖安装失败" "error"
            exit 1
        fi
    fi
    
    log "依赖检查完成 ✨" "success"
}

#--- 系统更新 ---
system_update() {
    log "系统更新" "title"
    
    log "更新软件包列表... 📋" "progress"
    apt-get update 2>/dev/null || log "软件包列表更新失败" "warn"
    
    log "执行系统升级... ⬆️" "progress"
    apt-get upgrade -y 2>/dev/null || log "系统升级失败" "warn"
    
    # 基本系统修复
    local hostname
    hostname=$(hostname 2>/dev/null || echo "localhost")
    if ! grep -q "^127.0.1.1.*$hostname" /etc/hosts 2>/dev/null; then
        log "修复 hosts 文件 🔧" "highlight"
        sed -i "/^127.0.1.1/d" /etc/hosts 2>/dev/null || true
        echo "127.0.1.1 $hostname" >> /etc/hosts 2>/dev/null || true
    fi
    
    log "系统更新完成 🎉" "success"
}

#--- 部署模式选择 ---
select_deployment_mode() {
    log "选择部署模式" "title"
    
    echo
    print_box "部署模式选择" "$PURPLE"
    echo
    echo "可选部署模式："
    echo "1) 🖥️  服务器模式 (推荐: system-optimize + network-optimize + ssh-security + auto-update)"
    echo "2) 💻 开发模式 (推荐: system-optimize + zsh-setup + mise-setup + docker-setup)"
    echo "3) 🚀 全部安装 (安装所有7个模块)"
    echo "4) 🎯 自定义选择 (逐个选择模块)"
    echo
    
    read -p "请选择模式 [1-4]: " -r mode_choice
    
    case "$mode_choice" in
        1)
            SELECTED_MODULES=(system-optimize network-optimize ssh-security auto-update-setup)
            log "选择: 🖥️ 服务器模式" "highlight"
            ;;
        2)
            SELECTED_MODULES=(system-optimize zsh-setup mise-setup docker-setup)
            log "选择: 💻 开发模式" "highlight"
            ;;
        3)
            SELECTED_MODULES=(system-optimize zsh-setup mise-setup docker-setup network-optimize ssh-security auto-update-setup)
            log "选择: 🚀 全部安装" "highlight"
            ;;
        4)
            custom_module_selection
            ;;
        *)
            log "无效选择，使用服务器模式" "warn"
            SELECTED_MODULES=(system-optimize network-optimize ssh-security auto-update-setup)
            ;;
    esac
}

#--- 自定义模块选择 ---
custom_module_selection() {
    local selected=()
    
    log "自定义模块选择 (system-optimize 建议安装)" "title"
    echo
    
    # system-optimize 特殊处理
    read -p "🔧 安装 system-optimize (系统优化) [Y/n]: " -r choice
    choice="${choice:-Y}"
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        selected+=(system-optimize)
    fi
    
    # 其他模块选择
    local other_modules=(zsh-setup mise-setup docker-setup network-optimize ssh-security auto-update-setup)
    local module_icons=(🐚 📦 🐳 🌐 🔒 🔄)
    
    for i in "${!other_modules[@]}"; do
        local module="${other_modules[$i]}"
        local icon="${module_icons[$i]}"
        echo
        echo "${icon} 模块: ${MODULES[$module]}"
        read -p "是否安装 $module? [y/N]: " -r choice
        if [[ "$choice" =~ ^[Yy]$ ]]; then
            selected+=("$module")
        fi
    done
    
    SELECTED_MODULES=("${selected[@]}")
}

#--- 依赖检查和解析 ---
resolve_dependencies() {
    local selected=("${SELECTED_MODULES[@]}")
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
        log "检测到依赖关系: 🔗" "warn"
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
    
    SELECTED_MODULES=("${final_list[@]}")
}

#--- 下载模块 ---
download_module() {
    local module="$1"
    local module_file="$TEMP_DIR/${module}.sh"
    
    log "下载模块: $module 📥" "progress"
    
    if curl -fsSL --connect-timeout 10 "$MODULE_BASE_URL/${module}.sh" -o "$module_file" 2>/dev/null; then
        if [[ -s "$module_file" ]] && head -1 "$module_file" | grep -q "#!/bin/bash" 2>/dev/null; then
            chmod +x "$module_file" 2>/dev/null || true
            return 0
        fi
    fi
    
    log "模块 $module 下载失败" "error"
    return 1
}

#--- 修复的模块执行函数 ---
execute_module() {
    local module="$1"
    local module_file="$TEMP_DIR/${module}.sh"
    
    if [[ ! -f "$module_file" ]]; then
        log "模块文件不存在: $module" "error"
        FAILED_MODULES+=("$module")
        return 1
    fi
    
    log "执行模块: ${MODULES[$module]} 🚀" "title"
    
    local start_time
    start_time=$(date +%s 2>/dev/null || echo "0")
    local exec_result=0
    
    # 🔥 关键修复：保持完整的输入输出，不重定向
    bash "$module_file" || exec_result=$?
    
    local end_time
    end_time=$(date +%s 2>/dev/null || echo "$start_time")
    local duration=$((end_time - start_time))
    MODULE_EXEC_TIME[$module]=$duration
    
    if (( exec_result == 0 )); then
        EXECUTED_MODULES+=("$module")
        log "模块 $module 执行成功 ✅ (耗时: ${duration}s)" "success"
        return 0
    else
        FAILED_MODULES+=("$module")
        log "模块 $module 执行失败 ❌ (耗时: ${duration}s)" "error"
        return 1
    fi
}

#--- 获取详细系统状态 ---
get_system_status() {
    local status_lines=()
    
    # 基础系统信息
    local cpu_cores
    cpu_cores=$(nproc 2>/dev/null || echo "未知")
    local total_mem
    total_mem=$(free -h 2>/dev/null | grep Mem | awk '{print $2}' || echo "未知")
    local used_mem
    used_mem=$(free -h 2>/dev/null | grep Mem | awk '{print $3}' || echo "未知")
    local disk_usage
    disk_usage=$(df -h / 2>/dev/null | awk 'NR==2 {print $5}' || echo "未知")
    local uptime_info
    uptime_info=$(uptime -p 2>/dev/null || echo "未知")
    local kernel
    kernel=$(uname -r 2>/dev/null || echo "未知")
    
    status_lines+=("💻 系统: $(grep 'PRETTY_NAME' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || echo 'Debian')")
    status_lines+=("🧠 CPU: ${cpu_cores}核心")
    status_lines+=("💾 内存: ${used_mem}/${total_mem}")
    status_lines+=("💿 磁盘使用率: $disk_usage")
    status_lines+=("⏰ 运行时间: $uptime_info")
    status_lines+=("🔧 内核版本: $kernel")
    
    # Zsh 状态
    if command -v zsh &>/dev/null; then
        local zsh_version
        zsh_version=$(zsh --version 2>/dev/null | awk '{print $2}' || echo "未知")
        local root_shell
        root_shell=$(getent passwd root 2>/dev/null | cut -d: -f7 || echo "未知")
        if [[ "$root_shell" == "$(which zsh 2>/dev/null)" ]]; then
            status_lines+=("🐚 Zsh Shell: 已安装并设为默认 (v$zsh_version)")
        else
            status_lines+=("🐚 Zsh Shell: 已安装但未设为默认 (v$zsh_version)")
        fi
    else
        status_lines+=("🐚 Zsh Shell: 未安装")
    fi
    
    # Docker 状态
    if command -v docker &>/dev/null; then
        local docker_version
        docker_version=$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',' || echo "未知")
        local containers_count
        containers_count=$(docker ps -q 2>/dev/null | wc -l || echo "0")
        local images_count
        images_count=$(docker images -q 2>/dev/null | wc -l || echo "0")
        status_lines+=("🐳 Docker: v$docker_version (容器: $containers_count, 镜像: $images_count)")
        
        if systemctl is-active --quiet docker 2>/dev/null; then
            status_lines+=("   └─ 服务状态: 🟢 运行中")
        else
            status_lines+=("   └─ 服务状态: 🔴 未运行")
        fi
    else
        status_lines+=("🐳 Docker: 未安装")
    fi
    
    # Mise 状态
    if [[ -f "$HOME/.local/bin/mise" ]]; then
        local mise_version
        mise_version=$("$HOME/.local/bin/mise" --version 2>/dev/null || echo "未知")
        status_lines+=("📦 Mise: v$mise_version")
    else
        status_lines+=("📦 Mise: 未安装")
    fi
    
    # 网络配置
    local network_info
    network_info=$(ip route 2>/dev/null | grep default | head -1 | awk '{print $3" via "$5}' || echo "未知")
    status_lines+=("🌐 网络: $network_info")
    
    # SSH 配置
    local ssh_port
    ssh_port=$(grep "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "22")
    local ssh_root_login
    ssh_root_login=$(grep "^PermitRootLogin " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "未设置")
    status_lines+=("🔒 SSH: 端口=$ssh_port, Root登录=$ssh_root_login")
    
    printf '%s\n' "${status_lines[@]}"
}

#--- 生成丰富的部署摘要 ---
generate_summary() {
    log "生成部署摘要" "title"
    
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
    
    # 控制台输出
    echo
    print_separator "=" 70 "$PURPLE"
    print_box "Debian 系统部署完成摘要" "$PURPLE"
    print_separator "=" 70 "$PURPLE"
    echo
    
    # 基本信息
    log "📋 基本信息" "stats"
    echo "   🔢 脚本版本: $SCRIPT_VERSION"
    echo "   📅 部署时间: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "   ⏱️  总耗时: ${total_time}秒"
    echo "   💻 操作系统: $(grep 'PRETTY_NAME' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || echo 'Debian')"
    echo "   🏠 主机名: $(hostname 2>/dev/null || echo '未知')"
    echo "   🌐 IP地址: $(hostname -I 2>/dev/null | awk '{print $1}' || echo '未知')"
    
    echo
    log "📊 执行统计" "stats"
    echo "   📦 总模块数: $total_modules"
    echo "   ✅ 成功执行: ${#EXECUTED_MODULES[@]} 个"
    echo "   ❌ 执行失败: ${#FAILED_MODULES[@]} 个"
    echo "   ⏭️  跳过执行: ${#SKIPPED_MODULES[@]} 个"
    echo "   📈 成功率: ${success_rate}%"
    echo "   ⏱️  平均耗时: ${avg_time}秒/模块"
    
    if (( ${#EXECUTED_MODULES[@]} > 0 )); then
        echo
        log "✅ 成功执行的模块详情" "stats"
        for module in "${EXECUTED_MODULES[@]}"; do
            local exec_time=${MODULE_EXEC_TIME[$module]}
            echo "   🟢 $module: ${MODULES[$module]} (耗时: ${exec_time}s)"
        done
    fi
    
    if (( ${#FAILED_MODULES[@]} > 0 )); then
        echo
        log "❌ 执行失败的模块" "error"
        for module in "${FAILED_MODULES[@]}"; do
            local exec_time=${MODULE_EXEC_TIME[$module]:-0}
            echo "   🔴 $module: ${MODULES[$module]} (耗时: ${exec_time}s)"
        done
    fi
    
    if (( ${#SKIPPED_MODULES[@]} > 0 )); then
        echo
        log "⏭️ 跳过的模块" "warn"
        for module in "${SKIPPED_MODULES[@]}"; do
            echo "   🟡 $module: ${MODULES[$module]}"
        done
    fi
    
    echo
    log "🖥️ 当前系统状态" "stats"
    while IFS= read -r status_line; do
        echo "   $status_line"
    done < <(get_system_status)
    
    echo
    log "📁 重要文件位置" "stats"
    echo "   📄 日志文件: $LOG_FILE"
    echo "   📋 摘要文件: $SUMMARY_FILE"
    echo "   🔧 模块临时目录: $TEMP_DIR"
    
    # 保存详细摘要到文件
    {
        echo "+================================================================+"
        echo "|                    Debian 系统部署摘要                         |"
        echo "+================================================================+"
        echo ""
        echo "📋 基本信息:"
        echo "   • 脚本版本: $SCRIPT_VERSION"
        echo "   • 部署时间: $(date '+%Y-%m-%d %H:%M:%S %Z')"
        echo "   • 总耗时: ${total_time}秒"
        echo "   • 操作系统: $(grep 'PRETTY_NAME' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || echo 'Debian')"
        echo "   • 主机名: $(hostname 2>/dev/null || echo '未知')"
        echo "   • IP地址: $(hostname -I 2>/dev/null | awk '{print $1}' || echo '未知')"
        echo ""
        echo "📊 执行统计:"
        echo "   • 总模块数: $total_modules"
        echo "   • 成功执行: ${#EXECUTED_MODULES[@]} 个"
        echo "   • 执行失败: ${#FAILED_MODULES[@]} 个"
        echo "   • 跳过执行: ${#SKIPPED_MODULES[@]} 个"
        echo "   • 成功率: ${success_rate}%"
        echo "   • 平均耗时: ${avg_time}秒/模块"
        echo ""
        echo "✅ 成功执行的模块:"
        for module in "${EXECUTED_MODULES[@]}"; do
            local exec_time=${MODULE_EXEC_TIME[$module]}
            echo "   [$module] ${MODULES[$module]} (耗时: ${exec_time}s)"
        done
        echo ""
        echo "🖥️ 当前系统状态:"
        get_system_status | sed 's/^/   /'
        echo ""
        echo "📁 重要文件位置:"
        echo "   • 日志文件: $LOG_FILE"
        echo "   • 摘要文件: $SUMMARY_FILE"
        echo ""
        echo "🔧 常用命令:"
        echo "   • 查看详细日志: tail -f $LOG_FILE"
        echo "   • 查看部署摘要: cat $SUMMARY_FILE"
        echo "   • 重新运行脚本: bash <(curl -fsSL https://raw.githubusercontent.com/LucaLin233/Linux/refs/heads/main/debian_setup.sh)"
        echo ""
        echo "生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
    } > "$SUMMARY_FILE" 2>/dev/null || true
    
    echo
    print_separator "-" 50 "$CYAN"
    log "📋 详细摘要已保存至: $SUMMARY_FILE" "highlight"
    print_separator "-" 50 "$CYAN"
}

#--- 最终建议 ---
show_recommendations() {
    echo
    print_box "系统部署完成！" "$GREEN"
    
    # SSH 安全提醒
    if [[ " ${EXECUTED_MODULES[*]} " =~ " ssh-security " ]]; then
        local new_ssh_port
        new_ssh_port=$(grep "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "22")
        if [[ "$new_ssh_port" != "22" ]] && [[ -n "$new_ssh_port" ]]; then
            echo
            print_separator "!" 60 "$YELLOW"
            log "🚨 重要安全提醒: SSH 端口已更改为 $new_ssh_port" "warn"
            log "🔗 新连接命令: ssh -p $new_ssh_port user@$(hostname -I 2>/dev/null | awk '{print $1}' || echo 'IP')" "highlight"
            log "🛡️  请确保防火墙规则已正确配置！" "warn"
            print_separator "!" 60 "$YELLOW"
        fi
    fi
    
    echo
    log "📚 常用操作指南" "stats"
    echo "   📖 查看详细日志: tail -f $LOG_FILE"
    echo "   📋 查看部署摘要: cat $SUMMARY_FILE"
    echo "   🔄 重新运行脚本: bash <(curl -fsSL https://raw.githubusercontent.com/LucaLin233/Linux/refs/heads/main/debian_setup.sh)"
    echo "   📊 检查部署状态: bash <(curl -fsSL https://raw.githubusercontent.com/LucaLin233/Linux/refs/heads/main/debian_setup.sh) --check-status"
    echo "   🆘 获取帮助信息: bash <(curl -fsSL https://raw.githubusercontent.com/LucaLin233/Linux/refs/heads/main/debian_setup.sh) --help"
    
    # 模块特定建议
    if [[ " ${EXECUTED_MODULES[*]} " =~ " zsh-setup " ]]; then
        echo
        log "🐚 Zsh 使用指南" "highlight"
        echo "   • 立即切换到 Zsh: exec zsh"
        echo "   • 重新配置主题: p10k configure"
        echo "   • 查看可用插件: ls ~/.oh-my-zsh/plugins/"
    fi
    
    if [[ " ${EXECUTED_MODULES[*]} " =~ " docker-setup " ]]; then
        echo
        log "🐳 Docker 使用指南" "highlight"
        echo "   • 检查 Docker 状态: docker version"
        echo "   • 管理 Docker 服务: systemctl status docker"
        echo "   • Docker 使用帮助: docker --help"
    fi
    
    if [[ " ${EXECUTED_MODULES[*]} " =~ " mise-setup " ]]; then
        echo
        log "📦 Mise 使用指南" "highlight"
        echo "   • 查看可用工具: mise ls-remote"
        echo "   • 安装 Node.js: mise install node@latest"
        echo "   • 切换工具版本: mise use node@18"
    fi
    
    echo
    print_separator "~" 50 "$GREEN"
    echo -e "${GREEN}${BOLD}感谢使用 Debian 系统部署脚本！${NC}"
    echo -e "${GREEN}如有问题，请查看日志文件或访问项目仓库。${NC}"
    print_separator "~" 50 "$GREEN"
}

#--- 命令行参数处理 ---
handle_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --check-status)
                if [[ -f "$SUMMARY_FILE" ]]; then
                    cat "$SUMMARY_FILE"
                else
                    echo "❌ 未找到部署摘要文件"
                fi
                exit 0
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            --version|-v)
                echo "🚀 Debian 部署脚本 v$SCRIPT_VERSION"
                exit 0
                ;;
            *)
                echo "❌ 未知参数: $1"
                echo "💡 使用 --help 查看帮助"
                exit 1
                ;;
        esac
        shift
    done
}

#--- 帮助信息 ---
show_help() {
    cat << EOF
🚀 Debian 系统部署脚本 v$SCRIPT_VERSION

📖 用法: $0 [选项]

🎛️  选项:
  --check-status    📊 查看最近的部署状态
  --help, -h        🆘 显示此帮助信息
  --version, -v     🔢 显示版本信息

🧩 功能模块:
  • system-optimize    🔧 系统优化 (Zram, 时区设置)
  • zsh-setup          🐚 Zsh Shell 环境配置
  • mise-setup         📦 Mise 版本管理器安装
  • docker-setup       🐳 Docker 容器化平台
  • network-optimize   🌐 网络性能优化 (BBR)
  • ssh-security       🔒 SSH 安全加固
  • auto-update-setup  🔄 自动更新系统配置

✨ 特性:
  ✓ 智能依赖处理    ✓ 模块化部署      ✓ 4种部署模式
  ✓ 进度显示        ✓ 系统状态检查    ✓ 丰富摘要生成
  ✓ 错误处理机制    ✓ 彩色界面        ✓ 详细日志记录

📁 文件位置:
  📄 日志文件: $LOG_FILE
  📋 摘要文件: $SUMMARY_FILE

🎯 示例:
  $0                  # 🚀 交互式部署
  $0 --check-status   # 📊 查看部署状态
  $0 --help          # 🆘 显示帮助信息

📧 问题反馈: https://github.com/LucaLin233/Linux
EOF
}

#--- 主程序 ---
main() {
    # 处理命令行参数
    handle_arguments "$@"
    
    # 初始化
    mkdir -p "$(dirname "$LOG_FILE")" "$TEMP_DIR" 2>/dev/null || true
    : > "$LOG_FILE" 2>/dev/null || true
    TOTAL_START_TIME=$(date +%s 2>/dev/null || echo "0")
    
    # 启动画面
    clear 2>/dev/null || true
    print_box "Debian 系统部署脚本 v$SCRIPT_VERSION" "$PURPLE"
    print_separator "=" 60 "$BLUE"
    
    log "🎯 Debian 系统部署脚本启动" "title"
    
    # 基础检查
    check_system
    check_network
    install_dependencies
    system_update
    
    # 模块选择和执行
    select_deployment_mode
    
    if (( ${#SELECTED_MODULES[@]} == 0 )); then
        log "未选择任何模块，退出" "warn"
        exit 0
    fi
    
    # 解析依赖
    resolve_dependencies
    
    echo
    log "📋 最终执行计划: ${SELECTED_MODULES[*]}" "highlight"
    echo
    read -p "🤔 确认执行以上模块? [Y/n]: " -r choice
    choice="${choice:-Y}"
    [[ "$choice" =~ ^[Yy]$ ]] || exit 0
    
    # 下载和执行模块
    local total=${#SELECTED_MODULES[@]}
    local current=0
    
    echo
    print_separator "~" 50 "$GREEN"
    log "开始下载和执行 $total 个模块..." "title"
    print_separator "~" 50 "$GREEN"
    
    for module in "${SELECTED_MODULES[@]}"; do
        current=$((current + 1))
        echo
        print_separator "-" 60 "$CYAN"
        show_progress "$current" "$total" "处理模块: ${MODULES[$module]}"
        print_separator "-" 60 "$CYAN"
        
        if download_module "$module"; then
            execute_module "$module" || log "继续执行其他模块... ⏭️" "warn"
        else
            FAILED_MODULES+=("$module")
            log "跳过执行 $module ⏭️" "warn"
        fi
    done
    
    # 生成摘要和建议
    generate_summary
    show_recommendations
    
    echo
    print_box "所有部署任务完成！" "$GREEN"
}

# 执行主程序
main "$@"
