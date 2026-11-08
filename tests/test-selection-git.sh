#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT
# Real Git, local commits only. Suites are inert fixtures, not production code.
unset GH_TOKEN GITHUB_TOKEN SSH_PRIVATE_KEY_B64 TEST_BASE_SHA TEST_HEAD_SHA
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_CONFIG_COUNT
repo="$TEMP_DIR/repo"
mkdir -p "$repo/tests" "$repo/tools"
cp "$ROOT_DIR/tests/run.sh" "$repo/tests/run.sh"
export CAPTURE="$TEMP_DIR/capture" GITHUB_STEP_SUMMARY="$TEMP_DIR/summary"
for name in cloudflare-tunnel motd; do
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s" >> "$CAPTURE"\n' "test-$name.sh" > "$repo/tests/test-$name.sh"
done
git init -q "$repo"
git -C "$repo" config user.name 'Selection fixture'
git -C "$repo" config user.email 'selection@example.invalid'
git -C "$repo" add .
git -C "$repo" commit -qm baseline
base=$(git -C "$repo" rev-parse HEAD)
check() {
    local expected=$1 full=$2
    : > "$CAPTURE"
    bash "$repo/tests/run.sh" > "$TEMP_DIR/output" 2>&1
    [[ "$(cat "$CAPTURE")" == "$expected" ]] || { cat "$TEMP_DIR/output"; exit 1; }
    grep -Fxq "Test selection: full=$full" "$TEMP_DIR/output"
}
commit() {
    git -C "$repo" add -A
    git -C "$repo" commit -qm change
    export TEST_HEAD_SHA
    TEST_HEAD_SHA=$(git -C "$repo" rev-parse HEAD)
}
export TEST_BASE_SHA="$base" TEST_HEAD_SHA="$base"
check '' false
printf 'fixture\n' > "$repo/tools/cloudflare_tunnel.sh"
commit
check test-cloudflare-tunnel.sh false
# Full PR range, not merely the last commit.
printf 'docs\n' > "$repo/README.md"
commit
check test-cloudflare-tunnel.sh false
# Diverged base: triple-dot uses the merge base, not base-only changes.
head=$TEST_HEAD_SHA
git -C "$repo" checkout -qb base-side "$base"
printf 'base only\n' > "$repo/unknown-base-file"
commit
export TEST_BASE_SHA="$TEST_HEAD_SHA" TEST_HEAD_SHA="$head"
git -C "$repo" checkout -q --detach "$head"
check test-cloudflare-tunnel.sh false
# Rename must include the unknown destination even with rename detection enabled.
git -C "$repo" mv tools/cloudflare_tunnel.sh tools/renamed.sh
commit
check $'test-cloudflare-tunnel.sh\ntest-motd.sh' true
# Invalid history must fail open to all tests, never an empty selection.
TEST_HEAD_SHA=0000000000000000000000000000000000000000 check $'test-cloudflare-tunnel.sh\ntest-motd.sh' true
# Non-repository checkout must also run all suites.
mv "$repo/.git" "$TEMP_DIR/git-metadata"
check $'test-cloudflare-tunnel.sh\ntest-motd.sh' true
printf 'All real Git selection tests passed.\n'
