#!/bin/bash
# Linux Network Optimizer v2.0 - 独立网络调优脚本
# 项目: https://github.com/LucaLin233/Linux
# 下载: https://raw.githubusercontent.com/LucaLin233/Linux/refs/heads/main/tools/kernel.sh
#
# 使用方法:
#   curl -fsSL https://raw.githubusercontent.com/LucaLin233/Linux/refs/heads/main/tools/kernel.sh | bash
#   bash kernel.sh [install|restore|status]

set -euo pipefail

readonly SCRIPT_VERSION="2.0"
readonly SYSCTL_CONFIG="/etc/sysctl.conf"
readonly LIMITS_CONFIG="/etc/security/limits.conf"
readonly INITIAL_BACKUP=".initial_backup"
readonly LATEST_BACKUP=".backup"

# === 简化日志系统 ===
info() { echo "✅ $1"; }
warn() { echo "⚠️  $1"; }
error() { echo "❌ $1"; }
success() { echo "🎉 $1"; }

banner() {
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║              Linux Network Optimizer v$SCRIPT_VERSION                ║"
    echo "║          BBR + fq_codel + TCP Fast Open + MPTCP             ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
}

# === 网络优化参数 (统一管理) ===
declare -A NET_PARAMS=(
    # 文件系统
    ["fs.file-max"]="1048576"
    ["fs.inotify.max_user_instances"]="8192"
    
    # 网络核心
    ["net.core.somaxconn"]="65535"
    ["net.core.netdev_max_backlog"]="30000"
    ["net.core.rmem_max"]="67108864"
    ["net.core.wmem_max"]="67108864"
    ["net.core.default_qdisc"]="fq_codel"
    
    # TCP 缓冲区
    ["net.ipv4.tcp_rmem"]="4096 87380 67108864"
    ["net.ipv4.tcp_wmem"]="4096 16384 67108864"
    ["net.ipv4.tcp_mem"]="786432 1048576 26777216"
    
    # TCP 连接优化
    ["net.ipv4.tcp_fin_timeout"]="15"
    ["net.ipv4.tcp_keepalive_time"]="600"
    ["net.ipv4.tcp_max_syn_backlog"]="65536"
    ["net.ipv4.tcp_max_tw_buckets"]="1440000"
    ["net.ipv4.tcp_max_orphans"]="262144"
    ["net.ipv4.tcp_syncookies"]="1"
    ["net.ipv4.tcp_tw_reuse"]="1"
    ["net.ipv4.tcp_timestamps"]="1"
    ["net.ipv4.tcp_sack"]="1"
    ["net.ipv4.tcp_window_scaling"]="1"
    ["net.ipv4.tcp_moderate_rcvbuf"]="1"
    ["net.ipv4.tcp_fastopen"]="3"
    ["net.ipv4.tcp_slow_start_after_idle"]="0"
    ["net.ipv4.tcp_notsent_lowat"]="16384"
    
    # UDP 优化
    ["net.ipv4.udp_rmem_min"]="8192"
    ["net.ipv4.udp_wmem_min"]="8192"
    ["net.ipv4.udp_mem"]="102400 873800 16777216"
    
    # 路由和端口
    ["net.ipv4.ip_local_port_range"]="1024 65535"
    ["net.ipv4.ip_forward"]="1"
    ["net.ipv4.conf.all.forwarding"]="1"
    ["net.ipv4.conf.all.route_localnet"]="1"
    
    # 拥塞控制 (动态设置)
    ["net.ipv4.tcp_congestion_control"]="bbr"
)

# MPTCP 参数 (单独处理)
declare -A MPTCP_PARAMS=(
    ["net.mptcp.enabled"]="1"
    ["net.mptcp.checksum_enabled"]="0"
    ["net.mptcp.allow_join_initial_addr_port"]="1"
    ["net.mptcp.pm_type"]="0"
    ["net.mptcp.stale_loss_cnt"]="4"
    ["net.mptcp.add_addr_timeout"]="120000"
    ["net.mptcp.close_timeout"]="30000"
    ["net.mptcp.scheduler"]="default"
)

# === 检测函数 ===
check_root() {
    [[ $EUID -eq 0 ]] || { error "需要 root 权限运行"; exit 1; }
}

detect_os() {
    [[ -f /etc/os-release ]] && source /etc/os-release && echo "${ID:-unknown}" || echo "unknown"
}

detect_interface() {
    ip route get 8.8.8.8 2>/dev/null | grep -oP 'dev \K\S+' | head -1 || \
    ip route show default 2>/dev/null | grep -oP 'dev \K\S+' | head -1 || \
    ls /sys/class/net/ | grep -v lo | head -1
}

check_kernel_version() {
    local version=$(uname -r | cut -d. -f1-2)
    local major=${version%.*} minor=${version#*.}
    [[ $major -gt 4 ]] || [[ $major -eq 4 && $minor -ge 9 ]]
}

# === BBR 支持和修复 ===
try_enable_bbr() {
    info "检查 BBR 拥塞控制支持..."
    
    # 尝试加载模块
    modprobe tcp_bbr 2>/dev/null || true
    
    # 检查是否可用
    if grep -wq bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        info "BBR 拥塞控制: 可用"
        return 0
    fi
    
    # 尝试安装模块包
    info "尝试安装 BBR 模块..."
    case $(detect_os) in
        ubuntu|debian)
            apt update >/dev/null 2>&1 && apt install -y linux-modules-extra-$(uname -r) >/dev/null 2>&1 || true
            ;;
        centos|rhel|rocky|alma)
            yum install -y kernel-modules-extra >/dev/null 2>&1 || true
            ;;
    esac
    
    # 再次尝试加载
    modprobe tcp_bbr 2>/dev/null || true
    
    if grep -wq bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        info "BBR 模块安装成功"
        return 0
    else
        warn "BBR 不可用，将使用 cubic 算法继续优化"
        NET_PARAMS["net.ipv4.tcp_congestion_control"]="cubic"
        return 1
    fi
}

# === MPTCP 支持检测 ===
check_mptcp_support() {
    if [[ ! -f /proc/sys/net/mptcp/enabled ]]; then
        warn "系统不支持 MPTCP"
        return 1
    fi
    
    info "检测 MPTCP 参数支持..."
    local supported=0 total=${#MPTCP_PARAMS[@]}
    
    for param in "${!MPTCP_PARAMS[@]}"; do
        if sysctl -n "$param" >/dev/null 2>&1; then
            NET_PARAMS["$param"]="${MPTCP_PARAMS[$param]}"
            ((supported++))
            info "  ✅ $param"
        else
            warn "  ❌ $param (不支持)"
        fi
    done
    
    info "MPTCP 检测结果: $supported/$total 参数支持"
    return 0
}

# === 备份管理 ===
create_backup() {
    local file="$1"
    
    if [[ -f "$file" ]]; then
        # 创建初始备份 (只创建一次)
        [[ ! -f "${file}${INITIAL_BACKUP}" ]] && cp "$file" "${file}${INITIAL_BACKUP}"
        
        # 创建最新备份 (每次覆盖)
        cp "$file" "${file}${LATEST_BACKUP}"
        
        info "已备份配置文件: $(basename "$file")"
    else
        warn "文件不存在: $file"
    fi
}

restore_backup() {
    local file="$1" backup_file="${file}${INITIAL_BACKUP}"
    
    if [[ -f "$backup_file" ]]; then
        cp "$backup_file" "$file"
        info "已恢复配置: $(basename "$file")"
    else
        error "未找到备份文件: $(basename "$backup_file")"
        return 1
    fi
}

# === 系统资源限制 ===
configure_limits() {
    info "配置系统资源限制..."
    
    create_backup "$LIMITS_CONFIG"
    
    # 禁用冲突配置
    for file in /etc/security/limits.d/*nproc.conf; do
        [[ -f "$file" ]] && mv "$file" "${file}.disabled" 2>/dev/null || true
    done
    
    # 配置 PAM limits
    [[ -f /etc/pam.d/common-session ]] && ! grep -q "pam_limits.so" /etc/pam.d/common-session && \
        echo "session required pam_limits.so" >> /etc/pam.d/common-session
    
    # 更新 limits.conf
    sed -i '/^# Network Optimizer/,$d' "$LIMITS_CONFIG"
    
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
    
    success "系统资源限制配置完成"
}

# === 网络参数应用 ===
apply_network_params() {
    info "应用网络优化参数..."
    
    create_backup "$SYSCTL_CONFIG"
    
    # 检测参数支持
    declare -A supported_params
    local supported=0 total=${#NET_PARAMS[@]}
    
    for param in "${!NET_PARAMS[@]}"; do
        if sysctl -n "$param" >/dev/null 2>&1; then
            supported_params["$param"]="${NET_PARAMS[$param]}"
            ((supported++))
        fi
    done
    
    # 生成配置文件
    local temp_config=$(mktemp)
    grep -v "^# Network Optimizer" "$SYSCTL_CONFIG" | \
    grep -v "^# === 网络性能优化" > "$temp_config" || true
    
    cat >> "$temp_config" << EOF

# Network Optimizer v${SCRIPT_VERSION} - 网络性能优化
# 生成时间: $(date "+%Y-%m-%d %H:%M:%S")
# 支持参数: $supported/$total

EOF
    
    # 写入参数
    for param in $(printf '%s\n' "${!supported_params[@]}" | sort); do
        echo "${param} = ${supported_params[$param]}" >> "$temp_config"
    done
    
    echo "# Network Optimizer 配置结束" >> "$temp_config"
    
    # 应用配置
    mv "$temp_config" "$SYSCTL_CONFIG"
    
    if sysctl -p >/dev/null 2>&1; then
        success "网络参数应用成功: $supported/$total"
    else
        warn "部分参数可能未生效"
    fi
}

# === 网卡队列优化 ===
optimize_interface() {
    local interface="$1"
    
    info "优化网卡队列调度: $interface"
    
    if ! command -v tc >/dev/null 2>&1; then
        warn "tc 命令不可用，跳过网卡队列优化"
        return 1
    fi
    
    local current_qdisc
    current_qdisc=$(tc qdisc show dev "$interface" 2>/dev/null | head -1 | awk '{print $2}' || echo "unknown")
    
    if [[ "$current_qdisc" == "fq_codel" ]]; then
        info "网卡 $interface 已使用 fq_codel"
    else
        if tc qdisc replace dev "$interface" root fq_codel 2>/dev/null; then
            success "网卡 $interface 已设置为 fq_codel"
        else
            warn "设置网卡队列调度器失败"
        fi
    fi
}

# === 状态验证 ===
verify_config() {
    info "验证网络优化配置..."
    
    local issues=0
    
    # BBR检查
    local cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    [[ "$cc" == "bbr" ]] && info "✅ BBR: 已启用" || { warn "❌ BBR: $cc"; ((issues++)); }
    
    # fq_codel检查  
    local qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "unknown")
    [[ "$qdisc" == "fq_codel" ]] && info "✅ fq_codel: 已启用" || { warn "❌ fq_codel: $qdisc"; ((issues++)); }
    
    # TCP Fast Open检查
    local tfo=$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo "0")
    [[ "$tfo" == "3" ]] && info "✅ TCP Fast Open: 完全启用" || { warn "❌ TFO: $tfo"; ((issues++)); }
    
    # MPTCP检查
    if [[ -f /proc/sys/net/mptcp/enabled ]]; then
        local mptcp=$(sysctl -n net.mptcp.enabled 2>/dev/null || echo "0")
        [[ "$mptcp" == "1" ]] && info "✅ MPTCP: 已启用" || { warn "❌ MPTCP: 未启用"; ((issues++)); }
    else
        info "◯ MPTCP: 系统不支持"
    fi
    
    # 系统限制检查
    grep -q "1048576" "$LIMITS_CONFIG" 2>/dev/null && \
        info "✅ 系统资源限制: 已优化" || { warn "❌ 系统限制: 未配置"; ((issues++)); }
    
    [[ $issues -eq 0 ]] && success "所有配置验证通过！" || warn "发现 $issues 个问题"
    
    return $issues
}

# === 主要功能 ===
install_optimization() {
    banner
    info "Linux 网络性能优化脚本 v$SCRIPT_VERSION"
    
    # 前置检查
    check_root
    check_kernel_version || { error "内核版本过低 (需要4.9+)"; exit 1; }
    
    local interface
    interface=$(detect_interface) || { error "无法检测网络接口"; exit 1; }
    info "检测到网络接口: $interface"
    
    # 显示优化内容
    echo
    info "将进行网络优化:"
    echo "  • BBR + fq_codel + TCP Fast Open"
    echo "  • MPTCP (如果支持)"
    echo "  • 系统资源限制调整"
    echo "  • 网络缓冲区优化"
    echo
    
    # 用户确认
    if [[ "${AUTO_YES:-0}" != "1" ]]; then
        read -p "确认继续? [Y/n]: " -r
        [[ "$REPLY" =~ ^[Nn] ]] && { info "用户取消"; exit 0; }
    fi
    
    # 执行优化
    echo
    try_enable_bbr
    check_mptcp_support || true
    configure_limits
    apply_network_params
    optimize_interface "$interface"
    
    # 验证结果
    echo
    verify_config
    
    echo
    success "网络优化安装完成！"
    info "使用说明:"
    info "  查看状态: $0 status"
    info "  恢复配置: $0 restore"
    warn "建议重启系统确保配置完全生效"
}

restore_optimization() {
    banner
    info "恢复原始网络配置..."
    
    check_root
    
    local restored=0
    
    # 恢复配置文件
    restore_backup "$SYSCTL_CONFIG" && ((restored++))
    restore_backup "$LIMITS_CONFIG" && ((restored++))
    
    # 重置网卡队列
    local interface
    if interface=$(detect_interface) && command -v tc >/dev/null 2>&1; then
        tc qdisc del dev "$interface" root 2>/dev/null && info "网卡队列已重置" || true
    fi
    
    # 恢复被禁用的文件
    for file in /etc/security/limits.d/*.conf.disabled; do
        [[ -f "$file" ]] && mv "$file" "${file%.disabled}" 2>/dev/null || true
    done
    
    if [[ $restored -gt 0 ]]; then
        sysctl -p >/dev/null 2>&1 || true
        success "配置恢复完成！"
        warn "建议重启系统完全应用恢复的配置"
    else
        error "未找到备份文件"
        exit 1
    fi
}

show_status() {
    banner
    
    echo "系统信息:"
    echo "  操作系统: $(detect_os | tr '[:lower:]' '[:upper:]') $(uname -r)"
    echo "  网络接口: $(detect_interface || echo "检测失败")"
    echo "  架构: $(uname -m)"
    echo
    
    echo "当前网络配置:"
    local params=(
        "net.ipv4.tcp_congestion_control:拥塞控制"
        "net.core.default_qdisc:队列调度器"  
        "net.ipv4.tcp_fastopen:TCP Fast Open"
        "net.mptcp.enabled:MPTCP状态"
        "net.core.rmem_max:接收缓冲区"
        "net.core.wmem_max:发送缓冲区"
    )
    
    for item in "${params[@]}"; do
        IFS=':' read -r param desc <<< "$item"
        local value=$(sysctl -n "$param" 2>/dev/null || echo "N/A")
        printf "  %-15s: %s\n" "$desc" "$value"
    done
    
    echo
    verify_config >/dev/null 2>&1
    [[ $? -eq 0 ]] && success "网络优化状态: 正常" || warn "网络优化状态: 存在问题"
}

show_help() {
    banner
    echo "使用方法: $0 [命令] [选项]"
    echo
    echo "命令:"
    echo "  install    安装网络优化 (默认)"
    echo "  restore    恢复原始配置" 
    echo "  status     查看当前状态"
    echo "  help       显示帮助信息"
    echo
    echo "选项:"
    echo "  -y         自动确认"
    echo
    echo "远程执行:"
    echo "  curl -fsSL https://raw.githubusercontent.com/LucaLin233/Linux/refs/heads/main/tools/kernel.sh | bash"
    echo "  wget -qO- https://raw.githubusercontent.com/LucaLin233/Linux/refs/heads/main/tools/kernel.sh | bash"
}

# === 主程序 ===
main() {
    local command="${1:-install}"
    
    # 解析参数
    while [[ $# -gt 0 ]]; do
        case $1 in
            install|restore|status|help) command="$1" ;;
            -y|--yes) export AUTO_YES=1 ;;
            -h|--help) command="help" ;;
            *) warn "未知参数: $1"; show_help; exit 1 ;;
        esac
        shift
    done
    
    # 执行命令
    case "$command" in
        install) install_optimization ;;
        restore) restore_optimization ;;  
        status) show_status ;;
        help) show_help ;;
        *) error "未知命令: $command"; show_help; exit 1 ;;
    esac
}

# 错误处理
trap 'error "脚本执行中断"; exit 130' INT
trap 'error "执行出错，行号: $LINENO"; exit 1' ERR

# 运行主程序
main "$@"
