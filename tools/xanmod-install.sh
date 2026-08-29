#!/usr/bin/env bash
# XanMod Kernel Installer for Debian/Ubuntu
# 内容与 modules/system-customize.sh 的共享 XanMod 事务函数保持一致。
#
# 用法：
#   bash xanmod-install.sh                  # 只读规划；需要修改时交互确认
#   bash xanmod-install.sh --yes            # 非交互授权必要修改
#   bash xanmod-install.sh install --yes    # 非交互授权必要修改
#   bash xanmod-install.sh status           # 查看 XanMod 状态

set -euo pipefail

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
    XANMOD_TRUSTED_UID="$EUID"
    XANMOD_TRUSTED_GID=$(id -g)
else
    XANMOD_KEYRING="/etc/apt/keyrings/xanmod-archive-keyring.gpg"
    XANMOD_SOURCE_LIST="/etc/apt/sources.list.d/xanmod-release.list"
    XANMOD_SOURCE_DEB822="/etc/apt/sources.list.d/xanmod-release.sources"
    XANMOD_LOCK="/run/lock/xanmod-install.lock"
    XANMOD_OS_RELEASE="/etc/os-release"
    XANMOD_CPUINFO="/proc/cpuinfo"
    XANMOD_TRUSTED_UID=0
    XANMOD_TRUSTED_GID=0
fi
readonly XANMOD_KEYRING XANMOD_SOURCE_LIST XANMOD_SOURCE_DEB822 XANMOD_LOCK
readonly XANMOD_OS_RELEASE XANMOD_CPUINFO
readonly XANMOD_TRUSTED_UID XANMOD_TRUSTED_GID
readonly -a XANMOD_MANAGED_PATHS=(
    "$XANMOD_KEYRING"
    "$XANMOD_SOURCE_LIST"
    "$XANMOD_SOURCE_DEB822"
)

XANMOD_ACTION="install"
XANMOD_ASSUME_YES=false
XANMOD_RUNTIME_SNAPSHOT_DIR=""
XANMOD_TRANSACTION_ACTIVE=false
XANMOD_CONFIG_MODIFIED=false
XANMOD_APT_MAY_BE_PARTIAL=false
XANMOD_STAGED_KEY=""
XANMOD_STAGED_SOURCE=""
XANMOD_CANDIDATE_SOURCE=""
XANMOD_ARMORED_KEY_TEMP=""
XANMOD_ACTIVE_APT_LISTS_DIR=""
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

info() { log "$1" "info"; }
warn() { log "$1" "warn"; }
error() { log "$1" "error"; }
success() { log "$1" "success"; }

require_root() {
    if (( EUID != 0 )); then
        error "需要 root 权限运行"
        return 1
    fi
}

require_commands() {
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
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y "$package_name"; then
        error "安装依赖包失败: $package_name"
        return 1
    fi
    if ! command -v "$command_name" >/dev/null 2>&1; then
        error "依赖命令仍不可用: $command_name"
        return 1
    fi
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
    xanmod_codename_safe "$1"
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

cleanup_xanmod_active_apt_lists() {
    if [[ -z "$XANMOD_ACTIVE_APT_LISTS_DIR" ]]; then
        return 0
    fi
    if [[ ! -e "$XANMOD_ACTIVE_APT_LISTS_DIR" ]] ||
        remove_xanmod_temp_directory "$XANMOD_ACTIVE_APT_LISTS_DIR" "临时 APT lists"; then
        XANMOD_ACTIVE_APT_LISTS_DIR=""
        return 0
    fi
    return 1
}

xanmod_source_is_usable() {
    local source_file="$1"
    local apt_status=0

    XANMOD_ACTIVE_APT_LISTS_DIR=$(mktemp -d "${TMPDIR:-/tmp}/xanmod-apt-lists.XXXXXX") || return 1
    if ! chmod 0755 "$XANMOD_ACTIVE_APT_LISTS_DIR" ||
        ! install -d -m 0755 "$XANMOD_ACTIVE_APT_LISTS_DIR/partial"; then
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

create_xanmod_runtime_snapshot() {
    local index

    if [[ "$XANMOD_TRANSACTION_ACTIVE" == "true" ]]; then
        error "XanMod 配置事务已经开始"
        return 1
    fi

    XANMOD_RUNTIME_SNAPSHOT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/xanmod-runtime-snapshot.XXXXXX") || return 1
    chmod 0700 "$XANMOD_RUNTIME_SNAPSHOT_DIR" || {
        remove_xanmod_temp_directory "$XANMOD_RUNTIME_SNAPSHOT_DIR" "XanMod 运行时快照" || true
        XANMOD_RUNTIME_SNAPSHOT_DIR=""
        return 1
    }

    for index in "${!XANMOD_MANAGED_PATHS[@]}"; do
        if ! capture_xanmod_snapshot_item \
            "${XANMOD_MANAGED_PATHS[$index]}" \
            "$XANMOD_RUNTIME_SNAPSHOT_DIR/item-$index"; then
            remove_xanmod_temp_directory "$XANMOD_RUNTIME_SNAPSHOT_DIR" "XanMod 运行时快照" || true
            XANMOD_RUNTIME_SNAPSHOT_DIR=""
            return 1
        fi
    done

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
    local cleanup_failed=false

    [[ "$XANMOD_TRANSACTION_ACTIVE" == "true" ]] || return 0

    for index in "${!XANMOD_MANAGED_PATHS[@]}"; do
        if ! restore_xanmod_snapshot_item \
            "${XANMOD_MANAGED_PATHS[$index]}" \
            "$XANMOD_RUNTIME_SNAPSHOT_DIR/item-$index"; then
            error "恢复 XanMod 配置失败: ${XANMOD_MANAGED_PATHS[$index]}"
            restore_failed=true
        fi
    done
    if [[ "$restore_failed" == "false" ]]; then
        XANMOD_CONFIG_MODIFIED=false
    fi

    if remove_xanmod_temp_directory "$XANMOD_RUNTIME_SNAPSHOT_DIR" "XanMod 运行时快照"; then
        XANMOD_RUNTIME_SNAPSHOT_DIR=""
        XANMOD_TRANSACTION_ACTIVE=false
    else
        cleanup_failed=true
    fi

    [[ "$restore_failed" == "false" && "$cleanup_failed" == "false" ]]
}

discard_xanmod_runtime_snapshot() {
    if [[ -z "$XANMOD_RUNTIME_SNAPSHOT_DIR" ]]; then
        XANMOD_TRANSACTION_ACTIVE=false
        return 0
    fi
    if ! remove_xanmod_temp_directory "$XANMOD_RUNTIME_SNAPSHOT_DIR" "XanMod 运行时快照"; then
        return 1
    fi
    XANMOD_RUNTIME_SNAPSHOT_DIR=""
    XANMOD_TRANSACTION_ACTIVE=false
}

prepare_xanmod_transaction() {
    :
}

abort_pending_xanmod_backup_transaction() {
    :
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

    cleanup_xanmod_stages || cleanup_failed=true
    cleanup_xanmod_active_apt_lists || cleanup_failed=true
    abort_pending_xanmod_backup_transaction || cleanup_failed=true
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
    local cleanup_status=0
    local saved_exit="$XANMOD_SAVED_TRAP_EXIT"

    if [[ "$XANMOD_GUARD_ACTIVE" != "true" || "$XANMOD_GUARD_HANDLING" == "true" ]]; then
        return
    fi
    XANMOD_GUARD_HANDLING=true
    trap - EXIT
    trap '' HUP INT TERM
    error "XanMod 事务异常退出，正在恢复运行前状态"
    cleanup_xanmod_transaction_state || cleanup_status=$?
    XANMOD_GUARD_ACTIVE=false
    if (( exit_status == 0 && cleanup_status != 0 )); then
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
        abort_pending_xanmod_backup_transaction || true
        clear_xanmod_transaction_guards
        return 1
    fi
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

    XANMOD_STAGED_KEY=$(make_xanmod_stage_file "$XANMOD_KEYRING" .gpg) || return 1

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

    XANMOD_ARMORED_KEY_TEMP=$(mktemp "${TMPDIR:-/tmp}/xanmod-key.XXXXXX") || {
        cleanup_xanmod_stages || true
        return 1
    }

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
            XANMOD_STAGED_KEY=$(make_xanmod_stage_file "$XANMOD_KEYRING" .gpg) || break
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
        XANMOD_STAGED_KEY=$(make_xanmod_stage_file "$XANMOD_KEYRING" .gpg) || break
    done

    cleanup_xanmod_stages || true
    error "无法获得指纹为 $XANMOD_KEY_FINGERPRINT 且 UID 匹配的 XanMod 签名密钥"
    return 1
}

stage_xanmod_source() {
    local codename="$1"
    local repository
    local source_status=0

    XANMOD_CANDIDATE_SOURCE=$(make_xanmod_stage_file "$XANMOD_SOURCE_DEB822" .sources) || return 1
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

    XANMOD_STAGED_SOURCE=$(make_xanmod_stage_file "$XANMOD_SOURCE_DEB822" .sources) || return 1
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
parse_xanmod_arguments() {
    XANMOD_ACTION="install"
    XANMOD_ASSUME_YES=false

    case $# in
        0) ;;
        1)
            case "$1" in
                install) ;;
                --yes|-y) XANMOD_ASSUME_YES=true ;;
                status) XANMOD_ACTION="status" ;;
                help|--help|-h) XANMOD_ACTION="help" ;;
                *) error "未知参数: $1"; return 1 ;;
            esac
            ;;
        2)
            if [[ "$1" == "install" && ( "$2" == "--yes" || "$2" == "-y" ) ]]; then
                XANMOD_ASSUME_YES=true
            else
                error "无效参数组合: $*"
                return 1
            fi
            ;;
        *)
            error "参数过多"
            return 1
            ;;
    esac
}

show_help() {
    cat <<'EOF'
用法：
  xanmod-install.sh [install] [--yes|-y]
                                 先执行只读规划；必要时安装或修复 XanMod
  xanmod-install.sh status       查看 XanMod 状态
  xanmod-install.sh help         显示本帮助

不支持、非 amd64、x86-64-v1，或目标包和正式仓库文件已严格安全有效时，无需授权。
只有计划确实包含修改时才使用 [y/N]；无交互终端时必须显式传入 --yes。
EOF
}

main() {
    local authorization_status=0
    local execution_status=0

    if ! parse_xanmod_arguments "$@"; then
        show_help
        return 1
    fi

    case "$XANMOD_ACTION" in
        help)
            show_help
            return 0
            ;;
        status)
            require_commands awk dpkg dpkg-query grep sort stat tr uname || return 1
            show_xanmod_status
            return 0
            ;;
    esac

    require_commands awk dpkg dpkg-query grep sort stat tr uname || return 1
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

    require_root || return 1
    require_commands apt-cache apt-get awk basename cat chgrp chmod chown cp curl dirname dpkg \
        dpkg-query flock grep id install mktemp mv readlink rm sort stat tr uname || return 1
    run_locked_xanmod_plan || execution_status=$?
    if (( execution_status == 0 )); then
        show_xanmod_status
    fi
    return "$execution_status"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    trap 'error "XanMod 安装脚本在第 $LINENO 行执行失败"' ERR
    main "$@"
fi
