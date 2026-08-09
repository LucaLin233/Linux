#!/usr/bin/env bash
# 网络优化模块
# 功能：自动探测带宽、RTT 与内存，动态配置 BBR、fq、TCP 缓冲区及 IPv4 转发参数。
# 无参数运行等同于 install：自动探测一次、立即应用，不创建定时任务。
#
# 用法：
#   bash network-optimize.sh [install] [选项]  # 自动计算并应用
#   bash network-optimize.sh plan [选项]       # 只计算，不修改系统
#   bash network-optimize.sh restore           # 恢复上一次配置
#   bash network-optimize.sh status            # 查看当前状态
#
# install/plan 可选参数：
#   --auto                       自动探测（默认）
#   --static                     使用原有固定 32 MiB 缓冲区
#   --bandwidth-mbps N           手动指定对称带宽
#   --download-mbps N            手动指定下载带宽
#   --upload-mbps N              手动指定上传带宽
#   --rtt-ms N                   手动指定 RTT
#   --target HOST                自定义 RTT 目标，可重复指定
#   --no-probe                   不发起网络探测；缺失数据时按内存保守配置

set -euo pipefail

# === 常量定义 ===
readonly NETWORK_CONF="/etc/sysctl.d/99-network-optimize.conf"
readonly NETWORK_INITIAL_BACKUP="/etc/sysctl.d/99-network-optimize.conf.initial-backup"
readonly NETWORK_PREVIOUS_BACKUP="/etc/sysctl.d/99-network-optimize.conf.previous-backup"

# Cloudflare 官方网络质量测试接口。最大测试流量为上下行各 84 MiB。
readonly SPEED_DOWNLOAD_URL="https://speed.cloudflare.com/__down"
readonly SPEED_UPLOAD_URL="https://speed.cloudflare.com/__up"
readonly -a SPEED_TEST_MIB=(4 16 64)
readonly SPEED_STAGE_TIMEOUT=8
readonly SPEED_CONTINUE_SECONDS="1.5"

# 中国大陆目标参考 tcpfit，刻意排除可能在海外命中 Anycast 的 223.5.5.5。
readonly -a CHINA_PING_TARGETS=(
    119.29.29.29
    180.76.76.76
    202.96.128.86
    1.2.4.8
    101.226.4.6
)
readonly -a GLOBAL_PING_TARGETS=(1.1.1.1 8.8.8.8 9.9.9.9)
readonly -a CHINA_TCP_TARGETS=(www.baidu.com www.qq.com www.163.com)
readonly -a GLOBAL_TCP_TARGETS=(www.cloudflare.com www.google.com www.wikipedia.org)
readonly AUTO_RTT_MIN_MS=10
readonly AUTO_RTT_MAX_MS=300

# 参数与计算结果。命令行参数优先于自动探测。
COMMAND="install"
TUNING_MODE="auto"
NO_PROBE="false"
MANUAL_BANDWIDTH_MBPS=""
MANUAL_DOWNLOAD_MBPS=""
MANUAL_UPLOAD_MBPS=""
MANUAL_RTT_MS=""
declare -a CUSTOM_RTT_TARGETS=()

DETECTED_DOWNLOAD_MBPS=""
DETECTED_UPLOAD_MBPS=""
DETECTED_RTT_MS=""
RTT_SOURCE="unknown"
BANDWIDTH_SOURCE="unknown"
RAM_MB=0
MEMORY_CAP_BYTES=0
RX_BDP_BYTES=0
TX_BDP_BYTES=0
RMEM_MAX_BYTES=33554432
WMEM_MAX_BYTES=33554432
CALCULATION_REASON="static 32 MiB"

# 旧版 kernel2.sh 使用的配置文件。
readonly LEGACY_KERNEL_CONF="/etc/sysctl.d/99-kernel.conf"
readonly LEGACY_KERNEL_ARCHIVE="/etc/sysctl.d/99-kernel.conf.legacy"

# 旧版脚本可能迁移过的主 sysctl 文件。
readonly LEGACY_SYSCTL_CONF="/etc/sysctl.conf"
readonly LEGACY_SYSCTL_BACKUP="/etc/sysctl.conf.bak"

# 旧版脚本写入 limits.conf 的标记与备份。
readonly LIMITS_CONF="/etc/security/limits.conf"
readonly LIMITS_BACKUP="/etc/security/limits.conf.bak"
readonly LIMITS_LEGACY_ARCHIVE="/etc/security/limits.conf.network-optimize.before-restore"
readonly LEGACY_LIMITS_MARKER="# Network Optimizer - 系统资源限制"

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

# === 旧配置迁移 ===
migrate_legacy_kernel_config() {
    if [[ ! -f "$LEGACY_KERNEL_CONF" ]]; then
        return 0
    fi

    if [[ -e "$LEGACY_KERNEL_ARCHIVE" ]]; then
        warn "检测到旧配置 $LEGACY_KERNEL_CONF，但历史归档已存在，保留旧文件不自动覆盖"
        warn "请手动检查并处理：$LEGACY_KERNEL_CONF"
        return 0
    fi

    if mv "$LEGACY_KERNEL_CONF" "$LEGACY_KERNEL_ARCHIVE"; then
        info "旧网络配置已迁移为历史归档：$LEGACY_KERNEL_ARCHIVE"
        info "新版配置将使用：$NETWORK_CONF"
        return 0
    fi

    error "无法迁移旧网络配置：$LEGACY_KERNEL_CONF"
    return 1
}

migrate_legacy_sysctl_conf() {
    # 旧版脚本为了兼容 Debian 12 升级 Debian 13 的环境，
    # 会将存在的 /etc/sysctl.conf 迁移为 .bak。
    [[ -s "$LEGACY_SYSCTL_CONF" ]] || return 0

    if [[ -e "$LEGACY_SYSCTL_BACKUP" ]]; then
        warn "检测到 $LEGACY_SYSCTL_CONF，但 $LEGACY_SYSCTL_BACKUP 已存在，保留当前文件不自动迁移"
        return 0
    fi

    if mv "$LEGACY_SYSCTL_CONF" "$LEGACY_SYSCTL_BACKUP"; then
        info "已迁移旧主 sysctl 配置：$LEGACY_SYSCTL_CONF → $LEGACY_SYSCTL_BACKUP"
        return 0
    fi

    error "无法迁移旧主 sysctl 配置：$LEGACY_SYSCTL_CONF"
    return 1
}

restore_legacy_limits() {
    local restored=false
    local disabled_file
    local original_file

    # 仅当当前 limits.conf 明确包含旧脚本标记时才恢复，
    # 避免影响非本脚本管理的资源限制。
    if [[ -f "$LIMITS_CONF" ]] &&
        grep -Fq "$LEGACY_LIMITS_MARKER" "$LIMITS_CONF"; then
        if [[ -f "$LIMITS_BACKUP" ]]; then
            cp -a "$LIMITS_CONF" "$LIMITS_LEGACY_ARCHIVE"
            cp -a "$LIMITS_BACKUP" "$LIMITS_CONF"
            chmod 644 "$LIMITS_CONF" 2>/dev/null || true

            info "已恢复 limits.conf 到旧脚本运行前的备份状态"
            info "恢复前的旧优化配置已保存至：$LIMITS_LEGACY_ARCHIVE"
            restored=true
        else
            warn "检测到旧版 limits 配置，但未找到 $LIMITS_BACKUP，无法安全恢复"
        fi
    fi

    # 恢复旧脚本禁用的 nproc 配置文件。
    # 新版不再管理 nproc；恢复后交由系统默认规则处理。
    for disabled_file in /etc/security/limits.d/*.conf.disabled; do
        [[ -f "$disabled_file" ]] || continue

        original_file="${disabled_file%.disabled}"

        if [[ -e "$original_file" ]]; then
            warn "跳过恢复 $disabled_file：目标文件已存在"
            continue
        fi

        if mv "$disabled_file" "$original_file"; then
            info "已恢复资源限制文件：$original_file"
            restored=true
        else
            warn "恢复资源限制文件失败：$disabled_file"
        fi
    done

    if [[ "$restored" == "false" ]]; then
        info "未检测到需要恢复的旧版资源限制配置"
    fi
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
            --auto)
                TUNING_MODE="auto"
                shift
                ;;
            --static)
                TUNING_MODE="static"
                shift
                ;;
            --bandwidth-mbps|--download-mbps|--upload-mbps|--rtt-ms|--target)
                if (( $# < 2 )); then
                    error "参数 $1 缺少值"
                    return 1
                fi
                case "$1" in
                    --bandwidth-mbps) MANUAL_BANDWIDTH_MBPS="$2" ;;
                    --download-mbps) MANUAL_DOWNLOAD_MBPS="$2" ;;
                    --upload-mbps) MANUAL_UPLOAD_MBPS="$2" ;;
                    --rtt-ms) MANUAL_RTT_MS="$2" ;;
                    --target) CUSTOM_RTT_TARGETS+=("$2") ;;
                esac
                shift 2
                ;;
            --no-probe)
                NO_PROBE="true"
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

    local target
    for target in "${CUSTOM_RTT_TARGETS[@]}"; do
        if [[ ! "$target" =~ ^[A-Za-z0-9._-]+$ ]]; then
            error "无效 RTT 目标: $target"
            return 1
        fi
    done

    if [[ "$TUNING_MODE" == "static" ]] &&
        [[ -n "$MANUAL_BANDWIDTH_MBPS$MANUAL_DOWNLOAD_MBPS$MANUAL_UPLOAD_MBPS$MANUAL_RTT_MS" ||
            ${#CUSTOM_RTT_TARGETS[@]} -gt 0 ]]; then
        error "--static 不能与动态带宽、RTT 或目标参数同时使用"
        return 1
    fi
}

detect_memory_mb() {
    awk '/^MemTotal:/ {printf "%d", $2 / 1024}' /proc/meminfo
}

calculate_memory_cap() {
    local ram_mb="$1"

    if (( ram_mb <= 512 )); then
        echo $((8 * 1024 * 1024))
    elif (( ram_mb <= 1024 )); then
        echo $((16 * 1024 * 1024))
    elif (( ram_mb <= 2048 )); then
        echo $((32 * 1024 * 1024))
    else
        echo $((64 * 1024 * 1024))
    fi
}

median_values() {
    sort -n | awk '
        { values[NR] = $1 }
        END {
            if (NR == 0) exit 1
            if (NR % 2) print values[(NR + 1) / 2]
            else printf "%.0f\n", (values[NR / 2] + values[NR / 2 + 1]) / 2
        }
    '
}

cleanup_temp_dir() {
    local directory="$1"
    local file

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

measure_ping_group() {
    local temp_dir
    local target
    local index=0
    local value
    local values=()

    command -v ping >/dev/null 2>&1 || return 1
    temp_dir=$(mktemp -d) || return 1

    for target in "$@"; do
        ((index += 1))
        (measure_ping_target "$target" > "$temp_dir/$index" 2>/dev/null) &
    done
    wait || true

    for value in "$temp_dir"/*; do
        [[ -s "$value" ]] || continue
        values+=("$(cat "$value")")
    done
    cleanup_temp_dir "$temp_dir"

    (( ${#values[@]} > 0 )) || return 1
    printf '%s\n' "${values[@]}" | median_values
}

measure_tcp_target() {
    local target="$1"
    local result
    local lookup
    local connected
    local milliseconds
    local values=()

    for _ in 1 2 3; do
        result=$(curl -4 --noproxy '*' --head --silent --output /dev/null \
            --connect-timeout 3 --max-time 5 \
            --write-out '%{time_namelookup} %{time_connect}' \
            "https://$target/" 2>/dev/null) || continue
        read -r lookup connected <<< "$result"
        milliseconds=$(awk -v lookup="$lookup" -v connected="$connected" '
            BEGIN {
                value = (connected - lookup) * 1000
                if (value > 0 && value <= 5000) printf "%.0f", value
            }
        ')
        [[ -n "$milliseconds" ]] && values+=("$milliseconds")
    done

    (( ${#values[@]} > 0 )) || return 1
    printf '%s\n' "${values[@]}" | median_values
}

measure_tcp_group() {
    local temp_dir
    local target
    local index=0
    local value
    local values=()

    command -v curl >/dev/null 2>&1 || return 1
    temp_dir=$(mktemp -d) || return 1

    for target in "$@"; do
        ((index += 1))
        (measure_tcp_target "$target" > "$temp_dir/$index" 2>/dev/null) &
    done
    wait || true

    for value in "$temp_dir"/*; do
        [[ -s "$value" ]] || continue
        values+=("$(cat "$value")")
    done
    cleanup_temp_dir "$temp_dir"

    (( ${#values[@]} > 0 )) || return 1
    printf '%s\n' "${values[@]}" | median_values
}

clamp_auto_rtt() {
    local value="$1"
    (( value < AUTO_RTT_MIN_MS )) && value=$AUTO_RTT_MIN_MS
    (( value > AUTO_RTT_MAX_MS )) && value=$AUTO_RTT_MAX_MS
    echo "$value"
}

detect_rtt() {
    local china_rtt=""
    local global_rtt=""
    local custom_rtt=""

    if (( ${#CUSTOM_RTT_TARGETS[@]} > 0 )); then
        custom_rtt=$(measure_ping_group "${CUSTOM_RTT_TARGETS[@]}" || true)
        if [[ -n "$custom_rtt" ]]; then
            RTT_SOURCE="custom ICMP"
        else
            custom_rtt=$(measure_tcp_group "${CUSTOM_RTT_TARGETS[@]}" || true)
            [[ -n "$custom_rtt" ]] && RTT_SOURCE="custom TCP/443"
        fi
        [[ -n "$custom_rtt" ]] || return 1
        DETECTED_RTT_MS=$(clamp_auto_rtt "$custom_rtt")
        return 0
    fi

    china_rtt=$(measure_ping_group "${CHINA_PING_TARGETS[@]}" || true)
    if [[ -z "$china_rtt" ]]; then
        china_rtt=$(measure_tcp_group "${CHINA_TCP_TARGETS[@]}" || true)
    fi

    global_rtt=$(measure_ping_group "${GLOBAL_PING_TARGETS[@]}" || true)
    if [[ -z "$global_rtt" ]]; then
        global_rtt=$(measure_tcp_group "${GLOBAL_TCP_TARGETS[@]}" || true)
    fi

    if [[ -n "$china_rtt" && -n "$global_rtt" ]]; then
        if (( china_rtt >= global_rtt )); then
            DETECTED_RTT_MS="$china_rtt"
        else
            DETECTED_RTT_MS="$global_rtt"
        fi
        RTT_SOURCE="max(CN, global)"
    elif [[ -n "$china_rtt" ]]; then
        DETECTED_RTT_MS="$china_rtt"
        RTT_SOURCE="CN targets"
    elif [[ -n "$global_rtt" ]]; then
        DETECTED_RTT_MS="$global_rtt"
        RTT_SOURCE="global targets"
    else
        return 1
    fi

    DETECTED_RTT_MS=$(clamp_auto_rtt "$DETECTED_RTT_MS")
}

measure_download_stage() {
    local mib="$1"
    local bytes=$((mib * 1024 * 1024))
    local result

    result=$(curl -4 --noproxy '*' --silent --show-error --output /dev/null \
        --header 'Accept-Encoding: identity' \
        --connect-timeout 4 --max-time "$SPEED_STAGE_TIMEOUT" \
        --write-out '%{size_download} %{time_total} %{speed_download}' \
        "$SPEED_DOWNLOAD_URL?bytes=$bytes" 2>/dev/null) || return 1

    awk -v expected="$bytes" '
        {
            if ($1 < expected * 0.9 || $2 <= 0 || $3 <= 0) exit 1
            printf "%.0f %.3f\n", $3 * 8 / 1000000, $2
        }
    ' <<< "$result"
}

measure_upload_stage() {
    local mib="$1"
    local result

    result=$(dd if=/dev/zero bs=1048576 count="$mib" status=none 2>/dev/null |
        curl -4 --noproxy '*' --silent --show-error --output /dev/null \
            --header 'Content-Type: application/octet-stream' \
            --header 'Expect:' \
            --connect-timeout 4 --max-time "$SPEED_STAGE_TIMEOUT" \
            --data-binary @- \
            --write-out '%{size_upload} %{time_total} %{speed_upload}' \
            "$SPEED_UPLOAD_URL" 2>/dev/null) || return 1

    awk -v expected="$((mib * 1024 * 1024))" '
        {
            if ($1 < expected * 0.9 || $2 <= 0 || $3 <= 0) exit 1
            printf "%.0f %.3f\n", $3 * 8 / 1000000, $2
        }
    ' <<< "$result"
}

should_continue_speed_test() {
    local duration="$1"
    awk -v duration="$duration" -v threshold="$SPEED_CONTINUE_SECONDS" \
        'BEGIN {exit !(duration < threshold)}'
}

probe_download_bandwidth() {
    local mib
    local result
    local bandwidth=""
    local duration=""

    for mib in "${SPEED_TEST_MIB[@]}"; do
        result=$(measure_download_stage "$mib" || true)
        [[ -n "$result" ]] || break
        read -r bandwidth duration <<< "$result"
        should_continue_speed_test "$duration" || break
    done

    [[ -n "$bandwidth" ]] || return 1
    echo "$bandwidth"
}

probe_upload_bandwidth() {
    local mib
    local result
    local bandwidth=""
    local duration=""

    for mib in "${SPEED_TEST_MIB[@]}"; do
        result=$(measure_upload_stage "$mib" || true)
        [[ -n "$result" ]] || break
        read -r bandwidth duration <<< "$result"
        should_continue_speed_test "$duration" || break
    done

    [[ -n "$bandwidth" ]] || return 1
    echo "$bandwidth"
}

conservative_bandwidth_tier() {
    local measured="$1"
    local adjusted
    local selected=1
    local tier
    local -a tiers=(10 25 50 100 200 300 500 750 1000 1500 2500 5000 10000)

    adjusted=$((measured * 80 / 100))
    (( adjusted < 1 )) && adjusted=1

    for tier in "${tiers[@]}"; do
        (( tier <= adjusted )) || break
        selected="$tier"
    done
    echo "$selected"
}

probe_bandwidth() {
    local raw_download=""
    local raw_upload=""

    command -v curl >/dev/null 2>&1 || return 1

    info "自动估算公网带宽（Cloudflare，上下行总流量最多约 168 MiB）..."
    raw_download=$(probe_download_bandwidth || true)
    raw_upload=$(probe_upload_bandwidth || true)

    [[ -n "$raw_download$raw_upload" ]] || return 1

    if [[ -n "$raw_download" ]]; then
        DETECTED_DOWNLOAD_MBPS=$(conservative_bandwidth_tier "$raw_download")
    fi
    if [[ -n "$raw_upload" ]]; then
        DETECTED_UPLOAD_MBPS=$(conservative_bandwidth_tier "$raw_upload")
    fi

    if [[ -z "$DETECTED_UPLOAD_MBPS" && -n "$DETECTED_DOWNLOAD_MBPS" ]]; then
        DETECTED_UPLOAD_MBPS="$DETECTED_DOWNLOAD_MBPS"
        (( DETECTED_UPLOAD_MBPS > 1000 )) && DETECTED_UPLOAD_MBPS=1000
    elif [[ -z "$DETECTED_DOWNLOAD_MBPS" && -n "$DETECTED_UPLOAD_MBPS" ]]; then
        DETECTED_DOWNLOAD_MBPS="$DETECTED_UPLOAD_MBPS"
    fi

    BANDWIDTH_SOURCE="Cloudflare 80% tier"
}

calculate_buffer_max() {
    local bandwidth_mbps="$1"
    local rtt_ms="$2"
    local memory_cap="$3"
    local minimum=$((8 * 1024 * 1024))
    local mib=$((1024 * 1024))
    local desired

    # 2 × BDP = Mbps × RTT(ms) × 250 bytes。
    desired=$((bandwidth_mbps * rtt_ms * 250))
    desired=$((((desired + mib - 1) / mib) * mib))
    (( desired < minimum )) && desired=$minimum
    (( desired > memory_cap )) && desired=$memory_cap
    echo "$desired"
}

needs_automatic_probe() {
    [[ "$TUNING_MODE" == "auto" && "$NO_PROBE" != "true" ]] || return 1
    [[ -z "$MANUAL_RTT_MS" ||
        ( -z "$MANUAL_BANDWIDTH_MBPS" &&
          ( -z "$MANUAL_DOWNLOAD_MBPS" || -z "$MANUAL_UPLOAD_MBPS" ) ) ]]
}

install_probe_dependencies() {
    local packages=()

    command -v curl >/dev/null 2>&1 || packages+=(curl)
    command -v ping >/dev/null 2>&1 || packages+=(iputils-ping)
    [[ -s /etc/ssl/certs/ca-certificates.crt ]] || packages+=(ca-certificates)
    (( ${#packages[@]} > 0 )) || return 0

    if ! command -v apt-get >/dev/null 2>&1; then
        warn "缺少探测工具且未找到 apt-get，将使用可用方法或内存保守配置"
        return 1
    fi

    info "安装网络探测依赖：${packages[*]}"
    if ! DEBIAN_FRONTEND=noninteractive apt-get update -qq; then
        warn "apt 索引更新失败，将继续尝试安装依赖"
    fi
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        "${packages[@]}"; then
        warn "网络探测依赖安装失败，将使用可用方法或内存保守配置"
        return 1
    fi
}

resolve_tuning_values() {
    local download_mbps=""
    local upload_mbps=""
    local rtt_ms=""

    RAM_MB=$(detect_memory_mb)
    is_positive_integer "$RAM_MB" 1 1073741824 || {
        error "无法读取系统内存"
        return 1
    }
    MEMORY_CAP_BYTES=$(calculate_memory_cap "$RAM_MB")

    if [[ "$TUNING_MODE" == "static" ]]; then
        RMEM_MAX_BYTES=33554432
        WMEM_MAX_BYTES=33554432
        CALCULATION_REASON="static 32 MiB"
        BANDWIDTH_SOURCE="not used"
        RTT_SOURCE="not used"
        return 0
    fi

    download_mbps="$MANUAL_DOWNLOAD_MBPS"
    upload_mbps="$MANUAL_UPLOAD_MBPS"
    if [[ -n "$MANUAL_BANDWIDTH_MBPS" ]]; then
        [[ -n "$download_mbps" ]] || download_mbps="$MANUAL_BANDWIDTH_MBPS"
        [[ -n "$upload_mbps" ]] || upload_mbps="$MANUAL_BANDWIDTH_MBPS"
    fi

    if [[ -n "$MANUAL_RTT_MS" ]]; then
        rtt_ms="$MANUAL_RTT_MS"
        RTT_SOURCE="command line"
    elif [[ "$NO_PROBE" != "true" ]]; then
        info "自动探测中国大陆与全球 RTT..."
        if detect_rtt; then
            rtt_ms="$DETECTED_RTT_MS"
        else
            warn "RTT 探测失败，将使用内存保守配置"
        fi
    fi

    if [[ -z "$download_mbps" || -z "$upload_mbps" ]]; then
        if [[ "$NO_PROBE" != "true" ]] && probe_bandwidth; then
            [[ -n "$download_mbps" ]] || download_mbps="$DETECTED_DOWNLOAD_MBPS"
            [[ -n "$upload_mbps" ]] || upload_mbps="$DETECTED_UPLOAD_MBPS"
        elif [[ "$NO_PROBE" != "true" ]]; then
            warn "带宽探测失败，将使用内存保守配置"
        fi
    fi

    if [[ -n "$download_mbps" && -z "$upload_mbps" ]]; then
        upload_mbps="$download_mbps"
        (( upload_mbps > 1000 )) && upload_mbps=1000
    elif [[ -n "$upload_mbps" && -z "$download_mbps" ]]; then
        download_mbps="$upload_mbps"
    fi

    if [[ -n "$MANUAL_BANDWIDTH_MBPS$MANUAL_DOWNLOAD_MBPS$MANUAL_UPLOAD_MBPS" ]]; then
        BANDWIDTH_SOURCE="command line / auto fill"
    fi

    DETECTED_DOWNLOAD_MBPS="$download_mbps"
    DETECTED_UPLOAD_MBPS="$upload_mbps"
    DETECTED_RTT_MS="$rtt_ms"

    if [[ -n "$download_mbps" && -n "$upload_mbps" && -n "$rtt_ms" ]]; then
        RX_BDP_BYTES=$((download_mbps * rtt_ms * 125))
        TX_BDP_BYTES=$((upload_mbps * rtt_ms * 125))
        RMEM_MAX_BYTES=$(calculate_buffer_max "$download_mbps" "$rtt_ms" "$MEMORY_CAP_BYTES")
        WMEM_MAX_BYTES=$(calculate_buffer_max "$upload_mbps" "$rtt_ms" "$MEMORY_CAP_BYTES")
        CALCULATION_REASON="2 x BDP, capped by RAM"
    else
        RMEM_MAX_BYTES="$MEMORY_CAP_BYTES"
        WMEM_MAX_BYTES="$MEMORY_CAP_BYTES"
        CALCULATION_REASON="probe incomplete, RAM fallback"
    fi
}

show_tuning_plan() {
    echo "========== 网络动态配置计划 =========="
    echo "模式: $TUNING_MODE"
    echo "内存: ${RAM_MB} MiB"
    echo "内存缓冲区上限: $((MEMORY_CAP_BYTES / 1024 / 1024)) MiB"
    echo "下载带宽: ${DETECTED_DOWNLOAD_MBPS:-未知} Mbps"
    echo "上传带宽: ${DETECTED_UPLOAD_MBPS:-未知} Mbps"
    echo "带宽来源: $BANDWIDTH_SOURCE"
    echo "RTT: ${DETECTED_RTT_MS:-未知} ms"
    echo "RTT 来源: $RTT_SOURCE"
    echo "接收 BDP: $((RX_BDP_BYTES / 1024)) KiB"
    echo "发送 BDP: $((TX_BDP_BYTES / 1024)) KiB"
    echo "rmem_max: $((RMEM_MAX_BYTES / 1024 / 1024)) MiB"
    echo "wmem_max: $((WMEM_MAX_BYTES / 1024 / 1024)) MiB"
    echo "计算依据: $CALCULATION_REASON"
}

# === 新版网络配置 ===
create_network_config() {
    local target_file="$1"
    local enable_bbr="$2"

    cat > "$target_file" <<EOF
# 由 network-optimize.sh 自动生成。
# 模式: $TUNING_MODE
# 内存: ${RAM_MB} MiB
# 下载带宽: ${DETECTED_DOWNLOAD_MBPS:-unknown} Mbps
# 上传带宽: ${DETECTED_UPLOAD_MBPS:-unknown} Mbps
# 带宽来源: $BANDWIDTH_SOURCE
# RTT: ${DETECTED_RTT_MS:-unknown} ms
# RTT 来源: $RTT_SOURCE
# 缓冲区依据: $CALCULATION_REASON
# 适用于 Debian 13 代理、转发及中高延迟公网 VPS。

# 1. IPv4 转发
net.ipv4.ip_forward = 1

# 2. 代理与非对称路由兼容
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2

# 3. 队列调度
net.core.default_qdisc = fq

# 4. TCP Fast Open
net.ipv4.tcp_fastopen = 3

# 5. 连接与接收队列
net.core.somaxconn = 32768
net.ipv4.tcp_max_syn_backlog = 8192
net.core.netdev_max_backlog = 16384

# 6. 临时端口
net.ipv4.ip_local_port_range = 1024 65535

# 7. TCP/UDP 缓冲区
net.core.rmem_max = $RMEM_MAX_BYTES
net.core.wmem_max = $WMEM_MAX_BYTES
net.ipv4.tcp_rmem = 4096 131072 $RMEM_MAX_BYTES
net.ipv4.tcp_wmem = 4096 65536 $WMEM_MAX_BYTES

# 8. 长连接与复杂路径
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
EOF

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

backup_network_config() {
    [[ -f "$NETWORK_CONF" ]] || return 0

    if [[ ! -f "$NETWORK_INITIAL_BACKUP" ]]; then
        cp -a "$NETWORK_CONF" "$NETWORK_INITIAL_BACKUP" || return 1
    fi

    cp -a "$NETWORK_CONF" "$NETWORK_PREVIOUS_BACKUP"
}

capture_runtime_values() {
    local config_file="$1"
    local output_file="$2"
    local key

    : > "$output_file"
    while IFS='=' read -r key _; do
        key="${key//[[:space:]]/}"
        [[ -z "$key" || "$key" == \#* ]] && continue
        if sysctl -n "$key" >/dev/null 2>&1; then
            printf '%s=%s\n' "$key" "$(sysctl -n "$key")" >> "$output_file"
        else
            error "当前内核不存在 sysctl 参数: $key"
            return 1
        fi
    done < "$config_file"
}

restore_runtime_values() {
    local values_file="$1"
    local key
    local value

    while IFS='=' read -r key value; do
        [[ -n "$key" ]] || continue
        sysctl -w "$key=$value" >/dev/null 2>&1 ||
            warn "运行时参数恢复失败: $key"
    done < "$values_file"
}

apply_network_config() {
    local config_file="$1"
    sysctl -p "$config_file"
}

install_optimization() {
    local temp_config
    local runtime_backup
    local bbr_enabled="false"

    info "开始配置网络优化..."

    if detect_container; then
        warn "检测到容器虚拟化环境，部分 sysctl 参数可能受宿主机限制"
    fi

    if needs_automatic_probe; then
        install_probe_dependencies || true
    fi

    resolve_tuning_values || return 1
    show_tuning_plan

    migrate_legacy_kernel_config || return 1
    migrate_legacy_sysctl_conf || return 1
    restore_legacy_limits

    if ensure_bbr_available; then
        bbr_enabled="true"
        info "BBR 支持：可用"
    fi

    if ! temp_config=$(mktemp /etc/sysctl.d/99-network-optimize.conf.new.XXXXXX); then
        error "无法创建网络配置临时文件"
        return 1
    fi

    create_network_config "$temp_config" "$bbr_enabled"

    runtime_backup=$(mktemp) || {
        rm -f "$temp_config"
        return 1
    }

    if ! capture_runtime_values "$temp_config" "$runtime_backup"; then
        rm -f "$temp_config" "$runtime_backup"
        return 1
    fi

    backup_network_config || {
        rm -f "$temp_config" "$runtime_backup"
        return 1
    }

    # 应用前已保存全部涉及参数的运行值，失败时逐项回滚。
    if ! apply_network_config "$temp_config"; then
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

    rm -f "$runtime_backup"
    success "网络优化配置已写入：$NETWORK_CONF"

    if [[ "$bbr_enabled" != "true" ]]; then
        warn "BBR 未启用；其余网络与转发参数已正常应用"
    fi

    echo
    echo "说明："
    echo "  - 无参数安装会自动探测一次并应用，不创建定时任务。"
    echo "  - IPv4 转发已启用，兼容 NAT、透明代理、网关与端口转发场景。"
    echo "  - 未启用 IPv6 转发、route_localnet 或 MPTCP。"
    echo "  - 新版不再管理 limits.conf、nproc 与 memlock。"
    echo "  - 已恢复旧脚本修改过的资源限制配置（若检测到对应备份）。"
    echo "  - 已移除的旧 sysctl 参数在重启前可能仍保留运行时值；重启后将完全按新版配置生效。"
}

restore_optimization() {
    info "开始恢复新版网络优化配置..."

    if [[ -f "$NETWORK_PREVIOUS_BACKUP" ]]; then
        cp -a "$NETWORK_PREVIOUS_BACKUP" "$NETWORK_CONF"

        if apply_network_config "$NETWORK_CONF"; then
            success "已恢复网络上一次配置：$NETWORK_PREVIOUS_BACKUP"
        else
            error "恢复网络配置后应用失败"
            return 1
        fi
    else
        rm -f "$NETWORK_CONF"
        warn "未找到新版网络配置备份，已删除 $NETWORK_CONF"
        warn "请重启系统，以清除已移除参数的运行时值"
    fi

    echo
    echo "注意："
    echo "  restore 仅恢复新版脚本管理的 $NETWORK_CONF。"
    echo "  不会自动修改旧版历史归档、limits.conf 或 nproc 配置。"
    echo "  建议重启系统，使所有未持久化的旧参数彻底恢复默认状态。"
}

show_status() {
    local available_cc
    local current_cc
    local current_qdisc
    local current_tfo
    local ip_forward
    local rp_filter_all
    local rp_filter_default
    local somaxconn
    local syn_backlog
    local backlog
    local port_range
    local rmem_max
    local wmem_max
    local tcp_rmem
    local tcp_wmem
    local slow_start_after_idle
    local mtu_probing

    available_cc=$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || echo "未知")
    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
    current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "未知")
    current_tfo=$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo "未知")
    ip_forward=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo "未知")
    rp_filter_all=$(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null || echo "未知")
    rp_filter_default=$(sysctl -n net.ipv4.conf.default.rp_filter 2>/dev/null || echo "未知")
    somaxconn=$(sysctl -n net.core.somaxconn 2>/dev/null || echo "未知")
    syn_backlog=$(sysctl -n net.ipv4.tcp_max_syn_backlog 2>/dev/null || echo "未知")
    backlog=$(sysctl -n net.core.netdev_max_backlog 2>/dev/null || echo "未知")
    port_range=$(sysctl -n net.ipv4.ip_local_port_range 2>/dev/null || echo "未知")
    rmem_max=$(sysctl -n net.core.rmem_max 2>/dev/null || echo "未知")
    wmem_max=$(sysctl -n net.core.wmem_max 2>/dev/null || echo "未知")
    tcp_rmem=$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null || echo "未知")
    tcp_wmem=$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null || echo "未知")
    slow_start_after_idle=$(sysctl -n net.ipv4.tcp_slow_start_after_idle 2>/dev/null || echo "未知")
    mtu_probing=$(sysctl -n net.ipv4.tcp_mtu_probing 2>/dev/null || echo "未知")

    echo "========== 网络优化状态 =========="
    echo "配置文件: $NETWORK_CONF"
    [[ -f "$NETWORK_CONF" ]] && echo "配置状态: 已存在" || echo "配置状态: 未创建"
    if [[ -f "$NETWORK_CONF" ]]; then
        grep -E '^# (模式|内存|下载带宽|上传带宽|带宽来源|RTT|RTT 来源|缓冲区依据):'             "$NETWORK_CONF" | sed 's/^# /  /'
    fi
    [[ -f "$NETWORK_INITIAL_BACKUP" ]] && echo "初始备份: $NETWORK_INITIAL_BACKUP"
    [[ -f "$NETWORK_PREVIOUS_BACKUP" ]] && echo "上次备份: $NETWORK_PREVIOUS_BACKUP"

    echo
    echo "拥塞控制:"
    echo "  可用算法: $available_cc"
    echo "  当前算法: $current_cc"
    echo "  默认队列: $current_qdisc"
    echo "  TCP Fast Open: $current_tfo"

    echo
    echo "转发与兼容性:"
    echo "  IPv4 转发: $ip_forward"
    echo "  rp_filter(all): $rp_filter_all"
    echo "  rp_filter(default): $rp_filter_default"
    echo "  IPv6 转发: 未由本模块配置"
    echo "  route_localnet: 未由本模块配置"
    echo "  MPTCP: 未由本模块配置"

    echo
    echo "连接容量:"
    echo "  somaxconn: $somaxconn"
    echo "  tcp_max_syn_backlog: $syn_backlog"
    echo "  netdev_max_backlog: $backlog"
    echo "  临时端口范围: $port_range"

    echo
    echo "缓冲区:"
    echo "  rmem_max: $rmem_max"
    echo "  wmem_max: $wmem_max"
    echo "  tcp_rmem: $tcp_rmem"
    echo "  tcp_wmem: $tcp_wmem"

    echo
    echo "TCP 行为:"
    echo "  slow_start_after_idle: $slow_start_after_idle"
    echo "  mtu_probing: $mtu_probing"

    echo
    echo "兼容迁移:"
    [[ -f "$LEGACY_KERNEL_ARCHIVE" ]] &&
        echo "  旧 kernel 配置归档: $LEGACY_KERNEL_ARCHIVE"

    [[ -f "$LEGACY_SYSCTL_BACKUP" ]] &&
        echo "  旧 sysctl.conf 备份: $LEGACY_SYSCTL_BACKUP"

    [[ -f "$LIMITS_LEGACY_ARCHIVE" ]] &&
        echo "  旧 limits 优化配置归档: $LIMITS_LEGACY_ARCHIVE"
}

show_help() {
    cat <<'EOF'
用法：
  network-optimize.sh [install] [选项]  自动计算并应用网络优化
  network-optimize.sh plan [选项]       只计算并显示计划，不修改系统
  network-optimize.sh restore           恢复新版脚本修改前的配置
  network-optimize.sh status            查看当前网络优化状态
  network-optimize.sh help              显示帮助

install/plan 选项：
  --auto                  自动探测（默认）
  --static                使用原有固定 32 MiB 缓冲区
  --bandwidth-mbps N      指定对称带宽，单位 Mbps
  --download-mbps N       指定下载带宽，单位 Mbps
  --upload-mbps N         指定上传带宽，单位 Mbps
  --rtt-ms N              指定 RTT，单位 ms
  --target HOST           自定义 RTT 目标，可重复指定
  --no-probe              禁止外部探测，缺失数据时按内存保守配置

示例：
  network-optimize.sh
  network-optimize.sh plan
  network-optimize.sh install --bandwidth-mbps 1000 --rtt-ms 180
  network-optimize.sh install --download-mbps 1000 --upload-mbps 500 --rtt-ms 180
  network-optimize.sh plan --target example.com --target 203.0.113.10
  network-optimize.sh install --static

默认行为：
  - 自动安装缺少的最小探测依赖
  - 自动测量中国大陆与全球 RTT，自动结果限制在 10–300 ms
  - 使用 Cloudflare 官方端点估算上下行带宽，总流量最多约 168 MiB
  - 根据 2 × BDP 与系统内存动态设置 TCP 缓冲区上限
  - 探测失败时按内存使用保守配置
  - 只在本次运行计算和应用，不创建定时任务
EOF
}

main() {
    local required_command

    if ! parse_arguments "$@"; then
        show_help
        exit 1
    fi

    for required_command in awk grep sort mktemp; do
        if ! command -v "$required_command" >/dev/null 2>&1; then
            error "缺少必要命令: $required_command"
            exit 1
        fi
    done

    case "$COMMAND" in
        install)
            require_root
            for required_command in sysctl mv cp find modprobe ip; do
                if ! command -v "$required_command" >/dev/null 2>&1; then
                    error "缺少必要命令: $required_command"
                    exit 1
                fi
            done
            install_optimization
            ;;
        plan)
            resolve_tuning_values
            show_tuning_plan
            ;;
        restore)
            require_root
            command -v sysctl >/dev/null 2>&1 || {
                error "缺少必要命令: sysctl"
                exit 1
            }
            restore_optimization
            ;;
        status)
            show_status
            ;;
        help)
            show_help
            ;;
    esac
}

trap 'error "网络优化脚本在第 $LINENO 行执行失败"' ERR

main "$@"
