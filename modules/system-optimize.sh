#!/usr/bin/env bash
# 系统优化模块
# 功能：智能 Zram 配置、时区设置、Chrony 时间同步

set -euo pipefail

# === 常量定义 ===
readonly ZRAM_CONFIG="/etc/systemd/zram-generator.conf"
readonly SYSCTL_CONFIG="/etc/sysctl.d/99-zram.conf"
readonly DEFAULT_TIMEZONE="Asia/Shanghai"
readonly APT_LOCK_TIMEOUT=120
readonly APT_LOCK_INTERVAL=5

# === 日志函数 ===
log() {
    local msg="$1"
    local level="${2:-info}"
    local -A colors=(
        [info]="\033[0;36m"
        [warn]="\033[0;33m"
        [error]="\033[0;31m"
        [debug]="\033[0;35m"
    )

    if [[ "$level" == "debug" && "${DEBUG:-}" != "1" ]]; then
        return 0
    fi

    echo -e "${colors[$level]:-\033[0;32m}${msg}\033[0m" >&2
}

# === APT 锁处理 ===
wait_for_apt() {
    local waited=0
    local lock_files=(
        /var/lib/dpkg/lock-frontend
        /var/lib/dpkg/lock
        /var/lib/apt/lists/lock
        /var/cache/apt/archives/lock
    )

    while fuser "${lock_files[@]}" >/dev/null 2>&1; do
        if (( waited >= APT_LOCK_TIMEOUT )); then
            log "APT/dpkg 被占用超过 ${APT_LOCK_TIMEOUT} 秒，请等待其他软件包操作完成后重试" "error"
            return 1
        fi

        if (( waited == 0 )); then
            log "等待 APT/dpkg 锁释放..." "warn"
        fi

        sleep "$APT_LOCK_INTERVAL"
        ((waited += APT_LOCK_INTERVAL))
    done
}

# === Swap / Zram 状态 ===
show_swap_status() {
    local swappiness
    local swap_info

    swappiness=$(cat /proc/sys/vm/swappiness 2>/dev/null || echo "unknown")
    echo "Swap 配置: swappiness=$swappiness"

    swap_info=$(swapon --noheadings --show 2>/dev/null || true)

    if [[ -z "$swap_info" ]]; then
        echo "Swap 状态: 无活动设备"
        return 0
    fi

    echo "Swap 状态:"

    while read -r device type size used priority; do
        [[ -z "$device" ]] && continue

        local display_type="磁盘"
        [[ "$device" == *"/zram"* ]] && display_type="Zram"

        echo "  - $display_type: $device ($size，已用 $used，优先级 $priority)"
    done <<< "$swap_info"
}

get_zram_used_bytes() {
    swapon --noheadings --bytes --output=NAME,USED 2>/dev/null |
        awk '$1 == "/dev/zram0" {print $2; exit}'
}

get_zram_size() {
    swapon --noheadings --output=NAME,SIZE 2>/dev/null |
        awk '$1 == "/dev/zram0" {print $2; exit}'
}

is_zram_active() {
    systemctl is-active --quiet systemd-zram-setup@zram0.service &&
        [[ -b /dev/zram0 ]] &&
        swapon --noheadings --output=NAME 2>/dev/null |
            awk '$1 == "/dev/zram0" {found=1} END {exit !found}'
}

# === Zram 配置 ===
get_optimal_zram_config() {
    local mem_mb="$1"
    local zram_size
    local swappiness

    # 小内存优先避免 OOM；大内存则减少不必要的压缩和换页。
    if (( mem_mb <= 512 )); then
        zram_size="ram * 2"
        swappiness=60
    elif (( mem_mb <= 1024 )); then
        zram_size="ram * 1.5"
        swappiness=60
    elif (( mem_mb <= 4096 )); then
        zram_size="ram"
        swappiness=40
    else
        zram_size="ram / 2"
        swappiness=20
    fi

    echo "${zram_size},${swappiness}"
}

write_zram_config() {
    local zram_size="$1"
    local swappiness="$2"

    cat > "$ZRAM_CONFIG" <<EOF
# Zram 配置：由 system-optimize.sh 自动生成
[zram0]
zram-size = ${zram_size}
compression-algorithm = zstd
EOF

    cat > "$SYSCTL_CONFIG" <<EOF
# Zram 相关内核参数：由 system-optimize.sh 自动生成
vm.swappiness = ${swappiness}
vm.page-cluster = 0
EOF

    # 部分内核不存在 kernel.zswap.enabled。
    # 仅在参数存在时禁用 zswap，避免整份 sysctl 配置应用失败。
    if [[ -e /proc/sys/kernel/zswap/enabled ]]; then
        echo "kernel.zswap.enabled = 0" >> "$SYSCTL_CONFIG"
    fi
}

apply_zram_sysctl() {
    if ! sysctl -p "$SYSCTL_CONFIG" >/dev/null 2>&1; then
        log "无法立即应用 Zram sysctl 配置，重启后会自动生效" "warn"
        return 1
    fi
}

get_zram_config_value() {
    local key="$1"

    [[ -f "$ZRAM_CONFIG" ]] || return 1

    awk -F= -v key="$key" '
        $1 ~ "^[[:space:]]*" key "[[:space:]]*$" {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
            print $2
            exit
        }
    ' "$ZRAM_CONFIG"
}

get_zram_swappiness() {
    [[ -f "$SYSCTL_CONFIG" ]] || return 1

    awk -F= '
        $1 ~ /^[[:space:]]*vm\.swappiness[[:space:]]*$/ {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
            print $2
            exit
        }
    ' "$SYSCTL_CONFIG"
}

zram_config_matches() {
    local target_size="$1"
    local target_swappiness="$2"
    local current_size
    local current_swappiness

    is_zram_active || return 1

    current_size=$(get_zram_config_value "zram-size" || true)
    current_swappiness=$(get_zram_swappiness || true)

    [[ "$current_size" == "$target_size" ]] &&
        [[ "$current_swappiness" == "$target_swappiness" ]]
}

install_zram_generator() {
    if dpkg-query -W -f='${db:Status-Status}' systemd-zram-generator 2>/dev/null |
        grep -qx "installed"; then
        return 0
    fi

    log "安装 systemd-zram-generator..." "info"

    if ! apt-get install -y systemd-zram-generator; then
        log "systemd-zram-generator 安装失败" "error"
        return 1
    fi
}

start_zram() {
    systemctl daemon-reload

    if ! systemctl start systemd-zram-setup@zram0.service; then
        log "systemd-zram-setup@zram0 服务启动失败" "error"
        return 1
    fi

    sleep 2

    if ! is_zram_active; then
        log "Zram 服务未正常激活" "error"
        return 1
    fi
}

setup_zram() {
    local mem_mb
    local config
    local zram_size
    local swappiness
    local used_bytes
    local current_size
    local actual_size

    mem_mb=$(awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo)

    if [[ ! "$mem_mb" =~ ^[0-9]+$ ]] || (( mem_mb <= 0 )); then
        log "无法获取系统内存大小，跳过 Zram 配置" "error"
        return 1
    fi

    config=$(get_optimal_zram_config "$mem_mb")
    zram_size="${config%,*}"
    swappiness="${config#*,}"

    echo "检测到内存: ${mem_mb}MB"
    echo "目标 Zram: ${zram_size}，swappiness=${swappiness}"

    if zram_config_matches "$zram_size" "$swappiness"; then
        current_size=$(get_zram_size)
        echo "Zram: ${current_size:-已启用}（配置无需变更）"
        show_swap_status
        return 0
    fi

    install_zram_generator || return 1

    used_bytes=$(get_zram_used_bytes)
    used_bytes="${used_bytes:-0}"

    write_zram_config "$zram_size" "$swappiness"
    apply_zram_sysctl || true
    systemctl daemon-reload

    # Zram 已有交换页时不强制 swapoff，避免低内存机器触发 OOM。
    if is_zram_active && (( used_bytes > 0 )); then
        log "当前 Zram 已使用 ${used_bytes} 字节 Swap；新配置将在下次重启后生效" "warn"
        show_swap_status
        return 0
    fi

    if is_zram_active; then
        log "停止未使用的现有 Zram 服务以应用新配置..." "info"
        systemctl stop systemd-zram-setup@zram0.service
    fi

    start_zram || return 1

    actual_size=$(get_zram_size)
    echo "Zram: ${actual_size:-已启用}（zstd，swappiness=${swappiness}）"
    show_swap_status
}

# === 时区配置 ===
setup_timezone() {
    local current_tz
    local choice
    local target_tz
    local -A tz_map=(
        [1]="$DEFAULT_TIMEZONE"
        [2]="UTC"
        [3]="Asia/Tokyo"
        [4]="Europe/London"
        [5]="America/New_York"
    )

    current_tz=$(timedatectl show --property=Timezone --value 2>/dev/null || true)
    current_tz="${current_tz:-未知}"

    read -r -p \
        "时区设置 [1=上海 2=UTC 3=东京 4=伦敦 5=纽约 6=自定义 7=保持当前]（默认 1）: " \
        choice </dev/tty
    choice="${choice:-1}"

    case "$choice" in
        [1-5])
            target_tz="${tz_map[$choice]}"
            ;;
        6)
            read -r -p \
                "输入时区（如 Asia/Shanghai，默认 ${DEFAULT_TIMEZONE}）: " \
                target_tz </dev/tty
            target_tz="${target_tz:-$DEFAULT_TIMEZONE}"

            if ! timedatectl list-timezones | grep -Fxq "$target_tz"; then
                log "无效时区，使用默认时区：${DEFAULT_TIMEZONE}" "warn"
                target_tz="$DEFAULT_TIMEZONE"
            fi
            ;;
        7)
            echo "时区: ${current_tz}（保持不变）"
            return 0
            ;;
        *)
            log "无效选择，使用默认时区：${DEFAULT_TIMEZONE}" "warn"
            target_tz="$DEFAULT_TIMEZONE"
            ;;
    esac

    if [[ "$current_tz" != "$target_tz" ]]; then
        if ! timedatectl set-timezone "$target_tz"; then
            log "设置时区失败" "error"
            return 1
        fi
    fi

    echo "时区: $target_tz"
}

# === Chrony 时间同步 ===
disable_timesyncd() {
    systemctl disable --now systemd-timesyncd >/dev/null 2>&1 || true
}

setup_chrony() {
    local sync_status
    local sources

    if systemctl is-active --quiet chrony; then
        disable_timesyncd

        sync_status=$(chronyc tracking 2>/dev/null |
            awk -F': ' '/Leap status/ {print $2}')

        if [[ "$sync_status" == "Normal" ]]; then
            echo "时间同步: Chrony（已同步）"
        else
            echo "时间同步: Chrony（运行中，等待同步）"
        fi

        return 0
    fi

    if ! command -v chronyd >/dev/null 2>&1; then
        log "安装 Chrony..." "info"

        if ! apt-get install -y chrony; then
            log "Chrony 安装失败，保留 systemd-timesyncd 状态不变" "error"
            return 1
        fi
    fi

    if ! systemctl enable --now chrony; then
        log "Chrony 启动失败，保留 systemd-timesyncd 状态不变" "error"
        return 1
    fi

    if ! systemctl is-active --quiet chrony; then
        log "Chrony 未处于运行状态" "error"
        return 1
    fi

    disable_timesyncd
    sleep 2

    sources=$(chronyc sources 2>/dev/null |
        awk '/^[\^\*\+\-]/ {count++} END {print count + 0}')

    echo "时间同步: Chrony（${sources} 个时间源）"
}

# === 主流程 ===
main() {
    if (( EUID != 0 )); then
        log "需要 root 权限运行" "error"
        exit 1
    fi

    local command_name
    for command_name in awk swapon systemctl timedatectl fuser; do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            log "缺少必要命令: $command_name" "error"
            exit 1
        fi
    done

    export SYSTEMD_PAGER=""
    export PAGER=""

    wait_for_apt || exit 1

    log "🔧 智能系统优化配置..." "info"

    echo
    setup_zram || log "Zram 配置失败，继续执行后续项目" "warn"

    echo
    setup_timezone || log "时区配置失败，继续执行后续项目" "warn"

    echo
    setup_chrony || log "Chrony 时间同步配置失败" "warn"

    echo
    log "✅ 系统优化完成" "info"

    if [[ "${DEBUG:-}" == "1" ]]; then
        echo
        log "=== 当前系统状态 ===" "debug"
        free -h
        swapon --show 2>/dev/null || true
        echo "swappiness: $(cat /proc/sys/vm/swappiness 2>/dev/null || echo "unknown")"
        timedatectl status 2>/dev/null || true
        chronyc tracking 2>/dev/null || true
    fi
}

trap 'log "系统优化脚本在第 $LINENO 行执行失败" "error"' ERR

main "$@"
