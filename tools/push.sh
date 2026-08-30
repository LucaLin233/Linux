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
MAX_RETRIES=3
RETRY_DELAY=5

TEMP_DIR=""
SUCCESS_FILE=""
FAILED_FILE=""
SSH_WRAPPER=""
RUNTIME_KEY_FILE=""
TEMP_DIR_DEV=""
TEMP_DIR_INODE=""
RUNTIME_INITIALIZED=false
RUNTIME_CLEANUP_ACTIVE=false
RUNTIME_TRAPS_INSTALLED=false

PARSED_PORT=""
PARSED_TARGET=""

WORKER_TRANSFER_PID=""
WORKER_TRANSFER_PGID=""
WORKER_TRANSFER_START=""
WORKER_OUTPUT_FILE=""

declare -a SERVERS=()
declare -A TASKS=()
declare -A ACTIVE_WORKERS=()
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
            (( (mode_value & 0022) == 0 )) || {
                echo -e "${RED}${ICON_ERROR} 配置文件不能允许组或其他用户写入${NC}" >&2
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
    local -a required=(ssh timeout stat dirname basename mkdir chmod mktemp ln rm cat id ps setsid awk tr wc sleep date)
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
        PARSED_TARGET="$user@[$host]"
    else
        PARSED_TARGET="$user@$host"
    fi
}

format_server_info() {
    parse_server_info "$1" || return 1
    printf '%s:%s\n' "$PARSED_TARGET" "$PARSED_PORT"
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

runtime_directory_trusted() {
    local metadata="" dev inode owner gid mode trusted_gid
    [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" && ! -L "$TEMP_DIR" ]] || return 1
    metadata=$(stat -Lc '%d:%i:%u:%g:%a' -- "$TEMP_DIR" 2>/dev/null) || return 1
    IFS=: read -r dev inode owner gid mode <<< "$metadata"
    trusted_gid=$(current_gid) || return 1
    [[ "$dev" == "$TEMP_DIR_DEV" && "$inode" == "$TEMP_DIR_INODE" && "$owner" == "$EUID" && "$gid" == "$trusted_gid" && "$mode" == 700 ]]
}

initialize_runtime() {
    local parent="${TMPDIR:-/tmp}" candidate="" metadata=""
    local dev inode owner gid mode trusted_gid
    local success_file failed_file wrapper

    [[ "$RUNTIME_INITIALIZED" == false && -z "$TEMP_DIR" ]] || return 1
    [[ "$parent" =~ ^[A-Za-z0-9_./-]+$ ]] || {
        echo -e "${RED}${ICON_ERROR} TMPDIR 包含不适合 rsync remote-shell 参数的字符: $parent${NC}" >&2
        return 1
    }
    [[ -d "$parent" && ! -L "$parent" ]] || return 1
    candidate=$(mktemp -d "$parent/push-runtime.XXXXXXXXXX") || {
        echo -e "${RED}${ICON_ERROR} 无法创建 push runtime 目录${NC}" >&2
        return 1
    }
    metadata=$(stat -Lc '%d:%i:%u:%g:%a' -- "$candidate" 2>/dev/null) || {
        rm -rf -- "$candidate"
        return 1
    }
    IFS=: read -r dev inode owner gid mode <<< "$metadata"
    trusted_gid=$(current_gid) || {
        rm -rf -- "$candidate"
        return 1
    }
    if [[ ! -d "$candidate" || -L "$candidate" || "$owner" != "$EUID" || "$gid" != "$trusted_gid" || "$mode" != 700 ]]; then
        echo -e "${RED}${ICON_ERROR} 新建 runtime 目录未通过 owner/mode 校验: $candidate${NC}" >&2
        rm -rf -- "$candidate"
        return 1
    fi
    success_file="$candidate/success"
    failed_file="$candidate/failed"
    wrapper="$candidate/ssh-wrapper"
    if ! (umask 077; set -o noclobber; : > "$success_file"; : > "$failed_file") 2>/dev/null; then
        rm -rf -- "$candidate"
        return 1
    fi
    [[ -f "$success_file" && ! -L "$success_file" && -f "$failed_file" && ! -L "$failed_file" ]] || {
        rm -rf -- "$candidate"
        return 1
    }

    TEMP_DIR="$candidate"
    SUCCESS_FILE="$success_file"
    FAILED_FILE="$failed_file"
    SSH_WRAPPER="$wrapper"
    TEMP_DIR_DEV="$dev"
    TEMP_DIR_INODE="$inode"
    RUNTIME_INITIALIZED=true
    ACTIVE_WORKERS=()
}

get_process_start_time() {
    local pid="$1"
    [[ "$pid" =~ ^[0-9]+$ && -r "/proc/$pid/stat" ]] || return 1
    awk '{print $22}' "/proc/$pid/stat" 2>/dev/null
}

process_identity_matches() {
    local pid="$1" expected_start="$2" current=""
    current=$(get_process_start_time "$pid") || return 1
    [[ "$current" == "$expected_start" ]]
}

job_is_active() {
    local expected="$1" pid
    while IFS= read -r pid; do
        [[ "$pid" == "$expected" ]] && return 0
    done < <(jobs -pr)
    return 1
}

prune_active_workers() {
    local pid
    for pid in "${!ACTIVE_WORKERS[@]}"; do
        if ! job_is_active "$pid" || ! process_identity_matches "$pid" "${ACTIVE_WORKERS[$pid]}"; then
            wait "$pid" 2>/dev/null || true
            unset 'ACTIVE_WORKERS[$pid]'
        fi
    done
}

terminate_active_workers() {
    local pid _
    prune_active_workers
    for pid in "${!ACTIVE_WORKERS[@]}"; do
        if job_is_active "$pid" && process_identity_matches "$pid" "${ACTIVE_WORKERS[$pid]}"; then
            kill -TERM "$pid" 2>/dev/null || true
        fi
    done
    for _ in {1..20}; do
        prune_active_workers
        (( ${#ACTIVE_WORKERS[@]} == 0 )) && break
        sleep 0.1
    done
    for pid in "${!ACTIVE_WORKERS[@]}"; do
        if job_is_active "$pid" && process_identity_matches "$pid" "${ACTIVE_WORKERS[$pid]}"; then
            kill -KILL "$pid" 2>/dev/null || true
        fi
    done
    for pid in "${!ACTIVE_WORKERS[@]}"; do
        wait "$pid" 2>/dev/null || true
        unset 'ACTIVE_WORKERS[$pid]'
    done
}

cleanup_runtime() {
    local cleanup_failed=false

    [[ "$RUNTIME_CLEANUP_ACTIVE" == false ]] || return 0
    RUNTIME_CLEANUP_ACTIVE=true
    terminate_active_workers || cleanup_failed=true
    unset SSHPASS

    if [[ -n "$TEMP_DIR" ]]; then
        if [[ ! -e "$TEMP_DIR" && ! -L "$TEMP_DIR" ]]; then
            :
        elif ! runtime_directory_trusted; then
            echo -e "${RED}${ICON_ERROR} 拒绝删除无法证明所有权的 runtime 路径: $TEMP_DIR${NC}" >&2
            cleanup_failed=true
        elif ! rm -rf -- "$TEMP_DIR"; then
            echo -e "${RED}${ICON_ERROR} runtime 目录删除失败: $TEMP_DIR${NC}" >&2
            cleanup_failed=true
        fi
    fi
    if [[ "$cleanup_failed" == false ]]; then
        TEMP_DIR=""
        SUCCESS_FILE=""
        FAILED_FILE=""
        SSH_WRAPPER=""
        RUNTIME_KEY_FILE=""
        TEMP_DIR_DEV=""
        TEMP_DIR_INODE=""
        RUNTIME_INITIALIZED=false
    fi
    RUNTIME_CLEANUP_ACTIVE=false
    [[ "$cleanup_failed" == false ]]
}

runtime_exit_handler() {
    local status="$?"
    trap - EXIT
    cleanup_runtime || true
    exit "$status"
}

runtime_signal_handler() {
    local signal_name="$1" status="$2"
    trap - EXIT HUP INT TERM
    echo -e "${YELLOW}${ICON_STOP} 收到 $signal_name，正在终止本次 push 进程树${NC}" >&2
    cleanup_runtime || true
    exit "$status"
}

install_runtime_traps() {
    [[ "$RUNTIME_INITIALIZED" == true ]] || return 1
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

    [[ "$directory" == /* ]] || {
        echo -e "${RED}${ICON_ERROR} known_hosts 父目录必须是绝对路径: $directory${NC}" >&2
        return 1
    }
    if path_has_symlink_component "$directory"; then
        echo -e "${RED}${ICON_ERROR} known_hosts 父目录路径包含符号链接: $directory${NC}" >&2
        return 1
    fi
    while [[ ! -e "$current" && ! -L "$current" ]]; do
        missing+=("$current")
        ancestor=$(dirname -- "$current") || return 1
        [[ "$ancestor" != "$current" ]] || return 1
        current="$ancestor"
    done
    secure_directory_metadata "$current" || {
        echo -e "${RED}${ICON_ERROR} known_hosts 父目录不可信: $current${NC}" >&2
        return 1
    }
    for ((index=${#missing[@]} - 1; index >= 0; index--)); do
        item=${missing[$index]}
        if mkdir -m 0700 -- "$item" 2>/dev/null; then
            :
        elif [[ ! -e "$item" && ! -L "$item" ]]; then
            return 1
        fi
        secure_directory_metadata "$item" || {
            echo -e "${RED}${ICON_ERROR} known_hosts 父目录不可信: $item${NC}" >&2
            return 1
        }
    done
    ! path_has_symlink_component "$directory"
}

prepare_known_hosts() {
    local known_hosts="$USER_KNOWN_HOSTS_FILE" directory="" metadata=""
    local owner gid mode trusted_gid mode_value=0

    contains_control_character "$known_hosts" && return 1
    if [[ "$known_hosts" == /dev/null ]]; then
        [[ "$ALLOW_INSECURE_HOST_KEY_STORAGE" == true ]] || return 1
        echo -e "${RED}${ICON_WARNING} known_hosts 使用 /dev/null，无法持久验证指纹，存在 MITM 风险。${NC}" >&2
        return 0
    fi
    [[ "$known_hosts" == /* ]] || return 1
    directory=$(dirname -- "$known_hosts") || return 1
    ensure_secure_directory_chain "$directory" || return 1
    if [[ ! -e "$known_hosts" && ! -L "$known_hosts" ]]; then
        if ! (umask 077; set -o noclobber; : > "$known_hosts") 2>/dev/null; then
            [[ -e "$known_hosts" || -L "$known_hosts" ]] || return 1
        fi
    fi
    [[ -f "$known_hosts" && ! -L "$known_hosts" ]] || {
        echo -e "${RED}${ICON_ERROR} known_hosts 必须是非符号链接普通文件${NC}" >&2
        return 1
    }
    metadata=$(stat -Lc '%u:%g:%a' -- "$known_hosts") || return 1
    IFS=: read -r owner gid mode <<< "$metadata"
    trusted_gid=$(current_gid) || return 1
    [[ "$owner" == "$EUID" && "$gid" == "$trusted_gid" && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    mode_value=$((8#$mode))
    (( (mode_value & 0600) == 0600 && (mode_value & 0022) == 0 )) || {
        echo -e "${RED}${ICON_ERROR} known_hosts 必须 owner 可读写且禁止组/其他用户写入${NC}" >&2
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
    -p "$PUSH_SSH_PORT"
    -o "ConnectTimeout=$PUSH_CONNECTION_TIMEOUT"
    -o "StrictHostKeyChecking=$PUSH_STRICT_HOST_KEY_CHECKING"
    -o "UserKnownHostsFile=$PUSH_USER_KNOWN_HOSTS_FILE"
    -o LogLevel=ERROR
)
if [[ "$PUSH_AUTH_METHOD" == key ]]; then
    args+=(-o BatchMode=yes -i "$PUSH_KEY_FILE")
else
    args+=(
        -o BatchMode=no
        -o PreferredAuthentications=password
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

worker_transfer_identity_matches() {
    [[ -n "$WORKER_TRANSFER_PID" && -n "$WORKER_TRANSFER_START" ]] || return 1
    process_identity_matches "$WORKER_TRANSFER_PID" "$WORKER_TRANSFER_START" || return 1
    local pgid=""
    pgid=$(ps -o pgid= -p "$WORKER_TRANSFER_PID" 2>/dev/null | tr -d ' ') || return 1
    [[ "$pgid" == "$WORKER_TRANSFER_PGID" && "$pgid" == "$WORKER_TRANSFER_PID" ]]
}

terminate_worker_transfer() {
    local _
    if worker_transfer_identity_matches; then
        kill -TERM -- "-$WORKER_TRANSFER_PGID" 2>/dev/null || true
        for _ in {1..20}; do
            worker_transfer_identity_matches || break
            sleep 0.1
        done
        if worker_transfer_identity_matches; then
            kill -KILL -- "-$WORKER_TRANSFER_PGID" 2>/dev/null || true
        fi
        wait "$WORKER_TRANSFER_PID" 2>/dev/null || true
    fi
    WORKER_TRANSFER_PID=""
    WORKER_TRANSFER_PGID=""
    WORKER_TRANSFER_START=""
}

worker_signal_handler() {
    local status="$1"
    trap - EXIT HUP INT TERM
    terminate_worker_transfer
    [[ -z "$WORKER_OUTPUT_FILE" ]] || rm -f -- "$WORKER_OUTPUT_FILE" 2>/dev/null || true
    exit "$status"
}

worker_exit_handler() {
    local status="$?"
    trap - EXIT
    terminate_worker_transfer
    [[ -z "$WORKER_OUTPUT_FILE" ]] || rm -f -- "$WORKER_OUTPUT_FILE" 2>/dev/null || true
    exit "$status"
}

run_transfer_command() {
    local output_file="$1"
    shift
    local -a command=("$@")
    local exit_code=0 pgid=""

    WORKER_OUTPUT_FILE="$output_file"
    if ! (umask 077; set -o noclobber; : > "$output_file") 2>/dev/null; then
        return 1
    fi
    setsid "${command[@]}" > "$output_file" 2>&1 &
    WORKER_TRANSFER_PID=$!
    WORKER_TRANSFER_PGID="$WORKER_TRANSFER_PID"
    for _ in {1..50}; do
        WORKER_TRANSFER_START=$(get_process_start_time "$WORKER_TRANSFER_PID" 2>/dev/null || true)
        pgid=$(ps -o pgid= -p "$WORKER_TRANSFER_PID" 2>/dev/null | tr -d ' ' || true)
        [[ -n "$WORKER_TRANSFER_START" && "$pgid" == "$WORKER_TRANSFER_PID" ]] && break
        kill -0 "$WORKER_TRANSFER_PID" 2>/dev/null || break
        sleep 0.01
    done
    if [[ -z "$WORKER_TRANSFER_START" || "$pgid" != "$WORKER_TRANSFER_PID" ]]; then
        if ! job_is_active "$WORKER_TRANSFER_PID"; then
            if wait "$WORKER_TRANSFER_PID"; then
                exit_code=0
            else
                exit_code=$?
            fi
            WORKER_TRANSFER_PID=""
            WORKER_TRANSFER_PGID=""
            WORKER_TRANSFER_START=""
            return "$exit_code"
        fi
        terminate_worker_transfer
        return 1
    fi
    if wait "$WORKER_TRANSFER_PID"; then
        exit_code=0
    else
        exit_code=$?
    fi
    WORKER_TRANSFER_PID=""
    WORKER_TRANSFER_PGID=""
    WORKER_TRANSFER_START=""
    return "$exit_code"
}

retry_rsync() {
    local server_info="$1" src="$2" dst="$3"
    local attempt=1 port target output_file output="" exit_code=0
    local -a rsync_opts command

    validate_transfer_path "$src" && validate_transfer_path "$dst" || return 1
    parse_server_info "$server_info" || return 1
    port="$PARSED_PORT"
    target="$PARSED_TARGET"
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

record_result() {
    local result="$1" server="$2" file lock_fd
    if [[ "$result" == success ]]; then
        file="$SUCCESS_FILE"
        exec {lock_fd}>"$SUCCESS_FILE.lock"
    else
        file="$FAILED_FILE"
        exec {lock_fd}>"$FAILED_FILE.lock"
    fi
    flock -x "$lock_fd"
    printf '%s\n' "$server" >> "$file"
    exec {lock_fd}>&-
}

push_to_server() {
    local server_info="$1" src="$2" dst="$3" index="$4" total="$5" display=""
    trap 'worker_signal_handler 129' HUP
    trap 'worker_signal_handler 130' INT
    trap 'worker_signal_handler 143' TERM
    trap worker_exit_handler EXIT
    display=$(format_server_info "$server_info") || return 1
    echo -e "${BLUE}[${index}/${total}]${NC} ${ICON_WORKING} ${CYAN}$display${NC}"
    if retry_rsync "$server_info" "$src" "$dst"; then
        record_result success "$server_info"
        echo -e "${GREEN}[${index}/${total}] ${ICON_SUCCESS} $display${NC}"
    else
        record_result failed "$server_info"
        echo -e "${RED}[${index}/${total}] ${ICON_ERROR} $display${NC}"
    fi
}

launch_worker() {
    local server="$1" src="$2" dst="$3" index="$4" total="$5" pid start=""
    push_to_server "$server" "$src" "$dst" "$index" "$total" &
    pid=$!
    for _ in {1..20}; do
        start=$(get_process_start_time "$pid" 2>/dev/null || true)
        [[ -n "$start" ]] && break
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.01
    done
    if [[ -n "$start" ]]; then
        ACTIVE_WORKERS["$pid"]="$start"
    else
        wait "$pid" 2>/dev/null || true
    fi
}

wait_for_worker_slot() {
    while :; do
        prune_active_workers
        (( ${#ACTIVE_WORKERS[@]} < MAX_PARALLEL )) && return 0
        wait -n 2>/dev/null || true
    done
}

wait_for_all_workers() {
    while (( ${#ACTIVE_WORKERS[@]} > 0 )); do
        wait -n 2>/dev/null || true
        prune_active_workers
    done
}

run_server_batch() {
    local src="$1" dst="$2"
    shift 2
    local -a servers=("$@")
    local index=0 total=${#servers[@]} server
    for server in "${servers[@]}"; do
        ((index += 1))
        wait_for_worker_slot
        launch_worker "$server" "$src" "$dst" "$index" "$total"
    done
    wait_for_all_workers
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
    : > "$FAILED_FILE"
    rm -f -- "$FAILED_FILE.lock"
    run_server_batch "$src" "$dst" "${failed_servers[@]}"
}

test_authentication() {
    local server port target status=0
    local -a command

    echo -e "${CYAN}${ICON_CONFIG} 对全部配置服务器执行无副作用 SSH true 认证测试${NC}"
    for server in "${SERVERS[@]}"; do
        if ! parse_server_info "$server"; then
            status=1
            continue
        fi
        port="$PARSED_PORT"
        target="$PARSED_TARGET"
        export PUSH_SSH_PORT="$port"
        export PUSH_CONNECTION_TIMEOUT="$CONNECTION_TIMEOUT"
        export PUSH_STRICT_HOST_KEY_CHECKING="$STRICT_HOST_KEY_CHECKING"
        export PUSH_USER_KNOWN_HOSTS_FILE="$USER_KNOWN_HOSTS_FILE"
        export PUSH_AUTH_METHOD="$AUTH_METHOD"
        export PUSH_KEY_FILE="$RUNTIME_KEY_FILE"
        command=(timeout "$TOTAL_TIMEOUT")
        [[ "$AUTH_METHOD" == password ]] && command+=(sshpass -e)
        command+=("$SSH_WRAPPER" "$target" true)
        if "${command[@]}"; then
            echo -e "${GREEN}${ICON_SUCCESS} $target:$port 认证成功${NC}"
        else
            echo -e "${RED}${ICON_ERROR} $target:$port 认证失败${NC}" >&2
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
    local src="$1" dst="$2" final_failed=0
    run_server_batch "$src" "$dst" "${SERVERS[@]}"
    show_summary
    interactive_retry "$src" "$dst"
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
        initialize_runtime || return 1
        install_runtime_traps || return 1
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
    initialize_runtime || return 1
    install_runtime_traps || return 1
    prepare_ssh_runtime || return 1
    run_transfer "$src" "$dst"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
