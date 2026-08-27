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
readonly APT_BIN="${CLOUDFLARED_APT_BIN:-/usr/bin/cloudflared}"
readonly LEGACY_UPDATER="${CLOUDFLARED_LEGACY_UPDATER:-/usr/local/bin/cloudflared-update}"
readonly LEGACY_SERVICE="${CLOUDFLARED_LEGACY_SERVICE:-/etc/systemd/system/cloudflared-updater.service}"
readonly LEGACY_TIMER="${CLOUDFLARED_LEGACY_TIMER:-/etc/systemd/system/cloudflared-updater.timer}"
readonly AUTO_UPDATE_SCRIPT="${CLOUDFLARED_AUTO_UPDATE_SCRIPT:-/usr/local/libexec/cloudflared-apt-update}"
readonly AUTO_UPDATE_SERVICE="${CLOUDFLARED_AUTO_UPDATE_SERVICE:-/etc/systemd/system/cloudflared-apt-update.service}"
readonly AUTO_UPDATE_TIMER="${CLOUDFLARED_AUTO_UPDATE_TIMER:-/etc/systemd/system/cloudflared-apt-update.timer}"
readonly SERVICE_FILE="${CLOUDFLARED_SERVICE_FILE:-/etc/systemd/system/cloudflared.service}"
readonly BINARY_UPDATE_SERVICE="${CLOUDFLARED_BINARY_UPDATE_SERVICE:-/etc/systemd/system/cloudflared-update.service}"
readonly BINARY_UPDATE_TIMER="${CLOUDFLARED_BINARY_UPDATE_TIMER:-/etc/systemd/system/cloudflared-update.timer}"

PRESERVE_AUTO_UPDATE=false

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
        backup_path "$path" "$backup_dir" || return 1
        rm -f "$path" || return 1
    done
    systemctl daemon-reload
    for path in "${paths[@]}"; do
        [[ ! -e "$path" ]] || return 1
    done
}

binary_updater_is_managed() {
    local path="$1"
    case "$path" in
        "$BINARY_UPDATE_SERVICE")
            grep -Fq 'Description=Update cloudflared' "$path" &&
                grep -Fq ' update; code=$?' "$path"
            ;;
        "$BINARY_UPDATE_TIMER")
            grep -Fq 'Description=Update cloudflared' "$path" &&
                grep -Fq 'OnCalendar=daily' "$path"
            ;;
        *) return 1 ;;
    esac
}

cleanup_binary_updater() {
    local path backup_dir
    local -a paths=("$BINARY_UPDATE_SERVICE" "$BINARY_UPDATE_TIMER")
    for path in "${paths[@]}"; do
        [[ -e "$path" ]] || continue
        binary_updater_is_managed "$path" || {
            warn "发现无法确认归属的 cloudflared 二进制更新单元，保留: $path"
            return 1
        }
    done
    backup_dir="$STATE_DIR/binary-updater-$(date +%Y%m%d_%H%M%S)"
    systemctl disable --now cloudflared-update.timer >/dev/null 2>&1 || true
    systemctl stop cloudflared-update.service >/dev/null 2>&1 || true
    for path in "${paths[@]}"; do
        [[ -e "$path" ]] || continue
        backup_path "$path" "$backup_dir" || return 1
        rm -f "$path" || return 1
    done
    systemctl daemon-reload
    for path in "${paths[@]}"; do
        [[ ! -e "$path" ]] || return 1
    done
}

legacy_auto_update_present() {
    if [[ -f "$LEGACY_TIMER" ]] && legacy_updater_is_managed "$LEGACY_TIMER" &&
        { systemctl is-enabled --quiet cloudflared-updater.timer 2>/dev/null ||
          systemctl is-active --quiet cloudflared-updater.timer 2>/dev/null; }; then
        return 0
    fi
    if [[ -f "$BINARY_UPDATE_TIMER" ]] && binary_updater_is_managed "$BINARY_UPDATE_TIMER" &&
        { systemctl is-enabled --quiet cloudflared-update.timer 2>/dev/null ||
          systemctl is-active --quiet cloudflared-update.timer 2>/dev/null; }; then
        return 0
    fi
    return 1
}

legacy_binary_is_apt_compat_symlink() {
    [[ -L "$LEGACY_BIN" ]] &&
        [[ "$(readlink -f "$LEGACY_BIN")" == "$APT_BIN" ]] &&
        dpkg-query -S "$APT_BIN" >/dev/null 2>&1
}

legacy_binary_is_safe_to_migrate() {
    [[ -x "$LEGACY_BIN" ]] || return 1

    # Cloudflare DEB postinst creates this unowned compatibility symlink.
    # Keep it; dpkg-query cannot report /usr/local/bin/cloudflared as owned.
    if legacy_binary_is_apt_compat_symlink; then
        return 0
    fi

    [[ -f "$SERVICE_FILE" ]] || return 1

    if [[ -L "$LEGACY_BIN" ]] &&
        [[ "$(readlink -f "$LEGACY_BIN")" == "$APT_BIN" ]] &&
        dpkg-query -S "$APT_BIN" >/dev/null 2>&1 &&
        grep -Fq "ExecStart=$APT_BIN " "$SERVICE_FILE"; then
        return 0
    fi

    grep -Fq "ExecStart=$LEGACY_BIN " "$SERVICE_FILE" || return 1
    "$LEGACY_BIN" version 2>/dev/null | grep -Eiq '^cloudflared version[[:space:]]'
}

migrate_legacy_service_path() {
    [[ -f "$SERVICE_FILE" ]] || return 0
    grep -Fq "ExecStart=$LEGACY_BIN " "$SERVICE_FILE" || return 0

    local backup_dir service_temp was_active=false
    backup_dir="$STATE_DIR/legacy-service-$(date +%Y%m%d_%H%M%S)"
    backup_path "$SERVICE_FILE" "$backup_dir"
    service_temp=$(mktemp)
    sed "s#^ExecStart=$LEGACY_BIN #ExecStart=$APT_BIN #" "$SERVICE_FILE" > "$service_temp"
    grep -Fq "ExecStart=$APT_BIN " "$service_temp" || {
        rm -f "$service_temp"
        error "旧服务路径迁移验证失败"
        return 1
    }
    systemctl is-active --quiet cloudflared.service && was_active=true || true
    install -m 0644 "$service_temp" "$SERVICE_FILE"
    rm -f "$service_temp"
    systemctl daemon-reload
    if [[ "$was_active" == true ]]; then
        if ! systemctl restart cloudflared.service || ! systemctl is-active --quiet cloudflared.service; then
            cp -a "$backup_dir/$(basename "$SERVICE_FILE")" "$SERVICE_FILE"
            systemctl daemon-reload
            systemctl restart cloudflared.service >/dev/null 2>&1 || true
            error "新 APT 二进制启动失败，已恢复旧服务路径"
            return 1
        fi
    fi
    info "cloudflared.service 已迁移到 $APT_BIN；原 unit 已备份。"
}

migrate_legacy_binary() {
    [[ -e "$LEGACY_BIN" || -L "$LEGACY_BIN" ]] || return 0
    if dpkg-query -S "$LEGACY_BIN" >/dev/null 2>&1 ||
        legacy_binary_is_apt_compat_symlink; then
        return 0
    fi

    if ! legacy_binary_is_safe_to_migrate; then
        error "无法确认 $LEGACY_BIN 属于旧版受管安装，已保留并停止迁移"
        return 1
    fi

    info "检测到可安全迁移的旧版 cloudflared 安装"
    migrate_legacy_service_path

    local backup_dir
    backup_dir="$STATE_DIR/legacy-$(date +%Y%m%d_%H%M%S)"
    backup_path "$LEGACY_BIN" "$backup_dir"
    rm -f "$LEGACY_BIN"
    info "旧二进制已自动备份并移除: $backup_dir"
}

write_auto_update_files() {
    install -d -m 0755 "$(dirname "$AUTO_UPDATE_SCRIPT")" "$(dirname "$AUTO_UPDATE_SERVICE")"

    cat > "$AUTO_UPDATE_SCRIPT" <<'UPDATER'
#!/usr/bin/env bash
# Managed by tools/cloudflare_tunnel.sh
set -euo pipefail

exec 9>/run/lock/cloudflared-apt-update.lock
if ! flock -n 9; then
    echo "另一项 cloudflared APT 更新正在运行，跳过"
    exit 0
fi

export DEBIAN_FRONTEND=noninteractive
installed=$(dpkg-query -W -f='${Version}' cloudflared 2>/dev/null) || {
    echo "cloudflared APT 包未安装" >&2
    exit 1
}

apt-get -o DPkg::Lock::Timeout=300 update -qq
candidate=$(LC_ALL=C apt-cache policy cloudflared | awk '/Candidate:/ {print $2; exit}')
if [[ -z "$candidate" || "$candidate" == "(none)" ]]; then
    echo "无法取得 cloudflared 候选版本" >&2
    exit 1
fi
if ! dpkg --compare-versions "$candidate" gt "$installed"; then
    echo "cloudflared 已是最新版本: $installed"
    exit 0
fi

was_active=false
systemctl is-active --quiet cloudflared.service && was_active=true || true
echo "升级 cloudflared: $installed -> $candidate"
apt-get -o DPkg::Lock::Timeout=300 install -y --only-upgrade cloudflared

if [[ "$was_active" == true ]]; then
    systemctl restart cloudflared.service
    systemctl is-active --quiet cloudflared.service
fi
/usr/bin/cloudflared version
UPDATER
    chmod 0755 "$AUTO_UPDATE_SCRIPT"

    cat > "$AUTO_UPDATE_SERVICE" <<EOF
# Managed by tools/cloudflare_tunnel.sh
[Unit]
Description=Check and install cloudflared APT updates
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$AUTO_UPDATE_SCRIPT
EOF

    cat > "$AUTO_UPDATE_TIMER" <<'EOF'
# Managed by tools/cloudflare_tunnel.sh
[Unit]
Description=Daily cloudflared APT update check

[Timer]
OnCalendar=daily
RandomizedDelaySec=6h
Persistent=true

[Install]
WantedBy=timers.target
EOF
    chmod 0644 "$AUTO_UPDATE_SERVICE" "$AUTO_UPDATE_TIMER"
}

auto_update_file_is_managed() {
    grep -Fq '# Managed by tools/cloudflare_tunnel.sh' "$1"
}

enable_auto_update() {
    local path backup_dir
    require_root
    check_platform
    dpkg-query -W -f='${db:Status-Status}' cloudflared 2>/dev/null | grep -qx installed || {
        error "请先安装 cloudflared APT 包"
        return 1
    }
    configure_repository
    command -v flock >/dev/null || {
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y util-linux
    }
    for path in "$AUTO_UPDATE_SCRIPT" "$AUTO_UPDATE_SERVICE" "$AUTO_UPDATE_TIMER"; do
        [[ -e "$path" ]] || continue
        auto_update_file_is_managed "$path" || {
            error "现有自动更新文件不受本脚本管理，拒绝覆盖: $path"
            return 1
        }
    done
    backup_dir="$STATE_DIR/auto-update-previous-$(date +%Y%m%d_%H%M%S)"
    for path in "$AUTO_UPDATE_SCRIPT" "$AUTO_UPDATE_SERVICE" "$AUTO_UPDATE_TIMER"; do
        backup_path "$path" "$backup_dir"
    done
    write_auto_update_files
    systemctl daemon-reload
    systemctl enable --now cloudflared-apt-update.timer
    info "已启用每日 APT 更新检查；更新时仅重启原本正在运行的 cloudflared 服务。"
}

disable_auto_update() {
    local confirmed="${1:-}" path backup_dir
    require_root
    check_platform
    for path in "$AUTO_UPDATE_SCRIPT" "$AUTO_UPDATE_SERVICE" "$AUTO_UPDATE_TIMER"; do
        [[ -e "$path" ]] || continue
        auto_update_file_is_managed "$path" || {
            error "自动更新文件不受本脚本管理，拒绝删除: $path"
            return 1
        }
    done
    if [[ "$confirmed" != --confirmed ]]; then
        confirm "禁用并删除 cloudflared APT 自动更新组件？" || { info "已取消"; return 0; }
    fi
    backup_dir="$STATE_DIR/auto-update-$(date +%Y%m%d_%H%M%S)"
    systemctl disable --now cloudflared-apt-update.timer >/dev/null 2>&1 || true
    systemctl stop cloudflared-apt-update.service >/dev/null 2>&1 || true
    for path in "$AUTO_UPDATE_SCRIPT" "$AUTO_UPDATE_SERVICE" "$AUTO_UPDATE_TIMER"; do
        [[ -e "$path" ]] || continue
        backup_path "$path" "$backup_dir" || return 1
        rm -f "$path" || return 1
    done
    systemctl daemon-reload
    info "APT 自动更新组件已禁用；备份目录: $backup_dir"
}

show_auto_update_status() {
    if command -v systemctl >/dev/null && systemctl is-enabled --quiet cloudflared-apt-update.timer 2>/dev/null; then
        echo "APT 自动更新: 已启用"
        systemctl list-timers cloudflared-apt-update.timer --no-pager 2>/dev/null || true
    else
        echo "APT 自动更新: 未启用"
    fi
}

validate_migration_inputs() {
    local path
    if [[ -e "$LEGACY_BIN" || -L "$LEGACY_BIN" ]] &&
        ! dpkg-query -S "$LEGACY_BIN" >/dev/null 2>&1 &&
        ! legacy_binary_is_safe_to_migrate; then
        error "无法确认 $LEGACY_BIN 属于旧版受管安装，拒绝自动迁移"
        return 1
    fi
    for path in "$LEGACY_UPDATER" "$LEGACY_SERVICE" "$LEGACY_TIMER"; do
        [[ -e "$path" ]] || continue
        legacy_updater_is_managed "$path" || {
            error "旧更新文件归属不明，拒绝自动迁移: $path"
            return 1
        }
    done
    for path in "$BINARY_UPDATE_SERVICE" "$BINARY_UPDATE_TIMER"; do
        [[ -e "$path" ]] || continue
        binary_updater_is_managed "$path" || {
            error "二进制更新单元归属不明，拒绝自动迁移: $path"
            return 1
        }
    done
}

install_package() {
    validate_migration_inputs
    PRESERVE_AUTO_UPDATE=false
    legacy_auto_update_present && PRESERVE_AUTO_UPDATE=true || true
    configure_repository
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y cloudflared
    migrate_legacy_binary
    cleanup_legacy_updater || { error "旧自定义更新组件清理失败"; return 1; }
    cleanup_binary_updater || { error "二进制更新单元清理失败"; return 1; }
    if [[ "$PRESERVE_AUTO_UPDATE" == true ]]; then
        enable_auto_update
        info "检测到旧版每日更新配置，已自动迁移为 APT timer。"
    fi

    [[ -x "$APT_BIN" ]] || { error "APT cloudflared 安装后不可用"; return 1; }
    "$APT_BIN" version
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
    if ! cloudflared service install --no-update-service "$token"; then
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
    info "安装完成。版本由 APT 管理。"
    if [[ "$PRESERVE_AUTO_UPDATE" == true ]]; then
        info "旧版自动更新行为已保留，无需再次确认。"
    else
        warn "自动更新安装新版时会重启正在运行的 cloudflared，单实例 Tunnel 会短暂中断。"
        if confirm "是否启用每日 APT 更新检测与安装？"; then
            enable_auto_update
        else
            info "自动更新未启用；稍后可运行: sudo $(basename "$0") enable-auto-update"
        fi
    fi
}

upgrade_cloudflared() {
    require_root
    check_platform
    validate_migration_inputs
    PRESERVE_AUTO_UPDATE=false
    legacy_auto_update_present && PRESERVE_AUTO_UPDATE=true || true
    configure_repository
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade cloudflared
    migrate_legacy_binary
    cleanup_legacy_updater || { error "旧自定义更新组件清理失败"; return 1; }
    cleanup_binary_updater || { error "二进制更新单元清理失败"; return 1; }
    if [[ "$PRESERVE_AUTO_UPDATE" == true ]]; then
        enable_auto_update
        info "检测到旧版每日更新配置，已自动迁移为 APT timer。"
    fi
    if systemctl cat cloudflared.service >/dev/null 2>&1; then
        systemctl restart cloudflared.service
        systemctl is-active --quiet cloudflared.service || {
            error "升级后服务未运行"
            return 1
        }
    fi
    "$APT_BIN" version
}

show_status() {
    if dpkg-query -W -f='${db:Status-Status}' cloudflared 2>/dev/null | grep -qx installed; then
        echo "APT 包: 已安装"
        "$APT_BIN" version 2>/dev/null || true
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
    [[ -e "$BINARY_UPDATE_SERVICE" || -e "$BINARY_UPDATE_TIMER" ]] &&
        warn "不适用于 APT 安装的 cloudflared 二进制更新单元仍存在"
    show_auto_update_status
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

    disable_auto_update --confirmed
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
  cloudflare_tunnel.sh status                查看包、服务、自动更新和旧版残留
  cloudflare_tunnel.sh enable-auto-update    启用每日 APT 更新检测与安装
  cloudflare_tunnel.sh disable-auto-update   禁用并备份自动更新组件
  cloudflare_tunnel.sh migrate-legacy   备份并清理旧二进制和自定义更新器
  cloudflare_tunnel.sh uninstall        删除服务、APT 包和本工具管理的软件源，保留配置
  cloudflare_tunnel.sh purge            二次确认后彻底删除本地 Tunnel 配置
  cloudflare_tunnel.sh help             显示帮助

APT 包会随系统 apt upgrade/full-upgrade 更新。enable-auto-update 会每日运行 apt-get update，
仅在候选版本较新时升级；原服务正在运行时会重启并造成短暂流量中断。
EOF
}

main() {
    local action="${1:-help}"
    case "$action" in
        install) install_cloudflared ;;
        upgrade) upgrade_cloudflared ;;
        status) show_status ;;
        enable-auto-update) enable_auto_update ;;
        disable-auto-update) disable_auto_update ;;
        migrate-legacy)
            require_root
            check_platform
            install_package
            ;;
        uninstall) uninstall_cloudflared ;;
        purge) purge_config ;;
        help|-h|--help) show_help ;;
        *) error "未知参数: $action"; show_help; return 1 ;;
    esac
}

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
    main "$@"
fi
