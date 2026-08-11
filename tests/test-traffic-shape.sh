#!/usr/bin/env bash
set -euo pipefail

readonly ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../tools/traffic-shape.sh
source "$ROOT_DIR/tools/traffic-shape.sh"

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

assert_eq "1000" "$(tc_rate_mbit 'class htb 1:10 root rate 1Gbit ceil 1Gbit')" \
    "parse Gbit rate"
assert_eq "2500" "$(tc_rate_mbit 'class htb 1:10 root rate 2500Mbit ceil 2500Mbit')" \
    "parse Mbit rate"
assert_eq "1000" "$(tc_rate_mbit 'class htb 1:10 root rate 1000000Kbit ceil 1000000Kbit')" \
    "parse Kbit rate"

# verify_qdisc_rate 通过 tc 函数读取模拟输出，不修改实际 qdisc。
tc() {
    printf '%s\n' 'class htb 1:10 root rate 1Gbit ceil 1Gbit burst 32Kb cburst 32Kb'
}
assert_ok "verify integer-Gbit shaping rate" verify_qdisc_rate test0 1000
unset -f tc

assert_eq "1" "$(calc_margin 15)" "margin for 15 Mbit"
assert_eq "2" "$(calc_margin 45)" "margin for 45 Mbit"
assert_eq "5" "$(calc_margin 80)" "margin for 80 Mbit"
assert_eq "6" "$(calc_validation_rate 15)" "validation rate for 15 Mbit"
assert_eq "1" "$(calc_auto_step 17 31)" "auto step for narrow range"
assert_eq "20" "$(calc_auto_step 100 300)" "auto step for wide range"

assert_eq "1.0.4" "$(script_version "$ROOT_DIR/tools/traffic-shape.sh")" \
    "extract update version"
assert_ok "validate managed update file" validate_update_file \
    "$ROOT_DIR/tools/traffic-shape.sh" "1.0.4"

temp_dir=$(mktemp -d)
trap 'rm -rf "$temp_dir"' EXIT
invalid_update="$temp_dir/invalid-update.sh"
sed 's#readonly UPDATE_REPO="LucaLin233/Linux"#readonly UPDATE_REPO="other/repo"#' \
    "$ROOT_DIR/tools/traffic-shape.sh" > "$invalid_update"
assert_fail "reject update from another repository" validate_update_file "$invalid_update" "1.0.4"

fixture="$temp_dir/iperf.json"
cat > "$fixture" <<'JSON'
{
  "end": {
    "sum_sent": {
      "bits_per_second": 18300000,
      "retransmits": 12
    },
    "sum_received": {
      "bits_per_second": 14600000
    }
  }
}
JSON
assert_eq $'18300000\t12\t14600000' "$(parse_iperf_json "$fixture")" \
    "parse sender and receiver throughput"

printf 'All tcshape tests passed.\n'
