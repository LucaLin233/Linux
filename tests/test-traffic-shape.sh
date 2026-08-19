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

assert_eq "128" "$(calc_fq_limit 1)" "fq limit keeps low-rate floor"
assert_eq "800" "$(calc_fq_limit 100)" "fq limit scales with shaping rate"
assert_eq "4000" "$(calc_fq_limit 500)" "fq limit preserves target backlog"
assert_eq "10000" "$(calc_fq_limit 1250)" "fq limit reaches kernel default ceiling"
assert_eq "10000" "$(calc_fq_limit 100000)" "fq limit keeps high-rate ceiling"

# verify_qdisc_rate 优先读取新版 tc JSON，并兼容 Debian 12 的文本输出。
TC_CLASS_OUTPUT='[{"class":"htb","handle":"1:10","rate":1000000000}]'
tc() {
    [[ "$*" == "-j class show dev test0" ]] || return 1
    printf '%s\n' "$TC_CLASS_OUTPUT"
}
assert_ok "verify exact shaping rate from JSON" verify_qdisc_rate test0 1000
assert_fail "reject mismatched shaping rate from JSON" verify_qdisc_rate test0 999
TC_CLASS_OUTPUT='class htb 1:10 root rate 12345Mbit ceil 12345Mbit burst 32Kb cburst 32Kb'
assert_ok "verify legacy Debian 12 tc class output" verify_qdisc_rate test0 12345
assert_fail "reject mismatched legacy tc class output" verify_qdisc_rate test0 12000
unset -f tc
unset TC_CLASS_OUTPUT

TC_APPLY_LOG=$(mktemp)
qdisc_remove_root() { return 1; }
tc() { printf '%s\n' "$*" >> "$TC_APPLY_LOG"; }
assert_ok "apply shaping when handle-zero root cannot be deleted" apply_qdisc eth0 1117
grep -Fqx "qdisc replace dev eth0 root handle 1: htb default 10" "$TC_APPLY_LOG" ||
    fail "HTB root was not applied with replace"
grep -Fq "class replace dev eth0 parent 1: classid 1:10 htb" "$TC_APPLY_LOG" ||
    fail "HTB class was not applied with replace"
grep -Fqx "qdisc replace dev eth0 parent 1:10 handle 10: fq limit 8936" "$TC_APPLY_LOG" ||
    fail "fq leaf did not use the rate-scaled limit"
if grep -Eq 'flow_limit|maxrate' "$TC_APPLY_LOG"; then
    fail "fq leaf still overrides flow_limit or maxrate"
fi
printf 'PASS: shaping restore tolerates non-deletable or auto-recreated root qdisc\n'
printf 'PASS: fq leaf uses only the rate-scaled queue limit\n'
unset -f tc
# 恢复脚本原始函数，供后续 mq 删除测试使用。
eval "$(sed -n '/^qdisc_remove_root() {/,/^}/p' "$ROOT_DIR/tools/traffic-shape.sh")"

assert_eq "1" "$(calc_margin 15)" "margin for 15 Mbit"
assert_eq "2" "$(calc_margin 45)" "margin for 45 Mbit"
assert_eq "5" "$(calc_margin 80)" "margin for 80 Mbit"
assert_eq "6" "$(calc_validation_rate 15)" "validation rate for 15 Mbit"
assert_eq "1" "$(calc_auto_step 17 31)" "auto step for narrow range"
assert_eq "20" "$(calc_auto_step 100 300)" "auto step for wide range"
assert_eq "32768" "$(calc_burst 20)" "burst keeps 32 KiB floor"
assert_eq "1000000" "$(calc_burst 2000)" "burst follows four milliseconds at line rate"
SCAN_CAP=10000
assert_eq "1000000000" "$(traffic_reserve_bytes)" "default scan cap keeps 1 GB reserve"
SCAN_CAP=100000
assert_eq "5000000000" "$(traffic_reserve_bytes)" "maximum scan cap keeps 5 GB reserve"
USED_TOTAL=0
USED_UPLOAD=0
traffic_used_bytes() {
    case "$1" in total) printf '%s\n' "$USED_TOTAL" ;; upload) printf '%s\n' "$USED_UPLOAD" ;; *) return 1 ;; esac
}
SCAN_CAP=10000
USED_TOTAL=88999999999
USED_UPLOAD=43999999999
assert_fail "traffic budget stays open below reserved threshold" traffic_budget_reached
USED_UPLOAD=44000000000
assert_ok "traffic budget stops at reserved direction threshold" traffic_budget_reached
eval "$(sed -n '/^traffic_used_bytes() {/,/^}/p' "$ROOT_DIR/tools/traffic-shape.sh")"
SCAN_CAP=""

tc() {
    cat <<'EOF'
qdisc mq 0: root
qdisc fq 0: parent :1 limit 10000p flow_limit 100p buckets 1024 orphan_mask 1023
qdisc fq 0: parent :2 limit 10000p flow_limit 100p buckets 1024 orphan_mask 1023
EOF
}
assert_eq "fq" "$(mq_leaf_kind eth0)" "detect mq handle-zero leaf qdisc"
assert_ok "verify every mq leaf uses fq" mq_leaves_are_kind eth0 fq
tc() {
    cat <<'EOF'
qdisc mq 1: root
qdisc fq 0: parent 1:1
qdisc fq_codel 0: parent 1:2
EOF
}
assert_fail "reject mixed mq leaf qdiscs" mq_leaves_are_kind eth0 fq
assert_fail "reject mixed mq restore profile" mq_restore_leaf_kind eth0
unset -f tc

default_leaf_options='{"limit":10000,"flow_limit":100}'
default_mq_json='[{"kind":"fq","parent":"1:1","options":{"limit":10000,"flow_limit":100}},{"kind":"fq","parent":"1:2","options":{"limit":10000,"flow_limit":100}}]'
custom_mq_json='[{"kind":"fq","parent":"1:1","options":{"limit":20000,"flow_limit":100}},{"kind":"fq","parent":"1:2","options":{"limit":10000,"flow_limit":100}}]'
assert_ok "accept default mq leaf options" mq_leaf_options_are_default \
    "$default_mq_json" 1 fq "$default_leaf_options"
assert_fail "reject custom mq leaf options" mq_leaf_options_are_default \
    "$custom_mq_json" 1 fq "$default_leaf_options"

QDISC_ERROR_LOG=$(mktemp)
tc() {
    case "$*" in
        "qdisc show dev eth0") printf '%s\n' 'qdisc fq 0: root' ;;
        "-j qdisc show dev eth0") return 1 ;;
        *) return 0 ;;
    esac
}
systemctl() { return 1; }
is_own_shaper() { return 1; }
if check_external_conflicts eth0 2> "$QDISC_ERROR_LOG"; then
    fail "qdisc parameter read failure unexpectedly allowed overwrite"
fi
assert_eq "1" "$(grep -Fc '无法读取 eth0 的 qdisc 参数，拒绝覆盖' "$QDISC_ERROR_LOG" || true)" \
    "report qdisc parameter read failure once"
if grep -Fq '包含自定义参数' "$QDISC_ERROR_LOG"; then
    fail "qdisc parameter read failure also reported custom parameters"
fi
printf 'PASS: distinguish qdisc read failure from custom parameters\n'
unset -f tc systemctl is_own_shaper

tc() { return 1; }
systemctl() { return 1; }
is_own_shaper() { return 1; }
assert_fail "reject unreadable root qdisc" check_external_conflicts eth0
assert_fail "reject unreadable Sweep qdisc snapshot" qdisc_save eth0
unset -f tc systemctl is_own_shaper

MQ_ROOT="mq"
MQ_HANDLE="0:"
MQ_LEAF_KIND="fq_codel"
MQ_CALL_LOG=$(mktemp)
root_qdisc_kind() { printf '%s\n' "$MQ_ROOT"; }
tc() {
    printf '%s\n' "$*" >> "$MQ_CALL_LOG"
    case "$*" in
        "qdisc show dev eth0")
            printf 'qdisc mq %s root\n' "$MQ_HANDLE"
            printf 'qdisc %s 0: parent %s1\n' "$MQ_LEAF_KIND" "${MQ_HANDLE%:}:"
            printf 'qdisc %s 0: parent %s2\n' "$MQ_LEAF_KIND" "${MQ_HANDLE%:}:"
            ;;
        "qdisc del dev eth0 root")
            [[ "$MQ_HANDLE" != "0:" ]] || return 2
            MQ_ROOT=""
            return 0
            ;;
        "qdisc replace dev eth0 root handle 1: mq") MQ_ROOT="mq"; MQ_HANDLE="1:" ;;
        "qdisc replace dev eth0 root mq") MQ_ROOT="mq"; MQ_HANDLE="1:" ;;
        "qdisc replace dev eth0 root fq") MQ_ROOT="fq"; MQ_HANDLE="1:" ;;
        "qdisc replace dev eth0 parent 1:1 fq_codel"|\
        "qdisc replace dev eth0 parent 1:2 fq_codel") return 0 ;;
        *) return 1 ;;
    esac
}
assert_ok "replace mq handle zero before safe root deletion" qdisc_remove_root eth0
grep -Fqx "qdisc replace dev eth0 root handle 1: mq" "$MQ_CALL_LOG" ||
    fail "safe mq deletion did not replace handle zero"
printf 'PASS: safe mq deletion replaces handle zero\n'
MQ_ROOT="mq"
MQ_HANDLE="1:"
: > "$MQ_CALL_LOG"
assert_ok "restore mq leaf qdisc kind" restore_simple_qdisc eth0 mq fq_codel
grep -Fqx "qdisc replace dev eth0 root mq" "$MQ_CALL_LOG" ||
    fail "mq root restore did not use replace"
grep -Fqx "qdisc replace dev eth0 parent 1:1 fq_codel" "$MQ_CALL_LOG" &&
    grep -Fqx "qdisc replace dev eth0 parent 1:2 fq_codel" "$MQ_CALL_LOG" ||
    fail "mq leaf restore did not replace every leaf"
printf 'PASS: mq root and leaf restore use replace\n'
MQ_ROOT="htb"
: > "$MQ_CALL_LOG"
assert_ok "restore simple fq qdisc" restore_simple_qdisc eth0 fq
grep -Fqx "qdisc replace dev eth0 root fq" "$MQ_CALL_LOG" ||
    fail "simple qdisc restore did not use replace"
printf 'PASS: simple qdisc restore uses replace\n'
unset -f tc root_qdisc_kind

if grep -Fq 'network-optimize' "$ROOT_DIR/tools/traffic-shape.sh"; then
    fail "traffic-shape code still references network-optimize"
fi
if grep -Eq '/var/lib/linux-setup|network-optimize[.]lock|network-optimize[.]bandwidth-cache' \
    "$ROOT_DIR/tools/traffic-shape.sh"; then
    fail "traffic-shape shares state, cache, or lock paths"
fi
grep -Fq 'tcshape 使用自身独立的流量上限' "$ROOT_DIR/docs/traffic-shape.md" ||
    fail "traffic-shape documentation still couples its budget"
printf 'PASS: traffic-shape keeps independent code, state, lock, and budget
'

assert_eq "1.0.13" "$(script_version "$ROOT_DIR/tools/traffic-shape.sh")" \
    "extract update version"
assert_ok "validate install source" validate_install_file \
    "$ROOT_DIR/tools/traffic-shape.sh"
assert_ok "validate managed update file" validate_update_file \
    "$ROOT_DIR/tools/traffic-shape.sh" "1.0.13"
grep -Fq '# Upstream version: v0.5.6' "$ROOT_DIR/tools/traffic-shape.sh" ||
    fail "traffic-shape upstream version is not pinned to v0.5.6"
grep -Fq '`v0.5.6`' "$ROOT_DIR/docs/traffic-shape.md" ||
    fail "traffic-shape documentation does not name v0.5.6 baseline"
printf 'PASS: tcpfit migration and algorithm baseline is v0.5.6\n'

temp_dir=$(mktemp -d)
trap 'rm -rf "$temp_dir"' EXIT
invalid_update="$temp_dir/invalid-update.sh"
sed 's#readonly UPDATE_REPO="LucaLin233/Linux"#readonly UPDATE_REPO="other/repo"#' \
    "$ROOT_DIR/tools/traffic-shape.sh" > "$invalid_update"
assert_fail "reject update from another repository" validate_update_file "$invalid_update" "1.0.13"

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
    TCSHAPE_OS_RELEASE_FILE="$1" check_supported_system >/dev/null 2>&1
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
probe_name="tcs${BASHPID}"
(( ${#probe_name} <= 15 )) || fail "temporary qdisc probe name exceeds IFNAMSIZ"
printf 'PASS: temporary qdisc probe name fits IFNAMSIZ\n'

fixture="$temp_dir/iperf.json"
cat > "$fixture" <<'JSON'
{
  "start": {
    "tcp_mss_default": 1380
  },
  "end": {
    "sum_sent": {
      "bits_per_second": 18300000,
      "retransmits": 12,
      "bytes": 18300000,
      "seconds": 8.0
    },
    "sum_received": {
      "bits_per_second": 14600000
    }
  }
}


JSON
parsed_iperf=$(parse_iperf_json "$fixture")
assert_eq "$(printf '18300000\t12\t14600000\t18300000\t1380')" \
    "$(cut -f1-5 <<< "$parsed_iperf")" \
    "parse sender, receiver, bytes and MSS"
assert_ok "parse iperf duration across jq number formats" \
    awk -F'\t' '$6 == 8 {found=1} END {exit !found}' <<< "$parsed_iperf"

assert_eq "0.1000" "$(retrans_pct 1 1448000 1448 8 0)" \
    "calculate retransmission rate for standard MSS"
assert_eq "0.1000" "$(retrans_pct 1 1380000 1380 8 0)" \
    "calculate retransmission rate for tunnel MSS"
assert_eq "0.1000" "$(retrans_pct 1 8948000 8948 8 0)" \
    "calculate retransmission rate for jumbo MSS"
assert_eq "0.1000" "$(retrans_pct 1 0 1448 1 11584000)" \
    "fallback to exact sender bps when bytes are unavailable"
assert_fail "threshold equality is not a spike" is_loss_spike 0.1 0.1 0
assert_ok "loss above fixed threshold is a spike" is_loss_spike 0.1001 0.1 0
assert_fail "adaptive baseline suppresses path noise" is_loss_spike 0.2 0.1 0.05
assert_ok "adaptive baseline accepts material spike" is_loss_spike 0.3 0.1 0.05
assert_fail "adaptive threshold is capped at one percent" is_loss_spike 1.0 0.1 0.5
assert_ok "loss above capped adaptive threshold is a spike" is_loss_spike 1.1 0.1 0.5

result_queue="$temp_dir/iperf-results"
printf '%s\n' \
    '37 0 5201 37 16280000 1448 3 37400000 37400000' \
    '36 2 5201 36 15600000 1448 3 37000000 37000000' > "$result_queue"
run_iperf() {
    local result
    result=$(sed -n '1p' "$result_queue")
    sed '1d' "$result_queue" > "$result_queue.next"
    mv -f "$result_queue.next" "$result_queue"
    printf '%s\n' "$result"
}
low_result='13 5000 5201 13 5600000 1448 3 13000000 13000000'
assert_eq '37 0 5201 37 16280000 1448 3 37400000 37400000' \
    "$(stabilize_unshaped_result peer.example 3 40 "$low_result")" \
    "retry low unshaped sample and keep the best complete result"
run_iperf() { return 75; }
if stabilize_unshaped_result peer.example 3 40 "$low_result" >/dev/null; then
    fail "traffic budget result was not propagated"
else
    assert_eq "75" "$?" "propagate traffic budget from low-sample retry"
fi
eval "$(sed -n '/^run_iperf() {/,/^}/p' "$ROOT_DIR/tools/traffic-shape.sh")"

STATUS_CALLED=false
require_root() { return 0; }
install_self() { fail "status invoked install_self"; }
ensure_dependencies() { fail "status invoked ensure_dependencies"; }
check_status_dependencies() { return 0; }
cmd_status() { STATUS_CALLED=true; }
main status
assert_eq "true" "$STATUS_CALLED" "status bypasses self-install and dependency installation"

printf 'All tcshape tests passed.\n'
