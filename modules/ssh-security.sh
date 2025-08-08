#!/bin/bash
# SSH 安全配置模块 v4.5 - 简化版
# 功能: SSH端口配置、密码认证控制、安全策略设置

set -euo pipefail

# === 常量定义 ===
readonly SSH_CONFIG="/etc/ssh/sshd_config"
readonly AUTHORIZED_KEYS="$HOME/.ssh/authorized_keys"

# === 日志函数 ===
log() {
    local msg="$1" level="${2:-info}"
    local -A colors=([info]="\033[0;36m" [warn]="\033[0;33m" [error]="\033[0;31m")
    echo -e "${colors[$level]:-\033[0;32m}$msg\033[0m"
}

# === 核心函数 ===

# 备份SSH配置
backup_ssh_config() {
    if [[ -f "$SSH_CONFIG" ]]; then
        # 只保留一个备份
        cp "$SSH_CONFIG" "$SSH_CONFIG.backup"
        echo "SSH配置: 已备份"
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

# 验证端口号
validate_port() {
    local port="$1"
    local current_ports="${2:-}"
    
    # 检查格式和范围
    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1024 || port > 65535 )); then
        return 1
    fi
    
    # 如果是当前SSH端口，允许通过
    if [[ "$current_ports" == *"$port"* ]]; then
        return 0
    fi
    
    # 检查是否被占用
    if ss -tuln 2>/dev/null | grep -q ":$port\b"; then
        return 1
    fi
    
    return 0
}

# 验证多个端口
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
        return 1
    fi
    
    echo "${valid_ports[*]}"
    return 0
}

# 选择SSH端口 - 修复菜单显示
choose_ssh_ports() {
    local current_ports=$(get_current_ssh_ports)
    
    echo "当前SSH端口: $current_ports" >&2
    echo "端口配置:" >&2
    echo "  1) 保持当前 ($current_ports)" >&2
    echo "  2) 使用2222端口" >&2
    echo "  3) 使用2022端口" >&2
    echo "  4) 自定义端口" >&2
    echo "  5) 多端口配置" >&2
    echo >&2
    
    local choice new_ports
    read -p "请选择 [1-5] (默认: 1): " choice >&2
    choice=${choice:-1}
    
    case "$choice" in
        1)
            echo "$current_ports"
            ;;
        2)
            if validate_port "2222" "$current_ports"; then
                echo "2222"
            else
                echo "端口2222不可用，保持当前端口" >&2
                echo "$current_ports"
            fi
            ;;
        3)
            if validate_port "2022" "$current_ports"; then
                echo "2022"
            else
                echo "端口2022不可用，保持当前端口" >&2
                echo "$current_ports"
            fi
            ;;
        4)
            while true; do
                read -p "输入端口号 (1024-65535): " new_ports >&2
                if [[ -z "$new_ports" ]]; then
                    echo "端口为空，保持当前端口" >&2
                    echo "$current_ports"
                    break
                elif validate_port "$new_ports" "$current_ports"; then
                    echo "$new_ports"
                    break
                else
                    echo "端口无效或被占用，请重新输入" >&2
                fi
            done
            ;;
        5)
            while true; do
                read -p "输入多个端口 (空格分隔): " new_ports >&2
                if [[ -z "$new_ports" ]]; then
                    echo "端口为空，保持当前端口" >&2
                    echo "$current_ports"
                    break
                else
                    local validated_ports
                    if validated_ports=$(validate_ports "$new_ports" "$current_ports"); then
                        echo "$validated_ports"
                        break
                    else
                        echo "部分端口无效，请重新输入" >&2
                    fi
                fi
            done
            ;;
        *)
            echo "无效选择，保持当前端口" >&2
            echo "$current_ports"
            ;;
    esac
}

# 检查SSH密钥
check_ssh_keys() {
    if [[ -f "$AUTHORIZED_KEYS" && -s "$AUTHORIZED_KEYS" ]]; then
        local key_count=$(grep -c "^ssh-" "$AUTHORIZED_KEYS" 2>/dev/null || echo "0")
        if (( key_count > 0 )); then
            return 0
        fi
    fi
    
    local key_files=("$HOME/.ssh/id_rsa.pub" "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_ecdsa.pub")
    for key_file in "${key_files[@]}"; do
        if [[ -f "$key_file" ]]; then
            return 0
        fi
    done
    
    return 1
}

# 配置密码认证 - 修复输出
configure_password_auth() {
    if check_ssh_keys; then
        local key_count=$(grep -c "^ssh-" "$AUTHORIZED_KEYS" 2>/dev/null || echo "0")
        echo "SSH密钥状态: 已配置 ($key_count 个)" >&2
        
        local disable_password
        read -p "是否禁用密码认证 (仅允许密钥登录)? [y/N]: " -r disable_password >&2
        
        if [[ "$disable_password" =~ ^[Yy]$ ]]; then
            echo "密码认证: 将禁用" >&2
            echo "no"
        else
            echo "密码认证: 保持启用" >&2
            echo "yes"
        fi
    else
        echo "SSH密钥状态: 未配置，保持密码认证" >&2
        echo "yes"
    fi
}

# 配置SSH安全设置 - 修复配置生成逻辑
configure_ssh_security() {
    local new_ports="$1"
    local password_auth="$2"
    
    backup_ssh_config
    
    # 更安全的配置方法：完全重写配置
    local temp_config=$(mktemp)
    
    # 生成完整的SSH配置
    cat > "$temp_config" << EOF
# SSH daemon configuration file
# Generated by ssh-security module

# Network
$(for port in $new_ports; do echo "Port $port"; done)
AddressFamily any
ListenAddress 0.0.0.0
ListenAddress ::

# Protocol
Protocol 2

# HostKeys
HostKey /etc/ssh/ssh_host_rsa_key
HostKey /etc/ssh/ssh_host_ecdsa_key
HostKey /etc/ssh/ssh_host_ed25519_key

# Logging
SyslogFacility AUTH
LogLevel INFO

# Authentication
LoginGraceTime 60
PermitRootLogin prohibit-password
StrictModes yes
MaxAuthTries 6
MaxSessions 10

PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys

PasswordAuthentication $password_auth
PermitEmptyPasswords no
ChallengeResponseAuthentication no

# Kerberos options
KerberosAuthentication no
KerberosOrLocalPasswd yes
KerberosTicketCleanup yes
KerberosGetAFSToken no

# GSSAPI options
GSSAPIAuthentication no
GSSAPICleanupCredentials yes
GSSAPIStrictAcceptorCheck yes
GSSAPIKeyExchange no

# Set this to 'yes' to enable PAM authentication, account processing,
# and session processing.
UsePAM yes

# Connection settings
ClientAliveInterval 600
ClientAliveCountMax 3
TCPKeepAlive yes

# Subsystems
Subsystem sftp /usr/lib/openssh/sftp-server

# Security
AllowAgentForwarding yes
AllowTcpForwarding yes
GatewayPorts no
X11Forwarding yes
X11DisplayOffset 10
X11UseLocalhost yes
PermitTTY yes
PrintMotd no
PrintLastLog yes
PermitUserEnvironment no
Compression delayed
UseDNS no

# Accept locale-related environment variables
AcceptEnv LANG LC_*
EOF
    
    # 替换原配置文件
    mv "$temp_config" "$SSH_CONFIG"
    echo "SSH配置: 已更新"
}

# 验证并应用SSH配置 - 增强错误输出
apply_ssh_config() {
    # 验证配置
    local sshd_test_output
    sshd_test_output=$(sshd -t 2>&1)
    local sshd_result=$?
    
    if [[ $sshd_result -ne 0 ]]; then
        echo "SSH配置验证失败:" >&2
        echo "$sshd_test_output" >&2
        echo "恢复备份配置..." >&2
        cp "$SSH_CONFIG.backup" "$SSH_CONFIG"
        systemctl reload sshd
        return 1
    fi
    
    # 重启服务
    if systemctl restart sshd 2>/dev/null; then
        echo "SSH服务: 已重启"
        return 0
    else
        echo "SSH服务重启失败" >&2
        return 1
    fi
}

# 显示配置摘要
show_ssh_summary() {
    echo
    log "🎯 SSH安全摘要:" "info"
    
    local current_ports=$(get_current_ssh_ports)
    local port_array=($current_ports)
    if (( ${#port_array[@]} == 1 )); then
        echo "  SSH端口: $current_ports"
    else
        echo "  SSH端口: $current_ports (多端口)"
    fi
    
    if grep -q "PasswordAuthentication no" "$SSH_CONFIG"; then
        echo "  密码认证: 已禁用"
    else
        echo "  密码认证: 已启用"
    fi
    
    echo "  Root登录: 仅允许密钥"
    
    if check_ssh_keys; then
        local key_count=$(grep -c "^ssh-" "$AUTHORIZED_KEYS" 2>/dev/null || echo "0")
        echo "  SSH密钥: 已配置 ($key_count 个)"
    else
        echo "  SSH密钥: 未配置"
    fi
}

# 显示安全提醒
show_security_warnings() {
    local new_ports="$1"
    local password_auth="$2"
    
    echo
    log "⚠️ 重要提醒:" "warn"
    
    local port_array=($new_ports)
    if [[ "${port_array[0]}" != "22" ]]; then
        echo "  新SSH连接命令: ssh -p ${port_array[0]} user@server"
        echo "  请确保防火墙允许新端口访问"
    fi
    
    if [[ "$password_auth" == "no" ]]; then
        echo "  密码登录已禁用，请确保SSH密钥正常"
    fi
}

# === 主流程 ===
main() {
    log "🔐 配置SSH安全..." "info"
    
    echo
    local new_ports=$(choose_ssh_ports)
    
    echo
    local password_auth=$(configure_password_auth)
    
    echo
    configure_ssh_security "$new_ports" "$password_auth"
    
    if ! apply_ssh_config; then
        log "✗ SSH配置失败" "error"
        exit 1
    fi
    
    show_security_warnings "$new_ports" "$password_auth"
    show_ssh_summary
    
    echo
    log "✅ SSH安全配置完成!" "info"
}

main "$@"
