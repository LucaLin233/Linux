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

# Ubuntu socket activation: ports only move after the generator reruns and the
# socket restarts; a plain sshd reload would keep the old listener.
SYSTEMCTL_CALLS=()
SOCKET_STATE=active
SOCKET_RESTART_RC=0
systemctl() {
    SYSTEMCTL_CALLS+=("$*")
    case "$*" in
        "is-active --quiet ssh.socket") [[ "$SOCKET_STATE" == active ]] ;;
        "is-active --quiet ssh") return 1 ;;
        "restart ssh.socket")
            [[ "$SOCKET_RESTART_RC" == 0 ]] || SOCKET_STATE=failed
            return "$SOCKET_RESTART_RC"
            ;;
    esac
}
systemctl_calls() {
    local IFS='|'
    printf '%s' "${SYSTEMCTL_CALLS[*]}"
}

assert_eq socket "$(detect_ssh_runtime_mode)" "active ssh.socket selects socket mode"
assert_ok "socket activation counts as a running SSH service" ssh_runtime_active ssh
SOCKET_STATE=inactive
assert_eq service "$(detect_ssh_runtime_mode)" "inactive ssh.socket selects service mode"
assert_fail "inactive service without socket is not running" ssh_runtime_active ssh

SYSTEMCTL_CALLS=()
reload_ssh_runtime ssh socket
assert_eq "daemon-reload|restart ssh.socket" "$(systemctl_calls)" \
    "socket mode regenerates and restarts ssh.socket even while it is down"
SYSTEMCTL_CALLS=()
reload_ssh_runtime ssh service
assert_eq "reload ssh" "$(systemctl_calls)" "service mode keeps reloading sshd"

# A failed ssh.socket restart leaves the socket inactive; rollback must keep the
# socket path instead of reloading the ssh.service that stopped with it.
backup_ssh_config() { :; }
install() { :; }
restore_ssh_config() { ROLLBACK_MODE="$2"; }
ROLLBACK_MODE=''
SOCKET_STATE=active
SOCKET_RESTART_RC=1
assert_fail "failed ssh.socket restart fails the apply" \
    apply_ssh_config "$TEMP_DIR/next.conf" ssh 2222
assert_eq socket "$ROLLBACK_MODE" "rollback keeps socket mode after ssh.socket failed to restart"

printf 'All SSH security tests passed.\n'
