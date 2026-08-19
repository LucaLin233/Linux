#!/usr/bin/env bash
set -euo pipefail

readonly ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT
export NETWORK_OPTIMIZE_STATE_DIR="$TEMP_DIR/state"
export NETWORK_OPTIMIZE_CONF="$TEMP_DIR/etc/sysctl.d/99-network-optimize.conf"
export NETWORK_OPTIMIZE_BBR_MODULES_FILE="$TEMP_DIR/etc/modules-load.d/network-optimize-bbr.conf"
export NETWORK_OPTIMIZE_INITCWND_HOOK="$TEMP_DIR/networkd-dispatcher/routable.d/50-network-optimize-initcwnd"
export NETWORK_OPTIMIZE_CACHE_FILE="$TEMP_DIR/state/network-optimize.bandwidth-cache"
export NETWORK_OPTIMIZE_LOCK_FILE="$TEMP_DIR/network-optimize.lock"

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

deny_real_network() {
    fail "CI attempted an unmocked public network or APT operation: $*"
}
iperf3() { deny_real_network iperf3 "$@"; }
ping() { deny_real_network ping "$@"; }
getent() { deny_real_network getent "$@"; }
apt-get() { deny_real_network apt-get "$@"; }
ip() { deny_real_network ip "$@"; }
read_iface_counter() { deny_real_network interface-counter "$@"; }

read_config_value() {
    local file="$1" wanted_key="$2"

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
    AUTO_MODE_REQUESTED=false
    INITCWND_MODE=auto
    INITCWND_ENABLED=true
    INITCWND_POLICY=unknown
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
    MEASUREMENT_SOURCE=unknown
    MEASUREMENT_EPOCH=0
    MEASUREMENT_TIME=unknown
    MEASUREMENT_NODES=none
    MEASUREMENT_CONFIDENCE=unknown
    MEASUREMENT_WARNINGS=""
    MEASUREMENT_ROUTE_TARGET=""
    MEASUREMENT_ROUTE_IDENTITY=""
}

is_interactive_terminal() { return 1; }
reset_selection
assert_fail "non-interactive execution requires --auto or complete bandwidth" \
    select_tuning_mode >/dev/null 2>&1
assert_eq '' "$TUNING_MODE" "refused non-interactive selection leaves mode unset"

is_interactive_terminal() { return 0; }
reset_selection
select_tuning_mode >/dev/null <<< ""
assert_eq auto "$TUNING_MODE" "interactive Enter selects default public speed test"
assert_eq true "$AUTO_MODE_REQUESTED" "default Enter records automatic mode"

reset_selection
select_tuning_mode >/dev/null <<'EOF'
n
1000
500
EOF
assert_eq manual "$TUNING_MODE" "interactive N selects manual bandwidth"
assert_eq 1000 "$MANUAL_DOWNLOAD_MBPS" "manual mode records download bandwidth"
assert_eq 500 "$MANUAL_UPLOAD_MBPS" "manual mode records upload bandwidth"
assert_eq 150 "$MANUAL_RTT_MS" "manual mode defaults RTT to 150 ms"

is_interactive_terminal() { return 1; }
reset_selection
parse_arguments install --auto
read() { fail "explicit --auto unexpectedly prompted"; }
select_tuning_mode
unset -f read
assert_eq auto "$TUNING_MODE" "--auto selects non-interactive automatic mode"
assert_eq true "$TUNING_SELECTION_EXPLICIT" "--auto bypasses the prompt"

for retired in --probe --yes --disable-ecn; do
    reset_selection
    assert_fail "reject retired $retired" parse_arguments install "$retired"
done
reset_selection
assert_fail "reject retired verify command" parse_arguments verify
reset_selection
assert_fail "reject --auto with manual bandwidth" \
    parse_arguments install --auto --bandwidth-mbps 1000
reset_selection
assert_fail "reject incomplete manual bandwidth" \
    parse_arguments plan --download-mbps 1000
reset_selection
assert_fail "reject RTT without bandwidth or --auto" \
    parse_arguments plan --rtt-ms 180
reset_selection
parse_arguments install --download-mbps 1000 --upload-mbps 500
assert_eq manual "$TUNING_MODE" "complete manual bandwidth selects manual mode"
assert_eq 150 "$MANUAL_RTT_MS" "manual command defaults RTT"

(
    mutation_log="$TEMP_DIR/retired-mutations.log"
    : > "$mutation_log"
    atomic_write_file() { printf 'atomic\n' >> "$mutation_log"; }
    sysctl() { printf 'sysctl\n' >> "$mutation_log"; return 1; }
    ip() { printf 'ip\n' >> "$mutation_log"; return 1; }
    apt-get() { printf 'apt\n' >> "$mutation_log"; return 1; }
    for retired in --probe --yes --disable-ecn; do
        reset_selection
        if (main install "$retired" >/dev/null 2>&1); then
            fail "retired $retired unexpectedly reached main success"
        fi
    done
    reset_selection
    if (main verify >/dev/null 2>&1); then
        fail "retired verify command unexpectedly reached main success"
    fi
    [[ ! -s "$mutation_log" ]] || fail "retired interfaces performed a write"
    printf 'PASS: retired parameters and command perform no writes\n'
)

if grep -Fq 'network-optimize' "$ROOT_DIR/linux_setup.sh"; then
    fail "linux_setup contains a network-optimize special case"
fi
execute_module_body=$(sed -n '/^execute_module() {/,/^}/p' "$ROOT_DIR/linux_setup.sh")
grep -Fq 'if bash "$module_file"; then' <<< "$execute_module_body" ||
    fail "linux_setup no longer invokes modules without arguments"
printf 'PASS: linux_setup keeps generic no-argument module invocation\n'

(
    apt_log="$TEMP_DIR/apt.log"
    : > "$apt_log"
    command() {
        [[ "$1" == "-v" ]] || return 1
        [[ "$2" != "iperf3" ]]
    }
    apt-get() {
        printf '%s\n' "$*" >> "$apt_log"
        return 0
    }
    install_probe_dependencies >/dev/null
    grep -Fqx 'update -qq' "$apt_log" || fail "dependency install skipped apt update"
    grep -Fqx 'install -y --no-install-recommends iperf3' "$apt_log" ||
        fail "dependency install did not use APT for iperf3 only"
    printf 'PASS: missing iperf3 installs through non-interactive APT\n'
)

NETWORK_TEST_TOTAL=24999999999
NETWORK_TEST_UPLOAD=12499999999
TRAFFIC_IFACES=(eth0)
traffic_used_bytes() {
    case "$1" in
        total) printf '%s\n' "$NETWORK_TEST_TOTAL" ;;
        upload) printf '%s\n' "$NETWORK_TEST_UPLOAD" ;;
        download) printf '%s\n' 0 ;;
        *) return 1 ;;
    esac
}
assert_fail "budget stays open below 12.5/25 GB" traffic_budget_reached upload
NETWORK_TEST_UPLOAD=12500000000
assert_ok "budget stops at 12.5 GB direction limit" traffic_budget_reached upload
NETWORK_TEST_UPLOAD=0
NETWORK_TEST_TOTAL=25000000000
assert_ok "budget stops at 25 GB total limit" traffic_budget_reached upload
unset -f traffic_used_bytes

(
    reset_selection
    detect_memory_mb() { printf '%s\n' 8192; }
    detect_cgroup_memory_limit_mb() { return 1; }
    current_epoch() { printf '%s\n' 2000000000; }
    format_measurement_epoch() { printf '%s\n' '2033-05-18T03:33:20Z'; }
    TUNING_MODE=manual
    MANUAL_DOWNLOAD_MBPS=1000
    MANUAL_UPLOAD_MBPS=500
    MANUAL_RTT_MS=180
    resolve_tuning_values >/dev/null
    assert_eq manual "$MEASUREMENT_CONFIDENCE" "manual input records explicit confidence"
    assert_eq 'command line manual input' "$MEASUREMENT_SOURCE" "manual input records source"

    generated_config="$TEMP_DIR/generated.conf"
    create_network_config "$generated_config" false
    grep -Fq '# 测量来源: command line manual input' "$generated_config" ||
        fail "generated config omits measurement source"
    grep -Fq '# 测量时间: 2033-05-18T03:33:20Z' "$generated_config" ||
        fail "generated config omits measurement time"
    grep -Fq '# 测量节点: manual input' "$generated_config" ||
        fail "generated config omits measurement nodes"
    grep -Fq '# 测量可信度: manual' "$generated_config" ||
        fail "generated config omits confidence"
    grep -Fq '# 测量警告: none' "$generated_config" ||
        fail "generated config omits warnings"

    for forbidden_key in \
        net.ipv4.tcp_ecn \
        net.ipv4.tcp_shrink_window \
        net.ipv4.tcp_collapse_max_bytes \
        net.ipv4.conf.all.forwarding \
        net.ipv4.conf.default.forwarding \
        net.ipv6.conf.all.forwarding \
        net.ipv6.conf.default.forwarding \
        net.ipv6.conf.all.accept_ra \
        net.ipv6.conf.default.accept_ra; do
        if grep -Eq "^${forbidden_key//./[.]}[[:space:]]*=" "$generated_config"; then
            fail "generated config still writes $forbidden_key"
        fi
    done
    assert_eq '4096 2097152 47185920' \
        "$(read_config_value "$generated_config" net.ipv4.tcp_rmem)" \
        "generated config keeps receive buffer calculation"
    assert_eq '4096 2097152 25165824' \
        "$(read_config_value "$generated_config" net.ipv4.tcp_wmem)" \
        "generated config keeps send buffer calculation"

    mkdir -p "$(dirname "$NETWORK_CONF")"
    cp "$generated_config" "$NETWORK_CONF"
    detect_default_iface() { return 1; }
    default_ipv4_route() { printf '\n'; }
    sysctl() { return 1; }
    tc() { return 1; }
    status_output=$(show_status)
    grep -Fq '测量来源: command line manual input' <<< "$status_output" ||
        fail "status omits measurement source"
    grep -Fq '测量时间: 2033-05-18T03:33:20Z' <<< "$status_output" ||
        fail "status omits measurement time"
    grep -Fq '测量节点: manual input' <<< "$status_output" ||
        fail "status omits measurement nodes"
    grep -Fq '测量可信度: manual' <<< "$status_output" ||
        fail "status omits confidence"
    grep -Fq '测量警告: none' <<< "$status_output" ||
        fail "status omits warnings"
    printf 'PASS: status reports persisted measurement metadata\n'
)

if grep -Eq 'network_health_snapshot|classify_network_health|最近一小时 OOM|Conntrack 使用量|file_handle_status' \
    "$ROOT_DIR/modules/network-optimize.sh"; then
    fail "generic health panel remains in network-optimize"
fi
printf 'PASS: generic health panel is absent\n'

(
    reset_selection
    COMMAND=plan
    TUNING_MODE=auto
    AUTO_MODE_REQUESTED=true
    detect_memory_mb() { printf '%s\n' 8192; }
    detect_cgroup_memory_limit_mb() { return 1; }
    load_measurement_cache() { return 1; }
    probe_bandwidth() {
        DETECTED_DOWNLOAD_MBPS=1000
        DETECTED_UPLOAD_MBPS=500
        MEASUREMENT_SOURCE='mock public iperf3'
        MEASUREMENT_EPOCH=2000000000
        MEASUREMENT_TIME='2033-05-18T03:33:20Z'
        MEASUREMENT_NODES='one.example'
        MEASUREMENT_CONFIDENCE=low
        MEASUREMENT_WARNINGS='only one peer'
        return 0
    }
    is_interactive_terminal() { return 1; }
    resolve_tuning_values >/dev/null
    assert_eq 1000 "$DETECTED_DOWNLOAD_MBPS" "low-confidence complete download succeeds"
    assert_eq 500 "$DETECTED_UPLOAD_MBPS" "low-confidence complete upload succeeds"
    low_config="$TEMP_DIR/low-confidence.conf"
    create_network_config "$low_config" false
    grep -Fq '# 测量可信度: low' "$low_config" || fail "low confidence was not persisted"
    grep -Fq '# 测量警告: only one peer' "$low_config" || fail "warning was not persisted"
    printf 'PASS: complete low-confidence input returns success and persists warning\n'
)

(
    reset_selection
    COMMAND=plan
    TUNING_MODE=auto
    AUTO_MODE_REQUESTED=true
    detect_memory_mb() { printf '%s\n' 8192; }
    detect_cgroup_memory_limit_mb() { return 1; }
    load_measurement_cache() { return 1; }
    probe_bandwidth() { return 1; }
    is_interactive_terminal() { return 1; }
    assert_fail "missing complete measurement returns failure" resolve_tuning_values >/dev/null 2>&1
)

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

previous_scope_paths="$NETWORK_PREVIOUS_BACKUP|$NETWORK_PREVIOUS_ABSENT|"
previous_scope_paths+="$BBR_MODULES_PREVIOUS_BACKUP|$BBR_MODULES_PREVIOUS_ABSENT|"
previous_scope_paths+="$ROUTE_HOOK_PREVIOUS_BACKUP|$ROUTE_HOOK_PREVIOUS_ABSENT|"
previous_scope_paths+="$RUNTIME_PREVIOUS_BACKUP|$ROUTE_PREVIOUS_BACKUP|"
previous_scope_paths+="$ROUTE_PREVIOUS_ABSENT|$ROUTE_PREVIOUS_OWNED"
initial_scope_paths="$NETWORK_INITIAL_BACKUP|$NETWORK_INITIAL_ABSENT|"
initial_scope_paths+="$BBR_MODULES_INITIAL_BACKUP|$BBR_MODULES_INITIAL_ABSENT|"
initial_scope_paths+="$ROUTE_HOOK_INITIAL_BACKUP|$ROUTE_HOOK_INITIAL_ABSENT|"
initial_scope_paths+="$RUNTIME_INITIAL_BACKUP|$ROUTE_INITIAL_BACKUP|"
initial_scope_paths+="$ROUTE_INITIAL_ABSENT|$ROUTE_INITIAL_OWNED"
assert_eq "$previous_scope_paths" "$(restore_scope_paths previous)" \
    "resolve previous restore scope paths"
assert_eq "$initial_scope_paths" "$(restore_scope_paths initial)" \
    "resolve initial restore scope paths"
assert_fail "reject invalid restore scope paths" restore_scope_paths invalid

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
grep -Fq '恢复项 route：失败' "$restore_log" || {
    cat "$restore_log" >&2
    fail "route target failure was not named"
}
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
