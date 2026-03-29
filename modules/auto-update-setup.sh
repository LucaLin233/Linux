#!/bin/bash

# 自动更新系统配置模块 v4.7.3 - 修复内核清理逻辑
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
        debug_log "发现现有Cron任务"
        return 0
    else
        debug_log "未发现现有Cron任务"
        return 1
    fi
}

get_cron_schedule() {
    debug_log "获取用户Cron时间选择"
    local choice
    read -p "使用默认时间 (每周日凌晨2点)? [Y/n] (默认: Y): " choice >&2 || choice="Y"
    choice=${choice:-Y}

    if [[ "$choice" =~ ^[Nn]$ ]]; then
        debug_log "用户选择自定义时间"
        echo "自定义时间格式: 分 时 日 月 周 (如: 0 3 * * 1)" >&2

        while true; do
            local custom_expr
            read -p "请输入Cron表达式: " custom_expr >&2 || custom_expr=""
            if [[ -n "$custom_expr" ]] && validate_cron_expression "$custom_expr"; then
                echo "Cron时间: 自定义 ($custom_expr)" >&2
                debug_log "用户设置自定义Cron: $custom_expr"
                echo "$custom_expr"
                return 0
            else
                echo "格式错误，请重新输入" >&2
            fi
        done
    else
        debug_log "用户选择默认时间"
        echo "Cron时间: 每周日凌晨2点" >&2
        echo "$DEFAULT_CRON"
    fi
    return 0
}

# === 核心功能函数 ===

ensure_cron_installed() {
    debug_log "开始检查Cron服务"

    if ! command -v crontab >/dev/null 2>&1; then
        debug_log "Cron服务未安装，开始安装"
        echo "安装cron服务..."
        if apt-get update >/dev/null 2>&1 && apt-get install -y cron >/dev/null 2>&1; then
            echo "cron服务: 安装成功"
            debug_log "Cron服务安装成功"
        else
            echo "cron服务: 安装失败"
            debug_log "Cron服务安装失败"
            return 1
        fi
    else
        echo "cron服务: 已安装"
        debug_log "Cron服务已安装"
    fi

    if ! systemctl is-active cron >/dev/null 2>&1; then
        debug_log "启动Cron服务"
        systemctl enable cron >/dev/null 2>&1 || true
        systemctl start cron >/dev/null 2>&1 || true
    fi

    if systemctl is-active cron >/dev/null 2>&1; then
        echo "cron服务: 运行正常"
        debug_log "Cron服务运行正常"
        return 0
    else
        echo "cron服务: 启动失败"
        debug_log "Cron服务启动失败"
        return 1
    fi
}

add_cron_job() {
    local cron_expr="$1"
    debug_log "添加Cron任务: $cron_expr"

    local temp_cron
    if ! temp_cron=$(mktemp); then
        debug_log "无法创建临时Cron文件"
        return 1
    fi

    crontab -l 2>/dev/null | grep -v "$UPDATE_SCRIPT" | grep -v "Auto-update managed" > "$temp_cron" || true
    echo "$CRON_COMMENT" >> "$temp_cron"
    echo "$cron_expr $UPDATE_SCRIPT" >> "$temp_cron"

    if crontab "$temp_cron"; then
        debug_log "Cron任务添加成功"
        rm -f "$temp_cron"
        return 0
    else
        debug_log "Cron任务添加失败"
        rm -f "$temp_cron"
        return 1
    fi
}

create_update_script() {
    debug_log "开始创建自动更新脚本"

    cat > "$UPDATE_SCRIPT" << 'EOF'
#!/bin/bash

# 自动系统更新脚本 v4.7.3 - 修复内核清理逻辑

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

log_update() {
    local msg="$1"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $msg" | tee -a "$LOGFILE"
}

stop_conflicting_services() {
    log_update "停止可能冲突的自动更新服务..."

    systemctl stop apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
    systemctl disable apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
    systemctl stop apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
    systemctl kill --kill-who=all apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
    systemctl stop unattended-upgrades 2>/dev/null || true
    systemctl stop packagekit 2>/dev/null || true

    log_update "等待所有 apt/dpkg 进程结束..."
    local waited=0
    while pgrep -x "apt-get|apt|dpkg|unattended" >/dev/null 2>&1; do
        if [[ $waited -ge 60 ]]; then
            log_update "强制终止残留进程..."
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

    log_update "冲突服务已停止"
}

wait_for_dpkg() {
    local waited=0

    log_update "检查 dpkg/apt 锁状态..."

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
            log_update "锁检查完成，可以继续"
            return 0
        fi

        log_update "等待锁释放... ($waited/$MAX_WAIT_LOCK 秒)"
        sleep $LOCK_CHECK_INTERVAL
        waited=$((waited + LOCK_CHECK_INTERVAL))
    done

    log_update "警告: 等待超时，强制清理锁文件..."

    pkill -9 -x apt-get || true
    pkill -9 -x apt || true
    pkill -9 -x dpkg || true
    sleep 3

    rm -f /var/lib/dpkg/lock-frontend \
          /var/lib/dpkg/lock \
          /var/lib/apt/lists/lock \
          /var/cache/apt/archives/lock 2>/dev/null || true

    sleep 2
    log_update "锁文件已清理"
    return 0
}

ensure_packages_configured() {
    log_update "验证包配置状态..."

    wait_for_dpkg

    log_update "执行 dpkg --configure -a..."
    if ! dpkg --configure -a 2>&1 | tee -a "$LOGFILE"; then
        log_update "警告: dpkg 配置失败，检查问题包..."

        local broken_pkgs
        broken_pkgs=$(dpkg -l 2>/dev/null | awk '$1 ~ /^i[UFH]/ {print $2}')

        if [[ -n "$broken_pkgs" ]]; then
            log_update "发现配置异常的包，尝试修复..."
            echo "$broken_pkgs" | while read -r pkg; do
                [[ -z "$pkg" ]] && continue
                log_update "修复: $pkg"

                wait_for_dpkg

                if timeout 300 apt-get install --reinstall $APT_OPTIONS "$pkg" 2>&1 | tee -a "$LOGFILE"; then
                    log_update "✓ 重装成功: $pkg"
                else
                    log_update "重装失败，尝试删除: $pkg"
                    wait_for_dpkg
                    apt-get purge -y --force-yes "$pkg" 2>&1 | tee -a "$LOGFILE" || true
                fi

                sleep 2
            done
        fi

        wait_for_dpkg
        dpkg --configure -a 2>&1 | tee -a "$LOGFILE" || true
    fi

    wait_for_dpkg

    log_update "修复依赖关系..."
    if ! apt-get install -f $APT_OPTIONS 2>&1 | tee -a "$LOGFILE"; then
        log_update "警告: 依赖修复出现问题，重试..."
        sleep 5
        wait_for_dpkg
        apt-get install -f $APT_OPTIONS 2>&1 | tee -a "$LOGFILE" || true
    fi

    wait_for_dpkg

    log_update "包状态统计:"
    local status_summary
    status_summary=$(dpkg -l 2>/dev/null | awk 'NR>5 && $1 ~ /^[a-z]/ {print $1}' | sort | uniq -c)
    if [[ -n "$status_summary" ]]; then
        echo "$status_summary" | while read -r count status; do
            log_update "  $count [$status]"
        done
    fi

    local rc_count
    rc_count=$(dpkg -l 2>/dev/null | awk '$1 == "rc"' | wc -l)
    if [[ $rc_count -gt 0 ]]; then
        log_update "发现 $rc_count 个残留配置文件"

        if [[ $rc_count -lt 50 ]]; then
            log_update "批量清理残留配置..."
            wait_for_dpkg

            dpkg -l 2>/dev/null | awk '$1 == "rc" {print $2}' | \
                xargs -r -n 10 dpkg --purge --force-all 2>&1 | tee -a "$LOGFILE" || true

            log_update "残留配置清理完成"
        else
            log_update "残留配置过多，跳过自动清理"
        fi
    fi
}

clean_old_kernels() {
    local current_kernel
    current_kernel=$(uname -r)
    log_update "当前内核: $current_kernel"

    # 获取所有已安装的 versioned 内核 image 包，按版本升序排列
    local all_kernels
    all_kernels=$(dpkg -l | awk '/^ii[[:space:]]+linux-image-[0-9]/ {print $2}' | sort -V)

    local kernel_count
    kernel_count=$(echo "$all_kernels" | grep -c . || echo 0)
    log_update "已安装内核数量: $kernel_count"

    if [[ $kernel_count -le 2 ]]; then
        log_update "内核数量 <= 2，无需清理"
        return 0
    fi

    # 排除当前内核后，head -n -1 保留最新的 1 个作为备份，其余全部删除
    local kernels_to_remove
    kernels_to_remove=$(echo "$all_kernels" | grep -v "$current_kernel" | head -n -1)

    if [[ -z "$kernels_to_remove" ]]; then
        log_update "无需清理的旧内核"
        return 0
    fi

    log_update "开始清理旧内核（保留当前 + 上一版本）..."

    echo "$kernels_to_remove" | while read -r old_kernel; do
        [[ -z "$old_kernel" ]] && continue
        local version="${old_kernel#linux-image-}"
        log_update "移除旧内核: $version"

        wait_for_dpkg

        for pkg in \
            "linux-image-${version}" \
            "linux-headers-${version}" \
            "linux-modules-${version}" \
            "linux-modules-extra-${version}"; do
            if dpkg -l "$pkg" 2>/dev/null | grep -q '^ii'; then
                if apt-get purge $APT_OPTIONS "$pkg" 2>&1 | tee -a "$LOGFILE"; then
                    log_update "  ✓ 移除: $pkg"
                else
                    log_update "  警告: 移除失败 $pkg"
                fi
            fi
        done

        sleep 2
    done

    log_update "旧内核清理完成"
}

check_boot_space() {
    local boot_usage
    boot_usage=$(df /boot 2>/dev/null | tail -1 | awk '{print $5}' | sed 's/%//' || echo 0)
    log_update "/boot 空间使用率: ${boot_usage}%"

    # 始终执行内核清理，不依赖空间阈值
    clean_old_kernels

    wait_for_dpkg

    boot_usage=$(df /boot 2>/dev/null | tail -1 | awk '{print $5}' | sed 's/%//' || echo 0)
    log_update "/boot 清理后使用率: ${boot_usage}%"
}

check_kernel_update() {
    local current
    current=$(uname -r)
    local latest
    latest=$(find /boot -name "vmlinuz-*" -printf "%f\n" 2>/dev/null | sed 's/vmlinuz-//' | sort -V | tail -1)

    if [[ -n "$latest" && "$current" != "$latest" ]]; then
        log_update "检测到新内核: $latest (当前: $current)"

        if [[ ! -f "/boot/vmlinuz-$latest" ]]; then
            log_update "错误: 内核文件不存在"
            return 1
        fi

        if [[ ! -f "/boot/initrd.img-$latest" ]]; then
            log_update "错误: initramfs 未找到，可能安装未完成"
            return 1
        fi

        if [[ ! -d "/lib/modules/$latest" ]]; then
            log_update "警告: 内核模块目录不存在"
            return 1
        fi

        log_update "新内核文件验证: 通过"
        return 0
    fi

    return 1
}

safe_reboot() {
    log_update "准备重启应用新内核..."

    log_update "最后确认包配置状态..."
    wait_for_dpkg
    dpkg --configure -a 2>&1 | tee -a "$LOGFILE" || true

    wait_for_dpkg

    local latest
    latest=$(find /boot -name "vmlinuz-*" -printf "%f\n" 2>/dev/null | sed 's/vmlinuz-//' | sort -V | tail -1)
    if [[ ! -f "/boot/initrd.img-$latest" ]]; then
        log_update "错误: initramfs 缺失，取消重启"
        return 1
    fi

    check_boot_space

    systemctl is-active sshd >/dev/null || systemctl start sshd

    sync
    log_update "系统将在60秒后重启（紧急情况可手动取消）..."
    sleep 60

    log_update "执行系统重启..."
    systemctl reboot || reboot
}

main() {
    : > "$LOGFILE"
    log_update "=== 开始自动系统更新 ==="
    log_update "系统: $(lsb_release -ds 2>/dev/null || echo 'Unknown')"
    log_update "内核: $(uname -r)"
    log_update "脚本版本: v4.7.3"

    stop_conflicting_services
    sleep 5

    log_update "--- 第一阶段: 系统准备 ---"
    wait_for_dpkg
    ensure_packages_configured
    check_boot_space

    log_update "--- 第二阶段: 系统更新 ---"
    wait_for_dpkg

    log_update "更新软件包列表..."
    if ! apt-get update 2>&1 | tee -a "$LOGFILE"; then
        log_update "警告: 软件包列表更新失败，重试..."
        sleep 5
        wait_for_dpkg
        apt-get update 2>&1 | tee -a "$LOGFILE" || true
    fi

    wait_for_dpkg

    log_update "升级系统软件包..."
    if ! DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade $APT_OPTIONS 2>&1 | tee -a "$LOGFILE"; then
        log_update "警告: 系统升级出现问题，尝试修复..."
        sleep 5
        wait_for_dpkg
        apt-get install -f $APT_OPTIONS 2>&1 | tee -a "$LOGFILE" || true
        wait_for_dpkg
        DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade $APT_OPTIONS 2>&1 | tee -a "$LOGFILE" || true
    fi

    log_update "--- 第三阶段: 清理验证 ---"
    wait_for_dpkg
    sleep 3

    ensure_packages_configured
    wait_for_dpkg

    check_boot_space
    wait_for_dpkg

    log_update "--- 第四阶段: 检查重启 ---"
    if check_kernel_update; then
        safe_reboot
    else
        log_update "无需重启（未检测到内核更新）"
    fi

    log_update "--- 第五阶段: 最终清理 ---"
    wait_for_dpkg

    log_update "保护关键包，防止 autoremove 误删..."
    apt-mark manual wireguard-tools 2>/dev/null || true

    log_update "清理不需要的软件包..."
    apt-get autoremove $APT_OPTIONS 2>&1 | tee -a "$LOGFILE" || true

    wait_for_dpkg

    log_update "清理软件包缓存..."
    apt-get autoclean 2>&1 | tee -a "$LOGFILE" || true

    log_update "恢复系统自动更新服务..."
    systemctl enable apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
    systemctl start unattended-upgrades 2>/dev/null || true

    log_update "=== 自动更新完成 ==="
}

trap 'systemctl start unattended-upgrades 2>/dev/null || true; systemctl enable apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true' EXIT

trap 'log_update "✗ 更新过程中发生错误（行号: $LINENO）"' ERR

main "$@"
EOF

    chmod +x "$UPDATE_SCRIPT"
    echo "更新脚本: 创建完成"
    debug_log "自动更新脚本创建成功"
    return 0
}

setup_cron_job() {
    debug_log "开始配置Cron任务"

    if has_cron_job; then
        local replace
        read -p "检测到现有任务，是否替换? [y/N] (默认: N): " -r replace || replace="N"
        replace=${replace:-N}
        if [[ ! "$replace" =~ ^[Yy]$ ]]; then
            echo "定时任务: 保持现有"
            debug_log "用户选择保持现有Cron任务"
            return 0
        fi
    fi

    local cron_expr
    if ! cron_expr=$(get_cron_schedule); then
        debug_log "获取Cron时间失败"
        return 1
    fi

    if add_cron_job "$cron_expr"; then
        echo "定时任务: 配置成功"
        debug_log "Cron任务配置成功"
        return 0
    else
        echo "定时任务: 配置失败"
        debug_log "Cron任务配置失败"
        return 1
    fi
}

test_update_script() {
    debug_log "询问是否测试更新脚本"

    local test_choice
    read -p "是否测试自动更新脚本? [y/N] (默认: N): " -r test_choice || test_choice="N"
    test_choice=${test_choice:-N}

    if [[ "$test_choice" =~ ^[Yy]$ ]]; then
        debug_log "用户选择测试脚本"
        echo "警告: 将执行真实的系统更新"
        local confirm
        read -p "确认继续? [y/N] (默认: N): " -r confirm || confirm="N"
        confirm=${confirm:-N}

        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            debug_log "开始执行测试脚本"
            echo "开始测试更新脚本..."
            echo "========================================="

            set +e
            "$UPDATE_SCRIPT"
            local test_exit_code=$?
            set -e

            echo "========================================="

            if [[ $test_exit_code -eq 0 ]]; then
                echo "✅ 测试执行成功，详细日志: $UPDATE_LOG"
                debug_log "测试脚本执行成功"
            else
                echo "⚠️  测试完成但返回非零退出码 ($test_exit_code)"
                echo "   详细日志: $UPDATE_LOG"
                debug_log "测试脚本退出码: $test_exit_code"
            fi
        else
            echo "已取消测试"
            debug_log "用户取消测试"
        fi
    else
        echo "跳过脚本测试"
        debug_log "用户跳过脚本测试"
    fi

    return 0
}

show_update_summary() {
    debug_log "显示自动更新配置摘要"
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

    if [[ -x "$UPDATE_SCRIPT" ]]; then
        echo "  更新脚本: 已创建"
    else
        echo "  更新脚本: 未找到"
    fi

    if systemctl is-active cron >/dev/null 2>&1; then
        echo "  Cron服务: 运行中"
    else
        echo "  Cron服务: 未运行"
    fi

    if [[ -f "$UPDATE_LOG" ]]; then
        echo "  更新日志: 存在"
    else
        echo "  更新日志: 待生成"
    fi
    return 0
}

main() {
    debug_log "开始自动更新系统配置"
    log "🔄 配置自动更新系统..." "info"

    echo
    echo "功能: 定时自动更新系统软件包和安全补丁"
    echo "版本: v4.7.3 (修复内核清理逻辑)"

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
    echo "  删除任务: crontab -l | grep -v '$UPDATE_SCRIPT' | crontab -"
    echo "  检查状态: dpkg -l | awk 'NR>5 {print \$1}' | sort | uniq -c"
    echo "  检查锁状态: lsof /var/lib/dpkg/lock-frontend"
    echo "  检查进程: pgrep -a apt"

    return 0
}

trap 'exit_code=$?; if [[ $exit_code -ne 0 && $exit_code -ne 130 ]]; then log "脚本异常退出，行号: $LINENO，退出码: $exit_code" "error"; fi' ERR

main "$@"

exit 0
