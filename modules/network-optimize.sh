#!/bin/bash
# 网络性能优化模块 v4.4 - 增加TCP Fast Open和MPTCP支持
# 集成第一个脚本的完整参数配置 - 使用fq_codel队列调度

set -euo pipefail

# === 常量定义 ===
readonly SYSCTL_CONFIG="/etc/sysctl.conf"
readonly LIMITS_CONFIG="/etc/security/limits.conf"

# === 日志函数 ===
log() {
    local msg="$1" level="${2:-info}"
    local -A colors=([info]="\033[0;36m" [warn]="\033[0;33m" [error]="\033[0;31m")
    echo -e "${colors[$level]:-\033[0;32m}$msg\033[0m"
}

# === 核心函数 ===

# 智能备份配置文件
backup_configs() {
    # 备份 sysctl 配置
    if [[ -f "$SYSCTL_CONFIG" ]]; then
        # 首次备份：保存原始配置
        if [[ ! -f "$SYSCTL_CONFIG.original" ]]; then
            cp "$SYSCTL_CONFIG" "$SYSCTL_CONFIG.original"
            log "已备份原始 sysctl 配置: sysctl.conf.original" "info"
        fi
        
        # 最近备份：总是覆盖
        cp "$SYSCTL_CONFIG" "$SYSCTL_CONFIG.backup"
        log "已备份当前 sysctl 配置: sysctl.conf.backup" "info"
    fi
    
    # 备份 limits 配置
    if [[ -f "$LIMITS_CONFIG" ]]; then
        if [[ ! -f "$LIMITS_CONFIG.original" ]]; then
            cp "$LIMITS_CONFIG" "$LIMITS_CONFIG.original"
            log "已备份原始 limits 配置: limits.conf.original" "info"
        fi
        
        cp "$LIMITS_CONFIG" "$LIMITS_CONFIG.backup"
        log "已备份当前 limits 配置: limits.conf.backup" "info"
    fi
}

# 检测主用网络接口
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

# 检查MPTCP支持
check_mptcp_support() {
    log "检查 MPTCP 支持..." "info"
    
    # 检查MPTCP内核支持
    if [[ -f "/proc/sys/net/mptcp/enabled" ]]; then
        log "✓ 系统支持 MPTCP" "info"
        return 0
    else
        log "⚠ 系统不支持 MPTCP，将跳过相关配置" "warn"
        return 1
    fi
}

# 配置系统资源限制
configure_system_limits() {
    log "配置系统资源限制..." "info"
    
    # 处理 nproc 配置文件重命名（修复版）
    if compgen -G "/etc/security/limits.d/*nproc.conf" > /dev/null 2>&1; then
        for file in /etc/security/limits.d/*nproc.conf; do
            if [[ -f "$file" ]]; then
                mv "$file" "${file%.conf}.conf_bk" 2>/dev/null || true
                log "已重命名 nproc 配置文件: $(basename "$file")" "info"
            fi
        done
    fi
    
    # 配置 PAM 限制
    if [[ -f /etc/pam.d/common-session ]] && ! grep -q 'session required pam_limits.so' /etc/pam.d/common-session; then
        echo "session required pam_limits.so" >> /etc/pam.d/common-session
        log "已配置 PAM limits 模块" "info"
    fi
    
    # 更新 limits.conf
    sed -i '/^# End of file/,$d' "$LIMITS_CONFIG"
    cat >> "$LIMITS_CONFIG" << 'EOF'
# End of file
*     soft   nofile    1048576
*     hard   nofile    1048576
*     soft   nproc     1048576
*     hard   nproc     1048576
*     soft   core      1048576
*     hard   core      1048576
*     hard   memlock   unlimited
*     soft   memlock   unlimited

root     soft   nofile    1048576
root     hard   nofile    1048576
root     soft   nproc     1048576
root     hard   nproc     1048576
root     soft   core      1048576
root     hard   core      1048576
root     hard   memlock   unlimited
root     soft   memlock   unlimited
EOF
    
    log "✓ 系统资源限制配置完成" "info"
}

# 配置网络优化参数（使用第一个脚本的完整参数）
configure_network_parameters() {
    log "配置网络优化参数..." "info"
    
    backup_configs
    
    # 需要移除的旧参数（第一个脚本的完整参数列表）
    local old_params=(
        "fs.file-max"
        "fs.inotify.max_user_instances"
        "net.core.somaxconn"
        "net.core.netdev_max_backlog"
        "net.core.rmem_max"
        "net.core.wmem_max"
        "net.ipv4.udp_rmem_min"
        "net.ipv4.udp_wmem_min"
        "net.ipv4.tcp_rmem"
        "net.ipv4.tcp_wmem"
        "net.ipv4.tcp_mem"
        "net.ipv4.udp_mem"
        "net.ipv4.tcp_syncookies"
        "net.ipv4.tcp_fin_timeout"
        "net.ipv4.tcp_tw_reuse"
        "net.ipv4.ip_local_port_range"
        "net.ipv4.tcp_max_syn_backlog"
        "net.ipv4.tcp_max_tw_buckets"
        "net.ipv4.route.gc_timeout"
        "net.ipv4.tcp_syn_retries"
        "net.ipv4.tcp_synack_retries"
        "net.ipv4.tcp_timestamps"
        "net.ipv4.tcp_max_orphans"
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
        "net.ipv4.tcp_keepalive_time"
        "net.ipv4.tcp_notsent_lowat"
        "net.ipv4.conf.all.route_localnet"
        "net.ipv4.ip_forward"
        "net.ipv4.conf.all.forwarding"
        "net.ipv4.conf.default.forwarding"
        "net.core.default_qdisc"
        "net.ipv4.tcp_congestion_control"
        "net.ipv4.tcp_abort_on_overflow"
        "net.ipv4.conf.all.rp_filter"
        "net.ipv4.conf.default.rp_filter"
        "net.ipv4.tcp_fastopen"
        "net.mptcp.enabled"
        "net.mptcp.checksum_enabled"
        "net.mptcp.allow_join_initial_addr_port"
    )
    
    # 移除旧配置
    for param in "${old_params[@]}"; do
        sed -i "/^${param//./\\.}[[:space:]]*=.*/d" "$SYSCTL_CONFIG"
    done
    
    # 检查MPTCP支持并设置MPTCP参数（使用正确的参数）
    local mptcp_config=""
    if check_mptcp_support; then
        mptcp_config="
# MPTCP (Multipath TCP) 优化配置
net.mptcp.enabled = 1
net.mptcp.checksum_enabled = 1
net.mptcp.allow_join_initial_addr_port = 1"
    fi
    
    # 添加第一个脚本的完整网络优化配置（使用fq_codel队列调度）
    cat >> "$SYSCTL_CONFIG" << EOF

# 网络性能优化 - 完整参数配置
fs.file-max = 1048576
fs.inotify.max_user_instances = 8192
net.core.somaxconn = 32768
net.core.netdev_max_backlog = 32768
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 16384 33554432
net.ipv4.tcp_mem = 786432 1048576 26777216
net.ipv4.udp_mem = 65536 131072 262144
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 1024 65000
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_max_tw_buckets = 6000
net.ipv4.route.gc_timeout = 100
net.ipv4.tcp_syn_retries = 1
net.ipv4.tcp_synack_retries = 1
net.ipv4.tcp_timestamps = 0
net.ipv4.tcp_max_orphans = 131072
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_ecn = 0
net.ipv4.tcp_frto = 0
net.ipv4.tcp_mtu_probing = 0
net.ipv4.tcp_rfc1337 = 0
net.ipv4.tcp_sack = 1
net.ipv4.tcp_fack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = 1
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.conf.all.route_localnet = 1
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
net.ipv4.conf.default.forwarding = 1
net.core.default_qdisc = fq_codel
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3${mptcp_config}

EOF
    
    # 应用配置（简化版）
    if sysctl -p >/dev/null 2>&1; then
        log "✓ sysctl 参数已应用" "info"
    else
        log "✗ sysctl 参数应用失败" "warn"
    fi
}

# 配置网卡队列调度
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
    if tc qdisc show dev "$interface" 2>/dev/null | grep -q "fq_codel"; then
        log "$interface 已使用 fq_codel 队列" "info"
        return 0
    fi
    
    # 切换到fq_codel队列
    log "切换 $interface 队列为 fq_codel..." "info"
    if tc qdisc replace dev "$interface" root fq_codel 2>/dev/null; then
        log "✓ $interface 队列已切换为 fq_codel" "info"
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
    local current_tfo=$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo "0")
    
    log "当前拥塞控制算法: $current_cc" "info"
    log "当前默认队列调度: $current_qdisc" "info"
    log "当前TCP Fast Open: $current_tfo (0=禁用,1=客户端,2=服务端,3=全部)" "info"
    
    # 检查MPTCP状态
    if [[ -f "/proc/sys/net/mptcp/enabled" ]]; then
        local current_mptcp=$(sysctl -n net.mptcp.enabled 2>/dev/null || echo "0")
        log "当前MPTCP状态: $current_mptcp (0=禁用,1=启用)" "info"
    fi
    
    if [[ "$current_cc" == "bbr" && "$current_qdisc" == "fq_codel" && "$current_tfo" == "3" ]]; then
        log "✓ BBR + fq_codel + TFO 配置成功" "info"
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
    local current_tfo=$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo "0")
    
    log "  拥塞控制算法: $current_cc" "info"
    log "  队列调度算法: $current_qdisc" "info"
    log "  TCP Fast Open: $current_tfo" "info"
    
    # 显示MPTCP状态
    if [[ -f "/proc/sys/net/mptcp/enabled" ]]; then
        local current_mptcp=$(sysctl -n net.mptcp.enabled 2>/dev/null || echo "0")
        log "  MPTCP状态: $current_mptcp" "info"
    fi
}

# 网络性能优化
setup_network_optimization() {
    echo
    log "网络性能优化说明:" "info"
    log "  BBR: 改进的TCP拥塞控制算法，提升网络吞吐量" "info"
    log "  fq_codel: 公平队列+延迟控制，平衡吞吐量和延迟" "info"
    log "  TCP Fast Open: 减少连接建立延迟，提升短连接性能" "info"
    log "  MPTCP: 多路径TCP，支持带宽聚合和链路冗余" "info"
    log "  完整参数: 包含系统资源限制和全面的TCP优化" "info"
    
    echo
    read -p "是否启用网络性能优化 (BBR+fq_codel+TFO+MPTCP+完整参数)? [Y/n] (默认: Y): " -r optimize_choice
    
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
    
    # 配置系统资源限制
    configure_system_limits
    
    # 配置网络参数
    configure_network_parameters
    
    # 配置网卡队列
    configure_interface_qdisc "$interface"
    
    # 验证配置
    verify_network_config
}

# 显示网络优化摘要
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
    if [[ "$current_qdisc" == "fq_codel" ]]; then
        log "  ✓ 队列调度: fq_codel" "info"
    else
        log "  ✗ 队列调度: $current_qdisc" "info"
    fi
    
    # TFO状态
    local current_tfo=$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo "0")
    if [[ "$current_tfo" == "3" ]]; then
        log "  ✓ TCP Fast Open: 启用 (客户端+服务端)" "info"
    else
        log "  ✗ TCP Fast Open: $current_tfo (0=禁用,1=客户端,2=服务端,3=全部)" "info"
    fi
    
    # MPTCP状态
    if [[ -f "/proc/sys/net/mptcp/enabled" ]]; then
        local current_mptcp=$(sysctl -n net.mptcp.enabled 2>/dev/null || echo "0")
        if [[ "$current_mptcp" == "1" ]]; then
            log "  ✓ MPTCP: 启用 (多路径TCP)" "info"
            # 显示MPTCP详细配置
            local mptcp_checksum=$(sysctl -n net.mptcp.checksum_enabled 2>/dev/null || echo "N/A")
            local mptcp_join=$(sysctl -n net.mptcp.allow_join_initial_addr_port 2>/dev/null || echo "N/A")
            log "    └── 校验和启用: $mptcp_checksum" "info"
            log "    └── 允许初始地址连接: $mptcp_join" "info"
        else
            log "  ✗ MPTCP: $current_mptcp (0=禁用,1=启用)" "info"
        fi
    else
        log "  ⚠ MPTCP: 系统不支持" "warn"
    fi
    
    # 系统资源限制状态（修复版检查）
    if grep -q "nofile.*1048576" "$LIMITS_CONFIG" 2>/dev/null; then
        log "  ✓ 系统资源限制: 已配置 (重新登录后生效)" "info"
    else
        log "  ✗ 系统资源限制: 未配置" "warn"
    fi
    
    # 配置文件状态
    if [[ -f "$SYSCTL_CONFIG.original" ]]; then
        log "  ✓ sysctl 原始配置: 已备份" "info"
    fi
    
    if [[ -f "$LIMITS_CONFIG.original" ]]; then
        log "  ✓ limits 原始配置: 已备份" "info"
    fi
    
    # 主网卡状态
    local interface
    if interface=$(detect_main_interface 2>/dev/null); then
        if command -v tc &>/dev/null && tc qdisc show dev "$interface" 2>/dev/null | grep -q "fq_codel"; then
            log "  ✓ 网卡 $interface: 使用 fq_codel 队列" "info"
        else
            log "  ✗ 网卡 $interface: 未使用 fq_codel 队列" "info"
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
    log "  查看TCP Fast Open: sysctl net.ipv4.tcp_fastopen" "info"
    log "  查看MPTCP状态: sysctl net.mptcp.enabled" "info"
    log "  查看MPTCP连接: ss -M" "info"
    log "  查看网卡队列: tc qdisc show" "info"
    log "  恢复 sysctl: cp /etc/sysctl.conf.backup /etc/sysctl.conf" "info"
    log "  恢复 limits: cp /etc/security/limits.conf.backup /etc/security/limits.conf" "info"
}

main "$@"
