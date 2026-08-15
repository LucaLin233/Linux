#!/usr/bin/env bash
set -euo pipefail

readonly ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly TEST_DIR=$(mktemp -d)
# shellcheck source=../tools/push.sh
source "$ROOT_DIR/tools/push.sh"
trap 'rm -rf "$TEST_DIR" "$TEMP_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }
assert_eq() {
    local expected="$1" actual="$2" name="$3"
    [[ "$actual" == "$expected" ]] || fail "$name: expected '$expected', got '$actual'"
    pass "$name"
}

DEFAULT_USER=root
DEFAULT_PORT=22
parse_server_info "admin@example.com:2222" || fail "parse IPv4 host"
assert_eq 2222 "$PARSED_PORT" "parse port"
assert_eq 'admin@example.com' "$PARSED_TARGET" "format IPv4 target"

parse_server_info "root@[2001:db8::1]:2200" || fail "parse IPv6 host"
assert_eq 'root@[2001:db8::1]' "$PARSED_TARGET" "preserve IPv6 brackets"
if parse_server_info "2001:db8::1" >/dev/null 2>&1; then
    fail "bare IPv6 address unexpectedly accepted"
fi
pass "reject bare IPv6 address"

config="$TEST_DIR/config.conf"
printf 'DEFAULT_USER=alice\n' > "$config"
chmod 600 "$config"
load_config "$config"
assert_eq alice "$DEFAULT_USER" "load protected config"
ln -s "$config" "$TEST_DIR/config-link.conf"
if load_config "$TEST_DIR/config-link.conf" >/dev/null 2>&1; then
    fail "symlink config unexpectedly accepted"
fi
pass "reject symlink config"

DELETE_EXTRA=true
ALLOW_DELETE_EXTRA=false
USER_KNOWN_HOSTS_FILE="$TEST_DIR/known_hosts"
if prepare_transfer_safety >/dev/null 2>&1; then
    fail "non-interactive delete unexpectedly accepted"
fi
pass "require explicit non-interactive delete authorization"

ALLOW_DELETE_EXTRA=true
STRICT_HOST_KEY_CHECKING=accept-new
prepare_transfer_safety
[[ -f "$USER_KNOWN_HOSTS_FILE" ]] || fail "known_hosts file not created"
pass "create persistent known_hosts file"

mkdir -p "$TEST_DIR/bin"
cat > "$TEST_DIR/bin/ssh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CAPTURE_FILE"
EOF
chmod 700 "$TEST_DIR/bin/ssh"
export PATH="$TEST_DIR/bin:$PATH"
export CAPTURE_FILE="$TEST_DIR/ssh-args"
PUSH_SSH_PORT=2200 \
PUSH_CONNECTION_TIMEOUT=15 \
PUSH_STRICT_HOST_KEY_CHECKING=accept-new \
PUSH_USER_KNOWN_HOSTS_FILE="$TEST_DIR/known hosts" \
PUSH_AUTH_METHOD=key \
PUSH_KEY_FILE="$TEST_DIR/private key" \
    "$SSH_WRAPPER" example-command

grep -Fxq "$TEST_DIR/private key" "$CAPTURE_FILE" || fail "SSH wrapper lost key path argument"
grep -Fxq "UserKnownHostsFile=$TEST_DIR/known hosts" "$CAPTURE_FILE" || fail "SSH wrapper lost known_hosts argument"
pass "SSH wrapper preserves argument boundaries"

if grep -Fq 'wait -n 2>/dev/null || wait' "$ROOT_DIR/tools/push.sh"; then
    fail "failed child still collapses the concurrency window"
fi
pass "failed child keeps sliding concurrency window"

printf 'All push tests passed.\n'
