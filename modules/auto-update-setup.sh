#!/bin/bash
# 自动更新系统配置模块 (优化版 v3.1 - 修复版)
# 优化: 模块化设计、减少重复代码、更好的错误处理
# 修复: cron选项显示、输入处理、表达式验证

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

# Cron 表达式验证 (强化版)
validate_cron_expression() {
    local expr="$1"
    
    # 基本格式检查：5个字段，用空格分隔
    local field_count=$(echo "$expr" | wc -w)
    if [[ "$field_count" -ne 5 ]]; then
        log "错误: cron表达式必须包含5个字段 (分 时 日 月 周)" "error"
        return 1
    fi
    
    # 简单的字符检查
    if [[ ! "$expr" =~ ^[0-9*,/-]+[[:space:]]+[0-9*,/-]+[[:space:]]+[0-9*,/-]+[[:space:]]+[0-9*,/-]+[[:space:]]+[0-9*,/-]+$ ]]; then
        log "错误: cron表达式包含无效字符" "error"
        return 1
    fi
    
    return 0
}

# Cron 任务管理 (修复版)
manage_cron_job() {
    local action="$1" 
    local cron_expr="${2:-}"
    local temp_cron
    
    temp_cron=$(mktemp) || { log "创建临时文件失败" "error"; return 1; }
    
    case "$action" in
        "add")
            # 验证 cron 表达式
            if [[ -z "$cron_expr" ]]; then
                log "错误: cron表达式为空" "error"
                rm -f "$temp_cron"
                return 1
            fi
            
            # 移除旧任务
            crontab -l 2>/dev/null | grep -v "$UPDATE_SCRIPT" | grep -v "Auto-update managed" > "$temp_cron" || true
            
            # 添加新任务
            echo "$CRON_COMMENT" >> "$temp_cron"
            echo "$cron_expr $UPDATE_SCRIPT" >> "$temp_cron"
            ;;
        "remove")
            crontab -l 2>/dev/null | grep -v "$UPDATE_SCRIPT" | grep -v "Auto-update managed" > "$temp_cron" || true
            ;;
        "check")
            crontab -l 2>/dev/null | grep -q "$UPDATE_SCRIPT"
            rm -f "$temp_cron"
            return $?
            ;;
    esac
    
    # 安装 crontab
    if crontab "$temp_cron" 2>/dev/null; then
        rm -f "$temp_cron"
        return 0
    else
        log "crontab安装失败，临时文件内容:" "error"
        cat "$temp_cron" | sed 's/^/  /' >&2
        rm -f "$temp_cron"
        return 1
    fi
}

# 显示 Cron 选项 (修复版)
show_cron_options() {
    echo >&2
    echo "⏰ 选择自动更新时间:" >&2
    echo "  1) 每周日凌晨2点 (默认推荐)" >&2
    echo "  2) 每周一凌晨3点" >&2
    echo "  3) 每周六凌晨4点" >&2
    echo "  4) 每月1号凌晨1点" >&2
    echo "  5) 自定义时间" >&2
    echo >&2
}

# 获取用户选择的 Cron 时间 (修复版)
get_cron_schedule() {
    local choice cron_expr custom_expr
    
    show_cron_options
    
    while true; do
        read -p "请选择 [1-5] (默认: 1): " choice </dev/tty >&2
        
        # 处理空输入，设置默认值
        [[ -z "$choice" ]] && choice="1"
        
        case "$choice" in
            1) 
                cron_expr="0 2 * * 0"
                log "已选择: 每周日凌晨2点" "info" >&2
                break 
                ;;
            2) 
                cron_expr="0 3 * * 1"
                log "已选择: 每周一凌晨3点" "info" >&2
                break 
                ;;
            3) 
                cron_expr="0 4 * * 6"
                log "已选择: 每周六凌晨4点" "info" >&2
                break 
                ;;
            4) 
                cron_expr="0 1 1 * *"
                log "已选择: 每月1号凌晨1点" "info" >&2
                break 
                ;;
            5) 
                echo >&2
                log "Cron格式: 分 时 日 月 周 (例: 0 2 * * 0)" "info" >&2
                while true; do
                    read -p "请输入Cron表达式: " custom_expr </dev/tty >&2
                    if [[ -n "$custom_expr" ]] && validate_cron_expression "$custom_expr"; then
                        cron_expr="$custom_expr"
                        log "已选择自定义时间: $custom_expr" "info" >&2
                        break 2
                    else
                        log "格式错误或为空，请重新输入" "error" >&2
                    fi
                done
                ;;
            *) 
                log "无效选择 '$choice'，请输入1-5" "error" >&2
                ;;
        esac
    done
    
    # 只输出 cron 表达式到 stdout
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

# 创建优化的自动更新脚本 (修复重启逻辑)
create_update_script() {
    log "创建自动更新脚本..." "info"
    
    cat > "$UPDATE_SCRIPT" << 'EOF'
#!/bin/bash
# 自动系统更新脚本 v3.1 (修复版)
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

# 安全重启 (修复版)
safe_reboot() {
    log_update "准备重启系统应用新内核..."
    
    # 确保关键服务运行
    systemctl is-active sshd >/dev/null || systemctl start sshd
    
    # 同步文件系统
    sync
    
    log_update "系统将在 30 秒后重启以应用新内核..."
    sleep 30
    
    # 强制重启，添加错误处理
    if ! systemctl reboot; then
        log_update "systemctl reboot 失败，尝试 reboot 命令"
        if ! reboot; then
            log_update "✗ 重启失败，请手动重启系统应用新内核"
            exit 1
        fi
    fi
}

# 主更新流程 (修复版)
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
    
    # 检查内核更新 - 如果有新内核立即重启
    if check_kernel_update; then
        safe_reboot
        # 注意：重启后脚本不会继续执行
    fi
    
    # 只有没有内核更新时才执行清理
    log_update "清理系统缓存..."
    apt-get autoremove -y >> "$LOGFILE" 2>&1
    apt-get autoclean >> "$LOGFILE" 2>&1
    log_update "✓ 系统清理完成"
    
    log_update "=== 自动更新完成，无需重启 ==="
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

# 配置 Cron 任务 (修复版)
setup_cron_job() {
    local cron_expr
    
    log "配置定时任务..." "info"
    
    # 检查现有任务
    if manage_cron_job "check"; then
        echo
        log "检测到现有的自动更新任务" "warn"
        read -p "是否替换现有任务? [y/N]: " -r replace
        if [[ ! "$replace" =~ ^[Yy]$ ]]; then
            log "保持现有任务不变" "info"
            return 0
        fi
    fi
    
    # 获取用户选择
    cron_expr=$(get_cron_schedule)
    
    # 验证返回的表达式
    if [[ -z "$cron_expr" ]]; then
        log "✗ 获取cron表达式失败" "error"
        return 1
    fi
    
    # 配置任务
    if manage_cron_job "add" "$cron_expr"; then
        log "✓ Cron任务配置成功" "info"
        
        echo
        log "📋 配置摘要:" "info"
        log "  执行时间: $(explain_cron_time "$cron_expr")" "info"
        log "  脚本路径: $UPDATE_SCRIPT" "info"
        log "  日志文件: $UPDATE_LOG" "info"
        log "  手动执行: $UPDATE_SCRIPT" "info"
        
        # 验证安装结果
        echo
        log "当前cron任务:" "info"
        crontab -l | grep -E "(Auto-update|$UPDATE_SCRIPT)" | sed 's/^/  /' || log "  (未找到相关任务)" "warn"
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
