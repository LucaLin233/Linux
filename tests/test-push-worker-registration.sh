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
        missing) worker_registration_phase_hook() { [[ "$1" != before-ready ]] || while :; do sleep 1; done; } ;;
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
    failures=1; [[ "$mode" == repeated ]] && failures=100
    process_identity_matches() { if [[ "$1" == "$worker" && "$failures" -gt 0 ]]; then ((failures -= 1)); return 1; fi; original_process_identity_matches "$@"; }
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
    process_identity_matches() { [[ "$1" != "$worker" ]] && original_process_identity_matches "$@"; }
    rc=0; wait_for_worker_slot || rc=$?
    assert_eq "$MANAGED_CLEANUP_FAILURE_STATUS" "$rc" "prune trust failure propagates 125"
    [[ -n "${ACTIVE_WORKERS[$worker]:-}" ]] || fail "prune trust failure discarded active worker evidence"
    eval "$(declare -f original_process_identity_matches | sed '1s/original_process_identity_matches/process_identity_matches/')"
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
worker_registration_phase_hook() { local current="$1"; [[ "$phase" == "$current" ]] || return 0; : > "$root/capture/phase"; while :; do sleep 1; done; }
parent_worker_registration_hook() { local current="$1"; [[ "$phase" == "$current" ]] || return 0; : > "$root/capture/phase"; while :; do sleep 1; done; }
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

write_test_worker_session_manifest() {
    local file="$1" state="$2" worker_pid="$3" worker_start="$4" leader_pid="$5" leader_start="$6" pgid="$7" sid="$8"
    printf 'version=1\nstate=%s\nworker_pid=%s\nworker_start=%s\nleader_pid=%s\nleader_start=%s\npgid=%s\nsid=%s\n' \
        "$state" "$worker_pid" "$worker_start" "$leader_pid" "$leader_start" "$pgid" "$sid" > "$file"
    chmod 0600 "$file"
}

(
    root="$TEST_DIR/session-dual-publish"; setup_fixture "$root"
    : > "$root/capture/terminate-calls"
    terminate_managed_session() { printf '%s:%s:%s:%s\n' "$@" >> "$root/capture/terminate-calls"; return 0; }
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
