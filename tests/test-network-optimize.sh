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
assert_eq "4194304" "$(calculate_buffer_default 100 150 8388608 512)" \
    "low-memory buffer default stays at 4 MiB"
assert_eq "4194304" "$(calculate_buffer_default 300 150 16777216 2048)" \
    "buffer default keeps 4 MiB floor"
assert_eq "8388608" "$(calculate_buffer_default 1000 150 37748736 2048)" \
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

printf 'All network-optimize tests passed.\n'
