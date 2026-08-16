#!/usr/bin/env bash
set -euo pipefail

readonly ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT
export NETWORK_OPTIMIZE_STATE_DIR="$TEMP_DIR/state"

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

assert_fail() {
    local name="$1"
    shift
    if "$@"; then
        fail "$name: command unexpectedly succeeded"
    fi
    printf 'PASS: %s\n' "$name"
}

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
    "parse sender receiver retransmission and CPU metrics"

TRAFFIC_TOUCHED=false
is_interactive_terminal() { return 1; }
traffic_mark() { TRAFFIC_TOUCHED=true; return 1; }
VERIFY_ASSUME_YES=false
assert_fail "non-interactive verify refuses without explicit confirmation" verify_impl
assert_eq false "$TRAFFIC_TOUCHED" "refused verify produces no measured traffic"

verify_dependencies_available() { return 0; }
traffic_mark() {
    PROBE_IFACE=eth0
    TRAFFIC_RX_START=0
    TRAFFIC_TX_START=0
}
rank_iperf_peers() {
    printf '%s\n' '12|peer.example|192.0.2.10|测试机房|TestProvider'
}
tcp_port_open() { [[ "$1:$2" == '192.0.2.10:5201' ]]; }
traffic_budget_reached() { return 1; }
traffic_report() { printf '%s\n' '流量：上传 1.00 GB / 下载 0 MB / 合计 1.00 GB'; }
run_verify_iperf() {
    case "$3" in
        1) VERIFY_RESULT='500|490|20|0.0100|10.0|5.0' ;;
        4) VERIFY_RESULT='900|880|30|0.0090|20.0|8.0' ;;
        *) return 1 ;;
    esac
}
TC_CALLS="$TEMP_DIR/tc.calls"
: > "$TC_CALLS"
tc() {
    printf '%s\n' "$*" >> "$TC_CALLS"
    [[ "$*" == 'qdisc show dev eth0' ]] || return 1
    printf '%s\n' 'qdisc fq 0: root refcnt 2 limit 10000p'
}
VERIFY_ASSUME_YES=true
verify_output=$(verify_impl)
grep -Fq '1 流：sender 500 Mbps / receiver 490 Mbps' <<< "$verify_output" ||
    fail "verify output misses single-stream metrics"
grep -Fq '4 流：sender 900 Mbps / receiver 880 Mbps' <<< "$verify_output" ||
    fail "verify output misses four-stream metrics"
grep -Fq '活动 qdisc: 生效（root fq）' <<< "$verify_output" ||
    fail "verify output misses active qdisc"
grep -Fq '最多尝试 3 组' <<< "$verify_output" ||
    fail "verify confirmation misses retry cap"
grep -Fq '重试会重复单流并产生额外流量' <<< "$verify_output" ||
    fail "verify confirmation misses partial-group traffic warning"
grep -Fq '最坏最多约 30 秒实际发送速率' <<< "$verify_output" ||
    fail "verify confirmation misses worst-case traffic estimate"
grep -Fq '结论：4 流 goodput 明显高于 1 流' <<< "$verify_output" ||
    fail "verify output misses comparison conclusion"
assert_eq 'qdisc show dev eth0' "$(cat "$TC_CALLS")" \
    "verify only reads qdisc state"

VERIFY_CALLS="$TEMP_DIR/verify.calls"
rank_iperf_peers() {
    printf '%s\n' \
        '12|first.example|192.0.2.10|首选机房|FirstProvider' \
        '24|second.example|192.0.2.20|备用机房|SecondProvider'
}
tcp_port_open() { return 0; }
run_verify_iperf() {
    printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$VERIFY_CALLS"
    case "$1:$2:$3" in
        192.0.2.10:5201:1) return 1 ;;
        192.0.2.10:5202:1) VERIFY_RESULT='510|500|21|0.0100|11.0|6.0' ;;
        192.0.2.10:5202:4) VERIFY_RESULT='910|890|31|0.0090|21.0|9.0' ;;
        *) return 1 ;;
    esac
}
: > "$VERIFY_CALLS"
verify_output=$(verify_impl 2>&1)
grep -Fq '对端: 首选机房/FirstProvider first.example [192.0.2.10]:5202' <<< "$verify_output" ||
    fail "verify did not select port with complete iperf result"
assert_eq $'192.0.2.10|5201|1\n192.0.2.10|5202|1\n192.0.2.10|5202|4' \
    "$(cat "$VERIFY_CALLS")" "busy first port rotates to successful port"

run_verify_iperf() {
    printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$VERIFY_CALLS"
    case "$1:$2:$3" in
        192.0.2.10:5201:1) VERIFY_RESULT='111|101|1|0.0100|1.0|1.0' ;;
        192.0.2.10:5201:4) return 1 ;;
        192.0.2.10:5202:1) VERIFY_RESULT='222|202|2|0.0200|2.0|2.0' ;;
        192.0.2.10:5202:4) VERIFY_RESULT='444|404|4|0.0400|4.0|4.0' ;;
        *) return 1 ;;
    esac
}
: > "$VERIFY_CALLS"
verify_output=$(verify_impl 2>&1)
grep -Fq '1 流：sender 222 Mbps / receiver 202 Mbps' <<< "$verify_output" ||
    fail "verify reused single-stream result from failed candidate"
grep -Fq '4 流：sender 444 Mbps / receiver 404 Mbps' <<< "$verify_output" ||
    fail "verify misses complete replacement candidate"
! grep -Fq '1 流：sender 111 Mbps' <<< "$verify_output" ||
    fail "verify mixed single and four-stream results across candidates"
printf 'PASS: verify never combines partial results across candidates\n'

run_verify_iperf() {
    printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$VERIFY_CALLS"
    VERIFY_RESULT='333|303|3|0.0300|3.0|3.0'
    [[ "$3" != 4 ]]
}
: > "$VERIFY_CALLS"
all_failed_log="$TEMP_DIR/all-failed.log"
assert_fail "verify fails when every candidate group is incomplete" \
    verify_impl > "$all_failed_log" 2>&1
assert_eq 6 "$(wc -l < "$VERIFY_CALLS")" \
    "verify caps retries at three complete group attempts"
grep -Fq '3 组公共 iperf3 候选均未得到完整的 1 流和 4 流结果' "$all_failed_log" ||
    fail "all-candidate failure does not explain missing complete group"

rank_iperf_peers() {
    printf '%s\n' '12|closed.example|192.0.2.30|关闭机房|ClosedProvider'
}
tcp_port_open() { return 1; }
run_verify_iperf() { fail "closed candidates unexpectedly started iperf"; }
all_closed_log="$TEMP_DIR/all-closed.log"
assert_fail "verify fails when no candidate port is reachable" \
    verify_impl > "$all_closed_log" 2>&1
grep -Fq '0 组公共 iperf3 候选均未得到完整的 1 流和 4 流结果' "$all_closed_log" ||
    fail "all-closed failure does not explain missing complete group"

assert_signal_cleanup() {
    local signal="$1" expected_rc="$2"
    local signal_name=${signal,,}
    local interrupt_dir="$TEMP_DIR/verify-$signal_name"
    local interrupt_pid_file="$TEMP_DIR/verify-$signal_name.pid"
    local interrupt_log="$TEMP_DIR/verify-$signal_name.log"
    local wrapper_pid child_pid rc=0

    verify_impl() {
        VERIFY_TEMP_DIR="$interrupt_dir"
        mkdir -p "$VERIFY_TEMP_DIR"
        sleep 30 &
        VERIFY_PID=$!
        printf '%s\n' "$VERIFY_PID" > "$interrupt_pid_file"
        wait "$VERIFY_PID"
    }

    run_verify_command > "$interrupt_log" 2>&1 &
    wrapper_pid=$!
    while [[ ! -s "$interrupt_pid_file" ]]; do sleep 0.01; done
    child_pid=$(cat "$interrupt_pid_file")
    kill -"$signal" "$wrapper_pid"
    for _ in {1..100}; do
        kill -0 "$wrapper_pid" 2>/dev/null || break
        sleep 0.01
    done
    kill -0 "$wrapper_pid" 2>/dev/null && fail "$signal verify did not exit promptly"
    wait "$wrapper_pid" 2>/dev/null || rc=$?
    assert_eq "$expected_rc" "$rc" "$signal verify returns signal-derived status"
    if kill -0 "$child_pid" 2>/dev/null; then
        ps -o pid,ppid,pgid,stat,cmd -p "$wrapper_pid,$child_pid" >&2 || true
        cat "$interrupt_log" >&2
        fail "$signal verify left child process running"
    fi
    [[ ! -e "$interrupt_dir" ]] || fail "$signal verify left temporary directory"
    printf 'PASS: %s verify cleans child process and temporary directory\n' "$signal"
}

assert_signal_cleanup HUP 129
assert_signal_cleanup INT 130
assert_signal_cleanup TERM 143

cleanup_dir="$TEMP_DIR/verify-cleanup"
verify_impl() {
    VERIFY_TEMP_DIR="$cleanup_dir"
    mkdir -p "$VERIFY_TEMP_DIR"
    return 1
}
assert_fail "verify propagates test failure" run_verify_command
[[ ! -e "$cleanup_dir" ]] || fail "failed verify did not clean temporary directory"
printf 'PASS: failed verify cleans temporary directory\n'

printf 'All network-optimize verify tests passed.\n'
