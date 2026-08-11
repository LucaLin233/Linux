#!/usr/bin/env bash
# tcshape-managed
# 出口限速器拐点扫描与 HTB + fq 流量整形工具
#
# Sweep/shape portions adapted from Kylin010/tcpfit.
# Upstream version: v0.5.4
# Upstream commit: 65885816bb77be38d041218f1bf62fe4ebe5c300
# Licensed under the MIT License. See THIRD_PARTY_NOTICES.md.

set -uo pipefail
umask 022

readonly VERSION="1.0.3"
readonly INSTALL_PATH="/usr/local/sbin/tcshape"
readonly STATE_DIR="/var/lib/tcshape"
readonly CONFIG_FILE="/etc/tcshape.conf"
readonly SERVICE_FILE="/etc/systemd/system/tcshape.service"
readonly LOCK_FILE="/run/lock/tcshape.lock"
readonly PID_FILE="/run/tcshape-$$.iperf.pid"

# 与 modules/network-optimize.sh 保持一致。
readonly TRAFFIC_TOTAL_LIMIT_BYTES=90000000000
readonly TRAFFIC_DIRECTION_LIMIT_BYTES=45000000000

readonly PORT_POOL="5201 5202 5203 5204 5205 5206 5207 5208 5209 5210 5200"
readonly PROBE_PORTS="5201 5202 5203 5200"
readonly LOSS_THRESHOLD="0.1"
readonly SCAN_CAP_MBIT=100000

IP_FAMILY="-4"
PEER_PORT="5201"
TRAFFIC_IFACE=""
TRAFFIC_RX_START=0
TRAFFIC_TX_START=0
QSAVE_IFACE=""
QSAVE_KIND=""
QSAVE_OWNED=false
SWEEP_ACTIVE=false

readonly PEER_POOL='speedtest.hkg12.hk.leaseweb.net|香港|Leaseweb
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

if [[ -t 1 ]]; then
    readonly C_RED=$'\033[0;31m'
    readonly C_GREEN=$'\033[0;32m'
    readonly C_YELLOW=$'\033[0;33m'
    readonly C_CYAN=$'\033[0;36m'
    readonly C_NC=$'\033[0m'
else
    readonly C_RED="" C_GREEN="" C_YELLOW="" C_CYAN="" C_NC=""
fi

info() { printf '%s[*]%s %s\n' "$C_CYAN" "$C_NC" "$*"; }
ok() { printf '%s[+]%s %s\n' "$C_GREEN" "$C_NC" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YELLOW" "$C_NC" "$*" >&2; }
error() { printf '%s[x]%s %s\n' "$C_RED" "$C_NC" "$*" >&2; }

usage() {
    cat <<'EOF'
tcshape - 出口限速器扫描与流量整形

短命令：
  tcshape s             自动选节点并扫描
  tcshape a             应用最近推荐值
  tcshape on 480        设置 480 Mbit 整形
  tcshape off           移除本工具整形
  tcshape st            查看状态

完整命令：
  tcshape scan [HOST] [--port N] [--nominal N] [--from N --to N]
                       [--step N] [--dur N] [--margin N] [--yes] [-4|-6]
  tcshape apply
  tcshape set RATE
  tcshape status
  tcshape off
EOF
}

require_root() {
    if (( EUID != 0 )); then
        error "需要 root 权限"
        exit 1
    fi
}

is_positive_integer() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= $2 && 10#$1 <= $3 ))
}

take_lock() {
    mkdir -p "$(dirname "$LOCK_FILE")"
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        error "另一个 tcshape 实例正在运行"
        exit 1
    fi
}

install_self() {
    [[ "$0" == "$INSTALL_PATH" ]] && return 0

    if [[ -e "$INSTALL_PATH" ]] &&
        ! grep -Fq '# tcshape-managed' "$INSTALL_PATH" 2>/dev/null; then
        error "$INSTALL_PATH 已存在且不属于本工具，拒绝覆盖"
        return 1
    fi

    if [[ -f "$INSTALL_PATH" ]] && cmp -s "$0" "$INSTALL_PATH"; then
        return 0
    fi

    local temp_file
    install -d -m 0755 /usr/local/sbin || return 1
    temp_file=$(mktemp /usr/local/sbin/.tcshape.XXXXXX) || return 1
    if ! install -m 0755 "$0" "$temp_file" || ! mv -f "$temp_file" "$INSTALL_PATH"; then
        rm -f "$temp_file"
        error "无法安装短命令：$INSTALL_PATH"
        return 1
    fi

    ok "已安装短命令：tcshape"
}

ensure_dependencies() {
    if [[ ! -f /etc/debian_version ]] || ! command -v apt-get >/dev/null 2>&1; then
        error "依赖自动安装仅支持 Debian"
        return 1
    fi

    local dependency
    local command_name
    local package_name
    local missing=()
    local required=(
        "tc:iproute2"
        "ip:iproute2"
        "iperf3:iperf3"
        "jq:jq"
        "ping:iputils-ping"
        "flock:util-linux"
        "timeout:coreutils"
        "pkill:procps"
    )

    for dependency in "${required[@]}"; do
        command_name="${dependency%%:*}"
        package_name="${dependency#*:}"
        command -v "$command_name" >/dev/null 2>&1 || missing+=("$package_name")
    done

    if (( ${#missing[@]} == 0 )); then
        return 0
    fi

    mapfile -t missing < <(printf '%s\n' "${missing[@]}" | sort -u)
    info "安装缺失依赖：${missing[*]}"

    if ! apt-get update -qq; then
        error "APT 软件包索引更新失败"
        return 1
    fi

    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"; then
        error "依赖安装失败"
        return 1
    fi
}

detect_iface() {
    local iface
    local route_target="1.1.1.1"
    [[ "$IP_FAMILY" == "-6" ]] && route_target="2606:4700:4700::1111"
    iface=$(ip ${IP_FAMILY} route get "$route_target" 2>/dev/null |
        awk '{for (i=1; i<NF; i++) if ($i=="dev") {print $(i+1); exit}}')

    if [[ -z "$iface" ]]; then
        iface=$(ip ${IP_FAMILY} route show default 2>/dev/null |
            awk '{for (i=1; i<NF; i++) if ($i=="dev") {print $(i+1); exit}}')
    fi

    [[ -n "$iface" && -d "/sys/class/net/$iface" ]] || return 1
    printf '%s\n' "$iface"
}

root_qdisc_kind() {
    tc qdisc show dev "$1" 2>/dev/null |
        awk '$1 == "qdisc" && $4 == "root" {print $2; found=1; exit} NR == 1 {fallback=$2} END {if (!found && fallback) print fallback}' |
        head -n 1
}

read_config_value() {
    local key="$1"
    local file="${2:-$CONFIG_FILE}"
    [[ -f "$file" ]] || return 1
    awk -F= -v key="$key" '$1 == key {print substr($0, index($0, "=") + 1); exit}' "$file"
}

is_own_shaper() {
    local iface="$1"
    local configured_iface
    [[ -f "$CONFIG_FILE" && -f "$SERVICE_FILE" ]] || return 1
    grep -Fq 'tcshape-managed' "$SERVICE_FILE" 2>/dev/null || return 1
    configured_iface=$(read_config_value INTERFACE || true)
    [[ "$configured_iface" == "$iface" ]] || return 1
    tc qdisc show dev "$iface" 2>/dev/null |
        awk '$1 == "qdisc" && $2 == "htb" && $3 == "1:" && $4 == "root" {found=1} END {exit !found}' || return 1
    tc class show dev "$iface" 2>/dev/null |
        grep -Eq '^class htb 1:10([[:space:]]|$)'
}

check_external_conflicts() {
    local iface="$1"
    local kind

    if systemctl is-active --quiet tcpfit-qdisc.service 2>/dev/null ||
        systemctl is-enabled --quiet tcpfit-qdisc.service 2>/dev/null; then
        error "检测到 tcpfit-qdisc.service，拒绝与其他整形工具同时管理 qdisc"
        return 1
    fi

    kind=$(root_qdisc_kind "$iface")
    if [[ "$kind" == "htb" ]] && ! is_own_shaper "$iface"; then
        error "检测到非本工具管理的 HTB，拒绝覆盖"
        return 1
    fi

    case "$kind" in
        ""|noqueue|mq|pfifo_fast|fq|fq_codel|htb)
            ;;
        *)
            error "当前根 qdisc 为 $kind，拒绝覆盖高级或未知配置"
            return 1
            ;;
    esac

    if ! is_own_shaper "$iface"; then
        local class_output
        local root_filter_output
        local unsafe_child_qdisc

        class_output=$(tc class show dev "$iface" 2>/dev/null || true)
        root_filter_output=$(tc filter show dev "$iface" parent root 2>/dev/null || true)

        # mq 会为每个硬件发送队列生成固有的 class mq；它不是用户自定义规则。
        # clsact/ingress filter 不属于根 qdisc，替换 root 时会原样保留。
        if [[ "$kind" == "mq" ]]; then
            if printf '%s\n' "$class_output" |
                awk 'NF && !($1 == "class" && $2 == "mq") {found=1} END {exit !found}'; then
                error "当前 mq 根队列下存在非 mq class，拒绝覆盖"
                return 1
            fi

            unsafe_child_qdisc=$(tc qdisc show dev "$iface" 2>/dev/null |
                awk '$1 == "qdisc" && $4 == "parent" && $2 !~ /^(fq|fq_codel|pfifo_fast|noqueue|clsact|ingress)$/ {print $2; exit}')
            if [[ -n "$unsafe_child_qdisc" ]]; then
                error "当前 mq 使用自定义子 qdisc：$unsafe_child_qdisc，拒绝覆盖"
                return 1
            fi
        elif [[ -n "$class_output" ]]; then
            error "当前根 qdisc 存在自定义 class，拒绝覆盖"
            return 1
        fi

        if [[ -n "$root_filter_output" ]]; then
            error "当前根 qdisc 存在自定义 filter，拒绝覆盖"
            return 1
        fi

        if [[ "$kind" == "mq" ]]; then
            local parent_id
            local child_filter_output
            while IFS= read -r parent_id; do
                [[ -n "$parent_id" ]] || continue
                child_filter_output=$(tc filter show dev "$iface" parent "$parent_id" 2>/dev/null || true)
                if [[ -n "$child_filter_output" ]]; then
                    error "当前 mq 子队列 $parent_id 存在自定义 filter，拒绝覆盖"
                    return 1
                fi
            done < <(printf '%s\n' "$class_output" |
                awk '$1 == "class" && $2 == "mq" {print $3}')
        fi
    fi
}

apply_qdisc() {
    local iface="$1"
    local rate="$2"

    tc qdisc del dev "$iface" root 2>/dev/null || true
    tc qdisc add dev "$iface" root handle 1: htb default 10 || return 1
    tc class add dev "$iface" parent 1: classid 1:10 htb \
        rate "${rate}mbit" ceil "${rate}mbit" \
        burst 32k cburst 32k quantum 1514 || return 1
    tc qdisc add dev "$iface" parent 1:10 handle 10: fq \
        limit 40960 flow_limit 8192 maxrate "${rate}mbit" || return 1
}

tc_rate_mbit() {
    local output="${1:-}"
    local raw

    raw=$(grep -oE 'rate [0-9.]+[KMGTkmgt]?bit' <<< "$output" 2>/dev/null || true)
    raw="${raw%%$'\n'*}"
    raw="${raw#rate }"
    [[ -n "$raw" ]] || return 1

    awk -v value="$raw" 'BEGIN {
        unit=value
        sub(/^[0-9.]+/, "", unit)
        sub(/bit$/, "", unit)
        number=value+0
        if (unit=="K" || unit=="k") number/=1000
        else if (unit=="G" || unit=="g") number*=1000
        else if (unit=="T" || unit=="t") number*=1000000
        else if (unit=="") number/=1000000
        if (number==int(number)) printf "%d", number
        else printf "%g", number
    }'
}

verify_qdisc_rate() {
    local iface="$1"
    local rate="$2"
    local applied

    applied=$(tc_rate_mbit "$(tc class show dev "$iface" 2>/dev/null)") || return 1
    awk -v applied="$applied" -v expected="$rate" \
        'BEGIN {exit !(applied > expected*0.99 && applied < expected*1.01)}'
}

qdisc_save() {
    local iface="$1"
    QSAVE_IFACE="$iface"
    QSAVE_KIND=$(root_qdisc_kind "$iface")
    QSAVE_OWNED=false
    is_own_shaper "$iface" && QSAVE_OWNED=true
}

restore_simple_qdisc() {
    local iface="$1"
    local kind="$2"

    tc qdisc del dev "$iface" root 2>/dev/null || true
    case "$kind" in
        "")
            return 0
            ;;
        noqueue|mq)
            sleep 1
            [[ "$(root_qdisc_kind "$iface")" == "$kind" ]] || return 1
            ;;
        pfifo_fast|fq|fq_codel)
            tc qdisc add dev "$iface" root "$kind" 2>/dev/null || return 1
            [[ "$(root_qdisc_kind "$iface")" == "$kind" ]] || return 1
            ;;
        *)
            return 1
            ;;
    esac
}

apply_saved_config() {
    local rate
    local iface
    rate=$(read_config_value RATE_MBIT) || return 1
    iface=$(read_config_value INTERFACE || true)
    [[ -n "$iface" && "$iface" != "auto" ]] || iface=$(detect_iface)
    is_positive_integer "$rate" 1 100000 || return 1
    apply_qdisc "$iface" "$rate" && verify_qdisc_rate "$iface" "$rate"
}

qdisc_restore() {
    stop_iperf
    [[ -n "$QSAVE_IFACE" ]] || return 0

    if [[ "$QSAVE_OWNED" == "true" ]]; then
        if ! apply_saved_config; then
            error "无法重新应用原有 tcshape 配置"
            return 1
        fi
    else
        if ! restore_simple_qdisc "$QSAVE_IFACE" "$QSAVE_KIND"; then
            error "无法自动恢复原 qdisc：${QSAVE_KIND:-unknown}"
            return 1
        fi
    fi

    QSAVE_IFACE=""
    QSAVE_KIND=""
    QSAVE_OWNED=false
}

save_baseline() {
    local iface="$1"
    local kind
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"

    [[ -f "$STATE_DIR/qdisc-baseline" ]] && return 0
    kind=$(root_qdisc_kind "$iface")

    case "$kind" in
        ""|noqueue|mq|pfifo_fast|fq|fq_codel) ;;
        *) error "无法保存可自动恢复的 qdisc 基线：$kind"; return 1 ;;
    esac

    {
        printf 'INTERFACE=%s\n' "$iface"
        printf 'KIND=%s\n' "$kind"
    } > "$STATE_DIR/qdisc-baseline"
    chmod 600 "$STATE_DIR/qdisc-baseline"

    tc -j qdisc show dev "$iface" > "$STATE_DIR/qdisc-before.json" 2>/dev/null || true
    tc -j class show dev "$iface" > "$STATE_DIR/class-before.json" 2>/dev/null || true
    tc -j filter show dev "$iface" > "$STATE_DIR/filter-before.json" 2>/dev/null || true
    chmod 600 "$STATE_DIR"/*.json 2>/dev/null || true
}

restore_baseline() {
    local baseline="$STATE_DIR/qdisc-baseline"
    local iface
    local kind
    [[ -f "$baseline" ]] || { error "未找到 qdisc 基线，拒绝猜测恢复"; return 1; }

    iface=$(read_config_value INTERFACE "$baseline") || return 1
    kind=$(read_config_value KIND "$baseline" || true)
    restore_simple_qdisc "$iface" "$kind"
}

write_service_files() {
    local rate="$1"
    local iface="$2"
    local temp_config
    local temp_service

    temp_config=$(mktemp /etc/.tcshape.conf.XXXXXX) || return 1
    temp_service=$(mktemp /etc/systemd/system/.tcshape.service.XXXXXX) || {
        rm -f "$temp_config"
        return 1
    }

    {
        echo "RATE_MBIT=$rate"
        echo "INTERFACE=$iface"
    } > "$temp_config"
    chmod 600 "$temp_config"

    cat > "$temp_service" <<EOF
# tcshape-managed
[Unit]
Description=tcshape egress traffic shaper
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$INSTALL_PATH _apply

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$temp_service"

    mv -f "$temp_config" "$CONFIG_FILE"
    mv -f "$temp_service" "$SERVICE_FILE"
    systemctl daemon-reload
}

cmd_set() {
    local rate="${1:-}"
    local requested_iface="${2:-}"
    local iface
    local previous_config=""

    is_positive_integer "$rate" 1 100000 || {
        error "速率必须是 1-100000 的整数（Mbit）"
        return 1
    }
    rate=$((10#$rate))

    if [[ -n "$requested_iface" ]]; then
        [[ "$requested_iface" =~ ^[[:alnum:]_.:-]+$ && -d "/sys/class/net/$requested_iface" ]] || {
            error "Sweep 记录的出口接口不存在：$requested_iface"
            return 1
        }
        iface="$requested_iface"
    else
        iface=$(detect_iface) || { error "无法确定默认出口接口"; return 1; }
    fi
    check_external_conflicts "$iface" || return 1

    if [[ -f "$CONFIG_FILE" ]]; then
        previous_config=$(mktemp)
        cp -a "$CONFIG_FILE" "$previous_config"
    else
        save_baseline "$iface" || return 1
    fi

    write_service_files "$rate" "$iface" || return 1
    systemctl enable tcshape.service >/dev/null 2>&1 || true

    if systemctl restart tcshape.service && verify_qdisc_rate "$iface" "$rate"; then
        rm -f "$previous_config"
        ok "已启用：${rate} Mbit（HTB + fq）"
        return 0
    fi

    error "整形应用失败，正在恢复"
    if [[ -n "$previous_config" && -f "$previous_config" ]]; then
        cp -a "$previous_config" "$CONFIG_FILE"
        rm -f "$previous_config"
        systemctl restart tcshape.service >/dev/null 2>&1 || true
    else
        systemctl disable --now tcshape.service >/dev/null 2>&1 || true
        rm -f "$CONFIG_FILE" "$SERVICE_FILE"
        systemctl daemon-reload
        restore_baseline || true
    fi
    return 1
}

cmd_off() {
    local iface

    if [[ ! -f "$CONFIG_FILE" || ! -f "$SERVICE_FILE" ]] ||
        ! grep -Fq 'tcshape-managed' "$SERVICE_FILE"; then
        info "本工具未启用持久整形"
        return 0
    fi

    iface=$(read_config_value INTERFACE || true)
    [[ -n "$iface" && -d "/sys/class/net/$iface" ]] || {
        error "配置中的接口不存在，拒绝猜测删除"
        return 1
    }
    if ! is_own_shaper "$iface"; then
        error "当前 qdisc 不属于本工具，拒绝删除"
        return 1
    fi

    systemctl disable --now tcshape.service >/dev/null 2>&1 || true
    if ! restore_baseline; then
        error "基线恢复失败，保留配置文件供人工检查"
        return 1
    fi

    rm -f "$CONFIG_FILE" "$SERVICE_FILE"
    systemctl daemon-reload
    rm -f "$STATE_DIR/qdisc-baseline"
    ok "已移除整形并恢复原 qdisc"
}

read_iface_counter() {
    local direction="$1"
    cat "/sys/class/net/$TRAFFIC_IFACE/statistics/${direction}_bytes" 2>/dev/null
}

traffic_mark() {
    TRAFFIC_IFACE="$1"
    TRAFFIC_RX_START=$(read_iface_counter rx) || return 1
    TRAFFIC_TX_START=$(read_iface_counter tx) || return 1
    [[ "$TRAFFIC_RX_START" =~ ^[0-9]+$ && "$TRAFFIC_TX_START" =~ ^[0-9]+$ ]]
}

traffic_used_bytes() {
    local direction="${1:-total}"
    local rx tx rx_used tx_used
    rx=$(read_iface_counter rx) || return 1
    tx=$(read_iface_counter tx) || return 1
    [[ "$rx" =~ ^[0-9]+$ && "$tx" =~ ^[0-9]+$ ]] || return 1
    rx_used=$((rx - TRAFFIC_RX_START)); (( rx_used < 0 )) && rx_used=0
    tx_used=$((tx - TRAFFIC_TX_START)); (( tx_used < 0 )) && tx_used=0

    case "$direction" in
        download) echo "$rx_used" ;;
        upload) echo "$tx_used" ;;
        total) echo $((rx_used + tx_used)) ;;
        *) return 1 ;;
    esac
}

traffic_budget_reached() {
    local total upload
    total=$(traffic_used_bytes total) || return 0
    upload=$(traffic_used_bytes upload) || return 0
    (( total >= TRAFFIC_TOTAL_LIMIT_BYTES || upload >= TRAFFIC_DIRECTION_LIMIT_BYTES ))
}

format_bytes() {
    awk -v bytes="$1" 'BEGIN {
        if (bytes >= 1000000000) printf "%.2f GB", bytes / 1000000000
        else printf "%.0f MB", bytes / 1000000
    }'
}

traffic_report() {
    local rx tx total
    [[ -n "$TRAFFIC_IFACE" ]] || return 0
    rx=$(traffic_used_bytes download || echo 0)
    tx=$(traffic_used_bytes upload || echo 0)
    total=$((rx + tx))
    echo
    echo "流量：上传 $(format_bytes "$tx") / 下载 $(format_bytes "$rx") / 合计 $(format_bytes "$total")"
}

kill_process_tree() {
    local pid="$1"
    pkill -TERM -P "$pid" 2>/dev/null || true
    kill -TERM "$pid" 2>/dev/null || true
    sleep 1
    pkill -KILL -P "$pid" 2>/dev/null || true
    kill -KILL "$pid" 2>/dev/null || true
}

stop_iperf() {
    local pid
    if [[ -f "$PID_FILE" ]]; then
        pid=$(cat "$PID_FILE" 2>/dev/null || true)
        [[ "$pid" =~ ^[0-9]+$ ]] && kill_process_tree "$pid"
        rm -f "$PID_FILE"
    fi
}

port_order() {
    local first="$1"
    local port
    printf '%s\n' "$first"
    for port in $PORT_POOL; do
        [[ "$port" == "$first" ]] || printf '%s\n' "$port"
    done
}

resolve_ip() {
    case "$IP_FAMILY" in
        -6) getent ahostsv6 "$1" 2>/dev/null | awk '/STREAM/ && $1 !~ /^::ffff:/ {print $1; exit}' ;;
        *) getent ahostsv4 "$1" 2>/dev/null | awk '/STREAM/ {print $1; exit}' ;;
    esac
}

probe_peer_port() {
    local host="$1"
    local ip
    local port
    ip=$(resolve_ip "$host") || return 1
    [[ -n "$ip" ]] || return 1

    if [[ "$IP_FAMILY" == "-6" ]]; then
        return 1
    fi

    for port in $PROBE_PORTS; do
        if timeout 3 bash -c "exec 3<>/dev/tcp/$ip/$port" 2>/dev/null; then
            printf '%s\n' "$port"
            return 0
        fi
    done
    return 1
}

parse_iperf_json() {
    local file="$1"
    jq -r '[
        .end.sum_sent.bits_per_second // 0,
        .end.sum_sent.retransmits // 0,
        .end.sum_received.bits_per_second // 0
    ] | @tsv' "$file" 2>/dev/null
}

run_iperf() {
    local host="$1"
    local duration="$2"
    local parallel="$3"
    local first_port="${4:-$PEER_PORT}"
    local port tmp pid started result sender_bps receiver_bps retrans rc

    for port in $(port_order "$first_port"); do
        traffic_budget_reached && return 75
        tmp=$(mktemp) || return 1
        started=$(date +%s)

        iperf3 "$IP_FAMILY" -c "$host" -p "$port" --connect-timeout 5000 \
            -t "$duration" -P "$parallel" -J > "$tmp" 2>&1 &
        pid=$!
        printf '%s\n' "$pid" > "$PID_FILE"

        while kill -0 "$pid" 2>/dev/null; do
            if traffic_budget_reached; then
                kill_process_tree "$pid"
                wait "$pid" 2>/dev/null || true
                rm -f "$PID_FILE" "$tmp"
                return 75
            fi
            if (( $(date +%s) - started > duration + 25 )); then
                kill_process_tree "$pid"
                break
            fi
            sleep 0.2
        done

        wait "$pid" 2>/dev/null
        rc=$?
        rm -f "$PID_FILE"

        if (( rc == 0 )); then
            result=$(parse_iperf_json "$tmp" || true)
            read -r sender_bps retrans receiver_bps <<< "$result"
            if [[ "$sender_bps" =~ ^[0-9]+([.][0-9]+)?$ ]] &&
                awk -v b="$sender_bps" 'BEGIN {exit !(b > 0)}'; then
                rm -f "$tmp"
                awk -v s="$sender_bps" -v r="$retrans" -v p="$port" -v recv="$receiver_bps" 'BEGIN {
                    printf "%.0f %d %d", s/1000000, r, p
                    if (recv > 0) printf " %.0f", recv/1000000
                    printf "\n"
                }'
                return 0
            fi
        fi

        rm -f "$tmp"
    done

    return 1
}

loss_pct() {
    awk -v rt="$1" -v gp="$2" -v duration="$3" 'BEGIN {
        packets = gp * 1000000 * duration / 8 / 1448
        if (packets < 1) packets = 1
        printf "%.4f", rt * 100 / packets
    }'
}

calc_margin() {
    local bw="$1"
    if (( bw <= 30 )); then echo 1
    elif (( bw <= 60 )); then echo 2
    elif (( bw <= 100 )); then echo 5
    elif (( bw <= 300 )); then echo 10
    elif (( bw <= 600 )); then echo 15
    elif (( bw <= 1000 )); then echo 25
    else echo 40
    fi
}

calc_step() {
    awk -v bw="$1" 'BEGIN {
        if (bw > 2500) step=int((bw/12)/10+0.5)*10
        else step=int(bw/300+0.5)*10
        if(step<20)step=20
        printf "%d", step
    }'
}

calc_auto_step() {
    local lo="$1"
    local hi="$2"
    awk -v lo="$lo" -v hi="$hi" 'BEGIN {
        step=int((hi-lo)/10+0.5)
        if (step<1) step=1
        printf "%d", step
    }'
}

calc_validation_rate() {
    local nominal="$1"
    local rate=$((nominal * 40 / 100))
    (( rate < 1 )) && rate=1
    printf '%d\n' "$rate"
}

calc_test_duration() {
    awk -v bw="$1" 'BEGIN {
        if (bw <= 0) {print 12; exit}
        seconds=int(16000/bw+0.999)
        if(seconds<3)seconds=3
        if(seconds>12)seconds=12
        print seconds
    }'
}

auto_pick_peer() {
    local temp_dir
    local host location provider rtt file port result gp rt used_port receiver goodput
    local fallback=""
    local fallback_rtt=""
    local ideal=50
    local acceptable=100

    info "自动选择附近的公共 iperf3 节点..." >&2
    temp_dir=$(mktemp -d) || return 1

    while IFS='|' read -r host location provider; do
        [[ -n "$host" ]] || continue
        (
            rtt=$(ping "$IP_FAMILY" -c 2 -q -W 2 "$host" 2>/dev/null |
                awk -F/ '/rtt|round-trip/ {printf "%.0f", $5}')
            [[ -n "$rtt" ]] && printf '%s|%s|%s|%s\n' "$rtt" "$host" "$location" "$provider" > "$temp_dir/${host//\//_}"
        ) &
    done <<< "$PEER_POOL"
    wait || true

    for file in "$temp_dir"/*; do
        [[ -s "$file" ]] && cat "$file"
    done | sort -t'|' -k1,1n > "$temp_dir/sorted"

    while IFS='|' read -r rtt host location provider; do
        [[ -n "$host" ]] || continue
        (( rtt <= acceptable )) || continue
        printf '  %-34s %-8s RTT %sms ' "$host" "$location" "$rtt" >&2

        port=$(probe_peer_port "$host" || true)
        if [[ -z "$port" && "$IP_FAMILY" == "-4" ]]; then
            echo "端口不可达" >&2
            continue
        fi
        port="${port:-5201}"
        result=$(run_iperf "$host" 3 1 "$port")
        case $? in
            0)
                read -r gp rt used_port receiver <<< "$result"
                goodput="${receiver:-$gp}"
                printf '可用（接收 %s Mbit，端口 %s）\n' "$goodput" "$used_port" >&2
                if (( rtt <= ideal )); then
                    rm -rf "$temp_dir"
                    printf '%s|%s|%s\n' "$host" "$used_port" "$goodput"
                    return 0
                fi
                [[ -n "$fallback" ]] || {
                    fallback="$host|$used_port|$goodput"
                    fallback_rtt="$rtt"
                }
                ;;
            75)
                rm -rf "$temp_dir"
                return 75
                ;;
            *)
                echo "不可用或繁忙" >&2
                ;;
        esac
    done < "$temp_dir/sorted"

    rm -rf "$temp_dir"
    if [[ -n "$fallback" ]]; then
        warn "最近可用节点 RTT ${fallback_rtt}ms，结果可能偏保守"
        printf '%s\n' "$fallback"
        return 0
    fi

    error "没有找到 ${acceptable}ms 内可用的公共 iperf3 节点"
    return 1
}

apply_test_shaper() {
    apply_qdisc "$1" "$2"
}

save_sweep_result() {
    local status="$1"
    shift
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"
    {
        echo "STATUS=$status"
        echo "CREATED_AT=$(date +%s)"
        printf '%s\n' "$@"
    } > "$STATE_DIR/sweep.result"
    chmod 600 "$STATE_DIR/sweep.result"
}

cleanup_sweep() {
    local exit_code=$?
    trap - EXIT INT TERM HUP
    stop_iperf
    if [[ "$SWEEP_ACTIVE" == "true" ]]; then
        qdisc_restore || exit_code=1
        SWEEP_ACTIVE=false
    fi
    rm -f "$PID_FILE"
    exit "$exit_code"
}

validate_peer_path() {
    local peer="$1"
    local nominal="$2"
    local iface="$3"
    local test_duration="${4:-8}"
    local rate result rc sender retrans port receiver goodput loss

    (( test_duration > 8 )) && test_duration=8
    rate=$(calc_validation_rate "$nominal")
    apply_test_shaper "$iface" "$rate" || return 1
    result=$(run_iperf "$peer" "$test_duration" 2)
    rc=$?
    (( rc == 75 )) && return 75
    (( rc == 0 )) || return 1
    read -r sender retrans port receiver <<< "$result"
    goodput="${receiver:-$sender}"
    loss=$(loss_pct "$retrans" "$sender" "$test_duration")

    if awk -v g="$goodput" -v r="$rate" -v loss="$loss" 'BEGIN {exit !(g < r*0.7 && loss <= 0.05)}'; then
        warn "对端吞吐不足：${goodput}/${rate} Mbit"
        return 1
    fi
    if awk -v loss="$loss" 'BEGIN {exit !(loss > 0.05)}'; then
        warn "低速验证仍有 ${loss}% 丢包，路径不够干净"
        return 1
    fi
    return 0
}

cmd_scan() {
    local peer=""
    local lo="" hi="" step="" margin="" nominal=""
    local duration="" gap=3 assume_yes=false user_range=false
    local iface picked result rc gp retrans port receiver goodput loss estimated_gp=""
    local last_ok="" broke_at="" base_loss="" peer_slow=0

    while (( $# > 0 )); do
        case "$1" in
            --peer) peer="${2:-}"; shift 2 ;;
            --port) PEER_PORT="${2:-}"; shift 2 ;;
            --nominal) nominal="${2:-}"; shift 2 ;;
            --from) lo="${2:-}"; shift 2 ;;
            --to) hi="${2:-}"; shift 2 ;;
            --step) step="${2:-}"; shift 2 ;;
            --dur) duration="${2:-}"; shift 2 ;;
            --margin) margin="${2:-}"; shift 2 ;;
            --yes|-y) assume_yes=true; shift ;;
            -4|-6) IP_FAMILY="$1"; shift ;;
            --*) error "未知参数：$1"; return 1 ;;
            *) [[ -z "$peer" ]] || { error "多余参数：$1"; return 1; }; peer="$1"; shift ;;
        esac
    done

    for value in "${duration:-12}" "${nominal:-1}" "${lo:-1}" "${hi:-1}" "${step:-1}" "${margin:-1}" "$PEER_PORT"; do
        is_positive_integer "$value" 1 100000 || { error "扫描参数必须是正整数"; return 1; }
    done
    [[ -n "$duration" ]] && duration=$((10#$duration))
    PEER_PORT=$((10#$PEER_PORT))
    [[ -n "$nominal" ]] && nominal=$((10#$nominal))
    [[ -n "$lo" ]] && lo=$((10#$lo))
    [[ -n "$hi" ]] && hi=$((10#$hi))
    [[ -n "$step" ]] && step=$((10#$step))
    [[ -n "$margin" ]] && margin=$((10#$margin))

    [[ -z "$duration" ]] || (( duration <= 120 )) || { error "--dur 最大 120 秒"; return 1; }
    is_positive_integer "$PEER_PORT" 1 65535 || { error "端口无效"; return 1; }

    if [[ -n "$lo" || -n "$hi" ]]; then
        [[ -n "$lo" && -n "$hi" ]] || { error "--from 和 --to 必须同时提供"; return 1; }
        (( lo < hi )) || { error "扫描起点必须小于终点"; return 1; }
        user_range=true
        nominal="${nominal:-$hi}"
        step="${step:-$(calc_step "$nominal")}" 
    fi

    iface=$(detect_iface) || { error "无法确定默认出口接口"; return 1; }
    check_external_conflicts "$iface" || return 1
    traffic_mark "$iface" || { error "无法读取网卡流量计数器"; return 1; }

    echo "接口：$iface"
    echo "流量上限：单方向 45 GB / 合计 90 GB"
    echo "Sweep 会临时替换根 qdisc，并产生大量上传流量。"
    if [[ "$assume_yes" != "true" ]]; then
        local answer
        read -r -p "继续扫描？[y/N]: " answer
        [[ "$answer" =~ ^[Yy]$ ]] || { info "已取消"; return 0; }
    fi

    if [[ -z "$peer" ]]; then
        picked=$(auto_pick_peer)
        rc=$?
        if (( rc == 75 )); then
            error "达到流量上限，已停止"
            traffic_report
            return 2
        fi
        (( rc == 0 )) || return 2
        IFS='|' read -r peer PEER_PORT estimated_gp <<< "$picked"
    fi
    if [[ -z "$duration" ]]; then
        duration=$(calc_test_duration "${estimated_gp:-0}")
    fi
    info "测速节点：$peer:$PEER_PORT"
    info "单档测试时长：${duration}s"

    rm -f "$STATE_DIR/sweep.result" 2>/dev/null || true
    qdisc_save "$iface"
    SWEEP_ACTIVE=true
    trap cleanup_sweep EXIT
    trap 'exit 130' INT TERM HUP

    if [[ "$user_range" == "false" ]]; then
        info "不限速探测（${duration}s，单流）..."
        tc qdisc del dev "$iface" root 2>/dev/null || true
        tc qdisc add dev "$iface" root fq || { error "无法应用临时 fq"; return 1; }

        result=$(run_iperf "$peer" "$duration" 1)
        rc=$?
        if (( rc == 75 )); then
            error "达到流量上限，已停止"
            save_sweep_result "BUDGET_EXCEEDED" "PEER=$peer"
            traffic_report
            return 2
        fi
        (( rc == 0 )) || { error "不限速探测失败"; save_sweep_result "FAILED" "PEER=$peer"; return 2; }
        read -r gp retrans port receiver <<< "$result"
        goodput="${receiver:-$gp}"
        loss=$(loss_pct "$retrans" "$gp" "$duration")
        printf '不限速：发送 %s Mbit / 接收 %s Mbit / 重传 %s / 丢包 %s%%\n' \
            "$gp" "$goodput" "$retrans" "$loss"

        if ! awk -v loss="$loss" -v threshold="$LOSS_THRESHOLD" 'BEGIN {exit !(loss > threshold)}'; then
            warn "未检测到限速器，不建议执行流量整形"
            save_sweep_result "NO_POLICER" "UNSHAPED_MBIT=$goodput" "UNSHAPED_SENDER_MBIT=$gp" "PEER=$peer"
            traffic_report
            return 0
        fi

        lo=$(awk -v g="$goodput" 'BEGIN {printf "%d", g*0.95}')
        (( lo < 1 )) && lo=1
        hi=$(awk -v g="$goodput" -v loss="$loss" -v cap="$SCAN_CAP_MBIT" 'BEGIN {
            factor=1.25+loss/100*2; if(factor>2.5)factor=2.5
            value=g*factor; if(value>cap)value=cap
            printf "%d", value
        }')
        nominal="${nominal:-$goodput}"
        step="${step:-$(calc_auto_step "$lo" "$hi")}"
        (( hi <= lo )) && hi=$((lo + step))
    fi

    info "验证节点路径..."
    validate_peer_path "$peer" "$nominal" "$iface" "$duration"
    rc=$?
    if (( rc != 0 )); then
        if (( rc == 75 )); then
            save_sweep_result "BUDGET_EXCEEDED" "PEER=$peer"
            error "达到流量上限，已停止"
        else
            save_sweep_result "PEER_UNSUITABLE" "PEER=$peer"
            warn "节点不适合测量，不建议应用流量整形"
        fi
        traffic_report
        return 2
    fi

    info "扫描 ${lo}-${hi} Mbit，步长 ${step}，每档 ${duration}s"
    printf '%-10s %-12s %-10s %-10s %s\n' "Rate" "Goodput" "Retrans" "Loss%" "Result"

    local rate retry hits test_result test_gp test_rt test_port test_recv test_loss
    local points=()
    for ((rate=lo; rate<=hi; rate+=step)); do points+=("$rate"); done
    [[ " ${points[*]} " == *" $hi "* ]] || points+=("$hi")

    for rate in "${points[@]}"; do
        apply_test_shaper "$iface" "$rate" || { error "无法应用 ${rate} Mbit 临时整形"; return 1; }
        result=$(run_iperf "$peer" "$duration" 1)
        rc=$?
        if (( rc == 75 )); then
            save_sweep_result "BUDGET_EXCEEDED" "PEER=$peer"
            error "达到流量上限，已停止"
            traffic_report
            return 2
        fi
        if (( rc != 0 )); then
            printf '%-10s %-12s %-10s %-10s %s\n' "$rate" "-" "-" "-" "节点繁忙"
            continue
        fi

        read -r gp retrans port receiver <<< "$result"
        goodput="${receiver:-$gp}"
        loss=$(loss_pct "$retrans" "$gp" "$duration")
        [[ -n "$base_loss" ]] || base_loss="$loss"
        hits=0
        if awk -v l="$loss" -v t="$LOSS_THRESHOLD" -v b="$base_loss" 'BEGIN {exit !((l>t) && (b<=0 || l>=b*10))}'; then
            hits=1
            for retry in 2 3; do
                sleep "$gap"
                test_result=$(run_iperf "$peer" "$duration" 1)
                rc=$?
                (( rc == 75 )) && { save_sweep_result "BUDGET_EXCEEDED" "PEER=$peer"; return 2; }
                (( rc == 0 )) || continue
                read -r test_gp test_rt test_port test_recv <<< "$test_result"
                test_loss=$(loss_pct "$test_rt" "$test_gp" "$duration")
                awk -v l="$test_loss" -v t="$LOSS_THRESHOLD" -v b="$base_loss" 'BEGIN {exit !((l>t) && (b<=0 || l>=b*10))}' && ((hits++))
            done
        fi

        if (( hits >= 2 )); then
            printf '%-10s %-12s %-10s %-10s %s\n' "$rate" "$gp" "$retrans" "$loss" "拐点"
            broke_at="$rate"
            break
        fi

        if awk -v g="$goodput" -v r="$rate" -v loss="$loss" -v threshold="$LOSS_THRESHOLD" \
            'BEGIN {exit !(g < r*0.7 && loss <= threshold)}'; then
            ((peer_slow++))
            printf '%-10s %-12s %-10s %-10s %s\n' "$rate" "$gp" "$retrans" "$loss" "节点偏慢"
            if (( peer_slow >= 3 )); then
                save_sweep_result "PEER_UNSUITABLE" "PEER=$peer"
                warn "节点吞吐不足，不建议应用流量整形"
                traffic_report
                return 2
            fi
        else
            peer_slow=0
            printf '%-10s %-12s %-10s %-10s %s\n' "$rate" "$gp" "$retrans" "$loss" "正常"
        fi
        last_ok="$rate"
        sleep "$gap"
    done

    if [[ -z "$last_ok" ]]; then
        save_sweep_result "INCONCLUSIVE" "PEER=$peer"
        warn "没有得到可用档位，不建议应用流量整形"
        traffic_report
        return 2
    fi

    if [[ -z "$broke_at" ]]; then
        save_sweep_result "NO_KNEE" "SCANNED_TO=$hi" "PEER=$peer"
        warn "扫描范围内未找到限速拐点，不建议应用流量整形"
        traffic_report
        return 0
    fi

    # 在最后安全档与粗扫拐点之间进行一次细扫。
    if (( broke_at - last_ok > 5 )); then
        local fine=$((step / 4)); (( fine < 1 )) && fine=1
        local coarse_broke="$broke_at"
        info "细扫 ${last_ok}-${coarse_broke} Mbit，步长 ${fine}"
        broke_at=""
        for ((rate=last_ok+fine; rate<coarse_broke; rate+=fine)); do
            apply_test_shaper "$iface" "$rate" || return 1
            result=$(run_iperf "$peer" "$duration" 1); rc=$?
            (( rc == 75 )) && { save_sweep_result "BUDGET_EXCEEDED" "PEER=$peer"; return 2; }
            (( rc == 0 )) || continue
            read -r gp retrans port receiver <<< "$result"
            goodput="${receiver:-$gp}"
            loss=$(loss_pct "$retrans" "$gp" "$duration")
            hits=0

            if awk -v l="$loss" -v t="$LOSS_THRESHOLD" -v b="$base_loss" 'BEGIN {exit !((l>t) && (b<=0 || l>=b*10))}'; then
                hits=1
                for retry in 2 3; do
                    sleep "$gap"
                    test_result=$(run_iperf "$peer" "$duration" 1); rc=$?
                    (( rc == 75 )) && { save_sweep_result "BUDGET_EXCEEDED" "PEER=$peer"; return 2; }
                    (( rc == 0 )) || continue
                    read -r test_gp test_rt test_port test_recv <<< "$test_result"
                    test_loss=$(loss_pct "$test_rt" "$test_gp" "$duration")
                    awk -v l="$test_loss" -v t="$LOSS_THRESHOLD" -v b="$base_loss" 'BEGIN {exit !((l>t) && (b<=0 || l>=b*10))}' && ((hits++))
                done
            fi

            if (( hits >= 2 )); then
                printf '%-10s %-12s %-10s %-10s %s\n' "$rate" "$gp" "$retrans" "$loss" "拐点"
                broke_at="$rate"
                break
            fi

            printf '%-10s %-12s %-10s %-10s %s\n' "$rate" "$gp" "$retrans" "$loss" "正常"
            last_ok="$rate"
        done
        [[ -n "$broke_at" ]] || broke_at="$coarse_broke"
    fi

    margin="${margin:-$(calc_margin "$nominal")}" 
    local recommend=$((last_ok - margin)); (( recommend < 1 )) && recommend="$last_ok"
    save_sweep_result "KNEE_FOUND" \
        "KNEE_MBIT=$last_ok" \
        "BROKE_AT_MBIT=$broke_at" \
        "RECOMMEND_MBIT=$recommend" \
        "PEER=$peer" \
        "INTERFACE=$iface"

    ok "找到拐点：${last_ok} Mbit；建议：${recommend} Mbit"
    echo "未自动应用。确认后执行：tcshape a"
    traffic_report
}

cmd_apply() {
    local result_file="$STATE_DIR/sweep.result"
    local status recommend result_iface
    [[ -f "$result_file" ]] || { error "没有 Sweep 结果，请先执行：tcshape s"; return 1; }
    status=$(read_config_value STATUS "$result_file" || true)

    if [[ "$status" != "KNEE_FOUND" ]]; then
        case "$status" in
            NO_POLICER) warn "未检测到限速器，不建议整形" ;;
            NO_KNEE) warn "未找到限速拐点，不建议整形" ;;
            *) warn "最近一次测量结果不可靠，不建议整形" ;;
        esac
        return 1
    fi

    recommend=$(read_config_value RECOMMEND_MBIT "$result_file") || return 1
    result_iface=$(read_config_value INTERFACE "$result_file" || true)
    cmd_set "$recommend" "$result_iface"
}

cmd_status() {
    local iface kind rate service_state result_status
    iface=$(detect_iface || true)
    [[ -n "$iface" ]] || { error "无法确定默认出口接口"; return 1; }
    kind=$(root_qdisc_kind "$iface")
    rate=$(tc class show dev "$iface" 2>/dev/null |
        awk '/class htb 1:10/ {for(i=1;i<NF;i++) if($i=="rate") {print $(i+1); exit}}')
    service_state=$(systemctl is-enabled tcshape.service 2>/dev/null || echo "未启用")
    result_status=$(read_config_value STATUS "$STATE_DIR/sweep.result" 2>/dev/null || echo "无")

    echo "接口: $iface"
    echo "根 qdisc: ${kind:-unknown}"
    echo "整形速率: ${rate:-未启用}"
    echo "持久服务: $service_state"
    echo "Sweep 结果: $result_status"
}

menu() {
    echo "tcshape v$VERSION"
    echo "1) 状态"
    echo "2) 扫描"
    echo "3) 应用推荐值"
    echo "4) 手动设置"
    echo "5) 关闭整形"
    echo "6) 退出"
    local choice rate
    read -r -p "选择 [1-6]（默认 1）: " choice
    choice="${choice:-1}"
    case "$choice" in
        1) cmd_status ;;
        2) cmd_scan ;;
        3) cmd_apply ;;
        4) read -r -p "速率 Mbit: " rate; cmd_set "$rate" ;;
        5) cmd_off ;;
        6) return 0 ;;
        *) error "无效选择"; return 1 ;;
    esac
}

main() {
    local command="${1:-menu}"
    [[ $# -gt 0 ]] && shift

    case "$command" in
        help|-h|--help) usage; return 0 ;;
        version|-v|--version) echo "tcshape $VERSION"; return 0 ;;
    esac

    require_root

    if [[ "$command" == "_apply" ]]; then
        apply_saved_config
        return $?
    fi

    install_self || return 1
    ensure_dependencies || return 1
    take_lock

    case "$command" in
        menu) menu ;;
        s|scan) cmd_scan "$@" ;;
        a|apply) cmd_apply ;;
        on|set) cmd_set "${1:-}" ;;
        off) cmd_off ;;
        st|status) cmd_status ;;
        *) error "未知命令：$command"; usage; return 1 ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
