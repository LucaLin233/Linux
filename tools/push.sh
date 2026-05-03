#!/bin/bash

# =============================================================================
# Server File Push Tool v1.2.0
# 高效的多服务器文件推送工具 (支持密钥和密码认证)
#
# v1.2.0 修复:
# [HIGH]   #1 并发控制改用 wait -n，实现真正的滑动窗口
# [HIGH]   #2 移除 eval，用 Bash 数组构建命令，消除命令注入
# [MEDIUM] #3 RSYNC_ARCHIVE / RSYNC_COMPRESS 配置项现在实际生效
# [MEDIUM] #4 实现 ENABLE_LOGGING / LOG_FILE 日志功能
# [MEDIUM] #5 --test-auth 分支补充显式 exit，不依赖函数内部 exit
# [MEDIUM] #6 rsync 退出码 23/24 单独处理，不做无意义重试
# [LOW]    #7 parse_server_info 支持 IPv6 地址 [::1]:22
# [LOW]    #8 interactive_retry 改为参数传递，消除全局变量依赖
# =============================================================================

SCRIPT_VERSION="1.2.0"
SCRIPT_NAME="Server File Push Tool"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; PURPLE='\033[0;35m'; CYAN='\033[0;36m'
WHITE='\033[1;37m'; NC='\033[0m'

ICON_SUCCESS="✅"; ICON_ERROR="❌"; ICON_WORKING="⚡"; ICON_INFO="ℹ️ "
ICON_ROCKET="🚀"; ICON_TIMEOUT="⏰"; ICON_STOP="🛑"; ICON_RETRY="🔄"
ICON_WARNING="⚠️ "; ICON_CONFIG="⚙️ "; ICON_KEY="🔑"; ICON_LOCK="🔒"

CONNECTION_TIMEOUT=30; TOTAL_TIMEOUT=300; MAX_RETRIES=3; RETRY_DELAY=5

declare -a RUNNING_PIDS=()
TEMP_DIR=$(mktemp -d)
SUCCESS_FILE="$TEMP_DIR/success"
FAILED_FILE="$TEMP_DIR/failed"

# =============================================================================
# FIX #4: 实现日志函数（原版 ENABLE_LOGGING/LOG_FILE 有配置无实现）
# =============================================================================

log() {
    local level="$1" message="$2"
    [[ "${ENABLE_LOGGING:-false}" != "true" ]] && return 0
    local log_dir
    log_dir=$(dirname "${LOG_FILE:-/var/log/push.log}")
    [[ ! -d "$log_dir" ]] && mkdir -p "$log_dir" 2>/dev/null
    printf '[%s] [%-7s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$message" \
        >> "${LOG_FILE:-/var/log/push.log}"
}

# =============================================================================
# 配置文件生成
# =============================================================================

generate_config() {
    local config_file=${1:-"config.conf"}
    cat > "$config_file" << 'EOF'
# =============================================================================
# Server File Push Tool - 配置文件 v1.2.0
# =============================================================================

# 认证方式: "key" | "password"
AUTH_METHOD="key"

# 密钥认证
KEY_FILE="/root/.ssh/id_rsa"

# 密码认证
PASSWORD_METHOD="file"        # "file" | "env" | "interactive" | "inline"
PASSWORD_FILE="/root/.ssh/password.txt"
PASSWORD_ENV_VAR="SSHPASS"
# PASSWORD="your_password"   # inline 方式，不推荐

DEFAULT_PORT=22
DEFAULT_USER="root"

# 并发和超时
MAX_PARALLEL=15
CONNECTION_TIMEOUT=30
TOTAL_TIMEOUT=300
MAX_RETRIES=3
RETRY_DELAY=5

# 同步选项
DELETE_EXTRA="true"       # true: 删除目标多余文件
RSYNC_ARCHIVE="true"      # true: 启用 -a 归档模式（保留权限/时间戳/软链接）
RSYNC_COMPRESS="true"     # true: 启用 -z 压缩传输

# 服务器列表
# 格式: "host" | "host:port" | "user@host" | "user@host:port" | "[ipv6]:port"
SERVERS=(
    "192.168.1.100"
    "admin@192.168.1.101:2222"
    "root@server1.example.com:22"
    # "[2001:db8::1]:22"         # IPv6 示例
)

# 预定义任务
declare -A TASKS=(
    ["nginx"]="/etc/nginx/:/etc/nginx/"
    ["web"]="/var/www/html/:/var/www/html/"
    ["config"]="/root/configs/:/root/configs/"
    ["scripts"]="/root/scripts/:/root/scripts/"
    ["hosts"]="/etc/hosts:/etc/hosts"
    ["ssh-keys"]="/root/.ssh/authorized_keys:/root/.ssh/authorized_keys"
)

# 日志
ENABLE_LOGGING="false"
LOG_FILE="/var/log/push.log"

# SSH 主机验证
# "no"         - 自动接受所有指纹（有 MITM 风险）
# "accept-new" - 自动接受新主机，已变更指纹将被拒绝（推荐，SSH 7.6+）
STRICT_HOST_KEY_CHECKING="accept-new"
USER_KNOWN_HOSTS_FILE="/dev/null"
EOF
    echo -e "${GREEN}${ICON_SUCCESS} 配置文件已生成: ${WHITE}$config_file${NC}"
}

# =============================================================================
# 依赖检查
# =============================================================================

check_dependencies() {
    local missing_deps=()
    for cmd in rsync ssh; do
        command -v "$cmd" &>/dev/null || missing_deps+=("$cmd")
    done
    if [[ "$AUTH_METHOD" == "password" ]]; then
        if ! command -v sshpass &>/dev/null; then
            echo -e "${RED}${ICON_ERROR} 密码认证需要安装 sshpass${NC}"
            echo -e "${WHITE}  Ubuntu/Debian: ${CYAN}sudo apt install sshpass${NC}"
            echo -e "${WHITE}  CentOS/RHEL:   ${CYAN}sudo yum install sshpass${NC}"
            missing_deps+=("sshpass")
        fi
    fi
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        echo -e "${RED}${ICON_ERROR} 缺少必要依赖: ${missing_deps[*]}${NC}"
        [[ -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
        exit 1
    fi
}

# =============================================================================
# 密码获取
# =============================================================================

get_password() {
    local password=""
    case "$PASSWORD_METHOD" in
        "file")
            [[ ! -f "$PASSWORD_FILE" ]] && {
                echo -e "${RED}${ICON_ERROR} 密码文件不存在: $PASSWORD_FILE${NC}"; return 1
            }
            local perms
            perms=$(stat -c %a "$PASSWORD_FILE" 2>/dev/null)
            [[ "$perms" != "600" ]] && \
                echo -e "${YELLOW}${ICON_WARNING} 密码文件权限不安全，建议: chmod 600 $PASSWORD_FILE${NC}"
            password=$(head -n1 "$PASSWORD_FILE" 2>/dev/null)
            [[ -z "$password" ]] && { echo -e "${RED}${ICON_ERROR} 密码文件为空${NC}"; return 1; }
            ;;
        "env")
            password="${!PASSWORD_ENV_VAR}"
            [[ -z "$password" ]] && {
                echo -e "${RED}${ICON_ERROR} 环境变量 $PASSWORD_ENV_VAR 未设置${NC}"; return 1
            }
            ;;
        "interactive")
            echo -e "${CYAN}${ICON_LOCK} 请输入SSH密码:${NC}"
            read -rs password; echo
            [[ -z "$password" ]] && { echo -e "${RED}${ICON_ERROR} 密码不能为空${NC}"; return 1; }
            ;;
        "inline")
            [[ -z "${PASSWORD:-}" ]] && {
                echo -e "${RED}${ICON_ERROR} 未设置 PASSWORD 变量${NC}"; return 1
            }
            password="$PASSWORD"
            ;;
        *)
            echo -e "${RED}${ICON_ERROR} 未知密码方式: $PASSWORD_METHOD${NC}"; return 1
            ;;
    esac
    export SSHPASS="$password"
    return 0
}

# =============================================================================
# FIX #7: 服务器信息解析 —— 新增 IPv6 [::1]:port 格式支持
# 原版正则 ^(.+):([0-9]+)$ 会将 [::1]:22 错误拆分为 host=[: port=1]22
# =============================================================================

parse_server_info() {
    local server_info="$1"
    local user="$DEFAULT_USER"
    local host="" port="$DEFAULT_PORT"

    # 解析 user@ 前缀
    if [[ "$server_info" =~ ^([^@]+)@(.+)$ ]]; then
        user="${BASH_REMATCH[1]}"
        server_info="${BASH_REMATCH[2]}"
    fi

    # IPv6: [::1]:port
    if [[ "$server_info" =~ ^\[([^\]]+)\]:([0-9]+)$ ]]; then
        host="${BASH_REMATCH[1]}"; port="${BASH_REMATCH[2]}"
    # IPv6: [::1]（无端口）
    elif [[ "$server_info" =~ ^\[([^\]]+)\]$ ]]; then
        host="${BASH_REMATCH[1]}"
    # 普通 host:port
    elif [[ "$server_info" =~ ^(.+):([0-9]+)$ ]]; then
        host="${BASH_REMATCH[1]}"; port="${BASH_REMATCH[2]}"
    else
        host="$server_info"
    fi

    echo "$user@$host:$port"
}

# =============================================================================
# FIX #2: 移除 eval，用 Bash 数组构建并直接执行命令，消除命令注入
# FIX #3: RSYNC_ARCHIVE / RSYNC_COMPRESS 实际控制 rsync 参数
# FIX #6: rsync 退出码 23/24 单独处理，不做无意义重试
# =============================================================================

retry_rsync() {
    local server_info=$1 src=$2 dst=$3
    local attempt=1

    local parsed_info
    parsed_info=$(parse_server_info "$server_info")
    local user host port tmp
    user="${parsed_info%%@*}"
    tmp="${parsed_info#*@}"
    port="${tmp##*:}"
    host="${tmp%:*}"

    # FIX #3: 根据配置动态构建 rsync 选项数组，不再硬编码 -az
    local rsync_opts=("--timeout=$CONNECTION_TIMEOUT")
    [[ "${RSYNC_ARCHIVE:-true}"   == "true" ]] && rsync_opts+=("-a") || rsync_opts+=("-r")
    [[ "${RSYNC_COMPRESS:-true}"  == "true" ]] && rsync_opts+=("-z")
    [[ "${DELETE_EXTRA:-true}"    == "true" ]] && rsync_opts+=("--delete")

    # FIX #2: SSH 选项用数组，消除字符串拼接后 eval 的注入风险
    local ssh_opts=(
        -p "$port"
        -o "ConnectTimeout=$CONNECTION_TIMEOUT"
        -o "StrictHostKeyChecking=${STRICT_HOST_KEY_CHECKING:-accept-new}"
        -o "UserKnownHostsFile=${USER_KNOWN_HOSTS_FILE:-/dev/null}"
        -o "LogLevel=ERROR"
    )

    while [[ $attempt -le $MAX_RETRIES ]]; do
        [[ $attempt -gt 1 ]] && {
            echo -e "${YELLOW}    ${ICON_RETRY} 第${attempt}次重试 (${RETRY_DELAY}s后)...${NC}"
            sleep "$RETRY_DELAY"
        }

        local output exit_code
        if [[ "$AUTH_METHOD" == "key" ]]; then
            # FIX #2: 直接数组展开执行，不经过 eval
            output=$(timeout "$TOTAL_TIMEOUT" rsync "${rsync_opts[@]}" \
                -e "ssh -i $KEY_FILE ${ssh_opts[*]}" \
                "$src" "$user@$host:$dst" 2>&1)
            exit_code=$?
        else
            local ssh_pw_opts=("${ssh_opts[@]}" -o "PreferredAuthentications=password")
            output=$(timeout "$TOTAL_TIMEOUT" sshpass -e rsync "${rsync_opts[@]}" \
                -e "ssh ${ssh_pw_opts[*]}" \
                "$src" "$user@$host:$dst" 2>&1)
            exit_code=$?
        fi

        case $exit_code in
            0) return 0 ;;
            23|24)
                echo -e "${RED}    ${ICON_ERROR} rsync 退出码 $exit_code（文件传输不完整，重试无意义）${NC}"
                [[ -n "$output" ]] && echo -e "${RED}    详情: $output${NC}"
                log "ERROR" "[$server_info] rsync exit=$exit_code: $output"
                return 1
                ;;
            124)
                [[ $attempt -eq $MAX_RETRIES ]] && \
                    echo -e "${RED}    ${ICON_TIMEOUT} 连接超时，已达最大重试次数${NC}"
                ;;
            255)
                if [[ $attempt -eq $MAX_RETRIES ]]; then
                    echo -e "${RED}    ${ICON_ERROR} SSH连接失败，已达最大重试次数${NC}"
                    [[ -n "$output" ]] && echo -e "${RED}    详情: $output${NC}"
                fi
                ;;
            *)
                if [[ $attempt -eq $MAX_RETRIES ]]; then
                    echo -e "${RED}    ${ICON_ERROR} 推送失败 (退出码: $exit_code)${NC}"
                    [[ -n "$output" ]] && echo -e "${RED}    错误详情: $output${NC}"
                fi
                ;;
        esac
        ((attempt++))
    done

    log "ERROR" "[$server_info] 推送失败，已重试 $MAX_RETRIES 次"
    return 1
}

push_to_server() {
    local server_info=$1 src=$2 dst=$3 index=$4 total=$5
    local display_info
    display_info=$(parse_server_info "$server_info")

    echo -e "${BLUE}[${index}/${total}]${NC} ${ICON_WORKING} ${CYAN}$display_info${NC}"

    if retry_rsync "$server_info" "$src" "$dst"; then
        echo -e "${GREEN}[${index}/${total}]${NC} ${ICON_SUCCESS} ${GREEN}$display_info${NC} ${WHITE}推送成功${NC}"
        log "INFO" "[$display_info] 推送成功"
        ( flock -x 200; echo "$server_info" >> "$SUCCESS_FILE" ) 200>"$SUCCESS_FILE.lock"
    else
        echo -e "${RED}[${index}/${total}]${NC} ${ICON_ERROR} ${RED}$display_info${NC} ${WHITE}推送失败 (已重试${MAX_RETRIES}次)${NC}"
        log "WARN" "[$display_info] 推送失败"
        ( flock -x 201; echo "$server_info" >> "$FAILED_FILE" ) 201>"$FAILED_FILE.lock"
    fi
}

# =============================================================================
# 信号处理
# =============================================================================

cleanup() {
    echo ""; echo -e "${YELLOW}${ICON_STOP} 检测到中断信号，正在清理...${NC}"
    for pid in "${RUNNING_PIDS[@]}"; do
        kill -0 "$pid" 2>/dev/null && kill -TERM "$pid" 2>/dev/null
    done
    sleep 2
    for pid in "${RUNNING_PIDS[@]}"; do
        kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null
    done
    [[ -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
    unset SSHPASS
    echo -e "${RED}${ICON_STOP} 推送已被用户中断${NC}"
    exit 1
}

trap cleanup SIGINT SIGTERM

# =============================================================================
# 配置检查与验证
# =============================================================================

check_and_generate_config() {
    local config_file=${1:-"config.conf"}
    if [[ ! -f "$config_file" ]]; then
        echo -e "${CYAN}${ICON_INFO} 欢迎使用 ${WHITE}$SCRIPT_NAME v$SCRIPT_VERSION${NC}"
        echo ""
        echo -e "${YELLOW}${ICON_WARNING} 未找到配置文件，正在生成默认配置...${NC}"
        generate_config "$config_file"
        echo ""
        echo -e "${RED}${ICON_CONFIG} 请编辑 ${CYAN}$config_file${RED} 后重新运行脚本${NC}"
        [[ -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
        exit 0
    fi
}

validate_config() {
    local errors=0

    [[ "$AUTH_METHOD" != "key" && "$AUTH_METHOD" != "password" ]] && {
        echo -e "${RED}${ICON_ERROR} 无效认证方式: $AUTH_METHOD${NC}"; ((errors++))
    }

    if [[ "$AUTH_METHOD" == "key" ]]; then
        if [[ ! -f "$KEY_FILE" ]]; then
            echo -e "${RED}${ICON_ERROR} 私钥不存在: $KEY_FILE${NC}"; ((errors++))
        elif [[ $(stat -c %a "$KEY_FILE" 2>/dev/null) != "600" ]]; then
            echo -e "${YELLOW}${ICON_WARNING} 私钥权限不安全，建议: chmod 600 $KEY_FILE${NC}"
        fi
    fi

    if [[ "$AUTH_METHOD" == "password" ]]; then
        command -v sshpass &>/dev/null || { echo -e "${RED}${ICON_ERROR} 需要安装 sshpass${NC}"; ((errors++)); }
        case "$PASSWORD_METHOD" in
            "file")
                [[ ! -f "$PASSWORD_FILE" ]] && {
                    echo -e "${RED}${ICON_ERROR} 密码文件不存在: $PASSWORD_FILE${NC}"; ((errors++))
                } ;;
            "env")
                [[ -z "${!PASSWORD_ENV_VAR:-}" ]] && \
                    echo -e "${YELLOW}${ICON_WARNING} 环境变量 $PASSWORD_ENV_VAR 未设置${NC}" ;;
            "inline")
                [[ -z "${PASSWORD:-}" ]] && {
                    echo -e "${RED}${ICON_ERROR} 未设置 PASSWORD 变量${NC}"; ((errors++))
                } ;;
            "interactive") ;;
            *)
                echo -e "${RED}${ICON_ERROR} 无效密码方式: $PASSWORD_METHOD${NC}"; ((errors++)) ;;
        esac
    fi

    [[ ${#SERVERS[@]} -eq 0 ]] && {
        echo -e "${RED}${ICON_ERROR} 未配置任何服务器${NC}"; ((errors++))
    }

    if [[ " ${SERVERS[*]} " =~ " 192.168.1.100 " || \
          " ${SERVERS[*]} " =~ " root@server1.example.com:22 " ]]; then
        echo -e "${YELLOW}${ICON_WARNING} 检测到示例服务器配置，请替换为实际服务器${NC}"
    fi

    if [[ $errors -gt 0 ]]; then
        echo -e "${RED}${ICON_ERROR} 配置验证失败，请检查: config.conf${NC}"
        [[ -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
        exit 1
    fi
}

# =============================================================================
# 结果统计
# =============================================================================

show_summary() {
    local total=${#SERVERS[@]} success=0 failed=0
    [[ -f "$SUCCESS_FILE" ]] && success=$(wc -l < "$SUCCESS_FILE" 2>/dev/null || echo 0)
    [[ -f "$FAILED_FILE"  ]] && failed=$(wc -l  < "$FAILED_FILE"  2>/dev/null || echo 0)

    echo ""; echo -e "${WHITE}📊 推送结果统计：${NC}"
    echo -e "${GREEN}  ✅ 成功: $success/$total${NC}"
    echo -e "${RED}  ❌ 失败: $failed/$total${NC}"

    if [[ $failed -gt 0 && -f "$FAILED_FILE" ]]; then
        echo ""; echo -e "${RED}${ICON_WARNING} 失败的服务器：${NC}"
        while IFS= read -r server; do
            [[ -n "$server" ]] && echo -e "${RED}  • $(parse_server_info "$server")${NC}"
        done < "$FAILED_FILE"
    fi
}

# =============================================================================
# FIX #8: interactive_retry 改为参数传入路径，消除隐式全局变量依赖
# 原版直接使用 $SRC_PATH/$DST_PATH，函数无法独立复用
# =============================================================================

interactive_retry() {
    local src="$1" dst="$2"      # FIX #8: 路径通过参数传入

    local failed=0
    [[ -f "$FAILED_FILE" ]] && failed=$(wc -l < "$FAILED_FILE" 2>/dev/null || echo 0)
    [[ $failed -eq 0 ]] && return

    echo ""; echo -e "${YELLOW}${ICON_RETRY} 检测到 $failed 台服务器推送失败${NC}"
    echo -e "${CYAN}是否要重新尝试推送失败的服务器？ [y/N]${NC}"

    read -r -t 30 response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}跳过重试${NC}"; return
    fi

    echo ""; echo -e "${YELLOW}重新推送失败的服务器...${NC}"

    local retry_file="$TEMP_DIR/retry_list"
    cp "$FAILED_FILE" "$retry_file"
    > "$FAILED_FILE"; rm -f "$FAILED_FILE.lock"

    local index=0 total_retry
    total_retry=$(wc -l < "$retry_file" 2>/dev/null || echo 0)
    RUNNING_PIDS=()

    while IFS= read -r server; do
        [[ -n "$server" ]] || continue
        ((index++))
        while (( $(jobs -rp | wc -l) >= MAX_PARALLEL )); do
            wait -n 2>/dev/null || wait
        done
        push_to_server "$server" "$src" "$dst" "$index" "$total_retry" &
        RUNNING_PIDS+=($!)
    done < "$retry_file"

    wait
    show_summary

    local new_failed=0
    [[ -f "$FAILED_FILE" ]] && new_failed=$(wc -l < "$FAILED_FILE" 2>/dev/null || echo 0)
    [[ $new_failed -gt 0 && $new_failed -lt $failed ]] && \
        interactive_retry "$src" "$dst"
}

# =============================================================================
# 帮助
# =============================================================================

show_help() {
    echo -e "${CYAN}${ICON_INFO} $SCRIPT_NAME v$SCRIPT_VERSION${NC}"
    echo ""; echo -e "${WHITE}用法: $0 <任务名> | <源路径> <目标路径>${NC}"; echo ""
    local auth_icon="${ICON_KEY}" auth_desc="SSH密钥认证"
    [[ "$AUTH_METHOD" == "password" ]] && { auth_icon="${ICON_LOCK}"; auth_desc="SSH密码认证"; }
    echo -e "${YELLOW}🔐 当前认证方式：${NC} $auth_icon $auth_desc"; echo ""
    if [[ ${#TASKS[@]} -gt 0 ]]; then
        echo -e "${YELLOW}📋 预定义任务：${NC}"
        for task in "${!TASKS[@]}"; do
            IFS=':' read -r src dst <<< "${TASKS[$task]}"
            echo -e "  ${GREEN}$task${NC}: ${BLUE}$src${NC} -> ${PURPLE}$dst${NC}"
        done; echo ""
    fi
    echo -e "${YELLOW}🛠️  选项：${NC}"
    echo -e "  ${WHITE}$0 -h, --help${NC}           # 显示帮助"
    echo -e "  ${WHITE}$0 --generate-config${NC}   # 生成配置文件"
    echo -e "  ${WHITE}$0 --test-auth${NC}          # 测试认证配置"
    echo ""
    echo -e "${CYAN}⚙️  当前配置:${NC}"
    echo -e "  服务器数量: ${CYAN}${#SERVERS[@]}${NC}  |  认证: ${CYAN}$AUTH_METHOD${NC}  |  主机验证: ${CYAN}${STRICT_HOST_KEY_CHECKING:-accept-new}${NC}"
    echo -e "  并发数: ${CYAN}${MAX_PARALLEL}${NC}  |  重试: ${CYAN}${MAX_RETRIES}次/${RETRY_DELAY}s${NC}  |  超时: ${CYAN}${CONNECTION_TIMEOUT}s/${TOTAL_TIMEOUT}s${NC}"
}

# =============================================================================
# 认证测试
# FIX #5: 函数改为 return 而非 exit，由调用方决定退出
# =============================================================================

test_authentication() {
    echo -e "${CYAN}${ICON_CONFIG} 测试认证配置...${NC}"; echo ""
    check_dependencies

    if [[ "$AUTH_METHOD" == "password" ]]; then
        echo -e "${YELLOW}${ICON_LOCK} 密码认证测试${NC}"
        if get_password; then
            echo -e "${GREEN}${ICON_SUCCESS} 密码获取成功${NC}"
        else
            echo -e "${RED}${ICON_ERROR} 密码获取失败${NC}"
            [[ -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
            return 1
        fi
    else
        echo -e "${YELLOW}${ICON_KEY} 密钥认证测试${NC}"
        if [[ ! -f "$KEY_FILE" ]]; then
            echo -e "${RED}${ICON_ERROR} 密钥文件不存在: $KEY_FILE${NC}"
            [[ -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
            return 1
        fi
        echo -e "${GREEN}${ICON_SUCCESS} 密钥文件存在: $KEY_FILE${NC}"
        local perms
        perms=$(stat -c %a "$KEY_FILE" 2>/dev/null)
        [[ "$perms" == "600" ]] \
            && echo -e "${GREEN}${ICON_SUCCESS} 密钥权限正确${NC}" \
            || echo -e "${YELLOW}${ICON_WARNING} 密钥权限: $perms (建议: 600)${NC}"
    fi

    echo ""; echo -e "${GREEN}${ICON_SUCCESS} 认证配置测试完成${NC}"
    [[ -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
    unset SSHPASS
    return 0
}

# =============================================================================
# 最终清理
# =============================================================================

finish_cleanup() {
    local failed=0
    [[ -f "$FAILED_FILE" ]] && failed=$(wc -l < "$FAILED_FILE" 2>/dev/null || echo 0)
    [[ $failed -eq 0 ]] \
        && echo -e "\n${GREEN}${ICON_SUCCESS} ${WHITE}所有服务器推送成功！${NC}" \
        || echo -e "\n${YELLOW}${ICON_WARNING} ${WHITE}部分服务器推送失败，请检查网络连接和服务器配置${NC}"
    [[ -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
    unset SSHPASS
    RUNNING_PIDS=()
}

# =============================================================================
# 主程序入口
# FIX #5: --test-auth 分支补充显式 exit $?，不再依赖函数内部 exit 来结束主流程
# =============================================================================

case "${1:-}" in
    "--generate-config")
        echo -e "${CYAN}${ICON_CONFIG} 生成新的配置文件...${NC}"
        generate_config "config.conf"
        echo -e "${YELLOW}请编辑 config.conf 后重新运行脚本${NC}"
        [[ -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
        exit 0
        ;;
    "--test-auth")
        check_and_generate_config
        source config.conf
        validate_config
        test_authentication
        exit $?    # FIX #5: 显式退出，防止继续执行后续推送逻辑
        ;;
    "-h"|"--help")
        check_and_generate_config
        source config.conf
        show_help
        [[ -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
        exit 0
        ;;
    *)
        check_and_generate_config
        source config.conf
        validate_config
        check_dependencies
        ;;
esac

# 密码认证准备
if [[ "$AUTH_METHOD" == "password" ]]; then
    get_password || { echo -e "${RED}${ICON_ERROR} 密码认证初始化失败${NC}"; finish_cleanup; exit 1; }
fi

# 参数解析
if [[ $# -eq 1 ]]; then
    TASK_NAME=$1
    if [[ -n "${TASKS[$TASK_NAME]:-}" ]]; then
        IFS=':' read -r SRC_PATH DST_PATH <<< "${TASKS[$TASK_NAME]}"
        echo -e "${ICON_ROCKET} ${YELLOW}执行预定义任务:${NC} ${GREEN}$TASK_NAME${NC}"
    else
        echo -e "${RED}${ICON_ERROR} 未找到任务 '$TASK_NAME'${NC}"
        echo -e "${CYAN}可用任务：${NC}"
        for task in "${!TASKS[@]}"; do echo -e "  ${GREEN}$task${NC}"; done
        finish_cleanup; exit 1
    fi
elif [[ $# -eq 2 ]]; then
    SRC_PATH=$1; DST_PATH=$2
    echo -e "${ICON_ROCKET} ${YELLOW}执行自定义推送${NC}"
else
    show_help; finish_cleanup; exit 1
fi

[[ ! -e "$SRC_PATH" ]] && {
    echo -e "${RED}${ICON_ERROR} 源路径不存在: $SRC_PATH${NC}"
    finish_cleanup; exit 1
}

# 推送信息摘要
echo -e "${WHITE}📂 源路径:${NC} ${BLUE}$SRC_PATH${NC}"
echo -e "${WHITE}📍 目标路径:${NC} ${PURPLE}$DST_PATH${NC}"
echo -e "${WHITE}🖥️  服务器数量:${NC} ${CYAN}${#SERVERS[@]}${NC}"
[[ "$AUTH_METHOD" == "key" ]] \
    && echo -e "${WHITE}🔐 认证方式:${NC} ${CYAN}SSH密钥${NC} (${KEY_FILE})" \
    || echo -e "${WHITE}🔐 认证方式:${NC} ${CYAN}SSH密码${NC} (${PASSWORD_METHOD})"
echo -e "${WHITE}🔒 主机验证:${NC} ${CYAN}${STRICT_HOST_KEY_CHECKING:-accept-new}${NC}"
echo -e "${WHITE}🔄 重试设置:${NC} ${CYAN}最多${MAX_RETRIES}次，间隔${RETRY_DELAY}s${NC}"
echo -e "${WHITE}⏰ 超时设置:${NC} ${CYAN}${CONNECTION_TIMEOUT}s/${TOTAL_TIMEOUT}s${NC}"
echo -e "${WHITE}⚡ 并发数:${NC} ${CYAN}${MAX_PARALLEL}${NC}"
echo -e "${WHITE}🔄 完全覆盖:${NC} ${YELLOW}$DELETE_EXTRA${NC}"

if [[ -f "$SRC_PATH" ]]; then
    echo -e "${WHITE}📄 文件大小:${NC} ${CYAN}$(du -h "$SRC_PATH" | cut -f1)${NC}"
elif [[ -d "$SRC_PATH" ]]; then
    echo -e "${WHITE}📁 目录大小:${NC} ${CYAN}$(du -sh "$SRC_PATH" 2>/dev/null | cut -f1)${NC}"
    echo -e "${WHITE}📄 文件数量:${NC} ${CYAN}$(find "$SRC_PATH" -type f | wc -l)${NC}"
fi

echo ""; echo -e "${YELLOW}开始推送... (按 Ctrl+C 可安全中断)${NC}"; echo ""

> "$SUCCESS_FILE"; > "$FAILED_FILE"
TOTAL_SERVERS=${#SERVERS[@]}
CURRENT_INDEX=0
START_TIME=$(date +%s)

for server in "${SERVERS[@]}"; do
    ((CURRENT_INDEX++))

    # FIX #1: 真正的滑动窗口并发控制
    # 原版: (($(jobs -r | wc -l) >= MAX_PARALLEL)) && wait
    #        wait 无参数 → 等待全部任务完成 → 批次模式，并发窗口实际等于批次大小
    # 修复: 循环 + wait -n（bash 4.3+）→ 等待任意一个子进程退出
    #        保持活跃进程数始终贴近 MAX_PARALLEL
    while (( $(jobs -rp | wc -l) >= MAX_PARALLEL )); do
        wait -n 2>/dev/null || wait
    done

    push_to_server "$server" "$SRC_PATH" "$DST_PATH" "$CURRENT_INDEX" "$TOTAL_SERVERS" &
    RUNNING_PIDS+=($!)
done

wait   # 等待最后一批完成

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
[[ $DURATION -ge 60 ]] \
    && DURATION_STR="${DURATION}s ($((DURATION/60))m$((DURATION%60))s)" \
    || DURATION_STR="${DURATION}s"

echo ""; echo -e "${CYAN}⏱️  总耗时: ${WHITE}$DURATION_STR${NC}"

show_summary
interactive_retry "$SRC_PATH" "$DST_PATH"   # FIX #8: 通过参数传入，不再读全局变量

echo ""; echo -e "${CYAN}═══════════════════════════════════════${NC}"

final_success=0; final_failed=0
[[ -f "$SUCCESS_FILE" ]] && final_success=$(wc -l < "$SUCCESS_FILE" 2>/dev/null || echo 0)
[[ -f "$FAILED_FILE"  ]] && final_failed=$(wc -l  < "$FAILED_FILE"  2>/dev/null || echo 0)

if [[ $final_failed -eq 0 ]]; then
    echo -e "${GREEN}${ICON_SUCCESS} ${WHITE}推送任务完成！所有 $final_success 台服务器推送成功${NC}"
else
    echo -e "${YELLOW}${ICON_WARNING} ${WHITE}推送任务完成！$final_success 台成功，$final_failed 台失败${NC}"
    echo ""; echo -e "${CYAN}💡 建议：${NC}"
    echo -e "${WHITE}• 检查失败服务器的网络连接${NC}"
    [[ "$AUTH_METHOD" == "key" ]] \
        && echo -e "${WHITE}• 验证SSH密钥和权限设置${NC}" \
        || echo -e "${WHITE}• 验证SSH密码和用户权限${NC}"
    echo -e "${WHITE}• 使用 '$0 --test-auth' 测试认证配置${NC}"
fi

echo -e "${CYAN}═══════════════════════════════════════${NC}"
log "INFO" "任务完成: 成功=$final_success 失败=$final_failed 耗时=$DURATION_STR"

finish_cleanup

[[ $final_failed -gt 0 ]] && exit 1 || exit 0
