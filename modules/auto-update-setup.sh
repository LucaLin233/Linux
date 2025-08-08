#!/bin/bash
# 自动更新系统配置模块 v4.3 - 简化版
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
    local -A colors=([info]="\033[0;36m" [warn]="\033[0;33m" [error]="\033[0;31m")
    echo -e "${colors[$level]:-\033[0;32m}$msg\033[0m"
}

# === 依赖检查函数 ===

# 检查并安装cron
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

# 获取用户选择的cron时间 - 修复版本
get_cron_schedule() {
    read -p "使用默认时间 (每周日凌晨2点)? [Y/n] (默认: Y): " choice >&2
    choice=${choice:-Y}
    
    if [[ "$choice" =~ ^[Nn]$ ]]; then
        echo "自定义时间格式: 分 时 日 月 周 (如: 0 3 * * 1)" >&2
        
        while true; do
            read -p "请输入Cron表达式: " custom_expr >&2
            if [[ -n "$custom_expr" ]] && validate_cron_expression "$custom_expr"; then
                echo "Cron时间: 自定义 ($custom_expr)" >&2
                echo "$custom_expr"
                return
            else
                echo "格式错误，请重新输入" >&2
            fi
        done
    else
        echo "Cron时间: 每周日凌晨2点" >&2
        echo "$DEFAULT_CRON"
    fi
}

# 创建自动更新脚本
create_update_script() {
    cat > "$UPDATE_SCRIPT" << 'EOF'
#!/bin/bash
# 自动系统更新脚本 v4.3

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
    echo "更新脚本: 创建完成"
}

# 配置cron任务
setup_cron_job() {
    if has_cron_job; then
        read -p "检测到现有任务，是否替换? [y/N] (默认: N): " -r replace
        replace=${replace:-N}
        if [[ ! "$replace" =~ ^[Yy]$ ]]; then
            echo "定时任务: 保持现有"
            return 0
        fi
    fi
    
    local cron_expr=$(get_cron_schedule)
    
    if add_cron_job "$cron_expr"; then
        echo "定时任务: 配置成功"
    else
        echo "定时任务: 配置失败"
        return 1
    fi
}

# 测试更新脚本
test_update_script() {
    read -p "是否测试自动更新脚本? [y/N] (默认: N): " -r test_choice
    test_choice=${test_choice:-N}
    
    if [[ "$test_choice" =~ ^[Yy]$ ]]; then
        echo "警告: 将执行真实的系统更新"
        read -p "确认继续? [y/N] (默认: N): " -r confirm
        confirm=${confirm:-N}
        
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            echo "开始测试更新脚本..."
            echo "========================================="
            "$UPDATE_SCRIPT"
            echo "========================================="
            echo "测试完成，详细日志: $UPDATE_LOG"
        else
            echo "已取消测试"
        fi
    else
        echo "跳过脚本测试"
    fi
}

# 显示自动更新配置摘要
show_update_summary() {
    echo
    log "🎯 自动更新摘要:" "info"
    
    # 定时任务状态
    if has_cron_job; then
        local cron_line=$(crontab -l 2>/dev/null | grep "$UPDATE_SCRIPT" | head -1)
        local cron_time=$(echo "$cron_line" | awk '{print $1, $2, $3, $4, $5}')
        echo "  定时任务: 已配置"
        if [[ "$cron_time" == "$DEFAULT_CRON" ]]; then
            echo "  执行时间: 每周日凌晨2点"
        else
            echo "  执行时间: 自定义 ($cron_time)"
        fi
    else
        echo "  定时任务: 未配置"
    fi
    
    # 脚本和服务状态
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
    
    # 日志状态
    if [[ -f "$UPDATE_LOG" ]]; then
        echo "  更新日志: 存在"
    else
        echo "  更新日志: 待生成"
    fi
}

# === 主流程 ===
main() {
    log "🔄 配置自动更新系统..." "info"
    
    echo
    echo "功能: 定时自动更新系统软件包和安全补丁"
    
    echo
    if ! ensure_cron_installed; then
        log "✗ cron服务配置失败" "error"
        return 1
    fi
    
    echo
    create_update_script
    
    echo
    setup_cron_job
    
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
}

main "$@"
