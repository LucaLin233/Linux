#!/usr/bin/env bash

# =============================================================================
# Server File Push Tool v1.4.0
# 多服务器文件推送工具：安全配置加载、凭据快照、主机指纹验证和进程树清理。
# =============================================================================

SCRIPT_VERSION="1.4.0"
SCRIPT_NAME="Server File Push Tool"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'
WHITE='\033[1;37m'; NC='\033[0m'

ICON_SUCCESS="✅"; ICON_ERROR="❌"; ICON_WORKING="⚡"; ICON_INFO="ℹ️ "
ICON_STOP="🛑"
ICON_WARNING="⚠️ "; ICON_CONFIG="⚙️ "; ICON_LOCK="🔒"

CONNECTION_TIMEOUT=30
TOTAL_TIMEOUT=300
TIMEOUT_KILL_AFTER=2
MAX_RETRIES=3
RETRY_DELAY=5

TEMP_DIR=""
SUCCESS_FILE=""
FAILED_FILE=""
SSH_WRAPPER=""
RUNTIME_KEY_FILE=""
TEMP_DIR_DEV=""
TEMP_DIR_INODE=""
RUNTIME_STATE="none"
RUNTIME_PARENT=""
RUNTIME_PARENT_DEV=""
RUNTIME_PARENT_INODE=""
RUNTIME_INITIALIZED=false
RUNTIME_CLEANUP_ACTIVE=false
RUNTIME_TRAPS_INSTALLED=false
RUNTIME_ALLOCATION_CRITICAL=false
RUNTIME_PENDING_SIGNAL=""
RUNTIME_PENDING_SIGNAL_STATUS=0
RUNTIME_ALLOCATOR_PID=""
RUNTIME_ALLOCATOR_START=""
RUNTIME_CANDIDATE_CREATED=false

PARSED_PORT=""
PARSED_SSH_TARGET=""
PARSED_RSYNC_TARGET=""
PARSED_DISPLAY_TARGET=""
PROC_STATE=""
PROC_PPID=""
PROC_PGID=""
PROC_SID=""
PROC_START=""
PROC_UID=""

WORKER_TRANSFER_PID=""
WORKER_TRANSFER_PGID=""
WORKER_TRANSFER_SID=""
WORKER_TRANSFER_START=""
WORKER_TRANSFER_CLEANUP_FAILED=false
WORKER_SIGNAL_CLEANUP_ACTIVE=false
WORKER_SESSION_STATE_FILE=""
WORKER_SESSION_STATE_TRANSIENT_STATUS=75
WORKER_SESSION_STATE_READ_ATTEMPTS=5
WORKER_SESSION_PATH_DEV=""
WORKER_SESSION_PATH_INODE=""
WORKER_SESSION_PATH_OWNER=""
WORKER_SESSION_PATH_GID=""
WORKER_SESSION_PATH_MODE=""
WORKER_SESSION_PATH_SIZE=""
WORKER_SESSION_FD_DEV=""
WORKER_SESSION_FD_INODE=""
WORKER_SESSION_FD_OWNER=""
WORKER_SESSION_FD_GID=""
WORKER_SESSION_FD_MODE=""
WORKER_SESSION_FD_SIZE=""
SESSION_FILE_DEV=""
SESSION_FILE_INODE=""
WORKER_OUTPUT_FILE=""

declare -a SERVERS=()
declare -A TASKS=()
declare -A ACTIVE_WORKERS=()
declare -A ACTIVE_WORKER_STATE_FILES=()
declare -A ACTIVE_WORKER_STATE_STARTS=()
declare -A REGISTERING_WORKERS=()
declare -A WORKER_REGISTRATION_READY_FILES=()
declare -A WORKER_REGISTRATION_RELEASE_FILES=()
declare -A WORKER_REGISTRATION_STARTS=()
declare -A WORKER_REGISTRATION_STAGE_FILES=()
WORKER_REGISTRATION_READY_FILE=""
WORKER_REGISTRATION_RELEASE_FILE=""
WORKER_REGISTRATION_STAGE_FILE=""
WORKER_REGISTRATION_READY_DEV=""
WORKER_REGISTRATION_READY_INODE=""
WORKER_REGISTRATION_TIMEOUT_TICKS=100
WORKER_REGISTRATION_CRITICAL=false
WORKER_REGISTRATION_PENDING_SIGNAL=""
WORKER_REGISTRATION_PENDING_STATUS=0
BATCH_WORKER_FAILED=false
BATCH_WORKER_ERROR=false
MANAGED_CLEANUP_FAILURE_STATUS=125
MANAGED_PROCESS_REUSED_STATUS=3
RUNTIME_ALLOCATOR_COLLISION_STATUS=17
declare -a CONFIG_SERVERS_BUFFER=()
declare -A CONFIG_TASKS_BUFFER=()

log() {
    local level="$1" message="$2"
    [[ "${ENABLE_LOGGING:-false}" == true ]] || return 0
    local log_file="${LOG_FILE:-/var/log/push.log}"
    local log_dir=""
    log_dir=$(dirname -- "$log_file") || return 1
    [[ -d "$log_dir" && ! -L "$log_dir" ]] || return 1
    printf '[%s] [%-7s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$message" >> "$log_file"
}

current_gid() {
    id -g
}

contains_control_character() {
    [[ "$1" =~ [[:cntrl:]] ]]
}

secure_fd_open_hook() {
    :
}

fd_reference_path() {
    local fd="$1"
    if [[ -e "/proc/self/fd/$fd" ]]; then
        printf '/proc/self/fd/%s\n' "$fd"
    elif [[ -e "/dev/fd/$fd" ]]; then
        printf '/dev/fd/%s\n' "$fd"
    else
        return 1
    fi
}

validate_opened_file_metadata() {
    local purpose="$1" owner="$2" gid="$3" mode="$4"
    local trusted_gid="" mode_value=0

    trusted_gid=$(current_gid) || return 1
    [[ "$owner" == "$EUID" && "$gid" == "$trusted_gid" ]] || {
        echo -e "${RED}${ICON_ERROR} $purpose owner 或 GID 不可信${NC}" >&2
        return 1
    }
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    mode_value=$((8#$mode))
    (( (mode_value & 0400) != 0 )) || {
        echo -e "${RED}${ICON_ERROR} $purpose 对当前 owner 不可读${NC}" >&2
        return 1
    }

    case "$purpose" in
        config)
            [[ "$mode" == 400 || "$mode" == 600 ]] || {
                echo -e "${RED}${ICON_ERROR} 配置文件权限必须是 0400 或 0600${NC}" >&2
                return 1
            }
            ;;
        private-key)
            [[ "$mode" == 400 || "$mode" == 600 ]] || {
                echo -e "${RED}${ICON_ERROR} 私钥权限必须是 0400 或 0600${NC}" >&2
                return 1
            }
            ;;
        password-file)
            [[ "$mode" == 600 ]] || {
                echo -e "${RED}${ICON_ERROR} 密码文件权限必须是 0600${NC}" >&2
                return 1
            }
            ;;
        *) return 1 ;;
    esac
}

open_trusted_file() {
    local path="$1" purpose="$2" fd_variable="$3"
    local before="" after="" fd_path=""
    local before_dev before_inode before_owner before_gid before_mode
    local after_dev after_inode after_owner after_gid after_mode
    local opened_fd

    contains_control_character "$path" && return 1
    [[ -e "$path" || -L "$path" ]] || {
        echo -e "${RED}${ICON_ERROR} $purpose 不存在: $path${NC}" >&2
        return 1
    }
    [[ ! -L "$path" && -f "$path" ]] || {
        echo -e "${RED}${ICON_ERROR} $purpose 必须是非符号链接普通文件: $path${NC}" >&2
        return 1
    }
    before=$(stat -Lc '%d:%i:%u:%g:%a' -- "$path" 2>/dev/null) || return 1
    IFS=: read -r before_dev before_inode before_owner before_gid before_mode <<< "$before"
    validate_opened_file_metadata "$purpose" "$before_owner" "$before_gid" "$before_mode" || return 1

    if ! exec {opened_fd}<"$path"; then
        echo -e "${RED}${ICON_ERROR} 无法打开 $purpose: $path${NC}" >&2
        return 1
    fi
    fd_path=$(fd_reference_path "$opened_fd") || {
        exec {opened_fd}<&-
        return 1
    }
    [[ -f "$fd_path" ]] || {
        exec {opened_fd}<&-
        return 1
    }
    after=$(stat -Lc '%d:%i:%u:%g:%a' -- "$fd_path" 2>/dev/null) || {
        exec {opened_fd}<&-
        return 1
    }
    IFS=: read -r after_dev after_inode after_owner after_gid after_mode <<< "$after"
    if [[ "$before_dev:$before_inode" != "$after_dev:$after_inode" ]]; then
        echo -e "${RED}${ICON_ERROR} $purpose 在检查和打开之间发生替换: $path${NC}" >&2
        exec {opened_fd}<&-
        return 1
    fi
    validate_opened_file_metadata "$purpose" "$after_owner" "$after_gid" "$after_mode" || {
        exec {opened_fd}<&-
        return 1
    }
    if ! secure_fd_open_hook "$purpose" "$path" "$opened_fd"; then
        exec {opened_fd}<&-
        return 1
    fi
    printf -v "$fd_variable" '%s' "$opened_fd"
}

source_config_fd() {
    local config_fd_path="$1" source_status=0 key
    local -a SERVERS=()
    local -A TASKS=()

    # config.conf 是通过已验证 fd 加载的受信任 Bash 配置。
    # shellcheck source=/dev/null
    source "$config_fd_path" || source_status=$?
    CONFIG_SERVERS_BUFFER=("${SERVERS[@]}")
    CONFIG_TASKS_BUFFER=()
    for key in "${!TASKS[@]}"; do
        CONFIG_TASKS_BUFFER["$key"]="${TASKS[$key]}"
    done
    return "$source_status"
}

load_config() {
    local config_file="$1" config_fd="" config_fd_path="" source_status=0 key

    open_trusted_file "$config_file" config config_fd || return 1
    config_fd_path=$(fd_reference_path "$config_fd") || {
        exec {config_fd}<&-
        return 1
    }
    source_config_fd "$config_fd_path" || source_status=$?
    exec {config_fd}<&-
    (( source_status == 0 )) || return "$source_status"

    SERVERS=("${CONFIG_SERVERS_BUFFER[@]}")
    TASKS=()
    for key in "${!CONFIG_TASKS_BUFFER[@]}"; do
        TASKS["$key"]="${CONFIG_TASKS_BUFFER[$key]}"
    done
    CONFIG_SERVERS_BUFFER=()
    CONFIG_TASKS_BUFFER=()
}


config_template() {
    cat <<'EOF'
# =============================================================================
# Server File Push Tool - 配置文件 v1.4.0
# =============================================================================

AUTH_METHOD="key"                 # "key" | "password"
KEY_FILE="/root/.ssh/id_rsa"      # 必须为当前用户所有，mode 0400 或 0600

PASSWORD_METHOD="file"            # "file" | "env" | "interactive" | "inline"
PASSWORD_FILE="/root/.ssh/password.txt" # 必须为当前用户所有，mode 0600
PASSWORD_ENV_VAR="SSHPASS"
# PASSWORD="your_password"        # inline 不推荐

DEFAULT_PORT=22
DEFAULT_USER="root"
MAX_PARALLEL=15
CONNECTION_TIMEOUT=30
TOTAL_TIMEOUT=300
MAX_RETRIES=3
RETRY_DELAY=5

DELETE_EXTRA="false"
ALLOW_DELETE_EXTRA="false"
RSYNC_ARCHIVE="true"
RSYNC_COMPRESS="true"

SERVERS=(
    "192.168.1.100"
    "admin@192.168.1.101:2222"
    "root@server1.example.com:22"
    # "root@[2001:db8::1]:22"
)

declare -A TASKS=(
    ["nginx"]="/etc/nginx/:/etc/nginx/"
    ["web"]="/var/www/html/:/var/www/html/"
    ["config"]="/root/configs/:/root/configs/"
)

ENABLE_LOGGING="false"
LOG_FILE="/var/log/push.log"
STRICT_HOST_KEY_CHECKING="accept-new" # "yes" | "no" | "accept-new"
USER_KNOWN_HOSTS_FILE="${HOME}/.ssh/known_hosts"
ALLOW_INSECURE_HOST_KEY_STORAGE="false"
EOF
}

path_has_symlink_component() {
    local path="$1" current="/" component
    local -a components=()

    [[ "$path" == /* ]] || return 0
    IFS=/ read -r -a components <<< "${path#/}"
    for component in "${components[@]}"; do
        [[ -n "$component" ]] || continue
        if [[ "$current" == / ]]; then
            current="/$component"
        else
            current="$current/$component"
        fi
        [[ -L "$current" ]] && return 0
        [[ -e "$current" ]] || break
    done
    return 1
}

trusted_directory_component() {
    local directory="$1" metadata="" owner gid mode trusted_gid mode_value=0

    [[ -d "$directory" && ! -L "$directory" && -x "$directory" ]] || return 1
    metadata=$(stat -Lc '%u:%g:%a' -- "$directory" 2>/dev/null) || return 1
    IFS=: read -r owner gid mode <<< "$metadata"
    trusted_gid=$(current_gid) || return 1
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    mode_value=$((8#$mode))
    if (( (mode_value & 0022) != 0 )); then
        (( (mode_value & 01000) != 0 )) || return 1
        [[ "$owner" == 0 && "$gid" == 0 ]] || return 1
    else
        [[ ( "$owner" == 0 && "$gid" == 0 ) ||
            ( "$owner" == "$EUID" && "$gid" == "$trusted_gid" ) ]] || return 1
    fi
}

validate_existing_directory_chain() {
    local directory="$1" current="/" component
    local -a components=()

    [[ "$directory" == /* ]] || return 1
    path_has_symlink_component "$directory" && return 1
    trusted_directory_component / || return 1
    IFS=/ read -r -a components <<< "${directory#/}"
    for component in "${components[@]}"; do
        [[ -n "$component" ]] || continue
        if [[ "$current" == / ]]; then
            current="/$component"
        else
            current="$current/$component"
        fi
        [[ -e "$current" ]] || return 1
        trusted_directory_component "$current" || return 1
    done
}

capture_directory_identity() {
    local directory="$1" dev_variable="$2" inode_variable="$3"
    local metadata="" captured_dev captured_inode
    metadata=$(stat -Lc '%d:%i' -- "$directory" 2>/dev/null) || return 1
    IFS=: read -r captured_dev captured_inode <<< "$metadata"
    printf -v "$dev_variable" '%s' "$captured_dev"
    printf -v "$inode_variable" '%s' "$captured_inode"
}

secure_directory_metadata() {
    local directory="$1" metadata="" owner gid mode
    local trusted_gid="" mode_value=0

    [[ -d "$directory" && ! -L "$directory" ]] || return 1
    metadata=$(stat -Lc '%u:%g:%a' -- "$directory" 2>/dev/null) || return 1
    IFS=: read -r owner gid mode <<< "$metadata"
    trusted_gid=$(current_gid) || return 1
    [[ "$owner" == "$EUID" && "$gid" == "$trusted_gid" && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    mode_value=$((8#$mode))
    (( (mode_value & 0700) == 0700 && (mode_value & 0022) == 0 ))
}

generate_config() {
    local config_file=${1:-config.conf}
    local config_dir="" config_name="" stage=""

    contains_control_character "$config_file" && return 1
    if [[ -e "$config_file" || -L "$config_file" ]]; then
        echo -e "${RED}${ICON_ERROR} 配置路径已存在，拒绝覆盖: $config_file${NC}" >&2
        return 1
    fi
    config_dir=$(dirname -- "$config_file") || return 1
    config_name=$(basename -- "$config_file") || return 1
    secure_directory_metadata "$config_dir" || {
        echo -e "${RED}${ICON_ERROR} 配置父目录不可信: $config_dir${NC}" >&2
        return 1
    }
    stage=$(mktemp "$config_dir/.${config_name}.tmp.XXXXXXXXXX") || {
        echo -e "${RED}${ICON_ERROR} 无法创建配置 stage${NC}" >&2
        return 1
    }
    chmod 0600 "$stage" || {
        rm -f -- "$stage"
        return 1
    }
    if ! config_template > "$stage"; then
        rm -f -- "$stage"
        return 1
    fi
    if ! ln -- "$stage" "$config_file"; then
        echo -e "${RED}${ICON_ERROR} 配置路径已被占用，未覆盖: $config_file${NC}" >&2
        rm -f -- "$stage"
        return 1
    fi
    if ! rm -f -- "$stage"; then
        echo -e "${RED}${ICON_ERROR} 配置 stage 残留: $stage${NC}" >&2
        return 1
    fi
    [[ -f "$config_file" && ! -L "$config_file" && "$(stat -Lc %a -- "$config_file")" == 600 ]] || return 1
    echo -e "${GREEN}${ICON_SUCCESS} 配置文件已生成: ${WHITE}$config_file${NC}"
}

check_and_generate_config() {
    local config_file=${1:-config.conf}
    if [[ ! -e "$config_file" && ! -L "$config_file" ]]; then
        echo -e "${CYAN}${ICON_INFO} 未找到配置文件，正在安全生成默认配置。${NC}"
        generate_config "$config_file" || return 1
        echo -e "${YELLOW}${ICON_CONFIG} 请编辑 $config_file 后重新运行脚本${NC}"
        return 2
    fi
}

check_dependencies() {
    local operation="$1" cmd
    local -a required=(ssh timeout stat dirname basename mkdir chmod mktemp ln rm cat id setsid awk od tr wc sleep date)
    [[ "$operation" == transfer ]] && required+=(rsync flock)
    [[ "${AUTH_METHOD:-}" == password ]] && required+=(sshpass)
    local -a missing=()
    for cmd in "${required[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if (( ${#missing[@]} > 0 )); then
        echo -e "${RED}${ICON_ERROR} 缺少必要依赖: ${missing[*]}${NC}" >&2
        return 1
    fi
}

validate_boolean() {
    [[ "$1" == true || "$1" == false ]]
}

parse_server_info() {
    local server_info="$1"
    local user="${DEFAULT_USER:-}" host="" port="${DEFAULT_PORT:-22}"

    [[ -n "$server_info" ]] || return 1
    contains_control_character "$server_info" && return 1
    [[ ! "$server_info" =~ [[:space:]] ]] || return 1
    if [[ "$server_info" == *@* ]]; then
        [[ "$server_info" != *@*@* ]] || return 1
        user=${server_info%%@*}
        server_info=${server_info#*@}
    fi
    [[ "$user" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ && "$user" != -* ]] || return 1

    if [[ "$server_info" =~ ^\[([^][]+)\]:([0-9]+)$ ]]; then
        host=${BASH_REMATCH[1]}; port=${BASH_REMATCH[2]}
        [[ "$host" =~ ^[0-9A-Fa-f:.%_-]+$ ]] || return 1
    elif [[ "$server_info" =~ ^\[([^][]+)\]$ ]]; then
        host=${BASH_REMATCH[1]}
        [[ "$host" =~ ^[0-9A-Fa-f:.%_-]+$ ]] || return 1
    elif [[ "$server_info" =~ ^([^:]+):([0-9]+)$ ]]; then
        host=${BASH_REMATCH[1]}; port=${BASH_REMATCH[2]}
        [[ "$host" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
    elif [[ "$server_info" == *:* ]]; then
        echo -e "${RED}${ICON_ERROR} IPv6 地址必须使用方括号${NC}" >&2
        return 1
    else
        host="$server_info"
        [[ "$host" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
    fi
    [[ -n "$host" && "$host" != -* && "$port" =~ ^[0-9]+$ ]] || return 1
    (( port >= 1 && port <= 65535 )) || return 1

    PARSED_PORT="$port"
    if [[ "$host" == *:* ]]; then
        PARSED_SSH_TARGET="$user@$host"
        PARSED_RSYNC_TARGET="$user@[$host]"
        PARSED_DISPLAY_TARGET="$user@[$host]"
    else
        PARSED_SSH_TARGET="$user@$host"
        PARSED_RSYNC_TARGET="$user@$host"
        PARSED_DISPLAY_TARGET="$user@$host"
    fi
}

format_server_info() {
    parse_server_info "$1" || return 1
    printf '%s:%s\n' "$PARSED_DISPLAY_TARGET" "$PARSED_PORT"
}

validate_config() {
    local errors=0 name value server

    DELETE_EXTRA="${DELETE_EXTRA:-false}"
    ALLOW_DELETE_EXTRA="${ALLOW_DELETE_EXTRA:-false}"
    ALLOW_INSECURE_HOST_KEY_STORAGE="${ALLOW_INSECURE_HOST_KEY_STORAGE:-false}"
    RSYNC_ARCHIVE="${RSYNC_ARCHIVE:-true}"
    RSYNC_COMPRESS="${RSYNC_COMPRESS:-true}"
    ENABLE_LOGGING="${ENABLE_LOGGING:-false}"
    USER_KNOWN_HOSTS_FILE="${USER_KNOWN_HOSTS_FILE:-${HOME}/.ssh/known_hosts}"
    STRICT_HOST_KEY_CHECKING="${STRICT_HOST_KEY_CHECKING:-accept-new}"

    for name in DELETE_EXTRA ALLOW_DELETE_EXTRA ALLOW_INSECURE_HOST_KEY_STORAGE RSYNC_ARCHIVE RSYNC_COMPRESS ENABLE_LOGGING; do
        value=${!name:-}
        validate_boolean "$value" || {
            echo -e "${RED}${ICON_ERROR} $name 必须是 true 或 false${NC}" >&2
            ((errors += 1))
        }
    done
    for name in DEFAULT_PORT MAX_PARALLEL CONNECTION_TIMEOUT TOTAL_TIMEOUT MAX_RETRIES RETRY_DELAY; do
        value=${!name:-}
        [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 1 )) || {
            echo -e "${RED}${ICON_ERROR} $name 必须是正整数${NC}" >&2
            ((errors += 1))
        }
    done
    [[ "${DEFAULT_PORT:-0}" =~ ^[0-9]+$ ]] && (( DEFAULT_PORT <= 65535 )) || ((errors += 1))
    [[ "$STRICT_HOST_KEY_CHECKING" == yes || "$STRICT_HOST_KEY_CHECKING" == no || "$STRICT_HOST_KEY_CHECKING" == accept-new ]] || ((errors += 1))
    [[ "$USER_KNOWN_HOSTS_FILE" != /dev/null || "$ALLOW_INSECURE_HOST_KEY_STORAGE" == true ]] || {
        echo -e "${RED}${ICON_ERROR} /dev/null 需要 ALLOW_INSECURE_HOST_KEY_STORAGE=true${NC}" >&2
        ((errors += 1))
    }
    [[ "${AUTH_METHOD:-}" == key || "${AUTH_METHOD:-}" == password ]] || ((errors += 1))
    if [[ "${AUTH_METHOD:-}" == key ]]; then
        [[ -n "${KEY_FILE:-}" ]] || ((errors += 1))
    else
        case "${PASSWORD_METHOD:-}" in
            file) [[ -n "${PASSWORD_FILE:-}" ]] || ((errors += 1)) ;;
            env) [[ "${PASSWORD_ENV_VAR:-}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || ((errors += 1)) ;;
            interactive) ;;
            inline) [[ -n "${PASSWORD:-}" ]] || ((errors += 1)) ;;
            *) ((errors += 1)) ;;
        esac
    fi
    (( ${#SERVERS[@]} > 0 )) || ((errors += 1))
    for server in "${SERVERS[@]}"; do
        parse_server_info "$server" >/dev/null 2>&1 || {
            echo -e "${RED}${ICON_ERROR} 服务器地址无效: $server${NC}" >&2
            ((errors += 1))
        }
    done
    (( errors == 0 )) || {
        echo -e "${RED}${ICON_ERROR} 配置验证失败${NC}" >&2
        return 1
    }
}

runtime_begin_allocation_critical() {
    [[ "$RUNTIME_ALLOCATION_CRITICAL" == false ]] || return 1
    RUNTIME_PENDING_SIGNAL=""
    RUNTIME_PENDING_SIGNAL_STATUS=0
    RUNTIME_ALLOCATION_CRITICAL=true
}

runtime_end_allocation_critical() {
    local signal_name="" signal_status=0
    RUNTIME_ALLOCATION_CRITICAL=false
    signal_name="$RUNTIME_PENDING_SIGNAL"
    signal_status="$RUNTIME_PENDING_SIGNAL_STATUS"
    RUNTIME_PENDING_SIGNAL=""
    RUNTIME_PENDING_SIGNAL_STATUS=0
    if [[ -n "$signal_name" ]]; then
        runtime_signal_handler "$signal_name" "$signal_status"
    fi
}

runtime_allocator_after_create_hook() {
    :
}

runtime_random_token() {
    local token=""
    token=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n') || return 1
    [[ "$token" =~ ^[0-9a-f]{32}$ ]] || return 1
    printf '%s\n' "$token"
}

runtime_allocator_child_cleanup() {
    if [[ "$RUNTIME_ALLOCATOR_CHILD_CREATED" == true &&
        ( -e "$RUNTIME_ALLOCATOR_CHILD_PATH" || -L "$RUNTIME_ALLOCATOR_CHILD_PATH" ) ]]; then
        if [[ -d "$RUNTIME_ALLOCATOR_CHILD_PATH" && ! -L "$RUNTIME_ALLOCATOR_CHILD_PATH" ]]; then
            rmdir -- "$RUNTIME_ALLOCATOR_CHILD_PATH" || {
                echo -e "${RED}${ICON_ERROR} allocator 自有 candidate 清理失败: $RUNTIME_ALLOCATOR_CHILD_PATH${NC}" >&2
                return 1
            }
        else
            echo -e "${RED}${ICON_ERROR} allocator candidate 类型已变化: $RUNTIME_ALLOCATOR_CHILD_PATH${NC}" >&2
            return 1
        fi
    fi
}

runtime_allocator_child_signal() {
    local status="$1"
    trap - EXIT HUP INT TERM
    runtime_allocator_child_cleanup || true
    exit "$status"
}

runtime_allocator_process() {
    local candidate="$1"
    RUNTIME_ALLOCATOR_CHILD_PATH="$candidate"
    RUNTIME_ALLOCATOR_CHILD_CREATED=false
    trap 'runtime_allocator_child_signal 129' HUP
    trap 'runtime_allocator_child_signal 130' INT
    trap 'runtime_allocator_child_signal 143' TERM
    kill -STOP "$BASHPID"
    if ! mkdir -m 0700 -- "$candidate" 2>/dev/null; then
        return "$RUNTIME_ALLOCATOR_COLLISION_STATUS"
    fi
    RUNTIME_ALLOCATOR_CHILD_CREATED=true
    if ! runtime_allocator_after_create_hook "$candidate"; then
        runtime_allocator_child_cleanup || true
        return 1
    fi
    return 0
}

start_runtime_allocator() {
    local candidate="$1" start="" allocator_state=""
    [[ -z "$RUNTIME_ALLOCATOR_PID" && -z "$RUNTIME_ALLOCATOR_START" ]] || return 1
    runtime_begin_allocation_critical || return 1
    runtime_allocator_process "$candidate" &
    RUNTIME_ALLOCATOR_PID=$!
    for _ in {1..100}; do
        if read_process_record "$RUNTIME_ALLOCATOR_PID"; then
            start=$PROC_START
            allocator_state=$PROC_STATE
            [[ "$allocator_state" == T ]] && break
        fi
        kill -0 "$RUNTIME_ALLOCATOR_PID" 2>/dev/null || break
        sleep 0.01
    done
    RUNTIME_ALLOCATOR_START="$start"
    if [[ -z "$RUNTIME_ALLOCATOR_START" || "$allocator_state" != T ]]; then
        kill -CONT "$RUNTIME_ALLOCATOR_PID" 2>/dev/null || true
        kill -TERM "$RUNTIME_ALLOCATOR_PID" 2>/dev/null || true
        wait "$RUNTIME_ALLOCATOR_PID" 2>/dev/null || true
        RUNTIME_ALLOCATOR_PID=""
        RUNTIME_ALLOCATOR_START=""
        if [[ ! -e "$candidate" && ! -L "$candidate" ]]; then
            TEMP_DIR=""
            RUNTIME_STATE=none
            RUNTIME_CANDIDATE_CREATED=false
            RUNTIME_PARENT=""
            RUNTIME_PARENT_DEV=""
            RUNTIME_PARENT_INODE=""
        fi
        runtime_end_allocation_critical
        return 1
    fi
    if [[ -z "$RUNTIME_PENDING_SIGNAL" ]]; then
        kill -CONT "$RUNTIME_ALLOCATOR_PID" 2>/dev/null || true
    fi
    runtime_end_allocation_critical
    return 0
}

wait_runtime_allocator() {
    local allocator_status=0
    [[ -n "$RUNTIME_ALLOCATOR_PID" ]] || return 1
    runtime_begin_allocation_critical || return 1
    wait "$RUNTIME_ALLOCATOR_PID" || allocator_status=$?
    if [[ -n "$RUNTIME_PENDING_SIGNAL" ]]; then
        if [[ -n "$RUNTIME_ALLOCATOR_START" ]] &&
            process_identity_matches "$RUNTIME_ALLOCATOR_PID" "$RUNTIME_ALLOCATOR_START"; then
            kill -CONT "$RUNTIME_ALLOCATOR_PID" 2>/dev/null || true
            kill -TERM "$RUNTIME_ALLOCATOR_PID" 2>/dev/null || true
        fi
        allocator_status=0
        wait "$RUNTIME_ALLOCATOR_PID" 2>/dev/null || allocator_status=$?
    fi
    if (( allocator_status == 0 )); then
        RUNTIME_CANDIDATE_CREATED=true
    fi
    RUNTIME_ALLOCATOR_PID=""
    RUNTIME_ALLOCATOR_START=""
    runtime_end_allocation_critical
    return "$allocator_status"
}

terminate_runtime_allocator() {
    local allocator_status=0
    [[ -n "$RUNTIME_ALLOCATOR_PID" ]] || return 0
    if [[ -n "$RUNTIME_ALLOCATOR_START" ]] &&
        process_identity_matches "$RUNTIME_ALLOCATOR_PID" "$RUNTIME_ALLOCATOR_START"; then
        kill -CONT "$RUNTIME_ALLOCATOR_PID" 2>/dev/null || true
        kill -TERM "$RUNTIME_ALLOCATOR_PID" 2>/dev/null || true
    fi
    wait "$RUNTIME_ALLOCATOR_PID" 2>/dev/null || allocator_status=$?
    if (( allocator_status == 0 )); then
        RUNTIME_CANDIDATE_CREATED=true
    fi
    RUNTIME_ALLOCATOR_PID=""
    RUNTIME_ALLOCATOR_START=""
    return 0
}

runtime_building_hook() {
    :
}

worker_registration_phase_hook() {
    :
}

parent_worker_registration_hook() {
    :
}

worker_session_state_publish_hook() {
    :
}

worker_session_state_read_hook() {
    :
}

runtime_parent_trusted() {
    local dev="" inode=""
    [[ -n "$RUNTIME_PARENT" && -d "$RUNTIME_PARENT" && ! -L "$RUNTIME_PARENT" ]] || return 1
    validate_existing_directory_chain "$RUNTIME_PARENT" || return 1
    capture_directory_identity "$RUNTIME_PARENT" dev inode || return 1
    [[ "$dev" == "$RUNTIME_PARENT_DEV" && "$inode" == "$RUNTIME_PARENT_INODE" ]]
}

runtime_building_directory_trusted() {
    local metadata="" dev inode owner gid mode trusted_gid
    runtime_parent_trusted || return 1
    [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" && ! -L "$TEMP_DIR" ]] || return 1
    metadata=$(stat -Lc '%d:%i:%u:%g:%a' -- "$TEMP_DIR" 2>/dev/null) || return 1
    IFS=: read -r dev inode owner gid mode <<< "$metadata"
    trusted_gid=$(current_gid) || return 1
    [[ "$owner" == "$EUID" && "$gid" == "$trusted_gid" && "$mode" == 700 ]] || return 1
    if [[ -n "$TEMP_DIR_DEV" || -n "$TEMP_DIR_INODE" ]]; then
        [[ "$dev" == "$TEMP_DIR_DEV" && "$inode" == "$TEMP_DIR_INODE" ]] || return 1
    fi
}

runtime_directory_trusted() {
    [[ "$RUNTIME_STATE" == initialized ]] || return 1
    runtime_building_directory_trusted
}

initialize_runtime() {
    local parent="${TMPDIR:-/tmp}" candidate="" metadata=""
    local dev inode owner gid mode trusted_gid
    local success_file failed_file wrapper parent_dev parent_inode
    local token="" allocator_status=0 attempt

    [[ "$RUNTIME_STATE" == none && "$RUNTIME_INITIALIZED" == false && -z "$TEMP_DIR" ]] || return 1
    [[ "$parent" =~ ^[A-Za-z0-9_./-]+$ ]] || {
        echo -e "${RED}${ICON_ERROR} TMPDIR 包含不适合 rsync remote-shell 参数的字符: $parent${NC}" >&2
        return 1
    }
    validate_existing_directory_chain "$parent" || {
        echo -e "${RED}${ICON_ERROR} TMPDIR 路径包含可替换或不可信目录: $parent${NC}" >&2
        return 1
    }
    capture_directory_identity "$parent" parent_dev parent_inode || return 1
    RUNTIME_PARENT="$parent"
    RUNTIME_PARENT_DEV="$parent_dev"
    RUNTIME_PARENT_INODE="$parent_inode"

    for attempt in {1..64}; do
        token=$(runtime_random_token) || return 1
        candidate="$parent/push-runtime.$token"
        TEMP_DIR="$candidate"
        TEMP_DIR_DEV=""
        TEMP_DIR_INODE=""
        RUNTIME_STATE=building
        RUNTIME_CANDIDATE_CREATED=false
        start_runtime_allocator "$candidate" || {
            echo -e "${RED}${ICON_ERROR} 无法启动 runtime allocator: $candidate${NC}" >&2
            return 1
        }
        allocator_status=0
        wait_runtime_allocator || allocator_status=$?
        if (( allocator_status == 0 )); then
            break
        fi
        if (( allocator_status == RUNTIME_ALLOCATOR_COLLISION_STATUS )) &&
            [[ -e "$candidate" || -L "$candidate" ]]; then
            TEMP_DIR=""
            RUNTIME_STATE=none
            RUNTIME_CANDIDATE_CREATED=false
            continue
        fi
        if [[ -e "$candidate" || -L "$candidate" ]]; then
            echo -e "${RED}${ICON_ERROR} allocator 失败并留下未接管 candidate: $candidate${NC}" >&2
            return 1
        fi
        TEMP_DIR=""
        RUNTIME_STATE=none
        RUNTIME_CANDIDATE_CREATED=false
        echo -e "${RED}${ICON_ERROR} runtime allocator 创建失败${NC}" >&2
        return 1
    done
    if [[ "$RUNTIME_CANDIDATE_CREATED" != true || -z "$TEMP_DIR" ]]; then
        echo -e "${RED}${ICON_ERROR} runtime allocator 未能创建可接管目录${NC}" >&2
        return 1
    fi
    runtime_building_hook "$candidate"

    metadata=$(stat -Lc '%d:%i:%u:%g:%a' -- "$candidate" 2>/dev/null) || {
        cleanup_runtime || true
        return 1
    }
    IFS=: read -r dev inode owner gid mode <<< "$metadata"
    trusted_gid=$(current_gid) || {
        cleanup_runtime || true
        return 1
    }
    TEMP_DIR_DEV="$dev"
    TEMP_DIR_INODE="$inode"
    if [[ ! -d "$candidate" || -L "$candidate" || "$owner" != "$EUID" || "$gid" != "$trusted_gid" || "$mode" != 700 ]]; then
        echo -e "${RED}${ICON_ERROR} 新建 runtime 目录未通过 owner/mode 校验: $candidate${NC}" >&2
        cleanup_runtime || true
        return 1
    fi
    success_file="$candidate/success"
    failed_file="$candidate/failed"
    wrapper="$candidate/ssh-wrapper"
    if ! (umask 077; set -o noclobber; : > "$success_file"; : > "$failed_file") 2>/dev/null; then
        cleanup_runtime || true
        return 1
    fi
    [[ -f "$success_file" && ! -L "$success_file" && -f "$failed_file" && ! -L "$failed_file" ]] || {
        cleanup_runtime || true
        return 1
    }

    SUCCESS_FILE="$success_file"
    FAILED_FILE="$failed_file"
    SSH_WRAPPER="$wrapper"
    RUNTIME_STATE=initialized
    RUNTIME_INITIALIZED=true
    ACTIVE_WORKERS=()
}

read_process_stat() {
    local pid="$1" stat_line="" stat_rest="" stat_fd
    local -a fields=()

    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    { exec {stat_fd}<"/proc/$pid/stat"; } 2>/dev/null || return 1
    IFS= read -r stat_line <&"$stat_fd" || [[ -n "$stat_line" ]] || { exec {stat_fd}<&- || true; return 1; }
    exec {stat_fd}<&- || true
    [[ "$stat_line" == "$pid ("* && "$stat_line" == *") "* ]] || return 1
    stat_rest=${stat_line##*) }
    read -r -a fields <<< "$stat_rest"
    (( ${#fields[@]} >= 20 )) || return 1
    PROC_STATE=${fields[0]}
    PROC_PPID=${fields[1]}
    PROC_PGID=${fields[2]}
    PROC_SID=${fields[3]}
    PROC_START=${fields[19]}
}

read_process_uid() {
    local pid="$1" uid_line="" status_key status_value status_fd
    { exec {status_fd}<"/proc/$pid/status"; } 2>/dev/null || return 1
    while read -r status_key status_value _ <&"$status_fd"; do
        if [[ "$status_key" == Uid: ]]; then
            uid_line=$status_value
            break
        fi
    done
    exec {status_fd}<&- || true
    [[ "$uid_line" =~ ^[0-9]+$ ]] || return 1
    PROC_UID=$uid_line
}

read_process_record() {
    local pid="$1"
    read_process_stat "$pid" || return 1
    read_process_uid "$pid"
}

get_process_start_time() {
    read_process_record "$1" || return 1
    printf '%s\n' "$PROC_START"
}

get_process_group_id() {
    read_process_record "$1" || return 1
    printf '%s\n' "$PROC_PGID"
}

get_process_session_id() {
    read_process_record "$1" || return 1
    printf '%s\n' "$PROC_SID"
}

process_identity_matches() {
    local pid="$1" expected_start="$2" _
    for _ in {1..3}; do
        if read_process_record "$pid"; then
            [[ "$PROC_START" == "$expected_start" && "$PROC_UID" == "$EUID" ]]
            return
        fi
        [[ -r "/proc/$pid/stat" ]] || return 1
        sleep 0.01
    done
    return 1
}

job_is_active() {
    local expected="$1" pid
    while IFS= read -r pid; do
        [[ "$pid" == "$expected" ]] && return 0
    done < <(jobs -pr)
    return 1
}

worker_registration_begin_critical() {
    [[ "$WORKER_REGISTRATION_CRITICAL" == false ]] || return 1
    WORKER_REGISTRATION_CRITICAL=true
}

worker_registration_end_critical() {
    local signal_name="$WORKER_REGISTRATION_PENDING_SIGNAL" status="$WORKER_REGISTRATION_PENDING_STATUS"
    WORKER_REGISTRATION_CRITICAL=false
    WORKER_REGISTRATION_PENDING_SIGNAL=""; WORKER_REGISTRATION_PENDING_STATUS=0
    [[ -z "$signal_name" ]] || runtime_signal_handler "$signal_name" "$status"
}

worker_registration_ready_path() {
    local pid="$1"
    [[ -n "$TEMP_DIR" && "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    printf '%s/worker-registration.%s.ready\n' "$TEMP_DIR" "$pid"
}

worker_registration_release_path() {
    local pid="$1"
    [[ -n "$TEMP_DIR" && "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    printf '%s/worker-registration.%s.release\n' "$TEMP_DIR" "$pid"
}

worker_registration_safe_unlink() {
    local path="$1" metadata owner gid trusted_gid
    [[ -n "$TEMP_DIR" && "$path" == "$TEMP_DIR"/* ]] || return 1
    [[ -e "$path" || -L "$path" ]] || return 0
    metadata=$(stat -c '%u:%g' -- "$path" 2>/dev/null) || return 1
    IFS=: read -r owner gid <<< "$metadata"
    trusted_gid=$(current_gid) || return 1
    [[ "$owner" == "$EUID" && "$gid" == "$trusted_gid" ]] || return 1
    [[ -f "$path" || -L "$path" ]] || return 1
    rm -f -- "$path"
}

cleanup_worker_registration_for_pid() {
    local pid="$1" ready release stage path failed=false saved
    ready=${WORKER_REGISTRATION_READY_FILES[$pid]:-}
    release=${WORKER_REGISTRATION_RELEASE_FILES[$pid]:-}
    stage=${WORKER_REGISTRATION_STAGE_FILES[$pid]:-}
    [[ -n "$ready" ]] || ready=$(worker_registration_ready_path "$pid") || return 1
    [[ -n "$release" ]] || release=$(worker_registration_release_path "$pid") || return 1
    for path in "$stage" "$ready" "$release"; do
        [[ -n "$path" ]] || continue
        worker_registration_safe_unlink "$path" || failed=true
    done
    saved=$(shopt -p nullglob || true); shopt -s nullglob
    for path in "$TEMP_DIR"/.worker-registration."$pid".*.stage; do
        worker_registration_safe_unlink "$path" || failed=true
    done
    eval "$saved"
    if [[ "$failed" == false ]]; then
        unset 'WORKER_REGISTRATION_READY_FILES[$pid]' 'WORKER_REGISTRATION_RELEASE_FILES[$pid]'
        unset 'WORKER_REGISTRATION_STARTS[$pid]' 'WORKER_REGISTRATION_STAGE_FILES[$pid]'
    fi
    [[ "$failed" == false ]]
}

cleanup_all_worker_registration_residue() {
    local pid path saved failed=false
    [[ -n "$TEMP_DIR" ]] || return 0
    for pid in "${!REGISTERING_WORKERS[@]}" "${!WORKER_REGISTRATION_READY_FILES[@]}"; do
        [[ -n "$pid" ]] || continue
        cleanup_worker_registration_for_pid "$pid" || failed=true
    done
    saved=$(shopt -p nullglob || true); shopt -s nullglob
    for path in "$TEMP_DIR"/worker-registration.*.ready "$TEMP_DIR"/worker-registration.*.release \
        "$TEMP_DIR"/.worker-registration.*.stage; do
        worker_registration_safe_unlink "$path" || failed=true
    done
    eval "$saved"
    [[ "$failed" == false ]]
}

publish_worker_registration_manifest() {
    local final="$1" role="$2" pid="$3" content="$4" token stage
    runtime_directory_trusted || return 1
    [[ "$final" == "$TEMP_DIR"/worker-registration."$pid"."$role" ]] || return 1
    [[ ! -e "$final" && ! -L "$final" ]] || return 1
    token=$(runtime_random_token) || return 1
    stage="$TEMP_DIR/.worker-registration.$pid.$role.$token.stage"
    if [[ "$role" == ready ]]; then WORKER_REGISTRATION_STAGE_FILE=$stage; else WORKER_REGISTRATION_STAGE_FILES[$pid]=$stage; fi
    if ! (umask 077; set -o noclobber; : > "$stage") 2>/dev/null; then return 1; fi
    printf '%s' "$content" > "$stage" || return 1
    chmod 0600 "$stage" || return 1
    if [[ "$role" == ready ]]; then
        read_worker_registration_manifest "$stage" ready || return 1
    else
        read_worker_registration_manifest "$stage" accepted || return 1
    fi
    mv -fT -- "$stage" "$final" || return 1
    if [[ "$role" == ready ]]; then WORKER_REGISTRATION_STAGE_FILE=""; else unset 'WORKER_REGISTRATION_STAGE_FILES[$pid]'; fi
}

REGISTRATION_STATE=""; REGISTRATION_WORKER_PID=""; REGISTRATION_WORKER_START=""
REGISTRATION_PARENT_PID=""; REGISTRATION_PARENT_START=""; REGISTRATION_READY_DEV=""; REGISTRATION_READY_INODE=""
REGISTRATION_FILE_DEV=""; REGISTRATION_FILE_INODE=""
read_worker_registration_manifest() {
    local file="$1" expected_state="$2" line key value line_count=0 before after owner gid mode trusted_gid
    local -A seen=()
    [[ -f "$file" && ! -L "$file" ]] || return 1
    before=$(stat -Lc '%d:%i:%u:%g:%a' -- "$file" 2>/dev/null) || return 1
    IFS=: read -r REGISTRATION_FILE_DEV REGISTRATION_FILE_INODE owner gid mode <<< "$before"
    trusted_gid=$(current_gid) || return 1
    [[ "$owner" == "$EUID" && "$gid" == "$trusted_gid" && "$mode" == 600 ]] || return 1
    REGISTRATION_STATE=""; REGISTRATION_WORKER_PID=""; REGISTRATION_WORKER_START=""
    REGISTRATION_PARENT_PID=""; REGISTRATION_PARENT_START=""; REGISTRATION_READY_DEV=""; REGISTRATION_READY_INODE=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        ((line_count += 1)); [[ "$line" == *=* ]] || return 1
        key=${line%%=*}; value=${line#*=}; [[ -z "${seen[$key]:-}" ]] || return 1; seen[$key]=1
        case "$key" in
            version) [[ "$value" == 1 ]] || return 1 ;;
            state) REGISTRATION_STATE=$value ;;
            worker_pid) REGISTRATION_WORKER_PID=$value ;;
            worker_start) REGISTRATION_WORKER_START=$value ;;
            parent_pid) REGISTRATION_PARENT_PID=$value ;;
            parent_start) REGISTRATION_PARENT_START=$value ;;
            ready_dev) REGISTRATION_READY_DEV=$value ;;
            ready_inode) REGISTRATION_READY_INODE=$value ;;
            *) return 1 ;;
        esac
    done < "$file"
    [[ "$REGISTRATION_STATE" == "$expected_state" ]] || return 1
    if [[ "$expected_state" == ready ]]; then
        (( line_count == 6 && ${#seen[@]} == 6 )) || return 1
        [[ -z "$REGISTRATION_READY_DEV" && -z "$REGISTRATION_READY_INODE" ]] || return 1
    elif [[ "$expected_state" == accepted ]]; then
        (( line_count == 8 && ${#seen[@]} == 8 )) || return 1
        [[ "$REGISTRATION_READY_DEV" =~ ^[1-9][0-9]*$ && "$REGISTRATION_READY_INODE" =~ ^[1-9][0-9]*$ ]] || return 1
    else return 1; fi
    for value in "$REGISTRATION_WORKER_PID" "$REGISTRATION_WORKER_START" "$REGISTRATION_PARENT_PID" "$REGISTRATION_PARENT_START"; do
        [[ "$value" =~ ^[1-9][0-9]*$ ]] || return 1
    done
    after=$(stat -Lc '%d:%i:%u:%g:%a' -- "$file" 2>/dev/null) || return 1
    [[ "$after" == "$before" ]]
}

publish_worker_registration_ready() {
    local pid="$1" start="$2" parent_pid="$3" parent_start="$4" content
    WORKER_REGISTRATION_READY_FILE=$(worker_registration_ready_path "$pid") || return 1
    WORKER_REGISTRATION_RELEASE_FILE=$(worker_registration_release_path "$pid") || return 1
    content=$(printf 'version=1\nstate=ready\nworker_pid=%s\nworker_start=%s\nparent_pid=%s\nparent_start=%s\n' \
        "$pid" "$start" "$parent_pid" "$parent_start") || return 1
    publish_worker_registration_manifest "$WORKER_REGISTRATION_READY_FILE" ready "$pid" "$content" || return 1
    read_worker_registration_manifest "$WORKER_REGISTRATION_READY_FILE" ready || return 1
    [[ "$REGISTRATION_WORKER_PID" == "$pid" && "$REGISTRATION_WORKER_START" == "$start" &&
        "$REGISTRATION_PARENT_PID" == "$parent_pid" && "$REGISTRATION_PARENT_START" == "$parent_start" ]] || return 1
    WORKER_REGISTRATION_READY_DEV=$REGISTRATION_FILE_DEV
    WORKER_REGISTRATION_READY_INODE=$REGISTRATION_FILE_INODE
}

publish_worker_registration_release() {
    local pid="$1" start="$2" parent_pid="$3" parent_start="$4" ready_dev="$5" ready_inode="$6" final content
    final=$(worker_registration_release_path "$pid") || return 1
    content=$(printf 'version=1\nstate=accepted\nworker_pid=%s\nworker_start=%s\nparent_pid=%s\nparent_start=%s\nready_dev=%s\nready_inode=%s\n' \
        "$pid" "$start" "$parent_pid" "$parent_start" "$ready_dev" "$ready_inode") || return 1
    publish_worker_registration_manifest "$final" release "$pid" "$content" || return 1
    [[ "$REGISTRATION_WORKER_PID" == "$pid" && "$REGISTRATION_WORKER_START" == "$start" &&
        "$REGISTRATION_PARENT_PID" == "$parent_pid" && "$REGISTRATION_PARENT_START" == "$parent_start" &&
        "$REGISTRATION_READY_DEV" == "$ready_dev" && "$REGISTRATION_READY_INODE" == "$ready_inode" ]]
}

validate_worker_registration_release() {
    local pid="$1" start="$2" parent_pid="$3" parent_start="$4" ready_meta
    read_worker_registration_manifest "$WORKER_REGISTRATION_RELEASE_FILE" accepted || return 1
    [[ "$REGISTRATION_WORKER_PID" == "$pid" && "$REGISTRATION_WORKER_START" == "$start" &&
        "$REGISTRATION_PARENT_PID" == "$parent_pid" && "$REGISTRATION_PARENT_START" == "$parent_start" &&
        "$REGISTRATION_READY_DEV" == "$WORKER_REGISTRATION_READY_DEV" &&
        "$REGISTRATION_READY_INODE" == "$WORKER_REGISTRATION_READY_INODE" ]] || return 1
    ready_meta=$(stat -Lc '%d:%i' -- "$WORKER_REGISTRATION_READY_FILE" 2>/dev/null) || return 1
    [[ "$ready_meta" == "$WORKER_REGISTRATION_READY_DEV:$WORKER_REGISTRATION_READY_INODE" ]]
}

worker_cleanup_own_registration() {
    local failed=false path
    for path in "$WORKER_REGISTRATION_STAGE_FILE" "$WORKER_REGISTRATION_READY_FILE" "$WORKER_REGISTRATION_RELEASE_FILE"; do
        [[ -n "$path" ]] || continue
        worker_registration_safe_unlink "$path" || failed=true
    done
    [[ "$failed" == false ]] && { WORKER_REGISTRATION_STAGE_FILE=""; WORKER_REGISTRATION_READY_FILE=""; WORKER_REGISTRATION_RELEASE_FILE=""; }
    [[ "$failed" == false ]]
}

worker_registration_signal_handler() {
    local status="$1"
    trap - EXIT HUP INT TERM
    worker_cleanup_own_registration || true
    exit "$status"
}

worker_registration_exit_handler() {
    local status="$?"
    trap - EXIT HUP INT TERM
    if ! worker_cleanup_own_registration && (( status == 0 )); then status=$MANAGED_CLEANUP_FAILURE_STATUS; fi
    exit "$status"
}

worker_registration_verify_parent_identity() {
    local parent_pid="$1" parent_start="$2" _
    for _ in {1..20}; do
        process_identity_matches "$parent_pid" "$parent_start" && return 0
        [[ -r "/proc/$parent_pid/stat" ]] || return 1
        sleep 0.01
    done
    return 1
}

registered_worker_entry() {
    local parent_pid="$1" parent_start="$2" server="$3" src="$4" dst="$5" index="$6" total="$7"
    local worker_pid=$BASHPID worker_start="" _
    WORKER_REGISTRATION_CRITICAL=false
    WORKER_REGISTRATION_PENDING_SIGNAL=""; WORKER_REGISTRATION_PENDING_STATUS=0
    trap 'worker_registration_signal_handler 129' HUP
    trap 'worker_registration_signal_handler 130' INT
    trap 'worker_registration_signal_handler 143' TERM
    trap worker_registration_exit_handler EXIT
    worker_registration_phase_hook before-ready "$worker_pid" || { echo -e "${RED}${ICON_ERROR} worker registration before-ready hook 失败: $worker_pid${NC}" >&2; return 1; }
    read_process_record "$worker_pid" || { echo -e "${RED}${ICON_ERROR} worker registration 无法读取自身身份: $worker_pid${NC}" >&2; return 1; }
    [[ "$PROC_UID" == "$EUID" && "$PROC_STATE" != Z ]] || { echo -e "${RED}${ICON_ERROR} worker registration 自身身份不可信: $worker_pid${NC}" >&2; return 1; }
    worker_start=$PROC_START
    publish_worker_registration_ready "$worker_pid" "$worker_start" "$parent_pid" "$parent_start" || { echo -e "${RED}${ICON_ERROR} worker registration ready 发布失败: $worker_pid${NC}" >&2; return 1; }
    worker_registration_phase_hook ready-published "$worker_pid" || { echo -e "${RED}${ICON_ERROR} worker registration ready-published hook 失败: $worker_pid${NC}" >&2; return 1; }
    for _ in $(seq 1 "$WORKER_REGISTRATION_TIMEOUT_TICKS"); do
        if ! process_identity_matches "$parent_pid" "$parent_start"; then
            [[ -r "/proc/$parent_pid/stat" ]] || { echo -e "${RED}${ICON_ERROR} worker registration parent 身份已消失: $worker_pid${NC}" >&2; return 1; }
            sleep 0.05
            continue
        fi
        if [[ -e "$WORKER_REGISTRATION_RELEASE_FILE" || -L "$WORKER_REGISTRATION_RELEASE_FILE" ]]; then
            validate_worker_registration_release "$worker_pid" "$worker_start" "$parent_pid" "$parent_start" || { echo -e "${RED}${ICON_ERROR} worker registration release 不可信: $worker_pid${NC}" >&2; return "$MANAGED_CLEANUP_FAILURE_STATUS"; }
            worker_registration_phase_hook release-validated "$worker_pid" || { echo -e "${RED}${ICON_ERROR} worker registration release-validated hook 失败: $worker_pid${NC}" >&2; return 1; }
            worker_cleanup_own_registration || { echo -e "${RED}${ICON_ERROR} worker registration handoff 清理失败: $worker_pid${NC}" >&2; return "$MANAGED_CLEANUP_FAILURE_STATUS"; }
            worker_registration_verify_parent_identity "$parent_pid" "$parent_start" || { echo -e "${RED}${ICON_ERROR} worker registration handoff 后 parent 身份已消失: $worker_pid${NC}" >&2; return 1; }
            worker_registration_phase_hook before-transfer "$worker_pid" || { echo -e "${RED}${ICON_ERROR} worker registration before-transfer hook 失败: $worker_pid${NC}" >&2; return 1; }
            push_to_server "$server" "$src" "$dst" "$index" "$total"
            return
        fi
        sleep 0.05
    done
    echo -e "${RED}${ICON_ERROR} worker registration release 等待超时: $worker_pid${NC}" >&2
    return 1
}

terminate_registering_worker_job() {
    local pid="$1" _ wait_status=0
    if job_is_active "$pid"; then kill -TERM "$pid" 2>/dev/null || true; fi
    for _ in {1..40}; do job_is_active "$pid" || break; sleep 0.05; done
    if job_is_active "$pid"; then kill -KILL "$pid" 2>/dev/null || true; fi
    for _ in {1..20}; do job_is_active "$pid" || break; sleep 0.05; done
    job_is_active "$pid" && return 1
    wait "$pid" 2>/dev/null || wait_status=$?
    record_worker_wait_status "$wait_status"
}

terminate_registering_worker() {
    local pid="$1" failed=false
    terminate_registering_worker_job "$pid" || failed=true
    cleanup_worker_registration_for_pid "$pid" || failed=true
    unset 'REGISTERING_WORKERS[$pid]'
    [[ "$failed" == false ]]
}

record_worker_wait_status() {
    local wait_status="$1"
    if (( wait_status == MANAGED_CLEANUP_FAILURE_STATUS )); then
        BATCH_WORKER_FAILED=true
    elif (( wait_status != 0 && wait_status != 127 )); then
        BATCH_WORKER_ERROR=true
    fi
}

runtime_has_published_worker_state() {
    local state_file
    [[ -n "$TEMP_DIR" ]] || return 1
    for state_file in "$TEMP_DIR"/worker-session.*.state; do
        [[ -e "$state_file" || -L "$state_file" ]] && return 0
    done
    return 1
}

runtime_has_worker_registration_state() {
    local path
    [[ -n "$TEMP_DIR" ]] || return 1
    for path in "$TEMP_DIR"/worker-registration.*.ready "$TEMP_DIR"/worker-registration.*.release \
        "$TEMP_DIR"/.worker-registration.*.stage; do
        [[ -e "$path" || -L "$path" ]] && return 0
    done
    return 1
}

has_unresolved_worker_registration() {
    local pid ready release
    for pid in "${!WORKER_REGISTRATION_READY_FILES[@]}"; do
        [[ -n "${REGISTERING_WORKERS[$pid]:-}" || -n "${ACTIVE_WORKERS[$pid]:-}" ]] && continue
        ready=${WORKER_REGISTRATION_READY_FILES[$pid]:-}; release=${WORKER_REGISTRATION_RELEASE_FILES[$pid]:-}
        [[ -e "$ready" || -L "$ready" || -e "$release" || -L "$release" ]] && return 0
    done
    return 1
}

has_unresolved_exited_worker_state() {
    local worker_pid state_file
    for worker_pid in "${!ACTIVE_WORKER_STATE_FILES[@]}"; do
        [[ -n "${ACTIVE_WORKERS[$worker_pid]:-}" ]] && continue
        state_file=${ACTIVE_WORKER_STATE_FILES[$worker_pid]}
        if [[ -e "$state_file" || -L "$state_file" ]]; then
            return 0
        fi
    done
    return 1
}

batch_schedule_barrier_present() {
    [[ "$BATCH_WORKER_FAILED" == true ]] || has_unresolved_exited_worker_state || has_unresolved_worker_registration
}

reset_batch_lifecycle_barrier() {
    if (( ${#ACTIVE_WORKERS[@]} != 0 || ${#ACTIVE_WORKER_STATE_FILES[@]} != 0 ||
        ${#ACTIVE_WORKER_STATE_STARTS[@]} != 0 || ${#REGISTERING_WORKERS[@]} != 0 ||
        ${#WORKER_REGISTRATION_READY_FILES[@]} != 0 || ${#WORKER_REGISTRATION_RELEASE_FILES[@]} != 0 ||
        ${#WORKER_REGISTRATION_STARTS[@]} != 0 || ${#WORKER_REGISTRATION_STAGE_FILES[@]} != 0 )) ||
        [[ -n "$WORKER_TRANSFER_PID" || -n "$WORKER_TRANSFER_PGID" ||
            -n "$WORKER_TRANSFER_SID" || -n "$WORKER_TRANSFER_START" ||
            -n "$WORKER_SESSION_STATE_FILE" || "$WORKER_TRANSFER_CLEANUP_FAILED" == true ]] ||
        runtime_has_published_worker_state || runtime_has_worker_registration_state; then
        echo -e "${RED}${ICON_ERROR} worker lifecycle barrier 尚未安全清空${NC}" >&2
        return 1
    fi
    BATCH_WORKER_FAILED=false
    BATCH_WORKER_ERROR=false
}

prune_active_workers() {
    local pid wait_status=0 failed=false ready release
    for pid in "${!ACTIVE_WORKERS[@]}"; do
        if job_is_active "$pid"; then
            if process_identity_matches "$pid" "${ACTIVE_WORKERS[$pid]}"; then
                ready=${WORKER_REGISTRATION_READY_FILES[$pid]:-}; release=${WORKER_REGISTRATION_RELEASE_FILES[$pid]:-}
                if [[ -n "$ready" && ! -e "$ready" && ! -L "$ready" &&
                    -n "$release" && ! -e "$release" && ! -L "$release" ]]; then
                    unset 'WORKER_REGISTRATION_READY_FILES[$pid]' 'WORKER_REGISTRATION_RELEASE_FILES[$pid]'
                    unset 'WORKER_REGISTRATION_STARTS[$pid]' 'WORKER_REGISTRATION_STAGE_FILES[$pid]'
                fi
                continue
            fi
            if [[ -r "/proc/$pid/stat" ]] && { ! read_process_record "$pid" || [[ "$PROC_STATE" != Z ]]; }; then
                if [[ "$BATCH_WORKER_FAILED" == false ]]; then
                    echo -e "${RED}${ICON_ERROR} active worker 身份不可验证，停止调度并交由完整 grace 清理: pid=$pid expected_start=${ACTIVE_WORKERS[$pid]} actual_start=${PROC_START:-unknown} state=${PROC_STATE:-unknown} uid=${PROC_UID:-unknown}${NC}" >&2
                fi
                BATCH_WORKER_FAILED=true
                failed=true
                continue
            fi
        fi
        wait_status=0
        wait "$pid" 2>/dev/null || wait_status=$?
        record_worker_wait_status "$wait_status"
        unset 'ACTIVE_WORKERS[$pid]'
        cleanup_worker_registration_for_pid "$pid" || { BATCH_WORKER_FAILED=true; failed=true; }
        if [[ -n "${ACTIVE_WORKER_STATE_FILES[$pid]:-}" &&
            ! -e "${ACTIVE_WORKER_STATE_FILES[$pid]}" && ! -L "${ACTIVE_WORKER_STATE_FILES[$pid]}" ]]; then
            unset 'ACTIVE_WORKER_STATE_FILES[$pid]' 'ACTIVE_WORKER_STATE_STARTS[$pid]'
        fi
    done
    [[ "$failed" == false ]]
}

cleanup_published_worker_sessions() {
    local worker_pid file worker_start cleanup_failed=false

    for worker_pid in "${!ACTIVE_WORKER_STATE_FILES[@]}"; do
        file=${ACTIVE_WORKER_STATE_FILES[$worker_pid]}
        worker_start=${ACTIVE_WORKER_STATE_STARTS[$worker_pid]:-}
        # Worker 仍在 ACTIVE/job 表中时可能继续原子发布状态；最终 fallback 必须等待 wait/reap。
        if [[ -n "${ACTIVE_WORKERS[$worker_pid]:-}" ]] || job_is_active "$worker_pid"; then
            continue
        fi
        if [[ ! -e "$file" && ! -L "$file" ]]; then
            if [[ -z "${ACTIVE_WORKERS[$worker_pid]:-}" ]]; then
                unset 'ACTIVE_WORKER_STATE_FILES[$worker_pid]'
                unset 'ACTIVE_WORKER_STATE_STARTS[$worker_pid]'
            fi
            continue
        fi
        if [[ -z "$worker_start" ]] ||
            ! cleanup_worker_session_state_file "$file" "$worker_pid" "$worker_start"; then
            echo -e "${RED}${ICON_ERROR} 主进程无法清理 worker session 状态: $file${NC}" >&2
            cleanup_failed=true
            continue
        fi
        unset 'ACTIVE_WORKER_STATE_FILES[$worker_pid]'
        unset 'ACTIVE_WORKER_STATE_STARTS[$worker_pid]'
    done
    [[ "$cleanup_failed" == false ]]
}

terminate_active_workers() {
    local pid _ wait_status=0 cleanup_failed=false

    for pid in "${!REGISTERING_WORKERS[@]}"; do
        terminate_registering_worker "$pid" || cleanup_failed=true
    done

    # prune 只 reap 已退出 worker；active 身份信任失败仅建立 barrier，不缩短 grace。
    prune_active_workers || cleanup_failed=true
    for pid in "${!ACTIVE_WORKERS[@]}"; do
        if job_is_active "$pid"; then
            # ACTIVE_WORKERS 只包含当前 shell 通过 $! 建立并完成 acceptance 的直接 child job。
            kill -TERM "$pid" 2>/dev/null || true
        fi
    done

    # 有序叶到根回收可能等待父进程 reap；保留约 10 秒完整 grace 供 session 清理和 hook 完成。
    for _ in {1..100}; do
        prune_active_workers || cleanup_failed=true
        (( ${#ACTIVE_WORKERS[@]} == 0 )) && break
        sleep 0.1
    done

    cleanup_published_worker_sessions || cleanup_failed=true

    # 完整 grace 后仍存活的 accepted active worker 才允许 KILL。
    for pid in "${!ACTIVE_WORKERS[@]}"; do
        if job_is_active "$pid"; then
            kill -KILL "$pid" 2>/dev/null || true
        fi
    done
    for _ in {1..20}; do
        prune_active_workers || cleanup_failed=true
        (( ${#ACTIVE_WORKERS[@]} == 0 )) && break
        sleep 0.05
    done

    for pid in "${!ACTIVE_WORKERS[@]}"; do
        if job_is_active "$pid"; then
            cleanup_failed=true
            continue
        fi
        wait_status=0
        wait "$pid" 2>/dev/null || wait_status=$?
        record_worker_wait_status "$wait_status"
        unset 'ACTIVE_WORKERS[$pid]'
        cleanup_worker_registration_for_pid "$pid" || cleanup_failed=true
    done

    cleanup_published_worker_sessions || cleanup_failed=true
    cleanup_all_worker_registration_residue || cleanup_failed=true
    [[ "$cleanup_failed" == false ]]
}

cleanup_runtime() {
    local cleanup_failed=false

    [[ "$RUNTIME_CLEANUP_ACTIVE" == false ]] || return 0
    RUNTIME_CLEANUP_ACTIVE=true
    terminate_runtime_allocator || cleanup_failed=true
    terminate_worker_transfer || cleanup_failed=true
    terminate_active_workers || cleanup_failed=true
    unset SSHPASS

    case "$RUNTIME_STATE" in
        none)
            if [[ -n "$TEMP_DIR" || -e "${TEMP_DIR:-}" || -L "${TEMP_DIR:-}" ]]; then
                echo -e "${RED}${ICON_ERROR} runtime 路径存在但无 building/initialized 状态: $TEMP_DIR${NC}" >&2
                cleanup_failed=true
            fi
            ;;
        building)
            if [[ ! -e "$TEMP_DIR" && ! -L "$TEMP_DIR" ]]; then
                :
            elif [[ "$RUNTIME_CANDIDATE_CREATED" != true ]]; then
                for _ in {1..40}; do
                    [[ ! -e "$TEMP_DIR" && ! -L "$TEMP_DIR" ]] && break
                    sleep 0.05
                done
                if [[ -e "$TEMP_DIR" || -L "$TEMP_DIR" ]]; then
                    echo -e "${RED}${ICON_ERROR} building candidate 存在但 allocator 未证明创建所有权: $TEMP_DIR${NC}" >&2
                    cleanup_failed=true
                fi
            elif ! runtime_building_directory_trusted; then
                echo -e "${RED}${ICON_ERROR} 拒绝删除无法证明所有权的 building runtime: $TEMP_DIR${NC}" >&2
                cleanup_failed=true
            elif ! rm -rf -- "$TEMP_DIR"; then
                echo -e "${RED}${ICON_ERROR} building runtime 删除失败: $TEMP_DIR${NC}" >&2
                cleanup_failed=true
            fi
            ;;
        initialized)
            if [[ ! -e "$TEMP_DIR" && ! -L "$TEMP_DIR" ]]; then
                :
            elif ! runtime_directory_trusted; then
                echo -e "${RED}${ICON_ERROR} 拒绝删除无法证明 inode 所有权的 runtime: $TEMP_DIR${NC}" >&2
                cleanup_failed=true
            elif ! rm -rf -- "$TEMP_DIR"; then
                echo -e "${RED}${ICON_ERROR} runtime 目录删除失败: $TEMP_DIR${NC}" >&2
                cleanup_failed=true
            fi
            ;;
        *)
            echo -e "${RED}${ICON_ERROR} 未知 runtime 生命周期状态: $RUNTIME_STATE${NC}" >&2
            cleanup_failed=true
            ;;
    esac

    if [[ "$cleanup_failed" == false ]]; then
        TEMP_DIR=""
        SUCCESS_FILE=""
        FAILED_FILE=""
        SSH_WRAPPER=""
        RUNTIME_KEY_FILE=""
        TEMP_DIR_DEV=""
        TEMP_DIR_INODE=""
        RUNTIME_PARENT=""
        RUNTIME_PARENT_DEV=""
        RUNTIME_PARENT_INODE=""
        RUNTIME_STATE=none
        RUNTIME_INITIALIZED=false
        RUNTIME_ALLOCATION_CRITICAL=false
        RUNTIME_PENDING_SIGNAL=""
        RUNTIME_PENDING_SIGNAL_STATUS=0
        RUNTIME_ALLOCATOR_PID=""
        RUNTIME_ALLOCATOR_START=""
        RUNTIME_CANDIDATE_CREATED=false
        ACTIVE_WORKERS=()
        ACTIVE_WORKER_STATE_FILES=()
        ACTIVE_WORKER_STATE_STARTS=()
        REGISTERING_WORKERS=()
        WORKER_REGISTRATION_READY_FILES=()
        WORKER_REGISTRATION_RELEASE_FILES=()
        WORKER_REGISTRATION_STARTS=()
        WORKER_REGISTRATION_STAGE_FILES=()
        WORKER_REGISTRATION_READY_FILE=""
        WORKER_REGISTRATION_RELEASE_FILE=""
        WORKER_REGISTRATION_STAGE_FILE=""
        WORKER_REGISTRATION_READY_DEV=""
        WORKER_REGISTRATION_READY_INODE=""
        WORKER_REGISTRATION_CRITICAL=false
        WORKER_REGISTRATION_PENDING_SIGNAL=""
        WORKER_REGISTRATION_PENDING_STATUS=0
        WORKER_SESSION_PATH_DEV=""
        WORKER_SESSION_PATH_INODE=""
        WORKER_SESSION_PATH_OWNER=""
        WORKER_SESSION_PATH_GID=""
        WORKER_SESSION_PATH_MODE=""
        WORKER_SESSION_PATH_SIZE=""
        WORKER_SESSION_FD_DEV=""
        WORKER_SESSION_FD_INODE=""
        WORKER_SESSION_FD_OWNER=""
        WORKER_SESSION_FD_GID=""
        WORKER_SESSION_FD_MODE=""
        WORKER_SESSION_FD_SIZE=""
        SESSION_FILE_DEV=""
        SESSION_FILE_INODE=""
    fi
    RUNTIME_CLEANUP_ACTIVE=false
    [[ "$cleanup_failed" == false ]]
}

runtime_exit_handler() {
    local status="$?" cleanup_status=0
    trap - EXIT
    cleanup_runtime || cleanup_status=$?
    if (( cleanup_status != 0 && status == 0 )); then
        status=1
    fi
    exit "$status"
}

runtime_signal_handler() {
    local signal_name="$1" status="$2"
    if [[ "$WORKER_REGISTRATION_CRITICAL" == true ]]; then
        if [[ -z "$WORKER_REGISTRATION_PENDING_SIGNAL" ]]; then
            WORKER_REGISTRATION_PENDING_SIGNAL=$signal_name
            WORKER_REGISTRATION_PENDING_STATUS=$status
        fi
        return 0
    fi
    if [[ "$RUNTIME_ALLOCATION_CRITICAL" == true ]]; then
        if [[ -z "$RUNTIME_PENDING_SIGNAL" ]]; then
            RUNTIME_PENDING_SIGNAL_STATUS="$status"
            RUNTIME_PENDING_SIGNAL="$signal_name"
        fi
        if [[ -n "$RUNTIME_ALLOCATOR_PID" && -n "$RUNTIME_ALLOCATOR_START" ]] &&
            process_identity_matches "$RUNTIME_ALLOCATOR_PID" "$RUNTIME_ALLOCATOR_START"; then
            kill -CONT "$RUNTIME_ALLOCATOR_PID" 2>/dev/null || true
            kill -TERM "$RUNTIME_ALLOCATOR_PID" 2>/dev/null || true
        fi
        return 0
    fi
    trap - EXIT HUP INT TERM
    echo -e "${YELLOW}${ICON_STOP} 收到 $signal_name，正在终止本次 push 进程树${NC}" >&2
    if ! cleanup_runtime; then
        echo -e "${RED}${ICON_ERROR} $signal_name 清理未完成，已保留残留路径供检查${NC}" >&2
    fi
    exit "$status"
}

install_runtime_traps() {
    [[ "$RUNTIME_TRAPS_INSTALLED" == false ]] || return 0
    trap runtime_exit_handler EXIT
    trap 'runtime_signal_handler HUP 129' HUP
    trap 'runtime_signal_handler INT 130' INT
    trap 'runtime_signal_handler TERM 143' TERM
    RUNTIME_TRAPS_INSTALLED=true
}

prepare_key_credentials() {
    local key_fd="" temp_key="$TEMP_DIR/private-key" metadata="" owner gid mode trusted_gid

    open_trusted_file "$KEY_FILE" private-key key_fd || return 1
    if ! (umask 077; set -o noclobber; : > "$temp_key") 2>/dev/null; then
        exec {key_fd}<&-
        return 1
    fi
    if ! cat <&"$key_fd" > "$temp_key"; then
        exec {key_fd}<&-
        rm -f -- "$temp_key"
        return 1
    fi
    exec {key_fd}<&-
    chmod 0600 "$temp_key" || {
        rm -f -- "$temp_key"
        return 1
    }
    metadata=$(stat -Lc '%u:%g:%a' -- "$temp_key") || return 1
    IFS=: read -r owner gid mode <<< "$metadata"
    trusted_gid=$(current_gid) || return 1
    [[ -f "$temp_key" && ! -L "$temp_key" && "$owner" == "$EUID" && "$gid" == "$trusted_gid" && "$mode" == 600 ]] || return 1
    RUNTIME_KEY_FILE="$temp_key"
}

prepare_password_credentials() {
    local password="" password_fd=""
    case "$PASSWORD_METHOD" in
        file)
            open_trusted_file "$PASSWORD_FILE" password-file password_fd || return 1
            IFS= read -r password <&"$password_fd" || true
            exec {password_fd}<&-
            ;;
        env)
            [[ "$PASSWORD_ENV_VAR" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
            password=${!PASSWORD_ENV_VAR:-}
            ;;
        interactive)
            echo -e "${CYAN}${ICON_LOCK} 请输入 SSH 密码:${NC}"
            read -rs password || return 1
            echo
            ;;
        inline)
            echo -e "${YELLOW}${ICON_WARNING} inline 密码会保留在 Shell 内存中，不推荐使用。${NC}" >&2
            password=${PASSWORD:-}
            ;;
        *) return 1 ;;
    esac
    [[ -n "$password" ]] || {
        echo -e "${RED}${ICON_ERROR} 密码为空${NC}" >&2
        return 1
    }
    export SSHPASS="$password"
}

prepare_credentials() {
    if [[ "$AUTH_METHOD" == key ]]; then
        prepare_key_credentials
    else
        prepare_password_credentials
    fi
}

ensure_secure_directory_chain() {
    local directory="$1" current="$1" ancestor="" item="" index
    local -a missing=()

    [[ "$directory" == /* ]] || return 1
    path_has_symlink_component "$directory" && return 1
    while [[ ! -e "$current" && ! -L "$current" ]]; do
        missing+=("$current")
        ancestor=$(dirname -- "$current") || return 1
        [[ "$ancestor" != "$current" ]] || return 1
        current="$ancestor"
    done
    validate_existing_directory_chain "$current" || {
        echo -e "${RED}${ICON_ERROR} known_hosts 祖先目录不可信: $current${NC}" >&2
        return 1
    }
    for ((index=${#missing[@]} - 1; index >= 0; index--)); do
        item=${missing[$index]}
        if mkdir -m 0700 -- "$item" 2>/dev/null; then
            :
        elif [[ ! -e "$item" && ! -L "$item" ]]; then
            return 1
        fi
        validate_existing_directory_chain "$item" || {
            echo -e "${RED}${ICON_ERROR} known_hosts 新建目录链不可信: $item${NC}" >&2
            return 1
        }
    done
}

known_hosts_path_literal_safe() {
    local path="$1"
    [[ "$path" =~ ^/[A-Za-z0-9_./-]+$ ]] || return 1
    case "$path/" in
        *'//'*) return 1 ;;
        *'/./'*) return 1 ;;
        *'/../'*) return 1 ;;
    esac
}

validate_known_hosts_file() {
    local known_hosts="$USER_KNOWN_HOSTS_FILE" directory="" metadata=""
    local owner gid mode trusted_gid mode_value=0

    if [[ "$known_hosts" == /dev/null ]]; then
        [[ "$ALLOW_INSECURE_HOST_KEY_STORAGE" == true ]]
        return
    fi
    known_hosts_path_literal_safe "$known_hosts" || {
        echo -e "${RED}${ICON_ERROR} known_hosts 路径包含 OpenSSH 会再次解释的字符: $known_hosts${NC}" >&2
        return 1
    }
    directory=$(dirname -- "$known_hosts") || return 1
    validate_existing_directory_chain "$directory" || return 1
    [[ -f "$known_hosts" && ! -L "$known_hosts" ]] || return 1
    metadata=$(stat -Lc '%u:%g:%a' -- "$known_hosts") || return 1
    IFS=: read -r owner gid mode <<< "$metadata"
    trusted_gid=$(current_gid) || return 1
    [[ "$owner" == "$EUID" && "$gid" == "$trusted_gid" && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    mode_value=$((8#$mode))
    (( (mode_value & 0600) == 0600 && (mode_value & 0022) == 0 ))
}

prepare_known_hosts() {
    local known_hosts="$USER_KNOWN_HOSTS_FILE" directory=""

    contains_control_character "$known_hosts" && return 1
    if [[ "$known_hosts" == /dev/null ]]; then
        [[ "$ALLOW_INSECURE_HOST_KEY_STORAGE" == true ]] || return 1
        echo -e "${RED}${ICON_WARNING} known_hosts 使用 /dev/null，无法持久验证指纹，存在 MITM 风险。${NC}" >&2
        return 0
    fi
    known_hosts_path_literal_safe "$known_hosts" || {
        echo -e "${RED}${ICON_ERROR} known_hosts 路径只允许保守的绝对路径字符且禁止 . 或 .. 组件${NC}" >&2
        return 1
    }
    directory=$(dirname -- "$known_hosts") || return 1
    ensure_secure_directory_chain "$directory" || return 1
    if [[ ! -e "$known_hosts" && ! -L "$known_hosts" ]]; then
        if ! (umask 077; set -o noclobber; : > "$known_hosts") 2>/dev/null; then
            [[ -e "$known_hosts" || -L "$known_hosts" ]] || return 1
        fi
    fi
    validate_known_hosts_file || {
        echo -e "${RED}${ICON_ERROR} known_hosts 文件或目录链不可信: $known_hosts${NC}" >&2
        return 1
    }
}

revalidate_known_hosts() {
    validate_known_hosts_file || {
        echo -e "${RED}${ICON_ERROR} SSH 启动前 known_hosts 重新验证失败: $USER_KNOWN_HOSTS_FILE${NC}" >&2
        return 1
    }
}

create_ssh_wrapper() {
    [[ "$RUNTIME_INITIALIZED" == true ]] || return 1
    runtime_directory_trusted || return 1
    [[ ! -e "$SSH_WRAPPER" && ! -L "$SSH_WRAPPER" ]] || return 1
    if ! (umask 077; set -o noclobber; cat > "$SSH_WRAPPER" <<'EOF'
#!/usr/bin/env bash
set -eu
args=(
    -F none
    -p "$PUSH_SSH_PORT"
    -o "ConnectTimeout=$PUSH_CONNECTION_TIMEOUT"
    -o "StrictHostKeyChecking=$PUSH_STRICT_HOST_KEY_CHECKING"
    -o "UserKnownHostsFile=$PUSH_USER_KNOWN_HOSTS_FILE"
    -o LogLevel=ERROR
    -o IdentitiesOnly=yes
    -o IdentityAgent=none
    -o IdentityFile=none
    -o CertificateFile=none
    -o ControlMaster=no
    -o ControlPath=none
    -o ClearAllForwardings=yes
    -o ForkAfterAuthentication=no
)
if [[ "$PUSH_AUTH_METHOD" == key ]]; then
    args+=(
        -o BatchMode=yes
        -o PreferredAuthentications=publickey
        -o PubkeyAuthentication=yes
        -o PasswordAuthentication=no
        -o KbdInteractiveAuthentication=no
        -i "$PUSH_KEY_FILE"
    )
else
    args+=(
        -o BatchMode=no
        -o PreferredAuthentications=password
        -o PubkeyAuthentication=no
        -o PasswordAuthentication=yes
        -o KbdInteractiveAuthentication=no
        -o NumberOfPasswordPrompts=1
    )
fi
exec ssh "${args[@]}" "$@"
EOF
    ) 2>/dev/null; then
        return 1
    fi
    chmod 0700 "$SSH_WRAPPER" || return 1
    [[ -f "$SSH_WRAPPER" && ! -L "$SSH_WRAPPER" && "$(stat -Lc %a -- "$SSH_WRAPPER")" == 700 ]]
}

prepare_ssh_runtime() {
    prepare_known_hosts || return 1
    prepare_credentials || return 1
    create_ssh_wrapper
}

prepare_delete_authorization() {
    [[ "$DELETE_EXTRA" == true ]] || return 0
    [[ "$ALLOW_DELETE_EXTRA" == true ]] && return 0
    if [[ ! -t 0 ]]; then
        echo -e "${RED}${ICON_ERROR} 非交互启用 --delete 必须设置 ALLOW_DELETE_EXTRA=true${NC}" >&2
        return 1
    fi
    local answer=""
    echo -e "${RED}${ICON_WARNING} rsync --delete 会删除远端多余文件。${NC}"
    read -r -p "请输入 DELETE 确认: " answer
    [[ "$answer" == DELETE ]]
}

validate_transfer_path() {
    local value="$1"
    [[ -n "$value" ]] || return 1
    ! contains_control_character "$value"
}


worker_session_state_path_metadata() {
    local file="$1" metadata="" trusted_gid=""
    [[ "$file" == "$TEMP_DIR"/worker-session.*.state ]] || return 1
    [[ ! -L "$file" ]] || return 1
    if [[ ! -e "$file" ]]; then return "$WORKER_SESSION_STATE_TRANSIENT_STATUS"; fi
    [[ -f "$file" ]] || return 1
    metadata=$(stat -Lc '%d:%i:%u:%g:%a:%s' -- "$file" 2>/dev/null) || return "$WORKER_SESSION_STATE_TRANSIENT_STATUS"
    trusted_gid=$(current_gid) || return "$WORKER_SESSION_STATE_TRANSIENT_STATUS"
    IFS=: read -r WORKER_SESSION_PATH_DEV WORKER_SESSION_PATH_INODE WORKER_SESSION_PATH_OWNER \
        WORKER_SESSION_PATH_GID WORKER_SESSION_PATH_MODE WORKER_SESSION_PATH_SIZE <<< "$metadata"
    [[ "$WORKER_SESSION_PATH_OWNER" == "$EUID" && "$WORKER_SESSION_PATH_GID" == "$trusted_gid" &&
        "$WORKER_SESSION_PATH_MODE" == 600 && "$WORKER_SESSION_PATH_SIZE" =~ ^[0-9]+$ ]] || return 1
    [[ -f "$file" && ! -L "$file" ]]
}

worker_session_state_file_trusted() {
    worker_session_state_path_metadata "$1"
}

open_worker_session_state_fd() {
    local file="$1" variable="$2" opened_fd=""
    if ! exec {opened_fd}<"$file"; then return "$WORKER_SESSION_STATE_TRANSIENT_STATUS"; fi
    printf -v "$variable" '%s' "$opened_fd"
}

close_worker_session_state_fd() {
    local fd="$1"
    exec {fd}<&-
}

worker_session_state_fd_metadata() {
    local fd="$1" fd_path="" metadata="" trusted_gid=""
    fd_path=$(fd_reference_path "$fd") || return "$WORKER_SESSION_STATE_TRANSIENT_STATUS"
    [[ -f "$fd_path" ]] || return 1
    metadata=$(stat -Lc '%d:%i:%u:%g:%a:%s' -- "$fd_path" 2>/dev/null) || return "$WORKER_SESSION_STATE_TRANSIENT_STATUS"
    trusted_gid=$(current_gid) || return "$WORKER_SESSION_STATE_TRANSIENT_STATUS"
    IFS=: read -r WORKER_SESSION_FD_DEV WORKER_SESSION_FD_INODE WORKER_SESSION_FD_OWNER \
        WORKER_SESSION_FD_GID WORKER_SESSION_FD_MODE WORKER_SESSION_FD_SIZE <<< "$metadata"
    [[ "$WORKER_SESSION_FD_OWNER" == "$EUID" && "$WORKER_SESSION_FD_GID" == "$trusted_gid" &&
        "$WORKER_SESSION_FD_MODE" == 600 ]]
}

worker_session_state_path_matches() {
    local file="$1" expected_dev="$2" expected_inode="$3" status=0
    worker_session_state_path_metadata "$file" || status=$?
    (( status == 0 )) || return "$status"
    [[ "$WORKER_SESSION_PATH_DEV" == "$expected_dev" && "$WORKER_SESSION_PATH_INODE" == "$expected_inode" ]] ||
        return "$WORKER_SESSION_STATE_TRANSIENT_STATUS"
}

publish_worker_session_state() {
    local lifecycle_state="$1" worker_pid worker_start token stage="" state_file=""
    runtime_directory_trusted || return 1
    worker_pid=$BASHPID
    worker_start=$(get_process_start_time "$worker_pid") || return 1
    state_file="$TEMP_DIR/worker-session.$worker_pid.state"
    token=$(runtime_random_token) || return 1
    stage="$TEMP_DIR/.worker-session.$worker_pid.$token.tmp"
    worker_session_state_publish_hook before-stage-create "$lifecycle_state" "$state_file" "$stage" || return 1
    if ! (umask 077; set -o noclobber; : > "$stage") 2>/dev/null; then return 1; fi
    if ! printf 'version=1\nstate=%s\nworker_pid=%s\nworker_start=%s\nleader_pid=%s\nleader_start=%s\npgid=%s\nsid=%s\n' \
        "$lifecycle_state" "$worker_pid" "$worker_start" "$WORKER_TRANSFER_PID" "$WORKER_TRANSFER_START" \
        "$WORKER_TRANSFER_PGID" "$WORKER_TRANSFER_SID" > "$stage"; then
        rm -f -- "$stage" || true; return 1
    fi
    chmod 0600 "$stage" || { rm -f -- "$stage" || true; return 1; }
    worker_session_state_publish_hook stage-ready "$lifecycle_state" "$state_file" "$stage" || { rm -f -- "$stage" || true; return 1; }
    mv -fT -- "$stage" "$state_file" || { rm -f -- "$stage" || true; return 1; }
    worker_session_state_publish_hook after-rename "$lifecycle_state" "$state_file" "$stage" || return 1
    worker_session_state_file_trusted "$state_file" || return 1
    WORKER_SESSION_STATE_FILE="$state_file"
    worker_session_state_publish_hook state-file-assigned "$lifecycle_state" "$state_file" "$stage" || return 1
}

remove_worker_session_state() {
    local state_file="${WORKER_SESSION_STATE_FILE:-}"
    [[ -n "$state_file" ]] || return 0
    if [[ ! -e "$state_file" && ! -L "$state_file" ]]; then WORKER_SESSION_STATE_FILE=""; return 0; fi
    worker_session_state_file_trusted "$state_file" || return 1
    rm -f -- "$state_file" || return 1
    WORKER_SESSION_STATE_FILE=""
}

parse_worker_session_state_fd() {
    local fd="$1" line="" key="" value=""
    local -a lines=()
    local -A seen=()
    SESSION_STATE=""; SESSION_WORKER_PID=""; SESSION_WORKER_START=""
    SESSION_LEADER_PID=""; SESSION_LEADER_START=""; SESSION_PGID=""; SESSION_SID=""
    mapfile -t -u "$fd" lines || return "$WORKER_SESSION_STATE_TRANSIENT_STATUS"
    (( ${#lines[@]} == 8 )) || return 1
    for line in "${lines[@]}"; do
        [[ "$line" == *=* ]] || return 1
        key=${line%%=*}; value=${line#*=}
        [[ -z "${seen[$key]:-}" ]] || return 1
        seen[$key]=1
        case "$key" in
            version) [[ "$value" == 1 ]] || return 1 ;;
            state) SESSION_STATE=$value ;;
            worker_pid) SESSION_WORKER_PID=$value ;;
            worker_start) SESSION_WORKER_START=$value ;;
            leader_pid) SESSION_LEADER_PID=$value ;;
            leader_start) SESSION_LEADER_START=$value ;;
            pgid) SESSION_PGID=$value ;;
            sid) SESSION_SID=$value ;;
            *) return 1 ;;
        esac
    done
    (( ${#seen[@]} == 8 )) || return 1
    [[ "$SESSION_STATE" == active || "$SESSION_STATE" == cleanup_failed ]] || return 1
    for value in "$SESSION_WORKER_PID" "$SESSION_WORKER_START" "$SESSION_LEADER_PID" \
        "$SESSION_LEADER_START" "$SESSION_PGID" "$SESSION_SID"; do
        [[ "$value" =~ ^[1-9][0-9]*$ ]] || return 1
    done
}

read_worker_session_state() {
    local file="$1" state_fd="" path_status=0 parse_status=0 final_status=0
    local path_dev path_inode fd_dev fd_inode fd_size
    worker_session_state_read_hook before-path "$file" || return "$WORKER_SESSION_STATE_TRANSIENT_STATUS"
    worker_session_state_path_metadata "$file" || path_status=$?
    (( path_status == 0 )) || return "$path_status"
    path_dev=$WORKER_SESSION_PATH_DEV; path_inode=$WORKER_SESSION_PATH_INODE
    worker_session_state_read_hook before-open "$file" || return "$WORKER_SESSION_STATE_TRANSIENT_STATUS"
    open_worker_session_state_fd "$file" state_fd || return $?
    worker_session_state_fd_metadata "$state_fd" || { final_status=$?; close_worker_session_state_fd "$state_fd" || true; return "$final_status"; }
    fd_dev=$WORKER_SESSION_FD_DEV; fd_inode=$WORKER_SESSION_FD_INODE; fd_size=$WORKER_SESSION_FD_SIZE
    if [[ "$fd_dev" != "$path_dev" || "$fd_inode" != "$path_inode" ]]; then
        close_worker_session_state_fd "$state_fd" || true
        return "$WORKER_SESSION_STATE_TRANSIENT_STATUS"
    fi
    worker_session_state_read_hook after-open "$file" "$state_fd" || { close_worker_session_state_fd "$state_fd" || true; return "$WORKER_SESSION_STATE_TRANSIENT_STATUS"; }
    worker_session_state_path_matches "$file" "$fd_dev" "$fd_inode" || { final_status=$?; close_worker_session_state_fd "$state_fd" || true; return "$final_status"; }
    parse_worker_session_state_fd "$state_fd" || parse_status=$?
    worker_session_state_fd_metadata "$state_fd" || { final_status=$?; close_worker_session_state_fd "$state_fd" || true; return "$final_status"; }
    if [[ "$WORKER_SESSION_FD_DEV" != "$fd_dev" || "$WORKER_SESSION_FD_INODE" != "$fd_inode" ||
        "$WORKER_SESSION_FD_SIZE" != "$fd_size" ]]; then
        close_worker_session_state_fd "$state_fd" || true
        return 1
    fi
    worker_session_state_read_hook before-final-path "$file" "$state_fd" || { close_worker_session_state_fd "$state_fd" || true; return "$WORKER_SESSION_STATE_TRANSIENT_STATUS"; }
    worker_session_state_path_matches "$file" "$fd_dev" "$fd_inode" || { final_status=$?; close_worker_session_state_fd "$state_fd" || true; return "$final_status"; }
    close_worker_session_state_fd "$state_fd" || return "$WORKER_SESSION_STATE_TRANSIENT_STATUS"
    (( parse_status == 0 )) || return "$parse_status"
    SESSION_FILE_DEV=$fd_dev; SESSION_FILE_INODE=$fd_inode
}

cleanup_worker_session_state_file() {
    local file="$1" expected_worker_pid="$2" expected_worker_start="$3"
    local attempt status=0 path_status=0 session_dev session_inode
    [[ -e "$file" || -L "$file" ]] || return 0
    for attempt in $(seq 1 "$WORKER_SESSION_STATE_READ_ATTEMPTS"); do
        status=0
        read_worker_session_state "$file" || status=$?
        if (( status == WORKER_SESSION_STATE_TRANSIENT_STATUS )); then
            (( attempt < WORKER_SESSION_STATE_READ_ATTEMPTS )) && { sleep 0.02; continue; }
            echo -e "${RED}${ICON_ERROR} worker session 状态文件在有界重试后仍不稳定: $file${NC}" >&2
            return 1
        elif (( status != 0 )); then
            echo -e "${RED}${ICON_ERROR} worker session 状态文件不可信: $file${NC}" >&2
            return 1
        fi
        [[ "$SESSION_WORKER_PID" == "$expected_worker_pid" && "$SESSION_WORKER_START" == "$expected_worker_start" ]] || return 1
        session_dev=$SESSION_FILE_DEV; session_inode=$SESSION_FILE_INODE
        path_status=0
        worker_session_state_path_matches "$file" "$session_dev" "$session_inode" || path_status=$?
        if (( path_status == WORKER_SESSION_STATE_TRANSIENT_STATUS )); then
            (( attempt < WORKER_SESSION_STATE_READ_ATTEMPTS )) && { sleep 0.02; continue; }
            return 1
        elif (( path_status != 0 )); then return 1; fi
        terminate_managed_session "$SESSION_LEADER_PID" "$SESSION_LEADER_START" "$SESSION_PGID" "$SESSION_SID" || return 1
        path_status=0
        worker_session_state_path_matches "$file" "$session_dev" "$session_inode" || path_status=$?
        if (( path_status == WORKER_SESSION_STATE_TRANSIENT_STATUS )); then
            (( attempt < WORKER_SESSION_STATE_READ_ATTEMPTS )) && { sleep 0.02; continue; }
            return 1
        elif (( path_status != 0 )); then return 1; fi
        rm -f -- "$file" || return 1
        return 0
    done
    return 1
}

collect_owned_session_processes() {
    local expected_sid="$1" members_variable="$2" pgids_variable="$3"
    local stat_file pid pgid existing existing_pgid
    local -n members_ref="$members_variable"
    local -n pgids_ref="$pgids_variable"

    members_ref=()
    pgids_ref=()
    for stat_file in /proc/[0-9]*/stat; do
        [[ -r "$stat_file" ]] || continue
        pid=${stat_file#/proc/}; pid=${pid%/stat}
        read_process_stat "$pid" || continue
        [[ "$PROC_SID" == "$expected_sid" && "$PROC_STATE" != Z ]] || continue
        read_process_uid "$pid" || continue
        if [[ "$PROC_UID" != "$EUID" ]]; then
            echo -e "${RED}${ICON_ERROR} 受管 SID $expected_sid 包含不可信 UID 进程: $pid/$PROC_UID${NC}" >&2
            return 2
        fi
        members_ref+=("$pid")
        pgid=$PROC_PGID
        existing=false
        for existing_pgid in "${pgids_ref[@]}"; do
            [[ "$existing_pgid" == "$pgid" ]] && existing=true
        done
        [[ "$existing" == true ]] || pgids_ref+=("$pgid")
    done
}

owned_session_has_live_members() {
    local expected_sid="$1"
    local -a members=() pgids=()
    collect_owned_session_processes "$expected_sid" members pgids || return 2
    (( ${#members[@]} > 0 ))
}

managed_leader_identity_trusted() {
    local leader_pid="$1" leader_start="$2" expected_pgid="$3" expected_sid="$4" record_status=0
    [[ -e "/proc/$leader_pid" ]] || return 0
    read_process_record_for_session_scan "$leader_pid" || record_status=$?
    (( record_status == 2 )) && return 0
    (( record_status == 0 )) || return 1
    # 相同 PID 但 start 不同表示 PID 已复用；原 leader 已消失，绝不触碰新进程。
    [[ "$PROC_START" == "$leader_start" ]] || return "$MANAGED_PROCESS_REUSED_STATUS"
    [[ "$PROC_UID" == "$EUID" && "$PROC_PGID" == "$expected_pgid" && "$PROC_SID" == "$expected_sid" ]]
}

read_process_stat_for_session_scan() {
    local pid="$1" _
    for _ in {1..3}; do
        read_process_stat "$pid" && return 0
        [[ -e "/proc/$pid" ]] || return 2
        sleep 0.005
    done
    return 1
}

read_process_uid_for_session_scan() {
    local pid="$1" _
    for _ in {1..3}; do
        read_process_uid "$pid" && return 0
        [[ -e "/proc/$pid" ]] || return 2
        sleep 0.005
    done
    return 1
}

read_process_record_for_session_scan() {
    local pid="$1" _
    for _ in {1..3}; do
        read_process_record "$pid" && return 0
        [[ -e "/proc/$pid" ]] || return 2
        sleep 0.005
    done
    return 1
}

# shellcheck disable=SC2034,SC2178  # Output arrays are populated through namerefs for callers.
collect_owned_session_records() {
    local expected_sid="$1" pids_variable="$2" starts_variable="$3" ppids_variable="$4"
    local pgids_variable="$5" states_variable="$6" stat_file pid record_status=0
    local -n pids_ref="$pids_variable" starts_ref="$starts_variable" ppids_ref="$ppids_variable"
    local -n pgids_ref="$pgids_variable" states_ref="$states_variable"
    pids_ref=(); starts_ref=(); ppids_ref=(); pgids_ref=(); states_ref=()
    for stat_file in /proc/[0-9]*/stat; do
        [[ -r "$stat_file" ]] || continue
        pid=${stat_file#/proc/}; pid=${pid%/stat}
        record_status=0
        read_process_stat_for_session_scan "$pid" || record_status=$?
        (( record_status == 2 )) && continue
        (( record_status == 0 )) || return 1
        [[ "$PROC_SID" == "$expected_sid" ]] || continue
        record_status=0
        read_process_uid_for_session_scan "$pid" || record_status=$?
        (( record_status == 2 )) && continue
        (( record_status == 0 )) || return 1
        [[ "$PROC_UID" == "$EUID" ]] || {
            echo -e "${RED}${ICON_ERROR} 受管 SID $expected_sid 包含不可信 UID 进程: $pid/$PROC_UID${NC}" >&2
            return 2
        }
        pids_ref+=("$pid")
        starts_ref[$pid]=$PROC_START
        ppids_ref[$pid]=$PROC_PPID
        pgids_ref[$pid]=$PROC_PGID
        states_ref[$pid]=$PROC_STATE
    done
}

session_process_identity_matches() {
    local pid="$1" expected_start="$2" expected_sid="$3"
    read_process_record "$pid" || return 1
    [[ "$PROC_UID" == "$EUID" && "$PROC_START" == "$expected_start" && "$PROC_SID" == "$expected_sid" ]]
}

wait_for_session_process_reap() {
    local pid="$1" expected_start="$2" expected_sid="$3" _
    for _ in {1..30}; do
        session_process_identity_matches "$pid" "$expected_start" "$expected_sid" || return 0
        sleep 0.01
    done
    return 1
}

terminate_owned_session_leaf_first() {
    local expected_sid="$1" leader_pid="$2" leader_start="$3" allow_leader_zombie="$4"
    local cleanup_pass pid parent pgid state total leaves_for_group
    local -a pids=() leaves=()
    local -A starts=() ppids=() pgids=() states=() has_child=() group_total=() group_leaves=() group_signaled=()

    for ((cleanup_pass=1; cleanup_pass<=16; cleanup_pass++)); do
        collect_owned_session_records "$expected_sid" pids starts ppids pgids states || return 1
        (( ${#pids[@]} > 0 )) || return 0
        has_child=(); group_total=(); group_leaves=(); group_signaled=(); leaves=()
        for pid in "${pids[@]}"; do
            parent=${ppids[$pid]}
            [[ -z "${starts[$parent]:-}" ]] || has_child[$parent]=1
            pgid=${pgids[$pid]}; group_total[$pgid]=$(( ${group_total[$pgid]:-0} + 1 ))
        done
        for pid in "${pids[@]}"; do
            [[ -z "${has_child[$pid]:-}" ]] || continue
            leaves+=("$pid"); pgid=${pgids[$pid]}; group_leaves[$pgid]=$(( ${group_leaves[$pgid]:-0} + 1 ))
        done
        (( ${#leaves[@]} > 0 )) || return 1

        for pid in "${leaves[@]}"; do
            session_process_identity_matches "$pid" "${starts[$pid]}" "$expected_sid" || continue
            [[ "$PROC_STATE" == Z ]] && continue
            pgid=${pgids[$pid]}; total=${group_total[$pgid]}; leaves_for_group=${group_leaves[$pgid]}
            if (( total == leaves_for_group )) && [[ -z "${group_signaled[$pgid]:-}" ]]; then
                kill -CONT -- "-$pgid" 2>/dev/null || true
                kill -TERM -- "-$pgid" 2>/dev/null || true
                group_signaled[$pgid]=1
            elif (( total != leaves_for_group )); then
                kill -CONT "$pid" 2>/dev/null || true
                kill -TERM "$pid" 2>/dev/null || true
            fi
        done
        if (( cleanup_pass == 1 )); then sleep 2; else sleep 0.2; fi

        for pid in "${leaves[@]}"; do
            session_process_identity_matches "$pid" "${starts[$pid]}" "$expected_sid" || continue
            state=$PROC_STATE
            if [[ "$state" != Z ]]; then
                kill -CONT "$pid" 2>/dev/null || true
                kill -KILL "$pid" 2>/dev/null || true
            fi
            if ! wait_for_session_process_reap "$pid" "${starts[$pid]}" "$expected_sid"; then
                if session_process_identity_matches "$pid" "${starts[$pid]}" "$expected_sid" &&
                    [[ "$allow_leader_zombie" == true && "$pid" == "$leader_pid" && "$PROC_STATE" == Z ]]; then
                    continue
                fi
                echo -e "${RED}${ICON_ERROR} 受管 SID $expected_sid 无法确认叶进程已回收: $pid/${PROC_STATE:-unknown}${NC}" >&2
                return 1
            fi
        done
    done

    collect_owned_session_records "$expected_sid" pids starts ppids pgids states || return 1
    for pid in "${pids[@]}"; do
        if [[ "$allow_leader_zombie" == true && "$pid" == "$leader_pid" &&
            "${starts[$pid]}" == "$leader_start" && "${states[$pid]}" == Z ]]; then
            continue
        fi
        echo -e "${RED}${ICON_ERROR} 受管 SID $expected_sid 清理后仍有 PID: $pid/${states[$pid]}${NC}" >&2
        return 1
    done
}

owned_session_fully_reaped() {
    local expected_sid="$1" pid
    local -a pids=()
    local -A starts=() ppids=() pgids=() states=()
    collect_owned_session_records "$expected_sid" pids starts ppids pgids states || return 1
    for pid in "${pids[@]}"; do
        echo -e "${RED}${ICON_ERROR} 受管 SID $expected_sid wait 后仍有 PID: $pid/${states[$pid]}${NC}" >&2
        return 1
    done
}

terminate_managed_session() {
    local leader_pid="$1" leader_start="$2" expected_pgid="$3" expected_sid="$4"
    local allow_leader_zombie="${5:-false}" current_sid="" leader_status=0

    [[ "$leader_pid" =~ ^[1-9][0-9]*$ && "$leader_start" =~ ^[1-9][0-9]*$ &&
        "$expected_pgid" =~ ^[1-9][0-9]*$ && "$expected_sid" =~ ^[1-9][0-9]*$ ]] || return 1
    read_process_record "$$" || return 1
    current_sid=$PROC_SID
    [[ "$expected_sid" != "$current_sid" ]] || return 1
    managed_leader_identity_trusted "$leader_pid" "$leader_start" "$expected_pgid" "$expected_sid" || leader_status=$?
    if (( leader_status == MANAGED_PROCESS_REUSED_STATUS )); then return 0; fi
    if (( leader_status != 0 )); then
        echo -e "${RED}${ICON_ERROR} 受管 session leader 身份不可信: $leader_pid${NC}" >&2
        return 1
    fi
    terminate_owned_session_leaf_first "$expected_sid" "$leader_pid" "$leader_start" "$allow_leader_zombie"
}

worker_transfer_identity_matches() {
    [[ -n "$WORKER_TRANSFER_PID" && -n "$WORKER_TRANSFER_START" ]] || return 1
    read_process_record "$WORKER_TRANSFER_PID" || return 1
    [[ "$PROC_UID" == "$EUID" && "$PROC_START" == "$WORKER_TRANSFER_START" &&
        "$PROC_PGID" == "$WORKER_TRANSFER_PGID" && "$PROC_SID" == "$WORKER_TRANSFER_SID" &&
        "$PROC_PGID" == "$WORKER_TRANSFER_PID" && "$PROC_SID" == "$WORKER_TRANSFER_PID" ]]
}

worker_after_session_cleanup_hook() {
    :
}

terminate_worker_transfer() {
    local cleanup_failed=false had_session=false

    if [[ -n "$WORKER_TRANSFER_PID" || -n "$WORKER_TRANSFER_PGID" ||
        -n "$WORKER_TRANSFER_SID" || -n "$WORKER_TRANSFER_START" ]]; then
        had_session=true
        if [[ -z "$WORKER_TRANSFER_PID" || -z "$WORKER_TRANSFER_PGID" ||
            -z "$WORKER_TRANSFER_SID" || -z "$WORKER_TRANSFER_START" ]] ||
            ! terminate_managed_session "$WORKER_TRANSFER_PID" "$WORKER_TRANSFER_START" \
                "$WORKER_TRANSFER_PGID" "$WORKER_TRANSFER_SID" true; then
            cleanup_failed=true
        fi
    fi
    [[ -z "$WORKER_TRANSFER_PID" ]] || wait "$WORKER_TRANSFER_PID" 2>/dev/null || true
    if [[ "$cleanup_failed" == false && "$had_session" == true && "$WORKER_SIGNAL_CLEANUP_ACTIVE" == true ]] &&
        ! owned_session_fully_reaped "$WORKER_TRANSFER_SID"; then
        cleanup_failed=true
    fi
    if [[ "$cleanup_failed" == false && "$had_session" == true ]] && ! worker_after_session_cleanup_hook; then
        cleanup_failed=true
    fi
    if [[ "$cleanup_failed" == false ]] && ! remove_worker_session_state; then
        echo -e "${RED}${ICON_ERROR} managed session 已结束但状态文件删除失败: $WORKER_SESSION_STATE_FILE${NC}" >&2
        cleanup_failed=true
    fi
    if [[ "$cleanup_failed" == true ]]; then
        WORKER_TRANSFER_CLEANUP_FAILED=true
        [[ -z "$WORKER_SESSION_STATE_FILE" ]] || publish_worker_session_state cleanup_failed || true
        return 1
    fi
    WORKER_TRANSFER_PID=""
    WORKER_TRANSFER_PGID=""
    WORKER_TRANSFER_SID=""
    WORKER_TRANSFER_START=""
    WORKER_TRANSFER_CLEANUP_FAILED=false
    WORKER_SESSION_STATE_FILE=""
    return 0
}

worker_signal_handler() {
    local status="$1"
    trap - EXIT HUP INT TERM
    WORKER_SIGNAL_CLEANUP_ACTIVE=true
    terminate_worker_transfer
    [[ -z "$WORKER_OUTPUT_FILE" ]] || rm -f -- "$WORKER_OUTPUT_FILE" 2>/dev/null || true
    exit "$status"
}

worker_exit_handler() {
    local status="$?"
    trap - EXIT
    if ! terminate_worker_transfer && (( status == 0 )); then
        status=$MANAGED_CLEANUP_FAILURE_STATUS
    fi
    [[ -z "$WORKER_OUTPUT_FILE" ]] || rm -f -- "$WORKER_OUTPUT_FILE" 2>/dev/null || true
    exit "$status"
}

clear_unpublished_exited_session() {
    local -a members=() pgids=()
    [[ -z "$WORKER_SESSION_STATE_FILE" && -n "$WORKER_TRANSFER_SID" ]] || return 1
    collect_owned_session_processes "$WORKER_TRANSFER_SID" members pgids || return 1
    if (( ${#members[@]} > 0 )); then
        echo -e "${RED}${ICON_ERROR} 未发布身份的已退出 session 仍有活动成员: ${members[*]}${NC}" >&2
        WORKER_TRANSFER_CLEANUP_FAILED=true
        return 1
    fi
    WORKER_TRANSFER_PID=""
    WORKER_TRANSFER_PGID=""
    WORKER_TRANSFER_SID=""
    WORKER_TRANSFER_START=""
    WORKER_TRANSFER_CLEANUP_FAILED=false
}

run_managed_command() {
    local output_file="$1"
    shift
    local -a command=("$@")
    local exit_code=0 pgid="" sid="" timeout_ticks=0 tick=0

    if [[ "$WORKER_TRANSFER_CLEANUP_FAILED" == true ||
        -n "$WORKER_TRANSFER_PID" || -n "$WORKER_TRANSFER_PGID" ||
        -n "$WORKER_TRANSFER_SID" || -n "$WORKER_TRANSFER_START" ||
        -n "$WORKER_SESSION_STATE_FILE" ]]; then
        echo -e "${RED}${ICON_ERROR} 上一次 managed session 生命周期尚未清理，拒绝启动新命令${NC}" >&2
        return "$MANAGED_CLEANUP_FAILURE_STATUS"
    fi
    WORKER_OUTPUT_FILE="$output_file"
    if ! (umask 077; set -o noclobber; : > "$output_file") 2>/dev/null; then
        return 1
    fi
    setsid "${command[@]}" > "$output_file" 2>&1 &
    WORKER_TRANSFER_PID=$!
    WORKER_TRANSFER_PGID="$WORKER_TRANSFER_PID"
    WORKER_TRANSFER_SID="$WORKER_TRANSFER_PID"
    for _ in {1..50}; do
        WORKER_TRANSFER_START=$(get_process_start_time "$WORKER_TRANSFER_PID" 2>/dev/null || true)
        pgid=$(get_process_group_id "$WORKER_TRANSFER_PID" 2>/dev/null || true)
        sid=$(get_process_session_id "$WORKER_TRANSFER_PID" 2>/dev/null || true)
        [[ -n "$WORKER_TRANSFER_START" && "$pgid" == "$WORKER_TRANSFER_PID" && "$sid" == "$WORKER_TRANSFER_PID" ]] && break
        kill -0 "$WORKER_TRANSFER_PID" 2>/dev/null || break
        sleep 0.01
    done
    if [[ -z "$WORKER_TRANSFER_START" || "$pgid" != "$WORKER_TRANSFER_PID" || "$sid" != "$WORKER_TRANSFER_PID" ]]; then
        if ! job_is_active "$WORKER_TRANSFER_PID"; then
            if wait "$WORKER_TRANSFER_PID"; then exit_code=0; else exit_code=$?; fi
            clear_unpublished_exited_session || return "$MANAGED_CLEANUP_FAILURE_STATUS"
            return "$exit_code"
        fi
        if ! terminate_worker_transfer; then
            return "$MANAGED_CLEANUP_FAILURE_STATUS"
        fi
        return 1
    fi
    if ! publish_worker_session_state active; then
        echo -e "${RED}${ICON_ERROR} 无法发布 managed session 状态${NC}" >&2
        if ! terminate_worker_transfer; then
            return "$MANAGED_CLEANUP_FAILURE_STATUS"
        fi
        return 1
    fi
    timeout_ticks=$(( (TOTAL_TIMEOUT + TIMEOUT_KILL_AFTER) * 20 ))
    for ((tick=0; tick<timeout_ticks; tick++)); do
        job_is_active "$WORKER_TRANSFER_PID" || break
        sleep 0.05
    done
    if job_is_active "$WORKER_TRANSFER_PID"; then
        if ! terminate_worker_transfer; then
            return "$MANAGED_CLEANUP_FAILURE_STATUS"
        fi
        return 124
    fi
    if wait "$WORKER_TRANSFER_PID"; then exit_code=0; else exit_code=$?; fi
    terminate_worker_transfer || return "$MANAGED_CLEANUP_FAILURE_STATUS"
    return "$exit_code"
}

run_transfer_command() {
    run_managed_command "$@"
}

retry_rsync() {
    local server_info="$1" src="$2" dst="$3"
    local attempt=1 port target output_file output="" exit_code=0
    local -a rsync_opts command

    validate_transfer_path "$src" && validate_transfer_path "$dst" || return 1
    parse_server_info "$server_info" || return 1
    port="$PARSED_PORT"
    target="$PARSED_RSYNC_TARGET"
    rsync_opts=(--protect-args "--timeout=$CONNECTION_TIMEOUT")
    [[ "$RSYNC_ARCHIVE" == true ]] && rsync_opts+=(-a) || rsync_opts+=(-r)
    [[ "$RSYNC_COMPRESS" == true ]] && rsync_opts+=(-z)
    [[ "$DELETE_EXTRA" == true ]] && rsync_opts+=(--delete)

    export PUSH_CONNECTION_TIMEOUT="$CONNECTION_TIMEOUT"
    export PUSH_STRICT_HOST_KEY_CHECKING="$STRICT_HOST_KEY_CHECKING"
    export PUSH_USER_KNOWN_HOSTS_FILE="$USER_KNOWN_HOSTS_FILE"
    export PUSH_AUTH_METHOD="$AUTH_METHOD"
    export PUSH_KEY_FILE="$RUNTIME_KEY_FILE"

    while (( attempt <= MAX_RETRIES )); do
        (( attempt > 1 )) && sleep "$RETRY_DELAY"
        export PUSH_SSH_PORT="$port"
        revalidate_known_hosts || return 1
        command=(timeout "$TOTAL_TIMEOUT")
        [[ "$AUTH_METHOD" == password ]] && command+=(sshpass -e)
        command+=(rsync "${rsync_opts[@]}" -e "$SSH_WRAPPER" -- "$src" "$target:$dst")
        output_file="$TEMP_DIR/transfer.$BASHPID.$attempt"
        if run_transfer_command "$output_file" "${command[@]}"; then
            exit_code=0
        else
            exit_code=$?
        fi
        output=$(<"$output_file")
        rm -f -- "$output_file" || true
        WORKER_OUTPUT_FILE=""
        case "$exit_code" in
            0) return 0 ;;
            "$MANAGED_CLEANUP_FAILURE_STATUS")
                echo -e "${RED}${ICON_ERROR} managed session 清理失败，停止 rsync 重试${NC}" >&2
                return "$MANAGED_CLEANUP_FAILURE_STATUS"
                ;;
            23|24)
                [[ -n "$output" ]] && echo -e "${RED}    $output${NC}" >&2
                return 1
                ;;
            124|255) ;;
            *) ;;
        esac
        ((attempt += 1))
    done
    return 1
}

append_result_record() {
    local file="$1" server="$2"
    printf '%s\n' "$server" >> "$file"
}

close_result_lock_fd() {
    local lock_fd="$1"
    exec {lock_fd}>&-
}

record_result() {
    local result="$1" server="$2" file="" lock_file="" lock_fd=""

    if [[ "$result" == success ]]; then
        file="$SUCCESS_FILE"
        lock_file="$SUCCESS_FILE.lock"
    else
        file="$FAILED_FILE"
        lock_file="$FAILED_FILE.lock"
    fi
    if ! exec {lock_fd}>>"$lock_file"; then
        echo -e "${RED}${ICON_ERROR} 无法打开结果锁文件: $lock_file${NC}" >&2
        return 1
    fi
    if ! flock -x "$lock_fd"; then
        echo -e "${RED}${ICON_ERROR} 无法锁定结果文件: $lock_file${NC}" >&2
        close_result_lock_fd "$lock_fd" || true
        return 1
    fi
    if ! append_result_record "$file" "$server"; then
        echo -e "${RED}${ICON_ERROR} 无法记录 $result 结果: $file${NC}" >&2
        close_result_lock_fd "$lock_fd" || true
        return 1
    fi
    if ! close_result_lock_fd "$lock_fd"; then
        echo -e "${RED}${ICON_ERROR} 无法关闭结果锁 fd: $lock_file${NC}" >&2
        return 1
    fi
}

push_to_server() {
    local server_info="$1" src="$2" dst="$3" index="$4" total="$5" display="" transfer_status=0
    trap 'worker_signal_handler 129' HUP
    trap 'worker_signal_handler 130' INT
    trap 'worker_signal_handler 143' TERM
    trap worker_exit_handler EXIT
    display=$(format_server_info "$server_info") || return 1
    echo -e "${BLUE}[${index}/${total}]${NC} ${ICON_WORKING} ${CYAN}$display${NC}"
    retry_rsync "$server_info" "$src" "$dst" || transfer_status=$?
    if (( transfer_status == MANAGED_CLEANUP_FAILURE_STATUS )); then
        echo -e "${RED}${ICON_ERROR} $display managed session 清理失败${NC}" >&2
        return "$MANAGED_CLEANUP_FAILURE_STATUS"
    fi
    if (( transfer_status == 0 )); then
        if ! record_result success "$server_info"; then
            echo -e "${RED}${ICON_ERROR} $display 传输成功但结果记录失败${NC}" >&2
            return 1
        fi
        echo -e "${GREEN}[${index}/${total}] ${ICON_SUCCESS} $display${NC}"
    else
        if ! record_result failed "$server_info"; then
            echo -e "${RED}${ICON_ERROR} $display 传输失败且结果记录失败${NC}" >&2
            return 1
        fi
        echo -e "${RED}[${index}/${total}] ${ICON_ERROR} $display${NC}"
    fi
    return 0
}

abort_worker_registration() {
    local pid="$1" was_active="${2:-false}" failed=false
    terminate_registering_worker_job "$pid" || failed=true
    cleanup_worker_registration_for_pid "$pid" || failed=true
    unset 'REGISTERING_WORKERS[$pid]'
    if [[ "$was_active" == true ]]; then
        unset 'ACTIVE_WORKERS[$pid]'
        if [[ -n "${ACTIVE_WORKER_STATE_FILES[$pid]:-}" &&
            ! -e "${ACTIVE_WORKER_STATE_FILES[$pid]}" && ! -L "${ACTIVE_WORKER_STATE_FILES[$pid]}" ]]; then
            unset 'ACTIVE_WORKER_STATE_FILES[$pid]' 'ACTIVE_WORKER_STATE_STARTS[$pid]'
        fi
    fi
    [[ "$failed" == false ]]
}

launch_worker() {
    local server="$1" src="$2" dst="$3" index="$4" total="$5"
    local parent_pid=$BASHPID parent_start="" pid ready release ready_dev ready_inode _ wait_status=0
    read_process_record "$parent_pid" || return "$MANAGED_CLEANUP_FAILURE_STATUS"
    [[ "$PROC_UID" == "$EUID" && "$PROC_STATE" != Z ]] || return "$MANAGED_CLEANUP_FAILURE_STATUS"
    parent_start=$PROC_START
    worker_registration_begin_critical || return "$MANAGED_CLEANUP_FAILURE_STATUS"
    registered_worker_entry "$parent_pid" "$parent_start" "$server" "$src" "$dst" "$index" "$total" &
    pid=$!
    ready="$TEMP_DIR/worker-registration.$pid.ready"
    release="$TEMP_DIR/worker-registration.$pid.release"
    REGISTERING_WORKERS[$pid]=direct
    WORKER_REGISTRATION_READY_FILES[$pid]=$ready
    WORKER_REGISTRATION_RELEASE_FILES[$pid]=$release
    worker_registration_end_critical
    parent_worker_registration_hook registering-created "$pid" "$ready" "$release" || {
        abort_worker_registration "$pid" false || return "$MANAGED_CLEANUP_FAILURE_STATUS"; return 1; }
    for _ in $(seq 1 "$WORKER_REGISTRATION_TIMEOUT_TICKS"); do
        if [[ -e "$ready" || -L "$ready" ]]; then
            parent_worker_registration_hook ready-observed "$pid" "$ready" "$release" || {
                abort_worker_registration "$pid" false || return "$MANAGED_CLEANUP_FAILURE_STATUS"; return 1; }
            if ! read_worker_registration_manifest "$ready" ready ||
                [[ "$REGISTRATION_WORKER_PID" != "$pid" || "$REGISTRATION_PARENT_PID" != "$parent_pid" ||
                    "$REGISTRATION_PARENT_START" != "$parent_start" ]] ||
                ! job_is_active "$pid" || ! process_identity_matches "$pid" "$REGISTRATION_WORKER_START"; then
                echo -e "${RED}${ICON_ERROR} worker registration ready 不可信: $pid${NC}" >&2
                abort_worker_registration "$pid" false || return "$MANAGED_CLEANUP_FAILURE_STATUS"
                return 1
            fi
            ready_dev=$REGISTRATION_FILE_DEV; ready_inode=$REGISTRATION_FILE_INODE
            ACTIVE_WORKERS[$pid]=$REGISTRATION_WORKER_START
            ACTIVE_WORKER_STATE_FILES[$pid]="$TEMP_DIR/worker-session.$pid.state"
            ACTIVE_WORKER_STATE_STARTS[$pid]=$REGISTRATION_WORKER_START
            WORKER_REGISTRATION_STARTS[$pid]=$REGISTRATION_WORKER_START
            unset 'REGISTERING_WORKERS[$pid]'
            parent_worker_registration_hook accepted-before-release "$pid" "$ready" "$release" || {
                abort_worker_registration "$pid" true || return "$MANAGED_CLEANUP_FAILURE_STATUS"; return 1; }
            if ! publish_worker_registration_release "$pid" "$REGISTRATION_WORKER_START" "$parent_pid" "$parent_start" "$ready_dev" "$ready_inode"; then
                echo -e "${RED}${ICON_ERROR} worker registration release 发布失败: $pid${NC}" >&2
                abort_worker_registration "$pid" true || return "$MANAGED_CLEANUP_FAILURE_STATUS"
                return 1
            fi
            parent_worker_registration_hook release-published "$pid" "$ready" "$release" || {
                abort_worker_registration "$pid" true || return "$MANAGED_CLEANUP_FAILURE_STATUS"; return 1; }
            return 0
        fi
        if ! job_is_active "$pid"; then
            wait_status=0; wait "$pid" 2>/dev/null || wait_status=$?
            record_worker_wait_status "$wait_status"
            cleanup_worker_registration_for_pid "$pid" || return "$MANAGED_CLEANUP_FAILURE_STATUS"
            unset 'REGISTERING_WORKERS[$pid]'
            (( wait_status == 0 )) && return 1
            return "$wait_status"
        fi
        sleep 0.05
    done
    echo -e "${RED}${ICON_ERROR} worker registration ready 超时: $pid${NC}" >&2
    abort_worker_registration "$pid" false || return "$MANAGED_CLEANUP_FAILURE_STATUS"
    return 1
}

wait_for_worker_slot() {
    local wait_status=0
    while :; do
        prune_active_workers || return "$MANAGED_CLEANUP_FAILURE_STATUS"
        if batch_schedule_barrier_present; then
            return "$MANAGED_CLEANUP_FAILURE_STATUS"
        fi
        (( ${#ACTIVE_WORKERS[@]} < MAX_PARALLEL )) && return 0

        wait_status=0
        wait -n 2>/dev/null || wait_status=$?
        record_worker_wait_status "$wait_status"
        if [[ "$BATCH_WORKER_FAILED" == true ]]; then
            return "$MANAGED_CLEANUP_FAILURE_STATUS"
        fi

        prune_active_workers || return "$MANAGED_CLEANUP_FAILURE_STATUS"
        if batch_schedule_barrier_present; then
            return "$MANAGED_CLEANUP_FAILURE_STATUS"
        fi
    done
}

wait_for_all_workers() {
    local wait_status=0
    while :; do
        prune_active_workers || return "$MANAGED_CLEANUP_FAILURE_STATUS"
        if batch_schedule_barrier_present; then
            return "$MANAGED_CLEANUP_FAILURE_STATUS"
        fi
        (( ${#ACTIVE_WORKERS[@]} == 0 )) && return 0

        wait_status=0
        wait -n 2>/dev/null || wait_status=$?
        record_worker_wait_status "$wait_status"
        if [[ "$BATCH_WORKER_FAILED" == true ]]; then
            return "$MANAGED_CLEANUP_FAILURE_STATUS"
        fi

        prune_active_workers || return "$MANAGED_CLEANUP_FAILURE_STATUS"
        if batch_schedule_barrier_present; then
            return "$MANAGED_CLEANUP_FAILURE_STATUS"
        fi
    done
}

result_line_count() {
    local file="$1"
    [[ -f "$file" ]] || { printf '0\n'; return 0; }
    wc -l < "$file"
}

stop_batch_after_lifecycle_failure() {
    BATCH_WORKER_FAILED=true
    if ! terminate_active_workers; then
        echo -e "${RED}${ICON_ERROR} batch lifecycle 清理未完成，已保留 runtime 与状态文件${NC}" >&2
    fi
    return "$MANAGED_CLEANUP_FAILURE_STATUS"
}

run_server_batch() {
    local src="$1" dst="$2"
    shift 2
    local -a servers=("$@")
    local index=0 total=${#servers[@]} server wait_status=0
    local success_before failed_before success_after failed_after recorded

    if [[ "$BATCH_WORKER_FAILED" == true || ${#ACTIVE_WORKERS[@]} -ne 0 ||
        ${#ACTIVE_WORKER_STATE_FILES[@]} -ne 0 || ${#ACTIVE_WORKER_STATE_STARTS[@]} -ne 0 ||
        ${#REGISTERING_WORKERS[@]} -ne 0 || ${#WORKER_REGISTRATION_READY_FILES[@]} -ne 0 ||
        ${#WORKER_REGISTRATION_RELEASE_FILES[@]} -ne 0 || ${#WORKER_REGISTRATION_STARTS[@]} -ne 0 ]] ||
        runtime_has_published_worker_state || runtime_has_worker_registration_state; then
        echo -e "${RED}${ICON_ERROR} 旧 batch lifecycle barrier 尚未安全 reset${NC}" >&2
        return "$MANAGED_CLEANUP_FAILURE_STATUS"
    fi

    BATCH_WORKER_ERROR=false
    success_before=$(result_line_count "$SUCCESS_FILE") || return 1
    failed_before=$(result_line_count "$FAILED_FILE") || return 1
    for server in "${servers[@]}"; do
        ((index += 1))
        wait_status=0
        wait_for_worker_slot || wait_status=$?
        if (( wait_status == MANAGED_CLEANUP_FAILURE_STATUS )); then
            stop_batch_after_lifecycle_failure
            return "$MANAGED_CLEANUP_FAILURE_STATUS"
        elif (( wait_status != 0 )); then
            return "$wait_status"
        fi

        if batch_schedule_barrier_present; then
            stop_batch_after_lifecycle_failure
            return "$MANAGED_CLEANUP_FAILURE_STATUS"
        fi
        wait_status=0
        launch_worker "$server" "$src" "$dst" "$index" "$total" || wait_status=$?
        if (( wait_status != 0 )); then
            (( wait_status == MANAGED_CLEANUP_FAILURE_STATUS )) && BATCH_WORKER_FAILED=true || BATCH_WORKER_ERROR=true
            terminate_active_workers || return "$MANAGED_CLEANUP_FAILURE_STATUS"
            return "$wait_status"
        fi
        if ! prune_active_workers || batch_schedule_barrier_present; then
            stop_batch_after_lifecycle_failure
            return "$MANAGED_CLEANUP_FAILURE_STATUS"
        fi
    done

    wait_status=0
    wait_for_all_workers || wait_status=$?
    if (( wait_status == MANAGED_CLEANUP_FAILURE_STATUS )); then
        stop_batch_after_lifecycle_failure
        return "$MANAGED_CLEANUP_FAILURE_STATUS"
    elif (( wait_status != 0 )); then
        return "$wait_status"
    fi

    success_after=$(result_line_count "$SUCCESS_FILE") || return 1
    failed_after=$(result_line_count "$FAILED_FILE") || return 1
    recorded=$((success_after - success_before + failed_after - failed_before))
    if [[ "$BATCH_WORKER_FAILED" == true ]]; then
        stop_batch_after_lifecycle_failure
        return "$MANAGED_CLEANUP_FAILURE_STATUS"
    fi
    if [[ "$BATCH_WORKER_ERROR" == true || "$recorded" -ne "$total" ]]; then
        echo -e "${RED}${ICON_ERROR} batch accounting 不完整: expected=$total recorded=$recorded${NC}" >&2
        return 1
    fi
}

show_summary() {
    local total=${#SERVERS[@]} success=0 failed=0
    [[ -f "$SUCCESS_FILE" ]] && success=$(wc -l < "$SUCCESS_FILE")
    [[ -f "$FAILED_FILE" ]] && failed=$(wc -l < "$FAILED_FILE")
    echo -e "${GREEN}成功: $success/$total${NC}  ${RED}失败: $failed/$total${NC}"
}

interactive_retry() {
    local src="$1" dst="$2" failed=0 response="" server
    local -a failed_servers=()
    [[ -f "$FAILED_FILE" ]] && failed=$(wc -l < "$FAILED_FILE")
    (( failed > 0 )) || return 0
    [[ -t 0 ]] || return 0
    read -r -t 30 -p "重试失败服务器？[y/N]: " response || return 0
    [[ "$response" =~ ^[Yy]$ ]] || return 0
    while IFS= read -r server; do
        [[ -n "$server" ]] && failed_servers+=("$server")
    done < "$FAILED_FILE"
    if ! : > "$FAILED_FILE"; then
        echo -e "${RED}${ICON_ERROR} 无法截断失败结果文件: $FAILED_FILE${NC}" >&2
        return 1
    fi
    if [[ -e "$FAILED_FILE.lock" || -L "$FAILED_FILE.lock" ]]; then
        rm -f -- "$FAILED_FILE.lock" || {
            echo -e "${RED}${ICON_ERROR} 无法清理失败结果锁: $FAILED_FILE.lock${NC}" >&2
            return 1
        }
    fi
    run_server_batch "$src" "$dst" "${failed_servers[@]}"
}

test_authentication() {
    local server port target display status=0 output_file="" output="" exit_code=0 index=0
    local -a command

    echo -e "${CYAN}${ICON_CONFIG} 对全部配置服务器执行无副作用 SSH true 认证测试${NC}"
    for server in "${SERVERS[@]}"; do
        ((index += 1))
        if ! parse_server_info "$server"; then
            status=1
            continue
        fi
        port="$PARSED_PORT"
        target="$PARSED_SSH_TARGET"
        display="$PARSED_DISPLAY_TARGET"
        export PUSH_SSH_PORT="$port"
        export PUSH_CONNECTION_TIMEOUT="$CONNECTION_TIMEOUT"
        export PUSH_STRICT_HOST_KEY_CHECKING="$STRICT_HOST_KEY_CHECKING"
        export PUSH_USER_KNOWN_HOSTS_FILE="$USER_KNOWN_HOSTS_FILE"
        export PUSH_AUTH_METHOD="$AUTH_METHOD"
        export PUSH_KEY_FILE="$RUNTIME_KEY_FILE"
        revalidate_known_hosts || return 1
        command=(timeout "$TOTAL_TIMEOUT")
        [[ "$AUTH_METHOD" == password ]] && command+=(sshpass -e)
        command+=("$SSH_WRAPPER" "$target" true)
        output_file="$TEMP_DIR/auth.$BASHPID.$index"
        if run_managed_command "$output_file" "${command[@]}"; then
            exit_code=0
        else
            exit_code=$?
        fi
        output=$(<"$output_file")
        rm -f -- "$output_file" || {
            echo -e "${RED}${ICON_ERROR} 认证输出文件残留: $output_file${NC}" >&2
            status=1
        }
        WORKER_OUTPUT_FILE=""
        if (( exit_code == MANAGED_CLEANUP_FAILURE_STATUS )); then
            echo -e "${RED}${ICON_ERROR} 认证 session 清理失败，停止后续服务器${NC}" >&2
            return "$MANAGED_CLEANUP_FAILURE_STATUS"
        fi
        if (( exit_code == 0 )); then
            echo -e "${GREEN}${ICON_SUCCESS} $display:$port 认证成功${NC}"
        else
            echo -e "${RED}${ICON_ERROR} $display:$port 认证失败${NC}" >&2
            [[ -n "$output" ]] && echo -e "${RED}$output${NC}" >&2
            status=1
        fi
    done
    return "$status"
}

show_help() {
    cat <<EOF
$SCRIPT_NAME v$SCRIPT_VERSION

用法:
  $0 --generate-config
  $0 --test-auth
  $0 TASK_NAME
  $0 SOURCE DESTINATION

--test-auth 会连接全部配置服务器，仅执行无副作用的 SSH true，不运行 rsync。
默认不删除远端文件；DELETE_EXTRA=true 仍需要显式授权。
EOF
}

resolve_transfer_arguments() {
    local -n source_ref="$1"
    local -n destination_ref="$2"
    shift 2
    local task

    if (( $# == 1 )); then
        task="$1"
        [[ -n "${TASKS[$task]:-}" ]] || return 1
        source_ref=${TASKS[$task]%%:*}
        destination_ref=${TASKS[$task]#*:}
    elif (( $# == 2 )); then
        source_ref="$1"
        destination_ref="$2"
    else
        return 1
    fi
    validate_transfer_path "$source_ref" && validate_transfer_path "$destination_ref" || return 1
    [[ -e "$source_ref" || -L "$source_ref" ]]
}

run_transfer() {
    local src="$1" dst="$2" final_failed=0 batch_status=0 retry_status=0

    run_server_batch "$src" "$dst" "${SERVERS[@]}" || batch_status=$?
    if (( batch_status == MANAGED_CLEANUP_FAILURE_STATUS )); then
        echo -e "${RED}${ICON_ERROR} batch lifecycle failure，停止汇总与交互重试${NC}" >&2
        return "$MANAGED_CLEANUP_FAILURE_STATUS"
    elif (( batch_status != 0 )); then
        echo -e "${RED}${ICON_ERROR} 结果记录不完整，拒绝输出成功汇总${NC}" >&2
        return 1
    fi

    show_summary
    interactive_retry "$src" "$dst" || retry_status=$?
    if (( retry_status == MANAGED_CLEANUP_FAILURE_STATUS )); then
        echo -e "${RED}${ICON_ERROR} 重试 batch lifecycle failure${NC}" >&2
        return "$MANAGED_CLEANUP_FAILURE_STATUS"
    elif (( retry_status != 0 )); then
        echo -e "${RED}${ICON_ERROR} 重试结果记录不完整${NC}" >&2
        return 1
    fi
    [[ -f "$FAILED_FILE" ]] && final_failed=$(wc -l < "$FAILED_FILE")
    (( final_failed == 0 ))
}

main() {
    local config_status=0 src="" dst=""

    case "${1:-}" in
        -h|--help)
            show_help
            return 0
            ;;
        --generate-config)
            generate_config config.conf
            return
            ;;
    esac

    check_and_generate_config config.conf || config_status=$?
    case "$config_status" in
        0) ;;
        2) return 0 ;;
        *) return 1 ;;
    esac
    load_config config.conf || return 1
    validate_config || return 1

    if [[ "${1:-}" == --test-auth ]]; then
        check_dependencies auth || return 1
        install_runtime_traps || return 1
        initialize_runtime || return 1
        prepare_ssh_runtime || return 1
        test_authentication
        return
    fi

    resolve_transfer_arguments src dst "$@" || {
        show_help >&2
        return 1
    }
    prepare_delete_authorization || return 1
    check_dependencies transfer || return 1
    install_runtime_traps || return 1
    initialize_runtime || return 1
    prepare_ssh_runtime || return 1
    run_transfer "$src" "$dst"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
