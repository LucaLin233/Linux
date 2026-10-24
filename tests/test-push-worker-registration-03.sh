#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/test-push-worker-registration-common.sh"

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
    MAX_PARALLEL=2
    push_to_server() {
        local server="$1" lock_fd
        exec {lock_fd}>>"$root/capture/calls.lock"; flock -x "$lock_fd"
        printf '%s\n' "$server" >> "$root/capture/calls"; : > "$root/capture/ready.$server"
        flock -u "$lock_fd"; exec {lock_fd}>&-
        while [[ ! -e "$root/capture/release" ]]; do sleep 0.01; done
        WORKER_TRANSFER_PID=$BASHPID
        WORKER_TRANSFER_START=11
        WORKER_TRANSFER_PGID=$BASHPID
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
    root="$TEST_DIR/state-publish-$state-$phase-$signal_name${5:-}"; CURRENT_FIXTURE_ROOT=$root
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
    printf "DIAG: publication state=%s phase=%s signal=%s main=%s/%s worker=%s/%s sid=%s\n" \
        "$state" "$phase" "$signal_name" "$main_pid" "$main_start" "$worker_pid" "$worker_start" "$managed_sid"
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