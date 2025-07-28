#!/bin/bash
# 系统优化模块 v4.0
# 功能: Zram配置、时区设置
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

# === 核心函数 ===

# 计算Zram大小
calculate_zram_size() {
    local mem_mb="$1"
    
    if (( mem_mb > 4096 )); then      # >4GB: 固定2GB
        echo "2G"
    elif (( mem_mb > 2048 )); then   # 2-4GB: 固定1GB  
        echo "1G"
    elif (( mem_mb > 1024 )); then   # 1-2GB: 内存大小
        echo "${mem_mb}M"
    else                             # <1GB: 2倍内存
        echo "$((mem_mb * 2))M"
    fi
}

# 配置Zram
setup_zram() {
    log "配置 Zram Swap..." "info"
    
    # 检查是否已有交换分区
    if swapon --show | grep -v zram | grep -q .; then
        echo
        log "检测到现有交换分区:" "warn"
        swapon --show | grep -v zram
        echo
        read -p "继续配置Zram? [Y/n] (默认: Y): " -r continue_zram
        [[ "$continue_zram" =~ ^[Nn]$ ]] && return 0
    fi
    
    # 获取内存信息并计算Zram大小
    local mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
    local zram_size=$(calculate_zram_size "$mem_mb")
    
    # 检查是否已有合适大小的zram
    if swapon --show | grep -q zram; then
        local current_zram_size=$(swapon --show | grep zram | awk '{print $3}' | head -1)
        log "检测到现有zram: $current_zram_size" "info"
        
        # 简单的大小比较（如果当前大小合理就跳过）
        if [[ "$current_zram_size" =~ [0-9.]+G ]] && [[ "$zram_size" =~ [0-9]+G ]]; then
            log "Zram大小已合适，跳过配置" "info"
            return 0
        elif [[ "$current_zram_size" =~ [0-9.]+G ]] && [[ "$zram_size" =~ [0-9]+M ]]; then
            # 当前是G级别，目标是M级别，需要重配
            :
        else
            # 其他情况简单检查数值
            local current_num=$(echo "$current_zram_size" | grep -o '[0-9.]*')
            local target_num=$(echo "$zram_size" | grep -o '[0-9]*')
            if (( $(echo "$current_num >= $target_num * 0.9" | bc -l 2>/dev/null || echo 0) )); then
                log "Zram大小已合适，跳过配置" "info"
                return 0
            fi
        fi
    fi
    
    log "内存: ${mem_mb}MB, 建议Zram大小: $zram_size" "info"
    
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
        # 备份并更新配置
        cp "$ZRAM_CONFIG" "${ZRAM_CONFIG}.bak"
        
        # 转换大小格式: 1920M -> 1920, 2G -> 2048
        local size_mib
        case "$zram_size" in
            *G) size_mib=$((${zram_size%G} * 1024)) ;;
            *M) size_mib=${zram_size%M} ;;
            *) size_mib=$zram_size ;;
        esac
        
        # 更新或添加SIZE参数
        if grep -q "^SIZE=" "$ZRAM_CONFIG"; then
            sed -i "s/^SIZE=.*/SIZE=$size_mib/" "$ZRAM_CONFIG"
        elif grep -q "^#SIZE=" "$ZRAM_CONFIG"; then
            sed -i "s/^#SIZE=.*/SIZE=$size_mib/" "$ZRAM_CONFIG"
        else
            echo "SIZE=$size_mib" >> "$ZRAM_CONFIG"
        fi
        
        # 移除错误的 ZRAM_SIZE 参数（如果存在）
        sed -i '/^ZRAM_SIZE=/d' "$ZRAM_CONFIG"
        
        # 确保注释掉PERCENT参数，避免覆盖SIZE
        sed -i 's/^PERCENT=/#PERCENT=/' "$ZRAM_CONFIG"
        
    else
        # 创建新配置文件
        local size_mib
        case "$zram_size" in
            *G) size_mib=$((${zram_size%G} * 1024)) ;;
            *M) size_mib=${zram_size%M} ;;
            *) size_mib=$zram_size ;;
        esac
        echo "SIZE=$size_mib" > "$ZRAM_CONFIG"
    fi
    
    # 启用并启动服务
    systemctl enable zramswap.service
    systemctl start zramswap.service
    
    # 验证配置
    if systemctl is-active zramswap.service &>/dev/null; then
        # 等待一下让服务完全启动
        sleep 1
        
        if swapon --show | grep -q zram0; then
            local actual_size=$(swapon --show | grep zram0 | awk '{print $3}')
            log "✓ Zram配置成功，实际大小: $actual_size" "info"
            log "  当前交换状态:" "info"
            swapon --show | sed 's/^/    /'
        else
            log "✗ Zram启动成功但交换设备未激活" "warn"
            systemctl status zramswap.service --no-pager -l
        fi
    else
        log "✗ Zram配置失败" "error"
        systemctl status zramswap.service --no-pager -l
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
    
    show_optimization_summary
    
    echo
    log "🎉 系统优化配置完成!" "info"
}

main "$@"
