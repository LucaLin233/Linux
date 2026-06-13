#!/usr/bin/env bash
# Linux Network Optimizer v3.1 - kernel2.sh
# Sysctl profile: LucaLin proxy-focused configuration

set -euo pipefail

readonly KERNEL_CONF="/etc/sysctl.d/99-kernel.conf"
readonly OLD_CUSTOM_CONF="/etc/sysctl.d/99-custom.conf"
readonly SYSCTL_FILE="/etc/sysctl.conf"
readonly LIMITS_CONFIG="/etc/security/limits.conf"

info() { echo "✅ $1"; }
warn() { echo "⚠️  $1"; }
error() { echo "❌ $1"; exit 1; }
success() { echo "🎉 $1"; }

# === 环境检测 ===
check_env() {
    [[ $EUID -eq 0 ]] || error "需要 root 权限"

    if [ -f /proc/user_beancounters ] || [ -d /proc/vz ] || [ "$(systemd-detect-virt 2>/dev/null)" = "lxc" ]; then
        warn "检测到容器虚拟化，尝试继续..."
        IS_CONTAINER=true
    else
        IS_CONTAINER=false
    fi
}

detect_interface() {
    ip route get 1.1.1.1 2>/dev/null | grep -oP 'dev \K\S+' | head -1 || \
    ls /sys/class/net/ 2>/dev/null | grep -v lo | head -1
}

# === 1. BBR 检测 ===
setup_bbr() {
    [[ "${IS_CONTAINER:-false}" = "true" ]] && return 0

    info "检查 BBR 支持..."
    modprobe tcp_bbr 2>/dev/null || true

    if ! grep -wq bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        case "$(grep ^ID= /etc/os-release 2>/dev/null || true)" in
            *ubuntu*|*debian*)
                apt update >/dev/null 2>&1 && \
                apt install -y "linux-modules-extra-$(uname -r)" >/dev/null 2>&1 || true
                ;;
        esac

        modprobe tcp_bbr 2>/dev/null || true
    fi
}

# === 2. Limits 配置 ===
apply_limits() {
    info "配置系统资源限制..."

    [ -f "$LIMITS_CONFIG" ] && [ ! -f "${LIMITS_CONFIG}.bak" ] && cp "$LIMITS_CONFIG" "${LIMITS_CONFIG}.bak"

    for file in /etc/security/limits.d/*nproc.conf; do
        [[ -f "$file" ]] && mv "$file" "${file}.disabled" 2>/dev/null || true
    done

    if [[ -f /etc/pam.d/common-session ]] && ! grep -q "pam_limits.so" /etc/pam.d/common-session; then
        echo "session required pam_limits.so" >> /etc/pam.d/common-session
    fi

    sed -i '/# Network Optimizer/,$d' "$LIMITS_CONFIG"

    cat >> "$LIMITS_CONFIG" << 'EOF'
# Network Optimizer - 系统资源限制
*     soft   nofile    1048576
*     hard   nofile    1048576
*     soft   nproc     1048576
*     hard   nproc     1048576
*     soft   memlock   unlimited
*     hard   memlock   unlimited
root  soft   nofile    1048576
root  hard   nofile    1048576
root  soft   nproc     1048576
root  hard   nproc     1048576
root  soft   memlock   unlimited
root  hard   memlock   unlimited
EOF
}

# === 3. Sysctl 配置 ===
apply_sysctl() {
    info "写入 sysctl 代理优化参数..."

    local content
    content=$(cat << 'EOF'
# 1. 基础文件句柄限制
fs.file-max = 6815744
fs.nr_open = 6815744

# 2. 网络队列与连接优化
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_abort_on_overflow = 1
net.ipv4.ip_local_port_range = 1024 65535
net.core.netdev_max_backlog = 65536

# 3. BBR 与拥塞控制
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3

# 4. TCP 窗口与缓冲区优化
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = 1
net.ipv4.tcp_moderate_rcvbuf = 1
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192

# 5. IPv6 专项开启与调优
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
net.ipv6.conf.lo.disable_ipv6 = 0
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1

# IPv6 路由缓存和邻居表
net.ipv6.route.max_size = 1048576
net.ipv6.neigh.default.gc_thresh1 = 1024
net.ipv6.neigh.default.gc_thresh2 = 4096
net.ipv6.neigh.default.gc_thresh3 = 8192

# 6. 时间戳与连接回收
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_slow_start_after_idle = 0

# 7. 安全与转发配置
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv4.ip_forward = 1
net.ipv4.conf.all.route_localnet = 1
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_ecn = 0

# 8. 其他辅助优化
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_fack = 1
net.ipv4.tcp_mtu_probing = 1
EOF
)

    if [ -f "$OLD_CUSTOM_CONF" ] && [ ! -f "${OLD_CUSTOM_CONF}.bak" ]; then
        mv "$OLD_CUSTOM_CONF" "${OLD_CUSTOM_CONF}.bak"
    fi

    source /etc/os-release

    if [[ "${ID:-}" = "debian" && "${VERSION_ID:-}" = "13" ]]; then
        [ -f "$SYSCTL_FILE" ] && [ ! -f "${SYSCTL_FILE}.bak" ] && mv "$SYSCTL_FILE" "${SYSCTL_FILE}.bak"
        echo "$content" > "$KERNEL_CONF"
    else
        [ -f "$SYSCTL_FILE" ] && [ ! -f "${SYSCTL_FILE}.backup" ] && cp "$SYSCTL_FILE" "${SYSCTL_FILE}.backup"
        echo "$content" > "$SYSCTL_FILE"
    fi

    sysctl --system >/dev/null 2>&1 || true
}

# === 4. 恢复逻辑 ===
restore_optimization() {
    info "正在按备份恢复状态..."

    source /etc/os-release

    if [[ "${ID:-}" = "debian" && "${VERSION_ID:-}" = "13" ]]; then
        [ -f "${SYSCTL_FILE}.bak" ] && mv "${SYSCTL_FILE}.bak" "$SYSCTL_FILE"
        [ -f "$KERNEL_CONF" ] && rm -f "$KERNEL_CONF"
    else
        [ -f "${SYSCTL_FILE}.backup" ] && mv "${SYSCTL_FILE}.backup" "$SYSCTL_FILE"
    fi

    [ -f "${OLD_CUSTOM_CONF}.bak" ] && mv "${OLD_CUSTOM_CONF}.bak" "$OLD_CUSTOM_CONF"
    [ -f "${LIMITS_CONFIG}.bak" ] && mv "${LIMITS_CONFIG}.bak" "$LIMITS_CONFIG"

    for file in /etc/security/limits.d/*.conf.disabled; do
        [[ -f "$file" ]] && mv "$file" "${file%.disabled}" 2>/dev/null || true
    done

    local interface
    interface="$(detect_interface || true)"

    if [[ -n "${interface:-}" ]] && command -v tc >/dev/null 2>&1; then
        tc qdisc del dev "$interface" root 2>/dev/null || true
    fi

    sysctl --system >/dev/null 2>&1 || true
    success "所有配置已恢复"
}

# === 5. 状态查看 ===
show_status() {
    sysctl \
        net.ipv4.tcp_congestion_control \
        net.core.default_qdisc \
        net.ipv4.tcp_fastopen \
        net.ipv4.ip_forward \
        net.ipv6.conf.all.forwarding \
        fs.file-max \
        fs.nr_open 2>/dev/null || true
}

# === 6. 入口 ===
main() {
    local cmd="install"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            install|restore|status)
                cmd="$1"
                ;;
            *)
                warn "忽略未知参数: $1"
                ;;
        esac
        shift
    done

    case "$cmd" in
        install)
            check_env
            setup_bbr
            apply_limits
            apply_sysctl

            local interface
            interface="$(detect_interface || true)"

            if [[ -n "${interface:-}" ]] && command -v tc >/dev/null 2>&1; then
                tc qdisc replace dev "$interface" root fq 2>/dev/null || true
            fi

            success "调优完成！"
            ;;
        restore)
            restore_optimization
            ;;
        status)
            show_status
            ;;
    esac
}

main "$@"
