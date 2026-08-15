#!/usr/bin/env bash
set -euo pipefail

readonly ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

export SBINSTALL_INSTALL_DIR="$TEMP_DIR/proxy"
export SBINSTALL_SERVICE_FILE="$TEMP_DIR/sing-box.service"
# shellcheck source=../tools/sbinstall.sh
source "$ROOT_DIR/tools/sbinstall.sh"
trap 'rm -rf "$TEMP_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }
assert_file_content() {
    local expected="$1" file="$2" name="$3"
    [[ -f "$file" && "$(<"$file")" == "$expected" ]] || fail "$name"
    pass "$name"
}

mkdir -p "$INSTALL_DIR" "$BACKUP_DIR"
fixture="$TEMP_DIR/release.json"
cat > "$fixture" <<'JSON'
{"assets":[{"name":"sing-box-1.2.3-linux-amd64.tar.gz","browser_download_url":"https://example.invalid/asset","digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}
JSON
metadata=$(release_asset_metadata "$fixture" "sing-box-1.2.3-linux-amd64.tar.gz")
[[ "$metadata" == $'https://example.invalid/asset\tsha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' ]] ||
    fail "release metadata parsing"
pass "release metadata parsing"

mkdir -p "$SRC_DIR"
printf old > "$SRC_DIR/sing-box"
STAGING_ROOT="$TEMP_DIR/staging"
mkdir -p "$STAGING_ROOT"
TRANSACTION_ACTIVE=false
cleanup
assert_file_content old "$SRC_DIR/sing-box" "cleanup preserves existing installation"

systemctl() { return 0; }
TRANSACTION_ACTIVE=true
OLD_SRC_MOVED=false
NEW_SRC_ACTIVATED=false
SERVICE_EXISTED=true
rollback_install
assert_file_content old "$SRC_DIR/sing-box" "rollback before activation preserves existing installation"

rm -rf "$SRC_DIR"
mkdir -p "$SRC_DIR" "$TEMP_DIR/rollback/src"
printf new > "$SRC_DIR/sing-box"
printf old > "$TEMP_DIR/rollback/src/sing-box"
printf old-unit > "$TEMP_DIR/rollback/sing-box.service"
printf new-unit > "$SERVICE_FILE"
ROLLBACK_DIR="$TEMP_DIR/rollback"
TRANSACTION_ACTIVE=true
OLD_SRC_MOVED=true
NEW_SRC_ACTIVATED=true
SERVICE_EXISTED=true
SERVICE_WAS_ACTIVE=true
SERVICE_WAS_ENABLED=true
rollback_install
assert_file_content old "$SRC_DIR/sing-box" "rollback restores previous binary"
assert_file_content old-unit "$SERVICE_FILE" "rollback restores previous unit"

cat > "$SERVICE_FILE" <<EOF
[Service]
ExecStart=$SRC_DIR/sing-box run -c $INSTALL_DIR/config.json
EOF
service_file_is_managed || fail "legacy managed unit detection"
pass "legacy managed unit detection"

printf 'All sbinstall tests passed.\n'
