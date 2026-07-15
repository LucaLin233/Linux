#!/usr/bin/env bash
# =============================================================================
# Debian 系统部署脚本
# 适用系统：Debian 12+
# 功能：模块化部署、依赖处理、模块版本固定下载
# =============================================================================

set -uo pipefail

# === 全局常量 ===
readonly SCRIPT_VERSION="4.0.0"
SCRIPT_COMMIT="${SCRIPT_COMMIT:-unknown}"

readonly MODULE_BASE_URL="https://raw.githubusercontent.com/LucaLin233/Linux"
readonly GITHUB_API_URL="https://api.github.com/repos/LucaLin233/Linux/commits/main"

LOG_FILE="/var/log/debian-setup.log"
readonly SUMMARY_FILE="/root/deployment_summary.txt"
readonly CACHE_DIR="/var/cache/debian-setup"
readonly LINE="============================================================"

TEMP_DIR=""
LATEST_COMMIT=""
TOTAL_START_TIME=0

SELECTED_MODULES=()
FILTERED_ARGS=()

declare -A MODULE_STATUS
declare -A MODULE_EXEC_TIME

# === 模块定义 ===
declare -A MODULES=(
    ["system-optimize"]="系统优化（Zram、时区、Chrony 时间同步）"
    ["system-customize"]="系统定制（欢迎信息、中文环境、XanMod 内核）"
    ["network-optimize"]="网络优化（BBR、fq、IPv4 转发）"
    ["zsh-setup"]="Zsh Shell 环境"
    ["mise-setup"]="Mise、Python、Node.js 版本管理"
    ["tools-setup"]="系统工具（NextTrace、测速、htop 等）"
    ["docker-setup"]="Docker 容器化平台"
    ["auto-update-setup"]="自动更新系统与内核"
    ["ssh-security"]="SSH 安全配置"
)

# === 模块依赖 ===
declare -A MODULE_DEPS=(
    ["system-customize"]="system-optimize"
    ["network-optimize"]="system-optimize"
    ["zsh-setup"]="system-optimize"
    ["mise-setup"]="system-optimize zsh-setup"
)

# === 标准执行顺序 ===
readonly MODULE_ORDER=(
    system-optimize
    system-customize
    network-optimize
    zsh-setup
    mise-setup
    tools-setup
    docker-setup
    auto-update-setup
    ssh-security
)

# === 颜色 ===
readonly C_RED='\033[0;31m'
readonly C_GREEN='\033[0;32m'
readonly C_YELLOW='\033[0;33m'
readonly C_CYAN='\033[0;36m'
readonly C_NC='\033[0m'

# =============================================================================
# 基础函数
# =============================================================================

log() {
    local message="$1"
    local level="${2:-info}"
    local timestamp
    local color
    local icon

    timestamp=$(date '+%H:%M:%S')

    case "$level" in
        info)
            color="$C_CYAN"
            icon="ℹ️ "
            ;;
        warn)
            color="$C_YELLOW"
            icon="⚠️ "
            ;;
        error)
            color="$C_RED"
            icon="❌"
            ;;
        success)
            color="$C_GREEN"
            icon="✅"
            ;;
        *)
            color="$C_NC"
            icon="•"
            ;;
    esac

    echo -e "${color}${icon} ${message}${C_NC}"
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE" 2>/dev/null || true
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

cleanup() {
    local exit_code=$?

    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        if (( exit_code == 0 )); then
            rm -rf "$TEMP_DIR" 2>/dev/null || true
        else
            log "脚本异常退出，临时文件保留在：$TEMP_DIR" "error"
            log "调试完成后可手动删除：rm -rf $TEMP_DIR" "warn"
            log "详细日志：$LOG_FILE" "error"
        fi
    fi

    exit "$exit_code"
}

init_logging() {
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

    if ! touch "$LOG_FILE" 2>/dev/null; then
        echo "⚠️ 无法写入日志文件 $LOG_FILE，将仅输出到终端"
        LOG_FILE="/dev/null"
    else
        : > "$LOG_FILE"
    fi
}

create_temp_dir() {
    if ! TEMP_DIR=$(mktemp -d -p /tmp debian-setup.XXXXXX); then
        log "无法创建安全临时目录" "error"
        exit 1
    fi

    chmod 700 "$TEMP_DIR"
}

# =============================================================================
# 系统检查
# =============================================================================

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
    free_space_kb=$(LANG=C df / 2>/dev/null | awk 'NR == 2 {print $4}' | tr -cd '0-9')

    if [[ -z "$free_space_kb" || "$free_space_kb" == "0" ]]; then
        log "无法获取根分区可用空间，跳过磁盘检查" "warn"
    else
        local free_space_gb
        free_space_gb=$((free_space_kb / 1024 / 1024))

        log "根分区可用空间：${free_space_gb}GB"

        if (( free_space_kb < 1048576 )); then
            log "根分区可用空间不足 1GB" "error"
            exit 1
        fi
    fi

    log "检查 GitHub 下载连接..."

    if ! curl -fsI \
        --connect-timeout 5 \
        --max-time 10 \
        "https://raw.githubusercontent.com/" >/dev/null 2>&1; then
        log "无法连接 raw.githubusercontent.com，模块下载可能失败" "warn"

        local choice
        read -r -p "是否继续执行？[y/N]: " choice

        if [[ ! "$choice" =~ ^[Yy]$ ]]; then
            log "用户取消执行" "info"
            exit 0
        fi
    fi

    log "系统预检查通过" "success"
}

# =============================================================================
# 依赖安装
# =============================================================================

install_dependencies() {
    log "检查基础依赖"

    local required_deps=(
        "curl:curl"
        "wget:wget"
        "git:git"
        "jq:jq"
        "rsync:rsync"
        "sudo:sudo"
        "dig:dnsutils"
        "crontab:cron"
        "fuser:psmisc"
        "locale-gen:locales"
        "gpg:gpg"
        "gpg-agent:gpg-agent"
        "dirmngr:dirmngr"
    )

    local missing_packages=()
    local dependency
    local command_name
    local package_name

    for dependency in "${required_deps[@]}"; do
        command_name="${dependency%%:*}"
        package_name="${dependency#*:}"

        if ! command_exists "$command_name"; then
            missing_packages+=("$package_name")
        fi
    done

    if (( ${#missing_packages[@]} == 0 )); then
        log "基础依赖已满足"
        return 0
    fi

    log "安装缺失依赖：${missing_packages[*]}"

    if ! apt-get update -qq; then
        log "无法更新 APT 软件包索引" "error"
        exit 1
    fi

    if ! apt-get install -y "${missing_packages[@]}"; then
        log "基础依赖安装失败" "error"
        exit 1
    fi

    log "基础依赖安装完成" "success"
}

# =============================================================================
# 系统更新与 hosts 修复
# =============================================================================

system_update() {
    log "更新软件包索引"

    if apt-get update; then
        log "软件包索引更新成功" "success"
    else
        log "软件包索引更新失败，后续模块可能无法安装软件包" "warn"
    fi

    local choice
    read -r -p "是否现在执行完整系统更新（apt-get full-upgrade）？[y/N]: " choice
    choice="${choice:-N}"

    if [[ ! "$choice" =~ ^[Yy]$ ]]; then
        log "已跳过完整系统更新"
        return 0
    fi

    log "执行完整系统更新..."

    if DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y \
        -o Dpkg::Options::=--force-confdef \
        -o Dpkg::Options::=--force-confold; then
        log "系统更新完成" "success"
    else
        log "系统更新失败，继续执行模块选择流程" "warn"
    fi
}

fix_hosts_file() {
    local hostname_value
    local cloud_config="/etc/cloud/cloud.cfg"

    hostname_value=$(hostname)

    if [[ -f "$cloud_config" ]]; then
        if grep -qE '^[[:space:]]*manage_etc_hosts:' "$cloud_config"; then
            sed -i \
                's/^[[:space:]]*manage_etc_hosts:.*/manage_etc_hosts: false/' \
                "$cloud_config"
        else
            echo "manage_etc_hosts: false" >> "$cloud_config"
        fi

        log "已禁用 cloud-init 对 /etc/hosts 的自动管理"
    fi

    if grep -qE "^127\.0\.1\.1[[:space:]].*\b${hostname_value}\b" \
        /etc/hosts 2>/dev/null; then
        log "/etc/hosts 已包含主机名映射"
        return 0
    fi

    cp /etc/hosts "/etc/hosts.backup.$(date +%s)" 2>/dev/null || true

    if grep -qE '^127\.0\.1\.1[[:space:]]' /etc/hosts 2>/dev/null; then
        sed -i \
            "s/^127\\.0\\.1\\.1[[:space:]]\\+.*/127.0.1.1 ${hostname_value}/" \
            /etc/hosts
    else
        echo "127.0.1.1 ${hostname_value}" >> /etc/hosts
    fi

    log "已更新 /etc/hosts 主机名映射" "success"
}

ask_fix_hosts() {
    local choice

    read -r -p "是否修复 hostname 与 /etc/hosts 映射？[y/N]: " choice
    choice="${choice:-N}"

    if [[ "$choice" =~ ^[Yy]$ ]]; then
        fix_hosts_file
    else
        log "已跳过 hostname 与 /etc/hosts 修复"
    fi
}

# =============================================================================
# 模块选择
# =============================================================================

select_deployment_mode() {
    echo
    echo "$LINE"
    echo "部署模式选择："
    echo "1) 🚀 全部安装（安装全部 ${#MODULE_ORDER[@]} 个模块）"
    echo "2) 🎯 自定义选择（按需选择模块）"
    echo "3) ❌ 退出脚本"
    echo

    local mode_choice
    read -r -p "请选择模式 [1-3]: " mode_choice

    case "$mode_choice" in
        1)
            SELECTED_MODULES=("${MODULE_ORDER[@]}")
            log "已选择全部模块"
            ;;
        2)
            custom_module_selection
            ;;
        3)
            log "用户选择退出" "info"
            exit 0
            ;;
        *)
            log "无效选择，已取消部署" "error"
            exit 1
            ;;
    esac
}

custom_module_selection() {
    local index=1
    local module
    local selection
    local number
    local max_index
    local selected=()

    echo
    echo "可用模块："

    for module in "${MODULE_ORDER[@]}"; do
        echo "  $index) $module - ${MODULES[$module]}"
        ((index++))
    done

    echo
    echo "请输入要安装的模块编号，多个编号用空格分隔，例如：1 3 5"
    echo "输入 q 取消并退出。"

    read -r -p "请选择: " selection

    if [[ "$selection" == "q" || "$selection" == "Q" ]]; then
        log "用户取消选择" "info"
        exit 0
    fi

    max_index=${#MODULE_ORDER[@]}

    for number in $selection; do
        if [[ "$number" =~ ^[0-9]+$ ]] &&
            (( number >= 1 && number <= max_index )); then
            selected+=("${MODULE_ORDER[number - 1]}")
        else
            log "跳过无效编号：$number" "warn"
        fi
    done

    if (( ${#selected[@]} == 0 )); then
        log "未选择有效模块" "error"
        exit 1
    fi

    SELECTED_MODULES=("${selected[@]}")
    log "已选择模块：${SELECTED_MODULES[*]}"
}

# =============================================================================
# 依赖解析
# =============================================================================

module_is_selected() {
    local target="$1"
    local module

    for module in "${SELECTED_MODULES[@]}"; do
        [[ "$module" == "$target" ]] && return 0
    done

    return 1
}

module_in_list() {
    local target="$1"
    shift

    local module
    for module in "$@"; do
        [[ "$module" == "$target" ]] && return 0
    done

    return 1
}

resolve_dependencies() {
    local all_needed=()
    local added_deps=()
    local module
    local choice
    local continue_choice

    collect_dependencies() {
        local current_module="$1"
        local dependency

        if module_in_list "$current_module" "${all_needed[@]}"; then
            return 0
        fi

        for dependency in ${MODULE_DEPS[$current_module]:-}; do
            collect_dependencies "$dependency"
        done

        all_needed+=("$current_module")
    }

    for module in "${SELECTED_MODULES[@]}"; do
        collect_dependencies "$module"
    done

    for module in "${all_needed[@]}"; do
        if ! module_is_selected "$module"; then
            added_deps+=("$module")
        fi
    done

    if (( ${#added_deps[@]} == 0 )); then
        return 0
    fi

    echo
    log "检测到模块依赖：${added_deps[*]}" "warn"

    read -r -p "是否自动添加依赖模块？[Y/n]: " choice
    choice="${choice:-Y}"

    if [[ ! "$choice" =~ ^[Yy]$ ]]; then
        log "未自动添加依赖模块，将仅执行已选择的模块" "warn"

        read -r -p "确认系统已满足依赖并继续执行？[y/N]: " continue_choice

        if [[ ! "$continue_choice" =~ ^[Yy]$ ]]; then
            log "已取消部署" "info"
            exit 0
        fi

        return 0
    fi

    local sorted=()

    for module in "${MODULE_ORDER[@]}"; do
        if module_in_list "$module" "${all_needed[@]}"; then
            sorted+=("$module")
        fi
    done

    SELECTED_MODULES=("${sorted[@]}")
    log "已加入依赖，最终模块顺序：${SELECTED_MODULES[*]}" "success"
}

# =============================================================================
# GitHub Commit 与模块下载
# =============================================================================

get_latest_commit() {
    local commit_hash

    commit_hash=$(
        curl -fsSL \
            --connect-timeout 5 \
            --max-time 15 \
            "$GITHUB_API_URL" 2>/dev/null |
            grep -m 1 '"sha"' |
            cut -d '"' -f 4 |
            cut -c 1-40
    ) || true

    if [[ "$commit_hash" =~ ^[0-9a-f]{40}$ ]]; then
        echo "$commit_hash"
        return 0
    fi

    return 1
}

download_with_retry() {
    local url="$1"
    local output="$2"
    local max_attempts=3
    local attempt

    for ((attempt = 1; attempt <= max_attempts; attempt++)); do
        if curl -fsSL \
            --connect-timeout 10 \
            --max-time 60 \
            "$url" \
            -o "$output" &&
            [[ -s "$output" ]] &&
            head -n 1 "$output" |
                grep -qE '^#!/(usr/bin/env bash|bin/bash|bin/sh)$'; then
            return 0
        fi

        if (( attempt < max_attempts )); then
            log "下载失败，2 秒后重试（$attempt/$max_attempts）..." "warn"
            sleep 2
        fi
    done

    return 1
}

download_module() {
    local module="$1"
    local module_file="$TEMP_DIR/${module}.sh"
    local module_url

    module_url="$MODULE_BASE_URL/$LATEST_COMMIT/modules/${module}.sh"

    log "下载模块：$module（commit: ${LATEST_COMMIT:0:7}）"

    if ! download_with_retry "$module_url" "$module_file"; then
        log "模块下载失败：$module" "error"
        return 1
    fi

    chmod 700 "$module_file"
    return 0
}

# =============================================================================
# 脚本自更新
# =============================================================================

try_cached_script() {
    local commit="$1"
    local cached_script="$CACHE_DIR/debian_setup_${commit}.sh"

    if [[ ! -s "$cached_script" ]]; then
        return 1
    fi

    if ! head -n 1 "$cached_script" |
        grep -qE '^#!/(usr/bin/env bash|bin/bash|bin/sh)$'; then
        log "缓存脚本格式异常，已删除：$cached_script" "warn"
        rm -f "$cached_script"
        return 1
    fi

    log "使用已缓存的新版本脚本（commit: ${commit:0:7}）"

    SCRIPT_COMMIT="$commit" exec bash "$cached_script" "${FILTERED_ARGS[@]}"
}

self_update() {
    local latest_commit
    local temp_script
    local script_url
    local remote_version
    local choice
    local cached_script=""

    log "检查主脚本更新..."

    if ! latest_commit=$(get_latest_commit); then
        log "无法获取 GitHub 最新 Commit，跳过主脚本自更新" "warn"
        return 0
    fi

    log "当前 Commit：$SCRIPT_COMMIT"
    log "最新 Commit：$latest_commit"

    if [[ "$SCRIPT_COMMIT" != "unknown" &&
        "$latest_commit" == "$SCRIPT_COMMIT" ]]; then
        log "主脚本已是最新版本"
        return 0
    fi

    if try_cached_script "$latest_commit"; then
        return 0
    fi

    if ! temp_script=$(mktemp "$TEMP_DIR/debian_setup_latest.XXXXXX.sh"); then
        log "无法创建主脚本更新临时文件" "warn"
        return 0
    fi

    script_url="$MODULE_BASE_URL/$latest_commit/debian_setup.sh"

    if ! download_with_retry "$script_url" "$temp_script"; then
        rm -f "$temp_script"
        log "主脚本更新下载失败，继续使用当前版本" "warn"
        return 0
    fi

    remote_version=$(
        grep -m 1 '^readonly SCRIPT_VERSION=' "$temp_script" |
            cut -d '"' -f 2
    )
    remote_version="${remote_version:-未知}"

    echo
    log "发现主脚本新版本" "warn"
    echo "  当前：v$SCRIPT_VERSION（commit: $SCRIPT_COMMIT）"
    echo "  最新：v$remote_version（commit: ${latest_commit:0:7}）"

    read -r -p "是否更新并重新运行？[Y/n]: " choice
    choice="${choice:-Y}"

    if [[ ! "$choice" =~ ^[Yy]$ ]]; then
        rm -f "$temp_script"
        log "已跳过主脚本更新"
        return 0
    fi

    mkdir -p "$CACHE_DIR" 2>/dev/null || true

    if [[ -d "$CACHE_DIR" ]]; then
        cached_script="$CACHE_DIR/debian_setup_${latest_commit}.sh"
        cp "$temp_script" "$cached_script"
        chmod 700 "$cached_script"

        find "$CACHE_DIR" \
            -maxdepth 1 \
            -type f \
            -name 'debian_setup_*.sh' \
            -printf '%T@ %p\n' |
            sort -nr |
            awk 'NR > 3 {print $2}' |
            xargs -r rm -f

        log "已缓存新主脚本：$cached_script"
    fi

    log "正在重新启动更新后的主脚本..." "success"

    if [[ -n "$cached_script" && -f "$cached_script" ]]; then
        SCRIPT_COMMIT="$latest_commit" exec bash "$cached_script" "${FILTERED_ARGS[@]}"
    fi

    SCRIPT_COMMIT="$latest_commit" exec bash "$temp_script" "${FILTERED_ARGS[@]}"
}

# =============================================================================
# 模块执行
# =============================================================================

execute_module() {
    local module="$1"
    local module_file="$TEMP_DIR/${module}.sh"
    local start_time
    local end_time
    local duration
    local result

    if [[ ! -f "$module_file" ]]; then
        log "模块文件不存在：$module" "error"
        MODULE_STATUS["$module"]="failed"
        return 1
    fi

    log "执行模块：${MODULES[$module]}"

    start_time=$(date +%s)

    if bash "$module_file"; then
        result=0
    else
        result=$?
    fi

    end_time=$(date +%s)
    duration=$((end_time - start_time))

    MODULE_EXEC_TIME["$module"]="$duration"

    if (( result == 0 )); then
        MODULE_STATUS["$module"]="success"
        log "模块执行成功：$module（${duration}s）" "success"
        return 0
    fi

    MODULE_STATUS["$module"]="failed"
    log "模块执行失败：$module（${duration}s，退出码：$result）" "error"
    return 1
}

# =============================================================================
# 部署摘要
# =============================================================================

get_system_status() {
    local cpu_cores
    local memory_info
    local disk_usage
    local uptime_info
    local kernel
    local shell_path
    local root_shell
    local docker_version
    local running_containers
    local image_count
    local ssh_ports
    local ssh_root_login
    local network_ip
    local network_interface

    cpu_cores=$(nproc 2>/dev/null || echo "未知")
    memory_info=$(LANG=C free -h 2>/dev/null | awk 'NR == 2 {print $3 "/" $2}' || echo "未知")
    disk_usage=$(df -h / 2>/dev/null | awk 'NR == 2 {print $5}' || echo "未知")
    uptime_info=$(uptime -p 2>/dev/null || echo "未知")
    kernel=$(uname -r 2>/dev/null || echo "未知")

    echo "CPU: ${cpu_cores} 核 | 内存: $memory_info | 磁盘: $disk_usage"
    echo "运行时间: $uptime_info"
    echo "内核: $kernel"

    if command_exists zsh; then
        shell_path=$(command -v zsh)
        root_shell=$(getent passwd root 2>/dev/null | cut -d: -f7)

        if [[ "$root_shell" == "$shell_path" ]]; then
            echo "Zsh: 已安装并设为 Root 默认 Shell"
        else
            echo "Zsh: 已安装，未设为 Root 默认 Shell"
        fi
    else
        echo "Zsh: 未安装"
    fi

    if command_exists docker; then
        docker_version=$(docker --version 2>/dev/null || echo "未知")
        running_containers=$(docker ps -q 2>/dev/null | wc -l)
        image_count=$(docker images -q 2>/dev/null | wc -l)

        if systemctl is-active --quiet docker 2>/dev/null; then
            echo "Docker: $docker_version（运行中）| 容器: $running_containers | 镜像: $image_count"
        else
            echo "Docker: $docker_version（未运行）| 容器: $running_containers | 镜像: $image_count"
        fi
    else
        echo "Docker: 未安装"
    fi

    if [[ -x "$HOME/.local/bin/mise" ]]; then
        echo "Mise: $("$HOME/.local/bin/mise" --version 2>/dev/null | head -n 1)"
    else
        echo "Mise: 未安装"
    fi

    local installed_tools=()

    command_exists nexttrace && installed_tools+=("NextTrace")
    command_exists speedtest-cli && installed_tools+=("Speedtest")
    command_exists htop && installed_tools+=("htop")
    command_exists tree && installed_tools+=("tree")
    command_exists jq && installed_tools+=("jq")

    if (( ${#installed_tools[@]} > 0 )); then
        echo "工具: ${installed_tools[*]}"
    else
        echo "工具: 未安装"
    fi

    ssh_ports=$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2}' | tr '\n' ' ')
    ssh_root_login=$(sshd -T 2>/dev/null | awk '$1 == "permitrootlogin" {print $2; exit}')

    echo "SSH: 端口=${ssh_ports:-未知} | Root 登录=${ssh_root_login:-未知}"

    network_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    network_interface=$(ip route 2>/dev/null | awk '/^default/ {print $5; exit}')

    echo "网络: ${network_ip:-未知} via ${network_interface:-未知}"
}

generate_summary() {
    local success_count=0
    local failed_count=0
    local total_modules
    local success_rate=0
    local total_time
    local module
    local summary_content

    for module in "${!MODULE_STATUS[@]}"; do
        case "${MODULE_STATUS[$module]}" in
            success) ((success_count++)) ;;
            failed) ((failed_count++)) ;;
        esac
    done

    total_modules=$((success_count + failed_count))

    if (( total_modules > 0 )); then
        success_rate=$((success_count * 100 / total_modules))
    fi

    total_time=$(( $(date +%s) - TOTAL_START_TIME ))

    summary_content=$(
        {
            echo "$LINE"
            echo "Debian 系统部署摘要"
            echo "$LINE"
            echo "脚本版本: $SCRIPT_VERSION"
            echo "模块 Commit: ${LATEST_COMMIT:-未知}"
            echo "部署时间: $(date '+%Y-%m-%d %H:%M:%S %Z')"
            echo "总耗时: ${total_time} 秒"
            echo "主机名: $(hostname)"
            echo "系统: $(. /etc/os-release && echo "${PRETTY_NAME:-Debian}")"
            echo
            echo "执行统计:"
            echo "总模块: $total_modules | 成功: $success_count | 失败: $failed_count | 成功率: ${success_rate}%"
            echo

            if (( success_count > 0 )); then
                echo "成功模块:"

                for module in "${MODULE_ORDER[@]}"; do
                    if [[ "${MODULE_STATUS[$module]:-}" == "success" ]]; then
                        echo "  ✅ $module (${MODULE_EXEC_TIME[$module]:-0}s)"
                    fi
                done

                echo
            fi

            if (( failed_count > 0 )); then
                echo "失败模块:"

                for module in "${MODULE_ORDER[@]}"; do
                    if [[ "${MODULE_STATUS[$module]:-}" == "failed" ]]; then
                        echo "  ❌ $module (${MODULE_EXEC_TIME[$module]:-0}s)"
                    fi
                done

                echo
            fi

            echo "当前系统状态:"
            get_system_status
            echo
            echo "文件位置:"
            echo "  日志: $LOG_FILE"
            echo "  摘要: $SUMMARY_FILE"
        }
    )

    echo
    echo "$LINE"
    echo "$summary_content"
    echo "$LINE"

    printf '%s\n' "$summary_content" > "$SUMMARY_FILE" 2>/dev/null || true

    echo "详细摘要已保存至：$SUMMARY_FILE"
}

show_recommendations() {
    echo
    log "部署流程完成" "success"

    if [[ "${MODULE_STATUS[ssh-security]:-}" == "success" ]]; then
        local ssh_ports
        local ip_address

        ssh_ports=$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2; exit}')
        ip_address=$(hostname -I 2>/dev/null | awk '{print $1}')

        if [[ -n "$ssh_ports" && -n "$ip_address" ]]; then
            echo "SSH 连接示例：ssh -p $ssh_ports root@$ip_address"
        fi
    fi

    echo
    echo "常用命令："
    echo "  查看部署日志: tail -f $LOG_FILE"
    echo "  查看部署摘要: cat $SUMMARY_FILE"
    echo "  查看自动更新日志: tail -f /var/log/auto-update.log"
    echo "  重新运行脚本: bash <(curl -fsSL https://raw.githubusercontent.com/LucaLin233/Linux/main/debian_setup.sh)"
}

# =============================================================================
# 参数处理
# =============================================================================

show_help() {
    cat <<EOF
Debian 系统部署脚本 v$SCRIPT_VERSION

用法：
  \$0 [选项]

选项：
  --check-status    查看最近部署摘要
  --clean-cache     清理主脚本缓存
  --help, -h        显示帮助信息
  --version, -v     显示版本信息

模块：
  system-optimize    系统优化（Zram、时区、Chrony）
  system-customize   系统定制（欢迎信息、中文环境、XanMod）
  network-optimize   网络优化（BBR、fq、IPv4 转发）
  zsh-setup          Zsh Shell 环境
  mise-setup         Mise、Python、Node.js
  tools-setup        系统工具
  docker-setup       Docker 平台
  auto-update-setup  自动更新系统与内核
  ssh-security       SSH 安全配置

文件位置：
  日志: $LOG_FILE
  摘要: $SUMMARY_FILE
  缓存: $CACHE_DIR
EOF
}

handle_arguments() {
    FILTERED_ARGS=()

    while (( $# > 0 )); do
        case "$1" in
            --internal-commit=*)
                SCRIPT_COMMIT="${1#*=}"
                shift
                ;;
            --clean-cache)
                log "清理主脚本缓存..."
                rm -rf "$CACHE_DIR"
                log "主脚本缓存已清理" "success"
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
                echo "Debian 系统部署脚本 v$SCRIPT_VERSION"

                if [[ "$SCRIPT_COMMIT" != "unknown" ]]; then
                    echo "Commit: $SCRIPT_COMMIT"
                fi

                exit 0
                ;;
            *)
                FILTERED_ARGS+=("$1")
                shift
                ;;
        esac
    done
}

# =============================================================================
# 主流程
# =============================================================================

main() {
    handle_arguments "$@"

    init_logging
    create_temp_dir

    trap cleanup EXIT INT TERM

    TOTAL_START_TIME=$(date +%s)

    clear 2>/dev/null || true

    echo "$LINE"
    echo "Debian 系统部署脚本 v$SCRIPT_VERSION"

    if [[ "$SCRIPT_COMMIT" != "unknown" ]]; then
        echo "Commit: ${SCRIPT_COMMIT:0:7}"
    fi

    echo "$LINE"

    self_update

    echo
    pre_check
    install_dependencies
    system_update
    ask_fix_hosts

    log "获取固定模块 Commit..."

    if ! LATEST_COMMIT=$(get_latest_commit); then
        log "无法获取 GitHub Commit，为避免主脚本与模块版本不一致，停止执行" "error"
        exit 1
    fi

    log "本次模块 Commit：${LATEST_COMMIT:0:7}"

    select_deployment_mode

    if (( ${#SELECTED_MODULES[@]} == 0 )); then
        log "未选择任何模块，退出" "warn"
        exit 0
    fi

    resolve_dependencies

    echo
    echo "最终执行计划：${SELECTED_MODULES[*]}"

    local confirmation
    read -r -p "确认执行以上模块？[Y/n]: " confirmation
    confirmation="${confirmation:-Y}"

    if [[ ! "$confirmation" =~ ^[Yy]$ ]]; then
        log "用户取消部署" "info"
        exit 0
    fi

    echo
    echo "$LINE"
    log "开始下载 ${#SELECTED_MODULES[@]} 个模块"
    echo "$LINE"

    local download_failed=0
    local downloaded=0
    local module

    for module in "${SELECTED_MODULES[@]}"; do
        ((downloaded++))
        echo
        echo "[$downloaded/${#SELECTED_MODULES[@]}] 下载模块：$module"

        if download_module "$module"; then
            log "模块下载成功：$module" "success"
        else
            MODULE_STATUS["$module"]="failed"
            ((download_failed++))
        fi
    done

    if (( download_failed > 0 )); then
        log "共有 $download_failed 个模块下载失败" "warn"

        local continue_choice
        read -r -p "是否继续执行已成功下载的模块？[y/N]: " continue_choice

        if [[ ! "$continue_choice" =~ ^[Yy]$ ]]; then
            log "用户取消执行" "info"
            generate_summary
            exit 1
        fi
    fi

    echo
    echo "$LINE"
    log "开始执行模块"
    echo "$LINE"

    local current=0
    local total=${#SELECTED_MODULES[@]}

    for module in "${SELECTED_MODULES[@]}"; do
        ((current++))

        if [[ "${MODULE_STATUS[$module]:-}" == "failed" ]]; then
            log "跳过模块 $module（下载失败）" "warn"
            continue
        fi

        echo
        echo "[$current/$total] 执行模块：${MODULES[$module]}"

        if ! execute_module "$module"; then
            log "模块失败，但继续执行后续模块：$module" "warn"
        fi
    done

    generate_summary
    show_recommendations
}

main "$@"
