#!/usr/bin/env bash
set -euo pipefail

readonly ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

mkdir -p "$TEMP_DIR/state" "$TEMP_DIR/etc/systemd/system" "$TEMP_DIR/run/lock"
export TCSHAPE_TEST_MODE=1
export TCSHAPE_INSTALL_PATH="$ROOT_DIR/tools/traffic-shape.sh"
export TCSHAPE_STATE_DIR="$TEMP_DIR/state"
export TCSHAPE_CONFIG_FILE="$TEMP_DIR/etc/tcshape.conf"
export TCSHAPE_SERVICE_FILE="$TEMP_DIR/etc/systemd/system/tcshape.service"
export TCSHAPE_LOCK_FILE="$TEMP_DIR/run/lock/tcshape.lock"

# shellcheck source=../tools/traffic-shape.sh
source "$ROOT_DIR/tools/traffic-shape.sh"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_eq() {
    local expected="$1" actual="$2" name="$3"
    [[ "$actual" == "$expected" ]] || fail "$name: expected '$expected', got '$actual'"
    printf 'PASS: %s\n' "$name"
}

assert_file_value() {
    local file="$1" key="$2" expected="$3" name="$4"
    assert_eq "$expected" "$(read_config_value "$key" "$file")" "$name"
}

SYSTEMD_ENABLED=false
SYSTEMD_ACTIVE=false
SYSTEMD_FAIL_ENABLE=false
SYSTEMD_FAIL_RESTART=false
SYSTEMD_FAIL_DAEMON_RELOAD_ONCE=false
CURRENT_SERVICE_IFACE=""
declare -A QDISC_KIND=([eth0]=fq [lo]=fq)
declare -A QDISC_RATE=([eth0]="" [lo]="")

root_qdisc_kind() { printf '%s\n' "${QDISC_KIND[$1]:-}"; }
check_external_conflicts() { return 0; }
qdisc_has_custom_parameters() { return 1; }

apply_qdisc() {
    local iface="$1" rate="$2"
    QDISC_KIND[$iface]=htb
    QDISC_RATE[$iface]="$rate"
}

verify_qdisc_rate() {
    [[ "${QDISC_KIND[$1]:-}" == htb && "${QDISC_RATE[$1]:-}" == "$2" ]]
}

is_tcshape_qdisc() {
    [[ "${QDISC_KIND[$1]:-}" == htb ]]
}

is_own_shaper() {
    local iface="$1"
    [[ -f "$CONFIG_FILE" && -f "$SERVICE_FILE" ]] || return 1
    [[ "$(read_config_value INTERFACE || true)" == "$iface" ]] || return 1
    is_tcshape_qdisc "$iface"
}

restore_simple_qdisc() {
    local iface="$1" kind="$2"
    QDISC_KIND[$iface]="$kind"
    QDISC_RATE[$iface]=""
}

tc() {
    local action="${1:-}"
    shift || true
    if [[ "$action" == "qdisc" && "${1:-}" == "del" ]]; then
        local iface=""
        while (( $# > 0 )); do
            [[ "$1" == "dev" ]] && { iface="${2:-}"; break; }
            shift
        done
        [[ -n "$iface" ]] || return 1
        QDISC_KIND[$iface]=""
        QDISC_RATE[$iface]=""
        return 0
    fi
    return 1
}

systemctl() {
    local command="${1:-}"
    shift || true
    case "$command" in
        daemon-reload)
            if [[ "$SYSTEMD_FAIL_DAEMON_RELOAD_ONCE" == true ]]; then
                SYSTEMD_FAIL_DAEMON_RELOAD_ONCE=false
                return 1
            fi
            return 0
            ;;
        enable)
            [[ "$SYSTEMD_FAIL_ENABLE" == false ]] || return 1
            SYSTEMD_ENABLED=true
            return 0
            ;;
        restart)
            [[ "$SYSTEMD_FAIL_RESTART" == false ]] || return 1
            CURRENT_SERVICE_IFACE=$(read_config_value INTERFACE)
            apply_saved_config || return 1
            SYSTEMD_ACTIVE=true
            return 0
            ;;
        disable)
            SYSTEMD_ENABLED=false
            SYSTEMD_ACTIVE=false
            return 0
            ;;
        is-enabled) [[ "$SYSTEMD_ENABLED" == true ]] ;;
        is-active) [[ "$SYSTEMD_ACTIVE" == true ]] ;;
        *) return 1 ;;
    esac
}

MOVE_FAIL_SERVICE=false
move_managed_file() {
    local source="$1" destination="$2"
    if [[ "$MOVE_FAIL_SERVICE" == true && "$destination" == "$SERVICE_FILE" ]]; then
        return 1
    fi
    mv -f "$source" "$destination"
}

# First enable on eth0.
cmd_set 500 eth0 >/dev/null
assert_eq htb "${QDISC_KIND[eth0]}" "first enable applies eth0"
assert_file_value "$CONFIG_FILE" INTERFACE eth0 "first enable stores eth0"
assert_eq true "$SYSTEMD_ENABLED" "first enable persists service"

# Migrate to lo: old HTB must be removed and the new baseline promoted.
cmd_set 800 lo >/dev/null
assert_eq fq "${QDISC_KIND[eth0]}" "migration removes old eth0 HTB"
assert_eq htb "${QDISC_KIND[lo]}" "migration applies lo HTB"
assert_file_value "$CONFIG_FILE" INTERFACE lo "migration stores lo"
assert_file_value "$STATE_DIR/qdisc-baseline" INTERFACE lo "migration promotes lo baseline"

# off restores the currently managed interface and leaves no orphan HTB.
cmd_off >/dev/null
assert_eq fq "${QDISC_KIND[lo]}" "off restores lo baseline"
assert_eq fq "${QDISC_KIND[eth0]}" "off leaves eth0 clean"
[[ ! -e "$CONFIG_FILE" && ! -e "$SERVICE_FILE" ]] || fail "off removes managed files"
printf 'PASS: off removes managed files\n'

# Service enable failure must roll back first-time setup.
SYSTEMD_FAIL_ENABLE=true
if cmd_set 600 eth0 >/dev/null 2>&1; then
    fail "service enable failure unexpectedly succeeded"
fi
SYSTEMD_FAIL_ENABLE=false
assert_eq fq "${QDISC_KIND[eth0]}" "enable failure restores baseline"
[[ ! -e "$CONFIG_FILE" && ! -e "$SERVICE_FILE" ]] || fail "enable failure removes managed files"
printf 'PASS: enable failure removes managed files\n'

# A partial persistent-file write must report failure and roll back the config move.
MOVE_FAIL_SERVICE=true
if cmd_set 700 eth0 >/dev/null 2>&1; then
    fail "service file move failure unexpectedly succeeded"
fi
MOVE_FAIL_SERVICE=false
assert_eq fq "${QDISC_KIND[eth0]}" "service move failure restores baseline"
[[ ! -e "$CONFIG_FILE" && ! -e "$SERVICE_FILE" ]] || fail "service move failure removes partial files"
printf 'PASS: service move failure removes partial files\n'

# daemon-reload failure must also roll back the already moved managed files.
SYSTEMD_FAIL_DAEMON_RELOAD_ONCE=true
if cmd_set 700 eth0 >/dev/null 2>&1; then
    fail "daemon-reload failure unexpectedly succeeded"
fi
assert_eq fq "${QDISC_KIND[eth0]}" "daemon-reload failure restores baseline"
[[ ! -e "$CONFIG_FILE" && ! -e "$SERVICE_FILE" ]] || fail "daemon-reload failure removes managed files"
printf 'PASS: daemon-reload failure removes managed files\n'

printf 'All tcshape state tests passed.\n'
