#!/bin/bash
# 系统优化模块 v6.0 - systemd-zram-generator版 - 现代化版本
# 功能: 智能Zram配置、时区设置、时间同步

set -euo pipefail

# === 常量定义 ===
readonly ZRAM_CONFIG="/etc/systemd/zram-generator.conf"
readonly SYSCTL_CONFIG="/etc/sysctl.d/99-zram.conf"
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
    
    local swap_output=$(swapon --show 2>/dev/null | tail -n +2)
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

# 彻底清理zram配置 - systemd版本
cleanup_zram_completely() {
    debug_log "开始彻底清理zram"
    
    # 停止systemd-zram服务
    systemctl stop systemd-zram-setup@zram0.service 2>/dev/null || true
    
    # 停止旧的zram-tools服务（如果存在）
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
    
    # 等待设备完全清理
    sleep 2
    debug_log "zram清理完成"
}

# === 核心功能函数 ===
# 获取最优zram配置 - 简化版
get_optimal_zram_config() {
    local mem_mb="$1"
    
    debug_log "计算zram配置，内存: ${mem_mb}MB"
    
    local zram_ratio swappiness
    
    # 根据内存大小确定zram比例和swappiness
    if (( mem_mb <= 512 )); then
        zram_ratio="ram * 2.5"
        swappiness=50  # 极小内存保守点
    elif (( mem_mb <= 1024 )); then
        zram_ratio="ram * 2"
        swappiness=60  # 小内存适中
    elif (( mem_mb <= 2048 )); then
        zram_ratio="ram * 1.2"
        swappiness=70  # 中等内存积极
    elif (( mem_mb <= 4096 )); then
        zram_ratio="ram * 0.8"   
        swappiness=80  # 高内存很积极
    else
        zram_ratio="ram / 2"
        swappiness=90  # 旗舰配置最积极
    fi
    
    echo "$zram_ratio,$swappiness"
}

# 设置系统参数 - 简化版
set_system_parameters() {
    local swappiness="$1"
    
    debug_log "设置系统参数: swappiness=$swappiness"
    
    # 创建sysctl配置文件
    cat > "$SYSCTL_CONFIG" << EOF
# Zram优化配置 - 由系统优化脚本自动生成
vm.swappiness = $swappiness
# 优化页面集群，提高zram效率
vm.page-cluster = 0
# 禁用zswap避免与zram冲突  
kernel.zswap.enabled = 0
EOF
    
    # 应用配置
    if sysctl -p "$SYSCTL_CONFIG" >/dev/null 2>&1; then
        debug_log "sysctl配置已应用"
    else
        debug_log "sysctl应用失败，使用运行时设置"
        
        # 运行时设置
        echo "$swappiness" > /proc/sys/vm/swappiness 2>/dev/null || true
        echo "0" > /proc/sys/vm/page-cluster 2>/dev/null || true
        [[ -f /sys/module/zswap/parameters/enabled ]] && 
            echo "0" > /sys/module/zswap/parameters/enabled 2>/dev/null || true
    fi
}

# 配置systemd-zram - 统一函数
setup_systemd_zram() {
    local zram_size="$1"
    local swappiness="$2"
    
    debug_log "配置systemd-zram: $zram_size, swappiness=$swappiness"
    
    # 确保安装了systemd-zram-generator
    if ! dpkg -l systemd-zram-generator &>/dev/null; then
        debug_log "安装systemd-zram-generator"
        DEBIAN_FRONTEND=noninteractive apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y systemd-zram-generator >/dev/null 2>&1 || {
            log "systemd-zram-generator安装失败" "error"
            return 1
        }
        systemctl daemon-reload
    fi
    
    # 移除旧的zram-tools（如果存在）
    if dpkg -l zram-tools &>/dev/null; then
        debug_log "移除旧的zram-tools"
        DEBIAN_FRONTEND=noninteractive apt-get remove --purge -y zram-tools >/dev/null 2>&1 || true
    fi
    
    # 创建zram配置文件
    cat > "$ZRAM_CONFIG" << EOF
# Zram配置 - 由系统优化脚本自动生成
[zram0]
zram-size = $zram_size
compression-algorithm = zstd
EOF
    
    debug_log "zram配置文件已创建"
    [[ "${DEBUG:-}" == "1" ]] && cat "$ZRAM_CONFIG" >&2
    
    # 设置系统参数
    set_system_parameters "$swappiness"
    
    # 重新加载systemd配置
    systemctl daemon-reload
    
    # 启动zram服务
    if ! systemctl start systemd-zram-setup@zram0.service >/dev/null 2>&1; then
        log "启动systemd-zram服务失败" "error"
        return 1
    fi
    
    # 等待服务启动
    sleep 3
    
    # 验证配置
    if [[ -b /dev/zram0 ]] && swapon --show 2>/dev/null | grep -q zram0; then
        local zram_info=$(swapon --show 2>/dev/null | grep zram0)
        local actual_size=$(echo "$zram_info" | awk '{print $3}')
        debug_log "zram配置成功: $actual_size"
        return 0
    else
        log "zram验证失败" "error"
        return 1
    fi
}

# 检查现有配置是否匹配
check_current_zram_config() {
    local target_size="$1"
    local target_swappiness="$2"
    
    # 检查是否已有合适的zram配置
    if systemctl is-active systemd-zram-setup@zram0.service &>/dev/null; then
        # 检查配置文件
        if [[ -f "$ZRAM_CONFIG" ]]; then
            local current_size=$(grep "zram-size.*=" "$ZRAM_CONFIG" 2>/dev/null | cut -d= -f2 | tr -d ' ')
            local current_swappiness=$(cat /proc/sys/vm/swappiness 2>/dev/null)
            
            debug_log "当前配置: size=$current_size, swappiness=$current_swappiness"
            debug_log "目标配置: size=$target_size, swappiness=$target_swappiness"
            
            # 简单的字符串比较（对于这个用例足够了）
            if [[ "$current_size" == "$target_size" ]] && 
               [[ "$current_swappiness" == "$target_swappiness" ]]; then
                return 0  # 配置匹配
            fi
        fi
    fi
    
    return 1  # 需要重新配置
}

# 主要的zram配置函数 - 重构版
setup_zram() {
    local mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
    local mem_display=$(format_size "$mem_mb")
    
    echo "检测到: ${mem_display}内存"
    
    # 获取最优配置
    local config=$(get_optimal_zram_config "$mem_mb")
    local zram_size=$(echo "$config" | cut -d, -f1)
    local swappiness=$(echo "$config" | cut -d, -f2)
    
    debug_log "目标配置: zram_size=$zram_size, swappiness=$swappiness"
    
    # 检查现有配置是否匹配
    if check_current_zram_config "$zram_size" "$swappiness"; then
        # 配置匹配，只需要确保优先级正确
        if swapon --show 2>/dev/null | grep -q zram0; then
            local current_info=$(swapon --show 2>/dev/null | grep zram0)
            local current_size=$(echo "$current_info" | awk '{print $3}')
            local priority=$(echo "$current_info" | awk '{print $5}')
            
            echo "Zram: $current_size (zstd, 优先级$priority, 已配置)"
            show_swap_status
            return 0
        fi
    fi
    
    # 需要重新配置
    echo "配置Zram..."
    cleanup_zram_completely
    
    # 配置新的zram
    if setup_systemd_zram "$zram_size" "$swappiness"; then
        # 获取实际配置信息显示
        local zram_info=$(swapon --show 2>/dev/null | grep zram0)
        local actual_size=$(echo "$zram_info" | awk '{print $3}')
        local priority=$(echo "$zram_info" | awk '{print $5}')
        
        echo "Zram: $actual_size (zstd, 优先级$priority)"
        show_swap_status
    else
        log "Zram配置失败" "error"
        return 1
    fi
}

# 配置时区 - 保持原有实现
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

# 配置Chrony - 保持原有实现
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
    
    # 检查必要命令
    for cmd in awk swapon systemctl; do
        command -v "$cmd" &>/dev/null || {
            log "缺少必要命令: $cmd" "error"
            exit 1
        }
    done
    
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
