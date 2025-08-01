#!/bin/bash
# SSH 安全配置模块 v4.4
# 修复变量传递和端口验证问题

set -euo pipefail

# === 常量定义 ===
readonly SSH_CONFIG="/etc/ssh/sshd_config"
readonly AUTHORIZED_KEYS="$HOME/.ssh/authorized_keys"

# === 日志函数 ===
log() {
    local msg="$1" level="${2:-info}"
    local -A colors=([info]="\033[0;36m" [warn]="\033[0;33m" [error]="\033[0;31m")
    echo -e "${colors[$level]:-\033[0;32m}$msg\033[0m" >&2
}

# === 核心函数 ===

# 智能备份SSH配置
backup_ssh_config() {
    if [[ -f "$SSH_CONFIG" ]]; then
        # 首次备份：保存原始配置
        if [[ ! -f "$SSH_CONFIG.original" ]]; then
            cp "$SSH_CONFIG" "$SSH_CONFIG.original"
            log "已备份原始配置: sshd_config.original" "info"
        fi
        
        # 最近备份：总是覆盖
        cp "$SSH_CONFIG" "$SSH_CONFIG.backup"
        log "已备份当前配置: sshd_config.backup" "info"
    fi
}

# 获取当前SSH端口
get_current_ssh_ports() {
    local ports
    ports=$(grep "^Port " "$SSH_CONFIG" 2>/dev/null | awk '{print $2}' || echo "")
    if [[ -z "$ports" ]]; then
        echo "22"
    else
        echo "$ports" | tr '\n' ' ' | sed 's/ $//'
    fi
}

# 验证端口号（修复版 - 允许当前端口）
validate_port() {
    local port="$1"
    local current_ports="${2:-}"
    
    # 检查格式
    if ! [[ "$port" =~ ^[0-9]+$ ]]; then
        log "✗ 无效的端口号格式: $port" "error"
        return 1
    fi
    
    # 检查范围
    if (( port < 1024 || port > 65535 )); then
        log "✗ 端口号必须在 1024-65535 范围内: $port" "error"
        return 1
    fi
    
    # 如果是当前SSH端口，允许通过
    if [[ "$current_ports" == *"$port"* ]]; then
        return 0
    fi
    
    # 检查是否被其他服务占用
    if ss -tuln 2>/dev/null | grep -q ":$port\b"; then
        log "✗ 端口 $port 已被其他服务占用" "error"
        return 1
    fi
    
    return 0
}

# 验证多个端口（修复版）
validate_ports() {
    local ports="$1"
    local current_ports="${2:-}"
    local port_array=($ports)
    local valid_ports=()
    
    for port in "${port_array[@]}"; do
        if validate_port "$port" "$current_ports"; then
            valid_ports+=("$port")
        fi
    done
    
    if (( ${#valid_ports[@]} == 0 )); then
        log "✗ 没有有效的端口号" "error"
        return 1
    fi
    
    echo "${valid_ports[*]}"
    return 0
}

# 显示端口选择选项
show_port_options() {
    local current_ports="$1"
    
    echo "SSH端口配置:" >&2
    echo "  1) 保持当前端口 ($current_ports)" >&2
    echo "  2) 单端口 - 常用安全端口 (2222)" >&2
    echo "  3) 单端口 - 常用安全端口 (2022)" >&2
    echo "  4) 单端口 - 自定义端口" >&2
    echo "  5) 多端口 - 自定义多个端口" >&2
    echo >&2
}

# 选择SSH端口（修复版）
choose_ssh_ports() {
    local current_ports=$(get_current_ssh_ports)
    
    log "当前SSH端口: $current_ports" "info"
    
    show_port_options "$current_ports"
    
    local choice new_ports
    read -p "请选择 [1-5] (默认: 1): " choice </dev/tty >&2
    choice=${choice:-1}
    
    case "$choice" in
        1)
            log "保持当前端口: $current_ports" "info"
            echo "$current_ports"
            ;;
        2)
            if validate_port "2222" "$current_ports"; then
                echo "2222"
            else
                echo "$current_ports"
            fi
            ;;
        3)
            if validate_port "2022" "$current_ports"; then
                echo "2022"
            else
                echo "$current_ports"
            fi
            ;;
        4)
            while true; do
                read -p "请输入端口号 (1024-65535): " new_ports </dev/tty >&2
                if [[ -z "$new_ports" ]]; then
                    log "端口号不能为空，保持当前端口" "warn"
                    echo "$current_ports"
                    break
                elif validate_port "$new_ports" "$current_ports"; then
                    echo "$new_ports"
                    break
                else
                    log "请重新输入有效的端口号" "warn"
                fi
            done
            ;;
        5)
            log "多端口配置说明:" "info"
            log "  - 可以监听多个端口，提供更好的可用性" "info"
            log "  - 用空格分隔端口号，如: 2222 9399 22022" "info"
            echo >&2
            while true; do
                read -p "请输入多个端口号 (用空格分隔): " new_ports </dev/tty >&2
                if [[ -z "$new_ports" ]]; then
                    log "端口号不能为空，保持当前端口" "warn"
                    echo "$current_ports"
                    break
                else
                    local validated_ports
                    if validated_ports=$(validate_ports "$new_ports" "$current_ports"); then
                        echo "$validated_ports"
                        break
                    else
                        log "请重新输入有效的端口号" "warn"
                    fi
                fi
            done
            ;;
        *)
            log "无效选择，保持当前端口: $current_ports" "warn"
            echo "$current_ports"
            ;;
    esac
}

# 检查SSH密钥
check_ssh_keys() {
    # 检查authorized_keys文件
    if [[ -f "$AUTHORIZED_KEYS" && -s "$AUTHORIZED_KEYS" ]]; then
        local key_count=$(grep -c "^ssh-" "$AUTHORIZED_KEYS" 2>/dev/null || echo "0")
        if (( key_count > 0 )); then
            return 0
        fi
    fi
    
    # 检查其他可能的密钥位置
    local key_files=("$HOME/.ssh/id_rsa.pub" "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_ecdsa.pub")
    for key_file in "${key_files[@]}"; do
        if [[ -f "$key_file" ]]; then
            return 0
        fi
    done
    
    return 1
}

# 配置密码认证（修复版 - 确保只返回yes/no）
configure_password_auth() {
    log "密码认证配置:" "info"
    log "  禁用密码认证可提高安全性，但需要确保SSH密钥正常工作" "info"
    
    if check_ssh_keys; then
        local key_count=$(grep -c "^ssh-" "$AUTHORIZED_KEYS" 2>/dev/null || echo "0")
        log "✓ 找到 $key_count 个SSH密钥" "info"
        
        local disable_password
        read -p "是否禁用密码认证 (仅允许密钥登录)? [y/N] (默认: N): " -r disable_password </dev/tty >&2
        
        if [[ "$disable_password" =~ ^[Yy]$ ]]; then
            log "✓ 将禁用密码认证" "info"
            echo "no"
        else
            log "保持密码认证启用" "info"
            echo "yes"
        fi
    else
        log "⚠ 未找到SSH密钥，保持密码认证启用" "warn"
        log "建议先配置SSH密钥后再禁用密码认证" "warn"
        echo "yes"
    fi
}

# 配置SSH安全设置（修复版 - 简化逻辑）
configure_ssh_security() {
    local new_ports="$1"
    local password_auth="$2"
    
    log "配置SSH安全设置..." "info"
    
    backup_ssh_config
    
    # 创建临时配置文件
    local temp_config=$(mktemp)
    
    # 保留原配置文件，但排除我们要管理的参数
    grep -v -E "^(Port |Protocol |PermitRootLogin |PasswordAuthentication |PubkeyAuthentication |AuthorizedKeysFile |MaxAuthTries |ClientAliveInterval |ClientAliveCountMax |LoginGraceTime )" "$SSH_CONFIG" | \
    grep -v -E "^# SSH安全配置" > "$temp_config"
    
    # 添加我们的配置
    {
        echo ""
        echo "# SSH安全配置 - 由脚本管理"
        
        # 添加端口配置
        local port_array=($new_ports)
        for port in "${port_array[@]}"; do
            echo "Port $port"
        done
        
        # 添加安全配置
        echo "Protocol 2"
        echo "PermitRootLogin prohibit-password"
        echo "PubkeyAuthentication yes"
        echo "AuthorizedKeysFile .ssh/authorized_keys"
        echo "MaxAuthTries 6"
        echo "ClientAliveInterval 600"
        echo "ClientAliveCountMax 3"
        echo "LoginGraceTime 60"
        echo "PasswordAuthentication $password_auth"
    } >> "$temp_config"
    
    # 替换原配置文件
    mv "$temp_config" "$SSH_CONFIG"
    
    log "✓ SSH安全设置已应用" "info"
}

# 验证并应用SSH配置（增强版）
apply_ssh_config() {
    log "验证SSH配置..." "info"
    
    # 验证配置文件语法
    local sshd_test_output
    sshd_test_output=$(sshd -t 2>&1)
    local sshd_test_result=$?
    
    if [[ $sshd_test_result -ne 0 ]]; then
        log "✗ SSH配置验证失败" "error"
        log "错误详情:" "error"
        echo "$sshd_test_output" | sed 's/^/  /' >&2
        
        log "恢复备份配置..." "info"
        cp "$SSH_CONFIG.backup" "$SSH_CONFIG"
        systemctl reload sshd
        return 1
    fi
    
    # 重启SSH服务
    log "应用SSH配置..." "info"
    if systemctl restart sshd; then
        log "✓ SSH服务已重启" "info"
        return 0
    else
        log "✗ SSH服务重启失败" "error"
        return 1
    fi
}

# 显示SSH安全提醒
show_security_warnings() {
    local new_ports="$1"
    local password_auth="$2"
    
    echo >&2
    log "🔒 SSH安全提醒:" "warn"
    
    local port_array=($new_ports)
    log "  ⚠ 当前SSH端口: $new_ports" "warn"
    if (( ${#port_array[@]} == 1 )); then
        log "  ⚠ 请使用端口连接: ssh -p ${port_array[0]} user@server" "warn"
    else
        log "  ⚠ 可使用任意配置的端口连接" "warn"
        for port in "${port_array[@]}"; do
            log "    ssh -p $port user@server" "warn"
        done
    fi
    log "  ⚠ 请确保防火墙允许这些端口" "warn"
    
    if [[ "$password_auth" == "no" ]]; then
        log "  🔑 密码认证已禁用，仅允许密钥登录" "warn"
        log "  🔑 请确保SSH密钥配置正确" "warn"
    fi
    
    log "  🛡 root用户仅允许密钥登录" "info"
    log "  ⏱ 连接超时时间: 10分钟" "info"
    log "  🔢 最大认证尝试: 6次" "info"
}

# 显示SSH配置摘要
show_ssh_summary() {
    echo >&2
    log "🎯 SSH配置摘要:" "info"
    
    # SSH端口
    local current_ports=$(get_current_ssh_ports)
    local port_array=($current_ports)
    if (( ${#port_array[@]} == 1 )); then
        log "  🔌 SSH端口: $current_ports" "info"
    else
        log "  🔌 SSH端口: $current_ports (多端口)" "info"
    fi
    
    # 认证方式
    if grep -q "PasswordAuthentication no" "$SSH_CONFIG"; then
        log "  🔑 密码认证: 已禁用" "info"
    else
        log "  🔑 密码认证: 已启用" "info"
    fi
    
    if grep -q "PubkeyAuthentication yes" "$SSH_CONFIG"; then
        log "  🗝 密钥认证: 已启用" "info"
    fi
    
    # Root登录
    if grep -q "PermitRootLogin prohibit-password" "$SSH_CONFIG"; then
        log "  👑 Root登录: 仅允许密钥" "info"
    fi
    
    # 备份状态
    if [[ -f "$SSH_CONFIG.original" ]]; then
        log "  💾 原始配置: 已备份" "info"
    fi
    
    if [[ -f "$SSH_CONFIG.backup" ]]; then
        log "  💾 最近配置: 已备份" "info"
    fi
    
    # SSH密钥状态
    if check_ssh_keys; then
        local key_count=$(grep -c "^ssh-" "$AUTHORIZED_KEYS" 2>/dev/null || echo "0")
        log "  🔐 SSH密钥: 已配置 ($key_count 个)" "info"
    else
        log "  🔐 SSH密钥: 未配置" "warn"
    fi
}

# === 主流程 ===
main() {
    log "🔐 配置SSH安全设置..." "info"
    
    echo >&2
    # 选择SSH端口
    local new_ports=$(choose_ssh_ports)
    
    echo >&2
    # 配置密码认证
    local password_auth=$(configure_password_auth)
    
    echo >&2
    # 配置SSH安全设置
    configure_ssh_security "$new_ports" "$password_auth"
    
    echo >&2
    # 应用配置
    if ! apply_ssh_config; then
        log "✗ SSH配置应用失败" "error"
        exit 1
    fi
    
    # 显示安全提醒
    show_security_warnings "$new_ports" "$password_auth"
    
    # 显示配置摘要
    show_ssh_summary
    
    echo >&2
    log "🎉 SSH安全配置完成!" "info"
    
    # 显示有用的命令
    local final_ports=$(get_current_ssh_ports)
    local port_array=($final_ports)
    echo >&2
    log "常用命令:" "info"
    if (( ${#port_array[@]} == 1 )); then
        log "  测试SSH连接: ssh -p ${port_array[0]} -o ConnectTimeout=5 user@server" "info"
    else
        log "  测试SSH连接 (任选端口):" "info"
        for port in "${port_array[@]}"; do
            log "    ssh -p $port -o ConnectTimeout=5 user@server" "info"
        done
    fi
    log "  查看SSH状态: systemctl status sshd" "info"
    log "  恢复配置: cp $SSH_CONFIG.backup $SSH_CONFIG" "info"
    log "  重启SSH: systemctl restart sshd" "info"
}

main "$@"
