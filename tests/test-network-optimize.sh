#!/usr/bin/env bash
set -euo pipefail

readonly ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
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
assert_eq "37748736" "$(calculate_buffer_max 1000 150 268435456)" \
    "buffer max rounds 2x BDP to MiB"
assert_eq "2097152" "$(calculate_buffer_default 100 150 8388608)" \
    "buffer default keeps 2 MiB floor"
assert_eq "3145728" "$(calculate_buffer_default 300 150 16777216)" \
    "buffer default rounds half BDP"
assert_eq "4194304" "$(calculate_buffer_default 1000 150 37748736)" \
    "buffer default keeps 4 MiB ceiling"
assert_eq "16384 32768 65536" "$(calculate_tcp_mem 1024)" \
    "tcp memory budget follows RAM"
assert_eq "4096 8192 16384" "$(calculate_tcp_mem 128)" \
    "tcp memory budget keeps minimums"

printf 'All network-optimize tests passed.\n'
