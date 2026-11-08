#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT
mkdir -p "$TEMP_DIR/tests" "$TEMP_DIR/bin"
cp "$ROOT_DIR/tests/run.sh" "$TEMP_DIR/tests/run.sh"
# Only stub suites run here; never invoke production scripts or the real suite.
for name in cloudflare-tunnel linux-setup motd push-worker-registration push setup-exec ssh-security xanmod; do
    printf '#!/usr/bin/env bash\nset -euo pipefail\nprintf "%%s\\n" "%s" >> "$CAPTURE"\n' "test-$name.sh" > "$TEMP_DIR/tests/test-$name.sh"
done
cat > "$TEMP_DIR/bin/git" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == *"--no-renames -z base...head --" ]] || exit 90
[[ "${DIFF_FAIL:-0}" == 0 ]] || exit 1
cat "$CHANGES"
STUB
chmod +x "$TEMP_DIR/bin/git"
export PATH="$TEMP_DIR/bin:$PATH"
export CAPTURE="$TEMP_DIR/capture" CHANGES="$TEMP_DIR/changes"
export GITHUB_STEP_SUMMARY="$TEMP_DIR/summary"
export TEST_BASE_SHA=base TEST_HEAD_SHA=head DIFF_FAIL=0
all=$(printf 'test-%s.sh\n' cloudflare-tunnel linux-setup motd push-worker-registration push setup-exec ssh-security xanmod)
check() {
    local expected=$1 actual
    shift
    : > "$CHANGES"; : > "$CAPTURE"; : > "$GITHUB_STEP_SUMMARY"
    if (( $# )); then printf '%s\0' "$@" > "$CHANGES"; fi
    bash "$TEMP_DIR/tests/run.sh" > "$TEMP_DIR/output" 2>&1
    actual=$(cat "$CAPTURE")
    [[ "$actual" == "$expected" ]] || { cat "$TEMP_DIR/output"; printf 'Unexpected selection: %s\n' "$actual" >&2; exit 1; }
}
check test-motd.sh tools/setup-motd.sh
check $'test-motd.sh\ntest-xanmod.sh' modules/system-customize.sh
check $'test-push-worker-registration.sh\ntest-push.sh' tools/push.sh
check test-cloudflare-tunnel.sh tools/cloudflare_tunnel.sh
check test-ssh-security.sh modules/ssh-security.sh
check test-linux-setup.sh modules/zsh-setup.sh p10k-config.zsh
check $'test-linux-setup.sh\ntest-setup-exec.sh' linux_setup.sh
check test-xanmod.sh tools/xanmod-install.sh
check $'test-motd.sh\ntest-ssh-security.sh' tools/setup-motd.sh modules/ssh-security.sh
check test-motd.sh tests/test-motd.sh
check "" README.md LICENSE
check ""
check "$all" tests/run.sh
check "$all" .github/workflows/shell-tests.yml
check "$all" tests/test-deleted.sh
check "$all" tools/setup-motd.sh tools/renamed-motd.sh
check "$all" $'unknown file\nwith newline.sh'
DIFF_FAIL=1 check "$all" README.md
TEST_BASE_SHA= TEST_HEAD_SHA= check "$all" README.md
TEST_HEAD_SHA= check "$all" README.md
# A failed child must keep its own errexit and stop later suites.
printf '#!/usr/bin/env bash\nset -euo pipefail\nfalse\nprintf "unexpected\\n" >> "$CAPTURE"\n' > "$TEMP_DIR/tests/test-cloudflare-tunnel.sh"
: > "$CAPTURE"
DIFF_FAIL=1
rc=0
bash "$TEMP_DIR/tests/run.sh" > "$TEMP_DIR/output" 2>&1 || rc=$?
[[ "$rc" == 1 && ! -s "$CAPTURE" ]] || { cat "$TEMP_DIR/output"; exit 1; }
grep -q "exit=1" "$TEMP_DIR/output"
grep -q "exit 1" "$GITHUB_STEP_SUMMARY"
printf 'All selection fixture tests passed.\n'
