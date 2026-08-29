#!/usr/bin/env bash
# XanMod Kernel Installer for Debian/Ubuntu
# 内容与 modules/system-customize.sh 的 XanMod 功能保持一致。
#
# 用法：
#   bash xanmod-install.sh                  # 交互确认后安装 XanMod 内核
#   bash xanmod-install.sh --yes            # 非交互授权安装
#   bash xanmod-install.sh install --yes    # 非交互授权安装
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

XANMOD_ACTION="install"
XANMOD_ASSUME_YES=false
XANMOD_RUNTIME_SNAPSHOT_DIR=""
XANMOD_TRANSACTION_ACTIVE=false
XANMOD_STAGED_KEY=""
XANMOD_STAGED_SOURCE=""
XANMOD_SELECTED_REPOSITORY=""

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

prepare_xanmod_transaction() {
    :
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

parse_xanmod_arguments() {
    XANMOD_ACTION="install"
    XANMOD_ASSUME_YES=false

    case $# in
        0)
            ;;
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
                                 检查并安装 XanMod 内核
  xanmod-install.sh status       查看 XanMod 状态
  xanmod-install.sh help         显示本帮助

安装默认使用 [y/N] 确认。无交互终端时必须显式传入 --yes。
EOF
}

main() {
    local authorization_status=0

    if ! parse_xanmod_arguments "$@"; then
        show_help
        return 1
    fi

    case "$XANMOD_ACTION" in
        help)
            show_help
            ;;
        status)
            require_commands awk dpkg dpkg-query grep sort tr uname || return 1
            show_xanmod_status
            ;;
        install)
            authorize_xanmod_install || authorization_status=$?
            case "$authorization_status" in
                0) ;;
                2) return 0 ;;
                *) return 1 ;;
            esac

            require_root || return 1
            require_commands apt-cache apt-get awk basename cat chmod cp curl dirname dpkg \
                dpkg-query flock grep install mktemp mv rm sort tr uname || return 1
            take_xanmod_lock || return 1
            install_xanmod
            show_xanmod_status
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    trap 'error "XanMod 安装脚本在第 $LINENO 行执行失败"' ERR
    main "$@"
fi
