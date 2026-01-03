#!/bin/bash
# Linux Network Optimizer v3.0 - 模式显示增强版
  
set -euo pipefail

readonly KERNEL_CONF="/etc/sysctl.d/99-kernel.conf"
readonly OLD_CUSTOM_CONF="/etc/sysctl.d/99-custom.conf"
readonly SYSCTL_FILE="/etc/sysctl.conf"
readonly LIMITS_CONFIG="/etc/security/limits.conf"

RUN_MODE="interactive"

info() { echo "✅ $1"; }
warn() { echo "⚠️  $1"; }
error() { echo "❌ $1"; exit 1; }
success() { echo "🎉 $1"; }

# === 环境检测 ===
check_env() {
    [[ $EUID -eq 0 ]] || error "需要 root 权限"
    if [ -f /proc/user_beancounters ] || [ -d /proc/vz ] || [ "$(systemd-detect-virt 2>/dev/null)" == "lxc" ]; then
        warn "检测到容器虚拟化，尝试继续..."
        IS_CONTAINER=true
    else
        IS_CONTAINER=false
    fi
}

detect_interface() {
    ip route get 1.1.1.1 2>/dev/null | grep -oP 'dev \K\S+' | head -1 || ls /sys/class/net/ 2>/dev/null | grep -v lo | head -1
}

# === 1. BBR & Limits ===
setup_bbr() {
    [[ "$IS_CONTAINER" == "true" ]] && return 0
    info "检查 BBR 支持..."
    modprobe tcp_bbr 2>/dev/null || true
    if ! grep -wq bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        case $(grep ^ID= /etc/os-release 2>/dev/null) in
            *ubuntu*|*debian*) apt update >/dev/null 2>&1 && apt install -y linux-modules-extra-$(uname -r) >/dev/null 2>&1 || true ;;
        esac
        modprobe tcp_bbr 2>/dev/null || true
    fi
}

apply_limits() {
    info "配置系统资源限制..."
    [ -f "$LIMITS_CONFIG" ] && [ ! -f "${LIMITS_CONFIG}.bak" ] && cp "$LIMITS_CONFIG" "${LIMITS_CONFIG}.bak"
    for file in /etc/security/limits.d/*nproc.conf; do [[ -f "$file" ]] && mv "$file" "${file}.disabled" 2>/dev/null || true; done
    [[ -f /etc/pam.d/common-session ]] && ! grep -q "pam_limits.so" /etc/pam.d/common-session && echo "session required pam_limits.so" >> /etc/pam.d/common-session

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

# === 2. Sysctl 处理 ===
apply_sysctl() {
    local target_scheme=""
    if [[ "$RUN_MODE" == "intl" ]]; then target_scheme="intl"
    elif [[ "$RUN_MODE" == "china" ]]; then target_scheme="china"
    else
        printf "是否为国内优化服务器? [y/N]: "
        read -r REPLY < /dev/tty || REPLY="n"
        [[ "$REPLY" =~ ^[Yy]$ ]] && target_scheme="china" || target_scheme="intl"
    fi
    
    # 醒目的模式展示
    echo "------------------------------------------------"
    if [[ "$target_scheme" == "china" ]]; then
        info "当前方案: [ 中国大陆优化方案 ]"
    else
        info "当前方案: [ 海外/国际优化方案 ]"
    fi
    echo "------------------------------------------------"

    local content=""
    if [[ "$target_scheme" == "intl" ]]; then
        content=$(cat << EOF
fs.file-max = 6815744
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_ecn=0
net.ipv4.tcp_frto=0
net.ipv4.tcp_mtu_probing=0
net.ipv4.tcp_rfc1337=0
net.ipv4.tcp_sack=1
net.ipv4.tcp_fack=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_adv_win_scale=1
net.ipv4.tcp_moderate_rcvbuf=1
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.ipv4.tcp_rmem=8192 174760 67108864
net.ipv4.tcp_wmem=8192 174760 67108864
net.ipv4.udp_rmem_min=8192
net.ipv4.udp_wmem_min=8192
net.ipv4.ip_forward=1
net.ipv4.conf.all.route_localnet=1
net.ipv4.conf.all.forwarding=1
net.ipv4.conf.default.forwarding=1
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv6.conf.all.forwarding=1
net.ipv6.conf.default.forwarding=1
net.ipv4.tcp_fastopen = 1027
EOF
)
    else
        content=$(cat << EOF
fs.file-max = 6815744
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_ecn=0
net.ipv4.tcp_frto=0
net.ipv4.tcp_mtu_probing=0
net.ipv4.tcp_rfc1337=0
net.ipv4.tcp_sack=1
net.ipv4.tcp_fack=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_adv_win_scale=1
net.ipv4.tcp_moderate_rcvbuf=1
net.ipv4.ip_forward=1
net.ipv4.conf.all.route_localnet=1
net.ipv4.conf.all.forwarding=1
net.ipv4.conf.default.forwarding=1
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv6.conf.all.forwarding=1
net.ipv6.conf.default.forwarding=1
net.ipv4.tcp_fastopen = 1027
EOF
)
    fi

    if [ -f "$OLD_CUSTOM_CONF" ] && [ ! -f "${OLD_CUSTOM_CONF}.bak" ]; then
        mv "$OLD_CUSTOM_CONF" "${OLD_CUSTOM_CONF}.bak"
    fi

    source /etc/os-release
    if [[ "${ID:-}" == "debian" && "${VERSION_ID:-}" == "13" ]]; then
        [ -f "$SYSCTL_FILE" ] && [ ! -f "${SYSCTL_FILE}.bak" ] && mv "$SYSCTL_FILE" "${SYSCTL_FILE}.bak"
        echo "$content" > "$KERNEL_CONF"
    else
        [ -f "$SYSCTL_FILE" ] && [ ! -f "${SYSCTL_FILE}.backup" ] && cp "$SYSCTL_FILE" "${SYSCTL_FILE}.backup"
        echo "$content" > "$SYSCTL_FILE"
    fi
    sysctl --system >/dev/null 2>&1 || true
}

# === 3. 恢复逻辑 ===
restore_optimization() {
    info "正在全面按备份恢复状态..."
    source /etc/os-release
    if [[ "${ID:-}" == "debian" && "${VERSION_ID:-}" == "13" ]]; then
        [ -f "${SYSCTL_FILE}.bak" ] && mv "${SYSCTL_FILE}.bak" "$SYSCTL_FILE"
        [ -f "$KERNEL_CONF" ] && rm -f "$KERNEL_CONF"
    else
        [ -f "${SYSCTL_FILE}.backup" ] && mv "${SYSCTL_FILE}.backup" "$SYSCTL_FILE"
    fi
    [ -f "${OLD_CUSTOM_CONF}.bak" ] && mv "${OLD_CUSTOM_CONF}.bak" "$OLD_CUSTOM_CONF"
    [ -f "${LIMITS_CONFIG}.bak" ] && mv "${LIMITS_CONFIG}.bak" "$LIMITS_CONFIG"
    for file in /etc/security/limits.d/*.conf.disabled; do [[ -f "$file" ]] && mv "$file" "${file%.disabled}" 2>/dev/null || true; done
    
    local interface=$(detect_interface)
    command -v tc >/dev/null 2>&1 && tc qdisc del dev "$interface" root 2>/dev/null || true
    sysctl --system >/dev/null 2>&1 || true
    success "所有配置已恢复"
}

# === 4. 入口 ===
main() {
    local cmd="install"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            install|restore|status) cmd="$1" ;;
            -i|--intl) RUN_MODE="intl" ;;
            -c|--china) RUN_MODE="china" ;;
        esac
        shift
    done

    case "$cmd" in
        install)
            check_env
            setup_bbr
            apply_limits
            apply_sysctl
            local interface=$(detect_interface)
            command -v tc >/dev/null 2>&1 && tc qdisc replace dev "$interface" root fq 2>/dev/null || true
            success "调优完成！"
            ;;
        restore) restore_optimization ;;
        status)  sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc ;;
    esac
}

main "$@"
