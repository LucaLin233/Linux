#!/usr/bin/env bash
# Debian 动态 MOTD 配置脚本
# 内容与 modules/system-customize.sh 的 MOTD 功能保持一致。

set -euo pipefail

readonly MOTD_SCRIPT="/etc/update-motd.d/00-custom-welcome"

log() {
    local msg="$1"
    local level="${2:-info}"
    local -A colors=(
        [info]="\033[0;36m"
        [error]="\033[0;31m"
        [success]="\033[0;32m"
    )
    echo -e "${colors[$level]:-\033[0;32m}${msg}\033[0m"
}

info() { log "$1" "info"; }
error() { log "$1" "error"; }
success() { log "$1" "success"; }

require_root() {
    if (( EUID != 0 )); then
        error "需要 root 权限运行"
        exit 1
    fi
}

backup_initial_file() {
    local file="$1"
    local backup_prefix="$file"
    local state_dir=""
    local suffix
    local legacy_state
    local state_file

    if [[ "$file" == /etc/update-motd.d/* ]]; then
        state_dir="/var/lib/linux-setup/motd-backups"
        install -d -m 0700 "$state_dir"
        backup_prefix="$state_dir/$(basename "$file")"

        for suffix in initial-backup previous-backup initial-absent previous-absent initial-unknown; do
            legacy_state="${file}.${suffix}"
            [[ -e "$legacy_state" || -L "$legacy_state" ]] || continue
            state_file="${backup_prefix}.${suffix}"
            if [[ -e "$state_file" || -L "$state_file" ]]; then
                state_file="${state_file}.legacy.$(date +%s).$$"
            fi
            mv "$legacy_state" "$state_file" || return 1
        done
    fi

    if [[ -e "${backup_prefix}.initial-backup" ||
        -e "${backup_prefix}.initial-absent" ||
        -e "${backup_prefix}.initial-unknown" ]]; then
        return 0
    fi

    if [[ -f "$file" ]] &&
        grep -Eq '由 (system-customize|setup-motd)\.sh 自动生成' "$file"; then
        install -D -m 0600 /dev/null "${backup_prefix}.initial-unknown"
    elif [[ -e "$file" || -L "$file" ]]; then
        cp -a "$file" "${backup_prefix}.initial-backup"
    else
        install -D -m 0600 /dev/null "${backup_prefix}.initial-absent"
    fi
}

replace_with_empty_regular_file() {
    local file="$1"

    # 避免静态欢迎文件链接到运行时动态文件时被 PAM 重复显示。
    install -m 0644 /dev/null "$file"
}

configure_motd() {
    info "配置动态欢迎信息..."

    install -d -m 0755 /etc/update-motd.d

    backup_initial_file /etc/motd || return 1
    backup_initial_file /etc/issue || return 1
    backup_initial_file /etc/issue.net || return 1
    replace_with_empty_regular_file /etc/motd
    replace_with_empty_regular_file /etc/issue
    replace_with_empty_regular_file /etc/issue.net

    backup_initial_file "$MOTD_SCRIPT" || return 1

    local file
    for file in /etc/update-motd.d/10-uname /etc/update-motd.d/50-motd-news; do
        backup_initial_file "$file" || return 1
        if [[ -x "$file" ]]; then
            chmod -x "$file"
            info "已禁用原生 MOTD 脚本: $(basename "$file")"
        fi
    done

    install -m 0755 /dev/stdin "$MOTD_SCRIPT" <<'SCRIPT'
#!/usr/bin/env bash
# 由 setup-motd.sh 自动生成。
# 欢迎横幅与系统状态面板。

hostname_value=$(hostname)
kernel=$(uname -r)

uptime_value=$(uptime -p 2>/dev/null | sed 's/^up //')
if [[ -z "$uptime_value" ]]; then
    uptime_value=$(uptime | sed -E 's/.*up[[:space:]]+//; s/,[[:space:]]+[0-9]+ user.*//')
fi

ESC=$'\033'
RESET="${ESC}[0m"
BLUE_BG="${ESC}[44;37m"
ITALIC_DIM="${ESC}[2;3;37m"
LABEL="${ESC}[1;36m"
VALUE="${ESC}[37m"
GREEN="${ESC}[32m"
ORANGE="${ESC}[33m"
RED="${ESC}[31m"

pick_color() {
    local percent="$1"
    local type="$2"
    local low
    local high
    local percent_int

    case "$type" in
        disk)
            low=70
            high=90
            ;;
        *)
            low=50
            high=80
            ;;
    esac

    percent_int=$(awk -v value="$percent" 'BEGIN {printf "%d", int(value + 0.5)}')

    if (( percent_int >= high )); then
        printf '%s' "$RED"
    elif (( percent_int >= low )); then
        printf '%s' "$ORANGE"
    else
        printf '%s' "$GREEN"
    fi
}

read -r _ user1 nice1 system1 idle1 iowait1 irq1 softirq1 steal1 _ < <(grep '^cpu ' /proc/stat)
total1=$((user1 + nice1 + system1 + idle1 + iowait1 + irq1 + softirq1 + steal1))
busy1=$((user1 + nice1 + system1 + irq1 + softirq1 + steal1))

sleep 0.5

read -r _ user2 nice2 system2 idle2 iowait2 irq2 softirq2 steal2 _ < <(grep '^cpu ' /proc/stat)
total2=$((user2 + nice2 + system2 + idle2 + iowait2 + irq2 + softirq2 + steal2))
busy2=$((user2 + nice2 + system2 + irq2 + softirq2 + steal2))

total_delta=$((total2 - total1))
busy_delta=$((busy2 - busy1))

if (( total_delta > 0 )); then
    cpu_percent=$(awk -v busy="$busy_delta" -v total="$total_delta" \
        'BEGIN {printf "%.1f", busy / total * 100}')
    cpu_color=$(pick_color "$cpu_percent" "cpu")
else
    cpu_percent="N/A"
    cpu_color="$VALUE"
fi

load_average=$(awk '{printf "%.2f %.2f %.2f", $1, $2, $3}' /proc/loadavg)

memory_raw=$(awk '
    /^MemTotal:/     { total=$2 }
    /^MemAvailable:/ { available=$2 }
    END {
        used=total-available
        percent=(total > 0) ? used/total*100 : 0
        printf "%.1f|%.1f|%.1f", used/1048576, total/1048576, percent
    }
' /proc/meminfo)

memory_used="${memory_raw%%|*}G"
memory_rest="${memory_raw#*|}"
memory_total="${memory_rest%%|*}G"
memory_percent="${memory_raw##*|}"
memory_color=$(pick_color "$memory_percent" "memory")

disk_percent=$(df / | awk 'NR == 2 {gsub(/%/, "", $5); print $5}')
disk_usage=$(df -h / | awk 'NR == 2 {printf "%s / %s", $3, $2}')
disk_color=$(pick_color "$disk_percent" "disk")

printf "\n${BLUE_BG} 已连接 %s 服务器 ${RESET}\n" "$hostname_value"
printf "${ITALIC_DIM} 今天想要做些什么？${RESET}\n\n"

printf "  ${LABEL}内核${RESET}      ${VALUE}%s${RESET}\n" "$kernel"
printf "  ${LABEL}运行时间${RESET}  ${VALUE}%s${RESET}\n" "$uptime_value"
printf "  ${LABEL}CPU负载${RESET}   ${VALUE}%s  (${cpu_color}%s%%${VALUE})${RESET}\n" \
    "$load_average" "$cpu_percent"
printf "  ${LABEL}内存${RESET}      ${VALUE}%s / %s  (${memory_color}%s%%${VALUE})${RESET}\n" \
    "$memory_used" "$memory_total" "$memory_percent"
printf "  ${LABEL}磁盘${RESET}      ${VALUE}%s  (${disk_color}%s%%${VALUE})${RESET}\n" \
    "$disk_usage" "$disk_percent"
SCRIPT

    echo "欢迎信息: 已配置"
    echo
    echo "预览："
    echo "----------------------------------------"
    "$MOTD_SCRIPT"
    echo "----------------------------------------"
}

main() {
    require_root

    local required_command
    for required_command in awk basename cat chmod cp date df grep hostname install mv sed sleep uname uptime; do
        if ! command -v "$required_command" >/dev/null 2>&1; then
            error "缺少必要命令: $required_command"
            exit 1
        fi
    done

    configure_motd
}

trap 'error "MOTD 配置脚本在第 $LINENO 行执行失败"' ERR

main "$@"
