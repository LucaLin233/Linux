#!/bin/bash
# 系统优化模块 (优化版 v3.0)
# 功能: Zram配置、时区设置、系统参数优化

set -euo pipefail

# === 常量定义 ===
readonly ZRAM_CONFIG="/etc/default/zramswap"
readonly SYSCTL_CONFIG="/etc/sysctl.d/99-debian-optimize.conf"
readonly DEFAULT_TIMEZONE="Asia/Shanghai"

# === 兼容性日志函数 ===
if ! command -v log &> /dev/null; then
    log() {
        local msg="$1" level="${2:-info}"
        local -A colors=([info]="\033[0;36m" [warn]="\033[0;33m" [error]="\033[0;31m")
        echo -e "${colors[$level]:-\033[0;32m}$msg\033[0m"
    }
fi

# === 系统信息获取 ===
get_memory_info() {
    # 返回物理内存大小(MB)
    awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo
}

get_cpu_cores() {
    nproc
}

# === Zram 配置模块 ===
calculate_zram_size() {
    local mem_mb="$1"
    local zram_mb
    
    if (( mem_mb > 4096 )); then      # >4GB: 固定2GB
        echo "2G"
    elif (( mem_mb > 2048 )); then   # 2-4GB: 固定1GB  
        echo "1G"
    elif (( mem_mb > 1024 )); then   # 1-2GB: 内存大小
        echo "${mem_mb}M"
    else                             # <1GB: 2倍内存
        zram_mb=$((mem_mb * 2))
        echo "${zram_mb}M"
    fi
}

setup_zram() {
    local mem_mb zram_size
    
    log "配置 Zram Swap..." "info"
    
    # 检查是否已有交换分区
    if swapon --show | grep -v zram | grep -q .; then
        log "检测到现有交换分区:" "warn"
        swapon --show | grep -v zram
        read -p "继续配置Zram? [Y/n]: " -r continue_zram
        [[ "$continue_zram" =~ ^[Nn]$ ]] && return 0
    fi
    
    # 计算Zram大小
    mem_mb=$(get_memory_info)
    zram_size=$(calculate_zram_size "$mem_mb")
    
    log "内存: ${mem_mb}MB, Zram大小: $zram_size" "info"
    
    # 安装zram-tools
    if ! dpkg -l zram-tools &>/dev/null; then
        log "安装 zram-tools..." "info"
        apt-get update -qq
        apt-get install -y zram-tools
    fi
    
    # 停止现有zram服务
    if systemctl is-active zramswap.service &>/dev/null; then
        log "停止现有 zramswap 服务..." "info"
        systemctl stop zramswap.service
    fi
    
    # 配置zram大小
    if [[ -f "$ZRAM_CONFIG" ]]; then
        # 备份原配置
        cp "$ZRAM_CONFIG" "${ZRAM_CONFIG}.bak"
        
        # 更新配置
        if grep -q "^ZRAM_SIZE=" "$ZRAM_CONFIG"; then
            sed -i "s/^ZRAM_SIZE=.*/ZRAM_SIZE=\"$zram_size\"/" "$ZRAM_CONFIG"
        else
            echo "ZRAM_SIZE=\"$zram_size\"" >> "$ZRAM_CONFIG"
        fi
    else
        # 创建新配置文件
        echo "ZRAM_SIZE=\"$zram_size\"" > "$ZRAM_CONFIG"
    fi
    
    # 启用并启动服务
    systemctl enable zramswap.service
    systemctl start zramswap.service
    
    # 验证配置
    if systemctl is-active zramswap.service &>/dev/null; then
        log "✓ Zram配置成功" "info"
        log "  当前交换状态:" "info"
        swapon --show | sed 's/^/    /'
    else
        log "✗ Zram配置失败" "error"
        return 1
    fi
}

# === 时区配置模块 ===
setup_timezone() {
    local target_tz desired_tz current_tz
    
    log "配置系统时区..." "info"
    
    if ! command -v timedatectl &>/dev/null; then
        log "timedatectl 不可用，跳过时区配置" "warn"
        return 0
    fi
    
    # 获取当前时区
    current_tz=$(timedatectl show --property=Timezone --value)
    
    log "当前时区: $current_tz" "info"
    
    # 询问用户
    cat << 'EOF'

常用时区选择:
1) Asia/Shanghai (中国标准时间)
2) UTC (协调世界时)
3) Asia/Tokyo (日本时间)
4) Europe/London (伦敦时间)
5) America/New_York (纽约时间)
6) 自定义时区
7) 保持当前时区

EOF
    
    read -p "请选择时区 [1-7, 默认1]: " -r tz_choice
    tz_choice=${tz_choice:-1}
    
    case "$tz_choice" in
        1) target_tz="Asia/Shanghai" ;;
        2) target_tz="UTC" ;;
        3) target_tz="Asia/Tokyo" ;;
        4) target_tz="Europe/London" ;;
        5) target_tz="America/New_York" ;;
        6) 
            while true; do
                read -p "请输入时区 (如: Asia/Shanghai): " -r desired_tz
                if timedatectl list-timezones | grep -q "^$desired_tz$"; then
                    target_tz="$desired_tz"
                    break
                else
                    log "无效时区，请重新输入" "error"
                fi
            done
            ;;
        7) 
            log "保持当前时区: $current_tz" "info"
            return 0
            ;;
        *) 
            log "无效选择，使用默认时区: $DEFAULT_TIMEZONE" "warn"
            target_tz="$DEFAULT_TIMEZONE"
            ;;
    esac
    
    # 设置时区
    if [[ "$current_tz" != "$target_tz" ]]; then
        timedatectl set-timezone "$target_tz"
        log "✓ 时区已设置为: $target_tz" "info"
        log "  当前时间: $(date)" "info"
    else
        log "时区无需更改" "info"
    fi
}

# === 系统参数优化模块 ===
setup_sysctl_optimization() {
    log "配置系统参数优化..." "info"
    
    read -p "是否应用系统参数优化? (网络、内存等) [Y/n]: " -r apply_sysctl
    [[ "$apply_sysctl" =~ ^[Nn]$ ]] && return 0
    
    # 创建优化配置
    cat > "$SYSCTL_CONFIG" << 'EOF'
# Debian 系统优化参数
# 生成时间: $(date)

# 网络优化
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# 内存管理优化
vm.swappiness = 10
vm.vfs_cache_pressure = 50
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5

# 文件系统优化
fs.file-max = 2097152
fs.inotify.max_user_watches = 524288

EOF
    
    # 应用配置
    if sysctl -p "$SYSCTL_CONFIG" &>/dev/null; then
        log "✓ 系统参数优化已应用" "info"
        log "  配置文件: $SYSCTL_CONFIG" "info"
    else
        log "✗ 系统参数优化应用失败" "error"
        return 1
    fi
}

# === 显示优化摘要 ===
show_optimization_summary() {
    echo
    log "🎯 系统优化摘要:" "info"
    
    # Zram状态
    if systemctl is-active zramswap.service &>/dev/null; then
        local zram_info
        zram_info=$(swapon --show | grep zram | awk '{print $3}')
        log "  ✓ Zram: ${zram_info:-已启用}" "info"
    else
        log "  ✗ Zram: 未配置" "info"
    fi
    
    # 时区状态
    local current_tz
    current_tz=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "未知")
    log "  ✓ 时区: $current_tz" "info"
    
    # 系统参数
    if [[ -f "$SYSCTL_CONFIG" ]]; then
        log "  ✓ 系统参数: 已优化" "info"
    else
        log "  - 系统参数: 未配置" "info"
    fi
    
    # 内存使用情况
    local mem_usage
    mem_usage=$(free -h | awk '/^Mem:/ {printf "使用:%s/%s", $3, $2}')
    log "  📊 内存: $mem_usage" "info"
}

# === 主执行流程 ===
main() {
    log "🔧 开始系统优化配置..." "info"
    
    # 显示系统信息
    local mem_mb cores
    mem_mb=$(get_memory_info)
    cores=$(get_cpu_cores)
    
    echo
    log "系统信息:" "info"
    log "  内存: ${mem_mb}MB" "info" 
    log "  CPU核心: $cores" "info"
    log "  内核: $(uname -r)" "info"
    
    echo
    
    # 执行优化模块
    setup_zram
    echo
    setup_timezone  
    echo
    setup_sysctl_optimization
    
    # 显示摘要
    show_optimization_summary
    
    log "🎉 系统优化配置完成!" "info"
}

# 执行主流程
main "$@"
