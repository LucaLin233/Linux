#!/usr/bin/env bash
set -euo pipefail

readonly ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }
assert_eq() {
    local expected="$1" actual="$2" name="$3"
    [[ "$actual" == "$expected" ]] || fail "$name: expected '$expected', got '$actual'"
    pass "$name"
}

cat > "$TEST_DIR/missing-value-case.sh" <<'CASE'
#!/usr/bin/env bash
set -uo pipefail
source "$TCSHAPE_SOURCE"
detect_iface() { printf 'detect_iface\n' >> "$ACTIVITY_LOG"; return 1; }
tc() { printf 'tc\n' >> "$ACTIVITY_LOG"; return 1; }
iperf3() { printf 'iperf3\n' >> "$ACTIVITY_LOG"; return 1; }
rc=0
cmd_scan "$1" || rc=$?
printf '%s|%s|%s|%s|%s|%s|%s\n' \
    "$PEER_PORT" "$IP_FAMILY" "$SCAN_ID" "$SCAN_IFACE" \
    "$SCAN_PEER" "$SCAN_CAP" "$SWEEP_ACTIVE" > "$STATE_SNAPSHOT"
exit "$rc"
CASE
chmod 700 "$TEST_DIR/missing-value-case.sh"

value_options=(
    --peer --port --nominal --from --to --step
    --dur --margin --cap --loss-threshold
)
for option in "${value_options[@]}"; do
    case_dir="$TEST_DIR/missing-${option#--}"
    mkdir -p "$case_dir"
    printf 'unchanged\n' > "$case_dir/config"
    : > "$case_dir/activity"
    rc=0
    timeout 1 env \
        TCSHAPE_SOURCE="$ROOT_DIR/tools/traffic-shape.sh" \
        TCSHAPE_TEST_MODE=1 \
        TCSHAPE_INSTALL_PATH="$case_dir/install" \
        TCSHAPE_STATE_DIR="$case_dir/state" \
        TCSHAPE_CONFIG_FILE="$case_dir/config" \
        TCSHAPE_SERVICE_FILE="$case_dir/service" \
        TCSHAPE_LOCK_FILE="$case_dir/lock" \
        ACTIVITY_LOG="$case_dir/activity" \
        STATE_SNAPSHOT="$case_dir/state.snapshot" \
        bash "$TEST_DIR/missing-value-case.sh" "$option" \
        > "$case_dir/output" 2>&1 || rc=$?
    [[ "$rc" != "124" ]] || fail "$option missing-value path exceeded one second"
    assert_eq 1 "$rc" "$option missing-value exit code"
    grep -Fq -- "$option 缺少值" "$case_dir/output" ||
        fail "$option missing-value error is not specific"
    [[ ! -s "$case_dir/activity" ]] || fail "$option called detect_iface, tc, or iperf3"
    [[ ! -e "$case_dir/state" ]] || fail "$option modified state directory"
    grep -Fxq 'unchanged' "$case_dir/config" || fail "$option modified config state"
    assert_eq '5201|-4|||||false' "$(cat "$case_dir/state.snapshot")" \
        "$option keeps global scan state"
done
pass "all value-taking scan options fail fast without side effects"

export TCSHAPE_TEST_MODE=1
export TCSHAPE_INSTALL_PATH="$TEST_DIR/installed-tcshape"
export TCSHAPE_STATE_DIR="$TEST_DIR/update-state"
export TCSHAPE_CONFIG_FILE="$TEST_DIR/update-config"
export TCSHAPE_SERVICE_FILE="$TEST_DIR/update-service"
export TCSHAPE_LOCK_FILE="$TEST_DIR/update-lock"
cp "$ROOT_DIR/tools/traffic-shape.sh" "$TCSHAPE_INSTALL_PATH"
# shellcheck source=../tools/traffic-shape.sh
source "$ROOT_DIR/tools/traffic-shape.sh"

UPDATE_CALLS="$TEST_DIR/update-calls"
: > "$UPDATE_CALLS"
curl() { printf 'curl\n' >> "$UPDATE_CALLS"; return 1; }
jq() { printf 'jq\n' >> "$UPDATE_CALLS"; return 1; }
install() { printf 'install\n' >> "$UPDATE_CALLS"; return 1; }
mv() { printf 'mv\n' >> "$UPDATE_CALLS"; return 1; }
install_before=$(sha256sum "$TCSHAPE_INSTALL_PATH" | awk '{print $1}')
rc=0
cmd_update </dev/null > "$TEST_DIR/update-no-yes.out" 2>&1 || rc=$?
assert_eq 1 "$rc" "non-interactive update without --yes is rejected"
grep -Fq '非交互更新必须显式使用 --yes' "$TEST_DIR/update-no-yes.out" ||
    fail "non-interactive update omitted explicit --yes guidance"
[[ ! -s "$UPDATE_CALLS" ]] || fail "non-interactive rejection entered download or install path"
assert_eq "$install_before" "$(sha256sum "$TCSHAPE_INSTALL_PATH" | awk '{print $1}')" \
    "non-interactive rejection preserves installed file"

rc=0
read_update_confirmation </dev/null > "$TEST_DIR/update-eof.out" 2>&1 || rc=$?
assert_eq 1 "$rc" "update confirmation EOF is rejected"
grep -Fq '无法读取更新确认，已取消' "$TEST_DIR/update-eof.out" ||
    fail "update EOF omitted rejection message"

: > "$UPDATE_CALLS"
rc=0
cmd_update --yes </dev/null > "$TEST_DIR/update-yes.out" 2>&1 || rc=$?
assert_eq 2 "$rc" "--yes reaches existing update network path"
grep -Fxq 'curl' "$UPDATE_CALLS" || fail "--yes did not enter update path"
if grep -Eq '^(install|mv)$' "$UPDATE_CALLS"; then
    fail "failed --yes network check unexpectedly reached overwrite path"
fi
pass "only explicit --yes permits unattended update"
unset -f curl jq install mv

cat > "$TEST_DIR/signal-case.sh" <<'CASE'
#!/usr/bin/env bash
set -uo pipefail
source "$TCSHAPE_SOURCE"
detect_iface() { printf '%s\n' eth0; }
check_external_conflicts() { return 0; }
traffic_mark() { return 0; }
show_current_shaping() { return 0; }
qdisc_save() { QSAVE_IFACE="$1"; QSAVE_KIND=fq; return 0; }
stop_iperf() { printf 'iperf\n' >> "$CLEANUP_LOG"; }
qdisc_restore() { printf 'qdisc\n' >> "$CLEANUP_LOG"; return 0; }
validate_peer_path() {
    printf 'ready\n' > "$READY_FILE"
    while :; do :; done
}
cmd_scan peer.example --from 10 --to 20 --step 10 --dur 1 --yes
CASE
chmod 700 "$TEST_DIR/signal-case.sh"

for signal_case in HUP:129 INT:130 TERM:143; do
    signal=${signal_case%%:*}
    expected=${signal_case#*:}
    case_dir="$TEST_DIR/signal-$signal"
    mkdir -p "$case_dir"
    : > "$case_dir/cleanup"
    rc=0
    timeout --preserve-status --signal="$signal" --kill-after=2 1 \
        env TCSHAPE_SOURCE="$ROOT_DIR/tools/traffic-shape.sh" \
        TCSHAPE_TEST_MODE=1 \
        TCSHAPE_INSTALL_PATH="$case_dir/install" \
        TCSHAPE_STATE_DIR="$case_dir/state" \
        TCSHAPE_CONFIG_FILE="$case_dir/config" \
        TCSHAPE_SERVICE_FILE="$case_dir/service" \
        TCSHAPE_LOCK_FILE="$case_dir/lock" \
        CLEANUP_LOG="$case_dir/cleanup" READY_FILE="$case_dir/ready" \
        bash "$TEST_DIR/signal-case.sh" > "$case_dir/output" 2>&1 || rc=$?
    assert_eq "$expected" "$rc" "$signal exit status"
    [[ -f "$case_dir/ready" ]] || fail "$signal arrived before Sweep signal traps"
    assert_eq 1 "$(grep -Fxc iperf "$case_dir/cleanup")" "$signal stops iperf"
    assert_eq 1 "$(grep -Fxc qdisc "$case_dir/cleanup")" "$signal restores qdisc"
done
pass "HUP, INT, and TERM preserve cleanup and conventional status"

printf 'All tcshape CLI safety tests passed.\n'
