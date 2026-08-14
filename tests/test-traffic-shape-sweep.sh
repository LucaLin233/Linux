#!/usr/bin/env bash
set -euo pipefail

readonly ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

export TCSHAPE_TEST_MODE=1
export TCSHAPE_INSTALL_PATH="$ROOT_DIR/tools/traffic-shape.sh"
export TCSHAPE_STATE_DIR="$TEMP_DIR/state"
export TCSHAPE_CONFIG_FILE="$TEMP_DIR/tcshape.conf"
export TCSHAPE_SERVICE_FILE="$TEMP_DIR/tcshape.service"
export TCSHAPE_LOCK_FILE="$TEMP_DIR/tcshape.lock"

# shellcheck source=../tools/traffic-shape.sh
source "$ROOT_DIR/tools/traffic-shape.sh"

RESULT_QUEUE="$TEMP_DIR/results.queue"
SAVED_RESULT="$TEMP_DIR/saved.result"
VALIDATE_RC=0

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_eq() {
    local expected="$1" actual="$2" name="$3"
    [[ "$actual" == "$expected" ]] || fail "$name: expected '$expected', got '$actual'"
    printf 'PASS: %s\n' "$name"
}

detect_iface() { printf '%s\n' eth0; }
check_external_conflicts() { return 0; }
traffic_mark() { return 0; }
show_current_shaping() { return 0; }
qdisc_save() { QSAVE_IFACE="$1"; QSAVE_KIND=fq; }
qdisc_restore() { return 0; }
qdisc_set_fq() { return 0; }
apply_test_shaper() { return 0; }
traffic_report() { return 0; }
sleep() { return 0; }
validate_peer_path() { return "$VALIDATE_RC"; }

run_iperf() {
    local result
    result=$(sed -n '1p' "$RESULT_QUEUE")
    [[ -n "$result" ]] || return 1
    sed '1d' "$RESULT_QUEUE" > "$RESULT_QUEUE.next"
    mv -f "$RESULT_QUEUE.next" "$RESULT_QUEUE"
    case "$result" in
        RC:*) return "${result#RC:}" ;;
        *) printf '%s\n' "$result" ;;
    esac
}

save_sweep_result() {
    local status="$1"
    shift
    {
        printf 'STATUS=%s\n' "$status"
        printf '%s\n' "$@"
    } > "$SAVED_RESULT"
}

run_case() {
    local name="$1" expected_rc="$2" expected_status="$3"
    shift 3
    local rc
    rm -f "$SAVED_RESULT"
    if (cmd_scan "$@" > "$TEMP_DIR/case.out" 2>&1); then
        rc=0
    else
        rc=$?
    fi
    assert_eq "$expected_rc" "$rc" "$name exit code"
    assert_eq "$expected_status" "$(awk -F= '$1 == "STATUS" {print $2}' "$SAVED_RESULT")" "$name status"
}

normal_80='80 0 5201 80 80000000 1448 1 80000000 80000000'
normal_90='90 0 5201 90 90000000 1448 1 90000000 90000000'
normal_100='100 0 5201 100 100000000 1448 1 100000000 100000000'
spike_82='82 1000 5201 82 82000000 1448 1 82000000 82000000'
spike_90='90 1000 5201 90 90000000 1448 1 90000000 90000000'
shallow_100='100 138 5201 100 100000000 1448 1 100000000 100000000'
shallow_95='95 131 5201 95 95000000 1448 1 95000000 95000000'
shallow_71='71 98 5201 71 71000000 1448 1 71000000 71000000'

printf '%s\n' "$normal_100" > "$RESULT_QUEUE"
VALIDATE_RC=0
run_case "no policer" 0 NO_POLICER peer.example --nominal 100 --dur 1 --yes

printf '%s\n' 'RC:75' > "$RESULT_QUEUE"
run_case "traffic budget" 2 BUDGET_EXCEEDED peer.example --nominal 100 --dur 1 --yes

printf '%s\n' "$spike_90" > "$RESULT_QUEUE"
VALIDATE_RC=1
run_case "unsuitable peer" 2 PEER_UNSUITABLE peer.example --nominal 100 --dur 1 --yes
VALIDATE_RC=0

above_cap='120 1000 5201 120 120000000 1448 1 120000000 120000000'
printf '%s\n' "$above_cap" > "$RESULT_QUEUE"
run_case "above scan cap" 0 ABOVE_CAP peer.example --nominal 100 --cap 100 --dur 1 --yes

printf '%s\n' "$normal_80" "$spike_90" "$normal_90" "$normal_90" "$normal_100" > "$RESULT_QUEUE"
run_case "single noisy sample" 0 NO_KNEE peer.example --from 80 --to 100 --step 10 --dur 1 --yes

printf '%s\n' \
    "$normal_80" \
    "$spike_90" "$spike_90" "$normal_90" \
    "$spike_82" "$spike_82" "$normal_80" > "$RESULT_QUEUE"
run_case "two of three knee vote" 0 KNEE_FOUND peer.example --from 80 --to 100 --step 10 --dur 1 --yes
grep -Fqx 'RECOMMEND_MBIT=75' "$SAVED_RESULT" || fail "knee recommendation keeps the complete decision result"
printf 'PASS: knee recommendation uses last safe rate and margin\n'

printf '%s\n' \
    "$shallow_100" \
    "$shallow_95" "$shallow_95" "$shallow_95" \
    "$shallow_71" > "$RESULT_QUEUE"
run_case "stable baseline noise" 2 INCONCLUSIVE peer.example --nominal 100 --dur 1 --yes

aggregate='3000 10000 5201 120 3000000000 1448 1 3000000000 120000000'
printf '%s\n' "$spike_90" "$aggregate" > "$RESULT_QUEUE"
run_case "aggregate guard above cap" 0 ABOVE_CAP peer.example --nominal 3000 --cap 100 --dur 1 --yes

printf 'All tcshape Sweep decision tests passed.\n'
