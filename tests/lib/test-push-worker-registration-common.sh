#!/usr/bin/env bash
set -euo pipefail
# Safe runtime identity only: no environment dump, credentials, or xtrace.
printf "DIAG: bash=%s kernel=%s\n" "$BASH_VERSION" "$(uname -r)"
dpkg-query -W bash libc6 2>/dev/null || true

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
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
    printf '%s\n' '--- process output ---' >&2
    [[ -f "$root/output.log" ]] && cat "$root/output.log" >&2 2>/dev/null || true
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
# shellcheck source=../tools/push.sh
source "$SCRIPT"
