#!/bin/bash
# 网络性能优化模块 v4.1
# 修复网卡检测和tc命令问题

set -euo pipefail

# === 常量定义 ===
readonly SYSCTL_CONFIG="/etc/sysctl.conf"

# === 日志函数 ===
log() {
    local msg="$1" level="${2:-info}"
    local -A colors=([info]="\033[0;36m" [warn]="\033[0;33m" [error]="\033[0;31m")
    echo -e "${colors[$level]:-\033[0;32m}$msg\033[0m"
}

# === 核心函数 ===

# 智能备份sysctl配置
backup_sysctl_config() {
    if [[ -f "$SYSCTL_CONFIG" ]]; then
        # 首次备份：保存原始配置
        if [[ ! -f "$SYSCTL_CONFIG.original" ]]; then
            cp "$SYSCTL_CONFIG" "$SYSCTL_CONFIG.original"
            log "已备份原始配置: sysctl.conf.original" "info"
        fi
        
        # 最近备份：总是覆盖
        cp "$SYSCTL_CONFIG" "$SYSCTL_CONFIG.backup"
        log "已备份当前配置: sysctl.conf.backup" "info"
    fi
}

# 检测主用网络接口（修复版）
detect_main_interface() {
    local interface
    interface=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++){if($i=="dev"){print $(i+1);exit}}}' || echo "")
    
    if [[ -z "$interface" ]]; then
        return 1
    fi
    
    echo "$interface"
}

# 检查BBR支持
check_bbr_support() {
    log "检查 BBR 支持..." "info"
    
    # 尝试加载BBR模块
    if modprobe tcp_bbr 2>/dev/null; then
        log "✓ BBR 模块加载成功" "info"
        return 0
    fi
    
    log "BBR 模块加载失败，检查内核支持..." "warn"
    
    # 检查内核配置
    if [[ -f "/proc/config.gz" ]]; then
        if zcat /proc/config.gz | grep -q "CONFIG_TCP_BBR=[ym]"; then
            log "✓ BBR 模块编译在内核中" "info"
            return 0
        else
            log "✗ 内核不支持 BBR" "error"
            return 1
        fi
    else
        log "⚠ 无法确定内核 BBR 支持状态" "warn"
        return 0  # 假设支持，继续配置
    fi
}

# 配置网络优化参数
configure_network_parameters() {
    log "配置网络优化参数..." "info"
    
    backup_sysctl_config
    
    # 需要移除的旧参数
    local old_params=(
        "net.ipv4.tcp_congestion_control"
        "net.core.default_qdisc"
        "fs.file-max"
        "net.ipv4.tcp_max_syn_backlog"
        "net.core.somaxconn"
        "net.ipv4.tcp_tw_reuse"
        "net.ipv4.tcp_abort_on_overflow"
        "net.ipv4.tcp_no_metrics_save"
        "net.ipv4.tcp_ecn"
        "net.ipv4.tcp_frto"
        "net.ipv4.tcp_mtu_probing"
        "net.ipv4.tcp_rfc1337"
        "net.ipv4.tcp_sack"
        "net.ipv4.tcp_fack"
        "net.ipv4.tcp_window_scaling"
        "net.ipv4.tcp_adv_win_scale"
        "net.ipv4.tcp_moderate_rcvbuf"
        "net.ipv4.tcp_fin_timeout"
        "net.ipv4.tcp_rmem"
        "net.ipv4.tcp_wmem"
        "net.core.rmem_max"
        "net.core.wmem_max"
        "net.ipv4.udp_rmem_min"
        "net.ipv4.udp_wmem_min"
        "net.ipv4.ip_local_port_range"
        "net.ipv4.tcp_timestamps"
        "net.ipv4.conf.all.rp_filter"
        "net.ipv4.conf.default.rp_filter"
        "net.ipv4.ip_forward"
        "net.ipv4.conf.all.route_localnet"
    )
    
    # 移除旧配置
    for param in "${old_params[@]}"; do
        sed -i "/^${param//./\\.}[[:space:]]*=.*/d" "$SYSCTL_CONFIG"
    done
    
    # 添加新的网络优化配置
    cat >> "$SYSCTL_CONFIG" << 'EOF'

# 网络性能优化 - BBR + cake + 高级参数
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = cake
fs.file-max = 6815744
net.ipv4.tcp_max_syn_backlog = 8192
net.core.somaxconn = 8192
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_abort_on_overflow = 1
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_ecn = 0
net.ipv4.tcp_frto = 0
net.ipv4.tcp_mtu_probing = 0
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_fack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = 2
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_timestamps = 1
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv4.ip_forward = 1
net.ipv4.conf.all.route_localnet = 1

EOF
    
    # 应用配置
    if sysctl -p >/dev/null 2>&1; then
        log "✓ sysctl 参数已应用" "info"
    else
        log "✗ sysctl 参数应用失败" "warn"
    fi
}

# 配置网卡队列调度（修复版）
configure_interface_qdisc() {
    local interface="$1"
    
    log "配置网卡队列调度..." "info"
    log "检测到主用网卡: $interface" "info"
    
    # 检查tc命令
    if ! command -v tc &>/dev/null; then
        log "✗ 未检测到 tc 命令，请安装 iproute2" "warn"
        return 1
    fi
    
    # 检查当前队列调度
    if tc qdisc show dev "$interface" 2>/dev/null | grep -q "cake"; then
        log "$interface 已使用 cake 队列" "info"
        return 0
    fi
    
    # 切换到cake队列
    log "切换 $interface 队列为 cake..." "info"
    if tc qdisc replace dev "$interface" root cake 2>/dev/null; then
        log "✓ $interface 队列已切换为 cake" "info"
        return 0
    else
        log "✗ $interface 队列切换失败 (可能需要管理员权限或硬件不支持)" "warn"
        return 1
    fi
}

# 验证网络优化配置
verify_network_config() {
    log "验证网络优化配置..." "info"
    
    local current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
    local current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "未知")
    
    log "当前拥塞控制算法: $current_cc" "info"
    log "当前默认队列调度: $current_qdisc" "info"
    
    if [[ "$current_cc" == "bbr" && "$current_qdisc" == "cake" ]]; then
        log "✓ BBR + cake 配置成功" "info"
        return 0
    else
        log "⚠ 网络优化配置可能未完全生效" "warn"
        log "建议重启系统以完全应用配置" "warn"
        return 1
    fi
}

# 显示当前网络状态
show_current_network_status() {
    log "当前网络状态:" "info"
    
    local current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
    local current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "未知")
    
    log "  拥塞控制算法: $current_cc" "info"
    log "  队列调度算法: $current_qdisc" "info"
}

# 网络性能优化
setup_network_optimization() {
    echo
    log "网络性能优化说明:" "info"
    log "  BBR: 改进的TCP拥塞控制算法，提升网络吞吐量" "info"
    log "  cake: 智能队列管理，减少网络延迟和抖动" "info"
    
    echo
    read -p "是否启用网络性能优化 (BBR+cake)? [Y/n] (默认: Y): " -r optimize_choice
    
    if [[ "$optimize_choice" =~ ^[Nn]$ ]]; then
        log "跳过网络优化配置" "info"
        show_current_network_status
        return 0
    fi
    
    # 检测网络接口
    local interface
    if ! interface=$(detect_main_interface); then
        log "✗ 未检测到主用网卡" "error"
        return 1
    fi
    
    # 检查BBR支持
    if ! check_bbr_support; then
        log "系统不支持BBR，无法继续配置" "error"
        return 1
    fi
    
    # 配置网络参数
    configure_network_parameters
    
    # 配置网卡队列
    configure_interface_qdisc "$interface"
    
    # 验证配置
    verify_network_config
}

# 显示网络优化摘要（修复版）
show_network_summary() {
    echo
    log "🎯 网络优化摘要:" "info"
    
    # 拥塞控制状态
    local current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
    if [[ "$current_cc" == "bbr" ]]; then
        log "  ✓ 拥塞控制: BBR" "info"
    else
        log "  ✗ 拥塞控制: $current_cc" "info"
    fi
    
    # 队列调度状态
    local current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "未知")
    if [[ "$current_qdisc" == "cake" ]]; then
        log "  ✓ 队列调度: cake" "info"
    else
        log "  ✗ 队列调度: $current_qdisc" "info"
    fi
    
    # 配置文件状态
    if [[ -f "$SYSCTL_CONFIG.original" ]]; then
        log "  ✓ 原始配置: 已备份" "info"
    fi
    
    if [[ -f "$SYSCTL_CONFIG.backup" ]]; then
        log "  ✓ 最近配置: 已备份" "info"
    fi
    
    # 主网卡状态（修复版）
    local interface
    if interface=$(detect_main_interface 2>/dev/null); then
        if command -v tc &>/dev/null && tc qdisc show dev "$interface" 2>/dev/null | grep -q "cake"; then
            log "  ✓ 网卡 $interface: 使用 cake 队列" "info"
        else
            log "  ✗ 网卡 $interface: 未使用 cake 队列" "info"
        fi
    else
        log "  ✗ 网卡检测: 失败" "warn"
    fi
}

# === 主流程 ===
main() {
    log "🚀 配置网络性能优化..." "info"
    
    setup_network_optimization
    
    show_network_summary
    
    echo
    log "🎉 网络优化配置完成!" "info"
    
    # 显示有用的命令
    echo
    log "常用命令:" "info"
    log "  查看拥塞控制: sysctl net.ipv4.tcp_congestion_control" "info"
    log "  查看队列调度: sysctl net.core.default_qdisc" "info"
    log "  查看网卡队列: tc qdisc show" "info"
    log "  恢复配置: cp /etc/sysctl.conf.backup /etc/sysctl.conf" "info"
}

main "$@"
