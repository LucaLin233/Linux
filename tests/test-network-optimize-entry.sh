#!/usr/bin/env bash
set -euo pipefail

readonly ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT
export NETWORK_OPTIMIZE_STATE_DIR="$TEMP_DIR/state"

# shellcheck source=../modules/network-optimize.sh
source "$ROOT_DIR/modules/network-optimize.sh"

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

reset_selection() {
    COMMAND=install
    RESTORE_SCOPE=previous
    TUNING_MODE=auto
    NO_PROBE=false
    TUNING_SELECTION_EXPLICIT=false
    ACTIVE_PROBE_REQUESTED=false
    MANUAL_BANDWIDTH_MBPS=""
    MANUAL_DOWNLOAD_MBPS=""
    MANUAL_UPLOAD_MBPS=""
    MANUAL_RTT_MS=""
    CUSTOM_RTT_TARGETS=()
}

is_interactive_terminal() { return 1; }
reset_selection
select_tuning_mode >/dev/null
assert_eq static "$TUNING_MODE" "non-interactive execution selects static mode"
assert_eq true "$NO_PROBE" "non-interactive execution disables probing"

is_interactive_terminal() { return 0; }
reset_selection
select_tuning_mode >/dev/null <<< "1"
assert_eq static "$TUNING_MODE" "interactive default selects static mode"
assert_eq true "$NO_PROBE" "interactive static mode disables probing"

reset_selection
select_tuning_mode >/dev/null <<'EOF'
2
1000
500

EOF
assert_eq auto "$TUNING_MODE" "manual mode keeps dynamic buffer calculation"
assert_eq true "$NO_PROBE" "manual mode disables active probing"
assert_eq 1000 "$MANUAL_DOWNLOAD_MBPS" "manual mode records download bandwidth"
assert_eq 500 "$MANUAL_UPLOAD_MBPS" "manual mode records upload bandwidth"
assert_eq 150 "$MANUAL_RTT_MS" "manual mode defaults RTT to 150 ms"

reset_selection
select_tuning_mode >/dev/null <<'EOF'
3
y
EOF
assert_eq auto "$TUNING_MODE" "confirmed probe selects auto mode"
assert_eq false "$NO_PROBE" "confirmed probe enables active probing"
assert_eq true "$ACTIVE_PROBE_REQUESTED" "interactive probe records explicit consent"

reset_selection
if select_tuning_mode >/dev/null <<'EOF'
3
n
EOF
then
    fail "declined active probe unexpectedly succeeded"
else
    assert_eq 2 "$?" "declined active probe returns cancellation status"
fi

reset_selection
parse_arguments install --probe
read() { fail "explicit probe unexpectedly prompted"; }
select_tuning_mode
unset -f read
assert_eq true "$TUNING_SELECTION_EXPLICIT" "explicit probe bypasses selection menu"
assert_eq false "$NO_PROBE" "explicit probe remains enabled"
assert_eq true "$ACTIVE_PROBE_REQUESTED" "probe flag records explicit consent"

reset_selection
parse_arguments install --static
read() { fail "explicit static mode unexpectedly prompted"; }
select_tuning_mode
unset -f read
assert_eq static "$TUNING_MODE" "explicit static mode bypasses selection menu"
assert_eq true "$NO_PROBE" "explicit static mode disables probing"

reset_selection
parse_arguments install --download-mbps 1000
assert_eq true "$NO_PROBE" "manual bandwidth never triggers active probing"
assert_eq 150 "$MANUAL_RTT_MS" "manual bandwidth defaults missing RTT to 150 ms"
assert_fail "custom target requires explicit probe consent" parse_arguments plan --target example.com
reset_selection
assert_ok "custom target accepts explicit probe consent" parse_arguments plan --probe --target example.com

managed_config="$TEMP_DIR/managed.conf"
initial_runtime="$TEMP_DIR/initial-runtime"
initial_config="$TEMP_DIR/initial-config"
printf '%s\n' 'net.ipv4.ip_local_port_range = 1024 65535' > "$managed_config"
printf '%s\n' 'net.ipv4.ip_local_port_range=40000 65000' > "$initial_runtime"
printf '%s\n' 'net.ipv4.ip_local_port_range = 32768 62000' > "$initial_config"
assert_ok "detect legacy managed unsafe port range" managed_unsafe_port_range_present "$managed_config"
assert_eq '40000 65000' \
    "$(resolve_port_range_restore_value "$managed_config" "$initial_runtime" "$initial_config")" \
    "prefer initial runtime port range"

rm -f "$initial_runtime"
assert_eq '32768 62000' \
    "$(resolve_port_range_restore_value "$managed_config" "$initial_runtime" "$initial_config")" \
    "fall back to initial config port range"

rm -f "$initial_config"
assert_eq '32768 60999' \
    "$(resolve_port_range_restore_value "$managed_config" "$initial_runtime" "$initial_config")" \
    "fall back to Debian default port range"

printf '%s\n' 'net.ipv4.ip_local_port_range = 32768 60999' > "$managed_config"
assert_fail "ignore non-legacy port range" resolve_port_range_restore_value \
    "$managed_config" "$initial_runtime" "$initial_config"
assert_fail "reject malformed port range" normalize_port_range '1024 invalid'

runtime_backup="$TEMP_DIR/runtime-backup"
: > "$runtime_backup"
SYSCTL_PORT_RANGE='1024 65535'
sysctl() {
    case "$1" in
        -n) printf '%s\n' "$SYSCTL_PORT_RANGE" ;;
        -w) SYSCTL_PORT_RANGE="${2#*=}" ;;
        *) return 1 ;;
    esac
}
assert_ok "capture current port range for rollback" capture_port_range_for_rollback "$runtime_backup"
assert_eq 'net.ipv4.ip_local_port_range=1024 65535' "$(cat "$runtime_backup")" \
    "rollback snapshot includes previous port range"
assert_ok "apply safe port range migration" apply_port_range_migration '32768 60999'
assert_eq '32768 60999' "$SYSCTL_PORT_RANGE" "port range migration applies expected value"
if grep -Eq '^net[.]ipv4[.]ip_local_port_range[[:space:]]*=' \
    "$ROOT_DIR/modules/network-optimize.sh"; then
    fail "generated sysctl configuration still owns ip_local_port_range"
fi
printf 'PASS: generated sysctl configuration no longer owns ip_local_port_range\n'

printf 'All network-optimize entry tests passed.\n'
