#!/usr/bin/env bash
set -euo pipefail

readonly ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT
export NETWORK_OPTIMIZE_STATE_DIR="$TEMP_DIR/state"
export NETWORK_OPTIMIZE_CONF="$TEMP_DIR/etc/sysctl.d/99-network-optimize.conf"
export NETWORK_OPTIMIZE_BBR_MODULES_FILE="$TEMP_DIR/etc/modules-load.d/network-optimize-bbr.conf"
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

# All previous resources form one function-failure transaction.
eval "$(declare -f backup_managed_file | sed '1s/backup_managed_file/backup_managed_file_real/')"
FAIL_BACKUP_TARGET=""
SYSTEM_MUTATION_CALLS=0
ROUTE_MUTATION_CALLS=0
IP_QUERY_FAIL=false
ROUTE_REPLACE_FAIL_MATCH=""
INJECT_HOOK_TARGET_FAILURE=false
CURRENT_ROUTE="default via 192.0.2.1 dev eth0 proto dhcp metric 100"
PRE_RESTORE_ROUTE="$CURRENT_ROUTE"
TARGET_RESTORE_ROUTE="default via 198.51.100.1 dev eth7 proto static metric 70"

backup_managed_file() {
    [[ -z "$FAIL_BACKUP_TARGET" || "$1" != "$FAIL_BACKUP_TARGET" ]] || return 1
    backup_managed_file_real "$@"
}
modprobe() {
    ((SYSTEM_MUTATION_CALLS += 1))
    return 0
}
apply_network_config() {
    ((SYSTEM_MUTATION_CALLS += 1))
    return 0
}
ip() {
    local route_args
    case "$1 $2 $3" in
        '-4 route show')
            [[ "$IP_QUERY_FAIL" == "false" ]] || return 1
            printf '%s\n' "$CURRENT_ROUTE"
            ;;
        '-4 route replace')
            shift 3
            route_args="$*"
            if [[ "$ROUTE_REPLACE_FAIL_MATCH" == '*' ||
                -n "$ROUTE_REPLACE_FAIL_MATCH" &&
                "$route_args" == "$ROUTE_REPLACE_FAIL_MATCH" ]]; then
                return 1
            fi
            CURRENT_ROUTE="$route_args"
            ((ROUTE_MUTATION_CALLS += 1))
            if [[ "$INJECT_HOOK_TARGET_FAILURE" == "true" &&
                "$route_args" == "$TARGET_RESTORE_ROUTE" ]]; then
                rm -rf -- "$(dirname "$INITCWND_ROUTE_HOOK")"
                printf '%s\n' blocker > "$(dirname "$INITCWND_ROUTE_HOOK")"
            elif [[ "$INJECT_HOOK_TARGET_FAILURE" == "true" &&
                "$route_args" == "$PRE_RESTORE_ROUTE" ]]; then
                rm -f -- "$(dirname "$INITCWND_ROUTE_HOOK")"
                mkdir -p "$(dirname "$INITCWND_ROUTE_HOOK")"
            fi
            ;;
        '-4 route del')
            shift 3
            CURRENT_ROUTE=""
            ((ROUTE_MUTATION_CALLS += 1))
            ;;
        *) return 1 ;;
    esac
}

seed_previous_bundle() {
    local path

    while IFS= read -r path; do rm -f -- "$path"; done < <(previous_state_paths)
    rm -f -- \
        "$NETWORK_INITIAL_BACKUP" "$NETWORK_INITIAL_ABSENT" "$NETWORK_INITIAL_UNKNOWN" \
        "$BBR_MODULES_INITIAL_BACKUP" "$BBR_MODULES_INITIAL_ABSENT" \
        "$BBR_MODULES_INITIAL_UNKNOWN" "$ROUTE_HOOK_INITIAL_BACKUP" \
        "$ROUTE_HOOK_INITIAL_ABSENT" "$ROUTE_INITIAL_BACKUP" \
        "$ROUTE_INITIAL_ABSENT" "$ROUTE_INITIAL_UNKNOWN" "$ROUTE_INITIAL_OWNED"
    mkdir -p \
        "$(dirname "$NETWORK_CONF")" "$(dirname "$BBR_MODULES_FILE")" \
        "$(dirname "$INITCWND_ROUTE_HOOK")" "$NETWORK_OPTIMIZE_STATE_DIR"
    printf '%s\n' 'new network' > "$NETWORK_CONF"
    printf '%s\n' 'new modules' > "$BBR_MODULES_FILE"
    printf '%s\n' 'new hook' > "$INITCWND_ROUTE_HOOK"
    printf '%s\n' 'old network previous' > "$NETWORK_PREVIOUS_BACKUP"
    : > "$BBR_MODULES_PREVIOUS_ABSENT"
    printf '%s\n' 'old runtime previous' > "$RUNTIME_PREVIOUS_BACKUP"
    printf '%s\n' 'old route previous' > "$ROUTE_PREVIOUS_BACKUP"
    printf '%s\n' owned > "$ROUTE_PREVIOUS_OWNED"
    : > "$ROUTE_HOOK_PREVIOUS_ABSENT"
    printf '%s\n' 'new runtime previous' > "$TEMP_DIR/new-runtime-snapshot"
    CURRENT_ROUTE="default via 192.0.2.1 dev eth0 proto dhcp metric 100"
    IP_QUERY_FAIL=false
    ROUTE_MUTATION_CALLS=0
    SYSTEM_MUTATION_CALLS=0
}

assert_previous_bundle_unchanged() {
    local name="$1"

    assert_eq 'old network previous' "$(cat "$NETWORK_PREVIOUS_BACKUP")" \
        "$name preserves network previous content"
    [[ ! -e "$NETWORK_PREVIOUS_ABSENT" ]] || fail "$name changed network absent state"
    [[ -e "$BBR_MODULES_PREVIOUS_ABSENT" && ! -e "$BBR_MODULES_PREVIOUS_BACKUP" ]] ||
        fail "$name changed modules absent state"
    assert_eq 'old runtime previous' "$(cat "$RUNTIME_PREVIOUS_BACKUP")" \
        "$name preserves runtime previous content"
    assert_eq 'old route previous' "$(cat "$ROUTE_PREVIOUS_BACKUP")" \
        "$name preserves route previous content"
    [[ -e "$ROUTE_PREVIOUS_OWNED" && ! -e "$ROUTE_PREVIOUS_ABSENT" ]] ||
        fail "$name changed route marker state"
    [[ -e "$ROUTE_HOOK_PREVIOUS_ABSENT" && ! -e "$ROUTE_HOOK_PREVIOUS_BACKUP" ]] ||
        fail "$name changed hook absent state"
    assert_eq 0 "$SYSTEM_MUTATION_CALLS" "$name performs no sysctl or module mutation"
    assert_eq 0 "$ROUTE_MUTATION_CALLS" "$name performs no route mutation"
}

run_previous_failure_case() {
    local failed_target="$1"
    local query_failure="$2"
    local name="$3"

    seed_previous_bundle
    FAIL_BACKUP_TARGET="$failed_target"
    IP_QUERY_FAIL="$query_failure"
    if backup_previous_state_set "$TEMP_DIR/new-runtime-snapshot" >/dev/null 2>&1; then
        fail "$name unexpectedly succeeded"
    fi
    FAIL_BACKUP_TARGET=""
    IP_QUERY_FAIL=false
    assert_previous_bundle_unchanged "$name"
}

run_previous_failure_case "$NETWORK_CONF" false \
    "network failure after runtime previous write"
run_previous_failure_case "$BBR_MODULES_FILE" false \
    "modules failure after network previous write"
assert_eq 'new network' "$(cat "$NETWORK_INITIAL_BACKUP")" \
    "previous rollback retains successful network initial backup"
run_previous_failure_case "$INITCWND_ROUTE_HOOK" false \
    "hook failure after modules previous write"
[[ -f "$NETWORK_INITIAL_BACKUP" ]] ||
    fail "previous rollback removed successful network initial backup"
printf 'PASS: previous rollback retains successful initial backups\n'
run_previous_failure_case "" true \
    "route failure after hook previous write"

# Restore failures roll every changed item back to the operation-before snapshot.
apply_network_config() {
    local config_file="$1"
    local key value

    ((SYSTEM_MUTATION_CALLS += 1))
    while IFS='=' read -r key value; do
        key="${key//[[:space:]]/}"
        value=$(printf '%s\n' "$value" | normalize_sysctl_value)
        [[ "$key" == "net.ipv4.tcp_ecn" ]] && SYSCTL_TCP_ECN="$value"
    done < "$config_file"
}

reset_restore_fixture() {
    local path

    while IFS= read -r path; do rm -f -- "$path"; done < <(previous_state_paths)
    rm -rf -- "$(dirname "$INITCWND_ROUTE_HOOK")"
    mkdir -p \
        "$(dirname "$NETWORK_CONF")" "$(dirname "$BBR_MODULES_FILE")" \
        "$(dirname "$INITCWND_ROUTE_HOOK")" "$NETWORK_OPTIMIZE_STATE_DIR"
    printf '%s\n' 'net.ipv4.tcp_ecn = 1' > "$NETWORK_CONF"
    printf '%s\n' 'current modules' > "$BBR_MODULES_FILE"
    printf '%s\n' 'current hook' > "$INITCWND_ROUTE_HOOK"
    printf '%s\n' 'net.ipv4.tcp_ecn = 2' > "$NETWORK_PREVIOUS_BACKUP"
    printf '%s\n' 'target modules' > "$BBR_MODULES_PREVIOUS_BACKUP"
    printf '%s\n' 'net.ipv4.tcp_ecn=2' > "$RUNTIME_PREVIOUS_BACKUP"
    printf '%s\n' "$TARGET_RESTORE_ROUTE" > "$ROUTE_PREVIOUS_BACKUP"
    printf '%s\n' 'target hook' > "$ROUTE_HOOK_PREVIOUS_BACKUP"
    SYSCTL_TCP_ECN=1
    SYSCTL_WRITE_FAIL_KEY=''
    CURRENT_ROUTE="$PRE_RESTORE_ROUTE"
    ROUTE_REPLACE_FAIL_MATCH=""
    INJECT_HOOK_TARGET_FAILURE=false
    ROUTE_MUTATION_CALLS=0
    SYSTEM_MUTATION_CALLS=0
    rm -f "$ROUTE_OWNED_MARKER"
}

assert_restore_rolled_back() {
    local name="$1"

    assert_eq 'net.ipv4.tcp_ecn = 1' "$(cat "$NETWORK_CONF")" \
        "$name restores current network file"
    assert_eq 'current modules' "$(cat "$BBR_MODULES_FILE")" \
        "$name restores current modules file"
    assert_eq '1' "$SYSCTL_TCP_ECN" "$name restores current runtime sysctl"
    assert_eq "$PRE_RESTORE_ROUTE" "$CURRENT_ROUTE" "$name restores current route"
    assert_eq 'current hook' "$(cat "$INITCWND_ROUTE_HOOK")" \
        "$name restores current hook"
}

reset_restore_fixture
ROUTE_REPLACE_FAIL_MATCH="$TARGET_RESTORE_ROUTE"
restore_log="$TEMP_DIR/restore-route-failure.log"
if restore_optimization previous > "$restore_log" 2>&1; then
    fail "route target restore failure unexpectedly returned success"
fi
assert_restore_rolled_back "route target failure"
grep -Fq '恢复项 route：失败' "$restore_log" ||
    fail "route target failure was not named"
grep -Fq '目标恢复失败，已回滚到操作前状态' "$restore_log" ||
    fail "route target failure did not report successful rollback"
! grep -Fq '部分恢复' "$restore_log" ||
    fail "successful pre-restore rollback was described as partial"
! grep -Fq '网络配置已恢复到 previous 状态' "$restore_log" ||
    fail "route target failure incorrectly reported overall success"
printf 'PASS: route target failure rolls all prior changes back\n'

reset_restore_fixture
INJECT_HOOK_TARGET_FAILURE=true
restore_log="$TEMP_DIR/restore-hook-failure.log"
if restore_optimization previous > "$restore_log" 2>&1; then
    fail "hook target restore failure unexpectedly returned success"
fi
assert_restore_rolled_back "hook target failure"
grep -Fq '恢复项 hook：失败' "$restore_log" ||
    fail "hook target failure was not named"
grep -Fq '目标恢复失败，已回滚到操作前状态' "$restore_log" ||
    fail "hook target failure did not report successful rollback"
! grep -Fq '部分恢复' "$restore_log" ||
    fail "successful hook rollback was described as partial"
! grep -Fq '网络配置已恢复到 previous 状态' "$restore_log" ||
    fail "hook target failure incorrectly reported overall success"
printf 'PASS: hook target failure rolls route and prior changes back\n'

reset_restore_fixture
ROUTE_REPLACE_FAIL_MATCH='*'
restore_log="$TEMP_DIR/restore-rollback-failure.log"
if restore_optimization previous > "$restore_log" 2>&1; then
    fail "incomplete pre-restore rollback unexpectedly returned success"
fi
assert_eq 'net.ipv4.tcp_ecn = 1' "$(cat "$NETWORK_CONF")" \
    "incomplete rollback still restores network file"
assert_eq 'current modules' "$(cat "$BBR_MODULES_FILE")" \
    "incomplete rollback still restores modules file"
assert_eq '1' "$SYSCTL_TCP_ECN" "incomplete rollback still restores runtime sysctl"
assert_eq 'current hook' "$(cat "$INITCWND_ROUTE_HOOK")" \
    "incomplete rollback still restores hook"
grep -Fq '目标恢复失败，且回滚不完整' "$restore_log" ||
    fail "incomplete rollback summary was missing"
grep -Fq '回滚失败项 route' "$restore_log" ||
    fail "incomplete rollback did not name route"
grep -Fq '部分恢复：回滚失败项 route' "$restore_log" ||
    fail "partial final state was not reported"
! grep -Fq '网络配置已恢复到 previous 状态' "$restore_log" ||
    fail "incomplete rollback incorrectly reported overall success"
printf 'PASS: incomplete pre-restore rollback reports exact failed item\n'

if grep -Eq 'restore_legacy_limits|LIMITS_|/etc/security/limits|[.]conf[.]disabled' \
    "$ROOT_DIR/modules/network-optimize.sh"; then
    fail "legacy limits management code remains in network-optimize.sh"
fi
printf 'PASS: legacy limits functions, constants, calls, and paths are absent\n'

printf 'All network-optimize entry tests passed.\n'
