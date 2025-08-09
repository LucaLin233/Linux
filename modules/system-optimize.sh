#!/bin/bash
# 系统优化模块 v5.0 - 智能Zram版
# 功能: 智能Zram配置、时区设置、时间同步

set -euo pipefail

# === 常量定义 ===
readonly ZRAM_CONFIG="/etc/default/zramswap"
readonly DEFAULT_TIMEZONE="Asia/Shanghai"

# === 日志函数 ===
log() {
    local msg="$1" level="${2:-info}"
    local -A colors=([info]="\033[0;36m" [warn]="\033[0;33m" [error]="\033[0;31m" [debug]="\033[0;35m")
    echo -e "${colors[$level]:-\033[0;32m}$msg\033[0m"
}

debug_log() {
    [[ "${DEBUG:-}" == "1" ]] && log "DEBUG: $1" "debug"
}

# === 辅助函数 ===
convert_to_mb() {
    local size="$1"
    size=$(echo "$size" | tr -d ' ')
    
    case "${size^^}" in
        *G|*GB)
            local value=$(echo "$size" | sed 's/[^0-9.]//g')
            echo "$value * 1024" | awk '{printf "%.0f", $1 * $3}'
            ;;
        *M|*MB)
            local value=$(echo "$size" | sed 's/[^0-9.]//g')
            echo "$value" | awk '{printf "%.0f", $1}'
            ;;
        *K|*KB)
            local value=$(echo "$size" | sed 's/[^0-9.]//g')
            echo "$value / 1024" | awk '{printf "%.0f", $1 / $3}'
            ;;
        *)
            local value=$(echo "$size" | sed 's/[^0-9.]//g')
            echo "$value / 1024 / 1024" | awk '{printf "%.0f", $1 / $3 / $5}'
            ;;
    esac
}

# CPU性能快速检测
benchmark_cpu_quick() {
    debug_log "开始CPU性能检测"
    local cores=$(nproc)
    
    # 快速压缩测试
    local start_time=$(date +%s.%N)
    if ! timeout 10s bash -c 'dd if=/dev/zero bs=1M count=32 2>/dev/null | gzip -1 > /dev/null' 2>/dev/null; then
        log "CPU检测超时，使用保守配置" "warn"
        echo "weak"
        return
    fi
    local end_time=$(date +%s.%N)
    
    local duration=$(echo "$end_time - $start_time" | bc 2>/dev/null || echo "5")
    local cpu_score=$(echo "scale=2; ($cores * 2) / $duration" | bc 2>/dev/null || echo "2")
    
    debug_log "CPU核心数: $cores, 测试时间: ${duration}s, 得分: $cpu_score"
    
    if (( $(echo "$cpu_score < 3" | bc -l 2>/dev/null || echo "1") )); then
        echo "weak"
    elif (( $(echo "$cpu_score < 8" | bc -l 2>/dev/null || echo "0") )); then
        echo "moderate"  
    else
        echo "strong"
    fi
}

# 获取内存分类
get_memory_category() {
    local mem_mb="$1"
    
    if (( mem_mb < 1024 )); then
        echo "low"          # 低配 (<1GB)
    elif (( mem_mb < 2048 )); then  
        echo "medium"       # 中配 (1-2GB)
    elif (( mem_mb < 4096 )); then
        echo "high"         # 高配 (2-4GB)  
    else
        echo "flagship"     # 旗舰 (4GB+)
    fi
}

# 智能决策矩阵
get_optimal_zram_config() {
    local mem_mb="$1"
    local cpu_level="$2"
    local cores=$(nproc)
    
    local mem_category=$(get_memory_category "$mem_mb")
    debug_log "内存分类: $mem_category, CPU等级: $cpu_level, 核心数: $cores"
    
    # 决策矩阵：算法,设备数,大小倍数
    case "$mem_category-$cpu_level" in
        "low-"*) 
            echo "lz4,single,1.8" ;;
        "medium-weak") 
            echo "lz4,single,1.5" ;;
        "medium-moderate"|"medium-strong") 
            echo "lz4,single,1.2" ;;
        "high-weak") 
            echo "lz4,single,1.0" ;;
        "high-moderate") 
            echo "zstd,single,0.8" ;;
        "high-strong") 
            # 4核以上考虑多设备
            if (( cores >= 4 )); then
                echo "zstd,multi,0.75"
            else
                echo "zstd,single,0.8"
            fi
            ;;
        "flagship-"*) 
            if (( cores >= 4 )); then
                echo "zstd,multi,0.5"
            else
                echo "zstd,single,0.6"
            fi
            ;;
        *)
            log "未知配置组合: $mem_category-$cpu_level，使用默认" "warn"
            echo "lz4,single,1.0"
            ;;
    esac
}

# 设置系统参数（优先级和swappiness）
set_system_parameters() {
    local mem_mb="$1"
    local device_count="${2:-1}"
    
    # 优先级设置
    local zram_priority disk_priority swappiness
    
    if (( mem_mb <= 1024 )); then
        zram_priority=90; disk_priority=40; swappiness=40
    elif (( mem_mb <= 2048 )); then
        zram_priority=100; disk_priority=30; swappiness=50
    else
        zram_priority=100; disk_priority=20; swappiness=60
    fi
    
    debug_log "设置zram优先级: $zram_priority, swappiness: $swappiness"
    
    # 设置swappiness
    if [[ -w /proc/sys/vm/swappiness ]]; then
        echo "$swappiness" > /proc/sys/vm/swappiness 2>/dev/null || {
            log "设置swappiness失败" "warn"
        }
    fi
    
    # 设置zram优先级
    for i in $(seq 0 $((device_count - 1))); do
        if [[ -b "/dev/zram$i" ]]; then
            swapon "/dev/zram$i" -p "$zram_priority" 2>/dev/null || {
                log "设置zram$i优先级失败" "warn"
            }
        fi
    done
    
    # 设置磁盘swap优先级（如果存在）
    if swapon --show | grep -v zram | grep -q "/"; then
        local disk_swap=$(swapon --show | grep -v zram | awk 'NR>1 {print $1}' | head -1)
        [[ -n "$disk_swap" ]] && swapoff "$disk_swap" 2>/dev/null && swapon "$disk_swap" -p "$disk_priority" 2>/dev/null || true
    fi
    
    echo "$zram_priority"
}

# 配置单个zram设备
setup_single_zram() {
    local size_mib="$1"
    local algorithm="$2"
    
    debug_log "配置单zram: ${size_mib}MB, 算法: $algorithm"
    
    # 停用现有zram
    systemctl stop zramswap.service 2>/dev/null || true
    
    # 安装zram-tools
    if ! dpkg -l zram-tools &>/dev/null; then
        debug_log "安装zram-tools"
        if ! apt-get update -qq && apt-get install -y zram-tools >/dev/null 2>&1; then
            log "zram-tools安装失败" "error"
            return 1
        fi
    fi
    
    # 配置文件
    if [[ -f "$ZRAM_CONFIG" ]]; then
        cp "$ZRAM_CONFIG" "${ZRAM_CONFIG}.bak"
        if grep -q "^SIZE=" "$ZRAM_CONFIG"; then
            sed -i "s/^SIZE=.*/SIZE=$size_mib/" "$ZRAM_CONFIG"
        else
            echo "SIZE=$size_mib" >> "$ZRAM_CONFIG"
        fi
        
        if grep -q "^ALGO=" "$ZRAM_CONFIG"; then
            sed -i "s/^ALGO=.*/ALGO=$algorithm/" "$ZRAM_CONFIG"
        else
            echo "ALGO=$algorithm" >> "$ZRAM_CONFIG"
        fi
    else
        cat > "$ZRAM_CONFIG" << EOF
SIZE=$size_mib
ALGO=$algorithm
EOF
    fi
    
    # 启动服务
    if ! systemctl enable zramswap.service >/dev/null 2>&1; then
        log "启用zramswap服务失败" "error"
        return 1
    fi
    
    if ! systemctl start zramswap.service 2>&1; then
        log "启动zramswap服务失败" "error" 
        return 1
    fi
    
    sleep 2
    return 0
}

# 配置多个zram设备
setup_multiple_zram() {
    local total_size_mb="$1"
    local algorithm="$2"
    local cores=$(nproc)
    local device_count=$((cores > 4 ? 4 : cores))  # 最多4个设备
    local per_device_mb=$((total_size_mb / device_count))
    
    debug_log "配置多zram: ${device_count}个设备, 每个${per_device_mb}MB"
    
    # 停用现有swap
    systemctl stop zramswap.service 2>/dev/null || true
    for dev in /dev/zram*; do
        [[ -b "$dev" ]] && swapoff "$dev" 2>/dev/null || true
    done
    
    # 卸载现有zram模块
    modprobe -r zram 2>/dev/null || true
    
    # 加载zram模块
    if ! modprobe zram num_devices="$device_count" 2>/dev/null; then
        log "加载zram模块失败" "error"
        return 1
    fi
    
    # 配置每个设备
    for i in $(seq 0 $((device_count - 1))); do
        local device="/dev/zram$i"
        debug_log "配置设备 $device"
        
        # 设置压缩算法
        if ! echo "$algorithm" > "/sys/block/zram$i/comp_algorithm" 2>/dev/null; then
            log "设置zram$i压缩算法失败" "warn"
        fi
        
        # 设置大小
        if ! echo "${per_device_mb}M" > "/sys/block/zram$i/disksize" 2>/dev/null; then
            log "设置zram$i大小失败" "error"
            return 1
        fi
        
        # 创建swap
        if ! mkswap "$device" >/dev/null 2>&1; then
            log "创建zram$i swap失败" "error"
            return 1
        fi
    done
    
    echo "$device_count"
    return 0
}

# 主要的zram配置函数
setup_zram() {
    local mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
    
    # CPU性能检测
    local cpu_level
    if ! cpu_level=$(benchmark_cpu_quick); then
        log "CPU检测失败，使用保守配置" "warn"
        cpu_level="weak"
    fi
    
    # 获取最优配置
    local config=$(get_optimal_zram_config "$mem_mb" "$cpu_level")
    local algorithm=$(echo "$config" | cut -d, -f1)
    local device_type=$(echo "$config" | cut -d, -f2)
    local multiplier=$(echo "$config" | cut -d, -f3)
    
    # 计算zram大小
    local target_size_mb=$(echo "$mem_mb * $multiplier" | bc | cut -d. -f1)
    
    debug_log "内存: ${mem_mb}MB, 配置: $config, 目标大小: ${target_size_mb}MB"
    
    # 检查现有zram是否合适
    local current_zram_info=$(swapon --show 2>/dev/null | grep zram | head -1)
    if [[ -n "$current_zram_info" ]]; then
        local current_size=$(echo "$current_zram_info" | awk '{print $3}')
        local current_mb=$(convert_to_mb "$current_size")
        local min_acceptable=$((target_size_mb * 90 / 100))
        local max_acceptable=$((target_size_mb * 110 / 100))
        
        if (( current_mb >= min_acceptable && current_mb <= max_acceptable )); then
            local priority=$(set_system_parameters "$mem_mb" 1)
            echo "Zram: $current_size ($algorithm, 已配置, 优先级$priority)"
            return 0
        fi
        
        # 清理现有配置
        systemctl stop zramswap.service 2>/dev/null || true
        for dev in /dev/zram*; do
            [[ -b "$dev" ]] && swapoff "$dev" 2>/dev/null || true
        done
    fi
    
    # 配置新的zram
    local device_count=1
    local actual_size priority
    
    if [[ "$device_type" == "multi" ]]; then
        if device_count=$(setup_multiple_zram "$target_size_mb" "$algorithm"); then
            priority=$(set_system_parameters "$mem_mb" "$device_count")
            actual_size="${target_size_mb}MB"
            echo "Zram: $actual_size ($algorithm, ${device_count}设备, 优先级$priority)"
        else
            log "多设备配置失败，回退到单设备" "warn"
            device_type="single"
        fi
    fi
    
    if [[ "$device_type" == "single" ]]; then
        if setup_single_zram "$target_size_mb" "$algorithm"; then
            sleep 2
            if swapon --show | grep -q zram0; then
                actual_size=$(swapon --show | grep zram0 | awk '{print $3}')
                priority=$(set_system_parameters "$mem_mb" 1)
                echo "Zram: $actual_size ($algorithm, 单设备, 优先级$priority)"
            else
                log "Zram启动验证失败" "error"
                return 1
            fi
        else
            log "Zram配置失败" "error"
            return 1
        fi
    fi
}

# 配置时区 - 保持原有逻辑
setup_timezone() {
    local current_tz=$(timedatectl show --property=Timezone --value 2>/dev/null)
    
    read -p "时区设置 [1=上海 2=UTC 3=东京 4=伦敦 5=纽约 6=自定义 7=保持] (默认1): " choice </dev/tty >&2
    choice=${choice:-1}
    
    local target_tz
    case "$choice" in
        1) target_tz="Asia/Shanghai" ;;
        2) target_tz="UTC" ;;
        3) target_tz="Asia/Tokyo" ;;
        4) target_tz="Europe/London" ;;
        5) target_tz="America/New_York" ;;
        6) 
            read -p "输入时区 (如: Asia/Shanghai): " target_tz </dev/tty >&2
            if ! timedatectl list-timezones | grep -q "^$target_tz$"; then
                log "无效时区，使用默认" "warn"
                target_tz="$DEFAULT_TIMEZONE"
            fi
            ;;
        7) 
            echo "时区: $current_tz (保持不变)"
            return 0
            ;;
        *) 
            target_tz="$DEFAULT_TIMEZONE"
            ;;
    esac
    
    if [[ "$current_tz" != "$target_tz" ]]; then
        if ! timedatectl set-timezone "$target_tz" 2>/dev/null; then
            log "设置时区失败" "error"
            return 1
        fi
    fi
    
    echo "时区: $target_tz"
}

# 配置Chrony - 保持原有逻辑  
setup_chrony() {
    if command -v chronyd &>/dev/null && systemctl is-active chrony &>/dev/null 2>&1; then
        local sync_status=$(chronyc tracking 2>/dev/null | grep "System clock synchronized" | awk '{print $4}' 2>/dev/null || echo "no")
        if [[ "$sync_status" == "yes" ]]; then
            echo "时间同步: Chrony (已同步)"
            return 0
        fi
    fi
    
    systemctl stop systemd-timesyncd 2>/dev/null || true
    systemctl disable systemd-timesyncd 2>/dev/null || true
    
    if ! command -v chronyd &>/dev/null; then
        if ! apt-get install -y chrony >/dev/null 2>&1; then
            log "Chrony安装失败" "error"
            return 1
        fi
    fi
    
    systemctl enable chrony >/dev/null 2>&1 || true
    systemctl start chrony >/dev/null 2>&1 || true
    
    sleep 2
    if systemctl is-active chrony &>/dev/null; then
        local sources_count=$(chronyc sources 2>/dev/null | grep -c "^\^" || echo "0")
        echo "时间同步: Chrony (${sources_count}个时间源)"
    else
        log "Chrony启动失败" "error"
        return 1
    fi
}

# === 主流程 ===
main() {
    # 检查root权限
    if [[ $EUID -ne 0 ]]; then
        log "需要root权限运行" "error"
        exit 1
    fi
    
    # 检查必要命令
    for cmd in bc awk swapon systemctl; do
        if ! command -v "$cmd" &>/dev/null; then
            log "缺少必要命令: $cmd" "error"
            exit 1
        fi
    done
    
    log "🔧 智能系统优化配置..." "info"
    
    echo
    if ! setup_zram; then
        log "Zram配置失败，继续其他配置" "warn"
    fi
    
    echo
    if ! setup_timezone; then
        log "时区配置失败" "warn"
    fi
    
    echo  
    if ! setup_chrony; then
        log "时间同步配置失败" "warn"
    fi
    
    echo
    log "✅ 优化完成" "info"
    
    # 显示最终状态
    if [[ "${DEBUG:-}" == "1" ]]; then
        echo
        log "=== 系统状态 ===" "debug"
        free -h | head -2
        swapon --show 2>/dev/null || echo "无swap设备"
        cat /proc/sys/vm/swappiness 2>/dev/null | xargs echo "swappiness:" || true
    fi
}

# 错误处理
trap 'log "脚本执行出错，行号: $LINENO" "error"; exit 1' ERR

main "$@"
