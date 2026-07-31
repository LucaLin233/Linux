#!/usr/bin/env bash
# XanMod Kernel Installer for Debian
# 内容与 modules/system-customize.sh 的 XanMod 功能保持一致。

set -euo pipefail

readonly XANMOD_KEYRING="/etc/apt/keyrings/xanmod-archive-keyring.gpg"
readonly XANMOD_SOURCE_LIST="/etc/apt/sources.list.d/xanmod-release.list"
readonly XANMOD_SOURCE_DEB822="/etc/apt/sources.list.d/xanmod-release.sources"
readonly XANMOD_KEY_FINGERPRINT="D38D7D1DA1349567ADED882D86F7D09EE734E623"
readonly XANMOD_KEY_URL="https://dl.xanmod.org/archive.key"
readonly XANMOD_KEY_FALLBACK_OPENPGP="https://keys.openpgp.org/vks/v1/by-fingerprint/${XANMOD_KEY_FINGERPRINT}"
readonly XANMOD_KEY_FALLBACK_UBUNTU="https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x${XANMOD_KEY_FINGERPRINT}"
readonly XANMOD_REPOSITORIES=(
    "https://deb.xanmod.org"
    "https://mirror.nju.edu.cn/xanmod"
    "https://mirrors.bfsu.edu.cn/xanmod"
    "https://mirrors.tuna.tsinghua.edu.cn/xanmod"
)

log() {
    local msg="$1" level="${2:-info}"
    local -A colors=([info]="\033[0;36m" [warn]="\033[0;33m" [error]="\033[0;31m" [success]="\033[0;32m")
    echo -e "${colors[$level]:-\033[0m}${msg}\033[0m"
}
info() { log "$1" info; }
warn() { log "$1" warn; }
error() { log "$1" error; }
success() { log "$1" success; }

require_root() { (( EUID == 0 )) || { error "需要 root 权限运行"; exit 1; }; }
ask_yes_no() { local choice; read -r -p "$1" choice; choice="${choice:-${2:-Y}}"; [[ "$choice" =~ ^[Yy]$ ]]; }

ensure_package() {
    local command_name="$1" package_name="$2"
    command -v "$command_name" >/dev/null 2>&1 && return 0
    info "安装依赖包: $package_name"
    apt-get update -qq && apt-get install -y "$package_name" && command -v "$command_name" >/dev/null 2>&1
}

get_debian_codename() {
    if [[ -r /etc/os-release ]]; then
        . /etc/os-release
        [[ -n "${VERSION_CODENAME:-}" ]] && { echo "$VERSION_CODENAME"; return 0; }
    fi
    command -v lsb_release >/dev/null 2>&1 && lsb_release -sc
}

is_amd64() {
    [[ "$(dpkg --print-architecture)" == amd64 ]] && [[ "$(uname -m)" == x86_64 || "$(uname -m)" == amd64 ]]
}

package_is_installed() { dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null | grep -qx installed; }

get_running_xanmod_package() {
    case "$(uname -r)" in
        *-x64v3-xanmod*) echo linux-xanmod-x64v3 ;;
        *-x64v2-xanmod*) echo linux-xanmod-x64v2 ;;
        *) return 1 ;;
    esac
}

detect_x86_64_psabi_level() {
    local cpuinfo_file="${1:-/proc/cpuinfo}"
    [[ -r "$cpuinfo_file" ]] || return 3
    awk '
        function has(name) { return index(flags, " " name " ") > 0 }
        BEGIN { found = 0 }
        /^flags[[:space:]]*:/ {
            found = 1; flags = " " $0 " "; level = 0
            if (has("lm") && has("cmov") && has("cx8") && has("fpu") && has("fxsr") && has("mmx") && has("syscall") && has("sse2")) level = 1
            if (level == 1 && has("cx16") && has("lahf_lm") && has("popcnt") && has("sse4_1") && has("sse4_2") && has("ssse3")) level = 2
            if (level == 2 && has("avx") && has("avx2") && has("bmi1") && has("bmi2") && has("f16c") && has("fma") && (has("abm") || has("lzcnt")) && has("movbe") && has("xsave")) level = 3
            if (level == 3 && has("avx512f") && has("avx512bw") && has("avx512cd") && has("avx512dq") && has("avx512vl")) level = 4
            if (level > 0) { print "v" level; exit 0 }; exit 2
        }
        END { if (!found) exit 3 }
    ' "$cpuinfo_file"
}

get_xanmod_package_for_psabi_level() {
    case "$1" in v4|v3) echo linux-xanmod-x64v3 ;; v2) echo linux-xanmod-x64v2 ;; *) return 1 ;; esac
}

detect_xanmod_package() {
    local level
    is_amd64 || return 1
    level=$(detect_x86_64_psabi_level) && get_xanmod_package_for_psabi_level "$level"
}

key_has_expected_fingerprint() {
    local key_file="$1" fingerprint
    fingerprint=$(gpg --batch --show-keys --with-colons "$key_file" 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }')
    [[ "$fingerprint" == "$XANMOD_KEY_FINGERPRINT" ]]
}

install_xanmod_key() {
    local key_temp url
    if [[ -s "$XANMOD_KEYRING" ]] && key_has_expected_fingerprint "$XANMOD_KEYRING"; then
        return 0
    fi

    [[ -e "$XANMOD_KEYRING" ]] && warn "现有 XanMod 密钥指纹无效，将重新获取"
    key_temp=$(mktemp) || return 1
    trap 'rm -f "$key_temp"' RETURN

    for url in "$XANMOD_KEY_URL" "$XANMOD_KEY_FALLBACK_OPENPGP" "$XANMOD_KEY_FALLBACK_UBUNTU"; do
        info "获取 XanMod 签名密钥: $url"
        if curl -fsSL --connect-timeout 10 --max-time 30 "$url" -o "$key_temp" && key_has_expected_fingerprint "$key_temp"; then
            if gpg --batch --yes --dearmor --output "${XANMOD_KEYRING}.new" "$key_temp" && key_has_expected_fingerprint "${XANMOD_KEYRING}.new"; then
                chmod 644 "${XANMOD_KEYRING}.new"
                mv -f "${XANMOD_KEYRING}.new" "$XANMOD_KEYRING"
                success "XanMod 签名密钥已验证并安装"
                trap - RETURN
                rm -f "$key_temp"
                return 0
            fi
            rm -f "${XANMOD_KEYRING}.new"
        fi
        warn "该密钥来源不可用或指纹不匹配，尝试下一个来源"
        : > "$key_temp"
    done

    trap - RETURN
    rm -f "$key_temp"
    error "无法获得指纹为 $XANMOD_KEY_FINGERPRINT 的 XanMod 签名密钥"
    return 1
}

write_deb822_source() {
    local file="$1" repository="$2" codename="$3"
    cat > "$file" <<EOF
Types: deb
URIs: $repository
Suites: $codename
Components: main
Signed-By: $XANMOD_KEYRING
EOF
}

xanmod_source_is_usable() {
    local source_file="$1"
    apt-get update -qq \
        -o "Dir::Etc::sourcelist=$source_file" \
        -o 'Dir::Etc::sourceparts=-' \
        -o 'APT::Get::List-Cleanup=0'
}

xanmod_deb822_source_configured() {
    [[ -s "$XANMOD_KEYRING" ]] && key_has_expected_fingerprint "$XANMOD_KEYRING" &&
        [[ -f "$XANMOD_SOURCE_DEB822" ]] &&
        grep -Eiq '^[[:space:]]*URIs:[[:space:]]*https://[^[:space:]]*xanmod[^[:space:]]*[[:space:]]*$' "$XANMOD_SOURCE_DEB822" &&
        grep -Fiq "Signed-By: $XANMOD_KEYRING" "$XANMOD_SOURCE_DEB822"
}

get_xanmod_source_file() {
    xanmod_deb822_source_configured && echo "$XANMOD_SOURCE_DEB822"
}

configure_xanmod_repository() {
    local codename source_file candidate selected="" probe_file
    ensure_package gpg gpg || { error "无法安装 GnuPG"; return 1; }
    codename=$(get_debian_codename) || { error "无法识别 Debian 发行版代号"; return 1; }
    install -d -m 0755 /etc/apt/keyrings
    install_xanmod_key || return 1

    if source_file=$(get_xanmod_source_file) && xanmod_source_is_usable "$source_file"; then
        echo "XanMod 软件源: 已配置并可用（$source_file）"
        return 0
    fi
    [[ -n "${source_file:-}" ]] && warn "现有 XanMod 软件源不可用，重新选择镜像"

    probe_file=$(mktemp --suffix=.sources) || return 1
    trap 'rm -f "$probe_file"' RETURN
    for candidate in "${XANMOD_REPOSITORIES[@]}"; do
        info "探测 XanMod 软件源: $candidate"
        write_deb822_source "$probe_file" "$candidate" "$codename"
        if xanmod_source_is_usable "$probe_file"; then
            selected="$candidate"
            break
        fi
        warn "软件源不可用: $candidate"
    done

    if [[ -z "$selected" ]]; then
        trap - RETURN
        rm -f "$probe_file"
        error "所有 XanMod 软件源均不可用，未修改正式 APT 配置"
        return 1
    fi

    install -m 644 "$probe_file" "${XANMOD_SOURCE_DEB822}.new"
    mv -f "${XANMOD_SOURCE_DEB822}.new" "$XANMOD_SOURCE_DEB822"
    rm -f "$XANMOD_SOURCE_LIST"
    trap - RETURN
    rm -f "$probe_file"
    echo "XanMod 软件源: 已配置（Deb822 / $codename / $selected）"
}

get_installed_xanmod_packages() {
    dpkg-query -W -f='${binary:Package} ${db:Status-Status}\n' 'linux-xanmod-*' 2>/dev/null |
        awk '$2 == "installed" { sub(/:amd64$/, "", $1); print $1 }' | sort -u
}

install_xanmod() {
    local target_package installed_packages install_choice
    echo "XanMod 将在兼容时自动安装；Debian 原内核会保留，重启后才生效。"
    ask_yes_no "是否安装 XanMod 内核？[Y/n]: " Y || { echo "XanMod 内核: 已跳过"; return 0; }
    if ! is_amd64; then
        warn "当前架构为 $(dpkg --print-architecture) / $(uname -m)，XanMod APT 仓库仅提供 amd64 内核包"
        return 0
    fi
    if ! target_package=$(detect_xanmod_package); then
        case $? in
            2) warn "当前 CPU 仅达到 x86-64-v1，不支持 XanMod MAIN 所需的 x86-64-v2" ;;
            3) target_package=$(get_running_xanmod_package || true); warn "无法读取本机 CPU 指令集" ;;
            *) warn "无法确认适用的 XanMod 内核包" ;;
        esac
        [[ -n "${target_package:-}" ]] || { warn "为避免安装不兼容内核，已保留 Debian 原内核"; return 0; }
    fi
    echo "检测到适合当前环境的 XanMod 包: $target_package"
    installed_packages=$(get_installed_xanmod_packages || true)
    if package_is_installed "$target_package"; then
        echo "XanMod 目标包: 已安装（$target_package）"
        echo "当前内核: $(uname -r)（目标内核将在下次重启后生效，如尚未运行）"
        return 0
    fi
    if [[ -n "$installed_packages" ]]; then
        warn "已安装的 XanMod 包与 CPU 检测结果不匹配: $(tr '\n' ' ' <<< "$installed_packages")"
        read -r -p "是否安装检测到的正确版本 $target_package？[Y/n]: " install_choice
        [[ "${install_choice:-Y}" =~ ^[Yy]$ ]] || { echo "XanMod 内核: 保留现有安装"; return 0; }
    fi
    configure_xanmod_repository || return 1
    info "更新软件包索引..."
    apt-get update || { error "APT 索引更新失败"; return 1; }
    info "安装 XanMod 内核包: $target_package"
    apt-get install -y "$target_package" || { error "XanMod 内核安装失败"; return 1; }
    package_is_installed "$target_package" || { error "XanMod 内核安装后验证失败"; return 1; }
    success "XanMod 内核已安装: $target_package"
    echo "当前运行内核: $(uname -r)"
    echo "说明: Debian 原内核未被移除；XanMod 将在下次系统重启后生效。"
}

show_xanmod_status() {
    local level="" recommended="" source_file="" installed
    echo; echo "XanMod 状态："
    echo "  当前架构: $(dpkg --print-architecture) / $(uname -m)"
    echo "  当前内核: $(uname -r)"
    if level=$(detect_x86_64_psabi_level); then recommended=$(get_xanmod_package_for_psabi_level "$level" || true); echo "  CPU psABI: x86-64-$level"; else echo "  CPU psABI: 无法确认或不受 MAIN 支持"; fi
    echo "  推荐包: ${recommended:-无}"
    echo "  当前运行包: $(get_running_xanmod_package || echo 无)"
    if [[ -s "$XANMOD_KEYRING" ]] && key_has_expected_fingerprint "$XANMOD_KEYRING"; then echo "  签名密钥: 已验证"; else echo "  签名密钥: 未配置或校验失败"; fi
    if source_file=$(get_xanmod_source_file); then echo "  软件源: 已配置（$source_file）"; else echo "  软件源: 未配置或校验失败"; fi
    installed=$(get_installed_xanmod_packages || true)
    echo "  已安装包: ${installed//$'\n'/ }"
}

show_help() { cat <<'EOF'
用法：
  xanmod-install.sh          检查并可选安装 XanMod 内核
  xanmod-install.sh status   查看 XanMod 状态
  xanmod-install.sh help     显示本帮助
EOF
}

main() {
    local action="${1:-install}" required_command
    require_root
    for required_command in apt-get awk curl dpkg gpg grep install mktemp mv rm sort tr uname; do
        command -v "$required_command" >/dev/null 2>&1 || { error "缺少必要命令: $required_command"; exit 1; }
    done
    case "$action" in
        install) install_xanmod; show_xanmod_status ;;
        status) show_xanmod_status ;;
        help|--help|-h) show_help ;;
        *) error "未知参数: $action"; show_help; exit 1 ;;
    esac
}

trap 'error "XanMod 安装脚本在第 $LINENO 行执行失败"' ERR
main "$@"
