#!/bin/bash
# 网络性能优化模块 v4.7 - 修复版
# BBR + fq_codel + TFO + MPTCP优化

set -euo pipefail

readonly SYSCTL_CONFIG="/etc/sysctl.conf"
readonly LIMITS_CONFIG="/etc/security/limits.conf"

MPTCP_SUPPORTED_COUNT=0
MPTCP_TOTAL_COUNT=8
MPTCP_CONFIG_TEXT=""

# === 日志函数 ===
log() {
    local msg="$1" level="${2:-info}"
    local -A colors=([info]="\033[0;36m" [warn]="\033[0;33m" [error]="\033[0;31m")
    echo -e "${colors[$level]:-\033[0;32m}$msg\033[0m"
}

# === 检测函数 ===
detect_main_interface() {
    local interface
    interface=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++){if($i=="dev"){print $(i+1);exit}}}' || echo "")
    [[ -n "$interface" ]] && echo "$interface" || return 1
}

check_bbr_support() {
    log "检查 BBR 支持..." "info"
    
    if modprobe tcp_bbr 2>/dev/null; then
        log "✓ BBR 模块加载成功" "info"
        return 0
    fi
    
    if [[ -f "/proc/config.gz" ]] && zcat /proc/config.gz | grep -q "CONFIG_TCP_BBR=[ym]"; then
        log "✓ BBR 内建支持已确认" "info"
        return 0
    else
        log "✗ 系统不支持 BBR" "error"
        return 1
    fi
}

check_mptcp_support() {
    [[ -f "/proc/sys/net/mptcp/enabled" ]]
}

check_mptcp_param() {
    local param="$1"
    local param_file="/proc/sys/${param//./\/}"
    [[ -f "$param_file" ]]
}

# === 配置函数 ===
backup_configs() {
    if [[ -f "$SYSCTL_CONFIG" ]]; then
        [[ ! -f "$SYSCTL_CONFIG.original" ]] && cp "$SYSCTL_CONFIG" "$SYSCTL_CONFIG.original"
        cp "$SYSCTL_CONFIG" "$SYSCTL_CONFIG.backup"
        log "已备份 sysctl 配置" "info"
    fi
    
    if [[ -f "$LIMITS_CONFIG" ]]; then
        [[ ! -f "$LIMITS_CONFIG.original" ]] && cp "$LIMITS_CONFIG" "$LIMITS_CONFIG.original"
        cp "$LIMITS_CONFIG" "$LIMITS_CONFIG.backup"
        log "已备份 limits 配置" "info"
    fi
}

configure_mptcp_params() {
    MPTCP_SUPPORTED_COUNT=0
    MPTCP_CONFIG_TEXT=""
    
    if ! check_mptcp_support; then
        log "⚠ 系统不支持 MPTCP" "warn"
        MPTCP_CONFIG_TEXT="
# MPTCP 不支持"
        return 0
    fi
    
    log "检测 MPTCP 参数支持..." "info"
    
    MPTCP_CONFIG_TEXT="

# MPTCP 优化配置"
    
    # 逐个检测参数（使用更稳定的方式，避免关联数组）
    if check_mptcp_param "net.mptcp.enabled"; then
        MPTCP_CONFIG_TEXT+="
net.mptcp.enabled = 1"
        log "  ✓ 支持: net.mptcp.enabled" "info"
        MPTCP_SUPPORTED_COUNT=$((MPTCP_SUPPORTED_COUNT + 1))
    else
        log "  ✗ 跳过: net.mptcp.enabled" "warn"
    fi
    
    if check_mptcp_param "net.mptcp.allow_join_initial_addr_port"; then
        MPTCP_CONFIG_TEXT+="
net.mptcp.allow_join_initial_addr_port = 1"
        log "  ✓ 支持: net.mptcp.allow_join_initial_addr_port" "info"
        MPTCP_SUPPORTED_COUNT=$((MPTCP_SUPPORTED_COUNT + 1))
    else
        log "  ✗ 跳过: net.mptcp.allow_join_initial_addr_port" "warn"
    fi
    
    if check_mptcp_param "net.mptcp.pm_type"; then
        MPTCP_CONFIG_TEXT+="
net.mptcp.pm_type = 0"
        log "  ✓ 支持: net.mptcp.pm_type" "info"
        MPTCP_SUPPORTED_COUNT=$((MPTCP_SUPPORTED_COUNT + 1))
    else
        log "  ✗ 跳过: net.mptcp.pm_type" "warn"
    fi
    
    if check_mptcp_param "net.mptcp.checksum_enabled"; then
        MPTCP_CONFIG_TEXT+="
net.mptcp.checksum_enabled = 0"
        log "  ✓ 支持: net.mptcp.checksum_enabled" "info"
        MPTCP_SUPPORTED_COUNT=$((MPTCP_SUPPORTED_COUNT + 1))
    else
        log "  ✗ 跳过: net.mptcp.checksum_enabled" "warn"
    fi
    
    if check_mptcp_param "net.mptcp.stale_loss_cnt"; then
        MPTCP_CONFIG_TEXT+="
net.mptcp.stale_loss_cnt = 4"
        log "  ✓ 支持: net.mptcp.stale_loss_cnt" "info"
        MPTCP_SUPPORTED_COUNT=$((MPTCP_SUPPORTED_COUNT + 1))
    else
        log "  ✗ 跳过: net.mptcp.stale_loss_cnt" "warn"
    fi
    
    if check_mptcp_param "net.mptcp.add_addr_timeout"; then
        MPTCP_CONFIG_TEXT+="
net.mptcp.add_addr_timeout = 60000"
        log "  ✓ 支持: net.mptcp.add_addr_timeout" "info"
        MPTCP_SUPPORTED_COUNT=$((MPTCP_SUPPORTED_COUNT + 1))
    else
        log "  ✗ 跳过: net.mptcp.add_addr_timeout" "warn"
    fi
    
    if check_mptcp_param "net.mptcp.close_timeout"; then
        MPTCP_CONFIG_TEXT+="
net.mptcp.close_timeout = 30000"
        log "  ✓ 支持: net.mptcp.close_timeout" "info"
        MPTCP_SUPPORTED_COUNT=$((MPTCP_SUPPORTED_COUNT + 1))
    else
        log "  ✗ 跳过: net.mptcp.close_timeout" "warn"
    fi
    
    if check_mptcp_param "net.mptcp.scheduler"; then
        MPTCP_CONFIG_TEXT+="
net.mptcp.scheduler = default"
        log "  ✓ 支持: net.mptcp.scheduler" "info"
        MPTCP_SUPPORTED_COUNT=$((MPTCP_SUPPORTED_COUNT + 1))
    else
        log "  ✗ 跳过: net.mptcp.scheduler" "warn"
    fi
    
    log "MPTCP 参数检测完成: $MPTCP_SUPPORTED_COUNT/$MPTCP_TOTAL_COUNT" "info"
}

configure_system_limits() {
    log "配置系统资源限制..." "info"
    
    # 处理 nproc 配置文件
    if compgen -G "/etc/security/limits.d/*nproc.conf" > /dev/null 2>&1; then
        for file in /etc/security/limits.d/*nproc.conf; do
            [[ -f "$file" ]] && mv "$file" "${file%.conf}.conf_bk" 2>/dev/null || true
        done
    fi
    
    # 配置 PAM 限制
    if [[ -f /etc/pam.d/common-session ]] && ! grep -q 'session required pam_limits.so' /etc/pam.d/common-session; then
        echo "session required pam_limits.so" >> /etc/pam.d/common-session
    fi
    
    # 更新 limits.conf
    sed -i '/^# End of file/,$d' "$LIMITS_CONFIG"
    cat >> "$LIMITS_CONFIG" << 'EOF'
# End of file
*     soft   nofile    1048576
*     hard   nofile    1048576
*     soft   nproc     1048576
*     hard   nproc     1048576
*     hard   memlock   unlimited
*     soft   memlock   unlimited

root     soft   nofile    1048576
root     hard   nofile    1048576
root     soft   nproc     1048576
root     hard   nproc     1048576
root     hard   memlock   unlimited
root     soft   memlock   unlimited
EOF
    
    log "✓ 系统资源限制配置完成" "info"
}

configure_network_parameters() {
    log "配置网络优化参数..." "info"
    
    backup_configs
    
    # 清理旧的配置标记
    sed -i '/^# === 网络性能优化配置开始 ===/,/^# === 网络性能优化配置结束 ===/d' "$SYSCTL_CONFIG"
    sed -i '/^# 网络性能优化.*版/d' "$SYSCTL_CONFIG"
    sed -i '/^# MPTCP.*优化配置/d' "$SYSCTL_CONFIG"
    
    # 清理相关参数（避免重复）
    local params_to_clean=(
        "fs.file-max" "fs.inotify.max_user_instances" "net.core.somaxconn"
        "net.core.netdev_max_backlog" "net.core.rmem_max" "net.core.wmem_max"
        "net.ipv4.udp_rmem_min" "net.ipv4.udp_wmem_min" "net.ipv4.tcp_rmem"
        "net.ipv4.tcp_wmem" "net.ipv4.tcp_mem" "net.ipv4.udp_mem"
        "net.ipv4.tcp_syncookies" "net.ipv4.tcp_fin_timeout" "net.ipv4.tcp_tw_reuse"
        "net.ipv4.ip_local_port_range" "net.ipv4.tcp_max_syn_backlog" "net.ipv4.tcp_max_tw_buckets"
        "net.ipv4.route.gc_timeout" "net.ipv4.tcp_syn_retries" "net.ipv4.tcp_synack_retries"
        "net.ipv4.tcp_timestamps" "net.ipv4.tcp_max_orphans" "net.ipv4.tcp_no_metrics_save"
        "net.ipv4.tcp_ecn" "net.ipv4.tcp_frto" "net.ipv4.tcp_mtu_probing"
        "net.ipv4.tcp_rfc1337" "net.ipv4.tcp_sack" "net.ipv4.tcp_fack"
        "net.ipv4.tcp_window_scaling" "net.ipv4.tcp_adv_win_scale" "net.ipv4.tcp_moderate_rcvbuf"
        "net.ipv4.tcp_keepalive_time" "net.ipv4.tcp_notsent_lowat" "net.ipv4.conf.all.route_localnet"
        "net.ipv4.ip_forward" "net.ipv4.conf.all.forwarding" "net.ipv4.conf.default.forwarding"
        "net.core.default_qdisc" "net.ipv4.tcp_congestion_control" "net.ipv4.tcp_fastopen"
        "net.mptcp.enabled" "net.mptcp.checksum_enabled" "net.mptcp.allow_join_initial_addr_port"
        "net.mptcp.pm_type" "net.mptcp.stale_loss_cnt" "net.mptcp.add_addr_timeout"
        "net.mptcp.close_timeout" "net.mptcp.scheduler"
    )
    
    for param in "${params_to_clean[@]}"; do
        sed -i "/^[[:space:]]*${param//./\\.}[[:space:]]*=.*/d" "$SYSCTL_CONFIG" || true
    done
    
    # 配置 MPTCP 参数
    configure_mptcp_params
    
    # 添加新的配置块
    cat >> "$SYSCTL_CONFIG" << EOF

# === 网络性能优化配置开始 ===
# 网络性能优化模块 v4.7 - $(date +"%Y-%m-%d %H:%M")
# BBR + fq_codel + TFO + MPTCP($MPTCP_SUPPORTED_COUNT/$MPTCP_TOTAL_COUNT)

# 文件系统优化
fs.file-max = 1048576
fs.inotify.max_user_instances = 8192

# 网络核心参数
net.core.somaxconn = 32768
net.core.netdev_max_backlog = 32768
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432

# UDP 优化
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.ipv4.udp_mem = 65536 131072 262144

# TCP 缓冲区优化
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 16384 33554432
net.ipv4.tcp_mem = 786432 1048576 26777216

# TCP 连接优化
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

# TCP 高级参数
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

# 路由和转发
net.ipv4.conf.all.route_localnet = 1
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
net.ipv4.conf.default.forwarding = 1

# 拥塞控制和队列调度
net.core.default_qdisc = fq_codel
net.ipv4.tcp_congestion_control = bbr

# TCP Fast Open
net.ipv4.tcp_fastopen = 3${MPTCP_CONFIG_TEXT}
# === 网络性能优化配置结束 ===

EOF
    
    # 应用配置，保留详细错误分析
    log "应用 sysctl 配置..." "info"
    
    local sysctl_output sysctl_exitcode=0
    sysctl_output=$(sysctl -p 2>&1) || sysctl_exitcode=$?
    
    if [[ $sysctl_exitcode -eq 0 ]]; then
        log "✓ 所有 sysctl 参数应用成功" "info"
    else
        local total_params failed_params success_params
        total_params=$(echo "$sysctl_output" | grep -c "=" 2>/dev/null || echo "0")
        failed_params=$(echo "$sysctl_output" | grep -c "cannot stat" 2>/dev/null || echo "0")
        
        if [[ $total_params -ge $failed_params ]]; then
            success_params=$((total_params - failed_params))
        else
            success_params=0
        fi
        
        if [[ $failed_params -eq 0 ]]; then
            log "✓ 所有 $total_params 个参数应用成功" "info"
        else
            log "⚠ sysctl 应用完成: $success_params 个成功, $failed_params 个不支持" "warn"
            
            # 显示不支持的参数
            echo "$sysctl_output" | grep "cannot stat" 2>/dev/null | while read -r line; do
                if [[ "$line" =~ /proc/sys/([^:]+) ]]; then
                    local param="${BASH_REMATCH[1]//\//.}"
                    log "  ✗ 不支持: $param" "warn"
                fi
            done || true
        fi
    fi
}

configure_interface_qdisc() {
    local interface="$1"
    
    log "配置网卡队列调度..." "info"
    log "检测到主用网卡: $interface" "info"
    
    if ! command -v tc &>/dev/null; then
        log "✗ 未检测到 tc 命令，请安装 iproute2" "warn"
        return 1
    fi
    
    if tc qdisc show dev "$interface" 2>/dev/null | grep -q "fq_codel"; then
        log "$interface 已使用 fq_codel 队列" "info"
        return 0
    fi
    
    if tc qdisc replace dev "$interface" root fq_codel 2>/dev/null; then
        log "✓ $interface 队列已切换为 fq_codel" "info"
        return 0
    else
        log "✗ $interface 队列切换失败" "warn"
        return 1
    fi
}

# === 验证函数 ===
get_mptcp_param() {
    local param="$1"
    local param_file="/proc/sys/${param//./\/}"
    
    if [[ -f "$param_file" ]]; then
        sysctl -n "$param" 2>/dev/null || echo "N/A"
    else
        echo "N/A"
    fi
}

verify_network_config() {
    log "验证网络优化配置..." "info"
    
    local current_cc current_qdisc current_tfo
    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
    current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "未知")
    current_tfo=$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo "0")
    
    log "当前拥塞控制算法: $current_cc" "info"
    log "当前默认队列调度: $current_qdisc" "info"
    log "当前TCP Fast Open: $current_tfo" "info"
    
    # 检查 MPTCP 状态
    if check_mptcp_support; then
        local current_mptcp
        current_mptcp=$(get_mptcp_param "net.mptcp.enabled")
        log "当前MPTCP状态: $current_mptcp" "info"
        
        if [[ "$current_mptcp" == "1" && $MPTCP_SUPPORTED_COUNT -gt 0 ]]; then
            local mptcp_pm_type mptcp_stale_loss mptcp_scheduler
            mptcp_pm_type=$(get_mptcp_param "net.mptcp.pm_type")
            mptcp_stale_loss=$(get_mptcp_param "net.mptcp.stale_loss_cnt")
            mptcp_scheduler=$(get_mptcp_param "net.mptcp.scheduler")
            
            log "  └── 路径管理器: $mptcp_pm_type" "info"
            log "  └── 故障检测阈值: $mptcp_stale_loss" "info"
            log "  └── 调度器: $mptcp_scheduler" "info"
        fi
    fi
    
    # 判断核心功能配置状态
    local success=true
    [[ "$current_cc" != "bbr" ]] && { log "⚠ BBR 未启用" "warn"; success=false; }
    [[ "$current_qdisc" != "fq_codel" ]] && { log "⚠ fq_codel 未启用" "warn"; success=false; }
    [[ "$current_tfo" != "3" ]] && { log "⚠ TCP Fast Open 未完全启用" "warn"; success=false; }
    
    if [[ "$success" == "true" ]]; then
        log "✓ 核心网络优化配置成功" "info"
    else
        log "⚠ 部分功能未完全生效，建议重启系统" "warn"
    fi
}

show_network_summary() {
    echo
    log "🎯 网络优化摘要:" "info"
    
    local current_cc current_qdisc current_tfo current_mptcp
    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
    current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "未知")
    current_tfo=$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo "0")
    
    # 显示核心组件状态
    [[ "$current_cc" == "bbr" ]] && log "  ✓ BBR: 已启用" "info" || log "  ✗ BBR: $current_cc" "warn"
    [[ "$current_qdisc" == "fq_codel" ]] && log "  ✓ fq_codel: 已启用" "info" || log "  ✗ fq_codel: $current_qdisc" "warn"
    [[ "$current_tfo" == "3" ]] && log "  ✓ TCP Fast Open: 已启用" "info" || log "  ✗ TFO: $current_tfo" "warn"
    
    # MPTCP 详细状态
    if check_mptcp_support; then
        current_mptcp=$(get_mptcp_param "net.mptcp.enabled")
        if [[ "$current_mptcp" == "1" ]]; then
            log "  ✓ MPTCP: 已启用 ($MPTCP_SUPPORTED_COUNT/8 参数)" "info"
            
            # 显示 MPTCP 详细参数
            if [[ $MPTCP_SUPPORTED_COUNT -gt 0 ]]; then
                local checksum join pm_type stale_loss timeout_add timeout_close scheduler
                checksum=$(get_mptcp_param "net.mptcp.checksum_enabled")
                join=$(get_mptcp_param "net.mptcp.allow_join_initial_addr_port")
                pm_type=$(get_mptcp_param "net.mptcp.pm_type")
                stale_loss=$(get_mptcp_param "net.mptcp.stale_loss_cnt")
                timeout_add=$(get_mptcp_param "net.mptcp.add_addr_timeout")
                timeout_close=$(get_mptcp_param "net.mptcp.close_timeout")
                scheduler=$(get_mptcp_param "net.mptcp.scheduler")
                
                [[ "$checksum" != "N/A" ]] && log "    ├── 校验和: $checksum" "info"
                [[ "$join" != "N/A" ]] && log "    ├── 初始地址连接: $join" "info"
                [[ "$pm_type" != "N/A" ]] && log "    ├── 路径管理器: $pm_type" "info"
                [[ "$stale_loss" != "N/A" ]] && log "    ├── 故障检测: $stale_loss" "info"
                [[ "$timeout_add" != "N/A" ]] && log "    ├── ADD超时: ${timeout_add}ms" "info"
                [[ "$timeout_close" != "N/A" ]] && log "    ├── 关闭超时: ${timeout_close}ms" "info"
                [[ "$scheduler" != "N/A" ]] && log "    └── 调度器: $scheduler" "info"
            fi
        else
            log "  ✗ MPTCP: 未启用" "warn"
        fi
    else
        log "  ⚠ MPTCP: 系统不支持" "warn"
    fi
    
    # 其他状态
    grep -q "nofile.*1048576" "$LIMITS_CONFIG" 2>/dev/null && \
        log "  ✓ 系统资源限制: 已配置" "info" || log "  ✗ 系统资源限制: 未配置" "warn"
    
    # 网卡状态
    local interface
    if interface=$(detect_main_interface); then
        if command -v tc &>/dev/null && tc qdisc show dev "$interface" 2>/dev/null | grep -q "fq_codel"; then
            log "  ✓ 网卡 $interface: fq_codel" "info"
        else
            log "  ⚠ 网卡 $interface: 非 fq_codel" "warn"
        fi
    else
        log "  ✗ 网卡检测失败" "warn"
    fi
}

# === 主流程 ===
setup_network_optimization() {
    echo
    log "网络性能优化说明:" "info"
    log "  BBR: 改进TCP拥塞控制，提升吞吐量" "info"
    log "  fq_codel: 公平队列调度，平衡延迟" "info"
    log "  TCP Fast Open: 减少连接建立延迟" "info"
    log "  MPTCP: 多路径TCP，适合代理场景" "info"
    
    echo
    read -p "是否启用网络性能优化? [Y/n]: " -r optimize_choice
    
    if [[ "$optimize_choice" =~ ^[Nn]$ ]]; then
        log "跳过网络优化配置" "info"
        return 0
    fi
    
    # 检测网络接口
    local interface
    if ! interface=$(detect_main_interface); then
        log "✗ 未检测到主用网卡" "error"
        return 1
    fi
    
    # 检查 BBR 支持
    if ! check_bbr_support; then
        log "系统不支持BBR，无法继续配置" "error"
        return 1
    fi
    
    # 执行配置
    configure_system_limits
    configure_network_parameters
    configure_interface_qdisc "$interface"
    
    # 验证配置
    verify_network_config
}

main() {
    log "🚀 网络性能优化模块 v4.7" "info"
    
    setup_network_optimization
    show_network_summary
    
    echo
    log "🎉 网络优化配置完成!" "info"
    
    # 常用命令提示
    echo
    log "常用命令:" "info"
    log "  查看拥塞控制: sysctl net.ipv4.tcp_congestion_control" "info"
    log "  查看MPTCP状态: sysctl net.mptcp.enabled" "info"
    log "  查看MPTCP连接: ss -M" "info"
    log "  查看网卡队列: tc qdisc show" "info"
    log "  恢复配置: cp /etc/sysctl.conf.backup /etc/sysctl.conf && sysctl -p" "info"
}

main "$@"
