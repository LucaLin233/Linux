#!/usr/bin/env bash
# linux-setup:name=网络优化（BBR、fq、TCP 缓冲区）
# linux-setup:order=30
# linux-setup:depends=
# linux-setup:enabled=true
# 网络优化模块
# TCP 调优仅覆盖 IPv4。
# 基础调优移植或参考 Kylin010/tcpfit v0.5.6（MIT，提交 67c0bdfb35dd98e86982600298237b6ecc08ebe4）。
# 事务备份、交互与验证为本仓库下游扩展。
# 功能：配置 BBR、fq 与 TCP 缓冲区；主动探测必须明确选择。
#
# 用法：
#   bash network-optimize.sh [install] [选项]  # 自动计算并应用
#   bash network-optimize.sh plan [选项]       # 只计算，不修改系统
#   bash network-optimize.sh restore           # 恢复上一次配置
#   bash network-optimize.sh status            # 查看当前状态
#   bash network-optimize.sh verify [--yes]    # 确认后只读验证网络性能
#
# install/plan 可选参数：
#   --probe                      明确执行自动探测
#   --bandwidth-mbps N           手动指定对称带宽
#   --download-mbps N            手动指定下载带宽
#   --upload-mbps N              手动指定上传带宽
#   --rtt-ms N                   手动指定 RTT
#   --disable-ecn                禁用 ECN，回退到传统丢包信号
#   --enable-initcwnd            强制设置初始拥塞窗口为 32
#   --disable-initcwnd           强制保留内核默认初始拥塞窗口

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
readonly LOCK_FILE="/run/lock/network-optimize.lock"
readonly NETWORK_DETAIL_LOG="${NETWORK_OPTIMIZE_LOG:-/var/log/linux-setup.log}"

# 首选附近公共 iperf3 节点进行多流双向测速；Cloudflare 用于并行交叉验证和回退。
readonly SPEED_DOWNLOAD_URL="https://speed.cloudflare.com/__down"
readonly SPEED_UPLOAD_URL="https://speed.cloudflare.com/__up"
readonly IPERF_DURATION=5
readonly IPERF_PARALLEL=4
readonly IPERF_MAX_PEERS=2
readonly -a IPERF_PORTS=(5201 5202 5203 5204 5205 5206 5207 5208 5209 5210 5200)
readonly VERIFY_MAX_GROUP_ATTEMPTS=3
readonly CLOUDFLARE_PARALLEL=8
readonly CLOUDFLARE_DURATION=6
readonly CLOUDFLARE_DOWNLOAD_BYTES=50000000
readonly CLOUDFLARE_UPLOAD_BYTES=250000000
readonly TRAFFIC_TOTAL_LIMIT_BYTES=90000000000
readonly TRAFFIC_DIRECTION_LIMIT_BYTES=45000000000
readonly TRAFFIC_STOP_RESERVE_BYTES=5000000000

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

# 参数与计算结果。命令行参数优先于自动探测。
COMMAND="install"
RESTORE_SCOPE="previous"
TUNING_MODE=""
TUNING_SELECTION_EXPLICIT="false"
ACTIVE_PROBE_REQUESTED="false"
ECN_DISABLED="false"
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
PHYSICAL_RAM_MB=0
RAM_MB=0
MEMORY_CAP_BYTES=0
RX_BDP_BYTES=0
TX_BDP_BYTES=0
RMEM_MAX_BYTES=0
WMEM_MAX_BYTES=0
RMEM_DEFAULT_BYTES=$TCP_BUFFER_DEFAULT_BYTES
WMEM_DEFAULT_BYTES=$TCP_BUFFER_DEFAULT_BYTES
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
declare -a IPERF_RUNNER_PIDS=() CLOUDFLARE_WORKER_PIDS=()
declare -a INITCWND_ROLLBACK_FAILED_ITEMS=()
PREFERRED_IPERF_PORT=""
CLOUDFLARE_IPV4=""
VERIFY_ASSUME_YES="false"
VERIFY_CONFIRM_EXPLICIT="false"
VERIFY_TEMP_DIR=""
VERIFY_RESULT=""

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
        printf '%s network-optimize: %s\n' "$(date '+%F %T')" "$message" >> "$NETWORK_DETAIL_LOG"
    fi
}


stage_managed_state() {
    local target="$1" backup="$2" absent="$3" stage

    install -d -m 0755 "$(dirname "$backup")" || return 1
    if [[ -e "$target" || -L "$target" ]]; then
        stage=$(mktemp "${backup}.new.XXXXXX") || return 1
        rm -f "$stage"
        if ! cp -a -- "$target" "$stage"; then
            rm -f "$stage"
            return 1
        fi
        if ! mv -f -- "$stage" "$backup"; then
            rm -f "$stage"
            return 1
        fi
        rm -f "$absent"
    else
        stage=$(mktemp "${absent}.new.XXXXXX") || return 1
        chmod 600 "$stage" || {
            rm -f "$stage"
            return 1
        }
        if ! mv -f -- "$stage" "$absent"; then
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
    if ! install -m "$mode" "$source_file" "$stage"; then
        rm -f "$stage"
        return 1
    fi
    if ! mv -f -- "$stage" "$destination"; then
        rm -f "$stage"
        return 1
    fi
}

atomic_write_file() {
    local destination="$1" content="$2" mode="${3:-0600}" stage

    install -d -m 0755 "$(dirname "$destination")" || return 1
    stage=$(mktemp "${destination}.new.XXXXXX") || return 1
    if ! printf '%s\n' "$content" > "$stage" || ! chmod "$mode" "$stage"; then
        rm -f "$stage"
        return 1
    fi
    if ! mv -f -- "$stage" "$destination"; then
        rm -f "$stage"
        return 1
    fi
}

atomic_restore_file() {
    local source_file="$1" destination="$2" stage

    install -d -m 0755 "$(dirname "$destination")" || return 1
    stage=$(mktemp "${destination}.rollback.XXXXXX") || return 1
    rm -f -- "$stage" || return 1
    if ! cp -a -- "$source_file" "$stage"; then
        rm -f -- "$stage"
        return 1
    fi
    if ! mv -f -- "$stage" "$destination"; then
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
        return $?
    fi

    if [[ -e "$absent" ]]; then
        rm -f "$target" || return 1
        return 0
    fi

    return 1
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
    if (( $# > 0 )) && [[ "$1" != -* ]]; then
        COMMAND="$1"
        shift
    fi

    while (( $# > 0 )); do
        case "$1" in
            --probe)
                TUNING_MODE="probe"
                TUNING_SELECTION_EXPLICIT="true"
                ACTIVE_PROBE_REQUESTED="true"
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
            --disable-ecn)
                ECN_DISABLED="true"
                shift
                ;;
            --enable-initcwnd)
                if [[ "$INITCWND_MODE" == "disabled" ]]; then
                    error "--enable-initcwnd 不能与 --disable-initcwnd 同时使用"
                    return 1
                fi
                INITCWND_MODE="enabled"
                shift
                ;;
            --disable-initcwnd)
                if [[ "$INITCWND_MODE" == "enabled" ]]; then
                    error "--enable-initcwnd 不能与 --disable-initcwnd 同时使用"
                    return 1
                fi
                INITCWND_MODE="disabled"
                shift
                ;;
            --yes)
                VERIFY_ASSUME_YES="true"
                VERIFY_CONFIRM_EXPLICIT="true"
                shift
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
        install|plan|restore|status|verify|help) ;;
        *)
            error "未知命令: $COMMAND"
            return 1
            ;;
    esac

    if [[ -n "$MANUAL_BANDWIDTH_MBPS" ]] &&
        ! is_positive_integer "$MANUAL_BANDWIDTH_MBPS" 1 100000; then
        error "--bandwidth-mbps 必须是 1–100000 的整数"
        return 1
    fi
    if [[ -n "$MANUAL_DOWNLOAD_MBPS" ]] &&
        ! is_positive_integer "$MANUAL_DOWNLOAD_MBPS" 1 100000; then
        error "--download-mbps 必须是 1–100000 的整数"
        return 1
    fi
    if [[ -n "$MANUAL_UPLOAD_MBPS" ]] &&
        ! is_positive_integer "$MANUAL_UPLOAD_MBPS" 1 100000; then
        error "--upload-mbps 必须是 1–100000 的整数"
        return 1
    fi
    if [[ -n "$MANUAL_RTT_MS" ]] &&
        ! is_positive_integer "$MANUAL_RTT_MS" 1 5000; then
        error "--rtt-ms 必须是 1–5000 的整数"
        return 1
    fi

    if [[ "$ACTIVE_PROBE_REQUESTED" == "true" ]] &&
        [[ -n "$MANUAL_BANDWIDTH_MBPS$MANUAL_DOWNLOAD_MBPS$MANUAL_UPLOAD_MBPS" ]]; then
        error "--probe 不能与手动带宽参数同时使用"
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
    elif [[ -n "$MANUAL_RTT_MS" && "$ACTIVE_PROBE_REQUESTED" != "true" ]]; then
        error "仅指定 RTT 无法计算缓冲区；请同时指定带宽，或使用 --probe"
        return 1
    fi

    if [[ "$COMMAND" != "verify" && "$VERIFY_CONFIRM_EXPLICIT" == "true" ]]; then
        error "--yes 只能用于 verify"
        return 1
    fi
    if [[ "$COMMAND" == "verify" ]] &&
        [[ -n "$MANUAL_BANDWIDTH_MBPS$MANUAL_DOWNLOAD_MBPS$MANUAL_UPLOAD_MBPS$MANUAL_RTT_MS" ||
            "$TUNING_SELECTION_EXPLICIT" == "true" ||
            "$ECN_DISABLED" == "true" || "$INITCWND_MODE" != "auto" ]]; then
        error "verify 仅接受 --yes；不会安装或应用网络优化"
        return 1
    fi
}

is_interactive_terminal() {
    [[ -t 0 ]]
}

show_active_probe_warning() {
    warn "主动探测会安装缺失的 curl、ping、iperf3、jq 等工具"
    warn "典型流量约等于 32 秒线速传输：1 Gbps 约 4 GB，2.5 Gbps 约 10 GB，10 Gbps 约 40 GB"
    warn "安全硬上限为单方向 45 GB、合计 90 GB；达到 40/85 GB 时提前终止测速"
    warn "流量按实际 IPv4 目标的路由接口分别计量并汇总；接口计数含后台流量，属于保守预算"
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
        error "非交互运行必须使用 --probe，或显式提供上下行带宽"
        return 1
    fi

    show_active_probe_warning
    read -r -p "是否执行主动测速？[y/N]: " answer || return 1
    if [[ "$answer" =~ ^[Yy]$ ]]; then
        TUNING_MODE="probe"
        ACTIVE_PROBE_REQUESTED="true"
    else
        prompt_manual_bandwidth || return 1
    fi

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

memory_status_summary() {
    local meminfo_file="${NETWORK_OPTIMIZE_MEMINFO_FILE:-/proc/meminfo}"

    [[ -r "$meminfo_file" ]] || {
        printf '%s\n' '不可读'
        return 0
    }
    awk '
        /^MemTotal:/ {total=$2}
        /^MemAvailable:/ {available=$2}
        END {
            if (!total || available == "") {print "不可读"; exit}
            used=total-available
            printf "已用 %.0f MiB / 可用 %.0f MiB / 总计 %.0f MiB", \
                used/1024, available/1024, total/1024
        }
    ' "$meminfo_file" 2>/dev/null
}

swap_status_summary() {
    local meminfo_file="${NETWORK_OPTIMIZE_MEMINFO_FILE:-/proc/meminfo}"

    [[ -r "$meminfo_file" ]] || {
        printf '%s\n' '不可读'
        return 0
    }
    awk '
        /^SwapTotal:/ {total=$2}
        /^SwapFree:/ {free=$2}
        END {
            if (total == "" || free == "") {print "不可读"; exit}
            if (total == 0) {print "未配置"; exit}
            printf "已用 %.0f MiB / 总计 %.0f MiB", (total-free)/1024, total/1024
        }
    ' "$meminfo_file" 2>/dev/null
}

recent_oom_event_count() {
    local journal

    command -v journalctl >/dev/null 2>&1 || {
        printf '%s\n' '不可读'
        return 0
    }
    if ! journal=$(journalctl -k --since '-1 hour' --no-pager -o cat 2>/dev/null); then
        printf '%s\n' '不可读'
        return 0
    fi
    awk '/oom-kill:/ {count += 1} END {print count + 0}' <<< "$journal"
}

calculate_memory_cap() {
    local ram_mb="$1"
    local cap=$((ram_mb * 32768)) # 有效 RAM / 32
    local minimum=$((8 * 1024 * 1024)) maximum=$((256 * 1024 * 1024))

    (( cap < minimum )) && cap=$minimum
    (( cap > maximum )) && cap=$maximum
    echo "$cap"
}

cleanup_temp_dir() {
    local directory="$1" file

    for file in "$directory"/*; do
        [[ -e "$file" ]] || continue
        rm -f "$file"
    done
    rmdir "$directory" 2>/dev/null || true
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
    local state="$1" detail_text="$2"
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
    [[ -n "$routes" ]] || return 2
    printf '%s\n' "$routes"
}

default_ipv4_route() {
    local route query_status

    if route=$(query_default_ipv4_route); then
        printf '%s\n' "$route"
        return 0
    fi
    query_status=$?
    if (( query_status == 2 )); then
        printf '\n'
        return 0
    fi
    return 1
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

backup_default_route() {
    local route="" query_status=0

    route=$(query_default_ipv4_route) || query_status=$?
    if (( query_status != 0 )); then
        if (( query_status != 2 )); then
            error "读取 IPv4 默认路由失败"
            return 1
        fi
    fi
    install -d -m 0755 "$NETWORK_OPTIMIZE_STATE_DIR" || return 1
    if [[ -n "$route" ]]; then
        atomic_write_file "$ROUTE_PREVIOUS_BACKUP" "$route" 0600 || return 1
        if [[ -e "$ROUTE_OWNED_MARKER" ]]; then
            atomic_write_file "$ROUTE_PREVIOUS_OWNED" "owned" 0600 || return 1
        else
            rm -f "$ROUTE_PREVIOUS_OWNED" || return 1
        fi
        rm -f "$ROUTE_PREVIOUS_ABSENT" || return 1
    else
        atomic_write_file "$ROUTE_PREVIOUS_ABSENT" "absent" 0600 || return 1
        rm -f "$ROUTE_PREVIOUS_BACKUP" "$ROUTE_PREVIOUS_OWNED" || return 1
    fi

    if [[ ! -e "$ROUTE_INITIAL_BACKUP" && ! -e "$ROUTE_INITIAL_ABSENT" &&
        ! -e "$ROUTE_INITIAL_UNKNOWN" ]]; then
        if [[ -n "$route" ]]; then
            atomic_write_file "$ROUTE_INITIAL_BACKUP" "$route" 0600 || return 1
            if [[ -e "$ROUTE_OWNED_MARKER" ]]; then
                atomic_write_file "$ROUTE_INITIAL_OWNED" "owned" 0600 || return 1
            else
                rm -f "$ROUTE_INITIAL_OWNED" || return 1
            fi
        else
            atomic_write_file "$ROUTE_INITIAL_ABSENT" "absent" 0600 || return 1
            rm -f "$ROUTE_INITIAL_OWNED" || return 1
        fi
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
    local actual expected

    [[ -f "$INITCWND_ROUTE_HOOK" ]] || return 1
    actual=$(<"$INITCWND_ROUTE_HOOK")
    expected=$(render_initcwnd_hook)
    [[ "$actual" == "$expected" ]]
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
    local hook_dir temp_hook

    hook_dir=$(dirname "$INITCWND_ROUTE_HOOK")
    if [[ ! -d "$hook_dir" ]]; then
        warn "未检测到 networkd-dispatcher，initcwnd 仅对当前 IPv4 默认路由生效"
        return 0
    fi
    if [[ -e "$INITCWND_ROUTE_HOOK" || -L "$INITCWND_ROUTE_HOOK" ]] &&
        ! is_managed_initcwnd_hook; then
        error "initcwnd 持久化路径已被其他配置占用：$INITCWND_ROUTE_HOOK"
        return 1
    fi

    temp_hook=$(mktemp "${INITCWND_ROUTE_HOOK}.new.XXXXXX") || return 1
    if ! render_initcwnd_hook > "$temp_hook" || ! chmod 0755 "$temp_hook"; then
        rm -f "$temp_hook"
        return 1
    fi
    if ! mv -f -- "$temp_hook" "$INITCWND_ROUTE_HOOK"; then
        rm -f "$temp_hook"
        return 1
    fi
}

# Generated hook uses clean as an array; apply path intentionally shadows it as a string.
# shellcheck disable=SC2128,SC2178
apply_initcwnd() {
    local route="" clean="" owned="false"
    local -a route_args=()

    if [[ "$INITCWND_ENABLED" != "true" ]]; then
        initcwnd_settings_owned && owned="true"
        if [[ "$owned" != "true" ]]; then
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
        if [[ -z "$route" ]]; then
            success "已移除 initcwnd 持久化状态；当前没有 IPv4 默认路由需要清理"
        elif [[ -n "$clean" ]]; then
            success "已移除本脚本设置的 initcwnd/initrwnd，恢复内核默认值"
        else
            success "已清理本脚本 initcwnd ownership 状态；路由已使用内核默认值"
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
    if ip -4 route replace "${route_args[@]}" initcwnd 32 initrwnd 32; then
        if ! create_initcwnd_ownership_marker; then
            error "创建 initcwnd ownership marker 失败"
            return 1
        fi
        if ! write_initcwnd_hook; then
            error "无法写入 initcwnd 持久化钩子"
            return 1
        fi
        if is_managed_initcwnd_hook; then
            success "默认路由已设置 initcwnd/initrwnd = 32，并通过 networkd-dispatcher 持久化"
        else
            success "默认路由已设置 initcwnd/initrwnd = 32（当前系统没有可用持久化钩子）"
        fi
    else
        error "默认路由不支持 initcwnd/initrwnd，网络 sysctl 已应用但路由优化失败"
        return 1
    fi
}

restore_default_route() {
    local route_file="$1" owned_file="${2:-}" absent_file="${3:-}" route="" clean=""
    local -a route_args=()

    if [[ ! -f "$route_file" && -n "$absent_file" && -e "$absent_file" ]]; then
        initcwnd_settings_owned || return 0
        route=$(default_ipv4_route) || return 1
        if [[ -z "$route" ]]; then
            remove_initcwnd_ownership_marker || return 1
            return 0
        fi
        if grep -Eq '(^| )(initcwnd|initrwnd) [0-9]+( |$)' <<< "$route"; then
            clean=$(strip_route_window_fields "$route")
            read -r -a route_args <<< "$clean"
            (( ${#route_args[@]} > 0 )) || return 1
            ip -4 route replace "${route_args[@]}" || return 1
        fi
        remove_initcwnd_ownership_marker || return 1
        return 0
    fi

    [[ -f "$route_file" ]] || {
        initcwnd_settings_owned || return 0
        route=$(default_ipv4_route) || return 1
        if [[ -z "$route" ]]; then
            remove_initcwnd_ownership_marker || return 1
            return 0
        fi
        route=$(strip_route_window_fields "$route")
    }
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
    local target="${1:-}"

    traffic_reset
    [[ -z "$target" ]] || traffic_add_target "$target"
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
    echo "流量（接口 $interfaces；含测试期间后台流量，按保守安全预算累计）：上传 $(format_bytes "$tx") / 下载 $(format_bytes "$rx") / 合计 $(format_bytes "$total")"
}

traffic_budget_reached() {
    local direction="$1" total directional total_stop=$((TRAFFIC_TOTAL_LIMIT_BYTES - TRAFFIC_STOP_RESERVE_BYTES))
    local direction_stop=$((TRAFFIC_DIRECTION_LIMIT_BYTES - TRAFFIC_STOP_RESERVE_BYTES))

    total=$(traffic_used_bytes total) || return 0
    directional=$(traffic_used_bytes "$direction") || return 0
    (( total >= total_stop || directional >= direction_stop ))
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
    local pid="$1" kill_after="${2:-$IPERF_KILL_AFTER_SECONDS}" attempt

    [[ "$pid" =~ ^[0-9]+$ ]] || return 0
    kill -TERM "$pid" 2>/dev/null || true
    for ((attempt = 0; attempt < kill_after * 10; attempt++)); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
    done
    kill -KILL "$pid" 2>/dev/null || true
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
    cleanup_tracked_pids CLOUDFLARE_WORKER_PIDS
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
    if [[ -n "${VERIFY_TEMP_DIR:-}" ]]; then
        temp_dir=$(mktemp -d "$VERIFY_TEMP_DIR/peers.XXXXXX") || return 1
    else
        temp_dir=$(mktemp -d) || return 1
    fi

    while IFS='|' read -r host location provider; do
        [[ -n "$host" ]] || continue
        ((index += 1))
        (
            peer_ip=$(resolve_ipv4 "$host" || true)
            [[ -n "$peer_ip" ]] || exit 0
            local_rtt=$(measure_ping_target "$peer_ip" || true)
            [[ -n "$local_rtt" ]] &&
                printf '%s|%s|%s|%s|%s\n' \
                    "$local_rtt" "$host" "$peer_ip" "$location" "$provider" \
                    > "$temp_dir/$index"
        ) &
    done <<< "$IPERF_PEER_POOL"
    wait || true

    for file in "$temp_dir"/*; do
        [[ -s "$file" ]] || continue
        cat "$file"
    done | sort -t '|' -k1,1n
    cleanup_temp_dir "$temp_dir"
}

tcp_port_open() {
    local ipv4="$1" port="$2"
    timeout 3 bash -c "exec 3<>/dev/tcp/$ipv4/$port" 2>/dev/null
}

run_iperf_test() {
    local host="$1" port="$2" direction="$3" output stats rc=0 reverse_mode="false"
    local receiver retransmits retransmit_percent cpu remote_cpu

    [[ "$direction" == "download" ]] && reverse_mode="true"
    output=$(mktemp) || return 1
    run_iperf_runner "$output" "$host" "$port" "$IPERF_DURATION" \
        "$IPERF_PARALLEL" "$direction" "$reverse_mode" || rc=$?
    if (( rc != 0 )); then
        rm -f "$output"
        return "$rc"
    fi
    stats=$(parse_iperf_metrics "$output") || {
        rm -f "$output"
        return 1
    }
    rm -f "$output"
    IFS='|' read -r _ receiver retransmits retransmit_percent cpu remote_cpu <<< "$stats"

    # goodput、CPU、重传与 loss 全部取自同一份完整 JSON 结果。
    printf '%s|%s|%s|%s\n' \
        "$receiver" "$cpu" "$retransmits" "$retransmit_percent"
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

verify_dependencies_available() {
    local command_name
    local -a missing=()

    for command_name in ip iperf3 jq ping timeout tc getent; do
        command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
    done
    (( ${#missing[@]} == 0 )) || {
        error "verify 缺少依赖：${missing[*]}；请先安装后重试（verify 不自动安装）"
        return 1
    }
}

run_verify_iperf() {
    local host="$1" port="$2" streams="$3" output_file rc=0

    output_file="$VERIFY_TEMP_DIR/iperf-${streams}.json"
    run_iperf_runner "$output_file" "$host" "$port" "$IPERF_DURATION" \
        "$streams" upload false || rc=$?
    if (( rc == 75 )); then
        error "verify 达到上传或总流量停止阈值，已终止 iperf3"
        return 75
    fi
    if (( rc != 0 )); then
        error "iperf3 ${streams} 流测试失败（退出码 $rc）"
        return 1
    fi
    VERIFY_RESULT=$(parse_iperf_metrics "$output_file") || {
        error "无法解析 iperf3 ${streams} 流结果"
        return 1
    }
}

cleanup_verify() {
    cleanup_tracked_pids IPERF_RUNNER_PIDS
    [[ -z "${VERIFY_TEMP_DIR:-}" ]] || rm -rf "$VERIFY_TEMP_DIR"
    VERIFY_TEMP_DIR=""
}

verify_impl() {
    local answer ranked rtt host peer_ip location provider port health_before allowance_before
    local single_result="" four_result="" candidate_single rc
    local single_sender single_receiver single_retrans single_retrans_pct single_cpu single_remote_cpu
    local four_sender four_receiver four_retrans four_retrans_pct four_cpu four_remote_cpu
    local qdisc_state qdisc_detail selected="false" traffic_started="false" attempts=0

    echo "verify 将运行 5 秒单流 + 5 秒四流上传测试。"
    echo "每个候选先测 1 流再测 4 流；任一步失败则整组作废并轮换，最多尝试 ${VERIFY_MAX_GROUP_ATTEMPTS} 组。"
    echo "正常完成约为 10 秒实际发送速率；若 1 流成功后 4 流失败，重试会重复单流并产生额外流量。"
    echo "最坏最多约 30 秒实际发送速率：1 Gbps 约 3.75 GB，10 Gbps 约 37.5 GB。"
    echo "沿用硬上限：单方向 45 GB、合计 90 GB；在 40/85 GB 提前停止。"
    echo "按每个实际 IPv4 测速目标的路由接口分别计量并汇总；接口计数包含测试期间后台流量，作为保守安全预算。"
    echo "不会修改 sysctl、路由或 qdisc；同时读取测试前后内核与网卡计数器。"
    if [[ "$VERIFY_ASSUME_YES" != "true" ]]; then
        if ! is_interactive_terminal; then
            error "非交互环境拒绝产生流量；显式传入 verify --yes 后重试"
            return 1
        fi
        read -r -p "确认开始 verify？[y/N]: " answer || return 1
        [[ "$answer" =~ ^[Yy]$ ]] || {
            info "已取消 verify；未产生测速流量"
            return 2
        }
    fi

    verify_dependencies_available || return 1
    VERIFY_TEMP_DIR=$(mktemp -d) || return 1
    ranked=$(rank_iperf_peers || true)
    [[ -n "$ranked" ]] || {
        error "无法找到可用的附近公共 iperf3 对端"
        return 1
    }
    peer_ip=$(awk -F'|' 'NF >= 3 {print $3; exit}' <<< "$ranked")
    traffic_mark "$peer_ip" || {
        error "无法按实际 IPv4 测速目标读取路由接口流量计数器，拒绝测速"
        return 1
    }
    health_before=$(network_health_snapshot "$PROBE_IFACE")
    allowance_before=$(nic_allowance_snapshot "$PROBE_IFACE")

    while IFS='|' read -r rtt host peer_ip location provider; do
        [[ -n "$peer_ip" ]] || continue
        while IFS= read -r port; do
            (( attempts >= VERIFY_MAX_GROUP_ATTEMPTS )) && break 2
            tcp_port_open "$peer_ip" "$port" || continue
            ((attempts += 1))
            candidate_single=""

            traffic_started="true"
            run_verify_iperf "$peer_ip" "$port" 1 && rc=0 || rc=$?
            if (( rc == 0 )); then
                candidate_single="$VERIFY_RESULT"
            elif (( rc == 75 )); then
                show_verify_health_since "$health_before" "$allowance_before"
                return 1
            else
                warn "候选 $host [$peer_ip]:$port 单流测试失败，整组作废"
            fi

            if [[ -n "$candidate_single" ]]; then
                run_verify_iperf "$peer_ip" "$port" 4 && rc=0 || rc=$?
                if (( rc == 0 )); then
                    single_result="$candidate_single"
                    four_result="$VERIFY_RESULT"
                    selected="true"
                    break 2
                elif (( rc == 75 )); then
                    show_verify_health_since "$health_before" "$allowance_before"
                    return 1
                else
                    warn "候选 $host [$peer_ip]:$port 四流测试失败，整组作废"
                fi
            fi

        done < <(ordered_iperf_ports)
    done <<< "$ranked"
    [[ "$selected" == "true" ]] || {
        [[ "$traffic_started" != "true" ]] || show_verify_health_since "$health_before" "$allowance_before"
        error "${attempts} 组公共 iperf3 候选均未得到完整的 1 流和 4 流结果"
        return 1
    }

    echo "对端: $location/$provider $host [$peer_ip]:$port（IPv4 RTT ${rtt} ms）"
    IFS='|' read -r single_sender single_receiver single_retrans single_retrans_pct \
        single_cpu single_remote_cpu <<< "$single_result"
    IFS='|' read -r four_sender four_receiver four_retrans four_retrans_pct \
        four_cpu four_remote_cpu <<< "$four_result"
    IFS='|' read -r qdisc_state qdisc_detail <<< "$(active_qdisc_state "$PROBE_IFACE")"

    printf '1 流：sender %s Mbps / receiver %s Mbps / 重传率 %s%%（%s 次）/ CPU 本机 %s%% 对端 %s%%\n' \
        "$single_sender" "$single_receiver" "$single_retrans_pct" "$single_retrans" \
        "$single_cpu" "$single_remote_cpu"
    printf '4 流：sender %s Mbps / receiver %s Mbps / 重传率 %s%%（%s 次）/ CPU 本机 %s%% 对端 %s%%\n' \
        "$four_sender" "$four_receiver" "$four_retrans_pct" "$four_retrans" \
        "$four_cpu" "$four_remote_cpu"
    printf '活动 qdisc: %s\n' "$(format_qdisc_state "$qdisc_state" "$qdisc_detail")"
    show_verify_health_since "$health_before" "$allowance_before"
    traffic_report
    if (( four_receiver * 100 >= single_receiver * 125 )); then
        echo "结论：4 流 goodput 明显高于 1 流；单流可能受 RTT、拥塞控制或路径限制。"
    elif (( single_receiver * 100 >= four_receiver * 125 )); then
        echo "结论：1 流 goodput 高于 4 流；对端负载或多流竞争可能影响结果。"
    else
        echo "结论：1 流与 4 流 goodput 接近；未见明显并行收益。"
    fi
}

run_verify_command() {
    local rc=0 previous_exit_trap previous_hup_trap previous_int_trap previous_term_trap

    previous_exit_trap=$(trap -p EXIT)
    previous_hup_trap=$(trap -p HUP)
    previous_int_trap=$(trap -p INT)
    previous_term_trap=$(trap -p TERM)
    trap 'cleanup_verify' EXIT
    trap 'cleanup_verify; exit 129' HUP
    trap 'cleanup_verify; exit 130' INT
    trap 'cleanup_verify; exit 143' TERM
    verify_impl || rc=$?
    cleanup_verify
    if [[ -n "$previous_exit_trap" ]]; then
        eval "$previous_exit_trap"
    else
        trap - EXIT
    fi
    if [[ -n "$previous_hup_trap" ]]; then
        eval "$previous_hup_trap"
    else
        trap - HUP
    fi
    if [[ -n "$previous_int_trap" ]]; then
        eval "$previous_int_trap"
    else
        trap - INT
    fi
    if [[ -n "$previous_term_trap" ]]; then
        eval "$previous_term_trap"
    else
        trap - TERM
    fi
    return "$rc"
}

probe_iperf_bandwidth() {
    local ranked rtt host peer_ip location provider port upload_result download_result upload download upload_cpu
    local download_cpu upload_retransmits download_retransmits upload_retransmit_percent download_retransmit_percent
    local best_upload=0 best_download=0 successful_peers=0

    command -v iperf3 >/dev/null 2>&1 || return 1
    command -v jq >/dev/null 2>&1 || return 1
    command -v timeout >/dev/null 2>&1 || return 1

    ranked=$(rank_iperf_peers || true)
    [[ -n "$ranked" ]] || return 1

    while IFS='|' read -r rtt host peer_ip location provider; do
        [[ -n "$host" ]] || continue
        (( rtt <= 150 )) || continue
        traffic_budget_reached upload && traffic_budget_reached download && break

        while IFS= read -r port; do
            traffic_add_target "$peer_ip" || continue
            show_probe_environment_once
            tcp_port_open "$peer_ip" "$port" || continue
            upload_result=$(run_iperf_test "$peer_ip" "$port" upload || true)
            download_result=$(run_iperf_test "$peer_ip" "$port" download || true)
            [[ -n "$upload_result$download_result" ]] || continue

            upload=""; upload_cpu=""; upload_retransmits=""; upload_retransmit_percent=""
            download=""; download_cpu=""; download_retransmits=""; download_retransmit_percent=""
            [[ -n "$upload_result" ]] &&
                IFS='|' read -r upload upload_cpu upload_retransmits upload_retransmit_percent <<< "$upload_result"
            [[ -n "$download_result" ]] &&
                IFS='|' read -r download download_cpu download_retransmits download_retransmit_percent <<< "$download_result"
            upload_cpu=$(format_cpu_percent "$upload_cpu")
            download_cpu=$(format_cpu_percent "$download_cpu")

            PREFERRED_IPERF_PORT="$port"
            detail "iperf3 成功节点：$location/$provider $host [$peer_ip]:$port（IPv4 RTT ${rtt} ms）"
            detail "节点结果：下载 ${download:-失败} Mbps（CPU ${download_cpu:-?}% / 重传率 ${download_retransmit_percent:-?}% [${download_retransmits:-?} 次]），上传 ${upload:-失败} Mbps（CPU ${upload_cpu:-?}% / 重传率 ${upload_retransmit_percent:-?}% [${upload_retransmits:-?} 次]）"

            [[ -n "$upload" ]] && (( upload > best_upload )) && best_upload=$upload
            [[ -n "$download" ]] && (( download > best_download )) && best_download=$download
            ((successful_peers += 1))
            break
        done < <(ordered_iperf_ports)

        (( successful_peers >= IPERF_MAX_PEERS )) && break
    done <<< "$ranked"

    (( best_upload > 0 || best_download > 0 )) || return 1
    (( best_upload > 0 )) && DETECTED_UPLOAD_MBPS=$best_upload
    (( best_download > 0 )) && DETECTED_DOWNLOAD_MBPS=$best_download
    BANDWIDTH_SOURCE="public iperf3, ${IPERF_PARALLEL} streams"
}

cloudflare_worker() {
    local direction="$1" upload_file="${2:-}" deadline=$((SECONDS + CLOUDFLARE_DURATION))
    local remaining curl_pid="" curl_rc=0

    trap 'terminate_recorded_pid "${curl_pid:-}" 1' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    while (( SECONDS < deadline )); do
        remaining=$((deadline - SECONDS))
        (( remaining > 0 )) || break

        if [[ "$direction" == "download" ]]; then
            curl -4 --noproxy '*' --fail --silent --output /dev/null \
                --resolve "speed.cloudflare.com:443:$CLOUDFLARE_IPV4" \
                --header 'Accept-Encoding: identity' \
                --connect-timeout 4 --max-time "$remaining" \
                "$SPEED_DOWNLOAD_URL?bytes=$CLOUDFLARE_DOWNLOAD_BYTES" &
        else
            curl -4 --noproxy '*' --fail --silent --output /dev/null \
                --resolve "speed.cloudflare.com:443:$CLOUDFLARE_IPV4" \
                --header 'Content-Type: application/octet-stream' \
                --header 'Expect:' \
                --connect-timeout 4 --max-time "$remaining" \
                --request POST --upload-file "$upload_file" \
                "$SPEED_UPLOAD_URL" &
        fi
        curl_pid=$!
        curl_rc=0
        wait "$curl_pid" || curl_rc=$?
        curl_pid=""
        (( curl_rc == 0 )) || break
    done
}

probe_cloudflare_direction() {
    local direction="$1" started ended elapsed start_bytes end_bytes transferred alive index pid upload_file=""
    local -a pids=()

    traffic_budget_reached "$direction" && return 1
    if [[ "$direction" == "upload" ]]; then
        upload_file=$(mktemp) || return 1
        if ! truncate -s "$CLOUDFLARE_UPLOAD_BYTES" "$upload_file"; then
            rm -f "$upload_file"
            return 1
        fi
    fi

    start_bytes=$(traffic_used_bytes "$direction") || {
        [[ -n "$upload_file" ]] && rm -f "$upload_file"
        return 1
    }
    started=$(date +%s%N)

    for ((index = 0; index < CLOUDFLARE_PARALLEL; index++)); do
        cloudflare_worker "$direction" "$upload_file" &
        pid=$!
        pids+=("$pid")
        register_tracked_pid CLOUDFLARE_WORKER_PIDS "$pid"
    done

    while true; do
        alive="false"
        for pid in "${pids[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                alive="true"
                break
            fi
        done
        [[ "$alive" == "true" ]] || break

        if traffic_budget_reached "$direction"; then
            cleanup_tracked_pids CLOUDFLARE_WORKER_PIDS
            break
        fi
        sleep 0.05
    done
    for pid in "${pids[@]}"; do
        if ! wait "$pid" 2>/dev/null; then
            detail "Cloudflare worker $pid 已停止或失败"
        fi
        unregister_tracked_pid CLOUDFLARE_WORKER_PIDS "$pid"
    done
    [[ -n "$upload_file" ]] && rm -f "$upload_file"

    ended=$(date +%s%N)
    end_bytes=$(traffic_used_bytes "$direction") || return 1
    transferred=$((end_bytes - start_bytes))
    (( transferred >= 33554432 )) || return 1

    elapsed=$(awk -v start="$started" -v end="$ended" \
        'BEGIN {printf "%.3f", (end - start) / 1000000000}')
    awk -v bytes="$transferred" -v seconds="$elapsed" '
        BEGIN {
            if (seconds <= 0) exit 1
            printf "%.0f\n", bytes * 8 / seconds / 1000000
        }
    '
}

format_bandwidth_result() {
    if [[ "$1" =~ ^[0-9]+$ ]]; then
        echo " $1 Mbps"
    else
        echo "失败"
    fi
}

probe_cloudflare_bandwidth() {
    local upload="" download="" crosscheck=""

    command -v curl >/dev/null 2>&1 || return 1
    CLOUDFLARE_IPV4=$(resolve_ipv4 speed.cloudflare.com || true)
    [[ -n "$CLOUDFLARE_IPV4" ]] || return 1
    traffic_add_target "$CLOUDFLARE_IPV4" || {
        warn "无法按 Cloudflare 实际 IPv4 目标读取路由接口计数器"
        return 1
    }
    show_probe_environment_once
    detail "使用 8 流 Cloudflare 交叉验证；iperf3 不可用时同时作为回退..."

    download=$(probe_cloudflare_direction download || true)
    upload=$(probe_cloudflare_direction upload || true)

    if [[ -n "$download" || -n "$upload" ]]; then
        detail "Cloudflare 结果：下载$(format_bandwidth_result "$download")，上传$(format_bandwidth_result "$upload")"
    else
        warn "Cloudflare 交叉验证失败：两个方向均未获得足够有效流量"
    fi

    if [[ -n "$download" ]] &&
        { [[ -z "$DETECTED_DOWNLOAD_MBPS" ]] || (( download > DETECTED_DOWNLOAD_MBPS )); }; then
        DETECTED_DOWNLOAD_MBPS="$download"
    fi
    if [[ -n "$upload" ]] &&
        { [[ -z "$DETECTED_UPLOAD_MBPS" ]] || (( upload > DETECTED_UPLOAD_MBPS )); }; then
        DETECTED_UPLOAD_MBPS="$upload"
    fi
    [[ -n "$DETECTED_DOWNLOAD_MBPS$DETECTED_UPLOAD_MBPS" ]] || return 1

    [[ -n "$download" ]] && crosscheck="download"
    [[ -n "$upload" ]] && crosscheck="${crosscheck:+$crosscheck/}upload"
    if [[ "$BANDWIDTH_SOURCE" == "unknown" ]]; then
        BANDWIDTH_SOURCE="Cloudflare $crosscheck, ${CLOUDFLARE_PARALLEL} parallel streams"
    elif [[ -n "$crosscheck" ]]; then
        BANDWIDTH_SOURCE="$BANDWIDTH_SOURCE + Cloudflare $crosscheck cross-check"
    fi
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
    if [[ "$root_qdisc" == "htb" &&
        -f "${NETWORK_OPTIMIZE_TCSHAPE_CONFIG_FILE:-/etc/tcshape.conf}" ]]; then
        BANDWIDTH_PROBE_NOTE="tcshape HTB 整形状态下测得（可能偏低）"
        warn "检测到 tcshape HTB 正在限制 $iface，主动测速结果可能偏低"
        warn "建议先执行 tcshape off，再重新运行 network-optimize 主动测速"
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

    info "自动测量公网带宽（40/85 GB 提前停止，硬上限 45/90 GB；按实际目标接口汇总）..."
    probe_iperf_bandwidth || true
    # 公共 iperf3 节点可能忙碌或单向限速；只要预算允许，再用并行 Cloudflare
    # 交叉验证，并对每个方向保留较高结果。
    probe_cloudflare_bandwidth || true
    traffic_report

    [[ -n "$DETECTED_DOWNLOAD_MBPS$DETECTED_UPLOAD_MBPS" ]] || return 1
    raw_download="$DETECTED_DOWNLOAD_MBPS"
    raw_upload="$DETECTED_UPLOAD_MBPS"

    if [[ -z "$DETECTED_UPLOAD_MBPS" && -n "$DETECTED_DOWNLOAD_MBPS" ]]; then
        DETECTED_UPLOAD_MBPS="$DETECTED_DOWNLOAD_MBPS"
        BANDWIDTH_SOURCE="$BANDWIDTH_SOURCE; upload inferred"
    elif [[ -z "$DETECTED_DOWNLOAD_MBPS" && -n "$DETECTED_UPLOAD_MBPS" ]]; then
        DETECTED_DOWNLOAD_MBPS="$DETECTED_UPLOAD_MBPS"
        BANDWIDTH_SOURCE="$BANDWIDTH_SOURCE; download inferred"
    fi

    DETECTED_DOWNLOAD_MBPS=$(round_bandwidth "$DETECTED_DOWNLOAD_MBPS")
    DETECTED_UPLOAD_MBPS=$(round_bandwidth "$DETECTED_UPLOAD_MBPS")

    detail "原始测速：下载 ${raw_download:-缺失} Mbps，上传 ${raw_upload:-缺失} Mbps"
    detail "计算带宽：下载 $DETECTED_DOWNLOAD_MBPS Mbps，上传 $DETECTED_UPLOAD_MBPS Mbps"
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

needs_automatic_probe() {
    [[ "$TUNING_MODE" == "probe" ]] || return 1
    [[ -z "$MANUAL_BANDWIDTH_MBPS" &&
       ( -z "$MANUAL_DOWNLOAD_MBPS" || -z "$MANUAL_UPLOAD_MBPS" ) ]]
}

install_probe_dependencies() {
    local packages=()

    command -v curl >/dev/null 2>&1 || packages+=(curl)
    command -v ping >/dev/null 2>&1 || packages+=(iputils-ping)
    command -v iperf3 >/dev/null 2>&1 || packages+=(iperf3)
    command -v jq >/dev/null 2>&1 || packages+=(jq)
    command -v timeout >/dev/null 2>&1 || packages+=(coreutils)
    [[ -s /etc/ssl/certs/ca-certificates.crt ]] || packages+=(ca-certificates)
    (( ${#packages[@]} > 0 )) || return 0

    if ! command -v apt-get >/dev/null 2>&1; then
        warn "缺少探测工具且未找到 apt-get"
        return 1
    fi

    info "安装网络探测依赖：${packages[*]}"
    if ! DEBIAN_FRONTEND=noninteractive apt-get update -qq; then
        warn "apt 索引更新失败，将继续尝试安装依赖"
    fi
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        "${packages[@]}"; then
        warn "网络探测依赖安装失败"
        return 1
    fi
}

resolve_tuning_values() {
    local download_mbps="" upload_mbps="" rtt_ms=""

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

    download_mbps="$MANUAL_DOWNLOAD_MBPS"
    upload_mbps="$MANUAL_UPLOAD_MBPS"
    if [[ -n "$MANUAL_BANDWIDTH_MBPS" ]]; then
        [[ -n "$download_mbps" ]] || download_mbps="$MANUAL_BANDWIDTH_MBPS"
        [[ -n "$upload_mbps" ]] || upload_mbps="$MANUAL_BANDWIDTH_MBPS"
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

    if [[ -z "$download_mbps" || -z "$upload_mbps" ]]; then
        if [[ "$TUNING_MODE" != "probe" ]]; then
            error "缺少有效上下行带宽，拒绝生成或应用配置"
            return 1
        fi
        if probe_bandwidth; then
            [[ -n "$download_mbps" ]] || download_mbps="$DETECTED_DOWNLOAD_MBPS"
            [[ -n "$upload_mbps" ]] || upload_mbps="$DETECTED_UPLOAD_MBPS"
        else
            warn "带宽探测失败"
            if ! is_interactive_terminal; then
                error "非交互终端无法手填带宽，拒绝生成或应用配置"
                return 1
            fi
            info "请手动提供上下行带宽"
            prompt_manual_bandwidth "interactive fallback after probe failure" || return 1
            download_mbps="$MANUAL_DOWNLOAD_MBPS"
            upload_mbps="$MANUAL_UPLOAD_MBPS"
            rtt_ms="$MANUAL_RTT_MS"
            if [[ "$MANUAL_RTT_DEFAULTED" == "true" ]]; then
                RTT_SOURCE="default for manual bandwidth"
                RTT_POLICY="fixed 150 ms default"
            else
                RTT_SOURCE="command line"
                RTT_POLICY="manual override"
            fi
        fi
    fi

    if ! is_positive_integer "$download_mbps" 1 100000 ||
        ! is_positive_integer "$upload_mbps" 1 100000; then
        error "未获得有效上下行带宽，拒绝生成或应用配置"
        return 1
    fi
    if [[ "$TUNING_MODE" == "manual" && "$BANDWIDTH_SOURCE" == "unknown" ]]; then
        BANDWIDTH_SOURCE="command line"
    fi

    DETECTED_DOWNLOAD_MBPS="$download_mbps"
    DETECTED_UPLOAD_MBPS="$upload_mbps"
    DETECTED_RTT_MS="$rtt_ms"

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

format_mib() {
    awk -v bytes="$1" 'BEGIN {printf "%.1f", bytes / 1048576}'
}

format_buffer_size() {
    awk -v bytes="$1" 'BEGIN {
        if (bytes < 1048576) printf "%.0f KiB", bytes / 1024
        else printf "%.1f MiB", bytes / 1048576
    }'
}

show_tuning_plan() {
    echo "========== 网络动态配置计划 =========="
    echo "模式: $TUNING_MODE"
    echo "物理内存: ${PHYSICAL_RAM_MB} MiB"
    echo "有效内存: ${RAM_MB} MiB"
    echo "单 socket 上限: $(format_mib "$MEMORY_CAP_BYTES") MiB（有效内存 / 32，绝对上限 256 MiB）"
    echo "下载带宽: ${DETECTED_DOWNLOAD_MBPS:-未知} Mbps"
    echo "上传带宽: ${DETECTED_UPLOAD_MBPS:-未知} Mbps"
    echo "带宽来源: $BANDWIDTH_SOURCE"
    format_rtt_selection_summary
    echo "接收 BDP: $((RX_BDP_BYTES / 1024)) KiB"
    echo "发送 BDP: $((TX_BDP_BYTES / 1024)) KiB"
    echo "rmem_max: $(format_buffer_size "$RMEM_MAX_BYTES")"
    echo "wmem_max: $(format_buffer_size "$WMEM_MAX_BYTES")"
    echo "tcp_rmem default: $(format_buffer_size "$RMEM_DEFAULT_BYTES")"
    echo "tcp_wmem default: $(format_buffer_size "$WMEM_DEFAULT_BYTES")"
    echo "计算依据: $CALCULATION_REASON"
    echo "initcwnd 模式: $INITCWND_MODE"
    echo "initcwnd/initrwnd: $([[ "$INITCWND_ENABLED" == "true" ]] && echo "32" || echo "内核默认")（策略: $INITCWND_POLICY）"
    echo "ECN: $([[ "$ECN_DISABLED" == "true" ]] && echo "显式禁用" || echo "保留当前设置（不持久接管）")"
}

network_health_snapshot() {
    local iface="${1:-}" dropped=0 squeezed=0 rx_errors=0 tx_errors=0 rx_dropped=0 tx_dropped=0 rx_packets=0
    local tx_packets=0 retrans=0 limited=0 line drop_hex squeeze_hex

    if [[ -r /proc/net/softnet_stat ]]; then
        while read -r line; do
            read -r _ drop_hex squeeze_hex _ <<< "$line"
            dropped=$((dropped + 16#${drop_hex:-0}))
            squeezed=$((squeezed + 16#${squeeze_hex:-0}))
        done < /proc/net/softnet_stat
    fi
    if [[ -n "$iface" ]]; then
        rx_errors=$(cat "/sys/class/net/$iface/statistics/rx_errors" 2>/dev/null || echo 0)
        tx_errors=$(cat "/sys/class/net/$iface/statistics/tx_errors" 2>/dev/null || echo 0)
        rx_dropped=$(cat "/sys/class/net/$iface/statistics/rx_dropped" 2>/dev/null || echo 0)
        tx_dropped=$(cat "/sys/class/net/$iface/statistics/tx_dropped" 2>/dev/null || echo 0)
        rx_packets=$(cat "/sys/class/net/$iface/statistics/rx_packets" 2>/dev/null || echo 0)
        tx_packets=$(cat "/sys/class/net/$iface/statistics/tx_packets" 2>/dev/null || echo 0)
    fi
    retrans=$(awk '/^Tcp:/ {if (++seen == 2) print $13}' /proc/net/snmp 2>/dev/null || echo 0)
    if command -v ss >/dev/null 2>&1; then
        limited=$(ss -tinmH 2>/dev/null |
            awk '/(sndbuf_limited|rwnd_limited)/ {count++} END {print count+0}')
    fi

    printf '%s %s %s %s %s %s %s %s %s %s\n' \
        "$dropped" "$squeezed" "${rx_errors:-0}" "${tx_errors:-0}" \
        "${rx_dropped:-0}" "${tx_dropped:-0}" "${retrans:-0}" "$limited" \
        "${rx_packets:-0}" "${tx_packets:-0}"
}

classify_network_health() {
    local softnet_drop="$1" squeezed="$2" errors="$3" nic_drop="$4" packets="$5" drop_ppm=0

    (( packets > 0 )) && drop_ppm=$((nic_drop * 1000000 / packets))

    if (( softnet_drop > 0 || errors > 0 ||
          (nic_drop >= 100 && packets > 0 && drop_ppm >= 1000) )); then
        printf '异常：测速期间 softnet 丢包 +%s，网卡丢包 +%s（%s ppm），网卡错误 +%s' \
            "$softnet_drop" "$nic_drop" "$drop_ppm" "$errors"
    elif (( nic_drop > 10 || drop_ppm > 100 || squeezed > 0 ||
             (nic_drop > 0 && packets == 0) )); then
        printf '注意：测速期间 softnet budget pressure +%s，网卡丢包 +%s（%s ppm），无新增 softnet 丢包或网卡错误' \
            "$squeezed" "$nic_drop" "$drop_ppm"
    elif (( nic_drop > 0 )); then
        printf '正常：测速期间仅有轻微网卡丢包波动 +%s（%s ppm），无 softnet 丢包或网卡错误' \
            "$nic_drop" "$drop_ppm"
    else
        printf '正常：测速期间 softnet 和网卡无新增丢包或错误'
    fi
}

nic_allowance_snapshot() {
    local iface="${1:-}" output

    [[ -n "$iface" ]] || return 0
    command -v ethtool >/dev/null 2>&1 || return 0
    output=$(ethtool -S "$iface" 2>/dev/null) || return 0
    awk '
            $1 ~ /_allowance_exceeded:$/ && $2 ~ /^[0-9]+$/ {
                key = $1
                sub(/:$/, "", key)
                print key "=" $2
            }
        ' <<< "$output"
}

format_nic_allowance_delta() {
    local before="$1" after="$2" key value before_value after_value delta part output=""
    local -a keys=()
    local -A before_values=()
    local -A after_values=()

    while IFS='=' read -r key value; do
        [[ -n "$key" && "$value" =~ ^[0-9]+$ ]] || continue
        before_values["$key"]="$value"
    done <<< "$before"
    while IFS='=' read -r key value; do
        [[ -n "$key" && "$value" =~ ^[0-9]+$ ]] || continue
        after_values["$key"]="$value"
    done <<< "$after"
    mapfile -t keys < <(
        printf '%s\n' "${!before_values[@]}" "${!after_values[@]}" |
            sed '/^$/d' | sort -u
    )
    (( ${#keys[@]} > 0 )) || return 0

    for key in "${keys[@]}"; do
        before_value=${before_values[$key]:-0}
        after_value=${after_values[$key]:-$before_value}
        if (( after_value < before_value )); then
            part="$key 计数器重置（$before_value -> $after_value）"
        else
            delta=$((after_value - before_value))
            (( delta > 0 )) || continue
            part="$key +$delta"
        fi
        [[ -z "$output" ]] || output+=", "
        output+="$part"
    done

    if [[ -n "$output" ]]; then
        printf '驱动 allowance：%s\n' "$output"
    else
        printf '驱动 allowance：无新增超额事件\n'
    fi
}

health_delta() {
    local before="$1" after="$2" value
    local b_drop b_squeeze b_rxerr b_txerr b_rxdrop b_txdrop b_retrans _ b_rxpkt b_txpkt
    local a_drop a_squeeze a_rxerr a_txerr a_rxdrop a_txdrop a_retrans a_limited a_rxpkt a_txpkt

    read -r b_drop b_squeeze b_rxerr b_txerr b_rxdrop b_txdrop b_retrans _ b_rxpkt b_txpkt <<< "$before"
    read -r a_drop a_squeeze a_rxerr a_txerr a_rxdrop a_txdrop a_retrans a_limited a_rxpkt a_txpkt <<< "$after"
    for value in "$b_drop" "$b_squeeze" "$b_rxerr" "$b_txerr" "$b_rxdrop" "$b_txdrop" \
        "$b_retrans" "$b_rxpkt" "$b_txpkt" "$a_drop" "$a_squeeze" "$a_rxerr" \
        "$a_txerr" "$a_rxdrop" "$a_txdrop" "$a_retrans" "$a_limited" "$a_rxpkt" "$a_txpkt"; do
        [[ "$value" =~ ^[0-9]+$ ]] || { printf '%s\n' unreadable; return; }
    done
    if (( a_drop < b_drop || a_squeeze < b_squeeze || a_rxerr < b_rxerr ||
          a_txerr < b_txerr || a_rxdrop < b_rxdrop || a_txdrop < b_txdrop ||
          a_retrans < b_retrans || a_rxpkt < b_rxpkt || a_txpkt < b_txpkt )); then
        printf '%s\n' reset
        return
    fi
    printf 'ok %s %s %s %s %s %s %s %s %s %s\n' \
        "$((a_drop - b_drop))" "$((a_squeeze - b_squeeze))" \
        "$((a_rxerr - b_rxerr))" "$((a_txerr - b_txerr))" \
        "$((a_rxdrop - b_rxdrop))" "$((a_txdrop - b_txdrop))" \
        "$((a_retrans - b_retrans))" "$a_limited" \
        "$((a_rxpkt - b_rxpkt))" "$((a_txpkt - b_txpkt))"
}

format_verify_health_delta() {
    local before="$1" after="$2" allowance_before="$3" allowance_after="$4"
    local status delta_drop delta_squeeze delta_rxerr delta_txerr delta_rxdrop delta_txdrop
    local delta_retrans limited delta_rxpkt delta_txpkt delta_packets health

    read -r status delta_drop delta_squeeze delta_rxerr delta_txerr delta_rxdrop delta_txdrop \
        delta_retrans limited delta_rxpkt delta_txpkt <<< "$(health_delta "$before" "$after")"
    if [[ "$status" != "ok" ]]; then
        [[ "$status" == "reset" ]] &&
            printf '网络健康：测试期间计数器重置，无法计算可靠增量\n' ||
            printf '网络健康：计数器不可读，无法计算 verify 增量\n'
        format_nic_allowance_delta "$allowance_before" "$allowance_after"
        return 0
    fi

    delta_packets=$((delta_rxpkt + delta_txpkt))
    health=$(classify_network_health "$delta_drop" "$delta_squeeze" \
        "$((delta_rxerr + delta_txerr))" "$((delta_rxdrop + delta_txdrop))" "$delta_packets")
    printf '系统计数增量：softnet_dropped +%s / time_squeeze +%s / 全机 TCP 重传 +%s\n' \
        "$delta_drop" "$delta_squeeze" "$delta_retrans"
    printf '网卡计数增量：drops rx +%s tx +%s / errors rx +%s tx +%s / packets rx +%s tx +%s\n' \
        "$delta_rxdrop" "$delta_txdrop" "$delta_rxerr" "$delta_txerr" "$delta_rxpkt" "$delta_txpkt"
    printf '网络健康：%s；当前受限 socket %s\n' "$health" "$limited"
    format_nic_allowance_delta "$allowance_before" "$allowance_after"
}
show_verify_health_since() {
    local health_before="$1" allowance_before="$2" health_after allowance_after

    health_after=$(network_health_snapshot "$PROBE_IFACE")
    allowance_after=$(nic_allowance_snapshot "$PROBE_IFACE")
    format_verify_health_delta "$health_before" "$health_after" \
        "$allowance_before" "$allowance_after"
}

format_rtt_selection_summary() {
    printf 'RTT：计算 %s ms（来源 %s；策略 %s）\n' \
        "${DETECTED_RTT_MS:-未知}" "${RTT_SOURCE:-unknown}" "${RTT_POLICY:-unknown}"
}

show_install_summary() {
    local before="$1" bbr_enabled="$2" after status delta_drop delta_squeeze delta_rxerr delta_txerr
    local delta_rxdrop delta_txdrop delta_retrans limited delta_rxpkt delta_txpkt delta_packets health
    local algorithm="当前拥塞控制" qdisc_state qdisc_detail

    after=$(network_health_snapshot "$PROBE_IFACE")
    read -r status delta_drop delta_squeeze delta_rxerr delta_txerr delta_rxdrop delta_txdrop \
        delta_retrans limited delta_rxpkt delta_txpkt <<< "$(health_delta "$before" "$after")"
    if [[ "$status" == "ok" ]]; then
        delta_packets=$((delta_rxpkt + delta_txpkt))
        health=$(classify_network_health "$delta_drop" "$delta_squeeze" \
            "$((delta_rxerr + delta_txerr))" "$((delta_rxdrop + delta_txdrop))" "$delta_packets")
    else
        health=$([[ "$status" == "reset" ]] && echo "计数器已重置" || echo "计数器不可读")
        delta_retrans="?"
        limited="?"
    fi
    [[ "$bbr_enabled" == "true" ]] && algorithm="BBR"
    IFS='|' read -r qdisc_state qdisc_detail <<< \
        "$(active_qdisc_state "${PROBE_IFACE:-}")"

    printf '环境：%s CPU / %.1f GiB / %s\n' \
        "$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 未知)" \
        "$(awk -v mb="$RAM_MB" 'BEGIN {print mb / 1024}')" \
        "${PROBE_IFACE:-unknown}"
    printf '测量：%s↓ %s↑ Mbps\n' \
        "${DETECTED_DOWNLOAD_MBPS:-未知}" "${DETECTED_UPLOAD_MBPS:-未知}"
    format_rtt_selection_summary
    printf '缓冲：TCP 起点 %s / 最大 %s\n' \
        "$(format_buffer_size "$WMEM_DEFAULT_BYTES")" "$(format_buffer_size "$WMEM_MAX_BYTES")"
    printf '网络健康：%s；TCP 重传新增 %s；受限 socket %s\n' \
        "$health" "$delta_retrans" "$limited"
    printf '应用：%s + ECN %s，配置成功；fq %s\n' \
        "$algorithm" "$([[ "$ECN_DISABLED" == "true" ]] && echo 已禁用 || echo 未接管)" \
        "$(format_qdisc_state "$qdisc_state" "$qdisc_detail")"
    printf 'initcwnd：%s（策略 %s）\n' \
        "$([[ "$INITCWND_ENABLED" == "true" ]] && echo 32 || echo 内核默认)" \
        "$INITCWND_POLICY"
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

    if [[ -e /proc/sys/net/ipv4/tcp_shrink_window ]]; then
        echo "net.ipv4.tcp_shrink_window = 1" >> "$target_file"
    fi

    if [[ -e /proc/sys/net/ipv4/tcp_collapse_max_bytes ]]; then
        echo "net.ipv4.tcp_collapse_max_bytes = 6291456" >> "$target_file"
    fi
}

create_network_config() {
    local target_file="$1" enable_bbr="$2"

    cat > "$target_file" <<EOF
# 由 network-optimize.sh 自动生成。
# 模式: $TUNING_MODE
# 物理内存: ${PHYSICAL_RAM_MB} MiB
# 有效内存: ${RAM_MB} MiB
# 下载带宽: ${DETECTED_DOWNLOAD_MBPS:-unknown} Mbps
# 上传带宽: ${DETECTED_UPLOAD_MBPS:-unknown} Mbps
# 带宽来源: $BANDWIDTH_SOURCE
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

# 4. TCP/UDP 缓冲区；TCP 初始默认固定 2 MiB，长流继续依赖 autotuning
# core default 与全局 tcp_mem 保留内核或发行版值，避免放大所有 socket 的内存承诺
net.core.rmem_max = $RMEM_MAX_BYTES
net.core.wmem_max = $WMEM_MAX_BYTES
net.ipv4.tcp_rmem = 4096 $RMEM_DEFAULT_BYTES $RMEM_MAX_BYTES
net.ipv4.tcp_wmem = 4096 $WMEM_DEFAULT_BYTES $WMEM_MAX_BYTES

# 5. 长连接、连接回收与复杂路径
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_mtu_probing = 1
EOF

    if [[ "$ECN_DISABLED" == "true" ]]; then
        cat >> "$target_file" <<'EOF'

# 仅在显式请求时禁用 ECN；默认保留系统或管理员设置
net.ipv4.tcp_ecn = 0
EOF
    fi

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

capture_runtime_values() {
    capture_runtime_values_from_files "$2" "$1"
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

    [[ "$failed" == "false" ]] || return 1
    success "运行时 sysctl 已与生成配置一致"
}

rollback_initcwnd_install() {
    INITCWND_ROLLBACK_FAILED_ITEMS=()

    if ! restore_default_route \
        "$ROUTE_PREVIOUS_BACKUP" "$ROUTE_PREVIOUS_OWNED" "$ROUTE_PREVIOUS_ABSENT"; then
        INITCWND_ROLLBACK_FAILED_ITEMS+=(route)
    fi
    if ! restore_managed_file \
        "$INITCWND_ROUTE_HOOK" "$ROUTE_HOOK_PREVIOUS_BACKUP" \
        "$ROUTE_HOOK_PREVIOUS_ABSENT"; then
        INITCWND_ROLLBACK_FAILED_ITEMS+=(hook)
    fi
    if ! apply_runtime_values_strict "$RUNTIME_PREVIOUS_BACKUP"; then
        INITCWND_ROLLBACK_FAILED_ITEMS+=(runtime)
    fi
    if ! restore_managed_file \
        "$NETWORK_CONF" "$NETWORK_PREVIOUS_BACKUP" "$NETWORK_PREVIOUS_ABSENT"; then
        INITCWND_ROLLBACK_FAILED_ITEMS+=(config)
    fi

    (( ${#INITCWND_ROLLBACK_FAILED_ITEMS[@]} == 0 ))
}

install_optimization() {
    local temp_config runtime_backup bbr_enabled="false" health_before

    info "开始配置网络优化..."

    if detect_container; then
        warn "检测到容器虚拟化环境，部分 sysctl 参数可能受宿主机限制"
    fi

    if needs_automatic_probe; then
        install_probe_dependencies || true
    fi

    PROBE_IFACE=$(detect_default_iface || true)
    health_before=$(network_health_snapshot "$PROBE_IFACE")
    resolve_tuning_values || return 1
    if [[ "${DEBUG:-}" == "1" ]]; then
        show_tuning_plan
    fi

    if ! temp_config=$(mktemp "${NETWORK_CONF}.new.XXXXXX"); then
        error "无法创建网络配置临时文件"
        return 1
    fi

    # 先按 BBR 可用生成候选配置，确保修改前快照包含拥塞控制键。
    # 完成全部备份后再尝试加载模块；不可用时重生成不接管拥塞控制的配置。
    create_network_config "$temp_config" true

    runtime_backup=$(mktemp) || {
        rm -f "$temp_config"
        return 1
    }

    if ! capture_runtime_values "$temp_config" "$runtime_backup"; then
        rm -f "$temp_config" "$runtime_backup"
        return 1
    fi
    prepare_legacy_backup_state

    install -d -m 0755 "$NETWORK_OPTIMIZE_STATE_DIR"
    merge_initial_runtime_values "$runtime_backup" || {
        rm -f "$temp_config" "$runtime_backup"
        return 1
    }
    backup_previous_state_set "$runtime_backup" || {
        rm -f "$temp_config" "$runtime_backup"
        return 1
    }

    if ensure_bbr_available; then
        bbr_enabled="true"
        info "BBR 支持：可用"
    else
        create_network_config "$temp_config" false
    fi

    # 应用前已保存全部涉及参数的运行值，失败时逐项回滚。
    if ! apply_network_config "$temp_config"; then
        restore_runtime_values "$runtime_backup"
        rm -f "$temp_config" "$runtime_backup"
        return 1
    fi
    if ! verify_network_config "$temp_config"; then
        restore_runtime_values "$runtime_backup"
        rm -f "$temp_config" "$runtime_backup"
        return 1
    fi

    if ! mv "$temp_config" "$NETWORK_CONF"; then
        error "写入网络配置文件失败"
        restore_runtime_values "$runtime_backup"
        rm -f "$temp_config" "$runtime_backup"
        return 1
    fi

    if ! apply_initcwnd; then
        if rollback_initcwnd_install; then
            error "initcwnd 应用失败，已回滚 route、hook、runtime、config"
        else
            error "initcwnd 应用失败，且回滚不完整：失败项 ${INITCWND_ROLLBACK_FAILED_ITEMS[*]}"
        fi
        rm -f "$temp_config" "$runtime_backup"
        return 1
    fi

    rm -f "$runtime_backup"
    success "网络优化配置已写入：$NETWORK_CONF"

    if [[ "$bbr_enabled" == "true" ]]; then
        if persist_bbr_module; then
            success "BBR 模块已设置为开机加载：$BBR_MODULES_FILE"
        else
            warn "无法写入 BBR 模块开机加载配置；当前运行不受影响"
        fi
    else
        warn "BBR 未启用；其余网络参数已正常应用"
    fi

    show_install_summary "$health_before" "$bbr_enabled"
}

# Capture operation-before state for compensating rollback on restore failure.
begin_restore_transaction() {
    local config_backup="$1" runtime_backup="$2" transaction_dir="" route="" query_status=0

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

    route=$(query_default_ipv4_route) || query_status=$?
    case "$query_status" in
        0)
            if ! atomic_write_file "$transaction_dir/route" "$route" 0600; then
                rm -rf -- "$transaction_dir"
                return 1
            fi
            ;;
        2)
            atomic_write_file "$transaction_dir/route-absent" "absent" 0600 || {
                rm -rf -- "$transaction_dir"
                return 1
            }
            ;;
        *)
            rm -rf -- "$transaction_dir"
            return 1
            ;;
    esac

    if [[ -e "$ROUTE_OWNED_MARKER" ]]; then
        atomic_write_file "$transaction_dir/route-owned" "owned" 0600 || {
            rm -rf -- "$transaction_dir"
            return 1
        }
    fi

    RESTORE_TRANSACTION_DIR="$transaction_dir"
}

restore_captured_default_route() {
    local transaction_dir="$1" target_route_file="$2" current_route="" expected_route="" query_status=0
    local -a route_args=()

    if [[ -f "$transaction_dir/route" ]]; then
        restore_default_route \
            "$transaction_dir/route" "$transaction_dir/route-owned"
        return $?
    fi
    [[ -e "$transaction_dir/route-absent" ]] || return 1

    current_route=$(query_default_ipv4_route) || query_status=$?
    if (( query_status == 2 )); then
        if [[ -e "$transaction_dir/route-owned" ]]; then
            create_initcwnd_ownership_marker || return 1
        else
            remove_initcwnd_ownership_marker || return 1
        fi
        return $?
    fi
    (( query_status == 0 )) || return 1

    [[ -f "$target_route_file" ]] || return 1
    expected_route=$(<"$target_route_file")
    [[ "$current_route" == "$expected_route" ]] || return 1
    read -r -a route_args <<< "$current_route"
    (( ${#route_args[@]} > 0 )) || return 1
    ip -4 route del "${route_args[@]}" || return 1
    if [[ -e "$transaction_dir/route-owned" ]]; then
        create_initcwnd_ownership_marker || return 1
    else
        remove_initcwnd_ownership_marker || return 1
    fi
}

rollback_restore_transaction() {
    local transaction_dir="$1" target_route_file="$2"

    RESTORE_ROLLBACK_FAILED_ITEMS=()
    if ! restore_managed_file \
        "$NETWORK_CONF" "$transaction_dir/network" "$transaction_dir/network-absent"; then
        RESTORE_ROLLBACK_FAILED_ITEMS+=(sysctl)
    fi
    if ! restore_managed_file \
        "$BBR_MODULES_FILE" "$transaction_dir/modules" "$transaction_dir/modules-absent"; then
        RESTORE_ROLLBACK_FAILED_ITEMS+=(modules)
    fi
    if ! apply_runtime_values_strict "$transaction_dir/runtime"; then
        RESTORE_ROLLBACK_FAILED_ITEMS+=(runtime)
    fi
    if ! restore_captured_default_route "$transaction_dir" "$target_route_file"; then
        RESTORE_ROLLBACK_FAILED_ITEMS+=(route)
    fi
    if ! restore_managed_file \
        "$INITCWND_ROUTE_HOOK" "$transaction_dir/hook" "$transaction_dir/hook-absent"; then
        RESTORE_ROLLBACK_FAILED_ITEMS+=(hook)
    fi

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
    local key="$1" fallback="${2:-不可用}" value

    if value=$(sysctl -n "$key" 2>/dev/null); then
        printf '%s\n' "${value:-$fallback}"
    else
        printf '%s\n' "$fallback"
    fi
}

print_sysctl_rows() {
    local spec label key fallback

    for spec in "$@"; do
        IFS='|' read -r label key fallback <<< "$spec"
        printf '  %s: %s\n' "$label" "$(read_sysctl_or "$key" "${fallback:-不可用}")"
    done
}

file_handle_status() {
    local source_file="${NETWORK_OPTIMIZE_FILE_NR:-/proc/sys/fs/file-nr}" allocated unused maximum

    if read -r allocated unused maximum 2>/dev/null < "$source_file"; then
        printf '%s allocated / %s unused / %s max\n' "$allocated" "$unused" "$maximum"
    else
        printf '%s\n' '不可用'
    fi
}

show_status() {
    local available_cc current_cc current_qdisc default_iface active_qdisc active_qdisc_state_name
    local active_qdisc_detail initcwnd_state initcwnd_state_name initcwnd_detail

    available_cc=$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || echo "未知")
    current_cc=$(read_sysctl_or net.ipv4.tcp_congestion_control "未知")
    current_qdisc=$(read_sysctl_or net.core.default_qdisc "未知")
    default_iface=$(detect_default_iface || true)
    active_qdisc=$(active_qdisc_state "$default_iface")
    IFS='|' read -r active_qdisc_state_name active_qdisc_detail <<< "$active_qdisc"
    initcwnd_state=$(detect_initcwnd_state)
    IFS='|' read -r initcwnd_state_name initcwnd_detail <<< "$initcwnd_state"

    echo "========== 网络优化状态 =========="
    echo "配置文件: $NETWORK_CONF"
    [[ -f "$NETWORK_CONF" ]] && echo "配置状态: 已存在" || echo "配置状态: 未创建"
    if [[ -f "$NETWORK_CONF" ]]; then
        grep -E '^# (模式|内存|物理内存|有效内存|下载带宽|上传带宽|带宽来源|带宽测量环境|计算 RTT|RTT 来源|RTT 策略|initcwnd 模式|initcwnd 策略|缓冲区依据):' "$NETWORK_CONF" | sed 's/^# /  /'
    fi
    [[ -f "$NETWORK_INITIAL_BACKUP" ]] && echo "初始备份: $NETWORK_INITIAL_BACKUP"
    [[ -f "$NETWORK_INITIAL_ABSENT" ]] && echo "初始状态: 配置文件原本不存在"
    [[ -f "$NETWORK_INITIAL_UNKNOWN" ]] && echo "初始状态: 旧版未记录，无法安全推测"
    [[ -f "$NETWORK_PREVIOUS_BACKUP" ]] && echo "上次备份: $NETWORK_PREVIOUS_BACKUP"

    echo
    echo "系统资源:"
    echo "  RAM: $(memory_status_summary)"
    echo "  Swap: $(swap_status_summary)"
    echo "  最近一小时 OOM: $(recent_oom_event_count)"

    echo
    echo "拥塞控制:"
    echo "  可用算法: $available_cc"
    echo "  当前算法: $current_cc"
    echo "  default qdisc: $current_qdisc"
    echo "  active qdisc (${default_iface:-未知接口}): $(format_qdisc_state "$active_qdisc_state_name" "$active_qdisc_detail")"
    print_sysctl_rows "TCP Fast Open|net.ipv4.tcp_fastopen|未知"

    echo
    echo "兼容性诊断（只读）:"
    print_sysctl_rows \
        "rp_filter(all)|net.ipv4.conf.all.rp_filter|未知" \
        "rp_filter(default)|net.ipv4.conf.default.rp_filter|未知"
    echo "  route_localnet: 未由本模块配置"
    echo "  MPTCP: 未由本模块配置"

    echo
    echo "连接容量:"
    print_sysctl_rows \
        "somaxconn|net.core.somaxconn|未知" \
        "tcp_max_syn_backlog|net.ipv4.tcp_max_syn_backlog|未知" \
        "netdev_max_backlog|net.core.netdev_max_backlog|未知" \
        "optmem_max|net.core.optmem_max|不可用" \
        "临时端口范围|net.ipv4.ip_local_port_range|未知" \
        "保留本地端口|net.ipv4.ip_local_reserved_ports|未配置"
    echo "  Conntrack 使用量: $(read_sysctl_or net.netfilter.nf_conntrack_count) / $(read_sysctl_or net.netfilter.nf_conntrack_max)"
    print_sysctl_rows "Conntrack buckets|net.netfilter.nf_conntrack_buckets|不可用"

    echo
    echo "缓冲区:"
    print_sysctl_rows \
        "rmem_default|net.core.rmem_default|未知" \
        "wmem_default|net.core.wmem_default|未知" \
        "rmem_max|net.core.rmem_max|未知" \
        "wmem_max|net.core.wmem_max|未知" \
        "tcp_rmem|net.ipv4.tcp_rmem|未知" \
        "tcp_wmem|net.ipv4.tcp_wmem|未知" \
        "tcp_mem（内核管理）|net.ipv4.tcp_mem|未知" \
        "tcp_moderate_rcvbuf|net.ipv4.tcp_moderate_rcvbuf|未知"

    echo
    echo "TCP 行为:"
    print_sysctl_rows \
        "fin_timeout|net.ipv4.tcp_fin_timeout|未知" \
        "slow_start_after_idle|net.ipv4.tcp_slow_start_after_idle|未知" \
        "mtu_probing|net.ipv4.tcp_mtu_probing|未知" \
        "keepalive_time|net.ipv4.tcp_keepalive_time|不可用" \
        "tcp_tw_reuse（只读）|net.ipv4.tcp_tw_reuse|不可用" \
        "ECN|net.ipv4.tcp_ecn|不可用"
    echo "  initcwnd ownership marker: $([[ -e "$ROUTE_OWNED_MARKER" ]] && echo 存在 || echo 不存在)"
    echo "  initcwnd 持久化钩子: $(initcwnd_hook_status)"
    echo "  默认路由窗口: $initcwnd_detail"
    [[ "$initcwnd_state_name" != "drift" ]] || echo "  initcwnd 状态: 漂移"

    echo
    echo "内核容量诊断（只读）:"
    print_sysctl_rows \
        "min_free_kbytes|vm.min_free_kbytes|不可用" \
        "file-max|fs.file-max|不可用" \
        "nr_open|fs.nr_open|不可用" \
        "netdev_budget|net.core.netdev_budget|不可用" \
        "netdev_budget_usecs|net.core.netdev_budget_usecs|不可用"
    echo "  file-nr: $(file_handle_status)"

    echo
    echo "网络健康:"
    echo "  健康快照字段: softnet_dropped time_squeeze rx_errors tx_errors rx_dropped tx_dropped tcp_retrans limited_sockets rx_packets tx_packets"
    echo "  健康快照累计值: $(network_health_snapshot "$(detect_default_iface || true)")"

    return 0
}

show_help() {
    cat <<'EOF'
用法：
  network-optimize.sh [install] [选项]  自动计算并应用网络优化
  network-optimize.sh plan [选项]       只计算并显示计划，不修改系统
  network-optimize.sh restore           恢复上一次运行前的配置
  network-optimize.sh restore initial   恢复首次运行前的可信配置
  network-optimize.sh status            查看当前网络优化状态
  network-optimize.sh verify [--yes]    确认后比较 1 流与 4 流 iperf3，只读系统状态
  network-optimize.sh help              显示帮助

install/plan 选项：
  --probe                 明确执行自动探测
  --bandwidth-mbps N      指定对称带宽，单位 Mbps
  --download-mbps N       指定下载带宽，单位 Mbps
  --upload-mbps N         指定上传带宽，单位 Mbps
  --rtt-ms N              指定 RTT，单位 ms
  --disable-ecn           禁用 ECN，兼容存在 ECN 黑洞的旧链路
  --enable-initcwnd       强制把默认路由 initcwnd/initrwnd 设置为 32
  --disable-initcwnd      强制保留内核默认初始拥塞窗口

verify 选项：
  --yes                   非交互环境显式确认产生测速流量

示例：
  network-optimize.sh                 # 交互选择测速或手填上下行带宽
  network-optimize.sh plan            # 交互选择测速或手填上下行带宽
  network-optimize.sh install --probe # 明确执行主动探测
  network-optimize.sh install --bandwidth-mbps 1000 --rtt-ms 180
  network-optimize.sh install --download-mbps 1000 --upload-mbps 500 --rtt-ms 180
  network-optimize.sh verify --yes

默认行为：
  - 交互终端只询问是否测速；拒绝后要求手填下载和上传带宽
  - 非交互终端必须使用 --probe，或显式提供对称带宽/完整上下行带宽
  - 手填带宽缺少 RTT 时按 150 ms 计算；显式 --rtt-ms 严格采用用户值
  - 主动探测不采集 RTT；未显式提供 --rtt-ms 时按 150 ms 计算 BDP
  - 只有 --probe 或交互确认后才主动探测并安装缺失依赖
  - 探测失败时，交互终端转为手填；非交互终端在写配置、sysctl 或路由前失败
  - 自动探测仅测量 IPv4 公网带宽，使用公共 iperf3 与 Cloudflare
  - TCP 调优仅覆盖 IPv4
  - 自动测速在单方向 40 GB 或合计 85 GB 时提前停止，硬上限仍为 45/90 GB
  - 流量按实际 IPv4 测速目标的路由接口分别计量并汇总，接口计数包含后台流量
  - 默认不持久管理 ECN；只在传入 --disable-ecn 时写入 tcp_ecn=0
  - initcwnd 默认 auto：已知上传 > 100 Mbps 设置 32，低于等于 100 Mbps或未知时保留内核默认
  - 仅凭本脚本 marker、受管 hook 或可信路由快照清理旧 initcwnd/initrwnd
  - 检测到 networkd-dispatcher 时持久化 IPv4 默认路由的 initcwnd/initrwnd；不扩展 IPv6
  - --enable-initcwnd/--disable-initcwnd 显式覆盖 auto，冲突参数会被拒绝
  - 根据 2 x BDP + 2 MiB 余量动态设置缓冲区上限，TCP 初始默认固定 2 MiB
  - RAM cap 为有效 RAM / 32，最低 8 MiB、最高 256 MiB，并识别有限 cgroup memory limit
  - 动态 socket 最大值保留 4 MiB 绝对下限；core socket 默认值和全局 tcp_mem 保留系统值
  - 只在本次运行计算和应用，不创建定时任务
  - verify 仅在交互确认或显式 --yes 后产生流量；install/status 不会调用 verify
  - verify 不修改 sysctl、路由或 qdisc，也不安装依赖或持久服务

实现来源：
  - 公共 iperf3、带宽探测、BDP/memory cap 与 initcwnd 策略移植或参考 tcpfit v0.5.6
  - 参数交互、事务备份/恢复和 verify 为本仓库下游实现
EOF
}

main() {
    local selection_rc=0

    if ! parse_arguments "$@"; then
        show_help
        exit 1
    fi

    select_tuning_mode || selection_rc=$?
    (( selection_rc == 0 )) || exit 1

    require_commands awk grep sort mktemp || exit 1

    case "$COMMAND" in
        install)
            require_root
            require_commands sysctl mv cp find modprobe ip flock getent install dirname getconf || exit 1
            take_lock
            install_optimization
            ;;
        plan)
            require_commands flock getent || exit 1
            take_lock
            resolve_tuning_values
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
        verify)
            run_verify_command
            ;;
        help)
            show_help
            ;;
    esac
}

trap 'error "网络优化脚本在第 $LINENO 行执行失败"' ERR

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
    trap 'cleanup_probe_processes' EXIT
    main "$@"
fi
