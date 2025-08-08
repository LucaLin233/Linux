#!/bin/bash
# 系统优化模块 v4.4 - 简化版
# 功能: Zram配置、时区设置、时间同步

set -euo pipefail

# === 常量定义 ===
readonly ZRAM_CONFIG="/etc/default/zramswap"
readonly DEFAULT_TIMEZONE="Asia/Shanghai"

# === 日志函数 ===
log() {
    local msg="$1" level="${2:-info}"
    local -A colors=([info]="\033[0;36m" [warn]="\033[0;33m" [error]="\033[0;31m")
    echo -e "${colors[$level]:-\033[0;32m}$msg\033[0m"
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

# 计算Zram大小 - 更保守的配置
calculate_zram_size() {
    local mem_mb="$1"
    
    if (( mem_mb < 1024 )); then     # <1GB: 1.5倍
        echo "$((mem_mb * 3 / 2))M"
    elif (( mem_mb < 2048 )); then   # 1-2GB: 1倍
        echo "${mem_mb}M"
    elif (( mem_mb < 8192 )); then   # 2-8GB: 0.5倍
        echo "$((mem_mb / 2))M"
    else                             # >8GB: 固定2GB
        echo "2G"
    fi
}

# 配置Zram - 简化版
setup_zram() {
    local mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
    local target_zram_size=$(calculate_zram_size "$mem_mb")
    
    # 检查现有zram
    local current_zram_info=$(swapon --show | grep zram | head -1)
    if [[ -n "$current_zram_info" ]]; then
        local current_size=$(echo "$current_zram_info" | awk '{print $3}')
        
        # 转换并比较大小
        local target_mb
        case "$target_zram_size" in
            *G) target_mb=$((${target_zram_size%G} * 1024)) ;;
            *M) target_mb=${target_zram_size%M} ;;
        esac
        
        local current_mb=$(convert_to_mb "$current_size")
        local min_acceptable=$((target_mb * 90 / 100))
        local max_acceptable=$((target_mb * 110 / 100))
        
        if (( current_mb >= min_acceptable && current_mb <= max_acceptable )); then
            echo "Zram: $current_size (无需调整)"
            return 0
        fi
        
        systemctl stop zramswap.service 2>/dev/null || true
    fi
    
    # 安装并配置zram
    if ! dpkg -l zram-tools &>/dev/null; then
        apt-get update -qq && apt-get install -y zram-tools >/dev/null
    fi
    
    # 配置大小
    local size_mib
    case "$target_zram_size" in
        *G) size_mib=$((${target_zram_size%G} * 1024)) ;;
        *M) size_mib=${target_zram_size%M} ;;
    esac
    
    if [[ -f "$ZRAM_CONFIG" ]]; then
        cp "$ZRAM_CONFIG" "${ZRAM_CONFIG}.bak"
        if grep -q "^SIZE=" "$ZRAM_CONFIG"; then
            sed -i "s/^SIZE=.*/SIZE=$size_mib/" "$ZRAM_CONFIG"
        else
            echo "SIZE=$size_mib" >> "$ZRAM_CONFIG"
        fi
    else
        echo "SIZE=$size_mib" > "$ZRAM_CONFIG"
    fi
    
    systemctl enable zramswap.service >/dev/null
    systemctl start zramswap.service
    
    sleep 2
    if swapon --show | grep -q zram0; then
        local actual_size=$(swapon --show | grep zram0 | awk '{print $3}')
        echo "Zram: $actual_size (已配置)"
    else
        log "Zram配置失败" "error"
        return 1
    fi
}

# 配置时区 - 简化版
setup_timezone() {
    local current_tz=$(timedatectl show --property=Timezone --value 2>/dev/null)
    
    # 直接提示，不显示选项菜单
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
        timedatectl set-timezone "$target_tz"
    fi
    
    echo "时区: $target_tz"
}

# 配置Chrony - 简化版
setup_chrony() {
    # 快速检查是否已配置
    if command -v chronyd &>/dev/null && systemctl is-active chrony &>/dev/null 2>&1; then
        local sync_status=$(chronyc tracking 2>/dev/null | grep "System clock synchronized" | awk '{print $4}' 2>/dev/null || echo "no")
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
        if ! apt-get install -y chrony >/dev/null 2>&1; then
            log "Chrony安装失败" "error"
            return 1
        fi
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
    log "🔧 系统优化配置..." "info"
    
    echo
    setup_zram
    
    echo
    setup_timezone
    
    echo  
    setup_chrony
    
    echo
    log "✅ 优化完成" "info"
}

main "$@"
