#!/usr/bin/env bash
set -euo pipefail

readonly ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

export CLOUDFLARED_KEYRING="$TEST_DIR/keyring.gpg"
export CLOUDFLARED_SOURCE_FILE="$TEST_DIR/cloudflared.list"
export CLOUDFLARED_STATE_DIR="$TEST_DIR/state"
export CLOUDFLARED_LEGACY_BIN="$TEST_DIR/cloudflared"
export CLOUDFLARED_APT_BIN="$TEST_DIR/usr-bin-cloudflared"
export CLOUDFLARED_LEGACY_UPDATER="$TEST_DIR/cloudflared-update"
export CLOUDFLARED_LEGACY_SERVICE="$TEST_DIR/cloudflared-updater.service"
export CLOUDFLARED_LEGACY_TIMER="$TEST_DIR/cloudflared-updater.timer"
export CLOUDFLARED_AUTO_UPDATE_SCRIPT="$TEST_DIR/cloudflared-apt-update"
export CLOUDFLARED_AUTO_UPDATE_SERVICE="$TEST_DIR/cloudflared-apt-update.service"
export CLOUDFLARED_AUTO_UPDATE_TIMER="$TEST_DIR/cloudflared-apt-update.timer"
export CLOUDFLARED_SERVICE_FILE="$TEST_DIR/cloudflared.service"
export CLOUDFLARED_BINARY_UPDATE_SERVICE="$TEST_DIR/cloudflared-update.service"
export CLOUDFLARED_BINARY_UPDATE_TIMER="$TEST_DIR/cloudflared-update.timer"
# shellcheck source=../tools/cloudflare_tunnel.sh
source "$ROOT_DIR/tools/cloudflare_tunnel.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }
SYSTEMCTL_TIMER_ENABLED=true
systemctl() {
    local unit="${!#}"
    if [[ "${1:-}" =~ ^(is-enabled|is-active)$ && "$unit" == *.timer ]]; then
        [[ "$SYSTEMCTL_TIMER_ENABLED" == true ]]
        return
    fi
    return 0
}
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

cat > "$SERVICE_FILE" <<EOF
[Service]
ExecStart=$LEGACY_BIN --no-autoupdate --token-file /etc/cloudflared/token
EOF
cat > "$LEGACY_BIN" <<'EOF'
#!/usr/bin/env bash
echo 'cloudflared version 2025.1.0'
EOF
chmod 0755 "$LEGACY_BIN"
migrate_legacy_binary
[[ ! -e "$LEGACY_BIN" ]] || fail "recognized legacy binary was not removed automatically"
grep -Fq "ExecStart=$APT_BIN --no-autoupdate --token-file /etc/cloudflared/token" "$SERVICE_FILE" ||
    fail "legacy service executable path was not migrated safely"
find "$STATE_DIR" -type f -name cloudflared.service -print -quit | grep -q . ||
    fail "legacy service unit was not backed up"
pass "automatically migrate legacy binary and service without replacing credentials"

printf '#!/bin/sh\necho custom\n' > "$LEGACY_BIN"
chmod 0755 "$LEGACY_BIN"
if migrate_legacy_binary >/dev/null 2>&1; then
    fail "unrecognized legacy binary unexpectedly migrated"
fi
[[ -f "$LEGACY_BIN" ]] || fail "unrecognized legacy binary was deleted"
rm -f "$LEGACY_BIN"
pass "preserve legacy binary without ownership evidence"

cat > "$APT_BIN" <<'EOF'
#!/usr/bin/env bash
echo 'cloudflared version 2026.8.2'
EOF
chmod 0755 "$APT_BIN"
dpkg-query() {
    if [[ "${1:-}" == -S && "${2:-}" == "$APT_BIN" ]]; then
        return 0
    fi
    command dpkg-query "$@"
}
ln -s "$APT_BIN" "$LEGACY_BIN"
migrate_legacy_binary
[[ -L "$LEGACY_BIN" ]] || fail "APT compatibility symlink was not preserved"
[[ "$(readlink -f "$LEGACY_BIN")" == "$APT_BIN" ]] || fail "APT compatibility symlink target changed"
pass "preserve Cloudflare APT compatibility symlink layout"
rm -f "$APT_BIN"

write_auto_update_files
bash -n "$AUTO_UPDATE_SCRIPT"
grep -Fq 'apt-get -o DPkg::Lock::Timeout=300 update -qq' "$AUTO_UPDATE_SCRIPT" ||
    fail "auto updater does not refresh APT metadata"
grep -Fq 'dpkg --compare-versions "$candidate" gt "$installed"' "$AUTO_UPDATE_SCRIPT" ||
    fail "auto updater does not compare installed and candidate versions"
grep -Fq 'install -y --only-upgrade cloudflared' "$AUTO_UPDATE_SCRIPT" ||
    fail "auto updater does not restrict upgrade to cloudflared"
grep -Fq 'systemctl restart cloudflared.service' "$AUTO_UPDATE_SCRIPT" ||
    fail "auto updater does not restart an active service"
grep -Fq 'OnCalendar=daily' "$AUTO_UPDATE_TIMER" || fail "daily timer missing"
grep -Fq 'RandomizedDelaySec=6h' "$AUTO_UPDATE_TIMER" || fail "timer jitter missing"
grep -Fq 'Persistent=true' "$AUTO_UPDATE_TIMER" || fail "persistent timer missing"
pass "generate opt-in APT update timer"

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
legacy_auto_update_present || fail "legacy auto-update intent was not detected"
pass "detect enabled legacy auto-update intent"
SYSTEMCTL_TIMER_ENABLED=false
if legacy_auto_update_present; then
    fail "disabled legacy timer unexpectedly enabled new auto-update"
fi
pass "do not preserve disabled legacy timer"
SYSTEMCTL_TIMER_ENABLED=true
cleanup_legacy_updater
[[ ! -e "$LEGACY_UPDATER" && ! -e "$LEGACY_SERVICE" && ! -e "$LEGACY_TIMER" ]] ||
    fail "managed legacy updater was not removed"
find "$STATE_DIR" -type f -name cloudflared-update -print -quit | grep -q . ||
    fail "legacy updater was not backed up"
pass "backup and remove recognized legacy updater"

cat > "$BINARY_UPDATE_SERVICE" <<'EOF'
[Unit]
Description=Update cloudflared
[Service]
ExecStart=/bin/bash -c '/usr/bin/cloudflared update; code=$?; exit $code'
EOF
cat > "$BINARY_UPDATE_TIMER" <<'EOF'
[Unit]
Description=Update cloudflared
[Timer]
OnCalendar=daily
EOF
cleanup_binary_updater
[[ ! -e "$BINARY_UPDATE_SERVICE" && ! -e "$BINARY_UPDATE_TIMER" ]] ||
    fail "package-incompatible binary updater was not removed"
pass "remove binary updater after migrating to APT"

printf custom > "$LEGACY_UPDATER"
if cleanup_legacy_updater >/dev/null 2>&1; then
    fail "unrecognized legacy updater unexpectedly removed"
fi
[[ -f "$LEGACY_UPDATER" ]] || fail "unrecognized legacy updater was deleted"
pass "preserve unrecognized legacy updater"

script="$ROOT_DIR/tools/cloudflare_tunnel.sh"
entrypoint_output=$(bash -c "$(cat "$script")" cloudflare_tunnel.sh help)
grep -Fq 'cloudflare_tunnel.sh install' <<< "$entrypoint_output" ||
    fail "bash -c entrypoint did not dispatch script arguments"
pass "support bash -c one-line invocation"

grep -Fq 'https://pkg.cloudflare.com/cloudflared' "$script" || fail "official APT repository missing"
grep -Fq 'apt-get install -y --only-upgrade cloudflared' "$script" || fail "APT upgrade path missing"
grep -Fq 'read -r -s -p' "$script" || fail "Token input is not hidden"
grep -Fq 'service install --no-update-service' "$script" || fail "package install still enables binary self-update"
grep -Fq 'enable-auto-update' "$script" || fail "opt-in auto-update command missing"
pass "use official APT lifecycle with opt-in update detection"

printf 'All cloudflare wrapper tests passed.\n'
