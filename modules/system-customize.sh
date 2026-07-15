#!/usr/bin/env bash
# 系统定制模块
# 功能：配置动态欢迎信息、中文 Locale，并可选安装 XanMod 内核
#
# 用法：
#   bash system-customize.sh           # 交互执行全部功能
#   bash system-customize.sh motd      # 仅配置欢迎信息
#   bash system-customize.sh locale    # 仅配置中文环境
#   bash system-customize.sh xanmod    # 仅配置 XanMod 内核
#   bash system-customize.sh status    # 查看 XanMod 状态

set -euo pipefail

# === 常量定义 ===
readonly MOTD_SCRIPT="/etc/update-motd.d/00-custom-welcome"

readonly XANMOD_KEYRING="/etc/apt/keyrings/xanmod-archive-keyring.gpg"
readonly XANMOD_SOURCE="/etc/apt/sources.list.d/xanmod-release.list"
readonly XANMOD_LEGACY_SOURCE="/etc/apt/sources.list.d/xanmod-release.sources"
readonly XANMOD_LEGACY_SOURCE_BACKUP="/root/xanmod-release.sources.legacy"
readonly XANMOD_OLD_BAD_BACKUP="/etc/apt/sources.list.d/xanmod-release.sources.backup"
readonly XANMOD_KEY_URL="https://dl.xanmod.org/archive.key"
readonly XANMOD_REPO_URL="http://deb.xanmod.org"
readonly XANMOD_PSABI_CHECK_URL="https://dl.xanmod.org/check_x86-64_psabi.sh"

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

info() {
    log "$1" "info"
}

warn() {
    log "$1" "warn"
}

error() {
    log "$1" "error"
}

success() {
    log "$1" "success"
}

require_root() {
    if (( EUID != 0 )); then
        error "需要 root 权限运行"
        exit 1
    fi
}

ask_yes_no() {
    local prompt="$1"
    local default="${2:-Y}"
    local choice

    read -r -p "$prompt" choice
    choice="${choice:-$default}"

    [[ "$choice" =~ ^[Yy]$ ]]
}

ensure_package() {
    local command_name="$1"
    local package_name="$2"

    if command -v "$command_name" >/dev/null 2>&1; then
        return 0
    fi

    info "安装依赖包: $package_name"

    if ! apt-get update -qq; then
        error "无法更新软件包索引，无法安装 $package_name"
        return 1
    fi

    if ! apt-get install -y "$package_name"; then
        error "安装依赖包失败: $package_name"
        return 1
    fi

    if ! command -v "$command_name" >/dev/null 2>&1; then
        error "依赖命令仍不可用: $command_name"
        return 1
    fi
}

# === 动态欢迎信息 ===
configure_motd() {
    if ! ask_yes_no "是否配置自定义动态欢迎信息？[Y/n]: " "Y"; then
        echo "欢迎信息: 已跳过"
        return 0
    fi

    info "配置动态欢迎信息..."

    : > /etc/motd
    : > /etc/issue
    : > /etc/issue.net

    local file
    for file in /etc/update-motd.d/10-uname /etc/update-motd.d/50-motd-news; do
        if [[ -x "$file" ]]; then
            chmod -x "$file"
            info "已禁用原生 MOTD 脚本: $(basename "$file")"
        fi
    done

    cat > "$MOTD_SCRIPT" <<'SCRIPT'
#!/usr/bin/env bash
# 由 system-customize.sh 自动生成。
# 欢迎横幅与系统状态面板。

hostname_value=$(hostname)
kernel=$(uname -r)

uptime_value=$(uptime -p 2>/dev/null | sed 's/^up //')
if [[ -z "$uptime_value" ]]; then
    uptime_value=$(uptime | sed -E 's/.*up[[:space:]]+//; s/,[[:space:]]+[0-9]+ user.*//')
fi

ESC=$'\033'
RESET="${ESC}[0m"
BLUE_BG="${ESC}[44;37m"
ITALIC_DIM="${ESC}[2;3;37m"
LABEL="${ESC}[1;36m"
VALUE="${ESC}[37m"
GREEN="${ESC}[32m"
ORANGE="${ESC}[33m"
RED="${ESC}[31m"

pick_color() {
    local percent="$1"
    local type="$2"
    local low
    local high
    local percent_int

    case "$type" in
        disk)
            low=70
            high=90
            ;;
        *)
            low=50
            high=80
            ;;
    esac

    percent_int=$(awk -v value="$percent" 'BEGIN {printf "%d", int(value + 0.5)}')

    if (( percent_int >= high )); then
        printf '%s' "$RED"
    elif (( percent_int >= low )); then
        printf '%s' "$ORANGE"
    else
        printf '%s' "$GREEN"
    fi
}

read -r _ user1 nice1 system1 idle1 _ < <(grep '^cpu ' /proc/stat)
total1=$((user1 + nice1 + system1 + idle1))
busy1=$((user1 + nice1 + system1))

sleep 0.5

read -r _ user2 nice2 system2 idle2 _ < <(grep '^cpu ' /proc/stat)
total2=$((user2 + nice2 + system2 + idle2))
busy2=$((user2 + nice2 + system2))

total_delta=$((total2 - total1))
busy_delta=$((busy2 - busy1))

if (( total_delta > 0 )); then
    cpu_percent=$(awk -v busy="$busy_delta" -v total="$total_delta" \
        'BEGIN {printf "%.1f", busy / total * 100}')
    cpu_color=$(pick_color "$cpu_percent" "cpu")
else
    cpu_percent="N/A"
    cpu_color="$VALUE"
fi

load_average=$(awk '{printf "%.2f %.2f %.2f", $1, $2, $3}' /proc/loadavg)

memory_raw=$(awk '
    /^MemTotal:/     { total=$2 }
    /^MemAvailable:/ { available=$2 }
    END {
        used=total-available
        percent=(total > 0) ? used/total*100 : 0
        printf "%.1f|%.1f|%.1f", used/1048576, total/1048576, percent
    }
' /proc/meminfo)

memory_used="${memory_raw%%|*}G"
memory_rest="${memory_raw#*|}"
memory_total="${memory_rest%%|*}G"
memory_percent="${memory_raw##*|}"
memory_color=$(pick_color "$memory_percent" "memory")

disk_percent=$(df / | awk 'NR == 2 {gsub(/%/, "", $5); print $5}')
disk_usage=$(df -h / | awk 'NR == 2 {printf "%s / %s", $3, $2}')
disk_color=$(pick_color "$disk_percent" "disk")

printf "\n${BLUE_BG} 已连接 %s 服务器 ${RESET}\n" "$hostname_value"
printf "${ITALIC_DIM} 今天想要做些什么？${RESET}\n\n"

printf "  ${LABEL}内核${RESET}      ${VALUE}%s${RESET}\n" "$kernel"
printf "  ${LABEL}运行时间${RESET}  ${VALUE}%s${RESET}\n" "$uptime_value"
printf "  ${LABEL}CPU负载${RESET}   ${VALUE}%s  (${cpu_color}%s%%${VALUE})${RESET}\n" \
    "$load_average" "$cpu_percent"
printf "  ${LABEL}内存${RESET}      ${VALUE}%s / %s  (${memory_color}%s%%${VALUE})${RESET}\n" \
    "$memory_used" "$memory_total" "$memory_percent"
printf "  ${LABEL}磁盘${RESET}      ${VALUE}%s  (${disk_color}%s%%${VALUE})${RESET}\n" \
    "$disk_usage" "$disk_percent"
SCRIPT

    chmod 755 "$MOTD_SCRIPT"

    echo "欢迎信息: 已配置"
    echo
    echo "预览："
    echo "----------------------------------------"
    "$MOTD_SCRIPT"
    echo "----------------------------------------"
}

# === 中文 Locale ===
configure_chinese_locale() {
    if ! ask_yes_no "是否设置系统中文环境（zh_CN.UTF-8）？[Y/n]: " "Y"; then
        echo "中文环境: 已跳过"
        return 0
    fi

    ensure_package "locale-gen" "locales" || return 1

    if ! command -v update-locale >/dev/null 2>&1; then
        error "未找到 update-locale，locales 安装可能不完整"
        return 1
    fi

    info "配置中文 Locale..."

    sed -i \
        's/^[[:space:]]*#[[:space:]]*zh_CN.UTF-8[[:space:]]\+UTF-8/zh_CN.UTF-8 UTF-8/' \
        /etc/locale.gen

    if ! grep -Fxq "zh_CN.UTF-8 UTF-8" /etc/locale.gen; then
        echo "zh_CN.UTF-8 UTF-8" >> /etc/locale.gen
    fi

    locale-gen

    # 移除旧设置中的 LC_ALL，避免强制覆盖所有 Locale 分类。
    sed -i '/^LC_ALL=/d' /etc/default/locale

    update-locale \
        LANG=zh_CN.UTF-8 \
        LANGUAGE=zh_CN:zh

    success "中文环境已配置"
    echo "说明: 当前 SSH 会话需重新登录后完全生效。"
    echo "当前会话可执行: unset LC_ALL && exec zsh"
    echo "系统 Locale 配置:"
    cat /etc/default/locale
}

# === XanMod 内核 ===
get_debian_codename() {
    if [[ -r /etc/os-release ]]; then
        . /etc/os-release

        if [[ -n "${VERSION_CODENAME:-}" ]]; then
            echo "$VERSION_CODENAME"
            return 0
        fi
    fi

    if command -v lsb_release >/dev/null 2>&1; then
        lsb_release -sc
        return 0
    fi

    return 1
}

is_amd64() {
    [[ "$(dpkg --print-architecture)" == "amd64" ]] &&
        [[ "$(uname -m)" == "x86_64" || "$(uname -m)" == "amd64" ]]
}

package_is_installed() {
    local package="$1"

    dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null |
        grep -qx "installed"
}

get_running_xanmod_package() {
    local kernel
    kernel=$(uname -r)

    case "$kernel" in
        *-x64v3-xanmod*)
            echo "linux-xanmod-x64v3"
            ;;
        *-x64v2-xanmod*)
            echo "linux-xanmod-x64v2"
            ;;
        *)
            return 1
            ;;
    esac
}

detect_x86_64_psabi_level() {
    local checker
    local result

    if ! checker=$(mktemp); then
        return 1
    fi

    if ! curl -fsSL \
        --connect-timeout 10 \
        --max-time 30 \
        "$XANMOD_PSABI_CHECK_URL" \
        -o "$checker"; then
        rm -f "$checker"
        return 1
    fi

    if [[ ! -s "$checker" ]]; then
        rm -f "$checker"
        return 1
    fi

    if ! result=$(awk -f "$checker" 2>/dev/null); then
        rm -f "$checker"
        return 1
    fi

    rm -f "$checker"

    case "$result" in
        *"x86-64-v3"*)
            echo "v3"
            ;;
        *"x86-64-v2"*)
            echo "v2"
            ;;
        *)
            return 1
            ;;
    esac
}

detect_xanmod_package() {
    local running_package
    local psabi_level

    if ! is_amd64; then
        return 1
    fi

    # 已实际运行的 XanMod 内核是最高优先级证据。
    if running_package=$(get_running_xanmod_package); then
        echo "$running_package"
        return 0
    fi

    # 已安装的元包次之，避免更新脚本误切换内核分支。
    if package_is_installed "linux-xanmod-x64v3"; then
        echo "linux-xanmod-x64v3"
        return 0
    fi

    if package_is_installed "linux-xanmod-x64v2"; then
        echo "linux-xanmod-x64v2"
        return 0
    fi

    # 首次安装时，使用 XanMod 官方 psABI 检测脚本。
    if ! psabi_level=$(detect_x86_64_psabi_level); then
        warn "无法确认 CPU 的 x86-64 psABI 等级，跳过 XanMod 安装"
        return 1
    fi

    case "$psabi_level" in
        v3)
            echo "linux-xanmod-x64v3"
            ;;
        v2)
            echo "linux-xanmod-x64v2"
            ;;
    esac
}

xanmod_source_configured() {
    [[ -s "$XANMOD_KEYRING" ]] &&
        [[ -f "$XANMOD_SOURCE" ]] &&
        grep -Fq "deb.xanmod.org" "$XANMOD_SOURCE" &&
        grep -Fq "signed-by=$XANMOD_KEYRING" "$XANMOD_SOURCE"
}

archive_old_bad_xanmod_backup() {
    if [[ ! -f "$XANMOD_OLD_BAD_BACKUP" ]]; then
        return 0
    fi

    if [[ -e "$XANMOD_LEGACY_SOURCE_BACKUP" ]]; then
        warn "检测到旧 XanMod APT 备份，但目标归档已存在: $XANMOD_LEGACY_SOURCE_BACKUP"
        warn "请手动处理: $XANMOD_OLD_BAD_BACKUP"
        return 0
    fi

    if mv "$XANMOD_OLD_BAD_BACKUP" "$XANMOD_LEGACY_SOURCE_BACKUP"; then
        info "已移出 APT 目录的旧 XanMod 备份: $XANMOD_LEGACY_SOURCE_BACKUP"
        return 0
    fi

    error "无法迁移旧 XanMod APT 备份: $XANMOD_OLD_BAD_BACKUP"
    return 1
}

migrate_legacy_xanmod_source() {
    if [[ ! -f "$XANMOD_LEGACY_SOURCE" ]]; then
        return 0
    fi

    if [[ -e "$XANMOD_LEGACY_SOURCE_BACKUP" ]]; then
        warn "检测到旧 XanMod source 文件，但历史归档已存在: $XANMOD_LEGACY_SOURCE_BACKUP"
        warn "请手动处理: $XANMOD_LEGACY_SOURCE"
        return 0
    fi

    if mv "$XANMOD_LEGACY_SOURCE" "$XANMOD_LEGACY_SOURCE_BACKUP"; then
        info "已归档旧 XanMod source 文件: $XANMOD_LEGACY_SOURCE_BACKUP"
        return 0
    fi

    error "无法归档旧 XanMod source 文件"
    return 1
}

configure_xanmod_repository() {
    local codename
    local key_temp

    archive_old_bad_xanmod_backup || return 1

    if xanmod_source_configured; then
        echo "XanMod 软件源: 已配置"
        return 0
    fi

    ensure_package "gpg" "gpg" || return 1

    codename=$(get_debian_codename) || {
        error "无法识别 Debian 发行版代号"
        return 1
    }

    migrate_legacy_xanmod_source || return 1

    install -d -m 0755 /etc/apt/keyrings

    if ! key_temp=$(mktemp); then
        error "无法创建 XanMod 密钥临时文件"
        return 1
    fi

    info "下载 XanMod 软件源签名密钥..."

    if ! curl -fsSL \
        --connect-timeout 10 \
        --max-time 30 \
        "$XANMOD_KEY_URL" \
        -o "$key_temp"; then
        rm -f "$key_temp"
        error "XanMod 签名密钥下载失败"
        return 1
    fi

    if [[ ! -s "$key_temp" ]]; then
        rm -f "$key_temp"
        error "XanMod 签名密钥为空"
        return 1
    fi

    if ! gpg --dearmor --yes \
        --output "$XANMOD_KEYRING" \
        "$key_temp"; then
        rm -f "$key_temp"
        error "XanMod 签名密钥转换失败"
        return 1
    fi

    rm -f "$key_temp"
    chmod 644 "$XANMOD_KEYRING"

    cat > "$XANMOD_SOURCE" <<EOF
deb [signed-by=$XANMOD_KEYRING] $XANMOD_REPO_URL $codename main
EOF

    echo "XanMod 软件源: 已配置（$codename）"
}

get_installed_xanmod_packages() {
    dpkg-query -W \
        -f='${binary:Package} ${db:Status-Status}\n' \
        "linux-xanmod-*" 2>/dev/null |
        awk '
            $2 == "installed" {
                sub(/:amd64$/, "", $1)
                print $1
            }
        ' |
        sort -u
}

is_xanmod_kernel_running() {
    [[ "$(uname -r)" == *"-xanmod"* ]]
}

install_xanmod() {
    local target_package
    local installed_packages
    local install_choice

    if ! ask_yes_no "是否安装 XanMod 内核？[y/N]: " "N"; then
        echo "XanMod 内核: 已跳过"
        return 0
    fi

    if ! is_amd64; then
        warn "当前架构为 $(dpkg --print-architecture) / $(uname -m)"
        warn "XanMod 官方 APT 仓库目前仅提供 amd64 内核包，已跳过安装"
        return 0
    fi

    if ! target_package=$(detect_xanmod_package); then
        warn "当前 CPU 不支持 XanMod MAIN 所需的 x86-64-v2 指令集"
        warn "为避免安装不兼容内核，已保留 Debian 原内核"
        return 0
    fi

    echo "检测到适合当前环境的 XanMod 包: $target_package"

    installed_packages=$(get_installed_xanmod_packages || true)

    if package_is_installed "$target_package"; then
        echo "XanMod 目标包: 已安装（$target_package）"

        if is_xanmod_kernel_running; then
            echo "当前内核: $(uname -r)（XanMod 已生效）"
        else
            echo "当前内核: $(uname -r)（XanMod 将在下次重启后生效）"
        fi

        return 0
    fi

    if [[ -n "$installed_packages" ]]; then
        warn "检测到已安装的其他 XanMod 包: $(tr '\n' ' ' <<< "$installed_packages")"

        read -r -p "是否额外安装当前检测到的 $target_package？[y/N]: " install_choice
        install_choice="${install_choice:-N}"

        if [[ ! "$install_choice" =~ ^[Yy]$ ]]; then
            echo "XanMod 内核: 保留现有安装"
            return 0
        fi
    fi

    configure_xanmod_repository || return 1

    info "更新软件包索引..."

    if ! apt-get update; then
        error "XanMod 软件源索引更新失败"
        return 1
    fi

    info "安装 XanMod 内核包: $target_package"

    if ! apt-get install -y "$target_package"; then
        error "XanMod 内核安装失败"
        return 1
    fi

    if ! package_is_installed "$target_package"; then
        error "XanMod 内核安装后验证失败"
        return 1
    fi

    success "XanMod 内核已安装: $target_package"
    echo "当前运行内核: $(uname -r)"
    echo "说明: Debian 原内核未被移除；XanMod 将在下次系统重启后生效。"
}

show_xanmod_status() {
    local package
    local installed_packages

    echo
    echo "XanMod 状态："
    echo "  当前架构: $(dpkg --print-architecture) / $(uname -m)"
    echo "  当前内核: $(uname -r)"

    if is_xanmod_kernel_running; then
        echo "  当前内核类型: XanMod（已生效）"
    else
        echo "  当前内核类型: 非 XanMod"
    fi

    if package=$(detect_xanmod_package); then
        echo "  推荐/当前包: $package"
    else
        echo "  推荐/当前包: 无（不支持 v2/v3 或非 amd64）"
    fi

    if xanmod_source_configured; then
        echo "  软件源状态: 已配置"
    else
        echo "  软件源状态: 未配置"
    fi

    installed_packages=$(get_installed_xanmod_packages || true)

    if [[ -n "$installed_packages" ]]; then
        echo "  已安装 XanMod 包: $(tr '\n' ' ' <<< "$installed_packages")"
    else
        echo "  已安装 XanMod 包: 无"
    fi
}

# === 主流程 ===
show_help() {
    cat <<'EOF'
用法：
  system-customize.sh            交互执行全部功能
  system-customize.sh all        交互执行全部功能
  system-customize.sh motd       仅配置动态欢迎信息
  system-customize.sh locale     仅配置中文环境
  system-customize.sh xanmod     仅检查并可选安装 XanMod 内核
  system-customize.sh status     查看 XanMod 状态
  system-customize.sh help       显示本帮助
EOF
}

main() {
    local action="${1:-all}"

    require_root

    local required_command
    for required_command in apt-get awk cat chmod curl dpkg grep hostname \
        mktemp sed sort uname; do
        if ! command -v "$required_command" >/dev/null 2>&1; then
            error "缺少必要命令: $required_command"
            exit 1
        fi
    done

    case "$action" in
        all)
            info "🎨 配置系统定制功能..."

            echo
            configure_motd

            echo
            configure_chinese_locale

            echo
            install_xanmod

            show_xanmod_status
            success "系统定制配置完成"
            ;;
        motd)
            configure_motd
            ;;
        locale)
            configure_chinese_locale
            ;;
        xanmod)
            install_xanmod
            show_xanmod_status
            ;;
        status)
            show_xanmod_status
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            error "未知参数: $action"
            show_help
            exit 1
            ;;
    esac
}

trap 'error "系统定制脚本在第 $LINENO 行执行失败"' ERR

main "$@"
