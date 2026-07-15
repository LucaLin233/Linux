#!/usr/bin/env bash
# 网络优化模块
# 功能：配置 BBR、fq 队列、IPv4 转发与代理/端口转发兼容参数
#
# 用法：
#   bash network-optimize.sh install   # 写入并应用优化配置
#   bash network-optimize.sh restore   # 恢复新版脚本修改前的配置
#   bash network-optimize.sh status    # 查看当前状态

set -euo pipefail

# === 常量定义 ===
readonly NETWORK_CONF="/etc/sysctl.d/99-network-optimize.conf"
readonly NETWORK_BACKUP="/etc/sysctl.d/99-network-optimize.conf.backup"

# 旧版 kernel2.sh 使用的配置文件。
readonly LEGACY_KERNEL_CONF="/etc/sysctl.d/99-kernel.conf"
readonly LEGACY_KERNEL_ARCHIVE="/etc/sysctl.d/99-kernel.conf.legacy"

# 旧版脚本可能迁移过的主 sysctl 文件。
readonly LEGACY_SYSCTL_CONF="/etc/sysctl.conf"
readonly LEGACY_SYSCTL_BACKUP="/etc/sysctl.conf.bak"

# 旧版脚本写入 limits.conf 的标记与备份。
readonly LIMITS_CONF="/etc/security/limits.conf"
readonly LIMITS_BACKUP="/etc/security/limits.conf.bak"
readonly LIMITS_LEGACY_ARCHIVE="/etc/security/limits.conf.network-optimize.before-restore"
readonly LEGACY_LIMITS_MARKER="# Network Optimizer - 系统资源限制"

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

# === 环境与 BBR 检测 ===
detect_container() {
    if [[ -f /proc/user_beancounters ]] ||
        [[ -d /proc/vz ]] ||
        [[ "$(systemd-detect-virt 2>/dev/null || true)" == "lxc" ]]; then
        return 0
    fi

    return 1
}

bbr_available() {
    grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null
}

ensure_bbr_available() {
    if bbr_available; then
        return 0
    fi

    info "当前内核未显示 BBR，尝试加载 tcp_bbr 模块..."
    modprobe tcp_bbr 2>/dev/null || true

    if bbr_available; then
        return 0
    fi

    warn "当前内核不支持 BBR，将保留现有拥塞控制算法"
    return 1
}

# === 旧配置迁移 ===
migrate_legacy_kernel_config() {
    if [[ ! -f "$LEGACY_KERNEL_CONF" ]]; then
        return 0
    fi

    if [[ -e "$LEGACY_KERNEL_ARCHIVE" ]]; then
        warn "检测到旧配置 $LEGACY_KERNEL_CONF，但历史归档已存在，保留旧文件不自动覆盖"
        warn "请手动检查并处理：$LEGACY_KERNEL_CONF"
        return 0
    fi

    if mv "$LEGACY_KERNEL_CONF" "$LEGACY_KERNEL_ARCHIVE"; then
        info "旧网络配置已迁移为历史归档：$LEGACY_KERNEL_ARCHIVE"
        info "新版配置将使用：$NETWORK_CONF"
        return 0
    fi

    error "无法迁移旧网络配置：$LEGACY_KERNEL_CONF"
    return 1
}

migrate_legacy_sysctl_conf() {
    # 旧版脚本为了兼容 Debian 12 升级 Debian 13 的环境，
    # 会将存在的 /etc/sysctl.conf 迁移为 .bak。
    [[ -s "$LEGACY_SYSCTL_CONF" ]] || return 0

    if [[ -e "$LEGACY_SYSCTL_BACKUP" ]]; then
        warn "检测到 $LEGACY_SYSCTL_CONF，但 $LEGACY_SYSCTL_BACKUP 已存在，保留当前文件不自动迁移"
        return 0
    fi

    if mv "$LEGACY_SYSCTL_CONF" "$LEGACY_SYSCTL_BACKUP"; then
        info "已迁移旧主 sysctl 配置：$LEGACY_SYSCTL_CONF → $LEGACY_SYSCTL_BACKUP"
        return 0
    fi

    error "无法迁移旧主 sysctl 配置：$LEGACY_SYSCTL_CONF"
    return 1
}

restore_legacy_limits() {
    local restored=false
    local disabled_file
    local original_file

    # 仅当当前 limits.conf 明确包含旧脚本标记时才恢复，
    # 避免影响非本脚本管理的资源限制。
    if [[ -f "$LIMITS_CONF" ]] &&
        grep -Fq "$LEGACY_LIMITS_MARKER" "$LIMITS_CONF"; then
        if [[ -f "$LIMITS_BACKUP" ]]; then
            cp -a "$LIMITS_CONF" "$LIMITS_LEGACY_ARCHIVE"
            cp -a "$LIMITS_BACKUP" "$LIMITS_CONF"
            chmod 644 "$LIMITS_CONF" 2>/dev/null || true

            info "已恢复 limits.conf 到旧脚本运行前的备份状态"
            info "恢复前的旧优化配置已保存至：$LIMITS_LEGACY_ARCHIVE"
            restored=true
        else
            warn "检测到旧版 limits 配置，但未找到 $LIMITS_BACKUP，无法安全恢复"
        fi
    fi

    # 恢复旧脚本禁用的 nproc 配置文件。
    # 新版不再管理 nproc；恢复后交由系统默认规则处理。
    for disabled_file in /etc/security/limits.d/*.conf.disabled; do
        [[ -f "$disabled_file" ]] || continue

        original_file="${disabled_file%.disabled}"

        if [[ -e "$original_file" ]]; then
            warn "跳过恢复 $disabled_file：目标文件已存在"
            continue
        fi

        if mv "$disabled_file" "$original_file"; then
            info "已恢复资源限制文件：$original_file"
            restored=true
        else
            warn "恢复资源限制文件失败：$disabled_file"
        fi
    done

    if [[ "$restored" == "false" ]]; then
        info "未检测到需要恢复的旧版资源限制配置"
    fi
}

# === 新版网络配置 ===
create_network_config() {
    local target_file="$1"
    local enable_bbr="$2"

    cat > "$target_file" <<'EOF'
# 由 network-optimize.sh 自动生成。
# 面向 BBR、代理、端口转发与高连接数 VPS 的稳定配置。

# 1. 队列调度
# fq 与 BBR pacing 配合，优先兼顾起速与吞吐。
net.core.default_qdisc = fq

# 2. TCP Fast Open
# 3 = 同时启用客户端与服务端。
net.ipv4.tcp_fastopen = 3

# 3. IPv4 转发与代理/端口转发兼容
net.ipv4.ip_forward = 1

# 宽松反向路径过滤：
# 比严格模式更兼容代理、转发、策略路由与非对称回程。
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2

# 4. 文件句柄与连接队列
fs.file-max = 1048576
net.core.somaxconn = 32768
net.core.netdev_max_backlog = 16384
net.ipv4.ip_local_port_range = 1024 65535
EOF

    if [[ "$enable_bbr" == "true" ]]; then
        cat >> "$target_file" <<'EOF'

# BBR 拥塞控制
net.ipv4.tcp_congestion_control = bbr
EOF
    else
        cat >> "$target_file" <<'EOF'

# 当前内核未检测到 BBR 支持，因此不设置 tcp_congestion_control。
# 可在升级内核后重新运行本脚本。
EOF
    fi

    chmod 644 "$target_file"
}

backup_network_config() {
    if [[ ! -f "$NETWORK_CONF" ]]; then
        return 0
    fi

    if cp -a "$NETWORK_CONF" "$NETWORK_BACKUP"; then
        info "已更新网络配置备份：$NETWORK_BACKUP"
        return 0
    fi

    error "网络配置备份失败"
    return 1
}

apply_network_config() {
    local config_file="$1"

    if ! sysctl -p "$config_file"; then
        error "网络 sysctl 参数应用失败"
        return 1
    fi

    return 0
}

install_optimization() {
    local temp_config
    local bbr_enabled="false"

    info "开始配置网络优化..."

    if detect_container; then
        warn "检测到容器虚拟化环境，部分 sysctl 参数可能受宿主机限制"
    fi

    migrate_legacy_kernel_config || return 1
    migrate_legacy_sysctl_conf || return 1
    restore_legacy_limits

    if ensure_bbr_available; then
        bbr_enabled="true"
        info "BBR 支持：可用"
    fi

    if ! temp_config=$(mktemp /etc/sysctl.d/99-network-optimize.conf.new.XXXXXX); then
        error "无法创建网络配置临时文件"
        return 1
    fi

    create_network_config "$temp_config" "$bbr_enabled"

    backup_network_config || {
        rm -f "$temp_config"
        return 1
    }

    # 先验证临时配置。sysctl -p 会实际应用配置，
    # 因此仅在配置本身生成完成后执行。
    if ! apply_network_config "$temp_config"; then
        rm -f "$temp_config"

        if [[ -f "$NETWORK_BACKUP" ]]; then
            warn "尝试恢复旧网络配置..."
            cp -a "$NETWORK_BACKUP" "$NETWORK_CONF"
            sysctl -p "$NETWORK_CONF" >/dev/null 2>&1 || true
        fi

        return 1
    fi

    if ! mv "$temp_config" "$NETWORK_CONF"; then
        error "写入网络配置文件失败"
        rm -f "$temp_config"
        return 1
    fi

    success "网络优化配置已写入：$NETWORK_CONF"

    if [[ "$bbr_enabled" != "true" ]]; then
        warn "BBR 未启用；其余网络与转发参数已正常应用"
    fi

    echo
    echo "说明："
    echo "  - IPv4 转发已启用，兼容 NAT、透明代理、网关与端口转发场景。"
    echo "  - 未启用 IPv6 转发、route_localnet 或 MPTCP。"
    echo "  - 新版不再管理 limits.conf、nproc 与 memlock。"
    echo "  - 已恢复旧脚本修改过的资源限制配置（若检测到对应备份）。"
    echo "  - 已移除的旧 sysctl 参数在重启前可能仍保留运行时值；重启后将完全按新版配置生效。"
}

restore_optimization() {
    info "开始恢复新版网络优化配置..."

    if [[ -f "$NETWORK_BACKUP" ]]; then
        cp -a "$NETWORK_BACKUP" "$NETWORK_CONF"

        if apply_network_config "$NETWORK_CONF"; then
            success "已恢复网络配置备份：$NETWORK_BACKUP"
        else
            error "恢复网络配置后应用失败"
            return 1
        fi
    else
        rm -f "$NETWORK_CONF"
        warn "未找到新版网络配置备份，已删除 $NETWORK_CONF"
        warn "请重启系统，以清除已移除参数的运行时值"
    fi

    echo
    echo "注意："
    echo "  restore 仅恢复新版脚本管理的 $NETWORK_CONF。"
    echo "  不会自动修改旧版历史归档、limits.conf 或 nproc 配置。"
    echo "  建议重启系统，使所有未持久化的旧参数彻底恢复默认状态。"
}

show_status() {
    local available_cc
    local current_cc
    local current_qdisc
    local current_tfo
    local ip_forward
    local rp_filter_all
    local rp_filter_default
    local file_max
    local somaxconn
    local backlog
    local port_range

    available_cc=$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || echo "未知")
    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
    current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "未知")
    current_tfo=$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo "未知")
    ip_forward=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo "未知")
    rp_filter_all=$(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null || echo "未知")
    rp_filter_default=$(sysctl -n net.ipv4.conf.default.rp_filter 2>/dev/null || echo "未知")
    file_max=$(sysctl -n fs.file-max 2>/dev/null || echo "未知")
    somaxconn=$(sysctl -n net.core.somaxconn 2>/dev/null || echo "未知")
    backlog=$(sysctl -n net.core.netdev_max_backlog 2>/dev/null || echo "未知")
    port_range=$(sysctl -n net.ipv4.ip_local_port_range 2>/dev/null || echo "未知")

    echo "========== 网络优化状态 =========="
    echo "配置文件: $NETWORK_CONF"
    [[ -f "$NETWORK_CONF" ]] && echo "配置状态: 已存在" || echo "配置状态: 未创建"
    [[ -f "$NETWORK_BACKUP" ]] && echo "配置备份: $NETWORK_BACKUP"

    echo
    echo "拥塞控制:"
    echo "  可用算法: $available_cc"
    echo "  当前算法: $current_cc"
    echo "  默认队列: $current_qdisc"
    echo "  TCP Fast Open: $current_tfo"

    echo
    echo "转发与兼容性:"
    echo "  IPv4 转发: $ip_forward"
    echo "  rp_filter(all): $rp_filter_all"
    echo "  rp_filter(default): $rp_filter_default"
    echo "  IPv6 转发: 未由本模块配置"
    echo "  route_localnet: 未由本模块配置"
    echo "  MPTCP: 未由本模块配置"

    echo
    echo "连接容量:"
    echo "  fs.file-max: $file_max"
    echo "  somaxconn: $somaxconn"
    echo "  netdev_max_backlog: $backlog"
    echo "  临时端口范围: $port_range"

    echo
    echo "兼容迁移:"
    [[ -f "$LEGACY_KERNEL_ARCHIVE" ]] &&
        echo "  旧 kernel 配置归档: $LEGACY_KERNEL_ARCHIVE"

    [[ -f "$LEGACY_SYSCTL_BACKUP" ]] &&
        echo "  旧 sysctl.conf 备份: $LEGACY_SYSCTL_BACKUP"

    [[ -f "$LIMITS_LEGACY_ARCHIVE" ]] &&
        echo "  旧 limits 优化配置归档: $LIMITS_LEGACY_ARCHIVE"
}

show_help() {
    cat <<'EOF'
用法：
  network-optimize.sh install   写入并应用网络优化配置
  network-optimize.sh restore   恢复新版脚本修改前的配置
  network-optimize.sh status    查看当前网络优化状态
  network-optimize.sh help      显示本帮助

新版配置特点：
  - 使用 fq + BBR（内核支持时）
  - 启用 IPv4 转发
  - 使用宽松 rp_filter=2，兼容代理与端口转发
  - 不启用 IPv6 转发、route_localnet、MPTCP
  - 不再管理 limits.conf、nproc、memlock
EOF
}

main() {
    local command="${1:-install}"

    require_root

    local required_command
    for required_command in sysctl grep awk sort mktemp mv cp find modprobe; do
        if ! command -v "$required_command" >/dev/null 2>&1; then
            error "缺少必要命令: $required_command"
            exit 1
        fi
    done

    case "$command" in
        install)
            install_optimization
            ;;
        restore)
            restore_optimization
            ;;
        status)
            show_status
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            error "未知参数: $command"
            show_help
            exit 1
            ;;
    esac
}

trap 'error "网络优化脚本在第 $LINENO 行执行失败"' ERR

main "$@"
