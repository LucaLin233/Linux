#!/usr/bin/env bash
# 自动更新系统配置模块
# 功能：每周安全更新系统与内核，必要时自动重启

set -euo pipefail

# === 常量定义 ===
readonly UPDATE_SCRIPT="/root/auto-update.sh"
readonly UPDATE_LOG="/var/log/auto-update.log"
readonly UPDATE_LOCK="/var/lock/auto-update.lock"

readonly DEFAULT_CRON="0 2 * * 0"
readonly CRON_COMMENT="# Auto-update managed by debian_setup"

readonly APT_LOCK_TIMEOUT=1800
readonly APT_LOCK_INTERVAL=10
readonly REBOOT_DELAY=30

# === 日志函数 ===
log() {
    local msg="$1"
    local level="${2:-info}"
    local -A colors=(
        [info]="\033[0;36m"
        [warn]="\033[0;33m"
        [error]="\033[0;31m"
        [success]="\033[0;32m"
        [debug]="\033[0;35m"
    )

    if [[ "$level" == "debug" && "${DEBUG:-}" != "1" ]]; then
        return 0
    fi

    echo -e "${colors[$level]:-\033[0;32m}${msg}\033[0m"
}

debug_log() {
    log "DEBUG: $1" "debug"
}

require_root() {
    if (( EUID != 0 )); then
        log "需要 root 权限运行" "error"
        exit 1
    fi
}

# === Cron 配置 ===
validate_cron_expression() {
    local expression="$1"

    [[ "$expression" =~ ^[0-9*/,-]+[[:space:]]+[0-9*/,-]+[[:space:]]+[0-9*/,-]+[[:space:]]+[0-9*/,-]+[[:space:]]+[0-9*/,-]+$ ]]
}

ensure_cron_installed() {
    if ! command -v crontab >/dev/null 2>&1; then
        log "安装 Cron 服务..." "info"

        if ! apt-get install -y cron; then
            log "Cron 服务安装失败" "error"
            return 1
        fi
    fi

    if ! systemctl enable --now cron >/dev/null 2>&1; then
        log "Cron 服务启动失败" "error"
        return 1
    fi

    if ! systemctl is-active --quiet cron; then
        log "Cron 服务未处于运行状态" "error"
        return 1
    fi

    echo "Cron 服务: 运行中"
}

get_cron_schedule() {
    local choice
    local custom_expression

    read -r -p "使用默认时间（每周日凌晨 2 点）？[Y/n]: " choice
    choice="${choice:-Y}"

    if [[ ! "$choice" =~ ^[Nn]$ ]]; then
        echo "$DEFAULT_CRON"
        return 0
    fi

    echo "自定义时间格式：分 时 日 月 周，例如：0 3 * * 1" >&2

    while true; do
        read -r -p "请输入 Cron 表达式: " custom_expression

        if validate_cron_expression "$custom_expression"; then
            echo "$custom_expression"
            return 0
        fi

        log "Cron 表达式格式错误，请重新输入" "warn"
    done
}

has_update_cron() {
    crontab -l 2>/dev/null |
        grep -Fq "$UPDATE_SCRIPT"
}

configure_cron_job() {
    local cron_expression="$1"
    local temp_cron
    local current_cron

    if ! temp_cron=$(mktemp); then
        log "无法创建 Cron 临时文件" "error"
        return 1
    fi

    current_cron=$(crontab -l 2>/dev/null || true)

    {
        printf '%s\n' "$current_cron" |
            grep -Fv "$CRON_COMMENT" |
            grep -Fv "$UPDATE_SCRIPT" || true

        echo "$CRON_COMMENT"
        echo "$cron_expression $UPDATE_SCRIPT"
    } > "$temp_cron"

    if ! crontab "$temp_cron"; then
        rm -f "$temp_cron"
        log "自动更新任务配置失败" "error"
        return 1
    fi

    rm -f "$temp_cron"

    echo "自动更新任务: 已配置"
}

# === 更新脚本生成 ===
create_update_script() {
    cat > "$UPDATE_SCRIPT" <<EOF
#!/usr/bin/env bash
# 由 auto-update-setup.sh 自动生成。
# 功能：安全执行系统与内核更新，必要时自动重启。

set -euo pipefail

readonly LOG_FILE="$UPDATE_LOG"
readonly LOCK_FILE="$UPDATE_LOCK"
readonly APT_LOCK_TIMEOUT=$APT_LOCK_TIMEOUT
readonly APT_LOCK_INTERVAL=$APT_LOCK_INTERVAL
readonly REBOOT_DELAY=$REBOOT_DELAY

log() {
    local level="\${1:-info}"
    shift
    local message="\$*"
    local timestamp

    timestamp=\$(date '+%Y-%m-%d %H:%M:%S %Z')
    echo "[\$timestamp] [\$level] \$message" | tee -a "\$LOG_FILE"
}

wait_for_apt_lock() {
    local waited=0
    local lock_files=(
        /var/lib/dpkg/lock-frontend
        /var/lib/dpkg/lock
        /var/lib/apt/lists/lock
        /var/cache/apt/archives/lock
    )

    while fuser "\${lock_files[@]}" >/dev/null 2>&1; do
        if (( waited >= APT_LOCK_TIMEOUT )); then
            log error "APT/dpkg 锁等待超时（\${APT_LOCK_TIMEOUT} 秒），跳过本次更新"
            return 1
        fi

        if (( waited == 0 )); then
            log info "检测到 APT/dpkg 正在被其他任务使用，开始等待锁释放"
        fi

        log info "等待 APT/dpkg 锁释放：\${waited}/\${APT_LOCK_TIMEOUT} 秒"
        sleep "\$APT_LOCK_INTERVAL"
        ((waited += APT_LOCK_INTERVAL))
    done

    return 0
}

run_full_upgrade() {
    log info "更新软件包索引"

    if ! apt-get update; then
        log error "软件包索引更新失败"
        return 1
    fi

    log info "执行完整系统升级（包含内核更新）"

    if DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y \\
        -o Dpkg::Options::=--force-confdef \\
        -o Dpkg::Options::=--force-confold; then
        return 0
    fi

    log warn "完整升级失败，尝试安全修复 dpkg 与依赖关系"

    if ! DEBIAN_FRONTEND=noninteractive dpkg --configure -a; then
        log warn "dpkg --configure -a 执行失败"
    fi

    if ! DEBIAN_FRONTEND=noninteractive apt-get -f install -y \\
        -o Dpkg::Options::=--force-confdef \\
        -o Dpkg::Options::=--force-confold; then
        log error "APT 依赖修复失败"
        return 1
    fi

    log info "再次执行完整系统升级"

    if ! DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y \\
        -o Dpkg::Options::=--force-confdef \\
        -o Dpkg::Options::=--force-confold; then
        log error "完整系统升级重试失败"
        return 1
    fi

    return 0
}

cleanup_packages() {
    log info "清理不再需要的软件包与缓存"

    DEBIAN_FRONTEND=noninteractive apt-get autoremove -y || \\
        log warn "自动清理不再需要的软件包失败"

    apt-get autoclean -y || \\
        log warn "清理 APT 缓存失败"
}

get_latest_boot_kernel() {
    find /boot -maxdepth 1 -type f -name 'vmlinuz-*' -printf '%f\\n' 2>/dev/null |
        sed 's/^vmlinuz-//' |
        sort -V |
        tail -n 1
}

has_new_complete_kernel() {
    local current_kernel
    local latest_kernel

    current_kernel=\$(uname -r)
    latest_kernel=\$(get_latest_boot_kernel)

    [[ -n "\$latest_kernel" ]] || return 1
    [[ "\$latest_kernel" != "\$current_kernel" ]] || return 1

    [[ -f "/boot/vmlinuz-\$latest_kernel" ]] || return 1
    [[ -f "/boot/initrd.img-\$latest_kernel" ]] || return 1
    [[ -d "/lib/modules/\$latest_kernel" ]] || return 1

    if dpkg --compare-versions "\$latest_kernel" gt "\$current_kernel" 2>/dev/null; then
        return 0
    fi

    # 部分云内核版本格式不完全符合 Debian 版本比较规则；
    # 内核文件完整且版本不同的情况下仍建议重启以应用更新。
    return 0
}

reboot_if_required() {
    local current_kernel
    local latest_kernel
    local reason=""

    current_kernel=\$(uname -r)
    latest_kernel=\$(get_latest_boot_kernel)

    if [[ -f /var/run/reboot-required ]]; then
        reason="系统标记需要重启"
    fi

    if has_new_complete_kernel; then
        if [[ -n "\$reason" ]]; then
            reason+="；"
        fi
        reason+="检测到新内核：\${latest_kernel}（当前：\${current_kernel}）"
    fi

    if [[ -z "\$reason" ]]; then
        log info "更新完成，无需重启"
        return 0
    fi

    log warn "\$reason"
    log warn "系统将在 \${REBOOT_DELAY} 秒后自动重启以应用更新"

    sync
    sleep "\$REBOOT_DELAY"

    log warn "正在自动重启系统"

    if ! systemctl reboot --message="Auto-update applied system updates"; then
        reboot
    fi
}

main() {
    touch "\$LOG_FILE"
    chmod 600 "\$LOG_FILE" 2>/dev/null || true

    # 文件描述符 9 用于 flock；防止 Cron、手动执行及残留任务重叠。
    exec 9>"\$LOCK_FILE"

    if ! flock -n 9; then
        log warn "已有自动更新任务正在运行，跳过本次任务"
        exit 0
    fi

    log info "========== 自动系统更新开始 =========="
    log info "当前内核：\$(uname -r)"

    if ! wait_for_apt_lock; then
        exit 1
    fi

    if ! run_full_upgrade; then
        log error "系统更新失败，请查看日志：\$LOG_FILE"
        exit 1
    fi

    cleanup_packages
    reboot_if_required

    log info "========== 自动系统更新完成 =========="
}

trap 'exit_code=\$?; if (( exit_code != 0 )); then log error "自动更新异常退出，行号：\$LINENO，退出码：\$exit_code"; fi' EXIT

main "\$@"
EOF

    chmod 700 "$UPDATE_SCRIPT"

    if [[ ! -x "$UPDATE_SCRIPT" ]]; then
        log "更新脚本创建失败" "error"
        return 1
    fi

    echo "更新脚本: 已创建（$UPDATE_SCRIPT）"
}

# === 摘要 ===
show_update_summary() {
    local cron_line
    local cron_schedule="未配置"

    echo
    log "🎯 自动更新摘要：" "info"

    if cron_line=$(crontab -l 2>/dev/null |
        grep -F "$UPDATE_SCRIPT" |
        head -n 1); then
        cron_schedule=$(awk '{print $1, $2, $3, $4, $5}' <<< "$cron_line")
    fi

    if [[ "$cron_schedule" == "$DEFAULT_CRON" ]]; then
        echo "  执行时间: 每周日凌晨 2 点"
    elif [[ "$cron_schedule" != "未配置" ]]; then
        echo "  执行时间: 自定义（$cron_schedule）"
    else
        echo "  执行时间: 未配置"
    fi

    [[ -x "$UPDATE_SCRIPT" ]] &&
        echo "  更新脚本: 已创建" ||
        echo "  更新脚本: 未找到"

    systemctl is-active --quiet cron &&
        echo "  Cron 服务: 运行中" ||
        echo "  Cron 服务: 未运行"

    echo "  APT 锁等待: 最长 $((APT_LOCK_TIMEOUT / 60)) 分钟"
    echo "  更新方式: apt-get full-upgrade（包含内核更新）"
    echo "  自动重启: 检测到需重启或新内核后，等待 ${REBOOT_DELAY} 秒"
    echo "  更新日志: $UPDATE_LOG"
}

# === 主流程 ===
main() {
    require_root

    local command
    for command in apt-get crontab flock fuser systemctl mktemp find sort dpkg; do
        if ! command -v "$command" >/dev/null 2>&1; then
            log "缺少必要命令: $command" "error"
            exit 1
        fi
    done

    log "🔄 配置自动更新系统..." "info"

    echo
    echo "功能说明："
    echo "  - 按计划执行完整系统更新，包含内核更新"
    echo "  - APT 被占用时最多等待 $((APT_LOCK_TIMEOUT / 60)) 分钟"
    echo "  - 更新完成且需要重启时，等待 ${REBOOT_DELAY} 秒自动重启"
    echo "  - 不会强杀 apt/dpkg 进程、删除锁文件或强制删除软件包"

    echo
    ensure_cron_installed || exit 1

    echo
    create_update_script || exit 1

    echo
    local cron_schedule
    cron_schedule=$(get_cron_schedule)

    if has_update_cron; then
        echo "检测到现有自动更新任务，将自动替换为新配置。"
    fi

    configure_cron_job "$cron_schedule" || exit 1

    show_update_summary

    echo
    log "✅ 自动更新系统配置完成" "success"
    echo "常用命令："
    echo "  手动更新: $UPDATE_SCRIPT"
    echo "  查看日志: tail -f $UPDATE_LOG"
    echo "  查看任务: crontab -l"
}

trap 'log "自动更新配置脚本在第 $LINENO 行执行失败" "error"' ERR

main "$@"
