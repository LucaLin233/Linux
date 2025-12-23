#!/bin/bash
# 系统优化模块 v6.1 - systemd-zram-generator版 - 优化版本
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
    
    # debug 级别只在 DEBUG=1 时显示
    if [[ "$level" == "debug" ]] && [[ "${DEBUG:-}" != "1" ]]; then
        return 0
    fi
    
    echo -e "${colors[$level]:-\033[0;32m}$msg\033[0m" >&2
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
    
    local swap_info=$(swapon --show 2>/dev/null | tail -n +2)
    if [[ -z "$swap_info" ]]; then
        echo "Swap状态: 无活动设备"
        return
    fi
    
    echo "Swap状态:"
    echo "$swap_info" | while read -r device _ size used priority; do
        [[ -z "$device" ]] && continue
        local type=$([[ "$device" == *"zram"* ]] && echo "Zram" || echo "磁盘")
        echo "  - $type: $device ($size, 已用$used, 优先级$priority)"
    done
}

# 彻底清理zram配置
cleanup_zram_completely() {
    log "清理zram配置" "debug"
    
    # 停止所有相关服务
    for service in systemd-zram-setup@zram0 zramswap; do
        systemctl stop "$service.service" 2>/dev/null || true
        systemctl disable "$service.service" 2>/dev/null || true
    done
    
    # 关闭并重置所有zram设备
    for dev in /dev/zram*; do
        [[ -b "$dev" ]] || continue
        swapoff "$dev" 2>/dev/null || true
        echo 1 > "/sys/block/$(basename "$dev")/reset" 2>/dev/null || true
        log "重置设备: $dev" "debug"
    done
    
    modprobe -r zram 2>/dev/null || true
    sleep 2
    log "zram清理完成" "debug"
}

# === 核心功能函数 ===
# 获取最优zram配置
get_optimal_zram_config() {
    local mem_mb="$1"
    
    log "计算zram配置，内存: ${mem_mb}MB" "debug"
    
    local zram_ratio swappiness
    
    # 根据内存大小确定zram比例和swappiness
    if (( mem_mb <= 512 )); then
        zram_ratio="ram * 2.5"
        swappiness=50
    elif (( mem_mb <= 1024 )); then
        zram_ratio="ram * 2"
        swappiness=60
    elif (( mem_mb <= 2048 )); then
        zram_ratio="ram * 1.2"
        swappiness=70
    elif (( mem_mb <= 4096 )); then
        zram_ratio="ram * 0.8"
        swappiness=80
    else
        zram_ratio="ram / 2"
        swappiness=90
    fi
    
    echo "$zram_ratio,$swappiness"
}

# 设置系统参数
set_system_parameters() {
    local swappiness="$1"
    
    log "设置系统参数: swappiness=$swappiness" "debug"
    
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
        log "sysctl配置已应用" "debug"
    else
        log "sysctl应用失败，使用运行时设置" "debug"
        
        # 运行时设置
        echo "$swappiness" > /proc/sys/vm/swappiness 2>/dev/null || true
        echo "0" > /proc/sys/vm/page-cluster 2>/dev/null || true
        [[ -f /sys/module/zswap/parameters/enabled ]] && \
            echo "0" > /sys/module/zswap/parameters/enabled 2>/dev/null || true
    fi
}

# 配置systemd-zram
setup_systemd_zram() {
    local zram_size="$1"
    local swappiness="$2"
    
    log "配置systemd-zram: $zram_size, swappiness=$swappiness" "debug"
    
    # 确保安装了systemd-zram-generator
    if ! dpkg -l systemd-zram-generator &>/dev/null; then
        log "安装systemd-zram-generator" "debug"
        DEBIAN_FRONTEND=noninteractive apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y systemd-zram-generator >/dev/null 2>&1 || {
            log "systemd-zram-generator安装失败" "error"
            return 1
        }
        systemctl daemon-reload
    fi
    
    # 移除旧的zram-tools（如果存在）
    if dpkg -l zram-tools &>/dev/null; then
        log "移除旧的zram-tools" "debug"
        DEBIAN_FRONTEND=noninteractive apt-get remove --purge -y zram-tools >/dev/null 2>&1 || true
    fi
    
    # 创建zram配置文件
    cat > "$ZRAM_CONFIG" << EOF
# Zram配置 - 由系统优化脚本自动生成
[zram0]
zram-size = $zram_size
compression-algorithm = zstd
EOF
    
    log "zram配置文件已创建" "debug"
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
        log "zram配置成功: $actual_size" "debug"
        return 0
    else
        log "zram验证失败" "error"
        return 1
    fi
}

# 检查现有配置是否匹配
check_current_zram_config() {
    local target_size="$1" target_swappiness="$2"
    
    systemctl is-active systemd-zram-setup@zram0.service &>/dev/null || return 1
    [[ -f "$ZRAM_CONFIG" ]] || return 1
    
    local current_size=$(awk -F= '/zram-size/{gsub(/[[:space:]]/, "", $2); print $2}' "$ZRAM_CONFIG")
    local current_swappiness=$(cat /proc/sys/vm/swappiness 2>/dev/null)
    
    log "当前配置: size=$current_size, swappiness=$current_swappiness" "debug"
    log "目标配置: size=$target_size, swappiness=$target_swappiness" "debug"
    
    [[ "$current_size" == "$target_size" ]] && [[ "$current_swappiness" == "$target_swappiness" ]]
}

# 主要的zram配置函数
setup_zram() {
    local mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
    local mem_display=$(format_size "$mem_mb")
    
    echo "检测到: ${mem_display}内存"
    
    # 获取最优配置
    local config=$(get_optimal_zram_config "$mem_mb")
    local zram_size=$(echo "$config" | cut -d, -f1)
    local swappiness=$(echo "$config" | cut -d, -f2)
    
    log "目标配置: zram_size=$zram_size, swappiness=$swappiness" "debug"
    
    # 检查现有配置是否匹配
    if check_current_zram_config "$zram_size" "$swappiness"; then
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

# 配置时区
setup_timezone() {
    local current_tz=$(timedatectl show --property=Timezone --value 2>/dev/null)
    
    # 时区映射
    local -A tz_map=(
        [1]="Asia/Shanghai"
        [2]="UTC"
        [3]="Asia/Tokyo"
        [4]="Europe/London"
        [5]="America/New_York"
    )
    
    read -p "时区设置 [1=上海 2=UTC 3=东京 4=伦敦 5=纽约 6=自定义 7=保持当前] (默认1): " choice </dev/tty >&2
    choice=${choice:-1}
    
    local target_tz
    case "$choice" in
        [1-5])
            target_tz="${tz_map[$choice]}"
            ;;
        6)
            read -p "输入时区 (如: Asia/Shanghai，默认Asia/Shanghai): " target_tz </dev/tty >&2
            target_tz=${target_tz:-Asia/Shanghai}
            if ! timedatectl list-timezones | grep -q "^$target_tz$"; then
                log "无效时区，使用默认上海时区" "warn"
                target_tz="Asia/Shanghai"
            fi
            ;;
        7)
            echo "时区: $current_tz (保持不变)"
            return 0
            ;;
        *)
            log "无效选择，使用默认上海时区" "warn"
            target_tz="Asia/Shanghai"
            ;;
    esac
    
    if [[ "$current_tz" != "$target_tz" ]]; then
        timedatectl set-timezone "$target_tz" || {
            log "设置时区失败" "error"
            return 1
        }
    fi
    
    echo "时区: $target_tz"
}

# 配置Chrony
setup_chrony() {
    # 检查现有状态
    if systemctl is-active chrony &>/dev/null; then
        local sync_status=$(chronyc tracking 2>/dev/null | awk '/System clock synchronized/{print $4}')
        if [[ "$sync_status" == "yes" ]]; then
            echo "时间同步: Chrony (已同步)"
            return 0
        fi
    fi
    
    # 停用冲突服务并安装
    systemctl stop systemd-timesyncd 2>/dev/null || true
    systemctl disable systemd-timesyncd 2>/dev/null || true
    
    if ! command -v chronyd &>/dev/null; then
        apt-get install -y chrony >/dev/null 2>&1 || {
            log "Chrony安装失败" "error"
            return 1
        }
    fi
    
    systemctl enable --now chrony >/dev/null 2>&1 || true
    sleep 2
    
    if systemctl is-active chrony &>/dev/null; then
        local sources=$(chronyc sources 2>/dev/null | grep -c "^\^" || echo "0")
        echo "时间同步: Chrony (${sources}个时间源)"
    else
        log "Chrony启动失败" "error"
        return 1
    fi
}

# 等待包管理器释放
wait_for_apt() {
    local max_wait=60
    local waited=0
    
    while ! timeout 10s apt-get update -qq 2>/dev/null; do
        if (( waited == 0 )); then
            log "等待包管理器释放..." "warn"
        fi
        
        if (( waited >= max_wait )); then
            log "包管理器锁定超时，请检查是否有其他apt进程运行" "error"
            return 1
        fi
        
        sleep 10
        waited=$((waited + 10))
    done
}

# === 主流程 ===
main() {
    # 检查root权限
    [[ $EUID -eq 0 ]] || {
        log "需要root权限运行" "error"
        exit 1
    }
    
    # 等待包管理器释放
    wait_for_apt || exit 1
    
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
