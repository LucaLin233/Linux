#!/usr/bin/env bash
set -euo pipefail

readonly ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

extract_payload() {
    awk '
        /install -m 0755 \/dev\/stdin .*<<.SCRIPT./ { capture=1; next }
        capture && $0 == "SCRIPT" { exit }
        capture { print }
    ' "$1"
}

extract_payload "$ROOT_DIR/modules/system-customize.sh" > "$TEST_DIR/module"
extract_payload "$ROOT_DIR/tools/setup-motd.sh" > "$TEST_DIR/tool"
cmp -s "$TEST_DIR/module" "$TEST_DIR/tool" || fail "MOTD payloads differ"
pass "MOTD payloads stay identical"

if grep -Fq 'sleep 0.5' "$TEST_DIR/module"; then
    fail "MOTD payload still delays login"
fi
pass "MOTD payload has no fixed login delay"

grep -Fq 'export LC_ALL=C' "$TEST_DIR/module" || fail "MOTD payload does not pin parser locale"
pass "MOTD payload pins parser locale"

# shellcheck source=../tools/setup-motd.sh
source "$ROOT_DIR/tools/setup-motd.sh"
trap 'rm -rf "$TEST_DIR"' EXIT
managed="$TEST_DIR/motd"
printf original > "$managed"
backup_managed_file "$managed"
printf first > "$managed"
backup_managed_file "$managed"
printf second > "$managed"
restore_managed_file "$managed" previous
[[ "$(<"$managed")" == first ]] || fail "previous restore did not recover last state"
pass "restore previous MOTD state"
restore_managed_file "$managed" initial
[[ "$(<"$managed")" == original ]] || fail "initial restore did not recover original state"
pass "restore initial MOTD state"

printf 'All MOTD tests passed.\n'
