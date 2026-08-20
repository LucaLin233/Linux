#!/usr/bin/env bash
set -euo pipefail

readonly ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT
export NETWORK_OPTIMIZE_STATE_DIR="$TEMP_DIR/state"
export NETWORK_OPTIMIZE_CONF="$TEMP_DIR/etc/sysctl.d/99-network-optimize.conf"
export NETWORK_OPTIMIZE_BBR_MODULES_FILE="$TEMP_DIR/etc/modules-load.d/network-optimize-bbr.conf"
export NETWORK_OPTIMIZE_INITCWND_HOOK="$TEMP_DIR/networkd-dispatcher/routable.d/50-network-optimize-initcwnd"
export NETWORK_OPTIMIZE_CACHE_FILE="$TEMP_DIR/state/network-optimize.bandwidth-cache"
export NETWORK_OPTIMIZE_LOCK_FILE="$TEMP_DIR/network-optimize.lock"
export NETWORK_OPTIMIZE_LOG="$TEMP_DIR/network-optimize.log"
# shellcheck source=../modules/network-optimize.sh
source "$ROOT_DIR/modules/network-optimize.sh"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_eq() {
    local expected="$1" actual="$2" name="$3"
    [[ "$actual" == "$expected" ]] || fail "$name: expected '$expected', got '$actual'"
    printf 'PASS: %s\n' "$name"
}

assert_ok() {
    local name="$1"
    shift
    "$@" || fail "$name"
    printf 'PASS: %s\n' "$name"
}

assert_fail() {
    local name="$1"
    shift
    if "$@"; then
        fail "$name: command unexpectedly succeeded"
    fi
    printf 'PASS: %s\n' "$name"
}

deny_real_network() {
    fail "CI attempted an unmocked public network or APT operation: $*"
}
iperf3() { deny_real_network iperf3 "$@"; }
ping() { deny_real_network ping "$@"; }
getent() { deny_real_network getent "$@"; }
apt-get() { deny_real_network apt-get "$@"; }
ip() { deny_real_network ip "$@"; }
read_iface_counter() { deny_real_network interface-counter "$@"; }

assert_eq "6291456" "$(calculate_buffer_max 100 150 268435456)" \
    "buffer max follows 2 x BDP above 4 MiB floor"
assert_eq "39845888" "$(calculate_buffer_max 1000 150 268435456)" \
    "buffer max includes 2 MiB headroom"
assert_eq "4194304" "$(calculate_buffer_max 10 20 268435456)" \
    "buffer max keeps 4 MiB floor"
assert_eq "16777216" "$(calculate_memory_cap 512)" \
    "512 MiB host caps each socket at RAM / 32"
assert_eq "268435456" "$(calculate_memory_cap 16384)" \
    "large-memory cap keeps 256 MiB ceiling"
assert_eq "2097152" "$TCP_BUFFER_DEFAULT_BYTES" \
    "TCP receive and send defaults stay fixed at 2 MiB"
(
    mock_page_size=4096
    getconf() {
        [[ "$1" == "PAGESIZE" ]] || return 1
        printf '%s\n' "$mock_page_size"
    }
    assert_eq '4096 8192 16384' "$(calculate_tcp_mem 128)" \
        "128 MiB RAM keeps tcp_mem byte floors with 4 KiB pages"
    assert_eq '8192 16384 32768' "$(calculate_tcp_mem 512)" \
        "512 MiB RAM derives tcp_mem with 4 KiB pages"
    assert_eq '16384 32768 65536' "$(calculate_tcp_mem 1024)" \
        "1 GiB RAM derives tcp_mem with 4 KiB pages"
    assert_eq '16.0 MiB / 32.0 MiB / 64.0 MiB' \
        "$(format_tcp_mem_bytes '4096 8192 16384')" \
        "4 KiB tcp_mem floors display fixed MiB values"

    mock_page_size=16384
    assert_eq '1024 2048 4096' "$(calculate_tcp_mem 128)" \
        "128 MiB RAM keeps tcp_mem byte floors with 16 KiB pages"
    assert_eq '16.0 MiB / 32.0 MiB / 64.0 MiB' \
        "$(format_tcp_mem_bytes '1024 2048 4096')" \
        "16 KiB tcp_mem floors display fixed MiB values"

    mock_page_size=65536
    assert_eq '256 512 1024' "$(calculate_tcp_mem 128)" \
        "128 MiB RAM keeps tcp_mem byte floors with 64 KiB pages"
    assert_eq '512 1024 2048' "$(calculate_tcp_mem 512)" \
        "512 MiB RAM derives tcp_mem with 64 KiB pages"
    assert_eq '1024 2048 4096' "$(calculate_tcp_mem 1024)" \
        "1 GiB RAM derives tcp_mem with 64 KiB pages"
    assert_eq '16.0 MiB / 32.0 MiB / 64.0 MiB' \
        "$(format_tcp_mem_bytes '256 512 1024')" \
        "64 KiB tcp_mem floors display fixed MiB values"
    assert_eq '32.0 MiB / 64.0 MiB / 128.0 MiB' \
        "$(format_tcp_mem_bytes '512 1024 2048')" \
        "64 KiB 512 MiB ratios display expected MiB values"
    assert_eq '64.0 MiB / 128.0 MiB / 256.0 MiB' \
        "$(format_tcp_mem_bytes '1024 2048 4096')" \
        "64 KiB 1 GiB ratios display expected MiB values"

    read -r low pressure maximum <<< "$(calculate_tcp_mem 128)"
    (( low > 0 && low < pressure && pressure < maximum )) ||
        fail "tcp_mem values are not strictly increasing"
    printf 'PASS: tcp_mem values are strictly increasing\n'

    assert_fail "zero RAM is rejected for tcp_mem" calculate_tcp_mem 0
    assert_fail "non-numeric RAM is rejected for tcp_mem" calculate_tcp_mem invalid
)
(
    getconf() { printf '%s\n' invalid; }
    assert_fail "non-numeric page size is rejected" calculate_tcp_mem 1024
    getconf() { printf '%s\n' 0; }
    assert_fail "zero page size is rejected" calculate_tcp_mem 1024
)
detect_cgroup_memory_limit_mb() { printf '%s\n' 512; }
assert_eq '512' "$(detect_effective_memory_mb 1024)" \
    "effective memory honors a smaller cgroup limit"
detect_cgroup_memory_limit_mb() { printf '%s\n' 2048; }
assert_eq '1024' "$(detect_effective_memory_mb 1024)" \
    "effective memory does not exceed physical RAM"
unset -f detect_cgroup_memory_limit_mb
eval "$(sed -n '/^detect_cgroup_memory_limit_mb() {/,/^}/p' "$ROOT_DIR/modules/network-optimize.sh")"

fixture="$TEMP_DIR/iperf.json"
cat > "$fixture" <<'JSON'
{
  "start": {"tcp_mss_default": 1448},
  "end": {
    "sum_sent": {"bits_per_second": 1000000000, "bytes": 724000000, "retransmits": 500},
    "sum_received": {"bits_per_second": 950000000},
    "cpu_utilization_percent": {"host_total": 12.34, "remote_total": 7.89}
  }
}
JSON
assert_eq '1000|950|500|0.1000|12.3|7.9' "$(parse_iperf_metrics "$fixture")" \
    "parse complete iperf3 JSON metrics"
traffic_reset
assert_fail "empty interface accounting does not preempt the first peer" \
    traffic_budget_reached upload
assert_eq 4 "$IPERF_PARALLEL" "public measurement uses four parallel streams"
assert_eq 2 "$IPERF_OMIT_SECONDS" "public measurement warms up for two seconds"
assert_eq 5 "$IPERF_DURATION" "public measurement uses five-second samples"
assert_eq 0.2 "$TRAFFIC_POLL_INTERVAL_SECONDS" \
    "traffic budget polling uses the configured interval"
assert_eq 2 "$IPERF_MAX_PEERS" "public measurement selects at most two peers"
iperf_runner_body=$(declare -f run_iperf_runner)
grep -Fq 'iperf3 -4 -c "$host"' <<< "$iperf_runner_body" ||
    fail "iperf3 runner is not forced to IPv4"
grep -Fq 'sleep "$TRAFFIC_POLL_INTERVAL_SECONDS"' <<< "$iperf_runner_body" ||
    fail "iperf3 runner does not use the traffic polling interval"
printf 'PASS: public iperf3 runner is IPv4 only and budget-polled\n'

counter_reader_body=$(sed -n '/^read_iface_counter() {/,/^}/p' \
    "$ROOT_DIR/modules/network-optimize.sh")
grep -Fq 'IFS= read -r value 2>/dev/null \' <<< "$counter_reader_body" ||
    fail "interface counter does not silence Bash read errors"
grep -Fq '< "/sys/class/net/$iface/statistics/${direction}_bytes"' \
    <<< "$counter_reader_body" || fail "interface counter does not use Bash read"
if grep -Eq '(^|[[:space:]])cat([[:space:]]|$)' <<< "$counter_reader_body"; then
    fail "interface counter still forks cat"
fi
printf 'PASS: interface counter uses Bash built-in read\n'

(
    eval "$(sed -n '/^read_iface_counter() {/,/^}/p' \
        "$ROOT_DIR/modules/network-optimize.sh")"
    missing_iface="network-optimize-missing-iface-$$"
    missing_counter_stderr="$TEMP_DIR/missing-interface-counter.stderr"

    if read_iface_counter "$missing_iface" rx \
        2>"$missing_counter_stderr"; then
        fail "missing interface counter unexpectedly succeeded"
    fi
    [[ ! -s "$missing_counter_stderr" ]] ||
        fail "missing interface counter emitted raw shell diagnostics"
    printf 'PASS: missing interface counter fails silently\n'
)

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
assert_eq '流量：eth0,eth1；上传 2.75 GB / 下载 1.75 GB / 合计 4.50 GB（包含同期后台流量）' \
    "$(traffic_report)" "traffic report sums mocked target interfaces"
read_iface_counter() { deny_real_network interface-counter "$@"; }

assert_eq "default via 192.0.2.1 dev eth0 proto dhcp metric 100" \
    "$(strip_route_window_fields 'default via 192.0.2.1 dev eth0 proto dhcp metric 100 initcwnd 32 initrwnd 32')" \
    "strip route window fields without losing route attributes"
assert_eq 'effective|root fq' "$(classify_active_qdisc <<'EOF'
qdisc fq 0: root refcnt 2 limit 10000p flow_limit 100p
EOF
)" "classify root fq as effective"
assert_eq 'effective|root htb; all 1 leaves fq' "$(classify_active_qdisc <<'EOF'
qdisc htb 1: root refcnt 2 default 10
qdisc fq 10: parent 1:10 limit 10000p
EOF
)" "classify traffic-shape HTB with fq leaf as effective"
assert_eq '生效（根队列 fq）' \
    "$(format_qdisc_state effective 'root fq')" \
    "format root fq detail in Chinese"
assert_eq '生效（根队列 mq，1 个叶子队列均为 fq）' \
    "$(format_qdisc_state effective 'root mq; all 1 leaves fq')" \
    "format mq leaf detail in Chinese"
assert_eq '不可读（根队列 mq，无可读叶子队列）' \
    "$(format_qdisc_state unreadable 'root mq; no readable leaves')" \
    "format unreadable qdisc leaves in Chinese"
assert_eq '不可读（无法读取 qdisc）' \
    "$(format_qdisc_state unreadable 'tc qdisc read failed')" \
    "format qdisc read failure in Chinese"

node_output=$(print_measurement_nodes \
    '新加坡/OVH sgp.proof.ovh.net [15.235.182.181]:5201 (IPv4 RTT 1 ms);新加坡/Leaseweb speedtest.sin1.sg.leaseweb.net [23.108.99.54]:5201 (IPv4 RTT 1 ms)' \
    '    ')
grep -Fq '    1. 新加坡 / OVH / sgp.proof.ovh.net [15.235.182.181]:5201 / RTT 1 ms' \
    <<< "$node_output" || fail "first measurement node is not formatted on its own line"
grep -Fq '    2. 新加坡 / Leaseweb / speedtest.sin1.sg.leaseweb.net [23.108.99.54]:5201 / RTT 1 ms' \
    <<< "$node_output" || fail "second measurement node is not formatted on its own line"
if grep -Fq ';新加坡' <<< "$node_output"; then
    fail "measurement node display retains a semicolon separator"
fi
printf 'PASS: measurement nodes use numbered Chinese display lines\n'

setup_probe_mocks() {
    TUNING_MODE=auto
    command() { return 0; }
    ordered_iperf_ports() { printf '%s\n' 5201; }
    traffic_add_target() { PROBE_IFACE=eth0; return 0; }
    traffic_budget_reached() { return 1; }
    show_probe_environment_once() { return 0; }
    tcp_port_open() { return 0; }
    route_identity_for_target() { printf '%s\n' '2|eth0|192.0.2.1|192.0.2.2'; }
    current_epoch() { printf '%s\n' 2000000000; }
    format_measurement_epoch() { printf '%s\n' '2033-05-18T03:33:20Z'; }
}

(
    setup_probe_mocks
    calls="$TEMP_DIR/dual-peer.calls"
    : > "$calls"
    rank_iperf_peers() {
        RANKED_IPERF_PEERS=$(printf '%s\n' \
            '10|one.example|192.0.2.10|A|ProviderA' \
            '20|two.example|192.0.2.20|B|ProviderB' \
            '30|three.example|192.0.2.30|C|ProviderC')
    }
    run_iperf_test() {
        printf '%s:%s\n' "$1" "$3" >> "$calls"
        case "$1:$3" in
            192.0.2.10:upload) IPERF_TEST_RESULT='500|10|1|0.01' ;;
            192.0.2.10:download) IPERF_TEST_RESULT='800|10|1|0.01' ;;
            192.0.2.20:upload) IPERF_TEST_RESULT='600|10|1|0.01' ;;
            192.0.2.20:download) IPERF_TEST_RESULT='700|10|1|0.01' ;;
            *) fail "third peer was tested" ;;
        esac
    }
    probe_iperf_bandwidth
    assert_eq 600 "$DETECTED_UPLOAD_MBPS" "dual-peer upload keeps higher valid result"
    assert_eq 800 "$DETECTED_DOWNLOAD_MBPS" "dual-peer download keeps higher valid result"
    assert_eq high "$MEASUREMENT_CONFIDENCE" "consistent dual-peer result is high confidence"
    assert_eq 'public iperf3 IPv4 (P=4, O=2s, t=5s)' "$MEASUREMENT_SOURCE" \
        "live measurement records warm-up and sample durations"
    assert_eq 4 "$(wc -l < "$calls" | tr -d ' ')" "only two peers are tested in both directions"
)
(
    setup_probe_mocks
    calls="$TEMP_DIR/same-route-peer.calls"
    : > "$calls"
    rank_iperf_peers() {
        RANKED_IPERF_PEERS=$(printf '%s\n' \
            '10|one.example|192.0.2.10|A|ProviderA' \
            '20|two.example|198.51.100.20|B|ProviderB' \
            '30|three.example|192.0.2.30|C|ProviderC')
    }
    route_identity_for_target() {
        case "$1" in
            198.51.100.20) printf '%s\n' '3|eth1|198.51.100.1|198.51.100.2' ;;
            *) printf '%s\n' '2|eth0|192.0.2.1|192.0.2.2' ;;
        esac
    }
    run_iperf_test() {
        printf '%s:%s\n' "$1" "$3" >> "$calls"
        case "$1:$3" in
            192.0.2.10:upload) IPERF_TEST_RESULT='500|10|1|0.01' ;;
            192.0.2.10:download) IPERF_TEST_RESULT='800|10|1|0.01' ;;
            192.0.2.30:upload) IPERF_TEST_RESULT='650|10|1|0.01' ;;
            192.0.2.30:download) IPERF_TEST_RESULT='750|10|1|0.01' ;;
            *) fail "cross-route peer was tested" ;;
        esac
    }
    probe_iperf_bandwidth
    assert_eq 650 "$DETECTED_UPLOAD_MBPS" \
        "later same-route peer replaces skipped cross-route peer"
    assert_eq 800 "$DETECTED_DOWNLOAD_MBPS" \
        "cross-route peer does not affect selected download"
    assert_eq 4 "$(wc -l < "$calls" | tr -d ' ')" \
        "only two same-route peers are tested"
    if grep -Fq 'two.example' <<< "$MEASUREMENT_NODES"; then
        fail "cross-route peer was included in measurement metadata"
    fi
    assert_eq 1.1.1.1 "$MEASUREMENT_ROUTE_TARGET" \
        "automatic measurement binds the fixed default-route target"
)


(
    setup_probe_mocks
    rank_iperf_peers() {
        RANKED_IPERF_PEERS='10|one.example|192.0.2.10|A|ProviderA'
    }
    run_iperf_test() {
        case "$3" in
            upload) IPERF_TEST_RESULT='500|10|1|0.01' ;;
            download) IPERF_TEST_RESULT='800|10|1|0.01' ;;
        esac
    }
    probe_iperf_bandwidth
    assert_eq low "$MEASUREMENT_CONFIDENCE" "single-peer complete result is low confidence"
    grep -Fq 'only one public iperf3 peer' <<< "$MEASUREMENT_WARNINGS" ||
        fail "single-peer result did not warn"
    printf 'PASS: single-peer warning does not fail complete measurement\n'
)

(
    setup_probe_mocks
    rank_iperf_peers() {
        RANKED_IPERF_PEERS=$(printf '%s\n' \
            '10|one.example|192.0.2.10|A|ProviderA' \
            '20|two.example|192.0.2.20|B|ProviderB')
    }
    run_iperf_test() {
        case "$1:$3" in
            192.0.2.10:upload) IPERF_TEST_RESULT='500|10|1|0.01' ;;
            192.0.2.10:download) IPERF_TEST_RESULT='1000|10|1|0.01' ;;
            192.0.2.20:upload) IPERF_TEST_RESULT='800|10|1|0.01' ;;
            192.0.2.20:download) IPERF_TEST_RESULT='1200|10|1|0.01' ;;
        esac
    }
    probe_iperf_bandwidth
    assert_eq 800 "$DETECTED_UPLOAD_MBPS" "divergent upload keeps higher result"
    assert_eq low "$MEASUREMENT_CONFIDENCE" "over-30-percent difference lowers confidence only"
    grep -Fq 'upload peer results differ by more than 30%' <<< "$MEASUREMENT_WARNINGS" ||
        fail "over-30-percent result did not warn"
    printf 'PASS: over-30-percent peer difference remains successful\n'
)

(
    setup_probe_mocks
    rank_iperf_peers() {
        RANKED_IPERF_PEERS=$(printf '%s\n' \
            '10|one.example|192.0.2.10|A|ProviderA' \
            '20|two.example|192.0.2.20|B|ProviderB')
    }
    run_iperf_test() {
        if [[ "$1" == 192.0.2.20 ]]; then
            return 75
        fi
        case "$3" in
            upload) IPERF_TEST_RESULT='500|10|1|0.01' ;;
            download) IPERF_TEST_RESULT='800|10|1|0.01' ;;
        esac
    }
    probe_iperf_bandwidth
    grep -Fq 'traffic budget stopped additional' <<< "$MEASUREMENT_WARNINGS" ||
        fail "budget stop did not persist a warning"
    assert_eq 500 "$DETECTED_UPLOAD_MBPS" "budget stop preserves complete earlier upload"
    assert_eq 800 "$DETECTED_DOWNLOAD_MBPS" "budget stop preserves complete earlier download"
    printf 'PASS: budget stop remains successful with earlier complete input\n'
)

(
    setup_probe_mocks
    route_calls="$TEMP_DIR/route-change.calls"
    printf '%s\n' 0 > "$route_calls"
    rm -f "$MEASUREMENT_CACHE"
    rank_iperf_peers() {
        RANKED_IPERF_PEERS='10|one.example|192.0.2.10|A|ProviderA'
    }
    route_identity_for_target() {
        local count

        if [[ "$1" == "$MEASUREMENT_ROUTE_PROBE_TARGET" ]]; then
            printf '%s\n' '2|eth0|192.0.2.1|192.0.2.2'
            return 0
        fi
        count=$(<"$route_calls")
        ((count += 1))
        printf '%s\n' "$count" > "$route_calls"
        if (( count <= 3 )); then
            printf '%s\n' '2|eth0|192.0.2.1|192.0.2.2'
        else
            printf '%s\n' '3|eth1|198.51.100.1|198.51.100.2'
        fi
    }
    run_iperf_test() {
        case "$3" in
            upload) IPERF_TEST_RESULT='500|10|1|0.01' ;;
            download) IPERF_TEST_RESULT='800|10|1|0.01' ;;
        esac
    }
    assert_fail "route change before sample adoption rejects live measurement" \
        probe_bandwidth >/dev/null 2>&1
    [[ ! -e "$MEASUREMENT_CACHE" ]] || fail "route-changed result wrote a cache"
    assert_eq false "$MEASUREMENT_CACHE_PENDING" \
        "route-changed result leaves no pending cache"
)

(
    mkdir -p "$(dirname "$MEASUREMENT_CACHE")"
    current_epoch() { printf '%s\n' 2000000000; }
    CURRENT_IDENTITY='2|eth0|192.0.2.1|192.0.2.2'
    route_identity_for_target() { printf '%s\n' "$CURRENT_IDENTITY"; }
    seed_cache() {
        local saved_at="$1"
        cat > "$MEASUREMENT_CACHE" <<EOF
version=2
saved_at=$saved_at
measured_at=2033-05-18T03:33:20Z
download_mbps=1000
upload_mbps=500
source=public iperf3 IPv4
nodes=one.example;two.example
confidence=high
warnings=none
route_target=1.1.1.1
ifindex=2
iface=eth0
gateway=192.0.2.1
source_address=192.0.2.2
EOF
    }

    seed_cache $((2000000000 - CACHE_FRESH_MAX_AGE_SECONDS))
    assert_ok "seven-day cache is fresh" \
        load_measurement_cache "$CACHE_FRESH_MAX_AGE_SECONDS" fresh
    assert_eq 1000 "$DETECTED_DOWNLOAD_MBPS" "fresh cache restores download"
    sed -i 's/^version=2$/version=1/' "$MEASUREMENT_CACHE"
    assert_fail "legacy v1 cache is ignored" \
        load_measurement_cache "$CACHE_FRESH_MAX_AGE_SECONDS" fresh

    seed_cache $((2000000000 - 60))
    assert_ok "fresh mode accepts a sixty-second cache" \
        load_measurement_cache "$CACHE_FRESH_MAX_AGE_SECONDS" fresh
    grep -Fq '7-day route-bound cache' <<< "$MEASUREMENT_SOURCE" ||
        fail "fresh mode mislabeled a sixty-second cache"
    assert_eq '' "$MEASUREMENT_WARNINGS" \
        "fresh mode adds no live-measurement failure warning"
    assert_eq '7 天内同路由缓存（公共 IPv4 iperf3 测速）' \
        "$(format_measurement_source "$MEASUREMENT_SOURCE")" \
        "legacy English fresh cache source is formatted in Chinese"
    assert_eq '测速：复用 7 天内同路由缓存，不执行现场测速' \
        "$(format_cache_reuse_summary "$MEASUREMENT_SOURCE")" \
        "fresh cache explicitly skips live measurement"
    grep -Fqx 'source=public iperf3 IPv4' "$MEASUREMENT_CACHE" ||
        fail "display formatting rewrote the legacy English cache source"

    seed_cache $((2000000000 - 60))
    assert_ok "refresh fallback accepts a cache newer than seven days" \
        load_measurement_cache "$CACHE_STALE_MAX_AGE_SECONDS" fallback
    grep -Fq 'fresh cache fallback' <<< "$MEASUREMENT_SOURCE" ||
        fail "refresh fallback mislabeled a sixty-second cache"
    grep -Fq '同路由缓存回退（公共 IPv4 iperf3 测速）' \
        <<< "$(format_measurement_source "$MEASUREMENT_SOURCE")" ||
        fail "fresh cache fallback label was not formatted in Chinese"
    assert_eq low "$MEASUREMENT_CONFIDENCE" \
        "refresh fallback marks reused fresh cache low confidence"
    grep -Fq 'live public iperf3 measurement failed' <<< "$MEASUREMENT_WARNINGS" ||
        fail "refresh fresh-cache fallback omitted the live failure warning"

    seed_cache $((2000000000 - 8 * 24 * 60 * 60))
    assert_ok "refresh fallback accepts an eight-day cache" \
        load_measurement_cache "$CACHE_STALE_MAX_AGE_SECONDS" fallback
    grep -Fq 'same-route stale cache' <<< "$MEASUREMENT_SOURCE" ||
        fail "refresh fallback mislabeled an eight-day cache"
    grep -Fq '同路由过期缓存（公共 IPv4 iperf3 测速）' \
        <<< "$(format_measurement_source "$MEASUREMENT_SOURCE")" ||
        fail "stale cache label was not formatted in Chinese"
    assert_eq low "$MEASUREMENT_CONFIDENCE" \
        "refresh fallback marks an eight-day cache low confidence"
    grep -Fq 'live public iperf3 measurement failed' <<< "$MEASUREMENT_WARNINGS" ||
        fail "refresh stale-cache fallback omitted the live failure warning"

    seed_cache $((2000000000 - 8 * 24 * 60 * 60))
    assert_ok "stale mode accepts an eight-day cache" \
        load_measurement_cache "$CACHE_STALE_MAX_AGE_SECONDS" stale
    grep -Fq 'same-route stale cache' <<< "$MEASUREMENT_SOURCE" ||
        fail "stale mode mislabeled an eight-day cache"
    assert_eq low "$MEASUREMENT_CONFIDENCE" \
        "stale mode keeps an eight-day cache low confidence"
    grep -Fq 'live public iperf3 measurement failed' <<< "$MEASUREMENT_WARNINGS" ||
        fail "stale mode omitted the live failure warning"

    seed_cache $((2000000000 - CACHE_FRESH_MAX_AGE_SECONDS - 1))
    assert_fail "cache older than seven days is not fresh" \
        load_measurement_cache "$CACHE_FRESH_MAX_AGE_SECONDS" fresh
    assert_ok "same-route cache just older than seven days is stale fallback" \
        load_measurement_cache "$CACHE_STALE_MAX_AGE_SECONDS" stale
    assert_eq low "$MEASUREMENT_CONFIDENCE" "stale fallback lowers confidence"
    assert_ok "refresh fallback accepts a cache older than seven days" \
        load_measurement_cache "$CACHE_STALE_MAX_AGE_SECONDS" fallback


    seed_cache $((2000000000 - CACHE_STALE_MAX_AGE_SECONDS))
    assert_ok "thirty-day same-route cache is accepted" \
        load_measurement_cache "$CACHE_STALE_MAX_AGE_SECONDS" stale
    seed_cache $((2000000000 - CACHE_STALE_MAX_AGE_SECONDS - 1))
    assert_fail "cache older than thirty days is rejected" \
        load_measurement_cache "$CACHE_STALE_MAX_AGE_SECONDS" stale
    assert_fail "refresh fallback rejects cache older than thirty days" \
        load_measurement_cache "$CACHE_STALE_MAX_AGE_SECONDS" fallback

    seed_cache $((2000000000 - 60))
    CURRENT_IDENTITY='2|eth0|198.51.100.1|192.0.2.2'
    assert_fail "route-mismatched cache is rejected" \
        load_measurement_cache "$CACHE_FRESH_MAX_AGE_SECONDS" fresh

    CURRENT_IDENTITY='2|eth0|192.0.2.1|192.0.2.2'
    DETECTED_DOWNLOAD_MBPS=900
    DETECTED_UPLOAD_MBPS=450
    MEASUREMENT_EPOCH=2000000000
    MEASUREMENT_TIME=2033-05-18T03:33:20Z
    MEASUREMENT_SOURCE='public iperf3 IPv4'
    MEASUREMENT_NODES='one.example'
    MEASUREMENT_CONFIDENCE=low
    MEASUREMENT_WARNINGS='only one peer'
    MEASUREMENT_ROUTE_TARGET=1.1.1.1
    MEASUREMENT_ROUTE_IDENTITY="$CURRENT_IDENTITY"
    write_measurement_cache
    grep -Fqx 'ifindex=2' "$MEASUREMENT_CACHE" || fail "cache omits ifindex"
    grep -Fqx 'iface=eth0' "$MEASUREMENT_CACHE" || fail "cache omits interface"
    grep -Fqx 'gateway=192.0.2.1' "$MEASUREMENT_CACHE" || fail "cache omits gateway"
    grep -Fqx 'source_address=192.0.2.2' "$MEASUREMENT_CACHE" || fail "cache omits source address"
    printf 'PASS: cache persists complete route binding\n'
)

(
    : > "$NETWORK_DETAIL_LOG"
    MEASUREMENT_WARNINGS=""
    MEASUREMENT_CONFIDENCE=high
    add_measurement_warning "duplicate warning"
    add_measurement_warning "duplicate warning"
    assert_eq "duplicate warning" "$MEASUREMENT_WARNINGS" \
        "measurement warning metadata is deduplicated"
    assert_eq 1 "$(grep -Fc 'measurement warning: duplicate warning' \
        "$NETWORK_DETAIL_LOG")" \
        "measurement warning detail log is deduplicated"

    rm -f "$NETWORK_DETAIL_LOG"
    mkdir "$NETWORK_DETAIL_LOG"
    add_measurement_warning "unwritable detail log" ||
        fail "unwritable detail log changed warning result"
    rmdir "$NETWORK_DETAIL_LOG"
    : > "$NETWORK_DETAIL_LOG"
    assert_eq low "$MEASUREMENT_CONFIDENCE" \
        "unwritable detail log does not change measurement confidence"
)

(
    warn() { printf '%s\n' "$1"; }
    MEASUREMENT_WARNINGS='failed to persist the route-bound measurement cache; live public iperf3 measurement failed, reused same-route cache no older than 30 days; only one public iperf3 peer produced a usable result; upload has fewer than two valid peer samples; upload peer results differ by more than 30%, using the higher valid result; download has fewer than two valid peer samples; download peer results differ by more than 30%, using the higher valid result; traffic budget stopped additional public iperf3 tests'
    warning_output=$(show_measurement_warnings)
    for expected_warning in \
        '警告：无法保存同路由测速缓存' \
        '警告：现场公共 iperf3 测速失败，复用 30 天内同路由缓存' \
        '警告：仅一个公共 iperf3 节点返回可用结果' \
        '警告：上传有效节点样本少于两个' \
        '警告：上传节点结果差异超过 30%，采用较高有效值' \
        '警告：下载有效节点样本少于两个' \
        '警告：下载节点结果差异超过 30%，采用较高有效值' \
        '警告：流量预算已停止后续公共 iperf3 测试'; do
        assert_eq 1 "$(grep -Fxc "$expected_warning" <<< "$warning_output")" \
            "each mapped warning appears exactly once"
    done
    if grep -Eq 'peer results differ|failed to persist|fewer than two|traffic budget stopped' \
        <<< "$warning_output"; then
        fail "measurement warning display leaked internal English values"
    fi
    printf 'PASS: all measurement warning values use Chinese display mappings\n'
)

(
    warning_file="$TEMP_DIR/active-root-htb-warning.out"
    MEASUREMENT_WARNINGS=""
    MEASUREMENT_CONFIDENCE=high
    readlink() { return 1; }
    find() { return 0; }
    sysctl() {
        [[ "$1" == "-n" ]] || return 1
        case "$2" in
            net.ipv4.tcp_congestion_control) printf '%s\n' cubic ;;
            net.core.default_qdisc) printf '%s\n' fq ;;
            *) return 1 ;;
        esac
    }
    tc() { printf '%s\n' 'qdisc htb 1: root refcnt 2 default 10'; }
    detail() { return 0; }
    warn() { printf '%s\n' "$1"; }

    show_probe_environment eth0 > "$warning_file"
    show_measurement_warnings >> "$warning_file"
    warning_output=$(<"$warning_file")
    expected_warning='检测到活动的根 HTB 队列，当前限速可能导致测速结果偏低。'
    assert_eq 1 "$(grep -Fc "$expected_warning" <<< "$warning_output")" \
        "active root HTB warning is displayed once"
    grep -Fqx "警告：$expected_warning" <<< "$warning_output" ||
        fail "active root HTB warning lacks the unified prefix"
    assert_eq "$expected_warning" "$MEASUREMENT_WARNINGS" \
        "active root HTB warning remains persisted"
    assert_eq low "$MEASUREMENT_CONFIDENCE" \
        "active root HTB warning still lowers confidence"
)

if grep -Eq 'NETWORK_OPTIMIZE_TCSHAPE_CONFIG_FILE|/etc/tcshape[.]conf|tcshape HTB|tcshape off' \
    "$ROOT_DIR/modules/network-optimize.sh"; then
    fail "network-optimize retains tcshape-specific runtime coupling"
fi
grep -Fq '检测到活动的根 HTB 队列，当前限速可能导致测速结果偏低。' \
    "$ROOT_DIR/modules/network-optimize.sh" ||
    fail "localized active root HTB warning is missing"
assert_eq '检测到活动的根 HTB 队列，当前限速可能导致测速结果偏低。' \
    "$(format_measurement_warning '检测到 active root HTB，当前限速可能导致测速偏低。')" \
    "legacy active root HTB warning is formatted in Chinese"
if grep -Fq '检测到 active root HTB，当前限速可能导致测速偏低。' \
    <<< "$(format_measurement_warning '检测到 active root HTB，当前限速可能导致测速偏低。')"; then
    fail "warning output retains active root HTB wording"
fi
printf 'PASS: network-optimize localizes active root HTB diagnostics\n'

if grep -Eq '(^|[[:space:]])(return|exit)[[:space:]]+2([[:space:]]|$)' \
    "$ROOT_DIR/modules/network-optimize.sh"; then
    fail "network-optimize still returns exit code 2"
fi
printf 'PASS: network-optimize has no exit code 2 path\n'

(
    timeout_args="$TEMP_DIR/iperf-timeout.args"
    output_file="$TEMP_DIR/iperf-timeout.output"
    traffic_add_target() { return 0; }
    traffic_budget_reached() { return 1; }
    timeout() {
        builtin printf '%s\n' "$*" > "$timeout_args"
        return 124
    }
    rc=0
    run_iperf_runner "$output_file" 192.0.2.10 5201 \
        "$IPERF_DURATION" "$IPERF_PARALLEL" upload false || rc=$?
    assert_eq 124 "$rc" "iperf deadline status is preserved"
    assert_eq '--foreground --signal=TERM --kill-after=3s 22s iperf3 -4 -c 192.0.2.10 -p 5201 -O 2 -t 5 -P 4 -J' \
        "$(<"$timeout_args")" "iperf runner enforces deadline and kill grace"
)

(
    bash -c 'trap "" TERM; while :; do :; done' &
    stubborn_pid=$!
    terminate_recorded_pid "$stubborn_pid" 1
    if kill -0 "$stubborn_pid" 2>/dev/null; then
        kill -KILL "$stubborn_pid" 2>/dev/null || true
        fail "TERM-resistant child survived KILL escalation"
    fi
    printf 'PASS: TERM-resistant child is escalated to KILL\n'
)

signal_bin="$TEMP_DIR/signal-bin"
signal_helper="$TEMP_DIR/signal-helper.sh"
mkdir -p "$signal_bin"
cat > "$signal_bin/iperf3" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$$" > "$IPERF_PID_FILE"
trap 'exit 0' HUP INT
if [[ "${IPERF_IGNORE_TERM:-false}" == "true" ]]; then
    trap '' TERM
else
    trap 'exit 0' TERM
fi
while :; do sleep 0.05; done
EOF
chmod 0755 "$signal_bin/iperf3"
cat > "$signal_helper" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=/dev/null
source "$NETWORK_MODULE"
traffic_add_target() { return 0; }
traffic_budget_reached() { return 1; }
main() {
    local probe_dir

    probe_dir=$(mktemp -d)
    register_probe_temp_path "$probe_dir"
    run_iperf_test 192.0.2.10 5201 upload
}
run_network_command
EOF
chmod 0755 "$signal_helper"

for signal_case in HUP INT TERM; do
    case "$signal_case" in
        HUP) expected_rc=129 ;;
        INT) expected_rc=130 ;;
        TERM) expected_rc=143 ;;
    esac
    ignore_term=false
    [[ "$signal_case" != "TERM" ]] || ignore_term=true
    case_dir="$TEMP_DIR/signal-$signal_case"
    case_tmp="$case_dir/tmp"
    pid_file="$case_dir/iperf.pid"
    mkdir -p "$case_tmp"

    signal_rc=0
    PATH="$signal_bin:$PATH" \
        NETWORK_MODULE="$ROOT_DIR/modules/network-optimize.sh" \
        IPERF_PID_FILE="$pid_file" TMPDIR="$case_tmp" \
        IPERF_IGNORE_TERM="$ignore_term" \
        timeout --foreground --preserve-status --signal="$signal_case" \
        --kill-after=10s 1s bash "$signal_helper" >/dev/null 2>&1 || signal_rc=$?

    assert_eq "$expected_rc" "$signal_rc" \
        "$signal_case returns the conventional signal status"
    [[ -s "$pid_file" ]] || fail "$signal_case did not start fake iperf3"
    iperf_pid=$(<"$pid_file")
    if kill -0 "$iperf_pid" 2>/dev/null; then
        kill -KILL "$iperf_pid" 2>/dev/null || true
        fail "$signal_case left an orphan iperf3 process"
    fi
    if find "$case_tmp" -mindepth 1 -print -quit | grep -q .; then
        find "$case_tmp" -mindepth 1 -print >&2
        fail "$signal_case left temporary probe resources"
    fi
    printf 'PASS: %s cleans iperf3 and temporary probe resources\n' "$signal_case"
done

if grep -Eq '(^|[^[:alnum:]_])pkill([^[:alnum:]_]|$)' \
    "$ROOT_DIR/modules/network-optimize.sh"; then
    fail "probe cleanup uses broad pkill"
fi
printf 'PASS: probe cleanup targets recorded PIDs without broad pkill\n'

CURRENT_ROUTE="default via 192.0.2.1 dev eth0 proto dhcp src 192.0.2.10 metric 100 onlink"
LAST_ROUTE_ARGS=""
IP_FAIL=false
IP_QUERY_FAIL=false
ROUTE_MUTATION_CALLS=0

default_ipv4_route() { printf '%s\n' "$CURRENT_ROUTE"; }
ip() {
    case "$1 $2 $3" in
        '-4 route show')
            [[ "$IP_QUERY_FAIL" == "false" ]] || return 1
            printf '%s\n' "$CURRENT_ROUTE"
            ;;
        '-4 route replace')
            shift 3
            LAST_ROUTE_ARGS="$*"
            [[ "$IP_FAIL" == "false" ]] || return 1
            CURRENT_ROUTE="$*"
            ((ROUTE_MUTATION_CALLS += 1))
            ;;
        '-4 route del')
            shift 3
            LAST_ROUTE_ARGS="$*"
            [[ "$IP_FAIL" == "false" ]] || return 1
            CURRENT_ROUTE=""
            ((ROUTE_MUTATION_CALLS += 1))
            ;;
        *) return 1 ;;
    esac
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
grep -Fq '# network-optimize:initcwnd-hook:v2' "$INITCWND_ROUTE_HOOK" ||
    fail "initcwnd route hook lacks verifiable version marker"
marker_pattern="[[ -e \"$ROUTE_OWNED_MARKER\" ]] || exit 0"
marker_checks=$(grep -nF "$marker_pattern" "$INITCWND_ROUTE_HOOK")
assert_eq 2 "$(wc -l <<< "$marker_checks" | tr -d ' ')" \
    "initcwnd hook checks ownership at start and immediately before write"
final_marker_line=$(tail -n 1 <<< "$marker_checks" | cut -d: -f1)
route_write_line=$(grep -nF 'ip -4 route replace "${clean[@]}" initcwnd 32 initrwnd 32' \
    "$INITCWND_ROUTE_HOOK" | cut -d: -f1)
assert_eq "$((final_marker_line + 1))" "$route_write_line" \
    "final ownership check directly guards route replacement"
initcwnd_settings_owned || fail "ownership marker is not accepted as ownership evidence"
printf 'PASS: marker ownership evidence is accepted\n'
render_legacy_initcwnd_hook > "$INITCWND_ROUTE_HOOK"
is_managed_initcwnd_hook || fail "exact v1 hook was not accepted for migration"
write_initcwnd_hook
if grep -Fq '# network-optimize:initcwnd-hook:v1' "$INITCWND_ROUTE_HOOK"; then
    fail "legacy initcwnd hook was not upgraded"
fi
grep -Fq '# network-optimize:initcwnd-hook:v2' "$INITCWND_ROUTE_HOOK" ||
    fail "legacy initcwnd hook did not migrate to v2"
printf 'PASS: exact legacy hook migrates to final-guard version\n'
bash -n "$INITCWND_ROUTE_HOOK" || fail "generated initcwnd route hook has invalid syntax"
(
    install() { fail "hook write attempted to normalize existing parent directory"; }
    write_initcwnd_hook
)
printf 'PASS: initcwnd hook write preserves existing parent directory\n'
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

# Trusted legacy snapshots authorize cleanup only for the script's exact 32/32 values.
rm -f "$ROUTE_OWNED_MARKER" "$INITCWND_ROUTE_HOOK" \
    "$ROUTE_PREVIOUS_BACKUP" "$ROUTE_INITIAL_BACKUP" "$ROUTE_INITIAL_UNKNOWN"
snapshot_route='default via 192.0.2.1 dev eth0 proto dhcp src 192.0.2.10 metric 100 onlink'
printf '%s\n' "$snapshot_route" > "$ROUTE_INITIAL_BACKUP"
CURRENT_ROUTE="$snapshot_route initcwnd 32 initrwnd 32"
apply_initcwnd >/dev/null
assert_eq "$snapshot_route" "$CURRENT_ROUTE" \
    "initial snapshot allows exact 32/32 cleanup"
printf 'PASS: initial snapshot ownership evidence is accepted for 32/32\n'

rm -f "$ROUTE_INITIAL_BACKUP"
printf '%s\n' "$snapshot_route" > "$ROUTE_PREVIOUS_BACKUP"
CURRENT_ROUTE="$snapshot_route initcwnd 32 initrwnd 32"
apply_initcwnd >/dev/null
assert_eq "$snapshot_route" "$CURRENT_ROUTE" \
    "previous snapshot allows exact 32/32 cleanup"
printf 'PASS: previous snapshot ownership evidence is accepted for 32/32\n'

rm -f "$ROUTE_PREVIOUS_BACKUP"
printf '%s\n' "$snapshot_route" > "$ROUTE_INITIAL_BACKUP"
for third_party_windows in \
    'initcwnd 16 initrwnd 20' \
    'initcwnd 32 initrwnd 20' \
    'initcwnd 16 initrwnd 32'; do
    CURRENT_ROUTE="$snapshot_route $third_party_windows"
    LAST_ROUTE_ARGS="not-called"
    apply_initcwnd >/dev/null
    assert_eq "$snapshot_route $third_party_windows" "$CURRENT_ROUTE" \
        "snapshot preserves third-party $third_party_windows"
    assert_eq "not-called" "$LAST_ROUTE_ARGS" \
        "snapshot rejects ownership for $third_party_windows"
done
printf 'PASS: legacy snapshots reject non-32/32 route windows\n'

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

# Route backup distinguishes query failure from a confirmed absent default route.
printf '%s\n' 'old previous route' > "$ROUTE_PREVIOUS_BACKUP"
printf '%s\n' owned > "$ROUTE_PREVIOUS_OWNED"
rm -f "$ROUTE_PREVIOUS_ABSENT"
IP_QUERY_FAIL=true
if backup_default_route >/dev/null 2>&1; then
    fail "failed default-route query unexpectedly produced a backup"
fi
IP_QUERY_FAIL=false
assert_eq 'old previous route' "$(cat "$ROUTE_PREVIOUS_BACKUP")" \
    "route query failure preserves previous route backup"
[[ -e "$ROUTE_PREVIOUS_OWNED" ]] ||
    fail "route query failure removed previous ownership marker"
printf 'PASS: route query failure preserves previous route state\n'

rm -f "$ROUTE_INITIAL_BACKUP" "$ROUTE_INITIAL_ABSENT" "$ROUTE_INITIAL_UNKNOWN" \
    "$ROUTE_INITIAL_OWNED" "$ROUTE_OWNED_MARKER" "$INITCWND_ROUTE_HOOK"
CURRENT_ROUTE=""
backup_default_route
[[ -e "$ROUTE_PREVIOUS_ABSENT" ]] ||
    fail "confirmed absent route did not write previous absent marker"
[[ -e "$ROUTE_INITIAL_ABSENT" ]] ||
    fail "confirmed absent route did not write initial absent marker"
[[ ! -e "$ROUTE_PREVIOUS_BACKUP" && ! -e "$ROUTE_PREVIOUS_OWNED" ]] ||
    fail "confirmed absent route retained misleading previous route state"
printf 'PASS: confirmed absent route writes explicit absent markers\n'

CURRENT_ROUTE="default via 203.0.113.1 dev eth9 proto static src 203.0.113.2 metric 77 onlink initcwnd 16 initrwnd 20"
LAST_ROUTE_ARGS="not-called"
restore_default_route \
    "$ROUTE_PREVIOUS_BACKUP" "$ROUTE_PREVIOUS_OWNED" "$ROUTE_PREVIOUS_ABSENT"
assert_eq "default via 203.0.113.1 dev eth9 proto static src 203.0.113.2 metric 77 onlink initcwnd 16 initrwnd 20" \
    "$CURRENT_ROUTE" "absent restore preserves a later third-party default route"
assert_eq "not-called" "$LAST_ROUTE_ARGS" \
    "absent restore does not delete or replace a later route"
printf 'PASS: absent route restore is conservative\n'

CURRENT_ROUTE="default via 198.51.100.1 dev eth7 proto dhcp src 198.51.100.2 metric 55 onlink"
backup_default_route
assert_eq "$CURRENT_ROUTE" "$(cat "$ROUTE_PREVIOUS_BACKUP")" \
    "present default route is written atomically"
[[ ! -e "$ROUTE_PREVIOUS_ABSENT" ]] ||
    fail "present route backup retained absent marker"
printf 'PASS: present route backup replaces absent state\n'

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
eval "$(declare -f remove_initcwnd_hook | sed '1s/remove_initcwnd_hook/remove_initcwnd_hook_real/')"
remove_initcwnd_hook() { return 1; }
if apply_initcwnd >/dev/null 2>&1; then
    fail "failed managed hook deletion unexpectedly succeeded"
fi
eval "$(declare -f remove_initcwnd_hook_real | sed '1s/remove_initcwnd_hook_real/remove_initcwnd_hook/')"
unset -f remove_initcwnd_hook_real
assert_eq "default via 192.0.2.1 dev eth0 proto dhcp metric 100" \
    "$CURRENT_ROUTE" "hook deletion failure does not undo completed route cleanup"
[[ -e "$INITCWND_ROUTE_HOOK" ]] || fail "failed hook deletion removed the hook"
[[ ! -e "$ROUTE_OWNED_MARKER" ]] || fail "failed hook deletion left hook active"
rm -f "$INITCWND_ROUTE_HOOK"
printf 'PASS: managed hook deletion failure propagates without success\n'

# Marker creation and deletion failures must be observable to callers.
remove_initcwnd_ownership_marker
CURRENT_ROUTE="default via 192.0.2.1 dev eth0 proto dhcp metric 100"
INITCWND_ENABLED=true
(
    create_initcwnd_ownership_marker() { return 1; }
    if apply_initcwnd >/dev/null 2>&1; then
        fail "failed ownership marker creation unexpectedly succeeded"
    fi
    [[ ! -e "$ROUTE_OWNED_MARKER" ]] ||
        fail "failed ownership marker creation left a marker"
)
printf 'PASS: ownership marker creation failure propagates\n'

create_initcwnd_ownership_marker
CURRENT_ROUTE="default via 192.0.2.1 dev eth0 proto dhcp metric 100"
INITCWND_ENABLED=false
(
    remove_initcwnd_ownership_marker() { return 1; }
    if apply_initcwnd >/dev/null 2>&1; then
        fail "failed ownership marker deletion unexpectedly succeeded"
    fi
)
[[ -e "$ROUTE_OWNED_MARKER" ]] ||
    fail "failed ownership marker deletion removed the marker"
remove_initcwnd_ownership_marker
printf 'PASS: ownership marker deletion failure propagates\n'

# BBR persistence must use checked atomic writes even when called in a condition.
(
    atomic_write_file() { return 1; }
    if persist_bbr_module; then
        fail "failed BBR atomic write unexpectedly succeeded"
    fi
)
rm -f "$BBR_MODULES_FILE"
persist_bbr_module
assert_eq tcp_bbr "$(cat "$BBR_MODULES_FILE")" "persist BBR module atomically"
assert_eq 644 "$(stat -c '%a' "$BBR_MODULES_FILE")" "persist BBR module mode"

# Rollback collects every failed install recovery item in execution order.
(
    restore_default_route() { return 1; }
    restore_managed_file() { return 1; }
    apply_runtime_values_strict() { return 1; }
    if rollback_install; then
        fail "incomplete install rollback unexpectedly succeeded"
    fi
    assert_eq 'config modules runtime route hook' "${INSTALL_ROLLBACK_FAILED_ITEMS[*]}" \
        "summarize all install rollback failures"
)
printf 'PASS: install rollback reports all five failed state classes\n'

CURRENT_ROUTE="default via 192.0.2.1 dev eth0 proto dhcp metric 100"
create_initcwnd_ownership_marker
assert_eq 'drift|ownership marker exists but default route lacks initcwnd/initrwnd 32' \
    "$(detect_initcwnd_state)" "detect marker and route drift"
INITCWND_ENABLED=false
apply_initcwnd >/dev/null
assert_eq "default via 192.0.2.1 dev eth0 proto dhcp metric 100" "$CURRENT_ROUTE" \
    "stale marker cleanup preserves route without window fields"
[[ ! -e "$ROUTE_OWNED_MARKER" ]] || fail "stale marker cleanup retained ownership"
printf 'PASS: stale initcwnd marker does not trigger nounset\n'
create_initcwnd_ownership_marker
CURRENT_ROUTE="default via 192.0.2.1 dev eth0 proto dhcp metric 100 initcwnd 32 initrwnd 32"
assert_eq 'effective|owned default route has initcwnd/initrwnd 32' \
    "$(detect_initcwnd_state)" "detect owned initcwnd route as effective"

printf 'All network-optimize tests passed.\n'
