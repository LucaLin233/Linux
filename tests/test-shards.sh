#!/usr/bin/env bash
set -euo pipefail
# These fixtures re-enter run.sh and require its serial, whole-shard behaviour.
unset TEST_JOBS TEST_SEGMENTS TEST_SEGMENT TEST_SEGMENT_SET
# Inert fixtures only: verify partitioning without running production suites.
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT
mkdir -p "$TEMP_DIR/tests" "$TEMP_DIR/bin"
cp "$ROOT_DIR/tests/run.sh" "$TEMP_DIR/tests/run.sh"
export CAPTURE="$TEMP_DIR/capture" GITHUB_STEP_SUMMARY="$TEMP_DIR/summary"
unset TEST_BASE_SHA TEST_HEAD_SHA
for name in cloudflare-tunnel motd push push-worker-registration new-suite; do
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s" >> "$CAPTURE"\n' "test-$name.sh" > "$TEMP_DIR/tests/test-$name.sh"
done
check() {
    local expected=$1
    shift
    : > "$CAPTURE"
    bash "$TEMP_DIR/tests/run.sh" "$@" > "$TEMP_DIR/output" 2>&1
    [[ "$(cat "$CAPTURE")" == "$expected" ]] || { cat "$TEMP_DIR/output"; exit 1; }
}
all=$'test-cloudflare-tunnel.sh\ntest-motd.sh\ntest-new-suite.sh\ntest-push-worker-registration.sh\ntest-push.sh'
check "$all"
check "$all" all
check test-motd.sh motd
check test-push-worker-registration.sh push-worker
check test-push.sh push
check test-cloudflare-tunnel.sh cloudflare
check test-new-suite.sh other
# Every current and future suite belongs to exactly one shard.
: > "$TEMP_DIR/union"
for shard in motd push-worker push cloudflare other; do
    : > "$CAPTURE"
    bash "$TEMP_DIR/tests/run.sh" "$shard" > "$TEMP_DIR/output" 2>&1
    cat "$CAPTURE" >> "$TEMP_DIR/union"
done
[[ "$(sort "$TEMP_DIR/union")" == "$all" ]]
for args in invalid extra; do
    : > "$CAPTURE"
    rc=0
    if [[ "$args" == extra ]]; then
        bash "$TEMP_DIR/tests/run.sh" all extra > "$TEMP_DIR/output" 2>&1 || rc=$?
    else
        bash "$TEMP_DIR/tests/run.sh" invalid > "$TEMP_DIR/output" 2>&1 || rc=$?
    fi
    [[ "$rc" == 2 && ! -s "$CAPTURE" ]]
done
# PR selection intersects the shard; unavailable history still covers all shards.
cat > "$TEMP_DIR/bin/git" <<'STUB'
#!/usr/bin/env bash
[[ "${DIFF_FAIL:-0}" == 0 ]] || exit 1
printf 'tools/push.sh\0'
STUB
chmod +x "$TEMP_DIR/bin/git"
ORIGINAL_PATH=$PATH
export PATH="$TEMP_DIR/bin:$PATH" TEST_BASE_SHA=base TEST_HEAD_SHA=head
check '' motd
check '' cloudflare
check '' other
check test-push.sh push
check test-push-worker-registration.sh push-worker
DIFF_FAIL=1 check test-motd.sh motd
DIFF_FAIL=1 check test-new-suite.sh other
# Child errexit and failure propagation must survive sharding.
printf '#!/usr/bin/env bash\nset -e\nfalse\nprintf unexpected >> "$CAPTURE"\n' > "$TEMP_DIR/tests/test-push-worker-registration.sh"
: > "$CAPTURE"
rc=0
bash "$TEMP_DIR/tests/run.sh" push-worker > "$TEMP_DIR/output" 2>&1 || rc=$?
[[ "$rc" == 1 && ! -s "$CAPTURE" ]]
grep -q 'exit=1' "$TEMP_DIR/output"
PATH=$ORIGINAL_PATH
unset TEST_BASE_SHA TEST_HEAD_SHA
# Segment subsets: one suite can be spread over several jobs, so every segment
# of a suite must be covered by exactly one job and every job must name a real
# segment of the suite's source.
guards() {
    awk '/^if seg_is [0-9]+; then$/ { n = $3; sub(";", "", n); print n }' "$1"
}
workflow="$ROOT_DIR/.github/workflows/shell-tests.yml"
[[ -f "$workflow" ]]
jobs=$(awk '
    /^[[:space:]]*- shard:/ { if (suite != "") print suite "|" segments "|" set; suite = ""; segments = ""; set = ""; next }
    /^[[:space:]]+suite:/ { suite = $2; next }
    /^[[:space:]]+segments:/ { segments = $2; next }
    /^[[:space:]]+segment_set:/ {
        set = $0
        sub(/^[[:space:]]*segment_set:[[:space:]]*/, "", set)
        gsub(/"/, "", set)
        next
    }
    END { if (suite != "") print suite "|" segments "|" set }
' "$workflow")
[[ -n "$jobs" ]]
# The Ubuntu and Debian matrices are separate lists of the same jobs.
raw_jobs=$(printf '%s\n' "$jobs" | grep -c . || true)
jobs=$(printf '%s\n' "$jobs" | sort -u)
distinct=$(printf '%s\n' "$jobs" | grep -c . || true)
[[ "$raw_jobs" == "$(( distinct * 2 ))" ]]
for suite in motd cloudflare push-worker push other; do
    declared=""
    covered=" "
    while IFS='|' read -r job_suite job_segments job_set; do
        [[ "$job_suite" == "$suite" ]] || continue
        [[ -n "$declared" ]] || declared=$job_segments
        [[ "$declared" == "$job_segments" ]] || { printf 'inconsistent segment count for %s\n' "$suite"; exit 1; }
        if [[ -z "$job_set" ]]; then
            for (( index = 0; index < job_segments; index++ )); do covered+="$index "; done
        else
            covered+="$job_set "
        fi
    done <<< "$jobs"
    [[ -n "$declared" ]] || { printf 'no job for %s\n' "$suite"; exit 1; }
    for (( index = 0; index < declared; index++ )); do
        count=$(printf '%s' "$covered" | tr ' ' '\n' | grep -c "^${index}$" || true)
        [[ "$count" == 1 ]] || { printf '%s segment %s covered %s times\n' "$suite" "$index" "$count"; exit 1; }
    done
    total=$(printf '%s' "$covered" | tr ' ' '\n' | grep -c '^[0-9][0-9]*$' || true)
    [[ "$total" == "$declared" ]] || { printf '%s covers %s segments, declared %s\n' "$suite" "$total" "$declared"; exit 1; }
done
[[ "$(guards "$ROOT_DIR/tests/test-motd.sh" | tr '\n' ' ')" == "0 1 2 3 4 5 6 7 " ]]
[[ "$(guards "$ROOT_DIR/tests/test-cloudflare-tunnel.sh" | tr '\n' ' ')" == "0 1 2 3 4 5 6 7 " ]]
[[ "$(guards "$ROOT_DIR/tests/test-push-worker-registration.sh" | tr '\n' ' ')" == "0 1 2 3 " ]]
# TEST_SEGMENTS wins over nothing: the subset must run only the named segments.
cat > "$TEMP_DIR/tests/test-motd.sh" <<'FIXTURE'
#!/usr/bin/env bash
printf 'test-motd.sh%s\n' "${TEST_SEGMENT:+-$TEST_SEGMENT}" >> "$CAPTURE"
FIXTURE
check_subset() {
    local expected=$1 set=$2
    : > "$CAPTURE"
    rc=0
    TEST_SEGMENTS=4 TEST_SEGMENT_SET="$set" bash "$TEMP_DIR/tests/run.sh" motd > "$TEMP_DIR/output" 2>&1 || rc=$?
    [[ "$rc" == 0 ]] || { cat "$TEMP_DIR/output"; exit 1; }
    [[ "$(sort "$CAPTURE")" == "$(printf '%s\n' "$expected" | sort)" ]] || { cat "$TEMP_DIR/output"; exit 1; }
}
check_subset 'test-motd.sh-0
test-motd.sh-3' '0 3'
check_subset 'test-motd.sh-2' '2'
check_subset 'test-motd.sh-0
test-motd.sh-1
test-motd.sh-2
test-motd.sh-3' ''
# Anything but a distinct in-range index aborts before the suite starts.
for bad in '0 4' x '-1' '1 1' '4' '1,2'; do
    : > "$CAPTURE"
    rc=0
    TEST_SEGMENTS=4 TEST_SEGMENT_SET="$bad" bash "$TEMP_DIR/tests/run.sh" motd > "$TEMP_DIR/output" 2>&1 || rc=$?
    [[ "$rc" == 2 && ! -s "$CAPTURE" ]] || { printf 'subset %s accepted\n' "$bad"; exit 1; }
done
printf 'All shard fixture tests passed.\n'
