#!/bin/bash
# 系统优化模块 v5.1 - 智能Zram版 - 完全修复版
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
    [[ "${DEBUG:-}" == "1" ]] && log "DEBUG: $1" "debug" >&2
}

# === 辅助函数 ===
# 转换大小单位到MB
convert_to_mb() {
    local size="$1"
    size=$(echo "$size" | tr -d ' ')
    local value=$(echo "$size" | sed 's/[^0-9.]//g')
    
    case "${size^^}" in
        *G|*GB) awk "BEGIN {printf \"%.0f\", $value * 1024}" ;;
        *M|*MB) awk "BEGIN {printf \"%.0f\", $value}" ;;
        *K|*KB) awk "BEGIN {printf \"%.0f\", $value / 1024}" ;;
        *)      awk "BEGIN {printf \"%.0f\", $value / 1024 / 1024}" ;;
    esac
}

# 转换为合适的显示单位
format_size() {
    local mb="$1"
    if (( mb >= 1024 )); then
        awk "BEGIN {gb=$mb/1024; printf (gb==int(gb)) ? \"%.0fGB\" : \"%.1fGB\", gb}"
    else
        echo "${mb}MB"
    fi
}

# 显示当前swap状态
show_swap_status() {
    local swappiness=$(cat /proc/sys/vm/swappiness 2>/dev/null || echo "unknown")
    echo "Swap配置: swappiness=$swappiness"
    
    local swap_output=$(swapon --show 2>/dev/null | tail -n +2)  # 跳过表头
    if [[ -n "$swap_output" ]]; then
        echo "Swap状态:"
        while read -r device _ size used priority; do
            [[ -z "$device" ]] && continue
            if [[ "$device" == *"zram"* ]]; then
                echo "  - Zram: $device ($size, 已用$used, 优先级$priority)"
            else
                echo "  - 磁盘: $device ($size, 已用$used, 优先级$priority)"
            fi
        done <<< "$swap_output"
    else
        echo "Swap状态: 无活动设备"
    fi
}

# 彻底清理zram配置 - 增强版
cleanup_zram_completely() {
    debug_log "开始彻底清理zram"
    
    # 停止服务
    systemctl stop zramswap.service 2>/dev/null || true
    systemctl disable zramswap.service 2>/dev/null || true
    
    # 关闭所有zram设备
    for dev in /dev/zram*; do
        if [[ -b "$dev" ]]; then
            swapoff "$dev" 2>/dev/null || true
            echo 1 > "/sys/block/$(basename $dev)/reset" 2>/dev/null || true
            debug_log "重置设备: $dev"
        fi
    done
    
    # 卸载zram模块
    modprobe -r zram 2>/dev/null || true
    
    # 清理配置文件备份
    [[ -f "$ZRAM_CONFIG" ]] && rm -f "${ZRAM_CONFIG}.bak" 2>/dev/null || true
    
    # 等待设备完全清理
    sleep 2
    debug_log "zram清理完成"
}

# === 核心功能函数 ===
# CPU性能快速检测 - 修复bc依赖
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
    
    local duration cpu_score
    if command -v bc >/dev/null 2>&1; then
        duration=$(echo "$end_time - $start_time" | bc 2>/dev/null || echo "5")
        cpu_score=$(echo "scale=2; ($cores * 2) / $duration" | bc 2>/dev/null || echo "2")
    else
        # 备用计算：使用整数运算
        local start_int=${start_time%.*}
        local end_int=${end_time%.*}
        duration=$((end_int - start_int + 1))  # 保守估计
        cpu_score=$(( (cores * 200) / duration / 100 ))  # 简化计算
    fi
    
    debug_log "CPU核心数: $cores, 测试时间: ${duration}s, 得分: $cpu_score"
    
    if command -v bc >/dev/null 2>&1; then
        if (( $(echo "$cpu_score < 3" | bc -l 2>/dev/null || echo "1") )); then
            echo "weak"
        elif (( $(echo "$cpu_score < 8" | bc -l 2>/dev/null || echo "0") )); then
            echo "moderate"  
        else
            echo "strong"
        fi
    else
        # 备用比较
        if (( cpu_score < 3 )); then
            echo "weak"
        elif (( cpu_score < 8 )); then
            echo "moderate"
        else
            echo "strong"
        fi
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

# 智能决策矩阵 - 统一zstd版本
get_optimal_zram_config() {
    local mem_mb="$1"
    local cpu_level="$2"
    local cores="$3"
    
    local mem_category=$(get_memory_category "$mem_mb")
    debug_log "内存分类: $mem_category, CPU等级: $cpu_level, 核心数: $cores"
    
    # 统一使用zstd，根据内存调整策略
    case "$mem_category" in
        "low") 
            echo "zstd,single,2.0" ;;    # 1GB以下更激进
        "medium") 
            echo "zstd,single,1.5" ;;    # 1-2GB
        "high") 
            if (( cores >= 4 )); then
                echo "zstd,multi,1.0"    # 2-4GB，多核用多设备
            else
                echo "zstd,single,1.0"
            fi
            ;;
        "flagship") 
            if (( cores >= 4 )); then
                echo "zstd,multi,0.6"    # 4GB+，适度配置
            else
                echo "zstd,single,0.8"
            fi
            ;;
        *)
            log "未知配置组合: $mem_category，使用默认" "warn"
            echo "zstd,single,1.0"
            ;;
    esac
}

# 设置系统参数（增强版，包含zswap禁用和页面集群优化）
set_system_parameters() {
    local mem_mb="$1"
    local device_count="${2:-1}"
    
    # 更积极的swappiness设置
    local zram_priority disk_priority swappiness
    
    if (( mem_mb <= 1024 )); then
        zram_priority=100; disk_priority=40; swappiness=60   # 低内存更积极使用swap
    elif (( mem_mb <= 2048 )); then
        zram_priority=100; disk_priority=30; swappiness=70   # 中等内存积极使用
    elif (( mem_mb <= 4096 )); then
        zram_priority=100; disk_priority=20; swappiness=80   # 高内存很积极
    else
        zram_priority=100; disk_priority=10; swappiness=90   # 旗舰配置最积极
    fi
    
    debug_log "目标配置: zram优先级=$zram_priority, swappiness=$swappiness"
    
    # 创建完整的sysctl配置文件
    local sysctl_file="/etc/sysctl.d/99-zram-optimize.conf"
    local needs_update=false
    
    # 检查是否需要更新配置
    if [[ ! -f "$sysctl_file" ]]; then
        needs_update=true
    else
        # 检查关键参数是否匹配
        local current_swappiness=$(grep "^vm.swappiness" "$sysctl_file" 2>/dev/null | awk '{print $3}')
        local current_page_cluster=$(grep "^vm.page-cluster" "$sysctl_file" 2>/dev/null | awk '{print $3}')
        
        if [[ "$current_swappiness" != "$swappiness" ]] || [[ "$current_page_cluster" != "0" ]]; then
            needs_update=true
        fi
    fi
    
    # 创建或更新sysctl配置文件
    if [[ "$needs_update" == "true" ]]; then
        cat > "$sysctl_file" << EOF
# Zram优化配置 - 由系统优化脚本自动生成
# 更积极地使用zram swap
vm.swappiness = $swappiness

# 优化页面集群，提高zram效率（特别是使用zstd时）
vm.page-cluster = 0

# 禁用zswap避免与zram冲突
# zswap会拦截要交换的页面，导致zram利用率低下
kernel.zswap.enabled = 0
EOF
        
        if [[ $? -eq 0 ]]; then
            debug_log "sysctl配置已更新: swappiness=$swappiness, page-cluster=0, zswap disabled"
            
            # 应用配置
            sysctl -p "$sysctl_file" >/dev/null 2>&1 || {
                debug_log "sysctl应用失败，使用运行时设置"
            }
        else
            log "sysctl配置文件写入失败" "error"
        fi
    fi
    
    # 运行时设置（确保立即生效）
    # 1. 设置swappiness
    local current_swappiness=$(cat /proc/sys/vm/swappiness 2>/dev/null || echo "60")
    if [[ "$current_swappiness" != "$swappiness" ]]; then
        if [[ -w /proc/sys/vm/swappiness ]]; then
            echo "$swappiness" > /proc/sys/vm/swappiness 2>/dev/null && \
                debug_log "swappiness运行时已设置: $current_swappiness -> $swappiness"
        fi
    fi
    
    # 2. 设置page-cluster
    local current_page_cluster=$(cat /proc/sys/vm/page-cluster 2>/dev/null || echo "3")
    if [[ "$current_page_cluster" != "0" ]]; then
        if [[ -w /proc/sys/vm/page-cluster ]]; then
            echo "0" > /proc/sys/vm/page-cluster 2>/dev/null && \
                debug_log "page-cluster已设置: $current_page_cluster -> 0"
        fi
    fi
    
    # 3. 禁用zswap（如果存在）
    if [[ -f /sys/module/zswap/parameters/enabled ]]; then
        local current_zswap=$(cat /sys/module/zswap/parameters/enabled 2>/dev/null || echo "N")
        if [[ "$current_zswap" == "Y" ]]; then
            echo "0" > /sys/module/zswap/parameters/enabled 2>/dev/null && \
                debug_log "zswap已禁用，避免与zram冲突"
        fi
    fi
    
    # 设置zram优先级（保持原有逻辑）
    for i in $(seq 0 $((device_count - 1))); do
        local device="/dev/zram$i"
        if [[ -b "$device" ]]; then
            if swapon --show 2>/dev/null | grep -q "^$device "; then
                swapoff "$device" 2>/dev/null || continue
            fi
            if ! swapon "$device" -p "$zram_priority" 2>/dev/null; then
                debug_log "设置zram$i优先级失败"
                swapon "$device" 2>/dev/null || true
            fi
        fi
    done
    
    # 设置磁盘swap优先级
    local disk_swap_count=0
    local disk_swap_output=$(swapon --show 2>/dev/null | grep -v zram | tail -n +2)
    if [[ -n "$disk_swap_output" ]]; then
        while read -r disk_swap _; do
            [[ -n "$disk_swap" ]] || continue
            if [[ -f "$disk_swap" || -b "$disk_swap" ]]; then
                if swapoff "$disk_swap" 2>/dev/null && swapon "$disk_swap" -p "$disk_priority" 2>/dev/null; then
                    ((disk_swap_count++))
                    debug_log "磁盘swap $disk_swap 优先级设置为 $disk_priority"
                fi
            fi
        done <<< "$disk_swap_output"
    fi
    
    echo "$zram_priority,$swappiness,$disk_swap_count"
}

# 配置单个zram设备 - 修复交互问题版本
setup_single_zram() {
    local size_mib="$1"
    local algorithm="$2"
    
    debug_log "配置单zram: ${size_mib}MB, 算法: $algorithm"
    
    # === 1. 预清理可能导致交互的配置文件 ===
    if ! dpkg -l zram-tools &>/dev/null; then
        debug_log "预清理可能的配置文件冲突"
        # 如果包未安装但配置文件存在，先删除以避免交互
        [[ -f "$ZRAM_CONFIG" ]] && rm -f "$ZRAM_CONFIG" 2>/dev/null || true
        [[ -f "${ZRAM_CONFIG}.bak" ]] && rm -f "${ZRAM_CONFIG}.bak" 2>/dev/null || true
    fi
    
    # === 2. 包完整性检查和安装 ===
    if ! dpkg -l zram-tools &>/dev/null; then
        debug_log "安装zram-tools"
        # 使用非交互模式安装
        DEBIAN_FRONTEND=noninteractive apt-get update -qq && \
        DEBIAN_FRONTEND=noninteractive apt-get install -y zram-tools >/dev/null 2>&1 || {
            log "zram-tools安装失败" "error"
            return 1
        }
        systemctl daemon-reload
    else
        # 检查关键文件是否真的存在
        if [[ ! -f /usr/sbin/zramswap ]] || [[ ! -f /usr/lib/systemd/system/zramswap.service ]]; then
            log "检测到zram-tools包损坏，重新安装" "warn"
            # 先清理配置文件避免交互
            rm -f "$ZRAM_CONFIG" "${ZRAM_CONFIG}.bak" 2>/dev/null || true
            apt-get purge -y zram-tools >/dev/null 2>&1 || true
            apt-get autoremove -y >/dev/null 2>&1 || true
            if ! DEBIAN_FRONTEND=noninteractive apt-get install -y zram-tools >/dev/null 2>&1; then
                log "zram-tools重装失败" "error"
                return 1
            fi
            systemctl daemon-reload
        fi
    fi
    
    # 继续原来的配置逻辑...
    debug_log "创建配置文件: SIZE=${size_mib}, ALGO=$algorithm"
    
    # 完全重写配置文件
    cat > "$ZRAM_CONFIG" << EOF
# Compression algorithm selection
ALGO=$algorithm

# Use fixed SIZE instead of PERCENT
SIZE=$size_mib

# Specifies the priority for the swap devices
PRIORITY=100
EOF
    
    debug_log "配置文件已创建"
    [[ "${DEBUG:-}" == "1" ]] && cat "$ZRAM_CONFIG" >&2
    
    # 启动服务
    if ! systemctl enable zramswap.service >/dev/null 2>&1; then
        log "启用zramswap服务失败" "error"
        return 1
    fi
    
    if ! systemctl start zramswap.service >/dev/null 2>&1; then
        log "启动zramswap服务失败" "error"
        return 1
    fi
    
    sleep 3
    
    # 验证配置
    if [[ -b /dev/zram0 ]]; then
        local actual_bytes=$(cat /sys/block/zram0/disksize 2>/dev/null || echo "0")
        local actual_mb=$((actual_bytes / 1024 / 1024))
        local min_expected=$((size_mib * 95 / 100))
        local max_expected=$((size_mib * 105 / 100))
        
        if (( actual_mb >= min_expected && actual_mb <= max_expected )); then
            debug_log "zram配置成功: 期望${size_mib}MB, 实际${actual_mb}MB"
            return 0
        else
            log "zram大小不匹配: 期望${size_mib}MB, 实际${actual_mb}MB" "error"
            return 1
        fi
    else
        log "zram设备未创建" "error"
        return 1
    fi
}

# 配置多个zram设备
setup_multiple_zram() {
    local total_size_mb="$1"
    local algorithm="$2"
    local cores="$3"
    local device_count=$((cores > 4 ? 4 : cores))
    local per_device_mb=$((total_size_mb / device_count))
    
    debug_log "配置多zram: ${device_count}个设备, 每个${per_device_mb}MB"
    
    # 彻底清理现有zram
    cleanup_zram_completely
    
    # 加载zram模块
    if ! modprobe zram num_devices="$device_count" 2>/dev/null; then
        debug_log "加载zram模块失败"
        return 1
    fi
    
    sleep 1
    
    # 配置每个设备
    for i in $(seq 0 $((device_count - 1))); do
        local device="/dev/zram$i"
        
        # 等待设备就绪
        local retry=0
        while [[ ! -b "$device" ]] && (( retry < 10 )); do
            sleep 0.1
            ((retry++))
        done
        
        [[ -b "$device" ]] || {
            debug_log "设备zram$i未就绪"
            return 1
        }
        
        # 设置压缩算法
        [[ -w "/sys/block/zram$i/comp_algorithm" ]] && 
            echo "$algorithm" > "/sys/block/zram$i/comp_algorithm" 2>/dev/null ||
            debug_log "设置zram$i压缩算法失败，使用默认"
        
        # 设置大小
        echo "${per_device_mb}M" > "/sys/block/zram$i/disksize" 2>/dev/null || {
            debug_log "设置zram$i大小失败"
            return 1
        }
        
        # 创建swap
        mkswap "$device" >/dev/null 2>&1 || {
            debug_log "创建zram$i swap失败"
            return 1
        }
    done
    
    echo "$device_count"
    return 0
}

# 主要的zram配置函数 - 完全修复版
setup_zram() {
    local mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
    local cores=$(nproc)
    local mem_display=$(format_size "$mem_mb")
    
    echo "检测到: ${mem_display}内存, ${cores}核CPU"
    
    # CPU性能检测
    local cpu_level
    if ! cpu_level=$(benchmark_cpu_quick); then
        log "CPU检测失败，使用保守配置" "warn"
        cpu_level="weak"
    fi
    
    echo "CPU性能: $cpu_level"
    
    # 获取最优配置
    local config=$(get_optimal_zram_config "$mem_mb" "$cpu_level" "$cores")
    local algorithm=$(echo "$config" | cut -d, -f1)
    local device_type=$(echo "$config" | cut -d, -f2)
    local multiplier=$(echo "$config" | cut -d, -f3)
    
    # 计算zram大小
    local target_size_mb
    if command -v bc >/dev/null 2>&1 && target_size_mb=$(awk "BEGIN {printf \"%.0f\", $mem_mb * $multiplier}" 2>/dev/null); then
        debug_log "目标大小计算: ${mem_mb}MB * $multiplier = ${target_size_mb}MB"
    else
        # 备用计算
        local int_multiplier=$(echo "$multiplier" | cut -d. -f1)
        local decimal_part=$(echo "$multiplier" | cut -d. -f2 2>/dev/null || echo "0")
        if [[ ${#decimal_part} -eq 1 ]]; then
            decimal_part="${decimal_part}0"
        fi
        target_size_mb=$(( (mem_mb * ${int_multiplier:-1}) + (mem_mb * ${decimal_part:-0} / 100) ))
        debug_log "使用整数计算: $target_size_mb"
    fi
    
    # 检查现有zram是否合适 - 关键修复
    local current_zram_devices=0
    local zram_output
    if zram_output=$(swapon --show 2>/dev/null); then
        current_zram_devices=$(echo "$zram_output" | grep -c "zram" 2>/dev/null || echo "0")
    fi
    
    # 确保变量安全
    current_zram_devices=$(echo "$current_zram_devices" | tr -cd '0-9' | head -c 10)
    current_zram_devices=${current_zram_devices:-0}
    
    debug_log "当前zram设备数量: $current_zram_devices"
    
    # 检查现有配置是否匹配
    if [[ "$current_zram_devices" =~ ^[0-9]+$ ]] && [[ "$current_zram_devices" -gt 0 ]]; then
        # 计算当前zram总大小
        local current_total_mb=0
        while read -r device _ size _; do
            [[ "$device" == *"zram"* ]] || continue
            local current_mb=$(convert_to_mb "$size")
            current_total_mb=$((current_total_mb + current_mb))
        done < <(swapon --show 2>/dev/null | grep zram)
        
        # 检查配置是否匹配
        local min_acceptable=$((target_size_mb * 90 / 100))
        local max_acceptable=$((target_size_mb * 110 / 100))
        local expected_device_count=1
        [[ "$device_type" == "multi" ]] && expected_device_count=$((cores > 4 ? 4 : cores))
        
        debug_log "当前: ${current_total_mb}MB/${current_zram_devices}设备, 期望: ${target_size_mb}MB/${expected_device_count}设备"
        
        # 配置匹配检查
        if (( current_total_mb >= min_acceptable && 
              current_total_mb <= max_acceptable && 
              current_zram_devices == expected_device_count )); then
            # 配置匹配，只调整优先级
            local params_result=$(set_system_parameters "$mem_mb" "$current_zram_devices")
            local priority=$(echo "$params_result" | cut -d, -f1)
            
            local display_size=$(format_size "$current_total_mb")
            local device_desc
            if (( current_zram_devices > 1 )); then
                device_desc="${current_zram_devices}设备"
            else
                device_desc="单设备"
            fi
            echo "Zram: $display_size ($algorithm, ${device_desc}, 优先级$priority, 已配置)"
            show_swap_status
            return 0
        else
            # 配置不匹配，需要重新配置
            echo "现有配置不匹配，重新配置..."
            cleanup_zram_completely  # 关键：彻底清理
        fi
    fi
    
    # 配置新的zram
    local device_count=1 actual_size_mb config_success=false
    
    if [[ "$device_type" == "multi" ]]; then
        if device_count=$(setup_multiple_zram "$target_size_mb" "$algorithm" "$cores"); then
            config_success=true
            actual_size_mb="$target_size_mb"
        else
            log "多设备配置失败，回退到单设备" "warn"
            cleanup_zram_completely
            device_type="single"
        fi
    fi
    
    if [[ "$device_type" == "single" ]]; then
        if setup_single_zram "$target_size_mb" "$algorithm"; then
            # 验证配置成功
            if swapon --show 2>/dev/null | grep -q zram0; then
                config_success=true
                local current_size=$(swapon --show 2>/dev/null | grep zram0 | awk '{print $3}')
                actual_size_mb=$(convert_to_mb "$current_size")
            else
                log "Zram启动验证失败" "error"
                return 1
            fi
        else
            log "Zram配置失败" "error"
            return 1
        fi
    fi
    
    # 设置优先级和显示结果
    if [[ "$config_success" == "true" ]]; then
        local params_result=$(set_system_parameters "$mem_mb" "$device_count")
        local priority=$(echo "$params_result" | cut -d, -f1)
        
        local display_size=$(format_size "$actual_size_mb")
        local device_desc
        if (( device_count > 1 )); then
            device_desc="${device_count}设备"
        else
            device_desc="单设备"
        fi
        echo "Zram: $display_size ($algorithm, ${device_desc}, 优先级$priority)"
        show_swap_status
    fi
}

# 配置时区
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
        timedatectl set-timezone "$target_tz" 2>/dev/null || {
            log "设置时区失败" "error"
            return 1
        }
    fi
    
    echo "时区: $target_tz"
}

# 配置Chrony
setup_chrony() {
    if command -v chronyd &>/dev/null && systemctl is-active chrony &>/dev/null 2>&1; then
        local sync_status=$(chronyc tracking 2>/dev/null | awk '/System clock synchronized/{print $4}' || echo "no")
        if [[ "$sync_status" == "yes" ]]; then
            echo "时间同步: Chrony (已同步)"
            return 0
        fi
    fi
    
    # 停用冲突服务
    systemctl stop systemd-timesyncd 2>/dev/null || true
    systemctl disable systemd-timesyncd 2>/dev/null || true
    
    # 安装chrony
    if ! command -v chronyd &>/dev/null; then
        apt-get install -y chrony >/dev/null 2>&1 || {
            log "Chrony安装失败" "error"
            return 1
        }
    fi
    
    # 启动服务
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
    [[ $EUID -eq 0 ]] || {
        log "需要root权限运行" "error"
        exit 1
    }
    
    # 检查包管理器锁定状态
    local wait_count=0
    while [[ $wait_count -lt 6 ]]; do
        if timeout 10s apt-get update -qq 2>/dev/null; then
            break
        else
            if [[ $wait_count -eq 0 ]]; then
                log "检测到包管理器被锁定，等待释放..." "warn"
            fi
            sleep 10
            wait_count=$((wait_count + 1))
        fi
    done
    
    if [[ $wait_count -ge 6 ]]; then
        log "包管理器锁定超时，请检查是否有其他apt进程运行" "error"
        exit 1
    fi
    
    # 检查和安装必要命令
    for cmd in awk swapon systemctl; do
        command -v "$cmd" &>/dev/null || {
            log "缺少必要命令: $cmd" "error"
            exit 1
        }
    done
    
    # 安装bc（如果需要）
    if ! command -v bc &>/dev/null; then
        log "安装必需的依赖: bc" "info"
        apt-get install -y bc >/dev/null 2>&1 || {
            log "bc安装失败，将使用备用计算方法" "warn"
        }
    fi
    
    # 避免分页器问题
    export SYSTEMD_PAGER=""
    export PAGER=""
    
    log "🔧 智能系统优化配置..." "info"
    
    echo
    setup_zram || log "Zram配置失败，继续其他配置" "warn"
    
    echo
    setup_timezone || log "时区配置失败" "warn"
    
    echo  
    setup_chrony || log "时间同步配置失败" "warn"
    
    echo
    log "✅ 优化完成" "info"
    
    # 显示最终状态
    if [[ "${DEBUG:-}" == "1" ]]; then
        echo
        log "=== 系统状态 ===" "debug"
        free -h | head -2
        swapon --show 2>/dev/null || echo "无swap设备"
        echo "swappiness: $(cat /proc/sys/vm/swappiness 2>/dev/null || echo 'unknown')"
    fi
}

# 错误处理
trap 'log "脚本执行出错，行号: $LINENO" "error"; exit 1' ERR

main "$@"
