#!/usr/bin/env bash
# 系统工具配置模块
# 功能：安装 NextTrace、Speedtest CLI 及常用系统工具

set -euo pipefail

# === 常量定义 ===
readonly NEXTTRACE_KEYRING="/etc/apt/keyrings/nexttrace.gpg"
readonly NEXTTRACE_SOURCE="/etc/apt/sources.list.d/nexttrace.sources"
readonly NEXTTRACE_KEY_URL="https://github.com/nxtrace/nexttrace-debs/releases/latest/download/nexttrace-archive-keyring.gpg"
readonly NEXTTRACE_REPO_URL="https://github.com/nxtrace/nexttrace-debs/releases/latest/download/"
readonly NEXTTRACE_INSTALLER_URL="https://nxtrace.org/nt"

readonly APT_TOOLS=(
    speedtest-cli
    htop
    jq
    tree
    curl
    wget
)

# === 日志函数 ===
log() {
    local msg="$1"
    local level="${2:-info}"
    local -A colors=(
        [info]="\033[0;36m"
        [warn]="\033[0;33m"
        [error]="\033[0;31m"
        [success]="\033[0;32m"
        [debug]="\033[0;35m"
    )

    if [[ "$level" == "debug" && "${DEBUG:-}" != "1" ]]; then
        return 0
    fi

    echo -e "${colors[$level]:-\033[0;32m}${msg}\033[0m"
}

debug_log() {
    log "DEBUG: $1" "debug"
}

require_root() {
    if (( EUID != 0 )); then
        log "需要 root 权限运行" "error"
        exit 1
    fi
}

# === 工具定义 ===
get_tool_command() {
    case "$1" in
        nexttrace) echo "nexttrace" ;;
        speedtest) echo "speedtest-cli" ;;
        htop|jq|tree|curl|wget) echo "$1" ;;
        *) return 1 ;;
    esac
}

get_tool_package() {
    case "$1" in
        speedtest) echo "speedtest-cli" ;;
        htop|jq|tree|curl|wget) echo "$1" ;;
        *) return 1 ;;
    esac
}

is_tool_installed() {
    local tool="$1"
    local command_name

    command_name=$(get_tool_command "$tool") || return 1
    command -v "$command_name" >/dev/null 2>&1
}

get_tool_version() {
    local tool="$1"
    local command_name
    local version_output

    command_name=$(get_tool_command "$tool") || return 1

    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "未安装"
        return 1
    fi

    case "$tool" in
        speedtest)
            version_output=$("$command_name" --version 2>/dev/null | head -n 1 || true)
            ;;
        *)
            version_output=$("$command_name" --version 2>/dev/null | head -n 1 || true)
            ;;
    esac

    [[ -n "$version_output" ]] && echo "$version_output" || echo "已安装"
}

# === 菜单 ===
show_tool_menu() {
    echo "可安装的工具："
    echo "  1) 全部安装 - NextTrace、测速和常用系统工具"
    echo "  2) 网络工具 - NextTrace + Speedtest CLI"
    echo "  3) 系统工具 - htop + jq + tree"
    echo "  4) 基础工具 - curl + wget"
    echo "  5) 自定义选择"
    echo "  6) 跳过安装"
    echo "  7) 更新已安装工具"
    echo
}

get_user_choice() {
    local choice

    show_tool_menu
    read -r -p "请选择 [1-7]（默认 1）: " choice
    choice="${choice:-1}"

    case "$choice" in
        1) echo "all" ;;
        2) echo "network" ;;
        3) echo "system" ;;
        4) echo "basic" ;;
        5) echo "custom" ;;
        6) echo "skip" ;;
        7) echo "update" ;;
        *)
            log "无效选择，使用全部安装" "warn"
            echo "all"
            ;;
    esac
}

get_tools_by_category() {
    case "$1" in
        all) echo "nexttrace speedtest htop jq tree curl wget" ;;
        network) echo "nexttrace speedtest" ;;
        system) echo "htop jq tree" ;;
        basic) echo "curl wget" ;;
        update) echo "nexttrace speedtest htop jq tree curl wget" ;;
        *) return 1 ;;
    esac
}

custom_tool_selection() {
    local choice
    local selected=()

    echo "选择要安装的工具（多选用空格分隔，例如：1 3 5）："
    echo "  1) nexttrace - 网络路由追踪"
    echo "  2) speedtest - 网络测速（speedtest-cli）"
    echo "  3) htop - 进程与资源监控"
    echo "  4) jq - JSON 处理"
    echo "  5) tree - 目录树显示"
    echo "  6) curl - 网络请求工具"
    echo "  7) wget - 文件下载工具"
    echo

    read -r -p "请输入编号（默认：全部）: " choices

    if [[ -z "${choices:-}" ]]; then
        echo "nexttrace speedtest htop jq tree curl wget"
        return 0
    fi

    for choice in $choices; do
        case "$choice" in
            1) selected+=("nexttrace") ;;
            2) selected+=("speedtest") ;;
            3) selected+=("htop") ;;
            4) selected+=("jq") ;;
            5) selected+=("tree") ;;
            6) selected+=("curl") ;;
            7) selected+=("wget") ;;
            *) log "跳过无效编号：$choice" "warn" ;;
        esac
    done

    printf '%s\n' "${selected[*]}"
}

# === NextTrace 安装 ===
is_nexttrace_apt_installed() {
    dpkg-query -W -f='${db:Status-Status}' nexttrace 2>/dev/null |
        grep -qx "installed"
}

backup_external_nexttrace() {
    local nexttrace_path
    local backup_path

    nexttrace_path=$(command -v nexttrace 2>/dev/null || true)

    [[ -n "$nexttrace_path" ]] || return 0
    is_nexttrace_apt_installed && return 0

    if [[ ! -f "$nexttrace_path" ]]; then
        return 0
    fi

    backup_path="${nexttrace_path}.backup.$(date +%Y%m%d-%H%M%S)"

    if mv "$nexttrace_path" "$backup_path"; then
        echo "旧 NextTrace 已备份至：$backup_path"
        return 0
    fi

    log "无法备份旧 NextTrace：$nexttrace_path" "error"
    return 1
}

restore_external_nexttrace() {
    local backup_path="$1"
    local original_path="${backup_path%.backup.*}"

    [[ -f "$backup_path" ]] || return 0

    if [[ ! -e "$original_path" ]]; then
        mv "$backup_path" "$original_path" || true
        log "已恢复原有 NextTrace：$original_path" "warn"
    fi
}

configure_nexttrace_repository() {
    local key_temp
    local attempt
    local downloaded=false

    if [[ -f "$NEXTTRACE_KEYRING" && -s "$NEXTTRACE_KEYRING" &&
        -f "$NEXTTRACE_SOURCE" ]]; then
        return 0
    fi

    mkdir -p /etc/apt/keyrings
    chmod 755 /etc/apt/keyrings

    if ! key_temp=$(mktemp); then
        log "无法创建 NextTrace 密钥临时文件" "error"
        return 1
    fi

    for attempt in 1 2 3; do
        if curl -fsSL \
            --connect-timeout 10 \
            --max-time 30 \
            "$NEXTTRACE_KEY_URL" \
            -o "$key_temp" &&
            [[ -s "$key_temp" ]]; then
            downloaded=true
            break
        fi

        (( attempt < 3 )) && {
            log "NextTrace 密钥下载失败，2 秒后重试（$attempt/3）..." "warn"
            sleep 2
        }
    done

    if [[ "$downloaded" != "true" ]]; then
        rm -f "$key_temp"
        log "NextTrace 签名密钥下载失败" "error"
        return 1
    fi

    if ! install -m 0644 "$key_temp" "$NEXTTRACE_KEYRING"; then
        rm -f "$key_temp"
        log "NextTrace 签名密钥安装失败" "error"
        return 1
    fi

    rm -f "$key_temp"

    cat > "$NEXTTRACE_SOURCE" <<EOF
Types: deb
URIs: $NEXTTRACE_REPO_URL
Suites: ./
Signed-By: $NEXTTRACE_KEYRING
EOF

    echo "NextTrace 官方软件源: 已配置"
}

install_nexttrace_from_apt() {
    local mode="$1"
    local backup_path=""

    if ! configure_nexttrace_repository; then
        return 1
    fi

    if ! apt-get update -qq; then
        log "NextTrace 软件源索引更新失败" "error"
        return 1
    fi

    if [[ "$mode" == "update" ]]; then
        if ! is_nexttrace_apt_installed; then
            return 1
        fi

        apt-get install -y --only-upgrade nexttrace
        return $?
    fi

    if command -v nexttrace >/dev/null 2>&1 && ! is_nexttrace_apt_installed; then
        local old_path
        old_path=$(command -v nexttrace)

        if ! backup_external_nexttrace; then
            return 1
        fi

        backup_path=$(find "$(dirname "$old_path")" -maxdepth 1 \
            -type f -name "$(basename "$old_path").backup.*" \
            -printf '%T@ %p\n' 2>/dev/null |
            sort -nr |
            awk 'NR == 1 {print $2}')
    fi

    if apt-get install -y nexttrace; then
        command -v nexttrace >/dev/null 2>&1
        return $?
    fi

    [[ -n "$backup_path" ]] && restore_external_nexttrace "$backup_path"
    return 1
}

install_nexttrace_fallback() {
    local installer
    local result=0

    if command -v nexttrace >/dev/null 2>&1; then
        log "官方 APT 安装失败，但当前 NextTrace 可用，保留现有版本" "warn"
        return 0
    fi

    if ! installer=$(mktemp); then
        log "无法创建 NextTrace 安装临时文件" "error"
        return 1
    fi

    log "尝试使用 NextTrace 官方安装脚本..." "warn"

    if ! curl -fsSL \
        --connect-timeout 10 \
        --max-time 60 \
        "$NEXTTRACE_INSTALLER_URL" \
        -o "$installer"; then
        rm -f "$installer"
        log "NextTrace 官方安装脚本下载失败" "error"
        return 1
    fi

    if [[ ! -s "$installer" ]]; then
        rm -f "$installer"
        log "NextTrace 官方安装脚本为空" "error"
        return 1
    fi

    bash "$installer" || result=$?
    rm -f "$installer"

    if (( result != 0 )); then
        log "NextTrace 官方安装脚本执行失败" "error"
        return 1
    fi

    if ! command -v nexttrace >/dev/null 2>&1; then
        log "NextTrace 安装后验证失败" "error"
        return 1
    fi

    echo "NextTrace: 已通过官方安装脚本安装"
}

install_nexttrace() {
    local mode="$1"

    if install_nexttrace_from_apt "$mode"; then
        echo "NextTrace: 已通过官方 APT 源安装"
        return 0
    fi

    if [[ "$mode" == "update" ]]; then
        if command -v nexttrace >/dev/null 2>&1; then
            log "NextTrace APT 更新失败，保留当前可用版本" "warn"
            return 0
        fi

        log "NextTrace 未通过 APT 安装，跳过自动更新" "warn"
        return 0
    fi

    install_nexttrace_fallback
}

# === APT 基础工具安装 ===
install_apt_tools() {
    local mode="$1"
    shift

    local requested_tools=("$@")
    local packages=()
    local tool
    local package

    for tool in "${requested_tools[@]}"; do
        [[ "$tool" == "nexttrace" ]] && continue

        package=$(get_tool_package "$tool") || continue

        if [[ "$mode" == "update" ]]; then
            if dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null |
                grep -qx "installed"; then
                packages+=("$package")
            fi
        else
            packages+=("$package")
        fi
    done

    (( ${#packages[@]} > 0 )) || return 0

    if ! apt-get update -qq; then
        log "APT 软件包索引更新失败" "error"
        return 1
    fi

    if [[ "$mode" == "update" ]]; then
        apt-get install -y --only-upgrade "${packages[@]}"
    else
        apt-get install -y "${packages[@]}"
    fi
}

# === 工具安装流程 ===
install_selected_tools() {
    local mode="$1"
    shift

    local tools=("$@")
    local tool
    local failed=()

    for tool in "${tools[@]}"; do
        if [[ "$tool" == "nexttrace" ]]; then
            if ! install_nexttrace "$mode"; then
                failed+=("nexttrace")
            fi
        fi
    done

    if ! install_apt_tools "$mode" "${tools[@]}"; then
        for tool in "${tools[@]}"; do
            [[ "$tool" != "nexttrace" ]] && failed+=("$tool")
        done
    fi

    if (( ${#failed[@]} > 0 )); then
        log "部分工具操作失败：${failed[*]}" "warn"
        return 1
    fi

    return 0
}

# === 摘要 ===
show_tools_summary() {
    local tools=(
        nexttrace
        speedtest
        htop
        jq
        tree
        curl
        wget
    )
    local installed=()
    local missing=()
    local tool
    local command_name

    echo
    log "🎯 系统工具摘要：" "info"

    for tool in "${tools[@]}"; do
        command_name=$(get_tool_command "$tool")

        if command -v "$command_name" >/dev/null 2>&1; then
            installed+=("$tool")
        else
            missing+=("$tool")
        fi
    done

    if (( ${#installed[@]} > 0 )); then
        echo "  已安装: ${installed[*]}"
    fi

    if (( ${#missing[@]} > 0 )); then
        echo "  未安装: ${missing[*]}"
    fi

    echo
    echo "常用命令："

    command -v nexttrace >/dev/null 2>&1 &&
        echo "  路由追踪: nexttrace 1.1.1.1"

    command -v speedtest-cli >/dev/null 2>&1 &&
        echo "  网络测速: speedtest-cli"

    command -v htop >/dev/null 2>&1 &&
        echo "  系统监控: htop"

    command -v tree >/dev/null 2>&1 &&
        echo "  目录树: tree /path/to/directory"

    command -v jq >/dev/null 2>&1 &&
        echo "  JSON 格式化: echo '{\"key\":\"value\"}' | jq ."
}

# === 主流程 ===
main() {
    require_root

    local command
    for command in apt-get curl git mktemp install grep awk sort find; do
        if ! command -v "$command" >/dev/null 2>&1; then
            log "缺少必要命令: $command" "error"
            exit 1
        fi
    done

    log "🛠️ 配置系统工具..." "info"

    local mode
    local selected_tools

    mode=$(get_user_choice)

    if [[ "$mode" == "skip" ]]; then
        echo "工具安装: 已跳过"
        show_tools_summary
        return 0
    fi

    if [[ "$mode" == "custom" ]]; then
        selected_tools=$(custom_tool_selection)
        [[ -n "$selected_tools" ]] || {
            log "未选择任何有效工具" "warn"
            return 0
        }
        read -r -a tools <<< "$selected_tools"
        mode="install"
    else
        selected_tools=$(get_tools_by_category "$mode")
        read -r -a tools <<< "$selected_tools"
    fi

    case "$mode" in
        update) echo "操作模式: 更新已安装工具" ;;
        *) echo "操作模式: 安装 ${tools[*]}" ;;
    esac

    echo
    install_selected_tools "$mode" "${tools[@]}" ||
        log "工具安装过程中存在失败项目" "warn"

    show_tools_summary

    echo
    log "✅ 系统工具配置完成" "success"
}

trap 'log "系统工具脚本在第 $LINENO 行执行失败" "error"' ERR

main "$@"
