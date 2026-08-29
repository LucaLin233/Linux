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
else
    XANMOD_KEYRING="/etc/apt/keyrings/xanmod-archive-keyring.gpg"
    XANMOD_SOURCE_LIST="/etc/apt/sources.list.d/xanmod-release.list"
    XANMOD_SOURCE_DEB822="/etc/apt/sources.list.d/xanmod-release.sources"
    XANMOD_LOCK="/run/lock/xanmod-install.lock"
    XANMOD_OS_RELEASE="/etc/os-release"
    XANMOD_CPUINFO="/proc/cpuinfo"
    XANMOD_BACKUP_STATE_DIR="/var/lib/linux-setup/apt-source-backups"
fi
readonly XANMOD_KEYRING XANMOD_SOURCE_LIST XANMOD_SOURCE_DEB822 XANMOD_LOCK
readonly XANMOD_OS_RELEASE XANMOD_CPUINFO XANMOD_BACKUP_STATE_DIR
readonly -a XANMOD_MANAGED_PATHS=(
    "$XANMOD_KEYRING"
    "$XANMOD_SOURCE_LIST"
    "$XANMOD_SOURCE_DEB822"
)

XANMOD_ASSUME_YES=false
XANMOD_RUNTIME_SNAPSHOT_DIR=""
XANMOD_TRANSACTION_ACTIVE=false
XANMOD_STAGED_KEY=""
XANMOD_STAGED_SOURCE=""
XANMOD_SELECTED_REPOSITORY=""
XANMOD_RESTORED_COUNT=0

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

    if ! read -r -p "是否安装 XanMod 内核？[y/N]: " choice; then
        return 1
    fi
    [[ "$choice" =~ ^[Yy]$ ]]
}

authorize_xanmod_install() {
    if [[ "$XANMOD_ASSUME_YES" == "true" ]]; then
        return 0
    fi
    if ! is_interactive_terminal; then
        error "非交互安装必须显式传入 --yes"
        return 1
    fi
    if confirm_xanmod_install; then
        return 0
    fi
    echo "XanMod 内核: 已跳过"
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

xanmod_codename_supported() {
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

xanmod_source_has_supported_uri() {
    grep -Eiq \
        '^[[:space:]]*URIs:[[:space:]]*https://(deb\.xanmod\.org|mirror\.nju\.edu\.cn/xanmod|mirrors\.bfsu\.edu\.cn/xanmod|mirrors\.tuna\.tsinghua\.edu\.cn/xanmod)/?[[:space:]]*$' \
        "$1"
}

xanmod_list_source_configured() {
    [[ -f "$XANMOD_KEYRING" && ! -L "$XANMOD_KEYRING" ]] &&
        xanmod_keyring_valid &&
        [[ -f "$XANMOD_SOURCE_LIST" && ! -L "$XANMOD_SOURCE_LIST" ]] &&
        awk -v expected_key="$XANMOD_KEYRING" '
            /^[[:space:]]*($|#)/ { next }
            {
                line_count++
                if (NF == 5 && $1 == "deb" &&
                    $2 == "[signed-by=" expected_key "]" &&
                    $3 ~ /^https:\/\/(deb\.xanmod\.org|mirror\.nju\.edu\.cn\/xanmod|mirrors\.bfsu\.edu\.cn\/xanmod|mirrors\.tuna\.tsinghua\.edu\.cn\/xanmod)\/?$/ &&
                    $4 ~ /^(bookworm|trixie|noble)$/ && $5 == "main") valid_count++
                else invalid = 1
            }
            END { exit !(line_count == 1 && valid_count == 1 && !invalid) }
        ' "$XANMOD_SOURCE_LIST"
}

xanmod_deb822_source_configured() {
    [[ -f "$XANMOD_KEYRING" && ! -L "$XANMOD_KEYRING" ]] &&
        xanmod_keyring_valid &&
        [[ -f "$XANMOD_SOURCE_DEB822" && ! -L "$XANMOD_SOURCE_DEB822" ]] &&
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
                else if (name == "Suites" && value ~ /^(bookworm|trixie|noble)$/) suites++
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

    case "$source_file" in
        *.sources)
            grep -Eq "^[[:space:]]*Suites:[[:space:]]*${codename}[[:space:]]*$" "$source_file"
            ;;
        *)
            grep -Eq "^[[:space:]]*deb[[:space:]].*[[:space:]]${codename}[[:space:]]+main([[:space:]]|$)" "$source_file"
            ;;
    esac
}

write_xanmod_deb822_source() {
    local source_file="$1"
    local repository="$2"
    local codename="$3"
    local keyring_path="${4:-$XANMOD_KEYRING}"

    cat > "$source_file" <<EOF
Types: deb
URIs: $repository
Suites: $codename
Components: main
Signed-By: $keyring_path
EOF
}

xanmod_source_is_usable() {
    local source_file="$1"
    local lists_temp=""
    local apt_status=0

    lists_temp=$(mktemp -d "${TMPDIR:-/tmp}/xanmod-apt-lists.XXXXXX") || return 1
    if ! chmod 0755 "$lists_temp" || ! install -d -m 0755 "$lists_temp/partial"; then
        rm -rf -- "$lists_temp"
        return 1
    fi

    if apt-get update -qq \
        -o "Dir::Etc::sourcelist=$source_file" \
        -o 'Dir::Etc::sourceparts=-' \
        -o "Dir::State::lists=$lists_temp" \
        -o 'APT::Get::List-Cleanup=0'; then
        apt_status=0
    else
        apt_status=$?
    fi

    rm -rf -- "$lists_temp"
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

create_xanmod_runtime_snapshot() {
    local index

    if [[ "$XANMOD_TRANSACTION_ACTIVE" == "true" ]]; then
        error "XanMod 配置事务已经开始"
        return 1
    fi

    XANMOD_RUNTIME_SNAPSHOT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/xanmod-runtime-snapshot.XXXXXX") || return 1
    chmod 0700 "$XANMOD_RUNTIME_SNAPSHOT_DIR" || {
        rm -rf -- "$XANMOD_RUNTIME_SNAPSHOT_DIR"
        XANMOD_RUNTIME_SNAPSHOT_DIR=""
        return 1
    }

    for index in "${!XANMOD_MANAGED_PATHS[@]}"; do
        if ! capture_xanmod_snapshot_item \
            "${XANMOD_MANAGED_PATHS[$index]}" \
            "$XANMOD_RUNTIME_SNAPSHOT_DIR/item-$index"; then
            rm -rf -- "$XANMOD_RUNTIME_SNAPSHOT_DIR"
            XANMOD_RUNTIME_SNAPSHOT_DIR=""
            return 1
        fi
    done

    XANMOD_TRANSACTION_ACTIVE=true
}

restore_xanmod_snapshot_item() {
    local target="$1"
    local snapshot_prefix="$2"
    local state=""

    [[ -r "${snapshot_prefix}.state" ]] || return 1
    state=$(<"${snapshot_prefix}.state")

    if [[ -d "$target" && ! -L "$target" ]]; then
        error "拒绝用文件状态覆盖目录: $target"
        return 1
    fi

    case "$state" in
        file)
            [[ -f "${snapshot_prefix}.data" && ! -L "${snapshot_prefix}.data" ]] || return 1
            install -d -m 0755 "$(dirname "$target")" || return 1
            rm -f -- "$target" || return 1
            cp -a -- "${snapshot_prefix}.data" "$target" || return 1
            ;;
        symlink)
            [[ -L "${snapshot_prefix}.data" ]] || return 1
            install -d -m 0755 "$(dirname "$target")" || return 1
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

    rm -rf -- "$XANMOD_RUNTIME_SNAPSHOT_DIR"
    XANMOD_RUNTIME_SNAPSHOT_DIR=""
    XANMOD_TRANSACTION_ACTIVE=false

    [[ "$restore_failed" == "false" ]]
}

discard_xanmod_runtime_snapshot() {
    if [[ -n "$XANMOD_RUNTIME_SNAPSHOT_DIR" ]]; then
        rm -rf -- "$XANMOD_RUNTIME_SNAPSHOT_DIR"
    fi
    XANMOD_RUNTIME_SNAPSHOT_DIR=""
    XANMOD_TRANSACTION_ACTIVE=false
}

ensure_xanmod_backup_state_dir() {
    local mode=""

    if [[ -L "$XANMOD_BACKUP_STATE_DIR" ||
        ( -e "$XANMOD_BACKUP_STATE_DIR" && ! -d "$XANMOD_BACKUP_STATE_DIR" ) ]]; then
        error "XanMod 备份状态路径不是可信目录: $XANMOD_BACKUP_STATE_DIR"
        return 1
    fi

    install -d -m 0700 "$XANMOD_BACKUP_STATE_DIR" || return 1
    chmod 0700 "$XANMOD_BACKUP_STATE_DIR" || return 1
    mode=$(stat -c '%a' "$XANMOD_BACKUP_STATE_DIR") || return 1
    if [[ "$mode" != "700" ]]; then
        error "XanMod 备份状态目录权限必须是 0700"
        return 1
    fi
}

get_xanmod_backup_prefix() {
    printf '%s/%s\n' "$XANMOD_BACKUP_STATE_DIR" "$(basename "$1")"
}

xanmod_persistent_state_count() {
    local prefix="$1"
    local scope="$2"
    local count=0
    local suffix

    for suffix in backup absent unknown; do
        if [[ -e "${prefix}.${scope}-${suffix}" || -L "${prefix}.${scope}-${suffix}" ]]; then
            ((count += 1))
        fi
    done
    printf '%s\n' "$count"
}

capture_xanmod_persistent_state() {
    local target="$1"
    local prefix="$2"
    local scope="$3"
    local backup="${prefix}.${scope}-backup"
    local absent="${prefix}.${scope}-absent"
    local unknown="${prefix}.${scope}-unknown"

    rm -f -- "$backup" "$absent" "$unknown" || return 1
    if [[ -L "$target" || -f "$target" ]]; then
        cp -a -- "$target" "$backup" || return 1
    elif [[ ! -e "$target" ]]; then
        install -m 0600 /dev/null "$absent" || return 1
    else
        error "拒绝备份非常规 XanMod 配置路径: $target"
        return 1
    fi
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

migrate_legacy_xanmod_backup_states() {
    local target
    local prefix
    local suffix
    local legacy
    local destination

    for target in "${XANMOD_MANAGED_PATHS[@]}"; do
        prefix=$(get_xanmod_backup_prefix "$target") || return 1
        for suffix in initial-backup initial-absent initial-unknown previous-backup previous-absent; do
            legacy="${target}.${suffix}"
            destination="${prefix}.${suffix}"
            [[ -e "$legacy" || -L "$legacy" ]] || continue
            if [[ -e "$destination" || -L "$destination" ]]; then
                destination=$(mktemp "$XANMOD_BACKUP_STATE_DIR/$(basename "$legacy").legacy.XXXXXX") || return 1
                rm -f -- "$destination" || return 1
            fi
            mv -T -- "$legacy" "$destination" || return 1
        done
    done
}

prepare_persistent_xanmod_backups() {
    local target
    local prefix
    local initial_count
    local previously_managed=false

    ensure_xanmod_backup_state_dir || return 1
    migrate_legacy_xanmod_backup_states || return 1
    if xanmod_configuration_looks_previously_managed; then
        previously_managed=true
    fi

    for target in "${XANMOD_MANAGED_PATHS[@]}"; do
        prefix=$(get_xanmod_backup_prefix "$target") || return 1
        initial_count=$(xanmod_persistent_state_count "$prefix" initial) || return 1
        if (( initial_count > 1 )); then
            error "XanMod initial 备份状态冲突: $target"
            return 1
        fi
        if (( initial_count == 0 )); then
            if [[ "$previously_managed" == "true" ]]; then
                install -m 0600 /dev/null "${prefix}.initial-unknown" || return 1
            else
                capture_xanmod_persistent_state "$target" "$prefix" initial || return 1
            fi
        fi

        capture_xanmod_persistent_state "$target" "$prefix" previous || return 1
    done
}

prepare_xanmod_transaction() {
    prepare_persistent_xanmod_backups
}

classify_xanmod_persistent_state() {
    local target="$1"
    local scope="$2"
    local prefix
    local count
    local backup
    local absent
    local unknown

    prefix=$(get_xanmod_backup_prefix "$target") || return 1
    count=$(xanmod_persistent_state_count "$prefix" "$scope") || return 1
    backup="${prefix}.${scope}-backup"
    absent="${prefix}.${scope}-absent"
    unknown="${prefix}.${scope}-unknown"

    if (( count == 0 )); then
        return 2
    fi
    if (( count != 1 )); then
        return 1
    fi
    if [[ -e "$unknown" || -L "$unknown" ]]; then
        return 2
    fi
    if [[ -L "$backup" || -f "$backup" ]]; then
        printf 'backup\n'
        return 0
    fi
    if [[ -f "$absent" && ! -L "$absent" ]]; then
        printf 'absent\n'
        return 0
    fi
    return 1
}

restore_xanmod_persistent_item() {
    local target="$1"
    local scope="$2"
    local state_type="$3"
    local prefix
    local backup
    local staged=""

    prefix=$(get_xanmod_backup_prefix "$target") || return 1
    backup="${prefix}.${scope}-backup"

    if [[ -d "$target" && ! -L "$target" ]]; then
        error "拒绝用备份文件覆盖目录: $target"
        return 1
    fi

    case "$state_type" in
        absent)
            rm -f -- "$target"
            ;;
        backup)
            staged=$(make_xanmod_stage_file "$target" .restore) || return 1
            rm -f -- "$staged" || return 1
            if ! cp -a -- "$backup" "$staged"; then
                rm -f -- "$staged"
                return 1
            fi
            if ! mv -fT -- "$staged" "$target"; then
                rm -f -- "$staged"
                return 1
            fi
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

    create_xanmod_runtime_snapshot || return 1
    for index in "${!XANMOD_MANAGED_PATHS[@]}"; do
        if ! restore_xanmod_persistent_item \
            "${XANMOD_MANAGED_PATHS[$index]}" "$scope" "${state_types[$index]}"; then
            error "恢复 XanMod 配置失败: ${XANMOD_MANAGED_PATHS[$index]}"
            apply_failed=true
            break
        fi
    done

    if [[ "$apply_failed" == "true" ]]; then
        if ! restore_xanmod_runtime_snapshot; then
            error "XanMod 组恢复失败，且运行前配置回滚不完整"
        fi
        return 1
    fi

    discard_xanmod_runtime_snapshot
    XANMOD_RESTORED_COUNT=${#XANMOD_MANAGED_PATHS[@]}
    if ! apt-get update -qq; then
        warn "XanMod 软件源配置已恢复，但 APT 索引更新失败；已保留请求恢复的配置"
        return 1
    fi
}


begin_xanmod_install_transaction() {
    prepare_xanmod_transaction || return 1
    create_xanmod_runtime_snapshot
}

make_xanmod_stage_file() {
    local target="$1"
    local suffix="$2"
    local target_dir

    target_dir=$(dirname "$target") || return 1
    install -d -m 0755 "$target_dir" || return 1
    mktemp --suffix="$suffix" "$target_dir/.xanmod-stage.$(basename "$target").XXXXXX"
}

cleanup_xanmod_stages() {
    [[ -z "$XANMOD_STAGED_KEY" ]] || rm -f -- "$XANMOD_STAGED_KEY"
    [[ -z "$XANMOD_STAGED_SOURCE" ]] || rm -f -- "$XANMOD_STAGED_SOURCE"
    XANMOD_STAGED_KEY=""
    XANMOD_STAGED_SOURCE=""
}

stage_xanmod_key() {
    local armored_temp=""
    local key_url

    XANMOD_STAGED_KEY=$(make_xanmod_stage_file "$XANMOD_KEYRING" .gpg) || return 1

    if xanmod_keyring_valid; then
        if install -m 0644 "$XANMOD_KEYRING" "$XANMOD_STAGED_KEY" &&
            xanmod_keyring_valid "$XANMOD_STAGED_KEY"; then
            return 0
        fi
        cleanup_xanmod_stages
        return 1
    fi

    if [[ -e "$XANMOD_KEYRING" || -L "$XANMOD_KEYRING" ]]; then
        warn "现有 XanMod 密钥不满足严格指纹与 UID 校验，将重新获取"
    fi

    armored_temp=$(mktemp "${TMPDIR:-/tmp}/xanmod-key.XXXXXX") || {
        cleanup_xanmod_stages
        return 1
    }

    for key_url in "$XANMOD_KEY_URL" "$XANMOD_KEY_FALLBACK_UBUNTU"; do
        info "下载 XanMod 软件源签名密钥: $key_url"
        : > "$armored_temp"
        if ! curl -fsSL --connect-timeout 10 --max-time 30 "$key_url" -o "$armored_temp"; then
            warn "该密钥来源下载失败，尝试下一个来源"
            continue
        fi
        if ! xanmod_keyring_valid "$armored_temp"; then
            warn "该密钥来源未通过严格主密钥指纹与 UID 校验，尝试下一个来源"
            continue
        fi

        rm -f -- "$XANMOD_STAGED_KEY"
        if ! gpg --batch --yes --dearmor --output "$XANMOD_STAGED_KEY" "$armored_temp"; then
            warn "XanMod 签名密钥转换失败，尝试下一个来源"
            rm -f -- "$XANMOD_STAGED_KEY"
            XANMOD_STAGED_KEY=$(make_xanmod_stage_file "$XANMOD_KEYRING" .gpg) || break
            continue
        fi
        chmod 0644 "$XANMOD_STAGED_KEY" || break
        if xanmod_keyring_valid "$XANMOD_STAGED_KEY"; then
            rm -f -- "$armored_temp"
            return 0
        fi

        warn "转换后的 XanMod 密钥未通过严格校验，尝试下一个来源"
        rm -f -- "$XANMOD_STAGED_KEY"
        XANMOD_STAGED_KEY=$(make_xanmod_stage_file "$XANMOD_KEYRING" .gpg) || break
    done

    rm -f -- "$armored_temp"
    cleanup_xanmod_stages
    error "无法获得指纹为 $XANMOD_KEY_FINGERPRINT 且 UID 匹配的 XanMod 签名密钥"
    return 1
}

stage_xanmod_source() {
    local codename="$1"
    local candidate_source=""
    local repository

    candidate_source=$(make_xanmod_stage_file "$XANMOD_SOURCE_DEB822" .sources) || return 1
    XANMOD_SELECTED_REPOSITORY=""

    for repository in "${XANMOD_REPOSITORIES[@]}"; do
        info "探测 XanMod 软件源: $repository"
        write_xanmod_deb822_source \
            "$candidate_source" "$repository" "$codename" "$XANMOD_STAGED_KEY"
        chmod 0644 "$candidate_source" || {
            rm -f -- "$candidate_source"
            return 1
        }

        if xanmod_source_is_usable "$candidate_source"; then
            XANMOD_SELECTED_REPOSITORY="$repository"
            break
        fi
        warn "XanMod 软件源不可用: $repository"
    done

    rm -f -- "$candidate_source"
    if [[ -z "$XANMOD_SELECTED_REPOSITORY" ]]; then
        error "所有 XanMod 软件源均不可用，未修改正式 APT 配置"
        return 1
    fi

    XANMOD_STAGED_SOURCE=$(make_xanmod_stage_file "$XANMOD_SOURCE_DEB822" .sources) || return 1
    write_xanmod_deb822_source \
        "$XANMOD_STAGED_SOURCE" "$XANMOD_SELECTED_REPOSITORY" "$codename" "$XANMOD_KEYRING"
    chmod 0644 "$XANMOD_STAGED_SOURCE"
}

xanmod_repository_ready() {
    local codename="$1"

    xanmod_deb822_source_configured &&
        [[ ! -e "$XANMOD_SOURCE_LIST" && ! -L "$XANMOD_SOURCE_LIST" ]] &&
        xanmod_source_matches_codename "$XANMOD_SOURCE_DEB822" "$codename" &&
        xanmod_source_is_usable "$XANMOD_SOURCE_DEB822"
}

configure_xanmod_repository() {
    local codename="$1"

    [[ "$XANMOD_TRANSACTION_ACTIVE" == "true" ]] || {
        error "拒绝在事务外修改 XanMod 配置"
        return 1
    }

    ensure_package "gpg" "gpg" || return 1
    install -d -m 0755 "$(dirname "$XANMOD_KEYRING")" || return 1
    install -d -m 0755 "$(dirname "$XANMOD_SOURCE_DEB822")" || return 1

    if xanmod_repository_ready "$codename"; then
        echo "XanMod 软件源: 已配置并可用（$XANMOD_SOURCE_DEB822）"
        return 0
    fi

    warn "现有 XanMod 软件源缺失、不匹配或不可用，将事务式重新配置"
    stage_xanmod_key || return 1
    if ! stage_xanmod_source "$codename"; then
        cleanup_xanmod_stages
        return 1
    fi

    if ! mv -fT -- "$XANMOD_STAGED_KEY" "$XANMOD_KEYRING"; then
        cleanup_xanmod_stages
        return 1
    fi
    XANMOD_STAGED_KEY=""

    if ! mv -fT -- "$XANMOD_STAGED_SOURCE" "$XANMOD_SOURCE_DEB822"; then
        cleanup_xanmod_stages
        return 1
    fi
    XANMOD_STAGED_SOURCE=""

    if ! rm -f -- "$XANMOD_SOURCE_LIST"; then
        return 1
    fi

    if ! xanmod_keyring_valid ||
        ! xanmod_deb822_source_configured ||
        ! xanmod_source_matches_codename "$XANMOD_SOURCE_DEB822" "$codename" ||
        ! xanmod_source_is_usable "$XANMOD_SOURCE_DEB822"; then
        error "正式 XanMod 软件源未通过隔离 APT 验证"
        return 1
    fi

    echo "XanMod 软件源: 已配置（Deb822 / $codename / $XANMOD_SELECTED_REPOSITORY）"
}

abort_xanmod_install_transaction() {
    local apt_may_be_partial="${1:-false}"

    cleanup_xanmod_stages
    if ! restore_xanmod_runtime_snapshot; then
        error "XanMod APT 配置回滚不完整，请立即人工检查三个受管文件"
    else
        warn "XanMod APT 配置已恢复到本次运行前状态"
    fi

    if [[ "$apt_may_be_partial" == "true" ]]; then
        warn "APT 可能已部分安装内核包；为避免误删可启动内核，脚本不会自动卸载任何包"
        warn "请检查: dpkg --audit；必要时执行 apt-get -f install，并确认引导菜单中的可用内核"
    fi

    return 1
}

get_installed_xanmod_packages() {
    dpkg-query -W -f='${binary:Package} ${db:Status-Status}\n' \
        "linux-xanmod-*" 2>/dev/null |
        awk '$2 == "installed" { sub(/:amd64$/, "", $1); print $1 }' |
        sort -u
}

install_xanmod() {
    local target_package=""
    local installed_packages=""
    local codename=""
    local policy_output=""
    local candidate_version=""

    codename=$(get_os_codename || true)
    if [[ -z "$codename" ]]; then
        warn "无法识别系统发行版代号，已跳过 XanMod 安装"
        return 0
    fi
    if ! xanmod_codename_supported "$codename"; then
        warn "XanMod 官方 APT 仓库不支持 $codename，已跳过内核安装"
        return 0
    fi

    echo "XanMod 将在兼容时自动安装；系统原内核会保留，重启后才生效。"
    if ! is_amd64; then
        warn "当前架构为 $(dpkg --print-architecture) / $(uname -m)"
        warn "XanMod 官方 APT 仓库目前仅提供 amd64 内核包，已跳过安装"
        return 0
    fi

    if target_package=$(detect_xanmod_package); then
        :
    else
        case $? in
            2)
                warn "当前 CPU 仅达到 x86-64-v1，不支持 XanMod MAIN 所需的 x86-64-v2"
                ;;
            3)
                target_package=$(get_running_xanmod_package || true)
                if [[ -n "$target_package" ]]; then
                    warn "无法读取本机 CPU 指令集，沿用当前已运行的 XanMod 分支: $target_package"
                else
                    warn "无法读取本机 CPU 指令集，跳过 XanMod 安装"
                fi
                ;;
            *)
                warn "无法确认适用的 XanMod 内核包"
                ;;
        esac
        if [[ -z "$target_package" ]]; then
            warn "为避免安装不兼容内核，已保留系统原内核"
            return 0
        fi
    fi

    echo "检测到适合当前环境的 XanMod 包: $target_package"
    installed_packages=$(get_installed_xanmod_packages || true)
    if [[ -n "$installed_packages" ]] && ! package_is_installed "$target_package"; then
        warn "已安装的 XanMod 包与 CPU 检测结果不匹配: $(tr '\n' ' ' <<< "$installed_packages")"
        warn "将安装检测到的正确版本: $target_package"
        echo "说明: 旧 XanMod 包将保留，确认新内核可正常启动后再手动清理。"
    fi

    if ! begin_xanmod_install_transaction; then
        error "无法建立 XanMod 配置运行时快照"
        return 1
    fi

    if ! configure_xanmod_repository "$codename"; then
        error "XanMod 软件源配置失败"
        abort_xanmod_install_transaction false || true
        return 1
    fi

    if package_is_installed "$target_package"; then
        discard_xanmod_runtime_snapshot
        echo "XanMod 目标包: 已安装（$target_package）"
        if [[ "$(get_running_xanmod_package || true)" == "$target_package" ]]; then
            echo "当前内核: $(uname -r)（匹配 CPU 检测结果）"
        else
            echo "当前内核: $(uname -r)（目标内核将在下次重启后生效）"
        fi
        return 0
    fi

    info "更新软件包索引..."
    if ! apt-get update; then
        error "XanMod 软件源索引更新失败"
        abort_xanmod_install_transaction false || true
        return 1
    fi

    if ! policy_output=$(apt-cache policy "$target_package"); then
        error "无法查询 XanMod 候选版本"
        abort_xanmod_install_transaction false || true
        return 1
    fi
    candidate_version=$(awk '/Candidate:/ {print $2; exit}' <<< "$policy_output")
    if [[ -z "$candidate_version" || "$candidate_version" == "(none)" ]]; then
        error "XanMod 软件源没有可安装的 $target_package 候选版本"
        abort_xanmod_install_transaction false || true
        return 1
    fi

    info "安装 XanMod 内核包: $target_package（$candidate_version）"
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y "$target_package"; then
        error "XanMod 内核安装失败"
        abort_xanmod_install_transaction true || true
        return 1
    fi
    if ! package_is_installed "$target_package"; then
        error "XanMod 内核安装后验证失败"
        abort_xanmod_install_transaction true || true
        return 1
    fi

    discard_xanmod_runtime_snapshot
    success "XanMod 内核已安装: $target_package"
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
    if [[ -z "$codename" ]] || ! xanmod_codename_supported "$codename"; then
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
        echo "  推荐包: 不适用（XanMod 官方仓库不支持 ${codename:-当前发行版}）"
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
                *.sources) echo "  软件源: 已配置（Deb822）" ;;
                *) echo "  软件源: 已配置（传统 list）" ;;
            esac
            echo "  软件源文件: $source_file"
        else
            echo "  软件源: 未配置或配置未通过校验"
        fi
    fi

    installed_packages=$(get_installed_xanmod_packages || true)
    if [[ -n "$installed_packages" ]]; then
        echo "  已安装包: $(tr '\n' ' ' <<< "$installed_packages")"
    else
        echo "  已安装包: 无"
    fi
}

take_xanmod_lock() {
    install -d -m 0755 "$(dirname "$XANMOD_LOCK")" || return 1
    if [[ -L "$XANMOD_LOCK" || ( -e "$XANMOD_LOCK" && ! -f "$XANMOD_LOCK" ) ]]; then
        error "XanMod 锁路径不是普通文件: $XANMOD_LOCK"
        return 1
    fi

    exec 9>> "$XANMOD_LOCK"
    if [[ -L "$XANMOD_LOCK" || ! -f "$XANMOD_LOCK" ]]; then
        exec 9>&-
        error "XanMod 锁路径在打开时发生变化"
        return 1
    fi
    if ! flock -n 9; then
        exec 9>&-
        error "另一个 XanMod 安装或恢复任务正在运行"
        return 1
    fi
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
                                      检查并安装 XanMod 内核
  system-customize.sh status          查看 XanMod 状态
  system-customize.sh restore         恢复上一次运行前的配置
  system-customize.sh restore initial 恢复首次运行前的可信配置
  system-customize.sh help            显示本帮助

XanMod 默认使用 [y/N] 确认。直接非交互安装必须传入 --yes；all 模式无 TTY 时会安全跳过 XanMod。
EOF
}

run_authorized_xanmod_install() {
    require_xanmod_commands apt-cache apt-get awk basename cat chmod cp curl dirname dpkg \
        dpkg-query flock grep install mktemp mv rm sort stat tr uname || return 1
    take_xanmod_lock || return 1
    install_xanmod
}

main() {
    local action="${1:-all}"
    local authorization_status=0

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
            authorize_xanmod_install || authorization_status=$?
            case "$authorization_status" in
                0) ;;
                2) return 0 ;;
                *) return 1 ;;
            esac
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
        hostname install mktemp mv rm sed sleep sort tr uname uptime; do
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
            if ! is_interactive_terminal; then
                echo "XanMod 内核: 无交互终端，all 模式已安全跳过；如需安装请运行 xanmod --yes"
            else
                authorization_status=0
                authorize_xanmod_install || authorization_status=$?
                case "$authorization_status" in
                    0) run_authorized_xanmod_install ;;
                    2) ;;
                    *) return 1 ;;
                esac
            fi
            show_xanmod_status
            success "系统定制配置完成"
            ;;
        motd) configure_motd ;;
        locale) configure_chinese_locale ;;
        xanmod)
            run_authorized_xanmod_install
            show_xanmod_status
            ;;
        status) show_xanmod_status ;;
        restore)
            require_xanmod_commands flock stat || return 1
            take_xanmod_lock || return 1
            restore_system_customization "${2:-previous}"
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    trap 'error "系统定制脚本在第 $LINENO 行执行失败"' ERR
    main "$@"
fi
