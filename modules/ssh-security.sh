#!/bin/bash
# SSH 安全配置模块 v5.1 - 智能安全版
# 功能: SSH端口配置、密码认证控制、安全策略设置

set -euo pipefail

# === 常量定义 ===
readonly SSH_CONFIG="/etc/ssh/sshd_config"
readonly AUTHORIZED_KEYS="$HOME/.ssh/authorized_keys"

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
# 备份SSH配置
backup_ssh_config() {
    debug_log "开始备份SSH配置"
    if [[ -f "$SSH_CONFIG" ]]; then
        if cp "$SSH_CONFIG" "$SSH_CONFIG.backup.$(date +%s)" 2>/dev/null; then
            debug_log "SSH配置已备份"
            echo "SSH配置: 已备份"
            return 0
        else
            log "SSH配置备份失败" "error"
            return 1
        fi
    else
        log "SSH配置文件不存在" "error"
        return 1
    fi
}

# 获取当前SSH端口
get_current_ssh_ports() {
    debug_log "获取当前SSH端口"
    local ports
    if ports=$(grep "^Port " "$SSH_CONFIG" 2>/dev/null | awk '{print $2}'); then
        if [[ -n "$ports" ]]; then
            echo "$ports" | tr '\n' ' ' | sed 's/ $//'
        else
            echo "22"
        fi
    else
        echo "22"
    fi
    return 0
}

# 验证端口号
validate_port() {
    local port="$1"
    local current_ports="${2:-}"
    
    debug_log "验证端口: $port, 当前端口: $current_ports"
    
    # 检查格式和范围
    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1024 || port > 65535 )); then
        debug_log "端口格式或范围无效: $port"
        return 1
    fi
    
    # 如果是当前SSH端口，允许通过
    if [[ "$current_ports" == *"$port"* ]]; then
        debug_log "端口是当前SSH端口，允许: $port"
        return 0
    fi
    
    # 检查是否被占用
    if ss -tuln 2>/dev/null | grep -q ":$port\b"; then
        debug_log "端口被占用: $port"
        return 1
    fi
    
    debug_log "端口验证通过: $port"
    return 0
}

# 检查SSH密钥
check_ssh_keys() {
    debug_log "检查SSH密钥"
    local key_count=0
    
    # 检查authorized_keys
    if [[ -f "$AUTHORIZED_KEYS" && -s "$AUTHORIZED_KEYS" ]]; then
        key_count=$(grep -c "^ssh-" "$AUTHORIZED_KEYS" 2>/dev/null || echo "0")
        if (( key_count > 0 )); then
            debug_log "找到 $key_count 个SSH密钥在 authorized_keys"
            return 0
        fi
    fi
    
    # 检查公钥文件
    local key_files=("$HOME/.ssh/id_rsa.pub" "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_ecdsa.pub")
    for key_file in "${key_files[@]}"; do
        if [[ -f "$key_file" ]]; then
            debug_log "找到SSH公钥文件: $key_file"
            return 0
        fi
    done
    
    debug_log "未找到SSH密钥"
    return 1
}

# 获取当前Root登录设置
get_current_root_login() {
    debug_log "获取当前Root登录设置"
    local current_setting
    if current_setting=$(grep "^PermitRootLogin" "$SSH_CONFIG" 2>/dev/null | awk '{print $2}'); then
        echo "$current_setting"
    else
        # 如果没有显式配置，SSH默认是prohibit-password
        echo "prohibit-password"
    fi
    return 0
}

# 格式化Root登录设置显示
format_root_login_display() {
    local setting="$1"
    debug_log "格式化Root登录显示: $setting"
    case "$setting" in
        "no") echo "禁止Root登录" ;;
        "prohibit-password") echo "仅允许密钥登录" ;;
        "yes") echo "允许密码登录" ;;
        *) echo "未知设置: $setting" ;;
    esac
    return 0
}

# === 核心功能函数 ===
# 选择SSH端口
choose_ssh_ports() {
    debug_log "开始选择SSH端口"
    local current_ports=$(get_current_ssh_ports)
    
    echo "当前SSH端口: $current_ports" >&2
    echo "端口配置:" >&2
    echo "  1) 保持当前 ($current_ports)" >&2
    echo "  2) 使用2222端口" >&2
    echo "  3) 使用2022端口" >&2
    echo "  4) 自定义端口" >&2
    echo >&2
    
    local choice new_ports
    read -p "请选择 [1-4] (默认: 1): " choice >&2 || choice="1"
    choice=${choice:-1}
    
    case "$choice" in
        1)
            debug_log "用户选择保持当前端口: $current_ports"
            echo "$current_ports"
            ;;
        2)
            if validate_port "2222" "$current_ports"; then
                debug_log "用户选择端口2222"
                echo "2222"
            else
                echo "端口2222不可用，保持当前端口" >&2
                echo "$current_ports"
            fi
            ;;
        3)
            if validate_port "2022" "$current_ports"; then
                debug_log "用户选择端口2022"
                echo "2022"
            else
                echo "端口2022不可用，保持当前端口" >&2
                echo "$current_ports"
            fi
            ;;
        4)
            while true; do
                read -p "输入端口号 (1024-65535): " new_ports >&2 || new_ports=""
                if [[ -z "$new_ports" ]]; then
                    echo "端口为空，保持当前端口" >&2
                    echo "$current_ports"
                    break
                elif validate_port "$new_ports" "$current_ports"; then
                    debug_log "用户自定义端口: $new_ports"
                    echo "$new_ports"
                    break
                else
                    echo "端口无效或被占用，请重新输入" >&2
                fi
            done
            ;;
        *)
            echo "无效选择，保持当前端口" >&2
            echo "$current_ports"
            ;;
    esac
    return 0
}

# 配置密码认证
configure_password_auth() {
    debug_log "开始配置密码认证"
    if check_ssh_keys; then
        local key_count=$(grep -c "^ssh-" "$AUTHORIZED_KEYS" 2>/dev/null || echo "0")
        echo "SSH密钥状态: 已配置 ($key_count 个)" >&2
        
        local disable_password
        read -p "是否禁用密码登录? [Y/n] (默认: Y): " -r disable_password >&2 || disable_password="Y"
        disable_password=${disable_password:-Y}
        
        if [[ "$disable_password" =~ ^[Yy]$ ]]; then
            echo "密码登录: 将禁用" >&2
            debug_log "用户选择禁用密码登录"
            echo "no"
        else
            echo "密码登录: 保持启用" >&2
            debug_log "用户选择启用密码登录"
            echo "yes"
        fi
    else
        echo "SSH密钥状态: 未配置" >&2
        echo "为了安全考虑，建议先配置SSH密钥后再禁用密码登录" >&2
        echo "密码登录: 保持启用" >&2
        debug_log "未找到SSH密钥，保持密码登录"
        echo "yes"
    fi
    return 0
}

# 配置Root登录策略
configure_root_login() {
    debug_log "开始配置Root登录策略"
    local current_setting=$(get_current_root_login)
    local current_display=$(format_root_login_display "$current_setting")
    
    echo "当前Root登录设置: $current_display" >&2
    echo "Root登录策略:" >&2
    echo "  1) 维持原样 ($current_display)" >&2
    echo "  2) 禁止Root登录 (推荐)" >&2
    echo "  3) 仅允许密钥登录" >&2
    echo "  4) 允许密码登录 (不推荐)" >&2
    echo >&2
    
    local choice
    read -p "请选择 [1-4] (默认: 1): " choice >&2 || choice="1"
    choice=${choice:-1}
    
    case "$choice" in
        1)
            debug_log "用户选择维持当前Root登录设置: $current_setting"
            echo "Root登录: 维持原样 ($current_display)" >&2
            echo "$current_setting"
            ;;
        2)
            debug_log "用户选择禁止Root登录"
            echo "Root登录: 禁止" >&2
            echo "no"
            ;;
        3)
            debug_log "用户选择Root仅密钥登录"
            echo "Root登录: 仅允许密钥" >&2
            echo "prohibit-password"
            ;;
        4)
            debug_log "用户选择Root允许密码登录"
            echo "Root登录: 允许密码 (不推荐)" >&2
            echo "yes"
            ;;
        *)
            debug_log "无效选择，维持当前Root登录设置: $current_setting"
            echo "无效选择，维持原样: $current_display" >&2
            echo "$current_setting"
            ;;
    esac
    return 0
}

# 生成SSH安全配置
generate_ssh_config() {
    local new_ports="$1"
    local password_auth="$2"
    local root_login="$3"
    
    debug_log "生成SSH配置: 端口=$new_ports, 密码认证=$password_auth, Root登录=$root_login"
    
    local temp_config
    if ! temp_config=$(mktemp); then
        log "无法创建临时配置文件" "error"
        return 1
    fi
    
    # 生成精简但安全的SSH配置
    if ! cat > "$temp_config" << EOF; then
# SSH daemon configuration
# Generated by ssh-security module $(date)

# Network
$(for port in $new_ports; do echo "Port $port"; done)

# Authentication
PermitRootLogin $root_login
PasswordAuthentication $password_auth
PermitEmptyPasswords no
PubkeyAuthentication yes

# Security
MaxAuthTries 3
LoginGraceTime 60
ClientAliveInterval 300
ClientAliveCountMax 2

# Disable less secure features
AllowAgentForwarding no
AllowTcpForwarding no
X11Forwarding no
UseDNS no

# System integration
UsePAM yes
PrintMotd no

# Subsystem
Subsystem sftp /usr/lib/openssh/sftp-server
EOF
        log "无法写入SSH配置文件" "error"
        rm -f "$temp_config"
        return 1
    fi
    
    echo "$temp_config"
    return 0
}

# 应用SSH配置
apply_ssh_config() {
    local temp_config="$1"
    
    debug_log "开始应用SSH配置"
    
    # 验证配置文件语法
    if ! sshd -t -f "$temp_config" 2>/dev/null; then
        local sshd_error
        sshd_error=$(sshd -t -f "$temp_config" 2>&1)
        log "SSH配置验证失败: $sshd_error" "error"
        rm -f "$temp_config"
        return 1
    fi
    
    debug_log "SSH配置验证通过"
    
    # 备份当前配置
    if ! backup_ssh_config; then
        rm -f "$temp_config"
        return 1
    fi
    
    # 应用新配置
    if ! mv "$temp_config" "$SSH_CONFIG"; then
        log "无法替换SSH配置文件" "error"
        return 1
    fi
    
    # 设置正确的权限
    chmod 644 "$SSH_CONFIG" || {
        log "设置SSH配置文件权限失败" "warn"
    }
    
    debug_log "SSH配置文件已更新"
    
    # 重新加载SSH服务
    if systemctl reload sshd 2>/dev/null; then
        echo "SSH服务: 已重新加载"
        debug_log "SSH服务重新加载成功"
        return 0
    else
        log "SSH服务重新加载失败，尝试重启" "warn"
        if systemctl restart sshd 2>/dev/null; then
            echo "SSH服务: 已重启"
            debug_log "SSH服务重启成功"
            return 0
        else
            log "SSH服务重启失败，恢复配置" "error"
            # 恢复备份配置
            local backup_file
            backup_file=$(ls -t "$SSH_CONFIG.backup."* 2>/dev/null | head -1)
            if [[ -n "$backup_file" ]]; then
                cp "$backup_file" "$SSH_CONFIG"
                systemctl restart sshd
                log "已恢复备份配置" "warn"
            fi
            return 1
        fi
    fi
}

# 显示配置摘要
show_ssh_summary() {
    debug_log "显示SSH配置摘要"
    echo
    log "🎯 SSH安全摘要:" "info"
    
    local current_ports=$(get_current_ssh_ports)
    echo "  SSH端口: $current_ports"
    
    if grep -q "PasswordAuthentication no" "$SSH_CONFIG" 2>/dev/null; then
        echo "  密码登录: 已禁用"
    else
        echo "  密码登录: 已启用"
    fi
    
    local root_setting
    root_setting=$(grep "PermitRootLogin" "$SSH_CONFIG" | awk '{print $2}' 2>/dev/null || echo "unknown")
    case "$root_setting" in
        "no") echo "  Root登录: 已禁止" ;;
        "prohibit-password") echo "  Root登录: 仅允许密钥" ;;
        "yes") echo "  Root登录: 允许密码" ;;
        *) echo "  Root登录: 未知状态" ;;
    esac
    
    if check_ssh_keys; then
        local key_count
        key_count=$(grep -c "^ssh-" "$AUTHORIZED_KEYS" 2>/dev/null || echo "0")
        echo "  SSH密钥: 已配置 ($key_count 个)"
    else
        echo "  SSH密钥: 未配置"
    fi
    return 0
}

# 显示安全提醒
show_security_warnings() {
    local new_ports="$1"
    local password_auth="$2"
    
    debug_log "显示安全提醒"
    echo
    log "⚠️ 重要提醒:" "warn"
    
    if [[ "$new_ports" != "22" ]]; then
        echo "  新SSH连接命令: ssh -p $new_ports user@server"
        echo "  请确保防火墙允许新端口 $new_ports"
    fi
    
    if [[ "$password_auth" == "no" ]] && ! check_ssh_keys; then
        echo "  ⚠️ 警告: 密码登录已禁用但未检测到SSH密钥!"
        echo "  请立即配置SSH密钥，否则可能无法登录!"
    fi
    
    echo "  建议测试新连接后再关闭当前会话"
    return 0
}

# === 主流程 ===
main() {
    debug_log "开始SSH安全配置"
    
    # 检查root权限
    if [[ $EUID -ne 0 ]]; then
        log "需要root权限运行" "error"
        exit 1
    fi
    
    # 检查SSH服务
    if ! systemctl is-active sshd &>/dev/null; then
        log "SSH服务未运行" "error"
        exit 1
    fi
    
    log "🔐 配置SSH安全..." "info"
    
    echo
    local new_ports
    if ! new_ports=$(choose_ssh_ports); then
        log "端口选择失败" "error"
        exit 1
    fi
    
    echo
    local password_auth
    if ! password_auth=$(configure_password_auth); then
        log "密码认证配置失败" "error"
        exit 1
    fi
    
    echo
    local root_login
    if ! root_login=$(configure_root_login); then
        log "Root登录配置失败" "error"
        exit 1
    fi
    
    echo
    echo "正在生成SSH配置..."
    local temp_config
    if ! temp_config=$(generate_ssh_config "$new_ports" "$password_auth" "$root_login"); then
        log "SSH配置生成失败" "error"
        exit 1
    fi
    
    if ! apply_ssh_config "$temp_config"; then
        log "✗ SSH配置应用失败" "error"
        exit 1
    fi
    
    show_security_warnings "$new_ports" "$password_auth"
    show_ssh_summary
    
    echo
    log "✅ SSH安全配置完成!" "info"
    return 0
}

# 错误处理
trap 'log "脚本执行出错，行号: $LINENO" "error"; exit 1' ERR

main "$@"
