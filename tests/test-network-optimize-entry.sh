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

read_config_value() {
    local file="$1"
    local wanted_key="$2"

    awk -F= -v wanted="$wanted_key" '
        {
            key=$1
            gsub(/[[:space:]]/, "", key)
            if (key == wanted) {
                value=substr($0, index($0, "=") + 1)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
                print value
                exit
            }
        }
    ' "$file"
}

reset_selection() {
    COMMAND=install
    RESTORE_SCOPE=previous
    TUNING_MODE=""
    TUNING_SELECTION_EXPLICIT=false
    ACTIVE_PROBE_REQUESTED=false
    ECN_DISABLED=false
    MANUAL_BANDWIDTH_MBPS=""
    MANUAL_DOWNLOAD_MBPS=""
    MANUAL_UPLOAD_MBPS=""
    MANUAL_RTT_MS=""
    MANUAL_RTT_DEFAULTED=false
    BANDWIDTH_SOURCE=unknown
    BANDWIDTH_PROBE_NOTE=""
    INITCWND_MODE=auto
    INITCWND_ENABLED=true
    INITCWND_POLICY=unknown
    VERIFY_ASSUME_YES=false
    VERIFY_CONFIRM_EXPLICIT=false
}

is_interactive_terminal() { return 1; }
reset_selection
assert_fail "non-interactive execution requires an explicit bandwidth source" \
    select_tuning_mode >/dev/null 2>&1
assert_eq '' "$TUNING_MODE" "refused non-interactive selection leaves mode unset"

is_interactive_terminal() { return 0; }
reset_selection
select_tuning_mode >/dev/null <<< "y"
assert_eq probe "$TUNING_MODE" "interactive yes selects active probe"
assert_eq true "$ACTIVE_PROBE_REQUESTED" "interactive yes records probe consent"

reset_selection
select_tuning_mode >/dev/null <<'EOF'
n
1000
500
EOF
assert_eq manual "$TUNING_MODE" "interactive no selects manual bandwidth"
assert_eq 1000 "$MANUAL_DOWNLOAD_MBPS" "manual mode records download bandwidth"
assert_eq 500 "$MANUAL_UPLOAD_MBPS" "manual mode records upload bandwidth"
assert_eq 150 "$MANUAL_RTT_MS" "manual mode defaults RTT to 150 ms"
assert_eq true "$MANUAL_RTT_DEFAULTED" "interactive manual mode records default RTT"

reset_selection
parse_arguments install --probe
read() { fail "explicit probe unexpectedly prompted"; }
select_tuning_mode
unset -f read
assert_eq true "$TUNING_SELECTION_EXPLICIT" "explicit probe bypasses selection menu"
assert_eq probe "$TUNING_MODE" "explicit probe selects probe mode"
assert_eq true "$ACTIVE_PROBE_REQUESTED" "probe flag records explicit consent"

reset_selection
assert_fail "reject removed --auto option" parse_arguments install --auto
reset_selection
assert_fail "reject removed --static option" parse_arguments install --static
reset_selection
assert_fail "reject removed --no-probe option" parse_arguments install --no-probe

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
parse_arguments install --download-mbps 1000 --upload-mbps 500
read() { fail "explicit manual bandwidth unexpectedly prompted"; }
select_tuning_mode
unset -f read
assert_eq manual "$TUNING_MODE" "complete manual bandwidth bypasses interaction"
assert_eq 150 "$MANUAL_RTT_MS" "manual bandwidth defaults missing RTT to 150 ms"
assert_eq true "$MANUAL_RTT_DEFAULTED" "manual bandwidth records default RTT source"
reset_selection
parse_arguments plan --bandwidth-mbps 800
assert_eq 800 "$MANUAL_DOWNLOAD_MBPS" "symmetric bandwidth fills download"
assert_eq 800 "$MANUAL_UPLOAD_MBPS" "symmetric bandwidth fills upload"
reset_selection
assert_fail "reject incomplete manual download bandwidth" \
    parse_arguments plan --download-mbps 1000
reset_selection
assert_fail "reject incomplete manual upload bandwidth" \
    parse_arguments plan --upload-mbps 500
reset_selection
assert_fail "reject probe combined with manual bandwidth" \
    parse_arguments plan --probe --bandwidth-mbps 1000
reset_selection
assert_fail "removed custom RTT target is rejected" parse_arguments plan --probe --target example.com

prepare_dynamic_case() {
    TUNING_MODE=probe
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
    BANDWIDTH_PROBE_NOTE=""
    INITCWND_MODE=auto
    INITCWND_ENABLED=true
    INITCWND_POLICY=unknown
}

detect_memory_mb() { printf '%s\n' 8192; }
detect_cgroup_memory_limit_mb() { return 1; }
PROBE_SHOULD_FAIL=false
probe_bandwidth() {
    [[ "$PROBE_SHOULD_FAIL" == "false" ]] || return 1
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

PROBE_SHOULD_FAIL=true
is_interactive_terminal() { return 0; }
prepare_dynamic_case
resolve_tuning_values >/dev/null <<'EOF'
1200
600
EOF
assert_eq manual "$TUNING_MODE" "interactive probe failure switches to manual mode"
assert_eq 1200 "$DETECTED_DOWNLOAD_MBPS" "probe failure fallback records download"
assert_eq 600 "$DETECTED_UPLOAD_MBPS" "probe failure fallback records upload"
assert_eq 150 "$DETECTED_RTT_MS" "probe failure fallback keeps 150 ms default RTT"

prepare_dynamic_case
MANUAL_RTT_MS=180
resolve_tuning_values >/dev/null <<'EOF'
1200
600
EOF
assert_eq 180 "$DETECTED_RTT_MS" "probe failure fallback preserves explicit RTT"
assert_eq 'manual override' "$RTT_POLICY" "probe fallback records explicit RTT policy"

is_interactive_terminal() { return 1; }
prepare_dynamic_case
assert_fail "non-interactive probe failure rejects missing bandwidth" \
    resolve_tuning_values >/dev/null 2>&1

install_probe_dependencies() { return 0; }
detect_container() { return 1; }
detect_default_iface() { return 1; }
network_health_snapshot() { printf '%s\n' '0 0 0 0 0 0 0 0 0 0'; }
ZERO_SYSCTL_WRITES=0
ZERO_ROUTE_WRITES=0
sysctl() {
    case "$1" in
        -w|-p) ((ZERO_SYSCTL_WRITES += 1)) ;;
    esac
    return 1
}
ip() {
    case "$1 $2 $3" in
        '-4 route replace'|'-4 route del') ((ZERO_ROUTE_WRITES += 1)) ;;
    esac
    return 1
}
rm -rf "$NETWORK_CONF" "$NETWORK_OPTIMIZE_STATE_DIR" "$ROUTE_OWNED_MARKER"
prepare_dynamic_case
assert_fail "failed non-interactive probe aborts install" \
    install_optimization >/dev/null 2>&1
[[ ! -e "$NETWORK_CONF" && ! -e "$NETWORK_OPTIMIZE_STATE_DIR" &&
    ! -e "$ROUTE_OWNED_MARKER" ]] ||
    fail "failed probe wrote config, state, or route ownership"
assert_eq 0 "$ZERO_SYSCTL_WRITES" "failed probe performs zero sysctl writes"
assert_eq 0 "$ZERO_ROUTE_WRITES" "failed probe performs zero route writes"
printf 'PASS: invalid bandwidth fails before config, sysctl, or route writes\n'
unset -f sysctl ip

PROBE_SHOULD_FAIL=false
is_interactive_terminal() { return 0; }
for manual_rtt in 40 300; do
    prepare_dynamic_case
    TUNING_MODE=manual
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
BANDWIDTH_PROBE_NOTE='tcshape HTB 整形状态下测得（可能偏低）'
create_network_config "$generated_config" false
grep -Fq '# 带宽测量环境: tcshape HTB 整形状态下测得（可能偏低）' "$generated_config" ||
    fail "generated config omits active tcshape measurement warning"
printf 'PASS: generated config records shaped bandwidth source\n'
BANDWIDTH_PROBE_NOTE=""
if grep -Eq '^net[.]ipv4[.]tcp_ecn[[:space:]]*=' "$generated_config"; then
    fail "default generated config still owns tcp_ecn"
fi
if grep -Eq '^net[.]netfilter[.]nf_conntrack_max[[:space:]]*=' "$generated_config"; then
    fail "generated config still owns nf_conntrack_max"
fi
for retired_key in \
    net.ipv4.tcp_mem \
    net.ipv4.tcp_adv_win_scale \
    net.ipv4.ip_local_port_range \
    net.ipv4.conf.all.rp_filter \
    net.ipv4.conf.default.rp_filter \
    net.ipv4.udp_rmem_min \
    net.ipv4.udp_wmem_min \
    net.core.rmem_default \
    net.core.wmem_default \
    net.core.netdev_budget \
    net.core.netdev_budget_usecs; do
    if grep -Eq "^${retired_key//./[.]}[[:space:]]*=" "$generated_config"; then
        fail "generated config still owns $retired_key"
    fi
done
assert_eq '1' "$(read_config_value "$generated_config" net.ipv4.ip_forward)" \
    "generated config preserves IPv4 forwarding"
assert_eq '4096 2097152 39845888' \
    "$(read_config_value "$generated_config" net.ipv4.tcp_rmem)" \
    "generated config uses fixed 2 MiB receive default"
assert_eq '4096 2097152 20971520' \
    "$(read_config_value "$generated_config" net.ipv4.tcp_wmem)" \
    "generated config uses fixed 2 MiB send default"
printf 'PASS: default generated config leaves retired global parameters unmanaged\n'

ECN_DISABLED=true
create_network_config "$generated_config" false
assert_eq '0' "$(read_config_value "$generated_config" net.ipv4.tcp_ecn)" \
    "explicit disable writes tcp_ecn=0"

mkdir -p "$IPV6_CONF_ROOT"/{all,default,eth0,eth1,br0,br-docker,veth123}
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
for expected_ra_line in \
    'net.ipv6.conf.all.accept_ra = 1' \
    'net.ipv6.conf.default.accept_ra = 1' \
    'net.ipv6.conf.default.forwarding = 1' \
    'net.ipv6.conf.all.forwarding = 1'; do
    grep -Fq "$expected_ra_line" "$ra_config" ||
        fail "forwarding/RA config misses $expected_ra_line"
done
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

printf '%s\n' 1 > "$IPV6_CONF_ROOT/br-docker/accept_ra"
printf '%s\n' 2 > "$IPV6_CONF_ROOT/veth123/accept_ra"
virtual_ra_backup="$TEMP_DIR/virtual-ra.runtime"
: > "$virtual_ra_backup"
capture_virtual_ipv6_ra_values "$virtual_ra_backup"
assert_eq $'net.ipv6.conf.br-docker.accept_ra=1\nnet.ipv6.conf.veth123.accept_ra=2' \
    "$(sort "$virtual_ra_backup")" "capture virtual interface RA values"
RA_BR_DOCKER=1
RA_VETH123=2
sysctl() {
    local key

    case "$1" in
        -n)
            case "$2" in
                net.ipv6.conf.br-docker.accept_ra) printf '%s\n' "$RA_BR_DOCKER" ;;
                net.ipv6.conf.veth123.accept_ra) printf '%s\n' "$RA_VETH123" ;;
                *) return 1 ;;
            esac
            ;;
        -w)
            key="${2%%=*}"
            case "$key" in
                net.ipv6.conf.br-docker.accept_ra) RA_BR_DOCKER="${2#*=}" ;;
                net.ipv6.conf.veth123.accept_ra) RA_VETH123="${2#*=}" ;;
                *) return 1 ;;
            esac
            ;;
        *) return 1 ;;
    esac
}
normalize_virtual_ipv6_ra "$virtual_ra_backup" >/dev/null
assert_eq 0 "$RA_BR_DOCKER" "normalize bridge RA"
assert_eq 0 "$RA_VETH123" "normalize veth RA"
restore_runtime_values "$virtual_ra_backup"
assert_eq 1 "$RA_BR_DOCKER" "rollback restores bridge RA"
assert_eq 2 "$RA_VETH123" "rollback restores veth RA"
unset -f sysctl

SYSCTL_TCP_ECN='1'
SYSCTL_CONNTRACK_MAX='262144'
SYSCTL_WRITE_FAIL_KEY=''
sysctl() {
    case "$1" in
        -n)
            case "$2" in
                net.ipv4.tcp_ecn) printf '%s\n' "$SYSCTL_TCP_ECN" ;;
                net.netfilter.nf_conntrack_max) printf '%s\n' "$SYSCTL_CONNTRACK_MAX" ;;
                *) return 1 ;;
            esac
            ;;
        -w)
            [[ "${2%%=*}" != "$SYSCTL_WRITE_FAIL_KEY" ]] || return 1
            case "$2" in
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

if grep -Eq 'LEGACY_(KERNEL|SYSCTL)|RETIRED_SYSCTL_KEYS|migrate_legacy_(kernel|sysctl)|managed_removed_sysctl|normalize_removed_sysctl|apply_removed_sysctl_migration|resolve_port_range_restore_value|apply_port_range_migration|NO_PROBE' \
    "$ROOT_DIR/modules/network-optimize.sh"; then
    fail "removed network migration or mode framework remains"
fi
printf 'PASS: removed network migration and mode framework is absent\n'

printf 'All network-optimize entry tests passed.\n'
