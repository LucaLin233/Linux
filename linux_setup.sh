#!/usr/bin/env bash
# =============================================================================
# Linux 系统部署脚本
# 适用系统：Debian 12+、Ubuntu 22.04/24.04
# 功能：模块化部署、依赖处理、模块版本固定下载
# =============================================================================

set -uo pipefail

# === 全局常量 ===
readonly SCRIPT_VERSION="5.0.0"
SCRIPT_COMMIT="${SCRIPT_COMMIT:-unknown}"

readonly MODULE_BASE_URL="https://raw.githubusercontent.com/LucaLin233/Linux"
readonly GITHUB_API_URL="https://api.github.com/repos/LucaLin233/Linux/commits/main"
readonly MODULES_API_URL="https://api.github.com/repos/LucaLin233/Linux/contents/modules"

LOG_FILE="/var/log/linux-setup.log"
readonly SUMMARY_FILE="/root/deployment_summary.txt"
readonly CACHE_DIR="/var/cache/linux-setup"
readonly LINE="============================================================"

TEMP_DIR=""
LATEST_COMMIT=""
TOTAL_START_TIME=0

SELECTED_MODULES=()
FILTERED_ARGS=()

declare -A MODULE_STATUS
declare -A MODULE_EXEC_TIME

# 模块注册信息从固定 Commit 的 modules/*.sh 元数据动态生成。
declare -A MODULES
declare -A MODULE_DEPS
declare -A MODULE_ORDER_VALUE
declare -A MODULE_FILES
MODULE_ORDER=()

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

backup_initial_and_previous() {
    local file="$1"
    local initial="${file}.initial-backup"
    local previous="${file}.previous-backup"

    [[ -e "$file" ]] || return 0
    [[ -e "$initial" ]] || cp -a "$file" "$initial" || return 1
    cp -a "$file" "$previous"
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
    if ! TEMP_DIR=$(mktemp -d -p /tmp linux-setup.XXXXXX); then
        log "无法创建安全临时目录" "error"
        exit 1
    fi

    chmod 700 "$TEMP_DIR"
}

# =============================================================================
# 系统检查
# =============================================================================

pre_check() {
    if (( EUID != 0 )); then
        log "需要 root 权限运行" "error"
        exit 1
    fi

    if [[ ! -r /etc/os-release ]]; then
        log "无法读取 /etc/os-release，无法识别系统" "error"
        exit 1
    fi

    local os_id
    local version_id
    local major_version

    # shellcheck disable=SC1091
    . /etc/os-release
    os_id="${ID:-}"
    version_id="${VERSION_ID:-}"
    major_version="${version_id%%.*}"

    case "$os_id" in
        debian)
            if [[ ! "$major_version" =~ ^[0-9]+$ ]] || (( major_version < 12 )); then
                log "仅支持 Debian 12 或更高版本，当前版本：${version_id:-未知}" "error"
                exit 1
            fi
            ;;
        ubuntu)
            case "$version_id" in
                22.04|24.04) ;;
                *)
                    log "仅支持 Ubuntu 22.04 或 24.04，当前版本：${version_id:-未知}" "error"
                    exit 1
                    ;;
            esac
            ;;
        *)
            log "仅支持 Debian 12+、Ubuntu 22.04/24.04，当前系统：${PRETTY_NAME:-${os_id:-未知}}" "error"
            exit 1
            ;;
    esac

    log "检测到受支持系统：${PRETTY_NAME:-$os_id $version_id}"

    local free_space_kb
    free_space_kb=$(LANG=C df / 2>/dev/null |
        awk 'NR == 2 {print $4}' |
        tr -cd '0-9')

    if [[ -n "$free_space_kb" && "$free_space_kb" != "0" ]]; then
        if (( free_space_kb < 1048576 )); then
            log "根分区可用空间不足 1GB" "error"
            exit 1
        fi
    fi

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
# 旧版 APT 软件源备份迁移
# =============================================================================

migrate_legacy_apt_source_backups() {
    local source_dir="/etc/apt/sources.list.d"
    local state_dir="/var/lib/linux-setup/apt-source-backups"
    local base
    local suffix
    local source
    local destination

    [[ -d "$source_dir" ]] || return 0
    install -d -m 0700 "$state_dir"

    for base in docker.sources nexttrace.sources xanmod-release.list xanmod-release.sources; do
        for suffix in initial-backup previous-backup initial-absent previous-absent initial-unknown; do
            source="$source_dir/${base}.${suffix}"
            [[ -e "$source" || -L "$source" ]] || continue
            destination="$state_dir/${base}.${suffix}"

            if [[ -e "$destination" || -L "$destination" ]]; then
                destination="${destination}.legacy.$(date +%s).$$"
            fi

            mv "$source" "$destination" || {
                log "无法迁移旧版 APT 软件源备份：$source" "warn"
                continue
            }
            chmod 600 "$destination" 2>/dev/null || true
        done
    done
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
    if apt-get update -qq; then
        log "软件包索引已更新" "success"
    else
        log "软件包索引更新失败，后续模块可能无法安装软件包" "warn"
    fi
}

fix_hosts_file() {
    local hostname_value
    local cloud_config="/etc/cloud/cloud.cfg"
    local changed=false

    hostname_value=$(hostname)

    if [[ -f "$cloud_config" ]]; then
        backup_initial_and_previous "$cloud_config" || return 1

        if grep -qE '^[[:space:]]*manage_etc_hosts:' "$cloud_config"; then
            if ! grep -qE '^[[:space:]]*manage_etc_hosts:[[:space:]]*false[[:space:]]*$' "$cloud_config"; then
                sed -i \
                    's/^[[:space:]]*manage_etc_hosts:.*/manage_etc_hosts: false/' \
                    "$cloud_config"
                changed=true
            fi
        else
            echo "manage_etc_hosts: false" >> "$cloud_config"
            changed=true
        fi
    fi

    if ! grep -qE "^127\\.0\\.1\\.1[[:space:]].*\\b${hostname_value}\\b" \
        /etc/hosts 2>/dev/null; then
        backup_initial_and_previous /etc/hosts || return 1

        if grep -qE '^127\.0\.1\.1[[:space:]]' /etc/hosts 2>/dev/null; then
            sed -i \
                "s/^127\\.0\\.1\\.1[[:space:]]\\+.*/127.0.1.1 ${hostname_value}/" \
                /etc/hosts
        else
            echo "127.0.1.1 ${hostname_value}" >> /etc/hosts
        fi

        changed=true
    fi

    [[ "$changed" == "true" ]] &&
        log "已修复 hostname 与 /etc/hosts 映射" "success"
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
    local sorted=()
    local module
    local choice
    local continue_choice
    local -A visit_state=()

    collect_dependencies() {
        local current_module="$1"
        local dependency

        case "${visit_state[$current_module]:-}" in
            visiting)
                log "检测到模块循环依赖：$current_module" "error"
                return 1
                ;;
            done)
                return 0
                ;;
        esac

        if [[ -z "${MODULES[$current_module]:-}" ]]; then
            log "依赖的模块不存在或不可用：$current_module" "error"
            return 1
        fi

        visit_state["$current_module"]="visiting"

        for dependency in ${MODULE_DEPS[$current_module]:-}; do
            collect_dependencies "$dependency" || return 1
        done

        visit_state["$current_module"]="done"
        all_needed+=("$current_module")
    }

    for module in "${SELECTED_MODULES[@]}"; do
        collect_dependencies "$module" || return 1
    done

    for module in "${all_needed[@]}"; do
        if ! module_is_selected "$module"; then
            added_deps+=("$module")
        fi
    done

    if (( ${#added_deps[@]} > 0 )); then
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

            all_needed=("${SELECTED_MODULES[@]}")
        fi
    fi

    # 无论用户输入编号的先后如何，都按模块声明的稳定顺序执行。
    for module in "${MODULE_ORDER[@]}"; do
        if module_in_list "$module" "${all_needed[@]}"; then
            sorted+=("$module")
        fi
    done

    SELECTED_MODULES=("${sorted[@]}")

    if (( ${#added_deps[@]} > 0 )) && [[ "$choice" =~ ^[Yy]$ ]]; then
        log "已加入依赖，最终模块顺序：${SELECTED_MODULES[*]}" "success"
    fi
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

read_module_metadata() {
    local module_file="$1"
    local key="$2"

    awk -v key="$key" '
        $0 ~ "^#[[:space:]]*linux-setup:" key "=" {
            value = $0
            sub("^#[[:space:]]*linux-setup:" key "=[[:space:]]*", "", value)
            sub("[[:space:]]*$", "", value)
            print value
            exit
        }
    ' "$module_file"
}

register_module() {
    local module="$1"
    local module_file="$2"
    local name
    local order
    local depends
    local enabled
    local dependency

    if ! bash -n "$module_file"; then
        log "模块语法检查失败，已跳过：$module" "error"
        return 1
    fi

    name=$(read_module_metadata "$module_file" "name")
    order=$(read_module_metadata "$module_file" "order")
    depends=$(read_module_metadata "$module_file" "depends")
    enabled=$(read_module_metadata "$module_file" "enabled")

    name="${name:-$module}"
    order="${order:-900}"
    enabled="${enabled:-true}"

    if [[ "$enabled" == "false" ]]; then
        return 2
    fi

    if [[ "$enabled" != "true" ]]; then
        log "模块 enabled 元数据无效，已跳过：$module" "error"
        return 1
    fi

    if [[ ! "$order" =~ ^[0-9]+$ ]] || (( 10#$order > 999999 )); then
        log "模块 order 元数据无效，已跳过：$module" "error"
        return 1
    fi

    for dependency in $depends; do
        if [[ ! "$dependency" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
            log "模块依赖名称无效，已跳过：$module -> $dependency" "error"
            return 1
        fi
    done

    MODULES["$module"]="$name"
    MODULE_DEPS["$module"]="$depends"
    MODULE_ORDER_VALUE["$module"]="$((10#$order))"
    MODULE_FILES["$module"]="$module_file"
}

remove_module_registration() {
    local module="$1"

    unset 'MODULES[$module]'
    unset 'MODULE_DEPS[$module]'
    unset 'MODULE_ORDER_VALUE[$module]'
    unset 'MODULE_FILES[$module]'
}

validate_module_dependencies() {
    local changed=true
    local module
    local dependency

    # 重复检查，确保依赖于已被剔除模块的模块也会被剔除。
    while [[ "$changed" == "true" ]]; do
        changed=false

        for module in "${!MODULES[@]}"; do
            for dependency in ${MODULE_DEPS[$module]:-}; do
                if [[ -z "${MODULES[$dependency]:-}" ]]; then
                    log "模块依赖不存在，已跳过：$module -> $dependency" "error"
                    remove_module_registration "$module"
                    changed=true
                    break
                fi
            done
        done
    done
}

build_module_order() {
    local module

    mapfile -t MODULE_ORDER < <(
        for module in "${!MODULES[@]}"; do
            printf '%010d\t%s\n' \
                "${MODULE_ORDER_VALUE[$module]}" \
                "$module"
        done |
            sort -k1,1n -k2,2 |
            awk -F '\t' '{print $2}'
    )
}

download_module() {
    local module="$1"
    local module_file="$TEMP_DIR/${module}.sh"
    local module_url

    module_url="$MODULE_BASE_URL/$LATEST_COMMIT/modules/${module}.sh"

    if ! download_with_retry "$module_url" "$module_file"; then
        return 1
    fi

    chmod 700 "$module_file"
}

discover_and_prepare_modules() {
    local index_file="$TEMP_DIR/modules-index.json"
    local file_name
    local module
    local module_file
    local register_result
    local -a module_files=()

    log "从固定 Commit 发现部署模块：${LATEST_COMMIT:0:7}"

    if ! curl -fsSL \
        --connect-timeout 10 \
        --max-time 30 \
        "${MODULES_API_URL}?ref=${LATEST_COMMIT}" \
        -o "$index_file"; then
        log "无法获取 modules 目录列表" "error"
        return 1
    fi

    if ! jq -e 'type == "array"' "$index_file" >/dev/null 2>&1; then
        log "GitHub modules 目录响应格式异常" "error"
        return 1
    fi

    mapfile -t module_files < <(
        jq -r '
            .[]
            | select(.type == "file")
            | .name
            | select(test("^[a-z0-9][a-z0-9-]*\\.sh$"))
        ' "$index_file" |
            sort -u
    )

    if (( ${#module_files[@]} == 0 )); then
        log "modules 目录中没有符合命名规范的脚本" "error"
        return 1
    fi

    for file_name in "${module_files[@]}"; do
        module="${file_name%.sh}"
        module_file="$TEMP_DIR/$file_name"

        if ! download_module "$module"; then
            log "模块下载失败，已跳过：$module" "error"
            continue
        fi

        if register_module "$module" "$module_file"; then
            continue
        else
            register_result=$?
        fi

        if (( register_result != 2 )); then
            rm -f "$module_file"
        fi
    done

    validate_module_dependencies
    build_module_order

    if (( ${#MODULE_ORDER[@]} == 0 )); then
        log "没有可用的部署模块" "error"
        return 1
    fi

    log "模块发现完成：${#MODULE_ORDER[@]} 个可用模块" "success"
}

# =============================================================================
# 脚本自更新
# =============================================================================

try_cached_script() {
    local commit="$1"
    local cached_script="$CACHE_DIR/linux_setup_${commit}.sh"

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

    if ! latest_commit=$(get_latest_commit); then
        log "无法检查主脚本更新，继续使用当前版本" "warn"
        return 0
    fi

    if [[ "$SCRIPT_COMMIT" != "unknown" &&
        "$latest_commit" == "$SCRIPT_COMMIT" ]]; then
        log "主脚本已是最新版本" "success"
        return 0
    fi

    if try_cached_script "$latest_commit"; then
        return 0
    fi

    if ! temp_script=$(mktemp "$TEMP_DIR/linux_setup_latest.XXXXXX.sh"); then
        log "无法创建主脚本更新临时文件，继续使用当前版本" "warn"
        return 0
    fi

    script_url="$MODULE_BASE_URL/$latest_commit/linux_setup.sh"

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
    echo "  当前：v$SCRIPT_VERSION（commit: ${SCRIPT_COMMIT:0:7}）"
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
        cached_script="$CACHE_DIR/linux_setup_${latest_commit}.sh"

        if cp "$temp_script" "$cached_script"; then
            chmod 700 "$cached_script"

            find "$CACHE_DIR" \
                -maxdepth 1 \
                -type f \
                -name 'linux_setup_*.sh' \
                -printf '%T@ %p\n' |
                sort -nr |
                awk 'NR > 3 {print $2}' |
                xargs -r rm -f

            log "主脚本已更新至 v$remote_version" "success"
        else
            cached_script=""
            log "无法缓存新主脚本，将直接使用临时文件重新运行" "warn"
        fi
    fi

    log "正在重新启动更新后的主脚本..." "success"

    if [[ -n "$cached_script" && -f "$cached_script" ]]; then
        SCRIPT_COMMIT="$latest_commit" exec bash \
            "$cached_script" "${FILTERED_ARGS[@]}"
    fi

    SCRIPT_COMMIT="$latest_commit" exec bash \
        "$temp_script" "${FILTERED_ARGS[@]}"
}

# =============================================================================
# 模块执行
# =============================================================================

execute_module() {
    local module="$1"
    local module_file="${MODULE_FILES[$module]:-}"
    local start_time
    local end_time
    local duration
    local result

    if [[ ! -f "$module_file" ]]; then
        log "模块文件不存在：$module" "error"
        MODULE_STATUS["$module"]="failed"
        return 1
    fi

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

    if (( result == 2 )); then
        MODULE_STATUS["$module"]="degraded"
        log "模块部分完成：$module（${duration}s）" "warn"
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
    local route_info

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

    route_info=$(ip -4 route get 1.1.1.1 2>/dev/null || true)
    network_interface=$(awk '
        {
            for (i = 1; i < NF; i++) {
                if ($i == "dev") {
                    print $(i + 1)
                    exit
                }
            }
        }
    ' <<< "$route_info")
    network_ip=$(awk '
        {
            for (i = 1; i < NF; i++) {
                if ($i == "src") {
                    print $(i + 1)
                    exit
                }
            }
        }
    ' <<< "$route_info")

    if [[ -z "$network_interface" ]]; then
        network_interface=$(ip -4 route show default 2>/dev/null | awk '
            {
                for (i = 1; i < NF; i++) {
                    if ($i == "dev") {
                        print $(i + 1)
                        exit
                    }
                }
            }
        ')
    fi
    if [[ -z "$network_ip" && -n "$network_interface" ]]; then
        network_ip=$(ip -4 -o address show dev "$network_interface" scope global 2>/dev/null |
            awk 'NR == 1 {split($4, address, "/"); print address[1]}')
    fi

    echo "网络: ${network_ip:-未知} via ${network_interface:-未知}"
}

generate_summary() {
    local success_count=0
    local degraded_count=0
    local failed_count=0
    local total_modules
    local success_rate=0
    local total_time
    local module
    local summary_content

    for module in "${!MODULE_STATUS[@]}"; do
        case "${MODULE_STATUS[$module]}" in
            success) ((success_count++)) ;;
            degraded) ((degraded_count++)) ;;
            failed) ((failed_count++)) ;;
        esac
    done

    total_modules=$((success_count + degraded_count + failed_count))

    if (( total_modules > 0 )); then
        success_rate=$(((success_count + degraded_count) * 100 / total_modules))
    fi

    total_time=$(( $(date +%s) - TOTAL_START_TIME ))

    summary_content=$(
        {
            echo "$LINE"
            echo "Linux 系统部署摘要"
            echo "$LINE"
            echo "脚本版本: $SCRIPT_VERSION"
            echo "模块 Commit: ${LATEST_COMMIT:-未知}"
            echo "部署时间: $(date '+%Y-%m-%d %H:%M:%S %Z')"
            echo "总耗时: ${total_time} 秒"
            echo "主机名: $(hostname)"
            echo "系统: $(. /etc/os-release && echo "${PRETTY_NAME:-Linux}")"
            echo
            echo "执行统计:"
            echo "总模块: $total_modules | 成功: $success_count | 部分完成: $degraded_count | 失败: $failed_count | 完成率: ${success_rate}%"
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

            if (( degraded_count > 0 )); then
                echo "部分完成模块:"
                for module in "${MODULE_ORDER[@]}"; do
                    [[ "${MODULE_STATUS[$module]:-}" == "degraded" ]] && echo "  ⚠️  $module (${MODULE_EXEC_TIME[$module]:-0}s)"
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

        ssh_ports=$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2}' | sort -n -u)
        ip_address=$(hostname -I 2>/dev/null | awk '{print $1}')

        if [[ -n "$ssh_ports" && -n "$ip_address" ]]; then
            echo "SSH 连接示例："
            while IFS= read -r ssh_port; do
                [[ -n "$ssh_port" ]] && echo "  ssh -p $ssh_port root@$ip_address"
            done <<< "$ssh_ports"
        fi
    fi

    echo
    echo "常用命令："
    echo "  查看部署日志: tail -f $LOG_FILE"
    echo "  查看部署摘要: cat $SUMMARY_FILE"
    echo "  查看自动更新日志: tail -f /var/log/auto-update.log"
    echo "  重新运行脚本: bash <(curl -fsSL https://raw.githubusercontent.com/LucaLin233/Linux/main/linux_setup.sh)"
}

# =============================================================================
# 参数处理
# =============================================================================

show_help() {
    cat <<EOF
Linux 系统部署脚本 v$SCRIPT_VERSION

用法：
  \$0 [选项]

选项：
  --check-status    查看最近部署摘要
  --clean-cache     清理主脚本缓存
  --help, -h        显示帮助信息
  --version, -v     显示版本信息

模块：
  启动部署后，从固定 Commit 的 modules/*.sh 自动发现并生成选择菜单。

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
                echo "Linux 系统部署脚本 v$SCRIPT_VERSION"

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

    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    TOTAL_START_TIME=$(date +%s)

    clear 2>/dev/null || true

    echo "$LINE"
    echo "Linux 系统部署脚本 v$SCRIPT_VERSION"

    if [[ "$SCRIPT_COMMIT" != "unknown" ]]; then
        echo "Commit: ${SCRIPT_COMMIT:0:7}"
    fi

    echo "$LINE"
    echo

    self_update

    pre_check
    migrate_legacy_apt_source_backups
    install_dependencies
    system_update
    fix_hosts_file

    if ! LATEST_COMMIT=$(get_latest_commit); then
        log "无法获取 GitHub Commit，为避免主脚本与模块版本不一致，停止执行" "error"
        exit 1
    fi

    if ! discover_and_prepare_modules; then
        exit 1
    fi

    select_deployment_mode

    if (( ${#SELECTED_MODULES[@]} == 0 )); then
        log "未选择任何模块，退出" "warn"
        exit 0
    fi

    resolve_dependencies || exit 1

    echo
    echo "最终执行计划：${SELECTED_MODULES[*]}"

    local confirmation
    read -r -p "确认执行以上模块？[Y/n]: " confirmation
    confirmation="${confirmation:-Y}"

    if [[ ! "$confirmation" =~ ^[Yy]$ ]]; then
        log "用户取消部署" "info"
        exit 0
    fi

    local module

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
        echo "[$current/$total] ${MODULES[$module]}"

        if ! execute_module "$module"; then
            log "模块失败，但继续执行后续模块：$module" "warn"
        fi
    done

    generate_summary
    show_recommendations
}

main "$@"
