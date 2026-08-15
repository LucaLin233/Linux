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
        [warn]="\033[0;33m"
        [error]="\033[0;31m"
        [success]="\033[0;32m"
    )
    echo -e "${colors[$level]:-\033[0;32m}${msg}\033[0m"
}

info() { log "$1" "info"; }
warn() { log "$1" "warn"; }
error() { log "$1" "error"; }
success() { log "$1" "success"; }

require_root() {
    if (( EUID != 0 )); then
        error "需要 root 权限运行"
        exit 1
    fi
}

backup_managed_file() {
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

    local initial_backup="${backup_prefix}.initial-backup"
    local previous_backup="${backup_prefix}.previous-backup"
    local initial_absent="${backup_prefix}.initial-absent"
    local previous_absent="${backup_prefix}.previous-absent"
    local initial_unknown="${backup_prefix}.initial-unknown"

    if [[ ! -e "$initial_backup" && ! -e "$initial_absent" && ! -e "$initial_unknown" ]]; then
        if [[ -f "$file" ]] &&
            grep -Eq '# linux-setup:managed-motd|由 (system-customize|setup-motd)\.sh 自动生成' "$file"; then
            install -D -m 0600 /dev/null "$initial_unknown" || return 1
        elif [[ -e "$file" || -L "$file" ]]; then
            cp -a "$file" "$initial_backup" || return 1
        else
            install -D -m 0600 /dev/null "$initial_absent" || return 1
        fi
    fi

    rm -f "$previous_backup" "$previous_absent"
    if [[ -e "$file" || -L "$file" ]]; then
        cp -a "$file" "$previous_backup" || return 1
    else
        install -D -m 0600 /dev/null "$previous_absent" || return 1
    fi
}

get_managed_backup_prefix() {
    local target="$1"
    local state_prefix

    if [[ "$target" != /etc/update-motd.d/* ]]; then
        printf '%s\n' "$target"
        return 0
    fi

    state_prefix="/var/lib/linux-setup/motd-backups/$(basename "$target")"
    if [[ -e "${state_prefix}.initial-backup" || -e "${state_prefix}.initial-absent" ||
        -e "${state_prefix}.initial-unknown" || -e "${state_prefix}.previous-backup" ||
        -e "${state_prefix}.previous-absent" ]]; then
        printf '%s\n' "$state_prefix"
    else
        printf '%s\n' "$target"
    fi
}

restore_managed_file() {
    local target="$1"
    local scope="$2"
    local backup_prefix backup absent unknown

    backup_prefix=$(get_managed_backup_prefix "$target") || return 1
    backup="${backup_prefix}.${scope}-backup"
    absent="${backup_prefix}.${scope}-absent"
    unknown="${backup_prefix}.${scope}-unknown"

    if [[ -e "$backup" || -L "$backup" ]]; then
        install -d -m 0755 "$(dirname "$target")" || return 1
        rm -f "$target" || return 1
        cp -a "$backup" "$target" || return 1
        return 0
    fi
    if [[ -e "$absent" ]]; then
        rm -f "$target" || return 1
        return 0
    fi
    if [[ -e "$unknown" ]]; then
        warn "初始状态未知，跳过恢复：$target"
        return 2
    fi
    warn "没有 $scope 配置状态，跳过恢复：$target"
    return 2
}

replace_with_empty_regular_file() {
    local file="$1"

    # 避免静态欢迎文件链接到运行时动态文件时被 PAM 重复显示。
    install -m 0644 /dev/null "$file"
}

configure_motd() {
    info "配置动态欢迎信息..."

    install -d -m 0755 /etc/update-motd.d

    backup_managed_file /etc/motd || return 1
    backup_managed_file /etc/issue || return 1
    backup_managed_file /etc/issue.net || return 1
    replace_with_empty_regular_file /etc/motd
    replace_with_empty_regular_file /etc/issue
    replace_with_empty_regular_file /etc/issue.net

    backup_managed_file "$MOTD_SCRIPT" || return 1

    local file
    for file in /etc/update-motd.d/10-uname /etc/update-motd.d/50-motd-news; do
        backup_managed_file "$file" || return 1
        if [[ -x "$file" ]]; then
            chmod -x "$file"
            info "已禁用原生 MOTD 脚本: $(basename "$file")"
        fi
    done

    install -m 0755 /dev/stdin "$MOTD_SCRIPT" <<'SCRIPT'
#!/usr/bin/env bash
# linux-setup:managed-motd
# 由 Linux Scripts Collection 自动生成。
# 欢迎横幅与系统状态面板。

export LC_ALL=C

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

disk_percent=$(df -P / | awk 'NR == 2 {gsub(/%/, "", $5); print $5}')
disk_usage=$(df -Ph / | awk 'NR == 2 {printf "%s / %s", $3, $2}')
disk_color=$(pick_color "$disk_percent" "disk")

printf "\n${BLUE_BG} 已连接 %s 服务器 ${RESET}\n" "$hostname_value"
printf "${ITALIC_DIM} 今天想要做些什么？${RESET}\n\n"

printf "  ${LABEL}内核${RESET}      ${VALUE}%s${RESET}\n" "$kernel"
printf "  ${LABEL}运行时间${RESET}  ${VALUE}%s${RESET}\n" "$uptime_value"
printf "  ${LABEL}CPU负载${RESET}   ${VALUE}%s${RESET}\n" "$load_average"
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

restore_motd() {
    local scope="${1:-previous}" target result restored=0 failed=false
    local -a targets=(/etc/motd /etc/issue /etc/issue.net "$MOTD_SCRIPT" /etc/update-motd.d/10-uname /etc/update-motd.d/50-motd-news)
    case "$scope" in
        previous|initial) ;;
        *) error "恢复范围必须是 previous 或 initial"; return 1 ;;
    esac
    for target in "${targets[@]}"; do
        if restore_managed_file "$target" "$scope"; then
            ((restored += 1))
        else
            result=$?
            (( result == 1 )) && failed=true
        fi
    done
    (( restored > 0 )) || { error "没有可恢复的可信配置"; return 1; }
    [[ "$failed" == false ]] || { error "部分 MOTD 配置恢复失败"; return 1; }
    success "MOTD 已恢复到 $scope 状态"
}

show_status() {
    if [[ -x "$MOTD_SCRIPT" ]] && grep -Fq '# linux-setup:managed-motd' "$MOTD_SCRIPT"; then
        echo "MOTD 状态: 已安装并受管"
    elif [[ -e "$MOTD_SCRIPT" ]]; then
        echo "MOTD 状态: 存在但不受本工具管理"
    else
        echo "MOTD 状态: 未安装"
    fi
}

show_help() {
    printf '%s\n' '用法: setup-motd.sh [install|status|restore|help]'
}

main() {
    local action="${1:-install}"
    require_root

    local required_command
    for required_command in awk basename chmod cp date df dirname grep hostname install mv rm sed uname uptime; do
        if ! command -v "$required_command" >/dev/null 2>&1; then
            error "缺少必要命令: $required_command"
            exit 1
        fi
    done

    case "$action" in
        install) configure_motd ;;
        status) show_status ;;
        restore) restore_motd "${2:-previous}" ;;
        help|-h|--help) show_help ;;
        *) error "未知参数: $action"; show_help; return 1 ;;
    esac
}

trap 'error "MOTD 配置脚本在第 $LINENO 行执行失败"' ERR

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
