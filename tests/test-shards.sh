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
# Segment coverage: one suite can be spread over several jobs, so every segment
# of a suite must be covered by exactly one job in each OS matrix, and every job
# must name real segments of the suite's source.  Nothing is deduplicated before
# the checks: a repeated shard name or a repeated segment is a failure.
guards() {
    awk '/^if seg_is [0-9]+; then$/ { n = $3; sub(";", "", n); print n }' "$1"
}
# run.sh is the single source of truth for which suites are segmented and how
# many segments each one has.
segmented_suites() {
    awk '
        /^declare -rA SEGMENTED_SUITES=\(/ { inside = 1; next }
        inside && /^\)/ { inside = 0; next }
        inside {
            entry = $1
            if (entry !~ /^\[test-[^]]*\.sh\]=[0-9]+$/) next
            name = entry; sub(/^\[/, "", name); sub(/\]=.*/, "", name)
            count = entry; sub(/^.*\]=/, "", count)
            print name, count
        }
    ' "$ROOT_DIR/tests/run.sh"
}
file_of_suite() {
    case $1 in
        motd) printf 'test-motd.sh' ;;
        cloudflare) printf 'test-cloudflare-tunnel.sh' ;;
        push-worker) printf 'test-push-worker-registration.sh' ;;
        push) printf 'test-push.sh' ;;
        *) return 1 ;;
    esac
}
suite_of_file() {
    case $1 in
        test-motd.sh) printf 'motd' ;;
        test-cloudflare-tunnel.sh) printf 'cloudflare' ;;
        test-push-worker-registration.sh) printf 'push-worker' ;;
        test-push.sh) printf 'push' ;;
        *) return 1 ;;
    esac
}
fail() { printf '%s\n' "$*" >&2; exit 1; }
workflow="$ROOT_DIR/.github/workflows/shell-tests.yml"
[[ -f "$workflow" ]]
# job|shard|suite|segments|segment_set, one line per matrix entry, duplicates kept.
jobs=$(awk '
    /^  [a-z][a-z0-9-]*:$/ {
        if (suite != "") print job "|" shard "|" suite "|" segments "|" set
        job = $1; sub(/:$/, "", job); shard = ""; suite = ""; segments = ""; set = ""
        next
    }
    /^[[:space:]]*- shard:/ {
        if (suite != "") print job "|" shard "|" suite "|" segments "|" set
        shard = $3; suite = ""; segments = ""; set = ""
        next
    }
    /^[[:space:]]+suite:/ { suite = $2; next }
    /^[[:space:]]+segments:/ { segments = $2; next }
    /^[[:space:]]+segment_set:/ {
        set = $0
        sub(/^[[:space:]]*segment_set:[[:space:]]*/, "", set)
        gsub(/"/, "", set)
        next
    }
    END { if (suite != "") print job "|" shard "|" suite "|" segments "|" set }
' "$workflow")
[[ -n "$jobs" ]] || fail 'no shard matrix in the workflow'

# One OS matrix on its own: unique shard names, every segment of every suite
# covered exactly once, union 0..N-1.
check_matrix() {
    local job=$1 rows suite row_suite suite_segments segment_set_value
    local declared covered index count total expected actual token
    local -a set_tokens=()
    rows=$(printf '%s\n' "$jobs" | awk -F'|' -v job="$job" '$1 == job')
    [[ -n "$rows" ]] || fail "no matrix rows for $job"
    if printf '%s\n' "$rows" | cut -d'|' -f2 | sort | uniq -d | grep -q .; then
        fail "$job repeats a shard name"
    fi
    for suite in motd cloudflare push-worker push other; do
        declared=""
        covered=" "
        while IFS='|' read -r _job _shard row_suite suite_segments segment_set_value; do
            [[ "$row_suite" == "$suite" ]] || continue
            case "$suite_segments" in
                ''|*[!0-9]*) fail "$job $suite has an unsupported segment count: '$suite_segments'" ;;
            esac
            if [[ -n "$segment_set_value" ]]; then
                # Strict tokens, checked before any coverage arithmetic: a set
                # carries decimal indices of the declared range, so a trailing
                # "x" (or "10x") fails here instead of being filtered out.
                read -r -a set_tokens <<< "$segment_set_value"
                for token in "${set_tokens[@]}"; do
                    [[ "$token" =~ ^([0-9]|1[01])$ ]] \
                        || fail "$job $suite has an invalid segment_set entry: '$token'"
                    (( token < suite_segments )) \
                        || fail "$job $suite segment_set entry $token is outside 0..$(( suite_segments - 1 ))"
                done
            fi
            if [[ -z "$declared" ]]; then
                declared=$suite_segments
            elif [[ "$declared" != "$suite_segments" ]]; then
                fail "$job $suite mixes segment counts: $declared and $suite_segments"
            fi
            if [[ -z "$segment_set_value" ]]; then
                for (( index = 0; index < suite_segments; index++ )); do
                    covered+=" $index"
                done
            else
                covered+=" $segment_set_value"
            fi
        done <<< "$rows"
        [[ -n "$declared" ]] || fail "$job has no job for $suite"
        for (( index = 0; index < declared; index++ )); do
            count=$(printf '%s' "$covered" | tr ' ' '\n' | grep -cx -- "$index" || true)
            [[ "$count" == 1 ]] || fail "$job $suite segment $index covered $count times"
        done
        total=$(printf '%s' "$covered" | tr ' ' '\n' | grep -cE '^[0-9]+$' || true)
        [[ "$total" == "$declared" ]] || fail "$job $suite covers $total segments, declared $declared"
        expected=$(seq -s ' ' 0 "$(( declared - 1 ))")
        actual=$(printf '%s' "$covered" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -n -u | tr '\n' ' ')
        actual=${actual% }
        [[ "$actual" == "$expected" ]] || fail "$job $suite covers '$actual', expected '$expected'"
    done
}

# The declared counts must be the ones the sources actually implement, and both
# OS matrices must agree on them.
declared_segments() {
    local job=$1 suite=$2 rows first
    rows=$(printf '%s\n' "$jobs" | awk -F'|' -v job="$job" -v suite="$suite" \
        '$1 == job && $3 == suite { print $4 }')
    [[ -n "$rows" ]] || fail "$job has no job for $suite"
    first=$(printf '%s\n' "$rows" | head -1)
    [[ "$(printf '%s\n' "$rows" | grep -cx -- "$first" || true)" == \
        "$(printf '%s\n' "$rows" | grep -c . || true)" ]] || fail "$job $suite mixes segment counts"
    printf '%s' "$first"
}

check_suites() {
    local suite file declared ubuntu_declared debian_declared guards_list guard_count expected name
    local -A families=()
    while read -r name count; do
        [[ -n "$name" ]] || continue
        families[$name]=$count
    done <<< "$(segmented_suites)"
    (( ${#families[@]} > 0 )) || fail 'run.sh declares no segmented suite'
    for name in "${!families[@]}"; do
        suite_of_file "$name" > /dev/null || fail "run.sh segments $name, which is not in the matrix"
    done
    for suite in motd cloudflare push-worker push other; do
        ubuntu_declared=$(declared_segments ubuntu-tests "$suite")
        debian_declared=$(declared_segments debian-tests "$suite")
        [[ "$ubuntu_declared" == "$debian_declared" ]] \
            || fail "$suite has $ubuntu_declared segments on Ubuntu but $debian_declared on Debian"
        declared=$ubuntu_declared
        if file=$(file_of_suite "$suite"); then
            guards_list=$(guards "$ROOT_DIR/tests/$file")
            guard_count=$(printf '%s' "$guards_list" | grep -c . || true)
            if (( declared > 1 )); then
                [[ -n "${families[$file]:-}" ]] || fail "$suite runs $declared segments but run.sh does not segment $file"
                [[ "${families[$file]}" == "$declared" ]] \
                    || fail "run.sh cuts $file into ${families[$file]} segments, the matrix says $declared"
                [[ "$guard_count" == "$declared" ]] \
                    || fail "$file has $guard_count segment guards, the matrix says $declared"
                expected=$(seq -s ' ' 0 "$(( declared - 1 ))")
                [[ "$(printf '%s\n' "$guards_list" | tr '\n' ' ')" == "$expected " ]] \
                    || fail "$file guard numbers are not 0..$(( declared - 1 ))"
            else
                [[ -z "${families[$file]:-}" ]] || fail "run.sh segments $file but its jobs run it whole"
                [[ "$guard_count" == 0 ]] || fail "$file has segment guards but its jobs run it whole"
            fi
        else
            # `other` is a bucket of suites, not a suite that can be cut up.
            (( declared == 1 )) || fail "$suite is a bucket and cannot be cut into $declared segments"
        fi
    done
}

check_matrix ubuntu-tests
check_matrix debian-tests
check_suites

# Subset execution: every segmented family must run only the segments its job
# names, and a segment count or subset the suite cannot honour must abort before
# the first suite starts.  TEST_SEGMENTS=1 still runs a suite whole in one
# process.
make_segment_fixture() {
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s${TEST_SEGMENT:+-$TEST_SEGMENT}" >> "$CAPTURE"\n' "$1" \
        > "$TEMP_DIR/tests/$1"
}
make_segment_fixture test-motd.sh
make_segment_fixture test-cloudflare-tunnel.sh
make_segment_fixture test-push-worker-registration.sh
check_subset() {
    local suite=$1 segs=$2 set_value=$3 expected=$4 rc=0 actual
    : > "$CAPTURE"
    TEST_SEGMENTS="$segs" TEST_SEGMENT_SET="$set_value" bash "$TEMP_DIR/tests/run.sh" "$suite" \
        > "$TEMP_DIR/output" 2>&1 || rc=$?
    [[ "$rc" == 0 ]] || { cat "$TEMP_DIR/output"; fail "subset '$set_value' for $suite (TEST_SEGMENTS=$segs) exited $rc"; }
    actual=$(sort "$CAPTURE" | tr '\n' ' ')
    [[ "$actual" == "$(printf '%s\n' "$expected" | sort | tr '\n' ' ')" ]] || {
        cat "$TEMP_DIR/output"
        fail "subset '$set_value' for $suite ran: $actual"
    }
}
check_subset motd 11 '0 1 2 3' 'test-motd.sh-0
test-motd.sh-1
test-motd.sh-2
test-motd.sh-3'
# Double-digit segments must run as themselves, not as "1" plus a stray "0".
check_subset motd 11 '8 9 10' 'test-motd.sh-8
test-motd.sh-9
test-motd.sh-10'
check_subset motd 11 '' 'test-motd.sh-0
test-motd.sh-1
test-motd.sh-2
test-motd.sh-3
test-motd.sh-4
test-motd.sh-5
test-motd.sh-6
test-motd.sh-7
test-motd.sh-8
test-motd.sh-9
test-motd.sh-10'
check_subset motd 1 '' 'test-motd.sh'
check_subset cloudflare 12 '0 2 6 9' 'test-cloudflare-tunnel.sh-0
test-cloudflare-tunnel.sh-2
test-cloudflare-tunnel.sh-6
test-cloudflare-tunnel.sh-9'
check_subset cloudflare 12 '1 3 5 7' 'test-cloudflare-tunnel.sh-1
test-cloudflare-tunnel.sh-3
test-cloudflare-tunnel.sh-5
test-cloudflare-tunnel.sh-7'
check_subset cloudflare 12 '4 8 10 11' 'test-cloudflare-tunnel.sh-4
test-cloudflare-tunnel.sh-8
test-cloudflare-tunnel.sh-10
test-cloudflare-tunnel.sh-11'
check_subset cloudflare 12 '' 'test-cloudflare-tunnel.sh-0
test-cloudflare-tunnel.sh-1
test-cloudflare-tunnel.sh-2
test-cloudflare-tunnel.sh-3
test-cloudflare-tunnel.sh-4
test-cloudflare-tunnel.sh-5
test-cloudflare-tunnel.sh-6
test-cloudflare-tunnel.sh-7
test-cloudflare-tunnel.sh-8
test-cloudflare-tunnel.sh-9
test-cloudflare-tunnel.sh-10
test-cloudflare-tunnel.sh-11'
check_subset cloudflare 1 '' 'test-cloudflare-tunnel.sh'
check_subset push-worker 7 '2' 'test-push-worker-registration.sh-2'
check_subset push-worker 7 '0 1 2 3' 'test-push-worker-registration.sh-0
test-push-worker-registration.sh-1
test-push-worker-registration.sh-2
test-push-worker-registration.sh-3'
check_subset push-worker 7 '4 5 6' 'test-push-worker-registration.sh-4
test-push-worker-registration.sh-5
test-push-worker-registration.sh-6'
check_subset push-worker 7 '' 'test-push-worker-registration.sh-0
test-push-worker-registration.sh-1
test-push-worker-registration.sh-2
test-push-worker-registration.sh-3
test-push-worker-registration.sh-4
test-push-worker-registration.sh-5
test-push-worker-registration.sh-6'
check_subset push-worker 1 '' 'test-push-worker-registration.sh'

check_reject() {
    local label=$1 suite=$2 segs=$3 set_value=$4 rc=0
    : > "$CAPTURE"
    TEST_SEGMENTS="$segs" TEST_SEGMENT_SET="$set_value" bash "$TEMP_DIR/tests/run.sh" "$suite" \
        > "$TEMP_DIR/output" 2>&1 || rc=$?
    [[ "$rc" == 2 ]] || { cat "$TEMP_DIR/output"; fail "$label: exit $rc, expected 2"; }
    [[ ! -s "$CAPTURE" ]] || { cat "$TEMP_DIR/output"; fail "$label: started a suite"; }
}
# A segment count the suite's source does not have would silently run part of it.
check_reject 'motd cut into two' motd 2 ''
check_reject 'motd cut into four' motd 4 ''
check_reject 'motd cut into eight' motd 8 ''
check_reject 'motd cut into twelve' motd 12 ''
check_reject 'cloudflare cut into four' cloudflare 4 ''
check_reject 'cloudflare cut into eight' cloudflare 8 ''
check_reject 'cloudflare cut into two' cloudflare 2 ''
check_reject 'push-worker cut into eight' push-worker 8 ''
check_reject 'push-worker cut into four' push-worker 4 ''
check_reject 'push-worker cut into two' push-worker 2 ''
check_reject 'motd segment past its source' motd 11 '11'
check_reject 'subset for an unsegmented suite' push 2 '0'
check_reject 'subset for the other bucket' other 2 '0'
check_reject 'subset without segmented mode' motd 1 '0'
check_reject 'mixed plan with one count' all 8 ''
check_reject 'mixed plan with four segments' all 4 '0 1 2 3'
# Anything but a distinct in-range index of the declared range is refused, and
# the refusal has to come from the segment validation itself: the declared count
# stays untouched, so a count mismatch cannot stand in for a token that got
# through.  A file named 1 must not turn "[1]" into a real segment.
segment_rejection='Invalid TEST_SEGMENT_SET entry|Duplicate segment in TEST_SEGMENT_SET|out of range for TEST_SEGMENTS'
check_bad_set() {
    local suite=$1 segs=$2 bad=$3 rc=0
    : > "$CAPTURE"
    ( cd "$TEMP_DIR" && TEST_SEGMENTS="$segs" TEST_SEGMENT_SET="$bad" \
        bash "$TEMP_DIR/tests/run.sh" "$suite" > "$TEMP_DIR/output" 2>&1 ) || rc=$?
    [[ "$rc" == 2 && ! -s "$CAPTURE" ]] || { cat "$TEMP_DIR/output"; fail "subset '$bad' for $suite accepted (exit $rc)"; }
    grep -qE "$segment_rejection" "$TEMP_DIR/output" \
        || { cat "$TEMP_DIR/output"; fail "subset '$bad' for $suite was not refused by the segment validation"; }
}
: > "$TEMP_DIR/1"
for bad in '1 01' '9223372036854775808' '18446744073709551616' '[1]' '1,2' '-1' '1 1' '+1' '0x1' 'x'; do
    check_bad_set motd 11 "$bad"
done
for bad in '10x' '11' '010' '1 10 10' '0 11'; do
    check_bad_set motd 11 "$bad"
done
# The seven-segment suite validates its own tokens the same way, so a set that
# only matches a stale segment count cannot pass for a good one.
for bad in '0 1 2 3x' '4 5 6x' '7' '6 6' '+1' '010'; do
    check_bad_set push-worker 7 "$bad"
done

# The twelve-segment suite validates its own tokens the same way, so a set that
# only matches the old eight-segment layout cannot pass for a good one.
for bad in '0 1 2 3x' '0 2 6x' '12' '11 11' '+1' '010'; do
    check_bad_set cloudflare 12 "$bad"
done
for bad in 0 9 08 '4x' '1 4' 9223372036854775808 18446744073709551616; do
    : > "$CAPTURE"
    rc=0
    TEST_SEGMENTS="$bad" bash "$TEMP_DIR/tests/run.sh" motd > "$TEMP_DIR/output" 2>&1 || rc=$?
    [[ "$rc" == 2 && ! -s "$CAPTURE" ]] || { cat "$TEMP_DIR/output"; fail "TEST_SEGMENTS=$bad accepted (exit $rc)"; }
done
printf 'All shard fixture tests passed.\n'
