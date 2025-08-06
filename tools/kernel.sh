#!/bin/bash

# Linux 网络和内核优化脚本
# 整合智能框架与全面参数配置
# 支持自动网卡检测和备份恢复功能
# v1.1 - 新增TCP Fast Open支持
# 作者: LucaLin233
# 仓库: https://github.com/LucaLin233/Linux

SYSCTL_FILE="/etc/sysctl.conf"
INITIAL_BACKUP_FILE="/etc/sysctl.conf.initial_backup"
LIMITS_BACKUP_FILE="/etc/security/limits.conf.initial_backup"

# 确保脚本以 root 权限运行
[ "$(id -u)" != "0" ] && { echo "❌ 错误: 此脚本必须以 root 权限运行"; exit 1; }

# 自动检测主网卡
NET_IF=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++){if($i=="dev"){print $(i+1);exit}}}')
if [ -z "$NET_IF" ]; then
    echo "❌ 未能检测到网卡接口，请手动设置 NET_IF 变量"
    exit 1
else
    echo "✅ 检测到网卡接口: $NET_IF"
fi

# 恢复功能
if [ -n "$1" ] && [ "$1" == "restore" ]; then
    echo "🔄 正在尝试恢复原始配置..."
    
    # 恢复 sysctl 配置
    if [ -f "$INITIAL_BACKUP_FILE" ]; then
        sudo cp "$INITIAL_BACKUP_FILE" "$SYSCTL_FILE"
        echo "✅ sysctl 配置已从 $INITIAL_BACKUP_FILE 恢复"
    else
        echo "❌ 未找到 sysctl 备份文件"
    fi
    
    # 恢复 limits 配置
    if [ -f "$LIMITS_BACKUP_FILE" ]; then
        sudo cp "$LIMITS_BACKUP_FILE" "/etc/security/limits.conf"
        echo "✅ limits 配置已恢复"
    else
        echo "❌ 未找到 limits 备份文件"
    fi
    
    # 重置网卡队列调度器
    if which tc >/dev/null 2>&1 && [ -n "$NET_IF" ]; then
        sudo tc qdisc del dev $NET_IF root 2>/dev/null
        echo "✅ 网卡队列调度器已重置"
    fi
    
    echo "🔄 正在应用恢复的配置..."
    if sudo sysctl -p 2>/dev/null; then
        echo "✅ 配置恢复成功！"
    else
        echo "⚠️  配置可能未完全应用，请检查系统日志"
    fi
    exit 0
fi

echo "🚀 开始网络和内核优化..."

# 创建备份文件
if [ ! -f "$INITIAL_BACKUP_FILE" ]; then
    echo "🔎 正在创建 sysctl 配置备份..."
    if sudo cp "$SYSCTL_FILE" "$INITIAL_BACKUP_FILE" 2>/dev/null; then
        echo "✅ sysctl 配置已备份至: $INITIAL_BACKUP_FILE"
    else
        echo "❌ 创建 sysctl 备份文件失败"
        exit 1
    fi
else
    echo "✅ sysctl 配置备份已存在"
fi

if [ ! -f "$LIMITS_BACKUP_FILE" ]; then
    echo "🔎 正在创建 limits 配置备份..."
    if sudo cp "/etc/security/limits.conf" "$LIMITS_BACKUP_FILE" 2>/dev/null; then
        echo "✅ limits 配置已备份至: $LIMITS_BACKUP_FILE"
    else
        echo "❌ 创建 limits 备份文件失败"
    fi
else
    echo "✅ limits 配置备份已存在"
fi

# 网络和系统参数配置
declare -A PARAMS=(
    [fs.file-max]="1048576"
    [fs.inotify.max_user_instances]="8192"
    [net.core.somaxconn]="32768"
    [net.core.netdev_max_backlog]="32768"
    [net.core.rmem_max]="33554432"
    [net.core.wmem_max]="33554432"
    [net.ipv4.udp_rmem_min]="16384"
    [net.ipv4.udp_wmem_min]="16384"
    [net.ipv4.tcp_rmem]="4096 87380 33554432"
    [net.ipv4.tcp_wmem]="4096 16384 33554432"
    [net.ipv4.tcp_mem]="786432 1048576 26777216"
    [net.ipv4.udp_mem]="65536 131072 262144"
    [net.ipv4.tcp_syncookies]="1"
    [net.ipv4.tcp_fin_timeout]="30"
    [net.ipv4.tcp_tw_reuse]="1"
    [net.ipv4.ip_local_port_range]="1024 65000"
    [net.ipv4.tcp_max_syn_backlog]="16384"
    [net.ipv4.tcp_max_tw_buckets]="6000"
    [net.ipv4.route.gc_timeout]="100"
    [net.ipv4.tcp_syn_retries]="1"
    [net.ipv4.tcp_synack_retries]="1"
    [net.ipv4.tcp_timestamps]="0"
    [net.ipv4.tcp_max_orphans]="131072"
    [net.ipv4.tcp_no_metrics_save]="1"
    [net.ipv4.tcp_ecn]="0"
    [net.ipv4.tcp_frto]="0"
    [net.ipv4.tcp_mtu_probing]="0"
    [net.ipv4.tcp_rfc1337]="0"
    [net.ipv4.tcp_sack]="1"
    [net.ipv4.tcp_fack]="1"
    [net.ipv4.tcp_window_scaling]="1"
    [net.ipv4.tcp_adv_win_scale]="1"
    [net.ipv4.tcp_moderate_rcvbuf]="1"
    [net.ipv4.tcp_keepalive_time]="600"
    [net.ipv4.tcp_notsent_lowat]="16384"
    [net.ipv4.conf.all.route_localnet]="1"
    [net.ipv4.ip_forward]="1"
    [net.ipv4.conf.all.forwarding]="1"
    [net.ipv4.conf.default.forwarding]="1"
    [net.core.default_qdisc]="fq_codel"
    [net.ipv4.tcp_congestion_control]="bbr"
    [net.ipv4.tcp_fastopen]="3"
)

# 配置系统资源限制
echo "🔧 正在配置系统资源限制..."

# 处理 nproc 配置文件重命名
[ -e /etc/security/limits.d/*nproc.conf ] && rename nproc.conf nproc.conf_bk /etc/security/limits.d/*nproc.conf 2>/dev/null

# 配置 PAM 限制
[ -f /etc/pam.d/common-session ] && [ -z "$(grep 'session required pam_limits.so' /etc/pam.d/common-session)" ] && echo "session required pam_limits.so" >> /etc/pam.d/common-session

# 使用优化值更新 limits.conf
sed -i '/^# End of file/,$d' /etc/security/limits.conf
cat >> /etc/security/limits.conf <<EOF
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

echo "✅ 系统资源限制配置完成"

# 处理 sysctl 参数
TEMP_FILE=$(mktemp)
if [ ! -f "$SYSCTL_FILE" ]; then
    touch "$TEMP_FILE"
else
    cp "$SYSCTL_FILE" "$TEMP_FILE"
fi

echo "🔍 正在检查和更新网络参数..."

# 检查 BBR 拥塞控制可用性
modprobe tcp_bbr &>/dev/null
if ! grep -wq bbr /proc/sys/net/ipv4/tcp_available_congestion_control; then
    echo "⚠️  BBR 拥塞控制不可用，将使用默认算法"
    unset PARAMS[net.ipv4.tcp_congestion_control]
    unset PARAMS[net.core.default_qdisc]
fi

# 验证参数支持性
declare -A SUPPORTED_PARAMS
for param in "${!PARAMS[@]}"; do
    if sysctl -n "$param" >/dev/null 2>&1 || [ -f "/proc/sys/$(echo "$param" | tr '.' '/')" ]; then
        SUPPORTED_PARAMS["$param"]="${PARAMS[$param]}"
        echo "✅ 支持的参数: $param"
    else
        echo "⚠️  不支持的参数，跳过: $param"
    fi
done

# 使用智能替换方法应用参数
for param in "${!SUPPORTED_PARAMS[@]}"; do
    value="${SUPPORTED_PARAMS[$param]}"
    escaped_param=$(echo "$param" | sed 's/[][\\.*^$()+?{|]/\\&/g')
    
    # 删除现有参数条目以避免冲突
    sed -i "/^[[:space:]]*${escaped_param}[[:space:]]*=/d" "$TEMP_FILE"
    
    # 添加新参数值
    echo "${param} = ${value}" >> "$TEMP_FILE"
    echo "🔄 已应用: $param = $value"
done

# 添加优化标记
if ! grep -q "# 网络优化配置 - 由 LucaLin233/Linux 生成" "$TEMP_FILE"; then
    {
        echo ""
        echo "# 网络优化配置 - 由 LucaLin233/Linux 生成"
        echo "# v1.1 - 包含TCP Fast Open支持"
        echo "# 生成时间: $(date)"
        echo "# 项目地址: https://github.com/LucaLin233/Linux"
    } >> "$TEMP_FILE"
fi

sudo mv "$TEMP_FILE" "$SYSCTL_FILE"

echo "📝 配置文件更新成功"
echo "🔄 正在应用新配置..."
if sudo sysctl -p 2>/dev/null; then
    echo "✅ 网络优化配置应用成功"
else
    echo "⚠️  部分配置可能未应用，但已写入配置文件"
fi

echo ""
echo "📊 当前生效的优化参数:"
for param in "${!SUPPORTED_PARAMS[@]}"; do
    current_value=$(sysctl -n "$param" 2>/dev/null || echo "N/A")
    echo "   $param = $current_value"
done

# 配置网卡队列调度器
echo ""
echo "🔧 正在配置网卡队列调度器..."
if ! which tc >/dev/null 2>&1; then
    echo "⚠️  未找到 tc 命令，跳过队列调度器配置"
    echo "   请手动安装 iproute2 软件包"
else
    if tc qdisc show dev $NET_IF 2>/dev/null | grep -q "fq_codel"; then
        echo "✅ $NET_IF 已在使用 fq_codel 队列调度器"
    else
        if sudo tc qdisc replace dev $NET_IF root fq_codel 2>/dev/null; then
            echo "🚀 $NET_IF 队列调度器已切换至 fq_codel"
        else
            echo "⚠️  切换至 fq_codel 队列调度器失败"
            echo "   内核可能不支持 fq_codel，检查内核版本: uname -r"
        fi
    fi
fi

# 验证关键优化功能状态
echo ""
echo "🔍 验证关键优化功能:"

# 验证 BBR 拥塞控制状态
current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
if [ "$current_cc" = "bbr" ]; then
    echo "✅ BBR 拥塞控制算法已启用"
else
    echo "⚠️  BBR 拥塞控制可能未启用，当前算法: $current_cc"
    echo "   检查内核 BBR 支持: lsmod | grep bbr"
    echo "   或重启系统使更改生效"
fi

# 验证 TCP Fast Open 状态
current_tfo=$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null)
case "$current_tfo" in
    "0") echo "❌ TCP Fast Open: 禁用" ;;
    "1") echo "🔵 TCP Fast Open: 仅客户端启用" ;;
    "2") echo "🔵 TCP Fast Open: 仅服务端启用" ;;
    "3") echo "✅ TCP Fast Open: 客户端+服务端均启用" ;;
    *) echo "⚠️  TCP Fast Open 状态未知: $current_tfo" ;;
esac

# 验证队列调度器
current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
if [ "$current_qdisc" = "fq_codel" ]; then
    echo "✅ 默认队列调度器: fq_codel"
else
    echo "⚠️  默认队列调度器: $current_qdisc"
fi

echo ""
echo "🎉 网络和内核优化完成！"
echo ""
echo "📋 使用说明:"
echo "   恢复原始配置:"
echo "   curl -fsSL https://raw.githubusercontent.com/LucaLin233/Linux/refs/heads/main/tools/kernel.sh | bash -s restore"
echo ""
echo "🔧 验证命令:"
echo "   查看拥塞控制: sysctl net.ipv4.tcp_congestion_control"
echo "   查看TCP Fast Open: sysctl net.ipv4.tcp_fastopen"
echo "   查看队列调度: sysctl net.core.default_qdisc"
echo "   查看网卡队列: tc qdisc show dev $NET_IF"
echo ""
echo "🔄 建议: 重启系统以确保所有配置生效"
echo "📖 更多信息请访问: https://github.com/LucaLin233/Linux"
