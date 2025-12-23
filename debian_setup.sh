#!/bin/bash

#=============================================================================
# Debian 系统部署脚本 v3.5.0
# 适用系统: Debian 12+, 作者: LucaLin233
# 功能: 模块化部署，智能依赖处理
#=============================================================================

set -uo pipefail

# 全局常量
readonly SCRIPT_VERSION="3.5.0"
SCRIPT_COMMIT="${SCRIPT_COMMIT:-unknown}"
readonly MODULE_BASE_URL="https://raw.githubusercontent.com/LucaLin233/Linux"
readonly TEMP_DIR="/tmp/debian-setup-modules"
readonly LOG_FILE="/var/log/debian-setup.log"
readonly SUMMARY_FILE="/root/deployment_summary.txt"
readonly LINE="============================================================"

# 模块定义
declare -A MODULES=(
    ["system-optimize"]="系统优化 (Zram, 时区, 时间同步)"
    ["zsh-setup"]="Zsh Shell 环境"
    ["mise-setup"]="Mise 版本管理器"
    ["docker-setup"]="Docker 容器化平台"
    ["tools-setup"]="系统工具 (NextTrace, SpeedTest等)"
    ["ssh-security"]="SSH 安全配置"
    ["auto-update-setup"]="自动更新系统"
)

# 依赖关系
declare -A MODULE_DEPS=(
    ["zsh-setup"]="system-optimize"
    ["mise-setup"]="system-optimize zsh-setup"
)

# 标准执行顺序（按依赖层级）
readonly MODULE_ORDER=(
    system-optimize
    zsh-setup
    docker-setup
    tools-setup
    ssh-security
    mise-setup
    auto-update-setup
)

# 执行状态
declare -A MODULE_STATUS
declare -A MODULE_EXEC_TIME
SELECTED_MODULES=()
TOTAL_START_TIME=0
LATEST_COMMIT=""
FILTERED_ARGS=()

# 颜色定义
readonly C_RED='\033[0;31m'
readonly C_GREEN='\033[0;32m'
readonly C_YELLOW='\033[0;33m'
readonly C_NC='\033[0m'

#=============================================================================
# 工具函数
#=============================================================================

log() {
    local msg="$1"
    local level="${2:-info}"
    local timestamp=$(date '+%H:%M:%S')
    
    local -A icons=([info]="✅" [warn]="⚠️ " [error]="❌" [success]="🎉")
    local -A colors=([info]=$C_GREEN [warn]=$C_YELLOW [error]=$C_RED [success]=$C_GREEN)
    
    echo -e "${colors[$level]}${icons[$level]} $msg${C_NC}"
    echo "[$timestamp] [$level] $msg" >> "$LOG_FILE"
}

check_command() {
    command -v "$1" &>/dev/null
}

get_info() {
    "$@" 2>/dev/null || echo "未知"
}

cleanup() {
    local exit_code=$?
    
    if (( exit_code != 0 )); then
        log "脚本异常退出，保留临时文件用于调试: $TEMP_DIR" "error"
        log "调试完成后手动删除: rm -rf $TEMP_DIR" "warn"
        log "详细日志: $LOG_FILE" "error"
    else
        [[ -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR" 2>/dev/null || true
    fi
    
    exit $exit_code
}
trap cleanup EXIT INT TERM

init_logging() {
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    
    if ! touch "$LOG_FILE" 2>/dev/null; then
        echo "⚠️  无法写入日志文件 $LOG_FILE，将只输出到终端"
        LOG_FILE="/dev/null"
    else
        : > "$LOG_FILE"
    fi
}

#=============================================================================
# 系统检查
#=============================================================================

pre_check() {
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
    free_space_kb=$(df / 2>/dev/null \vert{} awk 'NR==2 {print $4}')
    
    if [[ -z "$free_space_kb" ]] || [[ ! "$free_space_kb" =~ ^[0-9]+$ ]]; then
        log "无法获取磁盘空间信息，跳过检查" "warn"
    elif (( free_space_kb < 1048576 )); then
        log "磁盘空间不足 (需要至少1GB)" "error"
        exit 1
    fi
    
    log "检查网络连接..."
    if ! ping -c 1 -W 3 8.8.8.8 &>/dev/null; then
        log "网络连接异常，可能影响模块下载" "warn"
        read -p "继续执行? [y/N]: " -r choice
        [[ "$choice" =~ ^[Yy]$ ]] || exit 0
    fi
    
    log "系统检查通过"
}

#=============================================================================
# 依赖安装
#=============================================================================

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
        
        if ! check_command "$check_cmd"; then
            missing_packages+=("$package_name")
        fi
    done
    
    if (( ${#missing_packages[@]} > 0 )); then
        log "安装缺失依赖: ${missing_packages[*]}"
        
        if ! apt-get update -qq; then
            log "依赖安装失败" "error"
            exit 1
        fi
        
        if ! apt-get install -y "${missing_packages[@]}"; then
            log "依赖安装失败" "error"
            exit 1
        fi
    fi
    
    log "依赖检查完成"
}

#=============================================================================
# 系统更新
#=============================================================================

system_update() {
    log "系统更新"
    
    apt-get update 2>/dev/null || log "软件包列表更新失败" "warn"
    apt-get upgrade -y 2>/dev/null || log "系统升级失败" "warn"
    
    fix_hosts_file
    
    log "系统更新完成"
}

fix_hosts_file() {
    local hostname=$(hostname)
    
    if grep -qE "^127\.0\.1\.1[[:space:]]+.*\b$hostname\b" /etc/hosts 2>/dev/null; then
        return 0
    fi
    
    cp /etc/hosts "/etc/hosts.backup.$(date +%s)" 2>/dev/null || true
    
    if grep -q "^127.0.1.1" /etc/hosts 2>/dev/null; then
        sed -i "s/^127\.0\.1\.1[[:space:]]\+/127.0.1.1 $hostname /" /etc/hosts
    else
        echo "127.0.1.1 $hostname" >> /etc/hosts
    fi
}

#=============================================================================
# 模块选择
#=============================================================================

select_deployment_mode() {
    log "选择部署模式"
    
    echo
    echo "$LINE"
    echo "部署模式选择："
    echo "1) 🚀 全部安装 (安装所有7个模块)"
    echo "2) 🎯 自定义选择 (按需选择模块)"
    echo
    
    read -p "请选择模式 [1-2]: " -r mode_choice
    
    case "$mode_choice" in
        1)
            SELECTED_MODULES=("${MODULE_ORDER[@]}")
            log "选择: 全部安装"
            ;;
        2)
            custom_module_selection
            ;;
        *)
            log "无效选择，使用全部安装" "warn"
            SELECTED_MODULES=("${MODULE_ORDER[@]}")
            ;;
    esac
}

custom_module_selection() {
    echo
    echo "可用模块："
    
    local i=1
    for module in "${MODULE_ORDER[@]}"; do
        echo "$i) $module - ${MODULES[$module]}"
        ((i++))
    done
    
    echo
    echo "请输入要安装的模块编号 (用空格分隔，如: 1 3 5):"
    read -r selection
    
    local selected=()
    for num in $selection; do
        if [[ "$num" =~ ^[1-7]$ ]]; then
            local index=$((num - 1))
            selected+=("${MODULE_ORDER[$index]}")
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

#=============================================================================
# 依赖解析（递归 + 拓扑排序）
#=============================================================================

resolve_dependencies() {
    local all_needed=()
    
    collect_deps() {
        local module="$1"
        [[ " ${all_needed[*]} " =~ " $module " ]] && return
        
        for dep in ${MODULE_DEPS[$module]:-}; do
            collect_deps "$dep"
        done
        
        all_needed+=("$module")
    }
    
    for module in "${SELECTED_MODULES[@]}"; do
        collect_deps "$module"
    done
    
    local added_deps=()
    for module in "${all_needed[@]}"; do
        if [[ ! " ${SELECTED_MODULES[*]} " =~ " $module " ]]; then
            added_deps+=("$module")
        fi
    done
    
    if (( ${#added_deps[@]} > 0 )); then
        echo
        log "检测到依赖关系，需要添加: ${added_deps[*]}" "warn"
        read -p "自动添加依赖模块? [Y/n]: " -r choice
        choice="${choice:-Y}"
        if [[ ! "$choice" =~ ^[Yy]$ ]]; then
            log "用户取消添加依赖，可能导致执行失败" "warn"
            return
        fi
    fi
    
    local sorted=()
    for module in "${MODULE_ORDER[@]}"; do
        if [[ " ${all_needed[*]} " =~ " $module " ]]; then
            sorted+=("$module")
        fi
    done
    
    SELECTED_MODULES=("${sorted[@]}")
}

#=============================================================================
# 模块下载（带重试）
#=============================================================================

get_latest_commit() {
    local commit_hash
    commit_hash=$(curl -s --connect-timeout 5 --max-time 10 \
        "https://api.github.com/repos/LucaLin233/Linux/commits/main" 2>/dev/null | \
        grep '"sha"' | head -1 | cut -d'"' -f4 | cut -c1-7 2>/dev/null)
    
    if [[ -n "$commit_hash" ]] && [[ ${#commit_hash} -eq 7 ]]; then
        echo "$commit_hash"
    else
        echo "main"
    fi
}

download_with_retry() {
    local url="$1"
    local output="$2"
    local max_attempts=3
    
    for i in $(seq 1 $max_attempts); do
        if curl -fsSL --connect-timeout 10 --max-time 30 "$url" -o "$output" 2>/dev/null; then
            if [[ -s "$output" ]]; then
                local first_line
                first_line=$(head -1 "$output" 2>/dev/null)
                
                if [[ "$first_line" == "#!/bin/bash"* ]] || \
                   [[ "$first_line" == "#!/usr/bin/env bash"* ]] || \
                   [[ "$first_line" == "#!/bin/sh"* ]]; then
                    return 0
                fi
            fi
        fi
        
        if (( i < max_attempts )); then
            log "下载失败，2秒后重试 ($i/$max_attempts)..." "warn"
            sleep 2
        fi
    done
    
    return 1
}

download_module() {
    local module="$1"
    local module_file="$TEMP_DIR/${module}.sh"
    
    log "获取模块 $module (commit: $LATEST_COMMIT)"
    
    local download_url="$MODULE_BASE_URL/$LATEST_COMMIT/modules/${module}.sh"
    
    if download_with_retry "$download_url" "$module_file"; then
        chmod +x "$module_file" 2>/dev/null || true
        return 0
    fi
    
    log "模块 $module 下载失败" "error"
    return 1
}

#=============================================================================
# 脚本自我更新
#=============================================================================

try_cached_script() {
    local commit="$1"
    local cached_script="/var/cache/debian-setup/debian_setup_${commit}.sh"
    
    if [[ -f "$cached_script" ]] && [[ -s "$cached_script" ]]; then
        if head -1 "$cached_script" 2>/dev/null | grep -qE "^#!/bin/(bash|sh)"; then
            log "使用缓存的脚本 (commit: $commit)"
            chmod +x "$cached_script"
            exec bash "$cached_script" "${FILTERED_ARGS[@]}"
        else
            log "缓存文件损坏，删除" "warn"
            rm -f "$cached_script"
            return 1
        fi
    fi
    return 1
}

self_update() {
    log "检查脚本更新..."
    
    local latest_commit
    latest_commit=$(get_latest_commit)
    
    if [[ "$latest_commit" == "main" ]]; then
        log "无法获取最新版本信息，跳过更新检查" "warn"
        return 0
    fi
    
    log "当前 commit: $SCRIPT_COMMIT"
    log "最新 commit: $latest_commit"
    
    if [[ "$latest_commit" == "$SCRIPT_COMMIT" ]]; then
        log "已是最新版本 (commit: $SCRIPT_COMMIT)"
        return 0
    fi
    
    try_cached_script "$latest_commit" && return 0
    
    local temp_script="/tmp/debian_setup_latest.sh"
    local script_url="https://raw.githubusercontent.com/LucaLin233/Linux/$latest_commit/debian_setup.sh"
    
    log "下载最新版本..."
    
    if ! curl -fsSL --connect-timeout 10 --max-time 30 "$script_url" -o "$temp_script" 2>/dev/null; then
        log "无法下载最新版本，继续使用当前版本" "warn"
        return 0
    fi
    
    if [[ ! -s "$temp_script" ]] \vert{}\vert{} ! head -1 "$temp_script" | grep -qE "^#!/bin/(bash|sh)" 2>/dev/null; then
        log "下载的文件格式不正确，跳过更新" "warn"
        rm -f "$temp_script"
        return 0
    fi
    
    local remote_version
    remote_version=$(grep "^readonly SCRIPT_VERSION=" "$temp_script" 2>/dev/null | cut -d'"' -f2)
    remote_version="${remote_version:-未知}"
    
    echo
    log "发现新版本!" "warn"
    echo "  当前: v$SCRIPT_VERSION (commit: $SCRIPT_COMMIT)"
    echo "  最新: v$remote_version (commit: $latest_commit)"
    echo
    
    read -p "是否更新并重新运行? [Y/n]: " -r choice
    choice="${choice:-Y}"
    
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        log "更新脚本..."
        
        sed -i "13a SCRIPT_COMMIT=\"$latest_commit\"" "$temp_script"
        
        local cache_dir="/var/cache/debian-setup"
        mkdir -p "$cache_dir" 2>/dev/null || true
        
        if [[ -d "$cache_dir" ]]; then
            chmod +x "$temp_script"
            local cached_script="$cache_dir/debian_setup_${latest_commit}.sh"
            cp "$temp_script" "$cached_script" 2>/dev/null || true
            
            ls -t "$cache_dir"/debian_setup_*.sh 2>/dev/null | tail -n +4 | xargs rm -f 2>/dev/null || true
            
            log "脚本已缓存到: $cached_script"
        fi
        
        log "脚本已更新到 v$remote_version (commit: $latest_commit)" "success"
        log "重新启动脚本..." "success"
        
        if [[ -f "$cached_script" ]]; then
            exec bash "$cached_script" "${FILTERED_ARGS[@]}"
        else
            exec bash "$temp_script" "${FILTERED_ARGS[@]}"
        fi
    else
        log "跳过更新，继续使用当前版本"
        rm -f "$temp_script"
    fi
}

#=============================================================================
# 模块执行
#=============================================================================

execute_module() {
    local module="\$1"
    local module_file="$TEMP_DIR/${module}.sh"
    
    if [[ ! -f "$module_file" ]]; then
        log "模块文件不存在: $module" "error"
        MODULE_STATUS[$module]="failed"
        return 1
    fi
    
    log "执行模块: ${MODULES[$module]}"
    
    local start_time=$(date +%s)
    local exec_result=0
    
    set +e
    bash "$module_file"
    exec_result=$?
    set -e
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    MODULE_EXEC_TIME[$module]=$duration
    
    if (( exec_result == 0 )); then
        MODULE_STATUS[$module]="success"
        log "模块 $module 执行成功 (${duration}s)" "success"
        return 0
    else
        MODULE_STATUS[$module]="failed"
        log "模块 $module 执行失败 (${duration}s)" "error"
        return 1
    fi
}

#=============================================================================
# 系统状态获取
#=============================================================================

get_system_status() {
    local cpu_cores=$(nproc 2>/dev/null || echo "未知")
    local mem_info=$(free -h 2>/dev/null | grep Mem | awk '{print \$3"/"\$2}' || echo "未知")
    local disk_usage=$(df -h / 2>/dev/null | awk 'NR==2 {print \$5}' || echo "未知")
    local uptime_info=$(uptime -p 2>/dev/null || echo "未知")
    local kernel=$(uname -r 2>/dev/null || echo "未知")
    
    echo "💻 CPU: ${cpu_cores}核心 \vert{} 内存: $mem_info | 磁盘: $disk_usage"
    echo "⏰ 运行时间: $uptime_info"
    echo "🔧 内核: $kernel"
    
    if check_command zsh; then
        local zsh_version=$(zsh --version 2>/dev/null | awk '{print \$2}' || echo "未知")
        local root_shell=$(getent passwd root 2>/dev/null | cut -d: -f7)
        if [[ "$root_shell" == "$(which zsh 2>/dev/null)" ]]; then
            echo "🐚 Zsh: v$zsh_version (已设为默认)"
        else
            echo "🐚 Zsh: v$zsh_version (已安装但未设为默认)"
        fi
    else
        echo "🐚 Zsh: 未安装"
    fi
    
    if check_command docker; then
        local docker_version=$(docker --version 2>/dev/null | awk '{print \$3}' | tr -d ',' || echo "未知")
        local containers_count=$(docker ps -q 2>/dev/null | wc -l || echo "0")
        local images_count=$(docker images -q 2>/dev/null | wc -l || echo "0")
        if systemctl is-active --quiet docker 2>/dev/null; then
            echo "🐳 Docker: v$docker_version (运行中) \vert{} 容器: $containers_count | 镜像: $images_count"
        else
            echo "🐳 Docker: v$docker_version (已安装但未运行) \vert{} 容器: $containers_count | 镜像: $images_count"
        fi
    else
        echo "🐳 Docker: 未安装"
    fi
    
    if [[ -f "$HOME/.local/bin/mise" ]]; then
        local mise_version=$("$HOME/.local/bin/mise" --version 2>/dev/null | head -1 || echo "未知")
        echo "📦 Mise: v$mise_version"
    else
        echo "📦 Mise: 未安装"
    fi
    
    local tools_status=()
    check_command nexttrace && tools_status+=("NextTrace")
    check_command speedtest && tools_status+=("SpeedTest")
    check_command htop && tools_status+=("htop")
    check_command tree && tools_status+=("tree")
    check_command jq && tools_status+=("jq")
    if (( ${#tools_status[@]} > 0 )); then
        echo "🛠️ 工具: ${tools_status[*]}"
    else
        echo "🛠️ 工具: 未安装"
    fi
    
    local ssh_port=$(grep "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print \$2}' || echo "22")
    local ssh_root_login=$(grep "^PermitRootLogin " /etc/ssh/sshd_config 2>/dev/null | awk '{print \$2}' || echo "默认")
    echo "🔒 SSH: 端口=$ssh_port \vert{} Root登录=$ssh_root_login"
    
    local network_ip=$(hostname -I 2>/dev/null | awk '{print \$1}' || echo "未知")
    local network_interface=$(ip route 2>/dev/null | grep default | awk '{print \$5}' | head -1 || echo "未知")
    echo "🌐 网络: $network_ip via $network_interface"
}

#=============================================================================
# 部署摘要
#=============================================================================

generate_summary() {
    log "生成部署摘要"
    
    local success_count=0
    local failed_count=0
    
    for module in "${!MODULE_STATUS[@]}"; do
        if [[ "${MODULE_STATUS[$module]}" == "success" ]]; then
            success_count=$((success_count + 1))
        elif [[ "${MODULE_STATUS[$module]}" == "failed" ]]; then
            failed_count=$((failed_count + 1))
        fi
    done
    
    local total_modules=$((success_count + failed_count))
    local success_rate=0
    if [[ $total_modules -gt 0 ]]; then
        success_rate=$((success_count * 100 / total_modules))
    fi
    
    local total_time=$(( $(date +%s) - TOTAL_START_TIME ))
    local avg_time=0
    if [[ $success_count -gt 0 ]]; then
        avg_time=$((total_time / success_count))
    fi
    
    echo
    echo "$LINE"
    echo "Debian 系统部署完成摘要"
    echo "$LINE"
    
    cat << EOF

📋 基本信息:
   🔢 脚本版本: $SCRIPT_VERSION (commit: $SCRIPT_COMMIT)
   📅 部署时间: $(date '+%Y-%m-%d %H:%M:%S %Z')
   ⏱️  总耗时: ${total_time}秒 \vert{} 平均耗时: ${avg_time}秒/模块
   🏠 主机名: $(hostname)
   💻 系统: $(grep 'PRETTY_NAME' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || echo 'Debian')
   🌐 IP地址: $(hostname -I 2>/dev/null | awk '{print \$1}' || echo '未知')

📊 执行统计:
   📦 总模块: $total_modules \vert{} ✅ 成功: $success_count | ❌ 失败: $failed_count \vert{} 📈 成功率: ${success_rate}%

EOF
    
    if [[ $success_count -gt 0 ]]; then
        echo "✅ 成功模块:"
        for module in "${MODULE_ORDER[@]}"; do
            if [[ "${MODULE_STATUS[$module]:-}" == "success" ]]; then
                local exec_time=${MODULE_EXEC_TIME[$module]:-0}
                echo "   🟢 $module: ${MODULES[$module]} (${exec_time}s)"
            fi
        done
        echo
    fi
    
    if [[ $failed_count -gt 0 ]]; then
        echo "❌ 失败模块:"
        for module in "${MODULE_ORDER[@]}"; do
            if [[ "${MODULE_STATUS[$module]:-}" == "failed" ]]; then
                local exec_time=${MODULE_EXEC_TIME[$module]:-0}
                echo "   🔴 $module: ${MODULES[$module]} (${exec_time}s)"
            fi
        done
        echo
    fi
    
    echo "🖥️ 当前系统状态:"
    while IFS= read -r status_line; do
        echo "   $status_line"
    done < <(get_system_status)
    
    {
        echo "$LINE"
        echo "Debian 系统部署摘要"
        echo "$LINE"
        echo "脚本版本: $SCRIPT_VERSION (commit: $SCRIPT_COMMIT)"
        echo "部署时间: $(date '+%Y-%m-%d %H:%M:%S %Z')"
        echo "总耗时: ${total_time}秒"
        echo "主机: $(hostname)"
        echo "系统: $(grep 'PRETTY_NAME' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || echo 'Debian')"
        echo "IP地址: $(hostname -I 2>/dev/null | awk '{print \$1}' || echo '未知')"
        echo ""
        echo "执行统计:"
        echo "总模块: $total_modules, 成功: $success_count, 失败: $failed_count, 成功率: ${success_rate}%"
        echo ""
        
        if [[ $success_count -gt 0 ]]; then
            echo "成功模块:"
            for module in "${MODULE_ORDER[@]}"; do
                [[ "${MODULE_STATUS[$module]:-}" == "success" ]] && echo "  $module (${MODULE_EXEC_TIME[$module]:-0}s)"
            done
        fi
        
        if [[ $failed_count -gt 0 ]]; then
            echo ""
            echo "失败模块:"
            for module in "${MODULE_ORDER[@]}"; do
                [[ "${MODULE_STATUS[$module]:-}" == "failed" ]] && echo "  $module"
            done
        fi
        
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
    echo "$LINE"
}

#=============================================================================
# 最终建议
#=============================================================================

show_recommendations() {
    echo
    log "部署完成！" "success"
    
    if [[ "${MODULE_STATUS[ssh-security]:-}" == "success" ]]; then
        local new_ssh_port=$(grep "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print \$2}' || echo "22")
        if [[ "$new_ssh_port" != "22" ]]; then
            echo
            echo "⚠️  重要: SSH端口已更改为 $new_ssh_port"
            echo "   新连接: ssh -p $new_ssh_port user@$(hostname -I | awk '{print \$1}')"
        fi
    fi
    
    echo
    echo "📚 常用命令:"
    echo "   查看日志: tail -f $LOG_FILE"
    echo "   查看摘要: cat $SUMMARY_FILE"
    echo "   重新运行: bash <(curl -fsSL https://raw.githubusercontent.com/LucaLin233/Linux/refs/heads/main/debian_setup.sh)"
}

#=============================================================================
# 帮助信息
#=============================================================================

show_help() {
    cat << EOF
Debian 系统部署脚本 v$SCRIPT_VERSION

用法: $0 [选项]

选项:
  --check-status    查看部署状态
  --clean-cache     清理脚本缓存
  --help, -h        显示帮助信息
  --version, -v     显示版本信息

功能模块:
  system-optimize, zsh-setup, mise-setup, docker-setup, 
  tools-setup, ssh-security, auto-update-setup

文件位置:
  日志: $LOG_FILE
  摘要: $SUMMARY_FILE
  缓存: /var/cache/debian-setup/
EOF
}

#=============================================================================
# 命令行参数处理
#=============================================================================

handle_arguments() {
    FILTERED_ARGS=()
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --internal-commit=*)
                SCRIPT_COMMIT="${1#*=}"
                readonly SCRIPT_COMMIT
                shift
                ;;
            --clean-cache)
                log "清理脚本缓存..."
                rm -rf /var/cache/debian-setup/ 2>/dev/null || true
                log "缓存已清理" "success"
                exit 0
                ;;
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
                echo "Debian 部署脚本 v$SCRIPT_VERSION"
                [[ "$SCRIPT_COMMIT" != "unknown" ]] && echo "Commit: $SCRIPT_COMMIT"
                exit 0
                ;;
            *)
                FILTERED_ARGS+=("$1")
                shift
                ;;
        esac
    done
}

#=============================================================================
# 主程序
#=============================================================================

main() {
    handle_arguments "$@"
    
    init_logging
    mkdir -p "$TEMP_DIR" 2>/dev/null || true
    TOTAL_START_TIME=$(date +%s)
    
    clear 2>/dev/null || true
    echo "$LINE"
    echo "Debian 系统部署脚本 v$SCRIPT_VERSION"
    [[ "$SCRIPT_COMMIT" != "unknown" ]] && echo "Commit: $SCRIPT_COMMIT"
    echo "$LINE"
    
    self_update
    echo
    
    pre_check
    install_dependencies
    system_update
    
    log "获取 GitHub 最新代码版本..."
    LATEST_COMMIT=$(get_latest_commit)
    readonly LATEST_COMMIT
    log "当前版本: $LATEST_COMMIT"
    
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
    
    echo
    echo "$LINE"
    log "开始下载 ${#SELECTED_MODULES[@]} 个模块"
    echo "$LINE"
    
    local download_failed=0
    local downloaded=0
    
    for module in "${SELECTED_MODULES[@]}"; do
        downloaded=$((downloaded + 1))
        echo
        echo "[$downloaded/${#SELECTED_MODULES[@]}] 下载模块: $module"
        
        set +e
        download_module "$module"
        local result=$?
        set -e
        
        if (( result == 0 )); then
            log "✓ $module 下载成功"
        else
            MODULE_STATUS[$module]="failed"
            download_failed=$((download_failed + 1))
            log "✗ $module 下载失败" "error"
        fi
    done
    
    echo
    if (( download_failed > 0 )); then
        log "有 $download_failed 个模块下载失败" "warn"
        read -p "是否继续执行已下载的模块? [y/N]: " -r choice
        [[ "$choice" =~ ^[Yy]$ ]] || exit 1
    else
        log "所有模块下载完成" "success"
    fi
    
    echo
    echo "$LINE"
    log "开始执行模块"
    echo "$LINE"
    
    local current=0
    local total=${#SELECTED_MODULES[@]}
    
    set +e
    
    for module in "${SELECTED_MODULES[@]}"; do
        current=$((current + 1))
        
        if [[ "${MODULE_STATUS[$module]:-}" == "failed" ]]; then
            log "跳过模块 $module (下载失败)" "warn"
            continue
        fi
        
        echo
        echo "[$current/$total] 执行模块: ${MODULES[$module]}"
        
        execute_module "$module"
        local result=$?
        
        if (( result != 0 )); then
            log "模块 $module 执行失败" "warn"
        fi
    done
    
    set -e
    
    generate_summary
    show_recommendations
}

main "$@"
