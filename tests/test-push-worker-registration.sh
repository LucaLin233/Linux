#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly ROOT_DIR
readonly SCRIPT="$ROOT_DIR/tools/push.sh"
TEST_DIR=$(mktemp -d)
readonly TEST_DIR
CURRENT_FIXTURE_ROOT=""
trap 'rm -rf "$TEST_DIR"' EXIT

failure_diagnostics() {
    local root=${CURRENT_FIXTURE_ROOT:-} file pid
    [[ -n "$root" && -d "$root" ]] || return 0
    printf '%s\n' '=== worker registration diagnostics ===' >&2
    printf '%s\n' '--- coordinator/status ---' >&2
    for file in "$root"/capture/coordinator* "$root"/capture/watchdog* "$root"/capture/timeout*; do
        [[ -e "$file" || -L "$file" ]] || continue
        printf '[%s]\n' "$file" >&2; cat "$file" >&2 2>/dev/null || true
    done
    printf '%s\n' '--- registration/release/stages ---' >&2
    find "$root" \( -name 'worker-registration.*' -o -name '.worker-registration.*' \) -print 2>/dev/null | sort >&2 || true
    for file in "$root"/runtime/push-runtime.*/worker-registration.*; do
        [[ -e "$file" || -L "$file" ]] || continue
        printf '[%s]\n' "$file" >&2; cat "$file" >&2 2>/dev/null || true
    done
    printf '%s\n' '--- worker/session states ---' >&2
    for file in "$root"/runtime/push-runtime.*/worker-session.*.state; do
        [[ -e "$file" || -L "$file" ]] || continue
        printf '[%s]\n' "$file" >&2; cat "$file" >&2 2>/dev/null || true
    done
    printf '%s\n' '--- jobs ---' >&2; jobs -l >&2 || true
    printf '%s\n' '--- runtime tree ---' >&2
    find "$root/runtime" -mindepth 1 -maxdepth 4 -printf '%y %m %p\n' 2>/dev/null | sort >&2 || true
    printf '%s\n' '--- fake command calls ---' >&2
    for file in "$root"/capture/calls "$root"/capture/transfer-calls; do
        [[ -e "$file" ]] && { printf '[%s]\n' "$file" >&2; cat "$file" >&2 || true; }
    done
    printf '%s\n' '--- recorded proc identities ---' >&2
    for file in "$root"/capture/*.pid; do
        [[ -f "$file" && ! -L "$file" ]] || continue
        pid=$(<"$file")
        [[ "$pid" =~ ^[1-9][0-9]*$ && -r "/proc/$pid/stat" ]] && printf 'pid=%s stat=%s\n' "$pid" "$(<"/proc/$pid/stat")" >&2
    done
}
fail() { failure_diagnostics; printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected '$1', got '$2'"; pass "$3"; }
process_is_running() { local pid="$1" state; [[ -r "/proc/$pid/stat" ]] || return 1; state=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null) || return 1; [[ "$state" != Z ]]; }
test_process_identity_exists() {
    local pid="$1" start="$2"
    read_process_record "$pid" || return 1
    [[ "$PROC_UID" == "$EUID" && "$PROC_START" == "$start" ]]
}
wait_test_process_identity_gone() {
    local pid="$1" start="$2" _
    for _ in {1..100}; do test_process_identity_exists "$pid" "$start" || return 0; sleep 0.05; done
    return 1
}
wait_test_process_identity_present() {
    local pid="$1" start="$2" _
    for _ in {1..30}; do test_process_identity_exists "$pid" "$start" && return 0; [[ -r "/proc/$pid/stat" ]] || return 1; sleep 0.01; done
    return 1
}
wait_test_process_start() {
    local pid="$1" value="" _
    for _ in {1..100}; do value=$(get_process_start_time "$pid" 2>/dev/null || true); [[ -n "$value" ]] && { printf '%s\n' "$value"; return 0; }; sleep 0.005; done
    return 1
}

source_root="$TEST_DIR/source"; mkdir -m 0700 "$source_root"
source_result=$(env TMPDIR="$source_root" SCRIPT="$SCRIPT" bash -c '
set -euo pipefail
before=$(find "$TMPDIR" -mindepth 1 -print -quit)
source "$SCRIPT"
[[ -z "$TEMP_DIR" && -z "$SUCCESS_FILE" && -z "$FAILED_FILE" ]]
[[ "$before" == "$(find "$TMPDIR" -mindepth 1 -print -quit)" ]]
printf source-safe
')
assert_eq source-safe "$source_result" "source keeps zero runtime side effects"
# shellcheck source=../tools/push.sh
source "$SCRIPT"
trap 'rm -rf "$TEST_DIR"' EXIT

setup_fixture() {
    local root="$1"
    CURRENT_FIXTURE_ROOT=$root
    mkdir -m 0700 "$root" "$root/runtime" "$root/capture"
    TMPDIR="$root/runtime"; initialize_runtime
    # shellcheck disable=SC2034
    MAX_PARALLEL=2
    # shellcheck disable=SC2034
    MAX_RETRIES=1
    BATCH_WORKER_FAILED=false
    # shellcheck disable=SC2034
    BATCH_WORKER_ERROR=false
}
assert_no_registration_residue() {
    local root="$1"
    [[ -z "$(find "$root/runtime" \( -name 'worker-registration.*' -o -name '.worker-registration.*' -o -name 'worker-session.*.state' \) -print -quit)" ]] || fail "registration/session residue remains"
    (( ${#REGISTERING_WORKERS[@]} == 0 && ${#ACTIVE_WORKERS[@]} == 0 )) || fail "worker arrays remain"
    (( ${#WORKER_REGISTRATION_READY_FILES[@]} == 0 && ${#WORKER_REGISTRATION_RELEASE_FILES[@]} == 0 && ${#WORKER_REGISTRATION_STARTS[@]} == 0 && ${#WORKER_REGISTRATION_STAGE_FILES[@]} == 0 )) || fail "registration arrays remain"
}
test_watchdog_process() {
    local seconds="$1" marker="$2" target_pid="$3" timer=""
    trap '[[ -z "$timer" ]] || kill "$timer" 2>/dev/null || true; [[ -z "$timer" ]] || wait "$timer" 2>/dev/null || true; exit 0' HUP INT TERM
    sleep "$seconds" & timer=$!
    wait "$timer" 2>/dev/null || exit 0
    printf fired > "$marker"
    kill -KILL "$target_pid" 2>/dev/null || true
}

run_with_watchdog() {
    local name="$1" seconds="$2"; shift 2
    local marker="$TEST_DIR/watchdog-$name" pid watchdog rc=0
    "$@" & pid=$!
    test_watchdog_process "$seconds" "$marker" "$pid" & watchdog=$!
    wait "$pid" || rc=$?
    kill "$watchdog" 2>/dev/null || true; wait "$watchdog" 2>/dev/null || true
    [[ ! -e "$marker" ]] || fail "$name exceeded watchdog deadline"
    return "$rc"
}

root_cause_regression_case() (
    root="$TEST_DIR/root-cause"; setup_fixture "$root"
    GET_START_CALLS=0
    get_process_start_time() { ((GET_START_CALLS += 1)); return 1; }
    push_to_server() {
        local server="$1" lock_fd
        exec {lock_fd}>>"$root/capture/calls.lock"; flock -x "$lock_fd"
        printf '%s\n' "$server" >> "$root/capture/calls"; : > "$root/capture/ready.$server"
        flock -u "$lock_fd"; exec {lock_fd}>&-
        while [[ ! -e "$root/capture/release" ]]; do sleep 0.02; done
        return "$MANAGED_CLEANUP_FAILURE_STATUS"
    }
    (
        coordinator_status=0; deadline=$((SECONDS + 15))
        while (( SECONDS < deadline )); do
            if [[ -e "$root/capture/ready.one.example" && -e "$root/capture/ready.two.example" ]]; then : > "$root/capture/release"; break; fi
            sleep 0.02
        done
        if [[ ! -e "$root/capture/release" ]]; then : > "$root/capture/coordinator-timeout"; : > "$root/capture/release"; coordinator_status=1; fi
        while [[ ! -e "$root/capture/coordinator-stop" ]]; do sleep 0.02; done
        exit "$coordinator_status"
    ) & coordinator=$!
    rc=0; run_server_batch source destination one.example two.example three.example four.example || rc=$?
    : > "$root/capture/coordinator-stop"; coordinator_rc=0; wait "$coordinator" || coordinator_rc=$?
    assert_eq 0 "$coordinator_rc" "registration coordinator sees both first-slot workers"
    assert_eq "$MANAGED_CLEANUP_FAILURE_STATUS" "$rc" "cleanup failure remains lifecycle status"
    assert_eq 2 "$(wc -l < "$root/capture/calls")" "both first-slot workers enter fake transfer"
    grep -Fxq one.example "$root/capture/calls" || fail "one.example did not enter fake transfer"
    grep -Fxq two.example "$root/capture/calls" || fail "two.example did not enter fake transfer"
    grep -Eq 'three\.example|four\.example' "$root/capture/calls" && fail "registration failure scheduled later servers"
    assert_eq 0 "$GET_START_CALLS" "parent no longer depends on short get_process_start_time window"
    terminate_active_workers || true; cleanup_runtime; assert_no_registration_residue "$root"
    pass "deterministic registration regression avoids worker-one/worker-two deadlock"
)
run_with_watchdog root-cause 20 root_cause_regression_case

run_ready_failure_case() (
    kind="$1"; root="$TEST_DIR/ready-$kind"; setup_fixture "$root"
    # shellcheck disable=SC2034
    WORKER_REGISTRATION_TIMEOUT_TICKS=10
    push_to_server() { : > "$root/capture/transfer"; return 0; }
    case "$kind" in
        missing) worker_registration_phase_hook() { [[ "$1" != before-ready ]] || while :; do :; done; } ;;
        malformed) parent_worker_registration_hook() { [[ "$1" != ready-observed ]] || printf malformed > "$3"; } ;;
        symlink) parent_worker_registration_hook() { [[ "$1" != ready-observed ]] || { rm -f "$3"; ln -s "$root/other" "$3"; }; } ;;
        pid-mismatch) parent_worker_registration_hook() { [[ "$1" != ready-observed ]] || sed -i 's/^worker_pid=.*/worker_pid=999999/' "$3"; } ;;
        wrong-mode) parent_worker_registration_hook() { [[ "$1" != ready-observed ]] || chmod 0644 "$3"; } ;;
        duplicate-field) parent_worker_registration_hook() { [[ "$1" != ready-observed ]] || printf 'worker_pid=1\n' >> "$3"; } ;;
        unknown-field) parent_worker_registration_hook() { [[ "$1" != ready-observed ]] || printf 'unexpected=value\n' >> "$3"; } ;;
        illegal-number) parent_worker_registration_hook() { [[ "$1" != ready-observed ]] || sed -i 's/^worker_start=.*/worker_start=0/' "$3"; } ;;
        release-failure) publish_worker_registration_release() { return 1; } ;;
    esac
    rc=0; launch_worker one.example source destination 1 1 || rc=$?
    (( rc != 0 )) || fail "$kind registration failure unexpectedly succeeded"
    [[ ! -e "$root/capture/transfer" ]] || fail "$kind reached transfer before trusted handoff"
    cleanup_runtime || true; assert_no_registration_residue "$root"
    [[ -z "$(jobs -pr)" ]] || fail "$kind left worker job"
    pass "$kind registration failure is bounded and side-effect free"
)
for registration_failure in missing malformed symlink pid-mismatch wrong-mode duplicate-field unknown-field illegal-number release-failure; do run_ready_failure_case "$registration_failure"; done

(
    root="$TEST_DIR/release-replaced"; setup_fixture "$root"
    push_to_server() { : > "$root/capture/transfer"; return 0; }
    worker_registration_phase_hook() { [[ "$1" != ready-published ]] || while [[ ! -e "$root/capture/release-mutated" ]]; do sleep 0.02; done; }
    parent_worker_registration_hook() { [[ "$1" != release-published ]] || { chmod 0644 "$4"; : > "$root/capture/release-mutated"; }; }
    launch_worker one.example source destination 1 1
    rc=0; wait_for_all_workers || rc=$?
    assert_eq "$MANAGED_CLEANUP_FAILURE_STATUS" "$rc" "worker rejects replaced release before transfer"
    [[ ! -e "$root/capture/transfer" ]] || fail "replaced release reached transfer"
    cleanup_runtime || true; assert_no_registration_residue "$root"
    pass "release replacement is bounded and leaves no residue"
)
(
    root="$TEST_DIR/parent-disappeared"; setup_fixture "$root"
    push_to_server() { : > "$root/capture/transfer"; return 0; }
    sleep 300 & fake_parent=$!; read_process_record "$fake_parent"; fake_parent_start=$PROC_START
    registered_worker_entry "$fake_parent" "$fake_parent_start" one.example source destination 1 1 & worker=$!
    for _ in {1..200}; do [[ -e "$TEMP_DIR/worker-registration.$worker.ready" ]] && break; sleep 0.02; done
    [[ -e "$TEMP_DIR/worker-registration.$worker.ready" ]] || fail "worker did not publish ready before parent disappearance"
    kill -TERM "$fake_parent" 2>/dev/null || true; wait "$fake_parent" 2>/dev/null || true
    rc=0; wait "$worker" || rc=$?; (( rc != 0 )) || fail "worker accepted disappeared parent"
    [[ ! -e "$root/capture/transfer" ]] || fail "worker transferred after parent disappeared"
    cleanup_worker_registration_for_pid "$worker" || true; cleanup_runtime; assert_no_registration_residue "$root"
    pass "worker exits before transfer when parent identity disappears"
)

prune_identity_failure_case() (
    mode="$1"; root="$TEST_DIR/prune-$mode"; setup_fixture "$root"
    sleep 300 & worker=$!; read_process_record "$worker"; start=$PROC_START
    ACTIVE_WORKERS[$worker]=$start; ACTIVE_WORKER_STATE_FILES[$worker]="$TEMP_DIR/worker-session.$worker.state"; ACTIVE_WORKER_STATE_STARTS[$worker]=$start
    eval "$(declare -f process_identity_matches | sed '1s/process_identity_matches/original_process_identity_matches/')"
    eval "$(declare -f read_process_record_for_session_scan | sed '1s/read_process_record_for_session_scan/original_read_process_record_for_session_scan/')"
    failures=1; scan_failures=1; [[ "$mode" == repeated ]] && { failures=100; scan_failures=100; }
    process_identity_matches() { if [[ "$1" == "$worker" && "$failures" -gt 0 ]]; then ((failures -= 1)); return 1; fi; original_process_identity_matches "$@"; }
    read_process_record_for_session_scan() {
        if [[ "$1" == "$worker" && "$scan_failures" -gt 0 && -r "/proc/$worker/stat" ]]; then ((scan_failures -= 1)); return 1; fi
        original_read_process_record_for_session_scan "$@"
    }
    rc=0; prune_active_workers || rc=$?; (( rc != 0 )) || fail "$mode identity failure did not stop prune"
    [[ "$BATCH_WORKER_FAILED" == true ]] || fail "$mode identity failure did not set lifecycle barrier"
    process_is_running "$worker" || fail "$mode prune shortened active worker grace"
    [[ -n "${ACTIVE_WORKERS[$worker]:-}" ]] || fail "$mode prune discarded active worker evidence"
    rc=0; wait_for_worker_slot || rc=$?; assert_eq "$MANAGED_CLEANUP_FAILURE_STATUS" "$rc" "$mode identity failure propagates lifecycle status"
    terminate_active_workers || true
    process_is_running "$worker" && fail "$mode unified active cleanup left worker"
    cleanup_runtime || true; assert_no_registration_residue "$root"
    pass "$mode active identity failure defers termination to unified cleanup"
)
prune_identity_failure_case once
prune_identity_failure_case repeated
(
    root="$TEST_DIR/prune-cleanup-failure"; setup_fixture "$root"
    sleep 300 & worker=$!; read_process_record "$worker"; start=$PROC_START
    ACTIVE_WORKERS[$worker]=$start
    # shellcheck disable=SC2034
    ACTIVE_WORKER_STATE_FILES[$worker]="$TEMP_DIR/worker-session.$worker.state"
    # shellcheck disable=SC2034
    ACTIVE_WORKER_STATE_STARTS[$worker]=$start
    eval "$(declare -f process_identity_matches | sed '1s/process_identity_matches/original_process_identity_matches/')"
    eval "$(declare -f read_process_record_for_session_scan | sed '1s/read_process_record_for_session_scan/original_read_process_record_for_session_scan/')"
    process_identity_matches() { [[ "$1" != "$worker" ]] && original_process_identity_matches "$@"; }
    read_process_record_for_session_scan() { [[ "$1" != "$worker" || ! -r "/proc/$worker/stat" ]] && original_read_process_record_for_session_scan "$@"; }
    rc=0; wait_for_worker_slot || rc=$?
    assert_eq "$MANAGED_CLEANUP_FAILURE_STATUS" "$rc" "prune trust failure propagates 125"
    [[ -n "${ACTIVE_WORKERS[$worker]:-}" ]] || fail "prune trust failure discarded active worker evidence"
    eval "$(declare -f original_process_identity_matches | sed '1s/original_process_identity_matches/process_identity_matches/')"
    eval "$(declare -f original_read_process_record_for_session_scan | sed '1s/original_read_process_record_for_session_scan/read_process_record_for_session_scan/')"
    eval "$(declare -f cleanup_all_worker_registration_residue | sed '1s/cleanup_all_worker_registration_residue/original_cleanup_all_worker_registration_residue/')"
    cleanup_all_worker_registration_residue() { return 1; }
    rc=0; stop_batch_after_lifecycle_failure || rc=$?
    assert_eq "$MANAGED_CLEANUP_FAILURE_STATUS" "$rc" "active cleanup failure remains lifecycle status 125"
    eval "$(declare -f original_cleanup_all_worker_registration_residue | sed '1s/original_cleanup_all_worker_registration_residue/cleanup_all_worker_registration_residue/')"
    cleanup_runtime || true; assert_no_registration_residue "$root"
    pass "active cleanup failure preserves lifecycle status"
)
(
    root="$TEST_DIR/prune-exited"; setup_fixture "$root"
    sleep 0.1 & worker=$!; read_process_record "$worker"; start=$PROC_START
    ACTIVE_WORKERS[$worker]=$start
    # shellcheck disable=SC2034
    ACTIVE_WORKER_STATE_FILES[$worker]="$TEMP_DIR/worker-session.$worker.state"
    # shellcheck disable=SC2034
    ACTIVE_WORKER_STATE_STARTS[$worker]=$start
    sleep 0.2; prune_active_workers
    assert_eq 0 "${#ACTIVE_WORKERS[@]}" "exited worker is normally reaped"
    [[ "$BATCH_WORKER_FAILED" == false ]] || fail "normal exited worker set lifecycle barrier"
    cleanup_runtime; assert_no_registration_residue "$root"
    pass "normal exited worker accounting remains intact"
)

cat > "$TEST_DIR/registration-signal-child.sh" <<'CHILD'
#!/usr/bin/env bash
set -euo pipefail
script="$1" root="$2" phase="$3"
mkdir -p -m 0700 "$root/runtime" "$root/capture"
export TMPDIR="$root/runtime"
source "$script"
initialize_runtime; install_runtime_traps
WORKER_REGISTRATION_TIMEOUT_TICKS=200
push_to_server() { printf 'push pid=%s root=%s\n' "$BASHPID" "$root" >> "$root/capture/transfer-calls"; : > "$root/capture/transfer"; return 0; }
worker_registration_phase_hook() { local current="$1"; [[ "$phase" == "$current" ]] || return 0; : > "$root/capture/phase"; while :; do :; done; }
parent_worker_registration_hook() { local current="$1"; [[ "$phase" == "$current" ]] || return 0; : > "$root/capture/phase"; while :; do :; done; }
launch_worker one.example source destination 1 1
wait_for_all_workers
if [[ "$phase" == normal ]]; then [[ -e "$root/capture/transfer" ]] || { printf 'normal transfer missing\n' >&2; jobs -l >&2 || true; exit 91; }; fi
cleanup_runtime
CHILD
chmod 0700 "$TEST_DIR/registration-signal-child.sh"
run_registration_signal_case() {
    local phase="$1" signal_name="$2" expected="$3" root retry_root
    local pid watchdog unrelated rc=0
    root="$TEST_DIR/signal-$phase-$signal_name"; CURRENT_FIXTURE_ROOT=$root
    sleep 60 & unrelated=$!
    env --default-signal=HUP,INT,TERM bash "$TEST_DIR/registration-signal-child.sh" "$SCRIPT" "$root" "$phase" > "$root.log" 2>&1 & pid=$!
    for _ in {1..300}; do [[ -e "$root/capture/phase" ]] && break; sleep 0.05; done
    [[ -e "$root/capture/phase" ]] || { cat "$root.log"; kill "$pid" "$unrelated" 2>/dev/null || true; fail "$phase/$signal_name did not reach registration phase"; }
    test_watchdog_process 30 "$root.watchdog" "$pid" & watchdog=$!
    kill "-$signal_name" "$pid"; wait "$pid" || rc=$?
    kill "$watchdog" 2>/dev/null || true; wait "$watchdog" 2>/dev/null || true
    [[ ! -e "$root.watchdog" ]] || fail "$phase/$signal_name exceeded watchdog"
    assert_eq "$expected" "$rc" "$phase registration $signal_name status"
    [[ ! -e "$root/capture/transfer" ]] || fail "$phase/$signal_name reached transfer"
    [[ -z "$(find "$root/runtime" -mindepth 1 -print -quit 2>/dev/null)" ]] || fail "$phase/$signal_name left runtime state"
    kill -0 "$unrelated" 2>/dev/null || fail "$phase/$signal_name killed unrelated process"
    kill "$unrelated" 2>/dev/null || true; wait "$unrelated" 2>/dev/null || true
    retry_root="${root}-retry"
    env bash "$TEST_DIR/registration-signal-child.sh" "$SCRIPT" "$retry_root" normal > "$retry_root.log" 2>&1
    if [[ ! -e "$retry_root/capture/transfer" ]]; then cat "$retry_root.log" >&2 2>/dev/null || true; fail "$phase/$signal_name retry did not transfer"; fi
    [[ -z "$(find "$retry_root/runtime" -mindepth 1 -print -quit 2>/dev/null)" ]] || fail "$phase/$signal_name retry left runtime"
    pass "$phase/$signal_name leaves registration clean and retryable"
}
for registration_phase in before-ready accepted-before-release release-validated; do
    run_registration_signal_case "$registration_phase" HUP 129
    run_registration_signal_case "$registration_phase" INT 130
    run_registration_signal_case "$registration_phase" TERM 143
done

(
    sleep 60 & reused_pid=$!
    replacement_start=$(get_process_start_time "$reused_pid")
    expected_start=$((replacement_start + 1))
    eval "$(declare -f collect_owned_session_records | sed '1s/collect_owned_session_records/original_collect_owned_session_records/')"
    collect_owned_session_records() { fail "PID reuse path attempted to inspect or terminate replacement session"; }
    terminate_managed_session "$reused_pid" "$expected_start" "$reused_pid" "$reused_pid"
    test_process_identity_exists "$reused_pid" "$replacement_start" || fail "PID reuse path touched replacement process"
    kill -TERM "$reused_pid"; wait "$reused_pid" 2>/dev/null || true
    pass "managed leader PID reuse is treated as original session gone"
)

cat > "$TEST_DIR/failed-reap-child.sh" <<'CHILD'
#!/usr/bin/env bash
set -euo pipefail
script="$1" root="$2" mode="$3"
mkdir -p -m 0700 "$root/runtime" "$root/capture"
export TMPDIR="$root/runtime"
source "$script"
initialize_runtime
setsid bash -c 'trap "" HUP INT TERM; while :; do :; done' & leader=$!
for _ in {1..100}; do
    leader_start=$(get_process_start_time "$leader" 2>/dev/null || true)
    leader_pgid=$(get_process_group_id "$leader" 2>/dev/null || true)
    leader_sid=$(get_process_session_id "$leader" 2>/dev/null || true)
    [[ -n "$leader_start" && "$leader_pgid" == "$leader" && "$leader_sid" == "$leader" ]] && break
    sleep 0.01
done
[[ -n "$leader_start" && "$leader_pgid" == "$leader" && "$leader_sid" == "$leader" ]] || exit 90
printf '%s\n%s\n%s\n%s\n' "$leader" "$leader_start" "$leader_pgid" "$leader_sid" > "$root/capture/leader"
WORKER_TRANSFER_PID=$leader
WORKER_TRANSFER_START=$leader_start
WORKER_TRANSFER_PGID=$leader_pgid
WORKER_TRANSFER_SID=$leader_sid
publish_worker_session_state active
state_file=$WORKER_SESSION_STATE_FILE
eval "$(declare -f terminate_managed_session | sed '1s/terminate_managed_session/original_terminate_managed_session/')"
terminate_managed_session() { return 1; }
start_ns=$(date +%s%N)
rc=0
terminate_worker_transfer || rc=$?
elapsed_ns=$(( $(date +%s%N) - start_ns ))
[[ "$rc" != 0 && "$elapsed_ns" -lt 2000000000 ]] || exit 91
[[ "$WORKER_TRANSFER_PID" == "$leader" && "$WORKER_TRANSFER_START" == "$leader_start" &&
    "$WORKER_TRANSFER_PGID" == "$leader_pgid" && "$WORKER_TRANSFER_SID" == "$leader_sid" &&
    "$WORKER_TRANSFER_CLEANUP_FAILED" == true ]] || exit 92
read_worker_session_state "$state_file"
[[ "$SESSION_STATE" == cleanup_failed ]] || exit 93
next_rc=0
run_managed_command "$TEMP_DIR/forbidden-next-command" true || next_rc=$?
[[ "$next_rc" == "$MANAGED_CLEANUP_FAILURE_STATUS" && ! -e "$TEMP_DIR/forbidden-next-command" ]] || exit 94
printf 'rc=%s\nelapsed_ns=%s\nnext_rc=%s\nstate_file=%s\n' "$rc" "$elapsed_ns" "$next_rc" "$state_file" > "$root/capture/result"
: > "$root/capture/returned"
if [[ "$mode" == hold ]]; then
    while [[ ! -e "$root/capture/release-worker" ]]; do sleep 0.01; done
    for _ in {1..400}; do
        reap_status=0
        reap_direct_managed_leader "$leader" "$leader_start" "$leader_pgid" "$leader_sid" || reap_status=$?
        case "$reap_status" in
            0|"$MANAGED_PROCESS_REUSED_STATUS") break ;;
            *) sleep 0.01 ;;
        esac
    done
    (( reap_status == 0 || reap_status == MANAGED_PROCESS_REUSED_STATUS )) || exit 95
    : > "$root/capture/reaped"
    for _ in {1..400}; do
        [[ ! -e "$state_file" && ! -L "$state_file" ]] && break
        sleep 0.01
    done
    [[ ! -e "$state_file" && ! -L "$state_file" ]] || exit 96
    terminate_managed_session() { original_terminate_managed_session "$@"; }
else
    for _ in {1..400}; do [[ -e "$root/capture/release-recovery" ]] && break; sleep 0.01; done
    [[ -e "$root/capture/release-recovery" ]] || exit 97
    terminate_managed_session() { original_terminate_managed_session "$@"; }
fi
cleanup_runtime
CHILD
chmod 0700 "$TEST_DIR/failed-reap-child.sh"

run_failed_reap_case() {
    local run="$1" root="$TEST_DIR/failed-reap-$1" child watchdog rc=0
    bash "$TEST_DIR/failed-reap-child.sh" "$SCRIPT" "$root" recover > "$root.log" 2>&1 & child=$!
    test_watchdog_process 3 "$root.watchdog-fired" "$child" & watchdog=$!
    for _ in {1..80}; do [[ -e "$root/capture/returned" ]] && break; sleep 0.05; done
    [[ -e "$root/capture/returned" ]] || { cat "$root.log" >&2 || true; fail "failed reap run $run did not return before watchdog"; }
    kill -TERM "$watchdog" 2>/dev/null || true; wait "$watchdog" 2>/dev/null || true
    [[ ! -e "$root.watchdog-fired" ]] || fail "failed reap run $run fired watchdog"
    : > "$root/capture/release-recovery"
    wait "$child" || rc=$?
    [[ "$rc" == 0 ]] || cat "$root.log" >&2 2>/dev/null || true
    assert_eq 0 "$rc" "failed managed-session reap run $run returns bounded"
    [[ -z "$(find "$root/runtime" -name 'worker-session.*.state' -print -quit 2>/dev/null)" ]] || fail "failed reap run $run left worker-session state"
}
for failed_reap_run in $(seq 1 20); do run_failed_reap_case "$failed_reap_run"; done
pass "failed managed-session reap remains bounded for 20 deterministic runs"

(
    trap - EXIT HUP INT TERM
    root="$TEST_DIR/failed-reap-parent"; mkdir -p "$root/capture"; chmod 0700 "$root" "$root/capture"
    bash "$TEST_DIR/failed-reap-child.sh" "$SCRIPT" "$root" hold > "$root.log" 2>&1 & worker=$!
    worker_start=$(wait_test_process_start "$worker")
    for _ in {1..80}; do [[ -e "$root/capture/returned" ]] && break; sleep 0.05; done
    [[ -e "$root/capture/returned" ]] || fail "parent fallback worker did not return bounded"
    mapfile -t leader_fields < "$root/capture/leader"
    leader=${leader_fields[0]}; leader_start=${leader_fields[1]}; leader_sid=${leader_fields[3]}
    state_file=$(sed -n 's/^state_file=//p' "$root/capture/result")
    TEMP_DIR=$(dirname "$state_file")
    ACTIVE_WORKERS=(); ACTIVE_WORKER_STATE_FILES=(); ACTIVE_WORKER_STATE_STARTS=()
    BATCH_WORKER_FAILED=false
    # shellcheck disable=SC2034  # Consumed by sourced worker accounting.
    BATCH_WORKER_ERROR=false
    MAX_PARALLEL=1
    ACTIVE_WORKERS[$worker]=$worker_start
    ACTIVE_WORKER_STATE_FILES[$worker]=$state_file
    ACTIVE_WORKER_STATE_STARTS[$worker]=$worker_start
    : > "$root/capture/release-worker"
    wait_for_all_workers
    assert_eq 0 "${#ACTIVE_WORKERS[@]}" "scheduler parent fallback reaps active worker"
    assert_eq 0 "${#ACTIVE_WORKER_STATE_FILES[@]}" "scheduler parent fallback removes cleanup_failed state"
    wait_test_process_identity_gone "$leader" "$leader_start" || fail "parent fallback left same-identity leader"
    session_pids=(); session_starts=(); session_ppids=(); session_pgids=(); session_states=()
    collect_owned_session_records "$leader_sid" session_pids session_starts session_ppids session_pgids session_states
    assert_eq 0 "${#session_pids[@]}" "parent fallback leaves no managed SID member"
    [[ ! -e "$state_file" && -e "$root/capture/reaped" ]] || fail "parent fallback evidence incomplete"
    pass "parent fallback cleans a live failed session without PPID 1 zombie"
)

(
    trap - EXIT HUP INT TERM
    sleep 60 & replacement=$!
    replacement_start=$(wait_test_process_start "$replacement")
    wait_called=false
    wait() { wait_called=true; return 1; }
    reap_status=0
    reap_direct_managed_leader "$replacement" "$((replacement_start + 1))" "$replacement" "$replacement" || reap_status=$?
    assert_eq "$MANAGED_PROCESS_REUSED_STATUS" "$reap_status" "direct leader PID reuse returns safe status"
    [[ "$wait_called" == false ]] || fail "direct leader PID reuse waited on replacement process"
    test_process_identity_exists "$replacement" "$replacement_start" || fail "direct leader PID reuse touched replacement process"
    kill -TERM "$replacement"; builtin wait "$replacement" 2>/dev/null || true
    pass "direct leader PID reuse sends no signal and performs no wait"
)

(
    trap - EXIT HUP INT TERM
    leader=424242; leader_start=777777; wait_called=false; after_wait=false
    # shellcheck disable=SC2034  # Test double fills caller arrays through namerefs.
    collect_owned_session_records() {
        local -n pids_ref="$2" starts_ref="$3" ppids_ref="$4" pgids_ref="$5" states_ref="$6"
        pids_ref=(); starts_ref=(); ppids_ref=(); pgids_ref=(); states_ref=()
        [[ "$after_wait" == false ]] || return 0
        pids_ref=("$leader"); starts_ref[$leader]=$leader_start; ppids_ref[$leader]=$BASHPID
        pgids_ref[$leader]=$leader; states_ref[$leader]=Z
    }
    read_process_record_for_session_scan() {
        [[ "$after_wait" == false ]] || return 2
        PROC_UID=$EUID; PROC_PPID=$BASHPID; PROC_START=$leader_start
        PROC_STATE=Z; PROC_PGID=$leader; PROC_SID=$leader
    }
    wait() { wait_called=true; after_wait=true; return 0; }
    reap_direct_managed_leader "$leader" "$leader_start" "$leader" "$leader"
    [[ "$wait_called" == true ]] || fail "same-identity leader zombie was not wait/reaped"
    pass "same-identity direct leader zombie is immediately wait/reaped"
)

cat > "$TEST_DIR/hard-timeout-cleanup-failure-child.sh" <<'CHILD'
#!/usr/bin/env bash
set -euo pipefail
script="$1" root="$2"
mkdir -p -m 0700 "$root/runtime" "$root/capture"
export TMPDIR="$root/runtime"
source "$script"
initialize_runtime
TOTAL_TIMEOUT=1
TIMEOUT_KILL_AFTER=1
eval "$(declare -f terminate_managed_session | sed '1s/terminate_managed_session/original_terminate_managed_session/')"
failures=1
terminate_managed_session() {
    if (( failures > 0 )); then ((failures -= 1)); return 1; fi
    original_terminate_managed_session "$@"
}
start_ns=$(date +%s%N)
rc=0
run_managed_command "$TEMP_DIR/hard-output" timeout 1 bash -c \
    'trap "" HUP INT TERM; bash -c '\''trap "" HUP INT TERM; while :; do kill -STOP "$$"; done'\'' & wait "$!"' || rc=$?
elapsed_ns=$(( $(date +%s%N) - start_ns ))
[[ "$rc" == "$MANAGED_CLEANUP_FAILURE_STATUS" && "$elapsed_ns" -lt 5000000000 ]] || exit 90
[[ "$WORKER_TRANSFER_CLEANUP_FAILED" == true && -n "$WORKER_TRANSFER_PID" && -f "$WORKER_SESSION_STATE_FILE" ]] || exit 91
read_worker_session_state "$WORKER_SESSION_STATE_FILE"
[[ "$SESSION_STATE" == cleanup_failed ]] || exit 92
next_rc=0
run_managed_command "$TEMP_DIR/forbidden-hard-next" true || next_rc=$?
[[ "$next_rc" == "$MANAGED_CLEANUP_FAILURE_STATUS" && ! -e "$TEMP_DIR/forbidden-hard-next" ]] || exit 93
printf 'rc=%s\nelapsed_ns=%s\nnext_rc=%s\n' "$rc" "$elapsed_ns" "$next_rc" > "$root/capture/result"
: > "$root/capture/returned"
terminate_worker_transfer
cleanup_runtime
CHILD
chmod 0700 "$TEST_DIR/hard-timeout-cleanup-failure-child.sh"
(
    trap - EXIT HUP INT TERM
    root="$TEST_DIR/hard-timeout-cleanup-failure"
    bash "$TEST_DIR/hard-timeout-cleanup-failure-child.sh" "$SCRIPT" "$root" > "$root.log" 2>&1 & child=$!
    test_watchdog_process 5 "$root.watchdog-fired" "$child" & watchdog=$!
    for _ in {1..120}; do [[ -e "$root/capture/returned" ]] && break; sleep 0.05; done
    [[ -e "$root/capture/returned" ]] || { cat "$root.log" >&2 || true; fail "hard timeout cleanup failure did not return bounded"; }
    kill -TERM "$watchdog" 2>/dev/null || true; wait "$watchdog" 2>/dev/null || true
    [[ ! -e "$root.watchdog-fired" ]] || fail "hard timeout cleanup failure fired watchdog"
    rc=0; wait "$child" || rc=$?
    assert_eq 0 "$rc" "hard timeout cleanup failure recovers fixture"
    grep -Fxq "rc=$MANAGED_CLEANUP_FAILURE_STATUS" "$root/capture/result" || fail "hard timeout cleanup failure did not propagate 125"
    grep -Fxq "next_rc=$MANAGED_CLEANUP_FAILURE_STATUS" "$root/capture/result" || fail "hard timeout cleanup failure allowed next command"
    [[ -z "$(find "$root/runtime" -mindepth 1 -print -quit 2>/dev/null)" ]] || fail "hard timeout cleanup failure left runtime"
    pass "hard timeout cleanup failure is bounded and blocks subsequent command"
)

write_test_worker_session_manifest() {
    local file="$1" state="$2" worker_pid="$3" worker_start="$4" leader_pid="$5" leader_start="$6" pgid="$7" sid="$8"
    printf 'version=1\nstate=%s\nworker_pid=%s\nworker_start=%s\nleader_pid=%s\nleader_start=%s\npgid=%s\nsid=%s\n' \
        "$state" "$worker_pid" "$worker_start" "$leader_pid" "$leader_start" "$pgid" "$sid" > "$file"
    chmod 0600 "$file"
}

(
    root="$TEST_DIR/session-dual-publish"; setup_fixture "$root"
    : > "$root/capture/terminate-calls"
    terminate_managed_session() { printf '%s:%s:%s:%s:%s\n' "$@" >> "$root/capture/terminate-calls"; return 0; }
    worker_session_state_publish_hook() {
        local phase="$1" state="$2"
        if [[ "$phase" == stage-ready && "$state" == cleanup_failed ]]; then
            : > "$root/capture/stage.$BASHPID"
            while [[ ! -e "$root/capture/release" ]]; do sleep 0.01; done
        elif [[ "$phase" == after-rename && "$state" == cleanup_failed ]]; then
            : > "$root/capture/renamed.$BASHPID"
        fi
    }
    session_publisher() {
        WORKER_TRANSFER_PID=$BASHPID; WORKER_TRANSFER_START=11
        WORKER_TRANSFER_PGID=$BASHPID; WORKER_TRANSFER_SID=$BASHPID
        publish_worker_session_state active
        publish_worker_session_state cleanup_failed
    }
    session_publisher & first=$!; session_publisher & second=$!
    first_start=$(get_process_start_time "$first"); second_start=$(get_process_start_time "$second")
    ACTIVE_WORKERS[$first]=$first_start; ACTIVE_WORKERS[$second]=$second_start
    ACTIVE_WORKER_STATE_FILES[$first]="$TEMP_DIR/worker-session.$first.state"
    ACTIVE_WORKER_STATE_FILES[$second]="$TEMP_DIR/worker-session.$second.state"
    ACTIVE_WORKER_STATE_STARTS[$first]=$first_start; ACTIVE_WORKER_STATE_STARTS[$second]=$second_start
    for _ in {1..300}; do [[ -e "$root/capture/stage.$first" && -e "$root/capture/stage.$second" ]] && break; sleep 0.01; done
    [[ -e "$root/capture/stage.$first" && -e "$root/capture/stage.$second" ]] || fail "dual publishers did not reach pre-rename hook"
    cleanup_published_worker_sessions
    assert_eq 2 "${#ACTIVE_WORKER_STATE_FILES[@]}" "fallback waits while both workers can still publish"
    : > "$root/capture/release"
    wait "$first"; wait "$second"
    [[ -e "$root/capture/renamed.$first" && -e "$root/capture/renamed.$second" ]] || fail "dual publishers did not complete rename"
    prune_active_workers
    cleanup_published_worker_sessions
    assert_eq 2 "$(wc -l < "$root/capture/terminate-calls")" "fallback processes both stable cleanup_failed manifests"
    assert_eq 0 "${#ACTIVE_WORKER_STATE_FILES[@]}" "dual fallback clears both state maps"
    assert_eq 0 "${#ACTIVE_WORKER_STATE_STARTS[@]}" "dual fallback clears both state identities"
    runtime_has_published_worker_state && fail "dual fallback left worker session state"
    cleanup_runtime; assert_no_registration_residue "$root"
    pass "dual worker state transitions stabilize after wait/reap"
)

run_transient_state_case() (
    kind="$1"; root="$TEST_DIR/session-transient-$kind"; setup_fixture "$root"
    worker=11111; start=22222; file="$TEMP_DIR/worker-session.$worker.state"
    write_test_worker_session_manifest "$file" cleanup_failed "$worker" "$start" 33333 44444 33333 33333
    ACTIVE_WORKER_STATE_FILES[$worker]=$file; ACTIVE_WORKER_STATE_STARTS[$worker]=$start
    : > "$root/capture/terminate-calls"
    terminate_managed_session() { printf 'call\n' >> "$root/capture/terminate-calls"; return 0; }
    failures=2
    case "$kind" in
        inode)
            worker_session_state_read_hook() {
                if [[ "$1" == after-open && "$failures" -gt 0 ]]; then
                    next="$file.next.$failures"
                    write_test_worker_session_manifest "$next" cleanup_failed "$worker" "$start" 33333 44444 33333 33333
                    mv -fT "$next" "$file"; ((failures -= 1))
                fi
            }
            ;;
        open)
            eval "$(declare -f open_worker_session_state_fd | sed '1s/open_worker_session_state_fd/original_open_worker_session_state_fd/')"
            open_worker_session_state_fd() {
                if (( failures > 0 )); then ((failures -= 1)); return "$WORKER_SESSION_STATE_TRANSIENT_STATUS"; fi
                original_open_worker_session_state_fd "$@"
            }
            ;;
        stat)
            eval "$(declare -f worker_session_state_path_metadata | sed '1s/worker_session_state_path_metadata/original_worker_session_state_path_metadata/')"
            worker_session_state_path_metadata() {
                if (( failures > 0 )); then ((failures -= 1)); return "$WORKER_SESSION_STATE_TRANSIENT_STATUS"; fi
                original_worker_session_state_path_metadata "$@"
            }
            ;;
    esac
    cleanup_published_worker_sessions
    assert_eq 0 "${#ACTIVE_WORKER_STATE_FILES[@]}" "$kind transient failure clears state map after stabilization"
    assert_eq 1 "$(wc -l < "$root/capture/terminate-calls")" "$kind transient failure performs one trusted session cleanup"
    [[ ! -e "$file" ]] || fail "$kind transient failure left state file"
    cleanup_runtime; pass "$kind transient worker state failure is bounded and recoverable"
)
run_transient_state_case inode
run_transient_state_case open
run_transient_state_case stat

(
    root="$TEST_DIR/session-not-reaped"; setup_fixture "$root"
    sleep 300 & worker=$!; start=$(get_process_start_time "$worker")
    file="$TEMP_DIR/worker-session.$worker.state"
    write_test_worker_session_manifest "$file" cleanup_failed "$worker" "$start" 33333 44444 33333 33333
    ACTIVE_WORKERS[$worker]=$start; ACTIVE_WORKER_STATE_FILES[$worker]=$file; ACTIVE_WORKER_STATE_STARTS[$worker]=$start
    : > "$root/capture/terminate-calls"
    terminate_managed_session() { printf call >> "$root/capture/terminate-calls"; return 0; }
    cleanup_published_worker_sessions
    assert_eq 1 "${#ACTIVE_WORKER_STATE_FILES[@]}" "fallback retains state while worker is not reaped"
    assert_eq 0 "$(wc -c < "$root/capture/terminate-calls")" "fallback performs no session cleanup before reap"
    kill -TERM "$worker"; wait "$worker" 2>/dev/null || true; prune_active_workers
    cleanup_published_worker_sessions
    assert_eq 0 "${#ACTIVE_WORKER_STATE_FILES[@]}" "fallback succeeds after worker reap"
    cleanup_runtime; pass "worker reap gates final fallback"
)

run_permanent_state_case() (
    kind="$1"; root="$TEST_DIR/session-permanent-$kind"; setup_fixture "$root"
    worker=11111; start=22222; file="$TEMP_DIR/worker-session.$worker.state"
    write_test_worker_session_manifest "$file" cleanup_failed "$worker" "$start" 33333 44444 33333 33333
    ACTIVE_WORKER_STATE_FILES[$worker]=$file; ACTIVE_WORKER_STATE_STARTS[$worker]=$start
    : > "$root/capture/terminate-calls"
    terminate_managed_session() { printf call >> "$root/capture/terminate-calls"; return 0; }
    case "$kind" in
        symlink) mv "$file" "$file.real"; ln -s "$file.real" "$file" ;;
        wrong-mode) chmod 0644 "$file" ;;
        wrong-owner|wrong-gid)
            stat() {
                last=${!#}
                if [[ "$last" == "$file" ]]; then
                    raw=$(command stat -Lc '%d:%i:%u:%g:%a:%s' -- "$file")
                    IFS=: read -r dev ino owner gid mode size <<< "$raw"
                    [[ "$kind" == wrong-owner ]] && owner=$((EUID + 1)) || gid=$((gid + 1))
                    printf '%s:%s:%s:%s:%s:%s\n' "$dev" "$ino" "$owner" "$gid" "$mode" "$size"
                else command stat "$@"; fi
            }
            ;;
        malformed) printf malformed > "$file" ;;
        duplicate) printf 'worker_pid=11111\n' >> "$file" ;;
        unknown) printf 'unexpected=value\n' >> "$file" ;;
        missing) sed -i '/^sid=/d' "$file" ;;
        pid-mismatch) sed -i 's/^worker_pid=.*/worker_pid=99999/' "$file" ;;
        stable-tamper)
            worker_session_state_read_hook() { [[ "$1" != after-open ]] || printf tampered > "$file"; }
            ;;
    esac
    rc=0; cleanup_published_worker_sessions || rc=$?
    (( rc != 0 )) || fail "$kind permanent state unexpectedly succeeded"
    assert_eq 1 "${#ACTIVE_WORKER_STATE_FILES[@]}" "$kind permanent state preserves map evidence"
    assert_eq 0 "$(wc -c < "$root/capture/terminate-calls")" "$kind permanent state executes no session cleanup"
    [[ -e "$file" || -L "$file" ]] || fail "$kind permanent state deleted evidence"
    unset 'ACTIVE_WORKER_STATE_FILES[$worker]' 'ACTIVE_WORKER_STATE_STARTS[$worker]'
    command rm -f -- "$file" "$file.real" 2>/dev/null || true
    cleanup_runtime; pass "$kind permanent worker state remains rejected"
)
for permanent_state in symlink wrong-mode wrong-owner wrong-gid malformed duplicate unknown missing pid-mismatch stable-tamper; do
    run_permanent_state_case "$permanent_state"
done

run_parallel_fallback_iteration() (
    run="$1"; root="$TEST_DIR/session-parallel-$run"; setup_fixture "$root"
    # shellcheck disable=SC2034  # consumed by sourced run_server_batch
    MAX_PARALLEL=2
    push_to_server() {
        local server="$1" lock_fd
        exec {lock_fd}>>"$root/capture/calls.lock"; flock -x "$lock_fd"
        printf '%s\n' "$server" >> "$root/capture/calls"; : > "$root/capture/ready.$server"
        flock -u "$lock_fd"; exec {lock_fd}>&-
        while [[ ! -e "$root/capture/release" ]]; do sleep 0.01; done
        # shellcheck disable=SC2034  # consumed by sourced state publisher
        WORKER_TRANSFER_PID=$BASHPID
        # shellcheck disable=SC2034  # consumed by sourced state publisher
        WORKER_TRANSFER_START=11
        # shellcheck disable=SC2034  # consumed by sourced state publisher
        WORKER_TRANSFER_PGID=$BASHPID
        # shellcheck disable=SC2034  # consumed by sourced state publisher
        WORKER_TRANSFER_SID=$BASHPID
        publish_worker_session_state cleanup_failed
        return "$MANAGED_CLEANUP_FAILURE_STATUS"
    }
    terminate_managed_session() { return 0; }
    (
        deadline=$((SECONDS + 15)); status=0
        while (( SECONDS < deadline )); do
            if [[ -e "$root/capture/ready.one.example" && -e "$root/capture/ready.two.example" ]]; then : > "$root/capture/release"; break; fi
            sleep 0.01
        done
        [[ -e "$root/capture/release" ]] || { : > "$root/capture/coordinator-timeout"; : > "$root/capture/release"; status=1; }
        while [[ ! -e "$root/capture/stop" ]]; do sleep 0.01; done
        exit "$status"
    ) & coordinator=$!
    rc=0; run_server_batch source destination one.example two.example three.example four.example || rc=$?
    : > "$root/capture/stop"; coordinator_rc=0; wait "$coordinator" || coordinator_rc=$?
    assert_eq 0 "$coordinator_rc" "parallel fallback run $run coordinator releases both workers"
    assert_eq "$MANAGED_CLEANUP_FAILURE_STATUS" "$rc" "parallel fallback run $run returns lifecycle status"
    assert_eq 2 "$(wc -l < "$root/capture/calls")" "parallel fallback run $run starts only first two workers"
    assert_eq 0 "${#ACTIVE_WORKERS[@]}" "parallel fallback run $run reaps active workers"
    assert_eq 0 "${#ACTIVE_WORKER_STATE_FILES[@]}" "parallel fallback run $run clears state maps"
    assert_eq 0 "${#ACTIVE_WORKER_STATE_STARTS[@]}" "parallel fallback run $run clears state identities"
    [[ ! -e "$root/capture/ready.three.example" && ! -e "$root/capture/ready.four.example" ]] || fail "parallel fallback run $run launched later worker"
    runtime_has_published_worker_state && fail "parallel fallback run $run left session state"
    reset_batch_lifecycle_barrier; cleanup_runtime; assert_no_registration_residue "$root"
)
parallel_fallback_runs=${PUSH_WORKER_REGISTRATION_PARALLEL_STRESS:-1}
for parallel_run in $(seq 1 "$parallel_fallback_runs"); do run_parallel_fallback_iteration "$parallel_run"; done
pass "parallel fallback completed $parallel_fallback_runs deterministic run(s)"

write_active_grace_fixture() {
    local root="$1"
    mkdir -m 0700 "$root" "$root/bin" "$root/runtime" "$root/ssh" "$root/pids"
    printf source > "$root/source"
    cat > "$root/config.conf" <<EOF
AUTH_METHOD="password"
PASSWORD_METHOD="inline"
PASSWORD="fixture-secret"
DEFAULT_PORT=22
DEFAULT_USER="root"
MAX_PARALLEL=1
CONNECTION_TIMEOUT=5
TOTAL_TIMEOUT=60
MAX_RETRIES=1
RETRY_DELAY=1
DELETE_EXTRA="false"
ALLOW_DELETE_EXTRA="false"
RSYNC_ARCHIVE="true"
RSYNC_COMPRESS="false"
SERVERS=("root@example.com")
declare -A TASKS=()
ENABLE_LOGGING="false"
STRICT_HOST_KEY_CHECKING="accept-new"
USER_KNOWN_HOSTS_FILE="$root/ssh/known_hosts"
ALLOW_INSECURE_HOST_KEY_STORAGE="false"
EOF
    chmod 0600 "$root/config.conf"
    cat > "$root/bin/timeout" <<'EOF'
#!/usr/bin/env bash
trap '' HUP INT TERM
printf '%s\n' "$$" > "$PID_DIR/timeout.pid"
[[ ${1:-} == --kill-after=* ]] && shift
shift
"$@" &
wait "$!"
EOF
    cat > "$root/bin/sshpass" <<'EOF'
#!/usr/bin/env bash
trap '' HUP INT TERM
printf '%s\n' "$$" > "$PID_DIR/sshpass.pid"
[[ ${1:-} == -e ]] && shift
"$@" &
wait "$!"
EOF
    cat > "$root/bin/rsync" <<'EOF'
#!/usr/bin/env bash
trap '' HUP INT TERM
set -m
printf '%s\n' "$$" > "$PID_DIR/rsync.pid"
ssh fake-target &
wait "$!"
EOF
    cat > "$root/bin/ssh" <<'EOF'
#!/usr/bin/env bash
trap '' HUP INT TERM
printf '%s\n' "$$" > "$PID_DIR/ssh.pid"
if [[ "${STATE_PUBLISH_MODE:-active}" == cleanup ]]; then
    while [[ ! -e "$STATE_CLEANUP_RELEASE" ]]; do sleep 0.01; done
    exit 0
fi
sleep 300 &
printf '%s\n' "$!" > "$PID_DIR/leaf.pid"
wait "$!"
EOF
    chmod 0700 "$root/bin"/*
}
cat > "$TEST_DIR/active-grace-child.sh" <<'CHILD'
#!/usr/bin/env bash
set -euo pipefail
script="$1"
shift
source "$script"
worker_after_session_cleanup_hook() {
    : > "$ACTIVE_GRACE_STARTED"
    sleep 3.2
    : > "$ACTIVE_GRACE_FINISHED"
}
main "$@"
CHILD
chmod 0700 "$TEST_DIR/active-grace-child.sh"
run_active_grace_signal_case() {
    local signal_name="$1" expected="$2" root
    local main_pid watchdog unrelated rc=0 state_file file pid
    root="$TEST_DIR/active-grace-$signal_name"
    CURRENT_FIXTURE_ROOT=$root
    write_active_grace_fixture "$root"
    sleep 60 & unrelated=$!
    (
        cd "$root"
        exec env --default-signal=HUP,INT,TERM PATH="$root/bin:$PATH" TMPDIR="$root/runtime" PID_DIR="$root/pids" \
            ACTIVE_GRACE_STARTED="$root/cleanup-started" ACTIVE_GRACE_FINISHED="$root/cleanup-finished" \
            bash "$TEST_DIR/active-grace-child.sh" "$SCRIPT" "$root/source" /remote/path
    ) > "$root/output.log" 2>&1 &
    main_pid=$!
    for _ in {1..400}; do
        state_file=$(find "$root/runtime" -name 'worker-session.*.state' -print -quit 2>/dev/null || true)
        [[ -n "$state_file" && -f "$root/pids/leaf.pid" ]] && break
        sleep 0.05
    done
    if [[ -z "${state_file:-}" || ! -f "$root/pids/leaf.pid" ]]; then
        cat "$root/output.log" >&2 || true
        kill "$main_pid" "$unrelated" 2>/dev/null || true
        fail "$signal_name active grace fixture did not enter managed session"
    fi
    test_watchdog_process 20 "$root/watchdog-timeout" "$main_pid" & watchdog=$!
    kill "-$signal_name" "$main_pid"
    wait "$main_pid" || rc=$?
    kill "$watchdog" 2>/dev/null || true; wait "$watchdog" 2>/dev/null || true
    [[ ! -e "$root/watchdog-timeout" ]] || fail "$signal_name active grace exceeded watchdog"
    assert_eq "$expected" "$rc" "$signal_name active worker preserves main signal status"
    [[ -e "$root/cleanup-started" && -e "$root/cleanup-finished" ]] || { cat "$root/output.log" >&2 || true; fail "$signal_name active worker was killed before cleanup hook completed"; }
    for file in "$root/pids"/*.pid; do
        [[ -f "$file" ]] || continue
        pid=$(<"$file")
        process_is_running "$pid" && fail "$signal_name active grace left $(basename "$file") pid=$pid"
    done
    [[ -z "$(find "$root/runtime" -mindepth 1 -print -quit 2>/dev/null)" ]] || fail "$signal_name active grace left runtime state"
    kill -0 "$unrelated" 2>/dev/null || fail "$signal_name active grace killed unrelated process"
    kill "$unrelated" 2>/dev/null || true; wait "$unrelated" 2>/dev/null || true
    pass "$signal_name active worker receives full managed-session cleanup grace"
}
run_active_grace_signal_case HUP 129
run_active_grace_signal_case INT 130
run_active_grace_signal_case TERM 143

cat > "$TEST_DIR/live-cleanup-failure-child.sh" <<'CHILD'
#!/usr/bin/env bash
set -euo pipefail
script="$1"
shift
source "$script"
main_owner=$BASHPID
eval "$(declare -f terminate_managed_session | sed '1s/terminate_managed_session/original_terminate_managed_session/')"
terminate_managed_session() {
    if [[ "$BASHPID" != "$main_owner" ]]; then return 1; fi
    original_terminate_managed_session "$@"
}
main "$@"
CHILD
chmod 0700 "$TEST_DIR/live-cleanup-failure-child.sh"

run_live_cleanup_failure_signal_case() (
    trap - EXIT HUP INT TERM
    local signal_name="$1" expected="$2" root main_pid main_start state_file="" saved_temp
    local worker_pid="" worker_start="" leader_pid="" leader_start="" managed_sid="" watchdog="" unrelated="" unrelated_start="" rc=0
    cleanup_live_failure_fixture() {
        [[ -z "$worker_pid" || -z "$worker_start" ]] || { test_process_identity_exists "$worker_pid" "$worker_start" && kill -KILL "$worker_pid" 2>/dev/null || true; }
        [[ -z "$main_pid" || -z "$main_start" ]] || { test_process_identity_exists "$main_pid" "$main_start" && kill -KILL "$main_pid" 2>/dev/null || true; }
        [[ -z "$unrelated" || -z "$unrelated_start" ]] || { test_process_identity_exists "$unrelated" "$unrelated_start" && kill -TERM "$unrelated" 2>/dev/null || true; }
        [[ -z "$main_pid" ]] || wait "$main_pid" 2>/dev/null || true
        [[ -z "$watchdog" ]] || { kill -TERM "$watchdog" 2>/dev/null || true; wait "$watchdog" 2>/dev/null || true; }
        [[ -z "$unrelated" ]] || wait "$unrelated" 2>/dev/null || true
    }
    trap cleanup_live_failure_fixture EXIT
    local -a session_pids=()
    # shellcheck disable=SC2034  # Filled by collect_owned_session_records namerefs.
    local -A session_starts=() session_ppids=() session_pgids=() session_states=()
    root="$TEST_DIR/live-cleanup-failure-$signal_name"; CURRENT_FIXTURE_ROOT=$root
    write_active_grace_fixture "$root"
    sleep 60 & unrelated=$!; unrelated_start=$(wait_test_process_start "$unrelated")
    (
        cd "$root"
        exec env --default-signal=HUP,INT,TERM PATH="$root/bin:$PATH" TMPDIR="$root/runtime" PID_DIR="$root/pids" \
            bash "$TEST_DIR/live-cleanup-failure-child.sh" "$SCRIPT" "$root/source" /remote/path
    ) > "$root/output.log" 2>&1 &
    main_pid=$!; main_start=$(wait_test_process_start "$main_pid")
    for _ in {1..500}; do
        state_file=$(find "$root/runtime" -type f -name 'worker-session.*.state' -print -quit 2>/dev/null || true)
        [[ -n "$state_file" && -f "$root/pids/leaf.pid" ]] && break
        sleep 0.05
    done
    [[ -n "$state_file" && -f "$root/pids/leaf.pid" ]] || fail "$signal_name cleanup-failure fixture did not reach live session"
    saved_temp=$TEMP_DIR; TEMP_DIR=$(dirname "$state_file")
    read_worker_session_state "$state_file" || fail "$signal_name cleanup-failure state unreadable"
    worker_pid=$SESSION_WORKER_PID; worker_start=$SESSION_WORKER_START
    leader_pid=$SESSION_LEADER_PID; leader_start=$SESSION_LEADER_START; managed_sid=$SESSION_SID
    TEMP_DIR=$saved_temp
    wait_test_process_identity_present "$worker_pid" "$worker_start" || fail "$signal_name cleanup-failure worker identity missing"
    wait_test_process_identity_present "$leader_pid" "$leader_start" || fail "$signal_name cleanup-failure leader identity missing"
    test_watchdog_process 30 "$root/watchdog-fired" "$main_pid" & watchdog=$!
    kill "-$signal_name" "$main_pid"
    wait "$main_pid" || rc=$?
    kill -TERM "$watchdog" 2>/dev/null || true; wait "$watchdog" 2>/dev/null || true
    [[ ! -e "$root/watchdog-fired" ]] || fail "$signal_name cleanup failure fired watchdog"
    assert_eq "$expected" "$rc" "$signal_name cleanup failure preserves main signal status"
    wait_test_process_identity_gone "$worker_pid" "$worker_start" || fail "$signal_name cleanup failure left worker identity"
    wait_test_process_identity_gone "$leader_pid" "$leader_start" || fail "$signal_name cleanup failure left leader identity"
    collect_owned_session_records "$managed_sid" session_pids session_starts session_ppids session_pgids session_states || fail "$signal_name cleanup failure cannot verify managed SID"
    assert_eq 0 "${#session_pids[@]}" "$signal_name cleanup failure leaves no managed SID member or zombie"
    [[ -z "$(find "$root/runtime" -mindepth 1 -print -quit 2>/dev/null)" ]] || fail "$signal_name cleanup failure left runtime or state"
    test_process_identity_exists "$unrelated" "$unrelated_start" || fail "$signal_name cleanup failure killed unrelated process"
    kill -TERM "$unrelated"; wait "$unrelated" 2>/dev/null || true
    main_pid=""; main_start=""; watchdog=""; unrelated=""; unrelated_start=""
    trap - EXIT
    pass "$signal_name cleanup failure uses parent fallback without watchdog or zombie"
)
run_live_cleanup_failure_signal_case HUP 129
run_live_cleanup_failure_signal_case INT 130
run_live_cleanup_failure_signal_case TERM 143

cat > "$TEST_DIR/state-publication-child.sh" <<'CHILD'
#!/usr/bin/env bash
set -euo pipefail
script="$1"
shift
source "$script"
main_owner=$BASHPID
eval "$(declare -f terminate_managed_session | sed '1s/terminate_managed_session/original_terminate_managed_session/')"
terminate_managed_session() {
    if [[ "$STATE_PUBLISH_MODE" == cleanup && "$BASHPID" != "$main_owner" ]]; then return 1; fi
    original_terminate_managed_session "$@"
}
worker_session_state_publish_hook() {
    local phase="$1" state="$2" state_file="$3" hook_stage="$4" marker_stage worker_start
    if [[ "$STATE_PUBLISH_MODE" == cleanup && "$state" == active && "$phase" == state-file-assigned ]]; then
        : > "$STATE_CLEANUP_RELEASE"
    fi
    [[ "$phase" == "$STATE_PUBLISH_PHASE" && "$state" == "$STATE_PUBLISH_STATE" ]] || return 0
    [[ ! -e "$STATE_PUBLISH_MARKER" ]] || return 0
    worker_start=""
    for _ in {1..20}; do
        if read_process_record "$BASHPID" && [[ "$PROC_UID" == "$EUID" && "$PROC_STATE" != Z ]]; then worker_start=$PROC_START; break; fi
        sleep 0.01
    done
    [[ -n "$worker_start" ]] || return 1
    marker_stage="$STATE_PUBLISH_MARKER.$BASHPID.stage"
    (umask 077; set -o noclobber; : > "$marker_stage") || return 1
    printf 'phase=%s\nstate=%s\nworker_pid=%s\nworker_start=%s\nleader_pid=%s\nleader_start=%s\npgid=%s\nsid=%s\nstate_file=%s\nhook_stage=%s\n' \
        "$phase" "$state" "$BASHPID" "$worker_start" "$WORKER_TRANSFER_PID" "$WORKER_TRANSFER_START" \
        "$WORKER_TRANSFER_PGID" "$WORKER_TRANSFER_SID" "$state_file" "$hook_stage" > "$marker_stage"
    chmod 0600 "$marker_stage"; mv -fT "$marker_stage" "$STATE_PUBLISH_MARKER"
    while :; do :; done
}
main "$@"
CHILD
chmod 0700 "$TEST_DIR/state-publication-child.sh"

run_state_publication_signal_case() (
    local state="$1" phase="$2" signal_name="$3" expected="$4" mode root main_pid="" main_start="" worker_pid="" worker_start="" leader_pid="" leader_start="" managed_sid=""
    local watchdog="" watchdog_start="" unrelated="" unrelated_start="" rc=0 line key value marker state_file hook_stage
    local -a session_pids=()
    # shellcheck disable=SC2034  # Filled by collect_owned_session_records namerefs.
    local -A session_starts=() session_ppids=() session_pgids=() session_states=()
    cleanup_publication_fixture() {
        [[ -z "$worker_pid" || -z "$worker_start" ]] || { test_process_identity_exists "$worker_pid" "$worker_start" && kill -KILL "$worker_pid" 2>/dev/null || true; }
        [[ -z "$main_pid" || -z "$main_start" ]] || { test_process_identity_exists "$main_pid" "$main_start" && kill -KILL "$main_pid" 2>/dev/null || true; }
        [[ -z "$watchdog" || -z "$watchdog_start" ]] || { test_process_identity_exists "$watchdog" "$watchdog_start" && kill -TERM "$watchdog" 2>/dev/null || true; }
        [[ -z "$unrelated" || -z "$unrelated_start" ]] || { test_process_identity_exists "$unrelated" "$unrelated_start" && kill -TERM "$unrelated" 2>/dev/null || true; }
        [[ -z "$main_pid" ]] || wait "$main_pid" 2>/dev/null || true
        [[ -z "$watchdog" ]] || wait "$watchdog" 2>/dev/null || true
        [[ -z "$unrelated" ]] || wait "$unrelated" 2>/dev/null || true
    }
    trap cleanup_publication_fixture EXIT
    mode=active; [[ "$state" == cleanup_failed ]] && mode=cleanup
    root="$TEST_DIR/state-publish-$state-$phase-$signal_name"; CURRENT_FIXTURE_ROOT=$root
    write_active_grace_fixture "$root"
    mkdir -m 0700 "$root/capture"
    marker="$root/capture/publish-marker"
    sleep 60 & unrelated=$!; unrelated_start=$(wait_test_process_start "$unrelated")
    (
        cd "$root"
        exec env --default-signal=HUP,INT,TERM PATH="$root/bin:$PATH" TMPDIR="$root/runtime" PID_DIR="$root/pids" \
            STATE_PUBLISH_MODE="$mode" STATE_PUBLISH_STATE="$state" STATE_PUBLISH_PHASE="$phase" STATE_PUBLISH_MARKER="$marker" \
            STATE_CLEANUP_RELEASE="$root/capture/cleanup-release" bash "$TEST_DIR/state-publication-child.sh" "$SCRIPT" "$root/source" /remote/path
    ) > "$root/output.log" 2>&1 &
    main_pid=$!; main_start=$(wait_test_process_start "$main_pid")
    for _ in {1..600}; do [[ -f "$marker" ]] && break; sleep 0.05; done
    [[ -f "$marker" && ! -L "$marker" && "$(stat -Lc %a "$marker")" == 600 ]] || { cat "$root/output.log" >&2 || true; fail "$state/$phase/$signal_name did not reach publish hook"; }
    while IFS= read -r line; do key=${line%%=*}; value=${line#*=}; case "$key" in worker_pid) worker_pid=$value;;worker_start) worker_start=$value;;leader_pid) leader_pid=$value;;leader_start) leader_start=$value;;sid) managed_sid=$value;;state_file) state_file=$value;;hook_stage) hook_stage=$value;;esac; done < "$marker"
    [[ "$worker_pid" =~ ^[1-9][0-9]*$ && "$worker_start" =~ ^[1-9][0-9]*$ && "$managed_sid" =~ ^[1-9][0-9]*$ ]] || fail "$state/$phase/$signal_name marker identity malformed"
    wait_test_process_identity_present "$worker_pid" "$worker_start" || { cat "$marker" >&2; fail "$state/$phase/$signal_name worker identity missing at hook"; }
    test_watchdog_process 30 "$root/watchdog-timeout" "$main_pid" & watchdog=$!; watchdog_start=$(wait_test_process_start "$watchdog")
    kill "-$signal_name" "$main_pid"; wait "$main_pid" || rc=$?
    kill -TERM "$watchdog" 2>/dev/null || true; wait "$watchdog" 2>/dev/null || true
    [[ ! -e "$root/watchdog-timeout" ]] || fail "$state/$phase/$signal_name watchdog fired"
    assert_eq "$expected" "$rc" "$state/$phase preserves $signal_name status"
    wait_test_process_identity_gone "$worker_pid" "$worker_start" || fail "$state/$phase/$signal_name left worker identity"
    if [[ "$leader_pid" =~ ^[1-9][0-9]*$ && "$leader_start" =~ ^[1-9][0-9]*$ ]]; then
        if ! wait_test_process_identity_gone "$leader_pid" "$leader_start"; then
            read_process_record "$leader_pid" || true
            printf 'leader remains pid=%s expected_start=%s actual_start=%s state=%s ppid=%s pgid=%s sid=%s\n' \
                "$leader_pid" "$leader_start" "${PROC_START:-unknown}" "${PROC_STATE:-unknown}" "${PROC_PPID:-unknown}" "${PROC_PGID:-unknown}" "${PROC_SID:-unknown}" >&2
            cat "/proc/$leader_pid/stat" >&2 2>/dev/null || true
            fail "$state/$phase/$signal_name left leader identity"
        fi
    fi
    collect_owned_session_records "$managed_sid" session_pids session_starts session_ppids session_pgids session_states || fail "$state/$phase/$signal_name cannot verify managed SID"
    (( ${#session_pids[@]} == 0 )) || fail "$state/$phase/$signal_name left managed SID member: ${session_pids[*]}"
    [[ -z "$(find "$root/runtime" -mindepth 1 -print -quit 2>/dev/null)" ]] || fail "$state/$phase/$signal_name left runtime/session/registration state"
    [[ ! -e "$state_file" && ! -e "$hook_stage" && ! -L "$state_file" && ! -L "$hook_stage" ]] || fail "$state/$phase/$signal_name left publication path"
    test_process_identity_exists "$unrelated" "$unrelated_start" || fail "$state/$phase/$signal_name killed unrelated process"
    kill -TERM "$unrelated"; wait "$unrelated" 2>/dev/null || true
    unrelated=""; unrelated_start=""; main_pid=""; main_start=""; watchdog=""; watchdog_start=""
    trap - EXIT
    pass "$state/$phase/$signal_name publication window cleans process tree and runtime"
)
publication_states=${PUSH_STATE_PUBLICATION_STATES:-"active cleanup_failed"}
publication_phases=${PUSH_STATE_PUBLICATION_PHASES:-"before-stage-create stage-ready after-rename state-file-assigned"}
publication_signals=${PUSH_STATE_PUBLICATION_SIGNALS:-"HUP INT TERM"}
for publication_state in $publication_states; do
    for publication_phase in $publication_phases; do
        for publication_signal in $publication_signals; do
            case "$publication_signal" in HUP) publication_status=129 ;; INT) publication_status=130 ;; TERM) publication_status=143 ;; *) fail "unknown publication signal" ;; esac
            run_state_publication_signal_case "$publication_state" "$publication_phase" "$publication_signal" "$publication_status"
        done
    done
done

(
    root="$TEST_DIR/normal-parallel"; setup_fixture "$root"
    : > "$root/capture/current"; : > "$root/capture/max"
    push_to_server() {
        local server="$1" lock_fd current max group
        case "$server" in one.example|two.example) group=first ;; *) group=second ;; esac
        exec {lock_fd}>>"$root/capture/lock"; flock -x "$lock_fd"
        current=$(<"$root/capture/current"); ((current += 1)); printf '%s' "$current" > "$root/capture/current"
        max=$(<"$root/capture/max"); (( current > max )) && printf '%s' "$current" > "$root/capture/max"
        printf '%s\n' "$server" >> "$root/capture/transfer-calls"; : > "$root/capture/ready.$server"
        flock -u "$lock_fd"; exec {lock_fd}>&-
        while [[ ! -e "$root/capture/release.$group" ]]; do sleep 0.02; done
        exec {lock_fd}>>"$root/capture/lock"; flock -x "$lock_fd"
        current=$(<"$root/capture/current"); ((current -= 1)); printf '%s' "$current" > "$root/capture/current"
        flock -u "$lock_fd"; exec {lock_fd}>&-
        record_result success "$server"
    }
    (
        deadline=$((SECONDS + 15))
        while (( SECONDS < deadline )); do
            if [[ -e "$root/capture/ready.one.example" && -e "$root/capture/ready.two.example" ]]; then : > "$root/capture/release.first"; break; fi
            sleep 0.02
        done
        [[ -e "$root/capture/release.first" ]] || { : > "$root/capture/coordinator-timeout"; : > "$root/capture/release.first"; : > "$root/capture/release.second"; exit 1; }
        while (( SECONDS < deadline + 15 )); do
            if [[ -e "$root/capture/ready.three.example" && -e "$root/capture/ready.four.example" ]]; then : > "$root/capture/release.second"; exit 0; fi
            sleep 0.02
        done
        : > "$root/capture/coordinator-timeout"; : > "$root/capture/release.second"; exit 1
    ) & coordinator=$!
    run_server_batch source destination one.example two.example three.example four.example
    coordinator_rc=0; wait "$coordinator" || coordinator_rc=$?
    assert_eq 0 "$coordinator_rc" "normal parallel coordinator releases both worker pairs"
    assert_eq 2 "$(<"$root/capture/max")" "normal registration preserves MAX_PARALLEL=2"
    assert_eq 4 "$(wc -l < "$root/capture/transfer-calls")" "normal registration completes four fake servers"
    assert_no_registration_residue "$root"; cleanup_runtime; assert_no_registration_residue "$root"
    pass "normal registration/session lifecycle cleans all state"
)
printf 'All push worker registration tests passed.\n'
