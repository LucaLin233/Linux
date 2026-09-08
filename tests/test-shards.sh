#!/usr/bin/env bash
set -euo pipefail
# Inert fixtures only: verify partitioning without running production suites.
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT
mkdir -p "$TEMP_DIR/tests" "$TEMP_DIR/bin"
cp "$ROOT_DIR/tests/run.sh" "$TEMP_DIR/tests/run.sh"
export CAPTURE="$TEMP_DIR/capture" GITHUB_STEP_SUMMARY="$TEMP_DIR/summary"
unset TEST_BASE_SHA TEST_HEAD_SHA
for name in motd push push-worker-registration new-suite; do
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s" >> "$CAPTURE"\n' "test-$name.sh" > "$TEMP_DIR/tests/test-$name.sh"
done
check() {
    local expected=$1
    shift
    : > "$CAPTURE"
    bash "$TEMP_DIR/tests/run.sh" "$@" > "$TEMP_DIR/output" 2>&1
    [[ "$(cat "$CAPTURE")" == "$expected" ]] || { cat "$TEMP_DIR/output"; exit 1; }
}
all=$'test-motd.sh\ntest-new-suite.sh\ntest-push-worker-registration.sh\ntest-push.sh'
check "$all"
check "$all" all
check test-motd.sh motd
check $'test-push-worker-registration.sh\ntest-push.sh' push
check test-new-suite.sh other
# Every current and future suite belongs to exactly one shard.
: > "$TEMP_DIR/union"
for shard in motd push other; do
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
export PATH="$TEMP_DIR/bin:$PATH" TEST_BASE_SHA=base TEST_HEAD_SHA=head
check '' motd
check '' other
check $'test-push-worker-registration.sh\ntest-push.sh' push
DIFF_FAIL=1 check test-motd.sh motd
DIFF_FAIL=1 check test-new-suite.sh other
# Child errexit and failure propagation must survive sharding.
printf '#!/usr/bin/env bash\nset -e\nfalse\nprintf unexpected >> "$CAPTURE"\n' > "$TEMP_DIR/tests/test-push-worker-registration.sh"
: > "$CAPTURE"
rc=0
bash "$TEMP_DIR/tests/run.sh" push > "$TEMP_DIR/output" 2>&1 || rc=$?
[[ "$rc" == 1 && ! -s "$CAPTURE" ]]
grep -q 'exit=1' "$TEMP_DIR/output"
printf 'All shard fixture tests passed.\n'
