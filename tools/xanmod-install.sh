#!/usr/bin/env bash
# XanMod Kernel Installer for Debian
# 功能：自动检测 x86-64-v3/v2 并安装对应 XanMod MAIN 内核
#
# 用法：
#   bash xanmod-install.sh

set -euo pipefail

readonly XANMOD_KEYRING="/etc/apt/keyrings/xanmod-archive-keyring.gpg"
readonly XANMOD_SOURCE="/etc/apt/sources.list.d/xanmod-release.list"
readonly XANMOD_KEY_URL="https://dl.xanmod.org/archive.key"
readonly XANMOD_REPO_URL="http://deb.xanmod.org"
readonly XANMOD_PSABI_CHECK_URL="https://dl.xanmod.org/check_x86-64_psabi.sh"

log() {
    local message="$1"
    local level="${2:-info}"
    local -A colors=(
        [info]="\033[0;36m"
        [warn]="\033[0;33m"
        [error]="\033[0;31m"
        [success]="\033[0;32m"
    )

    echo -e "${colors[$level]:-\033[0m}${message}\033[0m"
}

info() {
    log "ℹ️  $1" "info"
}

warn() {
    log "⚠️  $1" "warn"
}

error() {
    log "❌ $1" "error"
}

success() {
    log "✅ $1" "success"
}

require_root() {
    if (( EUID != 0 )); then
        error "需要 root 权限运行"
        exit 1
    fi
}

package_installed() {
    local package="$1"

    dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null |
        grep -qx "installed"
}

is_amd64() {
    [[ "$(dpkg --print-architecture)" == "amd64" ]] &&
        [[ "$(uname -m)" == "x86_64" || "$(uname -m)" == "amd64" ]]
}

get_debian_codename() {
    if [[ -r /etc/os-release ]]; then
        . /etc/os-release

        if [[ -n "${VERSION_CODENAME:-}" ]]; then
            echo "$VERSION_CODENAME"
            return 0
        fi
    fi

    return 1
}

get_running_xanmod_package() {
    case "$(uname -r)" in
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

detect_psabi_level() {
    local checker
    local result

    checker="$1/psabi-check.awk"

    if ! curl -fsSL \
        --connect-timeout 10 \
        --max-time 30 \
        "$XANMOD_PSABI_CHECK_URL" \
        -o "$checker"; then
        return 1
    fi

    [[ -s "$checker" ]] || return 1

    if ! result=$(awk -f "$checker" 2>/dev/null); then
        return 1
    fi

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

detect_target_package() {
    local work_dir="$1"
    local running_package
    local psabi_level

    # 当前已经成功运行的 XanMod 内核最可信。
    if running_package=$(get_running_xanmod_package); then
        echo "$running_package"
        return 0
    fi

    # 已安装的元包次之，避免脚本擅自切换 v2/v3。
    if package_installed "linux-xanmod-x64v3"; then
        echo "linux-xanmod-x64v3"
        return 0
    fi

    if package_installed "linux-xanmod-x64v2"; then
        echo "linux-xanmod-x64v2"
        return 0
    fi

    if ! psabi_level=$(detect_psabi_level "$work_dir"); then
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

xanmod_source_exists() {
    grep -Rqs "deb.xanmod.org" \
        /etc/apt/sources.list \
        /etc/apt/sources.list.d 2>/dev/null
}

configure_xanmod_repository() {
    local work_dir="$1"
    local codename
    local key_file="$work_dir/xanmod-archive.key"
    local keyring_temp="$work_dir/xanmod-archive-keyring.gpg"

    if xanmod_source_exists; then
        info "检测到已有 XanMod 软件源，保留现有配置"
        return 0
    fi

    codename=$(get_debian_codename) || {
        error "无法识别 Debian 发行版代号"
        return 1
    }

    info "配置 XanMod 官方 APT 软件源..."

    if ! curl -fsSL \
        --connect-timeout 10 \
        --max-time 30 \
        "$XANMOD_KEY_URL" \
        -o "$key_file"; then
        error "XanMod 签名密钥下载失败"
        return 1
    fi

    if [[ ! -s "$key_file" ]]; then
        error "XanMod 签名密钥为空"
        return 1
    fi

    if ! gpg --dearmor --yes \
        --output "$keyring_temp" \
        "$key_file"; then
        error "XanMod 签名密钥转换失败"
        return 1
    fi

    install -d -m 0755 /etc/apt/keyrings
    install -m 0644 "$keyring_temp" "$XANMOD_KEYRING"

    cat > "$XANMOD_SOURCE" <<EOF
deb [signed-by=$XANMOD_KEYRING] $XANMOD_REPO_URL $codename main
EOF

    success "XanMod 软件源已配置（$codename）"
}

main() {
    require_root

    if ! is_amd64; then
        warn "当前架构：$(dpkg --print-architecture) / $(uname -m)"
        warn "XanMod 官方 APT 仓库目前仅提供 amd64 内核包，已退出。"
        exit 0
    fi

    local work_dir
    local target_package

    if ! work_dir=$(mktemp -d); then
        error "无法创建临时目录"
        exit 1
    fi

    trap 'rm -rf -- "$work_dir"' EXIT

    info "安装 XanMod 所需依赖..."
    apt-get update
    apt-get install -y curl gpg gpg-agent dirmngr

    if ! target_package=$(detect_target_package "$work_dir"); then
        warn "CPU 不支持 XanMod MAIN 所需的 x86-64-v2 指令集。"
        warn "为避免安装不兼容内核，保持 Debian 原内核。"
        exit 0
    fi

    echo "目标 XanMod 包: $target_package"

    if package_installed "$target_package"; then
        success "XanMod 元包已安装：$target_package"
        echo "当前运行内核: $(uname -r)"

        if [[ "$(uname -r)" == *"-xanmod"* ]]; then
            echo "状态: XanMod 内核已生效"
        else
            echo "状态: XanMod 将在下次重启后生效"
        fi

        exit 0
    fi

    configure_xanmod_repository "$work_dir"

    info "更新软件包索引..."
    apt-get update

    info "安装 XanMod 内核: $target_package"

    if ! apt-get install -y "$target_package"; then
        error "XanMod 内核安装失败"
        exit 1
    fi

    if ! package_installed "$target_package"; then
        error "XanMod 内核安装后验证失败"
        exit 1
    fi

    success "XanMod 内核已安装：$target_package"
    echo "当前运行内核: $(uname -r)"
    echo "Debian 原内核未被移除。请重启系统以切换到 XanMod。"
}

main "$@"
