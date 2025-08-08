#!/bin/bash
# Linux Network Optimizer v2.0 - 独立网络调优脚本
# 项目: https://github.com/LucaLin233/Linux
# 
# 使用方法:
#   curl -fsSL https://raw.githubusercontent.com/LucaLin233/Linux/refs/heads/main/tools/kernel.sh | bash
#   bash kernel.sh [install|restore|status] [-y]

set -euo pipefail

readonly VERSION="2.0"
readonly SYSCTL_CONFIG="/etc/sysctl.conf"
readonly LIMITS_CONFIG="/etc/security/limits.conf"

# === 简化日志 ===
info() { echo "✅ $1"; }
warn() { echo "⚠️  $1"; }
error() { echo "❌ $1"; exit 1; }
success() { echo "🎉 $1"; }

# === 网络参数统一管理 ===
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
    # TCP缓冲区
    ["net.ipv4.tcp_rmem"]="4096 87380 67108864"
    ["net.ipv4.tcp_wmem"]="4096 16384 67108864"
    ["net.ipv4.tcp_mem"]="786432 1048576 26777216"
    # TCP连接
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
    # UDP
    ["net.ipv4.udp_rmem_min"]="8192"
    ["net.ipv4.udp_wmem_min"]="8192"
    ["net.ipv4.udp_mem"]="102400 873800 16777216"
    # 路由
    ["net.ipv4.ip_local_port_range"]="1024 65535"
    ["net.ipv4.ip_forward"]="1"
    ["net.ipv4.conf.all.forwarding"]="1"
    ["net.ipv4.conf.all.route_localnet"]="1"
    # 拥塞控制
    ["net.ipv4.tcp_congestion_control"]="bbr"
)

# MPTCP参数
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

# === 基础检测 ===
check_root() { [[ $EUID -eq 0 ]] || error "需要 root 权限"; }

detect_interface() {
    ip route get 8.8.8.8 2>/dev/null | grep -oP 'dev \K\S+' | head -1 || \
    ls /sys/class/net/ 2>/dev/null | grep -v lo | head -1
}

check_kernel() {
    local ver=$(uname -r | cut -d. -f1-2)
    local major=${ver%.*} minor=${ver#*.}
    [[ $major -gt 4 ]] || [[ $major -eq 4 && $minor -ge 9 ]] || error "内核版本过低 (需要4.9+)"
}

# === BBR支持 (带自动修复) ===
setup_bbr() {
    info "检查 BBR 支持..."
    modprobe tcp_bbr 2>/dev/null || true
    
    if grep -wq bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        info "BBR: 可用"
        return 0
    fi
    
    # 尝试安装模块
    case $(grep ^ID= /etc/os-release 2>/dev/null) in
        *ubuntu*|*debian*) apt update >/dev/null 2>&1 && apt install -y linux-modules-extra-$(uname -r) >/dev/null 2>&1 || true ;;
        *centos*|*rhel*) yum install -y kernel-modules-extra >/dev/null 2>&1 || true ;;
    esac
    
    modprobe tcp_bbr 2>/dev/null || true
    
    if grep -wq bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        info "BBR: 安装成功"
    else
        warn "BBR 不可用，使用 cubic 算法"
        NET_PARAMS["net.ipv4.tcp_congestion_control"]="cubic"
    fi
}

# === MPTCP检测 ===
check_mptcp() {
    [[ ! -f /proc/sys/net/mptcp/enabled ]] && { warn "MPTCP: 系统不支持"; return; }
    
    info "检测 MPTCP 参数..."
    local supported=0
    
    for param in "${!MPTCP_PARAMS[@]}"; do
        if sysctl -n "$param" >/dev/null 2>&1; then
            NET_PARAMS["$param"]="${MPTCP_PARAMS[$param]}"
            ((supported++)) || true
            info "  ✅ $param"
        else
            warn "  ❌ $param"
        fi
    done
    
    info "MPTCP: $supported/${#MPTCP_PARAMS[@]} 参数支持"
}

# === 备份管理 ===
backup_config() {
    local file="$1"
    [[ -f "$file" ]] || return
    [[ ! -f "${file}.initial_backup" ]] && cp "$file" "${file}.initial_backup"
    cp "$file" "${file}.backup"
    info "备份: $(basename "$file")"
}

restore_config() {
    local file="$1" backup="${file}.initial_backup"
    [[ -f "$backup" ]] && cp "$backup" "$file" && info "恢复: $(basename "$file")" || error "备份不存在: $file"
}

# === 系统资源限制 ===
setup_limits() {
    info "配置系统资源限制..."
    backup_config "$LIMITS_CONFIG"
    
    # 禁用冲突文件
    for file in /etc/security/limits.d/*nproc.conf; do
        [[ -f "$file" ]] && mv "$file" "${file}.disabled" 2>/dev/null || true
    done
    
    # 配置PAM
    [[ -f /etc/pam.d/common-session ]] && ! grep -q "pam_limits.so" /etc/pam.d/common-session && \
        echo "session required pam_limits.so" >> /etc/pam.d/common-session
    
    # 更新limits.conf
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
    success "系统限制配置完成"
}

# === 智能参数清理和应用 ===
apply_params() {
    info "应用网络参数..."
    backup_config "$SYSCTL_CONFIG"
    
    # 检测支持的参数
    declare -A supported_params
    local supported=0
    
    for param in "${!NET_PARAMS[@]}"; do
        if sysctl -n "$param" >/dev/null 2>&1; then
            supported_params["$param"]="${NET_PARAMS[$param]}"
            ((supported++)) || true
        fi
    done
    
    # 彻底清理方案：保留非脚本管理的参数
    local temp_preserve=$(mktemp)
    local temp_config=$(mktemp)
    
    # 1. 提取要保留的参数（非脚本管理的参数）
    while IFS= read -r line; do
        # 跳过注释、空行和脚本标记
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        
        # 检查是否为参数行
        if [[ "$line" =~ ^[[:space:]]*([^[:space:]#=]+)[[:space:]]*= ]]; then
            local param_name="${BASH_REMATCH[1]}"
            
            # 检查是否是我们要管理的参数
            local is_our_param=false
            for our_param in "${!supported_params[@]}"; do
                if [[ "$param_name" == "$our_param" ]]; then
                    is_our_param=true
                    break
                fi
            done
            
            # 如果不是我们管理的参数，保留它
            if [[ "$is_our_param" == "false" ]]; then
                echo "$line" >> "$temp_preserve"
            fi
        fi
    done < "$SYSCTL_CONFIG"
    
    # 2. 重新构建干净的配置文件
    
    # 先写入保留的参数（如果有）
    if [[ -s "$temp_preserve" ]]; then
        echo "# 系统原有配置" > "$temp_config"
        cat "$temp_preserve" >> "$temp_config"
        echo "" >> "$temp_config"
    else
        touch "$temp_config"
    fi
    
    # 写入脚本配置
    cat >> "$temp_config" << EOF
# Network Optimizer v${VERSION} - 网络性能优化
# 生成时间: $(date "+%Y-%m-%d %H:%M:%S")

EOF
    
    # 按类别写入参数（保持整洁）
    write_section() {
        local pattern="$1" title="$2"
        local params=($(printf '%s\n' "${!supported_params[@]}" | grep -E "$pattern" | sort))
        
        if [[ ${#params[@]} -gt 0 ]]; then
            echo "# $title" >> "$temp_config"
            for param in "${params[@]}"; do
                echo "${param} = ${supported_params[$param]}" >> "$temp_config"
            done
            echo "" >> "$temp_config"
        fi
    }
    
    write_section "^fs\." "文件系统"
    write_section "^net\.core\." "网络核心"
    write_section "^net\.ipv4\.tcp" "TCP参数"
    write_section "^net\.ipv4\.udp" "UDP参数"
    write_section "^net\.ipv4\.(ip_forward|conf)" "路由转发"
    write_section "^net\.mptcp\." "MPTCP"
    
    echo "# Network Optimizer 配置结束" >> "$temp_config"
    
    # 3. 应用新配置
    mv "$temp_config" "$SYSCTL_CONFIG"
    rm -f "$temp_preserve"
    
    sysctl -p >/dev/null 2>&1 && success "参数应用成功: $supported/${#NET_PARAMS[@]}" || warn "部分参数未生效"
}

# === 网卡队列优化 ===
setup_qdisc() {
    local interface="$1"
    info "优化网卡队列: $interface"
    
    command -v tc >/dev/null 2>&1 || { warn "tc 命令不可用"; return; }
    
    local current=$(tc qdisc show dev "$interface" 2>/dev/null | head -1 | awk '{print $2}')
    
    if [[ "$current" == "fq_codel" ]]; then
        info "网卡 $interface: 已使用 fq_codel"
    else
        tc qdisc replace dev "$interface" root fq_codel 2>/dev/null && success "网卡 $interface: 已设置 fq_codel" || warn "网卡设置失败"
    fi
}

# === 验证配置 ===
verify_config() {
    info "验证配置..."
    local issues=0
    
    # 检查关键参数
    local checks=(
        "net.ipv4.tcp_congestion_control:BBR/拥塞控制:bbr"
        "net.core.default_qdisc:队列调度器:fq_codel"
        "net.ipv4.tcp_fastopen:TCP Fast Open:3"
        "net.mptcp.enabled:MPTCP:1"
    )
    
    for check in "${checks[@]}"; do
        IFS=':' read -r param name expected <<< "$check"
        local value=$(sysctl -n "$param" 2>/dev/null || echo "N/A")
        
        if [[ "$value" == "$expected" ]]; then
            info "✅ $name: 已启用"
        else
            warn "❌ $name: $value"
            ((issues++)) || true
        fi
    done
    
    grep -q "1048576" "$LIMITS_CONFIG" 2>/dev/null && info "✅ 系统限制: 已优化" || { warn "❌ 系统限制: 未配置"; ((issues++)) || true; }
    
    [[ $issues -eq 0 ]] && success "所有配置验证通过!" || warn "发现 $issues 个问题"
}

# === 用户交互 ===
user_confirm() {
    [[ "${AUTO_YES:-0}" == "1" ]] && return 0
    
    if [[ -t 0 ]]; then
        read -p "$1 [Y/n]: " -r
    elif [[ -r /dev/tty ]]; then
        read -p "$1 [Y/n]: " -r </dev/tty
    else
        warn "非交互环境，请使用 -y 参数"
        return 1
    fi
    
    [[ ! "$REPLY" =~ ^[Nn] ]]
}

# === 主要功能 ===
install_optimization() {
    echo "================================================================"
    echo "              Linux Network Optimizer v$VERSION"
    echo "         BBR + fq_codel + TCP Fast Open + MPTCP"
    echo "================================================================"
    
    check_root
    check_kernel
    
    local interface
    interface=$(detect_interface) || error "无法检测网络接口"
    info "网络接口: $interface"
    
    echo
    info "将进行网络优化:"
    echo "  • BBR + fq_codel + TCP Fast Open"
    echo "  • MPTCP (如果支持)"  
    echo "  • 系统资源限制"
    echo "  • 网络缓冲区优化"
    echo
    
    user_confirm "确认继续?" || { info "用户取消"; exit 0; }
    
    echo
    setup_bbr
    check_mptcp
    setup_limits
    apply_params
    setup_qdisc "$interface"
    
    echo
    verify_config
    
    echo
    success "网络优化完成!"
    
    local script_url="https://raw.githubusercontent.com/LucaLin233/Linux/refs/heads/main/tools/kernel.sh"
    info "后续命令:"
    info "  查看状态: curl -fsSL $script_url | bash -s status"
    info "  恢复配置: curl -fsSL $script_url | bash -s restore"
    info "  重新优化: curl -fsSL $script_url | bash -s install -y"
    warn "建议重启系统确保配置完全生效"
}

restore_optimization() {
    check_root
    info "恢复原始配置..."
    
    restore_config "$SYSCTL_CONFIG"
    restore_config "$LIMITS_CONFIG"
    
    # 重置网卡和恢复文件
    local interface
    interface=$(detect_interface) && command -v tc >/dev/null 2>&1 && tc qdisc del dev "$interface" root 2>/dev/null || true
    
    for file in /etc/security/limits.d/*.conf.disabled; do
        [[ -f "$file" ]] && mv "$file" "${file%.disabled}" 2>/dev/null || true
    done
    
    sysctl -p >/dev/null 2>&1 || true
    success "配置恢复完成!"
}

show_status() {
    echo "系统: $(grep ^PRETTY_NAME= /etc/os-release 2>/dev/null | cut -d'"' -f2 || echo "Unknown") $(uname -r)"
    echo "网卡: $(detect_interface || echo "未知")"
    echo
    
    echo "当前配置:"
    local params=("net.ipv4.tcp_congestion_control:拥塞控制" "net.core.default_qdisc:队列调度器" 
                  "net.ipv4.tcp_fastopen:TCP Fast Open" "net.mptcp.enabled:MPTCP")
    
    for item in "${params[@]}"; do
        IFS=':' read -r param desc <<< "$item"
        printf "  %-15s: %s\n" "$desc" "$(sysctl -n "$param" 2>/dev/null || echo "N/A")"
    done
    
    echo
    verify_config >/dev/null 2>&1 && success "优化状态: 正常" || warn "优化状态: 异常"
}

# === 主程序 ===
main() {
    local cmd="${1:-install}"
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            install|restore|status) cmd="$1" ;;
            -y|--yes) export AUTO_YES=1 ;;
            -h|--help) echo "用法: $0 [install|restore|status] [-y]"; exit 0 ;;
            *) warn "未知参数: $1"; exit 1 ;;
        esac
        shift
    done
    
    case "$cmd" in
        install) install_optimization ;;
        restore) restore_optimization ;;
        status) show_status ;;
        *) error "未知命令: $cmd" ;;
    esac
}

trap 'error "执行中断"' INT ERR
main "$@"
