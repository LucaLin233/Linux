#!/usr/bin/env bash
# linux-setup:name=系统优化（Zram、日志、THP、时间同步）
# linux-setup:order=10
# linux-setup:depends=
# linux-setup:enabled=true
# 系统优化模块
# 功能：智能 Zram、系统 sysctl、journald 限额、THP 策略、时区与 Chrony。

set -euo pipefail

# === 常量定义 ===
readonly DEFAULT_TIMEZONE="Asia/Shanghai"
readonly APT_LOCK_TIMEOUT=120
readonly APT_LOCK_INTERVAL=5

# 路径在加载阶段一次性固定：生产模式恒用系统路径；测试模式只接受显式给出的隔离路径，
# 缺失、空值或逃逸一律拒绝加载，不回落真实系统路径。
module_path_error() {
    printf '路径配置无效：%s\n' "$1" >&2
    exit 1
}

path_has_parent_reference() {
    [[ "$1" == ".." || "$1" == ../* || "$1" == */.. || "$1" == */../* ]]
}

# 最近的存在祖先必须物理落在测试根内，避免 .. 与 symlink 逃逸。
path_inside_root() {
    local dir="$1"
    local root="$2"
    local real

    while [[ ! -d "$dir" ]]; do
        [[ "$dir" == "/" || -z "$dir" ]] && return 1
        dir=$(dirname "$dir")
    done
    real=$(cd -P "$dir" 2>/dev/null && pwd -P) || return 1
    [[ "$real" == "$root" || "$real" == "$root"/* ]]
}

require_test_path() {
    local name="$1"
    local value="$2"
    local root="$3"
    local parent

    [[ -n "$value" ]] || module_path_error "$name 不能为空"
    [[ "$value" == /* ]] || module_path_error "$name 必须是绝对路径：$value"
    if path_has_parent_reference "$value"; then
        module_path_error "$name 不能包含 ..：$value"
    fi
    parent=$(dirname "$value")
    [[ -d "$parent" ]] || module_path_error "$name 的父目录必须预先存在：$parent"
    path_inside_root "$parent" "$root" || module_path_error "$name 逃逸测试根：$value"
}

require_test_derived_path() {
    local name="$1"
    local value="$2"
    local root="$3"

    [[ -n "$value" ]] || module_path_error "$name 不能为空"
    [[ "$value" == /* ]] || module_path_error "$name 必须是绝对路径：$value"
    if path_has_parent_reference "$value"; then
        module_path_error "$name 不能包含 ..：$value"
    fi
    path_inside_root "$(dirname "$value")" "$root" ||
        module_path_error "$name 逃逸测试根：$value"
}

init_module_paths() {
    local test_root="${LINUX_SETUP_TEST_ROOT:-}"
    local real_root=""

    if [[ "${LINUX_SETUP_TEST_MODE:-}" != "1" ]]; then
        ZRAM_CONFIG="/etc/systemd/zram-generator.conf"
        SYSCTL_CONFIG="/etc/sysctl.d/99-zram.conf"
        SYSTEM_TUNING_CONFIG="/etc/sysctl.d/99-system-optimize.conf"
        JOURNALD_DROPIN="/etc/systemd/journald.conf.d/90-linux-setup.conf"
        THP_CONFIG="/etc/tmpfiles.d/90-linux-setup-thp.conf"
        STATE_DIR="/var/lib/linux-setup/system-optimize"
        SYSFS_ROOT="/sys"
    else
        [[ -n "$test_root" ]] || module_path_error "LINUX_SETUP_TEST_ROOT 不能为空"
        [[ "$test_root" == /* ]] || module_path_error "LINUX_SETUP_TEST_ROOT 必须是绝对路径"
        if path_has_parent_reference "$test_root"; then
            module_path_error "LINUX_SETUP_TEST_ROOT 不能包含 ..：$test_root"
        fi
        [[ -d "$test_root" ]] || module_path_error "LINUX_SETUP_TEST_ROOT 不存在：$test_root"
        real_root=$(cd -P "$test_root" && pwd -P) ||
            module_path_error "LINUX_SETUP_TEST_ROOT 不可解析：$test_root"
        case "$real_root" in
            / | /etc | /usr | /var | /sys | /proc | /dev | /boot | /bin | /sbin | /lib | /lib64 | /root | /home)
                module_path_error "LINUX_SETUP_TEST_ROOT 不能是系统目录：$real_root"
                ;;
            /etc/* | /usr/* | /var/* | /sys/* | /proc/* | /dev/* | /boot/* | /bin/* | /sbin/* | /lib/* | /lib64/* | /root/* | /home/*)
                module_path_error "LINUX_SETUP_TEST_ROOT 不能位于系统目录下：$real_root"
                ;;
        esac

        ZRAM_CONFIG="${LINUX_SETUP_ZRAM_CONFIG:-}"
        SYSCTL_CONFIG="${LINUX_SETUP_SYSCTL_CONFIG:-}"
        THP_CONFIG="${LINUX_SETUP_THP_CONFIG:-}"
        STATE_DIR="${LINUX_SETUP_STATE_DIR:-}"
        SYSFS_ROOT="${LINUX_SETUP_SYSFS_ROOT:-}"

        require_test_path LINUX_SETUP_ZRAM_CONFIG "$ZRAM_CONFIG" "$real_root"
        require_test_path LINUX_SETUP_SYSCTL_CONFIG "$SYSCTL_CONFIG" "$real_root"
        require_test_path LINUX_SETUP_THP_CONFIG "$THP_CONFIG" "$real_root"
        require_test_path LINUX_SETUP_STATE_DIR "$STATE_DIR" "$real_root"
        require_test_path LINUX_SETUP_SYSFS_ROOT "$SYSFS_ROOT" "$real_root"
        SYSTEM_TUNING_CONFIG="$(dirname "$ZRAM_CONFIG")/sysctl.d/99-system-optimize.conf"
        JOURNALD_DROPIN="$(dirname "$ZRAM_CONFIG")/journald.conf.d/90-linux-setup.conf"
    fi

    ZSWAP_SERVICE_CONFIG="$(dirname "$ZRAM_CONFIG")/system/linux-setup-disable-zswap.service"
    ZRAM_SWAP_DROPIN="$(dirname "$ZRAM_CONFIG")/system/dev-zram0.swap.d/90-linux-setup-zswap.conf"
    SWAP_TARGET_DROPIN="$(dirname "$ZRAM_CONFIG")/system/swap.target.d/90-linux-setup-zswap.conf"

    if [[ "${LINUX_SETUP_TEST_MODE:-}" == "1" ]]; then
        require_test_derived_path ZSWAP_SERVICE_CONFIG "$ZSWAP_SERVICE_CONFIG" "$real_root"
        require_test_derived_path ZRAM_SWAP_DROPIN "$ZRAM_SWAP_DROPIN" "$real_root"
        require_test_derived_path SWAP_TARGET_DROPIN "$SWAP_TARGET_DROPIN" "$real_root"
    fi

    readonly ZRAM_CONFIG SYSCTL_CONFIG SYSTEM_TUNING_CONFIG JOURNALD_DROPIN THP_CONFIG \
        STATE_DIR SYSFS_ROOT ZSWAP_SERVICE_CONFIG ZRAM_SWAP_DROPIN SWAP_TARGET_DROPIN
}

init_module_paths

# === 日志函数 ===
log() {
    local msg="$1"
    local level="${2:-info}"
    local -A colors=(
        [info]="\033[0;36m"
        [warn]="\033[0;33m"
        [error]="\033[0;31m"
        [debug]="\033[0;35m"
    )

    if [[ "$level" == "debug" && "${DEBUG:-}" != "1" ]]; then
        return 0
    fi

    echo -e "${colors[$level]:-\033[0;32m}${msg}\033[0m" >&2
}

# === 配置文件备份与恢复 ===
backup_managed_file() {
    local target="$1"
    local initial_backup="${target}.initial-backup"
    local previous_backup="${target}.previous-backup"
    local initial_absent="${target}.initial-absent"
    local previous_absent="${target}.previous-absent"
    local initial_unknown="${target}.initial-unknown"

    if [[ ! -e "$initial_backup" && ! -e "$initial_absent" && ! -e "$initial_unknown" ]]; then
        if [[ -e "$target" || -L "$target" ]]; then
            cp -a "$target" "$initial_backup" || return 1
        else
            install -D -m 0600 /dev/null "$initial_absent" || return 1
        fi
    fi

    rm -f "$previous_backup" "$previous_absent"
    if [[ -e "$target" || -L "$target" ]]; then
        cp -a "$target" "$previous_backup" || return 1
    else
        install -D -m 0600 /dev/null "$previous_absent" || return 1
    fi
}

restore_managed_file() {
    local target="$1"
    local scope="$2"
    local backup="${target}.${scope}-backup"
    local absent="${target}.${scope}-absent"
    local unknown="${target}.${scope}-unknown"

    if [[ -e "$backup" || -L "$backup" ]]; then
        install -d -m 0755 "$(dirname "$target")"
        rm -f "$target"
        cp -a "$backup" "$target"
        return 0
    fi

    if [[ -e "$absent" ]]; then
        rm -f "$target"
        return 0
    fi

    if [[ -e "$unknown" ]]; then
        log "初始状态未知，跳过恢复：$target" "warn"
        return 2
    fi

    log "没有 $scope 配置状态，跳过恢复：$target" "warn"
    return 2
}

prepare_legacy_backup_state() {
    local target
    local marker

    while IFS='|' read -r target marker; do
        [[ -n "$target" ]] || continue
        if [[ ! -e "${target}.initial-backup" && ! -e "${target}.initial-absent" &&
            ! -e "${target}.initial-unknown" && -f "$target" ]] &&
            grep -Fq "$marker" "$target"; then
            install -D -m 0600 /dev/null "${target}.initial-unknown"
        fi
    done <<EOF
$ZRAM_CONFIG|Zram 配置：由 system-optimize.sh 自动生成
$SYSCTL_CONFIG|Zram 相关内核参数：由 system-optimize.sh 自动生成
EOF
}

backup_system_configs() {
    local target

    prepare_legacy_backup_state
    for target in \
        "$ZRAM_CONFIG" \
        "$SYSCTL_CONFIG" \
        "$SYSTEM_TUNING_CONFIG" \
        "$JOURNALD_DROPIN" \
        "$THP_CONFIG" \
        "$ZSWAP_SERVICE_CONFIG" \
        "$ZRAM_SWAP_DROPIN" \
        "$SWAP_TARGET_DROPIN"; do
        backup_managed_file "$target" || return 1
    done
}

capture_sysctl_values() {
    local config_file="$1"
    local output_file="$2"
    local key

    : > "$output_file"
    [[ -f "$config_file" ]] || return 0

    while IFS='=' read -r key _; do
        key="${key//[[:space:]]/}"
        [[ -n "$key" && "$key" != \#* ]] || continue
        if sysctl -n "$key" >/dev/null 2>&1; then
            printf '%s=%s\n' "$key" "$(sysctl -n "$key")" >> "$output_file"
        fi
    done < "$config_file"
}

restore_sysctl_values() {
    local values_file="$1"
    local key
    local value

    [[ -f "$values_file" ]] || return 0
    while IFS='=' read -r key value; do
        [[ -n "$key" ]] || continue
        sysctl -w "$key=$value" >/dev/null 2>&1 ||
            log "运行值恢复失败：$key" "warn"
    done < "$values_file"
}

# === APT 锁处理 ===
wait_for_apt() {
    local waited=0
    local lock_files=(
        /var/lib/dpkg/lock-frontend
        /var/lib/dpkg/lock
        /var/lib/apt/lists/lock
        /var/cache/apt/archives/lock
    )

    while fuser "${lock_files[@]}" >/dev/null 2>&1; do
        if (( waited >= APT_LOCK_TIMEOUT )); then
            log "APT/dpkg 被占用超过 ${APT_LOCK_TIMEOUT} 秒，请等待其他软件包操作完成后重试" "error"
            return 1
        fi

        if (( waited == 0 )); then
            log "等待 APT/dpkg 锁释放..." "warn"
        fi

        sleep "$APT_LOCK_INTERVAL"
        ((waited += APT_LOCK_INTERVAL))
    done
}

# === Swap / Zram 状态 ===
show_swap_status() {
    local swappiness
    local swap_info

    swappiness=$(cat /proc/sys/vm/swappiness 2>/dev/null || echo "unknown")
    echo "Swap 配置: swappiness=$swappiness"

    show_zswap_status
    show_zram_compression_status

    swap_info=$(swapon --noheadings --show 2>/dev/null || true)

    if [[ -z "$swap_info" ]]; then
        echo "Swap 状态: 无活动设备"
        return 0
    fi

    echo "Swap 状态:"

    while read -r device _type size used priority; do
        [[ -z "$device" ]] && continue

        local display_type="磁盘"
        [[ "$device" == *"/zram"* ]] && display_type="Zram"

        echo "  - $display_type: $device ($size，已用 $used，优先级 $priority)"
    done <<< "$swap_info"

    return 0
}

get_zram_used_bytes() {
    awk '
        $1 == "/dev/zram0" {
            print $4 * 1024
            exit
        }
    ' /proc/swaps
}

get_zram_size() {
    awk '
        $1 == "/dev/zram0" {
            printf "%.1fG\n", $3 / 1024 / 1024
            exit
        }
    ' /proc/swaps
}

is_zram_active() {
    systemctl is-active --quiet systemd-zram-setup@zram0.service &&
        [[ -b /dev/zram0 ]] &&
        awk '$1 == "/dev/zram0" {found=1} END {exit !found}' /proc/swaps
}

# === Zswap 控制 ===
zswap_parameter_path() {
    printf '%s/module/zswap/parameters/%s\n' "$SYSFS_ROOT" "$1"
}

get_zswap_state() {
    local path
    local value

    path=$(zswap_parameter_path enabled)
    if [[ ! -e "$path" ]]; then
        echo "unavailable"
        return 0
    fi

    if ! value=$(cat "$path" 2>/dev/null); then
        echo "unknown"
        return 0
    fi

    case "$value" in
        Y | 1) echo "enabled" ;;
        N | 0) echo "disabled" ;;
        *) echo "unknown" ;;
    esac
    return 0
}

zswap_snapshot_value() {
    case "$1" in
        enabled) echo "Y" ;;
        disabled) echo "N" ;;
        unavailable) echo "unavailable" ;;
        *) echo "unknown" ;;
    esac
}

show_zswap_status() {
    local state
    local compressor
    local zpool
    local max_pool_percent

    state=$(get_zswap_state)
    echo "zswap: $state"

    if [[ "$state" != "unavailable" ]]; then
        compressor=$(cat "$(zswap_parameter_path compressor)" 2>/dev/null || true)
        zpool=$(cat "$(zswap_parameter_path zpool)" 2>/dev/null || true)
        max_pool_percent=$(cat "$(zswap_parameter_path max_pool_percent)" 2>/dev/null || true)
        echo "  compressor=${compressor:-unknown} zpool=${zpool:-unknown} max_pool_percent=${max_pool_percent:-unknown}"
    fi

    return 0
}

show_zram_compression_status() {
    local algorithm_path="$SYSFS_ROOT/block/zram0/comp_algorithm"
    local mm_stat_path="$SYSFS_ROOT/block/zram0/mm_stat"
    local algorithm
    local orig_data_size
    local compr_data_size
    local mem_used_total
    local ratio

    algorithm=$(awk '{for (i = 1; i <= NF; i++) if ($i ~ /^\[.*\]$/) {gsub(/[\[\]]/, "", $i); print $i; exit}}' \
        "$algorithm_path" 2>/dev/null || true)
    echo "Zram 活动压缩算法: ${algorithm:-unknown}"

    if [[ ! -r "$mm_stat_path" ]]; then
        echo "Zram 压缩比（原始/压缩）: N/A"
        return 0
    fi

    orig_data_size=""
    compr_data_size=""
    mem_used_total=""
    read -r orig_data_size compr_data_size mem_used_total _ < "$mm_stat_path" || true

    if [[ ! "$orig_data_size" =~ ^[0-9]+$ ||
        ! "$compr_data_size" =~ ^[0-9]+$ ||
        ! "$mem_used_total" =~ ^[0-9]+$ ]]; then
        echo "Zram 压缩比（原始/压缩）: N/A"
        return 0
    fi

    echo "Zram mm_stat: orig_data_size=${orig_data_size} compr_data_size=${compr_data_size} mem_used_total=${mem_used_total}"

    if (( compr_data_size > 0 )); then
        ratio=$(awk -v orig="$orig_data_size" -v comp="$compr_data_size" \
            'BEGIN {printf "%.2f", orig / comp}')
        echo "Zram 压缩比（原始/压缩）: ${ratio}"
    else
        echo "Zram 压缩比（原始/压缩）: N/A（空设备或无压缩数据）"
    fi

    if (( mem_used_total > 0 )); then
        ratio=$(awk -v orig="$orig_data_size" -v used="$mem_used_total" \
            'BEGIN {printf "%.2f", orig / used}')
        echo "Zram 占用比（原始/实际占用）: ${ratio}"
    else
        echo "Zram 占用比（原始/实际占用）: N/A（空设备或无压缩数据）"
    fi

    return 0
}

capture_zswap_state() {
    local state
    local snapshot="$STATE_DIR/zswap-enabled.previous-runtime"
    local initial="$STATE_DIR/zswap-enabled.initial-runtime"

    state=$(zswap_snapshot_value "$(get_zswap_state)")
    if ! printf '%s\n' "$state" > "$snapshot"; then
        log "无法写入 zswap 运行快照：$snapshot" "error"
        return 1
    fi
    if ! chmod 600 "$snapshot"; then
        log "无法设置 zswap 运行快照权限：$snapshot" "error"
        return 1
    fi

    if [[ ! -f "$initial" ]]; then
        if ! cp -a "$snapshot" "$initial"; then
            log "无法写入 zswap 初始运行快照：$initial" "error"
            return 1
        fi
    fi

    if [[ "$state" == "unknown" ]]; then
        log "zswap 运行状态无法识别，快照标记为 unknown" "warn"
    fi

    return 0
}

restore_zswap_state() {
    local scope="$1"
    local snapshot="$STATE_DIR/zswap-enabled.${scope}-runtime"
    local path
    local value
    local state

    case "$scope" in
        previous | initial) ;;
        *)
            log "恢复范围必须是 previous 或 initial" "error"
            return 1
            ;;
    esac

    if [[ ! -f "$snapshot" ]]; then
        log "缺少 zswap ${scope} 运行快照，无法恢复运行值" "warn"
        return 2
    fi

    path=$(zswap_parameter_path enabled)
    if [[ ! -e "$path" ]]; then
        log "zswap 参数节点不存在，运行值无法恢复" "warn"
        return 2
    fi

    value=$(cat "$snapshot" 2>/dev/null || true)
    case "$value" in
        Y | N) ;;
        *)
            log "zswap 运行快照值不可信：$snapshot" "warn"
            return 2
            ;;
    esac

    if ! printf '%s\n' "$value" > "$path"; then
        log "写入 zswap 运行值失败：$path" "warn"
        return 1
    fi

    state=$(get_zswap_state)
    case "$value:$state" in
        Y:enabled | N:disabled) return 0 ;;
    esac

    log "zswap 运行值回读不符：期望 $value，实际 $state" "warn"
    return 1
}

render_zswap_service_config() {
    cat <<'EOF'
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
}

render_zswap_dropin_config() {
    cat <<'EOF'
# 由 system-optimize.sh 自动生成。
[Unit]
Wants=linux-setup-disable-zswap.service
After=linux-setup-disable-zswap.service
EOF
}

write_zswap_config() {
    local temp_file
    local target

    temp_file=$(mktemp) || return 1

    if ! render_zswap_service_config > "$temp_file"; then
        rm -f "$temp_file"
        return 1
    fi
    if ! install -D -m 0644 "$temp_file" "$ZSWAP_SERVICE_CONFIG"; then
        rm -f "$temp_file"
        return 1
    fi

    if ! render_zswap_dropin_config > "$temp_file"; then
        rm -f "$temp_file"
        return 1
    fi
    for target in "$ZRAM_SWAP_DROPIN" "$SWAP_TARGET_DROPIN"; do
        if ! install -D -m 0644 "$temp_file" "$target"; then
            rm -f "$temp_file"
            return 1
        fi
    done

    rm -f "$temp_file"
    return 0
}

file_mode() {
    stat -c '%a' "$1" 2>/dev/null || echo "unknown"
}

zswap_config_matches() {
    local temp_file

    temp_file=$(mktemp) || return 1

    if ! render_zswap_service_config > "$temp_file"; then
        rm -f "$temp_file"
        return 1
    fi
    if ! cmp -s "$temp_file" "$ZSWAP_SERVICE_CONFIG"; then
        rm -f "$temp_file"
        return 1
    fi

    if ! render_zswap_dropin_config > "$temp_file"; then
        rm -f "$temp_file"
        return 1
    fi
    if ! cmp -s "$temp_file" "$ZRAM_SWAP_DROPIN"; then
        rm -f "$temp_file"
        return 1
    fi
    if ! cmp -s "$temp_file" "$SWAP_TARGET_DROPIN"; then
        rm -f "$temp_file"
        return 1
    fi

    rm -f "$temp_file"

    [[ "$(file_mode "$ZSWAP_SERVICE_CONFIG")" == "644" ]] || return 1
    [[ "$(file_mode "$ZRAM_SWAP_DROPIN")" == "644" ]] || return 1
    [[ "$(file_mode "$SWAP_TARGET_DROPIN")" == "644" ]] || return 1

    return 0
}

setup_zswap() {
    local state
    local restart_ok=true

    if ! capture_zswap_state; then
        log "zswap 运行快照保存失败；本轮不写 zswap 配置、不重启服务" "error"
        show_zswap_status
        return 1
    fi

    if ! write_zswap_config; then
        log "zswap 控制文件写入失败" "error"
        show_zswap_status
        return 1
    fi

    if ! systemctl daemon-reload; then
        log "systemctl daemon-reload 失败，跳过 zswap 服务重启" "error"
        show_zswap_status
        return 1
    fi

    # 每次 install 都 restart：unit 已 active 时 start 不会重新执行 ExecStart。
    if ! systemctl restart linux-setup-disable-zswap.service; then
        log "linux-setup-disable-zswap.service 重启失败，继续独立回读实际状态" "warn"
        restart_ok=false
    fi

    state=$(get_zswap_state)
    case "$state" in
        unavailable)
            show_zswap_status
            return 0
            ;;
        disabled)
            show_zswap_status
            if [[ "$restart_ok" == "true" ]]; then
                return 0
            fi
            log "zswap 运行值已为 disabled，但纠偏服务重启失败" "warn"
            return 1
            ;;
        enabled)
            log "zswap 仍处于 enabled：纠偏服务未能关闭 zswap" "error"
            show_zswap_status
            return 1
            ;;
        *)
            log "zswap 运行状态无法确认" "error"
            show_zswap_status
            return 1
            ;;
    esac
}

# === Zram 配置 ===
get_optimal_zram_config() {
    local mem_mb="$1"
    local zram_size
    local swappiness

    # 小内存优先避免 OOM；大内存则减少不必要的压缩和换页。
    if (( mem_mb <= 512 )); then
        zram_size="ram * 2"
        swappiness=60
    elif (( mem_mb <= 1024 )); then
        zram_size="ram * 1.5"
        swappiness=60
    elif (( mem_mb <= 4096 )); then
        zram_size="ram"
        swappiness=40
    else
        zram_size="ram / 2"
        swappiness=20
    fi

    echo "${zram_size},${swappiness}"
}

write_zram_config() {
    local zram_size="$1"
    local swappiness="$2"

    if ! cat > "$ZRAM_CONFIG" <<EOF
# Zram 配置：由 system-optimize.sh 自动生成
[zram0]
zram-size = ${zram_size}
compression-algorithm = zstd
EOF
    then
        log "写入 Zram 配置失败：$ZRAM_CONFIG" "error"
        return 1
    fi

    if ! cat > "$SYSCTL_CONFIG" <<EOF
# Zram 相关内核参数：由 system-optimize.sh 自动生成
vm.swappiness = ${swappiness}
vm.page-cluster = 0
EOF
    then
        log "写入 Zram sysctl 配置失败：$SYSCTL_CONFIG" "error"
        return 1
    fi

    # zswap 由 linux-setup-disable-zswap.service 在 swap 激活前关闭；
    # kernel.zswap.enabled 在多数内核不存在，写进 sysctl 会让整份配置应用失败。
    return 0
}

apply_zram_sysctl() {
    if ! sysctl -p "$SYSCTL_CONFIG" >/dev/null 2>&1; then
        log "无法立即应用 Zram sysctl 配置，重启后会自动生效" "warn"
        return 1
    fi
}

get_zram_config_value() {
    local key="$1"

    [[ -f "$ZRAM_CONFIG" ]] || return 1

    awk -F= -v key="$key" '
        $1 ~ "^[[:space:]]*" key "[[:space:]]*$" {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
            print $2
            exit
        }
    ' "$ZRAM_CONFIG"
}

get_zram_sysctl_value() {
    local key="$1"

    [[ -f "$SYSCTL_CONFIG" ]] || return 1

    awk -F= -v key="$key" '
        $1 ~ "^[[:space:]]*" key "[[:space:]]*$" {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
            print $2
            exit
        }
    ' "$SYSCTL_CONFIG"
}

zram_config_matches() {
    local target_size="$1"
    local target_swappiness="$2"
    local current_size
    local current_swappiness
    local page_cluster
    local zswap_state

    is_zram_active || return 1

    current_size=$(get_zram_config_value "zram-size" || true)
    current_swappiness=$(get_zram_sysctl_value "vm.swappiness" || true)
    page_cluster=$(get_zram_sysctl_value "vm.page-cluster" || true)

    [[ "$current_size" == "$target_size" ]] || return 1
    [[ "$current_swappiness" == "$target_swappiness" ]] || return 1
    [[ "$page_cluster" == "0" ]] || return 1

    # 旧版本会写 kernel.zswap.enabled；该键不存在于多数内核，重新渲染后不得残留。
    if grep -Fq 'kernel.zswap.enabled' "$SYSCTL_CONFIG" 2>/dev/null; then
        return 1
    fi

    zswap_config_matches || return 1

    zswap_state=$(get_zswap_state)
    case "$zswap_state" in
        disabled | unavailable) ;;
        *) return 1 ;;
    esac

    return 0
}

# 只回答“设备是否需要重新激活”；sysctl、service、drop-in 的漂移都不算。
zram_device_config_matches() {
    local target_size="$1"
    local current_size
    local current_algorithm

    is_zram_active || return 1

    current_size=$(get_zram_config_value "zram-size" || true)
    current_algorithm=$(get_zram_config_value "compression-algorithm" || true)

    [[ "$current_size" == "$target_size" ]] || return 1
    [[ "$current_algorithm" == "zstd" ]] || return 1

    return 0
}

zram_kernel_module_available() {
    [[ -d "$SYSFS_ROOT/module/zram" ]] || modprobe zram >/dev/null 2>&1
}

get_ubuntu_kernel_meta_package() {
    local version_id=""
    local kernel_version

    kernel_version=$(uname -r)
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091  # /etc/os-release is provided by the target OS, not this repository.
        . /etc/os-release
        version_id="${VERSION_ID:-}"
    fi

    case "$kernel_version" in
        *-generic)
            case "$version_id" in
                22.04)
                    if [[ "$kernel_version" == 5.15.*-generic ]]; then
                        echo "linux-image-generic"
                    else
                        echo "linux-image-generic-hwe-22.04"
                    fi
                    ;;
                24.04)
                    echo "linux-image-generic"
                    ;;
                *)
                    return 1
                    ;;
            esac
            ;;
        *)
            return 1
            ;;
    esac
}

ensure_ubuntu_kernel_meta_package() {
    local meta_package

    meta_package=$(get_ubuntu_kernel_meta_package || true)
    [[ -n "$meta_package" ]] || return 1

    if dpkg-query -W -f='${db:Status-Status}' "$meta_package" 2>/dev/null |
        grep -qx "installed"; then
        return 0
    fi

    if ! apt-cache show --no-all-versions "$meta_package" >/dev/null 2>&1; then
        log "当前软件源没有 Ubuntu 内核元包：$meta_package" "warn"
        return 1
    fi

    log "为确保后续内核持续包含 Zram，安装内核元包：$meta_package" "warn"
    log "该元包可能同时安装 linux-firmware、CPU 微码及其他内核运行依赖" "warn"

    if ! NEEDRESTART_MODE=a DEBIAN_FRONTEND=noninteractive \
        apt-get install -y --no-install-recommends "$meta_package"; then
        log "Ubuntu 内核元包安装失败；当前内核的 Zram 配置仍将继续" "warn"
        return 1
    fi

    log "Ubuntu 内核元包已就绪，后续内核升级将自动携带 modules-extra" "info"
}

ensure_zram_kernel_module() {
    local os_id=""
    local kernel_version
    local extra_package
    local meta_package=""
    local apt_status=0
    local -a kernel_packages=()

    kernel_version=$(uname -r)
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091  # /etc/os-release is provided by the target OS, not this repository.
        . /etc/os-release
        os_id="${ID:-}"
    fi

    if zram_kernel_module_available; then
        if [[ "$os_id" == "ubuntu" ]]; then
            ensure_ubuntu_kernel_meta_package ||
                log "未能配置 Ubuntu 完整内核元包；未来内核升级后可能需要再次补充 modules-extra" "warn"
        fi
        return 0
    fi

    if [[ "$os_id" == "ubuntu" ]]; then
        extra_package="linux-modules-extra-${kernel_version}"

        if ! apt-cache show --no-all-versions "$extra_package" >/dev/null 2>&1; then
            log "当前软件源没有 $extra_package" "warn"
        else
            kernel_packages+=("$extra_package")

            # 精简 VPS 常安装 linux-image-virtual，它不会依赖 modules-extra。
            # 同时安装对应的完整 image 元包，确保后续内核升级自动携带 Zram 模块。
            meta_package=$(get_ubuntu_kernel_meta_package || true)
            if [[ -n "$meta_package" ]] &&
                apt-cache show --no-all-versions "$meta_package" >/dev/null 2>&1; then
                kernel_packages+=("$meta_package")
                log "为确保后续内核持续包含 Zram，安装内核元包：$meta_package" "warn"
                log "该元包可能同时安装 linux-firmware、CPU 微码及其他内核运行依赖" "warn"
            else
                meta_package=""
                log "未找到适用的完整内核元包；仅修复当前内核的 Zram 模块" "warn"
            fi

            log "当前 Ubuntu 内核缺少 Zram 模块，安装：${kernel_packages[*]}" "warn"
            NEEDRESTART_MODE=a DEBIAN_FRONTEND=noninteractive \
                apt-get install -y --no-install-recommends "${kernel_packages[@]}" || apt_status=$?
            depmod -a "$kernel_version" >/dev/null 2>&1 || true

            if zram_kernel_module_available; then
                if (( apt_status != 0 )); then
                    log "Zram 模块包已就绪，继续修复未完成的 dpkg 配置..." "warn"
                    if ! DEBIAN_FRONTEND=noninteractive dpkg --configure -a; then
                        log "dpkg 配置修复失败，请先修复软件包状态" "error"
                        return 1
                    fi
                fi

                if [[ -n "$meta_package" ]]; then
                    log "Ubuntu 内核元包已就绪，后续内核升级将自动携带 modules-extra" "info"
                fi
                log "Zram 内核模块已就绪" "info"
                return 0
            fi
        fi
    fi

    log "当前内核 $kernel_version 不提供 Zram 模块，已跳过 Zram，且不会安装 systemd-zram-generator" "warn"
    return 1
}

install_zram_generator() {
    ensure_zram_kernel_module || return 1

    if dpkg-query -W -f='${db:Status-Status}' systemd-zram-generator 2>/dev/null |
        grep -qx "installed"; then
        return 0
    fi

    log "安装 systemd-zram-generator..." "info"

    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y systemd-zram-generator; then
        log "systemd-zram-generator 安装失败" "error"
        return 1
    fi
}

start_zram() {
    systemctl daemon-reload

    if ! systemctl start systemd-zram-setup@zram0.service; then
        log "systemd-zram-setup@zram0 服务启动失败" "error"
        return 1
    fi

    sleep 2

    if ! is_zram_active; then
        log "Zram 服务未正常激活" "error"
        return 1
    fi
}

setup_zram() {
    local mem_mb
    local config
    local zram_size
    local swappiness
    local used_bytes
    local current_size
    local actual_size
    local active=false
    local device_matches=false
    local degraded=false
    local used_known=true
    local keys_file
    local pending_file="$STATE_DIR/zram-reconfigure.pending"

    mem_mb=$(awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo)

    if [[ ! "$mem_mb" =~ ^[0-9]+$ ]] || (( mem_mb <= 0 )); then
        log "无法获取系统内存大小，跳过 Zram 配置" "error"
        return 1
    fi

    config=$(get_optimal_zram_config "$mem_mb")
    zram_size="${config%,*}"
    swappiness="${config#*,}"

    echo "检测到内存: ${mem_mb}MB"
    echo "目标 Zram: ${zram_size}，swappiness=${swappiness}"

    # 是否重建只取决于设备本身，必须在覆盖原配置之前判断并保存结果。
    if zram_device_config_matches "$zram_size"; then
        device_matches=true
    fi

    # zswap 纠偏先于软件包检查：包安装失败不应让 zswap 保持开启。
    if ! setup_zswap; then
        log "zswap 未能确认关闭；继续配置 sysctl 与 Zram" "warn"
        degraded=true
    fi

    keys_file=$(mktemp) || return 1
    if ! printf 'vm.swappiness\nvm.page-cluster\n' > "$keys_file"; then
        rm -f "$keys_file"
        return 1
    fi
    if ! capture_sysctl_values "$keys_file" "$STATE_DIR/zram.previous-runtime"; then
        log "无法保存 Zram sysctl 运行值" "error"
        degraded=true
    elif [[ ! -f "$STATE_DIR/zram.initial-runtime" ]]; then
        if ! install -m 0600 "$STATE_DIR/zram.previous-runtime" \
            "$STATE_DIR/zram.initial-runtime"; then
            log "无法保存 Zram sysctl 初始运行值" "error"
            degraded=true
        fi
    fi
    rm -f "$keys_file"

    if ! write_zram_config "$zram_size" "$swappiness"; then
        log "Zram 配置写入失败" "error"
        degraded=true
    elif ! apply_zram_sysctl; then
        log "Zram sysctl 未能立即生效" "warn"
        degraded=true
    fi

    if ! install_zram_generator; then
        log "Zram 内核模块或 systemd-zram-generator 不可用" "error"
        show_swap_status
        return 1
    fi

    if [[ "$device_matches" == "true" ]]; then
        current_size=$(get_zram_size)
        if zram_config_matches "$zram_size" "$swappiness"; then
            echo "Zram: ${current_size:-已启用}（配置已生效）"
            rm -f "$pending_file" || true
        else
            echo "Zram: ${current_size:-已启用}（设备无需重建，配置已写入）"
        fi
        show_swap_status
        if [[ "$degraded" == "true" ]]; then
            return 1
        fi
        return 0
    fi

    used_bytes=0
    if is_zram_active; then
        active=true
        used_bytes=$(get_zram_used_bytes || true)
        if [[ ! "$used_bytes" =~ ^[0-9]+$ ]]; then
            used_known=false
        fi
    fi

    if [[ "$active" == "true" && "$used_known" == "false" ]]; then
        log "无法确认 Zram 已用交换页，按不安全处理：本次不重建设备" "error"
        if ! printf 'used-unknown\n' > "$pending_file"; then
            log "无法记录待重建状态：$pending_file" "warn"
        fi
        show_swap_status
        return 1
    fi

    # Zram 已有交换页时不强制 swapoff，避免低内存机器触发 OOM。
    if [[ "$active" == "true" ]] && (( used_bytes > 0 )); then
        log "当前 Zram 已使用 ${used_bytes} 字节 Swap；新配置将在下次重启后生效" "warn"
        if ! printf 'used-bytes=%s\n' "$used_bytes" > "$pending_file"; then
            log "无法记录待重建状态：$pending_file" "warn"
        fi
        show_swap_status
        if [[ "$degraded" == "true" ]]; then
            return 1
        fi
        return 0
    fi

    if [[ "$active" == "true" ]]; then
        log "停止未使用的现有 Zram 服务以应用新配置..." "info"
        if ! systemctl stop systemd-zram-setup@zram0.service; then
            log "停止 Zram 服务失败，不再继续重建" "error"
            show_swap_status
            return 1
        fi
    fi

    if ! start_zram; then
        log "Zram 服务未能按新配置启动" "error"
        show_swap_status
        return 1
    fi

    rm -f "$pending_file" || true
    actual_size=$(get_zram_size)
    echo "Zram: ${actual_size:-已启用}（zstd，swappiness=${swappiness}）"
    show_swap_status
    if [[ "$degraded" == "true" ]]; then
        return 1
    fi
    return 0
}

# === 通用系统调优 ===
setup_system_tuning() {
    local file_max
    local temp_file

    file_max=$(cat /proc/sys/fs/file-max 2>/dev/null || echo 0)
    [[ "$file_max" =~ ^[0-9]+$ ]] || file_max=0
    (( file_max < 1048576 )) && file_max=1048576

    temp_file=$(mktemp) || return 1
    cat > "$temp_file" <<EOF
# 由 system-optimize.sh 自动生成。
# Headless VPS 在 Kernel Panic 后等待 30 秒自动重启。
kernel.panic = 30

# 不降低管理员已经设置的更高系统文件句柄上限。
fs.file-max = $file_max
EOF

    capture_sysctl_values "$temp_file" "$STATE_DIR/system-tuning.previous-runtime" || {
        rm -f "$temp_file"
        return 1
    }
    if [[ ! -f "$STATE_DIR/system-tuning.initial-runtime" ]]; then
        install -m 0600 "$STATE_DIR/system-tuning.previous-runtime" \
            "$STATE_DIR/system-tuning.initial-runtime" || {
            rm -f "$temp_file"
            return 1
        }
    fi

    install -D -m 0644 "$temp_file" "$SYSTEM_TUNING_CONFIG"
    rm -f "$temp_file"
    if ! sysctl -p "$SYSTEM_TUNING_CONFIG" >/dev/null; then
        restore_managed_file "$SYSTEM_TUNING_CONFIG" previous || true
        restore_sysctl_values "$STATE_DIR/system-tuning.previous-runtime"
        return 1
    fi
}

setup_journald_limits() {
    local temp_file

    temp_file=$(mktemp) || return 1
    cat > "$temp_file" <<'EOF'
# 由 system-optimize.sh 自动生成。
[Journal]
SystemMaxUse=256M
SystemKeepFree=512M
RuntimeMaxUse=64M
MaxRetentionSec=7day
EOF

    if [[ -f "$JOURNALD_DROPIN" ]] && cmp -s "$temp_file" "$JOURNALD_DROPIN"; then
        rm -f "$temp_file"
        return 0
    fi

    install -D -m 0644 "$temp_file" "$JOURNALD_DROPIN"
    rm -f "$temp_file"

    # journald 没有稳定的独立配置校验命令；cat-config 至少确认 drop-in 可被发现。
    if command -v systemd-analyze >/dev/null 2>&1; then
        systemd-analyze cat-config systemd/journald.conf >/dev/null
    fi

    if ! systemctl restart systemd-journald ||
        ! systemctl is-active --quiet systemd-journald; then
        restore_managed_file "$JOURNALD_DROPIN" previous || true
        systemctl restart systemd-journald >/dev/null 2>&1 || true
        return 1
    fi
}

get_active_thp_mode() {
    local path="$1"
    awk '{for (i=1; i<=NF; i++) if ($i ~ /^\[.*\]$/) {gsub(/[\[\]]/, "", $i); print $i; exit}}' "$path"
}

setup_thp_policy() {
    local enabled_path="$SYSFS_ROOT/kernel/mm/transparent_hugepage/enabled"
    local defrag_path="$SYSFS_ROOT/kernel/mm/transparent_hugepage/defrag"
    local enabled_mode
    local defrag_mode
    local enabled_target
    local defrag_target

    [[ -e "$enabled_path" ]] || return 0

    enabled_mode=$(get_active_thp_mode "$enabled_path")
    case "$enabled_mode" in always|madvise|never) ;; *) return 1 ;; esac
    enabled_target="$enabled_mode"
    [[ "$enabled_mode" == "always" ]] && enabled_target="madvise"

    defrag_mode=""
    defrag_target=""
    if [[ -e "$defrag_path" ]]; then
        defrag_mode=$(get_active_thp_mode "$defrag_path")
        case "$defrag_mode" in always|defer|defer+madvise|madvise|never) ;; *) return 1 ;; esac
        defrag_target="$defrag_mode"
        case "$defrag_mode" in
            always|defer) defrag_target="defer+madvise" ;;
        esac
    fi

    printf '%s\n' "$enabled_mode" > "$STATE_DIR/thp-enabled.previous-runtime"
    printf '%s\n' "$defrag_mode" > "$STATE_DIR/thp-defrag.previous-runtime"
    chmod 600 "$STATE_DIR"/thp-*.previous-runtime
    if [[ ! -f "$STATE_DIR/thp-enabled.initial-runtime" ]]; then
        cp -a "$STATE_DIR/thp-enabled.previous-runtime" "$STATE_DIR/thp-enabled.initial-runtime"
        cp -a "$STATE_DIR/thp-defrag.previous-runtime" "$STATE_DIR/thp-defrag.initial-runtime"
    fi

    install -d -m 0755 "$(dirname "$THP_CONFIG")"
    {
        echo "# 由 system-optimize.sh 自动生成。"
        printf 'w- %s - - - - %s\n' "$enabled_path" "$enabled_target"
        if [[ -n "$defrag_target" ]]; then
            printf 'w- %s - - - - %s\n' "$defrag_path" "$defrag_target"
        fi
    } > "$THP_CONFIG"
    chmod 644 "$THP_CONFIG"

    if ! printf '%s\n' "$enabled_target" > "$enabled_path"; then
        restore_managed_file "$THP_CONFIG" previous || true
        return 1
    fi
    if [[ -n "$defrag_target" ]] &&
        ! printf '%s\n' "$defrag_target" > "$defrag_path"; then
        printf '%s\n' "$enabled_mode" > "$enabled_path" 2>/dev/null || true
        restore_managed_file "$THP_CONFIG" previous || true
        return 1
    fi
}

restore_system_configs() {
    local scope="${1:-previous}"
    local target
    local restored=false
    local runtime_scope="$scope"
    local failed=false
    local unknown=false
    local status
    local thp_value
    local stop_ok=true

    case "$scope" in previous | initial) ;;
        *)
            log "恢复范围必须是 previous 或 initial" "error"
            return 1
            ;;
    esac

    # 先停纠偏 unit，避免它在文件恢复后仍按旧配置干预 zswap 运行值。
    if systemctl cat linux-setup-disable-zswap.service >/dev/null 2>&1; then
        if ! systemctl stop linux-setup-disable-zswap.service; then
            log "停止 linux-setup-disable-zswap.service 失败" "error"
            failed=true
            stop_ok=false
        fi
    fi

    # 八个受管文件各自独立恢复，单个失败不阻断其余文件。
    for target in \
        "$ZRAM_CONFIG" \
        "$SYSCTL_CONFIG" \
        "$SYSTEM_TUNING_CONFIG" \
        "$JOURNALD_DROPIN" \
        "$THP_CONFIG" \
        "$ZSWAP_SERVICE_CONFIG" \
        "$ZRAM_SWAP_DROPIN" \
        "$SWAP_TARGET_DROPIN"; do
        status=0
        restore_managed_file "$target" "$scope" || status=$?
        case "$status" in
            0) restored=true ;;
            2) unknown=true ;;
            *) failed=true ;;
        esac
    done

    if [[ "$restored" != "true" ]]; then
        log "没有可恢复的可信配置" "error"
        return 1
    fi

    if ! systemctl daemon-reload; then
        log "恢复后 systemctl daemon-reload 失败" "warn"
        failed=true
    fi

    if [[ "$stop_ok" == "true" ]]; then
        status=0
        restore_zswap_state "$runtime_scope" || status=$?
        case "$status" in
            0) ;;
            2) unknown=true ;;
            *) failed=true ;;
        esac
    else
        log "未能确认纠偏 unit 已停止，跳过 zswap 运行值恢复" "warn"
    fi

    if [[ -f "$SYSCTL_CONFIG" ]]; then
        sysctl -p "$SYSCTL_CONFIG" >/dev/null || log "Zram sysctl 恢复后部分参数应用失败" "warn"
    fi
    restore_sysctl_values "$STATE_DIR/zram.${runtime_scope}-runtime"
    if [[ -f "$SYSTEM_TUNING_CONFIG" ]]; then
        sysctl -p "$SYSTEM_TUNING_CONFIG" >/dev/null || log "系统 sysctl 恢复后部分参数应用失败" "warn"
    fi
    restore_sysctl_values "$STATE_DIR/system-tuning.${runtime_scope}-runtime"

    if [[ -e "$SYSFS_ROOT/kernel/mm/transparent_hugepage/enabled" &&
        -f "$STATE_DIR/thp-enabled.${runtime_scope}-runtime" ]]; then
        thp_value=$(cat "$STATE_DIR/thp-enabled.${runtime_scope}-runtime" 2>/dev/null || true)
        if [[ -n "$thp_value" ]] &&
            ! printf '%s\n' "$thp_value" > "$SYSFS_ROOT/kernel/mm/transparent_hugepage/enabled"; then
            log "THP enabled 运行值恢复失败" "warn"
            failed=true
        fi
    fi
    if [[ -e "$SYSFS_ROOT/kernel/mm/transparent_hugepage/defrag" &&
        -f "$STATE_DIR/thp-defrag.${runtime_scope}-runtime" ]]; then
        thp_value=$(cat "$STATE_DIR/thp-defrag.${runtime_scope}-runtime" 2>/dev/null || true)
        if [[ -n "$thp_value" ]] &&
            ! printf '%s\n' "$thp_value" > "$SYSFS_ROOT/kernel/mm/transparent_hugepage/defrag"; then
            log "THP defrag 运行值恢复失败" "warn"
            failed=true
        fi
    fi

    if ! systemctl restart systemd-journald; then
        log "journald 重启失败" "warn"
        failed=true
    fi

    if [[ "$failed" == "true" ]]; then
        log "系统配置恢复部分失败；备份与运行快照已保留，未清除" "error"
        return 2
    fi
    if [[ "$unknown" == "true" ]]; then
        log "部分配置缺少可信的 $scope 状态，已跳过" "warn"
        return 2
    fi

    log "系统配置已恢复到 $scope 状态；linux-setup-disable-zswap.service 未自动启动；Zram 设备大小将在下次安全重启后完全按恢复配置生效" "success"
}

# === 时区配置 ===
setup_timezone() {
    local current_tz
    local choice
    local target_tz
    local -A tz_map=(
        [1]="$DEFAULT_TIMEZONE"
        [2]="UTC"
        [3]="Asia/Tokyo"
        [4]="Europe/London"
        [5]="America/New_York"
    )

    current_tz=$(timedatectl show --property=Timezone --value 2>/dev/null || true)
    current_tz="${current_tz:-未知}"

    read -r -p \
        "时区设置 [1=上海 2=UTC 3=东京 4=伦敦 5=纽约 6=自定义 7=保持当前]（默认 1）: " \
        choice </dev/tty
    choice="${choice:-1}"

    case "$choice" in
        [1-5])
            target_tz="${tz_map[$choice]}"
            ;;
        6)
            read -r -p \
                "输入时区（如 Asia/Shanghai，默认 ${DEFAULT_TIMEZONE}）: " \
                target_tz </dev/tty
            target_tz="${target_tz:-$DEFAULT_TIMEZONE}"

            if ! timedatectl list-timezones | grep -Fxq "$target_tz"; then
                log "无效时区，使用默认时区：${DEFAULT_TIMEZONE}" "warn"
                target_tz="$DEFAULT_TIMEZONE"
            fi
            ;;
        7)
            echo "时区: ${current_tz}（保持不变）"
            return 0
            ;;
        *)
            log "无效选择，使用默认时区：${DEFAULT_TIMEZONE}" "warn"
            target_tz="$DEFAULT_TIMEZONE"
            ;;
    esac

    if [[ "$current_tz" != "$target_tz" ]]; then
        if ! timedatectl set-timezone "$target_tz"; then
            log "设置时区失败" "error"
            return 1
        fi
    fi

    echo "时区: $target_tz"
}

# === Chrony 时间同步 ===
disable_timesyncd() {
    systemctl disable --now systemd-timesyncd >/dev/null 2>&1 || true
}

setup_chrony() {
    local sync_status
    local sources

    if systemctl is-active --quiet chrony; then
        disable_timesyncd

        sync_status=$(chronyc tracking 2>/dev/null |
            awk -F': ' '/Leap status/ {print $2}')

        if [[ "$sync_status" == "Normal" ]]; then
            echo "时间同步: Chrony（已同步）"
        else
            echo "时间同步: Chrony（运行中，等待同步）"
        fi

        return 0
    fi

    if ! command -v chronyd >/dev/null 2>&1; then
        log "安装 Chrony..." "info"

        if ! apt-get install -y chrony; then
            log "Chrony 安装失败，保留 systemd-timesyncd 状态不变" "error"
            return 1
        fi
    fi

    if ! systemctl enable --now chrony; then
        log "Chrony 启动失败，保留 systemd-timesyncd 状态不变" "error"
        return 1
    fi

    if ! systemctl is-active --quiet chrony; then
        log "Chrony 未处于运行状态" "error"
        return 1
    fi

    disable_timesyncd
    sleep 2

    sources=$(chronyc sources 2>/dev/null |
        awk '/^[\^\*\+\-]/ {count++} END {print count + 0}')

    echo "时间同步: Chrony（${sources} 个时间源）"
}

# === 主流程 ===
main() {
    local action="${1:-install}"
    local restore_scope="${2:-previous}"

    if (( EUID != 0 )); then
        log "需要 root 权限运行" "error"
        exit 1
    fi

    local command_name
    for command_name in apt-cache apt-get awk depmod dpkg dpkg-query fuser modprobe \
        swapon systemctl timedatectl uname cp install dirname sysctl cmp; do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            log "缺少必要命令: $command_name" "error"
            exit 1
        fi
    done

    export SYSTEMD_PAGER=""
    export PAGER=""

    if [[ "$action" == "restore" ]]; then
        if (( $# > 2 )); then
            log "用法：system-optimize.sh restore [initial]" "error"
            exit 1
        fi
        case "$restore_scope" in previous|initial) ;; *)
            log "恢复范围必须是 previous 或 initial" "error"
            exit 1
        esac
        restore_system_configs "$restore_scope"
        return
    fi
    if [[ "$action" != "install" ]]; then
        log "未知命令：$action" "error"
        exit 1
    fi

    wait_for_apt || exit 1
    install -d -m 0700 "$STATE_DIR"
    backup_system_configs || {
        log "系统配置备份失败，拒绝继续修改" "error"
        exit 1
    }

    log "🔧 智能系统优化配置..." "info"

    local degraded=false

    echo
    setup_zram || { log "Zram 配置失败，继续执行后续项目" "warn"; degraded=true; }

    echo
    setup_system_tuning || { log "系统 sysctl 调优失败" "warn"; degraded=true; }
    setup_journald_limits || { log "journald 限额配置失败" "warn"; degraded=true; }
    setup_thp_policy || { log "THP 策略配置失败" "warn"; degraded=true; }

    echo
    setup_timezone || { log "时区配置失败，继续执行后续项目" "warn"; degraded=true; }

    echo
    setup_chrony || { log "Chrony 时间同步配置失败" "warn"; degraded=true; }

    echo
    if [[ "$degraded" == "true" ]]; then
        log "系统优化部分完成" "warn"
        return 2
    fi

    log "✅ 系统优化完成" "info"

    if [[ "${DEBUG:-}" == "1" ]]; then
        echo
        log "=== 当前系统状态 ===" "debug"
        free -h
        swapon --show 2>/dev/null || true
        echo "swappiness: $(cat /proc/sys/vm/swappiness 2>/dev/null || echo "unknown")"
        timedatectl status 2>/dev/null || true
        chronyc tracking 2>/dev/null || true
    fi
}

# 被 source 时只加载常量与函数，不注册 ERR trap、不执行 main。
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    if [[ "${LINUX_SETUP_TEST_MODE:-}" == "1" ]]; then
        log "测试模式禁止执行生产主流程：$0" "error"
        exit 1
    fi

    trap 'exit_code=$?; (( exit_code == 2 )) || log "系统优化脚本在第 $LINENO 行执行失败" "error"' ERR

    main "$@"
fi
