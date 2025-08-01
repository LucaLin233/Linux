#!/bin/bash
# 系统优化模块 v4.3 - 新增 Chrony 时间同步
# 功能: Zram配置、时区设置、时间同步
# 统一代码风格，简化交互逻辑

set -euo pipefail

# === 常量定义 ===
readonly ZRAM_CONFIG="/etc/default/zramswap"
readonly DEFAULT_TIMEZONE="Asia/Shanghai"

# 时区选项数组
readonly TIMEZONES=(
    "Asia/Shanghai:中国标准时间"
    "UTC:协调世界时"
    "Asia/Tokyo:日本时间"
    "Europe/London:伦敦时间"
    "America/New_York:纽约时间"
)

# === 日志函数 ===
log() {
    local msg="$1" level="${2:-info}"
    local -A colors=([info]="\033[0;36m" [warn]="\033[0;33m" [error]="\033[0;31m")
    echo -e "${colors[$level]:-\033[0;32m}$msg\033[0m"
}

# === 辅助函数 ===

# 将各种大小格式转换为MB (修复版)
convert_to_mb() {
    local size="$1"
    
    # 移除所有空格
    size=$(echo "$size" | tr -d ' ')
    
    case "${size^^}" in  # 转大写处理
        *G|*GB)
            # 提取数值部分，支持小数
            local value=$(echo "$size" | sed 's/[^0-9.]//g')
            # 使用awk处理小数运算，更可靠
            echo "$value * 1024" | awk '{printf "%.0f", $1 * $3}'
            ;;
        *M|*MB)
            # 提取数值部分
            local value=$(echo "$size" | sed 's/[^0-9.]//g')
            # 转换为整数
            echo "$value" | awk '{printf "%.0f", $1}'
            ;;
        *K|*KB)
            local value=$(echo "$size" | sed 's/[^0-9.]//g')
            echo "$value / 1024" | awk '{printf "%.0f", $1 / $3}'
            ;;
        *B)
            local value=$(echo "$size" | sed 's/[^0-9.]//g')
            echo "$value / 1024 / 1024" | awk '{printf "%.0f", $1 / $3 / $5}'
            ;;
        *)
            # 纯数字，假设为字节
            echo "$size / 1024 / 1024" | awk '{printf "%.0f", $1 / $3 / $5}'
            ;;
    esac
}

# === 核心函数 ===

# 计算Zram大小 (改进版)
calculate_zram_size() {
    local mem_mb="$1"
    
    if (( mem_mb < 1024 )); then     # <1GB: 2倍内存
        echo "$((mem_mb * 2))M"
    elif (( mem_mb < 2048 )); then   # 1-2GB: 1.5倍内存
        echo "$((mem_mb * 3 / 2))M"
    elif (( mem_mb < 8192 )); then   # 2-8GB: 等于内存
        echo "${mem_mb}M"
    else                             # >8GB: 固定4-8GB
        if (( mem_mb > 16384 )); then
            echo "8G"  # 大于16GB时用8GB
        else
            echo "4G"  # 8-16GB时用4GB
        fi
    fi
}

# 配置Zram (修复交换分区显示和数值转换问题)
setup_zram() {
    log "配置 Zram Swap..." "info"
    
    # 获取内存信息并计算目标Zram大小
    local mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
    local target_zram_size=$(calculate_zram_size "$mem_mb")
    
    log "内存: ${mem_mb}MB, 目标Zram大小: $target_zram_size" "info"
    
    # 显示所有现有交换分区状态
    local all_swap=$(swapon --show | tail -n +2)  # 去掉表头
    if [[ -n "$all_swap" ]]; then
        echo
        log "当前交换状态:" "info"
        swapon --show | sed 's/^/    /'
        echo
    fi
    
    # 检查非zram交换分区并警告
    local non_zram_swap=$(swapon --show | grep -v zram | tail -n +2)
    if [[ -n "$non_zram_swap" ]]; then
        log "⚠️  检测到传统交换分区，建议关闭以避免冲突" "warn"
        read -p "继续配置Zram? [Y/n] (默认: Y): " -r continue_zram </dev/tty >&2
        [[ "$continue_zram" =~ ^[Nn]$ ]] && return 0
    fi
    
    # 检查现有zram并决定是否重新配置
    local current_zram_info=$(swapon --show | grep zram | head -1)
    if [[ -n "$current_zram_info" ]]; then
        local current_size=$(echo "$current_zram_info" | awk '{print $3}')
        log "检测到现有zram: $current_size" "info"
        
        # 转换目标大小为MB（整数）
        local target_mb
        case "$target_zram_size" in
            *G) target_mb=$((${target_zram_size%G} * 1024)) ;;
            *M) target_mb=${target_zram_size%M} ;;
        esac
        
        # 使用修复后的转换函数
        local current_mb=$(convert_to_mb "$current_size")
        
        log "当前大小: ${current_mb}MB, 目标大小: ${target_mb}MB" "info"
        
        # 简单的差异检查（允许5%误差，更严格一些）
        local min_acceptable=$((target_mb * 95 / 100))
        local max_acceptable=$((target_mb * 105 / 100))
        
        if (( current_mb >= min_acceptable && current_mb <= max_acceptable )); then
            log "✓ Zram大小合适 (${current_mb}MB ≈ ${target_mb}MB)，跳过配置" "info"
            return 0
        else
            log "当前${current_mb}MB与目标${target_mb}MB差异较大，重新配置..." "info"
            systemctl stop zramswap.service 2>/dev/null || true
        fi
    fi
    
    # 安装zram-tools
    if ! dpkg -l zram-tools &>/dev/null; then
        log "安装 zram-tools..." "info"
        apt-get update -qq
        apt-get install -y zram-tools
    fi
    
    # 配置zram大小
    if [[ -f "$ZRAM_CONFIG" ]]; then
        # 备份并更新配置
        cp "$ZRAM_CONFIG" "${ZRAM_CONFIG}.bak"
        
        # 转换大小格式: 3921M -> 3921, 4G -> 4096
        local size_mib
        case "$target_zram_size" in
            *G) size_mib=$((${target_zram_size%G} * 1024)) ;;
            *M) size_mib=${target_zram_size%M} ;;
            *) size_mib=$target_zram_size ;;
        esac
        
        # 更新或添加SIZE参数
        if grep -q "^SIZE=" "$ZRAM_CONFIG"; then
            sed -i "s/^SIZE=.*/SIZE=$size_mib/" "$ZRAM_CONFIG"
        elif grep -q "^#SIZE=" "$ZRAM_CONFIG"; then
            sed -i "s/^#SIZE=.*/SIZE=$size_mib/" "$ZRAM_CONFIG"
        else
            echo "SIZE=$size_mib" >> "$ZRAM_CONFIG"
        fi
        
        # 清理错误参数
        sed -i '/^ZRAM_SIZE=/d' "$ZRAM_CONFIG"
        sed -i 's/^PERCENT=/#PERCENT=/' "$ZRAM_CONFIG"
        
    else
        # 创建新配置文件
        local size_mib
        case "$target_zram_size" in
            *G) size_mib=$((${target_zram_size%G} * 1024)) ;;
            *M) size_mib=${target_zram_size%M} ;;
            *) size_mib=$target_zram_size ;;
        esac
        echo "SIZE=$size_mib" > "$ZRAM_CONFIG"
    fi
    
    # 启用并启动服务
    systemctl enable zramswap.service
    systemctl start zramswap.service
    
    # 验证配置
    if systemctl is-active zramswap.service &>/dev/null; then
        sleep 2
        if swapon --show | grep -q zram0; then
            local actual_size=$(swapon --show | grep zram0 | awk '{print $3}')
            log "✓ Zram配置成功，实际大小: $actual_size" "info"
            echo
            log "最终交换状态:" "info"
            swapon --show | sed 's/^/    /'
        else
            log "✗ Zram启动成功但交换设备未激活" "warn"
        fi
    else
        log "✗ Zram配置失败" "error"
        return 1
    fi
}

# 显示时区选项
show_timezone_options() {
    echo >&2
    echo "常用时区选择:" >&2
    
    for i in "${!TIMEZONES[@]}"; do
        local tz_info="${TIMEZONES[$i]}"
        local tz_name="${tz_info%%:*}"
        local tz_desc="${tz_info##*:}"
        echo "  $((i+1))) $tz_name ($tz_desc)" >&2
    done
    
    echo "  6) 自定义时区" >&2
    echo "  7) 保持当前时区" >&2
    echo >&2
}

# 配置时区
setup_timezone() {
    log "配置系统时区..." "info"
    
    if ! command -v timedatectl &>/dev/null; then
        log "timedatectl 不可用，跳过时区配置" "warn"
        return 0
    fi
    
    # 获取当前时区
    local current_tz=$(timedatectl show --property=Timezone --value)
    log "当前时区: $current_tz" "info"
    
    # 显示选项
    show_timezone_options
    
    local choice target_tz
    read -p "请选择时区 [1-7] (默认: 1): " choice </dev/tty >&2
    choice=${choice:-1}
    
    if [[ "$choice" =~ ^[1-5]$ ]]; then
        # 选择预设时区
        local tz_info="${TIMEZONES[$((choice-1))]}"
        target_tz="${tz_info%%:*}"
    elif [[ "$choice" == "6" ]]; then
        # 自定义时区
        while true; do
            read -p "请输入时区 (如: Asia/Shanghai): " target_tz </dev/tty >&2
            if timedatectl list-timezones | grep -q "^$target_tz$"; then
                break
            else
                log "无效时区，请重新输入" "error" >&2
            fi
        done
    elif [[ "$choice" == "7" ]]; then
        # 保持当前时区
        log "保持当前时区: $current_tz" "info"
        return 0
    else
        # 无效选择，使用默认
        log "无效选择，使用默认时区: $DEFAULT_TIMEZONE" "warn"
        target_tz="$DEFAULT_TIMEZONE"
    fi
    
    # 设置时区
    if [[ "$current_tz" != "$target_tz" ]]; then
        timedatectl set-timezone "$target_tz"
        log "✓ 时区已设置为: $target_tz" "info"
        log "  当前时间: $(date)" "info"
    else
        log "时区无需更改" "info"
    fi
}

# 配置 Chrony 时间同步
setup_chrony() {
    log "配置 Chrony 时间同步..." "info"
    
    # 检查是否已安装并正常工作
    if command -v chronyd &>/dev/null && systemctl is-active chronyd &>/dev/null; then
        local sync_status=$(chronyc tracking 2>/dev/null | grep "System clock synchronized" | awk '{print $4}' || echo "Unknown")
        if [[ "$sync_status" == "yes" ]]; then
            log "✓ Chrony 已安装且正常工作，跳过配置" "info"
            return 0
        fi
    fi
    
    # 检查现有时间同步服务
    local conflicting_services=()
    if systemctl is-active systemd-timesyncd &>/dev/null; then
        conflicting_services+=("systemd-timesyncd")
    fi
    if command -v ntpd &>/dev/null && systemctl is-active ntp &>/dev/null; then
        conflicting_services+=("ntp")
    fi
    
    if (( ${#conflicting_services[@]} > 0 )); then
        log "检测到现有时间同步服务: ${conflicting_services[*]}" "warn"
        read -p "安装 Chrony 将停用这些服务，继续? [Y/n] (默认: Y): " -r continue_chrony </dev/tty >&2
        [[ "$continue_chrony" =~ ^[Nn]$ ]] && return 0
    fi
    
    # 安装 chrony
    log "安装 Chrony..." "info"
    if ! apt-get update -qq || ! apt-get install -y chrony; then
        log "✗ Chrony 安装失败" "error"
        return 1
    fi
    
    # 停用冲突服务
    for service in "${conflicting_services[@]}"; do
        log "停用服务: $service" "info"
        systemctl stop "$service" 2>/dev/null || true
        systemctl disable "$service" 2>/dev/null || true
    done
    
    # 启用并启动 chronyd
    systemctl enable chronyd
    systemctl start chronyd
    
    # 等待服务稳定
    sleep 3
    
    # 验证安装
    if systemctl is-active chronyd &>/dev/null; then
        # 检查同步状态（可能需要几分钟）
        local sync_check=0
        local max_attempts=5
        
        while (( sync_check < max_attempts )); do
            if chronyc tracking &>/dev/null; then
                local sources_count=$(chronyc sources 2>/dev/null | grep -c "^\^" || echo "0")
                if (( sources_count > 0 )); then
                    log "✓ Chrony 配置成功，发现 $sources_count 个时间源" "info"
                    log "  同步状态: $(chronyc tracking 2>/dev/null | grep "System clock synchronized" | cut -d: -f2 | xargs || echo "检查中...")" "info"
                    break
                fi
            fi
            sync_check=$((sync_check + 1))
            if (( sync_check < max_attempts )); then
                log "等待 Chrony 同步... ($sync_check/$max_attempts)" "info"
                sleep 2
            fi
        done
        
        if (( sync_check >= max_attempts )); then
            log "⚠️  Chrony 已启动但同步状态未确认，可能需要更多时间" "warn"
        fi
    else
        log "✗ Chrony 服务启动失败" "error"
        return 1
    fi
}

# 显示系统信息
show_system_info() {
    local mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
    
    log "系统信息:" "info"
    log "  内存: ${mem_mb}MB" "info" 
    log "  CPU核心: $(nproc)" "info"
    log "  内核: $(uname -r)" "info"
}

# 显示优化摘要
show_optimization_summary() {
    echo
    log "🎯 系统优化摘要:" "info"
    
    # Zram状态
    if systemctl is-active zramswap.service &>/dev/null; then
        local zram_info=$(swapon --show | grep zram | awk '{print $3}' | head -1)
        log "  ✓ Zram: ${zram_info:-已启用}" "info"
    else
        log "  ✗ Zram: 未配置" "info"
    fi
    
    # 时区状态
    local current_tz=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "未知")
    log "  ✓ 时区: $current_tz" "info"
    
    # Chrony 状态
    if systemctl is-active chronyd &>/dev/null; then
        local sync_status=$(timedatectl show --property=NTPSynchronized --value 2>/dev/null || echo "unknown")
        if [[ "$sync_status" == "yes" ]]; then
            log "  ✓ 时间同步: Chrony (已同步)" "info"
        else
            log "  ⏳ 时间同步: Chrony (同步中...)" "info"
        fi
    else
        log "  ✗ 时间同步: 未配置" "info"
    fi
    
    # 内存和交换使用情况
    local mem_usage=$(free -h | awk '/^Mem:/ {printf "使用:%s/%s", $3, $2}')
    log "  📊 内存: $mem_usage" "info"
    
    local swap_usage=$(free -h | awk '/^Swap:/ {printf "使用:%s/%s", $3, $2}')
    if [[ "$swap_usage" != "使用:0B/0B" ]]; then
        log "  💾 交换: $swap_usage" "info"
    fi
}

# === 主流程 ===
main() {
    log "🔧 开始系统优化配置..." "info"
    
    echo
    show_system_info
    
    echo
    setup_zram
    
    echo
    setup_timezone
    
    echo
    setup_chrony
    
    show_optimization_summary
    
    echo
    log "🎉 系统优化配置完成!" "info"
}

main "$@"
