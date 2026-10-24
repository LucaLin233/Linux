#!/usr/bin/env bash
set -euo pipefail
# Execute each workflow lint step against inert files and a ShellCheck spy.  The
# two groups live in separate jobs, so every check runs one step on its own: its
# exit status, its linted file set, and its enumeration failure.  The required
# Ubuntu check must still gate both jobs.
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
unset GH_TOKEN GITHUB_TOKEN SSH_PRIVATE_KEY_B64
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_CONFIG_COUNT
root=$(mktemp -d)
cleanup() { rm -rf -- "$root"; }
trap cleanup EXIT
workflow="$ROOT_DIR/.github/workflows/shell-tests.yml"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
# Fail closed if the named step is missing, repeated, or its literal block
# changed shape.
extract_step() {
    local name=$1 out=$2
    rm -f -- "$out"
    if ! awk -v name="$name" -v out="$out" '
        $0 == "      - name: " name { found++; step = 1; next }
        step && /^        run: \|$/ { block = 1; next }
        block && /^          / { print substr($0, 11) > out; lines++; next }
        block { step = 0; block = 0 }
        END { if (found != 1 || lines == 0) exit 1 }
    ' "$workflow"; then
        fail "workflow step '$name' is missing, repeated, or has no literal run block"
    fi
}
extract_step 'Run ShellCheck' "$root/production.sh"
extract_step 'Run ShellCheck tests' "$root/tests.sh"
# Each step owns exactly one group: one per-file four-way pipeline, at that
# group's severity, with no trace of the other group's file selection.
check_step() {
    local label=$1 file=$2 severity=$3 foreign=$4
    [[ "$(grep -c -- '-n1 -P4' "$file" || true)" == 1 ]] \
        || fail "$label does not start exactly one -n1 -P4 pipeline"
    [[ "$(grep -c -- "--severity=$severity" "$file" || true)" == 1 ]] \
        || fail "$label does not use exactly one --severity=$severity"
    if grep -Fq -- "$foreign" "$file"; then
        fail "$label still selects the other group's files ($foreign)"
    fi
}
check_step 'the production lint step' "$root/production.sh" warning 'tests/*.sh'
check_step 'the tests lint step' "$root/tests.sh" error ':!:tests/**'
mkdir -p "$root/bin" "$root/repo"
cat > "$root/bin/shellcheck" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
# One file per call (xargs -n1), classified by severity: anything else is a defect.
[[ $# -eq 4 && $1 == -x && $3 == -- ]] || exit 90
level=$2
shift 3
printf "%s\t%s\n" "$level" "$1" >> "$CAPTURE"
case $level in
    --severity=warning) exit "$PRODUCTION_STATUS" ;;
    --severity=error) exit "$TEST_STATUS" ;;
    *) exit 91 ;;
esac
STUB
chmod +x "$root/bin/shellcheck"
real_git=$(command -v git)
cat > "$root/bin/git" <<STUB
#!/usr/bin/env bash
set -euo pipefail
# Only a file enumeration may be made to fail; everything else is real Git.
for arg in "\$@"; do
    case "\${ENUM_FAIL:-none} \$arg" in
        "production :!:tests/**") exit 1 ;;
        "tests tests/*.sh") exit 1 ;;
    esac
done
exec "$real_git" "\$@"
STUB
chmod +x "$root/bin/git"
export PATH="$root/bin:$PATH" CAPTURE="$root/capture"
cd "$root/repo"
git init -q
mkdir -p new/deep tests/nested
touch entry.sh new/deep/production.sh "new/space name.sh" tests/direct.sh tests/nested/deep.sh ignored.zsh
git add .
touch untracked.sh
printf "%s\n" \
    $'--severity=warning\tentry.sh' \
    $'--severity=warning\tnew/deep/production.sh' \
    $'--severity=warning\tnew/space name.sh' > "$root/production.expected"
printf "%s\n" \
    $'--severity=error\ttests/direct.sh' \
    $'--severity=error\ttests/nested/deep.sh' > "$root/tests.expected"
# Multiset comparison: every tracked script of the group exactly once, with the
# group's own severity.  Sorting keeps the parallel order out of the verdict,
# while a duplicated or a missing file still shows up as a difference.
check_linted() {
    local label=$1 expected=$2
    LC_ALL=C sort "$root/capture" > "$root/capture.sorted"
    LC_ALL=C sort "$expected" > "$root/expected.sorted"
    if ! diff -u "$root/expected.sorted" "$root/capture.sorted"; then
        fail "$label: linted file set is not the tracked group"
    fi
}
run_step() {
    local status=0
    bash --noprofile --norc -e -o pipefail "$1" || status=$?
    printf '%s' "$status"
}
# A step must follow its own group alone: the other group's status is held at 0
# and must not leak into this step's exit code.
export ENUM_FAIL=none
for group in production tests; do
    for group_status in 0 1; do
        if [[ "$group" == production ]]; then
            export PRODUCTION_STATUS=$group_status TEST_STATUS=0
            step=$root/production.sh expected=$root/production.expected
        else
            export PRODUCTION_STATUS=0 TEST_STATUS=$group_status
            step=$root/tests.sh expected=$root/tests.expected
        fi
        : > "$CAPTURE"
        status=$(run_step "$step")
        [[ "$status" == "$group_status" ]] \
            || fail "$group step exited $status with its group at $group_status"
        check_linted "$group=$group_status" "$expected"
        printf 'PASS: %s lint step exit=%s follows its own group\n' "$group" "$status"
    done
done
# A failed enumeration must fail that step and lint nothing: the pipeline keeps
# pipefail, so git failing is not swallowed by the empty xargs run behind it.
for group in production tests; do
    export ENUM_FAIL=$group PRODUCTION_STATUS=0 TEST_STATUS=0
    if [[ "$group" == production ]]; then step=$root/production.sh; else step=$root/tests.sh; fi
    : > "$CAPTURE"
    status=$(run_step "$step")
    [[ "$status" == 1 ]] || fail "$group enumeration failure exited $status"
    [[ ! -s "$CAPTURE" ]] || fail "$group enumeration failure still linted files"
    printf 'PASS: %s enumeration failure exits 1 without linting\n' "$group"
done
# The required check name must stay, and it must depend on both lint jobs and
# every Ubuntu shard, asserting each dependency's result; a job left out of
# `needs` would let its failure merge as green.
awk '
    /^  [a-z][a-z0-9-]*:$/ { job = $1; sub(/:$/, "", job) }
    job == "ubuntu" { print }
' "$workflow" > "$root/aggregate.yml"
[[ -s "$root/aggregate.yml" ]] || fail 'the workflow has no ubuntu aggregation job'
grep -qx '    name: Ubuntu 24.04 lint and tests' "$root/aggregate.yml" \
    || fail 'the ubuntu aggregation job no longer carries the required check name'
grep -qx '    name: Debian 13 tests' "$workflow" \
    || fail 'the workflow no longer carries the Debian required check name'
needs=$(awk '/^    needs: / { sub(/^    needs: \[/, ""); sub(/\].*$/, ""); print; exit }' "$root/aggregate.yml")
[[ -n "$needs" ]] || fail 'the ubuntu aggregation job has no inline needs list'
entries=$(printf '%s\n' "$needs" | tr ',' '\n' | sed 's/[[:space:]]//g' | grep -c . || true)
for required in lint lint-tests ubuntu-tests; do
    printf '%s\n' "$needs" | tr ',' '\n' | sed 's/[[:space:]]//g' | grep -qx -- "$required" \
        || fail "the ubuntu aggregation job does not need $required"
done
checks=$(grep -c -- '= success' "$root/aggregate.yml" || true)
[[ "$checks" == "$entries" ]] \
    || fail "the ubuntu job needs $entries jobs but asserts $checks results"
printf 'PASS: ubuntu aggregation needs and asserts %s\n' "$needs"
