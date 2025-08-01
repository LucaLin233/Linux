#!/bin/bash
# 自动更新系统配置模块 v4.2
# 优化用户体验，统一交互风格，添加cron依赖检查

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

# === 依赖检查函数 ===

# 检查并安装cron
ensure_cron_installed() {
    log "检查cron服务..." "info"
    
    # 检查crontab命令是否存在
    if ! command -v crontab >/dev/null 2>&1; then
        log "未检测到cron服务，正在安装..." "warn"
        
        # 更新包列表
        if ! apt-get update >/dev/null 2>&1; then
            log "✗ 无法更新软件包列表" "error"
            return 1
        fi
        
        # 安装cron
        if apt-get install -y cron >/dev/null 2>&1; then
            log "✓ cron安装成功" "info"
        else
            log "✗ cron安装失败" "error"
            return 1
        fi
    else
        log "✓ cron服务已安装" "info"
    fi
    
    # 检查cron服务状态
    if systemctl is-enabled cron >/dev/null 2>&1; then
        log "✓ cron服务已启用" "info"
    else
        log "启用cron服务..." "info"
        if systemctl enable cron >/dev/null 2>&1; then
            log "✓ cron服务已启用" "info"
        else
            log "✗ 无法启用cron服务" "error"
            return 1
        fi
    fi
    
    # 检查cron服务运行状态
    if systemctl is-active cron >/dev/null 2>&1; then
        log "✓ cron服务正在运行" "info"
    else
        log "启动cron服务..." "info"
        if systemctl start cron >/dev/null 2>&1; then
            log "✓ cron服务已启动" "info"
        else
            log "✗ 无法启动cron服务" "error"
            return 1
        fi
    fi
    
    return 0
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

# 获取用户选择的cron时间（优化版）
get_cron_schedule() {
    echo >&2
    log "自动更新时间配置:" "info" >&2
    log "  推荐使用默认时间（每周日凌晨2点），避开使用高峰" "info" >&2
    echo >&2
    
    read -p "使用默认时间 (每周日凌晨2点) ? [Y/n] (默认: Y): " choice </dev/tty >&2
    
    if [[ "$choice" =~ ^[Nn]$ ]]; then
        echo >&2
        log "自定义Cron时间:" "info" >&2
        log "  格式: 分 时 日 月 周" "info" >&2
        log "  示例: 0 3 * * 1 (每周一凌晨3点)" "info" >&2
        log "  示例: 30 1 1 * * (每月1号凌晨1点30分)" "info" >&2
        echo >&2
        
        while true; do
            read -p "请输入Cron表达式: " custom_expr </dev/tty >&2
            if [[ -n "$custom_expr" ]] && validate_cron_expression "$custom_expr"; then
                log "✓ Cron表达式验证通过" "info" >&2
                echo "$custom_expr"
                return
            else
                log "✗ 格式错误，请重新输入" "error" >&2
            fi
        done
    else
        log "✓ 使用默认时间配置" "info" >&2
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
# 自动系统更新脚本 v4.2

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

# 配置cron任务（优化版）
setup_cron_job() {
    log "配置定时任务..." "info"
    
    if has_cron_job; then
        echo
        log "检测到现有的自动更新任务" "warn"
        read -p "是否替换现有任务? [y/N] (默认: N): " -r replace
        if [[ ! "$replace" =~ ^[Yy]$ ]]; then
            log "保持现有任务不变" "info"
            return 0
        fi
    fi
    
    local cron_expr=$(get_cron_schedule)
    
    if add_cron_job "$cron_expr"; then
        log "✓ Cron任务配置成功" "info"
        
        echo
        log "📋 任务配置详情:" "info"
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

# 测试更新脚本（优化版）
test_update_script() {
    echo
    log "自动更新脚本测试:" "info"
    log "  可以测试脚本功能，但会执行真实的系统更新" "info"
    echo
    
    read -p "是否测试自动更新脚本? [y/N] (默认: N): " -r test_choice
    
    if [[ "$test_choice" =~ ^[Yy]$ ]]; then
        echo
        log "⚠ 警告: 这将执行真实的系统更新操作!" "warn"
        log "⚠ 可能会下载和安装软件包，并可能重启系统!" "warn"
        echo
        read -p "确认继续测试? [y/N] (默认: N): " -r confirm
        
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            log "开始测试自动更新脚本..." "info"
            echo "========================================="
            "$UPDATE_SCRIPT"
            echo "========================================="
            log "✓ 测试完成! 查看详细日志: $UPDATE_LOG" "info"
        else
            log "已取消测试" "info"
        fi
    else
        log "跳过脚本测试" "info"
    fi
}

# 显示自动更新配置摘要
show_update_summary() {
    echo
    log "🎯 自动更新配置摘要:" "info"
    
    # Cron任务状态
    if has_cron_job; then
        local cron_line=$(crontab -l 2>/dev/null | grep "$UPDATE_SCRIPT" | head -1)
        local cron_time=$(echo "$cron_line" | awk '{print $1, $2, $3, $4, $5}')
        log "  ✓ 定时任务: 已配置" "info"
        log "  ⏰ 执行时间: $(explain_cron_time "$cron_time")" "info"
    else
        log "  ✗ 定时任务: 未配置" "warn"
    fi
    
    # 脚本状态
    if [[ -x "$UPDATE_SCRIPT" ]]; then
        log "  ✓ 更新脚本: 已创建" "info"
        log "  📄 脚本路径: $UPDATE_SCRIPT" "info"
    else
        log "  ✗ 更新脚本: 未找到" "warn"
    fi
    
    # 日志文件状态
    if [[ -f "$UPDATE_LOG" ]]; then
        local log_size=$(du -h "$UPDATE_LOG" 2>/dev/null | awk '{print $1}' || echo "0")
        log "  📊 日志文件: 存在 ($log_size)" "info"
    else
        log "  📊 日志文件: 不存在" "info"
    fi
    
    # 系统信息
    local last_update=$(stat -c %y /var/lib/apt/lists 2>/dev/null | cut -d' ' -f1 || echo "未知")
    log "  🔄 上次apt更新: $last_update" "info"
    
    # Cron服务状态
    if systemctl is-active cron >/dev/null 2>&1; then
        log "  ✓ Cron服务: 运行中" "info"
    else
        log "  ✗ Cron服务: 未运行" "warn"
    fi
}

# === 主流程 ===
main() {
    log "🔄 配置自动更新系统..." "info"
    
    echo
    log "自动更新功能说明:" "info"
    log "  • 自动更新系统软件包和安全补丁" "info"
    log "  • 检测内核更新并智能重启" "info"
    log "  • 清理无用的软件包和缓存" "info"
    log "  • 记录详细的更新日志" "info"
    
    echo
    # 首先确保cron已安装并运行
    if ! ensure_cron_installed; then
        log "✗ cron服务配置失败，无法继续" "error"
        return 1
    fi
    
    echo
    create_update_script
    
    echo
    setup_cron_job
    
    test_update_script
    
    show_update_summary
    
    echo
    log "🎉 自动更新系统配置完成!" "info"
    
    # 显示常用命令
    echo
    log "常用命令:" "info"
    log "  手动执行更新: $UPDATE_SCRIPT" "info"
    log "  查看更新日志: tail -f $UPDATE_LOG" "info"
    log "  查看cron任务: crontab -l" "info"
    log "  编辑cron任务: crontab -e" "info"
    log "  删除自动更新: crontab -l | grep -v '$UPDATE_SCRIPT' | crontab -" "info"
    log "  查看cron服务状态: systemctl status cron" "info"
}

main "$@"
