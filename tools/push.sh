#!/bin/bash

# =============================================================================
# Server File Push Tool v1.1.0  
# 高效的多服务器文件推送工具 (支持密钥和密码认证)
# 
# 功能特性:
# - 多服务器并发推送
# - 支持SSH密钥和密码认证
# - 网络故障自动重试  
# - 连接超时控制
# - 实时进度显示
# - 彩色输出界面
# - 预定义任务支持
# - 安全的SSH连接
# - 修复并发统计问题
# =============================================================================

# 版本信息
SCRIPT_VERSION="1.1.0"
SCRIPT_NAME="Server File Push Tool"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

# 图标定义
ICON_SUCCESS="✅"
ICON_ERROR="❌"
ICON_WORKING="⚡"
ICON_INFO="ℹ️ "
ICON_ROCKET="🚀"
ICON_TIMEOUT="⏰"
ICON_STOP="🛑"
ICON_RETRY="🔄"
ICON_WARNING="⚠️ "
ICON_CONFIG="⚙️ "
ICON_KEY="🔑"
ICON_LOCK="🔒"

# 超时和重试设置
CONNECTION_TIMEOUT=30
TOTAL_TIMEOUT=300
MAX_RETRIES=3
RETRY_DELAY=5

# 进程跟踪和结果记录 - 使用临时文件解决并发问题
declare -a RUNNING_PIDS=()
TEMP_DIR=$(mktemp -d)
SUCCESS_FILE="$TEMP_DIR/success"
FAILED_FILE="$TEMP_DIR/failed"

# =============================================================================
# 配置文件生成函数 - 添加密码认证支持
# =============================================================================

generate_config() {
    local config_file=${1:-"config.conf"}
    
    cat > "$config_file" << 'EOF'
# =============================================================================
# Server File Push Tool - 配置文件 v1.1.0
# =============================================================================
# 本文件包含了所有可配置的参数，请根据你的实际环境进行修改
# 
# 项目地址: https://github.com/yourusername/server-push-tool
# 版本: 1.1.0
# 新增: SSH密码认证支持

# =============================================================================
# SSH 认证配置
# =============================================================================

# SSH 认证方式 (必须选择一种)
# "key"      - 使用SSH密钥认证 (推荐，更安全)
# "password" - 使用密码认证 (需要安装sshpass)
AUTH_METHOD="key"

# SSH密钥认证配置 (当AUTH_METHOD="key"时使用)
# SSH 私钥文件路径 (必须修改)
# 确保私钥文件存在且权限正确 (600)
KEY_FILE="/root/.ssh/id_rsa"

# SSH密码认证配置 (当AUTH_METHOD="password"时使用)
# 密码提供方式:
# "file"        - 从文件读取密码 (推荐)
# "env"         - 从环境变量读取密码
# "interactive" - 脚本运行时交互式输入密码
# "inline"      - 直接在配置中设置密码 (不推荐，不安全)
PASSWORD_METHOD="file"

# 密码文件路径 (当PASSWORD_METHOD="file"时使用)
# 文件应只包含一行密码，权限设置为600
PASSWORD_FILE="/root/.ssh/password.txt"

# 环境变量名 (当PASSWORD_METHOD="env"时使用)
# 例如: SSHPASS="your_password" ./push.sh
PASSWORD_ENV_VAR="SSHPASS"

# 直接密码设置 (当PASSWORD_METHOD="inline"时使用)
# 警告: 不推荐，密码会以明文存储在配置文件中
# PASSWORD="your_password_here"

# 默认SSH端口 (根据你的服务器配置修改)
DEFAULT_PORT=22

# 默认SSH用户名 (可以在服务器列表中单独指定)
DEFAULT_USER="root"

# =============================================================================
# 并发和超时配置
# =============================================================================

# 最大并发连接数 (建议根据网络带宽调整，一般10-20)
MAX_PARALLEL=15

# SSH连接超时时间 (秒)
CONNECTION_TIMEOUT=30

# 文件传输总超时时间 (秒)
TOTAL_TIMEOUT=300

# 重试配置
MAX_RETRIES=3        # 失败后最大重试次数
RETRY_DELAY=5        # 重试间隔时间 (秒)

# =============================================================================
# 同步选项
# =============================================================================

# 是否删除目标目录中多余的文件 (完全同步)
# true: 完全覆盖，删除目标目录多余文件
# false: 只更新和添加文件，不删除
DELETE_EXTRA="true"

# =============================================================================
# 服务器列表配置
# =============================================================================
# 格式: "hostname:port" 或 "hostname" (使用默认端口)
#       "user@hostname:port" 或 "user@hostname" (指定用户名)
# 
# 示例:
#   "192.168.1.100"              # 使用默认用户和端口
#   "192.168.1.100:2222"         # 使用默认用户，自定义端口
#   "admin@192.168.1.100"        # 自定义用户，默认端口
#   "admin@192.168.1.100:2222"   # 自定义用户和端口
#   "server.example.com:2222"

SERVERS=(
    # 请在这里添加你的服务器
    # 示例服务器配置（请删除并替换为实际服务器）
    "192.168.1.100"
    "admin@192.168.1.101:2222"
    "root@server1.example.com:22"
    # "user@server2.example.com:2222"
    # "10.0.0.10"
)

# =============================================================================
# 预定义推送任务
# =============================================================================
# 格式: ["任务名"]="源路径:目标路径"
# 
# 使用方法: ./push.sh 任务名
# 
# 路径说明:
#   - 文件同步: "/local/file.txt:/remote/file.txt"
#   - 目录同步: "/local/dir/:/remote/dir/"
#   - 目录内容同步: "/local/dir/:/remote/"

declare -A TASKS=(
    # Web应用相关
    ["nginx"]="/etc/nginx/:/etc/nginx/"
    ["web"]="/var/www/html/:/var/www/html/"
    ["static"]="/var/www/static/:/var/www/static/"
    
    # 配置文件相关
    ["config"]="/root/configs/:/root/configs/"
    ["scripts"]="/root/scripts/:/root/scripts/"
    ["crontab"]="/etc/crontab:/etc/crontab"
    
    # 应用程序相关
    ["app"]="/opt/myapp/:/opt/myapp/"
    ["logs"]="/var/log/myapp/:/var/log/myapp/"
    
    # 系统相关
    ["hosts"]="/etc/hosts:/etc/hosts"
    ["ssh-keys"]="/root/.ssh/authorized_keys:/root/.ssh/authorized_keys"
    
    # 自定义任务示例（请根据需要修改）
    ["example"]="/path/to/source:/path/to/destination"
)

# =============================================================================
# 高级配置
# =============================================================================

# 日志设置
ENABLE_LOGGING="false"         # 是否启用日志记录
LOG_FILE="/var/log/push.log"   # 日志文件路径

# 安全设置
STRICT_HOST_KEY_CHECKING="no"  # SSH严格主机密钥检查
USER_KNOWN_HOSTS_FILE="/dev/null"  # SSH known_hosts文件

# 性能优化
RSYNC_COMPRESS="true"          # 是否启用压缩传输
RSYNC_ARCHIVE="true"           # 是否使用归档模式

# =============================================================================
# 认证方式配置说明
# =============================================================================
# 
# 1. 密钥认证 (推荐):
#    - 设置 AUTH_METHOD="key"
#    - 配置 KEY_FILE 指向私钥文件
#    - 确保私钥权限: chmod 600 /path/to/key
#    - 确保目标服务器已配置公钥
# 
# 2. 密码认证:
#    - 设置 AUTH_METHOD="password"  
#    - 确保安装了 sshpass: apt install sshpass 或 yum install sshpass
#    - 选择密码提供方式:
#      * 文件方式 (推荐): 
#        PASSWORD_METHOD="file"
#        echo "your_password" > /root/.ssh/password.txt
#        chmod 600 /root/.ssh/password.txt
#      * 环境变量方式:
#        PASSWORD_METHOD="env"
#        export SSHPASS="your_password"
#      * 交互式输入:
#        PASSWORD_METHOD="interactive"
# 
# 3. 安全建议:
#    - 优先使用密钥认证
#    - 密码文件权限设置为 600
#    - 避免在命令行历史中暴露密码
#    - 定期更换密码
# 
# =============================================================================
# 快速设置示例
# =============================================================================
# 
# 密钥认证设置:
#   ssh-keygen -t rsa -b 4096
#   ssh-copy-id user@server
#   
# 密码认证设置:
#   sudo apt install sshpass  # Debian/Ubuntu
#   sudo yum install sshpass   # CentOS/RHEL
#   echo "password" > ~/.ssh/password.txt
#   chmod 600 ~/.ssh/password.txt
# 
# =============================================================================
EOF

    echo -e "${GREEN}${ICON_SUCCESS} 配置文件已生成: ${WHITE}$config_file${NC}"
}

# =============================================================================
# 依赖检查函数
# =============================================================================

check_dependencies() {
    local missing_deps=()
    
    # 检查基本工具
    for cmd in rsync ssh; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_deps+=("$cmd")
        fi
    done
    
    # 检查密码认证依赖
    if [[ "$AUTH_METHOD" == "password" ]]; then
        if ! command -v sshpass &> /dev/null; then
            echo -e "${RED}${ICON_ERROR} 密码认证需要安装 sshpass${NC}"
            echo -e "${YELLOW}安装命令:${NC}"
            echo -e "${WHITE}  Ubuntu/Debian: ${CYAN}sudo apt install sshpass${NC}"
            echo -e "${WHITE}  CentOS/RHEL:   ${CYAN}sudo yum install sshpass${NC}"
            echo -e "${WHITE}  Fedora:        ${CYAN}sudo dnf install sshpass${NC}"
            echo -e "${WHITE}  Arch Linux:    ${CYAN}sudo pacman -S sshpass${NC}"
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
# 密码获取函数
# =============================================================================

get_password() {
    local password=""
    
    case "$PASSWORD_METHOD" in
        "file")
            if [[ ! -f "$PASSWORD_FILE" ]]; then
                echo -e "${RED}${ICON_ERROR} 密码文件不存在: $PASSWORD_FILE${NC}"
                echo -e "${YELLOW}请创建密码文件:${NC}"
                echo -e "${WHITE}  echo 'your_password' > $PASSWORD_FILE${NC}"
                echo -e "${WHITE}  chmod 600 $PASSWORD_FILE${NC}"
                return 1
            fi
            
            # 检查文件权限
            local file_perms=$(stat -c %a "$PASSWORD_FILE" 2>/dev/null)
            if [[ "$file_perms" != "600" ]]; then
                echo -e "${YELLOW}${ICON_WARNING} 密码文件权限不安全，建议执行: chmod 600 $PASSWORD_FILE${NC}"
            fi
            
            password=$(head -n1 "$PASSWORD_FILE" 2>/dev/null)
            if [[ -z "$password" ]]; then
                echo -e "${RED}${ICON_ERROR} 密码文件为空: $PASSWORD_FILE${NC}"
                return 1
            fi
            ;;
            
        "env")
            password="${!PASSWORD_ENV_VAR}"
            if [[ -z "$password" ]]; then
                echo -e "${RED}${ICON_ERROR} 环境变量 $PASSWORD_ENV_VAR 未设置${NC}"
                echo -e "${YELLOW}请设置环境变量:${NC}"
                echo -e "${WHITE}  export $PASSWORD_ENV_VAR='your_password'${NC}"
                return 1
            fi
            ;;
            
        "interactive")
            echo -e "${CYAN}${ICON_LOCK} 请输入SSH密码:${NC}"
            read -s password
            echo
            if [[ -z "$password" ]]; then
                echo -e "${RED}${ICON_ERROR} 密码不能为空${NC}"
                return 1
            fi
            ;;
            
        "inline")
            if [[ -z "${PASSWORD:-}" ]]; then
                echo -e "${RED}${ICON_ERROR} 配置文件中未设置 PASSWORD 变量${NC}"
                return 1
            fi
            password="$PASSWORD"
            ;;
            
        *)
            echo -e "${RED}${ICON_ERROR} 未知的密码提供方式: $PASSWORD_METHOD${NC}"
            return 1
            ;;
    esac
    
    # 将密码导出到环境变量供sshpass使用
    export SSHPASS="$password"
    return 0
}

# =============================================================================
# 服务器信息解析函数
# =============================================================================

parse_server_info() {
    local server_info="$1"
    local user="$DEFAULT_USER"
    local host=""
    local port="$DEFAULT_PORT"
    
    # 解析 user@host:port 格式
    if [[ "$server_info" =~ ^([^@]+)@(.+)$ ]]; then
        user="${BASH_REMATCH[1]}"
        server_info="${BASH_REMATCH[2]}"
    fi
    
    # 解析 host:port 格式
    if [[ "$server_info" =~ ^(.+):([0-9]+)$ ]]; then
        host="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[2]}"
    else
        host="$server_info"
    fi
    
    echo "$user@$host:$port"
}

# =============================================================================
# 重试和推送核心函数 - 支持密码认证
# =============================================================================

retry_rsync() {
    local server_info=$1
    local src=$2
    local dst=$3
    local attempt=1
    
    # 解析服务器信息
    local parsed_info=$(parse_server_info "$server_info")
    local user=$(echo "$parsed_info" | cut -d@ -f1)
    local host_port=$(echo "$parsed_info" | cut -d@ -f2)
    local host=$(echo "$host_port" | cut -d: -f1)
    local port=$(echo "$host_port" | cut -d: -f2)
    
    local rsync_opts="-az --timeout=$CONNECTION_TIMEOUT"
    [[ "$DELETE_EXTRA" == "true" ]] && rsync_opts="$rsync_opts --delete"
    
    while [[ $attempt -le $MAX_RETRIES ]]; do
        if [[ $attempt -gt 1 ]]; then
            echo -e "${YELLOW}    ${ICON_RETRY} 第${attempt}次重试 (${RETRY_DELAY}s后)...${NC}"
            sleep $RETRY_DELAY
        fi
        
        local ssh_cmd=""
        local rsync_cmd=""
        local output=""
        
        # 根据认证方式构建命令
        if [[ "$AUTH_METHOD" == "key" ]]; then
            ssh_cmd="ssh -i $KEY_FILE -p $port -o ConnectTimeout=$CONNECTION_TIMEOUT -o StrictHostKeyChecking=$STRICT_HOST_KEY_CHECKING -o UserKnownHostsFile=$USER_KNOWN_HOSTS_FILE -o LogLevel=ERROR"
            rsync_cmd="timeout $TOTAL_TIMEOUT rsync $rsync_opts -e \"$ssh_cmd\" \"$src\" \"$user@$host:$dst\""
        else
            ssh_cmd="sshpass -e ssh -p $port -o ConnectTimeout=$CONNECTION_TIMEOUT -o StrictHostKeyChecking=$STRICT_HOST_KEY_CHECKING -o UserKnownHostsFile=$USER_KNOWN_HOSTS_FILE -o LogLevel=ERROR -o PreferredAuthentications=password"
            rsync_cmd="timeout $TOTAL_TIMEOUT rsync $rsync_opts -e \"$ssh_cmd\" \"$src\" \"$user@$host:$dst\""
        fi
        
        # 执行rsync命令
        output=$(eval "$rsync_cmd" 2>&1)
        local exit_code=$?
        
        case $exit_code in
            0)
                return 0  # 成功
                ;;
            124)
                if [[ $attempt -eq $MAX_RETRIES ]]; then
                    echo -e "${RED}    ${ICON_TIMEOUT} 连接超时，已达到最大重试次数${NC}"
                fi
                ;;
            255)
                if [[ $attempt -eq $MAX_RETRIES ]]; then
                    echo -e "${RED}    ${ICON_ERROR} SSH连接失败，已达到最大重试次数${NC}"
                    if [[ "$output" =~ "Permission denied" ]]; then
                        echo -e "${RED}    可能的原因: 认证失败 (密码错误或密钥问题)${NC}"
                    fi
                fi
                ;;
            *)
                if [[ $attempt -eq $MAX_RETRIES ]]; then
                    echo -e "${RED}    ${ICON_ERROR} 推送失败 (退出码: $exit_code)${NC}"
                    if [[ -n "$output" ]]; then
                        echo -e "${RED}    错误详情: $output${NC}"
                    fi
                fi
                ;;
        esac
        
        ((attempt++))
    done
    
    return 1  # 失败
}

push_to_server() {
    local server_info=$1
    local src=$2 
    local dst=$3
    local index=$4
    local total=$5
    
    # 解析服务器信息用于显示
    local parsed_info=$(parse_server_info "$server_info")
    local user=$(echo "$parsed_info" | cut -d@ -f1)
    local host_port=$(echo "$parsed_info" | cut -d@ -f2)
    local display_info="$user@$host_port"
    
    echo -e "${BLUE}[${index}/${total}]${NC} ${ICON_WORKING} ${CYAN}$display_info${NC}"
    
    if retry_rsync "$server_info" "$src" "$dst"; then
        echo -e "${GREEN}[${index}/${total}]${NC} ${ICON_SUCCESS} ${GREEN}$display_info${NC} ${WHITE}推送成功${NC}"
        # 记录成功结果到文件 - 使用文件锁避免并发写入问题
        (
            flock -x 200
            echo "$server_info" >> "$SUCCESS_FILE"
        ) 200>"$SUCCESS_FILE.lock"
    else
        echo -e "${RED}[${index}/${total}]${NC} ${ICON_ERROR} ${RED}$display_info${NC} ${WHITE}推送失败 (已重试${MAX_RETRIES}次)${NC}"
        # 记录失败结果到文件 - 使用文件锁避免并发写入问题
        (
            flock -x 201
            echo "$server_info" >> "$FAILED_FILE"
        ) 201>"$FAILED_FILE.lock"
    fi
}

# =============================================================================
# 信号处理函数 - 修复版，包含临时文件清理
# =============================================================================

cleanup() {
    echo ""
    echo -e "${YELLOW}${ICON_STOP} 检测到中断信号，正在清理...${NC}"
    
    # 杀死所有后台进程
    for pid in "${RUNNING_PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            echo -e "${YELLOW}终止进程 $pid${NC}"
            kill -TERM "$pid" 2>/dev/null
        fi
    done
    
    # 等待进程结束
    sleep 2
    
    # 强制杀死仍在运行的进程
    for pid in "${RUNNING_PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            echo -e "${RED}强制终止进程 $pid${NC}"
            kill -KILL "$pid" 2>/dev/null
        fi
    done
    
    # 清理临时文件和环境变量
    [[ -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
    unset SSHPASS
    
    echo -e "${RED}${ICON_STOP} 推送已被用户中断${NC}"
    exit 1
}

# 注册信号处理
trap cleanup SIGINT SIGTERM

# =============================================================================
# 配置检查和验证函数 - 增强版
# =============================================================================

check_and_generate_config() {
    local config_file=${1:-"config.conf"}
    
    if [[ ! -f "$config_file" ]]; then
        echo -e "${CYAN}${ICON_INFO} 欢迎使用 ${WHITE}$SCRIPT_NAME v$SCRIPT_VERSION${NC}"
        echo ""
        echo -e "${YELLOW}${ICON_WARNING} 未找到配置文件，正在生成默认配置...${NC}"
        echo ""
        
        generate_config "$config_file"
        
        echo ""
        echo -e "${RED}${ICON_CONFIG} 重要提示：${NC}"
        echo -e "${WHITE}  1. 请编辑配置文件: ${CYAN}$config_file${NC}"
        echo -e "${WHITE}  2. 必须修改以下配置项：${NC}"
        echo -e "${YELLOW}     • AUTH_METHOD${NC}  - 认证方式 (key/password)"
        echo -e "${YELLOW}     • SERVERS${NC}      - 服务器列表"
        echo -e "${YELLOW}     • 认证相关配置${NC}  - 根据选择的认证方式配置"
        echo ""
        echo -e "${WHITE}  3. 认证方式说明：${NC}"
        echo -e "${CYAN}     密钥认证 (推荐)：${NC}"
        echo -e "${WHITE}       - 设置 AUTH_METHOD=\"key\"${NC}"
        echo -e "${WHITE}       - 配置 KEY_FILE 路径${NC}"
        echo -e "${CYAN}     密码认证：${NC}"
        echo -e "${WHITE}       - 设置 AUTH_METHOD=\"password\"${NC}"
        echo -e "${WHITE}       - 安装 sshpass 工具${NC}"
        echo -e "${WHITE}       - 配置密码提供方式${NC}"
        echo ""
        echo -e "${WHITE}  4. 配置完成后重新运行脚本${NC}"
        echo ""
        echo -e "${CYAN}${ICON_INFO} 快速开始：${NC}"
        echo -e "${WHITE}     vim $config_file${NC}"
        echo -e "${WHITE}     ./push.sh -h${NC}"
        echo ""
        
        # 清理临时文件并退出
        [[ -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
        exit 0
    fi
}

validate_config() {
    local errors=0
    
    # 检查认证方式
    if [[ "$AUTH_METHOD" != "key" && "$AUTH_METHOD" != "password" ]]; then
        echo -e "${RED}${ICON_ERROR} 无效的认证方式: $AUTH_METHOD (应该是 'key' 或 'password')${NC}"
        ((errors++))
    fi
    
    # 检查密钥认证配置
    if [[ "$AUTH_METHOD" == "key" ]]; then
        if [[ ! -f "$KEY_FILE" ]]; then
            echo -e "${RED}${ICON_ERROR} SSH私钥文件不存在: $KEY_FILE${NC}"
            ((errors++))
        elif [[ $(stat -c %a "$KEY_FILE" 2>/dev/null) != "600" ]]; then
            echo -e "${YELLOW}${ICON_WARNING} SSH私钥文件权限不安全，建议执行: chmod 600 $KEY_FILE${NC}"
        fi
    fi
    
    # 检查密码认证配置
    if [[ "$AUTH_METHOD" == "password" ]]; then
        if ! command -v sshpass &> /dev/null; then
            echo -e "${RED}${ICON_ERROR} 密码认证需要安装 sshpass 工具${NC}"
            ((errors++))
        fi
        
        case "$PASSWORD_METHOD" in
            "file")
                if [[ ! -f "$PASSWORD_FILE" ]]; then
                    echo -e "${RED}${ICON_ERROR} 密码文件不存在: $PASSWORD_FILE${NC}"
                    ((errors++))
                fi
                ;;
            "env")
                if [[ -z "${!PASSWORD_ENV_VAR:-}" ]]; then
                    echo -e "${YELLOW}${ICON_WARNING} 环境变量 $PASSWORD_ENV_VAR 未设置${NC}"
                fi
                ;;
            "inline")
                if [[ -z "${PASSWORD:-}" ]]; then
                    echo -e "${RED}${ICON_ERROR} 配置文件中未设置 PASSWORD 变量${NC}"
                    ((errors++))
                fi
                ;;
            "interactive")
                # 交互式输入无需预先验证
                ;;
            *)
                echo -e "${RED}${ICON_ERROR} 无效的密码方式: $PASSWORD_METHOD${NC}"
                ((errors++))
                ;;
        esac
    fi
    
    # 检查服务器列表
    if [[ ${#SERVERS[@]} -eq 0 ]]; then
        echo -e "${RED}${ICON_ERROR} 未配置任何服务器${NC}"
        ((errors++))
    fi
    
    # 检查示例配置是否还在使用
    if [[ " ${SERVERS[*]} " =~ " 192.168.1.100 " ]] || [[ " ${SERVERS[*]} " =~ " root@server1.example.com:22 " ]]; then
        echo -e "${YELLOW}${ICON_WARNING} 检测到示例服务器配置，请替换为实际服务器${NC}"
    fi
    
    if [[ $errors -gt 0 ]]; then
        echo -e "${RED}${ICON_ERROR} 配置验证失败，请检查配置文件: config.conf${NC}"
        # 清理临时文件并退出
        [[ -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
        exit 1
    fi
}

# =============================================================================
# 结果统计和交互重试 - 修复版
# =============================================================================

show_summary() {
    local total=${#SERVERS[@]}
    local success=0
    local failed=0
    
    # 从文件读取结果统计 - 修复并发统计问题
    [[ -f "$SUCCESS_FILE" ]] && success=$(wc -l < "$SUCCESS_FILE" 2>/dev/null || echo 0)
    [[ -f "$FAILED_FILE" ]] && failed=$(wc -l < "$FAILED_FILE" 2>/dev/null || echo 0)
    
    echo ""
    echo -e "${WHITE}📊 推送结果统计：${NC}"
    echo -e "${GREEN}  ✅ 成功: $success/$total${NC}"
    echo -e "${RED}  ❌ 失败: $failed/$total${NC}"
    
    if [[ $failed -gt 0 && -f "$FAILED_FILE" ]]; then
        echo ""
        echo -e "${RED}${ICON_WARNING}失败的服务器：${NC}"
        while IFS= read -r server; do
            [[ -n "$server" ]] && echo -e "${RED}  • $(parse_server_info "$server")${NC}"
        done < "$FAILED_FILE"
    fi
}

interactive_retry() {
    local failed=0
    [[ -f "$FAILED_FILE" ]] && failed=$(wc -l < "$FAILED_FILE" 2>/dev/null || echo 0)
    
    if [[ $failed -eq 0 ]]; then
        return
    fi
    
    echo ""
    echo -e "${YELLOW}${ICON_RETRY} 检测到 $failed 台服务器推送失败${NC}"
    echo -e "${CYAN}是否要重新尝试推送失败的服务器？ [y/N]${NC}"
    
    read -r -t 30 response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}跳过重试${NC}"
        return
    fi
    
    echo ""
    echo -e "${YELLOW}重新推送失败的服务器...${NC}"
    echo ""
    
    # 备份失败列表，然后清空文件准备重试
    local retry_file="$TEMP_DIR/retry_list"
    cp "$FAILED_FILE" "$retry_file"
    > "$FAILED_FILE"  # 清空失败文件
    [[ -f "$FAILED_FILE.lock" ]] && rm -f "$FAILED_FILE.lock"
    
    local index=0
    local total_retry
    total_retry=$(wc -l < "$retry_file" 2>/dev/null || echo 0)
    
    # 清空当前进程ID数组
    RUNNING_PIDS=()
    
    while IFS= read -r server; do
        [[ -n "$server" ]] || continue
        ((index++))
        push_to_server "$server" "$SRC_PATH" "$DST_PATH" "$index" "$total_retry" &
        RUNNING_PIDS+=($!)
        (($(jobs -r | wc -l) >= MAX_PARALLEL)) && wait
    done < "$retry_file"
    
    wait
    show_summary
    
    # 检查是否还有失败，决定是否继续重试
    local new_failed=0
    [[ -f "$FAILED_FILE" ]] && new_failed=$(wc -l < "$FAILED_FILE" 2>/dev/null || echo 0)
    
    if [[ $new_failed -gt 0 && $new_failed -lt $failed ]]; then
        interactive_retry
    fi
}

# =============================================================================
# 帮助系统 - 增强版
# =============================================================================

show_help() {
    echo -e "${CYAN}${ICON_INFO} $SCRIPT_NAME v$SCRIPT_VERSION${NC}"
    echo ""
    echo -e "${WHITE}用法: $0 <任务名|自定义路径>${NC}"
    echo ""
    
    # 显示当前认证方式
    local auth_icon="${ICON_KEY}"
    local auth_desc="SSH密钥认证"
    if [[ "$AUTH_METHOD" == "password" ]]; then
        auth_icon="${ICON_LOCK}"
        auth_desc="SSH密码认证"
    fi
    echo -e "${YELLOW}🔐 当前认证方式：${NC} $auth_icon $auth_desc"
    echo ""
    
    if [[ ${#TASKS[@]} -gt 0 ]]; then
        echo -e "${YELLOW}📋 预定义任务：${NC}"
        for task in "${!TASKS[@]}"; do
            IFS=':' read -r src dst <<< "${TASKS[$task]}"
            echo -e "  ${GREEN}$task${NC}: ${BLUE}$src${NC} -> ${PURPLE}$dst${NC}"
        done
        echo ""
    fi
    
    echo -e "${YELLOW}🛠️  使用方式:${NC}"
    echo -e "  ${WHITE}$0 <任务名>${NC}                    # 执行预定义任务"
    echo -e "  ${WHITE}$0 <源路径> <目标路径>${NC}          # 自定义路径推送"
    echo -e "  ${WHITE}$0 -h, --help${NC}                 # 显示帮助信息"
    echo -e "  ${WHITE}$0 --generate-config${NC}          # 生成新的配置文件"
    echo -e "  ${WHITE}$0 --test-auth${NC}                # 测试认证配置"
    echo ""
    echo -e "${YELLOW}📝 例子:${NC}"
    echo -e "  ${WHITE}$0 nginx${NC}                       # 推送nginx配置"
    echo -e "  ${WHITE}$0 /local/file /remote/path/${NC}   # 自定义推送"
    echo ""
    echo -e "${CYAN}⚙️  当前配置:${NC}"
    echo -e "  ${WHITE}服务器数量:${NC} ${CYAN}${#SERVERS[@]}${NC}"
    echo -e "  ${WHITE}认证方式:${NC} ${CYAN}$AUTH_METHOD${NC}"
    if [[ "$AUTH_METHOD" == "password" ]]; then
        echo -e "  ${WHITE}密码方式:${NC} ${CYAN}$PASSWORD_METHOD${NC}"
    fi
    echo -e "  ${WHITE}重试设置:${NC} ${CYAN}最多${MAX_RETRIES}次，间隔${RETRY_DELAY}s${NC}"
    echo -e "  ${WHITE}超时设置:${NC} ${CYAN}连接${CONNECTION_TIMEOUT}s，传输${TOTAL_TIMEOUT}s${NC}"
    echo -e "  ${WHITE}并发数:${NC} ${CYAN}${MAX_PARALLEL}${NC}"
    echo ""
    echo -e "${YELLOW}💡 认证配置提示：${NC}"
    if [[ "$AUTH_METHOD" == "key" ]]; then
        echo -e "  ${WHITE}• 密钥文件：${NC} ${CYAN}$KEY_FILE${NC}"
        echo -e "  ${WHITE}• 确保密钥权限：${NC} chmod 600 $KEY_FILE"
    else
        echo -e "  ${WHITE}• 密码方式：${NC} ${CYAN}$PASSWORD_METHOD${NC}"
        if [[ "$PASSWORD_METHOD" == "file" ]]; then
            echo -e "  ${WHITE}• 密码文件：${NC} ${CYAN}$PASSWORD_FILE${NC}"
        fi
    fi
}

# =============================================================================
# 认证测试函数
# =============================================================================

test_authentication() {
    echo -e "${CYAN}${ICON_CONFIG} 测试认证配置...${NC}"
    echo ""
    
    # 检查依赖
    check_dependencies
    
    # 检查认证配置
    if [[ "$AUTH_METHOD" == "password" ]]; then
        echo -e "${YELLOW}${ICON_LOCK} 密码认证测试${NC}"
        if get_password; then
            echo -e "${GREEN}${ICON_SUCCESS} 密码获取成功${NC}"
        else
            echo -e "${RED}${ICON_ERROR} 密码获取失败${NC}"
            [[ -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
            exit 1
        fi
    else
        echo -e "${YELLOW}${ICON_KEY} 密钥认证测试${NC}"
        if [[ -f "$KEY_FILE" ]]; then
            echo -e "${GREEN}${ICON_SUCCESS} 密钥文件存在: $KEY_FILE${NC}"
            local perms=$(stat -c %a "$KEY_FILE" 2>/dev/null)
            if [[ "$perms" == "600" ]]; then
                echo -e "${GREEN}${ICON_SUCCESS} 密钥文件权限正确${NC}"
            else
                echo -e "${YELLOW}${ICON_WARNING} 密钥文件权限: $perms (建议: 600)${NC}"
            fi
        else
            echo -e "${RED}${ICON_ERROR} 密钥文件不存在: $KEY_FILE${NC}"
            [[ -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
            exit 1
        fi
    fi
    
    echo ""
    echo -e "${GREEN}${ICON_SUCCESS} 认证配置测试完成${NC}"
    
    # 清理临时文件
    [[ -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
    unset SSHPASS
    exit 0
}

# =============================================================================
# 最终清理函数
# =============================================================================

finish_cleanup() {
    # 检查最终结果
    local total=${#SERVERS[@]}
    local failed=0
    [[ -f "$FAILED_FILE" ]] && failed=$(wc -l < "$FAILED_FILE" 2>/dev/null || echo 0)
    
    if [[ $failed -eq 0 ]]; then
        echo ""
        echo -e "${GREEN}${ICON_SUCCESS} ${WHITE}所有服务器推送成功！${NC}"
    else
        echo ""
        echo -e "${YELLOW}${ICON_WARNING} ${WHITE}部分服务器推送失败，请检查网络连接和服务器配置${NC}"
    fi
    
    # 清理临时文件和环境变量
    [[ -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
    unset SSHPASS
    
    # 清空进程数组
    RUNNING_PIDS=()
}

# =============================================================================
# 主程序入口
# =============================================================================

# 处理特殊参数
case "${1:-}" in
    "--generate-config")
        echo -e "${CYAN}${ICON_CONFIG} 生成新的配置文件...${NC}"
        generate_config "config.conf"
        echo -e "${YELLOW}请编辑 config.conf 文件后重新运行脚本${NC}"
        # 清理临时文件并退出
        [[ -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
        exit 0
        ;;
    "--test-auth")
        # 先检查配置文件，如果不存在则生成
        check_and_generate_config
        source config.conf
        validate_config
        test_authentication
        ;;
    "-h"|"--help")
        # 先检查配置文件，如果不存在则生成
        check_and_generate_config
        source config.conf
        show_help
        # 清理临时文件并退出
        [[ -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
        exit 0
        ;;
    *)
        # 正常运行流程
        check_and_generate_config
        source config.conf
        validate_config
        check_dependencies
        ;;
esac

# =============================================================================
# 密码认证准备
# =============================================================================

if [[ "$AUTH_METHOD" == "password" ]]; then
    if ! get_password; then
        echo -e "${RED}${ICON_ERROR} 密码认证初始化失败${NC}"
        finish_cleanup
        exit 1
    fi
fi

# =============================================================================
# 主程序执行逻辑
# =============================================================================

# 参数解析
if [[ $# -eq 1 ]]; then
    TASK_NAME=$1
    if [[ -n "${TASKS[$TASK_NAME]}" ]]; then
        IFS=':' read -r SRC_PATH DST_PATH <<< "${TASKS[$TASK_NAME]}"
        echo -e "${ICON_ROCKET} ${YELLOW}执行预定义任务:${NC} ${GREEN}$TASK_NAME${NC}"
    else
        echo -e "${RED}${ICON_ERROR} 未找到任务 '$TASK_NAME'${NC}"
        echo ""
        echo -e "${CYAN}${ICON_INFO} 可用的预定义任务：${NC}"
        if [[ ${#TASKS[@]} -gt 0 ]]; then
            for task in "${!TASKS[@]}"; do
                echo -e "  ${GREEN}$task${NC}"
            done
        else
            echo -e "  ${YELLOW}(无预定义任务，请配置 config.conf)${NC}"
        fi
        echo ""
        echo -e "${WHITE}使用 '$0 -h' 查看完整帮助${NC}"
        finish_cleanup
        exit 1
    fi
elif [[ $# -eq 2 ]]; then
    SRC_PATH=$1
    DST_PATH=$2
    echo -e "${ICON_ROCKET} ${YELLOW}执行自定义推送${NC}"
else
    show_help
    finish_cleanup
    exit 1
fi

# 检查源路径
if [[ ! -e "$SRC_PATH" ]]; then
    echo -e "${RED}${ICON_ERROR} 源路径不存在: $SRC_PATH${NC}"
    finish_cleanup
    exit 1
fi

# 显示推送信息
echo -e "${WHITE}📂 源路径:${NC} ${BLUE}$SRC_PATH${NC}"
echo -e "${WHITE}📍 目标路径:${NC} ${PURPLE}$DST_PATH${NC}"
echo -e "${WHITE}🖥️  服务器数量:${NC} ${CYAN}${#SERVERS[@]}${NC}"

# 显示认证方式
if [[ "$AUTH_METHOD" == "key" ]]; then
    echo -e "${WHITE}🔐 认证方式:${NC} ${CYAN}SSH密钥${NC} (${KEY_FILE})"
else
    echo -e "${WHITE}🔐 认证方式:${NC} ${CYAN}SSH密码${NC} (${PASSWORD_METHOD})"
fi

echo -e "${WHITE}🔄 重试设置:${NC} ${CYAN}最多${MAX_RETRIES}次，间隔${RETRY_DELAY}s${NC}"
echo -e "${WHITE}⏰ 超时设置:${NC} ${CYAN}${CONNECTION_TIMEOUT}s/${TOTAL_TIMEOUT}s${NC}"
echo -e "${WHITE}⚡ 并发数:${NC} ${CYAN}${MAX_PARALLEL}${NC}"
echo -e "${WHITE}🔄 完全覆盖:${NC} ${YELLOW}$DELETE_EXTRA${NC}"

# 显示源路径类型和大小信息
if [[ -f "$SRC_PATH" ]]; then
    local file_size=$(du -h "$SRC_PATH" | cut -f1)
    echo -e "${WHITE}📄 文件大小:${NC} ${CYAN}$file_size${NC}"
elif [[ -d "$SRC_PATH" ]]; then
    local dir_size=$(du -sh "$SRC_PATH" 2>/dev/null | cut -f1)
    local file_count=$(find "$SRC_PATH" -type f | wc -l)
    echo -e "${WHITE}📁 目录大小:${NC} ${CYAN}$dir_size${NC}"
    echo -e "${WHITE}📄 文件数量:${NC} ${CYAN}$file_count${NC}"
fi

echo ""
echo -e "${YELLOW}开始推送... (按 Ctrl+C 可安全中断)${NC}"
echo ""

# 初始化结果文件
> "$SUCCESS_FILE"
> "$FAILED_FILE"

# 执行推送
TOTAL_SERVERS=${#SERVERS[@]}
CURRENT_INDEX=0

# 记录开始时间
START_TIME=$(date +%s)

for server in "${SERVERS[@]}"; do
    ((CURRENT_INDEX++))
    push_to_server "$server" "$SRC_PATH" "$DST_PATH" "$CURRENT_INDEX" "$TOTAL_SERVERS" &
    RUNNING_PIDS+=($!)
    
    # 控制并发数
    (($(jobs -r | wc -l) >= MAX_PARALLEL)) && wait
done

# 等待所有后台任务完成
wait

# 计算总耗时
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

# 格式化耗时显示
if [[ $DURATION -ge 60 ]]; then
    DURATION_STR="${DURATION}s ($(($DURATION/60))m$(($DURATION%60))s)"
else
    DURATION_STR="${DURATION}s"
fi

echo ""
echo -e "${CYAN}⏱️  总耗时: ${WHITE}$DURATION_STR${NC}"

# 显示结果和交互式重试
show_summary
interactive_retry

# 最终结果展示
echo ""
echo -e "${CYAN}═══════════════════════════════════════${NC}"

final_success=0
final_failed=0
[[ -f "$SUCCESS_FILE" ]] && final_success=$(wc -l < "$SUCCESS_FILE" 2>/dev/null || echo 0)
[[ -f "$FAILED_FILE" ]] && final_failed=$(wc -l < "$FAILED_FILE" 2>/dev/null || echo 0)

if [[ $final_failed -eq 0 ]]; then
    echo -e "${GREEN}${ICON_SUCCESS} ${WHITE}推送任务完成！所有 $final_success 台服务器推送成功${NC}"
else
    echo -e "${YELLOW}${ICON_WARNING} ${WHITE}推送任务完成！$final_success 台成功，$final_failed 台失败${NC}"
    
    # 提供失败服务器的快速重试建议
    if [[ $final_failed -gt 0 ]]; then
        echo ""
        echo -e "${CYAN}💡 建议：${NC}"
        echo -e "${WHITE}• 检查失败服务器的网络连接${NC}"
        if [[ "$AUTH_METHOD" == "key" ]]; then
            echo -e "${WHITE}• 验证SSH密钥和权限设置${NC}"
        else
            echo -e "${WHITE}• 验证SSH密码和用户权限${NC}"
        fi
        echo -e "${WHITE}• 可以稍后重新运行相同命令进行重试${NC}"
        echo -e "${WHITE}• 使用 '$0 --test-auth' 测试认证配置${NC}"
    fi
fi

echo -e "${CYAN}═══════════════════════════════════════${NC}"

# 执行最终清理
finish_cleanup

# 根据结果设置退出码
if [[ $final_failed -gt 0 ]]; then
    exit 1
else
    exit 0
fi
