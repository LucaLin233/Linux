#!/bin/bash
# 自动更新系统配置模块 (简化版 v4.0)
# 简化逻辑：默认时间 + 自定义选项

set -euo pipefail

# === 常量定义 ===
readonly UPDATE_SCRIPT="/root/auto-update.sh"
readonly UPDATE_LOG="/var/log/auto-update.log"
readonly DEFAULT_CRON="0 2 * * 0"
readonly CRON_COMMENT="# Auto-update managed by debian_setup"

# === 日志函数 ===
log() {
    local msg="$1" level="${2:-info}"
    local -A colors=([info]="\033[0;36m" [warn]="\033[0;33m" [error]="\033[0;31m")
    echo -e "${colors[$level]:-\033[0;32m}$msg\033[0m"
}

# === 核心函数 ===

# 简化的cron验证
validate_cron_expression() {
    [[ "$1" =~ ^[0-9*,/-]+[[:space:]]+[0-9*,/-]+[[:space:]]+[0-9*,/-]+[[:space:]]+[0-9*,/-]+[[:space:]]+[0-9*,/-]+$ ]]
}

# 检查是否已有cron任务
has_cron_job() {
    crontab -l 2>/dev/null | grep -q "$UPDATE_SCRIPT"
}

# 添加cron任务
add_cron_job() {
    local cron_expr="$1"
    local temp_cron=$(mktemp)
    
    # 移除旧的，添加新的
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

# 获取用户选择的cron时间
get_cron_schedule() {
    echo >&2
    read -p "使用默认时间 (每周日凌晨2点) ? [Y/n]: " choice </dev/tty >&2
    
    if [[ "$choice" =~ ^[Nn]$ ]]; then
        echo >&2
        log "Cron格式: 分 时 日 月 周 (例: 0 2 * * 0)" "info" >&2
        while true; do
            read -p "请输入Cron表达式: " custom_expr </dev/tty >&2
            if [[ -n "$custom_expr" ]] && validate_cron_expression "$custom_expr"; then
                echo "$custom_expr"
                return
            else
                log "格式错误，请重新输入" "error" >&2
            fi
        done
    else
        echo "$DEFAULT_CRON"
    fi
}

# 解释cron时间
explain_cron_time() {
    local cron_time="$1"
    if [[ "$cron_time" == "$DEFAULT_CRON" ]]; then
        echo "每周日凌晨2点"
    else
        echo "自定义时间: $cron_time"
    fi
}

# 创建自动更新脚本
create_update_script() {
    log "创建自动更新脚本..." "info"
    
    cat > "$UPDATE_SCRIPT" << 'EOF'
#!/bin/bash
# 自动系统更新脚本 v4.0

set -euo pipefail

readonly LOGFILE="/var/log/auto-update.log"
readonly APT_OPTIONS="-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold -o APT::ListChanges::Frontend=none"

log_update() {
    local msg="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $msg" | tee -a "$LOGFILE"
}

check_kernel_update() {
    local current=$(uname -r)
    local latest=$(find /boot -name "vmlinuz-*" -printf "%f\n" 2>/dev/null | sed 's/vmlinuz-//' | sort -V | tail -1)
    
    if [[ -n "$latest" && "$current" != "$latest" ]]; then
        log_update "检测到新内核: $latest (当前: $current)"
        return 0
    fi
    
    return 1
}

safe_reboot() {
    log_update "准备重启系统应用新内核..."
    systemctl is-active sshd >/dev/null || systemctl start sshd
    sync
    log_update "系统将在30秒后重启..."
    sleep 30
    systemctl reboot || reboot
}

main() {
    : > "$LOGFILE"
    log_update "=== 开始自动系统更新 ==="
    
    log_update "更新软件包列表..."
    apt-get update >> "$LOGFILE" 2>&1
    
    log_update "升级系统软件包..."
    DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade $APT_OPTIONS >> "$LOGFILE" 2>&1
    
    if check_kernel_update; then
        safe_reboot
    fi
    
    log_update "清理系统缓存..."
    apt-get autoremove -y >> "$LOGFILE" 2>&1
    apt-get autoclean >> "$LOGFILE" 2>&1
    
    log_update "=== 自动更新完成 ==="
}

trap 'log_update "✗ 更新过程中发生错误"' ERR
main "$@"
EOF

    chmod +x "$UPDATE_SCRIPT"
    log "✓ 自动更新脚本创建完成" "info"
}

# 配置cron任务
setup_cron_job() {
    log "配置定时任务..." "info"
    
    if has_cron_job; then
        echo
        log "检测到现有的自动更新任务" "warn"
        read -p "是否替换现有任务? [y/N]: " -r replace
        if [[ ! "$replace" =~ ^[Yy]$ ]]; then
            log "保持现有任务不变" "info"
            return 0
        fi
    fi
    
    local cron_expr=$(get_cron_schedule)
    
    if add_cron_job "$cron_expr"; then
        log "✓ Cron任务配置成功" "info"
        
        echo
        log "📋 配置摘要:" "info"
        log "  执行时间: $(explain_cron_time "$cron_expr")" "info"
        log "  脚本路径: $UPDATE_SCRIPT" "info"
        log "  日志文件: $UPDATE_LOG" "info"
        
        echo
        log "当前cron任务:" "info"
        crontab -l | grep -E "(Auto-update|$UPDATE_SCRIPT)" | sed 's/^/  /'
    else
        log "✗ Cron任务配置失败" "error"
        return 1
    fi
}

# 测试更新脚本
test_update_script() {
    echo
    read -p "是否测试自动更新脚本? [y/N]: " -r test_choice
    
    if [[ "$test_choice" =~ ^[Yy]$ ]]; then
        log "⚠ 注意: 这将执行真实的系统更新!" "warn"
        read -p "确认继续? [y/N]: " -r confirm
        
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            log "开始测试更新..." "info"
            echo "----------------------------------------"
            "$UPDATE_SCRIPT"
            echo "----------------------------------------"
            log "✓ 测试完成! 日志: $UPDATE_LOG" "info"
        fi
    fi
}

# === 主流程 ===
main() {
    log "🔄 配置自动更新系统..." "info"
    
    create_update_script
    echo
    setup_cron_job
    test_update_script
    
    echo
    log "🎉 自动更新系统配置完成!" "info"
}

main "$@"
