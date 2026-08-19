#!/usr/bin/env bash
# linux-setup:name=网络优化（BBR、fq、TCP 缓冲区）
# linux-setup:order=30
# linux-setup:depends=
# linux-setup:enabled=true
# 网络优化模块
# TCP 调优仅覆盖 IPv4。
# 基础调优移植或参考 Kylin010/tcpfit v0.5.6（MIT，提交 67c0bdfb35dd98e86982600298237b6ecc08ebe4）。
# 事务备份、交互与验证为本仓库下游扩展。
# 功能：配置 BBR、fq 与 TCP 缓冲区；交互默认测速，也可手动提供完整带宽。
# 完整用法与选项由 show_help 输出。

set -euo pipefail

# === 常量定义 ===
readonly NETWORK_CONF="${NETWORK_OPTIMIZE_CONF:-/etc/sysctl.d/99-network-optimize.conf}"
readonly NETWORK_INITIAL_BACKUP="${NETWORK_CONF}.initial-backup"
readonly NETWORK_PREVIOUS_BACKUP="${NETWORK_CONF}.previous-backup"
readonly NETWORK_INITIAL_ABSENT="${NETWORK_CONF}.initial-absent"
readonly NETWORK_INITIAL_UNKNOWN="${NETWORK_CONF}.initial-unknown"
readonly NETWORK_PREVIOUS_ABSENT="${NETWORK_CONF}.previous-absent"
readonly NETWORK_OPTIMIZE_STATE_DIR="${NETWORK_OPTIMIZE_STATE_DIR:-/var/lib/linux-setup}"
readonly BBR_MODULES_FILE="${NETWORK_OPTIMIZE_BBR_MODULES_FILE:-/etc/modules-load.d/network-optimize-bbr.conf}"
readonly BBR_MODULES_INITIAL_BACKUP="${BBR_MODULES_FILE}.initial-backup"
readonly BBR_MODULES_PREVIOUS_BACKUP="${BBR_MODULES_FILE}.previous-backup"
readonly BBR_MODULES_INITIAL_ABSENT="${BBR_MODULES_FILE}.initial-absent"
readonly BBR_MODULES_INITIAL_UNKNOWN="${BBR_MODULES_FILE}.initial-unknown"
readonly BBR_MODULES_PREVIOUS_ABSENT="${BBR_MODULES_FILE}.previous-absent"
readonly RUNTIME_INITIAL_BACKUP="${NETWORK_OPTIMIZE_STATE_DIR}/network-optimize.initial-runtime"
readonly RUNTIME_INITIAL_UNKNOWN="${NETWORK_OPTIMIZE_STATE_DIR}/network-optimize.initial-runtime-unknown"
readonly RUNTIME_PREVIOUS_BACKUP="${NETWORK_OPTIMIZE_STATE_DIR}/network-optimize.previous-runtime"
readonly ROUTE_INITIAL_BACKUP="${NETWORK_OPTIMIZE_STATE_DIR}/network-optimize.initial-route"
readonly ROUTE_PREVIOUS_BACKUP="${NETWORK_OPTIMIZE_STATE_DIR}/network-optimize.previous-route"
readonly ROUTE_INITIAL_ABSENT="${NETWORK_OPTIMIZE_STATE_DIR}/network-optimize.initial-route-absent"
readonly ROUTE_PREVIOUS_ABSENT="${NETWORK_OPTIMIZE_STATE_DIR}/network-optimize.previous-route-absent"
readonly ROUTE_INITIAL_UNKNOWN="${NETWORK_OPTIMIZE_STATE_DIR}/network-optimize.initial-route-unknown"
readonly ROUTE_INITIAL_OWNED="${ROUTE_INITIAL_BACKUP}.owned"
readonly ROUTE_PREVIOUS_OWNED="${ROUTE_PREVIOUS_BACKUP}.owned"
readonly ROUTE_OWNED_MARKER="${NETWORK_OPTIMIZE_STATE_DIR}/network-optimize.initcwnd-owned"
readonly INITCWND_ROUTE_HOOK="${NETWORK_OPTIMIZE_INITCWND_HOOK:-/etc/networkd-dispatcher/routable.d/50-network-optimize-initcwnd}"
readonly ROUTE_HOOK_INITIAL_BACKUP="${NETWORK_OPTIMIZE_STATE_DIR}/network-optimize.initial-initcwnd-hook"
readonly ROUTE_HOOK_PREVIOUS_BACKUP="${NETWORK_OPTIMIZE_STATE_DIR}/network-optimize.previous-initcwnd-hook"
readonly ROUTE_HOOK_INITIAL_ABSENT="${NETWORK_OPTIMIZE_STATE_DIR}/network-optimize.initial-initcwnd-hook-absent"
readonly ROUTE_HOOK_PREVIOUS_ABSENT="${NETWORK_OPTIMIZE_STATE_DIR}/network-optimize.previous-initcwnd-hook-absent"
readonly LOCK_FILE="${NETWORK_OPTIMIZE_LOCK_FILE:-/run/lock/network-optimize.lock}"
readonly NETWORK_DETAIL_LOG="${NETWORK_OPTIMIZE_LOG:-/var/log/linux-setup.log}"
readonly MEASUREMENT_CACHE="${NETWORK_OPTIMIZE_CACHE_FILE:-${NETWORK_OPTIMIZE_STATE_DIR}/network-optimize.bandwidth-cache}"

# 公共 iperf3 测速固定使用 IPv4、4 并发和 5 秒时长，最多采纳两个节点。
readonly IPERF_DURATION=5
readonly IPERF_PARALLEL=4
readonly IPERF_MAX_PEERS=2
readonly -a IPERF_PORTS=(5201 5202 5203 5204 5205 5206 5207 5208 5209 5210 5200)
readonly TRAFFIC_TOTAL_LIMIT_BYTES=25000000000
readonly TRAFFIC_DIRECTION_LIMIT_BYTES=12500000000
readonly CACHE_FRESH_MAX_AGE_SECONDS=$((7 * 24 * 60 * 60))
readonly CACHE_STALE_MAX_AGE_SECONDS=$((30 * 24 * 60 * 60))
readonly CACHE_FORMAT_VERSION=2
readonly MEASUREMENT_ROUTE_PROBE_TARGET="1.1.1.1"

# 公共节点参考 tcpfit，覆盖常见 VPS 机房区域。端口范围为 5201–5210，并兼容 5200。
readonly IPERF_PEER_POOL='speedtest.hkg12.hk.leaseweb.net|香港|Leaseweb
speedtest.sin1.sg.leaseweb.net|新加坡|Leaseweb
sgp.proof.ovh.net|新加坡|OVH
speedtest.syd12.au.leaseweb.net|悉尼|Leaseweb
speedtest.tyo11.jp.leaseweb.net|东京|Leaseweb
speedtest.fra1.de.leaseweb.net|法兰克福|Leaseweb
speedtest.ams2.nl.leaseweb.net|阿姆斯特丹|Leaseweb
ams.speedtest.clouvider.net|阿姆斯特丹|Clouvider
speedtest.lon12.uk.leaseweb.net|伦敦|Leaseweb
lon.speedtest.clouvider.net|伦敦|Clouvider
speedtest.lax12.us.leaseweb.net|洛杉矶|Leaseweb
speedtest.sfo12.us.leaseweb.net|旧金山|Leaseweb
speedtest.sea11.us.leaseweb.net|西雅图|Leaseweb
speedtest.dal13.us.leaseweb.net|达拉斯|Leaseweb
speedtest.chi11.us.leaseweb.net|芝加哥|Leaseweb
speedtest.nyc1.us.leaseweb.net|纽约|Leaseweb
speedtest.mia11.us.leaseweb.net|迈阿密|Leaseweb
speedtest.mtl2.ca.leaseweb.net|蒙特利尔|Leaseweb'

readonly DEFAULT_RTT_MS=150
readonly INITCWND_AUTO_UPLOAD_LIMIT_MBPS=100
readonly TCP_BUFFER_DEFAULT_BYTES=$((2 * 1024 * 1024))
readonly IPERF_DEADLINE_GRACE_SECONDS=15
readonly IPERF_KILL_AFTER_SECONDS=3

# 参数与计算结果。命令行参数优先于自动测量。
COMMAND="install"
RESTORE_SCOPE="previous"
TUNING_MODE=""
TUNING_SELECTION_EXPLICIT="false"
AUTO_MODE_REQUESTED="false"
FORCE_REFRESH="false"
INITCWND_MODE="auto"
INITCWND_ENABLED="true"
INITCWND_POLICY="unknown"
MANUAL_BANDWIDTH_MBPS=""
MANUAL_DOWNLOAD_MBPS=""
MANUAL_UPLOAD_MBPS=""
MANUAL_RTT_MS=""
MANUAL_RTT_DEFAULTED="false"

DETECTED_DOWNLOAD_MBPS=""
DETECTED_UPLOAD_MBPS=""
DETECTED_RTT_MS=""
RTT_SOURCE="unknown"
RTT_POLICY="unknown"
BANDWIDTH_SOURCE="unknown"
BANDWIDTH_PROBE_NOTE=""
MEASUREMENT_SOURCE="unknown"
MEASUREMENT_EPOCH=0
MEASUREMENT_TIME="unknown"
MEASUREMENT_NODES="none"
MEASUREMENT_CONFIDENCE="unknown"
MEASUREMENT_WARNINGS=""
MEASUREMENT_ROUTE_TARGET=""
MEASUREMENT_ROUTE_IDENTITY=""
MEASUREMENT_CACHE_PENDING="false"
PHYSICAL_RAM_MB=0
RAM_MB=0
MEMORY_CAP_BYTES=0
RX_BDP_BYTES=0
TX_BDP_BYTES=0
RMEM_MAX_BYTES=0
WMEM_MAX_BYTES=0
RMEM_DEFAULT_BYTES=$TCP_BUFFER_DEFAULT_BYTES
WMEM_DEFAULT_BYTES=$TCP_BUFFER_DEFAULT_BYTES
TCP_MEM_PAGES=""
CALCULATION_REASON="pending bandwidth"
RMEM_REASON="pending bandwidth"
WMEM_REASON="pending bandwidth"
PROBE_IFACE=""
declare -A PROBE_ENVIRONMENT_SHOWN_BY_IFACE=()
declare -a TRAFFIC_IFACES=()
declare -A TRAFFIC_RX_START_BY_IFACE=()
declare -A TRAFFIC_TX_START_BY_IFACE=()
# PID arrays are accessed through namerefs.
# shellcheck disable=SC2034
declare -a IPERF_RUNNER_PIDS=()
declare -a PROBE_TEMP_PATHS=()
declare -a INSTALL_ROLLBACK_FAILED_ITEMS=()
IPERF_TEST_RESULT=""
RANKED_IPERF_PEERS=""
PREFERRED_IPERF_PORT=""

# === 日志函数 ===
log() {
    local msg="$1" level="${2:-info}"
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
detail() {
    local message="$1"

    if [[ "${DEBUG:-}" == "1" ]]; then
        info "$message"
    elif [[ -w "$NETWORK_DETAIL_LOG" || ( ! -e "$NETWORK_DETAIL_LOG" && -w "$(dirname "$NETWORK_DETAIL_LOG")" ) ]]; then
        printf '%s network-optimize: %s\n' "$(date '+%F %T')" "$message" \
            2>/dev/null >> "$NETWORK_DETAIL_LOG" || true
    fi
}


stage_managed_state() {
    local target="$1" backup="$2" absent="$3" stage

    install -d -m 0755 "$(dirname "$backup")" || return 1
    if [[ -e "$target" || -L "$target" ]]; then
        stage=$(mktemp "${backup}.new.XXXXXX") || return 1
        rm -f "$stage"
        if ! cp -a -- "$target" "$stage" || ! mv -f -- "$stage" "$backup"; then
            rm -f "$stage"
            return 1
        fi
        rm -f "$absent"
    else
        stage=$(mktemp "${absent}.new.XXXXXX") || return 1
        if ! chmod 600 "$stage" || ! mv -f -- "$stage" "$absent"; then
            rm -f "$stage"
            return 1
        fi
        rm -f "$backup"
    fi
}

atomic_install_file() {
    local source_file="$1" destination="$2" mode="${3:-0600}" stage

    install -d -m 0755 "$(dirname "$destination")" || return 1
    stage=$(mktemp "${destination}.new.XXXXXX") || return 1
    if ! install -m "$mode" "$source_file" "$stage" ||
        ! mv -f -- "$stage" "$destination"; then
        rm -f "$stage"
        return 1
    fi
}

atomic_write_file() {
    local destination="$1" content="$2" mode="${3:-0600}" create_parent="${4:-true}" stage

    [[ "$create_parent" == "false" ]] ||
        install -d -m 0755 "$(dirname "$destination")" || return 1
    stage=$(mktemp "${destination}.new.XXXXXX") || return 1
    if ! printf '%s\n' "$content" > "$stage" || ! chmod "$mode" "$stage" ||
        ! mv -f -- "$stage" "$destination"; then
        rm -f "$stage"
        return 1
    fi
}

atomic_restore_file() {
    local source_file="$1" destination="$2" stage

    install -d -m 0755 "$(dirname "$destination")" || return 1
    stage=$(mktemp "${destination}.rollback.XXXXXX") || return 1
    rm -f -- "$stage" || return 1
    if ! cp -a -- "$source_file" "$stage" || ! mv -f -- "$stage" "$destination"; then
        rm -f -- "$stage"
        return 1
    fi
}

backup_managed_file() {
    local target="$1" initial_backup="$2" previous_backup="$3" initial_absent="$4" previous_absent="$5"

    local initial_unknown="${initial_backup%.initial-backup}.initial-unknown"

    if [[ ! -e "$initial_backup" && ! -e "$initial_absent" && ! -e "$initial_unknown" ]]; then
        stage_managed_state "$target" "$initial_backup" "$initial_absent" || return 1
    fi

    stage_managed_state "$target" "$previous_backup" "$previous_absent"
}

managed_file_specs() {
    cat <<EOF
network|$NETWORK_CONF|$NETWORK_INITIAL_BACKUP|$NETWORK_PREVIOUS_BACKUP|$NETWORK_INITIAL_ABSENT|$NETWORK_PREVIOUS_ABSENT
modules|$BBR_MODULES_FILE|$BBR_MODULES_INITIAL_BACKUP|$BBR_MODULES_PREVIOUS_BACKUP|$BBR_MODULES_INITIAL_ABSENT|$BBR_MODULES_PREVIOUS_ABSENT
hook|$INITCWND_ROUTE_HOOK|$ROUTE_HOOK_INITIAL_BACKUP|$ROUTE_HOOK_PREVIOUS_BACKUP|$ROUTE_HOOK_INITIAL_ABSENT|$ROUTE_HOOK_PREVIOUS_ABSENT
EOF
}

# Multi-file guard for command/function failures; not a power-loss transaction.
previous_state_paths() {
    printf '%s\n' \
        "$NETWORK_PREVIOUS_BACKUP" "$NETWORK_PREVIOUS_ABSENT" \
        "$BBR_MODULES_PREVIOUS_BACKUP" "$BBR_MODULES_PREVIOUS_ABSENT" \
        "$RUNTIME_PREVIOUS_BACKUP" "$ROUTE_PREVIOUS_BACKUP" \
        "$ROUTE_PREVIOUS_ABSENT" "$ROUTE_PREVIOUS_OWNED" \
        "$ROUTE_HOOK_PREVIOUS_BACKUP" "$ROUTE_HOOK_PREVIOUS_ABSENT"
}

begin_previous_state_transaction() {
    local transaction_dir="" path index=0

    install -d -m 0755 "$NETWORK_OPTIMIZE_STATE_DIR" || return 1
    transaction_dir=$(mktemp -d \
        "${NETWORK_OPTIMIZE_STATE_DIR}/network-optimize.previous-transaction.XXXXXX") ||
        return 1

    while IFS= read -r path; do
        if [[ -e "$path" || -L "$path" ]]; then
            if ! cp -a -- "$path" "$transaction_dir/item.$index" ||
                ! touch "$transaction_dir/present.$index"; then
                rm -rf -- "$transaction_dir"
                return 1
            fi
        fi
        ((index += 1))
    done < <(previous_state_paths)

    printf '%s\n' "$transaction_dir"
}

restore_previous_state_transaction() {
    local transaction_dir="$1" path index=0 failed="false"

    while IFS= read -r path; do
        if [[ -e "$transaction_dir/present.$index" ]]; then
            if ! atomic_restore_file "$transaction_dir/item.$index" "$path"; then
                failed="true"
            fi
        elif ! rm -f -- "$path"; then
            failed="true"
        fi
        ((index += 1))
    done < <(previous_state_paths)

    [[ "$failed" == "false" ]]
}

backup_previous_state_set() {
    local runtime_snapshot="$1" transaction_dir failed_item=""

    transaction_dir=$(begin_previous_state_transaction) || {
        error "无法创建 previous 备份事务"
        return 1
    }

    if ! atomic_install_file "$runtime_snapshot" "$RUNTIME_PREVIOUS_BACKUP" 0600; then
        failed_item="runtime"
    elif ! backup_network_state; then
        failed_item="${PREVIOUS_BACKUP_FAILED_ITEM:-managed-files}"
    elif ! backup_default_route; then
        failed_item="route"
    fi

    if [[ -z "$failed_item" ]]; then
        rm -rf -- "$transaction_dir" ||
            warn "previous 备份事务临时目录清理失败：$transaction_dir"
        return 0
    fi

    error "previous 备份更新失败（$failed_item），正在恢复旧回滚点"
    if ! restore_previous_state_transaction "$transaction_dir"; then
        error "previous 备份事务回滚不完整；操作前快照保留在：$transaction_dir"
        return 1
    fi
    rm -rf -- "$transaction_dir" || true
    return 1
}

restore_managed_file() {
    local target="$1" backup="$2" absent="$3"

    if [[ -e "$backup" || -L "$backup" ]]; then
        atomic_restore_file "$backup" "$target"
    elif [[ -e "$absent" ]]; then
        rm -f "$target"
    else
        return 1
    fi
}

require_commands() {
    local command_name

    for command_name in "$@"; do
        command -v "$command_name" >/dev/null 2>&1 || {
            error "缺少必要命令: $command_name"
            return 1
        }
    done
}

require_root() {
    if (( EUID != 0 )); then
        error "需要 root 权限运行"
        exit 1
    fi
}

take_lock() {
    local lock_file="$LOCK_FILE"

    if ! { exec 9>"$lock_file"; } 2>/dev/null; then
        if (( EUID != 0 )); then
            lock_file="${XDG_RUNTIME_DIR:-/tmp}/network-optimize-${UID}.lock"
            if ! { exec 9>"$lock_file"; } 2>/dev/null; then
                error "无法创建执行锁：$lock_file"
                return 1
            fi
        else
            error "无法创建执行锁：$lock_file"
            return 1
        fi
    fi
    if ! flock -n 9; then
        error "另一个 network-optimize 实例正在运行"
        return 1
    fi
}

# === 环境与 BBR 检测 ===
detect_container() {
    if [[ -f /proc/user_beancounters ]] ||
        [[ -d /proc/vz ]] ||
        [[ "$(systemd-detect-virt 2>/dev/null || true)" == "lxc" ]]; then
        return 0
    fi

    return 1
}

bbr_available() {
    grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null
}

persist_bbr_module() {
    atomic_write_file "$BBR_MODULES_FILE" "tcp_bbr" 0644 || return 1
}

ensure_bbr_available() {
    if bbr_available; then
        return 0
    fi

    info "当前内核未显示 BBR，尝试加载 tcp_bbr 模块..."
    modprobe tcp_bbr 2>/dev/null || true

    if bbr_available; then
        return 0
    fi

    warn "当前内核不支持 BBR，将保留现有拥塞控制算法"
    return 1
}

# === 一次性动态探测与计算 ===
is_positive_integer() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= $2 && 10#$1 <= $3 ))
}

parse_arguments() {
    local desired_mode spec option value max

    if (( $# > 0 )) && [[ "$1" != -* ]]; then
        COMMAND="$1"
        shift
    fi

    while (( $# > 0 )); do
        case "$1" in
            --auto)
                TUNING_MODE="auto"
                TUNING_SELECTION_EXPLICIT="true"
                AUTO_MODE_REQUESTED="true"
                shift
                ;;
            --refresh)
                FORCE_REFRESH="true"
                TUNING_SELECTION_EXPLICIT="true"
                shift
                ;;
            --bandwidth-mbps|--download-mbps|--upload-mbps|--rtt-ms)
                if (( $# < 2 )); then
                    error "参数 $1 缺少值"
                    return 1
                fi
                TUNING_SELECTION_EXPLICIT="true"
                case "$1" in
                    --bandwidth-mbps) MANUAL_BANDWIDTH_MBPS="$2" ;;
                    --download-mbps) MANUAL_DOWNLOAD_MBPS="$2" ;;
                    --upload-mbps) MANUAL_UPLOAD_MBPS="$2" ;;
                    --rtt-ms) MANUAL_RTT_MS="$2" ;;
                esac
                shift 2
                ;;
            --enable-initcwnd|--disable-initcwnd)
                desired_mode="enabled"
                [[ "$1" != "--disable-initcwnd" ]] || desired_mode="disabled"
                if [[ "$INITCWND_MODE" != "auto" && "$INITCWND_MODE" != "$desired_mode" ]]; then
                    error "--enable-initcwnd 不能与 --disable-initcwnd 同时使用"
                    return 1
                fi
                INITCWND_MODE="$desired_mode"
                shift
                ;;
            --probe|--yes|--disable-ecn)
                error "参数 $1 已退休；请使用 --auto 或完整手动带宽"
                return 1
                ;;
            initial)
                if [[ "$COMMAND" != "restore" ]]; then
                    error "initial 只能用于 restore"
                    return 1
                fi
                RESTORE_SCOPE="initial"
                shift
                ;;
            --help|-h)
                COMMAND="help"
                shift
                ;;
            *)
                error "未知参数: $1"
                return 1
                ;;
        esac
    done

    case "$COMMAND" in
        install|plan|restore|status|help) ;;
        *)
            error "未知命令: $COMMAND"
            return 1
            ;;
    esac

    for spec in \
        "--bandwidth-mbps|$MANUAL_BANDWIDTH_MBPS|100000" \
        "--download-mbps|$MANUAL_DOWNLOAD_MBPS|100000" \
        "--upload-mbps|$MANUAL_UPLOAD_MBPS|100000" \
        "--rtt-ms|$MANUAL_RTT_MS|5000"; do
        IFS='|' read -r option value max <<< "$spec"
        [[ -z "$value" ]] && continue
        if ! is_positive_integer "$value" 1 "$max"; then
            error "$option 必须是 1–$max 的整数"
            return 1
        fi
    done

    if [[ "$AUTO_MODE_REQUESTED" == "true" ]] &&
        [[ -n "$MANUAL_BANDWIDTH_MBPS$MANUAL_DOWNLOAD_MBPS$MANUAL_UPLOAD_MBPS" ]]; then
        error "--auto 不能与手动带宽参数同时使用"
        return 1
    fi

    if [[ "$FORCE_REFRESH" == "true" && "$AUTO_MODE_REQUESTED" != "true" ]]; then
        error "--refresh 必须与 --auto 同时使用"
        return 1
    fi

    if [[ -n "$MANUAL_BANDWIDTH_MBPS" ]]; then
        MANUAL_DOWNLOAD_MBPS="$MANUAL_BANDWIDTH_MBPS"
        MANUAL_UPLOAD_MBPS="$MANUAL_BANDWIDTH_MBPS"
    fi

    if [[ -n "$MANUAL_DOWNLOAD_MBPS$MANUAL_UPLOAD_MBPS" ]]; then
        if [[ -z "$MANUAL_DOWNLOAD_MBPS" || -z "$MANUAL_UPLOAD_MBPS" ]]; then
            error "手动配置必须同时指定 --download-mbps 和 --upload-mbps"
            return 1
        fi
        TUNING_MODE="manual"
        if [[ -z "$MANUAL_RTT_MS" ]]; then
            MANUAL_RTT_MS="$DEFAULT_RTT_MS"
            MANUAL_RTT_DEFAULTED="true"
        fi
    elif [[ -n "$MANUAL_RTT_MS" && "$AUTO_MODE_REQUESTED" != "true" ]]; then
        error "仅指定 RTT 无法计算缓冲区；请同时指定带宽，或使用 --auto"
        return 1
    fi

    if [[ "$COMMAND" != "install" && "$COMMAND" != "plan" ]] &&
        [[ "$TUNING_SELECTION_EXPLICIT" == "true" || "$INITCWND_MODE" != "auto" ]]; then
        error "$COMMAND 不接受测速或调优选项"
        return 1
    fi
}

is_interactive_terminal() {
    [[ -t 0 ]]
}

show_active_probe_warning() {
    printf '%s\n' \
        "测速配置：IPv4 iperf3，最多 2 个节点，每方向 4 并发 × 5 秒" \
        "流量上限：上传 12.5 GB / 下载 12.5 GB / 合计 25 GB（按出口接口统计，包含同期后台流量）" \
        "依赖处理：缺少 iperf3 时通过 APT 自动安装"
}

prompt_manual_bandwidth() {
    local source="${1:-interactive manual entry}" download_mbps upload_mbps

    read -r -p "下载带宽 Mbps: " download_mbps || return 1
    is_positive_integer "$download_mbps" 1 100000 || {
        error "下载带宽必须是 1–100000 的整数"
        return 1
    }
    read -r -p "上传带宽 Mbps: " upload_mbps || return 1
    is_positive_integer "$upload_mbps" 1 100000 || {
        error "上传带宽必须是 1–100000 的整数"
        return 1
    }

    TUNING_MODE="manual"
    MANUAL_DOWNLOAD_MBPS="$download_mbps"
    MANUAL_UPLOAD_MBPS="$upload_mbps"
    if [[ -z "$MANUAL_RTT_MS" ]]; then
        MANUAL_RTT_MS="$DEFAULT_RTT_MS"
        MANUAL_RTT_DEFAULTED="true"
    fi
    BANDWIDTH_SOURCE="$source"
    BANDWIDTH_PROBE_NOTE=""
}

select_tuning_mode() {
    local answer

    [[ "$COMMAND" == "install" || "$COMMAND" == "plan" ]] || return 0
    [[ "$TUNING_SELECTION_EXPLICIT" == "false" ]] || return 0

    if ! is_interactive_terminal; then
        error "非交互运行必须使用 --auto，或显式提供完整上下行带宽"
        return 1
    fi

    show_active_probe_warning
    read -r -p "是否执行公共测速？[Y/n]: " answer || return 1
    case "$answer" in
        ""|[Yy])
            TUNING_MODE="auto"
            AUTO_MODE_REQUESTED="true"
            ;;
        [Nn])
            prompt_manual_bandwidth || return 1
            ;;
        *)
            error "请输入 Y 或 N"
            return 1
            ;;
    esac

    TUNING_SELECTION_EXPLICIT="true"
}

detect_memory_mb() {
    awk '/^MemTotal:/ {printf "%d", $2 / 1024}' /proc/meminfo
}

detect_cgroup_memory_limit_mb() {
    local value="" limit_file

    for limit_file in /sys/fs/cgroup/memory.max \
        /sys/fs/cgroup/memory/memory.limit_in_bytes; do
        [[ -r "$limit_file" ]] || continue
        value=$(<"$limit_file")
        [[ "$value" =~ ^[0-9]+$ ]] || continue
        (( value > 0 && value < 9223372036854771712 )) || continue
        printf '%d\n' "$((value / 1024 / 1024))"
        return 0
    done
    return 1
}

detect_effective_memory_mb() {
    local physical_mb="${1:-}" cgroup_mb=""

    [[ "$physical_mb" =~ ^[0-9]+$ ]] || physical_mb=$(detect_memory_mb)
    cgroup_mb=$(detect_cgroup_memory_limit_mb 2>/dev/null || true)
    if [[ "$cgroup_mb" =~ ^[0-9]+$ ]] && (( cgroup_mb > 0 && cgroup_mb < physical_mb )); then
        printf '%s\n' "$cgroup_mb"
    else
        printf '%s\n' "$physical_mb"
    fi
}

calculate_memory_cap() {
    local ram_mb="$1"
    local cap=$((ram_mb * 32768)) # 有效 RAM / 32
    local minimum=$((8 * 1024 * 1024)) maximum=$((256 * 1024 * 1024))

    (( cap < minimum )) && cap=$minimum
    (( cap > maximum )) && cap=$maximum
    echo "$cap"
}

calculate_tcp_mem() {
    local ram_mb="$1" page_size total_pages low pressure maximum
    local low_floor pressure_floor maximum_floor
    local mib=$((1024 * 1024))

    is_positive_integer "$ram_mb" 1 1073741824 || return 1
    page_size=$(getconf PAGESIZE 2>/dev/null) || return 1
    is_positive_integer "$page_size" 1 1073741824 || return 1
    ram_mb=$((10#$ram_mb))
    page_size=$((10#$page_size))
    total_pages=$((ram_mb * 1024 * 1024 / page_size))
    (( total_pages > 0 )) || return 1

    low=$((total_pages / 16))
    pressure=$((total_pages / 8))
    maximum=$((total_pages / 4))
    low_floor=$(((16 * mib + page_size - 1) / page_size))
    pressure_floor=$(((32 * mib + page_size - 1) / page_size))
    maximum_floor=$(((64 * mib + page_size - 1) / page_size))
    (( low >= low_floor )) || low=$low_floor
    (( pressure >= pressure_floor )) || pressure=$pressure_floor
    (( maximum >= maximum_floor )) || maximum=$maximum_floor
    (( low > 0 )) || return 1
    (( low < pressure )) || return 1
    (( pressure < maximum )) || return 1

    printf '%s %s %s\n' "$low" "$pressure" "$maximum"
}

cleanup_temp_dir() {
    local directory="$1" file

    for file in "$directory"/*; do
        [[ -e "$file" ]] || continue
        rm -f "$file"
    done
    rmdir "$directory" 2>/dev/null || true
}

register_probe_temp_path() {
    PROBE_TEMP_PATHS+=("$1")
}

unregister_probe_temp_path() {
    local wanted="$1" path
    local -a remaining=()

    for path in "${PROBE_TEMP_PATHS[@]}"; do
        [[ "$path" == "$wanted" ]] || remaining+=("$path")
    done
    PROBE_TEMP_PATHS=("${remaining[@]}")
}

cleanup_probe_temp_paths() {
    local path
    local -a paths=("${PROBE_TEMP_PATHS[@]}")

    for path in "${paths[@]}"; do
        if [[ -d "$path" ]]; then
            cleanup_temp_dir "$path"
        else
            rm -f -- "$path"
        fi
        unregister_probe_temp_path "$path"
    done
}

remove_probe_temp_path() {
    local path="$1"

    rm -f -- "$path"
    unregister_probe_temp_path "$path"
}

measure_ping_target() {
    local target="$1"
    ping -4 -c 3 -q -W 2 "$target" 2>/dev/null |
        awk -F/ '/rtt|round-trip/ {printf "%.0f\n", $5}'
}

classify_active_qdisc() {
    awk '
        $1 == "qdisc" && $4 == "root" && root == "" { root = $2 }
        $1 == "qdisc" && $4 == "parent" && $2 != "clsact" && $2 != "ingress" {
            leaves++
            if ($2 == "fq") fq++
            else {
                if (other != "") other = other ","
                other = other $2
            }
        }
        END {
            if (root == "") {
                print "unreadable|no qdisc data"
            } else if (root == "fq") {
                print "effective|root fq"
            } else if (root == "mq" || root == "htb") {
                if (leaves > 0 && fq == leaves) {
                    printf "effective|root %s; all %d leaves fq\n", root, leaves
                } else if (leaves == 0 && root == "mq") {
                    print "unreadable|root mq; no readable leaves"
                } else if (leaves == 0) {
                    print "inactive|root htb; no readable leaves"
                } else {
                    printf "mixed|root %s; fq leaves %d/%d", root, fq, leaves
                    if (other != "") printf "; other: %s", other
                    print ""
                }
            } else if (root == "noqueue") {
                print "inactive|root noqueue"
            } else {
                printf "inactive|root %s\n", root
            }
        }
    '
}

active_qdisc_state() {
    local iface="$1" output

    [[ -n "$iface" ]] || {
        printf '%s\n' 'unreadable|default interface unavailable'
        return 0
    }
    output=$(tc qdisc show dev "$iface" 2>/dev/null) || {
        printf '%s\n' 'unreadable|tc qdisc read failed'
        return 0
    }
    classify_active_qdisc <<< "$output"
}

format_qdisc_state() {
    local state="$1" detail_text

    detail_text=$(format_qdisc_detail "$2")
    case "$state" in
        effective) printf '生效（%s）\n' "$detail_text" ;;
        mixed) printf '混合/未完全生效（%s）\n' "$detail_text" ;;
        inactive) printf '未生效（%s）\n' "$detail_text" ;;
        *) printf '不可读（%s）\n' "$detail_text" ;;
    esac
}

route_value_after() {
    local key="$1"
    awk -v key="$key" '
        !found {
            for (i = 1; i < NF; i++) {
                if ($i == key) {
                    print $(i + 1)
                    found = 1
                    break
                }
            }
        }
    '
}

detect_default_iface() {
    local iface=""

    iface=$(ip -4 route get 1.1.1.1 2>/dev/null | route_value_after dev)
    if [[ -z "$iface" ]]; then
        iface=$(ip -4 route show default 2>/dev/null | route_value_after dev)
    fi

    [[ -n "$iface" && -d "/sys/class/net/$iface" ]] || return 1
    echo "$iface"
}

query_default_ipv4_route() {
    local routes

    routes=$(ip -4 route show default 2>/dev/null) || return 1
    routes="${routes%%$'\n'*}"
    printf '%s\n' "$routes"
}

default_ipv4_route() {
    query_default_ipv4_route
}

strip_route_window_fields() {
    local route="$1" skip=false token
    local -a fields=() clean=()

    read -r -a fields <<< "$route"
    for token in "${fields[@]}"; do
        if [[ "$skip" == "true" ]]; then
            skip=false
            continue
        fi
        case "$token" in
            initcwnd|initrwnd) skip=true ;;
            *) clean+=("$token") ;;
        esac
    done
    printf '%s\n' "${clean[*]}"
}

create_initcwnd_ownership_marker() {
    atomic_install_file /dev/null "$ROUTE_OWNED_MARKER" 0600 || return 1
}

remove_initcwnd_ownership_marker() {
    rm -f -- "$ROUTE_OWNED_MARKER" || return 1
}

write_route_snapshot() {
    local route="$1" backup="$2" absent="$3" owned="$4"

    if [[ -n "$route" ]]; then
        atomic_write_file "$backup" "$route" 0600 || return 1
        if [[ -e "$ROUTE_OWNED_MARKER" ]]; then
            atomic_write_file "$owned" "owned" 0600 || return 1
        else
            rm -f "$owned" || return 1
        fi
        rm -f "$absent"
    else
        atomic_write_file "$absent" "absent" 0600 || return 1
        rm -f "$backup" "$owned"
    fi
}

backup_default_route() {
    local route=""

    if ! route=$(query_default_ipv4_route); then
        error "读取 IPv4 默认路由失败"
        return 1
    fi
    install -d -m 0755 "$NETWORK_OPTIMIZE_STATE_DIR" || return 1
    write_route_snapshot "$route" "$ROUTE_PREVIOUS_BACKUP" \
        "$ROUTE_PREVIOUS_ABSENT" "$ROUTE_PREVIOUS_OWNED" || return 1

    if [[ ! -e "$ROUTE_INITIAL_BACKUP" && ! -e "$ROUTE_INITIAL_ABSENT" &&
        ! -e "$ROUTE_INITIAL_UNKNOWN" ]]; then
        write_route_snapshot "$route" "$ROUTE_INITIAL_BACKUP" \
            "$ROUTE_INITIAL_ABSENT" "$ROUTE_INITIAL_OWNED"
    fi
}

resolve_initcwnd_policy() {
    case "$INITCWND_MODE" in
        enabled)
            INITCWND_ENABLED="true"
            INITCWND_POLICY="explicit enabled"
            if [[ "$DETECTED_UPLOAD_MBPS" =~ ^[0-9]+$ ]] &&
                (( DETECTED_UPLOAD_MBPS <= INITCWND_AUTO_UPLOAD_LIMIT_MBPS )); then
                warn "上传带宽不高于 100 Mbps；--enable-initcwnd 仍将强制设置 initcwnd/initrwnd=32"
            fi
            ;;
        disabled)
            INITCWND_ENABLED="false"
            INITCWND_POLICY="explicit disabled"
            ;;
        auto)
            if [[ "$DETECTED_UPLOAD_MBPS" =~ ^[0-9]+$ ]] &&
                (( DETECTED_UPLOAD_MBPS > INITCWND_AUTO_UPLOAD_LIMIT_MBPS )); then
                INITCWND_ENABLED="true"
                INITCWND_POLICY="auto: upload > 100 Mbps, set 32"
            elif [[ "$DETECTED_UPLOAD_MBPS" =~ ^[0-9]+$ ]]; then
                INITCWND_ENABLED="false"
                INITCWND_POLICY="auto: upload <= 100 Mbps, preserve kernel default"
            else
                INITCWND_ENABLED="false"
                INITCWND_POLICY="auto: upload unknown, preserve kernel default"
            fi
            ;;
    esac
}

detect_initcwnd_state() {
    local route=""
    if ! route=$(default_ipv4_route); then
        printf '%s\n' 'unreadable|default route query failed'
        return 0
    fi
    if [[ -e "$ROUTE_OWNED_MARKER" ]]; then
        if grep -Eq '(^| )initcwnd 32( |$)' <<< "$route" &&
            grep -Eq '(^| )initrwnd 32( |$)' <<< "$route"; then
            printf '%s\n' 'effective|owned default route has initcwnd/initrwnd 32'
        else
            printf '%s\n' 'drift|ownership marker exists but default route lacks initcwnd/initrwnd 32'
        fi
    elif grep -Eq '(^| )initcwnd [0-9]+' <<< "$route"; then
        printf '%s\n' 'external|default route has unowned initcwnd/initrwnd settings'
    else
        printf '%s\n' 'default|kernel default; no ownership marker'
    fi
}

render_initcwnd_hook() {
    cat <<EOF
#!/usr/bin/env bash
# Managed by network-optimize.sh
# network-optimize:initcwnd-hook:v2
set -euo pipefail

[[ -e "$ROUTE_OWNED_MARKER" ]] || exit 0
routes=\$(ip -4 route show default 2>/dev/null || true)
route=\${routes%%\$'\\n'*}
[[ -n "\$route" ]] || exit 0
read -r -a fields <<< "\$route"
skip=false
clean=()
for token in "\${fields[@]}"; do
    if [[ "\$skip" == "true" ]]; then
        skip=false
        continue
    fi
    case "\$token" in
        initcwnd|initrwnd) skip=true ;;
        *) clean+=("\$token") ;;
    esac
done
(( \${#clean[@]} > 0 )) || exit 0
[[ -e "$ROUTE_OWNED_MARKER" ]] || exit 0
ip -4 route replace "\${clean[@]}" initcwnd 32 initrwnd 32
EOF
}

render_legacy_initcwnd_hook() {
    cat <<EOF
#!/usr/bin/env bash
# Managed by network-optimize.sh
# network-optimize:initcwnd-hook:v1
set -euo pipefail

[[ -e "$ROUTE_OWNED_MARKER" ]] || exit 0
routes=\$(ip -4 route show default 2>/dev/null || true)
route=\${routes%%\$'\\n'*}
[[ -n "\$route" ]] || exit 0
read -r -a fields <<< "\$route"
skip=false
clean=()
for token in "\${fields[@]}"; do
    if [[ "\$skip" == "true" ]]; then
        skip=false
        continue
    fi
    case "\$token" in
        initcwnd|initrwnd) skip=true ;;
        *) clean+=("\$token") ;;
    esac
done
(( \${#clean[@]} > 0 )) || exit 0
ip -4 route replace "\${clean[@]}" initcwnd 32 initrwnd 32
EOF
}

is_managed_initcwnd_hook() {
    local actual expected legacy

    [[ -f "$INITCWND_ROUTE_HOOK" ]] || return 1
    actual=$(<"$INITCWND_ROUTE_HOOK")
    expected=$(render_initcwnd_hook)
    [[ "$actual" == "$expected" ]] && return 0
    legacy=$(render_legacy_initcwnd_hook)
    [[ "$actual" == "$legacy" ]]
}

route_has_script_windows() {
    awk '
        {
            for (i = 1; i <= NF; i++) {
                if ($i == "initcwnd") {
                    cwnd_count++
                    if ($(i + 1) != "32") bad = 1
                } else if ($i == "initrwnd") {
                    rwnd_count++
                    if ($(i + 1) != "32") bad = 1
                }
            }
        }
        END { exit !(bad == 0 && cwnd_count == 1 && rwnd_count == 1) }
    ' <<< "$1"
}

route_snapshot_proves_no_windows() {
    local route_file="$1" unknown_marker="${2:-}" current_route snapshot_route

    [[ -f "$route_file" ]] || return 1
    [[ -z "$unknown_marker" || ! -e "$unknown_marker" ]] || return 1
    snapshot_route=$(<"$route_file")
    [[ -n "$snapshot_route" ]] || return 1
    ! grep -Eq '(^| )(initcwnd|initrwnd) [0-9]+( |$)' <<< "$snapshot_route" || return 1

    current_route=$(default_ipv4_route) || return 1
    [[ -n "$current_route" ]] || return 1
    route_has_script_windows "$current_route" || return 1
    [[ "$(strip_route_window_fields "$current_route")" == "$snapshot_route" ]]
}

initcwnd_settings_owned() {
    [[ -e "$ROUTE_OWNED_MARKER" ]] && return 0
    is_managed_initcwnd_hook && return 0
    route_snapshot_proves_no_windows "$ROUTE_PREVIOUS_BACKUP" && return 0
    route_snapshot_proves_no_windows "$ROUTE_INITIAL_BACKUP" "$ROUTE_INITIAL_UNKNOWN"
}

initcwnd_hook_status() {
    if is_managed_initcwnd_hook; then
        printf '%s\n' '已安装（network-optimize 管理）'
    elif [[ -e "$INITCWND_ROUTE_HOOK" || -L "$INITCWND_ROUTE_HOOK" ]]; then
        printf '%s\n' '外部文件占用'
    elif [[ -d "$(dirname "$INITCWND_ROUTE_HOOK")" ]]; then
        printf '%s\n' '未安装'
    else
        printf '%s\n' '不可用（未检测到 networkd-dispatcher）'
    fi
}

remove_initcwnd_hook() {
    [[ -e "$INITCWND_ROUTE_HOOK" || -L "$INITCWND_ROUTE_HOOK" ]] || return 0
    if ! is_managed_initcwnd_hook; then
        warn "initcwnd 持久化路径已被其他配置占用，保留不动：$INITCWND_ROUTE_HOOK"
        return 0
    fi
    rm -f "$INITCWND_ROUTE_HOOK"
}

write_initcwnd_hook() {
    local hook_dir content

    hook_dir=$(dirname "$INITCWND_ROUTE_HOOK")
    if [[ ! -d "$hook_dir" ]]; then
        warn "警告：未检测到 networkd-dispatcher；initcwnd=32 仅对当前默认路由生效"
        return 0
    fi
    if [[ -e "$INITCWND_ROUTE_HOOK" || -L "$INITCWND_ROUTE_HOOK" ]] &&
        ! is_managed_initcwnd_hook; then
        error "initcwnd 持久化路径已被其他配置占用：$INITCWND_ROUTE_HOOK"
        return 1
    fi

    content=$(render_initcwnd_hook) || return 1
    atomic_write_file "$INITCWND_ROUTE_HOOK" "$content" 0755 false
}

# Generated hook uses clean as an array; apply path intentionally shadows it as a string.
# shellcheck disable=SC2128,SC2178
apply_initcwnd() {
    local route="" clean=""
    local -a route_args=()

    if [[ "$INITCWND_ENABLED" != "true" ]]; then
        if ! initcwnd_settings_owned; then
            warn "当前默认路由的 initcwnd/initrwnd 无本脚本 ownership 证据，保留不动"
            return 0
        fi
        if ! route=$(default_ipv4_route); then
            error "读取 IPv4 默认路由失败"
            return 1
        fi
        if [[ -n "$route" ]] &&
            grep -Eq '(^| )(initcwnd|initrwnd) [0-9]+( |$)' <<< "$route"; then
            clean=$(strip_route_window_fields "$route")
            read -r -a route_args <<< "$clean"
            ip -4 route replace "${route_args[@]}" || {
                error "清理本脚本拥有的 initcwnd/initrwnd 失败"
                return 1
            }
        fi
        if ! remove_initcwnd_ownership_marker; then
            error "删除 initcwnd ownership marker 失败"
            return 1
        fi
        if ! remove_initcwnd_hook; then
            error "移除本脚本 initcwnd 持久化钩子失败"
            return 1
        fi
        return 0
    fi
    if ! route=$(default_ipv4_route); then
        error "读取 IPv4 默认路由失败"
        return 1
    fi
    [[ -n "$route" ]] || {
        warn "未找到 IPv4 默认路由，跳过 initcwnd/initrwnd"
        return 0
    }
    clean=$(strip_route_window_fields "$route")
    read -r -a route_args <<< "$clean"
    if ! ip -4 route replace "${route_args[@]}" initcwnd 32 initrwnd 32; then
        error "默认路由不支持 initcwnd/initrwnd，网络 sysctl 已应用但路由优化失败"
        return 1
    fi
    if ! create_initcwnd_ownership_marker; then
        error "创建 initcwnd ownership marker 失败"
        return 1
    fi
    if ! write_initcwnd_hook; then
        error "无法写入 initcwnd 持久化钩子"
        return 1
    fi
}

# Generated hook uses clean as an array; restore path shadows it as a string.
# shellcheck disable=SC2128,SC2178
restore_default_route() {
    local route_file="$1" owned_file="${2:-}" absent_file="${3:-}" route="" clean=""
    local -a route_args=()

    if [[ ! -f "$route_file" ]]; then
        initcwnd_settings_owned || return 0
        route=$(default_ipv4_route) || return 1
        if [[ -z "$route" ]]; then
            remove_initcwnd_ownership_marker || return 1
            return 0
        fi
        if [[ -n "$absent_file" && -e "$absent_file" ]]; then
            if grep -Eq '(^| )(initcwnd|initrwnd) [0-9]+( |$)' <<< "$route"; then
                clean=$(strip_route_window_fields "$route")
                read -r -a route_args <<< "$clean"
                (( ${#route_args[@]} > 0 )) || return 1
                ip -4 route replace "${route_args[@]}" || return 1
            fi
            remove_initcwnd_ownership_marker || return 1
            return 0
        fi
        route=$(strip_route_window_fields "$route")
    fi
    [[ -n "$route" ]] || route=$(<"$route_file")
    read -r -a route_args <<< "$route"
    (( ${#route_args[@]} > 0 )) || return 1
    ip -4 route replace "${route_args[@]}" || return 1
    if [[ -n "$owned_file" && -e "$owned_file" ]]; then
        create_initcwnd_ownership_marker || return 1
    else
        remove_initcwnd_ownership_marker || return 1
    fi
}

detect_ipv4_iface_for_target() {
    local target="$1" iface

    iface=$(ip -4 route get "$target" 2>/dev/null | route_value_after dev)
    [[ -n "$iface" ]] || return 1
    printf '%s\n' "$iface"
}

read_iface_counter() {
    local iface="$1" direction="$2"
    cat "/sys/class/net/$iface/statistics/${direction}_bytes" 2>/dev/null
}

traffic_reset() {
    PROBE_IFACE=""
    PROBE_ENVIRONMENT_SHOWN_BY_IFACE=()
    TRAFFIC_IFACES=()
    TRAFFIC_RX_START_BY_IFACE=()
    TRAFFIC_TX_START_BY_IFACE=()
}

traffic_add_target() {
    local target="$1" iface rx tx

    iface=$(detect_ipv4_iface_for_target "$target") || return 1
    PROBE_IFACE="$iface"
    if [[ -n "${TRAFFIC_RX_START_BY_IFACE[$iface]+x}" ]]; then
        return 0
    fi

    rx=$(read_iface_counter "$iface" rx) || return 1
    tx=$(read_iface_counter "$iface" tx) || return 1
    is_positive_integer "$rx" 0 9223372036854775807 || return 1
    is_positive_integer "$tx" 0 9223372036854775807 || return 1
    TRAFFIC_IFACES+=("$iface")
    TRAFFIC_RX_START_BY_IFACE["$iface"]="$rx"
    TRAFFIC_TX_START_BY_IFACE["$iface"]="$tx"
}

traffic_mark() {
    traffic_reset
}

traffic_used_bytes() {
    local direction="${1:-total}" iface rx tx rx_used tx_used total_rx=0 total_tx=0

    (( ${#TRAFFIC_IFACES[@]} > 0 )) || return 1
    for iface in "${TRAFFIC_IFACES[@]}"; do
        rx=$(read_iface_counter "$iface" rx) || return 1
        tx=$(read_iface_counter "$iface" tx) || return 1
        [[ "$rx" =~ ^[0-9]+$ && "$tx" =~ ^[0-9]+$ ]] || return 1
        rx_used=$((rx - TRAFFIC_RX_START_BY_IFACE[$iface]))
        tx_used=$((tx - TRAFFIC_TX_START_BY_IFACE[$iface]))
        (( rx_used < 0 )) && rx_used=0
        (( tx_used < 0 )) && tx_used=0
        total_rx=$((total_rx + rx_used))
        total_tx=$((total_tx + tx_used))
    done

    case "$direction" in
        download) echo "$total_rx" ;;
        upload) echo "$total_tx" ;;
        total) echo $((total_rx + total_tx)) ;;
        *) return 1 ;;
    esac
}

format_bytes() {
    awk -v bytes="$1" 'BEGIN {
        if (bytes >= 1000000000) printf "%.2f GB", bytes / 1000000000
        else printf "%.0f MB", bytes / 1000000
    }'
}

traffic_report() {
    local rx tx total interfaces

    (( ${#TRAFFIC_IFACES[@]} > 0 )) || return 0
    rx=$(traffic_used_bytes download || echo 0)
    tx=$(traffic_used_bytes upload || echo 0)
    total=$((rx + tx))
    interfaces=$(IFS=,; echo "${TRAFFIC_IFACES[*]}")
    echo "流量：$interfaces；上传 $(format_bytes "$tx") / 下载 $(format_bytes "$rx") / 合计 $(format_bytes "$total")（包含同期后台流量）"
}

traffic_budget_reached() {
    local direction="$1" total directional

    (( ${#TRAFFIC_IFACES[@]} > 0 )) || return 1
    total=$(traffic_used_bytes total) || return 0
    directional=$(traffic_used_bytes "$direction") || return 0
    (( total >= TRAFFIC_TOTAL_LIMIT_BYTES ||
       directional >= TRAFFIC_DIRECTION_LIMIT_BYTES ))
}

register_tracked_pid() {
    local -n tracked="$1"
    tracked+=("$2")
}

# shellcheck disable=SC2178
unregister_tracked_pid() {
    local list_name="$1" wanted="$2" pid
    local -n tracked="$list_name"
    local -a remaining=()

    for pid in "${tracked[@]}"; do
        [[ "$pid" == "$wanted" ]] || remaining+=("$pid")
    done
    tracked=("${remaining[@]}")
}

terminate_recorded_pid() {
    local pid="$1" kill_after="${2:-$IPERF_KILL_AFTER_SECONDS}" attempt state=""
    local running="true"

    [[ "$pid" =~ ^[0-9]+$ ]] || return 0
    kill -TERM "$pid" 2>/dev/null || true
    for ((attempt = 0; attempt < kill_after * 10; attempt++)); do
        if ! kill -0 "$pid" 2>/dev/null; then
            running="false"
            break
        fi
        state=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || true)
        if [[ "$state" == "Z" ]]; then
            running="false"
            break
        fi
        sleep 0.1
    done
    [[ "$running" != "true" ]] || kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}

# shellcheck disable=SC2178
cleanup_tracked_pids() {
    local list_name="$1" pid
    local -n tracked="$list_name"
    local -a pids=("${tracked[@]}")

    for pid in "${pids[@]}"; do
        terminate_recorded_pid "$pid"
        unregister_tracked_pid "$list_name" "$pid"
    done
}

cleanup_probe_processes() {
    cleanup_tracked_pids IPERF_RUNNER_PIDS
    cleanup_probe_temp_paths
}

run_iperf_runner() {
    local output_file="$1" host="$2" port="$3" duration="$4" streams="$5" direction="$6" reverse_mode="${7:-false}"
    local deadline=$((duration + IPERF_DEADLINE_GRACE_SECONDS)) pid rc=0 limited="false"
    local -a reverse=()

    [[ "$reverse_mode" == "true" ]] && reverse=(-R)
    traffic_add_target "$host" || return 1
    traffic_budget_reached "$direction" && return 75

    timeout --foreground --signal=TERM --kill-after="${IPERF_KILL_AFTER_SECONDS}s" \
        "${deadline}s" iperf3 -4 -c "$host" -p "$port" -t "$duration" \
        -P "$streams" "${reverse[@]}" -J > "$output_file" 2>&1 &
    pid=$!
    register_tracked_pid IPERF_RUNNER_PIDS "$pid"

    while kill -0 "$pid" 2>/dev/null; do
        if traffic_budget_reached "$direction"; then
            limited="true"
            terminate_recorded_pid "$pid"
            break
        fi
        sleep 0.05
    done
    if [[ "$limited" != "true" ]]; then
        wait "$pid" || rc=$?
    else
        rc=75
    fi
    unregister_tracked_pid IPERF_RUNNER_PIDS "$pid"
    return "$rc"
}

resolve_ipv4() {
    getent ahostsv4 "$1" 2>/dev/null |
        awk '/STREAM/ && !found {print $1; found = 1}'
}

ordered_iperf_ports() {
    local port

    [[ -n "$PREFERRED_IPERF_PORT" ]] && echo "$PREFERRED_IPERF_PORT"
    for port in "${IPERF_PORTS[@]}"; do
        [[ "$port" == "$PREFERRED_IPERF_PORT" ]] || echo "$port"
    done
}

rank_iperf_peers() {
    local temp_dir host peer_ip location provider index=0 file

    command -v ping >/dev/null 2>&1 || return 1
    temp_dir=$(mktemp -d) || return 1
    register_probe_temp_path "$temp_dir"

    while IFS='|' read -r host location provider; do
        [[ -n "$host" ]] || continue
        ((index += 1))
        (
            peer_ip=$(resolve_ipv4 "$host" || true)
            [[ -n "$peer_ip" ]] || exit 0
            measurement_peer_route_matches "$peer_ip" || exit 0
            local_rtt=$(measure_ping_target "$peer_ip" || true)
            [[ -n "$local_rtt" ]] &&
                printf '%s|%s|%s|%s|%s\n' \
                    "$local_rtt" "$host" "$peer_ip" "$location" "$provider" \
                    > "$temp_dir/$index"
        ) &
    done <<< "$IPERF_PEER_POOL"
    wait || true

    RANKED_IPERF_PEERS=$(for file in "$temp_dir"/*; do
        [[ -s "$file" ]] || continue
        cat "$file"
    done | sort -t '|' -k1,1n)
    cleanup_temp_dir "$temp_dir"
    unregister_probe_temp_path "$temp_dir"
}

tcp_port_open() {
    local ipv4="$1" port="$2"
    timeout 3 bash -c "exec 3<>/dev/tcp/$ipv4/$port" 2>/dev/null
}

run_iperf_test() {
    local host="$1" port="$2" direction="$3" output stats rc=0 reverse_mode="false"
    local receiver retransmits retransmit_percent cpu remote_cpu

    IPERF_TEST_RESULT=""
    [[ "$direction" == "download" ]] && reverse_mode="true"
    output=$(mktemp) || return 1
    register_probe_temp_path "$output"
    run_iperf_runner "$output" "$host" "$port" "$IPERF_DURATION" \
        "$IPERF_PARALLEL" "$direction" "$reverse_mode" || rc=$?
    if (( rc != 0 )); then
        remove_probe_temp_path "$output"
        return "$rc"
    fi
    stats=$(parse_iperf_metrics "$output") || {
        remove_probe_temp_path "$output"
        return 1
    }
    remove_probe_temp_path "$output"
    IFS='|' read -r _ receiver retransmits retransmit_percent cpu remote_cpu <<< "$stats"

    # goodput、CPU、重传与 loss 全部取自同一份完整 JSON 结果。
    IPERF_TEST_RESULT=$(printf '%s|%s|%s|%s\n' \
        "$receiver" "$cpu" "$retransmits" "$retransmit_percent")
}

format_cpu_percent() {
    if [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        awk -v value="$1" 'BEGIN {printf "%.1f", value}'
    else
        echo "?"
    fi
}

parse_iperf_metrics() {
    local output_file="$1" stats sender_bps receiver_bps sent_bytes retransmits mss host_cpu remote_cpu
    local retransmit_percent

    stats=$(jq -r '
        [
            (.end.sum_sent.bits_per_second // ""),
            (.end.sum_received.bits_per_second // ""),
            (.end.sum_sent.bytes // ""),
            (.end.sum_sent.retransmits // ""),
            (.start.tcp_mss_default // 1448),
            (.end.cpu_utilization_percent.host_total // ""),
            (.end.cpu_utilization_percent.remote_total // "")
        ] | join("|")
    ' "$output_file" 2>/dev/null) || return 1
    IFS='|' read -r sender_bps receiver_bps sent_bytes retransmits mss host_cpu remote_cpu <<< "$stats"
    [[ "$sender_bps" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
    [[ "$receiver_bps" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1

    retransmit_percent="?"
    if [[ "$retransmits" =~ ^[0-9]+$ && "$sent_bytes" =~ ^[0-9]+$ &&
          "$mss" =~ ^[0-9]+$ ]] && (( sent_bytes > 0 && mss > 0 )); then
        retransmit_percent=$(awk -v retransmits="$retransmits" \
            -v bytes="$sent_bytes" -v mss="$mss" '
            BEGIN {printf "%.4f", retransmits * 100 / (bytes / mss)}
        ')
    fi

    printf '%s|%s|%s|%s|%s|%s\n' \
        "$(awk -v bps="$sender_bps" 'BEGIN {printf "%.0f", bps / 1000000}')" \
        "$(awk -v bps="$receiver_bps" 'BEGIN {printf "%.0f", bps / 1000000}')" \
        "${retransmits:-?}" "$retransmit_percent" \
        "$(format_cpu_percent "$host_cpu")" "$(format_cpu_percent "$remote_cpu")"
}

current_epoch() {
    date +%s
}

format_measurement_epoch() {
    date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf '%s\n' "$1"
}

add_measurement_warning() {
    local message="$1"

    [[ -n "$message" ]] || return 0
    if [[ "; $MEASUREMENT_WARNINGS; " != *"; $message; "* ]]; then
        MEASUREMENT_WARNINGS="${MEASUREMENT_WARNINGS:+$MEASUREMENT_WARNINGS; }$message"
        detail "measurement warning: $message"
    fi
    MEASUREMENT_CONFIDENCE="low"
}

show_measurement_warnings() {
    local warning

    [[ -n "$MEASUREMENT_WARNINGS" ]] || return 0
    while IFS= read -r warning; do
        [[ -n "$warning" ]] && warn "警告：$(format_measurement_warning "$warning")"
    done < <(printf '%s\n' "$MEASUREMENT_WARNINGS" | sed 's/;[[:space:]]*/\n/g')
}

read_iface_ifindex() {
    cat "/sys/class/net/$1/ifindex" 2>/dev/null
}

route_identity_for_target() {
    local target="$1" route iface gateway source ifindex

    route=$(ip -4 route get "$target" 2>/dev/null) || return 1
    iface=$(route_value_after dev <<< "$route")
    gateway=$(route_value_after via <<< "$route")
    source=$(route_value_after src <<< "$route")
    [[ -n "$iface" && -n "$source" ]] || return 1
    ifindex=$(read_iface_ifindex "$iface") || return 1
    [[ "$ifindex" =~ ^[0-9]+$ ]] || return 1
    [[ -n "$gateway" ]] || gateway="direct"
    printf '%s|%s|%s|%s\n' "$ifindex" "$iface" "$gateway" "$source"
}

validate_measurement_route() {
    local current_identity

    [[ "$TUNING_MODE" == "manual" ]] && return 0
    [[ "$TUNING_MODE" == "auto" ]] || return 1
    [[ "$MEASUREMENT_ROUTE_TARGET" == "$MEASUREMENT_ROUTE_PROBE_TARGET" ]] || return 1
    [[ -n "$MEASUREMENT_ROUTE_IDENTITY" ]] || return 1
    current_identity=$(route_identity_for_target "$MEASUREMENT_ROUTE_TARGET" || true)
    [[ -n "$current_identity" && "$current_identity" == "$MEASUREMENT_ROUTE_IDENTITY" ]]
}

measurement_peer_route_matches() {
    local peer_ip="$1" peer_identity current_identity

    [[ -n "$MEASUREMENT_ROUTE_IDENTITY" ]] || return 1
    peer_identity=$(route_identity_for_target "$peer_ip" || true)
    current_identity=$(route_identity_for_target \
        "$MEASUREMENT_ROUTE_TARGET" || true)
    [[ -n "$peer_identity" && "$peer_identity" == "$MEASUREMENT_ROUTE_IDENTITY" &&
        "$current_identity" == "$MEASUREMENT_ROUTE_IDENTITY" ]]
}

cache_field() {
    local file="$1" key="$2"

    awk -v wanted="$key" '
        index($0, wanted "=") == 1 {
            print substr($0, length(wanted) + 2)
            exit
        }
    ' "$file"
}

sanitize_cache_value() {
    printf '%s' "$1" | tr '\n\r' '  '
}

write_measurement_cache() {
    local ifindex iface gateway source warnings content

    [[ "$MEASUREMENT_ROUTE_TARGET" == "$MEASUREMENT_ROUTE_PROBE_TARGET" &&
        -n "$MEASUREMENT_ROUTE_IDENTITY" ]] || return 1
    IFS='|' read -r ifindex iface gateway source <<< "$MEASUREMENT_ROUTE_IDENTITY"
    [[ "$ifindex" =~ ^[0-9]+$ && -n "$iface" && -n "$gateway" && -n "$source" ]] || return 1
    warnings=${MEASUREMENT_WARNINGS:-none}
    content="version=$CACHE_FORMAT_VERSION
saved_at=$MEASUREMENT_EPOCH
measured_at=$(sanitize_cache_value "$MEASUREMENT_TIME")
download_mbps=$DETECTED_DOWNLOAD_MBPS
upload_mbps=$DETECTED_UPLOAD_MBPS
source=$(sanitize_cache_value "$MEASUREMENT_SOURCE")
nodes=$(sanitize_cache_value "$MEASUREMENT_NODES")
confidence=$(sanitize_cache_value "$MEASUREMENT_CONFIDENCE")
warnings=$(sanitize_cache_value "$warnings")
route_target=$MEASUREMENT_ROUTE_TARGET
ifindex=$ifindex
iface=$iface
gateway=$gateway
source_address=$source"
    atomic_write_file "$MEASUREMENT_CACHE" "$content" 0600
}

persist_pending_measurement_cache() {
    [[ "$MEASUREMENT_CACHE_PENDING" == "true" ]] || return 0
    MEASUREMENT_CACHE_PENDING="false"
    if ! write_measurement_cache; then
        add_measurement_warning "failed to persist the route-bound measurement cache"
    fi
}

load_measurement_cache() {
    local mode="$2" now saved_at age version download upload source nodes
    local confidence warnings target ifindex iface gateway source_address cached_identity current_identity measured_at

    [[ -f "$MEASUREMENT_CACHE" ]] || return 1
    version=$(cache_field "$MEASUREMENT_CACHE" version)
    saved_at=$(cache_field "$MEASUREMENT_CACHE" saved_at)
    download=$(cache_field "$MEASUREMENT_CACHE" download_mbps)
    upload=$(cache_field "$MEASUREMENT_CACHE" upload_mbps)
    target=$(cache_field "$MEASUREMENT_CACHE" route_target)
    ifindex=$(cache_field "$MEASUREMENT_CACHE" ifindex)
    iface=$(cache_field "$MEASUREMENT_CACHE" iface)
    gateway=$(cache_field "$MEASUREMENT_CACHE" gateway)
    source_address=$(cache_field "$MEASUREMENT_CACHE" source_address)
    [[ "$version" == "$CACHE_FORMAT_VERSION" ]] || return 1
    is_positive_integer "$saved_at" 1 9223372036854775807 || return 1
    is_positive_integer "$download" 1 100000 || return 1
    is_positive_integer "$upload" 1 100000 || return 1
    [[ "$target" == "$MEASUREMENT_ROUTE_PROBE_TARGET" ]] || return 1
    [[ "$ifindex" =~ ^[0-9]+$ && -n "$iface" &&
        -n "$gateway" && -n "$source_address" ]] || return 1

    now=$(current_epoch)
    is_positive_integer "$now" 1 9223372036854775807 || return 1
    age=$((now - saved_at))
    (( age >= 0 )) || return 1
    case "$mode" in
        fresh)
            (( age <= CACHE_FRESH_MAX_AGE_SECONDS )) || return 1
            ;;
        stale)
            (( age > CACHE_FRESH_MAX_AGE_SECONDS &&
               age <= CACHE_STALE_MAX_AGE_SECONDS )) || return 1
            ;;
        fallback)
            (( age <= CACHE_STALE_MAX_AGE_SECONDS )) || return 1
            ;;
        *) return 1 ;;
    esac

    cached_identity="$ifindex|$iface|$gateway|$source_address"
    current_identity=$(route_identity_for_target "$target" || true)
    [[ -n "$current_identity" && "$current_identity" == "$cached_identity" ]] || {
        detail "测速缓存路由不匹配，忽略缓存"
        return 1
    }

    source=$(cache_field "$MEASUREMENT_CACHE" source)
    nodes=$(cache_field "$MEASUREMENT_CACHE" nodes)
    confidence=$(cache_field "$MEASUREMENT_CACHE" confidence)
    warnings=$(cache_field "$MEASUREMENT_CACHE" warnings)
    measured_at=$(cache_field "$MEASUREMENT_CACHE" measured_at)
    [[ "$warnings" != "none" ]] || warnings=""

    DETECTED_DOWNLOAD_MBPS="$download"
    DETECTED_UPLOAD_MBPS="$upload"
    MEASUREMENT_EPOCH="$saved_at"
    MEASUREMENT_TIME="${measured_at:-$(format_measurement_epoch "$saved_at")}"
    MEASUREMENT_NODES="${nodes:-unknown}"
    MEASUREMENT_CONFIDENCE="${confidence:-low}"
    MEASUREMENT_WARNINGS="$warnings"
    MEASUREMENT_ROUTE_TARGET="$target"
    MEASUREMENT_ROUTE_IDENTITY="$current_identity"
    MEASUREMENT_CACHE_PENDING="false"
    PROBE_IFACE="$iface"
    if [[ "$mode" == "fresh" ]]; then
        MEASUREMENT_SOURCE="7-day route-bound cache (${source:-public iperf3})"
    elif (( age <= CACHE_FRESH_MAX_AGE_SECONDS )); then
        MEASUREMENT_SOURCE="same-route fresh cache fallback (${source:-public iperf3})"
    else
        MEASUREMENT_SOURCE="same-route stale cache (${source:-public iperf3})"
    fi
    if [[ "$mode" != "fresh" ]]; then
        add_measurement_warning "live public iperf3 measurement failed, reused same-route cache no older than 30 days"
    fi
    BANDWIDTH_SOURCE="$MEASUREMENT_SOURCE"
}

max_integer_value() {
    local value maximum=0

    for value in "$@"; do
        (( value > maximum )) && maximum=$value
    done
    printf '%s\n' "$maximum"
}

measurements_diverge_over_30_percent() {
    local first="$1" second="$2" low high

    if (( first < second )); then
        low=$first
        high=$second
    else
        low=$second
        high=$first
    fi
    (( high * 100 > low * 130 ))
}

probe_iperf_bandwidth() {
    local ranked rtt host peer_ip location provider port upload_result download_result
    local upload upload_cpu upload_retransmits upload_retransmit_percent
    local download download_cpu download_retransmits download_retransmit_percent
    local upload_rc download_rc node node_detail budget_stopped="false"
    local successful_peers=0
    local -a upload_values=() download_values=() nodes=()

    command -v iperf3 >/dev/null 2>&1 || return 1
    command -v jq >/dev/null 2>&1 || return 1
    command -v timeout >/dev/null 2>&1 || return 1

    MEASUREMENT_WARNINGS=""
    MEASUREMENT_CONFIDENCE="high"
    MEASUREMENT_CACHE_PENDING="false"
    MEASUREMENT_ROUTE_TARGET="$MEASUREMENT_ROUTE_PROBE_TARGET"
    MEASUREMENT_ROUTE_IDENTITY=$(route_identity_for_target \
        "$MEASUREMENT_ROUTE_TARGET" || true)
    [[ -n "$MEASUREMENT_ROUTE_IDENTITY" ]] || return 1
    rank_iperf_peers || return 1
    ranked="$RANKED_IPERF_PEERS"
    [[ -n "$ranked" ]] || return 1

    while IFS='|' read -r rtt host peer_ip location provider; do
        [[ -n "$host" && -n "$peer_ip" ]] || continue
        if ! measurement_peer_route_matches "$peer_ip"; then
            detail "skip cross-route iperf3 peer before test: $peer_ip"
            continue
        fi
        if traffic_budget_reached upload && traffic_budget_reached download; then
            budget_stopped="true"
            break
        fi

        while IFS= read -r port; do
            traffic_add_target "$peer_ip" || continue
            show_probe_environment_once
            tcp_port_open "$peer_ip" "$port" || continue

            upload_result=""
            download_result=""
            upload_rc=0
            download_rc=0
            if traffic_budget_reached upload; then
                upload_rc=75
            else
                if ! measurement_peer_route_matches "$peer_ip"; then
                    detail "skip iperf3 upload after route identity changed: $peer_ip"
                    break
                fi
                if run_iperf_test "$peer_ip" "$port" upload; then
                    upload_result="$IPERF_TEST_RESULT"
                else
                    upload_rc=$?
                fi
            fi
            if traffic_budget_reached download; then
                download_rc=75
            else
                if ! measurement_peer_route_matches "$peer_ip"; then
                    detail "skip iperf3 download after route identity changed: $peer_ip"
                    break
                fi
                if run_iperf_test "$peer_ip" "$port" download; then
                    download_result="$IPERF_TEST_RESULT"
                else
                    download_rc=$?
                fi
            fi
            (( upload_rc != 75 && download_rc != 75 )) || budget_stopped="true"

            if ! measurement_peer_route_matches "$peer_ip"; then
                detail "skip iperf3 sample after route identity changed: $peer_ip"
                break
            fi

            upload=""
            upload_cpu=""
            upload_retransmits=""
            upload_retransmit_percent=""
            download=""
            download_cpu=""
            download_retransmits=""
            download_retransmit_percent=""
            if [[ -n "$upload_result" ]]; then
                IFS='|' read -r upload upload_cpu upload_retransmits upload_retransmit_percent <<< "$upload_result"
                is_positive_integer "$upload" 1 100000 || upload=""
            fi
            if [[ -n "$download_result" ]]; then
                IFS='|' read -r download download_cpu download_retransmits download_retransmit_percent <<< "$download_result"
                is_positive_integer "$download" 1 100000 || download=""
            fi
            [[ -n "$upload$download" ]] || continue

            upload_cpu=$(format_cpu_percent "$upload_cpu")
            download_cpu=$(format_cpu_percent "$download_cpu")
            PREFERRED_IPERF_PORT="$port"
            node="$location/$provider $host [$peer_ip]:$port (IPv4 RTT ${rtt} ms)"
            nodes+=("$node")
            [[ -z "$upload" ]] || upload_values+=("$upload")
            [[ -z "$download" ]] || download_values+=("$download")
            ((successful_peers += 1))
            detail "iperf3 node: $node"
            node_detail="download ${download:-failed} Mbps "
            node_detail+="(CPU ${download_cpu:-?}% / "
            node_detail+="retransmit ${download_retransmit_percent:-?}% "
            node_detail+="[${download_retransmits:-?}]); "
            node_detail+="upload ${upload:-failed} Mbps "
            node_detail+="(CPU ${upload_cpu:-?}% / "
            node_detail+="retransmit ${upload_retransmit_percent:-?}% "
            node_detail+="[${upload_retransmits:-?}])"
            detail "node result: $node_detail"

            break
        done < <(ordered_iperf_ports)

        (( successful_peers >= IPERF_MAX_PEERS )) && break
    done <<< "$ranked"

    (( ${#upload_values[@]} > 0 && ${#download_values[@]} > 0 )) || return 1
    validate_measurement_route || return 1
    DETECTED_UPLOAD_MBPS=$(max_integer_value "${upload_values[@]}")
    DETECTED_DOWNLOAD_MBPS=$(max_integer_value "${download_values[@]}")
    MEASUREMENT_NODES=$(IFS=';'; printf '%s' "${nodes[*]}")
    MEASUREMENT_EPOCH=$(current_epoch)
    MEASUREMENT_TIME=$(format_measurement_epoch "$MEASUREMENT_EPOCH")
    MEASUREMENT_SOURCE="public iperf3 IPv4 (P=$IPERF_PARALLEL, t=${IPERF_DURATION}s)"
    BANDWIDTH_SOURCE="$MEASUREMENT_SOURCE"

    if (( successful_peers < IPERF_MAX_PEERS )); then
        add_measurement_warning "only one public iperf3 peer produced a usable result"
    fi
    if (( ${#upload_values[@]} < IPERF_MAX_PEERS )); then
        add_measurement_warning "upload has fewer than two valid peer samples"
    elif measurements_diverge_over_30_percent "${upload_values[0]}" "${upload_values[1]}"; then
        add_measurement_warning "upload peer results differ by more than 30%, using the higher valid result"
    fi
    if (( ${#download_values[@]} < IPERF_MAX_PEERS )); then
        add_measurement_warning "download has fewer than two valid peer samples"
    elif measurements_diverge_over_30_percent "${download_values[0]}" "${download_values[1]}"; then
        add_measurement_warning "download peer results differ by more than 30%, using the higher valid result"
    fi
    [[ "$budget_stopped" != "true" ]] ||
        add_measurement_warning "traffic budget stopped additional public iperf3 tests"
}

round_bandwidth() {
    local measured="$1" rounded

    if (( measured < 50 )); then
        rounded="$measured"
    elif (( measured < 200 )); then
        rounded=$((((measured + 5) / 10) * 10))
    else
        rounded=$((((measured + 25) / 50) * 50))
    fi
    (( rounded < 1 )) && rounded=1
    (( rounded > 100000 )) && rounded=100000
    echo "$rounded"
}

show_probe_environment() {
    local iface="${1:-$PROBE_IFACE}" driver="virtual" rx_queues tx_queues current_cc default_qdisc root_qdisc
    local driver_path

    [[ -n "$iface" ]] || return 1
    driver_path=$(readlink -f "/sys/class/net/$iface/device/driver" 2>/dev/null || true)
    [[ -n "$driver_path" ]] && driver="${driver_path##*/}"
    rx_queues=$(find "/sys/class/net/$iface/queues" -maxdepth 1 -name 'rx-*' 2>/dev/null | wc -l)
    tx_queues=$(find "/sys/class/net/$iface/queues" -maxdepth 1 -name 'tx-*' 2>/dev/null | wc -l)
    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)
    default_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)
    root_qdisc=$(tc qdisc show dev "$iface" 2>/dev/null | awk 'NR == 1 {print $2}')

    detail "测速环境：接口 $iface / 驱动 $driver / RX-TX 队列 ${rx_queues}-${tx_queues}"
    detail "测速前网络栈：CC $current_cc / default_qdisc $default_qdisc / root_qdisc ${root_qdisc:-unknown}"
    if [[ "$root_qdisc" == "htb" ]]; then
        BANDWIDTH_PROBE_NOTE="检测到活动的根 HTB 队列，当前限速可能导致测速结果偏低。"
        add_measurement_warning "$BANDWIDTH_PROBE_NOTE"
        warn "$BANDWIDTH_PROBE_NOTE"
    fi
}

show_probe_environment_once() {
    local iface="${PROBE_IFACE:-}"

    [[ -n "$iface" ]] || return 0
    [[ -z "${PROBE_ENVIRONMENT_SHOWN_BY_IFACE[$iface]+x}" ]] || return 0
    show_probe_environment "$iface"
    PROBE_ENVIRONMENT_SHOWN_BY_IFACE["$iface"]="true"
}

probe_bandwidth() {
    local raw_download raw_upload

    command -v ip >/dev/null 2>&1 || return 1
    traffic_mark

    info "测量 IPv4 公网带宽（每方向 12.5 GB，合计 25 GB；按实际目标接口汇总）..."
    if ! probe_iperf_bandwidth; then
        traffic_report
        return 1
    fi
    traffic_report

    raw_download="$DETECTED_DOWNLOAD_MBPS"
    raw_upload="$DETECTED_UPLOAD_MBPS"
    DETECTED_DOWNLOAD_MBPS=$(round_bandwidth "$DETECTED_DOWNLOAD_MBPS")
    DETECTED_UPLOAD_MBPS=$(round_bandwidth "$DETECTED_UPLOAD_MBPS")
    MEASUREMENT_CACHE_PENDING="true"

    detail "raw measurement: download $raw_download Mbps, upload $raw_upload Mbps"
    detail "calculation bandwidth: download $DETECTED_DOWNLOAD_MBPS Mbps, upload $DETECTED_UPLOAD_MBPS Mbps"
}

calculate_buffer_max() {
    local bandwidth_mbps="$1" rtt_ms="$2" memory_cap="$3" minimum=$((4 * 1024 * 1024)) mib=$((1024 * 1024)) desired

    # 2 x BDP + 2 MiB，为 socket 记账和通告窗口保留余量。
    desired=$((bandwidth_mbps * rtt_ms * 250 + 2 * 1024 * 1024))
    desired=$((((desired + mib - 1) / mib) * mib))
    (( desired < minimum )) && desired=$minimum
    (( desired > memory_cap )) && desired=$memory_cap
    echo "$desired"
}

buffer_limit_reason() {
    local bandwidth_mbps="$1" rtt_ms="$2" memory_cap="$3" minimum=$((4 * 1024 * 1024)) mib=$((1024 * 1024)) desired

    desired=$((bandwidth_mbps * rtt_ms * 250 + 2 * 1024 * 1024))
    desired=$((((desired + mib - 1) / mib) * mib))

    if (( desired < minimum )); then
        echo "4 MiB floor"
    elif (( desired > memory_cap )); then
        echo "effective RAM / 32 cap"
    else
        echo "2 x BDP + 2 MiB headroom"
    fi
}

install_probe_dependencies() {
    local packages=()

    command -v ping >/dev/null 2>&1 || packages+=(iputils-ping)
    command -v iperf3 >/dev/null 2>&1 || packages+=(iperf3)
    command -v jq >/dev/null 2>&1 || packages+=(jq)
    command -v timeout >/dev/null 2>&1 || packages+=(coreutils)
    (( ${#packages[@]} > 0 )) || return 0

    if ! command -v apt-get >/dev/null 2>&1; then
        warn "缺少测速依赖且未找到 apt-get"
        return 1
    fi

    info "通过 APT 安装公共测速依赖：${packages[*]}"
    if ! DEBIAN_FRONTEND=noninteractive apt-get update -qq; then
        warn "APT 索引更新失败，将继续尝试安装"
    fi
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        "${packages[@]}"; then
        warn "公共测速依赖安装失败"
        return 1
    fi
}

set_manual_measurement_metadata() {
    [[ "$BANDWIDTH_SOURCE" != "unknown" ]] || BANDWIDTH_SOURCE="command line manual input"
    MEASUREMENT_SOURCE="$BANDWIDTH_SOURCE"
    MEASUREMENT_EPOCH=$(current_epoch)
    MEASUREMENT_TIME=$(format_measurement_epoch "$MEASUREMENT_EPOCH")
    MEASUREMENT_NODES="manual input"
    MEASUREMENT_CONFIDENCE="manual"
    MEASUREMENT_WARNINGS=""
    MEASUREMENT_ROUTE_TARGET=""
    MEASUREMENT_ROUTE_IDENTITY=""
    MEASUREMENT_CACHE_PENDING="false"
}

resolve_tuning_values() {
    local download_mbps="" upload_mbps="" rtt_ms="" live_ready="true"
    local cache_fallback_mode="stale"

    PHYSICAL_RAM_MB=$(detect_memory_mb)
    is_positive_integer "$PHYSICAL_RAM_MB" 1 1073741824 || {
        error "无法读取系统内存"
        return 1
    }
    RAM_MB=$(detect_effective_memory_mb "$PHYSICAL_RAM_MB")
    is_positive_integer "$RAM_MB" 1 "$PHYSICAL_RAM_MB" || {
        error "无法确定有效内存上限"
        return 1
    }
    MEMORY_CAP_BYTES=$(calculate_memory_cap "$RAM_MB")
    TCP_MEM_PAGES=$(calculate_tcp_mem "$RAM_MB") || {
        error "无法根据有效内存和系统页大小计算 tcp_mem"
        return 1
    }

    download_mbps="$MANUAL_DOWNLOAD_MBPS"
    upload_mbps="$MANUAL_UPLOAD_MBPS"
    if [[ -n "$MANUAL_BANDWIDTH_MBPS" ]]; then
        [[ -n "$download_mbps" ]] || download_mbps="$MANUAL_BANDWIDTH_MBPS"
        [[ -n "$upload_mbps" ]] || upload_mbps="$MANUAL_BANDWIDTH_MBPS"
    fi

    if [[ -z "$download_mbps" || -z "$upload_mbps" ]]; then
        if [[ "$TUNING_MODE" != "auto" ]]; then
            error "缺少有效上下行带宽，拒绝生成或应用配置"
            return 1
        fi
        [[ "$FORCE_REFRESH" != "true" ]] || cache_fallback_mode="fallback"
        if [[ "$FORCE_REFRESH" != "true" ]] &&
            load_measurement_cache "$CACHE_FRESH_MAX_AGE_SECONDS" fresh; then
            download_mbps="$DETECTED_DOWNLOAD_MBPS"
            upload_mbps="$DETECTED_UPLOAD_MBPS"
        else
            if [[ "$COMMAND" == "install" ]] && ! install_probe_dependencies; then
                live_ready="false"
            fi
            if [[ "$live_ready" == "true" ]] && probe_bandwidth; then
                download_mbps="$DETECTED_DOWNLOAD_MBPS"
                upload_mbps="$DETECTED_UPLOAD_MBPS"
            elif load_measurement_cache "$CACHE_STALE_MAX_AGE_SECONDS" \
                "$cache_fallback_mode"; then
                download_mbps="$DETECTED_DOWNLOAD_MBPS"
                upload_mbps="$DETECTED_UPLOAD_MBPS"
            else
                warn "公共 iperf3 未获得完整双向结果，且没有可用同路由缓存"
                if ! is_interactive_terminal; then
                    error "非交互终端无法手填带宽，拒绝生成或应用配置"
                    return 1
                fi
                info "请手动提供上下行带宽"
                prompt_manual_bandwidth "interactive fallback after public iperf3 failure" || return 1
                download_mbps="$MANUAL_DOWNLOAD_MBPS"
                upload_mbps="$MANUAL_UPLOAD_MBPS"
                set_manual_measurement_metadata
            fi
        fi
    else
        set_manual_measurement_metadata
    fi

    if [[ -n "$MANUAL_RTT_MS" ]]; then
        rtt_ms="$MANUAL_RTT_MS"
        if [[ "$MANUAL_RTT_DEFAULTED" == "true" ]]; then
            RTT_SOURCE="default for manual bandwidth"
            RTT_POLICY="fixed 150 ms default"
        else
            RTT_SOURCE="command line"
            RTT_POLICY="manual override"
        fi
    else
        rtt_ms="$DEFAULT_RTT_MS"
        RTT_SOURCE="automatic policy"
        RTT_POLICY="fixed 150 ms"
    fi

    if ! is_positive_integer "$download_mbps" 1 100000 ||
        ! is_positive_integer "$upload_mbps" 1 100000; then
        error "未获得完整有效上下行带宽，拒绝生成或应用配置"
        return 1
    fi

    DETECTED_DOWNLOAD_MBPS="$download_mbps"
    DETECTED_UPLOAD_MBPS="$upload_mbps"
    DETECTED_RTT_MS="$rtt_ms"
    BANDWIDTH_SOURCE="$MEASUREMENT_SOURCE"

    RX_BDP_BYTES=$((download_mbps * rtt_ms * 125))
    TX_BDP_BYTES=$((upload_mbps * rtt_ms * 125))
    RMEM_MAX_BYTES=$(calculate_buffer_max "$download_mbps" "$rtt_ms" "$MEMORY_CAP_BYTES")
    WMEM_MAX_BYTES=$(calculate_buffer_max "$upload_mbps" "$rtt_ms" "$MEMORY_CAP_BYTES")
    RMEM_DEFAULT_BYTES=$TCP_BUFFER_DEFAULT_BYTES
    WMEM_DEFAULT_BYTES=$TCP_BUFFER_DEFAULT_BYTES
    RMEM_REASON=$(buffer_limit_reason "$download_mbps" "$rtt_ms" "$MEMORY_CAP_BYTES")
    WMEM_REASON=$(buffer_limit_reason "$upload_mbps" "$rtt_ms" "$MEMORY_CAP_BYTES")
    CALCULATION_REASON="rmem: $RMEM_REASON; wmem: $WMEM_REASON"

    resolve_initcwnd_policy
}

format_buffer_size() {
    awk -v bytes="$1" 'BEGIN {
        if (bytes < 1048576) printf "%.0f KiB", bytes / 1024
        else printf "%.1f MiB", bytes / 1048576
    }'
}

format_tcp_mem_pages() {
    local pages="$1" low pressure maximum extra=""

    read -r low pressure maximum extra <<< "$pages"
    [[ -z "$extra" ]] || return 1
    is_positive_integer "$low" 1 9223372036854775807 || return 1
    is_positive_integer "$pressure" 1 9223372036854775807 || return 1
    is_positive_integer "$maximum" 1 9223372036854775807 || return 1
    (( 10#$low < 10#$pressure && 10#$pressure < 10#$maximum )) || return 1
    printf '%s / %s / %s pages\n' "$low" "$pressure" "$maximum"
}

format_tcp_mem_bytes() {
    local pages="$1" low pressure maximum page_size

    format_tcp_mem_pages "$pages" >/dev/null || return 1
    read -r low pressure maximum <<< "$pages"
    page_size=$(getconf PAGESIZE 2>/dev/null) || return 1
    is_positive_integer "$page_size" 1 1073741824 || return 1
    awk -v low="$low" -v pressure="$pressure" -v maximum="$maximum" \
        -v page_size="$page_size" 'BEGIN {
            printf "%.1f MiB / %.1f MiB / %.1f MiB", \
                low * page_size / 1048576, pressure * page_size / 1048576, \
                maximum * page_size / 1048576
        }'
}

# 持久化值保持不变；所有面向用户的转换集中在此展示层。
format_display_value() {
    case "${1:-unknown}" in
        high) printf '%s\n' '高' ;;
        low) printf '%s\n' '低' ;;
        manual|"manual input") printf '%s\n' '手动输入' ;;
        auto) printf '%s\n' '自动' ;;
        unknown) printf '%s\n' '未知' ;;
        none) printf '%s\n' '无' ;;
        *) printf '%s\n' "$1" ;;
    esac
}

format_tuning_mode() {
    case "${1:-unknown}" in
        auto) printf '%s\n' '自动测速' ;;
        manual) printf '%s\n' '手动输入' ;;
        *) format_display_value "${1:-unknown}" ;;
    esac
}

format_measurement_source() {
    local value="${1:-unknown}" inner

    if [[ "$value" =~ ^7-day[[:space:]]route-bound[[:space:]]cache[[:space:]]\((.*)\)$ ]]; then
        inner=${BASH_REMATCH[1]}
        printf '7 天内同路由缓存（%s）\n' "$(format_measurement_source "$inner")"
    elif [[ "$value" =~ ^same-route[[:space:]]fresh[[:space:]]cache[[:space:]]fallback[[:space:]]\((.*)\)$ ]]; then
        inner=${BASH_REMATCH[1]}
        printf '同路由缓存回退（%s）\n' "$(format_measurement_source "$inner")"
    elif [[ "$value" =~ ^same-route[[:space:]]stale[[:space:]]cache[[:space:]]\((.*)\)$ ]]; then
        inner=${BASH_REMATCH[1]}
        printf '同路由过期缓存（%s）\n' "$(format_measurement_source "$inner")"
    elif [[ "$value" =~ ^public[[:space:]]iperf3[[:space:]]IPv4[[:space:]]\(P=([0-9]+),[[:space:]]t=([0-9]+)s\)$ ]]; then
        printf '公共 IPv4 iperf3 测速（%s 并发 × %s 秒）\n' \
            "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    else
        case "$value" in
            "public iperf3 IPv4"|"public iperf3")
                printf '%s\n' '公共 IPv4 iperf3 测速'
                ;;
            "command line manual input") printf '%s\n' '命令行手动输入' ;;
            "interactive manual entry") printf '%s\n' '交互手动输入' ;;
            "interactive fallback after public iperf3 failure")
                printf '%s\n' '公共 iperf3 测速失败后手动输入'
                ;;
            *) format_display_value "$value" ;;
        esac
    fi
}

format_measurement_warning() {
    case "$1" in
        "failed to persist the route-bound measurement cache")
            printf '%s\n' '无法保存同路由测速缓存'
            ;;
        "live public iperf3 measurement failed, reused same-route cache no older than 30 days")
            printf '%s\n' '现场公共 iperf3 测速失败，复用 30 天内同路由缓存'
            ;;
        "only one public iperf3 peer produced a usable result")
            printf '%s\n' '仅一个公共 iperf3 节点返回可用结果'
            ;;
        "upload has fewer than two valid peer samples")
            printf '%s\n' '上传有效节点样本少于两个'
            ;;
        "upload peer results differ by more than 30%, using the higher valid result")
            printf '%s\n' '上传节点结果差异超过 30%，采用较高有效值'
            ;;
        "download has fewer than two valid peer samples")
            printf '%s\n' '下载有效节点样本少于两个'
            ;;
        "download peer results differ by more than 30%, using the higher valid result")
            printf '%s\n' '下载节点结果差异超过 30%，采用较高有效值'
            ;;
        "traffic budget stopped additional public iperf3 tests")
            printf '%s\n' '流量预算已停止后续公共 iperf3 测试'
            ;;
        "检测到 active root HTB，当前限速可能导致测速偏低。")
            printf '%s\n' '检测到活动的根 HTB 队列，当前限速可能导致测速结果偏低。'
            ;;
        *) format_display_value "$1" ;;
    esac
}

format_measurement_node() {
    local measurement_node="$1"

    if [[ "$measurement_node" =~ ^([^/]+)/([^[:space:]]+)[[:space:]]+(.+)[[:space:]]+\(IPv4[[:space:]]RTT[[:space:]]([0-9]+)[[:space:]]ms\)$ ]]; then
        printf '%s / %s / %s / RTT %s ms\n' \
            "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" \
            "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"
    else
        format_display_value "$measurement_node"
    fi
}

print_measurement_nodes() {
    local nodes_value="${1:-none}" indent="${2:-  }" node_entry count=0

    if [[ "$nodes_value" == "manual input" ]]; then
        printf '%s%s\n' "$indent" '无（手动输入）'
        return 0
    fi
    if [[ -z "$nodes_value" || "$nodes_value" == "none" || "$nodes_value" == "unknown" ]]; then
        printf '%s%s\n' "$indent" "$(format_display_value "${nodes_value:-none}")"
        return 0
    fi
    while IFS= read -r node_entry; do
        node_entry="${node_entry#"${node_entry%%[![:space:]]*}"}"
        node_entry="${node_entry%"${node_entry##*[![:space:]]}"}"
        [[ -n "$node_entry" ]] || continue
        ((count += 1))
        printf '%s%d. %s\n' "$indent" "$count" \
            "$(format_measurement_node "$node_entry")"
    done < <(printf '%s\n' "$nodes_value" | sed 's/;[[:space:]]*/\n/g')
}

format_rtt_source() {
    case "${1:-unknown}" in
        "automatic policy") printf '%s\n' '自动策略' ;;
        "command line") printf '%s\n' '命令行指定' ;;
        "default for manual bandwidth") printf '%s\n' '手动带宽默认值' ;;
        *) format_display_value "${1:-unknown}" ;;
    esac
}

format_rtt_policy() {
    case "${1:-unknown}" in
        "fixed 150 ms") printf '%s\n' '固定 150 ms' ;;
        "fixed 150 ms default") printf '%s\n' '默认固定 150 ms' ;;
        "manual override") printf '%s\n' '手动指定' ;;
        *) format_display_value "${1:-unknown}" ;;
    esac
}

format_rtt_summary() {
    local rtt_ms="${1:-未知}" source="${2:-unknown}" policy="${3:-unknown}" reason

    [[ "$rtt_ms" != "unknown" ]] || rtt_ms='未知'
    case "$source|$policy" in
        "automatic policy|fixed 150 ms") reason='自动固定值' ;;
        "command line|manual override") reason='手动指定' ;;
        "default for manual bandwidth|fixed 150 ms default") reason='手动带宽默认值' ;;
        *) reason="$(format_rtt_source "$source")；$(format_rtt_policy "$policy")" ;;
    esac
    printf 'RTT：%s ms（%s）\n' "$rtt_ms" "$reason"
}

format_initcwnd_policy() {
    case "${1:-unknown}" in
        "auto: upload > 100 Mbps, set 32")
            printf '%s\n' '自动：上传 > 100 Mbps，设置为 32'
            ;;
        "auto: upload <= 100 Mbps, preserve kernel default")
            printf '%s\n' '自动：上传 ≤ 100 Mbps，保持内核默认'
            ;;
        "auto: upload unknown, preserve kernel default")
            printf '%s\n' '自动：上传未知，保持内核默认'
            ;;
        "explicit enabled") printf '%s\n' '手动启用' ;;
        "explicit disabled") printf '%s\n' '手动禁用' ;;
        *) format_display_value "${1:-unknown}" ;;
    esac
}

format_initcwnd_summary() {
    local enabled="$1" policy="$2" persistence="${3:-}" target reason

    [[ "$enabled" == "true" ]] && target=32 || target='内核默认'
    case "$policy" in
        "auto: upload > 100 Mbps, set 32") reason='自动：上传 > 100 Mbps' ;;
        "auto: upload <= 100 Mbps, preserve kernel default") reason='自动：上传 ≤ 100 Mbps' ;;
        "auto: upload unknown, preserve kernel default") reason='自动：上传未知' ;;
        "explicit enabled") reason='手动启用' ;;
        "explicit disabled") reason='手动禁用' ;;
        *) reason=$(format_initcwnd_policy "$policy") ;;
    esac
    if [[ "$enabled" == "true" ]]; then
        case "$persistence" in
            persistent) reason+='；已持久化' ;;
            current-route-only) reason+='；仅当前路由，未持久化' ;;
        esac
    fi
    printf '%s（%s）\n' "$target" "$reason"
}

format_calculation_reason() {
    local value="$1"

    value=${value//4 MiB floor/4 MiB 下限}
    value=${value//effective RAM \/ 32 cap/有效内存 \/ 32 上限}
    value=${value//2 x BDP + 2 MiB headroom/2 × BDP + 2 MiB 余量}
    value=${value//rmem: /接收：}
    value=${value//; wmem: /；发送：}
    printf '%s\n' "$value"
}

format_qdisc_detail() {
    local detail_text="$1"

    if [[ "$detail_text" =~ ^root[[:space:]]([^;]+)\;[[:space:]]all[[:space:]]([0-9]+)[[:space:]]leaves[[:space:]]fq$ ]]; then
        printf '根队列 %s，%s 个叶子队列均为 fq\n' \
            "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    elif [[ "$detail_text" =~ ^root[[:space:]]([^;]+)\;[[:space:]]no[[:space:]]readable[[:space:]]leaves$ ]]; then
        printf '根队列 %s，无可读叶子队列\n' "${BASH_REMATCH[1]}"
    elif [[ "$detail_text" =~ ^root[[:space:]]([^;]+)\;[[:space:]]fq[[:space:]]leaves[[:space:]]([0-9]+/[0-9]+)(\;[[:space:]]other:[[:space:]](.*))?$ ]]; then
        printf '根队列 %s，fq 叶子队列 %s' \
            "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
        [[ -z "${BASH_REMATCH[4]:-}" ]] || printf '，其他：%s' "${BASH_REMATCH[4]}"
        printf '\n'
    elif [[ "$detail_text" =~ ^root[[:space:]](.+)$ ]]; then
        printf '根队列 %s\n' "${BASH_REMATCH[1]}"
    else
        case "$detail_text" in
            "no qdisc data") printf '%s\n' '无 qdisc 数据' ;;
            "no readable leaves") printf '%s\n' '无可读叶子队列' ;;
            "tc qdisc read failed") printf '%s\n' '无法读取 qdisc' ;;
            "default interface unavailable") printf '%s\n' '默认接口不可用' ;;
            *) format_display_value "$detail_text" ;;
        esac
    fi
}

format_initcwnd_state_detail() {
    case "$1" in
        "default route query failed") printf '%s\n' '无法读取默认路由' ;;
        "owned default route has initcwnd/initrwnd 32")
            printf '%s\n' '已接管默认路由，initcwnd/initrwnd=32'
            ;;
        "ownership marker exists but default route lacks initcwnd/initrwnd 32")
            printf '%s\n' '存在所有权标记，但默认路由缺少 initcwnd/initrwnd=32'
            ;;
        "default route has unowned initcwnd/initrwnd settings")
            printf '%s\n' '默认路由存在非本脚本管理的 initcwnd/initrwnd'
            ;;
        "kernel default; no ownership marker")
            printf '%s\n' '内核默认，无所有权标记'
            ;;
        *) format_display_value "$1" ;;
    esac
}

format_tcp_mem_summary() {
    local pages

    pages=$(format_tcp_mem_pages "$1") || return 1
    pages=${pages% pages}
    printf '%s 页（%s）\n' "$pages" "$(format_tcp_mem_bytes "$1")"
}

format_cache_reuse_summary() {
    case "$1" in
        "7-day route-bound cache ("*")")
            printf '%s\n' '测速：复用 7 天内同路由缓存，不执行现场测速'
            ;;
        "same-route fresh cache fallback ("*")")
            printf '%s\n' '测速：现场测速失败，复用 7 天内同路由缓存'
            ;;
        "same-route stale cache ("*")")
            printf '%s\n' '测速：现场测速失败，复用 30 天内同路由过期缓存'
            ;;
    esac
}

show_tuning_plan() {
    local cache_summary

    echo "计划："
    printf '  模式：%s\n' "$(format_tuning_mode "$TUNING_MODE")"
    printf '  内存：物理 %s MiB / 有效 %s MiB\n' "$PHYSICAL_RAM_MB" "$RAM_MB"
    printf '  单 socket 上限：%s（有效内存 / 32，绝对上限 256 MiB）\n' \
        "$(format_buffer_size "$MEMORY_CAP_BYTES")"
    printf '  带宽：下载 %s Mbps / 上传 %s Mbps\n' \
        "${DETECTED_DOWNLOAD_MBPS:-未知}" "${DETECTED_UPLOAD_MBPS:-未知}"
    printf '  来源：%s\n' "$(format_measurement_source "$MEASUREMENT_SOURCE")"
    cache_summary=$(format_cache_reuse_summary "$MEASUREMENT_SOURCE")
    [[ -z "$cache_summary" ]] || printf '  %s\n' "$cache_summary"
    printf '  时间：%s\n' "$(format_display_value "$MEASUREMENT_TIME")"
    echo "  节点："
    print_measurement_nodes "$MEASUREMENT_NODES" '    '
    printf '  可信度：%s\n' "$(format_display_value "$MEASUREMENT_CONFIDENCE")"
    printf '  %s\n' "$(format_rtt_selection_summary)"
    printf '  BDP：接收 %s KiB / 发送 %s KiB\n' \
        "$((RX_BDP_BYTES / 1024))" "$((TX_BDP_BYTES / 1024))"
    printf '  TCP 缓冲：默认 %s / 接收上限 %s / 发送上限 %s\n' \
        "$(format_buffer_size "$RMEM_DEFAULT_BYTES")" \
        "$(format_buffer_size "$RMEM_MAX_BYTES")" \
        "$(format_buffer_size "$WMEM_MAX_BYTES")"
    printf '  TCP 内存：%s\n' "$(format_tcp_mem_summary "$TCP_MEM_PAGES")"
    printf '  计算依据：%s\n' "$(format_calculation_reason "$CALCULATION_REASON")"
    printf '  初始窗口：%s\n' \
        "$(format_initcwnd_summary "$INITCWND_ENABLED" "$INITCWND_POLICY")"
    echo "  ECN：保持现有设置"
}

format_rtt_selection_summary() {
    format_rtt_summary "${DETECTED_RTT_MS:-未知}" \
        "${RTT_SOURCE:-unknown}" "${RTT_POLICY:-unknown}"
}

show_install_summary() {
    local bbr_enabled="$1" algorithm qdisc_state qdisc_detail
    local cache_summary initcwnd_persistence="" bbr_module_summary

    if [[ "$bbr_enabled" == "true" ]]; then
        algorithm="BBR"
    else
        algorithm=$(read_sysctl_or net.ipv4.tcp_congestion_control 未知)
    fi
    IFS='|' read -r qdisc_state qdisc_detail <<< \
        "$(active_qdisc_state "${PROBE_IFACE:-}")"
    if [[ "$INITCWND_ENABLED" == "true" ]]; then
        if is_managed_initcwnd_hook; then
            initcwnd_persistence=persistent
        else
            initcwnd_persistence=current-route-only
        fi
    fi
    if [[ "$bbr_enabled" == "true" ]]; then
        bbr_module_summary=$BBR_MODULES_FILE
    else
        bbr_module_summary='未写入（当前内核不支持 BBR）'
    fi

    echo '结果：'
    printf '  环境：%s vCPU / %.1f GiB 内存 / %s\n' \
        "$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 未知)" \
        "$(awk -v mb="$RAM_MB" 'BEGIN {print mb / 1024}')" \
        "$(format_display_value "${PROBE_IFACE:-unknown}")"
    printf '  带宽：下载 %s Mbps / 上传 %s Mbps\n' \
        "${DETECTED_DOWNLOAD_MBPS:-未知}" "${DETECTED_UPLOAD_MBPS:-未知}"
    printf '  来源：%s\n' "$(format_measurement_source "$MEASUREMENT_SOURCE")"
    cache_summary=$(format_cache_reuse_summary "$MEASUREMENT_SOURCE")
    [[ -z "$cache_summary" ]] || printf '  %s\n' "$cache_summary"
    printf '  时间：%s\n' "$(format_display_value "$MEASUREMENT_TIME")"
    echo '  节点：'
    print_measurement_nodes "$MEASUREMENT_NODES" '    '
    printf '  可信度：%s\n' "$(format_display_value "$MEASUREMENT_CONFIDENCE")"
    printf '  %s\n' "$(format_rtt_selection_summary)"
    printf '  TCP 缓冲：默认 %s / 接收上限 %s / 发送上限 %s\n' \
        "$(format_buffer_size "$RMEM_DEFAULT_BYTES")" \
        "$(format_buffer_size "$RMEM_MAX_BYTES")" \
        "$(format_buffer_size "$WMEM_MAX_BYTES")"
    printf '  TCP 内存：%s\n' "$(format_tcp_mem_summary "$TCP_MEM_PAGES")"
    printf '  拥塞控制：%s\n' "$algorithm"
    printf '  队列：fq %s\n' "$(format_qdisc_state "$qdisc_state" "$qdisc_detail")"
    echo '  ECN：保持现有设置'
    printf '  初始窗口：%s\n' \
        "$(format_initcwnd_summary "$INITCWND_ENABLED" "$INITCWND_POLICY" \
            "$initcwnd_persistence")"
    printf '  sysctl 配置：%s\n' "$NETWORK_CONF"
    printf '  BBR 模块：%s\n' "$bbr_module_summary"
}

# === 新版网络配置 ===
append_supported_tcp_settings() {
    local target_file="$1"

    cat >> "$target_file" <<'EOF'

# TCP 自动调节与基础抗压
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_timestamps = 1
EOF
}

create_network_config() {
    local target_file="$1" enable_bbr="$2" measurement_warnings="${MEASUREMENT_WARNINGS:-none}"

    cat > "$target_file" <<EOF
# 由 network-optimize.sh 自动生成。
# 模式: $TUNING_MODE
# 物理内存: ${PHYSICAL_RAM_MB} MiB
# 有效内存: ${RAM_MB} MiB
# 下载带宽: ${DETECTED_DOWNLOAD_MBPS:-unknown} Mbps
# 上传带宽: ${DETECTED_UPLOAD_MBPS:-unknown} Mbps
# 测量来源: $MEASUREMENT_SOURCE
# 测量时间: $MEASUREMENT_TIME
# 测量节点: $MEASUREMENT_NODES
# 测量可信度: $MEASUREMENT_CONFIDENCE
# 测量警告: $measurement_warnings
${BANDWIDTH_PROBE_NOTE:+# 带宽测量环境: $BANDWIDTH_PROBE_NOTE}
# 计算 RTT: ${DETECTED_RTT_MS:-unknown} ms
# RTT 来源: $RTT_SOURCE
# RTT 策略: $RTT_POLICY
# initcwnd 模式: $INITCWND_MODE
# initcwnd 策略: $INITCWND_POLICY
# 缓冲区依据: $CALCULATION_REASON
# 适用于 Debian 13 代理及中高延迟公网 VPS。

# 1. 队列调度
net.core.default_qdisc = fq

# 2. TCP Fast Open
net.ipv4.tcp_fastopen = 3

# 3. 连接与接收队列
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 16384
net.core.netdev_max_backlog = 16384
net.core.optmem_max = 65536

# 4. tcpfit v0.5.6 mixed 基础内存模型；默认缓冲固定 2 MiB
# core default 影响 TCP、UDP 和其他未自行设置 socket buffer 的协议
# rmem/wmem max 仍按 2 x BDP + 2 MiB 计算，并受 effective RAM / 32 限制
# tcp_mem 按 effective RAM 推导，单位为 pages
net.core.rmem_default = $RMEM_DEFAULT_BYTES
net.core.wmem_default = $WMEM_DEFAULT_BYTES
net.core.rmem_max = $RMEM_MAX_BYTES
net.core.wmem_max = $WMEM_MAX_BYTES
net.ipv4.tcp_rmem = 4096 $RMEM_DEFAULT_BYTES $RMEM_MAX_BYTES
net.ipv4.tcp_wmem = 4096 $WMEM_DEFAULT_BYTES $WMEM_MAX_BYTES
net.ipv4.tcp_mem = $TCP_MEM_PAGES

# 5. 长连接、连接回收与复杂路径
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_mtu_probing = 1
EOF

    append_supported_tcp_settings "$target_file"

    if [[ "$enable_bbr" == "true" ]]; then
        cat >> "$target_file" <<'EOF'

# BBR 拥塞控制
net.ipv4.tcp_congestion_control = bbr
EOF
    else
        cat >> "$target_file" <<'EOF'

# 当前内核未检测到 BBR 支持，因此不设置 tcp_congestion_control。
# 可在升级内核后重新运行本脚本。
EOF
    fi

    chmod 644 "$target_file"
}

prepare_legacy_backup_state() {
    # 旧版没有 absent 标记。检测到脚本生成的现有文件时，无法证明它在
    # 第一次运行前是否存在，因此标记 unknown，绝不把当前受管状态冒充初始状态。
    if [[ -f "$NETWORK_CONF" ]] &&
        grep -Fq '# 由 network-optimize.sh 自动生成。' "$NETWORK_CONF"; then
        if [[ ! -e "$NETWORK_INITIAL_BACKUP" && ! -e "$NETWORK_INITIAL_ABSENT" &&
            ! -e "$NETWORK_INITIAL_UNKNOWN" ]]; then
            install -D -m 0600 /dev/null "$NETWORK_INITIAL_UNKNOWN"
        fi
        if [[ ! -e "$RUNTIME_INITIAL_BACKUP" && ! -e "$RUNTIME_INITIAL_UNKNOWN" ]]; then
            install -D -m 0600 /dev/null "$RUNTIME_INITIAL_UNKNOWN"
        fi
        if [[ ! -e "$ROUTE_INITIAL_BACKUP" && ! -e "$ROUTE_INITIAL_ABSENT" &&
            ! -e "$ROUTE_INITIAL_UNKNOWN" ]]; then
            install -D -m 0600 /dev/null "$ROUTE_INITIAL_UNKNOWN"
        fi
    fi

    if [[ ! -e "$BBR_MODULES_INITIAL_BACKUP" && ! -e "$BBR_MODULES_INITIAL_ABSENT" &&
        ! -e "$BBR_MODULES_INITIAL_UNKNOWN" && -e "$BBR_MODULES_FILE" ]]; then
        install -D -m 0600 /dev/null "$BBR_MODULES_INITIAL_UNKNOWN"
    fi
}

merge_initial_runtime_values() {
    local current_snapshot="$1" temp_file key value

    [[ ! -e "$RUNTIME_INITIAL_UNKNOWN" ]] || return 0

    if [[ ! -f "$RUNTIME_INITIAL_BACKUP" ]]; then
        atomic_install_file "$current_snapshot" "$RUNTIME_INITIAL_BACKUP" 0600
        return $?
    fi

    temp_file=$(mktemp) || return 1
    cp -a "$RUNTIME_INITIAL_BACKUP" "$temp_file" || {
        rm -f "$temp_file"
        return 1
    }

    while IFS='=' read -r key value; do
        [[ -n "$key" ]] || continue
        if ! grep -Fq "${key}=" "$temp_file"; then
            printf '%s=%s\n' "$key" "$value" >> "$temp_file"
        fi
    done < "$current_snapshot"

    if ! atomic_install_file "$temp_file" "$RUNTIME_INITIAL_BACKUP" 0600; then
        rm -f "$temp_file"
        return 1
    fi
    rm -f "$temp_file"
}

backup_network_state() {
    local label target initial previous initial_absent previous_absent

    install -d -m 0755 "$NETWORK_OPTIMIZE_STATE_DIR"
    prepare_legacy_backup_state
    while IFS='|' read -r label target initial previous initial_absent previous_absent; do
        PREVIOUS_BACKUP_FAILED_ITEM="$label"
        backup_managed_file "$target" "$initial" "$previous" \
            "$initial_absent" "$previous_absent" || return 1
    done < <(managed_file_specs)
}

capture_runtime_values_from_files() {
    local output_file="$1" input_file key
    shift

    : > "$output_file" || return 1
    for input_file in "$@"; do
        [[ -f "$input_file" ]] || continue
        while IFS='=' read -r key _; do
            key="${key//[[:space:]]/}"
            [[ -z "$key" || "$key" == \#* ]] && continue
            grep -Fq "${key}=" "$output_file" && continue
            if sysctl -n "$key" >/dev/null 2>&1; then
                printf '%s=%s\n' "$key" "$(sysctl -n "$key")" >> "$output_file" ||
                    return 1
            else
                warn "当前内核不存在运行时参数，跳过快照: $key"
            fi
        done < "$input_file"
    done
}

apply_runtime_values_strict() {
    local values_file="$1" key value expected actual failed=false

    [[ -f "$values_file" ]] || return 0
    while IFS='=' read -r key value; do
        [[ -n "$key" ]] || continue
        if ! sysctl -n "$key" >/dev/null 2>&1; then
            warn "当前内核不存在待恢复参数，跳过: $key"
            continue
        fi
        if ! sysctl -w "$key=$value" >/dev/null 2>&1; then
            error "运行时参数恢复失败: $key"
            failed=true
            continue
        fi
        expected=$(printf '%s\n' "$value" | normalize_sysctl_value)
        actual=$(sysctl -n "$key" 2>/dev/null | normalize_sysctl_value || true)
        if [[ "$actual" != "$expected" ]]; then
            error "运行时参数恢复验证失败: $key"
            failed=true
        fi
    done < "$values_file"

    [[ "$failed" == "false" ]]
}

restore_runtime_values() {
    local values_file="$1" key value

    while IFS='=' read -r key value; do
        [[ -n "$key" ]] || continue
        sysctl -w "$key=$value" >/dev/null 2>&1 ||
            warn "运行时参数恢复失败: $key"
    done < "$values_file"
}

apply_network_config() {
    local config_file="$1" output

    if [[ "${DEBUG:-}" == "1" ]]; then
        sysctl -p "$config_file"
        return
    fi

    if ! output=$(sysctl -p "$config_file" 2>&1); then
        printf '%s\n' "$output" >&2
        return 1
    fi
    [[ -z "$output" ]] || while IFS= read -r line; do detail "$line"; done <<< "$output"
}

normalize_sysctl_value() {
    awk '{$1 = $1; print}'
}

verify_network_config() {
    local config_file="$1" key expected actual failed="false"

    while IFS='=' read -r key expected; do
        key="${key//[[:space:]]/}"
        [[ -z "$key" || "$key" == \#* ]] && continue

        expected=$(printf '%s\n' "$expected" | normalize_sysctl_value)
        actual=$(sysctl -n "$key" 2>/dev/null | normalize_sysctl_value || true)
        if [[ -z "$actual" || "$actual" != "$expected" ]]; then
            error "验证失败: $key，期望 '$expected'，实际 '${actual:-不可用}'"
            failed="true"
        fi
    done < "$config_file"

    [[ "$failed" == "false" ]]
}

record_restore_failure() {
    local -n failures="$1"
    local label="$2"
    shift 2

    "$@" || failures+=("$label")
}

rollback_install() {
    INSTALL_ROLLBACK_FAILED_ITEMS=()

    record_restore_failure INSTALL_ROLLBACK_FAILED_ITEMS config \
        restore_managed_file "$NETWORK_CONF" \
        "$NETWORK_PREVIOUS_BACKUP" "$NETWORK_PREVIOUS_ABSENT"
    record_restore_failure INSTALL_ROLLBACK_FAILED_ITEMS modules \
        restore_managed_file "$BBR_MODULES_FILE" \
        "$BBR_MODULES_PREVIOUS_BACKUP" "$BBR_MODULES_PREVIOUS_ABSENT"
    record_restore_failure INSTALL_ROLLBACK_FAILED_ITEMS runtime \
        apply_runtime_values_strict "$RUNTIME_PREVIOUS_BACKUP"
    record_restore_failure INSTALL_ROLLBACK_FAILED_ITEMS route \
        restore_default_route "$ROUTE_PREVIOUS_BACKUP" \
        "$ROUTE_PREVIOUS_OWNED" "$ROUTE_PREVIOUS_ABSENT"
    record_restore_failure INSTALL_ROLLBACK_FAILED_ITEMS hook \
        restore_managed_file "$INITCWND_ROUTE_HOOK" \
        "$ROUTE_HOOK_PREVIOUS_BACKUP" "$ROUTE_HOOK_PREVIOUS_ABSENT"

    (( ${#INSTALL_ROLLBACK_FAILED_ITEMS[@]} == 0 ))
}

report_install_failure() {
    local message="$1"

    if rollback_install; then
        error "$message，已回滚 config、modules、runtime、route、hook"
    else
        error "$message，且回滚不完整：失败项 ${INSTALL_ROLLBACK_FAILED_ITEMS[*]}"
    fi
}

install_optimization() {
    local temp_config runtime_backup bbr_enabled="false"

    info "阶段 1/3：获取测量数据并计算参数"

    if detect_container; then
        warn "检测到容器虚拟化环境，部分 sysctl 参数可能受宿主机限制"
    fi

    resolve_tuning_values || return 1
    if ! validate_measurement_route; then
        error "测速绑定的默认 IPv4 出口已变化，拒绝写入系统状态"
        return 1
    fi
    persist_pending_measurement_cache
    show_measurement_warnings

    [[ -n "$PROBE_IFACE" ]] || PROBE_IFACE=$(detect_default_iface || true)
    if [[ "${DEBUG:-}" == "1" ]]; then
        show_tuning_plan
    fi

    info "阶段 2/3：备份并应用网络配置"
    if ! temp_config=$(mktemp "${NETWORK_CONF}.new.XXXXXX"); then
        error "无法创建网络配置临时文件"
        return 1
    fi

    # 先按 BBR 可用生成候选配置，确保修改前快照包含拥塞控制键。
    # 完成全部备份后再尝试加载模块；不可用时重生成不接管拥塞控制的配置。
    create_network_config "$temp_config" true

    if ! runtime_backup=$(mktemp) ||
        ! capture_runtime_values_from_files "$runtime_backup" "$temp_config"; then
        rm -f "$temp_config" "${runtime_backup:-}"
        return 1
    fi
    prepare_legacy_backup_state

    install -d -m 0755 "$NETWORK_OPTIMIZE_STATE_DIR"
    if ! merge_initial_runtime_values "$runtime_backup" ||
        ! backup_previous_state_set "$runtime_backup"; then
        rm -f "$temp_config" "$runtime_backup"
        return 1
    fi

    if ensure_bbr_available; then
        bbr_enabled="true"
    else
        create_network_config "$temp_config" false
    fi

    # 应用前已保存全部涉及参数的运行值，失败时逐项回滚。
    if ! apply_network_config "$temp_config" ||
        ! verify_network_config "$temp_config"; then
        report_install_failure "网络 sysctl 应用或验证失败"
        rm -f "$temp_config" "$runtime_backup"
        return 1
    fi

    if ! mv "$temp_config" "$NETWORK_CONF"; then
        report_install_failure "写入网络配置文件失败"
        rm -f "$temp_config" "$runtime_backup"
        return 1
    fi
    if ! validate_measurement_route; then
        report_install_failure "应用 initcwnd 前默认 IPv4 出口已变化"
        rm -f "$temp_config" "$runtime_backup"
        return 1
    fi

    if ! apply_initcwnd; then
        report_install_failure "initcwnd 应用失败"
        rm -f "$temp_config" "$runtime_backup"
        return 1
    fi

    if [[ "$bbr_enabled" == "true" ]]; then
        if ! persist_bbr_module; then
            report_install_failure "BBR 模块开机加载配置写入失败"
            rm -f "$temp_config" "$runtime_backup"
            return 1
        fi
    fi

    rm -f "$runtime_backup"
    info "阶段 3/3：验证完成并汇总结果"

    if [[ "$bbr_enabled" != "true" ]]; then
        warn "BBR 未启用；其余网络参数已正常应用"
    fi

    show_install_summary "$bbr_enabled"
}

# Capture operation-before state for compensating rollback on restore failure.
begin_restore_transaction() {
    local config_backup="$1" runtime_backup="$2" transaction_dir="" route=""

    install -d -m 0755 "$NETWORK_OPTIMIZE_STATE_DIR" || return 1
    transaction_dir=$(mktemp -d \
        "${NETWORK_OPTIMIZE_STATE_DIR}/network-optimize.restore-transaction.XXXXXX") ||
        return 1

    if ! stage_managed_state \
        "$NETWORK_CONF" "$transaction_dir/network" "$transaction_dir/network-absent" ||
        ! stage_managed_state \
            "$BBR_MODULES_FILE" "$transaction_dir/modules" "$transaction_dir/modules-absent" ||
        ! stage_managed_state \
            "$INITCWND_ROUTE_HOOK" "$transaction_dir/hook" "$transaction_dir/hook-absent" ||
        ! capture_runtime_values_from_files \
            "$transaction_dir/runtime" "$config_backup" "$runtime_backup"; then
        rm -rf -- "$transaction_dir"
        return 1
    fi

    if ! route=$(query_default_ipv4_route); then
        rm -rf -- "$transaction_dir"
        return 1
    fi
    if [[ -n "$route" ]]; then
        atomic_write_file "$transaction_dir/route" "$route" 0600
    else
        atomic_write_file "$transaction_dir/route-absent" "absent" 0600
    fi || {
        rm -rf -- "$transaction_dir"
        return 1
    }

    if [[ -e "$ROUTE_OWNED_MARKER" ]] &&
        ! atomic_write_file "$transaction_dir/route-owned" "owned" 0600; then
        rm -rf -- "$transaction_dir"
        return 1
    fi

    RESTORE_TRANSACTION_DIR="$transaction_dir"
}

restore_captured_route_ownership() {
    if [[ -e "$1/route-owned" ]]; then
        create_initcwnd_ownership_marker
    else
        remove_initcwnd_ownership_marker
    fi
}

restore_captured_default_route() {
    local transaction_dir="$1" target_route_file="$2" current_route="" expected_route=""
    local -a route_args=()

    if [[ -f "$transaction_dir/route" ]]; then
        restore_default_route \
            "$transaction_dir/route" "$transaction_dir/route-owned"
        return $?
    fi
    [[ -e "$transaction_dir/route-absent" ]] || return 1

    current_route=$(query_default_ipv4_route) || return 1
    if [[ -z "$current_route" ]]; then
        restore_captured_route_ownership "$transaction_dir"
        return
    fi

    [[ -f "$target_route_file" ]] || return 1
    expected_route=$(<"$target_route_file")
    [[ "$current_route" == "$expected_route" ]] || return 1
    read -r -a route_args <<< "$current_route"
    (( ${#route_args[@]} > 0 )) || return 1
    ip -4 route del "${route_args[@]}" || return 1
    restore_captured_route_ownership "$transaction_dir"
}

rollback_restore_transaction() {
    local transaction_dir="$1" target_route_file="$2"

    RESTORE_ROLLBACK_FAILED_ITEMS=()
    record_restore_failure RESTORE_ROLLBACK_FAILED_ITEMS sysctl \
        restore_managed_file "$NETWORK_CONF" \
        "$transaction_dir/network" "$transaction_dir/network-absent"
    record_restore_failure RESTORE_ROLLBACK_FAILED_ITEMS modules \
        restore_managed_file "$BBR_MODULES_FILE" \
        "$transaction_dir/modules" "$transaction_dir/modules-absent"
    record_restore_failure RESTORE_ROLLBACK_FAILED_ITEMS runtime \
        apply_runtime_values_strict "$transaction_dir/runtime"
    record_restore_failure RESTORE_ROLLBACK_FAILED_ITEMS route \
        restore_captured_default_route "$transaction_dir" "$target_route_file"
    record_restore_failure RESTORE_ROLLBACK_FAILED_ITEMS hook \
        restore_managed_file "$INITCWND_ROUTE_HOOK" \
        "$transaction_dir/hook" "$transaction_dir/hook-absent"

    (( ${#RESTORE_ROLLBACK_FAILED_ITEMS[@]} == 0 ))
}

restore_scope_paths() {
    local scope="${1^^}"
    local config_backup="NETWORK_${scope}_BACKUP" config_absent="NETWORK_${scope}_ABSENT"
    local modules_backup="BBR_MODULES_${scope}_BACKUP" modules_absent="BBR_MODULES_${scope}_ABSENT"
    local hook_backup="ROUTE_HOOK_${scope}_BACKUP" hook_absent="ROUTE_HOOK_${scope}_ABSENT"
    local runtime="RUNTIME_${scope}_BACKUP" route="ROUTE_${scope}_BACKUP"
    local route_absent="ROUTE_${scope}_ABSENT" route_owned="ROUTE_${scope}_OWNED"

    [[ "$scope" == "PREVIOUS" || "$scope" == "INITIAL" ]] || return 1
    printf '%s|' "${!config_backup}" "${!config_absent}" "${!modules_backup}" "${!modules_absent}" \
        "${!hook_backup}" "${!hook_absent}" "${!runtime}" "${!route}" "${!route_absent}"
    printf '%s\n' "${!route_owned}"
}

restore_optional_managed_item() {
    local label="$1" target="$2" backup="$3" absent="$4"

    if [[ ! -e "$backup" && ! -e "$absent" ]]; then
        warn "恢复项 $label：无可信快照，保留当前文件"
        return 0
    fi
    if restore_managed_file "$target" "$backup" "$absent"; then
        info "恢复项 $label：成功"
        return 0
    fi
    error "恢复项 $label：失败"
    return 1
}

restore_optimization() {
    local scope="${1:-previous}" config_backup config_absent modules_backup modules_absent
    local hook_backup hook_absent runtime_backup route_backup route_absent route_owned transaction_dir
    local sysctl_failed="false"
    local -a failed_items=()
    RESTORE_ROLLBACK_FAILED_ITEMS=()

    if ! IFS='|' read -r config_backup config_absent modules_backup modules_absent \
        hook_backup hook_absent runtime_backup route_backup route_absent route_owned \
        < <(restore_scope_paths "$scope"); then
        error "恢复范围必须是 previous 或 initial"
        return 1
    fi

    if [[ ! -e "$config_backup" && ! -e "$config_absent" ]]; then
        error "未找到可信的 $scope 网络配置状态，拒绝推测"
        return 1
    fi

    RESTORE_TRANSACTION_DIR=""
    if ! begin_restore_transaction "$config_backup" "$runtime_backup"; then
        error "无法保存恢复操作前状态，拒绝开始恢复"
        return 1
    fi
    transaction_dir="$RESTORE_TRANSACTION_DIR"

    info "开始恢复网络优化配置（$scope）..."

    if [[ -e "$config_backup" ]] && ! apply_network_config "$config_backup"; then
        error "恢复项 sysctl：目标配置应用失败"
        sysctl_failed="true"
    fi
    if ! restore_managed_file "$NETWORK_CONF" "$config_backup" "$config_absent"; then
        error "恢复项 sysctl：持久配置文件恢复失败"
        sysctl_failed="true"
    fi
    if [[ "$sysctl_failed" == "true" ]]; then
        failed_items+=(sysctl)
    else
        info "恢复项 sysctl：成功"
    fi

    restore_optional_managed_item modules "$BBR_MODULES_FILE" \
        "$modules_backup" "$modules_absent" || failed_items+=(modules)

    if [[ -f "$runtime_backup" ]]; then
        if apply_runtime_values_strict "$runtime_backup"; then
            info "恢复项 runtime：成功"
        else
            error "恢复项 runtime：失败"
            failed_items+=(runtime)
        fi
    else
        warn "恢复项 runtime：无可信快照，已跳过"
    fi

    if [[ "$scope" == "initial" && -e "$ROUTE_INITIAL_UNKNOWN" ]]; then
        warn "恢复项 route：初始状态未知，保留当前路由"
    elif restore_default_route "$route_backup" "$route_owned" "$route_absent"; then
        info "恢复项 route：成功"
    else
        error "恢复项 route：失败"
        failed_items+=(route)
    fi

    restore_optional_managed_item hook "$INITCWND_ROUTE_HOOK" \
        "$hook_backup" "$hook_absent" || failed_items+=(hook)

    if (( ${#failed_items[@]} > 0 )); then
        if rollback_restore_transaction "$transaction_dir" "$route_backup"; then
            error "目标恢复失败，已回滚到操作前状态：失败项 ${failed_items[*]}"
            rm -rf -- "$transaction_dir" || true
        else
            error "目标恢复失败，且回滚不完整：目标失败项 ${failed_items[*]}；回滚失败项 ${RESTORE_ROLLBACK_FAILED_ITEMS[*]}"
            error "部分恢复：回滚失败项 ${RESTORE_ROLLBACK_FAILED_ITEMS[*]}；操作前快照保留在 $transaction_dir"
        fi
        return 1
    fi

    rm -rf -- "$transaction_dir" ||
        warn "恢复事务临时目录清理失败：$transaction_dir"
    success "网络配置已恢复到 $scope 状态"
}

read_sysctl_or() {
    local key="$1" fallback="${2:-不可用}" value=""

    value=$(sysctl -n "$key" 2>/dev/null) || true
    printf '%s\n' "${value:-$fallback}"
}

print_status_section() {
    local title="$1" spec label value fallback
    shift

    printf '\n%s：\n' "$title"
    for spec in "$@"; do
        [[ -n "$spec" ]] || continue
        IFS='|' read -r label value fallback <<< "$spec"
        if [[ "$value" == sysctl:* ]]; then
            value=$(read_sysctl_or "${value#sysctl:}" "${fallback:-不可用}")
        fi
        printf '  %s：%s\n' "$label" "$value"
    done
}

config_comment_value() {
    local file="$1" label="$2" fallback="${3:-未记录}" value

    value=$(awk -v prefix="# $label: " '
        index($0, prefix) == 1 {
            print substr($0, length(prefix) + 1)
            exit
        }
    ' "$file" 2>/dev/null || true)
    printf '%s\n' "${value:-$fallback}"
}

show_status() {
    local available_cc default_iface active_qdisc_state_name active_qdisc_detail
    local initcwnd_state_name initcwnd_detail drift_status="" cache_summary warning
    local measurement_source="unknown" measurement_time="unknown" measurement_nodes="none"
    local measurement_confidence="unknown" measurement_warnings="none" cache_status="不存在"
    local config_mode="unknown" config_physical_ram="未记录" config_effective_ram="未记录"
    local config_download="未记录" config_upload="未记录" config_rtt="unknown"
    local config_rtt_source="unknown" config_rtt_policy="unknown" config_rtt_display=""
    local config_initcwnd_mode="unknown" config_initcwnd_policy="unknown"
    local config_calculation_reason="未记录"

    available_cc=$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || echo "未知")
    default_iface=$(detect_default_iface || true)
    IFS='|' read -r active_qdisc_state_name active_qdisc_detail <<< \
        "$(active_qdisc_state "$default_iface")"
    IFS='|' read -r initcwnd_state_name initcwnd_detail <<< "$(detect_initcwnd_state)"
    initcwnd_detail=$(format_initcwnd_state_detail "$initcwnd_detail")
    [[ "$initcwnd_state_name" != "drift" ]] || drift_status="initcwnd 状态|漂移"

    if [[ -f "$NETWORK_CONF" ]]; then
        config_mode=$(config_comment_value "$NETWORK_CONF" 模式 unknown)
        config_physical_ram=$(config_comment_value "$NETWORK_CONF" 物理内存)
        config_effective_ram=$(config_comment_value "$NETWORK_CONF" 有效内存)
        config_download=$(config_comment_value "$NETWORK_CONF" 下载带宽)
        config_upload=$(config_comment_value "$NETWORK_CONF" 上传带宽)
        config_rtt=$(config_comment_value "$NETWORK_CONF" "计算 RTT" unknown)
        config_rtt=${config_rtt% ms}
        config_rtt_source=$(config_comment_value "$NETWORK_CONF" "RTT 来源" unknown)
        config_rtt_policy=$(config_comment_value "$NETWORK_CONF" "RTT 策略" unknown)
        config_rtt_display=$(format_rtt_summary \
            "$config_rtt" "$config_rtt_source" "$config_rtt_policy")
        config_rtt_display=${config_rtt_display#RTT：}
        config_initcwnd_mode=$(config_comment_value "$NETWORK_CONF" "initcwnd 模式" unknown)
        config_initcwnd_policy=$(config_comment_value "$NETWORK_CONF" "initcwnd 策略" unknown)
        config_calculation_reason=$(config_comment_value "$NETWORK_CONF" 缓冲区依据)
        measurement_source=$(config_comment_value "$NETWORK_CONF" 测量来源 unknown)
        measurement_time=$(config_comment_value "$NETWORK_CONF" 测量时间 unknown)
        measurement_nodes=$(config_comment_value "$NETWORK_CONF" 测量节点 none)
        measurement_confidence=$(config_comment_value "$NETWORK_CONF" 测量可信度 unknown)
        measurement_warnings=$(config_comment_value "$NETWORK_CONF" 测量警告 none)
    elif [[ -f "$MEASUREMENT_CACHE" ]]; then
        measurement_source=$(cache_field "$MEASUREMENT_CACHE" source)
        measurement_time=$(cache_field "$MEASUREMENT_CACHE" measured_at)
        measurement_nodes=$(cache_field "$MEASUREMENT_CACHE" nodes)
        measurement_confidence=$(cache_field "$MEASUREMENT_CACHE" confidence)
        measurement_warnings=$(cache_field "$MEASUREMENT_CACHE" warnings)
    fi
    [[ -f "$MEASUREMENT_CACHE" ]] && cache_status="存在（$MEASUREMENT_CACHE）"

    echo "网络优化状态："
    echo "配置文件：$NETWORK_CONF"
    [[ -f "$NETWORK_CONF" ]] && echo "配置状态：已存在" || echo "配置状态：未创建"
    if [[ -f "$NETWORK_CONF" ]]; then
        print_status_section "配置记录" \
            "模式|$(format_tuning_mode "$config_mode")" \
            "物理内存|$config_physical_ram" \
            "有效内存|$config_effective_ram" \
            "下载带宽|$config_download" \
            "上传带宽|$config_upload" \
            "RTT|$config_rtt_display" \
            "initcwnd 模式|$(format_display_value "$config_initcwnd_mode")" \
            "initcwnd 策略|$(format_initcwnd_policy "$config_initcwnd_policy")" \
            "缓冲区依据|$(format_calculation_reason "$config_calculation_reason")"
    fi
    [[ -f "$NETWORK_INITIAL_BACKUP" ]] && echo "初始备份：$NETWORK_INITIAL_BACKUP"
    [[ -f "$NETWORK_INITIAL_ABSENT" ]] && echo "初始状态：配置文件原本不存在"
    [[ -f "$NETWORK_INITIAL_UNKNOWN" ]] && echo "初始状态：旧版未记录，无法安全推测"
    [[ -f "$NETWORK_PREVIOUS_BACKUP" ]] && echo "上次备份：$NETWORK_PREVIOUS_BACKUP"

    printf '\n测量记录：\n'
    printf '  来源：%s\n' "$(format_measurement_source "${measurement_source:-unknown}")"
    cache_summary=$(format_cache_reuse_summary "$measurement_source")
    [[ -z "$cache_summary" ]] || printf '  %s\n' "$cache_summary"
    printf '  时间：%s\n' "$(format_display_value "${measurement_time:-unknown}")"
    printf '  节点：\n'
    print_measurement_nodes "${measurement_nodes:-none}" '    '
    printf '  可信度：%s\n' "$(format_display_value "${measurement_confidence:-unknown}")"
    if [[ -z "$measurement_warnings" || "$measurement_warnings" == "none" ]]; then
        printf '  警告：无\n'
    else
        while IFS= read -r warning; do
            [[ -n "$warning" ]] || continue
            printf '  警告：%s\n' "$(format_measurement_warning "$warning")"
        done < <(printf '%s\n' "$measurement_warnings" | sed 's/;[[:space:]]*/\n/g')
    fi
    printf '  路由绑定缓存：%s\n' "$cache_status"

    print_status_section "拥塞与队列" \
        "可用算法|$available_cc" \
        "当前算法|$(read_sysctl_or net.ipv4.tcp_congestion_control 未知)" \
        "默认 qdisc|$(read_sysctl_or net.core.default_qdisc 未知)" \
        "当前 qdisc（${default_iface:-未知接口}）|$(format_qdisc_state "$active_qdisc_state_name" "$active_qdisc_detail")"
    print_status_section "受管缓冲区" \
        "rmem_default|sysctl:net.core.rmem_default|未知" \
        "wmem_default|sysctl:net.core.wmem_default|未知" \
        "rmem_max|sysctl:net.core.rmem_max|未知" \
        "wmem_max|sysctl:net.core.wmem_max|未知" \
        "tcp_rmem|sysctl:net.ipv4.tcp_rmem|未知" \
        "tcp_wmem|sysctl:net.ipv4.tcp_wmem|未知" \
        "tcp_mem|sysctl:net.ipv4.tcp_mem|未知" \
        "tcp_moderate_rcvbuf|sysctl:net.ipv4.tcp_moderate_rcvbuf|未知"
    print_status_section "初始拥塞窗口" \
        "所有权标记|$([[ -e "$ROUTE_OWNED_MARKER" ]] && echo 存在 || echo 不存在)" \
        "持久化钩子|$(initcwnd_hook_status)" \
        "默认路由窗口|$initcwnd_detail" "$drift_status"

    return 0
}

show_help() {
    cat <<'EOF'
用法：
  network-optimize.sh [install] [选项]  计算并应用网络优化
  network-optimize.sh plan [选项]       只计算并显示计划，不修改系统
  network-optimize.sh restore           恢复上一次运行前的配置
  network-optimize.sh restore initial   恢复首次运行前的可信配置
  network-optimize.sh status            查看优化与测量状态
  network-optimize.sh help              显示帮助

install/plan 选项：
  --auto                  非交互使用公共 IPv4 iperf3 自动测速
  --bandwidth-mbps N      指定对称带宽，单位 Mbps
  --download-mbps N       指定下载带宽，单位 Mbps
  --upload-mbps N         指定上传带宽，单位 Mbps
  --refresh               与 --auto 同用；绕过 7 天缓存，现场测速失败可回退到 30 天内缓存
  --rtt-ms N              指定 RTT，单位 ms
  --enable-initcwnd       强制把默认路由 initcwnd/initrwnd 设置为 32
  --disable-initcwnd      强制保留内核默认初始拥塞窗口

示例：
  network-optimize.sh                  # 交互询问测速，回车默认 Y
  network-optimize.sh install --auto   # 非交互自动测速并应用
  network-optimize.sh install --auto --refresh  # 强制重新测速
  network-optimize.sh plan --bandwidth-mbps 1000 --rtt-ms 180
  network-optimize.sh install --download-mbps 1000 --upload-mbps 500 --rtt-ms 180
  network-optimize.sh status
默认行为：

  - 无参数交互询问公共 iperf3 测速，默认 Y；选择 N 后手填完整上下行带宽
  - 非交互必须使用 --auto，或提供对称带宽/完整上下行带宽
  - install --auto 可通过系统配置的 APT 软件源非交互安装缺失测速依赖
  - 自动测速仅使用 IPv4 公共 iperf3；最多 2 个节点，每方向 P=4、t=5 秒
  - 每方向取有效较高结果；节点差异超过 30% 仅降低可信度并警告
  - 上传、下载各 12.5 GB，合计 25 GB；接口计数包含测试期间后台流量
  - 7 天内缓存可直接复用；--auto --refresh 绕过该缓存并强制现场测速
  - 主动测速失败时回退到 30 天内同路由缓存；refresh 也可回退到 7 天内缓存
  - 测速和缓存固定绑定 1.1.1.1 的 ifindex、接口、网关与源地址
  - 只有完整上下行输入才生成配置；低可信度会警告并持久化，但不改变成功退出码
  - 手填带宽缺少 RTT 时按 150 ms 计算；自动测速不采集 RTT
  - 主动测速失败且无缓存时，交互可转手填；非交互在系统写入前失败
  - TCP 调优仅覆盖 IPv4，不管理 forwarding、IPv6 RA 或系统代理
  - ECN 始终保留系统或管理员设置，不由本模块持久管理
  - initcwnd 默认 auto：上传 > 100 Mbps 设置 32，否则保留内核默认
  - initcwnd hook 在最终写路由前再次检查 ownership marker
  - 根据 2 x BDP + 2 MiB 余量设置缓冲区上限，TCP 初始默认固定 2 MiB
  - RAM cap 为有效 RAM / 32，最低 8 MiB、最高 256 MiB
  - 不创建定时任务，不调用 traffic-shape，也不共享其状态、缓存、锁或运行库

已退休且会被拒绝：verify、--probe、--yes、--disable-ecn。

实现来源：
  - 公共 iperf3、BDP/memory cap 与 initcwnd 策略移植或参考 tcpfit v0.5.6
  - 参数交互、路由绑定缓存和事务备份/恢复为本仓库下游实现
EOF
}

main() {
    if ! parse_arguments "$@"; then
        show_help
        exit 1
    fi

    select_tuning_mode || exit 1

    require_commands awk grep sort mktemp || exit 1

    case "$COMMAND" in
        install)
            require_root
            require_commands sysctl mv cp find modprobe ip flock getent install dirname getconf || exit 1
            take_lock
            install_optimization
            ;;
        plan)
            require_commands flock getent getconf || exit 1
            take_lock
            resolve_tuning_values
            if ! validate_measurement_route; then
                error "测速绑定的默认 IPv4 出口已变化，拒绝保存测量缓存"
                return 1
            fi
            persist_pending_measurement_cache
            show_measurement_warnings
            show_tuning_plan
            ;;
        restore)
            require_root
            require_commands flock sysctl || exit 1
            take_lock
            restore_optimization "$RESTORE_SCOPE"
            ;;
        status)
            show_status
            ;;
        help)
            show_help
            ;;
    esac
}

run_network_command() {
    trap 'cleanup_probe_processes' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    main "$@"
}

trap 'error "网络优化脚本在第 $LINENO 行执行失败"' ERR

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
    run_network_command "$@"
fi
