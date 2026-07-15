#!/usr/bin/env bash
# SSH 安全配置模块
# 功能：配置 SSH 端口、Root 登录策略与认证方式。
# 策略：完整替换主配置，保留并加载 sshd_config.d 扩展配置。

set -euo pipefail

# === 常量定义 ===
readonly SSH_CONFIG="/etc/ssh/sshd_config"
readonly SSH_BACKUP="/etc/ssh/sshd_config.backup"
readonly SSH_DROPIN_DIR="/etc/ssh/sshd_config.d"
readonly ROOT_AUTHORIZED_KEYS="/root/.ssh/authorized_keys"

# === 日志函数 ===
log() {
    local msg="$1"
    local level="${2:-info}"
    local -A colors=(
        [info]="\033[0;36m"
        [warn]="\033[0;33m"
        [error]="\033[0;31m"
        [success]="\033[0;32m"
        [debug]="\033[0;35m"
    )

    if [[ "$level" == "debug" && "${DEBUG:-}" != "1" ]]; then
        return 0
    fi

    echo -e "${colors[$level]:-\033[0;32m}${msg}\033[0m"
}

info() {
    log "$1" "info"
}

warn() {
    log "$1" "warn"
}

error() {
    log "$1" "error"
}

success() {
    log "$1" "success"
}

require_root() {
    if (( EUID != 0 )); then
        error "需要 root 权限运行"
        exit 1
    fi
}

# === SSH 服务与状态 ===
get_ssh_service_name() {
    if systemctl list-unit-files ssh.service --no-legend 2>/dev/null |
        grep -q '^ssh\.service'; then
        echo "ssh"
        return 0
    fi

    if systemctl list-unit-files sshd.service --no-legend 2>/dev/null |
        grep -q '^sshd\.service'; then
        echo "sshd"
        return 0
    fi

    return 1
}

normalize_root_login_policy() {
    case "$1" in
        without-password)
            echo "prohibit-password"
            ;;
        *)
            echo "$1"
            ;;
    esac
}

get_effective_value() {
    local key="$1"
    local value

    value=$(
        sshd -T 2>/dev/null |
            awk -v key="$key" '$1 == key {print $2; exit}'
    )

    if [[ "$key" == "permitrootlogin" ]]; then
        normalize_root_login_policy "$value"
    else
        echo "$value"
    fi
}

get_effective_ports() {
    sshd -T 2>/dev/null |
        awk '$1 == "port" {print $2}' |
        sort -n -u
}

port_is_in_list() {
    local target_port="$1"
    local ports="$2"

    grep -Fxq "$target_port" <<< "$ports"
}

validate_port() {
    local port="$1"
    local current_ports="$2"

    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1024 || port > 65535 )); then
        return 1
    fi

    if port_is_in_list "$port" "$current_ports"; then
        return 0
    fi

    if ss -ltnH 2>/dev/null |
        awk '{print $4}' |
        grep -Eq "(^|[:.])${port}$"; then
        return 1
    fi

    return 0
}

get_root_key_count() {
    if [[ ! -s "$ROOT_AUTHORIZED_KEYS" ]]; then
        echo "0"
        return 0
    fi

    awk '
        /^[[:space:]]*#/ || /^[[:space:]]*$/ {next}
        NF >= 2 {count++}
        END {print count + 0}
    ' "$ROOT_AUTHORIZED_KEYS" 2>/dev/null
}

format_root_login_display() {
    case "$1" in
        no)
            echo "禁止 Root 登录"
            ;;
        prohibit-password|without-password)
            echo "Root 仅允许密钥登录"
            ;;
        yes)
            echo "允许 Root 密码登录"
            ;;
        forced-commands-only)
            echo "仅允许强制命令密钥登录"
            ;;
        *)
            echo "未知（${1:-未设置}）"
            ;;
    esac
}

# === 交互选择 ===
choose_ssh_port() {
    local current_ports
    local choice
    local custom_port

    current_ports=$(get_effective_ports)

    if [[ -z "$current_ports" ]]; then
        current_ports="22"
    fi

    echo "当前 SSH 监听端口: $(tr '\n' ' ' <<< "$current_ports")" >&2
    echo "端口配置：" >&2
    echo "  1) 保持当前端口" >&2
    echo "  2) 使用 2222" >&2
    echo "  3) 使用 2022" >&2
    echo "  4) 自定义端口" >&2
    echo >&2

    read -r -p "请选择 [1-4]（默认 1）: " choice >&2
    choice="${choice:-1}"

    case "$choice" in
        1)
            head -n 1 <<< "$current_ports"
            ;;
        2)
            if validate_port "2222" "$current_ports"; then
                echo "2222"
            else
                warn "端口 2222 不可用，保持当前端口" >&2
                head -n 1 <<< "$current_ports"
            fi
            ;;
        3)
            if validate_port "2022" "$current_ports"; then
                echo "2022"
            else
                warn "端口 2022 不可用，保持当前端口" >&2
                head -n 1 <<< "$current_ports"
            fi
            ;;
        4)
            while true; do
                read -r -p "输入端口号（1024-65535）: " custom_port >&2

                if [[ -z "$custom_port" ]]; then
                    warn "端口为空，保持当前端口" >&2
                    head -n 1 <<< "$current_ports"
                    return 0
                fi

                if validate_port "$custom_port" "$current_ports"; then
                    echo "$custom_port"
                    return 0
                fi

                warn "端口无效或已被其他服务占用，请重新输入" >&2
            done
            ;;
        *)
            warn "无效选择，保持当前端口" >&2
            head -n 1 <<< "$current_ports"
            ;;
    esac
}

choose_password_authentication() {
    local key_count
    local choice

    key_count=$(get_root_key_count)

    if (( key_count > 0 )); then
        echo "Root SSH 密钥状态: 已配置（${key_count} 个）" >&2
        read -r -p "是否禁用密码与交互式认证？[Y/n]: " choice >&2
        choice="${choice:-Y}"

        if [[ "$choice" =~ ^[Nn]$ ]]; then
            echo "yes"
        else
            echo "no"
        fi

        return 0
    fi

    echo "Root SSH 密钥状态: 未检测到可用的 authorized_keys" >&2
    echo "为避免无法远程登录，密码与交互式认证将保持启用。" >&2
    echo "yes"
}

choose_root_login_policy() {
    local current_policy
    local choice

    current_policy=$(get_effective_value "permitrootlogin")
    current_policy="${current_policy:-prohibit-password}"

    echo "当前 Root 登录策略: $(format_root_login_display "$current_policy")" >&2
    echo "Root 登录策略：" >&2
    echo "  1) 保持当前策略（默认）" >&2
    echo "  2) 禁止 Root 登录" >&2
    echo "  3) Root 仅允许密钥登录" >&2
    echo "  4) 允许 Root 密码登录（不推荐）" >&2
    echo >&2

    read -r -p "请选择 [1-4]（默认 1）: " choice >&2
    choice="${choice:-1}"

    case "$choice" in
        1)
            echo "$current_policy"
            ;;
        2)
            echo "no"
            ;;
        3)
            echo "prohibit-password"
            ;;
        4)
            echo "yes"
            ;;
        *)
            warn "无效选择，保持当前策略" >&2
            echo "$current_policy"
            ;;
    esac
}

# === 配置生成与验证 ===
create_temp_ssh_config() {
    local port="$1"
    local password_auth="$2"
    local root_login="$3"
    local temp_config

    if ! temp_config=$(mktemp /etc/ssh/sshd_config.new.XXXXXX); then
        error "无法创建 SSH 配置临时文件"
        return 1
    fi

    cat > "$temp_config" <<EOF
# SSH daemon configuration
# 由 ssh-security.sh 自动生成。
# 主配置由本脚本完整管理；扩展配置在文件末尾加载。

# 网络
Port $port
AddressFamily any
ListenAddress 0.0.0.0
ListenAddress ::

# 认证
PermitRootLogin $root_login
PasswordAuthentication $password_auth
KbdInteractiveAuthentication $password_auth
PermitEmptyPasswords no
PubkeyAuthentication yes
UsePAM yes

# 登录安全
MaxAuthTries 3
LoginGraceTime 60
MaxSessions 10
ClientAliveInterval 300
ClientAliveCountMax 2

# 转发与图形功能
AllowAgentForwarding no
AllowTcpForwarding yes
X11Forwarding no
PermitTunnel no

# 其他
UseDNS no
PrintMotd no
Banner none
Subsystem sftp internal-sftp

# 加载额外 SSH 配置。
# 主配置中的核心认证策略已优先定义；
# 此处适合放置未与主配置冲突的扩展项或 Match 规则。
Include $SSH_DROPIN_DIR/*.conf
EOF

    chmod 600 "$temp_config"
    echo "$temp_config"
}

check_syntax() {
    local config_file="$1"

    if ! sshd -t -f "$config_file"; then
        error "SSH 配置语法验证失败"
        return 1
    fi
}

get_effective_value_from_config() {
    local config_file="$1"
    local key="$2"
    local value

    value=$(
        sshd -T -f "$config_file" 2>/dev/null |
            awk -v key="$key" '$1 == key {print $2; exit}'
    )

    if [[ "$key" == "permitrootlogin" ]]; then
        normalize_root_login_policy "$value"
    else
        echo "$value"
    fi
}

get_effective_ports_from_config() {
    local config_file="$1"

    sshd -T -f "$config_file" 2>/dev/null |
        awk '$1 == "port" {print $2}' |
        sort -n -u
}

verify_effective_settings() {
    local config_file="$1"
    local expected_port="$2"
    local expected_password_auth="$3"
    local expected_root_login="$4"
    local actual_value
    local ports
    local port
    local choice
    local extra_ports=()
    local key

    declare -A expected_values=(
        [permitrootlogin]="$expected_root_login"
        [passwordauthentication]="$expected_password_auth"
        [kbdinteractiveauthentication]="$expected_password_auth"
        [pubkeyauthentication]="yes"
        [allowtcpforwarding]="yes"
    )

    for key in "${!expected_values[@]}"; do
        actual_value=$(get_effective_value_from_config "$config_file" "$key")

        if [[ "$actual_value" != "${expected_values[$key]}" ]]; then
            error "最终生效配置不符合预期：$key=${actual_value:-未读取}，预期=${expected_values[$key]}"
            error "请检查 $SSH_DROPIN_DIR 中是否存在冲突配置"
            return 1
        fi
    done

    ports=$(get_effective_ports_from_config "$config_file")

    if ! port_is_in_list "$expected_port" "$ports"; then
        error "最终 SSH 配置未监听所选端口：$expected_port"
        return 1
    fi

    while IFS= read -r port; do
        [[ -z "$port" || "$port" == "$expected_port" ]] && continue
        extra_ports+=("$port")
    done <<< "$ports"

    if (( ${#extra_ports[@]} == 0 )); then
        return 0
    fi

    echo >&2
    warn "检测到 SSH 还会监听额外端口：${extra_ports[*]}" >&2
    echo "当前选择的主端口: $expected_port" >&2
    echo "额外端口可能来自: $SSH_DROPIN_DIR/*.conf" >&2

    read -r -p "是否保留全部监听端口并继续应用？[y/N]: " choice >&2
    choice="${choice:-N}"

    if [[ "$choice" =~ ^[Yy]$ ]]; then
        return 0
    fi

    warn "已取消应用 SSH 配置，当前配置未改变" >&2
    return 1
}

backup_ssh_config() {
    if [[ ! -f "$SSH_CONFIG" ]]; then
        error "未找到 SSH 主配置：$SSH_CONFIG"
        return 1
    fi

    if ! cp -a "$SSH_CONFIG" "$SSH_BACKUP"; then
        error "SSH 配置备份失败"
        return 1
    fi

    chmod 600 "$SSH_BACKUP" 2>/dev/null || true
}

restore_ssh_config() {
    local service_name="$1"

    if [[ ! -f "$SSH_BACKUP" ]]; then
        error "未找到 SSH 配置备份，无法自动恢复"
        return 1
    fi

    warn "恢复 SSH 配置备份..."

    if ! cp -a "$SSH_BACKUP" "$SSH_CONFIG"; then
        error "恢复 SSH 配置备份失败"
        return 1
    fi

    if ! sshd -t -f "$SSH_CONFIG" >/dev/null 2>&1; then
        error "备份 SSH 配置语法验证失败，需要人工处理"
        return 1
    fi

    if systemctl reload "$service_name" >/dev/null 2>&1; then
        warn "已恢复 SSH 配置并重新加载服务"
        return 0
    fi

    if systemctl restart "$service_name" >/dev/null 2>&1; then
        warn "已恢复 SSH 配置并重启服务"
        return 0
    fi

    error "SSH 配置已恢复，但服务无法启动，需要人工处理"
    return 1
}

apply_ssh_config() {
    local temp_config="$1"
    local service_name="$2"

    if ! backup_ssh_config; then
        rm -f "$temp_config"
        return 1
    fi

    if ! install -m 600 "$temp_config" "$SSH_CONFIG"; then
        rm -f "$temp_config"
        error "替换 SSH 主配置失败"
        return 1
    fi

    rm -f "$temp_config"

    if ! systemctl reload "$service_name"; then
        error "SSH 服务重载失败，尝试恢复原配置"
        restore_ssh_config "$service_name"
        return 1
    fi

    if ! systemctl is-active --quiet "$service_name"; then
        error "SSH 服务未处于运行状态，尝试恢复原配置"
        restore_ssh_config "$service_name"
        return 1
    fi
}

# === 摘要与提示 ===
show_summary() {
    local service_name="$1"
    local ports
    local root_login
    local password_auth
    local keyboard_auth

    ports=$(get_effective_ports)
    root_login=$(get_effective_value "permitrootlogin")
    password_auth=$(get_effective_value "passwordauthentication")
    keyboard_auth=$(get_effective_value "kbdinteractiveauthentication")

    echo
    info "🎯 SSH 安全配置摘要："
    echo "  SSH 服务: $service_name（运行中）"
    echo "  监听端口: $(tr '\n' ' ' <<< "$ports")"
    echo "  Root 登录: $(format_root_login_display "$root_login")"
    echo "  密码认证: $password_auth"
    echo "  交互式认证: $keyboard_auth"
    echo "  Root SSH 密钥数量: $(get_root_key_count)"
    echo "  TCP 转发: $(get_effective_value "allowtcpforwarding")"
    echo "  配置备份: $SSH_BACKUP"
}

show_connection_warning() {
    local primary_port="$1"
    local ip_address

    ip_address=$(hostname -I 2>/dev/null | awk '{print $1}')
    ip_address="${ip_address:-服务器IP}"

    echo
    warn "⚠️ 重要提醒："
    echo "  新 SSH 连接示例:"
    echo "  ssh -p $primary_port root@$ip_address"
    echo
    echo "  请确认防火墙与云服务商安全组已放行端口 $primary_port。"
    echo "  请保持当前 SSH 会话不要关闭，并在新终端测试连接成功后再退出。"
}

# === 主流程 ===
main() {
    require_root

    local command_name
    for command_name in sshd systemctl ss awk sort grep mktemp install cp; do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            error "缺少必要命令: $command_name"
            exit 1
        fi
    done

    local ssh_service
    if ! ssh_service=$(get_ssh_service_name); then
        error "未找到 SSH systemd 服务（ssh.service 或 sshd.service）"
        exit 1
    fi

    if ! systemctl is-active --quiet "$ssh_service"; then
        error "SSH 服务未运行，拒绝修改配置"
        exit 1
    fi

    mkdir -p "$SSH_DROPIN_DIR"

    info "🔐 配置 SSH 安全策略..."

    echo
    local selected_port
    selected_port=$(choose_ssh_port)

    echo
    local password_auth
    password_auth=$(choose_password_authentication)

    echo
    local root_login
    root_login=$(choose_root_login_policy)

    echo
    info "生成并验证 SSH 配置..."

    local temp_config
    if ! temp_config=$(create_temp_ssh_config \
        "$selected_port" \
        "$password_auth" \
        "$root_login"); then
        exit 1
    fi

    if ! check_syntax "$temp_config"; then
        rm -f "$temp_config"
        exit 1
    fi

    if ! verify_effective_settings \
        "$temp_config" \
        "$selected_port" \
        "$password_auth" \
        "$root_login"; then
        rm -f "$temp_config"
        exit 1
    fi

    if ! apply_ssh_config "$temp_config" "$ssh_service"; then
        exit 1
    fi

    show_summary "$ssh_service"
    show_connection_warning "$selected_port"

    echo
    success "SSH 安全配置完成"
}

trap 'error "SSH 配置脚本在第 $LINENO 行执行失败"' ERR

main "$@"
