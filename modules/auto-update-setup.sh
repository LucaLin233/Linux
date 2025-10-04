#!/bin/bash
# 自动更新系统配置模块 v4.6.1 - 修复计数bug
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
# 自动系统更新脚本 v4.6.1 - 修复计数bug

set -euo pipefail

readonly LOGFILE="/var/log/auto-update.log"
readonly APT_OPTIONS="-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold -o APT::ListChanges::Frontend=none"
readonly MAX_WAIT_DPKG=300

log_update() {
    local msg="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $msg" | tee -a "$LOGFILE"
}

wait_for_dpkg() {
    local waited=0
    log_update "检查dpkg锁状态..."
    
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
          fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || \
          fuser /var/cache/apt/archives/lock >/dev/null 2>&1; do
        
        if [[ $waited -ge $MAX_WAIT_DPKG ]]; then
            log_update "警告: dpkg锁等待超时，尝试强制解锁"
            rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock
            rm -f /var/lib/apt/lists/lock
            rm -f /var/cache/apt/archives/lock
            break
        fi
        
        log_update "等待dpkg解锁... ($waited/$MAX_WAIT_DPKG 秒)"
        sleep 5
        waited=$((waited + 5))
    done
    
    log_update "dpkg锁检查完成"
}

ensure_packages_configured() {
    log_update "验证包配置状态..."
    
    if ! dpkg --configure -a >> "$LOGFILE" 2>&1; then
        log_update "警告: dpkg配置出现问题，尝试修复"
    fi
    
    if ! apt-get install -f -y >> "$LOGFILE" 2>&1; then
        log_update "警告: 依赖修复出现问题"
    fi
    
    local status_summary=$(dpkg -l 2>/dev/null | awk 'NR>5 {print $1}' | sort | uniq -c)
    log_update "包状态统计:"
    echo "$status_summary" >> "$LOGFILE"
    
    local reinstall_pkgs=$(dpkg -l 2>/dev/null | awk '$1 == "ri" {print $2}')
    local reinstall_count=0
    if [[ -n "$reinstall_pkgs" ]]; then
        reinstall_count=$(echo "$reinstall_pkgs" | wc -l)
    fi
    
    if [[ $reinstall_count -gt 0 ]]; then
        log_update "发现 $reinstall_count 个需要重装的包，尝试修复..."
        echo "$reinstall_pkgs" | while read pkg; do
            [[ -z "$pkg" ]] && continue
            log_update "重装: $pkg"
            apt-get install --reinstall -y "$pkg" >> "$LOGFILE" 2>&1 || \
                log_update "警告: $pkg 重装失败"
        done
    fi
    
    local broken_pkgs=$(dpkg -l 2>/dev/null | awk '$1 ~ /^i[UFH]/ {print $2}')
    local broken_count=0
    if [[ -n "$broken_pkgs" ]]; then
        broken_count=$(echo "$broken_pkgs" | wc -l)
    fi
    
    if [[ $broken_count -gt 0 ]]; then
        log_update "警告: 发现 $broken_count 个配置异常的包"
        echo "$broken_pkgs" >> "$LOGFILE"
    else
        log_update "包配置状态: 正常"
    fi
    
    local rc_count=$(dpkg -l 2>/dev/null | awk '$1 == "rc"' | wc -l)
    if [[ $rc_count -gt 0 ]]; then
        log_update "提示: 有 $rc_count 个已删除包的配置文件残留（不影响系统）"
    fi
}

check_boot_space() {
    local boot_usage=$(df /boot 2>/dev/null | tail -1 | awk '{print $5}' | sed 's/%//' || echo 0)
    
    if [[ $boot_usage -gt 80 ]]; then
        log_update "警告: /boot 空间使用率 ${boot_usage}%，清理旧内核..."
        
        local current_kernel=$(uname -r)
        log_update "当前内核: $current_kernel"
        
        dpkg -l | grep '^ii' | grep 'linux-image-[0-9]' | \
            awk '{print $2}' | grep -v "$current_kernel" | \
            sort -V | head -n -1 | while read old_kernel; do
            log_update "移除旧内核: $old_kernel"
            apt-get purge -y "$old_kernel" >> "$LOGFILE" 2>&1 || true
        done
        
        boot_usage=$(df /boot 2>/dev/null | tail -1 | awk '{print $5}' | sed 's/%//' || echo 0)
        log_update "/boot 清理后使用率: ${boot_usage}%"
    else
        log_update "/boot 空间使用率: ${boot_usage}% (正常)"
    fi
}

check_kernel_update() {
    local current=$(uname -r)
    local latest=$(find /boot -name "vmlinuz-*" -printf "%f\n" 2>/dev/null | sed 's/vmlinuz-//' | sort -V | tail -1)
    
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
    dpkg --configure -a >> "$LOGFILE" 2>&1 || true
    
    wait_for_dpkg
    
    local latest=$(find /boot -name "vmlinuz-*" -printf "%f\n" 2>/dev/null | sed 's/vmlinuz-//' | sort -V | tail -1)
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
    
    wait_for_dpkg
    check_boot_space
    ensure_packages_configured
    
    log_update "更新软件包列表..."
    apt-get update >> "$LOGFILE" 2>&1
    
    log_update "升级系统软件包..."
    DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade $APT_OPTIONS >> "$LOGFILE" 2>&1
    
    log_update "确保所有包配置完成..."
    ensure_packages_configured
    
    if check_kernel_update; then
        safe_reboot
    else
        log_update "无需重启（未检测到内核更新）"
    fi
    
    log_update "清理系统缓存..."
    apt-get autoremove -y >> "$LOGFILE" 2>&1
    apt-get autoclean >> "$LOGFILE" 2>&1
    
    log_update "=== 自动更新完成 ==="
}

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
            if "$UPDATE_SCRIPT"; then
                debug_log "测试脚本执行成功"
            else
                debug_log "测试脚本执行失败"
            fi
            echo "========================================="
            echo "测试完成，详细日志: $UPDATE_LOG"
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
        cron_line=$(crontab -l 2>/dev/null | grep "$UPDATE_SCRIPT" | head -1)
        local cron_time
        cron_time=$(echo "$cron_line" | awk '{print $1, $2, $3, $4, $5}')
        echo "  定时任务: 已配置"
        if [[ "$cron_time" == "$DEFAULT_CRON" ]]; then
            echo "  执行时间: 每周日凌晨2点"
        else
            echo "  执行时间: 自定义 ($cron_time)"
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
    echo "版本: v4.6.1 (修复计数bug)"
    
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
    test_update_script
    
    show_update_summary
    
    echo
    log "✅ 自动更新系统配置完成!" "info"
    
    echo
    log "常用命令:" "info"
    echo "  手动执行: $UPDATE_SCRIPT"
    echo "  查看日志: tail -f $UPDATE_LOG"
    echo "  管理任务: crontab -l"
    echo "  删除任务: crontab -l | grep -v '$UPDATE_SCRIPT' | crontab -"
    echo "  检查状态: dpkg -l | awk 'NR>5 {print \$1}' | sort | uniq -c"
    
    return 0
}

trap 'log "脚本执行出错，行号: $LINENO" "error"; exit 1' ERR

main "$@"
