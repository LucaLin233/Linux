#!/bin/bash

# 自动更新系统配置模块 v4.7.4 - 精简输出
# 功能: 配置定时自动更新系统

set -euo pipefail

# === 常量定义 ===

readonly UPDATE_SCRIPT="/root/auto-update.sh"
readonly UPDATE_LOG="/var/log/auto-update.log"
readonly DEFAULT_CRON="0 2 * * 0"
readonly CRON_COMMENT="# Auto-update managed by debian_setup"

# === 日志函数 ===

log() {
    local msg="$1" level="${2:-info}"
    local -A colors=([info]="\033[0;36m" [warn]="\033[0;33m" [error]="\033[0;31m" [debug]="\033[0;35m")
    echo -e "${colors[$level]:-\033[0;32m}$msg\033[0m"
}

debug_log() {
    if [[ "${DEBUG:-}" == "1" ]]; then
        log "DEBUG: $1" "debug" >&2
    fi
    return 0
}

# === 辅助函数 ===

validate_cron_expression() {
    local expr="$1"
    debug_log "验证Cron表达式: $expr"

    if [[ "$expr" =~ ^[0-9*,/-]+[[:space:]]+[0-9*,/-]+[[:space:]]+[0-9*,/-]+[[:space:]]+[0-9*,/-]+[[:space:]]+[0-9*,/-]+$ ]]; then
        debug_log "Cron表达式验证通过"
        return 0
    else
        debug_log "Cron表达式验证失败"
        return 1
    fi
}

has_cron_job() {
    debug_log "检查现有Cron任务"
    if crontab -l 2>/dev/null | grep -q "$UPDATE_SCRIPT"; then
        return 0
    else
        return 1
    fi
}

get_cron_schedule() {
    local choice
    read -p "使用默认时间 (每周日凌晨2点)? [Y/n] (默认: Y): " choice >&2 || choice="Y"
    choice=${choice:-Y}

    if [[ "$choice" =~ ^[Nn]$ ]]; then
        echo "自定义时间格式: 分 时 日 月 周 (如: 0 3 * * 1)" >&2

        while true; do
            local custom_expr
            read -p "请输入Cron表达式: " custom_expr >&2 || custom_expr=""
            if [[ -n "$custom_expr" ]] && validate_cron_expression "$custom_expr"; then
                echo "Cron时间: 自定义 ($custom_expr)" >&2
                echo "$custom_expr"
                return 0
            else
                echo "格式错误，请重新输入" >&2
            fi
        done
    else
        echo "Cron时间: 每周日凌晨2点" >&2
        echo "$DEFAULT_CRON"
    fi
    return 0
}

# === 核心功能函数 ===

ensure_cron_installed() {
    if ! command -v crontab >/dev/null 2>&1; then
        echo "安装cron服务..."
        if apt-get update >/dev/null 2>&1 && apt-get install -y cron >/dev/null 2>&1; then
            echo "cron服务: 安装成功"
        else
            echo "cron服务: 安装失败"
            return 1
        fi
    else
        echo "cron服务: 已安装"
    fi

    if ! systemctl is-active cron >/dev/null 2>&1; then
        systemctl enable cron >/dev/null 2>&1 || true
        systemctl start cron >/dev/null 2>&1 || true
    fi

    if systemctl is-active cron >/dev/null 2>&1; then
        echo "cron服务: 运行正常"
        return 0
    else
        echo "cron服务: 启动失败"
        return 1
    fi
}

add_cron_job() {
    local cron_expr="$1"

    local temp_cron
    if ! temp_cron=$(mktemp); then
        return 1
    fi

    crontab -l 2>/dev/null | grep -v "$UPDATE_SCRIPT" | grep -v "Auto-update managed" > "$temp_cron" || true
    echo "$CRON_COMMENT" >> "$temp_cron"
    echo "$cron_expr $UPDATE_SCRIPT" >> "$temp_cron"

    if crontab "$temp_cron"; then
        rm -f "$temp_cron"
        return 0
    else
        rm -f "$temp_cron"
        return 1
    fi
}

create_update_script() {
    cat > "$UPDATE_SCRIPT" << 'EOF'
#!/bin/bash

# 自动系统更新脚本 v4.7.4 - 精简输出

set -euo pipefail

readonly LOGFILE="/var/log/auto-update.log"
readonly APT_OPTIONS="-y \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold \
    -o Dpkg::Options::=--force-confmiss \
    -o Dpkg::Use-Pty=0 \
    -o APT::Get::Assume-Yes=true \
    -o APT::Get::allow-downgrades=true \
    -o APT::Get::allow-remove-essential=false \
    -o APT::Get::allow-change-held-packages=false"
readonly MAX_WAIT_LOCK=600
readonly LOCK_CHECK_INTERVAL=10

# 重要信息：同时输出到终端和日志文件
log_info() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $1" | tee -a "$LOGFILE"
}

# 详细信息：仅写入日志文件
log_detail() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $1" >> "$LOGFILE"
}

# 警告/错误：同时输出到终端和日志文件
log_warn() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] ⚠️  $1" | tee -a "$LOGFILE"
}

stop_conflicting_services() {
    log_detail "停止可能冲突的自动更新服务..."

    systemctl stop apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
    systemctl disable apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
    systemctl stop apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
    systemctl kill --kill-who=all apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
    systemctl stop unattended-upgrades 2>/dev/null || true
    systemctl stop packagekit 2>/dev/null || true

    local waited=0
    while pgrep -x "apt-get|apt|dpkg|unattended" >/dev/null 2>&1; do
        if [[ $waited -ge 60 ]]; then
            log_warn "强制终止残留 apt/dpkg 进程"
            pkill -9 -x apt-get || true
            pkill -9 -x apt || true
            pkill -9 -x dpkg || true
            pkill -9 -x unattended-upgrade || true
            sleep 5
            break
        fi
        sleep 5
        waited=$((waited + 5))
    done
}

wait_for_dpkg() {
    local waited=0

    while [[ $waited -lt $MAX_WAIT_LOCK ]]; do
        local locked=false

        if lsof /var/lib/dpkg/lock-frontend 2>/dev/null | grep -q dpkg || \
           lsof /var/lib/apt/lists/lock 2>/dev/null | grep -q apt || \
           lsof /var/cache/apt/archives/lock 2>/dev/null | grep -q apt; then
            locked=true
        fi

        if pgrep -x "apt-get|apt|dpkg" >/dev/null 2>&1; then
            locked=true
        fi

        if [[ "$locked" == "false" ]]; then
            return 0
        fi

        log_detail "等待 dpkg/apt 锁释放... ($waited/$MAX_WAIT_LOCK 秒)"
        sleep $LOCK_CHECK_INTERVAL
        waited=$((waited + LOCK_CHECK_INTERVAL))
    done

    log_warn "等待锁超时，强制清理锁文件"

    pkill -9 -x apt-get || true
    pkill -9 -x apt || true
    pkill -9 -x dpkg || true
    sleep 3

    rm -f /var/lib/dpkg/lock-frontend \
          /var/lib/dpkg/lock \
          /var/lib/apt/lists/lock \
          /var/cache/apt/archives/lock 2>/dev/null || true

    sleep 2
    return 0
}

ensure_packages_configured() {
    log_detail "执行 dpkg --configure -a..."
    if ! dpkg --configure -a >> "$LOGFILE" 2>&1; then
        log_warn "dpkg 配置异常，尝试修复..."

        local broken_pkgs
        broken_pkgs=$(dpkg -l 2>/dev/null | awk '$1 ~ /^i[UFH]/ {print $2}')

        if [[ -n "$broken_pkgs" ]]; then
            echo "$broken_pkgs" | while read -r pkg; do
                [[ -z "$pkg" ]] && continue
                log_detail "修复包: $pkg"
                wait_for_dpkg
                if timeout 300 apt-get install --reinstall $APT_OPTIONS "$pkg" >> "$LOGFILE" 2>&1; then
                    log_detail "重装成功: $pkg"
                else
                    log_warn "重装失败，尝试删除: $pkg"
                    wait_for_dpkg
                    apt-get purge -y --force-yes "$pkg" >> "$LOGFILE" 2>&1 || true
                fi
                sleep 2
            done
        fi

        wait_for_dpkg
        dpkg --configure -a >> "$LOGFILE" 2>&1 || true
    fi

    wait_for_dpkg

    if ! apt-get install -f $APT_OPTIONS >> "$LOGFILE" 2>&1; then
        log_warn "依赖修复出现问题，重试..."
        sleep 5
        wait_for_dpkg
        apt-get install -f $APT_OPTIONS >> "$LOGFILE" 2>&1 || true
    fi

    wait_for_dpkg

    # rc 包清理（仅写日志）
    local rc_count
    rc_count=$(dpkg -l 2>/dev/null | awk '$1 == "rc"' | wc -l)
    if [[ $rc_count -gt 0 && $rc_count -lt 50 ]]; then
        log_detail "清理 $rc_count 个残留配置文件..."
        wait_for_dpkg
        dpkg -l 2>/dev/null | awk '$1 == "rc" {print $2}' | \
            xargs -r -n 10 dpkg --purge --force-all >> "$LOGFILE" 2>&1 || true
    fi
}

clean_old_kernels() {
    local current_kernel
    current_kernel=$(uname -r)

    local all_kernels
    all_kernels=$(dpkg -l | awk '/^ii[[:space:]]+linux-image-[0-9]/ {print $2}' | sort -V)

    local kernel_count
    kernel_count=$(echo "$all_kernels" | grep -c . || echo 0)

    if [[ $kernel_count -le 2 ]]; then
        log_detail "内核数量 <= 2，无需清理"
        return 0
    fi

    local kernels_to_remove
    kernels_to_remove=$(echo "$all_kernels" | grep -v "$current_kernel" | head -n -1)

    if [[ -z "$kernels_to_remove" ]]; then
        log_detail "无需清理的旧内核"
        return 0
    fi

    local removed_count=0
    echo "$kernels_to_remove" | while read -r old_kernel; do
        [[ -z "$old_kernel" ]] && continue
        local version="${old_kernel#linux-image-}"
        log_detail "移除旧内核: $version"

        wait_for_dpkg

        for pkg in \
            "linux-image-${version}" \
            "linux-headers-${version}" \
            "linux-modules-${version}" \
            "linux-modules-extra-${version}"; do
            if dpkg -l "$pkg" 2>/dev/null | grep -q '^ii'; then
                apt-get purge $APT_OPTIONS "$pkg" >> "$LOGFILE" 2>&1 || \
                    log_warn "移除失败: $pkg"
            fi
        done

        removed_count=$((removed_count + 1))
        sleep 2
    done

    local remove_total
    remove_total=$(echo "$kernels_to_remove" | grep -c . || echo 0)
    log_info "旧内核清理完成，已移除 $remove_total 个版本"
}

check_boot_space() {
    local boot_usage
    boot_usage=$(df /boot 2>/dev/null | tail -1 | awk '{print $5}' | sed 's/%//' || echo 0)
    log_detail "/boot 使用率: ${boot_usage}%"

    clean_old_kernels

    wait_for_dpkg

    boot_usage=$(df /boot 2>/dev/null | tail -1 | awk '{print $5}' | sed 's/%//' || echo 0)
    log_detail "/boot 清理后使用率: ${boot_usage}%"
}

check_kernel_update() {
    local current
    current=$(uname -r)
    local latest
    latest=$(find /boot -name "vmlinuz-*" -printf "%f\n" 2>/dev/null | sed 's/vmlinuz-//' | sort -V | tail -1)

    if [[ -n "$latest" && "$current" != "$latest" ]]; then
        log_info "检测到新内核: $latest（当前: $current）"

        [[ ! -f "/boot/vmlinuz-$latest" ]] && { log_warn "内核文件缺失，跳过重启"; return 1; }
        [[ ! -f "/boot/initrd.img-$latest" ]] && { log_warn "initramfs 缺失，跳过重启"; return 1; }
        [[ ! -d "/lib/modules/$latest" ]] && { log_warn "内核模块目录缺失，跳过重启"; return 1; }

        return 0
    fi

    return 1
}

safe_reboot() {
    wait_for_dpkg
    dpkg --configure -a >> "$LOGFILE" 2>&1 || true

    local latest
    latest=$(find /boot -name "vmlinuz-*" -printf "%f\n" 2>/dev/null | sed 's/vmlinuz-//' | sort -V | tail -1)
    if [[ ! -f "/boot/initrd.img-$latest" ]]; then
        log_warn "initramfs 缺失，取消重启"
        return 1
    fi

    systemctl is-active sshd >/dev/null || systemctl start sshd

    log_info "系统将在 60 秒后重启以应用新内核..."
    sync
    sleep 60

    log_info "执行重启..."
    systemctl reboot || reboot
}

main() {
    : > "$LOGFILE"

    log_info "=== 自动系统更新开始 ==="
    log_info "内核: $(uname -r) | 系统: $(lsb_release -ds 2>/dev/null || echo 'Unknown')"

    stop_conflicting_services
    sleep 5

    # 第一阶段：系统准备
    log_info "--- [1/5] 系统准备"
    wait_for_dpkg
    ensure_packages_configured
    check_boot_space

    # 第二阶段：系统更新
    log_info "--- [2/5] 更新软件包"
    wait_for_dpkg

    if ! apt-get update >> "$LOGFILE" 2>&1; then
        log_warn "软件包列表更新失败，重试..."
        sleep 5
        wait_for_dpkg
        apt-get update >> "$LOGFILE" 2>&1 || true
    fi

    wait_for_dpkg

    local upgraded_count=0
    if ! DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade $APT_OPTIONS >> "$LOGFILE" 2>&1; then
        log_warn "系统升级出现问题，尝试修复..."
        sleep 5
        wait_for_dpkg
        apt-get install -f $APT_OPTIONS >> "$LOGFILE" 2>&1 || true
        wait_for_dpkg
        DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade $APT_OPTIONS >> "$LOGFILE" 2>&1 || true
    fi

    upgraded_count=$(grep -c "^Inst " "$LOGFILE" 2>/dev/null || echo 0)
    log_info "软件包升级完成，共升级 $upgraded_count 个包"

    # 第三阶段：清理验证
    log_info "--- [3/5] 清理验证"
    wait_for_dpkg
    sleep 3
    ensure_packages_configured
    wait_for_dpkg
    check_boot_space
    wait_for_dpkg

    # 第四阶段：检查重启
    log_info "--- [4/5] 检查内核更新"
    if check_kernel_update; then
        safe_reboot
    else
        log_info "无需重启"
    fi

    # 第五阶段：最终清理
    log_info "--- [5/5] 最终清理"
    wait_for_dpkg

    log_detail "保护关键包..."
    apt-mark manual wireguard-tools 2>/dev/null || true

    apt-get autoremove $APT_OPTIONS >> "$LOGFILE" 2>&1 || true
    apt-get autoclean >> "$LOGFILE" 2>&1 || true

    systemctl enable apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
    systemctl start unattended-upgrades 2>/dev/null || true

    local boot_final
    boot_final=$(df /boot 2>/dev/null | tail -1 | awk '{print $5}' | sed 's/%//')
    log_info "=== 更新完成 | /boot: ${boot_final}% | 日志: $LOGFILE ==="
}

trap 'systemctl start unattended-upgrades 2>/dev/null || true; systemctl enable apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true' EXIT

trap 'log_warn "更新过程中发生错误（行号: $LINENO）"' ERR

main "$@"
EOF

    chmod +x "$UPDATE_SCRIPT"
    echo "更新脚本: 创建完成"
    return 0
}

setup_cron_job() {
    if has_cron_job; then
        local replace
        read -p "检测到现有任务，是否替换? [y/N] (默认: N): " -r replace || replace="N"
        replace=${replace:-N}
        if [[ ! "$replace" =~ ^[Yy]$ ]]; then
            echo "定时任务: 保持现有"
            return 0
        fi
    fi

    local cron_expr
    if ! cron_expr=$(get_cron_schedule); then
        return 1
    fi

    if add_cron_job "$cron_expr"; then
        echo "定时任务: 配置成功"
        return 0
    else
        echo "定时任务: 配置失败"
        return 1
    fi
}

test_update_script() {
    local test_choice
    read -p "是否测试自动更新脚本? [y/N] (默认: N): " -r test_choice || test_choice="N"
    test_choice=${test_choice:-N}

    if [[ "$test_choice" =~ ^[Yy]$ ]]; then
        echo "警告: 将执行真实的系统更新"
        local confirm
        read -p "确认继续? [y/N] (默认: N): " -r confirm || confirm="N"
        confirm=${confirm:-N}

        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            echo "开始测试更新脚本..."
            echo "========================================="

            set +e
            "$UPDATE_SCRIPT"
            local test_exit_code=$?
            set -e

            echo "========================================="

            if [[ $test_exit_code -eq 0 ]]; then
                echo "✅ 测试执行成功，详细日志: $UPDATE_LOG"
            else
                echo "⚠️  测试完成但返回非零退出码 ($test_exit_code)"
                echo "   详细日志: $UPDATE_LOG"
            fi
        else
            echo "已取消测试"
        fi
    else
        echo "跳过脚本测试"
    fi

    return 0
}

show_update_summary() {
    echo
    log "🎯 自动更新摘要:" "info"

    if has_cron_job; then
        local cron_line
        cron_line=$(crontab -l 2>/dev/null | grep -v "^#" | grep "$UPDATE_SCRIPT" | head -1)
        local cron_time
        cron_time=$(echo "$cron_line" | awk '{print $1, $2, $3, $4, $5}')

        echo "  定时任务: 已配置"
        if [[ "$cron_time" == "$DEFAULT_CRON" ]]; then
            echo "  执行时间: 每周日凌晨2点"
        elif [[ -n "$cron_time" ]]; then
            echo "  执行时间: 自定义 ($cron_time)"
        else
            echo "  执行时间: 已配置（查看详情: crontab -l）"
        fi
    else
        echo "  定时任务: 未配置"
    fi

    [[ -x "$UPDATE_SCRIPT" ]] && echo "  更新脚本: 已创建" || echo "  更新脚本: 未找到"
    systemctl is-active cron >/dev/null 2>&1 && echo "  Cron服务: 运行中" || echo "  Cron服务: 未运行"

    return 0
}

main() {
    log "🔄 配置自动更新系统..." "info"

    echo
    echo "功能: 定时自动更新系统软件包和安全补丁"
    echo "版本: v4.7.4 (精简输出)"

    echo
    if ! ensure_cron_installed; then
        log "✗ cron服务配置失败" "error"
        return 1
    fi

    echo
    if ! create_update_script; then
        log "✗ 更新脚本创建失败" "error"
        return 1
    fi

    echo
    if ! setup_cron_job; then
        log "✗ 定时任务配置失败" "error"
        return 1
    fi

    echo
    test_update_script || true

    show_update_summary || true

    echo
    log "✅ 自动更新系统配置完成!" "info"

    echo
    log "常用命令:" "info"
    echo "  手动执行: $UPDATE_SCRIPT"
    echo "  查看日志: tail -f $UPDATE_LOG"
    echo "  实时监控: watch -n1 'tail -20 $UPDATE_LOG'"
    echo "  管理任务: crontab -l"

    return 0
}

trap 'exit_code=$?; if [[ $exit_code -ne 0 && $exit_code -ne 130 ]]; then log "脚本异常退出，行号: $LINENO，退出码: $exit_code" "error"; fi' ERR

main "$@"

exit 0
