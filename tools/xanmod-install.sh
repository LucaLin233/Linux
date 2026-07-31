#!/usr/bin/env bash
# XanMod Kernel Installer for Debian
# 内容与 modules/system-customize.sh 的 XanMod 功能保持一致。
#
# 用法：
#   bash xanmod-install.sh          # 检查并可选安装 XanMod 内核
#   bash xanmod-install.sh status   # 查看 XanMod 状态

set -euo pipefail

readonly XANMOD_KEYRING="/etc/apt/keyrings/xanmod-archive-keyring.gpg"
readonly XANMOD_SOURCE_LIST="/etc/apt/sources.list.d/xanmod-release.list"
readonly XANMOD_SOURCE_DEB822="/etc/apt/sources.list.d/xanmod-release.sources"
readonly XANMOD_KEY_FINGERPRINT="D38D7D1DA1349567ADED882D86F7D09EE734E623"
readonly XANMOD_KEY_URL="https://dl.xanmod.org/archive.key"
readonly XANMOD_KEY_FALLBACK_UBUNTU="https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x${XANMOD_KEY_FINGERPRINT}"
readonly XANMOD_REPOSITORIES=(
    "https://deb.xanmod.org"
    "https://mirror.nju.edu.cn/xanmod"
    "https://mirrors.bfsu.edu.cn/xanmod"
    "https://mirrors.tuna.tsinghua.edu.cn/xanmod"
)

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
        exit 1
    fi
}

ask_yes_no() {
    local prompt="$1" default="${2:-Y}" choice
    read -r -p "$prompt" choice
    choice="${choice:-$default}"
    [[ "$choice" =~ ^[Yy]$ ]]
}

ensure_package() {
    local command_name="$1" package_name="$2"
    if command -v "$command_name" >/dev/null 2>&1; then return 0; fi
    info "安装依赖包: $package_name"
    if ! apt-get update -qq; then error "无法更新软件包索引，无法安装 $package_name"; return 1; fi
    if ! apt-get install -y "$package_name"; then error "安装依赖包失败: $package_name"; return 1; fi
    if ! command -v "$command_name" >/dev/null 2>&1; then error "依赖命令仍不可用: $command_name"; return 1; fi
}

get_debian_codename() {
    if [[ -r /etc/os-release ]]; then . /etc/os-release; if [[ -n "${VERSION_CODENAME:-}" ]]; then echo "$VERSION_CODENAME"; return 0; fi; fi
    if command -v lsb_release >/dev/null 2>&1; then lsb_release -sc; return 0; fi
    return 1
}

is_amd64() { [[ "$(dpkg --print-architecture)" == "amd64" ]] && [[ "$(uname -m)" == "x86_64" || "$(uname -m)" == "amd64" ]]; }
package_is_installed() { dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null | grep -qx "installed"; }

get_running_xanmod_package() {
    case "$(uname -r)" in
        *-x64v3-xanmod*) echo "linux-xanmod-x64v3" ;;
        *-x64v2-xanmod*) echo "linux-xanmod-x64v2" ;;
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
get_xanmod_package_for_psabi_level() { case "$1" in v4|v3) echo "linux-xanmod-x64v3" ;; v2) echo "linux-xanmod-x64v2" ;; *) return 1 ;; esac; }
detect_xanmod_package() { local psabi_level; is_amd64 || return 1; if psabi_level=$(detect_x86_64_psabi_level); then get_xanmod_package_for_psabi_level "$psabi_level"; else return $?; fi; }

get_primary_key_fingerprint() {
    gpg --batch --show-keys --with-colons "$1" 2>/dev/null | awk -F: '$1 == "pub" && !seen_pub { seen_pub = 1; next } seen_pub && $1 == "fpr" { print $10; exit }'
}

xanmod_keyring_valid() {
    local key_file="${1:-$XANMOD_KEYRING}" fingerprint
    [[ -s "$key_file" ]] || return 1
    fingerprint=$(get_primary_key_fingerprint "$key_file") || return 1
    [[ "$fingerprint" == "$XANMOD_KEY_FINGERPRINT" ]] || return 1
    gpg --batch --show-keys --with-colons "$key_file" 2>/dev/null | awk -F: '$1 == "uid" { found = 1 } END { exit !found }'
}

install_xanmod_key() {
    local key_temp key_new="${XANMOD_KEYRING}.new" key_url
    xanmod_keyring_valid && return 0
    if [[ -e "$XANMOD_KEYRING" ]]; then warn "现有 XanMod 密钥指纹不匹配或缺少 UID 绑定，将重新获取"; fi
    key_temp=$(mktemp) || return 1
    trap 'rm -f "$key_temp" "$key_new"' RETURN
    rm -f "$key_new"
    for key_url in "$XANMOD_KEY_URL" "$XANMOD_KEY_FALLBACK_UBUNTU"; do
        info "下载 XanMod 软件源签名密钥: $key_url"
        if ! curl -fsSL --connect-timeout 10 --max-time 30 "$key_url" -o "$key_temp"; then warn "该密钥来源下载失败，尝试下一个来源"; continue; fi
        if ! xanmod_keyring_valid "$key_temp"; then warn "该密钥来源的主密钥指纹不匹配或缺少 UID 绑定，尝试下一个来源"; continue; fi
        rm -f "$key_new"
        if ! gpg --batch --yes --dearmor --output "$key_new" "$key_temp"; then warn "XanMod 签名密钥转换失败，尝试下一个来源"; continue; fi
        if ! xanmod_keyring_valid "$key_new"; then warn "转换后的 XanMod 密钥指纹不匹配或缺少 UID 绑定，尝试下一个来源"; continue; fi
        chmod 644 "$key_new"; mv -f "$key_new" "$XANMOD_KEYRING"; rm -f "$key_temp"; trap - RETURN
        success "XanMod 签名密钥已验证并安装"; return 0
    done
    rm -f "$key_temp" "$key_new"; trap - RETURN
    error "无法获得指纹为 $XANMOD_KEY_FINGERPRINT 的 XanMod 签名密钥"; return 1
}

xanmod_source_has_supported_uri() { grep -Eiq '^[[:space:]]*URIs:[[:space:]]*https://(deb\.xanmod\.org|mirror\.nju\.edu\.cn/xanmod|mirrors\.bfsu\.edu\.cn/xanmod|mirrors\.tuna\.tsinghua\.edu\.cn/xanmod)/?[[:space:]]*$' "$1"; }
xanmod_list_source_configured() { [[ -s "$XANMOD_KEYRING" ]] && xanmod_keyring_valid && [[ -f "$XANMOD_SOURCE_LIST" ]] && grep -Eiq 'https://(deb\.xanmod\.org|mirror\.nju\.edu\.cn/xanmod|mirrors\.bfsu\.edu\.cn/xanmod|mirrors\.tuna\.tsinghua\.edu\.cn/xanmod)/?' "$XANMOD_SOURCE_LIST" && grep -Fiq "signed-by=$XANMOD_KEYRING" "$XANMOD_SOURCE_LIST"; }
xanmod_deb822_source_configured() { [[ -s "$XANMOD_KEYRING" ]] && xanmod_keyring_valid && [[ -f "$XANMOD_SOURCE_DEB822" ]] && xanmod_source_has_supported_uri "$XANMOD_SOURCE_DEB822" && grep -Fiq "Signed-By: $XANMOD_KEYRING" "$XANMOD_SOURCE_DEB822"; }
get_xanmod_source_file() { if xanmod_deb822_source_configured; then echo "$XANMOD_SOURCE_DEB822"; elif xanmod_list_source_configured; then echo "$XANMOD_SOURCE_LIST"; else return 1; fi; }

write_xanmod_deb822_source() {
    cat > "$1" <<EOF
Types: deb
URIs: $2
Suites: $3
Components: main
Signed-By: $XANMOD_KEYRING
EOF
}

xanmod_source_is_usable() {
    local source_file="$1" lists_temp apt_status
    lists_temp=$(mktemp -d) || return 1
    if ! chmod 0755 "$lists_temp"; then rm -rf -- "$lists_temp"; return 1; fi
    install -d -m 0755 "$lists_temp/partial"
    if apt-get update -qq -o "Dir::Etc::sourcelist=$source_file" -o 'Dir::Etc::sourceparts=-' -o "Dir::State::lists=$lists_temp" -o 'APT::Get::List-Cleanup=0'; then apt_status=0; else apt_status=$?; fi
    rm -rf -- "$lists_temp"
    return "$apt_status"
}

configure_xanmod_repository() {
    local codename source_file source_temp source_new="${XANMOD_SOURCE_DEB822}.new" repository selected_repository=""
    ensure_package "gpg" "gpg" || return 1
    codename=$(get_debian_codename) || { error "无法识别 Debian 发行版代号"; return 1; }
    install -d -m 0755 /etc/apt/keyrings
    install_xanmod_key || return 1
    if source_file=$(get_xanmod_source_file); then
        if xanmod_source_is_usable "$source_file"; then echo "XanMod 软件源: 已配置并可用（$source_file）"; return 0; fi
        warn "现有 XanMod 软件源不可用，将重新选择镜像"
    fi
    source_temp=$(mktemp --suffix=.sources) || return 1
    trap 'rm -f "$source_temp" "$source_new"' RETURN
    rm -f "$source_new"
    for repository in "${XANMOD_REPOSITORIES[@]}"; do
        info "探测 XanMod 软件源: $repository"; write_xanmod_deb822_source "$source_temp" "$repository" "$codename"
        if xanmod_source_is_usable "$source_temp"; then selected_repository="$repository"; break; fi
        warn "XanMod 软件源不可用: $repository"
    done
    if [[ -z "$selected_repository" ]]; then rm -f "$source_temp" "$source_new"; trap - RETURN; error "所有 XanMod 软件源均不可用，未修改正式 APT 配置"; return 1; fi
    install -m 644 "$source_temp" "$source_new"; mv -f "$source_new" "$XANMOD_SOURCE_DEB822"; rm -f "$XANMOD_SOURCE_LIST"; rm -f "$source_temp"; trap - RETURN
    echo "XanMod 软件源: 已配置（Deb822 / $codename / $selected_repository）"
}

get_installed_xanmod_packages() { dpkg-query -W -f='${binary:Package} ${db:Status-Status}\n' "linux-xanmod-*" 2>/dev/null | awk '$2 == "installed" { sub(/:amd64$/, "", $1); print $1 }' | sort -u; }

install_xanmod() {
    local target_package installed_packages install_choice
    echo "XanMod 将在兼容时自动安装；Debian 原内核会保留，重启后才生效。"
    if ! ask_yes_no "是否安装 XanMod 内核？[Y/n]: " "Y"; then echo "XanMod 内核: 已跳过"; return 0; fi
    if ! is_amd64; then warn "当前架构为 $(dpkg --print-architecture) / $(uname -m)"; warn "XanMod 官方 APT 仓库目前仅提供 amd64 内核包，已跳过安装"; return 0; fi
    if target_package=$(detect_xanmod_package); then :; else
        case $? in
            2) warn "当前 CPU 仅达到 x86-64-v1，不支持 XanMod MAIN 所需的 x86-64-v2" ;;
            3) target_package=$(get_running_xanmod_package || true); if [[ -n "$target_package" ]]; then warn "无法读取本机 CPU 指令集，沿用当前已运行的 XanMod 分支: $target_package"; else warn "无法读取本机 CPU 指令集，跳过 XanMod 安装"; fi ;;
            *) warn "无法确认适用的 XanMod 内核包" ;;
        esac
        if [[ -z "${target_package:-}" ]]; then warn "为避免安装不兼容内核，已保留 Debian 原内核"; return 0; fi
    fi
    echo "检测到适合当前环境的 XanMod 包: $target_package"
    installed_packages=$(get_installed_xanmod_packages || true)
    if package_is_installed "$target_package"; then
        echo "XanMod 目标包: 已安装（$target_package）"
        if [[ "$(get_running_xanmod_package || true)" == "$target_package" ]]; then echo "当前内核: $(uname -r)（匹配 CPU 检测结果）"; else echo "当前内核: $(uname -r)（目标内核将在下次重启后生效）"; fi
        return 0
    fi
    if [[ -n "$installed_packages" ]]; then
        warn "已安装的 XanMod 包与 CPU 检测结果不匹配: $(tr '\n' ' ' <<< "$installed_packages")"; warn "建议安装: $target_package"
        read -r -p "是否安装检测到的正确版本 $target_package？[Y/n]: " install_choice; install_choice="${install_choice:-Y}"
        if [[ ! "$install_choice" =~ ^[Yy]$ ]]; then echo "XanMod 内核: 保留现有安装"; return 0; fi
        echo "说明: 旧 XanMod 包将保留，确认新内核可正常启动后再手动清理。"
    fi
    configure_xanmod_repository || return 1
    info "更新软件包索引..."
    if ! apt-get update; then error "XanMod 软件源索引更新失败"; return 1; fi
    info "安装 XanMod 内核包: $target_package"
    if ! apt-get install -y "$target_package"; then error "XanMod 内核安装失败"; return 1; fi
    if ! package_is_installed "$target_package"; then error "XanMod 内核安装后验证失败"; return 1; fi
    success "XanMod 内核已安装: $target_package"; echo "当前运行内核: $(uname -r)"; echo "说明: Debian 原内核未被移除；XanMod 将在下次系统重启后生效。"
}

show_xanmod_status() {
    local psabi_level="" recommended_package="" running_package="" source_file="" installed_packages
    echo; echo "XanMod 状态："; echo "  当前架构: $(dpkg --print-architecture) / $(uname -m)"; echo "  当前内核: $(uname -r)"
    if psabi_level=$(detect_x86_64_psabi_level); then echo "  CPU psABI: x86-64-$psabi_level"; recommended_package=$(get_xanmod_package_for_psabi_level "$psabi_level" || true); else case $? in 2) echo "  CPU psABI: x86-64-v1（MAIN 不支持）" ;; *) echo "  CPU psABI: 无法确认" ;; esac; fi
    running_package=$(get_running_xanmod_package || true)
    if [[ -n "$running_package" ]]; then echo "  当前运行包: $running_package"; else echo "  当前运行包: 无（当前为非 XanMod 内核）"; fi
    if [[ -n "$recommended_package" ]]; then echo "  推荐包: $recommended_package"; elif [[ -n "$running_package" ]]; then echo "  推荐包: 无法检测；当前运行包可作为兼容性证据"; else echo "  推荐包: 无"; fi
    if source_file=$(get_xanmod_source_file); then case "$source_file" in *.sources) echo "  软件源: 已配置（Deb822）" ;; *) echo "  软件源: 已配置（传统 list）" ;; esac; echo "  软件源文件: $source_file"; else echo "  软件源: 未配置或配置未通过校验"; fi
    installed_packages=$(get_installed_xanmod_packages || true)
    if [[ -n "$installed_packages" ]]; then echo "  已安装包: $(tr '\n' ' ' <<< "$installed_packages")"; else echo "  已安装包: 无"; fi
}

show_help() {
    cat <<'EOF'
用法：
  xanmod-install.sh          检查并可选安装 XanMod 内核
  xanmod-install.sh status   查看 XanMod 状态
  xanmod-install.sh help     显示本帮助
EOF
}

main() {
    local action="${1:-install}"
    require_root
    local required_command
    for required_command in apt-get awk cat chmod curl dpkg grep install mktemp mv rm sort tr uname; do
        if ! command -v "$required_command" >/dev/null 2>&1; then error "缺少必要命令: $required_command"; exit 1; fi
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
