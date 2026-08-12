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

assert_eq "1.0.8" "$(script_version "$ROOT_DIR/tools/traffic-shape.sh")" \
    "extract update version"
assert_ok "validate install source" validate_install_file \
    "$ROOT_DIR/tools/traffic-shape.sh"
assert_ok "validate managed update file" validate_update_file \
    "$ROOT_DIR/tools/traffic-shape.sh" "1.0.8"

temp_dir=$(mktemp -d)
trap 'rm -rf "$temp_dir"' EXIT
invalid_update="$temp_dir/invalid-update.sh"
sed 's#readonly UPDATE_REPO="LucaLin233/Linux"#readonly UPDATE_REPO="other/repo"#' \
    "$ROOT_DIR/tools/traffic-shape.sh" > "$invalid_update"
assert_fail "reject update from another repository" validate_update_file "$invalid_update" "1.0.8"

empty_install="$temp_dir/empty-tcshape"
unknown_install="$temp_dir/unknown-tcshape"
managed_install="$temp_dir/managed-tcshape"
empty_link="$temp_dir/empty-link"
: > "$empty_install"
printf '#!/usr/bin/env bash\necho unknown\n' > "$unknown_install"
cp "$ROOT_DIR/tools/traffic-shape.sh" "$managed_install"
ln -s "$empty_install" "$empty_link"
assert_fail "reject empty install source" validate_install_file "$empty_install"
assert_ok "allow replacing zero-byte legacy target" install_target_is_replaceable "$empty_install"
assert_ok "allow replacing managed target" install_target_is_replaceable "$managed_install"
assert_fail "reject unknown nonempty target" install_target_is_replaceable "$unknown_install"
assert_fail "reject symlink target" install_target_is_replaceable "$empty_link"

check_os_file() {
    check_supported_system "$1" >/dev/null 2>&1
}

cat > "$temp_dir/debian12" <<'EOF'
ID=debian
VERSION_ID="12"
EOF
cat > "$temp_dir/debian13" <<'EOF'
ID=debian
VERSION_ID="13"
EOF
cat > "$temp_dir/debian11" <<'EOF'
ID=debian
VERSION_ID="11"
EOF
cat > "$temp_dir/ubuntu2204" <<'EOF'
ID=ubuntu
VERSION_ID="22.04"
EOF
cat > "$temp_dir/ubuntu2404" <<'EOF'
ID=ubuntu
VERSION_ID="24.04"
EOF
cat > "$temp_dir/ubuntu2004" <<'EOF'
ID=ubuntu
VERSION_ID="20.04"
EOF
cat > "$temp_dir/alpine" <<'EOF'
ID=alpine
VERSION_ID="3.20"
EOF
assert_ok "accept Debian 12" check_os_file "$temp_dir/debian12"
assert_ok "accept Debian 13" check_os_file "$temp_dir/debian13"
assert_fail "reject Debian 11" check_os_file "$temp_dir/debian11"
assert_ok "accept Ubuntu 22.04" check_os_file "$temp_dir/ubuntu2204"
assert_ok "accept Ubuntu 24.04" check_os_file "$temp_dir/ubuntu2404"
assert_fail "reject Ubuntu 20.04" check_os_file "$temp_dir/ubuntu2004"
assert_fail "reject unsupported distribution" check_os_file "$temp_dir/alpine"

assert_eq "3600" "$(sweep_result_age 1000 4600)" "calculate Sweep result age"
assert_eq "1小时1分钟" "$(format_age 3660)" "format Sweep result age"
assert_fail "reject future Sweep timestamp" sweep_result_age 5000 1000
assert_ok "accept Sweep result at 24-hour boundary" sweep_result_is_fresh 86400
assert_fail "reject Sweep result older than 24 hours" sweep_result_is_fresh 86401
assert_ok "accept minimum loss threshold" is_loss_threshold 0.0001
assert_ok "accept decimal loss threshold" is_loss_threshold 0.25
assert_fail "reject zero loss threshold" is_loss_threshold 0
assert_fail "reject excessive loss threshold" is_loss_threshold 10.1
assert_fail "reject malformed loss threshold" is_loss_threshold 0.1x
assert_ok "accept minimum scan cap" validate_scan_cap 100
assert_ok "accept maximum scan cap" validate_scan_cap 100000
assert_fail "reject low scan cap" validate_scan_cap 99
assert_fail "reject excessive scan cap" validate_scan_cap 100001

fq_json='[{"kind":"fq","root":true,"options":{"priomap ":[1,2],"weights ":[3,2,1],"limit":10000}}]'
assert_eq '{"priomap":[1,2],"weights":[3,2,1],"limit":10000}' \
    "$(normalize_qdisc_options "$fq_json" fq)" \
    "normalize qdisc option keys with trailing spaces"

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
