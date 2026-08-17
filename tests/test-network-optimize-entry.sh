#!/usr/bin/env bash
set -euo pipefail

readonly ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT
export NETWORK_OPTIMIZE_STATE_DIR="$TEMP_DIR/state"
export NETWORK_OPTIMIZE_CONF="$TEMP_DIR/etc/sysctl.d/99-network-optimize.conf"
export NETWORK_OPTIMIZE_IPV6_CONF_ROOT="$TEMP_DIR/proc/sys/net/ipv6/conf"
export NETWORK_OPTIMIZE_INITCWND_HOOK="$TEMP_DIR/networkd-dispatcher/routable.d/50-network-optimize-initcwnd"

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
    ECN_DISABLED=false
    MANUAL_BANDWIDTH_MBPS=""
    MANUAL_DOWNLOAD_MBPS=""
    MANUAL_UPLOAD_MBPS=""
    MANUAL_RTT_MS=""
    MANUAL_RTT_DEFAULTED=false
    INITCWND_MODE=auto
    INITCWND_ENABLED=true
    INITCWND_POLICY=unknown
    VERIFY_ASSUME_YES=false
    VERIFY_CONFIRM_EXPLICIT=false
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
parse_arguments install --disable-ecn
assert_eq true "$ECN_DISABLED" "disable ECN requires an explicit flag"

reset_selection
parse_arguments install --enable-initcwnd
assert_eq enabled "$INITCWND_MODE" "explicitly enable initcwnd"
reset_selection
parse_arguments install --disable-initcwnd
assert_eq disabled "$INITCWND_MODE" "explicitly disable initcwnd"
reset_selection
assert_fail "reject conflicting initcwnd flags" \
    parse_arguments install --enable-initcwnd --disable-initcwnd

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
assert_eq true "$MANUAL_RTT_DEFAULTED" "manual bandwidth records default RTT source"
assert_fail "removed custom RTT target is rejected" parse_arguments plan --probe --target example.com

prepare_dynamic_case() {
    TUNING_MODE=auto
    NO_PROBE=false
    MANUAL_BANDWIDTH_MBPS=""
    MANUAL_DOWNLOAD_MBPS=""
    MANUAL_UPLOAD_MBPS=""
    MANUAL_RTT_MS=""
    MANUAL_RTT_DEFAULTED=false
    DETECTED_DOWNLOAD_MBPS=""
    DETECTED_UPLOAD_MBPS=""
    DETECTED_RTT_MS=""
    RTT_SOURCE=unknown
    RTT_POLICY=unknown
    BANDWIDTH_SOURCE=unknown
    INITCWND_MODE=auto
    INITCWND_ENABLED=true
    INITCWND_POLICY=unknown
}

detect_memory_mb() { printf '%s\n' 8192; }
detect_cgroup_memory_limit_mb() { return 1; }
probe_bandwidth() {
    DETECTED_DOWNLOAD_MBPS=1000
    DETECTED_UPLOAD_MBPS=500
}
for observed_rtt in 40 180 300; do
    prepare_dynamic_case
    DETECTED_RTT_MS="$observed_rtt"
    resolve_tuning_values >/dev/null
    assert_eq 150 "$DETECTED_RTT_MS" \
        "automatic calculation ignores observed ${observed_rtt} ms and uses 150 ms"
    assert_eq 'fixed 150 ms' "$RTT_POLICY" \
        "automatic ${observed_rtt} ms case records fixed policy"
done
assert_eq 39845888 "$RMEM_MAX_BYTES" "automatic calculation uses fixed 150 ms for buffer max"

for manual_rtt in 40 300; do
    prepare_dynamic_case
    NO_PROBE=true
    MANUAL_DOWNLOAD_MBPS=1000
    MANUAL_UPLOAD_MBPS=500
    MANUAL_RTT_MS="$manual_rtt"
    resolve_tuning_values >/dev/null
    assert_eq "$manual_rtt" "$DETECTED_RTT_MS" \
        "manual RTT ${manual_rtt} ms remains unchanged"
    assert_eq 'manual override' "$RTT_POLICY" \
        "manual RTT ${manual_rtt} ms records override policy"
done

INITCWND_MODE=auto
DETECTED_UPLOAD_MBPS=100
resolve_initcwnd_policy
assert_eq false "$INITCWND_ENABLED" "auto initcwnd keeps kernel default at 100 Mbps"
assert_eq 'auto: upload <= 100 Mbps, preserve kernel default' "$INITCWND_POLICY" \
    "auto initcwnd explains low-upload policy"
INITCWND_MODE=auto
DETECTED_UPLOAD_MBPS=101
resolve_initcwnd_policy
assert_eq true "$INITCWND_ENABLED" "auto initcwnd enables 32 above 100 Mbps"
INITCWND_MODE=auto
DETECTED_UPLOAD_MBPS=""
resolve_initcwnd_policy
assert_eq false "$INITCWND_ENABLED" "auto initcwnd keeps kernel default when upload is unknown"
assert_eq 'auto: upload unknown, preserve kernel default' "$INITCWND_POLICY" \
    "auto initcwnd explains unknown-upload policy"
INITCWND_MODE=enabled
DETECTED_UPLOAD_MBPS=10
initcwnd_warning_log="$TEMP_DIR/initcwnd-warning.log"
resolve_initcwnd_policy > "$initcwnd_warning_log"
initcwnd_warning=$(<"$initcwnd_warning_log")
assert_eq true "$INITCWND_ENABLED" "explicit initcwnd enable overrides low upload"
grep -Fq '不高于 100 Mbps' <<< "$initcwnd_warning" ||
    fail "explicit low-bandwidth initcwnd enable did not warn"
printf 'PASS: explicit low-bandwidth initcwnd enable warns\n'
INITCWND_MODE=disabled
DETECTED_UPLOAD_MBPS=1000
resolve_initcwnd_policy
assert_eq false "$INITCWND_ENABLED" "explicit initcwnd disable overrides high upload"

NETWORK_TEST_TOTAL=84999999999
NETWORK_TEST_UPLOAD=39999999999
traffic_used_bytes() {
    case "$1" in
        total) printf '%s\n' "$NETWORK_TEST_TOTAL" ;;
        upload) printf '%s\n' "$NETWORK_TEST_UPLOAD" ;;
        download) printf '%s\n' 0 ;;
        *) return 1 ;;
    esac
}
assert_fail "active probe budget stays open below reserved threshold" \
    traffic_budget_reached upload
NETWORK_TEST_UPLOAD=40000000000
assert_ok "active probe budget stops at reserved direction threshold" \
    traffic_budget_reached upload
NETWORK_TEST_UPLOAD=0
NETWORK_TEST_TOTAL=85000000000
assert_ok "active probe budget stops at reserved total threshold" \
    traffic_budget_reached upload

ROUTE_GET_LOG="$TEMP_DIR/route-get-target"
ip() {
    [[ "$1 $2 $3" == '-4 route get' ]] || return 1
    printf '%s\n' "$4" > "$ROUTE_GET_LOG"
    printf '%s via 192.0.2.1 dev eth7 src 192.0.2.2\n' "$4"
}
read_iface_counter() {
    [[ "$1" == eth7 ]] || return 1
    case "$2" in rx) printf '%s\n' 100 ;; tx) printf '%s\n' 200 ;; *) return 1 ;; esac
}
traffic_mark 198.51.100.25
assert_eq eth7 "$PROBE_IFACE" "traffic accounting uses actual target route interface"
assert_eq 198.51.100.25 "$(cat "$ROUTE_GET_LOG")" "traffic accounting routes the real IPv4 target"
unset -f ip read_iface_counter

generated_config="$TEMP_DIR/generated.conf"
prepare_dynamic_case
resolve_tuning_values >/dev/null
ECN_DISABLED=false
create_network_config "$generated_config" false
if grep -Eq '^net[.]ipv4[.]tcp_ecn[[:space:]]*=' "$generated_config"; then
    fail "default generated config still owns tcp_ecn"
fi
if grep -Eq '^net[.]netfilter[.]nf_conntrack_max[[:space:]]*=' "$generated_config"; then
    fail "generated config still owns nf_conntrack_max"
fi
for retired_key in \
    net.ipv4.tcp_mem \
    net.ipv4.tcp_adv_win_scale \
    net.core.rmem_default \
    net.core.wmem_default \
    net.core.netdev_budget \
    net.core.netdev_budget_usecs; do
    if grep -Eq "^${retired_key//./[.]}[[:space:]]*=" "$generated_config"; then
        fail "generated config still owns $retired_key"
    fi
done
assert_eq '4096 2097152 39845888' \
    "$(read_saved_sysctl_value "$generated_config" net.ipv4.tcp_rmem)" \
    "generated config uses fixed 2 MiB receive default"
assert_eq '4096 2097152 20971520' \
    "$(read_saved_sysctl_value "$generated_config" net.ipv4.tcp_wmem)" \
    "generated config uses fixed 2 MiB send default"
printf 'PASS: default generated config leaves retired global parameters unmanaged\n'

ECN_DISABLED=true
create_network_config "$generated_config" false
assert_eq '0' "$(read_saved_sysctl_value "$generated_config" net.ipv4.tcp_ecn)" \
    "explicit disable writes tcp_ecn=0"

mkdir -p "$IPV6_CONF_ROOT"/{all,default,eth0,eth1,br0,veth123}
touch "$IPV6_CONF_ROOT/all/forwarding" "$IPV6_CONF_ROOT/all/accept_ra"
for ra_iface in default eth0 eth1 br0 veth123; do
    touch "$IPV6_CONF_ROOT/$ra_iface/accept_ra"
done
IPV6_ROUTE_GET_IFACE=eth1
IPV6_DEFAULT_IFACE=eth0
ip() {
    case "$1 $2 $3" in
        '-6 route get')
            [[ -n "$IPV6_ROUTE_GET_IFACE" ]] &&
                printf '2606:4700:4700::1111 via 2001:db8::1 dev %s src 2001:db8::2\n' \
                    "$IPV6_ROUTE_GET_IFACE"
            ;;
        '-6 route show')
            [[ -n "$IPV6_DEFAULT_IFACE" ]] &&
                printf 'default via 2001:db8::1 dev %s proto ra metric 100\n' \
                    "$IPV6_DEFAULT_IFACE"
            ;;
        *) return 1 ;;
    esac
}
ra_config="$TEMP_DIR/ra.conf"
: > "$ra_config"
append_ipv6_forwarding_config "$ra_config"
grep -Fq 'net.ipv6.conf.eth1.accept_ra = 2' "$ra_config" ||
    fail "actual IPv6 route interface did not receive accept_ra=2"
for excluded_iface in eth0 br0 veth123; do
    ! grep -Fq "net.ipv6.conf.${excluded_iface}.accept_ra = 2" "$ra_config" ||
        fail "non-egress interface $excluded_iface incorrectly received accept_ra=2"
done
printf 'PASS: multiple NICs select only actual IPv6 default egress and exclude bridge/veth\n'

IPV6_ROUTE_GET_IFACE=""
IPV6_DEFAULT_IFACE=eth0
: > "$ra_config"
append_ipv6_forwarding_config "$ra_config"
grep -Fq 'net.ipv6.conf.eth0.accept_ra = 2' "$ra_config" ||
    fail "IPv6 default-route fallback did not select eth0"
printf 'PASS: IPv6 default-route fallback selects one egress\n'

IPV6_ROUTE_GET_IFACE=""
IPV6_DEFAULT_IFACE=""
: > "$ra_config"
append_ipv6_forwarding_config "$ra_config"
! grep -Eq '^net[.]ipv6[.]conf[.].+[.]accept_ra = 2$' "$ra_config" ||
    fail "accept_ra=2 was generated without an IPv6 default route"
printf 'PASS: no IPv6 default route generates no per-interface accept_ra=2\n'
unset -f ip

managed_config="$TEMP_DIR/managed.conf"
initial_runtime="$TEMP_DIR/initial-runtime"
runtime_unknown="$TEMP_DIR/initial-runtime-unknown"
initial_config="$TEMP_DIR/initial-config"
config_unknown="$TEMP_DIR/initial-config-unknown"
printf '%s\n' 'net.ipv4.ip_local_port_range = 1024 65535' > "$managed_config"
printf '%s\n' 'net.ipv4.ip_local_port_range=40000 65000' > "$initial_runtime"
printf '%s\n' 'net.ipv4.ip_local_port_range = 32768 62000' > "$initial_config"
assert_ok "detect legacy managed unsafe port range" managed_unsafe_port_range_present "$managed_config"
assert_eq '40000 65000' \
    "$(resolve_port_range_restore_value "$managed_config" "$initial_runtime" "$runtime_unknown" \
        "$initial_config" "$config_unknown")" \
    "prefer initial runtime port range"

rm -f "$initial_runtime"
assert_eq '32768 62000' \
    "$(resolve_port_range_restore_value "$managed_config" "$initial_runtime" "$runtime_unknown" \
        "$initial_config" "$config_unknown")" \
    "fall back to initial config port range"

rm -f "$initial_config"
assert_eq '32768 60999' \
    "$(resolve_port_range_restore_value "$managed_config" "$initial_runtime" "$runtime_unknown" \
        "$initial_config" "$config_unknown")" \
    "fall back to Debian default port range"

printf '%s\n' 'net.ipv4.ip_local_port_range = 32768 60999' > "$managed_config"
assert_fail "ignore non-legacy port range" resolve_port_range_restore_value \
    "$managed_config" "$initial_runtime" "$runtime_unknown" "$initial_config" "$config_unknown"

printf '%s\n' 'net.ipv4.ip_local_port_range=1024 65535' > "$initial_runtime"
printf '%s\n' 'net.ipv4.ip_local_port_range = 1024 65535' > "$initial_config"
printf '%s\n' 'net.ipv4.ip_local_port_range = 1024 65535' > "$managed_config"
assert_eq '32768 60999' \
    "$(resolve_port_range_restore_value "$managed_config" "$initial_runtime" "$runtime_unknown" \
        "$initial_config" "$config_unknown")" \
    "reject contaminated unsafe initial port range"
touch "$runtime_unknown"
printf '%s\n' 'net.ipv4.ip_local_port_range = 32768 62000' > "$initial_config"
assert_eq '32768 62000' \
    "$(resolve_port_range_restore_value "$managed_config" "$initial_runtime" "$runtime_unknown" \
        "$initial_config" "$config_unknown")" \
    "ignore runtime backup marked unknown"
assert_fail "reject malformed port range" normalize_port_range '1024 invalid'

removed_managed_config="$TEMP_DIR/removed-managed.conf"
removed_initial_runtime="$TEMP_DIR/removed-initial-runtime"
removed_runtime_unknown="$TEMP_DIR/removed-initial-runtime-unknown"
removed_initial_config="$TEMP_DIR/removed-initial-config"
removed_config_unknown="$TEMP_DIR/removed-initial-config-unknown"
printf '%s\n' \
    '# 由 network-optimize.sh 自动生成。' \
    'net.ipv4.tcp_ecn = 1' \
    'net.ipv4.tcp_mem = 16384 32768 65536' \
    'net.ipv4.tcp_adv_win_scale = 1' \
    'net.core.rmem_default = 4194304' \
    'net.core.wmem_default = 4194304' \
    'net.core.netdev_budget = 600' \
    'net.core.netdev_budget_usecs = 4000' \
    'net.netfilter.nf_conntrack_max = 262144' > "$removed_managed_config"
printf '%s\n' \
    'net.ipv4.tcp_ecn=2' \
    'net.ipv4.tcp_mem=4096 8192 16384' \
    'net.ipv4.tcp_adv_win_scale=1' \
    'net.core.rmem_default=212992' \
    'net.core.wmem_default=212992' \
    'net.core.netdev_budget=300' \
    'net.core.netdev_budget_usecs=2000' \
    'net.netfilter.nf_conntrack_max=131072' > "$removed_initial_runtime"
printf '%s\n' \
    'net.ipv4.tcp_ecn = 0' \
    'net.ipv4.tcp_mem = 8192 16384 32768' \
    'net.ipv4.tcp_adv_win_scale = 1' \
    'net.core.rmem_default = 262144' \
    'net.core.wmem_default = 262144' \
    'net.core.netdev_budget = 300' \
    'net.core.netdev_budget_usecs = 2000' \
    'net.netfilter.nf_conntrack_max = 65536' > "$removed_initial_config"
assert_ok "detect old managed ECN" managed_removed_sysctl_present \
    "$removed_managed_config" net.ipv4.tcp_ecn
assert_ok "detect old managed Conntrack max" managed_removed_sysctl_present \
    "$removed_managed_config" net.netfilter.nf_conntrack_max
assert_ok "detect old managed tcp_mem" managed_removed_sysctl_present \
    "$removed_managed_config" net.ipv4.tcp_mem
assert_ok "detect old managed netdev budget" managed_removed_sysctl_present \
    "$removed_managed_config" net.core.netdev_budget
assert_eq '4096 8192 16384' "$(resolve_removed_sysctl_restore_value \
    "$removed_initial_runtime" "$removed_runtime_unknown" \
    "$removed_initial_config" "$removed_config_unknown" net.ipv4.tcp_mem)" \
    "prefer initial runtime tcp_mem"
assert_eq '300' "$(resolve_removed_sysctl_restore_value \
    "$removed_initial_runtime" "$removed_runtime_unknown" \
    "$removed_initial_config" "$removed_config_unknown" net.core.netdev_budget)" \
    "prefer initial runtime netdev budget"
assert_eq '2' "$(resolve_removed_sysctl_restore_value \
    "$removed_initial_runtime" "$removed_runtime_unknown" \
    "$removed_initial_config" "$removed_config_unknown" net.ipv4.tcp_ecn)" \
    "prefer initial runtime ECN"
assert_eq '131072' "$(resolve_removed_sysctl_restore_value \
    "$removed_initial_runtime" "$removed_runtime_unknown" \
    "$removed_initial_config" "$removed_config_unknown" net.netfilter.nf_conntrack_max)" \
    "prefer initial runtime Conntrack max"
rm -f "$removed_initial_runtime"
assert_eq '8192 16384 32768' "$(resolve_removed_sysctl_restore_value \
    "$removed_initial_runtime" "$removed_runtime_unknown" \
    "$removed_initial_config" "$removed_config_unknown" net.ipv4.tcp_mem)" \
    "fall back to initial config tcp_mem"
assert_eq '0' "$(resolve_removed_sysctl_restore_value \
    "$removed_initial_runtime" "$removed_runtime_unknown" \
    "$removed_initial_config" "$removed_config_unknown" net.ipv4.tcp_ecn)" \
    "fall back to initial config ECN"
assert_eq '65536' "$(resolve_removed_sysctl_restore_value \
    "$removed_initial_runtime" "$removed_runtime_unknown" \
    "$removed_initial_config" "$removed_config_unknown" net.netfilter.nf_conntrack_max)" \
    "fall back to initial config Conntrack max"
touch "$removed_config_unknown"
assert_fail "reject config backup marked unknown" resolve_removed_sysctl_restore_value \
    "$removed_initial_runtime" "$removed_runtime_unknown" \
    "$removed_initial_config" "$removed_config_unknown" net.ipv4.tcp_ecn
rm -f "$removed_config_unknown"
printf '%s\n' 'net.ipv4.tcp_ecn = invalid' > "$removed_initial_config"
assert_fail "reject unknown ECN restore value" resolve_removed_sysctl_restore_value \
    "$removed_initial_runtime" "$removed_runtime_unknown" \
    "$removed_initial_config" "$removed_config_unknown" net.ipv4.tcp_ecn
assert_fail "reject malformed tcp_mem" normalize_removed_sysctl_value \
    net.ipv4.tcp_mem '8192 4096 16384'
assert_fail "reject invalid tcp_adv_win_scale" normalize_removed_sysctl_value \
    net.ipv4.tcp_adv_win_scale 32

runtime_backup="$TEMP_DIR/runtime-backup"
: > "$runtime_backup"
SYSCTL_PORT_RANGE='1024 65535'
SYSCTL_TCP_ECN='1'
SYSCTL_CONNTRACK_MAX='262144'
SYSCTL_WRITE_FAIL_KEY=''
sysctl() {
    case "$1" in
        -n)
            case "$2" in
                net.ipv4.ip_local_port_range) printf '%s\n' "$SYSCTL_PORT_RANGE" ;;
                net.ipv4.tcp_ecn) printf '%s\n' "$SYSCTL_TCP_ECN" ;;
                net.netfilter.nf_conntrack_max) printf '%s\n' "$SYSCTL_CONNTRACK_MAX" ;;
                *) return 1 ;;
            esac
            ;;
        -w)
            [[ "${2%%=*}" != "$SYSCTL_WRITE_FAIL_KEY" ]] || return 1
            case "$2" in
                net.ipv4.ip_local_port_range=*) SYSCTL_PORT_RANGE="${2#*=}" ;;
                net.ipv4.tcp_ecn=*) SYSCTL_TCP_ECN="${2#*=}" ;;
                net.netfilter.nf_conntrack_max=*) SYSCTL_CONNTRACK_MAX="${2#*=}" ;;
                *) return 1 ;;
            esac
            ;;
        *) return 1 ;;
    esac
}
transaction_target="$TEMP_DIR/transaction-target"
transaction_current="$TEMP_DIR/transaction-current"
printf '%s\n' \
    'net.ipv4.tcp_ecn=2' \
    'net.netfilter.nf_conntrack_max=131072' > "$transaction_target"
assert_ok "capture runtime values across restore inputs" capture_runtime_values_from_files \
    "$transaction_current" "$transaction_target" "$transaction_target"
assert_eq 2 "$(wc -l < "$transaction_current" | tr -d ' ')" \
    "runtime transaction snapshot deduplicates keys"
SYSCTL_WRITE_FAIL_KEY=net.netfilter.nf_conntrack_max
assert_fail "strict runtime restore reports partial failure" apply_runtime_values_strict \
    "$transaction_target"
assert_eq 2 "$SYSCTL_TCP_ECN" "strict restore exposes the partial write for rollback"
SYSCTL_WRITE_FAIL_KEY=''
restore_runtime_values "$transaction_current"
assert_eq 1 "$SYSCTL_TCP_ECN" "transaction rollback restores ECN after partial failure"
assert_eq 262144 "$SYSCTL_CONNTRACK_MAX" \
    "transaction rollback preserves Conntrack max after partial failure"

assert_ok "capture current port range for rollback" capture_port_range_for_rollback "$runtime_backup"
assert_eq 'net.ipv4.ip_local_port_range=1024 65535' "$(cat "$runtime_backup")" \
    "rollback snapshot includes previous port range"
assert_ok "apply safe port range migration" apply_port_range_migration '32768 60999'
assert_eq '32768 60999' "$SYSCTL_PORT_RANGE" "port range migration applies expected value"
assert_ok "capture current ECN for rollback" capture_runtime_value_for_rollback \
    "$runtime_backup" net.ipv4.tcp_ecn
assert_ok "capture current Conntrack max for rollback" capture_runtime_value_for_rollback \
    "$runtime_backup" net.netfilter.nf_conntrack_max
assert_eq '1' "$(read_saved_sysctl_value "$runtime_backup" net.ipv4.tcp_ecn)" \
    "rollback snapshot includes previous ECN"
assert_eq '262144' "$(read_saved_sysctl_value "$runtime_backup" net.netfilter.nf_conntrack_max)" \
    "rollback snapshot includes previous Conntrack max"
assert_ok "apply ECN migration" apply_removed_sysctl_migration net.ipv4.tcp_ecn 2
assert_ok "apply Conntrack max migration" apply_removed_sysctl_migration \
    net.netfilter.nf_conntrack_max 131072
assert_eq '2' "$SYSCTL_TCP_ECN" "ECN migration applies expected value"
assert_eq '131072' "$SYSCTL_CONNTRACK_MAX" "Conntrack migration applies expected value"
restore_runtime_values "$runtime_backup"
assert_eq '1' "$SYSCTL_TCP_ECN" "runtime rollback restores previous ECN"
assert_eq '262144' "$SYSCTL_CONNTRACK_MAX" "runtime rollback restores previous Conntrack max"
if grep -Eq '^net[.]ipv4[.]ip_local_port_range[[:space:]]*=' \
    "$ROOT_DIR/modules/network-optimize.sh"; then
    fail "generated sysctl configuration still owns ip_local_port_range"
fi
printf 'PASS: generated sysctl configuration no longer owns ip_local_port_range\n'

# Failed staging must not destroy the prior previous-backup snapshot.
mkdir -p "$(dirname "$NETWORK_CONF")"
printf '%s\n' 'current config' > "$NETWORK_CONF"
printf '%s\n' 'initial config' > "$NETWORK_INITIAL_BACKUP"
printf '%s\n' 'old previous config' > "$NETWORK_PREVIOUS_BACKUP"
cp() { return 1; }
assert_fail "staging copy failure is reported" backup_managed_file \
    "$NETWORK_CONF" "$NETWORK_INITIAL_BACKUP" "$NETWORK_PREVIOUS_BACKUP" \
    "$NETWORK_INITIAL_ABSENT" "$NETWORK_PREVIOUS_ABSENT"
unset -f cp
assert_eq 'old previous config' "$(cat "$NETWORK_PREVIOUS_BACKUP")" \
    "failed staging copy preserves old previous backup"

# Restore must accumulate route failure and never report overall success.
printf '%s\n' 'restored config' > "$NETWORK_PREVIOUS_BACKUP"
apply_network_config() { return 0; }
restore_default_route() { return 1; }
restore_log="$TEMP_DIR/restore-failure.log"
if restore_optimization previous > "$restore_log" 2>&1; then
    fail "route restore failure unexpectedly returned success"
fi
grep -Fq '恢复项 route：失败' "$restore_log" ||
    fail "route restore failure was not named"
grep -Fq '部分恢复：失败项 route' "$restore_log" ||
    fail "partial restore summary omitted route"
! grep -Fq '网络配置已恢复到 previous 状态' "$restore_log" ||
    fail "partial restore incorrectly reported overall success"
printf 'PASS: route restore failure returns nonzero without overall success\n'

if grep -Eq 'restore_legacy_limits|LIMITS_|/etc/security/limits|[.]conf[.]disabled' \
    "$ROOT_DIR/modules/network-optimize.sh"; then
    fail "legacy limits management code remains in network-optimize.sh"
fi
printf 'PASS: legacy limits functions, constants, calls, and paths are absent\n'

printf 'All network-optimize entry tests passed.\n'
