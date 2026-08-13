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
    local expected="$1"
    local actual="$2"
    local name="$3"
    [[ "$actual" == "$expected" ]] || fail "$name: expected '$expected', got '$actual'"
    printf 'PASS: %s\n' "$name"
}

assert_eq "8388608" "$(calculate_buffer_max 100 150 268435456)" \
    "buffer max keeps 8 MiB floor"
assert_eq "39845888" "$(calculate_buffer_max 1000 150 268435456)" \
    "buffer max includes 2 MiB headroom"
assert_eq "4194304" "$(calculate_buffer_default 100 150 8388608)" \
    "buffer default keeps 4 MiB floor"
assert_eq "7340032" "$(calculate_buffer_default 700 150 37748736)" \
    "buffer default rounds half BDP within range"
assert_eq "8388608" "$(calculate_buffer_default 1000 150 37748736)" \
    "buffer default keeps 8 MiB ceiling"
assert_eq "67108864" "$(calculate_memory_cap 1024)" \
    "small-memory cap uses RAM / 16"
assert_eq "536870912" "$(calculate_memory_cap 8192)" \
    "large-memory cap uses RAM / 8 with 512 MiB ceiling"
assert_eq "16384 32768 65536" "$(calculate_tcp_mem 1024 4096)" \
    "tcp memory budget follows RAM with 4 KiB pages"
assert_eq "4096 8192 16384" "$(calculate_tcp_mem 1024 65536)" \
    "tcp memory budget follows RAM with 64 KiB pages"
assert_eq "4096 8192 16384" "$(calculate_tcp_mem 128 4096)" \
    "tcp memory budget keeps minimums"

assert_eq "default via 192.0.2.1 dev eth0 proto dhcp metric 100" \
    "$(strip_route_window_fields 'default via 192.0.2.1 dev eth0 proto dhcp metric 100 initcwnd 32 initrwnd 32')" \
    "strip route window fields without losing route attributes"

assert_eq "正常：测速期间 softnet 和网卡无新增丢包或错误" \
    "$(classify_network_health 0 0 0 0 1000000)" \
    "classify clean health snapshot"
assert_eq "正常：测速期间仅有轻微网卡丢包波动 +1（1 ppm），无 softnet 丢包或网卡错误" \
    "$(classify_network_health 0 0 0 1 1000000)" \
    "classify isolated NIC drop as normal fluctuation"
assert_eq "注意：测速期间 softnet budget pressure +105，网卡丢包 +0（0 ppm），无新增 softnet 丢包或网卡错误" \
    "$(classify_network_health 0 105 0 0 1000000)" \
    "classify softnet budget pressure as notice"
assert_eq "注意：测速期间 softnet budget pressure +0，网卡丢包 +1983（39 ppm），无新增 softnet 丢包或网卡错误" \
    "$(classify_network_health 0 0 0 1983 50000000)" \
    "classify low-ratio NIC drops during high-volume test as notice"
assert_eq "注意：测速期间 softnet budget pressure +0，网卡丢包 +2000（0 ppm），无新增 softnet 丢包或网卡错误" \
    "$(classify_network_health 0 0 0 2000 0)" \
    "classify NIC drops without packet denominator as notice"
assert_eq "异常：测速期间 softnet 丢包 +1，网卡丢包 +0（0 ppm），网卡错误 +0" \
    "$(classify_network_health 1 0 0 0 1000000)" \
    "classify softnet drops as abnormal"
assert_eq "异常：测速期间 softnet 丢包 +0，网卡丢包 +2000（2000 ppm），网卡错误 +0" \
    "$(classify_network_health 0 0 0 2000 1000000)" \
    "classify material NIC drop ratio as abnormal"
assert_eq "异常：测速期间 softnet 丢包 +0，网卡丢包 +0（0 ppm），网卡错误 +1" \
    "$(classify_network_health 0 0 1 0 1000000)" \
    "classify NIC errors as abnormal"

CURRENT_ROUTE="default via 192.0.2.1 dev eth0 proto dhcp src 192.0.2.10 metric 100 onlink"
LAST_ROUTE_ARGS=""
IP_FAIL=false

default_ipv4_route() { printf '%s\n' "$CURRENT_ROUTE"; }
ip() {
    [[ "$1 $2 $3" == "-4 route replace" ]] || return 1
    shift 3
    LAST_ROUTE_ARGS="$*"
    [[ "$IP_FAIL" == "false" ]] || return 1
    CURRENT_ROUTE="$*"
}

mkdir -p "$NETWORK_OPTIMIZE_STATE_DIR"
backup_default_route
apply_initcwnd >/dev/null
assert_eq "default via 192.0.2.1 dev eth0 proto dhcp src 192.0.2.10 metric 100 onlink initcwnd 32 initrwnd 32" \
    "$LAST_ROUTE_ARGS" "apply initcwnd while preserving route attributes"
[[ -e "$ROUTE_OWNED_MARKER" ]] || fail "apply initcwnd records ownership"
printf 'PASS: apply initcwnd records ownership\n'

backup_default_route
[[ -e "$ROUTE_PREVIOUS_OWNED" ]] || fail "rerun records previous route ownership"
printf 'PASS: rerun records previous route ownership\n'
INITCWND_ENABLED=false
apply_initcwnd >/dev/null
assert_eq "default via 192.0.2.1 dev eth0 proto dhcp src 192.0.2.10 metric 100 onlink" \
    "$CURRENT_ROUTE" "disable initcwnd removes owned route windows"
[[ ! -e "$ROUTE_OWNED_MARKER" ]] || fail "disable initcwnd clears ownership"
printf 'PASS: disable initcwnd clears ownership\n'

CURRENT_ROUTE="default via 198.51.100.1 dev eth1 proto dhcp metric 200"
restore_default_route "$ROUTE_PREVIOUS_BACKUP" "$ROUTE_PREVIOUS_OWNED"
assert_eq "default via 192.0.2.1 dev eth0 proto dhcp src 192.0.2.10 metric 100 onlink initcwnd 32 initrwnd 32" \
    "$CURRENT_ROUTE" "restore previous route snapshot"
[[ -e "$ROUTE_OWNED_MARKER" ]] || fail "restore previous owned route restores ownership"
printf 'PASS: restore previous owned route restores ownership\n'

CURRENT_ROUTE="default via 203.0.113.1 dev eth2 initcwnd 32 initrwnd 32 metric 300"
rm -f "$TEMP_DIR/missing-route"
restore_default_route "$TEMP_DIR/missing-route"
assert_eq "default via 203.0.113.1 dev eth2 metric 300" "$CURRENT_ROUTE" \
    "missing backup strips owned route windows from current route"

CURRENT_ROUTE="default via 192.0.2.1 dev eth0 proto dhcp metric 100"
INITCWND_ENABLED=true
IP_FAIL=true
if apply_initcwnd >/dev/null 2>&1; then
    fail "failed route replacement unexpectedly succeeded"
fi
IP_FAIL=false
assert_eq "default via 192.0.2.1 dev eth0 proto dhcp metric 100" "$CURRENT_ROUTE" \
    "failed initcwnd application leaves route unchanged"
[[ ! -e "$ROUTE_OWNED_MARKER" ]] || fail "failed initcwnd application does not claim ownership"
printf 'PASS: failed initcwnd application does not claim ownership\n'

printf 'All network-optimize tests passed.\n'
