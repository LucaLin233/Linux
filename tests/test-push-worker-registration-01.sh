#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/test-push-worker-registration-common.sh"
assert_eq source-safe "$source_result" "source keeps zero runtime side effects"

(
    # Inert direct-child job table: no SSH or production services.
    sleep 10 & snapshot_child=$!
    cleanup_snapshot_child() { kill -TERM "$snapshot_child" 2>/dev/null || true; wait "$snapshot_child" 2>/dev/null || true; }
    trap cleanup_snapshot_child EXIT
    job_is_active "$snapshot_child" || fail "snapshot misses active direct child"
    if job_is_active 0; then fail "snapshot accepts absent PID"; fi
    kill -TERM "$snapshot_child"
    wait "$snapshot_child" 2>/dev/null || true
    if job_is_active "$snapshot_child"; then fail "snapshot retains reaped child"; fi
    trap - EXIT
    pass "job snapshot preserves direct-child matching and reap semantics"
)
trap 'rm -rf "$TEST_DIR"' EXIT

# Deterministic coordinator contract: a live worker can republish after cleanup.
(
    root="$TEST_DIR/republish-tracking"; mkdir -m 0700 "$root"
    state_file="$root/worker.state"; : > "$state_file"
    ACTIVE_WORKERS=([424242]=12345)
    ACTIVE_WORKER_STATE_FILES=([424242]="$state_file")
    ACTIVE_WORKER_STATE_STARTS=([424242]=12345)
    worker_session_state_maybe_cleanup_failed() { return 0; }
    cleanup_calls=0
    cleanup_worker_session_state_file() { cleanup_calls=$((cleanup_calls + 1)); rm -f -- "$1"; }
    cleanup_active_failed_worker_sessions
    [[ ${ACTIVE_WORKER_STATE_FILES[424242]:-} == "$state_file" && ${ACTIVE_WORKER_STATE_STARTS[424242]:-} == 12345 ]] || fail "active cleanup lost live publisher tracking"
    : > "$state_file"
    ACTIVE_WORKERS=()
    job_is_active() { return 1; }
    cleanup_published_worker_sessions
    assert_eq 2 "$cleanup_calls" "post-reap fallback handles republished state"
    [[ ! -e $state_file && ${#ACTIVE_WORKER_STATE_FILES[@]} == 0 && ${#ACTIVE_WORKER_STATE_STARTS[@]} == 0 ]] || fail "republished state remains"
    pass "live publisher tracking survives successful active cleanup"
)

setup_fixture() {
    local root="$1"
    CURRENT_FIXTURE_ROOT=$root
    mkdir -m 0700 "$root" "$root/runtime" "$root/capture"
    TMPDIR="$root/runtime"; initialize_runtime
    MAX_PARALLEL=2
    MAX_RETRIES=1
    BATCH_WORKER_FAILED=false
    BATCH_WORKER_ERROR=false
}
assert_no_registration_residue() {
    local root="$1"
    [[ -z "$(find "$root/runtime" \( -name 'worker-registration.*' -o -name '.worker-registration.*' -o -name 'worker-session.*.state' \) -print -quit)" ]] || fail "registration/session residue remains"
    (( ${#REGISTERING_WORKERS[@]} == 0 && ${#ACTIVE_WORKERS[@]} == 0 )) || fail "worker arrays remain"
    (( ${#WORKER_REGISTRATION_READY_FILES[@]} == 0 && ${#WORKER_REGISTRATION_RELEASE_FILES[@]} == 0 && ${#WORKER_REGISTRATION_STARTS[@]} == 0 && ${#WORKER_REGISTRATION_STAGE_FILES[@]} == 0 )) || fail "registration arrays remain"
}

run_delayed_parent_reap_case() (
    local depth="$1" root leader leader_start leader_pgid leader_sid
    root="$TEST_DIR/delayed-reap-$depth"
    local state_file elapsed_start elapsed_end rc=0
    local -a session_pids=()
    local -A session_starts=() session_ppids=() session_pgids=() session_states=()
    setup_fixture "$root"
    mkfifo "$root/reap-clock"
    cat > "$root/parent.sh" <<'CHILD'
#!/usr/bin/env bash
set -u
root="$1" depth="$2"
trap '' HUP INT TERM
 : > "$root/parent-open"
if (( depth == 0 )); then
    sleep 300 & child=$!
    printf '%s\n' "$child" > "$root/leaf.pid"
else
    bash "$root/parent.sh" "$root" "$((depth - 1))" & child=$!
fi
kill -STOP "$BASHPID"
wait "$child" 2>/dev/null || true
exit 0
CHILD
    chmod 0700 "$root/parent.sh"
    setsid bash "$root/parent.sh" "$root" "$depth" & leader=$!
    leader_start=$(wait_test_process_start "$leader")
    for _ in {1..100}; do [[ -e "$root/parent-open" ]] && break; sleep .01; done
    read_process_record "$leader"; leader_pgid=$PROC_PGID; leader_sid=$PROC_SID
    [[ "$leader_pgid" == "$leader" && "$leader_sid" == "$leader" ]] || fail "delayed $depth leader identity invalid"
    WORKER_TRANSFER_PID=$leader; WORKER_TRANSFER_START=$leader_start
    WORKER_TRANSFER_PGID=$leader_pgid; WORKER_TRANSFER_SID=$leader_sid
    publish_worker_session_state active; state_file=$WORKER_SESSION_STATE_FILE
    leaf=$(<"$root/leaf.pid"); leaf_start=$(wait_test_process_start "$leaf")
    kill -KILL "$leaf" 2>/dev/null || true
    old_reap_status=1
    for _ in {1..30}; do
        session_process_identity_matches "$leaf" "$leaf_start" "$leader_sid" || { old_reap_status=0; break; }
        sleep 0.01
    done
    assert_eq 1 "$old_reap_status" "delayed $depth old 300ms window remains pending"
    ( sleep 1; kill -CONT -"$leader" 2>/dev/null || true ) & releaser=$!
    cleanup_clock; elapsed_start=$CLEANUP_NOW
    terminate_worker_transfer || rc=$?
    wait "$releaser" 2>/dev/null || true
    cleanup_clock; elapsed_end=$CLEANUP_NOW
    assert_eq 0 "$rc" "delayed $depth parent reap succeeds"
    (( elapsed_end - elapsed_start >= 100 )) || fail "delayed $depth reap did not wait for parent"
    wait_test_process_identity_gone "$leader" "$leader_start" || fail "delayed $depth left leader"
    collect_owned_session_records "$leader_sid" session_pids session_starts session_ppids session_pgids session_states
    assert_eq 0 "${#session_pids[@]}" "delayed $depth managed SID clears"
    [[ ! -e "$state_file" && "$RUNTIME_CLEANUP_ACTIVE" == false ]] || fail "delayed $depth state cleanup incomplete"
    cleanup_runtime
    exec 9>&-
    pass "delayed parent reap depth $depth preserves leaf-first order"
)
run_delayed_parent_reap_case 1
run_delayed_parent_reap_case 4

(
    root="$TEST_DIR/reap-deadline"; setup_fixture "$root"
    cat > "$root/parent.sh" <<'CHILD'
#!/usr/bin/env bash
set -u
root="$1"
trap '' HUP INT TERM
sleep 300 & child=$!
: > "$root/ready"
while [[ ! -e "$root/release" ]]; do :; done
wait "$child" 2>/dev/null || true
exit 0
CHILD
    chmod 0700 "$root/parent.sh"
    setsid bash "$root/parent.sh" "$root" & leader=$!
    for _ in {1..100}; do [[ -e "$root/ready" ]] && break; sleep .01; done
    leader_start=$(wait_test_process_start "$leader"); read_process_record "$leader"
    WORKER_TRANSFER_PID=$leader; WORKER_TRANSFER_START=$leader_start; WORKER_TRANSFER_PGID=$PROC_PGID; WORKER_TRANSFER_SID=$PROC_SID
    publish_worker_session_state active; state_file=$WORKER_SESSION_STATE_FILE
    MANAGED_SESSION_CLEANUP_TICKS=300
    rc=0; terminate_worker_transfer || rc=$?
    (( rc != 0 )) || fail "deadline failure unexpectedly succeeded"
    [[ -d "$TEMP_DIR" && -f "$state_file" && "$WORKER_TRANSFER_CLEANUP_FAILED" == true ]] || fail "deadline failure discarded evidence"
    [[ "$(stat -c %a "$TEMP_DIR")" == 700 && "$(stat -c %a "$state_file")" == 600 ]] || fail "deadline evidence trust changed"
    : > "$root/release"; wait "$leader" 2>/dev/null || true
    remove_worker_session_state
    WORKER_TRANSFER_PID=""; WORKER_TRANSFER_START=""; WORKER_TRANSFER_PGID=""; WORKER_TRANSFER_SID=""; WORKER_TRANSFER_CLEANUP_FAILED=false
    clear_managed_session_cleanup_tracking
    cleanup_runtime
    [[ ! -e "$TEMP_DIR" ]] || fail "deadline teardown left runtime"
    exec 9>&-
    pass "deadline failure is bounded and preserves then safely clears evidence"
)
if [[ "${PUSH_REAP_ONLY:-false}" == true ]]; then
    exit 0
fi
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

(
    sleep 60 & proc_fallback_worker=$!
    proc_fallback_start=$(wait_test_process_start "$proc_fallback_worker")
    eval "$(declare -f read_process_record | sed '1s/read_process_record/original_read_process_record/')"
    read_process_record() { [[ "$1" != "$proc_fallback_worker" ]] && original_read_process_record "$@"; }
    proc_fallback_status=0
    read_process_record_for_session_scan "$proc_fallback_worker" || proc_fallback_status=$?
    assert_eq 0 "$proc_fallback_status" "proc owner fallback recovers transient status-read failure"
    [[ "$PROC_START" == "$proc_fallback_start" && "$PROC_UID" == "$EUID" ]] || fail "proc owner fallback identity mismatch"
    kill -TERM "$proc_fallback_worker"; wait "$proc_fallback_worker" 2>/dev/null || true
    pass "proc owner fallback binds UID to stable PID start"
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
    ACTIVE_WORKER_STATE_FILES[$worker]="$TEMP_DIR/worker-session.$worker.state"
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
    ACTIVE_WORKER_STATE_FILES[$worker]="$TEMP_DIR/worker-session.$worker.state"
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