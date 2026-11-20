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

restricted_endpoints=$'10.0.0.5:22\n[2001:db8::5]:2222'
SSHD_OUTPUT=$'listenaddress 10.0.0.5:22\nlistenaddress [2001:db8::5]:2222'
assert_eq "$restricted_endpoints" "$(get_effective_listen_endpoints)" \
    "preserve distinct IPv4 and IPv6 address and port pairs"
assert_eq "$restricted_endpoints" "$(select_listen_endpoints "$restricted_endpoints" $'22\n2222' '')" \
    "keep existing pairs when the user keeps the current settings"
assert_fail "refuse to guess when changing the ports of distinct address bindings" \
    select_listen_endpoints "$restricted_endpoints" $'22\n2222' 2022

SSHD_OUTPUT=$'listenaddress 0.0.0.0:22\nlistenaddress [::]:22'
assert_eq $'0.0.0.0:22\n[::]:22' "$(get_effective_listen_endpoints)" \
    "preserve wildcard scope when it was already effective"
assert_eq $'0.0.0.0:2022\n[::]:2022' "$(select_listen_endpoints "$(get_effective_listen_endpoints)" 22 2022)" \
    "apply a new port to both addresses when they shared the old port"

for choice in 1 2; do
    (
        require_root() { :; }
        get_ssh_service_name() { printf 'ssh\n'; }
        ssh_runtime_active() { :; }
        ss() { :; }
        systemctl() { return 1; }
        choose_password_authentication() { printf 'no\n'; }
        choose_root_login_policy() { printf 'prohibit-password\n'; }
        check_syntax() { :; }
        verify_effective_settings() { :; }
        confirm_ssh_changes() { assert_eq "$expected_port" "$1" "choice $choice confirms the bound port"; }
        apply_ssh_config() {
            assert_eq "ListenAddress 10.0.0.5:$expected_port" "$(grep '^ListenAddress ' "$1")" \
                "choice $choice applies the intended address and port"
            rm -f -- "$1"
        }
        show_summary() { :; }
        hostname() { printf '10.0.0.5\n'; }
        mktemp() { command mktemp "$TEMP_DIR/sshd_config.new.XXXXXX"; }
        SSHD_OUTPUT=$'port 2222\nlistenaddress 10.0.0.5:2022'
        expected_port=2022
        [[ "$choice" != 2 ]] || expected_port=2222
        output=$(main <<< "$choice") || {
            printf '%s\n' "$output" >&2
            fail "main failed for SSH port choice $choice"
        }
        grep -Fq "ssh -p $expected_port root@10.0.0.5" <<< "$output" ||
            fail "choice $choice reported the wrong connection port"
    )
done

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
            get_effective_listen_endpoints
        ' _ "$ROOT_DIR/modules/ssh-security.sh") ||
        fail "locale $locale_name invocation failed"
    assert_eq $'0.0.0.0:22\n0.0.0.0:2222\n[::]:22\n[::]:2222' "$output" \
        "stable wildcard endpoint ordering under locale $locale_name"
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
created=$(create_temp_ssh_config $'22\n2222' no prohibit-password "$restricted_endpoints")
assert_eq "$CONFIG_FIXTURE" "$created" "create SSH configuration in temporary file"
assert_eq $'ListenAddress 10.0.0.5:22\nListenAddress [2001:db8::5]:2222' \
    "$(grep '^ListenAddress ' "$CONFIG_FIXTURE")" "render only the two original address and port pairs"

SSHD_OUTPUT=$'port 22\nport 2222\nlistenaddress 10.0.0.5:22\nlistenaddress [2001:db8::5]:2222\npermitrootlogin prohibit-password\npasswordauthentication no\nkbdinteractiveauthentication no\npubkeyauthentication yes\nallowtcpforwarding yes'
assert_ok "verify restricted effective SSH settings" verify_effective_settings \
    "$CONFIG_FIXTURE" $'22\n2222' no prohibit-password "$restricted_endpoints"

SSHD_OUTPUT=$'port 22\nport 2222\nlistenaddress 0.0.0.0:22\nlistenaddress [::]:22\npermitrootlogin prohibit-password\npasswordauthentication no\nkbdinteractiveauthentication no\npubkeyauthentication yes\nallowtcpforwarding yes'
assert_fail "reject widened effective SSH listen scope" verify_effective_settings \
    "$CONFIG_FIXTURE" $'22\n2222' no prohibit-password "$restricted_endpoints"

# Ubuntu socket activation: ports only move after the generator reruns and the
# socket restarts; a plain sshd reload would keep the old listener.
SYSTEMCTL_CALLS=()
SOCKET_STATE=active
SOCKET_RESTART_RC=0
SERVICE_STATE=inactive
SOCKET_LISTEN=''
systemctl() {
    SYSTEMCTL_CALLS+=("$*")
    case "$*" in
        "is-active --quiet ssh.socket") [[ "$SOCKET_STATE" == active ]] ;;
        "is-active --quiet ssh") [[ "$SERVICE_STATE" == active ]] ;;
        "show --property=MainPID --value ssh") printf '123\n' ;;
        "show --property=Listen --value ssh.socket") printf '%s\n' "$SOCKET_LISTEN" ;;
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

sleep() { :; }
ss() { printf '%s\n' "$SS_LISTEN"; }
SERVICE_STATE=active
SS_LISTEN=$'LISTEN 0 128 10.0.0.5:22 0.0.0.0:* users:(("sshd",pid=123,fd=3))\nLISTEN 0 128 [2001:db8::5]:2222 [::]:* users:(("sshd",pid=123,fd=4))'
assert_ok "service mode verifies both original endpoint pairs" verify_listening_endpoints ssh service "$restricted_endpoints"
SS_LISTEN=$'LISTEN 0 128 10.0.0.5:22 0.0.0.0:* users:(("sshd",pid=123,fd=3))\nLISTEN 0 128 [2001:db8::6]:2222 [::]:* users:(("sshd",pid=123,fd=4))\nLISTEN 0 128 [2001:db8::5]:2222 [::]:* users:(("other",pid=321,fd=3))'
assert_fail "service mode rejects a wrong address on the correct port" \
    verify_listening_endpoints ssh service "$restricted_endpoints"

SOCKET_STATE=active
SOCKET_LISTEN='[2001:db8::5]:2222 (Stream) 10.0.0.5:22 (Stream)'
SYSTEMD_SSH_LISTEN=$'LISTEN 0 128 10.0.0.5:22 0.0.0.0:* users:(("systemd",pid=1,fd=3))\nLISTEN 0 128 [2001:db8::5]:2222 [::]:* users:(("systemd",pid=1,fd=4))'
SS_LISTEN="$SYSTEMD_SSH_LISTEN"
assert_ok "socket mode verifies both original endpoint pairs" verify_listening_endpoints ssh socket "$restricted_endpoints"
SOCKET_LISTEN='[2001:db8::6]:2222 (Stream) 10.0.0.5:22 (Stream)'
assert_fail "socket mode rejects a wrong address on the correct port" \
    verify_listening_endpoints ssh socket "$restricted_endpoints"
SOCKET_LISTEN='[::]:22 (Stream)'
SS_LISTEN='LISTEN 0 128 *:22 *:* users:(("systemd",pid=1,fd=3))'
assert_ok "a dual-stack wildcard socket covers both wildcard endpoints" \
    verify_listening_endpoints ssh socket $'0.0.0.0:22\n[::]:22'

# A failed ssh.socket restart leaves the socket inactive; rollback must keep the
# socket path instead of reloading the ssh.service that stopped with it.
backup_ssh_config() { :; }
mkdir() { :; }
install() { :; }
restore_ssh_config() { ROLLBACK_MODE="$2"; }
ROLLBACK_MODE=''
SOCKET_STATE=active
SOCKET_LISTEN='[2001:db8::5]:2222 (Stream) 10.0.0.5:22 (Stream)'
SS_LISTEN="$SYSTEMD_SSH_LISTEN"
SOCKET_RESTART_RC=1
assert_fail "failed ssh.socket restart fails the apply" \
    apply_ssh_config "$TEMP_DIR/next.conf" ssh "$restricted_endpoints" "$restricted_endpoints"
assert_eq socket "$ROLLBACK_MODE" "rollback keeps socket mode after ssh.socket failed to restart"

printf 'All SSH security tests passed.\n'
