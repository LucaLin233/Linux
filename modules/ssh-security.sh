#!/bin/bash
# SSH 安全配置模块 v4.0
# 功能: SSH端口配置、安全设置、密钥管理
# 统一代码风格，智能备份策略

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
get_current_ssh_port() {
    local port
    port=$(grep "^Port " "$SSH_CONFIG" 2>/dev/null | awk '{print $2}' | head -n 1 || echo "")
    echo "${port:-22}"
}

# 验证端口号
validate_port() {
    local port="$1"
    
    # 检查格式
    if ! [[ "$port" =~ ^[0-9]+$ ]]; then
        log "✗ 无效的端口号格式" "error"
        return 1
    fi
    
    # 检查范围
    if (( port < 1024 || port > 65535 )); then
        log "✗ 端口号必须在 1024-65535 范围内" "error"
        return 1
    fi
    
    # 检查是否被占用
    if ss -tuln 2>/dev/null | grep -q ":$port\b"; then
        log "✗ 端口 $port 已被占用" "error"
        return 1
    fi
    
    return 0
}

# 显示端口选择选项
show_port_options() {
    local current_port="$1"
    
    echo >&2
    echo "SSH端口配置:" >&2
    echo "  1) 保持当前端口 ($current_port)" >&2
    echo "  2) 使用常用安全端口 (2222)" >&2
    echo "  3) 使用常用安全端口 (2022)" >&2
    echo "  4) 自定义端口" >&2
    echo >&2
}

# 选择SSH端口
choose_ssh_port() {
    local current_port=$(get_current_ssh_port)
    
    log "当前SSH端口: $current_port" "info"
    
    show_port_options "$current_port"
    
    local choice new_port
    read -p "请选择 [1-4] (默认: 1): " choice </dev/tty >&2
    choice=${choice:-1}
    
    case "$choice" in
        1)
            log "保持当前端口: $current_port" "info"
            echo "$current_port"
            ;;
        2)
            new_port="2222"
            if validate_port "$new_port"; then
                echo "$new_port"
            else
                echo "$current_port"
            fi
            ;;
        3)
            new_port="2022"
            if validate_port "$new_port"; then
                echo "$new_port"
            else
                echo "$current_port"
            fi
            ;;
        4)
            while true; do
                read -p "请输入端口号 (1024-65535): " new_port </dev/tty >&2
                if [[ -n "$new_port" ]] && validate_port "$new_port"; then
                    echo "$new_port"
                    break
                fi
            done
            ;;
        *)
            log "无效选择，保持当前端口: $current_port" "warn"
            echo "$current_port"
            ;;
    esac
}

# 配置SSH端口
configure_ssh_port() {
    local new_port="$1"
    local current_port=$(get_current_ssh_port)
    
    if [[ "$new_port" == "$current_port" ]]; then
        return 0
    fi
    
    log "更改SSH端口到 $new_port..." "info"
    
    # 移除旧的Port配置
    sed -i '/^Port /d' "$SSH_CONFIG"
    sed -i '/^#Port /d' "$SSH_CONFIG"
    
    # 在配置文件开头添加新端口
    sed -i "1i Port $new_port" "$SSH_CONFIG"
    
    log "✓ SSH端口已配置为 $new_port" "info"
}

# 检查SSH密钥
check_ssh_keys() {
    log "检查SSH密钥..." "info"
    
    # 检查authorized_keys文件
    if [[ -f "$AUTHORIZED_KEYS" && -s "$AUTHORIZED_KEYS" ]]; then
        local key_count=$(grep -c "^ssh-" "$AUTHORIZED_KEYS" 2>/dev/null || echo "0")
        if (( key_count > 0 )); then
            log "✓ 找到 $key_count 个SSH密钥" "info"
            return 0
        fi
    fi
    
    # 检查其他可能的密钥位置
    local key_files=("$HOME/.ssh/id_rsa.pub" "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_ecdsa.pub")
    for key_file in "${key_files[@]}"; do
        if [[ -f "$key_file" ]]; then
            log "找到密钥文件: $key_file" "info"
            return 0
        fi
    done
    
    log "✗ 未找到SSH密钥" "warn"
    return 1
}

# 配置SSH安全设置
configure_ssh_security() {
    log "配置SSH安全设置..." "info"
    
    backup_ssh_config
    
    # 移除可能冲突的旧配置
    local security_params=(
        "PermitRootLogin"
        "PasswordAuthentication"
        "Protocol"
        "MaxAuthTries"
        "ClientAliveInterval"
        "ClientAliveCountMax"
        "LoginGraceTime"
        "PubkeyAuthentication"
        "AuthorizedKeysFile"
    )
    
    for param in "${security_params[@]}"; do
        sed -i "/^${param}/d" "$SSH_CONFIG"
        sed -i "/^#${param}/d" "$SSH_CONFIG"
    done
    
    # 添加基础安全配置
    cat >> "$SSH_CONFIG" << 'EOF'

# SSH安全配置
Protocol 2
PermitRootLogin prohibit-password
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
MaxAuthTries 3
ClientAliveInterval 600
ClientAliveCountMax 3
LoginGraceTime 60
EOF
    
    log "✓ 基础安全设置已应用" "info"
}

# 配置密码认证
configure_password_auth() {
    echo
    log "密码认证配置:" "info"
    log "  禁用密码认证可提高安全性，但需要确保SSH密钥正常工作" "info"
    
    if check_ssh_keys; then
        echo
        read -p "是否禁用密码认证 (仅允许密钥登录)? [y/N] (默认: N): " -r disable_password
        
        if [[ "$disable_password" =~ ^[Yy]$ ]]; then
            echo "PasswordAuthentication no" >> "$SSH_CONFIG"
            log "✓ 已禁用密码认证" "info"
            log "⚠ 请确保SSH密钥工作正常!" "warn"
        else
            echo "PasswordAuthentication yes" >> "$SSH_CONFIG"
            log "保持密码认证启用" "info"
        fi
    else
        echo "PasswordAuthentication yes" >> "$SSH_CONFIG"
        log "⚠ 未找到SSH密钥，保持密码认证启用" "warn"
        log "建议先配置SSH密钥后再禁用密码认证" "warn"
    fi
}

# 验证并应用SSH配置
apply_ssh_config() {
    log "验证SSH配置..." "info"
    
    # 验证配置文件语法
    if ! sshd -t 2>/dev/null; then
        log "✗ SSH配置验证失败，恢复备份" "error"
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
    local new_port="$1"
    local current_port=$(get_current_ssh_port)
    
    echo
    log "🔒 SSH安全提醒:" "warn"
    
    if [[ "$new_port" != "$current_port" ]]; then
        log "  ⚠ SSH端口已更改为 $new_port" "warn"
        log "  ⚠ 请使用新端口连接: ssh -p $new_port user@server" "warn"
        log "  ⚠ 请确保防火墙允许端口 $new_port" "warn"
    fi
    
    if grep -q "PasswordAuthentication no" "$SSH_CONFIG"; then
        log "  🔑 密码认证已禁用，仅允许密钥登录" "warn"
        log "  🔑 请确保SSH密钥配置正确" "warn"
    fi
    
    log "  🛡 root用户仅允许密钥登录" "info"
    log "  ⏱ 连接超时时间: 10分钟" "info"
    log "  🔢 最大认证尝试: 3次" "info"
}

# 显示SSH配置摘要
show_ssh_summary() {
    echo
    log "🎯 SSH配置摘要:" "info"
    
    # SSH端口
    local current_port=$(get_current_ssh_port)
    log "  🔌 SSH端口: $current_port" "info"
    
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
    if check_ssh_keys >/dev/null 2>&1; then
        log "  🔐 SSH密钥: 已配置" "info"
    else
        log "  🔐 SSH密钥: 未配置" "warn"
    fi
}

# === 主流程 ===
main() {
    log "🔐 配置SSH安全设置..." "info"
    
    echo
    # 选择SSH端口
    local new_port=$(choose_ssh_port)
    
    echo
    # 配置SSH端口
    configure_ssh_port "$new_port"
    
    echo
    # 配置安全设置
    configure_ssh_security
    
    # 配置密码认证
    configure_password_auth
    
    echo
    # 应用配置
    if ! apply_ssh_config; then
        log "✗ SSH配置应用失败" "error"
        exit 1
    fi
    
    # 显示安全提醒
    show_security_warnings "$new_port"
    
    # 显示配置摘要
    show_ssh_summary
    
    echo
    log "🎉 SSH安全配置完成!" "info"
    
    # 显示有用的命令
    echo
    log "常用命令:" "info"
    log "  测试SSH连接: ssh -p $new_port -o ConnectTimeout=5 user@server" "info"
    log "  查看SSH状态: systemctl status sshd" "info"
    log "  恢复配置: cp $SSH_CONFIG.backup $SSH_CONFIG" "info"
    log "  重启SSH: systemctl restart sshd" "info"
}

main "$@"
