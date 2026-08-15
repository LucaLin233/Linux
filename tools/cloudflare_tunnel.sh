#!/usr/bin/env bash
# Cloudflare Tunnel manager for Debian/Ubuntu.
# Uses Cloudflare's official stable APT repository and service command.

set -euo pipefail

readonly KEYRING="${CLOUDFLARED_KEYRING:-/usr/share/keyrings/cloudflare-main.gpg}"
readonly SOURCE_FILE="${CLOUDFLARED_SOURCE_FILE:-/etc/apt/sources.list.d/cloudflared.list}"
readonly STATE_DIR="${CLOUDFLARED_STATE_DIR:-/var/lib/cloudflared-wrapper}"
readonly KEY_URL="https://pkg.cloudflare.com/cloudflare-main.gpg"
readonly REPOSITORY="https://pkg.cloudflare.com/cloudflared"
readonly LEGACY_BIN="${CLOUDFLARED_LEGACY_BIN:-/usr/local/bin/cloudflared}"
readonly LEGACY_UPDATER="${CLOUDFLARED_LEGACY_UPDATER:-/usr/local/bin/cloudflared-update}"
readonly LEGACY_SERVICE="${CLOUDFLARED_LEGACY_SERVICE:-/etc/systemd/system/cloudflared-updater.service}"
readonly LEGACY_TIMER="${CLOUDFLARED_LEGACY_TIMER:-/etc/systemd/system/cloudflared-updater.timer}"

info() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
error() { printf '[ERROR] %s\n' "$*" >&2; }

require_root() {
    (( EUID == 0 )) || { error "需要 root 权限"; exit 1; }
}

check_platform() {
    [[ -r /etc/os-release ]] || { error "无法读取 /etc/os-release"; return 1; }
    . /etc/os-release
    case "${ID:-}" in
        debian|ubuntu) ;;
        *) error "仅支持 Debian/Ubuntu，当前系统: ${PRETTY_NAME:-unknown}"; return 1 ;;
    esac
    [[ -d /run/systemd/system ]] || { error "当前环境未运行 systemd"; return 1; }
    command -v apt-get >/dev/null || { error "缺少 apt-get"; return 1; }
    command -v systemctl >/dev/null || { error "缺少 systemctl"; return 1; }
}

confirm() {
    local prompt="$1" answer
    [[ -t 0 ]] || return 1
    read -r -p "$prompt [y/N]: " answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

backup_path() {
    local path="$1" backup_dir="$2"
    [[ -e "$path" || -L "$path" ]] || return 0
    install -d -m 0700 "$backup_dir"
    cp -a "$path" "$backup_dir/$(basename "$path")"
}

configure_repository() {
    local key_temp source_temp backup_dir
    command -v curl >/dev/null || {
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl
    }

    install -d -m 0755 "$(dirname "$KEYRING")" "$(dirname "$SOURCE_FILE")"
    install -d -m 0700 "$STATE_DIR"
    if [[ -f "$SOURCE_FILE" ]] && ! grep -Fq "$REPOSITORY" "$SOURCE_FILE"; then
        error "现有软件源文件包含非 Cloudflare 配置，拒绝覆盖: $SOURCE_FILE"
        return 1
    fi
    backup_dir="$STATE_DIR/repository-$(date +%Y%m%d_%H%M%S)"
    backup_path "$KEYRING" "$backup_dir"
    backup_path "$SOURCE_FILE" "$backup_dir"
    key_temp=$(mktemp)
    source_temp=$(mktemp)
    trap 'rm -f "$key_temp" "$source_temp"' RETURN

    curl -fsSL --connect-timeout 10 --max-time 60 "$KEY_URL" -o "$key_temp"
    [[ -s "$key_temp" ]] || { error "Cloudflare 签名密钥为空"; return 1; }
    install -m 0644 "$key_temp" "$KEYRING"

    cat > "$source_temp" <<EOF
# Managed by tools/cloudflare_tunnel.sh
# Cloudflare stable repository for Debian-based distributions.
deb [signed-by=$KEYRING] $REPOSITORY any main
EOF
    install -m 0644 "$source_temp" "$SOURCE_FILE"
    : > "$STATE_DIR/repository-managed"
    trap - RETURN
    rm -f "$key_temp" "$source_temp"
}

legacy_updater_is_managed() {
    local path="$1"
    case "$path" in
        "$LEGACY_UPDATER") grep -Fq 'cloudflared 自动更新脚本 (由安装脚本生成)' "$path" ;;
        "$LEGACY_SERVICE") grep -Fq 'Description=Cloudflared Auto Updater' "$path" && grep -Fq "ExecStart=$LEGACY_UPDATER" "$path" ;;
        "$LEGACY_TIMER") grep -Fq 'Description=Cloudflared Auto Updater Timer' "$path" ;;
        *) return 1 ;;
    esac
}

cleanup_legacy_updater() {
    local path backup_dir
    backup_dir="$STATE_DIR/legacy-$(date +%Y%m%d_%H%M%S)"
    local -a paths=("$LEGACY_UPDATER" "$LEGACY_SERVICE" "$LEGACY_TIMER")

    for path in "${paths[@]}"; do
        [[ -e "$path" ]] || continue
        if ! legacy_updater_is_managed "$path"; then
            warn "发现无法确认归属的旧文件，保留: $path"
            return 1
        fi
    done

    systemctl disable --now cloudflared-updater.timer >/dev/null 2>&1 || true
    systemctl stop cloudflared-updater.service >/dev/null 2>&1 || true
    for path in "${paths[@]}"; do
        [[ -e "$path" ]] || continue
        backup_path "$path" "$backup_dir"
        rm -f "$path"
    done
    systemctl daemon-reload
}

migrate_legacy_binary() {
    [[ -e "$LEGACY_BIN" || -L "$LEGACY_BIN" ]] || return 0
    if dpkg-query -S "$LEGACY_BIN" >/dev/null 2>&1; then
        return 0
    fi

    warn "$LEGACY_BIN 会遮蔽 APT 安装的 /usr/bin/cloudflared"
    if ! confirm "备份并移除该旧二进制？"; then
        error "必须先处理旧二进制；也可运行 migrate-legacy"
        return 1
    fi

    local backup_dir
    backup_dir="$STATE_DIR/legacy-$(date +%Y%m%d_%H%M%S)"
    backup_path "$LEGACY_BIN" "$backup_dir"
    rm -f "$LEGACY_BIN"
    info "旧二进制已备份到 $backup_dir"
}

install_package() {
    configure_repository
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y cloudflared
    migrate_legacy_binary
    cleanup_legacy_updater || warn "旧自动更新组件未完全清理"

    command -v cloudflared >/dev/null || { error "cloudflared 安装后不可用"; return 1; }
    cloudflared version
}

install_service() {
    if systemctl cat cloudflared.service >/dev/null 2>&1; then
        info "cloudflared.service 已存在，不重复写入 Token"
        systemctl enable --now cloudflared.service
        return 0
    fi

    local token
    read -r -s -p "粘贴 Cloudflare Tunnel Token: " token
    printf '\n'
    [[ -n "$token" ]] || { error "Token 不能为空"; return 1; }
    if ! cloudflared service install "$token"; then
        unset token
        error "官方 service install 执行失败"
        return 1
    fi
    unset token
    systemctl enable --now cloudflared.service
    systemctl is-active --quiet cloudflared.service || {
        error "服务未处于运行状态"
        return 1
    }
}

install_cloudflared() {
    require_root
    check_platform
    install_package
    install_service
    info "安装完成。后续版本由 APT 管理；本脚本不创建独立更新定时器。"
}

upgrade_cloudflared() {
    require_root
    check_platform
    configure_repository
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade cloudflared
    migrate_legacy_binary
    cleanup_legacy_updater || warn "旧自动更新组件未完全清理"
    if systemctl cat cloudflared.service >/dev/null 2>&1; then
        systemctl restart cloudflared.service
        systemctl is-active --quiet cloudflared.service || {
            error "升级后服务未运行"
            return 1
        }
    fi
    cloudflared version
}

show_status() {
    if dpkg-query -W -f='${db:Status-Status}' cloudflared 2>/dev/null | grep -qx installed; then
        echo "APT 包: 已安装"
        /usr/bin/cloudflared version 2>/dev/null || true
    else
        echo "APT 包: 未安装"
    fi
    [[ -f "$SOURCE_FILE" ]] && echo "官方源: 已配置 ($SOURCE_FILE)" || echo "官方源: 未配置"
    if command -v systemctl >/dev/null && systemctl is-active --quiet cloudflared.service; then
        echo "服务: 运行中"
    else
        echo "服务: 未运行"
    fi
    [[ -e "$LEGACY_BIN" ]] && warn "旧二进制仍存在: $LEGACY_BIN"
    [[ -e "$LEGACY_TIMER" || -e "$LEGACY_SERVICE" || -e "$LEGACY_UPDATER" ]] &&
        warn "旧自定义更新组件仍存在"
}

remove_managed_repository() {
    local backup_dir
    backup_dir="$STATE_DIR/uninstall-$(date +%Y%m%d_%H%M%S)"
    if [[ -f "$STATE_DIR/repository-managed" && -f "$SOURCE_FILE" ]] &&
        grep -Fq '# Managed by tools/cloudflare_tunnel.sh' "$SOURCE_FILE"; then
        backup_path "$SOURCE_FILE" "$backup_dir"
        rm -f "$SOURCE_FILE" "$STATE_DIR/repository-managed"
    fi
}

uninstall_cloudflared() {
    local confirmed="${1:-}"
    require_root
    check_platform
    warn "将删除 cloudflared 服务和 APT 包；Tunnel 配置与凭据默认保留。"
    if [[ "$confirmed" != --confirmed ]]; then
        confirm "继续卸载？" || { info "已取消"; return 0; }
    fi

    if command -v cloudflared >/dev/null 2>&1; then
        cloudflared service uninstall >/dev/null 2>&1 || true
    fi
    systemctl disable --now cloudflared.service >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get remove -y cloudflared
    remove_managed_repository
    apt-get update
    info "卸载完成；/etc/cloudflared 与用户 .cloudflared 目录未删除。"
}

purge_config() {
    require_root
    check_platform
    warn "此操作会永久删除 /etc/cloudflared、/root/.cloudflared 和当前用户配置。"
    [[ -t 0 ]] || { error "彻底清理必须在交互终端执行"; return 1; }
    local answer
    read -r -p "请输入 PURGE 确认: " answer
    [[ "$answer" == PURGE ]] || { info "已取消"; return 0; }
    uninstall_cloudflared --confirmed
    rm -rf /etc/cloudflared /root/.cloudflared
    if [[ "${HOME:-/root}" != /root ]]; then
        rm -rf "$HOME/.cloudflared"
    fi
    info "Tunnel 本地配置已删除"
}

show_help() {
    cat <<'EOF'
用法：
  cloudflare_tunnel.sh install          配置官方 APT 源、安装包并安装 Tunnel 服务
  cloudflare_tunnel.sh upgrade          通过 APT 升级并重启服务
  cloudflare_tunnel.sh status           查看包、服务和旧版残留
  cloudflare_tunnel.sh migrate-legacy   备份并清理旧二进制和自定义更新器
  cloudflare_tunnel.sh uninstall        删除服务、APT 包和本工具管理的软件源，保留配置
  cloudflare_tunnel.sh purge            二次确认后彻底删除本地 Tunnel 配置
  cloudflare_tunnel.sh help             显示帮助

APT 包会随 apt upgrade/full-upgrade 更新；是否自动执行取决于系统更新策略。
EOF
}

main() {
    local action="${1:-help}"
    case "$action" in
        install) install_cloudflared ;;
        upgrade) upgrade_cloudflared ;;
        status) show_status ;;
        migrate-legacy)
            require_root
            check_platform
            migrate_legacy_binary
            cleanup_legacy_updater
            ;;
        uninstall) uninstall_cloudflared ;;
        purge) purge_config ;;
        help|-h|--help) show_help ;;
        *) error "未知参数: $action"; show_help; return 1 ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
