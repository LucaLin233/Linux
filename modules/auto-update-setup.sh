#!/bin/bash
# 自动更新系统配置模块 (优化版 v3.0)
# 优化: 模块化设计、减少重复代码、更好的错误处理

set -euo pipefail

# === 常量定义 ===
readonly UPDATE_SCRIPT="/root/auto-update.sh"
readonly UPDATE_LOG="/var/log/auto-update.log"
readonly DEFAULT_CRON="0 2 * * 0"
readonly CRON_COMMENT="# Auto-update managed by debian_setup"
readonly TEMP_DIR="/tmp/auto-update-setup"

# === 日志函数 (兼容性检查) ===
if ! command -v log &> /dev/null; then
    log() {
        local msg="$1" level="${2:-info}"
        local -A colors=([info]="\033[0;36m" [warn]="\033[0;33m" [error]="\033[0;31m")
        echo -e "${colors[$level]:-\033[0;32m}$msg\033[0m"
    }
fi

# === 核心函数 ===

# 清理函数
cleanup() {
    [[ -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

# Cron 表达式验证
validate_cron_expression() {
    local expr="$1"
    [[ "$expr" =~ ^([0-9*,-/]+[[:space:]]+){4}[0-9*,-/]+$ ]]
}

# Cron 任务管理
manage_cron_job() {
    local action="$1" 
    local cron_expr="${2:-}"
    local temp_cron
    
    temp_cron=$(mktemp) || { log "创建临时文件失败" "error"; return 1; }
    
    case "$action" in
        "add")
            # 移除旧任务，添加新任务
            crontab -l 2>/dev/null | grep -v "$UPDATE_SCRIPT" > "$temp_cron" || true
            echo "$CRON_COMMENT" >> "$temp_cron"
            echo "$cron_expr $UPDATE_SCRIPT" >> "$temp_cron"
            ;;
        "remove")
            crontab -l 2>/dev/null | grep -v "$UPDATE_SCRIPT" > "$temp_cron" || true
            ;;
        "check")
            crontab -l 2>/dev/null | grep -q "$UPDATE_SCRIPT"
            rm -f "$temp_cron"
            return $?
            ;;
    esac
    
    if crontab "$temp_cron"; then
        rm -f "$temp_cron"
        return 0
    else
        rm -f "$temp_cron"
        return 1
    fi
}

# 显示 Cron 选项
show_cron_options() {
    cat << 'EOF'

⏰ 选择自动更新时间:
  1) 每周日凌晨2点 (默认推荐)
  2) 每周一凌晨3点
  3) 每周六凌晨4点  
  4) 每月1号凌晨1点
  5) 自定义时间
  
EOF
}

# 获取用户选择的 Cron 时间
get_cron_schedule() {
    local choice cron_expr custom_expr
    
    show_cron_options
    
    while true; do
        read -p "请选择 [1-5]: " choice
        
        case "$choice" in
            1) cron_expr="0 2 * * 0"; break ;;
            2) cron_expr="0 3 * * 1"; break ;;
            3) cron_expr="0 4 * * 6"; break ;;
            4) cron_expr="0 1 1 * *"; break ;;
            5) 
                echo
                log "Cron格式: 分 时 日 月 周 (例: 0 2 * * 0)" "info"
                while true; do
                    read -p "请输入Cron表达式: " custom_expr
                    if validate_cron_expression "$custom_expr"; then
                        cron_expr="$custom_expr"
                        break 2
                    else
                        log "格式错误，请重新输入" "error"
                    fi
                done
                ;;
            *) log "无效选择，请输入1-5" "error" ;;
        esac
    done
    
    echo "$cron_expr"
}

# 解释 Cron 时间
explain_cron_time() {
    local cron_time="$1"
    case "$cron_time" in
        "0 2 * * 0") echo "每周日凌晨2点" ;;
        "0 3 * * 1") echo "每周一凌晨3点" ;;
        "0 4 * * 6") echo "每周六凌晨4点" ;;
        "0 1 1 * *") echo "每月1号凌晨1点" ;;
        *) echo "自定义时间: $cron_time" ;;
    esac
}

# 创建优化的自动更新脚本
create_update_script() {
    log "创建自动更新脚本..." "info"
    
    cat > "$UPDATE_SCRIPT" << 'EOF'
#!/bin/bash
# 自动系统更新脚本 v3.0 (优化版)
# 功能: 系统更新、内核检查、智能重启

set -euo pipefail

readonly LOGFILE="/var/log/auto-update.log"
readonly APT_OPTIONS="-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold -o APT::ListChanges::Frontend=none"

# 日志函数
log_update() {
    local msg="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $msg" | tee -a "$LOGFILE"
}

# 检查内核更新
check_kernel_update() {
    local current=$(uname -r)
    local latest
    
    # 获取最新安装的内核版本
    latest=$(find /boot -name "vmlinuz-*" -printf "%f\n" 2>/dev/null | \
             sed 's/vmlinuz-//' | sort -V | tail -1)
    
    if [[ -n "$latest" && "$current" != "$latest" ]]; then
        log_update "检测到新内核: $latest (当前: $current)"
        return 0
    fi
    
    log_update "内核已是最新版本: $current"
    return 1
}

# 安全重启
safe_reboot() {
    log_update "准备重启系统应用新内核..."
    
    # 确保关键服务运行
    systemctl is-active sshd >/dev/null || systemctl start sshd
    
    # 同步文件系统
    sync
    
    log_update "系统将在30秒后重启..."
    sleep 30
    
    # 添加错误检查
    if ! reboot; then
        log_update "✗ 重启失败，请手动重启应用新内核"
        exit 1
    fi
}

# 主更新流程
main() {
    # 初始化日志
    : > "$LOGFILE"
    log_update "=== 开始自动系统更新 ==="
    
    # 更新软件包列表
    log_update "更新软件包列表..."
    if apt-get update >> "$LOGFILE" 2>&1; then
        log_update "✓ 软件包列表更新成功"
    else
        log_update "✗ 软件包列表更新失败"
        exit 1
    fi
    
    # 升级系统
    log_update "升级系统软件包..."
    if DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade $APT_OPTIONS >> "$LOGFILE" 2>&1; then
        log_update "✓ 系统升级完成"
    else
        log_update "✗ 系统升级失败"
        exit 1
    fi
    
    # 清理系统
    log_update "清理系统缓存..."
    apt-get autoremove -y >> "$LOGFILE" 2>&1
    apt-get autoclean >> "$LOGFILE" 2>&1
    log_update "✓ 系统清理完成"
    
    # 检查内核更新
    if check_kernel_update; then
        safe_reboot
    else
        log_update "=== 自动更新完成，无需重启 ==="
    fi
}

# 错误处理
trap 'log_update "✗ 更新过程中发生错误"' ERR

# 执行主流程
main "$@"
EOF

    chmod +x "$UPDATE_SCRIPT"
    log "✓ 自动更新脚本创建完成: $UPDATE_SCRIPT" "info"
}

# 显示现有 Cron 任务
show_current_cron() {
    log "当前Cron任务:" "info"
    if crontab -l 2>/dev/null | grep -q .; then
        crontab -l 2>/dev/null | sed 's/^/  /'
    else
        log "  (暂无Cron任务)" "info"
    fi
}

# 配置 Cron 任务
setup_cron_job() {
    local cron_expr
    
    log "配置定时任务..." "info"
    echo
    
    # 检查现有任务
    if manage_cron_job "check"; then
        log "检测到现有的自动更新任务" "warn"
        read -p "是否替换现有任务? [y/N]: " -r replace
        [[ ! "$replace" =~ ^[Yy]$ ]] && { log "保持现有任务不变" "info"; return 0; }
    fi
    
    # 获取用户选择
    cron_expr=$(get_cron_schedule)
    
    # 配置任务
    if manage_cron_job "add" "$cron_expr"; then
        log "✓ Cron任务配置成功" "info"
        
        echo
        log "📋 配置摘要:" "info"
        log "  执行时间: $(explain_cron_time "$cron_expr")" "info"
        log "  脚本路径: $UPDATE_SCRIPT" "info"
        log "  日志文件: $UPDATE_LOG" "info"
        log "  手动执行: $UPDATE_SCRIPT" "info"
    else
        log "✗ Cron任务配置失败" "error"
        return 1
    fi
}

# 测试更新脚本
test_update_script() {
    echo
    read -p "是否测试自动更新脚本? (不会重启) [y/N]: " -r test_choice
    
    if [[ "$test_choice" =~ ^[Yy]$ ]]; then
        log "⚠ 注意: 这将执行真实的系统更新!" "warn"
        read -p "确认继续? [y/N]: " -r confirm
        
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            log "开始测试更新..." "info"
            echo "----------------------------------------"
            "$UPDATE_SCRIPT"
            echo "----------------------------------------"
            log "✓ 测试完成! 日志文件: $UPDATE_LOG" "info"
        fi
    fi
}

# === 主执行流程 ===
main() {
    log "🔄 配置自动更新系统..." "info"
    
    # 创建临时目录
    mkdir -p "$TEMP_DIR"
    
    # 创建更新脚本
    create_update_script
    
    echo
    
    # 显示当前状态
    show_current_cron
    
    echo
    
    # 配置定时任务
    setup_cron_job
    
    # 测试脚本
    test_update_script
    
    echo
    log "🎉 自动更新系统配置完成!" "info"
}

# 执行主流程
main "$@"
