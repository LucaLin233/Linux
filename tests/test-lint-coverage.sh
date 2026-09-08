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
mkdir -p "$root/bin" "$root/repo"
cat > "$root/bin/shellcheck" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ $1 == -x && $3 == -- && $# -gt 3 ]] || exit 90
level=$2
shift 3
for path; do printf "%s\t%s\n" "$level" "$path" >> "$CAPTURE"; done
case $level in
    --severity=warning) exit "$PRODUCTION_STATUS" ;;
    --severity=error) exit "$TEST_STATUS" ;;
    *) exit 91 ;;
esac
STUB
chmod +x "$root/bin/shellcheck"
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
    $'--severity=warning\tnew/space name.sh' \
    $'--severity=error\ttests/direct.sh' \
    $'--severity=error\ttests/nested/deep.sh' > "$root/expected"
for PRODUCTION_STATUS in 0 1; do
    for TEST_STATUS in 0 1; do
        export PRODUCTION_STATUS TEST_STATUS
        : > "$CAPTURE"
        status=0
        bash --noprofile --norc -e -o pipefail "$root/lint.sh" || status=$?
        expected=0
        if (( PRODUCTION_STATUS != 0 || TEST_STATUS != 0 )); then expected=1; fi
        [[ $status == "$expected" ]]
        diff -u "$root/expected" "$CAPTURE"
        printf "PASS: workflow lint production=%s tests=%s exit=%s\n" "$PRODUCTION_STATUS" "$TEST_STATUS" "$status"
    done
done
