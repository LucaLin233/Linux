#!/usr/bin/env bash
set -euo pipefail
# Execute only the workflow lint block against inert files and a ShellCheck spy.
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
unset GH_TOKEN GITHUB_TOKEN SSH_PRIVATE_KEY_B64
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_CONFIG_COUNT
root=$(mktemp -d)
cleanup() { rm -rf -- "$root"; }
trap cleanup EXIT
# Fail closed if the named step or its literal block changes shape.
awk '
    /^      - name: Run ShellCheck$/ { found++; step=1; next }
    step && /^        run: \|$/ { block=1; next }
    block && /^          / { print substr($0, 11); lines++; next }
    block { step=0; block=0 }
    END { if (found != 1 || lines == 0) exit 1 }
' "$ROOT_DIR/.github/workflows/shell-tests.yml" > "$root/lint.sh"
# Both groups must keep the per-file, four-way parallel invocation.
if [[ "$(grep -c -- '-n1 -P4' "$root/lint.sh")" != 2 ]]; then
    printf 'the lint block no longer starts both groups with -n1 -P4\n' >&2
    exit 1
fi
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
        "production :!:tests/**"|"both :!:tests/**") exit 1 ;;
        "tests tests/*.sh"|"both tests/*.sh") exit 1 ;;
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
cat "$root/production.expected" "$root/tests.expected" > "$root/all.expected"
# Multiset comparison: every tracked script of both groups exactly once, with
# its own group's severity.  Sorting keeps the parallel order out of the verdict,
# while a duplicated or a missing file still shows up as a difference.
check_linted() {
    local label=$1 expected=$2
    LC_ALL=C sort "$root/capture" > "$root/capture.sorted"
    LC_ALL=C sort "$expected" > "$root/expected.sorted"
    if ! diff -u "$root/expected.sorted" "$root/capture.sorted"; then
        printf 'FAIL: %s: linted file set is not the tracked split\n' "$label" >&2
        exit 1
    fi
}
run_lint() {
    local status=0
    bash --noprofile --norc -e -o pipefail "$root/lint.sh" || status=$?
    printf '%s' "$status"
}
# Both groups must always be linted in full, and a failure in either one must
# fail the step: the four result combinations cover that.
export ENUM_FAIL=none
for PRODUCTION_STATUS in 0 1; do
    for TEST_STATUS in 0 1; do
        export PRODUCTION_STATUS TEST_STATUS
        : > "$CAPTURE"
        status=$(run_lint)
        expected=0
        if (( PRODUCTION_STATUS != 0 || TEST_STATUS != 0 )); then expected=1; fi
        [[ $status == "$expected" ]] \
            || { printf 'FAIL: lint exited %s, expected %s\n' "$status" "$expected" >&2; exit 1; }
        check_linted "production=$PRODUCTION_STATUS tests=$TEST_STATUS" "$root/all.expected"
        printf "PASS: workflow lint production=%s tests=%s exit=%s\n" \
            "$PRODUCTION_STATUS" "$TEST_STATUS" "$status"
    done
done
# A failed enumeration must fail the step without hiding the other group: the
# background pipeline keeps pipefail, so git failing is not swallowed by the
# empty xargs run behind it.
for ENUM_FAIL in production tests both; do
    export ENUM_FAIL PRODUCTION_STATUS=0 TEST_STATUS=0
    : > "$CAPTURE"
    status=$(run_lint)
    [[ $status == 1 ]] \
        || { printf 'FAIL: %s enumeration failure exited %s\n' "$ENUM_FAIL" "$status" >&2; exit 1; }
    case "$ENUM_FAIL" in
        production) check_linted "$ENUM_FAIL enumeration failure" "$root/tests.expected" ;;
        tests) check_linted "$ENUM_FAIL enumeration failure" "$root/production.expected" ;;
        both) [[ ! -s "$CAPTURE" ]] \
            || { printf 'FAIL: both enumerations failed but files were linted\n' >&2; exit 1; } ;;
    esac
    printf 'PASS: %s enumeration failure exits 1\n' "$ENUM_FAIL"
done
