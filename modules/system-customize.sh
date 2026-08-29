#!/usr/bin/env bash
# linux-setup:name=系统定制（欢迎信息、中文环境、XanMod 内核）
# linux-setup:order=20
# linux-setup:depends=
# linux-setup:enabled=true
# 系统定制模块
# 功能：配置动态欢迎信息、中文 Locale，并可选安装 XanMod 内核
#
# 用法：
#   bash system-customize.sh           # 交互执行全部功能
#   bash system-customize.sh motd      # 仅配置欢迎信息
#   bash system-customize.sh locale    # 仅配置中文环境
#   bash system-customize.sh xanmod    # 仅配置 XanMod 内核
#   bash system-customize.sh status    # 查看 XanMod 状态
#   bash system-customize.sh restore   # 恢复上一次运行前的配置
#   bash system-customize.sh restore initial
#                                      # 恢复首次运行前的可信配置

set -euo pipefail

# === 常量定义 ===
readonly MOTD_SCRIPT="/etc/update-motd.d/00-custom-welcome"

readonly XANMOD_KEY_FINGERPRINT="D38D7D1DA1349567ADED882D86F7D09EE734E623"
readonly XANMOD_KEY_UID="XanMod Kernel <kernel@xanmod.org>"
readonly XANMOD_KEY_URL="https://dl.xanmod.org/archive.key"
readonly XANMOD_KEY_FALLBACK_UBUNTU="https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x${XANMOD_KEY_FINGERPRINT}"
readonly XANMOD_REPOSITORIES=(
    "https://deb.xanmod.org"
    "https://mirror.nju.edu.cn/xanmod"
    "https://mirrors.bfsu.edu.cn/xanmod"
    "https://mirrors.tuna.tsinghua.edu.cn/xanmod"
)

if [[ "${XANMOD_TEST_MODE:-0}" == "1" ]]; then
    XANMOD_KEYRING="${XANMOD_KEYRING_PATH:-/etc/apt/keyrings/xanmod-archive-keyring.gpg}"
    XANMOD_SOURCE_LIST="${XANMOD_SOURCE_LIST_PATH:-/etc/apt/sources.list.d/xanmod-release.list}"
    XANMOD_SOURCE_DEB822="${XANMOD_SOURCE_DEB822_PATH:-/etc/apt/sources.list.d/xanmod-release.sources}"
    XANMOD_LOCK="${XANMOD_LOCK_PATH:-/run/lock/xanmod-install.lock}"
    XANMOD_OS_RELEASE="${XANMOD_OS_RELEASE_PATH:-/etc/os-release}"
    XANMOD_CPUINFO="${XANMOD_CPUINFO_PATH:-/proc/cpuinfo}"
    XANMOD_BACKUP_STATE_DIR="${XANMOD_BACKUP_STATE_DIR:-/var/lib/linux-setup/apt-source-backups}"
    XANMOD_TRUSTED_UID="$EUID"
    XANMOD_TRUSTED_GID=$(id -g)
else
    XANMOD_KEYRING="/etc/apt/keyrings/xanmod-archive-keyring.gpg"
    XANMOD_SOURCE_LIST="/etc/apt/sources.list.d/xanmod-release.list"
    XANMOD_SOURCE_DEB822="/etc/apt/sources.list.d/xanmod-release.sources"
    XANMOD_LOCK="/run/lock/xanmod-install.lock"
    XANMOD_OS_RELEASE="/etc/os-release"
    XANMOD_CPUINFO="/proc/cpuinfo"
    XANMOD_BACKUP_STATE_DIR="/var/lib/linux-setup/apt-source-backups"
    XANMOD_TRUSTED_UID=0
    XANMOD_TRUSTED_GID=0
fi
readonly XANMOD_KEYRING XANMOD_SOURCE_LIST XANMOD_SOURCE_DEB822 XANMOD_LOCK
readonly XANMOD_OS_RELEASE XANMOD_CPUINFO XANMOD_BACKUP_STATE_DIR
readonly XANMOD_TRUSTED_UID XANMOD_TRUSTED_GID
readonly -a XANMOD_MANAGED_PATHS=(
    "$XANMOD_KEYRING"
    "$XANMOD_SOURCE_LIST"
    "$XANMOD_SOURCE_DEB822"
)

XANMOD_ASSUME_YES=false
XANMOD_RUNTIME_SNAPSHOT_DIR=""
XANMOD_RUNTIME_SNAPSHOT_BUILDING=false
XANMOD_TRANSACTION_ACTIVE=false
XANMOD_CONFIG_MODIFIED=false
XANMOD_APT_MAY_BE_PARTIAL=false
XANMOD_STAGED_KEY=""
XANMOD_STAGED_SOURCE=""
XANMOD_CANDIDATE_SOURCE=""
XANMOD_ARMORED_KEY_TEMP=""
XANMOD_ACTIVE_APT_LISTS_DIR=""
XANMOD_ACTIVE_APT_LISTS_BUILDING=false
XANMOD_ALLOCATION_CANDIDATE=""
XANMOD_ALLOCATION_KIND=""
XANMOD_ALLOCATION_OWNER_TOKEN=""
XANMOD_ALLOCATION_EXPECTED_MODE=""
XANMOD_ALLOCATION_STATE=""
XANMOD_RESTORE_STAGE=""
XANMOD_SELECTED_REPOSITORY=""
XANMOD_GUARD_ACTIVE=false
XANMOD_GUARD_HANDLING=false
XANMOD_SAVED_TRAP_EXIT=""
XANMOD_SAVED_TRAP_HUP=""
XANMOD_SAVED_TRAP_INT=""
XANMOD_SAVED_TRAP_TERM=""
XANMOD_LOCK_HELD=false
XANMOD_PLAN_ACTION=""
XANMOD_PLAN_REASON=""
XANMOD_PLAN_CODENAME=""
XANMOD_PLAN_PSABI=""
XANMOD_PLAN_TARGET_PACKAGE=""
XANMOD_PLAN_INSTALLED_PACKAGES=""
XANMOD_PLAN_PACKAGE_INSTALLED=false
XANMOD_PLAN_REPOSITORY_READY=false
XANMOD_PLAN_NEEDS_REPOSITORY_CHANGE=false
XANMOD_PLAN_NEEDS_PACKAGE_INSTALL=false
XANMOD_RESTORED_COUNT=0
XANMOD_BACKUP_STATE_DIR_CREATING=false
XANMOD_BACKUP_STATE_DIR_CREATED=false
XANMOD_BACKUP_STATE_DIR_PREEXISTED=false
XANMOD_BACKUP_TRANSACTION_ACTIVE=false
XANMOD_BACKUP_SNAPSHOT_BUILDING=false
XANMOD_BACKUP_SNAPSHOT_REMOVED=false
XANMOD_BACKUP_GROUP_SNAPSHOT_DIR=""
XANMOD_BACKUP_STAGE_DIR=""
XANMOD_BACKUP_STAGE_BUILDING=false
XANMOD_BACKUP_TRANSACTION_ID=""
XANMOD_CONFIGURATION_PREVIOUSLY_MANAGED=false
XANMOD_BACKUP_SNAPSHOT_PATHS=()
XANMOD_BACKUP_LEGACY_PATHS=()
XANMOD_BACKUP_ARCHIVE_STAGED=()
XANMOD_BACKUP_ARCHIVE_FINAL=()
XANMOD_BACKUP_NEW_ARCHIVES=()

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

backup_managed_file() {
    local file="$1"
    local backup_prefix="$file"
    local state_dir=""
    local suffix
    local legacy_state
    local state_file

    case "$file" in
        /etc/apt/sources.list.d/*)
            state_dir="/var/lib/linux-setup/apt-source-backups"
            ;;
        /etc/update-motd.d/*)
            state_dir="/var/lib/linux-setup/motd-backups"
            ;;
    esac

    if [[ -n "$state_dir" ]]; then
        install -d -m 0700 "$state_dir"
        backup_prefix="$state_dir/$(basename "$file")"

        for suffix in initial-backup previous-backup initial-absent previous-absent initial-unknown; do
            legacy_state="${file}.${suffix}"
            [[ -e "$legacy_state" || -L "$legacy_state" ]] || continue
            state_file="${backup_prefix}.${suffix}"
            if [[ -e "$state_file" || -L "$state_file" ]]; then
                state_file="${state_file}.legacy.$(date +%s).$$"
            fi
            mv "$legacy_state" "$state_file" || return 1
        done
    fi

    local initial_backup="${backup_prefix}.initial-backup"
    local previous_backup="${backup_prefix}.previous-backup"
    local initial_absent="${backup_prefix}.initial-absent"
    local previous_absent="${backup_prefix}.previous-absent"
    local initial_unknown="${backup_prefix}.initial-unknown"

    if [[ ! -e "$initial_backup" && ! -e "$initial_absent" && ! -e "$initial_unknown" ]]; then
        if [[ -f "$file" ]] &&
            grep -Eq '# linux-setup:managed-motd|由 (system-customize|setup-motd)\.sh 自动生成' "$file"; then
            install -D -m 0600 /dev/null "$initial_unknown" || return 1
        elif [[ -e "$file" || -L "$file" ]]; then
            cp -a "$file" "$initial_backup" || return 1
        else
            install -D -m 0600 /dev/null "$initial_absent" || return 1
        fi
    fi

    rm -f "$previous_backup" "$previous_absent"
    if [[ -e "$file" || -L "$file" ]]; then
        cp -a "$file" "$previous_backup" || return 1
    else
        install -D -m 0600 /dev/null "$previous_absent" || return 1
    fi
}

get_managed_backup_prefix() {
    local target="$1"
    local state_prefix

    case "$target" in
        /etc/apt/sources.list.d/*)
            state_prefix="/var/lib/linux-setup/apt-source-backups/$(basename "$target")"
            ;;
        /etc/update-motd.d/*)
            state_prefix="/var/lib/linux-setup/motd-backups/$(basename "$target")"
            ;;
        *)
            printf '%s\n' "$target"
            return 0
            ;;
    esac

    if [[ -e "${state_prefix}.initial-backup" || -e "${state_prefix}.initial-absent" ||
        -e "${state_prefix}.initial-unknown" || -e "${state_prefix}.previous-backup" ||
        -e "${state_prefix}.previous-absent" ]]; then
        printf '%s\n' "$state_prefix"
        return 0
    fi

    printf '%s\n' "$target"
}

restore_managed_file() {
    local target="$1"
    local scope="$2"
    local backup_prefix
    local backup
    local absent
    local unknown

    backup_prefix=$(get_managed_backup_prefix "$target") || return 1
    backup="${backup_prefix}.${scope}-backup"
    absent="${backup_prefix}.${scope}-absent"
    unknown="${backup_prefix}.${scope}-unknown"

    if [[ -e "$backup" || -L "$backup" ]]; then
        install -d -m 0755 "$(dirname "$target")" || return 1
        rm -f "$target" || return 1
        cp -a "$backup" "$target" || return 1
        return 0
    fi

    if [[ -e "$absent" ]]; then
        rm -f "$target" || return 1
        return 0
    fi

    if [[ -e "$unknown" ]]; then
        warn "初始状态未知，跳过恢复：$target"
        return 2
    fi

    warn "没有 $scope 配置状态，跳过恢复：$target"
    return 2
}

# === 动态欢迎信息 ===
replace_with_empty_regular_file() {
    local file="$1"

    # Debian/Ubuntu 镜像的静态欢迎文件可能链接到运行时动态文件。
    # 直接重定向清空会保留链接，导致 PAM 两次读取同一动态 MOTD。
    install -m 0644 /dev/null "$file"
}

configure_motd() {
    if ! ask_yes_no "是否配置自定义动态欢迎信息？[Y/n]: " "Y"; then
        echo "欢迎信息: 已跳过"
        return 0
    fi

    install -d -m 0755 /etc/update-motd.d
    info "配置动态欢迎信息..."

    backup_managed_file /etc/motd || return 1
    backup_managed_file /etc/issue || return 1
    backup_managed_file /etc/issue.net || return 1
    replace_with_empty_regular_file /etc/motd
    replace_with_empty_regular_file /etc/issue
    replace_with_empty_regular_file /etc/issue.net

    backup_managed_file "$MOTD_SCRIPT" || return 1

    local file
    for file in /etc/update-motd.d/10-uname /etc/update-motd.d/50-motd-news; do
        backup_managed_file "$file" || return 1
        if [[ -x "$file" ]]; then
            chmod -x "$file"
            info "已禁用原生 MOTD 脚本: $(basename "$file")"
        fi
    done

    install -m 0755 /dev/stdin "$MOTD_SCRIPT" <<'SCRIPT'
#!/usr/bin/env bash
# linux-setup:managed-motd
# 由 Linux Scripts Collection 自动生成。
# 欢迎横幅与系统状态面板。

export LC_ALL=C

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

disk_percent=$(df -P / | awk 'NR == 2 {gsub(/%/, "", $5); print $5}')
disk_usage=$(df -Ph / | awk 'NR == 2 {printf "%s / %s", $3, $2}')
disk_color=$(pick_color "$disk_percent" "disk")

printf "\n${BLUE_BG} 已连接 %s 服务器 ${RESET}\n" "$hostname_value"
printf "${ITALIC_DIM} 今天想要做些什么？${RESET}\n\n"

printf "  ${LABEL}内核${RESET}      ${VALUE}%s${RESET}\n" "$kernel"
printf "  ${LABEL}运行时间${RESET}  ${VALUE}%s${RESET}\n" "$uptime_value"
printf "  ${LABEL}CPU负载${RESET}   ${VALUE}%s${RESET}\n" "$load_average"
printf "  ${LABEL}内存${RESET}      ${VALUE}%s / %s  (${memory_color}%s%%${VALUE})${RESET}\n" \
    "$memory_used" "$memory_total" "$memory_percent"
printf "  ${LABEL}磁盘${RESET}      ${VALUE}%s  (${disk_color}%s%%${VALUE})${RESET}\n" \
    "$disk_usage" "$disk_percent"
SCRIPT

    echo "欢迎信息: 已配置"
    echo
    echo "预览："
    echo "----------------------------------------"
    "$MOTD_SCRIPT"
    echo "----------------------------------------"
}

# === 中文 Locale ===
get_locale_config_file() {
    local os_id=""
    local version_id=""
    local major_version=""

    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        os_id="${ID:-}"
        version_id="${VERSION_ID:-}"
        major_version="${version_id%%.*}"
    fi

    case "$os_id" in
        debian)
            if [[ "$major_version" =~ ^[0-9]+$ ]] && (( major_version >= 13 )); then
                echo "/etc/locale.conf"
            else
                echo "/etc/default/locale"
            fi
            ;;
        ubuntu)
            if [[ "$version_id" == "24.04" ]]; then
                echo "/etc/locale.conf"
            else
                echo "/etc/default/locale"
            fi
            ;;
        *)
            echo "/etc/default/locale"
            ;;
    esac
}

configure_chinese_locale() {
    local locale_config
    if ! ask_yes_no "是否设置系统中文环境（zh_CN.UTF-8）？[Y/n]: " "Y"; then
        echo "中文环境: 已跳过"
        return 0
    fi

    ensure_package "locale-gen" "locales" || return 1

    if ! command -v update-locale >/dev/null 2>&1; then
        error "未找到 update-locale，locales 安装可能不完整"
        return 1
    fi
    backup_managed_file /etc/locale.gen || return 1
    backup_managed_file /etc/locale.conf || return 1
    backup_managed_file /etc/default/locale || return 1

    info "配置中文 Locale..."

    sed -i \
        's/^[[:space:]]*#[[:space:]]*zh_CN.UTF-8[[:space:]]\+UTF-8/zh_CN.UTF-8 UTF-8/' \
        /etc/locale.gen

    if ! grep -Fxq "zh_CN.UTF-8 UTF-8" /etc/locale.gen; then
        echo "zh_CN.UTF-8 UTF-8" >> /etc/locale.gen
    fi

    locale-gen

    locale_config=$(get_locale_config_file)

    # LC_ALL 不应写入系统 Locale 配置，否则会覆盖所有分类设置。
    if [[ -f "$locale_config" ]]; then
        sed -i '/^LC_ALL=/d' "$locale_config"
    fi

    update-locale \
        --locale-file "$locale_config" \
        LANG=zh_CN.UTF-8 \
        LANGUAGE=zh_CN:zh

    success "中文环境已配置"
    echo "说明: 当前 SSH 会话需重新登录后完全生效。"
    echo "当前会话可执行: unset LC_ALL && exec zsh"
    echo "系统 Locale 配置（$locale_config）:"
    cat "$locale_config"
}

# === XanMod 内核 ===
require_xanmod_commands() {
    local command_name
    for command_name in "$@"; do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            error "缺少必要命令: $command_name"
            return 1
        fi
    done
}

is_interactive_terminal() {
    [[ -t 0 && -t 1 ]]
}

confirm_xanmod_install() {
    local choice=""
    if ! read -r -p "是否执行以上 XanMod 修改？[y/N]: " choice; then
        return 1
    fi
    [[ "$choice" =~ ^[Yy]$ ]]
}

authorize_xanmod_install() {
    if [[ "$XANMOD_ASSUME_YES" == "true" ]]; then
        return 0
    fi
    if ! is_interactive_terminal; then
        error "非交互执行 XanMod 修改必须显式传入 --yes"
        return 1
    fi
    if confirm_xanmod_install; then
        return 0
    fi
    echo "XanMod 修改: 已取消"
    return 2
}
get_os_codename() {
    if [[ -r "$XANMOD_OS_RELEASE" ]]; then
        # shellcheck disable=SC1090
        . "$XANMOD_OS_RELEASE"
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

xanmod_codename_safe() {
    [[ "$1" =~ ^[a-z0-9][a-z0-9.+-]*$ ]]
}

xanmod_codename_supported() {
    xanmod_codename_safe "$1" || return 1
    case "$1" in
        bookworm|trixie|noble) return 0 ;;
        *) return 1 ;;
    esac
}

is_amd64() {
    [[ "$(dpkg --print-architecture)" == "amd64" ]] &&
        [[ "$(uname -m)" == "x86_64" || "$(uname -m)" == "amd64" ]]
}

package_is_installed() {
    dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null |
        grep -qx "installed"
}

get_running_xanmod_package() {
    case "$(uname -r)" in
        *-x64v3-xanmod*) echo "linux-xanmod-x64v3" ;;
        *-x64v2-xanmod*) echo "linux-xanmod-x64v2" ;;
        *) return 1 ;;
    esac
}

# 可选文件参数供离线 CPU 特征测试使用。
# shellcheck disable=SC2120
detect_x86_64_psabi_level() {
    local cpuinfo_file="${1:-$XANMOD_CPUINFO}"

    [[ -r "$cpuinfo_file" ]] || return 3
    awk '
        function has(name) { return index(flags, " " name " ") > 0 }
        BEGIN { found = 0 }
        /^flags[[:space:]]*:/ {
            found = 1
            flags = " " $0 " "
            level = 0
            if (has("lm") && has("cmov") && has("cx8") && has("fpu") &&
                has("fxsr") && has("mmx") && has("syscall") && has("sse2")) level = 1
            if (level == 1 && has("cx16") && has("lahf_lm") && has("popcnt") &&
                has("sse4_1") && has("sse4_2") && has("ssse3")) level = 2
            if (level == 2 && has("avx") && has("avx2") && has("bmi1") &&
                has("bmi2") && has("f16c") && has("fma") &&
                (has("abm") || has("lzcnt")) && has("movbe") && has("xsave")) level = 3
            if (level == 3 && has("avx512f") && has("avx512bw") &&
                has("avx512cd") && has("avx512dq") && has("avx512vl")) level = 4
            if (level > 0) { print "v" level; exit 0 }
            exit 2
        }
        END { if (!found) exit 3 }
    ' "$cpuinfo_file"
}

get_xanmod_package_for_psabi_level() {
    case "$1" in
        v4|v3) echo "linux-xanmod-x64v3" ;;
        v2) echo "linux-xanmod-x64v2" ;;
        *) return 1 ;;
    esac
}

detect_xanmod_package() {
    local psabi_level

    is_amd64 || return 1
    if psabi_level=$(detect_x86_64_psabi_level); then
        if [[ "$psabi_level" == "v1" ]]; then
            return 2
        fi
        get_xanmod_package_for_psabi_level "$psabi_level"
    else
        return $?
    fi
}

xanmod_regular_file_trusted() {
    local file="$1"
    local expected_mode="$2"
    local metadata=""

    [[ -f "$file" && ! -L "$file" ]] || return 1
    metadata=$(stat -c '%u:%g:%a' -- "$file") || return 1
    [[ "$metadata" == "$XANMOD_TRUSTED_UID:$XANMOD_TRUSTED_GID:$expected_mode" ]]
}

set_xanmod_staged_file_metadata() {
    local file="$1"

    [[ -f "$file" && ! -L "$file" ]] || return 1
    if [[ "${XANMOD_TEST_MODE:-0}" == "1" ]]; then
        [[ "$(stat -c '%u' -- "$file")" == "$XANMOD_TRUSTED_UID" ]] || return 1
        chgrp "$XANMOD_TRUSTED_GID" "$file" || return 1
    else
        chown 0:0 "$file" || return 1
    fi
    chmod 0644 "$file" || return 1
    xanmod_regular_file_trusted "$file" 644
}

xanmod_keyring_valid() {
    local key_file="${1:-$XANMOD_KEYRING}"

    [[ -s "$key_file" ]] || return 1
    command -v gpg >/dev/null 2>&1 || return 1
    gpg --batch --show-keys --with-colons "$key_file" 2>/dev/null |
        awk -F: -v expected_fingerprint="$XANMOD_KEY_FINGERPRINT" \
            -v expected_uid="$XANMOD_KEY_UID" '
            $1 == "pub" {
                pub_count++
                waiting_for_primary_fingerprint = 1
                next
            }
            $1 == "sub" {
                waiting_for_primary_fingerprint = 0
                next
            }
            $1 == "fpr" && waiting_for_primary_fingerprint {
                primary_fingerprint_count++
                if ($10 == expected_fingerprint) fingerprint_matches = 1
                waiting_for_primary_fingerprint = 0
                next
            }
            $1 == "uid" && $10 == expected_uid { uid_matches = 1 }
            END {
                exit !(pub_count == 1 && primary_fingerprint_count == 1 &&
                    fingerprint_matches && uid_matches)
            }
        '
}

xanmod_formal_keyring_valid() {
    xanmod_regular_file_trusted "$XANMOD_KEYRING" 644 &&
        xanmod_keyring_valid "$XANMOD_KEYRING"
}

xanmod_list_source_configured() {
    xanmod_formal_keyring_valid &&
        xanmod_regular_file_trusted "$XANMOD_SOURCE_LIST" 644 &&
        awk -v expected_key="$XANMOD_KEYRING" '
            /^[[:space:]]*($|#)/ { next }
            {
                line_count++
                if (NF == 5 && $1 == "deb" &&
                    $2 == "[signed-by=" expected_key "]" &&
                    $3 ~ /^https:\/\/(deb\.xanmod\.org|mirror\.nju\.edu\.cn\/xanmod|mirrors\.bfsu\.edu\.cn\/xanmod|mirrors\.tuna\.tsinghua\.edu\.cn\/xanmod)\/?$/ &&
                    $4 ~ /^[a-z0-9][a-z0-9.+-]*$/ && $5 == "main") valid_count++
                else invalid = 1
            }
            END { exit !(line_count == 1 && valid_count == 1 && !invalid) }
        ' "$XANMOD_SOURCE_LIST"
}

xanmod_deb822_source_configured() {
    xanmod_formal_keyring_valid &&
        xanmod_regular_file_trusted "$XANMOD_SOURCE_DEB822" 644 &&
        awk -F: -v expected_key="$XANMOD_KEYRING" '
            function trim(value) {
                sub(/^[[:space:]]+/, "", value)
                sub(/[[:space:]]+$/, "", value)
                return value
            }
            /^[[:space:]]*($|#)/ { next }
            {
                name=trim($1)
                value=trim(substr($0, index($0, ":") + 1))
                if (name == "Types" && value == "deb") types++
                else if (name == "URIs" &&
                    value ~ /^https:\/\/(deb\.xanmod\.org|mirror\.nju\.edu\.cn\/xanmod|mirrors\.bfsu\.edu\.cn\/xanmod|mirrors\.tuna\.tsinghua\.edu\.cn\/xanmod)\/?$/) uris++
                else if (name == "Suites" && value ~ /^[a-z0-9][a-z0-9.+-]*$/) suites++
                else if (name == "Components" && value == "main") components++
                else if (name == "Signed-By" && value == expected_key) signed_by++
                else invalid = 1
            }
            END {
                exit !(types == 1 && uris == 1 && suites == 1 && components == 1 &&
                    signed_by == 1 && !invalid)
            }
        ' "$XANMOD_SOURCE_DEB822"
}

get_xanmod_source_file() {
    if xanmod_deb822_source_configured; then
        echo "$XANMOD_SOURCE_DEB822"
    elif xanmod_list_source_configured; then
        echo "$XANMOD_SOURCE_LIST"
    else
        return 1
    fi
}

xanmod_source_matches_codename() {
    local source_file="$1"
    local codename="$2"

    xanmod_codename_safe "$codename" || return 1
    case "$source_file" in
        *.sources)
            awk -F: -v expected="$codename" '
                function trim(value) {
                    sub(/^[[:space:]]+/, "", value)
                    sub(/[[:space:]]+$/, "", value)
                    return value
                }
                /^[[:space:]]*($|#)/ { next }
                {
                    name=trim($1)
                    value=trim(substr($0, index($0, ":") + 1))
                    if (name == "Suites") {
                        suite_count++
                        suite=value
                    }
                }
                END { exit !(suite_count == 1 && suite == expected) }
            ' "$source_file"
            ;;
        *)
            awk -v expected="$codename" '
                /^[[:space:]]*($|#)/ { next }
                {
                    line_count++
                    if (NF == 5 && $1 == "deb" && $4 == expected && $5 == "main")
                        valid_count++
                    else
                        invalid=1
                }
                END { exit !(line_count == 1 && valid_count == 1 && !invalid) }
            ' "$source_file"
            ;;
    esac
}

write_xanmod_deb822_source() {
    local source_file="$1"
    local repository="$2"
    local codename="$3"
    local keyring_path="${4:-$XANMOD_KEYRING}"

    xanmod_codename_safe "$codename" || return 1
    cat > "$source_file" <<EOF
Types: deb
URIs: $repository
Suites: $codename
Components: main
Signed-By: $keyring_path
EOF
}

remove_xanmod_temp_directory() {
    local path="$1"
    local label="$2"

    [[ -n "$path" ]] || return 0
    if rm -rf -- "$path"; then
        return 0
    fi
    error "$label 残留: $path"
    return 1
}

remove_xanmod_temp_file() {
    local path="$1"
    local label="$2"

    [[ -n "$path" ]] || return 0
    if rm -f -- "$path"; then
        return 0
    fi
    error "$label 残留: $path"
    return 1
}

xanmod_random_token() {
    local token=""

    token=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n') || return 1
    [[ "$token" =~ ^[0-9a-f]{32}$ ]] || return 1
    printf '%s\n' "$token"
}

xanmod_allocation_proof_path() {
    local kind="$1"
    local candidate="$2"
    local owner_token="$3"

    case "$kind" in
        directory) printf '%s/.xanmod-allocation-owner\n' "$candidate" ;;
        file) printf '%s.xanmod-owner.%s\n' "$candidate" "$owner_token" ;;
        *) return 1 ;;
    esac
}

xanmod_create_temp_directory_at_path() {
    local path="$1"
    local mode="$2"
    local proof_path=""
    local identity=""

    proof_path=$(xanmod_allocation_proof_path directory "$path" "$XANMOD_ALLOCATION_OWNER_TOKEN") || return 1
    mkdir -m "$mode" -- "$path" || return 1
    if ! identity=$(stat -c '%d:%i' -- "$path") ||
        ! (umask 077; set -o noclobber; printf '%s\n%s\n' \
            "$XANMOD_ALLOCATION_OWNER_TOKEN" "$identity" > "$proof_path") 2>/dev/null; then
        rmdir "$path" 2>/dev/null || true
        return 1
    fi
}

xanmod_create_temp_file_at_path() {
    local path="$1"
    local mode="$2"
    local proof_path=""
    local identity=""

    [[ "$mode" == "0600" || "$mode" == "600" ]] || return 1
    proof_path=$(xanmod_allocation_proof_path file "$path" "$XANMOD_ALLOCATION_OWNER_TOKEN") || return 1
    if ! (umask 077; set -o noclobber; : > "$path") 2>/dev/null; then
        return 1
    fi
    if ! identity=$(stat -c '%d:%i' -- "$path") ||
        ! (umask 077; set -o noclobber; printf '%s\n%s\n' \
            "$XANMOD_ALLOCATION_OWNER_TOKEN" "$identity" > "$proof_path") 2>/dev/null; then
        rm -f -- "$path" 2>/dev/null || true
        return 1
    fi
}

xanmod_begin_pending_allocation() {
    local kind="$1"
    local candidate="$2"
    local mode="$3"
    local owner_token="$4"

    if [[ -n "$XANMOD_ALLOCATION_CANDIDATE" || -n "$XANMOD_ALLOCATION_STATE" ]]; then
        error "XanMod 临时资源分配生命周期尚未结束"
        return 1
    fi
    [[ "$kind" == directory || "$kind" == file ]] || return 1
    [[ "$owner_token" =~ ^[0-9A-Za-z_-]+$ ]] || return 1
    XANMOD_ALLOCATION_CANDIDATE="$candidate"
    XANMOD_ALLOCATION_KIND="$kind"
    XANMOD_ALLOCATION_OWNER_TOKEN="$owner_token"
    XANMOD_ALLOCATION_EXPECTED_MODE="${mode#0}"
    XANMOD_ALLOCATION_STATE=candidate
}

xanmod_clear_pending_allocation() {
    XANMOD_ALLOCATION_CANDIDATE=""
    XANMOD_ALLOCATION_KIND=""
    XANMOD_ALLOCATION_OWNER_TOKEN=""
    XANMOD_ALLOCATION_EXPECTED_MODE=""
    XANMOD_ALLOCATION_STATE=""
}

xanmod_after_allocation_attempt_hook() {
    :
}

xanmod_run_pending_allocation_create() {
    # 子进程忽略事务信号，避免停在“已创建但尚未写入所有权证明”的窗口。
    # 父 shell 仍保留事务 trap，并在创建调用返回后按 proof 状态清理。
    (
        trap '' HUP INT TERM
        case "$XANMOD_ALLOCATION_KIND" in
            directory)
                xanmod_create_temp_directory_at_path \
                    "$XANMOD_ALLOCATION_CANDIDATE" "$XANMOD_ALLOCATION_EXPECTED_MODE"
                ;;
            file)
                xanmod_create_temp_file_at_path \
                    "$XANMOD_ALLOCATION_CANDIDATE" "$XANMOD_ALLOCATION_EXPECTED_MODE"
                ;;
            *) return 1 ;;
        esac
    )
}

xanmod_pending_allocation_proof_trusted() {
    local proof_path=""
    local metadata=""
    local proof_token=""
    local proof_identity=""
    local extra_line=""

    [[ -n "$XANMOD_ALLOCATION_CANDIDATE" &&
        -n "$XANMOD_ALLOCATION_OWNER_TOKEN" ]] || return 1
    proof_path=$(xanmod_allocation_proof_path \
        "$XANMOD_ALLOCATION_KIND" "$XANMOD_ALLOCATION_CANDIDATE" \
        "$XANMOD_ALLOCATION_OWNER_TOKEN") || return 1
    [[ -f "$proof_path" && ! -L "$proof_path" ]] || return 1
    metadata=$(stat -c '%u:%g:%a' -- "$proof_path") || return 1
    [[ "$metadata" == "$XANMOD_TRUSTED_UID:$XANMOD_TRUSTED_GID:600" ]] || return 1
    {
        IFS= read -r proof_token || return 1
        IFS= read -r proof_identity || return 1
        if IFS= read -r extra_line; then
            return 1
        fi
    } < "$proof_path"
    [[ "$proof_token" == "$XANMOD_ALLOCATION_OWNER_TOKEN" &&
        "$proof_identity" =~ ^[0-9]+:[0-9]+$ ]]
}

xanmod_pending_allocation_owned() {
    local metadata=""
    local identity=""
    local proof_path=""
    local proof_token=""
    local proof_identity=""

    xanmod_pending_allocation_proof_trusted || return 1
    case "$XANMOD_ALLOCATION_KIND" in
        directory)
            [[ -d "$XANMOD_ALLOCATION_CANDIDATE" &&
                ! -L "$XANMOD_ALLOCATION_CANDIDATE" ]] || return 1
            ;;
        file)
            [[ -f "$XANMOD_ALLOCATION_CANDIDATE" &&
                ! -L "$XANMOD_ALLOCATION_CANDIDATE" ]] || return 1
            ;;
        *) return 1 ;;
    esac
    metadata=$(stat -c '%u:%g:%a' -- "$XANMOD_ALLOCATION_CANDIDATE") || return 1
    [[ "$metadata" == "$XANMOD_TRUSTED_UID:$XANMOD_TRUSTED_GID:$XANMOD_ALLOCATION_EXPECTED_MODE" ]] || return 1
    identity=$(stat -c '%d:%i' -- "$XANMOD_ALLOCATION_CANDIDATE") || return 1
    proof_path=$(xanmod_allocation_proof_path \
        "$XANMOD_ALLOCATION_KIND" "$XANMOD_ALLOCATION_CANDIDATE" \
        "$XANMOD_ALLOCATION_OWNER_TOKEN") || return 1
    {
        IFS= read -r proof_token || return 1
        IFS= read -r proof_identity || return 1
    } < "$proof_path"
    [[ "$proof_token" == "$XANMOD_ALLOCATION_OWNER_TOKEN" &&
        "$identity" == "$proof_identity" ]]
}

xanmod_release_pending_allocation_proof() {
    local proof_path=""

    xanmod_pending_allocation_owned || return 1
    proof_path=$(xanmod_allocation_proof_path \
        "$XANMOD_ALLOCATION_KIND" "$XANMOD_ALLOCATION_CANDIDATE" \
        "$XANMOD_ALLOCATION_OWNER_TOKEN") || return 1
    if ! rm -f -- "$proof_path"; then
        error "XanMod 分配所有权标记残留: $proof_path"
        return 1
    fi
}

cleanup_xanmod_pending_allocation() {
    local proof_path=""

    if [[ -z "$XANMOD_ALLOCATION_CANDIDATE" ]]; then
        xanmod_clear_pending_allocation
        return 0
    fi
    proof_path=$(xanmod_allocation_proof_path \
        "$XANMOD_ALLOCATION_KIND" "$XANMOD_ALLOCATION_CANDIDATE" \
        "$XANMOD_ALLOCATION_OWNER_TOKEN") || return 1

    if xanmod_pending_allocation_owned; then
        case "$XANMOD_ALLOCATION_KIND" in
            directory)
                remove_xanmod_temp_directory \
                    "$XANMOD_ALLOCATION_CANDIDATE" "XanMod 自有临时目录" || return 1
                ;;
            file)
                remove_xanmod_temp_file \
                    "$XANMOD_ALLOCATION_CANDIDATE" "XanMod 自有临时文件" || return 1
                remove_xanmod_temp_file \
                    "$proof_path" "XanMod 分配所有权标记" || return 1
                ;;
        esac
    elif [[ "$XANMOD_ALLOCATION_KIND" == file &&
        ! -e "$XANMOD_ALLOCATION_CANDIDATE" &&
        ! -L "$XANMOD_ALLOCATION_CANDIDATE" ]] &&
        xanmod_pending_allocation_proof_trusted; then
        remove_xanmod_temp_file \
            "$proof_path" "XanMod 分配所有权标记" || return 1
    else
        # 没有可信 proof 的 candidate 可能是冲突对象；只清状态，绝不删除路径。
        xanmod_clear_pending_allocation
        return 0
    fi

    xanmod_clear_pending_allocation
}

xanmod_finish_pending_allocation() {
    local path_variable="$1"
    local building_variable="${2:-}"

    xanmod_pending_allocation_owned || return 1
    XANMOD_ALLOCATION_STATE=owned
    printf -v "$path_variable" '%s' "$XANMOD_ALLOCATION_CANDIDATE"
    if [[ -n "$building_variable" ]]; then
        printf -v "$building_variable" '%s' true
    fi
    XANMOD_ALLOCATION_STATE=active
    xanmod_release_pending_allocation_proof || return 1
    xanmod_clear_pending_allocation
}

xanmod_allocate_temp_directory() {
    local path_variable="$1"
    local building_variable="$2"
    local parent="$3"
    local prefix="$4"
    local mode="$5"
    local token=""
    local owner_token=""
    local candidate=""
    local create_status=0
    local candidate_conflict=false
    local attempt

    [[ -d "$parent" && ! -L "$parent" ]] || return 1
    [[ -z "$XANMOD_ALLOCATION_CANDIDATE" && -z "$XANMOD_ALLOCATION_STATE" ]] || return 1
    printf -v "$path_variable" '%s' ""
    printf -v "$building_variable" '%s' false
    for attempt in {1..64}; do
        token=$(xanmod_random_token) || return 1
        owner_token=$(xanmod_random_token) || return 1
        candidate="$parent/$prefix.$token"
        xanmod_begin_pending_allocation directory "$candidate" "$mode" "$owner_token" || return 1
        create_status=0
        xanmod_run_pending_allocation_create 2>/dev/null || create_status=$?
        xanmod_after_allocation_attempt_hook directory "$candidate" "$create_status" || true
        if (( create_status == 0 )); then
            xanmod_finish_pending_allocation "$path_variable" "$building_variable"
            return
        fi
        if xanmod_pending_allocation_owned; then
            cleanup_xanmod_pending_allocation || true
            return 1
        fi
        candidate_conflict=false
        [[ -e "$candidate" || -L "$candidate" ]] && candidate_conflict=true
        xanmod_clear_pending_allocation
        if [[ "$candidate_conflict" == true ]]; then
            continue
        fi
        return 1
    done
    return 1
}

xanmod_allocate_temp_file() {
    local path_variable="$1"
    local parent="$2"
    local prefix="$3"
    local suffix="$4"
    local mode="$5"
    local token=""
    local owner_token=""
    local candidate=""
    local create_status=0
    local candidate_conflict=false
    local attempt

    [[ -d "$parent" && ! -L "$parent" ]] || return 1
    [[ -z "$XANMOD_ALLOCATION_CANDIDATE" && -z "$XANMOD_ALLOCATION_STATE" ]] || return 1
    printf -v "$path_variable" '%s' ""
    for attempt in {1..64}; do
        token=$(xanmod_random_token) || return 1
        owner_token=$(xanmod_random_token) || return 1
        candidate="$parent/$prefix.$token$suffix"
        xanmod_begin_pending_allocation file "$candidate" "$mode" "$owner_token" || return 1
        create_status=0
        xanmod_run_pending_allocation_create || create_status=$?
        xanmod_after_allocation_attempt_hook file "$candidate" "$create_status" || true
        if (( create_status == 0 )); then
            xanmod_finish_pending_allocation "$path_variable"
            return
        fi
        if xanmod_pending_allocation_owned; then
            cleanup_xanmod_pending_allocation || true
            return 1
        fi
        candidate_conflict=false
        [[ -e "$candidate" || -L "$candidate" ]] && candidate_conflict=true
        xanmod_clear_pending_allocation
        if [[ "$candidate_conflict" == true ]]; then
            continue
        fi
        return 1
    done
    return 1
}

cleanup_xanmod_active_apt_lists() {
    if [[ -z "$XANMOD_ACTIVE_APT_LISTS_DIR" ]]; then
        XANMOD_ACTIVE_APT_LISTS_BUILDING=false
        return 0
    fi
    if [[ ! -e "$XANMOD_ACTIVE_APT_LISTS_DIR" && ! -L "$XANMOD_ACTIVE_APT_LISTS_DIR" ]] ||
        remove_xanmod_temp_directory "$XANMOD_ACTIVE_APT_LISTS_DIR" "临时 APT lists"; then
        XANMOD_ACTIVE_APT_LISTS_DIR=""
        XANMOD_ACTIVE_APT_LISTS_BUILDING=false
        return 0
    fi
    return 1
}

xanmod_source_is_usable() {
    local source_file="$1"
    local apt_status=0
    local temp_parent="${TMPDIR:-/tmp}"

    xanmod_allocate_temp_directory XANMOD_ACTIVE_APT_LISTS_DIR \
        XANMOD_ACTIVE_APT_LISTS_BUILDING "$temp_parent" xanmod-apt-lists 0755 || return 1
    XANMOD_ACTIVE_APT_LISTS_BUILDING=false
    if ! install -d -m 0755 "$XANMOD_ACTIVE_APT_LISTS_DIR/partial"; then
        cleanup_xanmod_active_apt_lists || true
        return 1
    fi

    if apt-get update -qq \
        -o "Dir::Etc::sourcelist=$source_file" \
        -o 'Dir::Etc::sourceparts=-' \
        -o "Dir::State::lists=$XANMOD_ACTIVE_APT_LISTS_DIR" \
        -o 'APT::Get::List-Cleanup=0'; then
        apt_status=0
    else
        apt_status=$?
    fi

    if ! cleanup_xanmod_active_apt_lists; then
        return 125
    fi
    return "$apt_status"
}

capture_xanmod_snapshot_item() {
    local target="$1"
    local snapshot_prefix="$2"

    if [[ -L "$target" ]]; then
        printf '%s\n' symlink > "${snapshot_prefix}.state" || return 1
        cp -a -- "$target" "${snapshot_prefix}.data" || return 1
    elif [[ -f "$target" ]]; then
        printf '%s\n' file > "${snapshot_prefix}.state" || return 1
        cp -a -- "$target" "${snapshot_prefix}.data" || return 1
    elif [[ ! -e "$target" ]]; then
        printf '%s\n' absent > "${snapshot_prefix}.state" || return 1
    else
        error "拒绝处理非常规 XanMod 配置路径: $target"
        return 1
    fi
}

cleanup_incomplete_xanmod_runtime_snapshot() {
    if [[ "$XANMOD_TRANSACTION_ACTIVE" == "true" ]]; then
        error "拒绝把完整活动快照当作不完整快照删除"
        return 1
    fi
    if [[ -z "$XANMOD_RUNTIME_SNAPSHOT_DIR" ]]; then
        XANMOD_RUNTIME_SNAPSHOT_BUILDING=false
        return 0
    fi
    if ! remove_xanmod_temp_directory "$XANMOD_RUNTIME_SNAPSHOT_DIR" "XanMod 不完整运行时快照"; then
        return 1
    fi
    XANMOD_RUNTIME_SNAPSHOT_DIR=""
    XANMOD_RUNTIME_SNAPSHOT_BUILDING=false
}

create_xanmod_runtime_snapshot() {
    local index
    local temp_parent="${TMPDIR:-/tmp}"

    if [[ "$XANMOD_TRANSACTION_ACTIVE" == "true" ||
        "$XANMOD_RUNTIME_SNAPSHOT_BUILDING" == "true" ||
        -n "$XANMOD_RUNTIME_SNAPSHOT_DIR" ]]; then
        error "XanMod 配置快照生命周期尚未结束"
        return 1
    fi

    if ! xanmod_allocate_temp_directory XANMOD_RUNTIME_SNAPSHOT_DIR \
        XANMOD_RUNTIME_SNAPSHOT_BUILDING "$temp_parent" xanmod-runtime-snapshot 0700; then
        cleanup_incomplete_xanmod_runtime_snapshot || true
        return 1
    fi

    for index in "${!XANMOD_MANAGED_PATHS[@]}"; do
        if ! capture_xanmod_snapshot_item \
            "${XANMOD_MANAGED_PATHS[$index]}" \
            "$XANMOD_RUNTIME_SNAPSHOT_DIR/item-$index"; then
            cleanup_incomplete_xanmod_runtime_snapshot || true
            return 1
        fi
    done

    XANMOD_RUNTIME_SNAPSHOT_BUILDING=false
    XANMOD_TRANSACTION_ACTIVE=true
    XANMOD_CONFIG_MODIFIED=false
}

restore_xanmod_snapshot_item() {
    local target="$1"
    local snapshot_prefix="$2"
    local state=""
    local parent=""

    [[ -r "${snapshot_prefix}.state" ]] || return 1
    state=$(<"${snapshot_prefix}.state")

    if [[ -d "$target" && ! -L "$target" ]]; then
        error "拒绝用文件状态覆盖目录: $target"
        return 1
    fi
    parent=$(dirname "$target") || return 1
    if [[ ! -d "$parent" ]]; then
        install -d -m 0755 "$parent" || return 1
    elif [[ -L "$parent" ]]; then
        error "拒绝通过符号链接父目录恢复: $parent"
        return 1
    fi

    case "$state" in
        file)
            [[ -f "${snapshot_prefix}.data" && ! -L "${snapshot_prefix}.data" ]] || return 1
            rm -f -- "$target" || return 1
            cp -a -- "${snapshot_prefix}.data" "$target" || return 1
            ;;
        symlink)
            [[ -L "${snapshot_prefix}.data" ]] || return 1
            rm -f -- "$target" || return 1
            cp -a -- "${snapshot_prefix}.data" "$target" || return 1
            ;;
        absent)
            rm -f -- "$target" || return 1
            ;;
        *)
            return 1
            ;;
    esac
}

restore_xanmod_runtime_snapshot() {
    local index
    local restore_failed=false

    [[ "$XANMOD_TRANSACTION_ACTIVE" == "true" ]] || return 0

    for index in "${!XANMOD_MANAGED_PATHS[@]}"; do
        if ! restore_xanmod_snapshot_item \
            "${XANMOD_MANAGED_PATHS[$index]}" \
            "$XANMOD_RUNTIME_SNAPSHOT_DIR/item-$index"; then
            error "恢复 XanMod 配置失败: ${XANMOD_MANAGED_PATHS[$index]}"
            restore_failed=true
        fi
    done
    if [[ "$restore_failed" == "true" ]]; then
        XANMOD_CONFIG_MODIFIED=true
        error "XanMod 运行时快照已保留，可在故障解除后重试: $XANMOD_RUNTIME_SNAPSHOT_DIR"
        return 1
    fi

    if ! remove_xanmod_temp_directory "$XANMOD_RUNTIME_SNAPSHOT_DIR" "XanMod 运行时快照"; then
        XANMOD_CONFIG_MODIFIED=true
        return 1
    fi
    XANMOD_RUNTIME_SNAPSHOT_DIR=""
    XANMOD_RUNTIME_SNAPSHOT_BUILDING=false
    XANMOD_TRANSACTION_ACTIVE=false
    XANMOD_CONFIG_MODIFIED=false
}

discard_xanmod_runtime_snapshot() {
    if [[ -z "$XANMOD_RUNTIME_SNAPSHOT_DIR" ]]; then
        XANMOD_RUNTIME_SNAPSHOT_BUILDING=false
        XANMOD_TRANSACTION_ACTIVE=false
        return 0
    fi
    if ! remove_xanmod_temp_directory "$XANMOD_RUNTIME_SNAPSHOT_DIR" "XanMod 运行时快照"; then
        return 1
    fi
    XANMOD_RUNTIME_SNAPSHOT_DIR=""
    XANMOD_RUNTIME_SNAPSHOT_BUILDING=false
    XANMOD_TRANSACTION_ACTIVE=false
}

xanmod_directory_trusted() {
    local directory="$1"
    local expected_mode="$2"
    local metadata=""

    [[ -d "$directory" && ! -L "$directory" ]] || return 1
    metadata=$(stat -c '%u:%g:%a' -- "$directory") || return 1
    [[ "$metadata" == "$XANMOD_TRUSTED_UID:$XANMOD_TRUSTED_GID:$expected_mode" ]]
}

set_xanmod_state_file_metadata() {
    local file="$1"

    [[ -f "$file" && ! -L "$file" ]] || return 1
    if [[ "${XANMOD_TEST_MODE:-0}" == "1" ]]; then
        [[ "$(stat -c '%u' -- "$file")" == "$XANMOD_TRUSTED_UID" ]] || return 1
        chgrp "$XANMOD_TRUSTED_GID" "$file" || return 1
    else
        chown 0:0 "$file" || return 1
    fi
    chmod 0600 "$file" || return 1
    xanmod_regular_file_trusted "$file" 600
}

xanmod_state_marker_trusted() {
    local marker="$1"

    xanmod_regular_file_trusted "$marker" 600 && [[ ! -s "$marker" ]]
}

xanmod_path_owner_trusted() {
    local path="$1"
    local metadata=""

    [[ -e "$path" || -L "$path" ]] || return 1
    metadata=$(stat -c '%u:%g' -- "$path") || return 1
    [[ "$metadata" == "$XANMOD_TRUSTED_UID:$XANMOD_TRUSTED_GID" ]]
}

xanmod_legacy_backup_item_trusted() {
    local backup="$1"
    local mode=""
    local mode_value=0

    if [[ -L "$backup" ]]; then
        xanmod_path_owner_trusted "$backup"
        return
    fi
    [[ -f "$backup" ]] || return 1
    xanmod_path_owner_trusted "$backup" || return 1
    mode=$(stat -c '%a' -- "$backup") || return 1
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    mode_value=$((8#$mode))
    (( (mode_value & 0400) != 0 && (mode_value & 0022) == 0 ))
}

xanmod_backup_metadata_values() {
    local metadata_file="$1"

    xanmod_regular_file_trusted "$metadata_file" 600 || return 1
    awk -F= '
        $1 == "type" && ($2 == "file" || $2 == "symlink") { type=$2; type_count++; next }
        $1 == "uid" && $2 ~ /^[0-9]+$/ { uid=$2; uid_count++; next }
        $1 == "gid" && $2 ~ /^[0-9]+$/ { gid=$2; gid_count++; next }
        $1 == "mode" && $2 ~ /^[0-7][0-7][0-7]([0-7])?$/ { mode=$2; mode_count++; next }
        { invalid=1 }
        END {
            if (type_count == 1 && uid_count == 1 && gid_count == 1 && mode_count == 1 && !invalid)
                print type, uid, gid, mode
            else
                exit 1
        }
    ' "$metadata_file"
}

xanmod_new_backup_state_trusted() {
    local backup="$1"
    local metadata_file="$2"

    xanmod_regular_file_trusted "$backup" 600 &&
        xanmod_backup_metadata_values "$metadata_file" >/dev/null
}

xanmod_backup_parent_directory_trusted() {
    local directory="$1"
    local metadata=""
    local owner=""
    local group=""
    local mode=""
    local mode_value=0

    [[ -d "$directory" && ! -L "$directory" ]] || return 1
    metadata=$(stat -c '%u:%g:%a' -- "$directory") || return 1
    IFS=: read -r owner group mode <<< "$metadata"
    [[ "$owner" == "$XANMOD_TRUSTED_UID" &&
        "$group" == "$XANMOD_TRUSTED_GID" &&
        "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    mode_value=$((8#$mode))
    (( (mode_value & 0700) == 0700 && (mode_value & 0022) == 0 ))
}

ensure_xanmod_backup_state_parent_dir() {
    local parent=""
    local current=""
    local ancestor=""
    local directory=""
    local index
    local -a missing_directories=()

    parent=$(dirname "$XANMOD_BACKUP_STATE_DIR") || return 1
    if [[ "$parent" != /* ]]; then
        error "XanMod backup 父目录必须是绝对路径: $parent"
        return 1
    fi
    current="$parent"
    while [[ ! -e "$current" && ! -L "$current" ]]; do
        missing_directories+=("$current")
        ancestor=$(dirname "$current") || return 1
        if [[ "$ancestor" == "$current" ]]; then
            error "无法定位可信 XanMod backup 父目录: $parent"
            return 1
        fi
        current="$ancestor"
    done
    if ! xanmod_backup_parent_directory_trusted "$current"; then
        error "XanMod backup 父目录类型、owner、GID 或 mode 不可信: $current"
        return 1
    fi

    for ((index = ${#missing_directories[@]} - 1; index >= 0; index--)); do
        directory="${missing_directories[$index]}"
        if mkdir -m 0755 -- "$directory" 2>/dev/null; then
            :
        elif [[ ! -e "$directory" && ! -L "$directory" ]]; then
            error "无法创建 XanMod backup 父目录: $directory"
            return 1
        fi
        if ! xanmod_backup_parent_directory_trusted "$directory"; then
            error "XanMod backup 父目录类型、owner、GID 或 mode 不可信: $directory"
            return 1
        fi
    done
}

xanmod_create_backup_state_dir() {
    xanmod_create_temp_directory_at_path "$XANMOD_BACKUP_STATE_DIR" 0700
}

ensure_xanmod_backup_state_dir() {
    local owner_token=""
    local create_status=0
    local collision=false

    XANMOD_BACKUP_STATE_DIR_CREATING=false
    XANMOD_BACKUP_STATE_DIR_CREATED=false
    XANMOD_BACKUP_STATE_DIR_PREEXISTED=false
    ensure_xanmod_backup_state_parent_dir || return 1
    if [[ -e "$XANMOD_BACKUP_STATE_DIR" || -L "$XANMOD_BACKUP_STATE_DIR" ]]; then
        XANMOD_BACKUP_STATE_DIR_PREEXISTED=true
        if ! xanmod_directory_trusted "$XANMOD_BACKUP_STATE_DIR" 700; then
            error "XanMod 备份目录类型、owner 或 mode 不可信: $XANMOD_BACKUP_STATE_DIR"
            return 1
        fi
        return 0
    fi

    owner_token=$(xanmod_random_token) || return 1
    xanmod_begin_pending_allocation directory \
        "$XANMOD_BACKUP_STATE_DIR" 0700 "$owner_token" || return 1
    create_status=0
    (
        trap '' HUP INT TERM
        xanmod_create_backup_state_dir
    ) 2>/dev/null || create_status=$?
    xanmod_after_allocation_attempt_hook \
        backup-state "$XANMOD_BACKUP_STATE_DIR" "$create_status" || true

    if (( create_status == 0 )); then
        if ! xanmod_pending_allocation_owned; then
            error "无法证明新建 XanMod 备份目录属于本次事务: $XANMOD_BACKUP_STATE_DIR"
            cleanup_xanmod_pending_allocation || true
            return 1
        fi
        XANMOD_ALLOCATION_STATE=owned
        XANMOD_BACKUP_STATE_DIR_CREATING=true
        XANMOD_BACKUP_STATE_DIR_CREATED=true
        XANMOD_BACKUP_STATE_DIR_CREATING=false
        XANMOD_ALLOCATION_STATE=active
        if ! xanmod_release_pending_allocation_proof; then
            cleanup_xanmod_pending_allocation || true
            cleanup_new_empty_xanmod_backup_state_dir || true
            return 1
        fi
        xanmod_clear_pending_allocation
        if ! xanmod_directory_trusted "$XANMOD_BACKUP_STATE_DIR" 700; then
            error "新建 XanMod 备份目录未通过 owner/mode 校验"
            cleanup_new_empty_xanmod_backup_state_dir || true
            return 1
        fi
        return 0
    fi

    if xanmod_pending_allocation_owned; then
        cleanup_xanmod_pending_allocation || true
        error "XanMod 备份目录创建失败，但检测到本次事务的未提交目录"
        return 1
    fi
    [[ -e "$XANMOD_BACKUP_STATE_DIR" || -L "$XANMOD_BACKUP_STATE_DIR" ]] && collision=true
    xanmod_clear_pending_allocation
    if [[ "$collision" == true ]]; then
        XANMOD_BACKUP_STATE_DIR_PREEXISTED=true
        if xanmod_directory_trusted "$XANMOD_BACKUP_STATE_DIR" 700; then
            return 0
        fi
        error "竞争创建后的 XanMod 备份目录不可信: $XANMOD_BACKUP_STATE_DIR"
        return 1
    fi
    error "无法排他创建 XanMod 备份目录: $XANMOD_BACKUP_STATE_DIR"
    return 1
}

get_xanmod_backup_prefix() {
    printf '%s/%s\n' "$XANMOD_BACKUP_STATE_DIR" "$(basename "$1")"
}

xanmod_state_path_exists() {
    [[ -e "$1" || -L "$1" ]]
}

classify_xanmod_state_prefix() {
    local prefix="$1"
    local scope="$2"
    local allow_unknown="$3"
    local backup="${prefix}.${scope}-backup"
    local metadata_file="${prefix}.${scope}-backup-meta"
    local absent="${prefix}.${scope}-absent"
    local unknown="${prefix}.${scope}-unknown"
    local state_count=0
    local state_type="none"

    if xanmod_state_path_exists "$backup" || xanmod_state_path_exists "$metadata_file"; then
        ((state_count += 1))
        if xanmod_state_path_exists "$backup" && xanmod_state_path_exists "$metadata_file"; then
            xanmod_new_backup_state_trusted "$backup" "$metadata_file" || return 1
            state_type="backup-new"
        elif xanmod_state_path_exists "$backup" && ! xanmod_state_path_exists "$metadata_file"; then
            xanmod_legacy_backup_item_trusted "$backup" || return 1
            state_type="backup-legacy"
        else
            return 1
        fi
    fi
    if xanmod_state_path_exists "$absent"; then
        ((state_count += 1))
        xanmod_state_marker_trusted "$absent" || return 1
        state_type="absent"
    fi
    if xanmod_state_path_exists "$unknown"; then
        ((state_count += 1))
        [[ "$allow_unknown" == "true" ]] || return 1
        xanmod_state_marker_trusted "$unknown" || return 1
        state_type="unknown"
    fi
    (( state_count <= 1 )) || return 1
    printf '%s\n' "$state_type"
}

validate_xanmod_backup_group_items() {
    local target
    local prefix

    for target in "${XANMOD_MANAGED_PATHS[@]}"; do
        prefix=$(get_xanmod_backup_prefix "$target") || return 1
        classify_xanmod_state_prefix "$prefix" initial true >/dev/null || return 1
        classify_xanmod_state_prefix "$prefix" previous false >/dev/null || return 1
        classify_xanmod_state_prefix "$target" initial true >/dev/null || return 1
        classify_xanmod_state_prefix "$target" previous false >/dev/null || return 1
    done
}

write_xanmod_backup_metadata() {
    local source_path="$1"
    local metadata_file="$2"
    local source_type="file"
    local metadata=""
    local source_uid
    local source_gid
    local source_mode

    [[ -L "$source_path" ]] && source_type="symlink"
    metadata=$(stat -c '%u:%g:%a' -- "$source_path") || return 1
    IFS=: read -r source_uid source_gid source_mode <<< "$metadata"
    printf 'type=%s\nuid=%s\ngid=%s\nmode=%s\n' \
        "$source_type" "$source_uid" "$source_gid" "$source_mode" > "$metadata_file" || return 1
    set_xanmod_state_file_metadata "$metadata_file"
}

capture_xanmod_persistent_state() {
    local target="$1"
    local prefix="$2"
    local scope="$3"
    local backup="${prefix}.${scope}-backup"
    local metadata_file="${prefix}.${scope}-backup-meta"
    local absent="${prefix}.${scope}-absent"
    local unknown="${prefix}.${scope}-unknown"

    rm -f -- "$backup" "$metadata_file" "$absent" "$unknown" || return 1
    if [[ -L "$target" ]]; then
        readlink "$target" > "$backup" || return 1
        set_xanmod_state_file_metadata "$backup" || return 1
        write_xanmod_backup_metadata "$target" "$metadata_file" || return 1
    elif [[ -f "$target" ]]; then
        cat "$target" > "$backup" || return 1
        set_xanmod_state_file_metadata "$backup" || return 1
        write_xanmod_backup_metadata "$target" "$metadata_file" || return 1
    elif [[ ! -e "$target" ]]; then
        install -m 0600 /dev/null "$absent" || return 1
        set_xanmod_state_file_metadata "$absent" || return 1
    else
        error "拒绝备份非常规 XanMod 配置路径: $target"
        return 1
    fi
}

stage_xanmod_state_from_prefix() {
    local source_prefix="$1"
    local source_scope="$2"
    local destination_prefix="$3"
    local destination_scope="$4"
    local state_type=""
    local source_backup="${source_prefix}.${source_scope}-backup"
    local source_meta="${source_prefix}.${source_scope}-backup-meta"
    local destination_backup="${destination_prefix}.${destination_scope}-backup"
    local destination_meta="${destination_prefix}.${destination_scope}-backup-meta"
    local destination_absent="${destination_prefix}.${destination_scope}-absent"
    local destination_unknown="${destination_prefix}.${destination_scope}-unknown"
    local link_target=""

    state_type=$(classify_xanmod_state_prefix "$source_prefix" "$source_scope" true) || return 1
    rm -f -- "$destination_backup" "$destination_meta" "$destination_absent" "$destination_unknown" || return 1
    case "$state_type" in
        backup-new)
            cat "$source_backup" > "$destination_backup" || return 1
            cat "$source_meta" > "$destination_meta" || return 1
            set_xanmod_state_file_metadata "$destination_backup" || return 1
            set_xanmod_state_file_metadata "$destination_meta" || return 1
            ;;
        backup-legacy)
            if [[ -L "$source_backup" ]]; then
                link_target=$(readlink "$source_backup") || return 1
                printf '%s\n' "$link_target" > "$destination_backup" || return 1
            else
                cat "$source_backup" > "$destination_backup" || return 1
            fi
            set_xanmod_state_file_metadata "$destination_backup" || return 1
            write_xanmod_backup_metadata "$source_backup" "$destination_meta" || return 1
            ;;
        absent)
            install -m 0600 /dev/null "$destination_absent" || return 1
            set_xanmod_state_file_metadata "$destination_absent" || return 1
            ;;
        unknown)
            install -m 0600 /dev/null "$destination_unknown" || return 1
            set_xanmod_state_file_metadata "$destination_unknown" || return 1
            ;;
        *)
            return 1
            ;;
    esac
}

xanmod_configuration_looks_previously_managed() {
    if [[ -f "$XANMOD_SOURCE_DEB822" ]] &&
        grep -Fq "Signed-By: $XANMOD_KEYRING" "$XANMOD_SOURCE_DEB822"; then
        return 0
    fi
    if [[ -f "$XANMOD_SOURCE_LIST" ]] && grep -Fq 'xanmod' "$XANMOD_SOURCE_LIST"; then
        return 0
    fi
    return 1
}

build_xanmod_backup_snapshot_paths() {
    local target
    local prefix
    local suffix
    local -a suffixes=(
        initial-backup initial-backup-meta initial-absent initial-unknown
        previous-backup previous-backup-meta previous-absent previous-unknown
    )

    XANMOD_BACKUP_SNAPSHOT_PATHS=()
    for target in "${XANMOD_MANAGED_PATHS[@]}"; do
        prefix=$(get_xanmod_backup_prefix "$target") || return 1
        for suffix in "${suffixes[@]}"; do
            XANMOD_BACKUP_SNAPSHOT_PATHS+=("${prefix}.${suffix}" "${target}.${suffix}")
        done
    done
}

xanmod_backup_state_dir_empty() {
    [[ -d "$XANMOD_BACKUP_STATE_DIR" && ! -L "$XANMOD_BACKUP_STATE_DIR" ]] || return 1
    [[ -z "$(find "$XANMOD_BACKUP_STATE_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]
}

cleanup_new_empty_xanmod_backup_state_dir() {
    if [[ "$XANMOD_BACKUP_STATE_DIR_PREEXISTED" == "true" ]]; then
        return 0
    fi
    if [[ "$XANMOD_BACKUP_STATE_DIR_CREATING" != "true" &&
        "$XANMOD_BACKUP_STATE_DIR_CREATED" != "true" ]]; then
        return 0
    fi
    if [[ ! -e "$XANMOD_BACKUP_STATE_DIR" && ! -L "$XANMOD_BACKUP_STATE_DIR" ]]; then
        XANMOD_BACKUP_STATE_DIR_CREATING=false
        XANMOD_BACKUP_STATE_DIR_CREATED=false
        return 0
    fi
    if ! xanmod_directory_trusted "$XANMOD_BACKUP_STATE_DIR" 700; then
        error "拒绝删除类型、owner 或 mode 不可信的 backup 路径: $XANMOD_BACKUP_STATE_DIR"
        return 1
    fi
    if ! xanmod_backup_state_dir_empty; then
        error "本次新建的 XanMod backup 目录非空，保留路径: $XANMOD_BACKUP_STATE_DIR"
        return 1
    fi
    if ! rmdir "$XANMOD_BACKUP_STATE_DIR"; then
        error "本次新建的空 XanMod backup 目录残留: $XANMOD_BACKUP_STATE_DIR"
        return 1
    fi
    XANMOD_BACKUP_STATE_DIR_CREATING=false
    XANMOD_BACKUP_STATE_DIR_CREATED=false
    XANMOD_BACKUP_STATE_DIR_PREEXISTED=false
}

cleanup_incomplete_xanmod_backup_snapshot() {
    local cleanup_failed=false

    if [[ "$XANMOD_BACKUP_TRANSACTION_ACTIVE" == "true" ]]; then
        error "拒绝把完整 backup 组快照当作不完整快照删除"
        return 1
    fi
    cleanup_xanmod_backup_stage || cleanup_failed=true
    if [[ -n "$XANMOD_BACKUP_GROUP_SNAPSHOT_DIR" ]]; then
        if [[ ! -e "$XANMOD_BACKUP_GROUP_SNAPSHOT_DIR" && ! -L "$XANMOD_BACKUP_GROUP_SNAPSHOT_DIR" ]] ||
            remove_xanmod_temp_directory "$XANMOD_BACKUP_GROUP_SNAPSHOT_DIR" "XanMod 不完整 backup 组快照"; then
            :
        else
            cleanup_failed=true
        fi
    fi
    cleanup_new_empty_xanmod_backup_state_dir || cleanup_failed=true

    if [[ "$cleanup_failed" == "false" ]]; then
        XANMOD_BACKUP_GROUP_SNAPSHOT_DIR=""
        XANMOD_BACKUP_SNAPSHOT_BUILDING=false
        XANMOD_BACKUP_SNAPSHOT_REMOVED=false
        XANMOD_BACKUP_SNAPSHOT_PATHS=()
        XANMOD_BACKUP_NEW_ARCHIVES=()
        return 0
    fi
    return 1
}

create_xanmod_backup_group_snapshot() {
    local index
    local temp_parent="${TMPDIR:-/tmp}"

    if [[ "$XANMOD_BACKUP_TRANSACTION_ACTIVE" == "true" ||
        "$XANMOD_BACKUP_SNAPSHOT_BUILDING" == "true" ||
        "$XANMOD_BACKUP_SNAPSHOT_REMOVED" == "true" ||
        -n "$XANMOD_BACKUP_GROUP_SNAPSHOT_DIR" ]]; then
        error "XanMod backup 快照生命周期尚未结束"
        return 1
    fi
    build_xanmod_backup_snapshot_paths || return 1
    if ! xanmod_allocate_temp_directory XANMOD_BACKUP_GROUP_SNAPSHOT_DIR \
        XANMOD_BACKUP_SNAPSHOT_BUILDING "$temp_parent" xanmod-backup-group 0700; then
        cleanup_incomplete_xanmod_backup_snapshot || true
        return 1
    fi
    for index in "${!XANMOD_BACKUP_SNAPSHOT_PATHS[@]}"; do
        if ! capture_xanmod_snapshot_item \
            "${XANMOD_BACKUP_SNAPSHOT_PATHS[$index]}" \
            "$XANMOD_BACKUP_GROUP_SNAPSHOT_DIR/item-$index"; then
            cleanup_incomplete_xanmod_backup_snapshot || true
            return 1
        fi
    done
    XANMOD_BACKUP_SNAPSHOT_BUILDING=false
    XANMOD_BACKUP_SNAPSHOT_REMOVED=false
    XANMOD_BACKUP_TRANSACTION_ACTIVE=true
}

stage_xanmod_legacy_backup_item() {
    local legacy="$1"
    local staged="$2"

    if [[ -L "$legacy" ]]; then
        readlink "$legacy" > "$staged" || return 1
    else
        cat "$legacy" > "$staged" || return 1
    fi
    set_xanmod_state_file_metadata "$staged"
}

stage_legacy_xanmod_backup_migration() {
    local target
    local suffix
    local legacy
    local staged
    local final
    local archive_index=0
    local -a suffixes=(
        initial-backup initial-backup-meta initial-absent initial-unknown
        previous-backup previous-backup-meta previous-absent previous-unknown
    )

    XANMOD_BACKUP_LEGACY_PATHS=()
    XANMOD_BACKUP_ARCHIVE_STAGED=()
    XANMOD_BACKUP_ARCHIVE_FINAL=()
    for target in "${XANMOD_MANAGED_PATHS[@]}"; do
        for suffix in "${suffixes[@]}"; do
            legacy="${target}.${suffix}"
            xanmod_state_path_exists "$legacy" || continue
            staged="$XANMOD_BACKUP_STAGE_DIR/legacy-$archive_index"
            final="$XANMOD_BACKUP_STATE_DIR/$(basename "$legacy").legacy.$XANMOD_BACKUP_TRANSACTION_ID.$archive_index"
            stage_xanmod_legacy_backup_item "$legacy" "$staged" || return 1
            XANMOD_BACKUP_LEGACY_PATHS+=("$legacy")
            XANMOD_BACKUP_ARCHIVE_STAGED+=("$staged")
            XANMOD_BACKUP_ARCHIVE_FINAL+=("$final")
            ((archive_index += 1))
        done
    done
}

stage_xanmod_initial_state() {
    local target="$1"
    local staged_prefix="$2"
    local active_prefix
    local active_state
    local legacy_state

    active_prefix=$(get_xanmod_backup_prefix "$target") || return 1
    active_state=$(classify_xanmod_state_prefix "$active_prefix" initial true) || return 1
    legacy_state=$(classify_xanmod_state_prefix "$target" initial true) || return 1

    if [[ "$active_state" != "none" ]]; then
        stage_xanmod_state_from_prefix "$active_prefix" initial "$staged_prefix" initial
    elif [[ "$legacy_state" != "none" ]]; then
        stage_xanmod_state_from_prefix "$target" initial "$staged_prefix" initial
    elif [[ "$XANMOD_CONFIGURATION_PREVIOUSLY_MANAGED" == "true" ]]; then
        install -m 0600 /dev/null "${staged_prefix}.initial-unknown" || return 1
        set_xanmod_state_file_metadata "${staged_prefix}.initial-unknown"
    else
        capture_xanmod_persistent_state "$target" "$staged_prefix" initial
    fi
}

commit_xanmod_persistent_state() {
    local target="$1"
    local scope="$2"
    local staged_prefix="$3"
    local final_prefix
    local suffix
    local staged
    local final
    local moved_count=0
    local -a suffixes=(backup backup-meta absent unknown)

    final_prefix=$(get_xanmod_backup_prefix "$target") || return 1
    for suffix in "${suffixes[@]}"; do
        rm -f -- "${final_prefix}.${scope}-${suffix}" || return 1
    done
    for suffix in "${suffixes[@]}"; do
        staged="${staged_prefix}.${scope}-${suffix}"
        final="${final_prefix}.${scope}-${suffix}"
        xanmod_state_path_exists "$staged" || continue
        mv -fT -- "$staged" "$final" || return 1
        ((moved_count += 1))
    done
    (( moved_count > 0 ))
}

commit_xanmod_backup_group() {
    local index
    local target
    local staged_prefix

    XANMOD_BACKUP_NEW_ARCHIVES=()
    for index in "${!XANMOD_BACKUP_ARCHIVE_STAGED[@]}"; do
        mv -fT -- "${XANMOD_BACKUP_ARCHIVE_STAGED[$index]}" \
            "${XANMOD_BACKUP_ARCHIVE_FINAL[$index]}" || return 1
        XANMOD_BACKUP_NEW_ARCHIVES+=("${XANMOD_BACKUP_ARCHIVE_FINAL[$index]}")
    done

    for target in "${XANMOD_MANAGED_PATHS[@]}"; do
        staged_prefix="$XANMOD_BACKUP_STAGE_DIR/$(basename "$target")"
        commit_xanmod_persistent_state "$target" initial "$staged_prefix" || return 1
        commit_xanmod_persistent_state "$target" previous "$staged_prefix" || return 1
    done
    for target in "${XANMOD_BACKUP_LEGACY_PATHS[@]}"; do
        rm -f -- "$target" || return 1
    done
}

cleanup_xanmod_backup_stage() {
    if [[ -z "$XANMOD_BACKUP_STAGE_DIR" ]]; then
        XANMOD_BACKUP_STAGE_BUILDING=false
        return 0
    fi
    if ! remove_xanmod_temp_directory "$XANMOD_BACKUP_STAGE_DIR" "XanMod backup stage"; then
        return 1
    fi
    XANMOD_BACKUP_STAGE_DIR=""
    XANMOD_BACKUP_STAGE_BUILDING=false
}

restore_xanmod_backup_group_snapshot() {
    local index
    local restore_failed=false
    local cleanup_failed=false
    local archive

    [[ "$XANMOD_BACKUP_TRANSACTION_ACTIVE" == "true" ]] || return 0
    if [[ "$XANMOD_BACKUP_SNAPSHOT_REMOVED" != "true" ]]; then
        if [[ -z "$XANMOD_BACKUP_GROUP_SNAPSHOT_DIR" ]] ||
            ! xanmod_directory_trusted "$XANMOD_BACKUP_GROUP_SNAPSHOT_DIR" 700; then
            error "XanMod backup 组快照缺失或不可信，保留事务状态: $XANMOD_BACKUP_GROUP_SNAPSHOT_DIR"
            return 1
        fi
        if ! xanmod_directory_trusted "$XANMOD_BACKUP_STATE_DIR" 700; then
            error "XanMod backup 状态目录缺失或不可信，拒绝以通用 0755 父目录恢复: $XANMOD_BACKUP_STATE_DIR"
            return 1
        fi

        for index in "${!XANMOD_BACKUP_SNAPSHOT_PATHS[@]}"; do
            if ! restore_xanmod_snapshot_item \
                "${XANMOD_BACKUP_SNAPSHOT_PATHS[$index]}" \
                "$XANMOD_BACKUP_GROUP_SNAPSHOT_DIR/item-$index"; then
                error "恢复 XanMod backup 组失败: ${XANMOD_BACKUP_SNAPSHOT_PATHS[$index]}"
                restore_failed=true
            fi
        done
        if [[ "$restore_failed" == "true" ]]; then
            error "XanMod backup 组快照已保留，可在故障解除后重试: $XANMOD_BACKUP_GROUP_SNAPSHOT_DIR"
            return 1
        fi

        for archive in "${XANMOD_BACKUP_NEW_ARCHIVES[@]}"; do
            if ! rm -f -- "$archive"; then
                error "XanMod legacy archive 残留: $archive"
                cleanup_failed=true
            fi
        done
        cleanup_xanmod_backup_stage || cleanup_failed=true
        if [[ "$cleanup_failed" == "true" ]]; then
            error "XanMod backup 组快照已保留，可在清理故障解除后重试: $XANMOD_BACKUP_GROUP_SNAPSHOT_DIR"
            return 1
        fi

        if ! remove_xanmod_temp_directory \
            "$XANMOD_BACKUP_GROUP_SNAPSHOT_DIR" "XanMod backup 组快照"; then
            return 1
        fi
        XANMOD_BACKUP_GROUP_SNAPSHOT_DIR=""
        XANMOD_BACKUP_SNAPSHOT_BUILDING=false
        XANMOD_BACKUP_SNAPSHOT_REMOVED=true
    fi

    if ! cleanup_new_empty_xanmod_backup_state_dir; then
        error "XanMod backup 状态目录清理未完成，可在故障解除后重试: $XANMOD_BACKUP_STATE_DIR"
        return 1
    fi
    XANMOD_BACKUP_TRANSACTION_ACTIVE=false
    XANMOD_BACKUP_SNAPSHOT_REMOVED=false
    XANMOD_BACKUP_STATE_DIR_CREATING=false
    XANMOD_BACKUP_STATE_DIR_CREATED=false
    XANMOD_BACKUP_STATE_DIR_PREEXISTED=false
    XANMOD_BACKUP_SNAPSHOT_PATHS=()
    XANMOD_BACKUP_NEW_ARCHIVES=()
}

discard_xanmod_backup_group_snapshot() {
    cleanup_xanmod_backup_stage || return 1
    if [[ "$XANMOD_BACKUP_SNAPSHOT_REMOVED" == "true" ]]; then
        cleanup_new_empty_xanmod_backup_state_dir || return 1
    elif [[ -n "$XANMOD_BACKUP_GROUP_SNAPSHOT_DIR" ]]; then
        if ! remove_xanmod_temp_directory "$XANMOD_BACKUP_GROUP_SNAPSHOT_DIR" "XanMod backup 组快照"; then
            return 1
        fi
    fi
    XANMOD_BACKUP_GROUP_SNAPSHOT_DIR=""
    XANMOD_BACKUP_SNAPSHOT_BUILDING=false
    XANMOD_BACKUP_SNAPSHOT_REMOVED=false
    XANMOD_BACKUP_TRANSACTION_ACTIVE=false
    XANMOD_BACKUP_STATE_DIR_CREATING=false
    XANMOD_BACKUP_STATE_DIR_CREATED=false
    XANMOD_BACKUP_STATE_DIR_PREEXISTED=false
    XANMOD_BACKUP_SNAPSHOT_PATHS=()
    XANMOD_BACKUP_NEW_ARCHIVES=()
}

prepare_persistent_xanmod_backups() {
    local target
    local staged_prefix

    ensure_xanmod_backup_state_dir || return 1
    validate_xanmod_backup_group_items || return 1
    create_xanmod_backup_group_snapshot || return 1
    XANMOD_BACKUP_TRANSACTION_ID=$(basename "$XANMOD_BACKUP_GROUP_SNAPSHOT_DIR")
    if ! xanmod_allocate_temp_directory XANMOD_BACKUP_STAGE_DIR \
        XANMOD_BACKUP_STAGE_BUILDING "$XANMOD_BACKUP_STATE_DIR" .xanmod-backup-stage 0700; then
        restore_xanmod_backup_group_snapshot || true
        return 1
    fi
    XANMOD_BACKUP_STAGE_BUILDING=false

    if xanmod_configuration_looks_previously_managed; then
        XANMOD_CONFIGURATION_PREVIOUSLY_MANAGED=true
    else
        XANMOD_CONFIGURATION_PREVIOUSLY_MANAGED=false
    fi

    if ! stage_legacy_xanmod_backup_migration; then
        restore_xanmod_backup_group_snapshot || true
        return 1
    fi
    for target in "${XANMOD_MANAGED_PATHS[@]}"; do
        staged_prefix="$XANMOD_BACKUP_STAGE_DIR/$(basename "$target")"
        if ! stage_xanmod_initial_state "$target" "$staged_prefix" ||
            ! capture_xanmod_persistent_state "$target" "$staged_prefix" previous; then
            restore_xanmod_backup_group_snapshot || true
            return 1
        fi
    done
    if ! commit_xanmod_backup_group; then
        restore_xanmod_backup_group_snapshot || true
        return 1
    fi
    discard_xanmod_backup_group_snapshot
}

prepare_xanmod_transaction() {
    prepare_persistent_xanmod_backups
}

abort_pending_xanmod_backup_transaction() {
    if [[ "$XANMOD_BACKUP_TRANSACTION_ACTIVE" == "true" ]]; then
        restore_xanmod_backup_group_snapshot
    elif [[ "$XANMOD_BACKUP_SNAPSHOT_BUILDING" == "true" ||
        -n "$XANMOD_BACKUP_GROUP_SNAPSHOT_DIR" ||
        -n "$XANMOD_BACKUP_STAGE_DIR" ]]; then
        cleanup_incomplete_xanmod_backup_snapshot
    elif [[ "$XANMOD_BACKUP_STATE_DIR_CREATING" == "true" ||
        "$XANMOD_BACKUP_STATE_DIR_CREATED" == "true" ]]; then
        cleanup_new_empty_xanmod_backup_state_dir
    fi
}

classify_xanmod_persistent_state() {
    local target="$1"
    local scope="$2"
    local prefix
    local state_type

    prefix=$(get_xanmod_backup_prefix "$target") || return 1
    state_type=$(classify_xanmod_state_prefix "$prefix" "$scope" "$( [[ "$scope" == initial ]] && echo true || echo false )") || return 1
    case "$state_type" in
        none|unknown) return 2 ;;
        backup-new|backup-legacy) printf 'backup\n' ;;
        absent) printf 'absent\n' ;;
        *) return 1 ;;
    esac
}

restore_xanmod_persistent_item() {
    local target="$1"
    local scope="$2"
    local state_type="$3"
    local prefix
    local backup
    local metadata_file
    local staged=""
    local metadata_values=""
    local backup_type=""
    local original_uid=""
    local original_gid=""
    local original_mode=""
    local link_target=""

    prefix=$(get_xanmod_backup_prefix "$target") || return 1
    backup="${prefix}.${scope}-backup"
    metadata_file="${prefix}.${scope}-backup-meta"

    if [[ -d "$target" && ! -L "$target" ]]; then
        error "拒绝用备份文件覆盖目录: $target"
        return 1
    fi
    case "$state_type" in
        absent)
            rm -f -- "$target"
            ;;
        backup)
            make_xanmod_stage_file XANMOD_RESTORE_STAGE "$target" .restore || return 1
            staged="$XANMOD_RESTORE_STAGE"
            if ! remove_xanmod_temp_file "$staged" "XanMod restore stage"; then
                return 1
            fi
            if xanmod_state_path_exists "$metadata_file"; then
                metadata_values=$(xanmod_backup_metadata_values "$metadata_file") || return 1
                read -r backup_type original_uid original_gid original_mode <<< "$metadata_values"
                if [[ "$backup_type" == file ]]; then
                    if ! cat "$backup" > "$staged"; then
                        remove_xanmod_temp_file "$staged" "XanMod restore stage" || true
                        return 1
                    fi
                    if [[ "${XANMOD_TEST_MODE:-0}" == "1" ]]; then
                        if [[ "$original_uid" != "$XANMOD_TRUSTED_UID" ||
                            "$original_gid" != "$XANMOD_TRUSTED_GID" ]] ||
                            ! chgrp "$original_gid" "$staged"; then
                            remove_xanmod_temp_file "$staged" "XanMod restore stage" || true
                            return 1
                        fi
                    elif ! chown "$original_uid:$original_gid" "$staged"; then
                        remove_xanmod_temp_file "$staged" "XanMod restore stage" || true
                        return 1
                    fi
                    if ! chmod "$original_mode" "$staged"; then
                        remove_xanmod_temp_file "$staged" "XanMod restore stage" || true
                        return 1
                    fi
                else
                    link_target=$(<"$backup")
                    if [[ -z "$link_target" ]] || ! ln -s "$link_target" "$staged"; then
                        remove_xanmod_temp_file "$staged" "XanMod restore stage" || true
                        return 1
                    fi
                    if [[ "${XANMOD_TEST_MODE:-0}" == "1" ]]; then
                        if [[ "$original_uid" != "$XANMOD_TRUSTED_UID" ||
                            "$original_gid" != "$XANMOD_TRUSTED_GID" ]]; then
                            remove_xanmod_temp_file "$staged" "XanMod restore stage" || true
                            return 1
                        fi
                    elif ! chown -h "$original_uid:$original_gid" "$staged"; then
                        remove_xanmod_temp_file "$staged" "XanMod restore stage" || true
                        return 1
                    fi
                fi
            elif ! cp -a -- "$backup" "$staged"; then
                remove_xanmod_temp_file "$staged" "XanMod restore stage" || true
                return 1
            fi
            if ! mv -fT -- "$staged" "$target"; then
                remove_xanmod_temp_file "$staged" "XanMod restore stage" || true
                return 1
            fi
            XANMOD_RESTORE_STAGE=""
            ;;
        *)
            return 1
            ;;
    esac
}

restore_xanmod_group() {
    local scope="$1"
    local target
    local state_type
    local state_status=0
    local index
    local apply_failed=false
    local -a state_types=()

    XANMOD_RESTORED_COUNT=0
    ensure_xanmod_backup_state_dir || return 1
    validate_xanmod_backup_group_items || return 1

    for target in "${XANMOD_MANAGED_PATHS[@]}"; do
        state_status=0
        state_type=$(classify_xanmod_persistent_state "$target" "$scope") || state_status=$?
        case "$state_status" in
            0) state_types+=("$state_type") ;;
            2)
                warn "XanMod $scope 组状态缺失或未知，不进行部分恢复"
                return 2
                ;;
            *)
                error "XanMod $scope 组备份状态不可信，不进行部分恢复"
                return 1
                ;;
        esac
    done

    XANMOD_APT_MAY_BE_PARTIAL=false
    install_xanmod_transaction_guards || return 1
    if ! create_xanmod_runtime_snapshot; then
        clear_xanmod_transaction_guards
        return 1
    fi
    XANMOD_CONFIG_MODIFIED=true
    for index in "${!XANMOD_MANAGED_PATHS[@]}"; do
        if ! restore_xanmod_persistent_item \
            "${XANMOD_MANAGED_PATHS[$index]}" "$scope" "${state_types[$index]}"; then
            error "恢复 XanMod 配置失败: ${XANMOD_MANAGED_PATHS[$index]}"
            apply_failed=true
            break
        fi
    done

    if [[ "$apply_failed" == "true" ]]; then
        abort_xanmod_install_transaction || true
        return 1
    fi
    if ! complete_xanmod_install_transaction; then
        return 1
    fi

    XANMOD_RESTORED_COUNT=${#XANMOD_MANAGED_PATHS[@]}
    if ! apt-get update -qq; then
        warn "XanMod 软件源配置已恢复，但 APT 索引更新失败；已保留请求恢复的配置"
        return 1
    fi
}

restore_xanmod_saved_trap() {
    local signal_name="$1"
    local trap_definition="$2"

    trap - "$signal_name"
    if [[ -n "$trap_definition" ]]; then
        # shellcheck disable=SC2294
        eval "$trap_definition"
    fi
}

install_xanmod_transaction_guards() {
    if [[ "$XANMOD_GUARD_ACTIVE" == "true" ]]; then
        error "XanMod 事务保护已经启用"
        return 1
    fi

    XANMOD_SAVED_TRAP_EXIT=$(trap -p EXIT || true)
    XANMOD_SAVED_TRAP_HUP=$(trap -p HUP || true)
    XANMOD_SAVED_TRAP_INT=$(trap -p INT || true)
    XANMOD_SAVED_TRAP_TERM=$(trap -p TERM || true)
    XANMOD_GUARD_ACTIVE=true
    XANMOD_GUARD_HANDLING=false
    trap 'xanmod_transaction_exit_handler $?' EXIT
    trap 'xanmod_transaction_signal_handler HUP 129' HUP
    trap 'xanmod_transaction_signal_handler INT 130' INT
    trap 'xanmod_transaction_signal_handler TERM 143' TERM
}

clear_xanmod_transaction_guards() {
    local saved_exit="$XANMOD_SAVED_TRAP_EXIT"
    local saved_hup="$XANMOD_SAVED_TRAP_HUP"
    local saved_int="$XANMOD_SAVED_TRAP_INT"
    local saved_term="$XANMOD_SAVED_TRAP_TERM"

    trap - EXIT HUP INT TERM
    XANMOD_GUARD_ACTIVE=false
    XANMOD_GUARD_HANDLING=false
    XANMOD_SAVED_TRAP_EXIT=""
    XANMOD_SAVED_TRAP_HUP=""
    XANMOD_SAVED_TRAP_INT=""
    XANMOD_SAVED_TRAP_TERM=""
    restore_xanmod_saved_trap EXIT "$saved_exit"
    restore_xanmod_saved_trap HUP "$saved_hup"
    restore_xanmod_saved_trap INT "$saved_int"
    restore_xanmod_saved_trap TERM "$saved_term"
}

warn_xanmod_partial_install() {
    warn "APT 可能已部分安装内核包；为避免误删可启动内核，脚本不会自动卸载任何包"
    warn "请检查: dpkg --audit；必要时执行 apt-get -f install，并确认引导菜单中的可用内核"
}

cleanup_xanmod_transaction_state() {
    local cleanup_failed=false

    cleanup_xanmod_pending_allocation || cleanup_failed=true
    cleanup_xanmod_stages || cleanup_failed=true
    cleanup_xanmod_active_apt_lists || cleanup_failed=true
    abort_pending_xanmod_backup_transaction || cleanup_failed=true
    if [[ "$XANMOD_RUNTIME_SNAPSHOT_BUILDING" == "true" ||
        ( -n "$XANMOD_RUNTIME_SNAPSHOT_DIR" && "$XANMOD_TRANSACTION_ACTIVE" != "true" ) ]]; then
        cleanup_incomplete_xanmod_runtime_snapshot || cleanup_failed=true
    fi
    if [[ "$XANMOD_TRANSACTION_ACTIVE" == "true" ]]; then
        if [[ "$XANMOD_CONFIG_MODIFIED" == "true" ]]; then
            restore_xanmod_runtime_snapshot || cleanup_failed=true
        else
            discard_xanmod_runtime_snapshot || cleanup_failed=true
        fi
    fi
    if [[ "$XANMOD_APT_MAY_BE_PARTIAL" == "true" ]]; then
        warn_xanmod_partial_install
        XANMOD_APT_MAY_BE_PARTIAL=false
    fi

    [[ "$cleanup_failed" == "false" ]]
}

xanmod_transaction_signal_handler() {
    local signal_name="$1"
    local exit_status="$2"
    local saved_exit="$XANMOD_SAVED_TRAP_EXIT"

    if [[ "$XANMOD_GUARD_HANDLING" == "true" ]]; then
        exit "$exit_status"
    fi
    XANMOD_GUARD_HANDLING=true
    trap - EXIT
    trap '' HUP INT TERM
    error "收到 $signal_name，正在回滚 XanMod 事务"
    cleanup_xanmod_transaction_state || true
    XANMOD_GUARD_ACTIVE=false
    restore_xanmod_saved_trap EXIT "$saved_exit"
    exit "$exit_status"
}

xanmod_transaction_exit_handler() {
    local exit_status="$1"
    local saved_exit="$XANMOD_SAVED_TRAP_EXIT"

    if [[ "$XANMOD_GUARD_ACTIVE" != "true" || "$XANMOD_GUARD_HANDLING" == "true" ]]; then
        return
    fi
    XANMOD_GUARD_HANDLING=true
    trap - EXIT
    trap '' HUP INT TERM
    error "XanMod 事务异常退出，正在恢复运行前状态"
    cleanup_xanmod_transaction_state || true
    XANMOD_GUARD_ACTIVE=false
    if (( exit_status == 0 )); then
        exit_status=1
    fi
    restore_xanmod_saved_trap EXIT "$saved_exit"
    exit "$exit_status"
}

begin_xanmod_install_transaction() {
    XANMOD_APT_MAY_BE_PARTIAL=false
    XANMOD_CONFIG_MODIFIED=false
    install_xanmod_transaction_guards || return 1
    if ! prepare_xanmod_transaction; then
        abort_pending_xanmod_backup_transaction || true
        clear_xanmod_transaction_guards
        return 1
    fi
    if ! create_xanmod_runtime_snapshot; then
        cleanup_xanmod_transaction_state || true
        clear_xanmod_transaction_guards
        return 1
    fi
}

make_xanmod_stage_file() {
    local path_variable="$1"
    local target="$2"
    local suffix="$3"
    local target_dir
    local prefix

    target_dir=$(dirname "$target") || return 1
    install -d -m 0755 "$target_dir" || return 1
    prefix=".xanmod-stage.$(basename "$target")"
    xanmod_allocate_temp_file "$path_variable" "$target_dir" "$prefix" "$suffix" 0600
}

cleanup_xanmod_stages() {
    local cleanup_failed=false

    if [[ -n "$XANMOD_STAGED_KEY" ]]; then
        if [[ ! -e "$XANMOD_STAGED_KEY" && ! -L "$XANMOD_STAGED_KEY" ]] ||
            remove_xanmod_temp_file "$XANMOD_STAGED_KEY" "XanMod staged key"; then
            XANMOD_STAGED_KEY=""
        else
            cleanup_failed=true
        fi
    fi
    if [[ -n "$XANMOD_STAGED_SOURCE" ]]; then
        if [[ ! -e "$XANMOD_STAGED_SOURCE" && ! -L "$XANMOD_STAGED_SOURCE" ]] ||
            remove_xanmod_temp_file "$XANMOD_STAGED_SOURCE" "XanMod staged source"; then
            XANMOD_STAGED_SOURCE=""
        else
            cleanup_failed=true
        fi
    fi
    if [[ -n "$XANMOD_CANDIDATE_SOURCE" ]]; then
        if [[ ! -e "$XANMOD_CANDIDATE_SOURCE" && ! -L "$XANMOD_CANDIDATE_SOURCE" ]] ||
            remove_xanmod_temp_file "$XANMOD_CANDIDATE_SOURCE" "XanMod candidate source"; then
            XANMOD_CANDIDATE_SOURCE=""
        else
            cleanup_failed=true
        fi
    fi
    if [[ -n "$XANMOD_ARMORED_KEY_TEMP" ]]; then
        if [[ ! -e "$XANMOD_ARMORED_KEY_TEMP" && ! -L "$XANMOD_ARMORED_KEY_TEMP" ]] ||
            remove_xanmod_temp_file "$XANMOD_ARMORED_KEY_TEMP" "XanMod armored key"; then
            XANMOD_ARMORED_KEY_TEMP=""
        else
            cleanup_failed=true
        fi
    fi
    if [[ -n "$XANMOD_RESTORE_STAGE" ]]; then
        if [[ ! -e "$XANMOD_RESTORE_STAGE" && ! -L "$XANMOD_RESTORE_STAGE" ]] ||
            remove_xanmod_temp_file "$XANMOD_RESTORE_STAGE" "XanMod restore stage"; then
            XANMOD_RESTORE_STAGE=""
        else
            cleanup_failed=true
        fi
    fi

    [[ "$cleanup_failed" == "false" ]]
}

stage_xanmod_key() {
    local key_url

    make_xanmod_stage_file XANMOD_STAGED_KEY "$XANMOD_KEYRING" .gpg || return 1

    if xanmod_keyring_valid "$XANMOD_KEYRING"; then
        if install -m 0600 "$XANMOD_KEYRING" "$XANMOD_STAGED_KEY" &&
            set_xanmod_staged_file_metadata "$XANMOD_STAGED_KEY" &&
            xanmod_keyring_valid "$XANMOD_STAGED_KEY"; then
            return 0
        fi
        cleanup_xanmod_stages || true
        return 1
    fi

    if [[ -e "$XANMOD_KEYRING" || -L "$XANMOD_KEYRING" ]]; then
        warn "现有 XanMod 密钥不满足严格内容校验，将重新获取"
    fi

    if ! xanmod_allocate_temp_file XANMOD_ARMORED_KEY_TEMP \
        "${TMPDIR:-/tmp}" xanmod-key .asc 0600; then
        cleanup_xanmod_stages || true
        return 1
    fi

    for key_url in "$XANMOD_KEY_URL" "$XANMOD_KEY_FALLBACK_UBUNTU"; do
        info "下载 XanMod 软件源签名密钥: $key_url"
        if ! : > "$XANMOD_ARMORED_KEY_TEMP" ||
            ! curl -fsSL --connect-timeout 10 --max-time 30 \
                "$key_url" -o "$XANMOD_ARMORED_KEY_TEMP"; then
            warn "该密钥来源下载失败，尝试下一个来源"
            continue
        fi
        if ! xanmod_keyring_valid "$XANMOD_ARMORED_KEY_TEMP"; then
            warn "该密钥来源未通过严格主密钥指纹与 UID 校验，尝试下一个来源"
            continue
        fi

        remove_xanmod_temp_file "$XANMOD_STAGED_KEY" "XanMod staged key" || break
        if ! gpg --batch --yes --dearmor --output "$XANMOD_STAGED_KEY" "$XANMOD_ARMORED_KEY_TEMP"; then
            warn "XanMod 签名密钥转换失败，尝试下一个来源"
            remove_xanmod_temp_file "$XANMOD_STAGED_KEY" "XanMod staged key" || break
            make_xanmod_stage_file XANMOD_STAGED_KEY "$XANMOD_KEYRING" .gpg || break
            continue
        fi
        if ! set_xanmod_staged_file_metadata "$XANMOD_STAGED_KEY"; then
            break
        fi
        if xanmod_keyring_valid "$XANMOD_STAGED_KEY"; then
            if ! remove_xanmod_temp_file "$XANMOD_ARMORED_KEY_TEMP" "XanMod armored key"; then
                cleanup_xanmod_stages || true
                return 1
            fi
            XANMOD_ARMORED_KEY_TEMP=""
            return 0
        fi

        warn "转换后的 XanMod 密钥未通过严格校验，尝试下一个来源"
        remove_xanmod_temp_file "$XANMOD_STAGED_KEY" "XanMod staged key" || break
        make_xanmod_stage_file XANMOD_STAGED_KEY "$XANMOD_KEYRING" .gpg || break
    done

    cleanup_xanmod_stages || true
    error "无法获得指纹为 $XANMOD_KEY_FINGERPRINT 且 UID 匹配的 XanMod 签名密钥"
    return 1
}

stage_xanmod_source() {
    local codename="$1"
    local repository
    local source_status=0

    make_xanmod_stage_file XANMOD_CANDIDATE_SOURCE "$XANMOD_SOURCE_DEB822" .sources || return 1
    XANMOD_SELECTED_REPOSITORY=""

    for repository in "${XANMOD_REPOSITORIES[@]}"; do
        info "探测 XanMod 软件源: $repository"
        if ! write_xanmod_deb822_source \
            "$XANMOD_CANDIDATE_SOURCE" "$repository" "$codename" "$XANMOD_STAGED_KEY" ||
            ! set_xanmod_staged_file_metadata "$XANMOD_CANDIDATE_SOURCE"; then
            cleanup_xanmod_stages || true
            return 1
        fi

        source_status=0
        xanmod_source_is_usable "$XANMOD_CANDIDATE_SOURCE" || source_status=$?
        if (( source_status == 0 )); then
            XANMOD_SELECTED_REPOSITORY="$repository"
            break
        fi
        if (( source_status == 125 )); then
            cleanup_xanmod_stages || true
            return 1
        fi
        warn "XanMod 软件源不可用: $repository"
    done

    if ! remove_xanmod_temp_file "$XANMOD_CANDIDATE_SOURCE" "XanMod candidate source"; then
        return 1
    fi
    XANMOD_CANDIDATE_SOURCE=""
    if [[ -z "$XANMOD_SELECTED_REPOSITORY" ]]; then
        error "所有 XanMod 软件源均不可用，未修改正式 APT 配置"
        return 1
    fi

    make_xanmod_stage_file XANMOD_STAGED_SOURCE "$XANMOD_SOURCE_DEB822" .sources || return 1
    write_xanmod_deb822_source \
        "$XANMOD_STAGED_SOURCE" "$XANMOD_SELECTED_REPOSITORY" "$codename" "$XANMOD_KEYRING" || return 1
    set_xanmod_staged_file_metadata "$XANMOD_STAGED_SOURCE"
}

xanmod_repository_files_ready() {
    local codename="$1"

    xanmod_deb822_source_configured &&
        [[ ! -e "$XANMOD_SOURCE_LIST" && ! -L "$XANMOD_SOURCE_LIST" ]] &&
        xanmod_source_matches_codename "$XANMOD_SOURCE_DEB822" "$codename"
}

xanmod_repository_ready() {
    local codename="$1"

    xanmod_repository_files_ready "$codename" || return 1
    xanmod_source_is_usable "$XANMOD_SOURCE_DEB822"
}

xanmod_after_formal_commit_hook() {
    :
}

configure_xanmod_repository() {
    local codename="$1"
    local ready_status=0
    local formal_status=0

    [[ "$XANMOD_TRANSACTION_ACTIVE" == "true" ]] || {
        error "拒绝在事务外修改 XanMod 配置"
        return 1
    }

    ensure_package "gpg" "gpg" || return 1
    install -d -m 0755 "$(dirname "$XANMOD_KEYRING")" || return 1
    install -d -m 0755 "$(dirname "$XANMOD_SOURCE_DEB822")" || return 1

    xanmod_repository_ready "$codename" || ready_status=$?
    if (( ready_status == 0 )); then
        echo "XanMod 软件源: 已配置并可用（$XANMOD_SOURCE_DEB822）"
        return 0
    fi
    if (( ready_status == 125 )); then
        return 1
    fi

    warn "现有 XanMod 软件源缺失、不安全、不匹配或不可用，将事务式重新配置"
    stage_xanmod_key || return 1
    if ! stage_xanmod_source "$codename"; then
        cleanup_xanmod_stages || true
        return 1
    fi
    xanmod_regular_file_trusted "$XANMOD_STAGED_KEY" 644 || return 1
    xanmod_regular_file_trusted "$XANMOD_STAGED_SOURCE" 644 || return 1

    XANMOD_CONFIG_MODIFIED=true
    if ! mv -fT -- "$XANMOD_STAGED_KEY" "$XANMOD_KEYRING"; then
        cleanup_xanmod_stages || true
        return 1
    fi
    XANMOD_STAGED_KEY=""

    if ! mv -fT -- "$XANMOD_STAGED_SOURCE" "$XANMOD_SOURCE_DEB822"; then
        cleanup_xanmod_stages || true
        return 1
    fi
    XANMOD_STAGED_SOURCE=""

    rm -f -- "$XANMOD_SOURCE_LIST" || return 1
    xanmod_after_formal_commit_hook || return 1

    if ! xanmod_formal_keyring_valid ||
        ! xanmod_deb822_source_configured ||
        ! xanmod_source_matches_codename "$XANMOD_SOURCE_DEB822" "$codename"; then
        error "正式 XanMod 文件未通过内容、owner 或 mode 校验"
        return 1
    fi
    xanmod_source_is_usable "$XANMOD_SOURCE_DEB822" || formal_status=$?
    if (( formal_status != 0 )); then
        if (( formal_status != 125 )); then
            error "正式 XanMod 软件源未通过隔离 APT 验证"
        fi
        return 1
    fi

    echo "XanMod 软件源: 已配置（Deb822 / $codename / $XANMOD_SELECTED_REPOSITORY）"
}
get_installed_xanmod_packages() {
    dpkg-query -W -f='${binary:Package} ${db:Status-Status}\n' \
        "linux-xanmod-*" 2>/dev/null |
        awk '$2 == "installed" { sub(/:amd64$/, "", $1); print $1 }' |
        sort -u
}

reset_xanmod_plan() {
    XANMOD_PLAN_ACTION=""
    XANMOD_PLAN_REASON=""
    XANMOD_PLAN_CODENAME=""
    XANMOD_PLAN_PSABI=""
    XANMOD_PLAN_TARGET_PACKAGE=""
    XANMOD_PLAN_INSTALLED_PACKAGES=""
    XANMOD_PLAN_PACKAGE_INSTALLED=false
    XANMOD_PLAN_REPOSITORY_READY=false
    XANMOD_PLAN_NEEDS_REPOSITORY_CHANGE=false
    XANMOD_PLAN_NEEDS_PACKAGE_INSTALL=false
}

resolve_xanmod_plan() {
    local detect_status=0

    reset_xanmod_plan
    XANMOD_PLAN_CODENAME=$(get_os_codename || true)
    if [[ -z "$XANMOD_PLAN_CODENAME" ]]; then
        XANMOD_PLAN_ACTION="skip"
        XANMOD_PLAN_REASON="无法识别系统发行版代号"
        return 0
    fi
    if ! xanmod_codename_safe "$XANMOD_PLAN_CODENAME" ||
        ! xanmod_codename_supported "$XANMOD_PLAN_CODENAME"; then
        XANMOD_PLAN_ACTION="skip"
        XANMOD_PLAN_REASON="当前入口不支持发行版代号 $XANMOD_PLAN_CODENAME"
        return 0
    fi
    if ! is_amd64; then
        XANMOD_PLAN_ACTION="skip"
        XANMOD_PLAN_REASON="当前架构不是受支持的 amd64/x86_64"
        return 0
    fi

    detect_status=0
    XANMOD_PLAN_TARGET_PACKAGE=$(detect_xanmod_package) || detect_status=$?
    case "$detect_status" in
        0)
            XANMOD_PLAN_PSABI=$(detect_x86_64_psabi_level || true)
            ;;
        2)
            XANMOD_PLAN_ACTION="skip"
            XANMOD_PLAN_PSABI="v1"
            XANMOD_PLAN_REASON="当前 CPU 仅达到 x86-64-v1，XanMod MAIN 至少需要 x86-64-v2"
            return 0
            ;;
        3)
            XANMOD_PLAN_TARGET_PACKAGE=$(get_running_xanmod_package || true)
            if [[ -z "$XANMOD_PLAN_TARGET_PACKAGE" ]]; then
                XANMOD_PLAN_ACTION="skip"
                XANMOD_PLAN_REASON="无法读取 CPU 指令集，且当前没有可作为兼容性证据的 XanMod 分支"
                return 0
            fi
            XANMOD_PLAN_PSABI="unknown-running-compatible"
            ;;
        *)
            XANMOD_PLAN_ACTION="skip"
            XANMOD_PLAN_REASON="无法确认适用的 XanMod 内核包"
            return 0
            ;;
    esac

    XANMOD_PLAN_INSTALLED_PACKAGES=$(get_installed_xanmod_packages || true)
    if package_is_installed "$XANMOD_PLAN_TARGET_PACKAGE"; then
        XANMOD_PLAN_PACKAGE_INSTALLED=true
    fi
    if xanmod_repository_files_ready "$XANMOD_PLAN_CODENAME"; then
        XANMOD_PLAN_REPOSITORY_READY=true
    fi

    if [[ "$XANMOD_PLAN_PACKAGE_INSTALLED" == "true" &&
        "$XANMOD_PLAN_REPOSITORY_READY" == "true" ]]; then
        XANMOD_PLAN_ACTION="noop"
        XANMOD_PLAN_REASON="目标包已安装，正式 XanMod 仓库文件严格安全有效"
        return 0
    fi

    XANMOD_PLAN_ACTION="modify"
    if [[ "$XANMOD_PLAN_REPOSITORY_READY" != "true" ]]; then
        XANMOD_PLAN_NEEDS_REPOSITORY_CHANGE=true
    fi
    if [[ "$XANMOD_PLAN_PACKAGE_INSTALLED" != "true" ]]; then
        XANMOD_PLAN_NEEDS_PACKAGE_INSTALL=true
    fi
}

show_xanmod_plan_result() {
    case "$XANMOD_PLAN_ACTION" in
        skip)
            warn "$XANMOD_PLAN_REASON，已安全跳过 XanMod"
            ;;
        noop)
            echo "XanMod: 无需修改（$XANMOD_PLAN_REASON）"
            ;;
        modify)
            echo "XanMod 修改计划："
            echo "  发行版代号: $XANMOD_PLAN_CODENAME"
            echo "  目标包: $XANMOD_PLAN_TARGET_PACKAGE"
            case "$XANMOD_PLAN_PSABI" in
                unknown-running-compatible) echo "  CPU psABI: 无法读取；沿用当前运行分支" ;;
                "") ;;
                *) echo "  CPU psABI: x86-64-$XANMOD_PLAN_PSABI" ;;
            esac
            if [[ "$XANMOD_PLAN_NEEDS_REPOSITORY_CHANGE" == "true" ]]; then
                echo "  APT 配置: 需要事务式重新生成 key/list/source"
            else
                echo "  APT 配置: 正式文件严格安全；安装前仍会隔离验证可用性"
            fi
            if [[ "$XANMOD_PLAN_NEEDS_PACKAGE_INSTALL" == "true" ]]; then
                echo "  内核包: 需要安装；系统原内核和其他 XanMod 分支会保留"
            else
                echo "  内核包: 已安装，仅修复正式仓库文件"
            fi
            ;;
    esac
}

abort_xanmod_install_transaction() {
    local config_was_modified="$XANMOD_CONFIG_MODIFIED"

    XANMOD_GUARD_HANDLING=true
    trap - EXIT
    trap '' HUP INT TERM
    cleanup_xanmod_transaction_state || true
    clear_xanmod_transaction_guards
    if [[ "$config_was_modified" == "true" && "$XANMOD_CONFIG_MODIFIED" == "false" ]]; then
        warn "XanMod APT 配置已恢复到本次运行前状态"
    elif [[ "$config_was_modified" == "true" ]]; then
        error "XanMod APT 配置回滚不完整，请立即人工检查三个受管文件"
    fi
    return 1
}

complete_xanmod_install_transaction() {
    local cleanup_failed=false

    XANMOD_GUARD_HANDLING=true
    trap - EXIT
    trap '' HUP INT TERM
    cleanup_xanmod_stages || cleanup_failed=true
    cleanup_xanmod_active_apt_lists || cleanup_failed=true
    abort_pending_xanmod_backup_transaction || cleanup_failed=true
    XANMOD_CONFIG_MODIFIED=false
    XANMOD_APT_MAY_BE_PARTIAL=false
    clear_xanmod_transaction_guards
    discard_xanmod_runtime_snapshot || cleanup_failed=true

    [[ "$cleanup_failed" == "false" ]]
}

install_xanmod() {
    local policy_output=""
    local candidate_version=""

    [[ "$XANMOD_PLAN_ACTION" == "modify" ]] || {
        error "没有可执行的 XanMod 修改计划"
        return 1
    }

    echo "检测到适合当前环境的 XanMod 包: $XANMOD_PLAN_TARGET_PACKAGE"
    if [[ -n "$XANMOD_PLAN_INSTALLED_PACKAGES" &&
        "$XANMOD_PLAN_PACKAGE_INSTALLED" != "true" ]]; then
        warn "已安装的 XanMod 包与 CPU 检测结果不匹配: $(tr '\n' ' ' <<< "$XANMOD_PLAN_INSTALLED_PACKAGES")"
        warn "将安装检测到的正确版本: $XANMOD_PLAN_TARGET_PACKAGE"
        echo "说明: 旧 XanMod 包将保留，确认新内核可正常启动后再手动清理。"
    fi

    if ! begin_xanmod_install_transaction; then
        error "无法建立 XanMod 安装事务"
        return 1
    fi

    if ! configure_xanmod_repository "$XANMOD_PLAN_CODENAME"; then
        error "XanMod 软件源配置失败"
        abort_xanmod_install_transaction || true
        return 1
    fi

    if package_is_installed "$XANMOD_PLAN_TARGET_PACKAGE"; then
        if ! complete_xanmod_install_transaction; then
            error "XanMod 配置已提交，但临时事务状态清理失败"
            return 1
        fi
        echo "XanMod 目标包: 已安装（$XANMOD_PLAN_TARGET_PACKAGE）"
        return 0
    fi

    info "更新软件包索引..."
    if ! apt-get update; then
        error "XanMod 软件源索引更新失败"
        abort_xanmod_install_transaction || true
        return 1
    fi

    if ! policy_output=$(apt-cache policy "$XANMOD_PLAN_TARGET_PACKAGE"); then
        error "无法查询 XanMod 候选版本"
        abort_xanmod_install_transaction || true
        return 1
    fi
    candidate_version=$(awk '/Candidate:/ {print $2; exit}' <<< "$policy_output")
    if [[ -z "$candidate_version" || "$candidate_version" == "(none)" ]]; then
        error "XanMod 软件源没有可安装的 $XANMOD_PLAN_TARGET_PACKAGE 候选版本"
        abort_xanmod_install_transaction || true
        return 1
    fi

    info "安装 XanMod 内核包: $XANMOD_PLAN_TARGET_PACKAGE（$candidate_version）"
    XANMOD_APT_MAY_BE_PARTIAL=true
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y "$XANMOD_PLAN_TARGET_PACKAGE"; then
        error "XanMod 内核安装失败"
        abort_xanmod_install_transaction || true
        return 1
    fi
    if ! package_is_installed "$XANMOD_PLAN_TARGET_PACKAGE"; then
        error "XanMod 内核安装后验证失败"
        abort_xanmod_install_transaction || true
        return 1
    fi

    if ! complete_xanmod_install_transaction; then
        error "XanMod 已安装，但临时事务状态清理失败"
        return 1
    fi
    success "XanMod 内核已安装: $XANMOD_PLAN_TARGET_PACKAGE"
    echo "当前运行内核: $(uname -r)"
    echo "说明: 系统原内核未被移除；XanMod 将在下次系统重启后生效。"
}

show_xanmod_status() {
    local psabi_level=""
    local recommended_package=""
    local running_package=""
    local source_file=""
    local installed_packages=""
    local codename=""
    local repository_supported=true

    codename=$(get_os_codename || true)
    if [[ -z "$codename" ]] || ! xanmod_codename_safe "$codename" ||
        ! xanmod_codename_supported "$codename"; then
        repository_supported=false
    fi

    echo
    echo "XanMod 状态："
    echo "  当前架构: $(dpkg --print-architecture) / $(uname -m)"
    echo "  当前内核: $(uname -r)"

    if psabi_level=$(detect_x86_64_psabi_level); then
        echo "  CPU psABI: x86-64-$psabi_level"
        recommended_package=$(get_xanmod_package_for_psabi_level "$psabi_level" || true)
    else
        case $? in
            2) echo "  CPU psABI: x86-64-v1（MAIN 不支持）" ;;
            *) echo "  CPU psABI: 无法确认" ;;
        esac
    fi

    running_package=$(get_running_xanmod_package || true)
    if [[ -n "$running_package" ]]; then
        echo "  当前运行包: $running_package"
    else
        echo "  当前运行包: 无（当前为非 XanMod 内核）"
    fi

    if [[ "$repository_supported" != "true" ]]; then
        echo "  推荐包: 不适用（当前入口不支持 ${codename:-当前发行版}）"
        echo "  软件源: 不适用"
    else
        if [[ -n "$recommended_package" ]]; then
            echo "  推荐包: $recommended_package"
        elif [[ -n "$running_package" ]]; then
            echo "  推荐包: 无法检测；当前运行包可作为兼容性证据"
        else
            echo "  推荐包: 无"
        fi

        if source_file=$(get_xanmod_source_file); then
            case "$source_file" in
                *.sources) echo "  软件源: 已配置（Deb822，owner/mode 安全）" ;;
                *) echo "  软件源: 已配置（传统 list，owner/mode 安全）" ;;
            esac
            echo "  软件源文件: $source_file"
        else
            echo "  软件源: 未配置，或内容/owner/mode 未通过校验"
        fi
    fi

    installed_packages=$(get_installed_xanmod_packages || true)
    if [[ -n "$installed_packages" ]]; then
        echo "  已安装包: $(tr '\n' ' ' <<< "$installed_packages")"
    else
        echo "  已安装包: 无"
    fi
}

xanmod_lock_file_trusted() {
    local metadata=""
    local owner=""
    local group=""
    local mode=""
    local mode_value=0

    [[ -f "$XANMOD_LOCK" && ! -L "$XANMOD_LOCK" ]] || return 1
    metadata=$(stat -c '%u:%g:%a' -- "$XANMOD_LOCK") || return 1
    IFS=: read -r owner group mode <<< "$metadata"
    [[ "$owner" == "$XANMOD_TRUSTED_UID" && "$group" == "$XANMOD_TRUSTED_GID" ]] || return 1
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    mode_value=$((8#$mode))
    (( (mode_value & 0022) == 0 ))
}

take_xanmod_lock() {
    install -d -m 0755 "$(dirname "$XANMOD_LOCK")" || return 1
    if [[ ! -e "$XANMOD_LOCK" && ! -L "$XANMOD_LOCK" ]]; then
        install -m 0600 /dev/null "$XANMOD_LOCK" || return 1
    fi
    if ! xanmod_lock_file_trusted; then
        error "XanMod 锁文件类型、owner 或权限不可信: $XANMOD_LOCK"
        return 1
    fi

    exec 9>> "$XANMOD_LOCK"
    if ! xanmod_lock_file_trusted; then
        exec 9>&-
        error "XanMod 锁文件在打开时发生变化"
        return 1
    fi
    if ! flock -n 9; then
        exec 9>&-
        error "另一个 XanMod 安装或恢复任务正在运行"
        return 1
    fi
    XANMOD_LOCK_HELD=true
}

release_xanmod_lock() {
    local release_failed=false

    if [[ "$XANMOD_LOCK_HELD" == "true" ]]; then
        flock -u 9 || release_failed=true
        exec 9>&- || release_failed=true
        XANMOD_LOCK_HELD=false
    fi
    [[ "$release_failed" == "false" ]]
}

run_locked_xanmod_plan() {
    local execution_status=0

    take_xanmod_lock || return 1
    if ! resolve_xanmod_plan; then
        execution_status=1
    else
        case "$XANMOD_PLAN_ACTION" in
            modify) install_xanmod || execution_status=$? ;;
            skip|noop) show_xanmod_plan_result ;;
            *) execution_status=1 ;;
        esac
    fi
    release_xanmod_lock || execution_status=1
    return "$execution_status"
}

restore_system_customization() {
    local scope="${1:-previous}"
    local target
    local result
    local restored_count=0
    local restore_failed=false
    local locale_restored=false
    local -a targets=(
        /etc/motd
        /etc/issue
        /etc/issue.net
        "$MOTD_SCRIPT"
        /etc/update-motd.d/10-uname
        /etc/update-motd.d/50-motd-news
        /etc/locale.gen
        /etc/locale.conf
        /etc/default/locale
    )

    case "$scope" in
        previous|initial) ;;
        *)
            error "恢复范围必须是 previous 或 initial"
            return 1
            ;;
    esac

    info "恢复系统定制配置到 $scope 状态..."

    for target in "${targets[@]}"; do
        if restore_managed_file "$target" "$scope"; then
            ((restored_count += 1))
            case "$target" in
                /etc/locale.gen|/etc/locale.conf|/etc/default/locale)
                    locale_restored=true
                    ;;
            esac
        else
            result=$?
            (( result == 1 )) && restore_failed=true
        fi
    done

    local xanmod_result=0
    restore_xanmod_group "$scope" || xanmod_result=$?
    restored_count=$((restored_count + XANMOD_RESTORED_COUNT))
    if (( xanmod_result == 1 )); then
        restore_failed=true
    fi

    if (( restored_count == 0 )); then
        error "没有可恢复的可信配置"
        return 1
    fi

    if [[ "$locale_restored" == "true" ]]; then
        if command -v locale-gen >/dev/null 2>&1; then
            locale-gen || {
                warn "Locale 配置已恢复，但 locale-gen 执行失败"
                restore_failed=true
            }
        else
            warn "Locale 配置已恢复，但缺少 locale-gen，区域数据尚未重新生成"
            restore_failed=true
        fi
    fi

    echo "说明: 已安装的 XanMod 内核包不会被卸载。"

    if [[ "$restore_failed" == "true" ]]; then
        error "部分配置恢复或应用失败"
        return 1
    fi

    success "系统定制配置已恢复到 $scope 状态（$restored_count 个文件状态）"
}

# === 主流程 ===
show_help() {
    cat <<'EOF'
用法：
  system-customize.sh                 交互执行全部功能
  system-customize.sh all             交互执行全部功能
  system-customize.sh motd            仅配置动态欢迎信息
  system-customize.sh locale          仅配置中文环境
  system-customize.sh xanmod [--yes|-y]
                                      只读规划；必要时安装或修复 XanMod
  system-customize.sh status          查看 XanMod 状态
  system-customize.sh restore         恢复上一次运行前的配置
  system-customize.sh restore initial 恢复首次运行前的可信配置
  system-customize.sh help            显示本帮助

直接 xanmod 先执行只读规划。仅计划确实包含修改时使用 [y/N]；无 TTY 必须传入 --yes。
all 模式无 TTY 时仍完成 MOTD/Locale，但只跳过确需修改的 XanMod 步骤。
EOF
}

require_xanmod_plan_commands() {
    require_xanmod_commands awk dpkg dpkg-query grep sort stat tr uname
}

require_xanmod_mutation_commands() {
    require_xanmod_commands apt-cache apt-get awk basename cat chgrp chmod chown cp curl dirname \
        dpkg dpkg-query find flock grep id install ln mkdir mv od readlink rm rmdir sort stat tr uname
}

run_authorized_xanmod_install() {
    require_xanmod_mutation_commands || return 1
    run_locked_xanmod_plan
}

run_direct_xanmod_action() {
    local authorization_status=0
    local execution_status=0

    require_xanmod_plan_commands || return 1
    resolve_xanmod_plan || return 1
    show_xanmod_plan_result
    if [[ "$XANMOD_PLAN_ACTION" != "modify" ]]; then
        show_xanmod_status
        return 0
    fi

    authorize_xanmod_install || authorization_status=$?
    case "$authorization_status" in
        0) ;;
        2) return 0 ;;
        *) return 1 ;;
    esac

    require_root
    run_authorized_xanmod_install || execution_status=$?
    if (( execution_status == 0 )); then
        show_xanmod_status
    fi
    return "$execution_status"
}

main() {
    local action="${1:-all}"
    local authorization_status=0
    local xanmod_status=0
    local restore_status=0

    XANMOD_ASSUME_YES=false
    case "$action" in
        help|--help|-h)
            (( $# == 1 )) || { error "help 不接受额外参数"; return 1; }
            show_help
            return 0
            ;;
        xanmod)
            case $# in
                1) ;;
                2)
                    case "$2" in
                        --yes|-y) XANMOD_ASSUME_YES=true ;;
                        *) error "未知 XanMod 参数: $2"; show_help; return 1 ;;
                    esac
                    ;;
                *) error "xanmod 参数过多"; show_help; return 1 ;;
            esac
            run_direct_xanmod_action
            return
            ;;
        all)
            (( $# <= 1 )) || { error "all 不接受额外参数"; show_help; return 1; }
            ;;
        motd|locale|status)
            (( $# == 1 )) || { error "$action 不接受额外参数"; show_help; return 1; }
            ;;
        restore)
            (( $# <= 2 )) || { error "restore 参数过多"; show_help; return 1; }
            ;;
        *)
            error "未知参数: $action"
            show_help
            return 1
            ;;
    esac

    require_root

    local required_command
    for required_command in apt-get apt-cache awk basename cat chmod cp curl df dirname dpkg grep \
        hostname install mktemp mv rm sed sleep sort stat tr uname uptime; do
        if ! command -v "$required_command" >/dev/null 2>&1; then
            error "缺少必要命令: $required_command"
            return 1
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

            require_xanmod_plan_commands || return 1
            resolve_xanmod_plan || return 1
            show_xanmod_plan_result
            if [[ "$XANMOD_PLAN_ACTION" == "modify" ]]; then
                if ! is_interactive_terminal; then
                    echo "XanMod 修改: 无交互终端，all 模式已安全跳过；如需执行请运行 xanmod --yes"
                else
                    authorize_xanmod_install || authorization_status=$?
                    case "$authorization_status" in
                        0) run_authorized_xanmod_install || xanmod_status=$? ;;
                        2) ;;
                        *) return 1 ;;
                    esac
                fi
            fi
            show_xanmod_status
            if (( xanmod_status != 0 )); then
                return "$xanmod_status"
            fi
            success "系统定制配置完成"
            ;;
        motd)
            configure_motd
            ;;
        locale)
            configure_chinese_locale
            ;;
        status)
            show_xanmod_status
            ;;
        restore)
            require_xanmod_commands chgrp chown flock ln readlink rmdir stat || return 1
            take_xanmod_lock || return 1
            restore_system_customization "${2:-previous}" || restore_status=$?
            release_xanmod_lock || restore_status=1
            return "$restore_status"
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    trap 'error "系统定制脚本在第 $LINENO 行执行失败"' ERR
    main "$@"
fi
