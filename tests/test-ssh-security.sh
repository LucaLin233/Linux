#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly ROOT_DIR
TEMP_DIR=$(mktemp -d)
readonly TEMP_DIR
trap 'rm -rf "$TEMP_DIR"' EXIT

# shellcheck source=../modules/ssh-security.sh
source "$ROOT_DIR/modules/ssh-security.sh"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_eq() {
    local expected="$1" actual="$2" name="$3"
    [[ "$actual" == "$expected" ]] || fail "$name: expected '$expected', got '$actual'"
    printf 'PASS: %s\n' "$name"
}

assert_ok() {
    local name="$1"
    shift
    "$@" || fail "$name"
    printf 'PASS: %s\n' "$name"
}

assert_fail() {
    local name="$1"
    shift
    if "$@"; then
        fail "$name: command unexpectedly succeeded"
    fi
    printf 'PASS: %s\n' "$name"
}

SSHD_OUTPUT=''
sshd() {
    printf '%s\n' "$SSHD_OUTPUT"
}

SSHD_OUTPUT=$'listenaddress 10.0.0.5:22\nlistenaddress [2001:db8::5]:2222'
assert_eq $'10.0.0.5\n2001:db8::5' "$(get_effective_listen_addresses)" \
    "strip ports while preserving restricted IPv4 and IPv6 addresses"

SSHD_OUTPUT=$'listenaddress 0.0.0.0:22\nlistenaddress [::]:22'
assert_eq $'0.0.0.0\n::' "$(get_effective_listen_addresses)" \
    "preserve wildcard scope when it was already effective"

run_locale_case() {
    local locale_name="$1" output
    if ! locale -a 2>/dev/null | grep -Fqx "$locale_name"; then
        printf 'SKIP: locale %s is unavailable\n' "$locale_name"
        return 0
    fi
    output=$(LC_ALL="$locale_name" SSHD_OUTPUT=$'listenaddress [::]:22\nlistenaddress 0.0.0.0:22\nlistenaddress [::]:2222\nlistenaddress 0.0.0.0:2222' \
        bash -c '
            sshd() { printf "%s\n" "$SSHD_OUTPUT"; }
            source "$1"
            get_effective_listen_addresses
        ' _ "$ROOT_DIR/modules/ssh-security.sh") ||
        fail "locale $locale_name invocation failed"
    assert_eq $'0.0.0.0\n::' "$output" "stable deduplicated wildcard ordering under locale $locale_name"
}

run_locale_case C
non_c_locale=$(locale -a 2>/dev/null | grep -Ev '^(C|C\.utf8|POSIX)$' | head -n 1 || true)
if [[ -n "$non_c_locale" ]]; then
    run_locale_case "$non_c_locale"
else
    printf 'SKIP: no non-C locale is available\n'
fi

CONFIG_FIXTURE="$TEMP_DIR/sshd_config"
mktemp() {
    printf '%s\n' "$CONFIG_FIXTURE"
}
restricted_addresses=$'10.0.0.5\n2001:db8::5'
created=$(create_temp_ssh_config $'22\n2222' no prohibit-password "$restricted_addresses")
assert_eq "$CONFIG_FIXTURE" "$created" "create SSH configuration in temporary file"
grep -Fqx 'ListenAddress 10.0.0.5' "$CONFIG_FIXTURE" || fail "restricted IPv4 address was not rendered"
grep -Fqx 'ListenAddress 2001:db8::5' "$CONFIG_FIXTURE" || fail "restricted IPv6 address was not rendered"
if grep -Fqx 'ListenAddress 0.0.0.0' "$CONFIG_FIXTURE" || grep -Fqx 'ListenAddress ::' "$CONFIG_FIXTURE"; then
    fail "restricted configuration was widened to wildcard addresses"
fi
printf 'PASS: generated configuration does not widen ListenAddress\n'

SSHD_OUTPUT=$'port 22\nport 2222\nlistenaddress 10.0.0.5:22\nlistenaddress [2001:db8::5]:2222\npermitrootlogin prohibit-password\npasswordauthentication no\nkbdinteractiveauthentication no\npubkeyauthentication yes\nallowtcpforwarding yes'
assert_ok "verify restricted effective SSH settings" verify_effective_settings \
    "$CONFIG_FIXTURE" $'22\n2222' no prohibit-password "$restricted_addresses"

SSHD_OUTPUT=$'port 22\nport 2222\nlistenaddress 0.0.0.0:22\nlistenaddress [::]:22\npermitrootlogin prohibit-password\npasswordauthentication no\nkbdinteractiveauthentication no\npubkeyauthentication yes\nallowtcpforwarding yes'
assert_fail "reject widened effective SSH listen scope" verify_effective_settings \
    "$CONFIG_FIXTURE" $'22\n2222' no prohibit-password "$restricted_addresses"

printf 'All SSH security tests passed.\n'
