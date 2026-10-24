#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/test-push-worker-registration-common.sh"

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


assert_retained_runtime_trusted() {
    local path="$1" expected_dev="$2" expected_inode="$3" metadata="" dev inode owner gid mode trusted_gid
    [[ -d "$path" && ! -L "$path" ]] || fail "retained runtime is not a regular directory: $path"
    metadata=$(stat -Lc '%d:%i:%u:%g:%a' -- "$path") || fail "cannot stat retained runtime: $path"
    IFS=: read -r dev inode owner gid mode <<< "$metadata"
    trusted_gid=$(current_gid)
    [[ "$dev" == "$expected_dev" && "$inode" == "$expected_inode" &&
        "$owner" == "$EUID" && "$gid" == "$trusted_gid" && "$mode" == 700 ]] ||
        fail "retained runtime trust mismatch: $metadata"
}

assert_retained_state_trusted() {
    local file="$1" metadata="" owner gid mode trusted_gid
    [[ -f "$file" && ! -L "$file" ]] || fail "retained worker state is not a regular file: $file"
    metadata=$(stat -Lc '%u:%g:%a' -- "$file") || fail "cannot stat retained worker state: $file"
    IFS=: read -r owner gid mode <<< "$metadata"
    trusted_gid=$(current_gid)
    [[ "$owner" == "$EUID" && "$gid" == "$trusted_gid" && "$mode" == 600 ]] ||
        fail "retained worker state trust mismatch: $metadata"
}

run_preserved_cleanup_retry_case() (
    local run="$1" root runtime runtime_dev runtime_inode credential leader leader_start leader_pgid leader_sid state_file
    local owner watchdog rc=0 metadata="" state_status=0
    local -a session_pids=()
    local -A session_starts=() session_ppids=() session_pgids=() session_states=()
    root="$TEST_DIR/runtime-evidence-retry-$run"; setup_fixture "$root"
    runtime=$TEMP_DIR; runtime_dev=$TEMP_DIR_DEV; runtime_inode=$TEMP_DIR_INODE
    credential="$runtime/private-key"
    printf 'fixture-credential-do-not-print\n' > "$credential"; chmod 0600 "$credential"
    RUNTIME_KEY_FILE=$credential

    setsid bash -c 'trap "" HUP INT TERM; kill -STOP "$BASHPID"; while :; do :; done' & leader=$!
    leader_start=$(wait_test_process_start "$leader")
    for _ in {1..100}; do
        read_process_record "$leader" || true
        [[ "$PROC_START" == "$leader_start" && "$PROC_STATE" == T ]] && break
        sleep 0.01
    done
    read_process_record "$leader"
    leader_pgid=$PROC_PGID; leader_sid=$PROC_SID
    [[ "$leader_pgid" == "$leader" && "$leader_sid" == "$leader" ]] || fail "retry run $run leader identity invalid"
    WORKER_TRANSFER_PID=$leader; WORKER_TRANSFER_START=$leader_start
    WORKER_TRANSFER_PGID=$leader_pgid; WORKER_TRANSFER_SID=$leader_sid
    publish_worker_session_state active
    state_file=$WORKER_SESSION_STATE_FILE

    eval "$(declare -f terminate_managed_session | sed '1s/terminate_managed_session/original_terminate_managed_session/')"
    terminate_managed_session() { return 1; }
    owner=$BASHPID
    test_watchdog_process 3 "$root/watchdog-fired" "$owner" & watchdog=$!
    cleanup_runtime > "$root/capture/first-cleanup.log" 2>&1 || rc=$?
    kill -TERM "$watchdog" 2>/dev/null || true; wait "$watchdog" 2>/dev/null || true

    (( rc != 0 )) || fail "retry run $run first cleanup unexpectedly succeeded"
    [[ ! -e "$root/watchdog-fired" ]] || fail "retry run $run watchdog fired"
    [[ "$TEMP_DIR" == "$runtime" && "$TEMP_DIR_DEV" == "$runtime_dev" && "$TEMP_DIR_INODE" == "$runtime_inode" ]] ||
        fail "retry run $run lost runtime identity"
    assert_retained_runtime_trusted "$runtime" "$runtime_dev" "$runtime_inode"
    assert_retained_state_trusted "$state_file"
    metadata=$(stat -Lc '%u:%g:%a' -- "$credential")
    [[ "$metadata" == "$EUID:$(current_gid):600" ]] || fail "retry run $run credential permissions changed: $metadata"
    grep -Fq 'fixture-credential-do-not-print' "$root/capture/first-cleanup.log" && fail "retry run $run printed credential content"
    state_status=0; read_worker_session_state "$state_file" || state_status=$?
    assert_eq 0 "$state_status" "retry run $run retained state parses"
    [[ "$SESSION_STATE" == cleanup_failed && "$SESSION_LEADER_PID" == "$leader" &&
        "$SESSION_LEADER_START" == "$leader_start" && "$SESSION_PGID" == "$leader_pgid" && "$SESSION_SID" == "$leader_sid" ]] ||
        fail "retry run $run retained state identity mismatch"
    [[ "$WORKER_TRANSFER_PID" == "$leader" && "$WORKER_TRANSFER_START" == "$leader_start" &&
        "$WORKER_TRANSFER_PGID" == "$leader_pgid" && "$WORKER_TRANSFER_SID" == "$leader_sid" &&
        "$WORKER_TRANSFER_CLEANUP_FAILED" == true && "$WORKER_SESSION_STATE_FILE" == "$state_file" &&
        "$RUNTIME_CLEANUP_ACTIVE" == false ]] || fail "retry run $run lost cleanup globals"
    test_process_identity_exists "$leader" "$leader_start" || fail "retry run $run lost live leader tracking"
    read_process_record "$leader"
    [[ "$PROC_PPID" == "$BASHPID" && "$PROC_STATE" != Z ]] || fail "retry run $run orphaned or zombified leader"

    eval "$(declare -f original_terminate_managed_session | sed '1s/original_terminate_managed_session/terminate_managed_session/')"
    cleanup_runtime
    wait_test_process_identity_gone "$leader" "$leader_start" || fail "retry run $run left leader identity"
    collect_owned_session_records "$leader_sid" session_pids session_starts session_ppids session_pgids session_states
    assert_eq 0 "${#session_pids[@]}" "retry run $run clears managed SID"
    [[ ! -e "$state_file" && ! -L "$state_file" && ! -e "$runtime" && ! -L "$runtime" ]] ||
        fail "retry run $run left state or runtime"
    runtime_lifecycle_globals_resolved || fail "retry run $run left lifecycle globals"
    [[ "$RUNTIME_STATE" == none && "$RUNTIME_CLEANUP_ACTIVE" == false ]] || fail "retry run $run runtime state not reset"
    pass "failed cleanup evidence retry run $run preserves then clears runtime"
)

runtime_evidence_stress=${PUSH_RUNTIME_EVIDENCE_STRESS:-20}
for runtime_evidence_run in $(seq 1 "$runtime_evidence_stress"); do
    run_preserved_cleanup_retry_case "$runtime_evidence_run"
done
pass "failed cleanup evidence retry completed $runtime_evidence_stress deterministic run(s)"

(
    local_cleanup_root="$TEST_DIR/active-cleanup-evidence"; setup_fixture "$local_cleanup_root"
    runtime=$TEMP_DIR; runtime_dev=$TEMP_DIR_DEV; runtime_inode=$TEMP_DIR_INODE
    sleep 300 & worker=$!; worker_start=$(wait_test_process_start "$worker")
    sleep 300 & replacement=$!; replacement_start=$(wait_test_process_start "$replacement")
    state_file="$runtime/worker-session.$worker.state"
    write_test_worker_session_manifest "$state_file" cleanup_failed "$worker" "$worker_start" \
        "$replacement" "$((replacement_start + 1))" "$replacement" "$replacement"
    ACTIVE_WORKERS[$worker]=$worker_start
    ACTIVE_WORKER_STATE_FILES[$worker]=$state_file
    ACTIVE_WORKER_STATE_STARTS[$worker]=$worker_start
    eval "$(declare -f terminate_active_workers | sed '1s/terminate_active_workers/original_terminate_active_workers/')"
    terminate_active_workers() { return 1; }
    rc=0; cleanup_runtime > "$local_cleanup_root/capture/first-cleanup.log" 2>&1 || rc=$?
    (( rc != 0 )) || fail "active cleanup evidence first call unexpectedly succeeded"
    assert_retained_runtime_trusted "$runtime" "$runtime_dev" "$runtime_inode"
    assert_retained_state_trusted "$state_file"
    [[ -n "${ACTIVE_WORKERS[$worker]:-}" && "${ACTIVE_WORKER_STATE_FILES[$worker]:-}" == "$state_file" &&
        "${ACTIVE_WORKER_STATE_STARTS[$worker]:-}" == "$worker_start" && "$RUNTIME_CLEANUP_ACTIVE" == false ]] ||
        fail "active cleanup evidence maps were discarded"
    test_process_identity_exists "$worker" "$worker_start" || fail "active cleanup evidence worker disappeared"
    eval "$(declare -f original_terminate_active_workers | sed '1s/original_terminate_active_workers/terminate_active_workers/')"
    cleanup_runtime
    wait_test_process_identity_gone "$worker" "$worker_start" || fail "active cleanup retry left worker"
    [[ ! -e "$state_file" && ! -e "$runtime" && ${#ACTIVE_WORKERS[@]} == 0 &&
        ${#ACTIVE_WORKER_STATE_FILES[@]} == 0 && ${#ACTIVE_WORKER_STATE_STARTS[@]} == 0 ]] ||
        fail "active cleanup retry left runtime, state, or maps"
    test_process_identity_exists "$replacement" "$replacement_start" || fail "active cleanup retry touched PID-reuse replacement"
    kill -TERM "$replacement"; wait "$replacement" 2>/dev/null || true
    pass "active cleanup failure preserves evidence and retry clears it"
)

run_runtime_trust_retention_case() (
    local kind="$1" root runtime runtime_dev runtime_inode original_path replacement_path rc=0
    root="$TEST_DIR/runtime-trust-$kind"; setup_fixture "$root"
    runtime=$TEMP_DIR; runtime_dev=$TEMP_DIR_DEV; runtime_inode=$TEMP_DIR_INODE
    case "$kind" in
        symlink)
            original_path="$runtime.original"; replacement_path="$runtime.replacement"
            mv "$runtime" "$original_path"; mkdir -m 0700 "$replacement_path"; : > "$replacement_path/marker"
            ln -s "$replacement_path" "$runtime"
            ;;
        wrong-mode) chmod 0755 "$runtime" ;;
        wrong-owner|wrong-gid)
            eval "$(declare -f stat | sed '1s/stat/original_stat/')" 2>/dev/null || true
            stat() {
                local last="${!#}" metadata dev inode owner gid mode
                if [[ "$last" == "$runtime" && "$1" == -Lc && "$2" == '%d:%i:%u:%g:%a' ]]; then
                    metadata=$(command stat -Lc '%d:%i:%u:%g:%a' -- "$runtime") || return 1
                    IFS=: read -r dev inode owner gid mode <<< "$metadata"
                    [[ "$kind" == wrong-owner ]] && owner=$((owner + 1)) || gid=$((gid + 1))
                    printf '%s:%s:%s:%s:%s\n' "$dev" "$inode" "$owner" "$gid" "$mode"
                else
                    command stat "$@"
                fi
            }
            ;;
        *) fail "unknown runtime trust case: $kind" ;;
    esac
    cleanup_runtime > "$root/capture/cleanup.log" 2>&1 || rc=$?
    (( rc != 0 )) || fail "$kind untrusted runtime unexpectedly deleted"
    [[ "$TEMP_DIR" == "$runtime" && "$TEMP_DIR_DEV" == "$runtime_dev" && "$TEMP_DIR_INODE" == "$runtime_inode" &&
        "$RUNTIME_CLEANUP_ACTIVE" == false ]] || fail "$kind untrusted runtime lost path identity"
    case "$kind" in
        symlink)
            [[ -L "$runtime" && -f "$replacement_path/marker" && -d "$original_path" ]] || fail "symlink replacement was modified"
            rm -f "$runtime"; rmdir "$replacement_path" 2>/dev/null || { rm -f "$replacement_path/marker"; rmdir "$replacement_path"; }
            mv "$original_path" "$runtime"
            ;;
        wrong-mode) chmod 0700 "$runtime" ;;
        wrong-owner|wrong-gid)
            unset -f stat
            ;;
    esac
    cleanup_runtime
    [[ ! -e "$runtime" && ! -L "$runtime" ]] || fail "$kind trusted retry left runtime"
    pass "$kind runtime trust failure preserves evidence and replacement"
)
for runtime_trust_kind in symlink wrong-owner wrong-gid wrong-mode; do
    run_runtime_trust_retention_case "$runtime_trust_kind"
done

for final_residue_kind in worker-session registration-ready registration-stage; do
    (
        root="$TEST_DIR/runtime-final-proof-$final_residue_kind"; setup_fixture "$root"
        runtime=$TEMP_DIR; runtime_dev=$TEMP_DIR_DEV; runtime_inode=$TEMP_DIR_INODE
        case "$final_residue_kind" in
            worker-session) residue="$runtime/worker-session.99999.state" ;;
            registration-ready) residue="$runtime/worker-registration.99999.ready" ;;
            registration-stage) residue="$runtime/.worker-registration.99999.ready.token.stage" ;;
        esac
        eval "$(declare -f terminate_active_workers | sed '1s/terminate_active_workers/original_terminate_active_workers/')"
        terminate_active_workers() {
            original_terminate_active_workers || return 1
            printf 'retained-lifecycle-evidence\n' > "$residue"; chmod 0600 "$residue"
        }
        rc=0; cleanup_runtime > "$root/capture/cleanup.log" 2>&1 || rc=$?
        (( rc != 0 )) || fail "$final_residue_kind final proof unexpectedly deleted runtime"
        assert_retained_runtime_trusted "$runtime" "$runtime_dev" "$runtime_inode"
        [[ -f "$residue" && ! -L "$residue" && "$TEMP_DIR" == "$runtime" && "$RUNTIME_CLEANUP_ACTIVE" == false ]] ||
            fail "$final_residue_kind final proof discarded evidence"
        eval "$(declare -f original_terminate_active_workers | sed '1s/original_terminate_active_workers/terminate_active_workers/')"
        rm -f -- "$residue"
        cleanup_runtime
        [[ ! -e "$runtime" ]] || fail "$final_residue_kind final proof retry left runtime"
        pass "$final_residue_kind blocks runtime deletion until evidence is cleared"
    )
done

(
    root="$TEST_DIR/runtime-final-proof-success"; setup_fixture "$root"; runtime=$TEMP_DIR
    cleanup_runtime
    [[ ! -e "$runtime" && -z "$TEMP_DIR" && "$RUNTIME_STATE" == none && "$RUNTIME_CLEANUP_ACTIVE" == false ]] ||
        fail "clean runtime final proof did not clear state"
    pass "clean runtime final proof preserves normal success path"
)


cat > "$TEST_DIR/runtime-retention-signal-child.sh" <<'CHILD'
#!/usr/bin/env bash
set -euo pipefail
script="$1" root="$2" leader="$3" leader_start="$4" leader_pgid="$5" leader_sid="$6"
mkdir -p "$root/runtime" "$root/capture"
chmod 0700 "$root" "$root/runtime" "$root/capture"
TMPDIR="$root/runtime"
# shellcheck source=../tools/push.sh
source "$script"
initialize_runtime
credential="$TEMP_DIR/private-key"
printf 'signal-fixture-credential-do-not-print\n' > "$credential"
chmod 0600 "$credential"
RUNTIME_KEY_FILE=$credential
WORKER_TRANSFER_PID=$leader
WORKER_TRANSFER_START=$leader_start
WORKER_TRANSFER_PGID=$leader_pgid
WORKER_TRANSFER_SID=$leader_sid
publish_worker_session_state active
state_file=$WORKER_SESSION_STATE_FILE
terminate_managed_session() { return 1; }
install_runtime_traps
worker_start=$(get_process_start_time "$BASHPID")
stage="$root/capture/ready.stage"
{
    printf 'target_pid=%s\n' "$BASHPID"
    printf 'target_start=%s\n' "$worker_start"
    printf 'runtime=%s\n' "$TEMP_DIR"
    printf 'runtime_dev=%s\n' "$TEMP_DIR_DEV"
    printf 'runtime_inode=%s\n' "$TEMP_DIR_INODE"
    printf 'state_file=%s\n' "$state_file"
    printf 'credential=%s\n' "$credential"
} > "$stage"
chmod 0600 "$stage"
mv -fT "$stage" "$root/capture/ready"
while :; do :; done
CHILD
chmod 0700 "$TEST_DIR/runtime-retention-signal-child.sh"

run_runtime_retention_signal_case() (
    local signal_name="$1" expected="$2" root leader="" leader_start="" leader_pgid="" leader_sid="" target="" target_pid="" target_start=""
    local runtime runtime_dev runtime_inode state_file credential watchdog="" rc=0 line key value state_status=0 reap_status=0
    local -a session_pids=()
    local -A session_starts=() session_ppids=() session_pgids=() session_states=()
    cleanup_runtime_retention_signal_fixture() {
        if [[ -n "$target" ]]; then kill -KILL "$target" 2>/dev/null || true; wait "$target" 2>/dev/null || true; fi
        if [[ -n "$leader" ]]; then kill -CONT "$leader" 2>/dev/null || true; kill -KILL "$leader" 2>/dev/null || true; wait "$leader" 2>/dev/null || true; fi
        if [[ -n "$watchdog" ]]; then kill -TERM "$watchdog" 2>/dev/null || true; wait "$watchdog" 2>/dev/null || true; fi
    }
    trap cleanup_runtime_retention_signal_fixture EXIT
    root="$TEST_DIR/runtime-retention-signal-$signal_name"; CURRENT_FIXTURE_ROOT=$root
    mkdir -m 0700 "$root"
    setsid bash -c 'trap "" HUP INT TERM; kill -STOP "$BASHPID"; while :; do :; done' & leader=$!
    leader_start=$(wait_test_process_start "$leader")
    for _ in {1..100}; do read_process_record "$leader" || true; [[ "$PROC_STATE" == T ]] && break; sleep 0.01; done
    read_process_record "$leader"; leader_pgid=$PROC_PGID; leader_sid=$PROC_SID
    [[ "$leader_pgid" == "$leader" && "$leader_sid" == "$leader" ]] || fail "$signal_name retention leader identity invalid"

    (
        exec env --default-signal=HUP,INT,TERM bash "$TEST_DIR/runtime-retention-signal-child.sh" \
            "$SCRIPT" "$root" "$leader" "$leader_start" "$leader_pgid" "$leader_sid"
    ) > "$root/output.log" 2>&1 & target=$!
    for _ in {1..300}; do [[ -f "$root/capture/ready" ]] && break; sleep 0.02; done
    [[ -f "$root/capture/ready" ]] || { cat "$root/output.log" >&2 || true; fail "$signal_name retention child not ready"; }
    while IFS= read -r line; do
        key=${line%%=*}; value=${line#*=}
        case "$key" in
            target_pid) target_pid=$value ;;
            target_start) target_start=$value ;;
            runtime) runtime=$value ;;
            runtime_dev) runtime_dev=$value ;;
            runtime_inode) runtime_inode=$value ;;
            state_file) state_file=$value ;;
            credential) credential=$value ;;
        esac
    done < "$root/capture/ready"
    [[ "$target_pid" == "$target" && "$target_start" =~ ^[1-9][0-9]*$ &&
        "$runtime_dev" =~ ^[0-9]+$ && "$runtime_inode" =~ ^[1-9][0-9]*$ ]] ||
        fail "$signal_name retention ready metadata malformed"
    job_is_active "$target" || fail "$signal_name retention target job missing"
    test_watchdog_process 5 "$root/watchdog-fired" "$target" & watchdog=$!
    kill "-$signal_name" "$target"
    wait "$target" || rc=$?
    kill -TERM "$watchdog" 2>/dev/null || true; wait "$watchdog" 2>/dev/null || true
    [[ ! -e "$root/watchdog-fired" ]] || fail "$signal_name retention watchdog fired"
    assert_eq "$expected" "$rc" "$signal_name failed cleanup preserves signal status"
    assert_retained_runtime_trusted "$runtime" "$runtime_dev" "$runtime_inode"
    assert_retained_state_trusted "$state_file"
    [[ "$(stat -Lc '%u:%g:%a' -- "$credential")" == "$EUID:$(current_gid):600" ]] ||
        fail "$signal_name retained credential permissions changed"
    grep -Fq "$runtime" "$root/output.log" || fail "$signal_name failure output omitted runtime path"
    grep -Fq 'signal-fixture-credential-do-not-print' "$root/output.log" && fail "$signal_name failure output leaked credential"
    TEMP_DIR=$runtime
    state_status=0; read_worker_session_state "$state_file" || state_status=$?
    assert_eq 0 "$state_status" "$signal_name retained cleanup_failed state parses"
    [[ "$SESSION_STATE" == cleanup_failed && "$SESSION_LEADER_PID" == "$leader" &&
        "$SESSION_LEADER_START" == "$leader_start" && "$SESSION_PGID" == "$leader_pgid" && "$SESSION_SID" == "$leader_sid" ]] ||
        fail "$signal_name retained cleanup_failed identity mismatch"
    test_process_identity_exists "$leader" "$leader_start" || fail "$signal_name failed cleanup lost leader tracking"
    read_process_record "$leader"
    [[ "$PROC_PPID" == "$BASHPID" && "$PROC_STATE" != Z ]] || fail "$signal_name teardown leader lost safe parent"

    terminate_managed_session "$leader" "$leader_start" "$leader_pgid" "$leader_sid" true
    reap_direct_managed_leader "$leader" "$leader_start" "$leader_pgid" "$leader_sid" "$BASHPID" || reap_status=$?
    assert_eq 0 "$reap_status" "$signal_name teardown safely reaps leader"
    collect_owned_session_records "$leader_sid" session_pids session_starts session_ppids session_pgids session_states
    assert_eq 0 "${#session_pids[@]}" "$signal_name teardown clears managed SID"
    assert_retained_runtime_trusted "$runtime" "$runtime_dev" "$runtime_inode"
    rm -rf -- "$runtime"
    TEMP_DIR=""
    leader=""; target=""; watchdog=""
    trap - EXIT
    pass "$signal_name cleanup failure retains trusted runtime and state"
)
run_runtime_retention_signal_case HUP 129
run_runtime_retention_signal_case INT 130
run_runtime_retention_signal_case TERM 143
