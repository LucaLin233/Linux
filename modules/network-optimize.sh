#!/bin/bash
# 网络性能优化模块 v4.6 - 稳定版
# 集成完整参数配置 - 使用fq_codel队列调度 + 稳定MPTCP优化

set -euo pipefail

# === 常量定义 ===
readonly SYSCTL_CONFIG="/etc/sysctl.conf"
readonly LIMITS_CONFIG="/etc/security/limits.conf"

# === 全局变量初始化 ===
MPTCP_SUPPORTED_COUNT=0
MPTCP_TOTAL_COUNT=10
MPTCP_CONFIG_TEXT=""

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

# 检查单个MPTCP参数
check_mptcp_param() {
    local param="$1"
    local param_file="/proc/sys/${param//./\/}"
    
    if [[ -f "$param_file" ]]; then
        return 0
    else
        return 1
    fi
}

# 稳定版MPTCP参数配置
configure_mptcp_params() {
    # 重置全局变量
    MPTCP_SUPPORTED_COUNT=0
    MPTCP_CONFIG_TEXT=""
    
    if ! check_mptcp_support; then
        MPTCP_CONFIG_TEXT="
# MPTCP 不被当前系统支持"
        return 0
    fi
    
    log "检测MPTCP参数支持情况..." "info"
    
    # 开始构建配置文本
    MPTCP_CONFIG_TEXT="

# MPTCP (Multipath TCP) 智能优化配置 - 专为代理场景优化"
    
    # 逐个检测参数（使用更稳定的方式）
    
    # 1. net.mptcp.enabled
    if check_mptcp_param "net.mptcp.enabled"; then
        MPTCP_CONFIG_TEXT="${MPTCP_CONFIG_TEXT}
net.mptcp.enabled = 1  # 启用MPTCP"
        log "  ✓ 支持参数: net.mptcp.enabled" "info"
        MPTCP_SUPPORTED_COUNT=$((MPTCP_SUPPORTED_COUNT + 1))
    else
        log "  ✗ 跳过参数: net.mptcp.enabled (内核不支持)" "warn"
    fi
    
    # 2. net.mptcp.allow_join_initial_addr_port
    if check_mptcp_param "net.mptcp.allow_join_initial_addr_port"; then
        MPTCP_CONFIG_TEXT="${MPTCP_CONFIG_TEXT}
net.mptcp.allow_join_initial_addr_port = 1  # 允许初始地址连接"
        log "  ✓ 支持参数: net.mptcp.allow_join_initial_addr_port" "info"
        MPTCP_SUPPORTED_COUNT=$((MPTCP_SUPPORTED_COUNT + 1))
    else
        log "  ✗ 跳过参数: net.mptcp.allow_join_initial_addr_port (内核不支持)" "warn"
    fi
    
    # 3. net.mptcp.pm_type
    if check_mptcp_param "net.mptcp.pm_type"; then
        MPTCP_CONFIG_TEXT="${MPTCP_CONFIG_TEXT}
net.mptcp.pm_type = 0  # 路径管理器类型(0=内核)"
        log "  ✓ 支持参数: net.mptcp.pm_type" "info"
        MPTCP_SUPPORTED_COUNT=$((MPTCP_SUPPORTED_COUNT + 1))
    else
        log "  ✗ 跳过参数: net.mptcp.pm_type (内核不支持)" "warn"
    fi
    
    # 4. net.mptcp.checksum_enabled
    if check_mptcp_param "net.mptcp.checksum_enabled"; then
        MPTCP_CONFIG_TEXT="${MPTCP_CONFIG_TEXT}
net.mptcp.checksum_enabled = 0  # 校验和(代理推荐关闭)"
        log "  ✓ 支持参数: net.mptcp.checksum_enabled" "info"
        MPTCP_SUPPORTED_COUNT=$((MPTCP_SUPPORTED_COUNT + 1))
    else
        log "  ✗ 跳过参数: net.mptcp.checksum_enabled (内核不支持)" "warn"
    fi
    
    # 5. net.mptcp.stale_loss_cnt
    if check_mptcp_param "net.mptcp.stale_loss_cnt"; then
        MPTCP_CONFIG_TEXT="${MPTCP_CONFIG_TEXT}
net.mptcp.stale_loss_cnt = 4  # 故障检测阈值"
        log "  ✓ 支持参数: net.mptcp.stale_loss_cnt" "info"
        MPTCP_SUPPORTED_COUNT=$((MPTCP_SUPPORTED_COUNT + 1))
    else
        log "  ✗ 跳过参数: net.mptcp.stale_loss_cnt (内核不支持)" "warn"
    fi
    
    # 6. net.mptcp.add_addr_timeout
    if check_mptcp_param "net.mptcp.add_addr_timeout"; then
        MPTCP_CONFIG_TEXT="${MPTCP_CONFIG_TEXT}
net.mptcp.add_addr_timeout = 60000  # ADD_ADDR超时(ms)"
        log "  ✓ 支持参数: net.mptcp.add_addr_timeout" "info"
        MPTCP_SUPPORTED_COUNT=$((MPTCP_SUPPORTED_COUNT + 1))
    else
        log "  ✗ 跳过参数: net.mptcp.add_addr_timeout (内核不支持)" "warn"
    fi
    
    # 7. net.mptcp.close_timeout
    if check_mptcp_param "net.mptcp.close_timeout"; then
        MPTCP_CONFIG_TEXT="${MPTCP_CONFIG_TEXT}
net.mptcp.close_timeout = 30000  # 连接关闭超时(ms)"
        log "  ✓ 支持参数: net.mptcp.close_timeout" "info"
        MPTCP_SUPPORTED_COUNT=$((MPTCP_SUPPORTED_COUNT + 1))
    else
        log "  ✗ 跳过参数: net.mptcp.close_timeout (内核不支持)" "warn"
    fi
    
    # 8. net.mptcp.scheduler
    if check_mptcp_param "net.mptcp.scheduler"; then
        MPTCP_CONFIG_TEXT="${MPTCP_CONFIG_TEXT}
net.mptcp.scheduler = default  # 数据包调度器"
        log "  ✓ 支持参数: net.mptcp.scheduler" "info"
        MPTCP_SUPPORTED_COUNT=$((MPTCP_SUPPORTED_COUNT + 1))
    else
        log "  ✗ 跳过参数: net.mptcp.scheduler (内核不支持)" "warn"
    fi
    
    # 9. net.mptcp.syn_retries
    if check_mptcp_param "net.mptcp.syn_retries"; then
        MPTCP_CONFIG_TEXT="${MPTCP_CONFIG_TEXT}
net.mptcp.syn_retries = 5  # SYN重传次数"
        log "  ✓ 支持参数: net.mptcp.syn_retries" "info"
        MPTCP_SUPPORTED_COUNT=$((MPTCP_SUPPORTED_COUNT + 1))
    else
        log "  ✗ 跳过参数: net.mptcp.syn_retries (内核不支持)" "warn"
    fi
    
    # 10. net.mptcp.blackhole_detection
    if check_mptcp_param "net.mptcp.blackhole_detection"; then
        MPTCP_CONFIG_TEXT="${MPTCP_CONFIG_TEXT}
net.mptcp.blackhole_detection = 1  # 黑洞检测"
        log "  ✓ 支持参数: net.mptcp.blackhole_detection" "info"
        MPTCP_SUPPORTED_COUNT=$((MPTCP_SUPPORTED_COUNT + 1))
    else
        log "  ✗ 跳过参数: net.mptcp.blackhole_detection (内核不支持)" "warn"
    fi
    
    log "MPTCP参数检测完成: $MPTCP_SUPPORTED_COUNT/$MPTCP_TOTAL_COUNT 个参数可用" "info"
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

# 配置网络优化参数（稳定版）
configure_network_parameters() {
    log "配置网络优化参数..." "info"
    
    backup_configs
    
    # 清理旧的完整配置块（包括注释和参数）
    log "清理旧的网络优化配置..." "info"
    
    # 移除所有可能的旧配置标记区域
    sed -i '/^# === 网络性能优化配置开始 ===/,/^# === 网络性能优化配置结束 ===/d' "$SYSCTL_CONFIG"
    
    # 也清理可能的其他旧标记
    sed -i '/^# 网络性能优化.*BBR.*fq_codel/d' "$SYSCTL_CONFIG"
    sed -i '/^# Network optimization for VPS/d' "$SYSCTL_CONFIG"
    sed -i '/^# 网络性能优化.*完整参数配置/d' "$SYSCTL_CONFIG"
    sed -i '/^# 网络性能优化.*cake.*高级/d' "$SYSCTL_CONFIG"
    sed -i '/^# 网络性能优化.*智能.*检测/d' "$SYSCTL_CONFIG"
    sed -i '/^# 网络性能优化.*稳定版/d' "$SYSCTL_CONFIG"
    
    # 清理可能重复的MPTCP配置注释
    sed -i '/^# MPTCP.*优化配置/d' "$SYSCTL_CONFIG"
    
    # 清理所有相关参数（确保没有重复）
    local params_to_clean=(
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
        "net.mptcp.pm_type"
        "net.mptcp.stale_loss_cnt"
        "net.mptcp.syn_retries"
        "net.mptcp.add_addr_timeout"
        "net.mptcp.close_timeout"
        "net.mptcp.scheduler"
        "net.mptcp.blackhole_detection"
    )
    
    # 清理参数
    for param in "${params_to_clean[@]}"; do
        sed -i "/^[[:space:]]*${param//./\\.}[[:space:]]*=.*/d" "$SYSCTL_CONFIG" || true
    done
    
    # 配置MPTCP参数
    configure_mptcp_params
    
    # 添加新的配置块
    cat >> "$SYSCTL_CONFIG" << EOF

# === 网络性能优化配置开始 ===
# 网络性能优化模块 v4.6 - 稳定版
# 生成时间: $(date)
# 包含: BBR + fq_codel + TFO + MPTCP稳定优化 + 完整TCP优化
# MPTCP兼容性: $MPTCP_SUPPORTED_COUNT/$MPTCP_TOTAL_COUNT 个参数可用

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
    
    # 应用配置，智能处理错误
    log "应用 sysctl 配置..." "info"
    
    local sysctl_output
    local sysctl_exitcode=0
    
    # 捕获sysctl输出和退出码
    sysctl_output=$(sysctl -p 2>&1) || sysctl_exitcode=$?
    
    if [[ $sysctl_exitcode -eq 0 ]]; then
        log "✓ 所有 sysctl 参数已成功应用" "info"
    else
        # 分析输出，统计成功和失败的参数
        local total_params
        local failed_params
        local success_params
        
        total_params=$(echo "$sysctl_output" | grep -c "=" || echo "0")
        failed_params=$(echo "$sysctl_output" | grep -c "cannot stat" || echo "0")
        success_params=$((total_params - failed_params))
        
        if [[ $failed_params -eq 0 ]]; then
            log "✓ 所有 $total_params 个 sysctl 参数已成功应用" "info"
        else
            log "⚠ sysctl 应用完成: $success_params 个成功, $failed_params 个不支持" "warn"
            
            # 显示不支持的参数
            echo "$sysctl_output" | while read -r line; do
                if [[ "$line" =~ "cannot stat" ]]; then
                    local param
                    param=$(echo "$line" | grep -o "/proc/sys/[^:]*" | sed 's|/proc/sys/||' | sed 's|/|.|g')
                    log "  ✗ 不支持的参数: $param (内核版本限制)" "warn"
                fi
            done
            
            if [[ $success_params -gt 0 ]]; then
                log "✓ 核心网络优化参数已正常应用" "info"
            fi
        fi
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

# 获取MPTCP参数值（安全方式）
get_mptcp_param() {
    local param="$1"
    local param_file="/proc/sys/${param//./\/}"
    
    if [[ -f "$param_file" ]]; then
        sysctl -n "$param" 2>/dev/null || echo "N/A"
    else
        echo "N/A"
    fi
}

# 验证网络优化配置
verify_network_config() {
    log "验证网络优化配置..." "info"
    
    local current_cc
    local current_qdisc
    local current_tfo
    
    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
    current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "未知")
    current_tfo=$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo "0")
    
    log "当前拥塞控制算法: $current_cc" "info"
    log "当前默认队列调度: $current_qdisc" "info"
    log "当前TCP Fast Open: $current_tfo (0=禁用,1=客户端,2=服务端,3=全部)" "info"
    
    # 检查MPTCP状态
    if [[ -f "/proc/sys/net/mptcp/enabled" ]]; then
        local current_mptcp
        current_mptcp=$(get_mptcp_param "net.mptcp.enabled")
        log "当前MPTCP状态: $current_mptcp (0=禁用,1=启用)" "info"
        
        if [[ "$current_mptcp" == "1" ]]; then
            # 验证MPTCP详细参数
            local mptcp_pm_type
            local mptcp_stale_loss
            local mptcp_scheduler
            
            mptcp_pm_type=$(get_mptcp_param "net.mptcp.pm_type")
            mptcp_stale_loss=$(get_mptcp_param "net.mptcp.stale_loss_cnt")
            mptcp_scheduler=$(get_mptcp_param "net.mptcp.scheduler")
            
            log "  └── 路径管理器类型: $mptcp_pm_type" "info"
            log "  └── 故障检测阈值: $mptcp_stale_loss" "info"
            log "  └── 调度器类型: $mptcp_scheduler" "info"
        fi
    fi
    
    # 判断核心功能是否配置成功
    local core_features_ok=true
    
    if [[ "$current_cc" != "bbr" ]]; then
        log "⚠ BBR未启用: $current_cc" "warn"
        core_features_ok=false
    fi
    
    if [[ "$current_qdisc" != "fq_codel" ]]; then
        log "⚠ fq_codel未启用: $current_qdisc" "warn"
        core_features_ok=false
    fi
    
    if [[ "$current_tfo" != "3" ]]; then
        log "⚠ TCP Fast Open未完全启用: $current_tfo" "warn"
        core_features_ok=false
    fi
    
    if [[ "$core_features_ok" == "true" ]]; then
        log "✓ BBR + fq_codel + TFO + MPTCP 核心功能配置成功" "info"
        return 0
    else
        log "⚠ 部分网络优化功能未完全生效" "warn"
        log "建议重启系统以完全应用配置" "warn"
        return 1
    fi
}

# 显示当前网络状态
show_current_network_status() {
    log "当前网络状态:" "info"
    
    local current_cc
    local current_qdisc  
    local current_tfo
    
    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
    current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "未知")
    current_tfo=$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo "0")
    
    log "  拥塞控制算法: $current_cc" "info"
    log "  队列调度算法: $current_qdisc" "info"
    log "  TCP Fast Open: $current_tfo" "info"
    
    # 显示MPTCP状态
    if [[ -f "/proc/sys/net/mptcp/enabled" ]]; then
        local current_mptcp
        current_mptcp=$(get_mptcp_param "net.mptcp.enabled")
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
    log "  MPTCP稳定优化: 多路径TCP，专为代理转发场景优化" "info"
    log "  智能参数检测: 自动适配内核版本，跳过不支持的参数" "info"
    log "  完整参数: 包含系统资源限制和全面的TCP优化" "info"
    
    echo
    read -p "是否启用网络性能优化 (BBR+fq_codel+TFO+MPTCP稳定优化+完整参数)? [Y/n] (默认: Y): " -r optimize_choice
    
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
    local current_cc
    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
    if [[ "$current_cc" == "bbr" ]]; then
        log "  ✓ 拥塞控制: BBR" "info"
    else
        log "  ✗ 拥塞控制: $current_cc" "info"
    fi
    
    # 队列调度状态
    local current_qdisc
    current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "未知")
    if [[ "$current_qdisc" == "fq_codel" ]]; then
        log "  ✓ 队列调度: fq_codel" "info"
    else
        log "  ✗ 队列调度: $current_qdisc" "info"
    fi
    
    # TFO状态
    local current_tfo
    current_tfo=$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo "0")
    if [[ "$current_tfo" == "3" ]]; then
        log "  ✓ TCP Fast Open: 启用 (客户端+服务端)" "info"
    else
        log "  ✗ TCP Fast Open: $current_tfo (0=禁用,1=客户端,2=服务端,3=全部)" "info"
    fi
    
    # MPTCP详细状态
    if [[ -f "/proc/sys/net/mptcp/enabled" ]]; then
        local current_mptcp
        current_mptcp=$(get_mptcp_param "net.mptcp.enabled")
        if [[ "$current_mptcp" == "1" ]]; then
            # 显示兼容性信息
            local compat_info=""
            if [[ $MPTCP_SUPPORTED_COUNT -gt 0 ]]; then
                compat_info=" (${MPTCP_SUPPORTED_COUNT}/${MPTCP_TOTAL_COUNT} 参数可用)"
            fi
            
            log "  ✓ MPTCP: 启用 (多路径TCP)${compat_info}" "info"
            
            # 显示MPTCP详细配置（只显示支持的参数）
            local mptcp_checksum
            local mptcp_join
            local mptcp_pm_type
            local mptcp_stale_loss
            local mptcp_syn_retries
            local mptcp_add_timeout
            local mptcp_close_timeout
            local mptcp_scheduler
            local mptcp_blackhole
            
            mptcp_checksum=$(get_mptcp_param "net.mptcp.checksum_enabled")
            mptcp_join=$(get_mptcp_param "net.mptcp.allow_join_initial_addr_port")
            mptcp_pm_type=$(get_mptcp_param "net.mptcp.pm_type")
            mptcp_stale_loss=$(get_mptcp_param "net.mptcp.stale_loss_cnt")
            mptcp_syn_retries=$(get_mptcp_param "net.mptcp.syn_retries")
            mptcp_add_timeout=$(get_mptcp_param "net.mptcp.add_addr_timeout")
            mptcp_close_timeout=$(get_mptcp_param "net.mptcp.close_timeout")
            mptcp_scheduler=$(get_mptcp_param "net.mptcp.scheduler")
            mptcp_blackhole=$(get_mptcp_param "net.mptcp.blackhole_detection")
            
            [[ "$mptcp_checksum" != "N/A" ]] && log "    ├── 校验和启用: $mptcp_checksum (代理推荐:0)" "info"
            [[ "$mptcp_join" != "N/A" ]] && log "    ├── 允许初始地址连接: $mptcp_join" "info"
            [[ "$mptcp_pm_type" != "N/A" ]] && log "    ├── 路径管理器类型: $mptcp_pm_type (0=内核)" "info"
            [[ "$mptcp_stale_loss" != "N/A" ]] && log "    ├── 故障检测阈值: $mptcp_stale_loss (推荐:4)" "info"
            [[ "$mptcp_syn_retries" != "N/A" ]] && log "    ├── SYN重传次数: $mptcp_syn_retries (推荐:5)" "info"
            [[ "$mptcp_add_timeout" != "N/A" ]] && log "    ├── ADD_ADDR超时: ${mptcp_add_timeout}ms (推荐:60000)" "info"
            [[ "$mptcp_close_timeout" != "N/A" ]] && log "    ├── 关闭超时: ${mptcp_close_timeout}ms (推荐:30000)" "info"
            [[ "$mptcp_scheduler" != "N/A" ]] && log "    ├── 调度器类型: $mptcp_scheduler (推荐:default)" "info"
            [[ "$mptcp_blackhole" != "N/A" ]] && log "    └── 黑洞检测: $mptcp_blackhole (推荐:1)" "info"
            
            # 如果有不支持的参数，显示提示
            if [[ $MPTCP_SUPPORTED_COUNT -lt $MPTCP_TOTAL_COUNT ]]; then
                local missing_count
                missing_count=$((MPTCP_TOTAL_COUNT - MPTCP_SUPPORTED_COUNT))
                log "    └── ⚠ $missing_count 个高级参数不被当前内核支持 (不影响基本功能)" "warn"
            fi
        else
            log "  ✗ MPTCP: $current_mptcp (0=禁用,1=启用)" "info"
        fi
    else
        log "  ⚠ MPTCP: 系统不支持" "warn"
    fi
    
    # 系统资源限制状态
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
    log "🚀 配置网络性能优化 (稳定版本)..." "info"
    
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
    log "  查看MPTCP统计: cat /proc/net/mptcp_net/stats 2>/dev/null || echo '统计不可用'" "info"
    log "  查看网卡队列: tc qdisc show" "info"
    log "  恢复 sysctl: cp /etc/sysctl.conf.backup /etc/sysctl.conf && sysctl -p" "info"
    log "  恢复 limits: cp /etc/security/limits.conf.backup /etc/security/limits.conf" "info"
    
    # 如果有MPTCP参数不支持，给出建议
    if [[ $MPTCP_SUPPORTED_COUNT -lt $MPTCP_TOTAL_COUNT ]]; then
        echo
        log "💡 内核兼容性提示:" "info"
        log "  当前内核版本: $(uname -r)" "info"
        log "  MPTCP参数支持: ${MPTCP_SUPPORTED_COUNT}/${MPTCP_TOTAL_COUNT}" "info"
        log "  建议: 升级到 Linux 5.10+ 以获得完整MPTCP功能支持" "info"
        log "  现有配置已足够支持 ss2022+realm 的代理场景" "info"
    fi
}

main "$@"
