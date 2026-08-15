#!/usr/bin/env bash
set -euo pipefail

readonly ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

export CLOUDFLARED_KEYRING="$TEST_DIR/keyring.gpg"
export CLOUDFLARED_SOURCE_FILE="$TEST_DIR/cloudflared.list"
export CLOUDFLARED_STATE_DIR="$TEST_DIR/state"
export CLOUDFLARED_LEGACY_BIN="$TEST_DIR/cloudflared"
export CLOUDFLARED_LEGACY_UPDATER="$TEST_DIR/cloudflared-update"
export CLOUDFLARED_LEGACY_SERVICE="$TEST_DIR/cloudflared-updater.service"
export CLOUDFLARED_LEGACY_TIMER="$TEST_DIR/cloudflared-updater.timer"
# shellcheck source=../tools/cloudflare_tunnel.sh
source "$ROOT_DIR/tools/cloudflare_tunnel.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }
systemctl() { return 0; }
curl() {
    local output=""
    while (( $# > 0 )); do
        if [[ "$1" == -o ]]; then
            output="$2"
            break
        fi
        shift
    done
    [[ -n "$output" ]] || return 1
    printf 'test-key' > "$output"
}

configure_repository
[[ -s "$KEYRING" ]] || fail "repository key was not installed"
grep -Fq 'https://pkg.cloudflare.com/cloudflared any main' "$SOURCE_FILE" ||
    fail "official repository definition was not written"
pass "configure official stable APT repository"

cat > "$LEGACY_UPDATER" <<'EOF'
#!/usr/bin/env bash
# cloudflared 自动更新脚本 (由安装脚本生成)
EOF
cat > "$LEGACY_SERVICE" <<EOF
[Unit]
Description=Cloudflared Auto Updater
[Service]
ExecStart=$LEGACY_UPDATER
EOF
cat > "$LEGACY_TIMER" <<'EOF'
[Unit]
Description=Cloudflared Auto Updater Timer
EOF
cleanup_legacy_updater
[[ ! -e "$LEGACY_UPDATER" && ! -e "$LEGACY_SERVICE" && ! -e "$LEGACY_TIMER" ]] ||
    fail "managed legacy updater was not removed"
find "$STATE_DIR" -type f -name cloudflared-update -print -quit | grep -q . ||
    fail "legacy updater was not backed up"
pass "backup and remove recognized legacy updater"

printf custom > "$LEGACY_UPDATER"
if cleanup_legacy_updater >/dev/null 2>&1; then
    fail "unrecognized legacy updater unexpectedly removed"
fi
[[ -f "$LEGACY_UPDATER" ]] || fail "unrecognized legacy updater was deleted"
pass "preserve unrecognized legacy updater"

script="$ROOT_DIR/tools/cloudflare_tunnel.sh"
grep -Fq 'https://pkg.cloudflare.com/cloudflared' "$script" || fail "official APT repository missing"
grep -Fq 'apt-get install -y --only-upgrade cloudflared' "$script" || fail "APT upgrade path missing"
grep -Fq 'read -r -s -p' "$script" || fail "Token input is not hidden"
if grep -Fq 'OnCalendar=' "$script"; then
    fail "custom updater timer still generated"
fi
pass "use official APT lifecycle without custom timer"

printf 'All cloudflare wrapper tests passed.\n'
