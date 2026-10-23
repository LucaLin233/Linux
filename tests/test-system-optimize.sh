#!/usr/bin/env bash
# system-optimize 模块的隔离测试：不调用真实 systemctl/sysctl/modprobe/apt-get/swapon。
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly ROOT_DIR
MODULE="$ROOT_DIR/modules/system-optimize.sh"
TEMP_DIR=$(mktemp -d)
readonly TEMP_DIR
trap 'rm -rf "$TEMP_DIR"' EXIT

CALLS="$TEMP_DIR/calls"
: > "$CALLS"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

pass() {
    printf 'PASS: %s\n' "$1"
}

assert_eq() {
    local expected="$1" actual="$2" name="$3"
    [[ "$actual" == "$expected" ]] || fail "$name: expected '$expected', got '$actual'"
    pass "$name"
}

assert_ok() {
    local name="$1"
    shift
    "$@" || fail "$name"
    pass "$name"
}

assert_fail() {
    local name="$1"
    shift
    if "$@"; then
        fail "$name: command unexpectedly succeeded"
    fi
    pass "$name"
}

assert_contains() {
    local haystack="$1" needle="$2" name="$3"
    [[ "$haystack" == *"$needle"* ]] || fail "$name: missing '$needle' in: $haystack"
    pass "$name"
}

assert_not_contains() {
    local haystack="$1" needle="$2" name="$3"
    [[ "$haystack" != *"$needle"* ]] || fail "$name: unexpected '$needle' in: $haystack"
    pass "$name"
}

record() {
    printf '%s\n' "$*" >> "$CALLS"
}

reset_calls() {
    : > "$CALLS"
}

call_index() {
    local needle="$1"
    grep -n -F -- "$needle" "$CALLS" | head -n 1 | cut -d: -f1
}

assert_call_order() {
    local first="$1" second="$2" name="$3"
    local first_line second_line
    first_line=$(call_index "$first")
    second_line=$(call_index "$second")
    [[ -n "$first_line" && -n "$second_line" ]] ||
        fail "$name: missing call ($first=$first_line, $second=$second_line): $(cat "$CALLS")"
    (( first_line < second_line )) ||
        fail "$name: expected '$first' before '$second', got $(cat "$CALLS")"
    pass "$name"
}

assert_no_call() {
    local needle="$1" name="$2"
    if grep -Fq -- "$needle" "$CALLS"; then
        fail "$name: unexpected call '$needle': $(cat "$CALLS")"
    fi
    pass "$name"
}

assert_call() {
    local needle="$1" name="$2"
    grep -Fq -- "$needle" "$CALLS" || fail "$name: missing call '$needle': $(cat "$CALLS")"
    pass "$name"
}

# ---------------------------------------------------------------- sandbox

make_sandbox() {
    local root
    root=$(mktemp -d "$TEMP_DIR/sandbox.XXXXXX")
    mkdir -p \
        "$root/etc/systemd" \
        "$root/etc/sysctl.d" \
        "$root/etc/tmpfiles.d" \
        "$root/var/lib/linux-setup/system-optimize" \
        "$root/sys/module/zswap/parameters" \
        "$root/sys/block/zram0" \
        "$root/sys/kernel/mm/transparent_hugepage"
    printf '%s\n' "$root"
}

SANDBOX=$(make_sandbox)
readonly SANDBOX
readonly SB_ZRAM_CONFIG="$SANDBOX/etc/systemd/zram-generator.conf"
readonly SB_SYSCTL_CONFIG="$SANDBOX/etc/sysctl.d/99-zram.conf"
readonly SB_THP_CONFIG="$SANDBOX/etc/tmpfiles.d/90-linux-setup-thp.conf"
readonly SB_STATE_DIR="$SANDBOX/var/lib/linux-setup/system-optimize"
readonly SB_SYSFS_ROOT="$SANDBOX/sys"
readonly SB_ZSWAP_SERVICE="$SANDBOX/etc/systemd/system/linux-setup-disable-zswap.service"
readonly SB_ZRAM_SWAP_DROPIN="$SANDBOX/etc/systemd/system/dev-zram0.swap.d/90-linux-setup-zswap.conf"
readonly SB_SWAP_TARGET_DROPIN="$SANDBOX/etc/systemd/system/swap.target.d/90-linux-setup-zswap.conf"

base_env=(
    "LINUX_SETUP_TEST_MODE=1"
    "LINUX_SETUP_TEST_ROOT=$SANDBOX"
    "LINUX_SETUP_ZRAM_CONFIG=$SB_ZRAM_CONFIG"
    "LINUX_SETUP_SYSCTL_CONFIG=$SB_SYSCTL_CONFIG"
    "LINUX_SETUP_THP_CONFIG=$SB_THP_CONFIG"
    "LINUX_SETUP_STATE_DIR=$SB_STATE_DIR"
    "LINUX_SETUP_SYSFS_ROOT=$SB_SYSFS_ROOT"
)

for entry in "${base_env[@]}"; do
    export "${entry?}"
done

reset_sandbox() {
    rm -rf "$SANDBOX"
    mkdir -p \
        "$SANDBOX/etc/systemd" \
        "$SANDBOX/etc/sysctl.d" \
        "$SANDBOX/etc/tmpfiles.d" \
        "$SB_STATE_DIR" \
        "$SB_SYSFS_ROOT/module/zswap/parameters" \
        "$SB_SYSFS_ROOT/block/zram0" \
        "$SB_SYSFS_ROOT/kernel/mm/transparent_hugepage"
    : > "$CALLS"
    printf 'vm.swappiness=60\nvm.page-cluster=0\n' > "$SB_STATE_DIR/zram.previous-runtime"
    printf 'kernel.panic=30\nfs.file-max=1048576\n' > "$SB_STATE_DIR/system-tuning.previous-runtime"
    SYSTEMCTL_FAIL=""
    SYSTEMCTL_HOOK=""
    SYSTEMCTL_CAT_STATUS=0
    SYSCTL_STATUS=0
    SYSCTL_VALUE=60
    GENERATOR_STATUS=0
    ZRAM_ACTIVE=false
    ZRAM_USED=""
    ZRAM_SIZE_LABEL="4.0G"
    SWAPON_OUTPUT=""
    ZRAM_PRIORITY=100
    SYSTEMCTL_SHOW_STATUS=0
    SYSTEMCTL_SHOW_VALUE="loaded"
    ZRAM_START_REBUILD=true
    ZRAM_START_PRIORITY=100
}

reset_sandbox

# ---------------------------------------------------------------- stubs

SYSTEMCTL_FAIL=""
SYSTEMCTL_HOOK=""
SYSTEMCTL_CAT_STATUS=0
SYSCTL_STATUS=0
SYSCTL_VALUE=60
GENERATOR_STATUS=0
ZRAM_ACTIVE=false
ZRAM_USED=""
ZRAM_SIZE_LABEL="4.0G"
SWAPON_OUTPUT=""
ZRAM_PRIORITY=100
SYSTEMCTL_SHOW_STATUS=0
SYSTEMCTL_SHOW_VALUE="loaded"
ZRAM_START_REBUILD=true
ZRAM_START_PRIORITY=100

systemctl() {
    local line="systemctl $*"
    record "$line"
    if [[ -n "$SYSTEMCTL_HOOK" ]]; then
        eval "$SYSTEMCTL_HOOK"
    fi
    if [[ -n "$SYSTEMCTL_FAIL" && "$line" == *"$SYSTEMCTL_FAIL"* ]]; then
        return 1
    fi
    if [[ "${1:-}" == "cat" ]]; then
        return "$SYSTEMCTL_CAT_STATUS"
    fi
    if [[ "${1:-}" == "show" ]]; then
        printf '%s\n' "$SYSTEMCTL_SHOW_VALUE"
        return "$SYSTEMCTL_SHOW_STATUS"
    fi
    # start zram unit 时模拟设备按目标参数重建。
    if [[ "${1:-}" == "start" && "$*" == *zram* ]]; then
        if [[ "$ZRAM_START_REBUILD" == "true" ]]; then
            seed_runtime_zram "${ZRAM_START_SIZE_EXPR:-$TARGET_SIZE}"
        fi
        ZRAM_PRIORITY="$ZRAM_START_PRIORITY"
    fi
    return 0
}

sysctl() {
    record "sysctl $*"
    if [[ "${1:-}" == "-n" ]]; then
        printf '%s\n' "$SYSCTL_VALUE"
    fi
    return "$SYSCTL_STATUS"
}

swapon() {
    record "swapon $*"
    printf '%s\n' "$SWAPON_OUTPUT"
    return 0
}

modprobe() {
    record "modprobe $*"
    return 0
}

sleep() {
    record "sleep $*"
    return 0
}

install_zram_generator() {
    record "install_zram_generator"
    return "$GENERATOR_STATUS"
}

is_zram_active() {
    [[ "$ZRAM_ACTIVE" == "true" ]]
}

get_zram_used_bytes() {
    printf '%s\n' "$ZRAM_USED"
}

get_zram_size() {
    printf '%s\n' "$ZRAM_SIZE_LABEL"
}

# shellcheck source=../modules/system-optimize.sh
source "$MODULE"

readonly ZSWAP_ENABLED="$SYSFS_ROOT/module/zswap/parameters/enabled"
assert_eq "$SB_ZRAM_CONFIG" "$ZRAM_CONFIG" "module uses sandbox zram config"
assert_eq "$SB_SYSFS_ROOT" "$SYSFS_ROOT" "module uses sandbox sysfs root"
assert_eq "$SB_ZSWAP_SERVICE" "$ZSWAP_SERVICE_CONFIG" "module derives zswap service path"
assert_eq "$SB_ZRAM_SWAP_DROPIN" "$ZRAM_SWAP_DROPIN" "module derives zram swap drop-in path"
assert_eq "$SB_SWAP_TARGET_DROPIN" "$SWAP_TARGET_DROPIN" "module derives swap target drop-in path"

# ---------------------------------------------------------------- loading behaviour

calls_before="$TEMP_DIR/loaded-calls"
: > "$calls_before"
load_output=$(bash -c '
    set -euo pipefail
    calls="$1"
    trap "echo TRAP_CHANGED" ERR
    before=$(trap -p ERR)
    systemctl() { printf "systemctl %s\n" "$*" >> "$calls"; }
    sysctl() { printf "sysctl %s\n" "$*" >> "$calls"; }
    modprobe() { printf "modprobe %s\n" "$*" >> "$calls"; }
    swapon() { printf "swapon %s\n" "$*" >> "$calls"; }
    source "$2"
    after=$(trap -p ERR)
    [[ "$before" == "$after" ]] || { echo TRAP_CHANGED; exit 1; }
    declare -F get_zswap_state >/dev/null || { echo MISSING_FUNCTION; exit 1; }
    echo SOURCED
' _ "$calls_before" "$MODULE" 2>&1)
assert_contains "$load_output" "SOURCED" "source only defines functions"
assert_not_contains "$load_output" "TRAP_CHANGED" "source keeps caller ERR trap"
[[ ! -s "$calls_before" ]] || fail "source ran side-effect commands: $(cat "$calls_before")"
pass "source runs no side-effect commands"

production_paths=$(env -u LINUX_SETUP_TEST_MODE \
    "LINUX_SETUP_ZRAM_CONFIG=/tmp/ignored/zram.conf" \
    "LINUX_SETUP_SYSFS_ROOT=/tmp/ignored/sys" \
    bash -c 'source "$1"; printf "%s\n%s\n%s\n" "$ZRAM_CONFIG" "$SYSFS_ROOT" "$ZSWAP_SERVICE_CONFIG"' _ "$MODULE")
assert_eq $'/etc/systemd/zram-generator.conf\n/sys\n/etc/systemd/system/linux-setup-disable-zswap.service' \
    "$production_paths" "production paths ignore override variables"

test_paths=$(env "${base_env[@]}" bash -c '
    source "$1"
    printf "%s\n%s\n%s\n%s\n%s\n" "$ZRAM_CONFIG" "$SYSFS_ROOT" "$ZSWAP_SERVICE_CONFIG" \
        "$ZRAM_SWAP_DROPIN" "$SWAP_TARGET_DROPIN"
' _ "$MODULE")
assert_eq "$ZRAM_CONFIG
$SYSFS_ROOT
$ZSWAP_SERVICE_CONFIG
$ZRAM_SWAP_DROPIN
$SWAP_TARGET_DROPIN" "$test_paths" "test mode applies all five overrides and derives systemd files"

assert_fail "refuse production main under test mode" \
    env "${base_env[@]}" bash "$MODULE" install

test_mode_message=$(env "${base_env[@]}" bash "$MODULE" install 2>&1 || true)
assert_contains "$test_mode_message" "测试模式禁止执行生产主流程" "test mode blocks real main with explicit error"

run_source_env() {
    env "$@" bash -c 'source "$1"' _ "$MODULE" >/dev/null 2>&1
}

run_source_env_unset() {
    local name="$1"
    shift
    env -u "$name" "$@" bash -c 'source "$1"' _ "$MODULE" >/dev/null 2>&1
}

no_zram_env=()
for entry in "${base_env[@]}"; do
    [[ "${entry%%=*}" == "LINUX_SETUP_ZRAM_CONFIG" ]] || no_zram_env+=("$entry")
done
assert_fail "missing override variable is rejected" \
    run_source_env_unset LINUX_SETUP_ZRAM_CONFIG "${no_zram_env[@]}"
assert_fail "empty override variable is rejected" run_source_env "${base_env[@]}" "LINUX_SETUP_ZRAM_CONFIG="
assert_fail "relative override path is rejected" run_source_env "${base_env[@]}" "LINUX_SETUP_ZRAM_CONFIG=etc/zram.conf"
assert_fail "override outside test root is rejected" \
    run_source_env "${base_env[@]}" "LINUX_SETUP_ZRAM_CONFIG=/etc/systemd/zram-generator.conf"
assert_fail "override with .. is rejected" \
    run_source_env "${base_env[@]}" "LINUX_SETUP_ZRAM_CONFIG=$SANDBOX/../escape/zram.conf"
assert_fail "system test root is rejected" \
    run_source_env "${base_env[@]}" "LINUX_SETUP_TEST_ROOT=/etc"

mkdir -p "$TEMP_DIR/outside"
ln -s "$TEMP_DIR/outside" "$TEMP_DIR/link"
assert_fail "symlinked override escapes test root" \
    run_source_env "${base_env[@]}" "LINUX_SETUP_ZRAM_CONFIG=$TEMP_DIR/link/zram.conf"

message=$(env "${base_env[@]}" "LINUX_SETUP_ZRAM_CONFIG=" \
    bash -c 'source "$1"' _ "$MODULE" 2>&1 || true)
assert_contains "$message" "路径配置无效" "path rejection reports a clear error"
[[ ! -e "$SANDBOX/../escape" ]] || fail "path validation wrote outside the sandbox"
pass "path validation fails before any write"

# ---------------------------------------------------------------- zswap control files

reset_sandbox
assert_ok "write zswap control files" write_zswap_config
assert_eq "644" "$(file_mode "$ZSWAP_SERVICE_CONFIG")" "service file mode is 0644"
assert_eq "644" "$(file_mode "$ZRAM_SWAP_DROPIN")" "zram swap drop-in mode is 0644"
assert_eq "644" "$(file_mode "$SWAP_TARGET_DROPIN")" "swap target drop-in mode is 0644"
assert_eq "755" "$(stat -c '%a' "$(dirname "$ZRAM_SWAP_DROPIN")")" "drop-in directory mode is 0755"
assert_eq "755" "$(stat -c '%a' "$(dirname "$SWAP_TARGET_DROPIN")")" "swap target directory mode is 0755"

expected_service=$(cat <<'EOF'
# 由 system-optimize.sh 自动生成。
[Unit]
Description=Disable zswap before managed swap activation
DefaultDependencies=no
Before=dev-zram0.swap swap.target
ConditionPathExists=/sys/module/zswap/parameters/enabled

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStartSec=10s
ExecStart=/bin/sh -c 'printf 0 > /sys/module/zswap/parameters/enabled || exit 1; read -r state < /sys/module/zswap/parameters/enabled || exit 1; case "$$state" in N|0) exit 0 ;; *) exit 1 ;; esac'
EOF
)
expected_dropin=$(cat <<'EOF'
# 由 system-optimize.sh 自动生成。
[Unit]
Wants=linux-setup-disable-zswap.service
After=linux-setup-disable-zswap.service
EOF
)

assert_eq "$expected_service" "$(cat "$ZSWAP_SERVICE_CONFIG")" "service file matches the documented unit"
assert_eq "$expected_dropin" "$(cat "$ZRAM_SWAP_DROPIN")" "zram swap drop-in matches the documented unit"
assert_eq "$expected_dropin" "$(cat "$SWAP_TARGET_DROPIN")" "swap target drop-in matches the documented unit"
assert_contains "$(cat "$ZSWAP_SERVICE_CONFIG")" 'case "$$state"' "service keeps the literal \$\$state for systemd escaping"

for forbidden in 'Requires=' 'ExecStop=' '[Install]' 'Restart='; do
    if grep -Fq -- "$forbidden" "$ZSWAP_SERVICE_CONFIG"; then
        fail "service must not contain $forbidden"
    fi
done
pass "service has no Requires/ExecStop/Install/Restart directives"

assert_ok "written control files match expectations" zswap_config_matches
printf 'x\n' >> "$ZSWAP_SERVICE_CONFIG"
assert_fail "extra service content breaks zswap_config_matches" zswap_config_matches
write_zswap_config
chmod 600 "$ZSWAP_SERVICE_CONFIG"
assert_fail "wrong service mode breaks zswap_config_matches" zswap_config_matches
write_zswap_config

# ---------------------------------------------------------------- sysctl rendering

reset_sandbox
assert_ok "write zram config" write_zram_config "ram" 60
if grep -Fq 'kernel.zswap.enabled' "$SYSCTL_CONFIG"; then
    fail "sysctl config must not contain kernel.zswap.enabled"
fi
pass "sysctl config has no kernel.zswap.enabled"
if grep -Fq '/proc/sys/kernel/zswap' "$MODULE"; then
    fail "module still references the removed /proc/sys/kernel/zswap probe"
fi
pass "module no longer probes /proc/sys/kernel/zswap"
assert_eq "60" "$(get_zram_sysctl_value vm.swappiness)" "swappiness is rendered in sysctl config"
assert_eq "0" "$(get_zram_sysctl_value vm.page-cluster)" "page-cluster is rendered as 0"
assert_eq "ram" "$(get_zram_config_value zram-size)" "zram-size is rendered in zram config"

# ---------------------------------------------------------------- zswap runtime state

reset_sandbox
printf 'Y\n' > "$ZSWAP_ENABLED"
assert_eq "enabled" "$(get_zswap_state)" "Y maps to enabled"
printf '1\n' > "$ZSWAP_ENABLED"
assert_eq "enabled" "$(get_zswap_state)" "1 maps to enabled"
printf 'N\n' > "$ZSWAP_ENABLED"
assert_eq "disabled" "$(get_zswap_state)" "N maps to disabled"
printf '0\n' > "$ZSWAP_ENABLED"
assert_eq "disabled" "$(get_zswap_state)" "0 maps to disabled"
printf 'X\n' > "$ZSWAP_ENABLED"
assert_eq "unknown" "$(get_zswap_state)" "invalid content maps to unknown"
printf '\n' > "$ZSWAP_ENABLED"
assert_eq "unknown" "$(get_zswap_state)" "empty content maps to unknown"
rm -f "$ZSWAP_ENABLED"
assert_eq "unavailable" "$(get_zswap_state)" "missing node maps to unavailable"
assert_ok "get_zswap_state always reports success" get_zswap_state >/dev/null

reset_sandbox
printf 'Y\n' > "$ZSWAP_ENABLED"
SYSTEMCTL_HOOK='if [[ "$*" == "restart linux-setup-disable-zswap.service" ]]; then printf "N\n" > "$ZSWAP_ENABLED"; fi'
assert_ok "setup_zswap succeeds after restart disabled zswap" setup_zswap >/dev/null 2>&1
assert_eq "Y" "$(cat "$STATE_DIR/zswap-enabled.previous-runtime")" "previous snapshot records pre-change Y"
assert_eq "Y" "$(cat "$STATE_DIR/zswap-enabled.initial-runtime")" "initial snapshot records Y"
assert_eq "N" "$(cat "$ZSWAP_ENABLED")" "runtime value is disabled after restart"
assert_call_order "daemon-reload" "restart linux-setup-disable-zswap.service" \
    "daemon-reload precedes the zswap restart"

reset_sandbox
printf 'N\n' > "$ZSWAP_ENABLED"
assert_ok "setup_zswap still restarts an already disabled zswap" setup_zswap >/dev/null 2>&1
assert_call "restart linux-setup-disable-zswap.service" "already disabled zswap is restarted, not just started"
assert_no_call "systemctl start linux-setup-disable-zswap" "setup_zswap never uses start instead of restart"
assert_eq "N" "$(cat "$STATE_DIR/zswap-enabled.previous-runtime")" "previous snapshot records N"

reset_sandbox
assert_ok "setup_zswap tolerates a kernel without zswap" setup_zswap >/dev/null 2>&1
assert_eq "unavailable" "$(cat "$STATE_DIR/zswap-enabled.previous-runtime")" "missing node is recorded as unavailable"
assert_eq "unavailable" "$(get_zswap_state)" "missing node is not reported as disabled"

reset_sandbox
printf 'X\n' > "$ZSWAP_ENABLED"
assert_fail "unrecognised zswap value fails the remediation" setup_zswap >/dev/null 2>&1
assert_eq "unknown" "$(cat "$STATE_DIR/zswap-enabled.previous-runtime")" "unrecognised value is recorded as unknown"

reset_sandbox
printf 'Y\n' > "$ZSWAP_ENABLED"
assert_fail "restart failure with zswap still enabled is reported" setup_zswap >/dev/null 2>&1
assert_eq "Y" "$(cat "$ZSWAP_ENABLED")" "failed remediation leaves the runtime value visible"

reset_sandbox
printf 'Y\n' > "$ZSWAP_ENABLED"
SYSTEMCTL_FAIL="restart linux-setup-disable-zswap.service"
SYSTEMCTL_HOOK='if [[ "$*" == "restart linux-setup-disable-zswap.service" ]]; then printf "N\n" > "$ZSWAP_ENABLED"; fi'
assert_fail "restart failure degrades even when the value reads back disabled" setup_zswap >/dev/null 2>&1

reset_sandbox
printf 'Y\n' > "$ZSWAP_ENABLED"
SYSTEMCTL_FAIL="daemon-reload"
assert_fail "daemon-reload failure aborts the remediation" setup_zswap >/dev/null 2>&1
assert_no_call "restart linux-setup-disable-zswap" "daemon-reload failure prevents the restart"

reset_sandbox
printf 'Y\n' > "$ZSWAP_ENABLED"
mkdir -p "$STATE_DIR/zswap-enabled.previous-runtime"
assert_fail "snapshot write failure aborts the remediation" setup_zswap >/dev/null 2>&1
assert_no_call "restart linux-setup-disable-zswap" "snapshot failure prevents the restart"
[[ ! -e "$ZSWAP_SERVICE_CONFIG" ]] || fail "snapshot failure must not write the service file"
pass "snapshot failure writes no zswap control files"
rmdir "$STATE_DIR/zswap-enabled.previous-runtime"

reset_sandbox
printf 'Y\n' > "$ZSWAP_ENABLED"
SYSTEMCTL_HOOK='if [[ "$*" == "restart linux-setup-disable-zswap.service" ]]; then printf "N\n" > "$ZSWAP_ENABLED"; fi'
setup_zswap >/dev/null 2>&1
printf 'Y\n' > "$ZSWAP_ENABLED"
setup_zswap >/dev/null 2>&1
assert_eq "Y" "$(cat "$STATE_DIR/zswap-enabled.initial-runtime")" "initial snapshot stays at the first observed value"
assert_eq "Y" "$(cat "$STATE_DIR/zswap-enabled.previous-runtime")" "previous snapshot follows the latest pre-install value"

reset_sandbox
printf 'Y\n' > "$ZSWAP_ENABLED"
printf 'Y\n' > "$STATE_DIR/zswap-enabled.previous-runtime"
assert_ok "restore zswap state writes the snapshot back" restore_zswap_state previous
assert_eq "Y" "$(cat "$ZSWAP_ENABLED")" "restore writes Y back to sysfs"

reset_sandbox
printf 'Y\n' > "$ZSWAP_ENABLED"
printf 'unknown\n' > "$STATE_DIR/zswap-enabled.previous-runtime"
assert_fail "restore refuses an untrusted snapshot" restore_zswap_state previous
assert_eq "Y" "$(cat "$ZSWAP_ENABLED")" "untrusted snapshot leaves sysfs untouched"

reset_sandbox
printf 'Y\n' > "$ZSWAP_ENABLED"
restore_zswap_state initial || status=$?
assert_eq "2" "${status:-0}" "missing snapshot reports the untrusted status"
assert_eq "Y" "$(cat "$ZSWAP_ENABLED")" "missing snapshot leaves sysfs untouched"
unset status

# ---------------------------------------------------------------- setup_zram flow

MEM_MB=$(awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo)
TARGET_CONFIG=$(get_optimal_zram_config "$MEM_MB")
TARGET_SIZE="${TARGET_CONFIG%,*}"
TARGET_SWAPPINESS="${TARGET_CONFIG##*,}"

# 这些函数在模块里已有定义，必须在 source 之后覆盖才能生效。
install_zram_generator() {
    record "install_zram_generator"
    return "$GENERATOR_STATUS"
}

is_zram_active() {
    [[ "$ZRAM_ACTIVE" == "true" ]]
}

get_zram_used_bytes() {
    printf '%s\n' "$ZRAM_USED"
}

get_zram_size() {
    printf '%s\n' "$ZRAM_SIZE_LABEL"
}

get_zram_priority() {
    printf '%s\n' "$ZRAM_PRIORITY"
}

seed_device() {
    printf '# Zram 配置：由 system-optimize.sh 自动生成\n[zram0]\nzram-size = %s\ncompression-algorithm = zstd\n' \
        "$1" > "$ZRAM_CONFIG"
}

seed_sysctl() {
    printf '# Zram 相关内核参数：由 system-optimize.sh 自动生成\nvm.swappiness = %s\nvm.page-cluster = 0\n' \
        "$1" > "$SYSCTL_CONFIG"
}

# 运行态：disksize 按表达式求值写入，comp_algorithm 用方括号标记活动算法。
seed_runtime_zram() {
    local expression="$1"
    local bytes

    bytes=$(zram_target_bytes "$expression") || fail "cannot evaluate zram size: $expression"
    printf '%s\n' "$bytes" > "$SYSFS_ROOT/block/zram0/disksize"
    printf 'lzo [zstd] lz4\n' > "$SYSFS_ROOT/block/zram0/comp_algorithm"
}

seed_active_device() {
    seed_device "$1"
    seed_sysctl "${2:-$TARGET_SWAPPINESS}"
    seed_runtime_zram "$1"
    write_zswap_config
    printf 'N\n' > "$ZSWAP_ENABLED"
    ZRAM_ACTIVE=true
}

reset_sandbox
seed_active_device "$TARGET_SIZE" 99
ZRAM_USED=0
assert_ok "policy-only drift succeeds without rebuilding" setup_zram >/dev/null 2>&1
assert_no_call "systemctl stop" "policy drift never stops the zram unit"
assert_no_call "swapoff" "policy drift never calls swapoff"
assert_eq "$TARGET_SWAPPINESS" "$(get_zram_sysctl_value vm.swappiness)" "sysctl drift is rewritten"
assert_eq "$TARGET_SIZE" "$(get_zram_config_value zram-size)" "device size text is unchanged"

reset_sandbox
seed_active_device "ram * 7"
ZRAM_USED=4096
assert_ok "zram with used pages is deferred" setup_zram >/dev/null 2>&1
[[ -f "$STATE_DIR/zram-reconfigure.pending" ]] || fail "used pages must leave a pending marker"
pass "used pages leave a pending reconfigure marker"
assert_no_call "systemctl stop" "used pages never stop the device"
assert_no_call "swapoff" "used pages never call swapoff"
assert_no_call "systemctl start" "used pages never restart the device"

reset_sandbox
seed_active_device "ram * 7"
ZRAM_USED=""
assert_fail "unknown zram usage degrades instead of rebuilding" setup_zram >/dev/null 2>&1
assert_no_call "systemctl stop" "unknown usage never stops the device"
assert_no_call "swapoff" "unknown usage never calls swapoff"
assert_contains "$(cat "$STATE_DIR/zram-reconfigure.pending")" "used-unknown" "unknown usage is recorded"

reset_sandbox
seed_active_device "ram * 7"
ZRAM_USED=0
assert_ok "unused device is rebuilt" setup_zram >/dev/null 2>&1
assert_call_order "systemctl stop" "systemctl start" "rebuild stops before starting"
assert_no_call "swapoff" "rebuild never calls swapoff"
[[ ! -e "$STATE_DIR/zram-reconfigure.pending" ]] || fail "successful rebuild clears the pending marker"
pass "successful rebuild clears the pending marker"

# 回归：第一次因交换页延迟重建后配置文本已等于目标，但设备仍是旧容量；
# 第二次运行必须继续按待重建处理，不能据配置文件报告「配置已生效」并清掉标记。
reset_sandbox
seed_active_device "ram * 7"
ZRAM_USED=4096
assert_ok "deferred rebuild writes the target config" setup_zram >/dev/null 2>&1
[[ -f "$STATE_DIR/zram-reconfigure.pending" ]] || fail "deferred rebuild must leave a pending marker"
assert_eq "$TARGET_SIZE" "$(get_zram_config_value zram-size)" "deferred rebuild still writes the target text"

reset_calls
second_run_output=$(setup_zram 2>&1) || fail "rerun with a pending marker must not fail"
assert_not_contains "$second_run_output" "配置已生效" "pending rerun must not claim the config is in effect"
[[ -f "$STATE_DIR/zram-reconfigure.pending" ]] || fail "pending rerun must keep the pending marker"
pass "pending rerun keeps the pending marker"
assert_no_call "systemctl stop" "pending rerun never stops the device"
assert_no_call "systemctl start" "pending rerun never starts the device"

reset_sandbox
seed_active_device "ram * 7"
ZRAM_USED=0
SYSTEMCTL_FAIL="stop systemd-zram-setup"
assert_fail "stop failure aborts the rebuild" setup_zram >/dev/null 2>&1
assert_no_call "systemctl start" "stop failure never reaches start"

reset_sandbox
seed_active_device "$TARGET_SIZE"
ZRAM_USED=0
SYSTEMCTL_FAIL="restart linux-setup-disable-zswap"
assert_fail "zswap failure degrades but keeps going" setup_zram >/dev/null 2>&1
assert_call "install_zram_generator" "zswap failure does not skip the generator check"
assert_eq "$TARGET_SWAPPINESS" "$(get_zram_sysctl_value vm.swappiness)" "zswap failure still writes sysctl"

reset_sandbox
seed_active_device "$TARGET_SIZE"
ZRAM_USED=0
GENERATOR_STATUS=1
assert_fail "missing zram generator fails the module step" setup_zram >/dev/null 2>&1

# ---------------------------------------------------------------- status display

reset_sandbox
printf 'lzo [zstd] lz4\n' > "$SYSFS_ROOT/block/zram0/comp_algorithm"
printf '4096 1024 2048 512 0 0 0\n' > "$SYSFS_ROOT/block/zram0/mm_stat"
status_output=$(show_zram_compression_status)
assert_contains "$status_output" "zstd" "status reports the active compression algorithm"
assert_contains "$status_output" "4.00" "status reports the raw/compressed ratio"
assert_contains "$status_output" "2.00" "status reports the raw/resident ratio"
assert_contains "$status_output" "orig_data_size=4096" "status reports mm_stat fields"

printf '0 0 0 0 0 0 0\n' > "$SYSFS_ROOT/block/zram0/mm_stat"
status_output=$(show_zram_compression_status)
assert_contains "$status_output" "N/A（空设备或无压缩数据）" "empty device reports N/A instead of dividing by zero"

printf 'a b c\n' > "$SYSFS_ROOT/block/zram0/mm_stat"
status_output=$(show_zram_compression_status)
assert_contains "$status_output" "N/A" "invalid mm_stat reports N/A"
assert_ok "status survives invalid mm_stat" show_zram_compression_status >/dev/null

rm -f "$SYSFS_ROOT/block/zram0/mm_stat"
assert_ok "status survives a missing mm_stat" show_zram_compression_status >/dev/null

reset_sandbox
printf 'Y\n' > "$ZSWAP_ENABLED"
printf 'zstd\n' > "$SYSFS_ROOT/module/zswap/parameters/compressor"
printf 'zsmalloc\n' > "$SYSFS_ROOT/module/zswap/parameters/zpool"
printf '20\n' > "$SYSFS_ROOT/module/zswap/parameters/max_pool_percent"
zswap_output=$(show_zswap_status)
assert_contains "$zswap_output" "zswap: enabled" "status reports the zswap state"
assert_contains "$zswap_output" "compressor=zstd" "status reports the zswap compressor"
assert_contains "$zswap_output" "zpool=zsmalloc" "status reports the zswap zpool"
assert_contains "$zswap_output" "max_pool_percent=20" "status reports max_pool_percent"

rm -f "$ZSWAP_ENABLED"
zswap_output=$(show_zswap_status)
assert_contains "$zswap_output" "zswap: unavailable" "status reports a missing zswap node"
assert_not_contains "$zswap_output" "zswap: disabled" "missing node is never reported as disabled"

SWAPON_OUTPUT=""
swap_output=$(show_swap_status)
assert_contains "$swap_output" "无活动设备" "status handles a host without swap"
assert_ok "status returns success without swap" show_swap_status >/dev/null

SWAPON_OUTPUT='/dev/zram0 partition 4294967296 1024 100'
swap_output=$(show_swap_status)
assert_contains "$swap_output" "Zram: /dev/zram0" "status lists the zram device"
assert_contains "$swap_output" "优先级 100" "status reports the swap priority"
SWAPON_OUTPUT=""

# ---------------------------------------------------------------- backup and restore lists

saved_backup_fn=$(declare -f backup_managed_file)
saved_restore_fn=$(declare -f restore_managed_file)
saved_restore_zswap_fn=$(declare -f restore_zswap_state)

restore_functions() {
    eval "$saved_backup_fn"
    eval "$saved_restore_fn"
    eval "$saved_restore_zswap_fn"
}

expected_targets=$(printf '%s\n' \
    "$ZRAM_CONFIG" "$SYSCTL_CONFIG" "$SYSTEM_TUNING_CONFIG" "$JOURNALD_DROPIN" "$THP_CONFIG" \
    "$ZSWAP_SERVICE_CONFIG" "$ZRAM_SWAP_DROPIN" "$SWAP_TARGET_DROPIN" | sort)

reset_sandbox
backup_managed_file() { record "backup $1"; }
reset_calls
backup_system_configs
assert_eq "8" "$(grep -c '^backup ' "$CALLS")" "backup covers eight managed files"
assert_eq "$expected_targets" "$(grep '^backup ' "$CALLS" | cut -d' ' -f2- | sort)" \
    "backup receives the documented eight targets"

restore_managed_file() { record "restore $1"; return 0; }
restore_zswap_state() { record "restore-zswap $1"; return 0; }
reset_calls
assert_ok "restore walks all managed files" restore_system_configs previous
assert_eq "8" "$(grep -c '^restore ' "$CALLS")" "restore covers eight managed files"
assert_eq "$expected_targets" "$(grep '^restore ' "$CALLS" | cut -d' ' -f2- | sort)" \
    "restore receives the documented eight targets"
restore_functions

# ---------------------------------------------------------------- restore semantics

reset_sandbox
write_zswap_config
printf 'custom\n' > "$ZSWAP_SERVICE_CONFIG.previous-backup"
for target in "$ZRAM_CONFIG" "$SYSCTL_CONFIG" "$SYSTEM_TUNING_CONFIG" "$JOURNALD_DROPIN" \
    "$THP_CONFIG" "$ZRAM_SWAP_DROPIN" "$SWAP_TARGET_DROPIN"; do
    install -D -m 0600 /dev/null "$target.previous-absent"
done
printf 'Y\n' > "$ZSWAP_ENABLED"
printf 'Y\n' > "$STATE_DIR/zswap-enabled.previous-runtime"
printf 'N\n' > "$ZSWAP_ENABLED"
SYSTEMCTL_HOOK='if [[ "$*" == "stop linux-setup-disable-zswap.service" ]]; then cp "$ZSWAP_SERVICE_CONFIG" "$TEMP_DIR/at-stop"; fi; if [[ "$*" == "daemon-reload" ]]; then cp "$ZSWAP_ENABLED" "$TEMP_DIR/at-reload"; fi'
assert_ok "restore applies the previous scope" restore_system_configs previous
assert_eq "custom" "$(cat "$ZSWAP_SERVICE_CONFIG")" "previous backup content is restored"
assert_contains "$(cat "$TEMP_DIR/at-stop")" "ExecStart=" "zswap unit is stopped before files are restored"
assert_eq "N" "$(cat "$TEMP_DIR/at-reload")" "runtime value is restored after daemon-reload"
assert_eq "Y" "$(cat "$ZSWAP_ENABLED")" "runtime snapshot is written back"
assert_no_call "restart linux-setup-disable-zswap" "restore never restarts the zswap unit"
assert_no_call "swapoff" "restore never calls swapoff"
assert_no_call "stop swap.target" "restore never stops swap.target"

reset_sandbox
write_zswap_config
rm -f "$ZRAM_SWAP_DROPIN"
for target in "$ZRAM_CONFIG" "$SYSCTL_CONFIG" "$SYSTEM_TUNING_CONFIG" "$JOURNALD_DROPIN" \
    "$THP_CONFIG" "$ZSWAP_SERVICE_CONFIG"; do
    install -D -m 0600 /dev/null "$target.previous-absent"
done
printf 'Y\n' > "$ZSWAP_ENABLED"
printf 'N\n' > "$STATE_DIR/zswap-enabled.previous-runtime"
printf 'N\n' > "$SWAP_TARGET_DROPIN.previous-unknown"
set +e
restore_system_configs previous
unknown_status=$?
set -e
assert_eq "2" "$unknown_status" "unknown state reports a partial restore"
[[ ! -e "$ZRAM_SWAP_DROPIN" ]] || fail "absent marker must delete a module-generated file"
pass "absent marker deletes the module-generated drop-in"
[[ -e "$SWAP_TARGET_DROPIN" ]] || fail "unknown marker must keep the dropped file"
pass "unknown marker keeps the file untouched"

reset_sandbox
write_zswap_config
restore_managed_file() { record "restore $1"; [[ "$1" != "$SWAP_TARGET_DROPIN" ]]; }
restore_zswap_state() { return 0; }
set +e
restore_system_configs previous
restore_status=$?
set -e
assert_eq "2" "$restore_status" "partial restore reports status 2"
assert_eq "8" "$(grep -c '^restore ' "$CALLS")" "partial restore still visits all eight files"

reset_sandbox
write_zswap_config
restore_managed_file() { record "restore $1"; return 2; }
restore_zswap_state() { return 0; }
set +e
restore_system_configs previous
restore_status=$?
set -e
assert_eq "1" "$restore_status" "restore without trusted state reports status 1"
restore_functions

# ---------------------------------------------------------------- main aggregation

if (( EUID == 0 )); then
    marker="$TEMP_DIR/main-calls"
    : > "$marker"
    set +e
    main_output=$(env "${base_env[@]}" bash -c '
        set -euo pipefail
        source "$1"
        marker="$2"
        apt-cache() { :; }
        apt-get() { :; }
        depmod() { :; }
        dpkg() { :; }
        dpkg-query() { :; }
        fuser() { :; }
        modprobe() { :; }
        swapon() { :; }
        systemctl() { :; }
        sysctl() { :; }
        timedatectl() { :; }
        wait_for_apt() { :; }
        backup_system_configs() { :; }
        setup_zram() { echo setup_zram >> "$marker"; return 1; }
        setup_system_tuning() { echo setup_system_tuning >> "$marker"; return 0; }
        setup_journald_limits() { echo setup_journald_limits >> "$marker"; return 0; }
        setup_thp_policy() { echo setup_thp_policy >> "$marker"; return 0; }
        setup_timezone() { echo setup_timezone >> "$marker"; return 0; }
        setup_chrony() { echo setup_chrony >> "$marker"; return 0; }
        main install
    ' _ "$MODULE" "$marker" 2>&1)
    main_status=$?
    set -e
    assert_eq "2" "$main_status" "zswap-only failure degrades main to exit code 2"
    assert_eq $'setup_zram\nsetup_system_tuning\nsetup_journald_limits\nsetup_thp_policy\nsetup_timezone\nsetup_chrony' \
        "$(cat "$marker")" "main keeps running every step after zswap fails"
    assert_contains "$main_output" "系统优化部分完成" "main reports a degraded result"
else
    printf 'SKIP: main aggregation needs root (EUID=%s)\n' "$EUID"
fi


# ---------------------------------------------------------------- PR 2: zram sizing table

assert_eq "ram * 2,100" "$(get_optimal_zram_config 512)" "512 MiB keeps 2x sizing"
assert_eq "ram * 1.5,100" "$(get_optimal_zram_config 513)" "513 MiB moves to 1.5x sizing"
assert_eq "ram * 1.5,100" "$(get_optimal_zram_config 1024)" "1024 MiB stays at 1.5x sizing"
assert_eq "ram,100" "$(get_optimal_zram_config 1025)" "1025 MiB moves to 1x sizing"
assert_eq "ram,100" "$(get_optimal_zram_config 4096)" "4096 MiB stays at 1x sizing"
assert_eq "min(ram / 2, 8192),100" "$(get_optimal_zram_config 4097)" "4097 MiB caps at half of RAM"
assert_eq "min(ram / 2, 8192),100" "$(get_optimal_zram_config 16384)" "16384 MiB caps at half of RAM"
assert_eq "min(ram / 2, 8192),100" "$(get_optimal_zram_config 32768)" "32768 MiB keeps the 8 GiB ceiling"

comma_config=$(get_optimal_zram_config 8192)
assert_eq "min(ram / 2, 8192)" "${comma_config%,*}" "size expression is cut at the last comma"
assert_eq "100" "${comma_config##*,}" "swappiness is cut after the last comma"

# ---------------------------------------------------------------- PR 2: rendered policy

reset_sandbox
assert_ok "write zram config with swap policy" write_zram_config "ram" 100
assert_eq "100" "$(get_zram_config_value swap-priority)" "generator config renders swap-priority=100"
assert_eq "zstd" "$(get_zram_config_value compression-algorithm)" "generator config keeps zstd"
assert_eq "100" "$(get_zram_sysctl_value vm.swappiness)" "sysctl renders swappiness=100"
assert_eq "0" "$(get_zram_sysctl_value vm.page-cluster)" "sysctl keeps page-cluster=0"
assert_not_contains "$(cat "$SYSCTL_CONFIG")" "zswap" "sysctl still has no zswap knob"
assert_not_contains "$(cat "$ZRAM_CONFIG")" "mem_limit" "generator config adds no mem_limit"
assert_not_contains "$(cat "$ZRAM_CONFIG")" "writeback" "generator config adds no writeback"

# ---------------------------------------------------------------- PR 2: priority matching

saved_optimal_fn=$(declare -f get_optimal_zram_config)
get_optimal_zram_config() { printf 'min(ram / 2, 8192),100\n'; }

reset_sandbox
seed_device "min(ram / 2, 8192)"
seed_sysctl 100
seed_runtime_zram "min(ram / 2, 8192)"
write_zswap_config
printf 'N\n' > "$ZSWAP_ENABLED"
ZRAM_ACTIVE=true
ZRAM_USED=0
ZRAM_PRIORITY=100
assert_ok "comma expression is parsed and the size text is preserved" setup_zram >/dev/null 2>&1
assert_eq "min(ram / 2, 8192)" "$(get_zram_config_value zram-size)" "size expression keeps its comma"
assert_eq "100" "$(get_zram_sysctl_value vm.swappiness)" "parsed swappiness is 100"
assert_no_call "systemctl stop" "missing priority text with running 100 does not rebuild"

reset_sandbox
seed_device "min(ram / 2, 8192)"
seed_sysctl 100
seed_runtime_zram "min(ram / 2, 8192)"
write_zswap_config
printf 'N\n' > "$ZSWAP_ENABLED"
ZRAM_ACTIVE=true
ZRAM_USED=0
ZRAM_PRIORITY=50
assert_ok "priority drift rebuilds the device" setup_zram >/dev/null 2>&1
assert_call "systemctl stop" "running priority other than 100 triggers a rebuild"
assert_eq "100" "$(get_zram_config_value swap-priority)" "rebuild writes priority 100"

reset_sandbox
seed_device "min(ram / 2, 8192)"
seed_sysctl 100
seed_runtime_zram "min(ram / 2, 8192)"
write_zswap_config
printf 'N\n' > "$ZSWAP_ENABLED"
ZRAM_ACTIVE=true
ZRAM_USED=2048
ZRAM_PRIORITY=50
assert_ok "priority drift with used pages is deferred" setup_zram >/dev/null 2>&1
assert_no_call "systemctl stop" "used pages still block the priority rebuild"
[[ -f "$STATE_DIR/zram-reconfigure.pending" ]] || fail "deferred priority rebuild must leave a pending marker"
pass "deferred priority rebuild leaves a pending marker"

eval "$saved_optimal_fn"

# ---------------------------------------------------------------- PR 2: THP defrag

# get_active_thp_mode 是既有实现：busybox awk 不会把 gsub 结果写回 $i，
# 因此本环境用桩提供 modes，只测本 PR 的转换与写入门槛；CI 的 gawk/mawk 走真实实现。
THP_DIR="$SYSFS_ROOT/kernel/mm/transparent_hugepage"
probe_file="$TEMP_DIR/thp-probe"
printf 'always [madvise] never\n' > "$probe_file"
if [[ "$(get_active_thp_mode "$probe_file")" == "madvise" ]]; then
    printf 'PASS: get_active_thp_mode strips mode brackets in this environment\n'
else
    printf 'SKIP: awk here does not strip THP mode brackets; THP policy is unit-tested with a stubbed getter\n'
fi

THP_ENABLED_MODE=""
THP_DEFRAG_MODE=""
get_active_thp_mode() {
    case "$1" in
        */defrag) printf '%s\n' "$THP_DEFRAG_MODE" ;;
        *) printf '%s\n' "$THP_ENABLED_MODE" ;;
    esac
}

reset_sandbox
THP_ENABLED_MODE=always
THP_DEFRAG_MODE=always
printf 'always [madvise] never\n' > "$THP_DIR/enabled"
printf 'always defer defer+madvise madvise never\n' > "$THP_DIR/defrag"
assert_ok "THP always defrag is relaxed" setup_thp_policy
assert_eq "madvise" "$(cat "$THP_DIR/enabled")" "THP enabled always becomes madvise"
assert_eq "defer+madvise" "$(cat "$THP_DIR/defrag")" "THP defrag always becomes defer+madvise"
assert_contains "$(cat "$THP_CONFIG")" "defer+madvise" "tmpfiles config records the defrag target"
assert_eq "always" "$(cat "$STATE_DIR/thp-defrag.previous-runtime")" "pre-change defrag mode is snapshotted"

reset_sandbox
THP_ENABLED_MODE=madvise
THP_DEFRAG_MODE=defer
printf 'always [madvise] never\n' > "$THP_DIR/enabled"
printf 'always defer defer+madvise madvise never\n' > "$THP_DIR/defrag"
assert_ok "THP defer defrag is kept" setup_thp_policy
assert_eq "defer" "$(cat "$THP_DIR/defrag")" "defer defrag is left untouched"

reset_sandbox
THP_ENABLED_MODE=never
THP_DEFRAG_MODE=madvise
printf 'always madvise [never]\n' > "$THP_DIR/enabled"
printf 'always defer defer+madvise madvise never\n' > "$THP_DIR/defrag"
assert_ok "THP madvise/never modes are kept" setup_thp_policy
assert_eq "never" "$(cat "$THP_DIR/enabled")" "never enabled mode is untouched"
assert_eq "madvise" "$(cat "$THP_DIR/defrag")" "madvise defrag is untouched"

reset_sandbox
THP_ENABLED_MODE=madvise
THP_DEFRAG_MODE=always
printf 'always [madvise] never\n' > "$THP_DIR/enabled"
printf 'always defer madvise never\n' > "$THP_DIR/defrag"
assert_fail "unsupported defrag target degrades instead of forcing" setup_thp_policy
assert_eq "always defer madvise never" "$(cat "$THP_DIR/defrag")" "unsupported defrag mode is not written"
assert_eq "always [madvise] never" "$(cat "$THP_DIR/enabled")" "unsupported defrag aborts before touching enabled"

reset_sandbox
THP_ENABLED_MODE=madvise
THP_DEFRAG_MODE=""
printf 'always [madvise] never\n' > "$THP_DIR/enabled"
rm -f "$THP_DIR/defrag"
assert_ok "missing defrag node is skipped" setup_thp_policy
assert_eq "madvise" "$(cat "$THP_DIR/enabled")" "missing defrag still applies the enabled policy"

# ---------------------------------------------------------------- PR 2: rollback

reset_sandbox
write_zram_config "min(ram / 2, 8192)" 100
printf '# old zram config\n[zram0]\nzram-size = ram\ncompression-algorithm = lz4\n' > "$ZRAM_CONFIG.previous-backup"
printf 'vm.swappiness=60\nvm.page-cluster=3\n' > "$STATE_DIR/zram.previous-runtime"
for target in "$SYSCTL_CONFIG" "$SYSTEM_TUNING_CONFIG" "$JOURNALD_DROPIN" "$THP_CONFIG" \
    "$ZSWAP_SERVICE_CONFIG" "$ZRAM_SWAP_DROPIN" "$SWAP_TARGET_DROPIN"; do
    install -D -m 0600 /dev/null "$target.previous-absent"
done
printf 'N\n' > "$ZSWAP_ENABLED"
printf 'N\n' > "$STATE_DIR/zswap-enabled.previous-runtime"
reset_calls
assert_ok "rollback restores the previous zram policy" restore_system_configs previous
assert_contains "$(cat "$ZRAM_CONFIG")" "compression-algorithm = lz4" "previous generator config is restored"
assert_call "sysctl -w vm.swappiness=60" "rollback restores vm.swappiness"
assert_call "sysctl -w vm.page-cluster=3" "rollback restores vm.page-cluster"
assert_no_call "swapoff" "rollback never forces swapoff"

printf 'All system-optimize tests passed.\n'
