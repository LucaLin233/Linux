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
export NETWORK_OPTIMIZE_LOG="$TEMP_DIR/network-optimize.log"

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
getconf() {
    case "$1" in
        PAGESIZE) printf '%s\n' 4096 ;;
        _NPROCESSORS_ONLN) printf '%s\n' 4 ;;
        *) return 1 ;;
    esac
}

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
    FORCE_REFRESH=false
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
    MEASUREMENT_CACHE_PENDING=false
    TCP_MEM_PAGES=""
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
probe_guidance=$(show_active_probe_warning)
expected_probe_guidance=$(printf '%s\n' \
    '测速配置：IPv4 iperf3，最多 2 个节点，每方向 4 并发 × 5 秒' \
    '流量上限：上传 12.5 GB / 下载 12.5 GB / 合计 25 GB（按出口接口统计，包含同期后台流量）' \
    '依赖处理：缺少 iperf3 时通过 APT 自动安装')
assert_eq "$expected_probe_guidance" "$probe_guidance" \
    "interactive speed-test guidance uses three plain lines"
select_tuning_body=$(declare -f select_tuning_mode)
grep -Fq 'read -r -p "是否执行公共测速？[Y/n]: " answer' \
    <<< "$select_tuning_body" || fail "interactive speed-test prompt is not concise"
printf 'PASS: interactive speed-test prompt uses concise wording\n'

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

for refresh_args in '--auto --refresh' '--refresh --auto'; do
    reset_selection
    read -r -a parsed_refresh_args <<< "$refresh_args"
    parse_arguments install "${parsed_refresh_args[@]}"
    assert_eq true "$FORCE_REFRESH" "refresh is accepted regardless of argument order"
    assert_eq auto "$TUNING_MODE" "refresh keeps automatic mode"
done
reset_selection
assert_fail "reject --refresh without --auto" parse_arguments install --refresh
reset_selection
assert_fail "reject --refresh before manual bandwidth" \
    parse_arguments install --refresh --bandwidth-mbps 1000
reset_selection
assert_fail "reject manual bandwidth before --refresh" \
    parse_arguments install --bandwidth-mbps 1000 --refresh
reset_selection
assert_fail "reject --refresh on status" parse_arguments status --refresh --auto

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
if grep -Fq '执行模块：${MODULES[$module]}' <<< "$execute_module_body"; then
    fail "execute_module still repeats the user-visible module name"
fi
execution_loop=$(sed -n '/for module in "${SELECTED_MODULES\[@\]}"; do/,/generate_summary/p' \
    "$ROOT_DIR/linux_setup.sh")
assert_eq 1 "$(grep -Fc '${MODULES[$module]}' <<< "$execution_loop")" \
    "selected module name appears once in the execution loop"
grep -Fq 'echo "[$current/$total] ${MODULES[$module]}"' <<< "$execution_loop" ||
    fail "module progress line no longer matches the concise format"
printf 'PASS: linux_setup keeps generic no-argument module invocation\n'

assert_eq 高 "$(format_display_value high)" "format high confidence"
assert_eq 低 "$(format_display_value low)" "format low confidence"
assert_eq 手动输入 "$(format_display_value manual)" "format manual confidence"
assert_eq 未知 "$(format_display_value unknown)" "format unknown value"
assert_eq 无 "$(format_display_value none)" "format none value"
assert_eq '公共 IPv4 iperf3 测速（4 并发 × 5 秒）' \
    "$(format_measurement_source 'public iperf3 IPv4 (P=4, t=5s)')" \
    "format live measurement source"
assert_eq 自动策略 "$(format_rtt_source 'automatic policy')" \
    "format automatic RTT source"
assert_eq 命令行指定 "$(format_rtt_source 'command line')" \
    "format command-line RTT source"
assert_eq '固定 150 ms' "$(format_rtt_policy 'fixed 150 ms')" \
    "format fixed RTT policy"
assert_eq 手动指定 "$(format_rtt_policy 'manual override')" \
    "format manual RTT policy"
assert_eq '自动：上传 > 100 Mbps，设置为 32' \
    "$(format_initcwnd_policy 'auto: upload > 100 Mbps, set 32')" \
    "format enabled automatic initcwnd policy"
assert_eq '自动：上传 ≤ 100 Mbps，保持内核默认' \
    "$(format_initcwnd_policy 'auto: upload <= 100 Mbps, preserve kernel default')" \
    "format disabled automatic initcwnd policy"
assert_eq 手动启用 "$(format_initcwnd_policy 'explicit enabled')" \
    "format explicit initcwnd enablement"
assert_eq 手动禁用 "$(format_initcwnd_policy 'explicit disabled')" \
    "format explicit initcwnd disablement"
assert_eq '存在所有权标记，但默认路由缺少 initcwnd/initrwnd=32' \
    "$(format_initcwnd_state_detail 'ownership marker exists but default route lacks initcwnd/initrwnd 32')" \
    "format ownership drift state"
assert_eq '内核默认，无所有权标记' \
    "$(format_initcwnd_state_detail 'kernel default; no ownership marker')" \
    "format default ownership state"
assert_eq 1 "$(grep -Fc '警告：未检测到 networkd-dispatcher；initcwnd=32 仅对当前默认路由生效' \
    "$ROOT_DIR/modules/network-optimize.sh")" \
    "missing networkd-dispatcher warning has one output path"
for redundant_success in \
    'BBR 支持：可用' \
    '运行时 sysctl 已与生成配置一致' \
    '默认路由已设置 initcwnd/initrwnd' \
    '网络优化配置已写入' \
    'BBR 模块已设置为开机加载'; do
    if grep -Fq "$redundant_success" "$ROOT_DIR/modules/network-optimize.sh"; then
        fail "normal path retains redundant success output: $redundant_success"
    fi
done
printf 'PASS: normal install path keeps success state in one final summary\n'

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
    detect_memory_mb() { printf '%s\n' 1024; }
    detect_cgroup_memory_limit_mb() { printf '%s\n' 512; }
    current_epoch() { printf '%s\n' 2000000000; }
    format_measurement_epoch() { printf '%s\n' '2033-05-18T03:33:20Z'; }
    TUNING_MODE=manual
    MANUAL_DOWNLOAD_MBPS=1000
    MANUAL_UPLOAD_MBPS=500
    MANUAL_RTT_MS=180
    resolve_tuning_values >/dev/null
    assert_eq 512 "$RAM_MB" \
        "tuning uses cgroup-limited effective RAM"
    assert_eq '8192 16384 32768' "$TCP_MEM_PAGES" \
        "tcp_mem uses effective RAM instead of physical RAM"
)


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
        net.ipv4.tcp_adv_win_scale \
        net.core.netdev_budget \
        net.core.netdev_budget_usecs \
        net.ipv4.ip_local_port_range \
        net.ipv4.tcp_no_metrics_save \
        net.ipv4.tcp_tw_reuse \
        vm.min_free_kbytes \
        fs.file-max \
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
    assert_eq 2097152 \
        "$(read_config_value "$generated_config" net.core.rmem_default)" \
        "generated config fixes core receive default at 2 MiB"
    assert_eq 2097152 \
        "$(read_config_value "$generated_config" net.core.wmem_default)" \
        "generated config fixes core send default at 2 MiB"
    assert_eq '4096 2097152 47185920' \
        "$(read_config_value "$generated_config" net.ipv4.tcp_rmem)" \
        "generated config keeps receive buffer calculation"
    assert_eq '4096 2097152 25165824' \
        "$(read_config_value "$generated_config" net.ipv4.tcp_wmem)" \
        "generated config keeps send buffer calculation"
    assert_eq '131072 262144 524288' \
        "$(read_config_value "$generated_config" net.ipv4.tcp_mem)" \
        "generated config writes effective-RAM tcp_mem pages"

    plan_output=$(show_tuning_plan)
    grep -Fq 'TCP 缓冲：默认 2.0 MiB / 接收上限 45.0 MiB / 发送上限 24.0 MiB' \
        <<< "$plan_output" || fail "plan collapses asymmetric buffer limits"
    grep -Fq 'TCP 内存：131072 / 262144 / 524288 页（512.0 MiB / 1024.0 MiB / 2048.0 MiB）' \
        <<< "$plan_output" || fail "plan omits combined TCP memory summary"
    sysctl() {
        [[ "$1" == "-n" && "$2" == "net.ipv4.tcp_congestion_control" ]] || return 1
        printf '%s\n' cubic
    }
    active_qdisc_state() { printf '%s\n' 'effective|root fq'; }
    install_summary=$(show_install_summary false)
    grep -Fq 'TCP 缓冲：默认 2.0 MiB / 接收上限 45.0 MiB / 发送上限 24.0 MiB' \
        <<< "$install_summary" || fail "install summary collapses asymmetric buffer limits"
    grep -Fq '拥塞控制：cubic' <<< "$install_summary" ||
        fail "non-BBR summary omits active congestion control"
    sysctl() { return 1; }
    unknown_cc_summary=$(show_install_summary false)
    grep -Fq '拥塞控制：未知' <<< "$unknown_cc_summary" ||
        fail "non-BBR summary does not handle congestion-control read failure"
    grep -Fq 'TCP 内存：131072 / 262144 / 524288 页（512.0 MiB / 1024.0 MiB / 2048.0 MiB）' \
        <<< "$install_summary" || fail "install summary omits combined TCP memory summary"
    for manual_output in "$plan_output" "$install_summary"; do
        grep -Fq '  节点：' <<< "$manual_output" ||
            fail "manual output omits node label"
        grep -Fq '    无（手动输入）' <<< "$manual_output" ||
            fail "manual input is not shown as no measurement node"
        if grep -Fq '1. 手动输入' <<< "$manual_output"; then
            fail "manual input is still shown as a numbered measurement node"
        fi
    done
    assert_eq 1 "$(grep -Fc 'TCP 内存：' <<< "$install_summary")" \
        "install summary reports TCP memory once"
    printf 'PASS: plan and install summary preserve directional limits and manual-node semantics\n'

    (
        sysctl() {
            [[ "$1" == "-n" ]] || return 1
            case "$2" in
                net.core.rmem_default) printf '%s\n' 1048576 ;;
                net.core.wmem_default) printf '%s\n' 1572864 ;;
                net.ipv4.tcp_mem) printf '%s\n' '11111 22222 44444' ;;
                *) printf '%s\n' 0 ;;
            esac
        }
        runtime_snapshot="$TEMP_DIR/generated-runtime.snapshot"
        capture_runtime_values_from_files "$runtime_snapshot" \
            "$generated_config" "$generated_config"
        assert_eq 1 "$(grep -Fc 'net.core.rmem_default=' "$runtime_snapshot")" \
            "runtime snapshot captures rmem_default once"
        assert_eq 1 "$(grep -Fc 'net.core.wmem_default=' "$runtime_snapshot")" \
            "runtime snapshot captures wmem_default once"
        assert_eq 1 "$(grep -Fc 'net.ipv4.tcp_mem=' "$runtime_snapshot")" \
            "runtime snapshot captures tcp_mem once"
        grep -Fqx 'net.core.rmem_default=1048576' "$runtime_snapshot" ||
            fail "runtime snapshot lost old rmem_default"
        grep -Fqx 'net.core.wmem_default=1572864' "$runtime_snapshot" ||
            fail "runtime snapshot lost old wmem_default"
        grep -Fqx 'net.ipv4.tcp_mem=11111 22222 44444' "$runtime_snapshot" ||
            fail "runtime snapshot lost old tcp_mem"
        mkdir -p "$NETWORK_OPTIMIZE_STATE_DIR"
        rm -f "$RUNTIME_INITIAL_UNKNOWN"
        printf '%s\n' 'net.core.rmem_max=8388608' > "$RUNTIME_INITIAL_BACKUP"
        merge_initial_runtime_values "$runtime_snapshot"
        merge_initial_runtime_values "$runtime_snapshot"
        assert_eq 1 "$(grep -Fc 'net.core.rmem_default=' \
            "$RUNTIME_INITIAL_BACKUP")" \
            "initial runtime merge adds rmem_default once"
        assert_eq 1 "$(grep -Fc 'net.core.wmem_default=' \
            "$RUNTIME_INITIAL_BACKUP")" \
            "initial runtime merge adds wmem_default once"
        assert_eq 1 "$(grep -Fc 'net.ipv4.tcp_mem=' "$RUNTIME_INITIAL_BACKUP")" \
            "initial runtime merge adds tcp_mem once"
    )

    mkdir -p "$(dirname "$NETWORK_CONF")"
    cp "$generated_config" "$NETWORK_CONF"
    detect_default_iface() { return 1; }
    default_ipv4_route() { printf '\n'; }
    sysctl() {
        [[ "$1" == "-n" ]] || return 1
        case "$2" in
            net.core.rmem_default) printf '%s\n' 2097152 ;;
            net.core.wmem_default) printf '%s\n' 2097152 ;;
            net.ipv4.tcp_mem) printf '%s\n' '131072 262144 524288' ;;
            *) return 1 ;;
        esac
    }
    tc() { return 1; }
    status_output=$(show_status)
    grep -Fq '来源：命令行手动输入' <<< "$status_output" ||
        fail "status omits formatted measurement source"
    grep -Fq '时间：2033-05-18T03:33:20Z' <<< "$status_output" ||
        fail "status omits measurement time"
    grep -Fq '无（手动输入）' <<< "$status_output" ||
        fail "status omits manual no-node display"
    if grep -Fq '1. 手动输入' <<< "$status_output"; then
        fail "status numbers manual input as a measurement node"
    fi
    grep -Fq '可信度：手动输入' <<< "$status_output" ||
        fail "status omits formatted confidence"
    grep -Fq '警告：无' <<< "$status_output" ||
        fail "status omits formatted empty warnings"
    grep -Fq 'rmem_default：2097152' <<< "$status_output" ||
        fail "status omits rmem_default"
    grep -Fq 'wmem_default：2097152' <<< "$status_output" ||
        fail "status omits wmem_default"
    grep -Fq 'tcp_mem：131072 262144 524288' <<< "$status_output" ||
        fail "status omits tcp_mem"
    printf 'PASS: status reports persisted measurement metadata through display formatters\n'
)

(
    reset_selection
    TUNING_MODE=auto
    PHYSICAL_RAM_MB=6144
    RAM_MB=5222
    MEMORY_CAP_BYTES=169659596
    DETECTED_DOWNLOAD_MBPS=9400
    DETECTED_UPLOAD_MBPS=9000
    MEASUREMENT_SOURCE='7-day route-bound cache (public iperf3 IPv4 (P=4, t=5s))'
    MEASUREMENT_TIME='2026-08-19T20:12:00Z'
    MEASUREMENT_NODES='新加坡/OVH sgp.proof.ovh.net [15.235.182.181]:5201 (IPv4 RTT 1 ms);新加坡/Leaseweb speedtest.sin1.sg.leaseweb.net [23.108.99.54]:5201 (IPv4 RTT 1 ms)'
    MEASUREMENT_CONFIDENCE=low
    MEASUREMENT_WARNINGS='upload peer results differ by more than 30%, using the higher valid result; download peer results differ by more than 30%, using the higher valid result'
    DETECTED_RTT_MS=150
    RTT_SOURCE='automatic policy'
    RTT_POLICY='fixed 150 ms'
    RX_BDP_BYTES=176250000
    TX_BDP_BYTES=168750000
    RMEM_DEFAULT_BYTES=2097152
    WMEM_DEFAULT_BYTES=2097152
    RMEM_MAX_BYTES=169659596
    WMEM_MAX_BYTES=169659596
    TCP_MEM_PAGES='82816 165632 331264'
    CALCULATION_REASON='rmem: effective RAM / 32 cap; wmem: effective RAM / 32 cap'
    INITCWND_MODE=auto
    INITCWND_ENABLED=true
    INITCWND_POLICY='auto: upload > 100 Mbps, set 32'
    PROBE_IFACE=eth0

    active_qdisc_state() { printf '%s\n' 'effective|root mq; all 1 leaves fq'; }
    is_managed_initcwnd_hook() { return 1; }
    detect_default_iface() { printf '%s\n' eth0; }
    detect_initcwnd_state() { printf '%s\n' 'default|kernel default; no ownership marker'; }
    sysctl() {
        [[ "$1" == "-n" ]] || return 1
        case "$2" in
            net.ipv4.tcp_congestion_control) printf '%s\n' bbr ;;
            net.core.default_qdisc) printf '%s\n' fq ;;
            net.core.rmem_default|net.core.wmem_default) printf '%s\n' 2097152 ;;
            net.ipv4.tcp_mem) printf '%s\n' '82816 165632 331264' ;;
            *) printf '%s\n' 0 ;;
        esac
    }

    mkdir -p "$(dirname "$NETWORK_CONF")"
    create_network_config "$NETWORK_CONF" true
    plan_output=$(show_tuning_plan)
    install_output=$(show_install_summary true)
    status_output=$(show_status)
    grep -Fq 'RTT：150 ms（自动固定值）' <<< "$status_output" ||
        fail "status omits single RTT label"
    if grep -Fq 'RTT：RTT：' <<< "$status_output"; then
        fail "status repeats the RTT label"
    fi
    grep -Fq '内核默认，无所有权标记' <<< "$status_output" ||
        fail "status omits localized ownership state"
    if grep -Fq 'ownership 标记' <<< "$status_output"; then
        fail "status leaks the old ownership wording"
    fi
    for display_output in "$plan_output" "$install_output" "$status_output"; do
        grep -Fq '7 天内同路由缓存（公共 IPv4 iperf3 测速（4 并发 × 5 秒））' \
            <<< "$display_output" || fail "display surface omitted formatted cache source"
        grep -Fq '可信度：低' <<< "$display_output" ||
            fail "display surface omitted formatted confidence"
        grep -Fq '新加坡 / OVH / sgp.proof.ovh.net [15.235.182.181]:5201 / RTT 1 ms' \
            <<< "$display_output" || fail "display surface omitted formatted node"
        if grep -Eq '(^|[^[:alpha:]])(high|low|none)([^[:alpha:]]|$)|automatic policy|fixed 150 ms|peer results differ|root mq; all' \
            <<< "$display_output"; then
            fail "display surface leaked internal English metadata"
        fi
    done
    grep -Fq '测速：复用 7 天内同路由缓存，不执行现场测速' \
        <<< "$install_output" || fail "install summary omits fresh-cache reuse notice"
    assert_eq 1 "$(grep -Fc 'TCP 内存：' <<< "$install_output")" \
        "final install summary contains one TCP memory line"
    assert_eq 0 "$(grep -Fc '警告：' <<< "$install_output")" \
        "final install summary does not repeat measurement warnings"
    grep -Fq '队列：fq 生效（根队列 mq，1 个叶子队列均为 fq）' \
        <<< "$install_output" || fail "install summary omits formatted qdisc detail"
    grep -Fq '警告：上传节点结果差异超过 30%，采用较高有效值' \
        <<< "$status_output" || fail "status omits formatted upload warning"
    grep -Fq '警告：下载节点结果差异超过 30%，采用较高有效值' \
        <<< "$status_output" || fail "status omits formatted download warning"
    grep -Fq '# 测量来源: 7-day route-bound cache (public iperf3 IPv4 (P=4, t=5s))' \
        "$NETWORK_CONF" || fail "display layer changed persisted measurement source"
    grep -Fq '# 测量可信度: low' "$NETWORK_CONF" ||
        fail "display layer changed persisted confidence"
    grep -Fq '# RTT 来源: automatic policy' "$NETWORK_CONF" ||
        fail "display layer changed persisted RTT source"
    grep -Fq '# initcwnd 策略: auto: upload > 100 Mbps, set 32' "$NETWORK_CONF" ||
        fail "display layer changed persisted initcwnd policy"
    printf 'PASS: plan, install summary, and status share Chinese display mappings\n'
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

(
    reset_selection
    COMMAND=plan
    TUNING_MODE=auto
    AUTO_MODE_REQUESTED=true
    FORCE_REFRESH=true
    detect_memory_mb() { printf '%s\n' 8192; }
    detect_cgroup_memory_limit_mb() { return 1; }
    cache_modes=""
    probe_calls=0
    load_measurement_cache() {
        cache_modes="${cache_modes:+$cache_modes }$2"
        return 1
    }
    probe_bandwidth() {
        ((probe_calls += 1))
        DETECTED_DOWNLOAD_MBPS=1000
        DETECTED_UPLOAD_MBPS=500
        MEASUREMENT_SOURCE='refreshed public iperf3'
        MEASUREMENT_EPOCH=2000000000
        MEASUREMENT_TIME='2033-05-18T03:33:20Z'
        MEASUREMENT_NODES='one.example'
        MEASUREMENT_CONFIDENCE=high
        MEASUREMENT_WARNINGS=''
        MEASUREMENT_ROUTE_TARGET=1.1.1.1
        MEASUREMENT_ROUTE_IDENTITY='2|eth0|192.0.2.1|192.0.2.2'
        MEASUREMENT_CACHE_PENDING=true
    }
    is_interactive_terminal() { return 1; }
    resolve_tuning_values >/dev/null
    assert_eq 1 "$probe_calls" "refresh forces a live measurement"
    assert_eq '' "$cache_modes" "successful refresh bypasses the fresh cache"
    assert_eq 'refreshed public iperf3' "$MEASUREMENT_SOURCE" \
        "successful refresh keeps live measurement metadata"
)

(
    reset_selection
    COMMAND=plan
    TUNING_MODE=auto
    AUTO_MODE_REQUESTED=true
    FORCE_REFRESH=true
    detect_memory_mb() { printf '%s\n' 8192; }
    detect_cgroup_memory_limit_mb() { return 1; }
    cache_modes=""
    probe_calls=0
    load_measurement_cache() {
        cache_modes="${cache_modes:+$cache_modes }$2"
        [[ "$2" == "fallback" ]] || return 1
        DETECTED_DOWNLOAD_MBPS=900
        DETECTED_UPLOAD_MBPS=450
        MEASUREMENT_SOURCE='same-route stale cache (public iperf3)'
        MEASUREMENT_EPOCH=1999999940
        MEASUREMENT_TIME='2033-05-18T03:32:20Z'
        MEASUREMENT_NODES='cached.example'
        MEASUREMENT_CONFIDENCE=low
        MEASUREMENT_WARNINGS='live measurement failed'
        MEASUREMENT_ROUTE_TARGET=1.1.1.1
        MEASUREMENT_ROUTE_IDENTITY='2|eth0|192.0.2.1|192.0.2.2'
        return 0
    }
    probe_bandwidth() {
        ((probe_calls += 1))
        return 1
    }
    is_interactive_terminal() { return 1; }
    resolve_tuning_values >/dev/null
    assert_eq 1 "$probe_calls" "refresh attempts live measurement before fallback"
    assert_eq fallback "$cache_modes" \
        "refresh failure accepts the full thirty-day fallback window"
    assert_eq 900 "$DETECTED_DOWNLOAD_MBPS" \
        "refresh failure reuses route-matched fallback download"
    assert_eq low "$MEASUREMENT_CONFIDENCE" \
        "refresh fallback remains low confidence"
)

(
    FAIL_STAGE=""
    APPLY_FAIL_KEY=""
    BBR_AVAILABLE=true
    PERSIST_FAIL=false
    VALIDATION_CALLS=0
    APPLY_NETWORK_CALLS=0
    TCP_MEM_WRITE_ATTEMPTS=0
    APPLY_INITCWND_CALLS=0
    PERSIST_CALLS=0
    RUNTIME_STATE=""
    CURRENT_ROUTE=""
    SUCCESS_LOG="$TEMP_DIR/install-success.log"

    seed_install_fixture() {
        rm -rf -- \
            "$(dirname "$NETWORK_CONF")" "$(dirname "$BBR_MODULES_FILE")" \
            "$(dirname "$INITCWND_ROUTE_HOOK")" "$NETWORK_OPTIMIZE_STATE_DIR"
        mkdir -p \
            "$(dirname "$NETWORK_CONF")" "$(dirname "$BBR_MODULES_FILE")" \
            "$(dirname "$INITCWND_ROUTE_HOOK")" "$NETWORK_OPTIMIZE_STATE_DIR"
        printf '%s\n' 'old config' > "$NETWORK_CONF"
        printf '%s\n' 'old modules' > "$BBR_MODULES_FILE"
        printf '%s\n' 'old hook' > "$INITCWND_ROUTE_HOOK"
        printf '%s\n' 'old config' > "$NETWORK_PREVIOUS_BACKUP"
        printf '%s\n' 'old modules' > "$BBR_MODULES_PREVIOUS_BACKUP"
        printf '%s\n' 'old runtime' > "$RUNTIME_PREVIOUS_BACKUP"
        printf '%s\n' 'old route' > "$ROUTE_PREVIOUS_BACKUP"
        printf '%s\n' 'old hook' > "$ROUTE_HOOK_PREVIOUS_BACKUP"
        rm -f -- \
            "$NETWORK_PREVIOUS_ABSENT" "$BBR_MODULES_PREVIOUS_ABSENT" \
            "$ROUTE_PREVIOUS_ABSENT" "$ROUTE_PREVIOUS_OWNED" \
            "$ROUTE_HOOK_PREVIOUS_ABSENT" "$ROUTE_OWNED_MARKER"
        VALIDATION_CALLS=0
        APPLY_NETWORK_CALLS=0
        APPLY_FAIL_KEY=""
        TCP_MEM_WRITE_ATTEMPTS=0
        APPLY_INITCWND_CALLS=0
        PERSIST_CALLS=0
        RUNTIME_STATE='old runtime'
        CURRENT_ROUTE='old route'
        PROBE_IFACE=""
        : > "$SUCCESS_LOG"
    }

    assert_install_fixture_old() {
        local name="$1"

        assert_eq 'old config' "$(<"$NETWORK_CONF")" "$name restores config"
        assert_eq 'old modules' "$(<"$BBR_MODULES_FILE")" "$name restores modules"
        assert_eq 'old runtime' "$RUNTIME_STATE" "$name restores runtime"
        assert_eq 'old route' "$CURRENT_ROUTE" "$name restores route"
        assert_eq 'old hook' "$(<"$INITCWND_ROUTE_HOOK")" "$name restores hook"
    }

    detect_container() { return 1; }
    resolve_tuning_values() {
        TUNING_MODE=auto
        MEASUREMENT_ROUTE_TARGET="$MEASUREMENT_ROUTE_PROBE_TARGET"
        MEASUREMENT_ROUTE_IDENTITY='2|eth0|192.0.2.1|192.0.2.2'
        MEASUREMENT_CACHE_PENDING=false
        return 0
    }
    validate_measurement_route() {
        ((VALIDATION_CALLS += 1))
        case "$FAIL_STAGE" in
            first-route) return 1 ;;
            second-route) (( VALIDATION_CALLS == 1 )) ;;
            *) return 0 ;;
        esac
    }
    persist_pending_measurement_cache() { return 0; }
    detect_default_iface() { printf '%s\n' eth0; }
    create_network_config() {
        printf '%s\n' 'new config' > "$1"
        if [[ "$APPLY_FAIL_KEY" == "net.ipv4.tcp_mem" ]]; then
            printf '%s\n' 'net.ipv4.tcp_mem = 8192 16384 32768' >> "$1"
        fi
    }
    capture_runtime_values_from_files() { printf '%s\n' 'old runtime' > "$1"; }
    prepare_legacy_backup_state() { return 0; }
    merge_initial_runtime_values() { return 0; }
    backup_previous_state_set() { return 0; }
    ensure_bbr_available() { [[ "$BBR_AVAILABLE" == "true" ]]; }
    apply_network_config() {
        ((APPLY_NETWORK_CALLS += 1))
        RUNTIME_STATE='new runtime'
        if [[ -n "$APPLY_FAIL_KEY" ]] &&
            grep -Eq "^${APPLY_FAIL_KEY//./[.]}[[:space:]]*=" "$1"; then
            ((TCP_MEM_WRITE_ATTEMPTS += 1))
            return 1
        fi
    }
    verify_network_config() { return 0; }
    apply_initcwnd() {
        ((APPLY_INITCWND_CALLS += 1))
        CURRENT_ROUTE='new route'
        printf '%s\n' 'new hook' > "$INITCWND_ROUTE_HOOK"
    }
    persist_bbr_module() {
        ((PERSIST_CALLS += 1))
        printf '%s\n' 'new modules' > "$BBR_MODULES_FILE"
        [[ "$PERSIST_FAIL" != "true" ]]
    }
    apply_runtime_values_strict() { RUNTIME_STATE=$(<"$1"); }
    restore_default_route() { CURRENT_ROUTE=$(<"$1"); }
    show_install_summary() { return 0; }
    info() { return 0; }
    warn() { return 0; }
    error() { return 0; }
    success() { printf '%s\n' "$1" >> "$SUCCESS_LOG"; }

    seed_install_fixture
    FAIL_STAGE=first-route
    if install_optimization; then
        fail "first route validation failure unexpectedly succeeded"
    fi
    assert_install_fixture_old "first route validation failure"
    assert_eq 1 "$VALIDATION_CALLS" \
        "first route validation fails before the second check"
    assert_eq 0 "$APPLY_NETWORK_CALLS" \
        "first route validation performs no runtime write"
    assert_eq 0 "$APPLY_INITCWND_CALLS" \
        "first route validation performs no route or hook write"
    assert_eq 0 "$PERSIST_CALLS" \
        "first route validation performs no module write"

    seed_install_fixture
    FAIL_STAGE=second-route
    if install_optimization; then
        fail "second route validation failure unexpectedly succeeded"
    fi
    assert_install_fixture_old "second route validation failure"
    assert_eq 2 "$VALIDATION_CALLS" \
        "second route validation runs immediately before initcwnd"
    assert_eq 1 "$APPLY_NETWORK_CALLS" \
        "second route validation occurs after runtime apply"
    assert_eq 0 "$APPLY_INITCWND_CALLS" \
        "second route validation blocks initcwnd"
    assert_eq 0 "$PERSIST_CALLS" \
        "second route validation blocks BBR persistence"

    seed_install_fixture
    FAIL_STAGE=""
    APPLY_FAIL_KEY=net.ipv4.tcp_mem
    BBR_AVAILABLE=true
    PERSIST_FAIL=false
    if install_optimization; then
        fail "tcp_mem write failure unexpectedly succeeded"
    fi
    assert_install_fixture_old "tcp_mem write failure"
    assert_eq 1 "$TCP_MEM_WRITE_ATTEMPTS" \
        "tcp_mem write failure is observed"
    assert_eq 0 "$APPLY_INITCWND_CALLS" \
        "tcp_mem write failure blocks initcwnd"
    assert_eq 0 "$PERSIST_CALLS" \
        "tcp_mem write failure blocks BBR persistence"
    assert_eq 0 "${#INSTALL_ROLLBACK_FAILED_ITEMS[@]}" \
        "tcp_mem write failure completes all five rollback items"

    seed_install_fixture
    FAIL_STAGE=""
    BBR_AVAILABLE=true
    PERSIST_FAIL=true
    if install_optimization; then
        fail "BBR persistence failure unexpectedly succeeded"
    fi
    assert_install_fixture_old "BBR persistence failure"
    assert_eq 2 "$VALIDATION_CALLS" \
        "BBR failure follows both route validations"
    assert_eq 1 "$APPLY_INITCWND_CALLS" \
        "BBR failure occurs after initcwnd apply"
    assert_eq 1 "$PERSIST_CALLS" \
        "BBR persistence failure is observed"
    assert_eq 0 "${#INSTALL_ROLLBACK_FAILED_ITEMS[@]}" \
        "BBR persistence failure completes all five rollback items"
    [[ ! -s "$SUCCESS_LOG" ]] ||
        fail "BBR persistence failure emitted a success message before rollback"

    seed_install_fixture
    FAIL_STAGE=""
    BBR_AVAILABLE=false
    PERSIST_FAIL=false
    install_optimization
    assert_eq 'new config' "$(<"$NETWORK_CONF")" \
        "unsupported BBR still applies non-BBR config"
    assert_eq 'old modules' "$(<"$BBR_MODULES_FILE")" \
        "unsupported BBR leaves module persistence unchanged"
    assert_eq 0 "$PERSIST_CALLS" \
        "unsupported BBR remains a successful warning path"
    [[ ! -s "$SUCCESS_LOG" ]] ||
        fail "successful install emitted redundant standalone success messages"
    printf 'PASS: successful install defers success state to the final summary\n'
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

(
    SYS_RMEM_DEFAULT=2097152
    SYS_WMEM_DEFAULT=2097152
    SYS_TCP_MEM='8192 16384 32768'
    sysctl() {
        local key value

        case "$1" in
            -n)
                case "$2" in
                    net.core.rmem_default) printf '%s\n' "$SYS_RMEM_DEFAULT" ;;
                    net.core.wmem_default) printf '%s\n' "$SYS_WMEM_DEFAULT" ;;
                    net.ipv4.tcp_mem) printf '%s\n' "$SYS_TCP_MEM" ;;
                    *) return 1 ;;
                esac
                ;;
            -w)
                key=${2%%=*}
                value=${2#*=}
                case "$key" in
                    net.core.rmem_default) SYS_RMEM_DEFAULT="$value" ;;
                    net.core.wmem_default) SYS_WMEM_DEFAULT="$value" ;;
                    net.ipv4.tcp_mem) SYS_TCP_MEM="$value" ;;
                    *) return 1 ;;
                esac
                ;;
            *) return 1 ;;
        esac
    }
    begin_restore_transaction() {
        RESTORE_TRANSACTION_DIR=$(mktemp -d "$TEMP_DIR/runtime-restore.XXXXXX")
    }
    apply_network_config() { return 0; }
    restore_managed_file() { return 0; }
    restore_default_route() { return 0; }
    info() { return 0; }
    warn() { return 0; }
    error() { return 0; }
    success() { return 0; }

    mkdir -p "$NETWORK_OPTIMIZE_STATE_DIR" "$(dirname "$NETWORK_CONF")"
    printf '%s\n' '# previous target' > "$NETWORK_PREVIOUS_BACKUP"
    printf '%s\n' '# initial target' > "$NETWORK_INITIAL_BACKUP"
    cat > "$RUNTIME_PREVIOUS_BACKUP" <<'EOF'
net.core.rmem_default=1111111
net.core.wmem_default=1222222
net.ipv4.tcp_mem=100 200 400
EOF
    cat > "$RUNTIME_INITIAL_BACKUP" <<'EOF'
net.core.rmem_default=524288
net.core.wmem_default=786432
net.ipv4.tcp_mem=50 100 200
EOF

    restore_optimization previous
    assert_eq 1111111 "$SYS_RMEM_DEFAULT" \
        "restore previous recovers exact rmem_default"
    assert_eq 1222222 "$SYS_WMEM_DEFAULT" \
        "restore previous recovers exact wmem_default"
    assert_eq '100 200 400' "$SYS_TCP_MEM" \
        "restore previous recovers exact tcp_mem"

    SYS_RMEM_DEFAULT=2097152
    SYS_WMEM_DEFAULT=2097152
    SYS_TCP_MEM='8192 16384 32768'
    restore_optimization initial
    assert_eq 524288 "$SYS_RMEM_DEFAULT" \
        "restore initial recovers exact rmem_default"
    assert_eq 786432 "$SYS_WMEM_DEFAULT" \
        "restore initial recovers exact wmem_default"
    assert_eq '50 100 200' "$SYS_TCP_MEM" \
        "restore initial recovers exact tcp_mem"
)

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
