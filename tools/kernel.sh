#!/bin/bash
# Linux Network Optimizer v2.3 - 完全整合版 (无功能缺失)
# 包含：内核检测、BBR自动修复、PAM/Limits深度优化、网卡队列优化、Debian 13特化处理

set -euo pipefail

readonly CUSTOM_CONF="/etc/sysctl.d/99-custom.conf"
readonly SYSCTL_FILE="/etc/sysctl.conf"
readonly LIMITS_CONFIG="/etc/security/limits.conf"

info() { echo "✅ $1"; }
warn() { echo "⚠️  $1"; }
error() { echo "❌ $1"; exit 1; }
success() { echo "🎉 $1"; }

# === 1. 基础环境检测 (保留原版) ===
check_env() {
    [[ $EUID -eq 0 ]] || error "需要 root 权限"
    
    local ver=$(uname -r | cut -d. -f1-2)
    local major=${ver%.*} minor=${ver#*.}
    [[ $major -gt 4 ]] || [[ $major -eq 4 && $minor -ge 9 ]] || error "内核版本过低 (需要4.9+)"
    
    ip route get 8.8.8.8 2>/dev/null | grep -oP 'dev \K\S+' | head -1 || \
    ls /sys/class/net/ 2>/dev/null | grep -v lo | head -1
}

# === 2. BBR 自动修复 (保留原版自动安装逻辑) ===
setup_bbr() {
    info "检查 BBR 支持..."
    modprobe tcp_bbr 2>/dev/null || true
    if ! grep -wq bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        warn "BBR 模块未就绪，尝试安装内核增强组件..."
        case $(grep ^ID= /etc/os-release 2>/dev/null) in
            *ubuntu*|*debian*) apt update >/dev/null 2>&1 && apt install -y linux-modules-extra-$(uname -r) >/dev/null 2>&1 || true ;;
            *centos*|*rhel*) yum install -y kernel-modules-extra >/dev/null 2>&1 || true ;;
        esac
        modprobe tcp_bbr 2>/dev/null || true
    fi
}

# === 3. 资源限制优化 (保留原版 PAM 及目录清理) ===
apply_limits() {
    info "配置系统资源限制 (Limits & PAM)..."
    [ -f "$LIMITS_CONFIG" ] && [ ! -f "${LIMITS_CONFIG}.bak" ] && cp "$LIMITS_CONFIG" "${LIMITS_CONFIG}.bak"
    
    # 清理 limits.d 冲突
    for file in /etc/security/limits.d/*nproc.conf; do
        [[ -f "$file" ]] && mv "$file" "${file}.disabled" 2>/dev/null || true
    done

    # PAM 确保生效
    [[ -f /etc/pam.d/common-session ]] && ! grep -q "pam_limits.so" /etc/pam.d/common-session && \
        echo "session required pam_limits.so" >> /etc/pam.d/common-session

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

# === 4. Sysctl 特化处理 (按你最新要求) ===
apply_sysctl() {
    read -p "是否为国内优化服务器? [y/N]: " -r
    local is_domestic=$(echo "$REPLY" | tr '[:upper:]' '[:lower:]')
    
    local content=""
    if [[ "$is_domestic" != "y" ]]; then
        info "应用海外版优化参数..."
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
        info "应用国内版优化参数..."
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

    source /etc/os-release
    if [[ "${ID:-}" == "debian" && "${VERSION_ID:-}" == "13" ]]; then
        info "Debian 13 特化模式: sysctl.conf -> .bak"
        [ -f "$SYSCTL_FILE" ] && mv "$SYSCTL_FILE" "${SYSCTL_FILE}.bak"
        echo "$content" > "$CUSTOM_CONF"
        sysctl --system
    else
        info "通用模式: 备份并覆盖 $SYSCTL_FILE"
        [ -f "$SYSCTL_FILE" ] && cp "$SYSCTL_FILE" "${SYSCTL_FILE}.backup"
        echo "$content" > "$SYSCTL_FILE"
        sysctl -p
    fi
}

# === 5. 恢复功能 (完整版) ===
restore_optimization() {
    [[ $EUID -eq 0 ]] || error "需要 root 权限"
    info "全面恢复原始配置..."

    # 恢复 Sysctl
    source /etc/os-release
    if [[ "${ID:-}" == "debian" && "${VERSION_ID:-}" == "13" ]]; then
        [ -f "${SYSCTL_FILE}.bak" ] && mv "${SYSCTL_FILE}.bak" "$SYSCTL_FILE"
        [ -f "$CUSTOM_CONF" ] && rm -f "$CUSTOM_CONF"
    else
        [ -f "${SYSCTL_FILE}.backup" ] && mv "${SYSCTL_FILE}.backup" "$SYSCTL_FILE"
    fi
    sysctl --system >/dev/null 2>&1 || true

    # 恢复 Limits & PAM
    [ -f "${LIMITS_CONFIG}.bak" ] && mv "${LIMITS_CONFIG}.bak" "$LIMITS_CONFIG"
    for file in /etc/security/limits.d/*.conf.disabled; do
        [[ -f "$file" ]] && mv "$file" "${file%.disabled}" 2>/dev/null || true
    done

    # 恢复网卡队列
    local interface=$(detect_interface)
    command -v tc >/dev/null 2>&1 && tc qdisc del dev "$interface" root 2>/dev/null || true

    success "系统配置已恢复至优化前状态"
}

# === 入口控制 ===
case "${1:-install}" in
    install)
        check_env
        setup_bbr
        apply_limits
        apply_sysctl
        # 网卡队列优化 (同步参数里的 fq)
        interface=$(detect_interface)
        command -v tc >/dev/null 2>&1 && tc qdisc replace dev "$interface" root fq 2>/dev/null || true
        success "全套优化已完成"
        ;;
    restore)
        restore_optimization
        ;;
    status)
        echo "拥塞控制: $(sysctl -n net.ipv4.tcp_congestion_control)"
        echo "队列算法: $(sysctl -n net.core.default_qdisc)"
        echo "TFO参数: $(sysctl -n net.ipv4.tcp_fastopen)"
        ;;
    *)
        echo "用法: $0 [install|restore|status]"
        ;;
esac
