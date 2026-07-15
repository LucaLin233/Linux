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

APT_UPDATED=false
NEXTTRACE_BACKUP_PATH=""

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

require_root() {
    if (( EUID != 0 )); then
        log "需要 root 权限运行" "error"
        exit 1
    fi
}

apt_update_once() {
    if [[ "$APT_UPDATED" == "true" ]]; then
        return 0
    fi

    if ! apt-get update -qq; then
        log "APT 软件包索引更新失败" "error"
        return 1
    fi

    APT_UPDATED=true
}

# === 工具映射 ===
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

command_is_available() {
    local tool="$1"
    local command_name

    command_name=$(get_tool_command "$tool") || return 1
    command -v "$command_name" >/dev/null 2>&1
}

package_is_installed() {
    local package="$1"

    dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null |
        grep -qx "installed"
}

# === 菜单 ===
show_tool_menu() {
    echo "可安装的工具：" >&2
    echo "  1) 全部安装 - NextTrace、测速和常用系统工具" >&2
    echo "  2) 网络工具 - NextTrace + Speedtest CLI" >&2
    echo "  3) 系统工具 - htop + jq + tree" >&2
    echo "  4) 基础工具 - curl + wget" >&2
    echo "  5) 自定义选择" >&2
    echo "  6) 跳过安装" >&2
    echo "  7) 更新已安装工具" >&2
    echo >&2
}

get_user_choice() {
    local choice

    show_tool_menu
    read -r -p "请选择 [1-7]（默认 1）: " choice >&2
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
            log "无效选择，使用全部安装" "warn" >&2
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
    local choices
    local choice
    local selected=()

    echo "选择要安装的工具（多选用空格分隔，例如：1 3 5）：" >&2
    echo "  1) nexttrace - 网络路由追踪" >&2
    echo "  2) speedtest - 网络测速（speedtest-cli）" >&2
    echo "  3) htop - 进程与资源监控" >&2
    echo "  4) jq - JSON 处理" >&2
    echo "  5) tree - 目录树显示" >&2
    echo "  6) curl - 网络请求工具" >&2
    echo "  7) wget - 文件下载工具" >&2
    echo >&2

    read -r -p "请输入编号（默认：全部）: " choices >&2

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
            *) log "跳过无效编号：$choice" "warn" >&2 ;;
        esac
    done

    printf '%s\n' "${selected[*]}"
}

# === NextTrace 安装 ===
is_nexttrace_apt_installed() {
    package_is_installed "nexttrace"
}

nexttrace_source_configured() {
    [[ -s "$NEXTTRACE_KEYRING" ]] &&
        [[ -f "$NEXTTRACE_SOURCE" ]] &&
        grep -Fq "$NEXTTRACE_REPO_URL" "$NEXTTRACE_SOURCE" &&
        grep -Fq "Signed-By: $NEXTTRACE_KEYRING" "$NEXTTRACE_SOURCE"
}

configure_nexttrace_repository() {
    local key_temp=""
    local attempt

    if nexttrace_source_configured; then
        return 0
    fi

    install -d -m 0755 /etc/apt/keyrings

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
            break
        fi

        if (( attempt == 3 )); then
            rm -f "$key_temp"
            log "NextTrace 签名密钥下载失败" "error"
            return 1
        fi

        log "NextTrace 密钥下载失败，2 秒后重试（$attempt/3）..." "warn"
        sleep 2
    done

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

    APT_UPDATED=false
    echo "NextTrace 官方软件源: 已配置"
}

backup_external_nexttrace() {
    local nexttrace_path
    local backup_path

    NEXTTRACE_BACKUP_PATH=""

    if is_nexttrace_apt_installed; then
        return 0
    fi

    nexttrace_path=$(command -v nexttrace 2>/dev/null || true)

    [[ -n "$nexttrace_path" && -f "$nexttrace_path" ]] || return 0

    backup_path="${nexttrace_path}.backup.$(date +%Y%m%d-%H%M%S)"

    if ! mv "$nexttrace_path" "$backup_path"; then
        log "无法备份旧 NextTrace：$nexttrace_path" "error"
        return 1
    fi

    NEXTTRACE_BACKUP_PATH="$backup_path"
    echo "旧 NextTrace 已备份至：$backup_path"
}

restore_external_nexttrace() {
    local original_path

    [[ -n "$NEXTTRACE_BACKUP_PATH" && -f "$NEXTTRACE_BACKUP_PATH" ]] || return 0

    original_path="${NEXTTRACE_BACKUP_PATH%.backup.*}"

    if [[ ! -e "$original_path" ]]; then
        mv "$NEXTTRACE_BACKUP_PATH" "$original_path"
        log "已恢复原有 NextTrace：$original_path" "warn"
    fi
}

install_nexttrace_from_apt() {
    local mode="$1"

    configure_nexttrace_repository || return 1
    apt_update_once || return 1

    if [[ "$mode" == "update" ]]; then
        if ! is_nexttrace_apt_installed; then
            return 1
        fi

        apt-get install -y --only-upgrade nexttrace
        return $?
    fi

    backup_external_nexttrace || return 1

    if apt-get install -y nexttrace; then
        if command -v nexttrace >/dev/null 2>&1; then
            return 0
        fi
    fi

    restore_external_nexttrace
    return 1
}

install_nexttrace_fallback() {
    local installer=""
    local result=0

    if command -v nexttrace >/dev/null 2>&1; then
        log "官方 APT 安装失败，但当前 NextTrace 仍可用，保留现有版本" "warn"
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
        if [[ "$mode" == "update" ]]; then
            echo "NextTrace: 已通过官方 APT 源更新"
        else
            echo "NextTrace: 已通过官方 APT 源安装"
        fi
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

    local tool
    local package
    local packages=()

    for tool in "$@"; do
        [[ "$tool" == "nexttrace" ]] && continue

        package=$(get_tool_package "$tool") || continue

        if [[ "$mode" == "update" ]]; then
            package_is_installed "$package" && packages+=("$package")
        else
            packages+=("$package")
        fi
    done

    (( ${#packages[@]} > 0 )) || return 0

    apt_update_once || return 1

    if [[ "$mode" == "update" ]]; then
        apt-get install -y --only-upgrade "${packages[@]}"
    else
        apt-get install -y "${packages[@]}"
    fi
}

# === 执行工具安装 ===
install_selected_tools() {
    local mode="$1"
    shift

    local failed=()
    local tool

    for tool in "$@"; do
        if [[ "$tool" == "nexttrace" ]]; then
            if ! install_nexttrace "$mode"; then
                failed+=("nexttrace")
            fi
        fi
    done

    if ! install_apt_tools "$mode" "$@"; then
        for tool in "$@"; do
            [[ "$tool" != "nexttrace" ]] && failed+=("$tool")
        done
    fi

    if (( ${#failed[@]} > 0 )); then
        log "部分工具操作失败：${failed[*]}" "warn"
        return 1
    fi
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

    echo
    log "🎯 系统工具摘要：" "info"

    for tool in "${tools[@]}"; do
        if command_is_available "$tool"; then
            installed+=("$tool")
        else
            missing+=("$tool")
        fi
    done

    (( ${#installed[@]} > 0 )) &&
        echo "  已安装: ${installed[*]}"

    (( ${#missing[@]} > 0 )) &&
        echo "  未安装: ${missing[*]}"

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

    local command_name
    for command_name in apt-get curl dpkg grep install mktemp mv; do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            log "缺少必要命令: $command_name" "error"
            exit 1
        fi
    done

    log "🛠️ 配置系统工具..." "info"

    local mode
    local selected_tools
    local -a tools=()

    mode=$(get_user_choice)

    if [[ "$mode" == "skip" ]]; then
        echo "工具安装: 已跳过"
        show_tools_summary
        return 0
    fi

    if [[ "$mode" == "custom" ]]; then
        selected_tools=$(custom_tool_selection)

        if [[ -z "$selected_tools" ]]; then
            log "未选择任何有效工具" "warn"
            return 0
        fi

        read -r -a tools <<< "$selected_tools"
        mode="install"
    else
        selected_tools=$(get_tools_by_category "$mode")
        read -r -a tools <<< "$selected_tools"
    fi

    if [[ "$mode" == "update" ]]; then
        echo "操作模式: 更新已安装工具"
    else
        echo "操作模式: 安装 ${tools[*]}"
    fi

    echo
    install_selected_tools "$mode" "${tools[@]}" ||
        log "工具安装过程中存在失败项目" "warn"

    show_tools_summary

    echo
    log "✅ 系统工具配置完成" "success"
}

trap 'log "系统工具脚本在第 $LINENO 行执行失败" "error"' ERR

main "$@"
