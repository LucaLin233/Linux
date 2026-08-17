#!/usr/bin/env bash
set -euo pipefail

readonly ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT
export NETWORK_OPTIMIZE_STATE_DIR="$TEMP_DIR/state"
export NETWORK_OPTIMIZE_CONF="$TEMP_DIR/etc/sysctl.d/99-network-optimize.conf"
export NETWORK_OPTIMIZE_IPV6_CONF_ROOT="$TEMP_DIR/proc/sys/net/ipv6/conf"
export NETWORK_OPTIMIZE_INITCWND_HOOK="$TEMP_DIR/networkd-dispatcher/routable.d/50-network-optimize-initcwnd"
# shellcheck source=../modules/network-optimize.sh
source "$ROOT_DIR/modules/network-optimize.sh"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_eq() {
    local expected="$1"
    local actual="$2"
    local name="$3"
    [[ "$actual" == "$expected" ]] || fail "$name: expected '$expected', got '$actual'"
    printf 'PASS: %s\n' "$name"
}

assert_eq "6291456" "$(calculate_buffer_max 100 150 268435456)" \
    "buffer max follows 2 x BDP above 4 MiB floor"
assert_eq "39845888" "$(calculate_buffer_max 1000 150 268435456)" \
    "buffer max includes 2 MiB headroom"
assert_eq "4194304" "$(calculate_buffer_max 10 20 268435456)" \
    "buffer max keeps 4 MiB floor"
assert_eq "16777216" "$(calculate_memory_cap 512)" \
    "512 MiB host caps each socket at RAM / 32"
assert_eq "33554432" "$(calculate_memory_cap 1024)" \
    "1 GiB host caps each socket at RAM / 32"
assert_eq "67108864" "$(calculate_memory_cap 2048)" \
    "2 GiB host caps each socket at RAM / 32"
assert_eq "134217728" "$(calculate_memory_cap 4096)" \
    "4 GiB host caps each socket at RAM / 32"
assert_eq "268435456" "$(calculate_memory_cap 16384)" \
    "large-memory cap keeps 256 MiB ceiling"
assert_eq "effective RAM / 32 cap" "$(buffer_limit_reason 10000 150 67108864)" \
    "buffer reason reports the memory-derived cap"
assert_eq "2097152" "$TCP_BUFFER_DEFAULT_BYTES" \
    "TCP receive and send defaults stay fixed at 2 MiB"
assert_eq 'netdev_budget' "$(removed_sysctl_display_name net.core.netdev_budget)" \
    "display known retired sysctl by short name"
assert_eq 'net.test.unknown' "$(removed_sysctl_display_name net.test.unknown)" \
    "preserve the full name of an unknown retired sysctl"
detect_cgroup_memory_limit_mb() { printf '%s\n' 512; }
assert_eq '512' "$(detect_effective_memory_mb 1024)" \
    "effective memory honors a smaller cgroup limit"
detect_cgroup_memory_limit_mb() { printf '%s\n' 2048; }
assert_eq '1024' "$(detect_effective_memory_mb 1024)" \
    "effective memory does not exceed physical RAM"
detect_cgroup_memory_limit_mb() { return 1; }

meminfo_fixture="$TEMP_DIR/meminfo"
printf '%s\n' \
    'MemTotal:        1048576 kB' \
    'MemAvailable:     262144 kB' \
    'SwapTotal:        524288 kB' \
    'SwapFree:         393216 kB' > "$meminfo_fixture"
assert_eq '已用 768 MiB / 可用 256 MiB / 总计 1024 MiB' \
    "$(memory_status_summary "$meminfo_fixture")" "format RAM status"
assert_eq '已用 128 MiB / 总计 512 MiB' \
    "$(swap_status_summary "$meminfo_fixture")" "format Swap status"
printf '%s\n' 'SwapTotal: 0 kB' 'SwapFree: 0 kB' > "$meminfo_fixture"
assert_eq '未配置' "$(swap_status_summary "$meminfo_fixture")" "report absent Swap"
journalctl() {
    printf '%s\n' \
        'oom-kill:constraint=CONSTRAINT_NONE' \
        'Out of memory: Killed process 123' \
        'oom-kill:constraint=CONSTRAINT_MEMCG'
}
assert_eq '2' "$(recent_oom_event_count)" "count canonical OOM events once"
unset -f journalctl

sysctl() {
    [[ "$1" == "-n" ]] || return 1
    case "$2" in
        net.test.present) printf '%s\n' '42' ;;
        net.test.empty) printf '\n' ;;
        *) return 1 ;;
    esac
}
assert_eq '42' "$(read_sysctl_or net.test.present)" "read available sysctl value"
assert_eq 'none' "$(read_sysctl_or net.test.empty none)" \
    "use fallback for an empty sysctl value"
assert_eq 'fallback' "$(read_sysctl_or net.test.missing fallback)" \
    "use explicit fallback for unavailable sysctl"
assert_eq $'  Present: 42\n  Missing: unavailable' \
    "$(print_sysctl_rows \
        'Present|net.test.present|unavailable' \
        'Missing|net.test.missing|unavailable')" \
    "format table-driven sysctl status rows"
unset -f sysctl

file_nr_fixture="$TEMP_DIR/file-nr"
printf '%s\n' '120 0 100000' > "$file_nr_fixture"
assert_eq '120 allocated / 0 unused / 100000 max' \
    "$(file_handle_status "$file_nr_fixture")" "format file handle status"
assert_eq '不可用' "$(file_handle_status "$TEMP_DIR/missing-file-nr")" \
    "handle unavailable file handle status"
status_function=$(declare -f show_status)
for diagnostic_key in \
    vm.min_free_kbytes fs.file-max fs.nr_open net.ipv4.tcp_tw_reuse \
    net.core.netdev_budget net.core.netdev_budget_usecs; do
    grep -Fq "$diagnostic_key" <<< "$status_function" ||
        fail "status omits read-only diagnostic $diagnostic_key"
done
printf 'PASS: status includes read-only kernel capacity diagnostics\n'
show_status >/dev/null || fail "status fails when optional diagnostics are unavailable"
printf 'PASS: status succeeds when optional diagnostics are unavailable\n'

TUNING_MODE=auto
DETECTED_RTT_MS=150
RTT_SOURCE='automatic policy'
RTT_POLICY='fixed 150 ms'
assert_eq 'RTT：计算 150 ms（来源 automatic policy；策略 fixed 150 ms）' \
    "$(format_rtt_selection_summary)" "summary reports fixed automatic calculation RTT"
TUNING_MODE=static
assert_eq 'RTT：未使用（静态 32 MiB 缓冲区）' \
    "$(format_rtt_selection_summary)" "summary explains static RTT handling"

PROBE_IFACE=eth0
TRAFFIC_IFACES=(eth0 eth1)
TRAFFIC_RX_START_BY_IFACE=([eth0]=100000000 [eth1]=50000000)
TRAFFIC_TX_START_BY_IFACE=([eth0]=200000000 [eth1]=100000000)
read_iface_counter() {
    case "$1:$2" in
        eth0:rx) echo 1600000000 ;;
        eth0:tx) echo 2450000000 ;;
        eth1:rx) echo 300000000 ;;
        eth1:tx) echo 600000000 ;;
        *) return 1 ;;
    esac
}
assert_eq '流量（接口 eth0,eth1；含测试期间后台流量，按保守安全预算累计）：上传 2.75 GB / 下载 1.75 GB / 合计 4.50 GB' \
    "$(traffic_report)" "traffic report sums actual target interfaces conservatively"

assert_eq "default via 192.0.2.1 dev eth0 proto dhcp metric 100" \
    "$(strip_route_window_fields 'default via 192.0.2.1 dev eth0 proto dhcp metric 100 initcwnd 32 initrwnd 32')" \
    "strip route window fields without losing route attributes"

assert_eq 'effective|root fq' "$(classify_active_qdisc <<'EOF'
qdisc fq 0: root refcnt 2 limit 10000p flow_limit 100p
EOF
)" "classify root fq as effective"
assert_eq 'effective|root mq; all 2 leaves fq' "$(classify_active_qdisc <<'EOF'
qdisc mq 0: root
qdisc fq 0: parent :2 limit 10000p
qdisc fq 0: parent :1 limit 10000p
qdisc clsact ffff: parent ffff:fff1
EOF
)" "classify mq with all fq leaves as effective"
assert_eq 'effective|root htb; all 1 leaves fq' "$(classify_active_qdisc <<'EOF'
qdisc htb 1: root refcnt 2 r2q 10 default 0xa direct_packets_stat 0
qdisc fq 10: parent 1:10 limit 10000p flow_limit 100p
qdisc clsact ffff: parent ffff:fff1
EOF
)" "classify htb with fq leaf as effective"
assert_eq 'mixed|root htb; fq leaves 1/2; other: fq_codel' "$(classify_active_qdisc <<'EOF'
qdisc htb 1: root refcnt 2 r2q 10 default 0xa direct_packets_stat 0
qdisc fq 10: parent 1:10 limit 10000p flow_limit 100p
qdisc fq_codel 20: parent 1:20 limit 10240p
EOF
)" "classify mixed htb leaves"
assert_eq 'inactive|root htb; no readable leaves' "$(classify_active_qdisc <<'EOF'
qdisc htb 1: root refcnt 2 r2q 10 default 0xa direct_packets_stat 0
EOF
)" "classify htb without readable leaves as inactive"
assert_eq 'mixed|root mq; fq leaves 1/2; other: fq_codel' "$(classify_active_qdisc <<'EOF'
qdisc mq 0: root
qdisc fq 0: parent :2 limit 10000p
qdisc fq_codel 0: parent :1 limit 10240p
EOF
)" "classify mixed mq leaves"
assert_eq 'inactive|root noqueue' "$(classify_active_qdisc <<'EOF'
qdisc noqueue 0: root refcnt 2
EOF
)" "classify root noqueue explicitly"
assert_eq 'unreadable|no qdisc data' "$(classify_active_qdisc </dev/null)" \
    "classify unreadable qdisc output"

assert_eq "正常：测速期间 softnet 和网卡无新增丢包或错误" \
    "$(classify_network_health 0 0 0 0 1000000)" \
    "classify clean health snapshot"
assert_eq "正常：测速期间仅有轻微网卡丢包波动 +1（1 ppm），无 softnet 丢包或网卡错误" \
    "$(classify_network_health 0 0 0 1 1000000)" \
    "classify isolated NIC drop as normal fluctuation"
assert_eq "注意：测速期间 softnet budget pressure +105，网卡丢包 +0（0 ppm），无新增 softnet 丢包或网卡错误" \
    "$(classify_network_health 0 105 0 0 1000000)" \
    "classify softnet budget pressure as notice"
assert_eq "注意：测速期间 softnet budget pressure +0，网卡丢包 +1983（39 ppm），无新增 softnet 丢包或网卡错误" \
    "$(classify_network_health 0 0 0 1983 50000000)" \
    "classify low-ratio NIC drops during high-volume test as notice"
assert_eq "注意：测速期间 softnet budget pressure +0，网卡丢包 +2000（0 ppm），无新增 softnet 丢包或网卡错误" \
    "$(classify_network_health 0 0 0 2000 0)" \
    "classify NIC drops without packet denominator as notice"
assert_eq "异常：测速期间 softnet 丢包 +1，网卡丢包 +0（0 ppm），网卡错误 +0" \
    "$(classify_network_health 1 0 0 0 1000000)" \
    "classify softnet drops as abnormal"
assert_eq "异常：测速期间 softnet 丢包 +0，网卡丢包 +2000（2000 ppm），网卡错误 +0" \
    "$(classify_network_health 0 0 0 2000 1000000)" \
    "classify material NIC drop ratio as abnormal"
assert_eq "异常：测速期间 softnet 丢包 +0，网卡丢包 +0（0 ppm），网卡错误 +1" \
    "$(classify_network_health 0 0 1 0 1000000)" \
    "classify NIC errors as abnormal"

ethtool() {
    [[ "$*" == '-S eth0' ]] || return 1
    printf '%s\n' \
        'NIC statistics:' \
        '     bw_out_allowance_exceeded: 4' \
        '     pps_allowance_exceeded: 7' \
        '     unrelated_counter: 99'
}
assert_eq $'bw_out_allowance_exceeded=4\npps_allowance_exceeded=7' \
    "$(nic_allowance_snapshot eth0)" "read supported driver allowance counters"
ethtool() { return 1; }
assert_eq '' "$(nic_allowance_snapshot eth0)" \
    "ignore unsupported ethtool statistics"
unset -f ethtool

assert_eq $'系统计数增量：softnet_dropped +1 / time_squeeze +5 / 全机 TCP 重传 +30\n网卡计数增量：drops rx +10 tx +20 / errors rx +0 tx +1 / packets rx +100 tx +500\n网络健康：异常：测速期间 softnet 丢包 +1，网卡丢包 +30（50000 ppm），网卡错误 +1；当前受限 socket 2\n驱动 allowance：bw_out_allowance_exceeded +2' \
    "$(format_verify_health_delta \
        '0 10 0 0 2 3 100 0 1000 2000' \
        '1 15 0 1 12 23 130 2 1100 2500' \
        'bw_out_allowance_exceeded=4' \
        'bw_out_allowance_exceeded=6')" \
    "format verify health and allowance deltas"
assert_eq '驱动 allowance：无新增超额事件' \
    "$(format_nic_allowance_delta \
        $'bw_out_allowance_exceeded=4\npps_allowance_exceeded=7' \
        $'bw_out_allowance_exceeded=4\npps_allowance_exceeded=7')" \
    "format unchanged allowance counters"
assert_eq '网络健康：测试期间计数器重置，无法计算可靠增量' \
    "$(format_verify_health_delta \
        '1 0 0 0 0 0 10 0 100 100' \
        '0 0 0 0 0 0 10 0 100 100' '' '')" \
    "reject reset verify counters"

CURRENT_ROUTE="default via 192.0.2.1 dev eth0 proto dhcp src 192.0.2.10 metric 100 onlink"
LAST_ROUTE_ARGS=""
IP_FAIL=false

default_ipv4_route() { printf '%s\n' "$CURRENT_ROUTE"; }
ip() {
    [[ "$1 $2 $3" == "-4 route replace" ]] || return 1
    shift 3
    LAST_ROUTE_ARGS="$*"
    [[ "$IP_FAIL" == "false" ]] || return 1
    CURRENT_ROUTE="$*"
}

mkdir -p "$NETWORK_OPTIMIZE_STATE_DIR" "$(dirname "$INITCWND_ROUTE_HOOK")"
backup_default_route
apply_initcwnd >/dev/null
assert_eq "default via 192.0.2.1 dev eth0 proto dhcp src 192.0.2.10 metric 100 onlink initcwnd 32 initrwnd 32" \
    "$LAST_ROUTE_ARGS" "apply initcwnd while preserving route attributes"
[[ -e "$ROUTE_OWNED_MARKER" ]] || fail "apply initcwnd records ownership"
printf 'PASS: apply initcwnd records ownership\n'
[[ -x "$INITCWND_ROUTE_HOOK" ]] || fail "apply initcwnd installs executable route hook"
grep -Fq '# Managed by network-optimize.sh' "$INITCWND_ROUTE_HOOK" ||
    fail "initcwnd route hook lacks ownership marker"
grep -Fq '# network-optimize:initcwnd-hook:v1' "$INITCWND_ROUTE_HOOK" ||
    fail "initcwnd route hook lacks verifiable version marker"
initcwnd_settings_owned || fail "ownership marker is not accepted as ownership evidence"
printf 'PASS: marker ownership evidence is accepted\n'
bash -n "$INITCWND_ROUTE_HOOK" || fail "generated initcwnd route hook has invalid syntax"
printf 'PASS: apply initcwnd installs managed persistence hook\n'

backup_default_route
[[ -e "$ROUTE_PREVIOUS_OWNED" ]] || fail "rerun records previous route ownership"
printf 'PASS: rerun records previous route ownership\n'
INITCWND_ENABLED=false
apply_initcwnd >/dev/null
assert_eq "default via 192.0.2.1 dev eth0 proto dhcp src 192.0.2.10 metric 100 onlink" \
    "$CURRENT_ROUTE" "disable initcwnd removes owned route windows"
[[ ! -e "$ROUTE_OWNED_MARKER" ]] || fail "disable initcwnd clears ownership"
[[ ! -e "$INITCWND_ROUTE_HOOK" ]] || fail "disable initcwnd removes managed route hook"
printf 'PASS: disable initcwnd clears ownership and persistence hook\n'

CURRENT_ROUTE="default via 198.51.100.1 dev eth1 proto dhcp metric 200"
restore_default_route "$ROUTE_PREVIOUS_BACKUP" "$ROUTE_PREVIOUS_OWNED"
assert_eq "default via 192.0.2.1 dev eth0 proto dhcp src 192.0.2.10 metric 100 onlink initcwnd 32 initrwnd 32" \
    "$CURRENT_ROUTE" "restore previous route snapshot"
[[ -e "$ROUTE_OWNED_MARKER" ]] || fail "restore previous owned route restores ownership"
printf 'PASS: restore previous owned route restores ownership\n'

CURRENT_ROUTE="default via 203.0.113.1 dev eth2 initcwnd 32 initrwnd 32 metric 300"
rm -f "$TEMP_DIR/missing-route"
restore_default_route "$TEMP_DIR/missing-route"
assert_eq "default via 203.0.113.1 dev eth2 metric 300" "$CURRENT_ROUTE" \
    "missing backup strips owned route windows from current route"

CURRENT_ROUTE="default via 192.0.2.1 dev eth0 proto dhcp metric 100"
INITCWND_ENABLED=true
IP_FAIL=true
if apply_initcwnd >/dev/null 2>&1; then
    fail "failed route replacement unexpectedly succeeded"
fi
IP_FAIL=false
assert_eq "default via 192.0.2.1 dev eth0 proto dhcp metric 100" "$CURRENT_ROUTE" \
    "failed initcwnd application leaves route unchanged"
[[ ! -e "$ROUTE_OWNED_MARKER" ]] || fail "failed initcwnd application does not claim ownership"
printf 'PASS: failed initcwnd application does not claim ownership\n'

# A verifiable managed hook is sufficient ownership evidence without the marker.
rm -f "$ROUTE_OWNED_MARKER" "$ROUTE_PREVIOUS_BACKUP" "$ROUTE_INITIAL_BACKUP"
CURRENT_ROUTE="default via 192.0.2.1 dev eth0 proto dhcp src 192.0.2.10 metric 100 onlink initcwnd 32 initrwnd 32"
write_initcwnd_hook
INITCWND_ENABLED=false
apply_initcwnd >/dev/null
assert_eq "default via 192.0.2.1 dev eth0 proto dhcp src 192.0.2.10 metric 100 onlink" \
    "$CURRENT_ROUTE" "managed hook ownership allows route-window cleanup"
printf 'PASS: hook ownership evidence is accepted\n'

# A trusted snapshot proving the pre-script route had no windows is also sufficient.
rm -f "$ROUTE_OWNED_MARKER" "$INITCWND_ROUTE_HOOK"
printf '%s\n' 'default via 192.0.2.1 dev eth0 proto dhcp src 192.0.2.10 metric 100 onlink' \
    > "$ROUTE_PREVIOUS_BACKUP"
CURRENT_ROUTE="default via 192.0.2.1 dev eth0 proto dhcp src 192.0.2.10 metric 100 onlink initcwnd 32 initrwnd 32"
apply_initcwnd >/dev/null
assert_eq "default via 192.0.2.1 dev eth0 proto dhcp src 192.0.2.10 metric 100 onlink" \
    "$CURRENT_ROUTE" "trusted route snapshot allows owned cleanup"
printf 'PASS: snapshot ownership evidence is accepted\n'

# A stale snapshot for another default route must not authorize cleanup.
printf '%s\n' 'default via 192.0.2.1 dev eth0 proto dhcp metric 100' \
    > "$ROUTE_PREVIOUS_BACKUP"
CURRENT_ROUTE="default via 203.0.113.1 dev eth9 proto static metric 77 initcwnd 16 initrwnd 20"
LAST_ROUTE_ARGS="not-called"
apply_initcwnd >/dev/null
assert_eq "default via 203.0.113.1 dev eth9 proto static metric 77 initcwnd 16 initrwnd 20" \
    "$CURRENT_ROUTE" "stale snapshot cannot claim a different route"
assert_eq "not-called" "$LAST_ROUTE_ARGS" "stale snapshot does not replace third-party route"
printf 'PASS: stale route snapshot is not ownership evidence\n'

# Marker-like content with extra commands is not a verifiable managed hook.
rm -f "$ROUTE_PREVIOUS_BACKUP" "$ROUTE_INITIAL_BACKUP"
render_initcwnd_hook > "$INITCWND_ROUTE_HOOK"
printf '%s\n' 'echo external-command' >> "$INITCWND_ROUTE_HOOK"
if is_managed_initcwnd_hook; then
    fail "modified initcwnd hook was accepted as managed"
fi
CURRENT_ROUTE="default via 203.0.113.1 dev eth9 proto static metric 77 initcwnd 16 initrwnd 20"
LAST_ROUTE_ARGS="not-called"
apply_initcwnd >/dev/null
assert_eq "not-called" "$LAST_ROUTE_ARGS" "modified hook cannot authorize route cleanup"
printf 'PASS: only exact generated hook is ownership evidence\n'

# Unowned third-party route windows must remain untouched.
rm -f "$ROUTE_OWNED_MARKER" "$INITCWND_ROUTE_HOOK" \
    "$ROUTE_PREVIOUS_BACKUP" "$ROUTE_INITIAL_BACKUP" "$ROUTE_INITIAL_UNKNOWN"
CURRENT_ROUTE="default via 203.0.113.1 dev eth9 proto static src 203.0.113.2 metric 77 onlink initcwnd 16 initrwnd 20"
LAST_ROUTE_ARGS="not-called"
apply_initcwnd >/dev/null
assert_eq "default via 203.0.113.1 dev eth9 proto static src 203.0.113.2 metric 77 onlink initcwnd 16 initrwnd 20" \
    "$CURRENT_ROUTE" "unowned third-party route windows remain unchanged"
assert_eq "not-called" "$LAST_ROUTE_ARGS" "unowned cleanup does not replace route"

# Owned cleanup failure must propagate and retain ownership for retry.
CURRENT_ROUTE="default via 192.0.2.1 dev eth0 proto dhcp metric 100 initcwnd 32 initrwnd 32"
install -D -m 0600 /dev/null "$ROUTE_OWNED_MARKER"
IP_FAIL=true
if apply_initcwnd >/dev/null 2>&1; then
    fail "failed owned initcwnd cleanup unexpectedly succeeded"
fi
IP_FAIL=false
assert_eq "default via 192.0.2.1 dev eth0 proto dhcp metric 100 initcwnd 32 initrwnd 32" \
    "$CURRENT_ROUTE" "failed owned cleanup preserves route attributes"
[[ -e "$ROUTE_OWNED_MARKER" ]] || fail "failed owned cleanup dropped ownership marker"
printf 'PASS: owned cleanup failure propagates\n'

# Hook deletion failure must return nonzero and leave the now-inert hook for retry.
CURRENT_ROUTE="default via 192.0.2.1 dev eth0 proto dhcp metric 100 initcwnd 32 initrwnd 32"
write_initcwnd_hook
remove_initcwnd_hook() { return 1; }
if apply_initcwnd >/dev/null 2>&1; then
    fail "failed managed hook deletion unexpectedly succeeded"
fi
unset -f remove_initcwnd_hook
assert_eq "default via 192.0.2.1 dev eth0 proto dhcp metric 100" \
    "$CURRENT_ROUTE" "hook deletion failure does not undo completed route cleanup"
[[ -e "$INITCWND_ROUTE_HOOK" ]] || fail "failed hook deletion removed the hook"
[[ ! -e "$ROUTE_OWNED_MARKER" ]] || fail "failed hook deletion left hook active"
rm -f "$INITCWND_ROUTE_HOOK"
printf 'PASS: managed hook deletion failure propagates without success\n'

CURRENT_ROUTE="default via 192.0.2.1 dev eth0 proto dhcp metric 100"
install -D -m 0600 /dev/null "$ROUTE_OWNED_MARKER"
assert_eq 'drift|ownership marker exists but default route lacks initcwnd/initrwnd 32' \
    "$(detect_initcwnd_state)" "detect marker and route drift"
CURRENT_ROUTE="default via 192.0.2.1 dev eth0 proto dhcp metric 100 initcwnd 32 initrwnd 32"
assert_eq 'effective|owned default route has initcwnd/initrwnd 32' \
    "$(detect_initcwnd_state)" "detect owned initcwnd route as effective"

printf 'All network-optimize tests passed.\n'
