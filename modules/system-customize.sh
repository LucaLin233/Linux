#!/usr/bin/env bash
# linux-setup:name=系统定制（欢迎信息、中文环境、XanMod 内核）
# linux-setup:order=20
# linux-setup:depends=
# linux-setup:enabled=true
# 系统定制模块
# 功能：配置动态欢迎信息、中文 Locale，并可选安装 XanMod 内核
#
# 用法：
#   bash system-customize.sh           # 交互执行全部功能
#   bash system-customize.sh motd      # 仅配置欢迎信息
#   bash system-customize.sh locale    # 仅配置中文环境
#   bash system-customize.sh xanmod    # 仅配置 XanMod 内核
#   bash system-customize.sh status    # 查看 XanMod 状态
#   bash system-customize.sh restore   # 恢复上一次运行前的配置
#   bash system-customize.sh restore initial
#                                      # 恢复首次运行前的可信配置

set -euo pipefail

# === 常量定义 ===
# === MOTD group transaction ===
if [[ "${MOTD_TEST_MODE:-0}" == "1" ]]; then
    MOTD_ETC_ROOT="${MOTD_ETC_ROOT:-/etc}"
    MOTD_STATE_DIR="${MOTD_STATE_DIR:-/var/lib/linux-setup/motd-backups}"
    MOTD_LOCK_FILE="${MOTD_LOCK_FILE:-/run/lock/linux-setup-motd.lock}"
    MOTD_TRANSACTION_PARENT="${MOTD_TRANSACTION_PARENT:-$MOTD_STATE_DIR/transactions}"
    MOTD_TRUSTED_UID=$EUID
    MOTD_TRUSTED_GID=$(id -g)
else
    MOTD_ETC_ROOT=/etc
    MOTD_STATE_DIR=/var/lib/linux-setup/motd-backups
    MOTD_LOCK_FILE=/run/lock/linux-setup-motd.lock
    MOTD_TRANSACTION_PARENT="$MOTD_STATE_DIR/transactions"
    MOTD_TRUSTED_UID=0
    MOTD_TRUSTED_GID=0
fi
readonly MOTD_ETC_ROOT MOTD_STATE_DIR MOTD_LOCK_FILE MOTD_TRANSACTION_PARENT MOTD_TRUSTED_UID MOTD_TRUSTED_GID
readonly MOTD_SCRIPT="$MOTD_ETC_ROOT/update-motd.d/00-custom-welcome"
readonly MOTD_SNAPSHOT_VERSION=1
readonly MOTD_PAYLOAD_SHA256="cf2a4f8dfe2fe26bff5509cdaee56d9e0816fafd0594251b02e892201af5c4d5"
readonly -a MOTD_TARGET_IDS=(motd issue issue_net custom_welcome uname motd_news)
readonly -a MOTD_TARGET_PATHS=(
    "$MOTD_ETC_ROOT/motd" "$MOTD_ETC_ROOT/issue" "$MOTD_ETC_ROOT/issue.net"
    "$MOTD_SCRIPT" "$MOTD_ETC_ROOT/update-motd.d/10-uname" "$MOTD_ETC_ROOT/update-motd.d/50-motd-news"
)
declare -gA MOTD_PATH_BY_ID=()
declare -gA MOTD_SNAPSHOT_STATE=() MOTD_SNAPSHOT_UID=() MOTD_SNAPSHOT_GID=() MOTD_SNAPSHOT_MODE=()
declare -gA MOTD_SNAPSHOT_ATIME=() MOTD_SNAPSHOT_MTIME=() MOTD_SNAPSHOT_DIGEST=() MOTD_SNAPSHOT_LINK=()
declare -gA MOTD_TARGET_ACTION=() MOTD_TARGET_STAGE=()
declare -gA MOTD_STAGE_DEV=() MOTD_STAGE_INO=() MOTD_STAGE_TYPE=() MOTD_STAGE_UID=() MOTD_STAGE_GID=()
declare -gA MOTD_STAGE_MODE=() MOTD_STAGE_DIGEST=() MOTD_STAGE_LINK=() MOTD_STAGE_ATIME=() MOTD_STAGE_MTIME=()
declare -gA MOTD_DELETE_DEV=() MOTD_DELETE_INO=() MOTD_DELETE_TYPE=() MOTD_DELETE_LINK=()
for MOTD_INDEX in "${!MOTD_TARGET_IDS[@]}"; do
    MOTD_PATH_BY_ID["${MOTD_TARGET_IDS[$MOTD_INDEX]}"]="${MOTD_TARGET_PATHS[$MOTD_INDEX]}"
done
unset MOTD_INDEX

MOTD_LOCK_FD=""
MOTD_LOCK_HELD=false
MOTD_STATE_DIR_CREATED=false
MOTD_TRANSACTION_ACTIVE=false
MOTD_TRANSACTION_COMMITTED=false
MOTD_ROLLBACK_MODE=false
MOTD_TRANSACTION_LIFECYCLE=none
MOTD_TRANSACTION_ID=""
MOTD_TRANSACTION_OPERATION=""
MOTD_TRANSACTION_BUILDING_PATH=""
MOTD_TRANSACTION_FINAL_PATH=""
MOTD_TRANSACTION_DIR=""
MOTD_INITIAL_OLD=absent
MOTD_PREVIOUS_OLD=absent
MOTD_INITIAL_NEW=-
MOTD_PREVIOUS_NEW=-
MOTD_RESTORED_COUNT=0
MOTD_LAST_GENERATION=""
MOTD_SAVED_TRAP_EXIT=""
MOTD_SAVED_TRAP_HUP=""
MOTD_SAVED_TRAP_INT=""
MOTD_SAVED_TRAP_TERM=""
MOTD_LEGACY_KIND=""
MOTD_LEGACY_PATH=""
MOTD_LEGACY_UID=""
MOTD_LEGACY_GID=""
MOTD_LEGACY_MODE=""
MOTD_LEGACY_ATIME=""
MOTD_LEGACY_MTIME=""
MOTD_LEGACY_DEV=""
MOTD_LEGACY_INO=""
MOTD_LEGACY_FD=""
MOTD_CLEANUP_FAILURES=()
MOTD_SNAPSHOT_BUILDING_PATHS=()
MOTD_SNAPSHOT_FINAL_PATHS=()
MOTD_POINTER_STAGE_PATHS=()
MOTD_PENDING_STAGE_PATHS=()
MOTD_NEW_GENERATIONS=()
MOTD_ALL_TARGET_STAGE_PATHS=()

motd_lock_acquired_hook() { :; }
motd_state_directory_created_hook() { :; }
motd_lock_open_hook() { :; }
motd_lock_close_hook() { :; }
motd_snapshot_capture_hook() { :; }
motd_snapshot_manifest_hook() { :; }
motd_snapshot_commit_hook() { :; }
motd_legacy_io_hook() { :; }
motd_cleanup_path_hook() { :; }
motd_target_commit_hook() { :; }
motd_rollback_hook() { :; }
motd_transaction_phase_hook() { :; }
motd_preview_hook() { "$MOTD_SCRIPT"; }

motd_random_id() {
    local value
    value=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n') || return 1
    [[ "$value" =~ ^[0-9a-f]{32}$ ]] || return 1
    printf '%s\n' "$value"
}

motd_path_parent() {
    local path="$1"
    [[ "$path" == */* ]] || return 1
    path=${path%/*}
    [[ -n "$path" ]] || path=/
    printf '%s\n' "$path"
}

motd_array_add() {
    local array_name="$1" value="$2"
    local -n target_array="$array_name"
    target_array+=("$value")
}

motd_array_remove_value() {
    local array_name="$1" value="$2" item
    local -n source_array="$array_name"
    local -a kept=()
    for item in "${source_array[@]}"; do [[ "$item" == "$value" ]] || kept+=("$item"); done
    source_array=("${kept[@]}")
}

motd_any_tracked_transient() {
    local item
    [[ -n "$MOTD_TRANSACTION_BUILDING_PATH" || -n "$MOTD_TRANSACTION_FINAL_PATH" || -n "$MOTD_TRANSACTION_DIR" ]] && return 0
    for item in "${MOTD_SNAPSHOT_BUILDING_PATHS[@]}" "${MOTD_POINTER_STAGE_PATHS[@]}" "${MOTD_PENDING_STAGE_PATHS[@]}" "${MOTD_ALL_TARGET_STAGE_PATHS[@]}"; do
        [[ -n "$item" ]] && return 0
    done
    return 1
}

motd_validate_ancestor_directory() {
    local path="$1" metadata owner gid mode mode_value
    [[ -d "$path" && ! -L "$path" ]] || return 1
    metadata=$(stat -c '%u:%g:%a' -- "$path" 2>/dev/null) || return 1
    IFS=: read -r owner gid mode <<< "$metadata"
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    mode_value=$((8#$mode))
    if [[ "$owner" != 0 ]]; then
        [[ "${MOTD_TEST_MODE:-0}" == 1 && "$owner" == "$MOTD_TRUSTED_UID" && "$gid" == "$MOTD_TRUSTED_GID" ]] || return 1
    elif [[ "$gid" != 0 && "${MOTD_TEST_MODE:-0}" != 1 ]]; then
        return 1
    fi
    if (( (mode_value & 0002) != 0 )); then (( (mode_value & 01000) != 0 && owner == 0 )) || return 1; fi
    if (( (mode_value & 0020) != 0 )); then [[ "$owner" == 0 && "$gid" == 0 ]] || return 1; fi
}

motd_validate_directory_chain() {
    local path="$1" current=/ component
    local -a components=()
    [[ "$path" == /* ]] || return 1
    IFS=/ read -r -a components <<< "${path#/}"
    motd_validate_ancestor_directory / || return 1
    for component in "${components[@]}"; do
        [[ -n "$component" && "$component" != . && "$component" != .. ]] || continue
        [[ "$current" == / ]] && current="/$component" || current="$current/$component"
        [[ -e "$current" || -L "$current" ]] || return 1
        motd_validate_ancestor_directory "$current" || return 1
    done
}

motd_ensure_parent_chain() {
    local path="$1" parent current=/ component
    local -a components=()
    parent=$(motd_path_parent "$path") || return 1
    IFS=/ read -r -a components <<< "${parent#/}"
    motd_validate_ancestor_directory / || return 1
    for component in "${components[@]}"; do
        [[ -n "$component" && "$component" != . && "$component" != .. ]] || continue
        [[ "$current" == / ]] && current="/$component" || current="$current/$component"
        if [[ ! -e "$current" && ! -L "$current" ]]; then
            mkdir -m 0700 -- "$current" || return 1
            chown "$MOTD_TRUSTED_UID:$MOTD_TRUSTED_GID" "$current" || return 1
        fi
        motd_validate_ancestor_directory "$current" || return 1
    done
}

motd_validate_secure_directory() {
    local path="$1" metadata owner gid mode
    [[ -d "$path" && ! -L "$path" ]] || return 1
    metadata=$(stat -c '%u:%g:%a' -- "$path" 2>/dev/null) || return 1
    IFS=: read -r owner gid mode <<< "$metadata"
    [[ "$owner" == "$MOTD_TRUSTED_UID" && "$gid" == "$MOTD_TRUSTED_GID" && "$mode" == 700 ]]
}

motd_validate_secure_file() {
    local path="$1" metadata owner gid mode
    [[ -f "$path" && ! -L "$path" ]] || return 1
    metadata=$(stat -c '%u:%g:%a' -- "$path" 2>/dev/null) || return 1
    IFS=: read -r owner gid mode <<< "$metadata"
    [[ "$owner" == "$MOTD_TRUSTED_UID" && "$gid" == "$MOTD_TRUSTED_GID" && "$mode" == 600 ]]
}

motd_ensure_secure_directory() {
    local path="$1"
    motd_ensure_parent_chain "$path" || return 1
    if [[ ! -e "$path" && ! -L "$path" ]]; then
        mkdir -m 0700 -- "$path" || return 1
        chown "$MOTD_TRUSTED_UID:$MOTD_TRUSTED_GID" "$path" || return 1
    fi
    motd_validate_secure_directory "$path"
}

motd_take_lock() {
    local parent before fd_meta after owner gid mode dev inode
    [[ "$MOTD_LOCK_HELD" == false ]] || return 1
    parent=$(motd_path_parent "$MOTD_LOCK_FILE") || return 1
    motd_validate_directory_chain "$parent" || { error "MOTD 锁父目录不可信: $parent"; return 1; }
    if [[ ! -e "$MOTD_LOCK_FILE" && ! -L "$MOTD_LOCK_FILE" ]]; then
        (umask 077; set -o noclobber; : > "$MOTD_LOCK_FILE") 2>/dev/null || return 1
        chown "$MOTD_TRUSTED_UID:$MOTD_TRUSTED_GID" "$MOTD_LOCK_FILE" || return 1
        chmod 0600 "$MOTD_LOCK_FILE" || return 1
    fi
    motd_validate_secure_file "$MOTD_LOCK_FILE" || { error "MOTD 锁文件不可信: $MOTD_LOCK_FILE"; return 1; }
    before=$(stat -c '%d:%i' -- "$MOTD_LOCK_FILE") || return 1
    motd_lock_open_hook "$MOTD_LOCK_FILE" || return 1
    { exec {MOTD_LOCK_FD}<>"$MOTD_LOCK_FILE"; } 2>/dev/null || return 1
    [[ -f "/proc/$BASHPID/fd/$MOTD_LOCK_FD" ]] || { exec {MOTD_LOCK_FD}>&- || true; return 1; }
    fd_meta=$(stat -Lc '%u:%g:%a:%d:%i' -- "/proc/$BASHPID/fd/$MOTD_LOCK_FD") || { exec {MOTD_LOCK_FD}>&- || true; return 1; }
    IFS=: read -r owner gid mode dev inode <<< "$fd_meta"
    after=$(stat -c '%d:%i' -- "$MOTD_LOCK_FILE" 2>/dev/null) || after=""
    if [[ "$owner" != "$MOTD_TRUSTED_UID" || "$gid" != "$MOTD_TRUSTED_GID" || "$mode" != 600 || "$dev:$inode" != "$before" || "$after" != "$before" ]]; then
        error "MOTD 锁文件在检查和打开间被替换"
        exec {MOTD_LOCK_FD}>&- || true
        MOTD_LOCK_FD=""
        return 1
    fi
    flock -n "$MOTD_LOCK_FD" || { error "已有 MOTD install/restore 正在运行"; exec {MOTD_LOCK_FD}>&- || true; MOTD_LOCK_FD=""; return 1; }
    MOTD_LOCK_HELD=true
    motd_lock_acquired_hook "$MOTD_LOCK_FILE" || { motd_release_lock || true; return 1; }
}

motd_release_lock() {
    local failed=false
    [[ "$MOTD_LOCK_HELD" == true ]] || return 0
    flock -u "$MOTD_LOCK_FD" || { error "释放 MOTD 锁失败"; failed=true; }
    motd_lock_close_hook "$MOTD_LOCK_FD" || { error "关闭 MOTD 锁 fd 失败"; failed=true; }
    exec {MOTD_LOCK_FD}>&- || { error "关闭 MOTD 锁 fd 失败"; failed=true; }
    MOTD_LOCK_FD=""
    MOTD_LOCK_HELD=false
    [[ "$failed" == false ]]
}

motd_snapshot_object_path() { printf '%s/objects/%s\n' "$1" "$2"; }

motd_reset_snapshot_metadata() {
    MOTD_SNAPSHOT_STATE=(); MOTD_SNAPSHOT_UID=(); MOTD_SNAPSHOT_GID=(); MOTD_SNAPSHOT_MODE=()
    MOTD_SNAPSHOT_ATIME=(); MOTD_SNAPSHOT_MTIME=(); MOTD_SNAPSHOT_DIGEST=(); MOTD_SNAPSHOT_LINK=()
}

motd_validate_snapshot() {
    local directory="$1" expected_scope="$2" expected_generation="${3:-}"
    local manifest line key scope="" generation="" id state uid gid mode atime mtime digest extra object actual metadata
    local line_number=0 target_index=0
    motd_validate_secure_directory "$directory" || return 1
    motd_validate_secure_directory "$directory/objects" || return 1
    manifest="$directory/manifest"
    motd_validate_secure_file "$manifest" || return 1
    motd_reset_snapshot_metadata
    while IFS= read -r line || [[ -n "$line" ]]; do
        ((line_number += 1))
        case "$line_number" in
            1) [[ "$line" == "version=$MOTD_SNAPSHOT_VERSION" ]] || return 1 ;;
            2) [[ "$line" == scope=* ]] || return 1; scope=${line#scope=}; [[ "$scope" == "$expected_scope" ]] || return 1 ;;
            3) [[ "$line" == generation=* ]] || return 1; generation=${line#generation=}; [[ "$generation" =~ ^[0-9a-f]{32}$ ]] || return 1; [[ -z "$expected_generation" || "$generation" == "$expected_generation" ]] || return 1 ;;
            *)
                IFS='|' read -r key id state uid gid mode atime mtime digest extra <<< "$line"
                [[ "$key" == target && -z "$extra" && "$id" == "${MOTD_TARGET_IDS[$target_index]:-}" ]] || return 1
                object=$(motd_snapshot_object_path "$directory" "$id") || return 1
                case "$state" in
                    regular)
                        [[ "$uid" =~ ^[0-9]+$ && "$gid" =~ ^[0-9]+$ && "$mode" =~ ^[0-7]{3,4}$ && "$atime" =~ ^[0-9]+$ && "$mtime" =~ ^[0-9]+$ && "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
                        motd_validate_secure_file "$object" || return 1
                        actual=$(sha256sum "$object") || return 1
                        [[ "${actual%% *}" == "$digest" ]] || return 1
                        ;;
                    symlink)
                        [[ "$uid$gid$mode$atime$mtime$digest" == ------ && -L "$object" ]] || return 1
                        metadata=$(stat -c '%u:%g' -- "$object") || return 1
                        [[ "$metadata" == "$MOTD_TRUSTED_UID:$MOTD_TRUSTED_GID" ]] || return 1
                        MOTD_SNAPSHOT_LINK[$id]=$(readlink -- "$object") || return 1
                        ;;
                    absent)
                        [[ "$uid$gid$mode$atime$mtime$digest" == ------ && ! -e "$object" && ! -L "$object" ]] || return 1
                        ;;
                    unknown)
                        [[ "$expected_scope" == initial && "$uid$gid$mode$atime$mtime$digest" == ------ && ! -e "$object" && ! -L "$object" ]] || return 1
                        ;;
                    *) return 1 ;;
                esac
                MOTD_SNAPSHOT_STATE[$id]=$state
                MOTD_SNAPSHOT_UID[$id]=$uid; MOTD_SNAPSHOT_GID[$id]=$gid; MOTD_SNAPSHOT_MODE[$id]=$mode
                MOTD_SNAPSHOT_ATIME[$id]=$atime; MOTD_SNAPSHOT_MTIME[$id]=$mtime; MOTD_SNAPSHOT_DIGEST[$id]=$digest
                ((target_index += 1))
                ;;
        esac
    done < "$manifest"
    [[ "$line_number" == 9 && "$target_index" == 6 ]]
}

motd_target_configuration_is_managed() {
    [[ -f "$MOTD_SCRIPT" && ! -L "$MOTD_SCRIPT" ]] || return 1
    grep -Eq '# linux-setup:managed-motd|由 (system-customize|setup-motd)\.sh 自动生成' "$MOTD_SCRIPT"
}

motd_append_captured_target() {
    local source="$1" id="$2" directory="$3" manifest="$4" force_unknown="$5"
    local object metadata uid gid mode atime mtime dev inode before after digest link
    object=$(motd_snapshot_object_path "$directory" "$id") || return 1
    motd_snapshot_capture_hook "$id" "$source" || return 1
    if [[ "$force_unknown" == true ]]; then printf 'target|%s|unknown|-|-|-|-|-|-\n' "$id" >> "$manifest" || return 1; return 0; fi
    if [[ -L "$source" ]]; then
        link=$(readlink -- "$source") || return 1
        ln -s -- "$link" "$object" || return 1
        printf 'target|%s|symlink|-|-|-|-|-|-\n' "$id" >> "$manifest" || return 1
        return 0
    fi
    if [[ -f "$source" ]]; then
        metadata=$(stat -c '%u:%g:%a:%X:%Y:%d:%i' -- "$source") || return 1
        IFS=: read -r uid gid mode atime mtime dev inode <<< "$metadata"
        before="$dev:$inode"
        (umask 077; set -o noclobber; : > "$object") 2>/dev/null || return 1
        cat -- "$source" > "$object" || return 1
        chown "$MOTD_TRUSTED_UID:$MOTD_TRUSTED_GID" "$object" || return 1
        chmod 0600 "$object" || return 1
        after=$(stat -c '%d:%i' -- "$source" 2>/dev/null) || return 1
        [[ "$after" == "$before" ]] || return 1
        digest=$(sha256sum "$object") || return 1
        printf 'target|%s|regular|%s|%s|%s|%s|%s|%s\n' "$id" "$uid" "$gid" "$mode" "$atime" "$mtime" "${digest%% *}" >> "$manifest" || return 1
        return 0
    fi
    if [[ ! -e "$source" ]]; then printf 'target|%s|absent|-|-|-|-|-|-\n' "$id" >> "$manifest" || return 1; return 0; fi
    error "MOTD 目标类型不支持: $source"
    return 1
}

motd_capture_snapshot_to_dir() {
    local directory="$1" scope="$2" generation="$3" force_unknown="${4:-false}" manifest id path
    mkdir -m 0700 -- "$directory" || return 1
    chown "$MOTD_TRUSTED_UID:$MOTD_TRUSTED_GID" "$directory" || return 1
    mkdir -m 0700 -- "$directory/objects" || return 1
    chown "$MOTD_TRUSTED_UID:$MOTD_TRUSTED_GID" "$directory/objects" || return 1
    manifest="$directory/manifest"
    (umask 077; set -o noclobber; : > "$manifest") 2>/dev/null || return 1
    chown "$MOTD_TRUSTED_UID:$MOTD_TRUSTED_GID" "$manifest" || return 1
    chmod 0600 "$manifest" || return 1
    printf 'version=%s\nscope=%s\ngeneration=%s\n' "$MOTD_SNAPSHOT_VERSION" "$scope" "$generation" > "$manifest" || return 1
    for id in "${MOTD_TARGET_IDS[@]}"; do
        path=${MOTD_PATH_BY_ID[$id]}
        motd_append_captured_target "$path" "$id" "$directory" "$manifest" "$force_unknown" || return 1
    done
    motd_snapshot_manifest_hook "$scope" "$manifest" || return 1
    motd_validate_snapshot "$directory" "$scope" "$generation"
}

motd_open_legacy_regular() {
    local path="$1" metadata owner gid mode atime mtime dev inode path_identity fd_meta after fd_mode_hex parent
    parent=$(motd_path_parent "$path") || return 1
    motd_validate_directory_chain "$parent" || return 1
    [[ -f "$path" && ! -L "$path" ]] || return 1
    motd_legacy_io_hook stat "$path" || return 1
    metadata=$(stat -c '%u:%g:%a:%X:%Y:%d:%i' -- "$path") || return 1
    IFS=: read -r owner gid mode atime mtime dev inode <<< "$metadata"
    [[ "$owner" == "$MOTD_TRUSTED_UID" && "$gid" == "$MOTD_TRUSTED_GID" && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$mode & 0022) == 0 )) || return 1
    path_identity="$dev:$inode"
    motd_legacy_io_hook open "$path" || return 1
    { exec {MOTD_LEGACY_FD}<"$path"; } 2>/dev/null || return 1
    [[ -f "/proc/$BASHPID/fd/$MOTD_LEGACY_FD" ]] || { exec {MOTD_LEGACY_FD}>&- || true; MOTD_LEGACY_FD=""; return 1; }
    fd_meta=$(stat -Lc '%u:%g:%a:%d:%i:%f' -- "/proc/$BASHPID/fd/$MOTD_LEGACY_FD") || { exec {MOTD_LEGACY_FD}>&- || true; MOTD_LEGACY_FD=""; return 1; }
    IFS=: read -r owner gid mode dev inode fd_mode_hex <<< "$fd_meta"
    (( (16#$fd_mode_hex & 0170000) == 0100000 )) || { exec {MOTD_LEGACY_FD}>&- || true; MOTD_LEGACY_FD=""; return 1; }
    after=$(stat -c '%d:%i' -- "$path" 2>/dev/null) || after=""
    if [[ "$owner" != "$MOTD_TRUSTED_UID" || "$gid" != "$MOTD_TRUSTED_GID" || "$dev:$inode" != "$path_identity" || "$after" != "$path_identity" ]]; then
        exec {MOTD_LEGACY_FD}>&- || true
        MOTD_LEGACY_FD=""
        return 1
    fi
    MOTD_LEGACY_UID=$owner; MOTD_LEGACY_GID=$gid; MOTD_LEGACY_MODE=${metadata#*:*:}; MOTD_LEGACY_MODE=${MOTD_LEGACY_MODE%%:*}
    MOTD_LEGACY_ATIME=$atime; MOTD_LEGACY_MTIME=$mtime; MOTD_LEGACY_DEV=$dev; MOTD_LEGACY_INO=$inode
}

motd_close_legacy_fd() {
    [[ -n "$MOTD_LEGACY_FD" ]] || return 0
    exec {MOTD_LEGACY_FD}>&- || return 1
    MOTD_LEGACY_FD=""
}

motd_legacy_prefixes_for_id() {
    local path=${MOTD_PATH_BY_ID[$1]}
    printf '%s\n%s/%s\n' "$path" "$MOTD_STATE_DIR" "$(basename "$path")"
}

motd_find_legacy_state() {
    local id="$1" scope="$2" prefix suffix candidate count=0
    MOTD_LEGACY_KIND=""; MOTD_LEGACY_PATH=""
    while IFS= read -r prefix; do
        for suffix in backup absent unknown; do
            [[ "$suffix" == unknown && "$scope" != initial ]] && continue
            candidate="${prefix}.${scope}-${suffix}"
            [[ -e "$candidate" || -L "$candidate" ]] || continue
            ((count += 1)); MOTD_LEGACY_KIND=$suffix; MOTD_LEGACY_PATH=$candidate
        done
    done < <(motd_legacy_prefixes_for_id "$id")
    (( count == 1 )) || { (( count == 0 )) && return 2; error "legacy MOTD 状态冲突: $id/$scope"; return 1; }
}

motd_validate_legacy_symlink() {
    local path="$1" parent metadata owner gid
    parent=$(motd_path_parent "$path") || return 1
    motd_validate_directory_chain "$parent" || return 1
    [[ -L "$path" ]] || return 1
    metadata=$(stat -c '%u:%g' -- "$path") || return 1
    IFS=: read -r owner gid <<< "$metadata"
    [[ "$owner" == "$MOTD_TRUSTED_UID" && "$gid" == "$MOTD_TRUSTED_GID" ]]
}

motd_validate_legacy_marker() {
    local path="$1" metadata owner gid mode
    local parent
    parent=$(motd_path_parent "$path") || return 1
    motd_validate_directory_chain "$parent" || return 1
    [[ -f "$path" && ! -L "$path" ]] || return 1
    metadata=$(stat -c '%u:%g:%a' -- "$path") || return 1
    IFS=: read -r owner gid mode <<< "$metadata"
    [[ "$owner" == "$MOTD_TRUSTED_UID" && "$gid" == "$MOTD_TRUSTED_GID" && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$mode & 0022) == 0 ))
}

motd_append_legacy_target() {
    local id="$1" kind="$2" path="$3" directory="$4" manifest="$5" object link digest path_after fd_after
    object=$(motd_snapshot_object_path "$directory" "$id") || return 1
    case "$kind" in
        backup)
            if [[ -L "$path" ]]; then
                motd_validate_legacy_symlink "$path" || return 1
                link=$(readlink -- "$path") || return 1
                ln -s -- "$link" "$object" || return 1
                printf 'target|%s|symlink|-|-|-|-|-|-\n' "$id" >> "$manifest" || return 1
            else
                motd_open_legacy_regular "$path" || return 1
                motd_legacy_io_hook create "$object" || { motd_close_legacy_fd || true; return 1; }
                (umask 077; set -o noclobber; : > "$object") 2>/dev/null || { motd_close_legacy_fd || true; return 1; }
                motd_legacy_io_hook cat "$path" || { motd_close_legacy_fd || true; return 1; }
                cat "/proc/$BASHPID/fd/$MOTD_LEGACY_FD" > "$object" || { motd_close_legacy_fd || true; return 1; }
                path_after=$(stat -c '%d:%i' -- "$path" 2>/dev/null) || { motd_close_legacy_fd || true; return 1; }
                fd_after=$(stat -Lc '%d:%i' -- "/proc/$BASHPID/fd/$MOTD_LEGACY_FD") || { motd_close_legacy_fd || true; return 1; }
                [[ "$path_after" == "$MOTD_LEGACY_DEV:$MOTD_LEGACY_INO" && "$fd_after" == "$path_after" ]] || { motd_close_legacy_fd || true; return 1; }
                motd_close_legacy_fd || return 1
                motd_legacy_io_hook chown "$object" || return 1
                chown "$MOTD_TRUSTED_UID:$MOTD_TRUSTED_GID" "$object" || return 1
                motd_legacy_io_hook chmod "$object" || return 1
                chmod 0600 "$object" || return 1
                motd_legacy_io_hook sha256 "$object" || return 1
                digest=$(sha256sum "$object") || return 1
                motd_legacy_io_hook manifest "$manifest" || return 1
                printf 'target|%s|regular|%s|%s|%s|%s|%s|%s\n' "$id" "$MOTD_LEGACY_UID" "$MOTD_LEGACY_GID" "$MOTD_LEGACY_MODE" "$MOTD_LEGACY_ATIME" "$MOTD_LEGACY_MTIME" "${digest%% *}" >> "$manifest" || return 1
            fi
            ;;
        absent|unknown)
            motd_validate_legacy_marker "$path" || return 1
            printf 'target|%s|%s|-|-|-|-|-|-\n' "$id" "$kind" >> "$manifest" || return 1
            ;;
        *) return 1 ;;
    esac
}

motd_create_persistent_snapshot() {
    local scope="$1" force_unknown="${2:-false}" generation stage final
    generation=$(motd_random_id) || return 1
    stage="$MOTD_STATE_DIR/generations/.${generation}.stage"
    final="$MOTD_STATE_DIR/generations/$generation"
    motd_array_add MOTD_SNAPSHOT_BUILDING_PATHS "$stage"
    motd_array_add MOTD_SNAPSHOT_FINAL_PATHS "$final"
    MOTD_LAST_GENERATION=$generation
    [[ ! -e "$stage" && ! -L "$stage" && ! -e "$final" && ! -L "$final" ]] || return 1
    motd_capture_snapshot_to_dir "$stage" "$scope" "$generation" "$force_unknown" || return 1
    motd_snapshot_commit_hook "$scope" "$generation" directory || return 1
    motd_validate_snapshot "$stage" "$scope" "$generation" || return 1
    mv -T -- "$stage" "$final" || return 1
    motd_validate_snapshot "$final" "$scope" "$generation" || return 1
    motd_array_remove_value MOTD_SNAPSHOT_BUILDING_PATHS "$stage"
    MOTD_NEW_GENERATIONS+=("$generation")
    motd_array_remove_value MOTD_SNAPSHOT_FINAL_PATHS "$final"
}

motd_import_legacy_snapshot() {
    local scope="$1" id result=0 found=0 generation
    local -A kinds=() paths=()
    for id in "${MOTD_TARGET_IDS[@]}"; do
        result=0; motd_find_legacy_state "$id" "$scope" || result=$?
        case "$result" in 0) ((found += 1)); kinds[$id]=$MOTD_LEGACY_KIND; paths[$id]=$MOTD_LEGACY_PATH ;; 2) ;; *) return 1 ;; esac
    done
    (( found > 0 )) || return 2
    (( found == 6 )) || { error "legacy MOTD $scope 状态不完整"; return 1; }
    motd_legacy_io_hook random-id "$scope" || return 1
    generation=$(motd_random_id) || return 1
    local stage="$MOTD_STATE_DIR/generations/.${generation}.stage" final="$MOTD_STATE_DIR/generations/$generation" manifest
    motd_array_add MOTD_SNAPSHOT_BUILDING_PATHS "$stage"
    motd_array_add MOTD_SNAPSHOT_FINAL_PATHS "$final"
    MOTD_LAST_GENERATION=$generation
    [[ ! -e "$stage" && ! -L "$stage" && ! -e "$final" && ! -L "$final" ]] || return 1
    mkdir -m 0700 -- "$stage" || return 1; chown "$MOTD_TRUSTED_UID:$MOTD_TRUSTED_GID" "$stage" || return 1
    mkdir -m 0700 -- "$stage/objects" || return 1; chown "$MOTD_TRUSTED_UID:$MOTD_TRUSTED_GID" "$stage/objects" || return 1
    manifest="$stage/manifest"
    (umask 077; set -o noclobber; : > "$manifest") 2>/dev/null || return 1
    chown "$MOTD_TRUSTED_UID:$MOTD_TRUSTED_GID" "$manifest" || return 1; chmod 0600 "$manifest" || return 1
    printf 'version=%s\nscope=%s\ngeneration=%s\n' "$MOTD_SNAPSHOT_VERSION" "$scope" "$generation" > "$manifest" || return 1
    for id in "${MOTD_TARGET_IDS[@]}"; do motd_append_legacy_target "$id" "${kinds[$id]}" "${paths[$id]}" "$stage" "$manifest" || return 1; done
    motd_snapshot_manifest_hook "$scope" "$manifest" || return 1
    motd_validate_snapshot "$stage" "$scope" "$generation" || return 1
    motd_snapshot_commit_hook "$scope" "$generation" legacy-directory || return 1
    motd_validate_snapshot "$stage" "$scope" "$generation" || return 1
    motd_legacy_io_hook mv "$final" || return 1
    motd_validate_snapshot "$stage" "$scope" "$generation" || return 1
    mv -T -- "$stage" "$final" || return 1
    motd_validate_snapshot "$final" "$scope" "$generation" || return 1
    motd_array_remove_value MOTD_SNAPSHOT_BUILDING_PATHS "$stage"
    MOTD_NEW_GENERATIONS+=("$generation")
    motd_array_remove_value MOTD_SNAPSHOT_FINAL_PATHS "$final"
}

motd_pointer_path() { printf '%s/%s.current\n' "$MOTD_STATE_DIR" "$1"; }

motd_read_pointer() {
    local scope="$1" pointer generation
    pointer=$(motd_pointer_path "$scope") || return 1
    motd_validate_secure_file "$pointer" || return 1
    IFS= read -r generation < "$pointer" || return 1
    [[ "$generation" =~ ^[0-9a-f]{32}$ && "$(wc -l < "$pointer")" == 1 ]] || return 1
    motd_validate_snapshot "$MOTD_STATE_DIR/generations/$generation" "$scope" "$generation" || return 1
    printf '%s\n' "$generation"
}

motd_read_pointer_or_absent() {
    local pointer
    pointer=$(motd_pointer_path "$1") || return 1
    if [[ ! -e "$pointer" && ! -L "$pointer" ]]; then printf 'absent\n'; else motd_read_pointer "$1"; fi
}

motd_allocate_file_stage() {
    local parent="$1" prefix="$2" token path
    token=$(motd_random_id) || return 1
    path="$parent/.${prefix}.${token}"
    [[ ! -e "$path" && ! -L "$path" ]] || return 1
    printf '%s\n' "$path"
}

motd_validate_single_line_stage() {
    local path="$1" expected="$2" expected_identity="$3" value identity
    motd_validate_secure_file "$path" || return 1
    identity=$(stat -c '%d:%i' -- "$path") || return 1
    [[ "$identity" == "$expected_identity" ]] || return 1
    IFS= read -r value < "$path" || return 1
    [[ "$value" == "$expected" && "$(wc -l < "$path")" == 1 ]] || return 1
}

motd_set_pointer() {
    local scope="$1" generation="$2" pointer stage stage_identity actual
    pointer=$(motd_pointer_path "$scope") || return 1
    if [[ "$generation" == absent ]]; then
        if [[ -e "$pointer" || -L "$pointer" ]]; then motd_validate_secure_file "$pointer" || return 1; rm -f -- "$pointer" || return 1; fi
        return 0
    fi
    motd_validate_snapshot "$MOTD_STATE_DIR/generations/$generation" "$scope" "$generation" || return 1
    stage=$(motd_allocate_file_stage "$MOTD_STATE_DIR" "$scope.pointer") || return 1
    motd_array_add MOTD_POINTER_STAGE_PATHS "$stage"
    (umask 077; set -o noclobber; : > "$stage") 2>/dev/null || return 1
    printf '%s\n' "$generation" > "$stage" || return 1
    chown "$MOTD_TRUSTED_UID:$MOTD_TRUSTED_GID" "$stage" || return 1
    chmod 0600 "$stage" || return 1
    stage_identity=$(stat -c '%d:%i' -- "$stage") || return 1
    if [[ "$MOTD_ROLLBACK_MODE" == false ]]; then motd_snapshot_commit_hook "$scope" "$generation" pointer || return 1; fi
    motd_validate_single_line_stage "$stage" "$generation" "$stage_identity" || return 1
    mv -Tf -- "$stage" "$pointer" || return 1
    motd_array_remove_value MOTD_POINTER_STAGE_PATHS "$stage"
    actual=$(motd_read_pointer "$scope") || return 1
    [[ "$actual" == "$generation" ]]
}

motd_write_journal() {
    local phase="$1" journal stage
    [[ -n "$MOTD_TRANSACTION_DIR" ]] || return 1
    journal="$MOTD_TRANSACTION_DIR/journal"
    stage=$(motd_allocate_file_stage "$MOTD_TRANSACTION_DIR" journal) || return 1
    motd_array_add MOTD_POINTER_STAGE_PATHS "$stage"
    (umask 077; set -o noclobber; : > "$stage") 2>/dev/null || return 1
    printf 'version=1\ntransaction=%s\noperation=%s\nphase=%s\ninitial_old=%s\nprevious_old=%s\ninitial_new=%s\nprevious_new=%s\n' \
        "$MOTD_TRANSACTION_ID" "$MOTD_TRANSACTION_OPERATION" "$phase" "$MOTD_INITIAL_OLD" "$MOTD_PREVIOUS_OLD" "$MOTD_INITIAL_NEW" "$MOTD_PREVIOUS_NEW" > "$stage" || return 1
    chown "$MOTD_TRUSTED_UID:$MOTD_TRUSTED_GID" "$stage" || return 1
    chmod 0600 "$stage" || return 1
    mv -Tf -- "$stage" "$journal" || return 1
    motd_array_remove_value MOTD_POINTER_STAGE_PATHS "$stage"
}

motd_read_journal() {
    local directory="$1" journal line value line_number=0
    journal="$directory/journal"
    motd_validate_secure_file "$journal" || return 1
    MOTD_JOURNAL_TRANSACTION=""; MOTD_JOURNAL_OPERATION=""; MOTD_JOURNAL_PHASE=""
    MOTD_JOURNAL_INITIAL_OLD=""; MOTD_JOURNAL_PREVIOUS_OLD=""; MOTD_JOURNAL_INITIAL_NEW=""; MOTD_JOURNAL_PREVIOUS_NEW=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        ((line_number += 1))
        case "$line_number" in
            1) [[ "$line" == version=1 ]] || return 1 ;;
            2) [[ "$line" == transaction=* ]] || return 1; MOTD_JOURNAL_TRANSACTION=${line#transaction=} ;;
            3) [[ "$line" == operation=install || "$line" == operation=restore ]] || return 1; MOTD_JOURNAL_OPERATION=${line#operation=} ;;
            4) [[ "$line" == phase=prepared || "$line" == phase=active || "$line" == phase=rolledback || "$line" == phase=committed ]] || return 1; MOTD_JOURNAL_PHASE=${line#phase=} ;;
            5) [[ "$line" == initial_old=* ]] || return 1; MOTD_JOURNAL_INITIAL_OLD=${line#initial_old=} ;;
            6) [[ "$line" == previous_old=* ]] || return 1; MOTD_JOURNAL_PREVIOUS_OLD=${line#previous_old=} ;;
            7) [[ "$line" == initial_new=* ]] || return 1; MOTD_JOURNAL_INITIAL_NEW=${line#initial_new=} ;;
            8) [[ "$line" == previous_new=* ]] || return 1; MOTD_JOURNAL_PREVIOUS_NEW=${line#previous_new=} ;;
            *) return 1 ;;
        esac
    done < "$journal"
    (( line_number == 8 )) || return 1
    [[ "$MOTD_JOURNAL_TRANSACTION" =~ ^[0-9a-f]{32}$ ]] || return 1
    for value in "$MOTD_JOURNAL_INITIAL_OLD" "$MOTD_JOURNAL_PREVIOUS_OLD"; do [[ "$value" == absent || "$value" =~ ^[0-9a-f]{32}$ ]] || return 1; done
    for value in "$MOTD_JOURNAL_INITIAL_NEW" "$MOTD_JOURNAL_PREVIOUS_NEW"; do [[ "$value" == - || "$value" =~ ^[0-9a-f]{32}$ ]] || return 1; done
}

motd_validate_journal_generations() {
    local phase="$1" initial_old="$2" previous_old="$3" initial_new="$4" previous_new="$5" current_initial current_previous path
    [[ "$initial_old" == absent ]] || motd_validate_snapshot "$MOTD_STATE_DIR/generations/$initial_old" initial "$initial_old" || return 1
    if [[ "$previous_old" != absent ]]; then
        path="$MOTD_STATE_DIR/generations/$previous_old"
        if [[ -e "$path" || -L "$path" ]]; then
            motd_validate_snapshot "$path" previous "$previous_old" || return 1
        elif [[ "$phase" == committed && "$previous_new" =~ ^[0-9a-f]{32}$ ]]; then
            current_previous=$(motd_read_pointer previous) || return 1; [[ "$current_previous" == "$previous_new" ]] || return 1
        else return 1; fi
    fi
    if [[ "$initial_new" != - ]]; then
        path="$MOTD_STATE_DIR/generations/$initial_new"
        if [[ -e "$path" || -L "$path" ]]; then motd_validate_snapshot "$path" initial "$initial_new" || return 1
        elif [[ "$phase" == rolledback ]]; then current_initial=$(motd_read_pointer_or_absent initial) || return 1; [[ "$current_initial" == "$initial_old" ]] || return 1
        else return 1; fi
    fi
    if [[ "$previous_new" != - ]]; then
        path="$MOTD_STATE_DIR/generations/$previous_new"
        if [[ -e "$path" || -L "$path" ]]; then motd_validate_snapshot "$path" previous "$previous_new" || return 1
        elif [[ "$phase" == rolledback ]]; then current_previous=$(motd_read_pointer_or_absent previous) || return 1; [[ "$current_previous" == "$previous_old" ]] || return 1
        else return 1; fi
    fi
}

motd_publish_pending() {
    local pending="$MOTD_STATE_DIR/pending" stage stage_identity pending_identity actual
    [[ ! -e "$pending" && ! -L "$pending" ]] || return 1
    stage=$(motd_allocate_file_stage "$MOTD_STATE_DIR" pending) || return 1
    motd_array_add MOTD_PENDING_STAGE_PATHS "$stage"
    motd_transaction_phase_hook pending-create || return 1
    (umask 077; set -o noclobber; : > "$stage") 2>/dev/null || return 1
    motd_transaction_phase_hook pending-write || return 1
    printf '%s\n' "$MOTD_TRANSACTION_ID" > "$stage" || return 1
    motd_transaction_phase_hook pending-chown || return 1
    chown "$MOTD_TRUSTED_UID:$MOTD_TRUSTED_GID" "$stage" || return 1
    motd_transaction_phase_hook pending-chmod || return 1
    chmod 0600 "$stage" || return 1
    stage_identity=$(stat -c '%d:%i' -- "$stage") || return 1
    motd_transaction_phase_hook pending-publish || return 1
    motd_validate_single_line_stage "$stage" "$MOTD_TRANSACTION_ID" "$stage_identity" || return 1
    ln -- "$stage" "$pending" || return 1
    pending_identity=$(stat -c '%d:%i' -- "$pending") || return 1
    [[ "$pending_identity" == "$stage_identity" ]] || return 1
    actual=$(motd_read_pending) || return 1
    [[ "$actual" == "$MOTD_TRANSACTION_ID" ]] || return 1
    rm -f -- "$stage" || return 1
    motd_array_remove_value MOTD_PENDING_STAGE_PATHS "$stage"
}

motd_read_pending() {
    local pending="$MOTD_STATE_DIR/pending" transaction
    motd_validate_secure_file "$pending" || return 1
    IFS= read -r transaction < "$pending" || return 1
    [[ "$transaction" =~ ^[0-9a-f]{32}$ && "$(wc -l < "$pending")" == 1 ]] || return 1
    printf '%s\n' "$transaction"
}

motd_note_cleanup_failure() {
    local path="$1"
    MOTD_CLEANUP_FAILURES+=("$path")
    error "MOTD 残留路径: $path"
}

motd_remove_tracked_file() {
    local path="$1" expected_parent="$2" pattern="$3"
    [[ -n "$path" && "$path" == "$expected_parent"/$pattern ]] || return 1
    if [[ ! -e "$path" && ! -L "$path" ]]; then return 0; fi
    [[ -f "$path" && ! -L "$path" ]] || return 1
    motd_validate_secure_file "$path" || return 1
    motd_cleanup_path_hook "$path" || return 1
    rm -f -- "$path"
}

motd_remove_tracked_dir() {
    local path="$1" expected_parent="$2" pattern="$3"
    [[ -n "$path" && "$path" == "$expected_parent"/$pattern ]] || return 1
    if [[ ! -e "$path" && ! -L "$path" ]]; then return 0; fi
    motd_validate_secure_directory "$path" || return 1
    motd_cleanup_path_hook "$path" || return 1
    rm -rf -- "$path"
}

motd_cleanup_stage_arrays() {
    local path id generation failed=false
    MOTD_CLEANUP_FAILURES=()
    for path in "${MOTD_ALL_TARGET_STAGE_PATHS[@]}"; do
        [[ -n "$path" ]] || continue
        if [[ -e "$path" || -L "$path" ]]; then
            if [[ "$path" != "$MOTD_ETC_ROOT"/*/.linux-setup-motd.* && "$path" != "$MOTD_ETC_ROOT"/.linux-setup-motd.* ]] || [[ -d "$path" && ! -L "$path" ]] || ! rm -f -- "$path"; then
                motd_note_cleanup_failure "$path"; failed=true
            fi
        fi
    done
    MOTD_ALL_TARGET_STAGE_PATHS=()
    for id in "${MOTD_TARGET_IDS[@]}"; do MOTD_TARGET_STAGE[$id]=""; done
    for path in "${MOTD_POINTER_STAGE_PATHS[@]}"; do
        if ! motd_remove_tracked_file "$path" "$MOTD_STATE_DIR" '.initial.pointer.*' && ! motd_remove_tracked_file "$path" "$MOTD_STATE_DIR" '.previous.pointer.*' && ! motd_remove_tracked_file "$path" "$MOTD_TRANSACTION_DIR" '.journal.*'; then
            motd_note_cleanup_failure "$path"; failed=true
        fi
    done
    for path in "${MOTD_PENDING_STAGE_PATHS[@]}"; do
        motd_remove_tracked_file "$path" "$MOTD_STATE_DIR" '.pending.*' || { motd_note_cleanup_failure "$path"; failed=true; }
    done
    for path in "${MOTD_SNAPSHOT_BUILDING_PATHS[@]}"; do
        motd_remove_tracked_dir "$path" "$MOTD_STATE_DIR/generations" '.*.stage' || { motd_note_cleanup_failure "$path"; failed=true; }
    done
    for path in "${MOTD_SNAPSHOT_FINAL_PATHS[@]}"; do
        if [[ -e "$path" || -L "$path" ]]; then
            generation=${path##*/}
            motd_remove_generation "$generation" || { motd_note_cleanup_failure "$path"; failed=true; }
        fi
    done
    MOTD_SNAPSHOT_FINAL_PATHS=()
    MOTD_POINTER_STAGE_PATHS=(); MOTD_PENDING_STAGE_PATHS=(); MOTD_SNAPSHOT_BUILDING_PATHS=()
    [[ "$failed" == false ]]
}

motd_remove_pending_for_transaction() {
    local pending="$MOTD_STATE_DIR/pending" value
    if [[ ! -e "$pending" && ! -L "$pending" ]]; then return 0; fi
    value=$(motd_read_pending) || return 1
    [[ "$value" == "$MOTD_TRANSACTION_ID" ]] || return 1
    motd_cleanup_path_hook "$pending" || return 1
    rm -f -- "$pending"
}

motd_generation_is_referenced() {
    local generation="$1" initial previous
    initial=$(motd_read_pointer_or_absent initial) || return 1
    previous=$(motd_read_pointer_or_absent previous) || return 1
    [[ "$generation" == "$initial" || "$generation" == "$previous" || "$generation" == "$MOTD_INITIAL_OLD" || "$generation" == "$MOTD_PREVIOUS_OLD" ]]
}

motd_remove_generation() {
    local generation="$1" path="$MOTD_STATE_DIR/generations/$1"
    [[ "$generation" =~ ^[0-9a-f]{32}$ ]] || return 1
    motd_generation_is_referenced "$generation" && return 0
    if [[ ! -e "$path" && ! -L "$path" ]]; then return 0; fi
    motd_validate_snapshot "$path" initial "$generation" >/dev/null 2>&1 || motd_validate_snapshot "$path" previous "$generation" >/dev/null 2>&1 || return 1
    motd_remove_tracked_dir "$path" "$MOTD_STATE_DIR/generations" "$generation"
}

motd_cleanup_new_generations() {
    local generation failed=false
    for generation in "${MOTD_NEW_GENERATIONS[@]}"; do
        motd_remove_generation "$generation" || { motd_note_cleanup_failure "$MOTD_STATE_DIR/generations/$generation"; failed=true; }
    done
    [[ "$failed" == false ]]
}

motd_cleanup_replaced_previous_generation() {
    local current_initial current_previous path
    [[ "$MOTD_PREVIOUS_OLD" =~ ^[0-9a-f]{32}$ && "$MOTD_PREVIOUS_NEW" =~ ^[0-9a-f]{32}$ && "$MOTD_PREVIOUS_OLD" != "$MOTD_PREVIOUS_NEW" ]] || return 0
    current_initial=$(motd_read_pointer_or_absent initial) || return 1
    current_previous=$(motd_read_pointer_or_absent previous) || return 1
    [[ "$MOTD_PREVIOUS_OLD" == "$current_initial" || "$MOTD_PREVIOUS_OLD" == "$current_previous" ]] && return 0
    path="$MOTD_STATE_DIR/generations/$MOTD_PREVIOUS_OLD"
    if [[ ! -e "$path" && ! -L "$path" ]]; then return 0; fi
    motd_validate_snapshot "$path" previous "$MOTD_PREVIOUS_OLD" || return 1
    motd_remove_tracked_dir "$path" "$MOTD_STATE_DIR/generations" "$MOTD_PREVIOUS_OLD" || { motd_note_cleanup_failure "$path"; return 1; }
}

motd_validate_residue_file() {
    local path="$1" pattern="$2"
    [[ "$path" == "$MOTD_STATE_DIR"/$pattern ]] || return 1
    motd_validate_secure_file "$path"
}

motd_cleanup_root_stages() {
    local saved path name failed=false
    saved=$(shopt -p nullglob dotglob || true); shopt -s nullglob
    for path in "$MOTD_STATE_DIR"/.initial.pointer.* "$MOTD_STATE_DIR"/.previous.pointer.* "$MOTD_STATE_DIR"/.pending.*; do
        name=${path##*/}
        [[ "$name" =~ ^\.(initial|previous)\.pointer\.[0-9a-f]{32}$ || "$name" =~ ^\.pending\.[0-9a-f]{32}$ ]] || { error "未知 MOTD root residue: $path"; failed=true; continue; }
        motd_validate_secure_file "$path" && rm -f -- "$path" || { error "不可信或无法清理的 MOTD residue: $path"; failed=true; }
    done
    eval "$saved"
    [[ "$failed" == false ]]
}

motd_validate_state_root_entries() {
    local saved path name failed=false
    saved=$(shopt -p nullglob dotglob || true); shopt -s nullglob dotglob
    for path in "$MOTD_STATE_DIR"/*; do
        name=${path##*/}
        case "$name" in
            generations) motd_validate_secure_directory "$path" || failed=true ;;
            transactions) motd_validate_secure_directory "$path" || failed=true ;;
            initial.current|previous.current|pending) ;;
            *)
                if [[ ! "$name" =~ ^(motd|issue|issue\.net|00-custom-welcome|10-uname|50-motd-news)\.(initial|previous)-(backup|absent|unknown)$ ]]; then
                    error "未知 MOTD state root 对象: $path"; failed=true
                fi
                ;;
        esac
    done
    eval "$saved"
    [[ "$failed" == false ]]
}

motd_cleanup_generation_stages() {
    local saved path name failed=false
    saved=$(shopt -p nullglob dotglob || true); shopt -s nullglob dotglob
    for path in "$MOTD_STATE_DIR/generations"/*; do
        name=${path##*/}
        if [[ "$name" =~ ^\.[0-9a-f]{32}\.stage$ ]]; then
            motd_validate_secure_directory "$path" && rm -rf -- "$path" || { error "不可信或无法清理的 generation stage: $path"; failed=true; }
        elif [[ "$name" =~ ^[0-9a-f]{32}$ ]]; then
            :
        else
            error "未知 generation 对象: $path"; failed=true
        fi
    done
    eval "$saved"
    [[ "$failed" == false ]]
}

motd_scan_transactions_without_pending() {
    local saved path name failed=false
    saved=$(shopt -p nullglob dotglob || true); shopt -s nullglob dotglob
    for path in "$MOTD_TRANSACTION_PARENT"/*; do
        name=${path##*/}
        if [[ "$name" =~ ^\.[0-9a-f]{32}\.stage$ ]]; then
            motd_validate_secure_directory "$path" && rm -rf -- "$path" || { error "不可信 transaction building residue: $path"; failed=true; }
        elif [[ "$name" =~ ^[0-9a-f]{32}$ ]]; then
            if ! motd_validate_secure_directory "$path" || ! motd_validate_transaction_directory_contents "$path" || ! motd_read_journal "$path" || [[ "$MOTD_JOURNAL_TRANSACTION" != "$name" ]] || ! motd_validate_snapshot "$path/rollback" runtime "$name"; then
                error "无 pending 的 transaction residue 不可信: $path"; failed=true; continue
            fi
            case "$MOTD_JOURNAL_PHASE" in
                prepared) rm -rf -- "$path" || { error "无法清理 prepared transaction: $path"; failed=true; } ;;
                rolledback)
                    if motd_validate_journal_generations rolledback "$MOTD_JOURNAL_INITIAL_OLD" "$MOTD_JOURNAL_PREVIOUS_OLD" "$MOTD_JOURNAL_INITIAL_NEW" "$MOTD_JOURNAL_PREVIOUS_NEW"; then rm -rf -- "$path" || { error "无法清理 rolledback transaction: $path"; failed=true; }
                    else error "rolledback transaction generation 不一致: $path"; failed=true; fi
                    ;;
                committed)
                    if motd_validate_journal_generations committed "$MOTD_JOURNAL_INITIAL_OLD" "$MOTD_JOURNAL_PREVIOUS_OLD" "$MOTD_JOURNAL_INITIAL_NEW" "$MOTD_JOURNAL_PREVIOUS_NEW"; then
                        MOTD_PREVIOUS_OLD=$MOTD_JOURNAL_PREVIOUS_OLD; MOTD_PREVIOUS_NEW=$MOTD_JOURNAL_PREVIOUS_NEW
                        motd_cleanup_replaced_previous_generation || failed=true
                        rm -rf -- "$path" || { error "无法清理 committed transaction: $path"; failed=true; }
                        MOTD_PREVIOUS_OLD=absent; MOTD_PREVIOUS_NEW=-
                    else error "committed transaction generation 不一致: $path"; failed=true; fi
                    ;;
                *) error "active transaction 缺少 pending: $path"; failed=true ;;
            esac
        else
            error "未知 transaction residue: $path"; failed=true
        fi
    done
    eval "$saved"
    [[ "$failed" == false ]]
}

motd_prune_unreferenced_generations() {
    local saved path name initial previous failed=false
    initial=$(motd_read_pointer_or_absent initial) || return 1
    previous=$(motd_read_pointer_or_absent previous) || return 1
    saved=$(shopt -p nullglob dotglob || true); shopt -s nullglob dotglob
    for path in "$MOTD_STATE_DIR/generations"/*; do
        name=${path##*/}
        [[ "$name" =~ ^[0-9a-f]{32}$ ]] || { error "未知 generation 对象: $path"; failed=true; continue; }
        [[ "$name" == "$initial" || "$name" == "$previous" ]] && continue
        motd_validate_snapshot "$path" initial "$name" >/dev/null 2>&1 || motd_validate_snapshot "$path" previous "$name" >/dev/null 2>&1 || { error "不可信 generation: $path"; failed=true; continue; }
        rm -rf -- "$path" || { error "无法清理 generation: $path"; failed=true; }
    done
    eval "$saved"
    [[ "$failed" == false ]]
}

motd_begin_transaction() {
    local operation="$1" transaction stage final
    MOTD_INITIAL_OLD=$(motd_read_pointer_or_absent initial) || return 1
    MOTD_PREVIOUS_OLD=$(motd_read_pointer_or_absent previous) || return 1
    MOTD_INITIAL_NEW=-; MOTD_PREVIOUS_NEW=-
    transaction=$(motd_random_id) || return 1
    stage="$MOTD_TRANSACTION_PARENT/.${transaction}.stage"; final="$MOTD_TRANSACTION_PARENT/$transaction"
    MOTD_TRANSACTION_ID=$transaction; MOTD_TRANSACTION_OPERATION=$operation
    MOTD_TRANSACTION_BUILDING_PATH=$stage; MOTD_TRANSACTION_FINAL_PATH=$final
    [[ ! -e "$stage" && ! -L "$stage" && ! -e "$final" && ! -L "$final" ]] || return 1
    mkdir -m 0700 -- "$stage" || return 1
    MOTD_TRANSACTION_DIR=$stage; MOTD_TRANSACTION_LIFECYCLE=building
    chown "$MOTD_TRUSTED_UID:$MOTD_TRUSTED_GID" "$stage" || return 1
    motd_transaction_phase_hook transaction-snapshot-building || return 1
    motd_capture_snapshot_to_dir "$stage/rollback" runtime "$transaction" false || return 1
    motd_write_journal prepared || return 1
    MOTD_TRANSACTION_LIFECYCLE="prepared-stage"
    motd_transaction_phase_hook snapshot-commit || return 1
    motd_validate_snapshot "$stage/rollback" runtime "$transaction" || return 1
    motd_transaction_phase_hook transaction-final-move || return 1
    motd_validate_snapshot "$stage/rollback" runtime "$transaction" || return 1
    mv -T -- "$stage" "$final" || return 1
    MOTD_TRANSACTION_DIR=$final; MOTD_TRANSACTION_LIFECYCLE="final-pre-pending"
    MOTD_TRANSACTION_BUILDING_PATH=""
    motd_transaction_phase_hook transaction-final-moved || return 1
    motd_publish_pending || return 1
    MOTD_TRANSACTION_ACTIVE=true
    motd_transaction_phase_hook pending-published || return 1
    motd_write_journal active || return 1
    MOTD_TRANSACTION_LIFECYCLE=active
    motd_transaction_phase_hook pending-active || return 1
}

motd_restore_old_pointers() {
    local failed=false
    motd_set_pointer initial "$MOTD_INITIAL_OLD" || failed=true
    motd_set_pointer previous "$MOTD_PREVIOUS_OLD" || failed=true
    [[ "$failed" == false ]]
}

motd_rollback_current_transaction() {
    local failed=false
    motd_prepare_snapshot_plan "$MOTD_TRANSACTION_DIR/rollback" runtime || return 1
    motd_validate_all_target_stages || return 1
    MOTD_ROLLBACK_MODE=true
    motd_commit_target_plan rollback true || failed=true
    motd_restore_old_pointers || failed=true
    MOTD_ROLLBACK_MODE=false
    [[ "$failed" == false ]]
}

motd_remove_transaction_directory() {
    local path name failed=false seen="|"
    for path in "$MOTD_TRANSACTION_DIR" "$MOTD_TRANSACTION_BUILDING_PATH" "$MOTD_TRANSACTION_FINAL_PATH"; do
        [[ -n "$path" && "$seen" != *"|$path|"* ]] || continue
        seen+="$path|"; name=${path##*/}
        if [[ "$name" == ".${MOTD_TRANSACTION_ID}.stage" ]]; then
            motd_remove_tracked_dir "$path" "$MOTD_TRANSACTION_PARENT" ".${MOTD_TRANSACTION_ID}.stage" || { motd_note_cleanup_failure "$path"; failed=true; }
        elif [[ "$name" == "$MOTD_TRANSACTION_ID" ]]; then
            motd_remove_tracked_dir "$path" "$MOTD_TRANSACTION_PARENT" "$MOTD_TRANSACTION_ID" || { motd_note_cleanup_failure "$path"; failed=true; }
        else
            motd_note_cleanup_failure "$path"; failed=true
        fi
    done
    [[ "$failed" == false ]]
}

motd_abort_transaction() {
    local rollback_failed=false cleanup_failed=false
    case "$MOTD_TRANSACTION_LIFECYCLE" in
        building|prepared-stage|final-pre-pending|none)
            motd_cleanup_stage_arrays || cleanup_failed=true
            motd_cleanup_new_generations || cleanup_failed=true
            motd_remove_transaction_directory || cleanup_failed=true
            [[ "$cleanup_failed" == false ]] || return 1
            motd_clear_transaction_globals
            return 0
            ;;
        active|rolledback)
            if [[ "$MOTD_TRANSACTION_LIFECYCLE" == active ]]; then
                motd_rollback_current_transaction || rollback_failed=true
            fi
            motd_cleanup_stage_arrays || cleanup_failed=true
            if [[ "$rollback_failed" == true || "$cleanup_failed" == true ]]; then
                error "MOTD rollback/cleanup 不完整，保留 journal: $MOTD_TRANSACTION_DIR"
                return 1
            fi
            if [[ "$MOTD_TRANSACTION_LIFECYCLE" == active ]]; then
                motd_write_journal rolledback || return 1
                MOTD_TRANSACTION_LIFECYCLE=rolledback
            fi
            motd_cleanup_new_generations || return 1
            motd_remove_pending_for_transaction || return 1
            motd_remove_transaction_directory || return 1
            motd_clear_transaction_globals
            ;;
        committed)
            error "committed transaction 不得执行 abort: $MOTD_TRANSACTION_DIR"
            return 1
            ;;
        *) return 1 ;;
    esac
}

motd_complete_transaction() {
    local failed=false
    motd_transaction_phase_hook committed-cleanup || return 1
    motd_cleanup_replaced_previous_generation || failed=true
    motd_transaction_phase_hook committed-old-generation-cleaned || return 1
    motd_cleanup_stage_arrays || failed=true
    [[ "$failed" == false ]] || { error "committed cleanup 不完整，保留 journal: $MOTD_TRANSACTION_DIR"; return 1; }
    motd_remove_pending_for_transaction || return 1
    motd_transaction_phase_hook committed-pending-removed || return 1
    motd_remove_transaction_directory || return 1
    motd_clear_transaction_globals
    MOTD_STATE_DIR_CREATED=false
}

motd_mark_transaction_committed() {
    motd_write_journal committed || return 1
    MOTD_TRANSACTION_COMMITTED=true; MOTD_TRANSACTION_LIFECYCLE=committed
}

motd_validate_pending_transaction() {
    local pending_id="$1" directory="$MOTD_TRANSACTION_PARENT/$1" basename
    [[ "$pending_id" =~ ^[0-9a-f]{32}$ ]] || return 1
    basename=${directory##*/}
    [[ "$basename" == "$pending_id" ]] || return 1
    motd_validate_secure_directory "$directory" || return 1
    motd_validate_transaction_directory_contents "$directory" || return 1
    motd_read_journal "$directory" || return 1
    [[ "$MOTD_JOURNAL_TRANSACTION" == "$pending_id" ]] || return 1
    motd_validate_snapshot "$directory/rollback" runtime "$pending_id" || return 1
    motd_validate_journal_generations "$MOTD_JOURNAL_PHASE" "$MOTD_JOURNAL_INITIAL_OLD" "$MOTD_JOURNAL_PREVIOUS_OLD" "$MOTD_JOURNAL_INITIAL_NEW" "$MOTD_JOURNAL_PREVIOUS_NEW" || return 1
}

motd_recover_pending_transaction() {
    local pending="$MOTD_STATE_DIR/pending" transaction
    if [[ ! -e "$pending" && ! -L "$pending" ]]; then return 0; fi
    transaction=$(motd_read_pending) || { error "pending 不可信，保留证据: $pending"; return 1; }
    motd_validate_pending_transaction "$transaction" || { error "pending/journal 不一致，保留证据: $pending"; return 1; }
    MOTD_TRANSACTION_ID=$transaction
    MOTD_TRANSACTION_FINAL_PATH="$MOTD_TRANSACTION_PARENT/$transaction"
    MOTD_TRANSACTION_DIR=$MOTD_TRANSACTION_FINAL_PATH
    MOTD_TRANSACTION_OPERATION=$MOTD_JOURNAL_OPERATION
    MOTD_INITIAL_OLD=$MOTD_JOURNAL_INITIAL_OLD; MOTD_PREVIOUS_OLD=$MOTD_JOURNAL_PREVIOUS_OLD
    MOTD_INITIAL_NEW=$MOTD_JOURNAL_INITIAL_NEW; MOTD_PREVIOUS_NEW=$MOTD_JOURNAL_PREVIOUS_NEW
    MOTD_TRANSACTION_LIFECYCLE=$MOTD_JOURNAL_PHASE
    MOTD_NEW_GENERATIONS=()
    [[ "$MOTD_INITIAL_NEW" == - ]] || MOTD_NEW_GENERATIONS+=("$MOTD_INITIAL_NEW")
    [[ "$MOTD_PREVIOUS_NEW" == - ]] || MOTD_NEW_GENERATIONS+=("$MOTD_PREVIOUS_NEW")
    motd_cleanup_target_residue_for_transaction "$transaction" || return 1
    case "$MOTD_JOURNAL_PHASE" in
        prepared)
            warn "清理 pending 发布前中断的 MOTD transaction: $transaction"
            MOTD_TRANSACTION_ACTIVE=false
            motd_remove_pending_for_transaction || return 1
            motd_remove_transaction_directory || return 1
            motd_cleanup_new_generations || return 1
            motd_clear_transaction_globals
            ;;
        active)
            warn "回滚 pending MOTD transaction: $transaction"
            MOTD_TRANSACTION_ACTIVE=true
            motd_abort_transaction
            ;;
        rolledback)
            warn "完成 rolledback MOTD transaction 清理: $transaction"
            MOTD_TRANSACTION_ACTIVE=false
            motd_cleanup_new_generations || return 1
            motd_remove_pending_for_transaction || return 1
            motd_remove_transaction_directory || return 1
            motd_clear_transaction_globals
            ;;
        committed)
            warn "完成 committed MOTD transaction 清理: $transaction"
            MOTD_TRANSACTION_ACTIVE=true; MOTD_TRANSACTION_COMMITTED=true
            motd_complete_transaction
            ;;
        *) return 1 ;;
    esac
}

motd_reconcile_state() {
    local pending="$MOTD_STATE_DIR/pending"
    motd_cleanup_root_stages || return 1
    motd_validate_state_root_entries || return 1
    motd_cleanup_generation_stages || return 1
    if [[ ! -e "$pending" && ! -L "$pending" ]]; then
        motd_scan_transactions_without_pending || return 1
    else
        motd_recover_pending_transaction || return 1
        motd_scan_transactions_without_pending || return 1
    fi
    motd_prune_unreferenced_generations || return 1
    motd_assert_no_target_residue
}

motd_clear_transaction_globals() {
    MOTD_TRANSACTION_ACTIVE=false; MOTD_TRANSACTION_COMMITTED=false; MOTD_ROLLBACK_MODE=false; MOTD_TRANSACTION_LIFECYCLE=none
    MOTD_TRANSACTION_ID=""; MOTD_TRANSACTION_OPERATION=""; MOTD_TRANSACTION_BUILDING_PATH=""; MOTD_TRANSACTION_FINAL_PATH=""; MOTD_TRANSACTION_DIR=""
    MOTD_INITIAL_OLD=absent; MOTD_PREVIOUS_OLD=absent; MOTD_INITIAL_NEW=-; MOTD_PREVIOUS_NEW=-
    MOTD_TARGET_ACTION=(); MOTD_TARGET_STAGE=(); MOTD_STAGE_DEV=(); MOTD_STAGE_INO=(); MOTD_STAGE_TYPE=(); MOTD_STAGE_UID=(); MOTD_STAGE_GID=(); MOTD_STAGE_MODE=(); MOTD_STAGE_DIGEST=(); MOTD_STAGE_LINK=(); MOTD_STAGE_ATIME=(); MOTD_STAGE_MTIME=(); MOTD_DELETE_DEV=(); MOTD_DELETE_INO=(); MOTD_DELETE_TYPE=(); MOTD_DELETE_LINK=()
    MOTD_SNAPSHOT_BUILDING_PATHS=(); MOTD_SNAPSHOT_FINAL_PATHS=(); MOTD_POINTER_STAGE_PATHS=(); MOTD_PENDING_STAGE_PATHS=(); MOTD_NEW_GENERATIONS=(); MOTD_ALL_TARGET_STAGE_PATHS=()
}

motd_reset_target_plan() {
    MOTD_TARGET_ACTION=(); MOTD_TARGET_STAGE=(); MOTD_STAGE_DEV=(); MOTD_STAGE_INO=(); MOTD_STAGE_TYPE=()
    MOTD_STAGE_UID=(); MOTD_STAGE_GID=(); MOTD_STAGE_MODE=(); MOTD_STAGE_DIGEST=(); MOTD_STAGE_LINK=()
    MOTD_STAGE_ATIME=(); MOTD_STAGE_MTIME=(); MOTD_DELETE_DEV=(); MOTD_DELETE_INO=(); MOTD_DELETE_TYPE=(); MOTD_DELETE_LINK=()
}

MOTD_ALLOCATED_PATH=""
motd_allocate_target_stage() {
    local id="$1" target=${MOTD_PATH_BY_ID[$1]} parent token path
    parent=$(motd_path_parent "$target") || return 1
    token=$(motd_random_id) || return 1
    path="$parent/.linux-setup-motd.${MOTD_TRANSACTION_ID}.${id}.${token}"
    MOTD_TARGET_STAGE[$id]=$path
    MOTD_ALL_TARGET_STAGE_PATHS+=("$path")
    MOTD_ALLOCATED_PATH=$path
    [[ ! -e "$path" && ! -L "$path" ]]
}

motd_stat_stage_numeric() {
    stat -c '%u:%g:%a:%d:%i:%X:%Y' -- "$1" 2>/dev/null
}

motd_record_target_stage() {
    local id="$1" expected_type="$2" expected_uid="$3" expected_gid="$4" expected_mode="$5" expected_digest="$6" expected_link="$7" expected_atime="$8" expected_mtime="$9"
    local path=${MOTD_TARGET_STAGE[$id]} metadata uid gid mode dev inode atime mtime actual
    [[ -n "$path" ]] || return 1
    metadata=$(motd_stat_stage_numeric "$path") || return 1
    IFS=: read -r uid gid mode dev inode atime mtime <<< "$metadata"
    [[ "$uid" == "$expected_uid" && "$gid" == "$expected_gid" && "$mode" == "$expected_mode" ]] || return 1
    case "$expected_type" in
        regular)
            [[ -f "$path" && ! -L "$path" ]] || return 1
            actual=$(sha256sum "$path") || return 1
            [[ "${actual%% *}" == "$expected_digest" ]] || return 1
            if [[ "$expected_atime" != - ]]; then
                touch -a -d "@$expected_atime" "$path" || return 1
                touch -m -d "@$expected_mtime" "$path" || return 1
            fi
            metadata=$(motd_stat_stage_numeric "$path") || return 1
            IFS=: read -r uid gid mode dev inode atime mtime <<< "$metadata"
            [[ "$uid" == "$expected_uid" && "$gid" == "$expected_gid" && "$mode" == "$expected_mode" ]] || return 1
            [[ "$expected_atime" == - || ( "$atime" == "$expected_atime" && "$mtime" == "$expected_mtime" ) ]] || return 1
            ;;
        symlink)
            [[ -L "$path" ]] || return 1
            actual=$(readlink -- "$path") || return 1
            [[ "$actual" == "$expected_link" ]] || return 1
            ;;
        *) return 1 ;;
    esac
    MOTD_STAGE_DEV[$id]=$dev; MOTD_STAGE_INO[$id]=$inode; MOTD_STAGE_TYPE[$id]=$expected_type
    MOTD_STAGE_UID[$id]=$expected_uid; MOTD_STAGE_GID[$id]=$expected_gid; MOTD_STAGE_MODE[$id]=$expected_mode
    MOTD_STAGE_DIGEST[$id]=$expected_digest; MOTD_STAGE_LINK[$id]=$expected_link
    MOTD_STAGE_ATIME[$id]=$expected_atime; MOTD_STAGE_MTIME[$id]=$expected_mtime
}

motd_validate_target_stage() {
    local id="$1" path=${MOTD_TARGET_STAGE[$1]:-} metadata uid gid mode dev inode atime mtime actual
    [[ "${MOTD_TARGET_ACTION[$id]:-}" == replace && -n "$path" ]] || return 1
    metadata=$(motd_stat_stage_numeric "$path") || return 1
    IFS=: read -r uid gid mode dev inode atime mtime <<< "$metadata"
    [[ "$dev" == "${MOTD_STAGE_DEV[$id]}" && "$inode" == "${MOTD_STAGE_INO[$id]}" && "$uid" == "${MOTD_STAGE_UID[$id]}" && "$gid" == "${MOTD_STAGE_GID[$id]}" && "$mode" == "${MOTD_STAGE_MODE[$id]}" ]] || return 1
    case "${MOTD_STAGE_TYPE[$id]}" in
        regular)
            [[ -f "$path" && ! -L "$path" ]] || return 1
            actual=$(sha256sum "$path") || return 1
            [[ "${actual%% *}" == "${MOTD_STAGE_DIGEST[$id]}" ]] || return 1
            if [[ "${MOTD_STAGE_ATIME[$id]}" != - ]]; then
                touch -a -d "@${MOTD_STAGE_ATIME[$id]}" "$path" || return 1
                touch -m -d "@${MOTD_STAGE_MTIME[$id]}" "$path" || return 1
            fi
            metadata=$(motd_stat_stage_numeric "$path") || return 1
            IFS=: read -r uid gid mode dev inode atime mtime <<< "$metadata"
            [[ "$dev" == "${MOTD_STAGE_DEV[$id]}" && "$inode" == "${MOTD_STAGE_INO[$id]}" && "$uid" == "${MOTD_STAGE_UID[$id]}" && "$gid" == "${MOTD_STAGE_GID[$id]}" && "$mode" == "${MOTD_STAGE_MODE[$id]}" ]] || return 1
            [[ "${MOTD_STAGE_ATIME[$id]}" == - || ( "$atime" == "${MOTD_STAGE_ATIME[$id]}" && "$mtime" == "${MOTD_STAGE_MTIME[$id]}" ) ]] || return 1
            ;;
        symlink)
            [[ -L "$path" ]] || return 1
            actual=$(readlink -- "$path") || return 1
            [[ "$actual" == "${MOTD_STAGE_LINK[$id]}" ]] || return 1
            metadata=$(motd_stat_stage_numeric "$path") || return 1
            IFS=: read -r uid gid mode dev inode atime mtime <<< "$metadata"
            [[ "$dev" == "${MOTD_STAGE_DEV[$id]}" && "$inode" == "${MOTD_STAGE_INO[$id]}" && "$uid" == "${MOTD_STAGE_UID[$id]}" && "$gid" == "${MOTD_STAGE_GID[$id]}" && "$mode" == "${MOTD_STAGE_MODE[$id]}" ]] || return 1
            ;;
        *) return 1 ;;
    esac
}

motd_record_delete_target() {
    local id="$1" path=${MOTD_PATH_BY_ID[$1]} metadata dev inode link
    if [[ -L "$path" ]]; then
        metadata=$(stat -c '%d:%i' -- "$path") || return 1
        IFS=: read -r dev inode <<< "$metadata"
        link=$(readlink -- "$path") || return 1
        MOTD_DELETE_TYPE[$id]=symlink; MOTD_DELETE_LINK[$id]=$link
    elif [[ -f "$path" ]]; then
        metadata=$(stat -c '%d:%i' -- "$path") || return 1
        IFS=: read -r dev inode <<< "$metadata"
        MOTD_DELETE_TYPE[$id]=regular; MOTD_DELETE_LINK[$id]=-
    elif [[ ! -e "$path" ]]; then
        dev=-; inode=-; MOTD_DELETE_TYPE[$id]=absent; MOTD_DELETE_LINK[$id]=-
    else return 1; fi
    MOTD_DELETE_DEV[$id]=$dev; MOTD_DELETE_INO[$id]=$inode
}

motd_validate_delete_target() {
    local id="$1" path=${MOTD_PATH_BY_ID[$1]} metadata dev inode link
    case "${MOTD_DELETE_TYPE[$id]:-}" in
        symlink)
            [[ -L "$path" ]] || return 1
            metadata=$(stat -c '%d:%i' -- "$path") || return 1; IFS=: read -r dev inode <<< "$metadata"
            link=$(readlink -- "$path") || return 1
            [[ "$dev" == "${MOTD_DELETE_DEV[$id]}" && "$inode" == "${MOTD_DELETE_INO[$id]}" && "$link" == "${MOTD_DELETE_LINK[$id]}" ]]
            ;;
        regular)
            [[ -f "$path" && ! -L "$path" ]] || return 1
            metadata=$(stat -c '%d:%i' -- "$path") || return 1; IFS=: read -r dev inode <<< "$metadata"
            [[ "$dev" == "${MOTD_DELETE_DEV[$id]}" && "$inode" == "${MOTD_DELETE_INO[$id]}" ]]
            ;;
        absent) [[ ! -e "$path" && ! -L "$path" ]] ;;
        *) return 1 ;;
    esac
}

motd_validate_all_target_stages() {
    local id
    for id in "${MOTD_TARGET_IDS[@]}"; do
        case "${MOTD_TARGET_ACTION[$id]:-}" in
            replace) motd_validate_target_stage "$id" || { error "MOTD stage 完整性失败: $id"; return 1; } ;;
            delete) [[ -z "${MOTD_TARGET_STAGE[$id]:-}" ]] && motd_validate_delete_target "$id" || return 1 ;;
            noop) [[ -z "${MOTD_TARGET_STAGE[$id]:-}" ]] || return 1 ;;
            *) return 1 ;;
        esac
    done
}

motd_prepare_regular_stage() {
    local id="$1" source="$2" uid="$3" gid="$4" mode="$5" atime="$6" mtime="$7" digest="$8" stage
    motd_allocate_target_stage "$id" || return 1
    stage=$MOTD_ALLOCATED_PATH
    (umask 077; set -o noclobber; : > "$stage") 2>/dev/null || return 1
    cat -- "$source" > "$stage" || return 1
    chown "$uid:$gid" "$stage" || return 1
    chmod "$mode" "$stage" || return 1
    MOTD_TARGET_ACTION[$id]=replace
    motd_record_target_stage "$id" regular "$uid" "$gid" "$mode" "$digest" "" "$atime" "$mtime"
}

motd_prepare_symlink_stage() {
    local id="$1" link="$2" stage
    motd_allocate_target_stage "$id" || return 1
    stage=$MOTD_ALLOCATED_PATH
    ln -s -- "$link" "$stage" || return 1
    MOTD_TARGET_ACTION[$id]=replace
    motd_record_target_stage "$id" symlink "$MOTD_TRUSTED_UID" "$MOTD_TRUSTED_GID" 777 "" "$link" - -
}

motd_prepare_snapshot_plan() {
    local snapshot="$1" scope="$2" id object
    motd_validate_snapshot "$snapshot" "$scope" || return 1
    motd_reset_target_plan
    MOTD_RESTORED_COUNT=0
    for id in "${MOTD_TARGET_IDS[@]}"; do
        object=$(motd_snapshot_object_path "$snapshot" "$id") || return 1
        case "${MOTD_SNAPSHOT_STATE[$id]}" in
            regular)
                motd_prepare_regular_stage "$id" "$object" "${MOTD_SNAPSHOT_UID[$id]}" "${MOTD_SNAPSHOT_GID[$id]}" "${MOTD_SNAPSHOT_MODE[$id]}" "${MOTD_SNAPSHOT_ATIME[$id]}" "${MOTD_SNAPSHOT_MTIME[$id]}" "${MOTD_SNAPSHOT_DIGEST[$id]}" || return 1
                ((MOTD_RESTORED_COUNT += 1))
                ;;
            symlink)
                motd_prepare_symlink_stage "$id" "${MOTD_SNAPSHOT_LINK[$id]}" || return 1
                ((MOTD_RESTORED_COUNT += 1))
                ;;
            absent)
                motd_record_delete_target "$id" || return 1
                MOTD_TARGET_ACTION[$id]=delete; MOTD_TARGET_STAGE[$id]=""; ((MOTD_RESTORED_COUNT += 1))
                ;;
            unknown)
                warn "MOTD 初始状态未知，显式 no-op: ${MOTD_PATH_BY_ID[$id]}"
                MOTD_TARGET_ACTION[$id]=noop; MOTD_TARGET_STAGE[$id]=""
                ;;
            *) return 1 ;;
        esac
    done
}

motd_prepare_install_plan() {
    local id path stage metadata uid gid mode atime mtime digest new_mode
    local empty_digest="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    motd_reset_target_plan
    for id in "${MOTD_TARGET_IDS[@]}"; do
        path=${MOTD_PATH_BY_ID[$id]}
        case "$id" in
            motd|issue|issue_net)
                motd_allocate_target_stage "$id" || return 1; stage=$MOTD_ALLOCATED_PATH
                (umask 022; set -o noclobber; : > "$stage") 2>/dev/null || return 1
                chown "$MOTD_TRUSTED_UID:$MOTD_TRUSTED_GID" "$stage" || return 1
                chmod 0644 "$stage" || return 1
                MOTD_TARGET_ACTION[$id]=replace
                motd_record_target_stage "$id" regular "$MOTD_TRUSTED_UID" "$MOTD_TRUSTED_GID" 644 "$empty_digest" "" - - || return 1
                ;;
            custom_welcome)
                motd_allocate_target_stage "$id" || return 1; stage=$MOTD_ALLOCATED_PATH
                motd_write_payload "$stage" || return 1
                chown "$MOTD_TRUSTED_UID:$MOTD_TRUSTED_GID" "$stage" || return 1
                chmod 0755 "$stage" || return 1
                bash -n "$stage" || return 1
                digest=$(sha256sum "$stage") || return 1
                [[ "${digest%% *}" == "$MOTD_PAYLOAD_SHA256" ]] || return 1
                MOTD_TARGET_ACTION[$id]=replace
                motd_record_target_stage "$id" regular "$MOTD_TRUSTED_UID" "$MOTD_TRUSTED_GID" 755 "$MOTD_PAYLOAD_SHA256" "" - - || return 1
                ;;
            uname|motd_news)
                if [[ ! -e "$path" && ! -L "$path" ]]; then
                    MOTD_TARGET_ACTION[$id]=noop; MOTD_TARGET_STAGE[$id]=""
                elif [[ -L "$path" ]]; then
                    motd_record_delete_target "$id" || return 1
                    MOTD_TARGET_ACTION[$id]=delete; MOTD_TARGET_STAGE[$id]=""
                elif [[ -f "$path" ]]; then
                    metadata=$(stat -c '%u:%g:%a:%X:%Y' -- "$path") || return 1
                    IFS=: read -r uid gid mode atime mtime <<< "$metadata"
                    new_mode=$((8#$mode & ~8#111)); printf -v new_mode '%03o' "$new_mode"
                    digest=$(sha256sum "$path") || return 1
                    motd_prepare_regular_stage "$id" "$path" "$uid" "$gid" "$new_mode" "$atime" "$mtime" "${digest%% *}" || return 1
                else return 1
                fi
                ;;
        esac
    done
}

motd_commit_target_plan() {
    local operation="$1" rollback_mode="${2:-false}" id path action stage failed=false
    for id in "${MOTD_TARGET_IDS[@]}"; do
        path=${MOTD_PATH_BY_ID[$id]}; action=${MOTD_TARGET_ACTION[$id]}; stage=${MOTD_TARGET_STAGE[$id]:-}
        if [[ "$rollback_mode" == true ]]; then
            motd_rollback_hook "$id" "$path" || { error "rollback hook 失败: $id"; failed=true; continue; }
        else
            motd_target_commit_hook "$operation" "$id" "$path" || { error "target commit hook 失败: $id"; return 1; }
        fi
        case "$action" in
            replace)
                if ! motd_validate_target_stage "$id"; then
                    error "hook 后 stage 完整性失败: $id"
                    [[ "$rollback_mode" == true ]] && { failed=true; continue; }
                    return 1
                fi
                mv -Tf -- "$stage" "$path" || { error "目标原子替换失败: $id"; [[ "$rollback_mode" == true ]] && { failed=true; continue; }; return 1; }
                MOTD_TARGET_STAGE[$id]=""; motd_array_remove_value MOTD_ALL_TARGET_STAGE_PATHS "$stage"
                ;;
            delete)
                if ! motd_validate_delete_target "$id"; then
                    error "hook 后 delete 目标完整性失败: $id"
                    [[ "$rollback_mode" == true ]] && { failed=true; continue; }
                    return 1
                fi
                rm -f -- "$path" || { error "目标删除失败: $id"; [[ "$rollback_mode" == true ]] && { failed=true; continue; }; return 1; }
                ;;
            noop) ;;
            *) return 1 ;;
        esac
        if [[ "$rollback_mode" == false ]]; then motd_transaction_phase_hook "target-committed-$id" || return 1; fi
    done
    [[ "$failed" == false ]]
}

motd_prepare_state_layout() {
    if [[ ! -e "$MOTD_STATE_DIR" && ! -L "$MOTD_STATE_DIR" ]]; then
        motd_ensure_parent_chain "$MOTD_STATE_DIR" || return 1
        mkdir -m 0700 -- "$MOTD_STATE_DIR" || return 1
        MOTD_STATE_DIR_CREATED=true
        chown "$MOTD_TRUSTED_UID:$MOTD_TRUSTED_GID" "$MOTD_STATE_DIR" || return 1
        motd_state_directory_created_hook "$MOTD_STATE_DIR" || return 1
    elif ! motd_validate_secure_directory "$MOTD_STATE_DIR"; then
        error "MOTD 状态目录不可信: $MOTD_STATE_DIR"
        return 1
    fi
    motd_ensure_secure_directory "$MOTD_STATE_DIR/generations" || return 1
    motd_ensure_secure_directory "$MOTD_TRANSACTION_PARENT" || return 1
}

motd_cleanup_new_state_directory() {
    [[ "$MOTD_STATE_DIR_CREATED" == true ]] || return 0
    if [[ -e "$MOTD_STATE_DIR/initial.current" || -L "$MOTD_STATE_DIR/initial.current" || -e "$MOTD_STATE_DIR/previous.current" || -L "$MOTD_STATE_DIR/previous.current" || -e "$MOTD_STATE_DIR/pending" || -L "$MOTD_STATE_DIR/pending" ]]; then return 0; fi
    motd_validate_secure_directory "$MOTD_STATE_DIR" || return 1
    rm -rf -- "$MOTD_STATE_DIR" || return 1
    MOTD_STATE_DIR_CREATED=false
}

motd_ensure_snapshot_pointer() {
    local scope="$1" result=0 unknown=false
    motd_read_pointer "$scope" >/dev/null 2>&1 && return 0
    local pointer; pointer=$(motd_pointer_path "$scope") || return 1
    [[ ! -e "$pointer" && ! -L "$pointer" ]] || return 1
    motd_import_legacy_snapshot "$scope" || result=$?
    case "$result" in
        0)
            if [[ "$scope" == initial ]]; then MOTD_INITIAL_NEW=$MOTD_LAST_GENERATION; else MOTD_PREVIOUS_NEW=$MOTD_LAST_GENERATION; fi
            motd_write_journal active || return 1
            motd_set_pointer "$scope" "$MOTD_LAST_GENERATION"
            return
            ;;
        2) ;;
        *) return 1 ;;
    esac
    [[ "$scope" == initial ]] || return 2
    motd_target_configuration_is_managed && unknown=true
    motd_create_persistent_snapshot initial "$unknown" || return 1
    MOTD_INITIAL_NEW=$MOTD_LAST_GENERATION
    motd_write_journal active || return 1
    motd_set_pointer initial "$MOTD_INITIAL_NEW"
}

motd_refresh_previous_snapshot() {
    motd_create_persistent_snapshot previous false || return 1
    MOTD_PREVIOUS_NEW=$MOTD_LAST_GENERATION
    motd_write_journal active || return 1
    motd_set_pointer previous "$MOTD_PREVIOUS_NEW"
}

motd_restore_saved_trap() {
    local signal="$1" definition="$2"
    trap - "$signal"
    [[ -z "$definition" ]] || eval "$definition"
}

motd_install_transaction_traps() {
    MOTD_SAVED_TRAP_EXIT=$(trap -p EXIT || true)
    MOTD_SAVED_TRAP_HUP=$(trap -p HUP || true)
    MOTD_SAVED_TRAP_INT=$(trap -p INT || true)
    MOTD_SAVED_TRAP_TERM=$(trap -p TERM || true)
    trap 'motd_transaction_exit_handler $?' EXIT
    trap 'motd_transaction_signal_handler HUP 129' HUP
    trap 'motd_transaction_signal_handler INT 130' INT
    trap 'motd_transaction_signal_handler TERM 143' TERM
}

motd_restore_transaction_traps() {
    local exit_trap="$MOTD_SAVED_TRAP_EXIT" hup_trap="$MOTD_SAVED_TRAP_HUP" int_trap="$MOTD_SAVED_TRAP_INT" term_trap="$MOTD_SAVED_TRAP_TERM"
    trap - EXIT HUP INT TERM
    motd_restore_saved_trap EXIT "$exit_trap"
    motd_restore_saved_trap HUP "$hup_trap"
    motd_restore_saved_trap INT "$int_trap"
    motd_restore_saved_trap TERM "$term_trap"
}

motd_transaction_signal_handler() {
    local signal="$1" status="$2" failed=false
    trap - EXIT HUP INT TERM
    warn "收到 $signal，回滚 MOTD transaction"
    if [[ "$MOTD_TRANSACTION_COMMITTED" == true ]]; then
        error "committed MOTD transaction 清理失败，保留 journal: $MOTD_TRANSACTION_DIR"; failed=true
    elif [[ "$MOTD_TRANSACTION_ACTIVE" == true ]] || motd_any_tracked_transient; then
        motd_abort_transaction || failed=true
    fi
    motd_cleanup_new_state_directory || failed=true
    motd_release_lock || failed=true
    motd_restore_transaction_traps
    [[ "$failed" == false ]] || error "MOTD 信号清理不完整，已报告残留路径"
    exit "$status"
}

motd_transaction_exit_handler() {
    local status="$1" failed=false
    trap - EXIT HUP INT TERM
    if [[ "$MOTD_TRANSACTION_COMMITTED" == true ]]; then
        error "committed MOTD transaction EXIT 清理失败，保留 journal: $MOTD_TRANSACTION_DIR"; failed=true; (( status == 0 )) && status=1
    elif [[ "$MOTD_TRANSACTION_ACTIVE" == true ]] || motd_any_tracked_transient; then
        motd_abort_transaction || failed=true
        (( status == 0 )) && status=1
    fi
    motd_cleanup_new_state_directory || failed=true
    motd_release_lock || failed=true
    motd_restore_transaction_traps
    [[ "$failed" == false ]] || { error "MOTD EXIT 清理不完整"; (( status == 0 )) && status=1; }
    exit "$status"
}

motd_install_body() {
    motd_prepare_state_layout || return 1
    motd_reconcile_state || return 1
    motd_validate_target_parents || return 1
    motd_begin_transaction install || return 1
    motd_ensure_snapshot_pointer initial || return 1
    motd_refresh_previous_snapshot || return 1
    motd_prepare_install_plan || return 1
    motd_transaction_phase_hook install-plan-ready || return 1
    motd_validate_all_target_stages || return 1
    motd_commit_target_plan install false || return 1
    motd_mark_transaction_committed || return 1
    motd_complete_transaction
}

motd_restore_body() {
    local scope="$1" result=0 generation
    motd_prepare_state_layout || return 1
    motd_reconcile_state || return 1
    motd_validate_target_parents || return 1
    motd_begin_transaction restore || return 1
    motd_ensure_snapshot_pointer "$scope" || result=$?
    (( result == 0 )) || return "$result"
    generation=$(motd_read_pointer "$scope") || return 1
    motd_prepare_snapshot_plan "$MOTD_STATE_DIR/generations/$generation" "$scope" || return 1
    motd_transaction_phase_hook restore-plan-ready || return 1
    motd_validate_all_target_stages || return 1
    motd_commit_target_plan restore false || return 1
    motd_mark_transaction_committed || return 1
    motd_complete_transaction
}

motd_run_locked_operation() {
    local operation="$1" scope="${2:-}" status=0 release_failed=false
    motd_take_lock || return 1
    motd_install_transaction_traps || { motd_release_lock || true; return 1; }
    case "$operation" in
        install) motd_install_body || status=$? ;;
        restore) motd_restore_body "$scope" || status=$? ;;
        *) status=1 ;;
    esac
    if (( status != 0 )) && { [[ "$MOTD_TRANSACTION_ACTIVE" == true || -n "$MOTD_TRANSACTION_DIR" ]] || motd_any_tracked_transient; }; then
        if [[ "$MOTD_TRANSACTION_COMMITTED" == true ]]; then
            error "committed MOTD transaction 清理失败，保留 journal: $MOTD_TRANSACTION_DIR"
        else
            motd_abort_transaction || status=1
        fi
    fi
    motd_cleanup_new_state_directory || status=1
    motd_release_lock || release_failed=true
    motd_restore_transaction_traps
    [[ "$release_failed" == false ]] || status=1
    return "$status"
}

motd_install_group() {
    info "配置动态欢迎信息..."
    motd_run_locked_operation install || return $?
    echo "欢迎信息: 已配置"
    echo; echo "预览："; echo "----------------------------------------"
    motd_preview_hook || warn "MOTD 已成功提交，但预览执行失败"
    echo "----------------------------------------"
}

motd_restore_group() {
    local scope="${1:-previous}" status=0
    [[ "$scope" == previous || "$scope" == initial ]] || return 1
    motd_run_locked_operation restore "$scope" || status=$?
    if (( status == 2 )); then warn "没有 $scope MOTD 组 snapshot"; return 2; fi
    (( status == 0 )) || return "$status"
    success "MOTD 已恢复到 $scope 状态"
}

motd_validate_target_parents() {
    local path
    motd_validate_directory_chain "$MOTD_ETC_ROOT" || return 1
    if [[ ! -e "$MOTD_ETC_ROOT/update-motd.d" && ! -L "$MOTD_ETC_ROOT/update-motd.d" ]]; then
        mkdir -m 0755 -- "$MOTD_ETC_ROOT/update-motd.d" || return 1
        chown "$MOTD_TRUSTED_UID:$MOTD_TRUSTED_GID" "$MOTD_ETC_ROOT/update-motd.d" || return 1
    fi
    motd_validate_directory_chain "$MOTD_ETC_ROOT/update-motd.d" || return 1
    for path in "${MOTD_TARGET_PATHS[@]}"; do
        if [[ -e "$path" && ! -L "$path" && ! -f "$path" ]]; then error "MOTD 目标类型不支持: $path"; return 1; fi
    done
}

motd_write_payload(){ local destination="$1"; install -m 0755 /dev/stdin "$destination" <<'SCRIPT'
#!/usr/bin/env bash
# linux-setup:managed-motd
# 由 Linux Scripts Collection 自动生成。
# 欢迎横幅与系统状态面板。

export LC_ALL=C

hostname_value=$(hostname)
kernel=$(uname -r)

uptime_value=$(uptime -p 2>/dev/null | sed 's/^up //')
if [[ -z "$uptime_value" ]]; then
    uptime_value=$(uptime | sed -E 's/.*up[[:space:]]+//; s/,[[:space:]]+[0-9]+ user.*//')
fi

ESC=$'\033'
RESET="${ESC}[0m"
BLUE_BG="${ESC}[44;37m"
ITALIC_DIM="${ESC}[2;3;37m"
LABEL="${ESC}[1;36m"
VALUE="${ESC}[37m"
GREEN="${ESC}[32m"
ORANGE="${ESC}[33m"
RED="${ESC}[31m"

pick_color() {
    local percent="$1"
    local type="$2"
    local low
    local high
    local percent_int

    case "$type" in
        disk)
            low=70
            high=90
            ;;
        *)
            low=50
            high=80
            ;;
    esac

    percent_int=$(awk -v value="$percent" 'BEGIN {printf "%d", int(value + 0.5)}')

    if (( percent_int >= high )); then
        printf '%s' "$RED"
    elif (( percent_int >= low )); then
        printf '%s' "$ORANGE"
    else
        printf '%s' "$GREEN"
    fi
}

load_average=$(awk '{printf "%.2f %.2f %.2f", $1, $2, $3}' /proc/loadavg)

memory_raw=$(awk '
    /^MemTotal:/     { total=$2 }
    /^MemAvailable:/ { available=$2 }
    END {
        used=total-available
        percent=(total > 0) ? used/total*100 : 0
        printf "%.1f|%.1f|%.1f", used/1048576, total/1048576, percent
    }
' /proc/meminfo)

memory_used="${memory_raw%%|*}G"
memory_rest="${memory_raw#*|}"
memory_total="${memory_rest%%|*}G"
memory_percent="${memory_raw##*|}"
memory_color=$(pick_color "$memory_percent" "memory")

disk_percent=$(df -P / | awk 'NR == 2 {gsub(/%/, "", $5); print $5}')
disk_usage=$(df -Ph / | awk 'NR == 2 {printf "%s / %s", $3, $2}')
disk_color=$(pick_color "$disk_percent" "disk")

printf "\n${BLUE_BG} 已连接 %s 服务器 ${RESET}\n" "$hostname_value"
printf "${ITALIC_DIM} 今天想要做些什么？${RESET}\n\n"

printf "  ${LABEL}内核${RESET}      ${VALUE}%s${RESET}\n" "$kernel"
printf "  ${LABEL}运行时间${RESET}  ${VALUE}%s${RESET}\n" "$uptime_value"
printf "  ${LABEL}CPU负载${RESET}   ${VALUE}%s${RESET}\n" "$load_average"
printf "  ${LABEL}内存${RESET}      ${VALUE}%s / %s  (${memory_color}%s%%${VALUE})${RESET}\n" \
    "$memory_used" "$memory_total" "$memory_percent"
printf "  ${LABEL}磁盘${RESET}      ${VALUE}%s  (${disk_color}%s%%${VALUE})${RESET}\n" \
    "$disk_usage" "$disk_percent"
SCRIPT
}

motd_validate_transaction_directory_contents() {
    local directory="$1" saved path name failed=false
    saved=$(shopt -p nullglob dotglob || true); shopt -s nullglob dotglob
    for path in "$directory"/*; do
        name=${path##*/}
        case "$name" in
            rollback) motd_validate_secure_directory "$path" || failed=true ;;
            journal) motd_validate_secure_file "$path" || failed=true ;;
            .journal.*) [[ "$name" =~ ^\.journal\.[0-9a-f]{32}$ ]] && motd_validate_secure_file "$path" || failed=true ;;
            *) failed=true ;;
        esac
    done
    eval "$saved"
    [[ "$failed" == false ]]
}

motd_cleanup_target_residue_for_transaction() {
    local transaction="$1" saved path name failed=false
    [[ "$transaction" =~ ^[0-9a-f]{32}$ ]] || return 1
    saved=$(shopt -p nullglob dotglob || true); shopt -s nullglob
    for path in "$MOTD_ETC_ROOT"/.linux-setup-motd.* "$MOTD_ETC_ROOT/update-motd.d"/.linux-setup-motd.*; do
        name=${path##*/}
        [[ "$name" =~ ^\.linux-setup-motd\.${transaction}\.(motd|issue|issue_net|custom_welcome|uname|motd_news)\.[0-9a-f]{32}$ ]] || { error "未知 target stage residue: $path"; failed=true; continue; }
        if [[ -d "$path" && ! -L "$path" ]] || ! rm -f -- "$path"; then error "无法清理 target stage residue: $path"; failed=true; fi
    done
    eval "$saved"
    [[ "$failed" == false ]]
}

motd_assert_no_target_residue() {
    local saved path failed=false
    saved=$(shopt -p nullglob dotglob || true); shopt -s nullglob
    for path in "$MOTD_ETC_ROOT"/.linux-setup-motd.* "$MOTD_ETC_ROOT/update-motd.d"/.linux-setup-motd.*; do
        error "未识别 target stage residue: $path"; failed=true
    done
    eval "$saved"
    [[ "$failed" == false ]]
}

readonly XANMOD_KEY_FINGERPRINT="D38D7D1DA1349567ADED882D86F7D09EE734E623"
readonly XANMOD_KEY_UID="XanMod Kernel <kernel@xanmod.org>"
readonly XANMOD_KEY_URL="https://dl.xanmod.org/archive.key"
readonly XANMOD_KEY_FALLBACK_UBUNTU="https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x${XANMOD_KEY_FINGERPRINT}"
readonly XANMOD_REPOSITORIES=(
    "https://deb.xanmod.org"
    "https://mirror.nju.edu.cn/xanmod"
    "https://mirrors.bfsu.edu.cn/xanmod"
    "https://mirrors.tuna.tsinghua.edu.cn/xanmod"
)

if [[ "${XANMOD_TEST_MODE:-0}" == "1" ]]; then
    XANMOD_KEYRING="${XANMOD_KEYRING_PATH:-/etc/apt/keyrings/xanmod-archive-keyring.gpg}"
    XANMOD_SOURCE_LIST="${XANMOD_SOURCE_LIST_PATH:-/etc/apt/sources.list.d/xanmod-release.list}"
    XANMOD_SOURCE_DEB822="${XANMOD_SOURCE_DEB822_PATH:-/etc/apt/sources.list.d/xanmod-release.sources}"
    XANMOD_LOCK="${XANMOD_LOCK_PATH:-/run/lock/xanmod-install.lock}"
    XANMOD_OS_RELEASE="${XANMOD_OS_RELEASE_PATH:-/etc/os-release}"
    XANMOD_CPUINFO="${XANMOD_CPUINFO_PATH:-/proc/cpuinfo}"
    XANMOD_BACKUP_STATE_DIR="${XANMOD_BACKUP_STATE_DIR:-/var/lib/linux-setup/apt-source-backups}"
    XANMOD_TRUSTED_UID="$EUID"
    XANMOD_TRUSTED_GID=$(id -g)
else
    XANMOD_KEYRING="/etc/apt/keyrings/xanmod-archive-keyring.gpg"
    XANMOD_SOURCE_LIST="/etc/apt/sources.list.d/xanmod-release.list"
    XANMOD_SOURCE_DEB822="/etc/apt/sources.list.d/xanmod-release.sources"
    XANMOD_LOCK="/run/lock/xanmod-install.lock"
    XANMOD_OS_RELEASE="/etc/os-release"
    XANMOD_CPUINFO="/proc/cpuinfo"
    XANMOD_BACKUP_STATE_DIR="/var/lib/linux-setup/apt-source-backups"
    XANMOD_TRUSTED_UID=0
    XANMOD_TRUSTED_GID=0
fi
readonly XANMOD_KEYRING XANMOD_SOURCE_LIST XANMOD_SOURCE_DEB822 XANMOD_LOCK
readonly XANMOD_OS_RELEASE XANMOD_CPUINFO XANMOD_BACKUP_STATE_DIR
readonly XANMOD_TRUSTED_UID XANMOD_TRUSTED_GID
readonly -a XANMOD_MANAGED_PATHS=(
    "$XANMOD_KEYRING"
    "$XANMOD_SOURCE_LIST"
    "$XANMOD_SOURCE_DEB822"
)

readonly XANMOD_ALLOCATION_NOT_CREATED=17
readonly XANMOD_ALLOCATION_FAILED_CLEAN=18
readonly XANMOD_ALLOCATION_RESIDUE_WITH_PROOF=19
readonly XANMOD_ALLOCATION_RESIDUE_WITHOUT_PROOF=20

XANMOD_ASSUME_YES=false
XANMOD_RUNTIME_SNAPSHOT_DIR=""
XANMOD_RUNTIME_SNAPSHOT_BUILDING=false
XANMOD_TRANSACTION_ACTIVE=false
XANMOD_CONFIG_MODIFIED=false
XANMOD_APT_MAY_BE_PARTIAL=false
XANMOD_STAGED_KEY=""
XANMOD_STAGED_SOURCE=""
XANMOD_CANDIDATE_SOURCE=""
XANMOD_ARMORED_KEY_TEMP=""
XANMOD_ACTIVE_APT_LISTS_DIR=""
XANMOD_ACTIVE_APT_LISTS_BUILDING=false
XANMOD_ALLOCATION_CANDIDATE=""
XANMOD_ALLOCATION_KIND=""
XANMOD_ALLOCATION_OWNER_TOKEN=""
XANMOD_ALLOCATION_EXPECTED_MODE=""
XANMOD_ALLOCATION_PROOF_OWNED=false
XANMOD_ALLOCATION_STATE=""
XANMOD_ALLOCATION_CRITICAL=false
XANMOD_ALLOCATION_PENDING_SIGNAL=""
XANMOD_ALLOCATION_PENDING_SIGNAL_STATUS=0
XANMOD_RESTORE_STAGE=""
XANMOD_SELECTED_REPOSITORY=""
XANMOD_GUARD_ACTIVE=false
XANMOD_GUARD_HANDLING=false
XANMOD_SAVED_TRAP_EXIT=""
XANMOD_SAVED_TRAP_HUP=""
XANMOD_SAVED_TRAP_INT=""
XANMOD_SAVED_TRAP_TERM=""
XANMOD_LOCK_HELD=false
XANMOD_PLAN_ACTION=""
XANMOD_PLAN_REASON=""
XANMOD_PLAN_CODENAME=""
XANMOD_PLAN_PSABI=""
XANMOD_PLAN_TARGET_PACKAGE=""
XANMOD_PLAN_INSTALLED_PACKAGES=""
XANMOD_PLAN_PACKAGE_INSTALLED=false
XANMOD_PLAN_REPOSITORY_READY=false
XANMOD_PLAN_NEEDS_REPOSITORY_CHANGE=false
XANMOD_PLAN_NEEDS_PACKAGE_INSTALL=false
XANMOD_RESTORED_COUNT=0
XANMOD_BACKUP_STATE_DIR_CREATING=false
XANMOD_BACKUP_STATE_DIR_CREATED=false
XANMOD_BACKUP_STATE_DIR_PREEXISTED=false
XANMOD_BACKUP_TRANSACTION_ACTIVE=false
XANMOD_BACKUP_SNAPSHOT_BUILDING=false
XANMOD_BACKUP_SNAPSHOT_REMOVED=false
XANMOD_BACKUP_GROUP_SNAPSHOT_DIR=""
XANMOD_BACKUP_STAGE_DIR=""
XANMOD_BACKUP_STAGE_BUILDING=false
XANMOD_BACKUP_TRANSACTION_ID=""
XANMOD_CONFIGURATION_PREVIOUSLY_MANAGED=false
XANMOD_BACKUP_SNAPSHOT_PATHS=()
XANMOD_BACKUP_LEGACY_PATHS=()
XANMOD_BACKUP_ARCHIVE_STAGED=()
XANMOD_BACKUP_ARCHIVE_FINAL=()
XANMOD_BACKUP_NEW_ARCHIVES=()

# === 日志函数 ===
log() {
    local msg="$1"
    local level="${2:-info}"
    local -A colors=(
        [info]="\033[0;36m"
        [warn]="\033[0;33m"
        [error]="\033[0;31m"
        [success]="\033[0;32m"
        [debug]="\033[0;35m"
    )

    if [[ "$level" == "debug" && "${DEBUG:-}" != "1" ]]; then
        return 0
    fi

    echo -e "${colors[$level]:-\033[0;32m}${msg}\033[0m"
}

info() {
    log "$1" "info"
}

warn() {
    log "$1" "warn"
}

error() {
    log "$1" "error"
}

success() {
    log "$1" "success"
}

require_root() {
    if (( EUID != 0 )); then
        error "需要 root 权限运行"
        exit 1
    fi
}

ask_yes_no() {
    local prompt="$1"
    local default="${2:-Y}"
    local choice

    read -r -p "$prompt" choice
    choice="${choice:-$default}"

    [[ "$choice" =~ ^[Yy]$ ]]
}

ensure_package() {
    local command_name="$1"
    local package_name="$2"

    if command -v "$command_name" >/dev/null 2>&1; then
        return 0
    fi

    info "安装依赖包: $package_name"

    if ! apt-get update -qq; then
        error "无法更新软件包索引，无法安装 $package_name"
        return 1
    fi

    if ! apt-get install -y "$package_name"; then
        error "安装依赖包失败: $package_name"
        return 1
    fi

    if ! command -v "$command_name" >/dev/null 2>&1; then
        error "依赖命令仍不可用: $command_name"
        return 1
    fi
}

backup_managed_file() {
    local file="$1"
    local backup_prefix="$file"
    local state_dir=""
    local suffix
    local legacy_state
    local state_file

    case "$file" in
        /etc/apt/sources.list.d/*)
            state_dir="/var/lib/linux-setup/apt-source-backups"
            ;;
        /etc/update-motd.d/*)
            state_dir="/var/lib/linux-setup/motd-backups"
            ;;
    esac

    if [[ -n "$state_dir" ]]; then
        install -d -m 0700 "$state_dir"
        backup_prefix="$state_dir/$(basename "$file")"

        for suffix in initial-backup previous-backup initial-absent previous-absent initial-unknown; do
            legacy_state="${file}.${suffix}"
            [[ -e "$legacy_state" || -L "$legacy_state" ]] || continue
            state_file="${backup_prefix}.${suffix}"
            if [[ -e "$state_file" || -L "$state_file" ]]; then
                state_file="${state_file}.legacy.$(date +%s).$$"
            fi
            mv "$legacy_state" "$state_file" || return 1
        done
    fi

    local initial_backup="${backup_prefix}.initial-backup"
    local previous_backup="${backup_prefix}.previous-backup"
    local initial_absent="${backup_prefix}.initial-absent"
    local previous_absent="${backup_prefix}.previous-absent"
    local initial_unknown="${backup_prefix}.initial-unknown"

    if [[ ! -e "$initial_backup" && ! -e "$initial_absent" && ! -e "$initial_unknown" ]]; then
        if [[ -f "$file" ]] &&
            grep -Eq '# linux-setup:managed-motd|由 (system-customize|setup-motd)\.sh 自动生成' "$file"; then
            install -D -m 0600 /dev/null "$initial_unknown" || return 1
        elif [[ -e "$file" || -L "$file" ]]; then
            cp -a "$file" "$initial_backup" || return 1
        else
            install -D -m 0600 /dev/null "$initial_absent" || return 1
        fi
    fi

    rm -f "$previous_backup" "$previous_absent"
    if [[ -e "$file" || -L "$file" ]]; then
        cp -a "$file" "$previous_backup" || return 1
    else
        install -D -m 0600 /dev/null "$previous_absent" || return 1
    fi
}

get_managed_backup_prefix() {
    local target="$1"
    local state_prefix

    case "$target" in
        /etc/apt/sources.list.d/*)
            state_prefix="/var/lib/linux-setup/apt-source-backups/$(basename "$target")"
            ;;
        /etc/update-motd.d/*)
            state_prefix="/var/lib/linux-setup/motd-backups/$(basename "$target")"
            ;;
        *)
            printf '%s\n' "$target"
            return 0
            ;;
    esac

    if [[ -e "${state_prefix}.initial-backup" || -e "${state_prefix}.initial-absent" ||
        -e "${state_prefix}.initial-unknown" || -e "${state_prefix}.previous-backup" ||
        -e "${state_prefix}.previous-absent" ]]; then
        printf '%s\n' "$state_prefix"
        return 0
    fi

    printf '%s\n' "$target"
}

restore_managed_file() {
    local target="$1"
    local scope="$2"
    local backup_prefix
    local backup
    local absent
    local unknown

    backup_prefix=$(get_managed_backup_prefix "$target") || return 1
    backup="${backup_prefix}.${scope}-backup"
    absent="${backup_prefix}.${scope}-absent"
    unknown="${backup_prefix}.${scope}-unknown"

    if [[ -e "$backup" || -L "$backup" ]]; then
        install -d -m 0755 "$(dirname "$target")" || return 1
        rm -f "$target" || return 1
        cp -a "$backup" "$target" || return 1
        return 0
    fi

    if [[ -e "$absent" ]]; then
        rm -f "$target" || return 1
        return 0
    fi

    if [[ -e "$unknown" ]]; then
        warn "初始状态未知，跳过恢复：$target"
        return 2
    fi

    warn "没有 $scope 配置状态，跳过恢复：$target"
    return 2
}

# === 动态欢迎信息 ===
configure_motd(){ if ! ask_yes_no "是否配置自定义动态欢迎信息？[Y/n]: " "Y";then echo "欢迎信息: 已跳过";return 0;fi;motd_install_group; }

# === 中文 Locale ===
get_locale_config_file() {
    local os_id=""
    local version_id=""
    local major_version=""

    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        os_id="${ID:-}"
        version_id="${VERSION_ID:-}"
        major_version="${version_id%%.*}"
    fi

    case "$os_id" in
        debian)
            if [[ "$major_version" =~ ^[0-9]+$ ]] && (( major_version >= 13 )); then
                echo "/etc/locale.conf"
            else
                echo "/etc/default/locale"
            fi
            ;;
        ubuntu)
            if [[ "$version_id" == "24.04" ]]; then
                echo "/etc/locale.conf"
            else
                echo "/etc/default/locale"
            fi
            ;;
        *)
            echo "/etc/default/locale"
            ;;
    esac
}

configure_chinese_locale() {
    local locale_config
    if ! ask_yes_no "是否设置系统中文环境（zh_CN.UTF-8）？[Y/n]: " "Y"; then
        echo "中文环境: 已跳过"
        return 0
    fi

    ensure_package "locale-gen" "locales" || return 1

    if ! command -v update-locale >/dev/null 2>&1; then
        error "未找到 update-locale，locales 安装可能不完整"
        return 1
    fi
    backup_managed_file /etc/locale.gen || return 1
    backup_managed_file /etc/locale.conf || return 1
    backup_managed_file /etc/default/locale || return 1

    info "配置中文 Locale..."

    sed -i \
        's/^[[:space:]]*#[[:space:]]*zh_CN.UTF-8[[:space:]]\+UTF-8/zh_CN.UTF-8 UTF-8/' \
        /etc/locale.gen

    if ! grep -Fxq "zh_CN.UTF-8 UTF-8" /etc/locale.gen; then
        echo "zh_CN.UTF-8 UTF-8" >> /etc/locale.gen
    fi

    locale-gen

    locale_config=$(get_locale_config_file)

    # LC_ALL 不应写入系统 Locale 配置，否则会覆盖所有分类设置。
    if [[ -f "$locale_config" ]]; then
        sed -i '/^LC_ALL=/d' "$locale_config"
    fi

    update-locale \
        --locale-file "$locale_config" \
        LANG=zh_CN.UTF-8 \
        LANGUAGE=zh_CN:zh

    success "中文环境已配置"
    echo "说明: 当前 SSH 会话需重新登录后完全生效。"
    echo "当前会话可执行: unset LC_ALL && exec zsh"
    echo "系统 Locale 配置（$locale_config）:"
    cat "$locale_config"
}

# === XanMod 内核 ===
require_xanmod_commands() {
    local command_name
    for command_name in "$@"; do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            error "缺少必要命令: $command_name"
            return 1
        fi
    done
}

is_interactive_terminal() {
    [[ -t 0 && -t 1 ]]
}

confirm_xanmod_install() {
    local choice=""
    if ! read -r -p "是否执行以上 XanMod 修改？[y/N]: " choice; then
        return 1
    fi
    [[ "$choice" =~ ^[Yy]$ ]]
}

authorize_xanmod_install() {
    if [[ "$XANMOD_ASSUME_YES" == "true" ]]; then
        return 0
    fi
    if ! is_interactive_terminal; then
        error "非交互执行 XanMod 修改必须显式传入 --yes"
        return 1
    fi
    if confirm_xanmod_install; then
        return 0
    fi
    echo "XanMod 修改: 已取消"
    return 2
}
get_os_codename() {
    if [[ -r "$XANMOD_OS_RELEASE" ]]; then
        # shellcheck disable=SC1090
        . "$XANMOD_OS_RELEASE"
        if [[ -n "${VERSION_CODENAME:-}" ]]; then
            echo "$VERSION_CODENAME"
            return 0
        fi
    fi

    if command -v lsb_release >/dev/null 2>&1; then
        lsb_release -sc
        return 0
    fi

    return 1
}

xanmod_codename_safe() {
    [[ "$1" =~ ^[a-z0-9][a-z0-9.+-]*$ ]]
}

xanmod_codename_supported() {
    xanmod_codename_safe "$1" || return 1
    case "$1" in
        bookworm|trixie|noble) return 0 ;;
        *) return 1 ;;
    esac
}

is_amd64() {
    [[ "$(dpkg --print-architecture)" == "amd64" ]] &&
        [[ "$(uname -m)" == "x86_64" || "$(uname -m)" == "amd64" ]]
}

package_is_installed() {
    dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null |
        grep -qx "installed"
}

get_running_xanmod_package() {
    case "$(uname -r)" in
        *-x64v3-xanmod*) echo "linux-xanmod-x64v3" ;;
        *-x64v2-xanmod*) echo "linux-xanmod-x64v2" ;;
        *) return 1 ;;
    esac
}

# 可选文件参数供离线 CPU 特征测试使用。
# shellcheck disable=SC2120
detect_x86_64_psabi_level() {
    local cpuinfo_file="${1:-$XANMOD_CPUINFO}"

    [[ -r "$cpuinfo_file" ]] || return 3
    awk '
        function has(name) { return index(flags, " " name " ") > 0 }
        BEGIN { found = 0 }
        /^flags[[:space:]]*:/ {
            found = 1
            flags = " " $0 " "
            level = 0
            if (has("lm") && has("cmov") && has("cx8") && has("fpu") &&
                has("fxsr") && has("mmx") && has("syscall") && has("sse2")) level = 1
            if (level == 1 && has("cx16") && has("lahf_lm") && has("popcnt") &&
                has("sse4_1") && has("sse4_2") && has("ssse3")) level = 2
            if (level == 2 && has("avx") && has("avx2") && has("bmi1") &&
                has("bmi2") && has("f16c") && has("fma") &&
                (has("abm") || has("lzcnt")) && has("movbe") && has("xsave")) level = 3
            if (level == 3 && has("avx512f") && has("avx512bw") &&
                has("avx512cd") && has("avx512dq") && has("avx512vl")) level = 4
            if (level > 0) { print "v" level; exit 0 }
            exit 2
        }
        END { if (!found) exit 3 }
    ' "$cpuinfo_file"
}

get_xanmod_package_for_psabi_level() {
    case "$1" in
        v4|v3) echo "linux-xanmod-x64v3" ;;
        v2) echo "linux-xanmod-x64v2" ;;
        *) return 1 ;;
    esac
}

detect_xanmod_package() {
    local psabi_level

    is_amd64 || return 1
    if psabi_level=$(detect_x86_64_psabi_level); then
        if [[ "$psabi_level" == "v1" ]]; then
            return 2
        fi
        get_xanmod_package_for_psabi_level "$psabi_level"
    else
        return $?
    fi
}

xanmod_regular_file_trusted() {
    local file="$1"
    local expected_mode="$2"
    local metadata=""

    [[ -f "$file" && ! -L "$file" ]] || return 1
    metadata=$(stat -c '%u:%g:%a' -- "$file") || return 1
    [[ "$metadata" == "$XANMOD_TRUSTED_UID:$XANMOD_TRUSTED_GID:$expected_mode" ]]
}

set_xanmod_staged_file_metadata() {
    local file="$1"

    [[ -f "$file" && ! -L "$file" ]] || return 1
    if [[ "${XANMOD_TEST_MODE:-0}" == "1" ]]; then
        [[ "$(stat -c '%u' -- "$file")" == "$XANMOD_TRUSTED_UID" ]] || return 1
        chgrp "$XANMOD_TRUSTED_GID" "$file" || return 1
    else
        chown 0:0 "$file" || return 1
    fi
    chmod 0644 "$file" || return 1
    xanmod_regular_file_trusted "$file" 644
}

xanmod_keyring_valid() {
    local key_file="${1:-$XANMOD_KEYRING}"

    [[ -s "$key_file" ]] || return 1
    command -v gpg >/dev/null 2>&1 || return 1
    gpg --batch --show-keys --with-colons "$key_file" 2>/dev/null |
        awk -F: -v expected_fingerprint="$XANMOD_KEY_FINGERPRINT" \
            -v expected_uid="$XANMOD_KEY_UID" '
            $1 == "pub" {
                pub_count++
                waiting_for_primary_fingerprint = 1
                next
            }
            $1 == "sub" {
                waiting_for_primary_fingerprint = 0
                next
            }
            $1 == "fpr" && waiting_for_primary_fingerprint {
                primary_fingerprint_count++
                if ($10 == expected_fingerprint) fingerprint_matches = 1
                waiting_for_primary_fingerprint = 0
                next
            }
            $1 == "uid" && $10 == expected_uid { uid_matches = 1 }
            END {
                exit !(pub_count == 1 && primary_fingerprint_count == 1 &&
                    fingerprint_matches && uid_matches)
            }
        '
}

xanmod_formal_keyring_valid() {
    xanmod_regular_file_trusted "$XANMOD_KEYRING" 644 &&
        xanmod_keyring_valid "$XANMOD_KEYRING"
}

xanmod_list_source_configured() {
    xanmod_formal_keyring_valid &&
        xanmod_regular_file_trusted "$XANMOD_SOURCE_LIST" 644 &&
        awk -v expected_key="$XANMOD_KEYRING" '
            /^[[:space:]]*($|#)/ { next }
            {
                line_count++
                if (NF == 5 && $1 == "deb" &&
                    $2 == "[signed-by=" expected_key "]" &&
                    $3 ~ /^https:\/\/(deb\.xanmod\.org|mirror\.nju\.edu\.cn\/xanmod|mirrors\.bfsu\.edu\.cn\/xanmod|mirrors\.tuna\.tsinghua\.edu\.cn\/xanmod)\/?$/ &&
                    $4 ~ /^[a-z0-9][a-z0-9.+-]*$/ && $5 == "main") valid_count++
                else invalid = 1
            }
            END { exit !(line_count == 1 && valid_count == 1 && !invalid) }
        ' "$XANMOD_SOURCE_LIST"
}

xanmod_deb822_source_configured() {
    xanmod_formal_keyring_valid &&
        xanmod_regular_file_trusted "$XANMOD_SOURCE_DEB822" 644 &&
        awk -F: -v expected_key="$XANMOD_KEYRING" '
            function trim(value) {
                sub(/^[[:space:]]+/, "", value)
                sub(/[[:space:]]+$/, "", value)
                return value
            }
            /^[[:space:]]*($|#)/ { next }
            {
                name=trim($1)
                value=trim(substr($0, index($0, ":") + 1))
                if (name == "Types" && value == "deb") types++
                else if (name == "URIs" &&
                    value ~ /^https:\/\/(deb\.xanmod\.org|mirror\.nju\.edu\.cn\/xanmod|mirrors\.bfsu\.edu\.cn\/xanmod|mirrors\.tuna\.tsinghua\.edu\.cn\/xanmod)\/?$/) uris++
                else if (name == "Suites" && value ~ /^[a-z0-9][a-z0-9.+-]*$/) suites++
                else if (name == "Components" && value == "main") components++
                else if (name == "Signed-By" && value == expected_key) signed_by++
                else invalid = 1
            }
            END {
                exit !(types == 1 && uris == 1 && suites == 1 && components == 1 &&
                    signed_by == 1 && !invalid)
            }
        ' "$XANMOD_SOURCE_DEB822"
}

get_xanmod_source_file() {
    if xanmod_deb822_source_configured; then
        echo "$XANMOD_SOURCE_DEB822"
    elif xanmod_list_source_configured; then
        echo "$XANMOD_SOURCE_LIST"
    else
        return 1
    fi
}

xanmod_source_matches_codename() {
    local source_file="$1"
    local codename="$2"

    xanmod_codename_safe "$codename" || return 1
    case "$source_file" in
        *.sources)
            awk -F: -v expected="$codename" '
                function trim(value) {
                    sub(/^[[:space:]]+/, "", value)
                    sub(/[[:space:]]+$/, "", value)
                    return value
                }
                /^[[:space:]]*($|#)/ { next }
                {
                    name=trim($1)
                    value=trim(substr($0, index($0, ":") + 1))
                    if (name == "Suites") {
                        suite_count++
                        suite=value
                    }
                }
                END { exit !(suite_count == 1 && suite == expected) }
            ' "$source_file"
            ;;
        *)
            awk -v expected="$codename" '
                /^[[:space:]]*($|#)/ { next }
                {
                    line_count++
                    if (NF == 5 && $1 == "deb" && $4 == expected && $5 == "main")
                        valid_count++
                    else
                        invalid=1
                }
                END { exit !(line_count == 1 && valid_count == 1 && !invalid) }
            ' "$source_file"
            ;;
    esac
}

write_xanmod_deb822_source() {
    local source_file="$1"
    local repository="$2"
    local codename="$3"
    local keyring_path="${4:-$XANMOD_KEYRING}"

    xanmod_codename_safe "$codename" || return 1
    cat > "$source_file" <<EOF
Types: deb
URIs: $repository
Suites: $codename
Components: main
Signed-By: $keyring_path
EOF
}

remove_xanmod_temp_directory() {
    local path="$1"
    local label="$2"

    [[ -n "$path" ]] || return 0
    if rm -rf -- "$path"; then
        return 0
    fi
    error "$label 残留: $path"
    return 1
}

remove_xanmod_temp_file() {
    local path="$1"
    local label="$2"

    [[ -n "$path" ]] || return 0
    if rm -f -- "$path"; then
        return 0
    fi
    error "$label 残留: $path"
    return 1
}

xanmod_random_token() {
    local token=""

    token=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n') || return 1
    [[ "$token" =~ ^[0-9a-f]{32}$ ]] || return 1
    printf '%s\n' "$token"
}

xanmod_allocation_proof_path() {
    local kind="$1"
    local candidate="$2"
    local owner_token="$3"

    case "$kind" in
        directory) printf '%s/.xanmod-allocation-owner\n' "$candidate" ;;
        file) printf '%s.xanmod-owner.%s\n' "$candidate" "$owner_token" ;;
        *) return 1 ;;
    esac
}

xanmod_create_allocation_proof_file() {
    local proof_path="$1"

    (umask 077; set -o noclobber; : > "$proof_path") 2>/dev/null
}

xanmod_write_allocation_proof() {
    local proof_path="$1"
    local owner_token="$2"
    local identity="$3"

    printf '%s\n%s\n' "$owner_token" "$identity" > "$proof_path"
}

xanmod_cleanup_created_allocation() {
    local kind="$1"
    local path="$2"
    local proof_path="$3"
    local proof_owned="$4"
    local cleanup_failed=false

    case "$kind" in
        directory)
            if [[ -e "$path" || -L "$path" ]]; then
                if [[ ! -d "$path" || -L "$path" ]]; then
                    error "XanMod 自有临时目录类型已变化，保留路径: $path"
                    cleanup_failed=true
                else
                    if [[ "$proof_owned" == true && ( -e "$proof_path" || -L "$proof_path" ) ]]; then
                        if [[ ! -f "$proof_path" || -L "$proof_path" ]]; then
                            error "XanMod 自有分配 proof 类型已变化，保留路径: $proof_path"
                            cleanup_failed=true
                        elif ! remove_xanmod_temp_file "$proof_path" "XanMod 自有分配 proof"; then
                            cleanup_failed=true
                        fi
                    fi
                    if ! rmdir -- "$path"; then
                        error "XanMod 自有临时目录残留: $path"
                        cleanup_failed=true
                    fi
                fi
            fi
            ;;
        file)
            if [[ "$proof_owned" == true && ( -e "$proof_path" || -L "$proof_path" ) ]]; then
                if [[ ! -f "$proof_path" || -L "$proof_path" ]]; then
                    error "XanMod 自有分配 proof 类型已变化，保留路径: $proof_path"
                    cleanup_failed=true
                elif ! remove_xanmod_temp_file "$proof_path" "XanMod 自有分配 proof"; then
                    cleanup_failed=true
                fi
            fi
            if [[ -e "$path" || -L "$path" ]]; then
                if [[ ! -f "$path" || -L "$path" ]]; then
                    error "XanMod 自有临时文件类型已变化，保留路径: $path"
                    cleanup_failed=true
                elif ! remove_xanmod_temp_file "$path" "XanMod 自有临时文件"; then
                    cleanup_failed=true
                fi
            fi
            ;;
        *) return 1 ;;
    esac

    [[ "$cleanup_failed" == false ]]
}

xanmod_create_temp_directory_at_path() {
    local path="$1"
    local mode="$2"
    local proof_path=""
    local identity=""
    local proof_owned=false

    proof_path=$(xanmod_allocation_proof_path directory "$path" "$XANMOD_ALLOCATION_OWNER_TOKEN") || return 1
    if ! mkdir -m "$mode" -- "$path" 2>/dev/null; then
        return "$XANMOD_ALLOCATION_NOT_CREATED"
    fi
    if ! identity=$(stat -c '%d:%i' -- "$path"); then
        error "无法读取新建 XanMod 临时目录 identity: $path"
    elif ! xanmod_create_allocation_proof_file "$proof_path"; then
        error "无法排他创建 XanMod 分配 proof: $proof_path"
    else
        proof_owned=true
        if xanmod_write_allocation_proof \
            "$proof_path" "$XANMOD_ALLOCATION_OWNER_TOKEN" "$identity"; then
            return 0
        fi
        error "写入 XanMod 分配 proof 失败: $proof_path"
    fi

    if xanmod_cleanup_created_allocation directory \
        "$path" "$proof_path" "$proof_owned"; then
        return "$XANMOD_ALLOCATION_FAILED_CLEAN"
    fi
    if [[ "$proof_owned" == true ]]; then
        return "$XANMOD_ALLOCATION_RESIDUE_WITH_PROOF"
    fi
    return "$XANMOD_ALLOCATION_RESIDUE_WITHOUT_PROOF"
}

xanmod_create_temp_file_at_path() {
    local path="$1"
    local mode="$2"
    local proof_path=""
    local identity=""
    local proof_owned=false

    [[ "$mode" == "0600" || "$mode" == "600" ]] || return 1
    proof_path=$(xanmod_allocation_proof_path file "$path" "$XANMOD_ALLOCATION_OWNER_TOKEN") || return 1
    if ! (umask 077; set -o noclobber; : > "$path") 2>/dev/null; then
        return "$XANMOD_ALLOCATION_NOT_CREATED"
    fi
    if ! identity=$(stat -c '%d:%i' -- "$path"); then
        error "无法读取新建 XanMod 临时文件 identity: $path"
    elif ! xanmod_create_allocation_proof_file "$proof_path"; then
        error "无法排他创建 XanMod 分配 proof: $proof_path"
    else
        proof_owned=true
        if xanmod_write_allocation_proof \
            "$proof_path" "$XANMOD_ALLOCATION_OWNER_TOKEN" "$identity"; then
            return 0
        fi
        error "写入 XanMod 分配 proof 失败: $proof_path"
    fi

    if xanmod_cleanup_created_allocation file \
        "$path" "$proof_path" "$proof_owned"; then
        return "$XANMOD_ALLOCATION_FAILED_CLEAN"
    fi
    if [[ "$proof_owned" == true ]]; then
        return "$XANMOD_ALLOCATION_RESIDUE_WITH_PROOF"
    fi
    return "$XANMOD_ALLOCATION_RESIDUE_WITHOUT_PROOF"
}

xanmod_begin_pending_allocation() {
    local kind="$1"
    local candidate="$2"
    local mode="$3"
    local owner_token="$4"

    if [[ -n "$XANMOD_ALLOCATION_CANDIDATE" || -n "$XANMOD_ALLOCATION_STATE" ]]; then
        error "XanMod 临时资源分配生命周期尚未结束"
        return 1
    fi
    [[ "$kind" == directory || "$kind" == file ]] || return 1
    [[ "$owner_token" =~ ^[0-9A-Za-z_-]+$ ]] || return 1
    XANMOD_ALLOCATION_CANDIDATE="$candidate"
    XANMOD_ALLOCATION_KIND="$kind"
    XANMOD_ALLOCATION_OWNER_TOKEN="$owner_token"
    XANMOD_ALLOCATION_EXPECTED_MODE="${mode#0}"
    XANMOD_ALLOCATION_PROOF_OWNED=false
    XANMOD_ALLOCATION_STATE=candidate
}

xanmod_clear_pending_allocation() {
    XANMOD_ALLOCATION_CANDIDATE=""
    XANMOD_ALLOCATION_KIND=""
    XANMOD_ALLOCATION_OWNER_TOKEN=""
    XANMOD_ALLOCATION_EXPECTED_MODE=""
    XANMOD_ALLOCATION_PROOF_OWNED=false
    XANMOD_ALLOCATION_STATE=""
}

xanmod_begin_allocation_critical_section() {
    if [[ "$XANMOD_ALLOCATION_CRITICAL" == true ]]; then
        error "XanMod 分配结果提交临界区已经启用"
        return 1
    fi
    XANMOD_ALLOCATION_PENDING_SIGNAL=""
    XANMOD_ALLOCATION_PENDING_SIGNAL_STATUS=0
    XANMOD_ALLOCATION_CRITICAL=true
}

xanmod_end_allocation_critical_section() {
    local signal_name=""
    local signal_status=0

    XANMOD_ALLOCATION_CRITICAL=false
    signal_name="$XANMOD_ALLOCATION_PENDING_SIGNAL"
    signal_status="$XANMOD_ALLOCATION_PENDING_SIGNAL_STATUS"
    XANMOD_ALLOCATION_PENDING_SIGNAL=""
    XANMOD_ALLOCATION_PENDING_SIGNAL_STATUS=0
    if [[ -n "$signal_name" ]]; then
        xanmod_transaction_signal_handler "$signal_name" "$signal_status"
    fi
}

xanmod_after_allocation_attempt_hook() {
    :
}

xanmod_run_pending_allocation_create() {
    # 子进程忽略事务信号，避免停在“已创建但尚未写入所有权证明”的窗口。
    # 父 shell 仍保留事务 trap，并在创建调用返回后按 proof 状态清理。
    (
        trap '' HUP INT TERM
        case "$XANMOD_ALLOCATION_KIND" in
            directory)
                xanmod_create_temp_directory_at_path \
                    "$XANMOD_ALLOCATION_CANDIDATE" "$XANMOD_ALLOCATION_EXPECTED_MODE"
                ;;
            file)
                xanmod_create_temp_file_at_path \
                    "$XANMOD_ALLOCATION_CANDIDATE" "$XANMOD_ALLOCATION_EXPECTED_MODE"
                ;;
            *) return 1 ;;
        esac
    )
}

xanmod_pending_allocation_proof_trusted() {
    local proof_path=""
    local metadata=""
    local proof_token=""
    local proof_identity=""
    local extra_line=""

    [[ -n "$XANMOD_ALLOCATION_CANDIDATE" &&
        -n "$XANMOD_ALLOCATION_OWNER_TOKEN" ]] || return 1
    proof_path=$(xanmod_allocation_proof_path \
        "$XANMOD_ALLOCATION_KIND" "$XANMOD_ALLOCATION_CANDIDATE" \
        "$XANMOD_ALLOCATION_OWNER_TOKEN") || return 1
    [[ -f "$proof_path" && ! -L "$proof_path" ]] || return 1
    metadata=$(stat -c '%u:%g:%a' -- "$proof_path") || return 1
    [[ "$metadata" == "$XANMOD_TRUSTED_UID:$XANMOD_TRUSTED_GID:600" ]] || return 1
    {
        IFS= read -r proof_token || return 1
        IFS= read -r proof_identity || return 1
        if IFS= read -r extra_line; then
            return 1
        fi
    } < "$proof_path"
    [[ "$proof_token" == "$XANMOD_ALLOCATION_OWNER_TOKEN" &&
        "$proof_identity" =~ ^[0-9]+:[0-9]+$ ]]
}

xanmod_pending_allocation_owned() {
    local metadata=""
    local identity=""
    local proof_path=""
    local proof_token=""
    local proof_identity=""

    xanmod_pending_allocation_proof_trusted || return 1
    case "$XANMOD_ALLOCATION_KIND" in
        directory)
            [[ -d "$XANMOD_ALLOCATION_CANDIDATE" &&
                ! -L "$XANMOD_ALLOCATION_CANDIDATE" ]] || return 1
            ;;
        file)
            [[ -f "$XANMOD_ALLOCATION_CANDIDATE" &&
                ! -L "$XANMOD_ALLOCATION_CANDIDATE" ]] || return 1
            ;;
        *) return 1 ;;
    esac
    metadata=$(stat -c '%u:%g:%a' -- "$XANMOD_ALLOCATION_CANDIDATE") || return 1
    [[ "$metadata" == "$XANMOD_TRUSTED_UID:$XANMOD_TRUSTED_GID:$XANMOD_ALLOCATION_EXPECTED_MODE" ]] || return 1
    identity=$(stat -c '%d:%i' -- "$XANMOD_ALLOCATION_CANDIDATE") || return 1
    proof_path=$(xanmod_allocation_proof_path \
        "$XANMOD_ALLOCATION_KIND" "$XANMOD_ALLOCATION_CANDIDATE" \
        "$XANMOD_ALLOCATION_OWNER_TOKEN") || return 1
    {
        IFS= read -r proof_token || return 1
        IFS= read -r proof_identity || return 1
    } < "$proof_path"
    [[ "$proof_token" == "$XANMOD_ALLOCATION_OWNER_TOKEN" &&
        "$identity" == "$proof_identity" ]]
}

xanmod_mark_pending_allocation_residue() {
    local create_status="$1"
    local proof_path=""
    local residue_reported=false

    case "$create_status" in
        "$XANMOD_ALLOCATION_RESIDUE_WITH_PROOF")
            XANMOD_ALLOCATION_PROOF_OWNED=true
            ;;
        "$XANMOD_ALLOCATION_RESIDUE_WITHOUT_PROOF")
            XANMOD_ALLOCATION_PROOF_OWNED=false
            ;;
        *) return 1 ;;
    esac
    XANMOD_ALLOCATION_STATE=residue
    if [[ -e "$XANMOD_ALLOCATION_CANDIDATE" || -L "$XANMOD_ALLOCATION_CANDIDATE" ]]; then
        error "XanMod 自有临时资源残留: $XANMOD_ALLOCATION_CANDIDATE"
        residue_reported=true
    fi
    if [[ "$XANMOD_ALLOCATION_PROOF_OWNED" == true ]]; then
        proof_path=$(xanmod_allocation_proof_path \
            "$XANMOD_ALLOCATION_KIND" "$XANMOD_ALLOCATION_CANDIDATE" \
            "$XANMOD_ALLOCATION_OWNER_TOKEN") || return 1
        if [[ -e "$proof_path" || -L "$proof_path" ]]; then
            error "XanMod 自有分配 proof 残留: $proof_path"
            residue_reported=true
        fi
    fi
    if [[ "$residue_reported" == false ]]; then
        error "XanMod 自有临时资源清理状态不完整: $XANMOD_ALLOCATION_CANDIDATE"
    fi
    return 0
}

xanmod_release_pending_allocation_proof() {
    local proof_path=""

    if ! xanmod_pending_allocation_owned; then
        error "XanMod 分配所有权证明不可信: $XANMOD_ALLOCATION_CANDIDATE"
        return 1
    fi
    proof_path=$(xanmod_allocation_proof_path \
        "$XANMOD_ALLOCATION_KIND" "$XANMOD_ALLOCATION_CANDIDATE" \
        "$XANMOD_ALLOCATION_OWNER_TOKEN") || return 1
    if ! rm -f -- "$proof_path"; then
        error "XanMod 分配所有权标记残留: $proof_path"
        return 1
    fi
}

cleanup_xanmod_pending_allocation() {
    local proof_path=""

    if [[ -z "$XANMOD_ALLOCATION_CANDIDATE" ]]; then
        xanmod_clear_pending_allocation
        return 0
    fi
    proof_path=$(xanmod_allocation_proof_path \
        "$XANMOD_ALLOCATION_KIND" "$XANMOD_ALLOCATION_CANDIDATE" \
        "$XANMOD_ALLOCATION_OWNER_TOKEN") || return 1

    if [[ "$XANMOD_ALLOCATION_STATE" == residue ||
        "$XANMOD_ALLOCATION_PROOF_OWNED" == true ]]; then
        if ! xanmod_cleanup_created_allocation \
            "$XANMOD_ALLOCATION_KIND" "$XANMOD_ALLOCATION_CANDIDATE" \
            "$proof_path" "$XANMOD_ALLOCATION_PROOF_OWNED"; then
            return 1
        fi
    elif xanmod_pending_allocation_owned; then
        XANMOD_ALLOCATION_STATE=residue
        XANMOD_ALLOCATION_PROOF_OWNED=true
        if ! xanmod_cleanup_created_allocation \
            "$XANMOD_ALLOCATION_KIND" "$XANMOD_ALLOCATION_CANDIDATE" \
            "$proof_path" true; then
            return 1
        fi
    elif [[ "$XANMOD_ALLOCATION_KIND" == file &&
        ! -e "$XANMOD_ALLOCATION_CANDIDATE" &&
        ! -L "$XANMOD_ALLOCATION_CANDIDATE" ]] &&
        xanmod_pending_allocation_proof_trusted; then
        XANMOD_ALLOCATION_STATE=residue
        XANMOD_ALLOCATION_PROOF_OWNED=true
        if ! xanmod_cleanup_created_allocation file \
            "$XANMOD_ALLOCATION_CANDIDATE" "$proof_path" true; then
            return 1
        fi
    else
        # 没有可信 proof 或 owned-residue 状态的 candidate 可能是冲突对象。
        # 只清内存状态，绝不删除该路径。
        xanmod_clear_pending_allocation
        return 0
    fi

    xanmod_clear_pending_allocation
}

xanmod_finish_pending_allocation() {
    local path_variable="$1"
    local building_variable="${2:-}"

    if ! xanmod_pending_allocation_owned; then
        XANMOD_ALLOCATION_PROOF_OWNED=true
        XANMOD_ALLOCATION_STATE=residue
        error "XanMod 新建临时资源未通过所有权校验: $XANMOD_ALLOCATION_CANDIDATE"
        return 1
    fi
    XANMOD_ALLOCATION_STATE=owned
    XANMOD_ALLOCATION_PROOF_OWNED=true
    printf -v "$path_variable" '%s' "$XANMOD_ALLOCATION_CANDIDATE"
    if [[ -n "$building_variable" ]]; then
        printf -v "$building_variable" '%s' true
    fi
    XANMOD_ALLOCATION_STATE=active
    xanmod_release_pending_allocation_proof || return 1
    xanmod_clear_pending_allocation
}

xanmod_allocate_temp_directory() {
    local path_variable="$1"
    local building_variable="$2"
    local parent="$3"
    local prefix="$4"
    local mode="$5"
    local token=""
    local owner_token=""
    local candidate=""
    local create_status=0
    local candidate_conflict=false
    local attempt

    [[ -d "$parent" && ! -L "$parent" ]] || return 1
    [[ -z "$XANMOD_ALLOCATION_CANDIDATE" && -z "$XANMOD_ALLOCATION_STATE" ]] || return 1
    printf -v "$path_variable" '%s' ""
    printf -v "$building_variable" '%s' false
    for attempt in {1..64}; do
        token=$(xanmod_random_token) || return 1
        owner_token=$(xanmod_random_token) || return 1
        candidate="$parent/$prefix.$token"
        xanmod_begin_pending_allocation directory "$candidate" "$mode" "$owner_token" || return 1
        xanmod_begin_allocation_critical_section || return 1
        create_status=0
        xanmod_run_pending_allocation_create || create_status=$?
        case "$create_status" in
            0)
                XANMOD_ALLOCATION_PROOF_OWNED=true
                XANMOD_ALLOCATION_STATE=owned
                ;;
            "$XANMOD_ALLOCATION_NOT_CREATED")
                candidate_conflict=false
                [[ -e "$candidate" || -L "$candidate" ]] && candidate_conflict=true
                xanmod_clear_pending_allocation
                ;;
            "$XANMOD_ALLOCATION_FAILED_CLEAN")
                xanmod_clear_pending_allocation
                ;;
            "$XANMOD_ALLOCATION_RESIDUE_WITH_PROOF"|"$XANMOD_ALLOCATION_RESIDUE_WITHOUT_PROOF")
                xanmod_mark_pending_allocation_residue "$create_status"
                ;;
            *)
                if xanmod_pending_allocation_owned; then
                    XANMOD_ALLOCATION_PROOF_OWNED=true
                    XANMOD_ALLOCATION_STATE=residue
                else
                    xanmod_clear_pending_allocation
                fi
                ;;
        esac
        xanmod_end_allocation_critical_section
        xanmod_after_allocation_attempt_hook directory "$candidate" "$create_status" || true
        case "$create_status" in
            0)
                xanmod_finish_pending_allocation "$path_variable" "$building_variable"
                return
                ;;
            "$XANMOD_ALLOCATION_NOT_CREATED")
                if [[ "$candidate_conflict" == true ]]; then
                    continue
                fi
                return 1
                ;;
            *) return 1 ;;
        esac
    done
    return 1
}

xanmod_allocate_temp_file() {
    local path_variable="$1"
    local parent="$2"
    local prefix="$3"
    local suffix="$4"
    local mode="$5"
    local token=""
    local owner_token=""
    local candidate=""
    local create_status=0
    local candidate_conflict=false
    local attempt

    [[ -d "$parent" && ! -L "$parent" ]] || return 1
    [[ -z "$XANMOD_ALLOCATION_CANDIDATE" && -z "$XANMOD_ALLOCATION_STATE" ]] || return 1
    printf -v "$path_variable" '%s' ""
    for attempt in {1..64}; do
        token=$(xanmod_random_token) || return 1
        owner_token=$(xanmod_random_token) || return 1
        candidate="$parent/$prefix.$token$suffix"
        xanmod_begin_pending_allocation file "$candidate" "$mode" "$owner_token" || return 1
        xanmod_begin_allocation_critical_section || return 1
        create_status=0
        xanmod_run_pending_allocation_create || create_status=$?
        case "$create_status" in
            0)
                XANMOD_ALLOCATION_PROOF_OWNED=true
                XANMOD_ALLOCATION_STATE=owned
                ;;
            "$XANMOD_ALLOCATION_NOT_CREATED")
                candidate_conflict=false
                [[ -e "$candidate" || -L "$candidate" ]] && candidate_conflict=true
                xanmod_clear_pending_allocation
                ;;
            "$XANMOD_ALLOCATION_FAILED_CLEAN")
                xanmod_clear_pending_allocation
                ;;
            "$XANMOD_ALLOCATION_RESIDUE_WITH_PROOF"|"$XANMOD_ALLOCATION_RESIDUE_WITHOUT_PROOF")
                xanmod_mark_pending_allocation_residue "$create_status"
                ;;
            *)
                if xanmod_pending_allocation_owned; then
                    XANMOD_ALLOCATION_PROOF_OWNED=true
                    XANMOD_ALLOCATION_STATE=residue
                else
                    xanmod_clear_pending_allocation
                fi
                ;;
        esac
        xanmod_end_allocation_critical_section
        xanmod_after_allocation_attempt_hook file "$candidate" "$create_status" || true
        case "$create_status" in
            0)
                xanmod_finish_pending_allocation "$path_variable"
                return
                ;;
            "$XANMOD_ALLOCATION_NOT_CREATED")
                if [[ "$candidate_conflict" == true ]]; then
                    continue
                fi
                return 1
                ;;
            *) return 1 ;;
        esac
    done
    return 1
}

cleanup_xanmod_active_apt_lists() {
    if [[ -z "$XANMOD_ACTIVE_APT_LISTS_DIR" ]]; then
        XANMOD_ACTIVE_APT_LISTS_BUILDING=false
        return 0
    fi
    if [[ ! -e "$XANMOD_ACTIVE_APT_LISTS_DIR" && ! -L "$XANMOD_ACTIVE_APT_LISTS_DIR" ]] ||
        remove_xanmod_temp_directory "$XANMOD_ACTIVE_APT_LISTS_DIR" "临时 APT lists"; then
        XANMOD_ACTIVE_APT_LISTS_DIR=""
        XANMOD_ACTIVE_APT_LISTS_BUILDING=false
        return 0
    fi
    return 1
}

xanmod_source_is_usable() {
    local source_file="$1"
    local apt_status=0
    local temp_parent="${TMPDIR:-/tmp}"

    xanmod_allocate_temp_directory XANMOD_ACTIVE_APT_LISTS_DIR \
        XANMOD_ACTIVE_APT_LISTS_BUILDING "$temp_parent" xanmod-apt-lists 0755 || return 1
    XANMOD_ACTIVE_APT_LISTS_BUILDING=false
    if ! install -d -m 0755 "$XANMOD_ACTIVE_APT_LISTS_DIR/partial"; then
        cleanup_xanmod_active_apt_lists || true
        return 1
    fi

    if apt-get update -qq \
        -o "Dir::Etc::sourcelist=$source_file" \
        -o 'Dir::Etc::sourceparts=-' \
        -o "Dir::State::lists=$XANMOD_ACTIVE_APT_LISTS_DIR" \
        -o 'APT::Get::List-Cleanup=0'; then
        apt_status=0
    else
        apt_status=$?
    fi

    if ! cleanup_xanmod_active_apt_lists; then
        return 125
    fi
    return "$apt_status"
}

capture_xanmod_snapshot_item() {
    local target="$1"
    local snapshot_prefix="$2"

    if [[ -L "$target" ]]; then
        printf '%s\n' symlink > "${snapshot_prefix}.state" || return 1
        cp -a -- "$target" "${snapshot_prefix}.data" || return 1
    elif [[ -f "$target" ]]; then
        printf '%s\n' file > "${snapshot_prefix}.state" || return 1
        cp -a -- "$target" "${snapshot_prefix}.data" || return 1
    elif [[ ! -e "$target" ]]; then
        printf '%s\n' absent > "${snapshot_prefix}.state" || return 1
    else
        error "拒绝处理非常规 XanMod 配置路径: $target"
        return 1
    fi
}

cleanup_incomplete_xanmod_runtime_snapshot() {
    if [[ "$XANMOD_TRANSACTION_ACTIVE" == "true" ]]; then
        error "拒绝把完整活动快照当作不完整快照删除"
        return 1
    fi
    if [[ -z "$XANMOD_RUNTIME_SNAPSHOT_DIR" ]]; then
        XANMOD_RUNTIME_SNAPSHOT_BUILDING=false
        return 0
    fi
    if ! remove_xanmod_temp_directory "$XANMOD_RUNTIME_SNAPSHOT_DIR" "XanMod 不完整运行时快照"; then
        return 1
    fi
    XANMOD_RUNTIME_SNAPSHOT_DIR=""
    XANMOD_RUNTIME_SNAPSHOT_BUILDING=false
}

create_xanmod_runtime_snapshot() {
    local index
    local temp_parent="${TMPDIR:-/tmp}"

    if [[ "$XANMOD_TRANSACTION_ACTIVE" == "true" ||
        "$XANMOD_RUNTIME_SNAPSHOT_BUILDING" == "true" ||
        -n "$XANMOD_RUNTIME_SNAPSHOT_DIR" ]]; then
        error "XanMod 配置快照生命周期尚未结束"
        return 1
    fi

    if ! xanmod_allocate_temp_directory XANMOD_RUNTIME_SNAPSHOT_DIR \
        XANMOD_RUNTIME_SNAPSHOT_BUILDING "$temp_parent" xanmod-runtime-snapshot 0700; then
        cleanup_incomplete_xanmod_runtime_snapshot || true
        return 1
    fi

    for index in "${!XANMOD_MANAGED_PATHS[@]}"; do
        if ! capture_xanmod_snapshot_item \
            "${XANMOD_MANAGED_PATHS[$index]}" \
            "$XANMOD_RUNTIME_SNAPSHOT_DIR/item-$index"; then
            cleanup_incomplete_xanmod_runtime_snapshot || true
            return 1
        fi
    done

    XANMOD_RUNTIME_SNAPSHOT_BUILDING=false
    XANMOD_TRANSACTION_ACTIVE=true
    XANMOD_CONFIG_MODIFIED=false
}

restore_xanmod_snapshot_item() {
    local target="$1"
    local snapshot_prefix="$2"
    local state=""
    local parent=""

    [[ -r "${snapshot_prefix}.state" ]] || return 1
    state=$(<"${snapshot_prefix}.state")

    if [[ -d "$target" && ! -L "$target" ]]; then
        error "拒绝用文件状态覆盖目录: $target"
        return 1
    fi
    parent=$(dirname "$target") || return 1
    if [[ ! -d "$parent" ]]; then
        install -d -m 0755 "$parent" || return 1
    elif [[ -L "$parent" ]]; then
        error "拒绝通过符号链接父目录恢复: $parent"
        return 1
    fi

    case "$state" in
        file)
            [[ -f "${snapshot_prefix}.data" && ! -L "${snapshot_prefix}.data" ]] || return 1
            rm -f -- "$target" || return 1
            cp -a -- "${snapshot_prefix}.data" "$target" || return 1
            ;;
        symlink)
            [[ -L "${snapshot_prefix}.data" ]] || return 1
            rm -f -- "$target" || return 1
            cp -a -- "${snapshot_prefix}.data" "$target" || return 1
            ;;
        absent)
            rm -f -- "$target" || return 1
            ;;
        *)
            return 1
            ;;
    esac
}

restore_xanmod_runtime_snapshot() {
    local index
    local restore_failed=false

    [[ "$XANMOD_TRANSACTION_ACTIVE" == "true" ]] || return 0

    for index in "${!XANMOD_MANAGED_PATHS[@]}"; do
        if ! restore_xanmod_snapshot_item \
            "${XANMOD_MANAGED_PATHS[$index]}" \
            "$XANMOD_RUNTIME_SNAPSHOT_DIR/item-$index"; then
            error "恢复 XanMod 配置失败: ${XANMOD_MANAGED_PATHS[$index]}"
            restore_failed=true
        fi
    done
    if [[ "$restore_failed" == "true" ]]; then
        XANMOD_CONFIG_MODIFIED=true
        error "XanMod 运行时快照已保留，可在故障解除后重试: $XANMOD_RUNTIME_SNAPSHOT_DIR"
        return 1
    fi

    if ! remove_xanmod_temp_directory "$XANMOD_RUNTIME_SNAPSHOT_DIR" "XanMod 运行时快照"; then
        XANMOD_CONFIG_MODIFIED=true
        return 1
    fi
    XANMOD_RUNTIME_SNAPSHOT_DIR=""
    XANMOD_RUNTIME_SNAPSHOT_BUILDING=false
    XANMOD_TRANSACTION_ACTIVE=false
    XANMOD_CONFIG_MODIFIED=false
}

discard_xanmod_runtime_snapshot() {
    if [[ -z "$XANMOD_RUNTIME_SNAPSHOT_DIR" ]]; then
        XANMOD_RUNTIME_SNAPSHOT_BUILDING=false
        XANMOD_TRANSACTION_ACTIVE=false
        return 0
    fi
    if ! remove_xanmod_temp_directory "$XANMOD_RUNTIME_SNAPSHOT_DIR" "XanMod 运行时快照"; then
        return 1
    fi
    XANMOD_RUNTIME_SNAPSHOT_DIR=""
    XANMOD_RUNTIME_SNAPSHOT_BUILDING=false
    XANMOD_TRANSACTION_ACTIVE=false
}

xanmod_directory_trusted() {
    local directory="$1"
    local expected_mode="$2"
    local metadata=""

    [[ -d "$directory" && ! -L "$directory" ]] || return 1
    metadata=$(stat -c '%u:%g:%a' -- "$directory") || return 1
    [[ "$metadata" == "$XANMOD_TRUSTED_UID:$XANMOD_TRUSTED_GID:$expected_mode" ]]
}

set_xanmod_state_file_metadata() {
    local file="$1"

    [[ -f "$file" && ! -L "$file" ]] || return 1
    if [[ "${XANMOD_TEST_MODE:-0}" == "1" ]]; then
        [[ "$(stat -c '%u' -- "$file")" == "$XANMOD_TRUSTED_UID" ]] || return 1
        chgrp "$XANMOD_TRUSTED_GID" "$file" || return 1
    else
        chown 0:0 "$file" || return 1
    fi
    chmod 0600 "$file" || return 1
    xanmod_regular_file_trusted "$file" 600
}

xanmod_state_marker_trusted() {
    local marker="$1"

    xanmod_regular_file_trusted "$marker" 600 && [[ ! -s "$marker" ]]
}

xanmod_path_owner_trusted() {
    local path="$1"
    local metadata=""

    [[ -e "$path" || -L "$path" ]] || return 1
    metadata=$(stat -c '%u:%g' -- "$path") || return 1
    [[ "$metadata" == "$XANMOD_TRUSTED_UID:$XANMOD_TRUSTED_GID" ]]
}

xanmod_legacy_backup_item_trusted() {
    local backup="$1"
    local mode=""
    local mode_value=0

    if [[ -L "$backup" ]]; then
        xanmod_path_owner_trusted "$backup"
        return
    fi
    [[ -f "$backup" ]] || return 1
    xanmod_path_owner_trusted "$backup" || return 1
    mode=$(stat -c '%a' -- "$backup") || return 1
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    mode_value=$((8#$mode))
    (( (mode_value & 0400) != 0 && (mode_value & 0022) == 0 ))
}

xanmod_backup_metadata_values() {
    local metadata_file="$1"

    xanmod_regular_file_trusted "$metadata_file" 600 || return 1
    awk -F= '
        $1 == "type" && ($2 == "file" || $2 == "symlink") { type=$2; type_count++; next }
        $1 == "uid" && $2 ~ /^[0-9]+$/ { uid=$2; uid_count++; next }
        $1 == "gid" && $2 ~ /^[0-9]+$/ { gid=$2; gid_count++; next }
        $1 == "mode" && $2 ~ /^[0-7][0-7][0-7]([0-7])?$/ { mode=$2; mode_count++; next }
        { invalid=1 }
        END {
            if (type_count == 1 && uid_count == 1 && gid_count == 1 && mode_count == 1 && !invalid)
                print type, uid, gid, mode
            else
                exit 1
        }
    ' "$metadata_file"
}

xanmod_new_backup_state_trusted() {
    local backup="$1"
    local metadata_file="$2"

    xanmod_regular_file_trusted "$backup" 600 &&
        xanmod_backup_metadata_values "$metadata_file" >/dev/null
}

xanmod_backup_parent_directory_trusted() {
    local directory="$1"
    local metadata=""
    local owner=""
    local group=""
    local mode=""
    local mode_value=0

    [[ -d "$directory" && ! -L "$directory" ]] || return 1
    metadata=$(stat -c '%u:%g:%a' -- "$directory") || return 1
    IFS=: read -r owner group mode <<< "$metadata"
    [[ "$owner" == "$XANMOD_TRUSTED_UID" &&
        "$group" == "$XANMOD_TRUSTED_GID" &&
        "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    mode_value=$((8#$mode))
    (( (mode_value & 0700) == 0700 && (mode_value & 0022) == 0 ))
}

ensure_xanmod_backup_state_parent_dir() {
    local parent=""
    local current=""
    local ancestor=""
    local directory=""
    local index
    local -a missing_directories=()

    parent=$(dirname "$XANMOD_BACKUP_STATE_DIR") || return 1
    if [[ "$parent" != /* ]]; then
        error "XanMod backup 父目录必须是绝对路径: $parent"
        return 1
    fi
    current="$parent"
    while [[ ! -e "$current" && ! -L "$current" ]]; do
        missing_directories+=("$current")
        ancestor=$(dirname "$current") || return 1
        if [[ "$ancestor" == "$current" ]]; then
            error "无法定位可信 XanMod backup 父目录: $parent"
            return 1
        fi
        current="$ancestor"
    done
    if ! xanmod_backup_parent_directory_trusted "$current"; then
        error "XanMod backup 父目录类型、owner、GID 或 mode 不可信: $current"
        return 1
    fi

    for ((index = ${#missing_directories[@]} - 1; index >= 0; index--)); do
        directory="${missing_directories[$index]}"
        if mkdir -m 0755 -- "$directory" 2>/dev/null; then
            :
        elif [[ ! -e "$directory" && ! -L "$directory" ]]; then
            error "无法创建 XanMod backup 父目录: $directory"
            return 1
        fi
        if ! xanmod_backup_parent_directory_trusted "$directory"; then
            error "XanMod backup 父目录类型、owner、GID 或 mode 不可信: $directory"
            return 1
        fi
    done
}

xanmod_create_backup_state_dir() {
    xanmod_create_temp_directory_at_path "$XANMOD_BACKUP_STATE_DIR" 0700
}

validate_existing_xanmod_backup_state_dir() {
    if [[ ! -e "$XANMOD_BACKUP_STATE_DIR" && ! -L "$XANMOD_BACKUP_STATE_DIR" ]]; then
        return 2
    fi
    if ! xanmod_directory_trusted "$XANMOD_BACKUP_STATE_DIR" 700; then
        error "XanMod 备份目录类型、owner、GID 或 mode 不可信: $XANMOD_BACKUP_STATE_DIR"
        return 1
    fi
}

ensure_xanmod_backup_state_dir() {
    local owner_token=""
    local create_status=0
    local state_status=0
    local collision=false

    XANMOD_BACKUP_STATE_DIR_CREATING=false
    XANMOD_BACKUP_STATE_DIR_CREATED=false
    XANMOD_BACKUP_STATE_DIR_PREEXISTED=false
    ensure_xanmod_backup_state_parent_dir || return 1
    state_status=0
    validate_existing_xanmod_backup_state_dir || state_status=$?
    case "$state_status" in
        0)
            XANMOD_BACKUP_STATE_DIR_PREEXISTED=true
            return 0
            ;;
        2) ;;
        *) return 1 ;;
    esac

    owner_token=$(xanmod_random_token) || return 1
    xanmod_begin_pending_allocation directory \
        "$XANMOD_BACKUP_STATE_DIR" 0700 "$owner_token" || return 1
    xanmod_begin_allocation_critical_section || return 1
    create_status=0
    (
        trap '' HUP INT TERM
        xanmod_create_backup_state_dir
    ) || create_status=$?
    case "$create_status" in
        0)
            XANMOD_ALLOCATION_PROOF_OWNED=true
            XANMOD_ALLOCATION_STATE=owned
            ;;
        "$XANMOD_ALLOCATION_NOT_CREATED")
            [[ -e "$XANMOD_BACKUP_STATE_DIR" || -L "$XANMOD_BACKUP_STATE_DIR" ]] && collision=true
            xanmod_clear_pending_allocation
            ;;
        "$XANMOD_ALLOCATION_FAILED_CLEAN")
            xanmod_clear_pending_allocation
            ;;
        "$XANMOD_ALLOCATION_RESIDUE_WITH_PROOF"|"$XANMOD_ALLOCATION_RESIDUE_WITHOUT_PROOF")
            xanmod_mark_pending_allocation_residue "$create_status"
            ;;
        *)
            if xanmod_pending_allocation_owned; then
                XANMOD_ALLOCATION_PROOF_OWNED=true
                XANMOD_ALLOCATION_STATE=residue
            else
                xanmod_clear_pending_allocation
            fi
            ;;
    esac
    xanmod_end_allocation_critical_section
    xanmod_after_allocation_attempt_hook \
        backup-state "$XANMOD_BACKUP_STATE_DIR" "$create_status" || true

    case "$create_status" in
        0)
            if ! xanmod_pending_allocation_owned; then
                XANMOD_ALLOCATION_PROOF_OWNED=true
                XANMOD_ALLOCATION_STATE=residue
                error "无法证明新建 XanMod 备份目录属于本次事务: $XANMOD_BACKUP_STATE_DIR"
                return 1
            fi
            XANMOD_BACKUP_STATE_DIR_CREATING=true
            XANMOD_BACKUP_STATE_DIR_CREATED=true
            XANMOD_BACKUP_STATE_DIR_CREATING=false
            XANMOD_ALLOCATION_STATE=active
            xanmod_release_pending_allocation_proof || return 1
            xanmod_clear_pending_allocation
            if ! xanmod_directory_trusted "$XANMOD_BACKUP_STATE_DIR" 700; then
                error "新建 XanMod 备份目录未通过 owner/mode 校验"
                cleanup_new_empty_xanmod_backup_state_dir || true
                return 1
            fi
            return 0
            ;;
        "$XANMOD_ALLOCATION_NOT_CREATED")
            if [[ "$collision" == true ]]; then
                XANMOD_BACKUP_STATE_DIR_PREEXISTED=true
                if xanmod_directory_trusted "$XANMOD_BACKUP_STATE_DIR" 700; then
                    return 0
                fi
                error "竞争创建后的 XanMod 备份目录不可信: $XANMOD_BACKUP_STATE_DIR"
                return 1
            fi
            error "无法排他创建 XanMod 备份目录: $XANMOD_BACKUP_STATE_DIR"
            return 1
            ;;
        "$XANMOD_ALLOCATION_FAILED_CLEAN")
            error "XanMod 备份目录创建后的 proof 建立失败"
            return 1
            ;;
        *) return 1 ;;
    esac
}

get_xanmod_backup_prefix() {
    printf '%s/%s\n' "$XANMOD_BACKUP_STATE_DIR" "$(basename "$1")"
}

xanmod_state_path_exists() {
    [[ -e "$1" || -L "$1" ]]
}

classify_xanmod_state_prefix() {
    local prefix="$1"
    local scope="$2"
    local allow_unknown="$3"
    local backup="${prefix}.${scope}-backup"
    local metadata_file="${prefix}.${scope}-backup-meta"
    local absent="${prefix}.${scope}-absent"
    local unknown="${prefix}.${scope}-unknown"
    local state_count=0
    local state_type="none"

    if xanmod_state_path_exists "$backup" || xanmod_state_path_exists "$metadata_file"; then
        ((state_count += 1))
        if xanmod_state_path_exists "$backup" && xanmod_state_path_exists "$metadata_file"; then
            xanmod_new_backup_state_trusted "$backup" "$metadata_file" || return 1
            state_type="backup-new"
        elif xanmod_state_path_exists "$backup" && ! xanmod_state_path_exists "$metadata_file"; then
            xanmod_legacy_backup_item_trusted "$backup" || return 1
            state_type="backup-legacy"
        else
            return 1
        fi
    fi
    if xanmod_state_path_exists "$absent"; then
        ((state_count += 1))
        xanmod_state_marker_trusted "$absent" || return 1
        state_type="absent"
    fi
    if xanmod_state_path_exists "$unknown"; then
        ((state_count += 1))
        [[ "$allow_unknown" == "true" ]] || return 1
        xanmod_state_marker_trusted "$unknown" || return 1
        state_type="unknown"
    fi
    (( state_count <= 1 )) || return 1
    printf '%s\n' "$state_type"
}

validate_xanmod_backup_group_items() {
    local target
    local prefix

    for target in "${XANMOD_MANAGED_PATHS[@]}"; do
        prefix=$(get_xanmod_backup_prefix "$target") || return 1
        classify_xanmod_state_prefix "$prefix" initial true >/dev/null || return 1
        classify_xanmod_state_prefix "$prefix" previous false >/dev/null || return 1
        classify_xanmod_state_prefix "$target" initial true >/dev/null || return 1
        classify_xanmod_state_prefix "$target" previous false >/dev/null || return 1
    done
}

write_xanmod_backup_metadata() {
    local source_path="$1"
    local metadata_file="$2"
    local source_type="file"
    local metadata=""
    local source_uid
    local source_gid
    local source_mode

    [[ -L "$source_path" ]] && source_type="symlink"
    metadata=$(stat -c '%u:%g:%a' -- "$source_path") || return 1
    IFS=: read -r source_uid source_gid source_mode <<< "$metadata"
    printf 'type=%s\nuid=%s\ngid=%s\nmode=%s\n' \
        "$source_type" "$source_uid" "$source_gid" "$source_mode" > "$metadata_file" || return 1
    set_xanmod_state_file_metadata "$metadata_file"
}

capture_xanmod_persistent_state() {
    local target="$1"
    local prefix="$2"
    local scope="$3"
    local backup="${prefix}.${scope}-backup"
    local metadata_file="${prefix}.${scope}-backup-meta"
    local absent="${prefix}.${scope}-absent"
    local unknown="${prefix}.${scope}-unknown"

    rm -f -- "$backup" "$metadata_file" "$absent" "$unknown" || return 1
    if [[ -L "$target" ]]; then
        readlink "$target" > "$backup" || return 1
        set_xanmod_state_file_metadata "$backup" || return 1
        write_xanmod_backup_metadata "$target" "$metadata_file" || return 1
    elif [[ -f "$target" ]]; then
        cat "$target" > "$backup" || return 1
        set_xanmod_state_file_metadata "$backup" || return 1
        write_xanmod_backup_metadata "$target" "$metadata_file" || return 1
    elif [[ ! -e "$target" ]]; then
        install -m 0600 /dev/null "$absent" || return 1
        set_xanmod_state_file_metadata "$absent" || return 1
    else
        error "拒绝备份非常规 XanMod 配置路径: $target"
        return 1
    fi
}

stage_xanmod_state_from_prefix() {
    local source_prefix="$1"
    local source_scope="$2"
    local destination_prefix="$3"
    local destination_scope="$4"
    local state_type=""
    local source_backup="${source_prefix}.${source_scope}-backup"
    local source_meta="${source_prefix}.${source_scope}-backup-meta"
    local destination_backup="${destination_prefix}.${destination_scope}-backup"
    local destination_meta="${destination_prefix}.${destination_scope}-backup-meta"
    local destination_absent="${destination_prefix}.${destination_scope}-absent"
    local destination_unknown="${destination_prefix}.${destination_scope}-unknown"
    local link_target=""

    state_type=$(classify_xanmod_state_prefix "$source_prefix" "$source_scope" true) || return 1
    rm -f -- "$destination_backup" "$destination_meta" "$destination_absent" "$destination_unknown" || return 1
    case "$state_type" in
        backup-new)
            cat "$source_backup" > "$destination_backup" || return 1
            cat "$source_meta" > "$destination_meta" || return 1
            set_xanmod_state_file_metadata "$destination_backup" || return 1
            set_xanmod_state_file_metadata "$destination_meta" || return 1
            ;;
        backup-legacy)
            if [[ -L "$source_backup" ]]; then
                link_target=$(readlink "$source_backup") || return 1
                printf '%s\n' "$link_target" > "$destination_backup" || return 1
            else
                cat "$source_backup" > "$destination_backup" || return 1
            fi
            set_xanmod_state_file_metadata "$destination_backup" || return 1
            write_xanmod_backup_metadata "$source_backup" "$destination_meta" || return 1
            ;;
        absent)
            install -m 0600 /dev/null "$destination_absent" || return 1
            set_xanmod_state_file_metadata "$destination_absent" || return 1
            ;;
        unknown)
            install -m 0600 /dev/null "$destination_unknown" || return 1
            set_xanmod_state_file_metadata "$destination_unknown" || return 1
            ;;
        *)
            return 1
            ;;
    esac
}

xanmod_configuration_looks_previously_managed() {
    if [[ -f "$XANMOD_SOURCE_DEB822" ]] &&
        grep -Fq "Signed-By: $XANMOD_KEYRING" "$XANMOD_SOURCE_DEB822"; then
        return 0
    fi
    if [[ -f "$XANMOD_SOURCE_LIST" ]] && grep -Fq 'xanmod' "$XANMOD_SOURCE_LIST"; then
        return 0
    fi
    return 1
}

build_xanmod_backup_snapshot_paths() {
    local target
    local prefix
    local suffix
    local -a suffixes=(
        initial-backup initial-backup-meta initial-absent initial-unknown
        previous-backup previous-backup-meta previous-absent previous-unknown
    )

    XANMOD_BACKUP_SNAPSHOT_PATHS=()
    for target in "${XANMOD_MANAGED_PATHS[@]}"; do
        prefix=$(get_xanmod_backup_prefix "$target") || return 1
        for suffix in "${suffixes[@]}"; do
            XANMOD_BACKUP_SNAPSHOT_PATHS+=("${prefix}.${suffix}" "${target}.${suffix}")
        done
    done
}

xanmod_backup_state_dir_empty() {
    [[ -d "$XANMOD_BACKUP_STATE_DIR" && ! -L "$XANMOD_BACKUP_STATE_DIR" ]] || return 1
    [[ -z "$(find "$XANMOD_BACKUP_STATE_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]
}

cleanup_new_empty_xanmod_backup_state_dir() {
    if [[ "$XANMOD_BACKUP_STATE_DIR_PREEXISTED" == "true" ]]; then
        return 0
    fi
    if [[ "$XANMOD_BACKUP_STATE_DIR_CREATING" != "true" &&
        "$XANMOD_BACKUP_STATE_DIR_CREATED" != "true" ]]; then
        return 0
    fi
    if [[ ! -e "$XANMOD_BACKUP_STATE_DIR" && ! -L "$XANMOD_BACKUP_STATE_DIR" ]]; then
        XANMOD_BACKUP_STATE_DIR_CREATING=false
        XANMOD_BACKUP_STATE_DIR_CREATED=false
        return 0
    fi
    if ! xanmod_directory_trusted "$XANMOD_BACKUP_STATE_DIR" 700; then
        error "拒绝删除类型、owner 或 mode 不可信的 backup 路径: $XANMOD_BACKUP_STATE_DIR"
        return 1
    fi
    if ! xanmod_backup_state_dir_empty; then
        error "本次新建的 XanMod backup 目录非空，保留路径: $XANMOD_BACKUP_STATE_DIR"
        return 1
    fi
    if ! rmdir "$XANMOD_BACKUP_STATE_DIR"; then
        error "本次新建的空 XanMod backup 目录残留: $XANMOD_BACKUP_STATE_DIR"
        return 1
    fi
    XANMOD_BACKUP_STATE_DIR_CREATING=false
    XANMOD_BACKUP_STATE_DIR_CREATED=false
    XANMOD_BACKUP_STATE_DIR_PREEXISTED=false
}

cleanup_incomplete_xanmod_backup_snapshot() {
    local cleanup_failed=false

    if [[ "$XANMOD_BACKUP_TRANSACTION_ACTIVE" == "true" ]]; then
        error "拒绝把完整 backup 组快照当作不完整快照删除"
        return 1
    fi
    cleanup_xanmod_backup_stage || cleanup_failed=true
    if [[ -n "$XANMOD_BACKUP_GROUP_SNAPSHOT_DIR" ]]; then
        if [[ ! -e "$XANMOD_BACKUP_GROUP_SNAPSHOT_DIR" && ! -L "$XANMOD_BACKUP_GROUP_SNAPSHOT_DIR" ]] ||
            remove_xanmod_temp_directory "$XANMOD_BACKUP_GROUP_SNAPSHOT_DIR" "XanMod 不完整 backup 组快照"; then
            :
        else
            cleanup_failed=true
        fi
    fi
    cleanup_new_empty_xanmod_backup_state_dir || cleanup_failed=true

    if [[ "$cleanup_failed" == "false" ]]; then
        XANMOD_BACKUP_GROUP_SNAPSHOT_DIR=""
        XANMOD_BACKUP_SNAPSHOT_BUILDING=false
        XANMOD_BACKUP_SNAPSHOT_REMOVED=false
        XANMOD_BACKUP_SNAPSHOT_PATHS=()
        XANMOD_BACKUP_NEW_ARCHIVES=()
        return 0
    fi
    return 1
}

create_xanmod_backup_group_snapshot() {
    local index
    local temp_parent="${TMPDIR:-/tmp}"

    if [[ "$XANMOD_BACKUP_TRANSACTION_ACTIVE" == "true" ||
        "$XANMOD_BACKUP_SNAPSHOT_BUILDING" == "true" ||
        "$XANMOD_BACKUP_SNAPSHOT_REMOVED" == "true" ||
        -n "$XANMOD_BACKUP_GROUP_SNAPSHOT_DIR" ]]; then
        error "XanMod backup 快照生命周期尚未结束"
        return 1
    fi
    build_xanmod_backup_snapshot_paths || return 1
    if ! xanmod_allocate_temp_directory XANMOD_BACKUP_GROUP_SNAPSHOT_DIR \
        XANMOD_BACKUP_SNAPSHOT_BUILDING "$temp_parent" xanmod-backup-group 0700; then
        cleanup_incomplete_xanmod_backup_snapshot || true
        return 1
    fi
    for index in "${!XANMOD_BACKUP_SNAPSHOT_PATHS[@]}"; do
        if ! capture_xanmod_snapshot_item \
            "${XANMOD_BACKUP_SNAPSHOT_PATHS[$index]}" \
            "$XANMOD_BACKUP_GROUP_SNAPSHOT_DIR/item-$index"; then
            cleanup_incomplete_xanmod_backup_snapshot || true
            return 1
        fi
    done
    XANMOD_BACKUP_SNAPSHOT_BUILDING=false
    XANMOD_BACKUP_SNAPSHOT_REMOVED=false
    XANMOD_BACKUP_TRANSACTION_ACTIVE=true
}

stage_xanmod_legacy_backup_item() {
    local legacy="$1"
    local staged="$2"

    if [[ -L "$legacy" ]]; then
        readlink "$legacy" > "$staged" || return 1
    else
        cat "$legacy" > "$staged" || return 1
    fi
    set_xanmod_state_file_metadata "$staged"
}

stage_legacy_xanmod_backup_migration() {
    local target
    local suffix
    local legacy
    local staged
    local final
    local archive_index=0
    local -a suffixes=(
        initial-backup initial-backup-meta initial-absent initial-unknown
        previous-backup previous-backup-meta previous-absent previous-unknown
    )

    XANMOD_BACKUP_LEGACY_PATHS=()
    XANMOD_BACKUP_ARCHIVE_STAGED=()
    XANMOD_BACKUP_ARCHIVE_FINAL=()
    for target in "${XANMOD_MANAGED_PATHS[@]}"; do
        for suffix in "${suffixes[@]}"; do
            legacy="${target}.${suffix}"
            xanmod_state_path_exists "$legacy" || continue
            staged="$XANMOD_BACKUP_STAGE_DIR/legacy-$archive_index"
            final="$XANMOD_BACKUP_STATE_DIR/$(basename "$legacy").legacy.$XANMOD_BACKUP_TRANSACTION_ID.$archive_index"
            stage_xanmod_legacy_backup_item "$legacy" "$staged" || return 1
            XANMOD_BACKUP_LEGACY_PATHS+=("$legacy")
            XANMOD_BACKUP_ARCHIVE_STAGED+=("$staged")
            XANMOD_BACKUP_ARCHIVE_FINAL+=("$final")
            ((archive_index += 1))
        done
    done
}

stage_xanmod_initial_state() {
    local target="$1"
    local staged_prefix="$2"
    local active_prefix
    local active_state
    local legacy_state

    active_prefix=$(get_xanmod_backup_prefix "$target") || return 1
    active_state=$(classify_xanmod_state_prefix "$active_prefix" initial true) || return 1
    legacy_state=$(classify_xanmod_state_prefix "$target" initial true) || return 1

    if [[ "$active_state" != "none" ]]; then
        stage_xanmod_state_from_prefix "$active_prefix" initial "$staged_prefix" initial
    elif [[ "$legacy_state" != "none" ]]; then
        stage_xanmod_state_from_prefix "$target" initial "$staged_prefix" initial
    elif [[ "$XANMOD_CONFIGURATION_PREVIOUSLY_MANAGED" == "true" ]]; then
        install -m 0600 /dev/null "${staged_prefix}.initial-unknown" || return 1
        set_xanmod_state_file_metadata "${staged_prefix}.initial-unknown"
    else
        capture_xanmod_persistent_state "$target" "$staged_prefix" initial
    fi
}

commit_xanmod_persistent_state() {
    local target="$1"
    local scope="$2"
    local staged_prefix="$3"
    local final_prefix
    local suffix
    local staged
    local final
    local moved_count=0
    local -a suffixes=(backup backup-meta absent unknown)

    final_prefix=$(get_xanmod_backup_prefix "$target") || return 1
    for suffix in "${suffixes[@]}"; do
        rm -f -- "${final_prefix}.${scope}-${suffix}" || return 1
    done
    for suffix in "${suffixes[@]}"; do
        staged="${staged_prefix}.${scope}-${suffix}"
        final="${final_prefix}.${scope}-${suffix}"
        xanmod_state_path_exists "$staged" || continue
        mv -fT -- "$staged" "$final" || return 1
        ((moved_count += 1))
    done
    (( moved_count > 0 ))
}

commit_xanmod_backup_group() {
    local index
    local target
    local staged_prefix

    XANMOD_BACKUP_NEW_ARCHIVES=()
    for index in "${!XANMOD_BACKUP_ARCHIVE_STAGED[@]}"; do
        mv -fT -- "${XANMOD_BACKUP_ARCHIVE_STAGED[$index]}" \
            "${XANMOD_BACKUP_ARCHIVE_FINAL[$index]}" || return 1
        XANMOD_BACKUP_NEW_ARCHIVES+=("${XANMOD_BACKUP_ARCHIVE_FINAL[$index]}")
    done

    for target in "${XANMOD_MANAGED_PATHS[@]}"; do
        staged_prefix="$XANMOD_BACKUP_STAGE_DIR/$(basename "$target")"
        commit_xanmod_persistent_state "$target" initial "$staged_prefix" || return 1
        commit_xanmod_persistent_state "$target" previous "$staged_prefix" || return 1
    done
    for target in "${XANMOD_BACKUP_LEGACY_PATHS[@]}"; do
        rm -f -- "$target" || return 1
    done
}

cleanup_xanmod_backup_stage() {
    if [[ -z "$XANMOD_BACKUP_STAGE_DIR" ]]; then
        XANMOD_BACKUP_STAGE_BUILDING=false
        return 0
    fi
    if ! remove_xanmod_temp_directory "$XANMOD_BACKUP_STAGE_DIR" "XanMod backup stage"; then
        return 1
    fi
    XANMOD_BACKUP_STAGE_DIR=""
    XANMOD_BACKUP_STAGE_BUILDING=false
}

restore_xanmod_backup_group_snapshot() {
    local index
    local restore_failed=false
    local cleanup_failed=false
    local archive

    [[ "$XANMOD_BACKUP_TRANSACTION_ACTIVE" == "true" ]] || return 0
    if [[ "$XANMOD_BACKUP_SNAPSHOT_REMOVED" != "true" ]]; then
        if [[ -z "$XANMOD_BACKUP_GROUP_SNAPSHOT_DIR" ]] ||
            ! xanmod_directory_trusted "$XANMOD_BACKUP_GROUP_SNAPSHOT_DIR" 700; then
            error "XanMod backup 组快照缺失或不可信，保留事务状态: $XANMOD_BACKUP_GROUP_SNAPSHOT_DIR"
            return 1
        fi
        if ! xanmod_directory_trusted "$XANMOD_BACKUP_STATE_DIR" 700; then
            error "XanMod backup 状态目录缺失或不可信，拒绝以通用 0755 父目录恢复: $XANMOD_BACKUP_STATE_DIR"
            return 1
        fi

        for index in "${!XANMOD_BACKUP_SNAPSHOT_PATHS[@]}"; do
            if ! restore_xanmod_snapshot_item \
                "${XANMOD_BACKUP_SNAPSHOT_PATHS[$index]}" \
                "$XANMOD_BACKUP_GROUP_SNAPSHOT_DIR/item-$index"; then
                error "恢复 XanMod backup 组失败: ${XANMOD_BACKUP_SNAPSHOT_PATHS[$index]}"
                restore_failed=true
            fi
        done
        if [[ "$restore_failed" == "true" ]]; then
            error "XanMod backup 组快照已保留，可在故障解除后重试: $XANMOD_BACKUP_GROUP_SNAPSHOT_DIR"
            return 1
        fi

        for archive in "${XANMOD_BACKUP_NEW_ARCHIVES[@]}"; do
            if ! rm -f -- "$archive"; then
                error "XanMod legacy archive 残留: $archive"
                cleanup_failed=true
            fi
        done
        cleanup_xanmod_backup_stage || cleanup_failed=true
        if [[ "$cleanup_failed" == "true" ]]; then
            error "XanMod backup 组快照已保留，可在清理故障解除后重试: $XANMOD_BACKUP_GROUP_SNAPSHOT_DIR"
            return 1
        fi

        if ! remove_xanmod_temp_directory \
            "$XANMOD_BACKUP_GROUP_SNAPSHOT_DIR" "XanMod backup 组快照"; then
            return 1
        fi
        XANMOD_BACKUP_GROUP_SNAPSHOT_DIR=""
        XANMOD_BACKUP_SNAPSHOT_BUILDING=false
        XANMOD_BACKUP_SNAPSHOT_REMOVED=true
    fi

    if ! cleanup_new_empty_xanmod_backup_state_dir; then
        error "XanMod backup 状态目录清理未完成，可在故障解除后重试: $XANMOD_BACKUP_STATE_DIR"
        return 1
    fi
    XANMOD_BACKUP_TRANSACTION_ACTIVE=false
    XANMOD_BACKUP_SNAPSHOT_REMOVED=false
    XANMOD_BACKUP_STATE_DIR_CREATING=false
    XANMOD_BACKUP_STATE_DIR_CREATED=false
    XANMOD_BACKUP_STATE_DIR_PREEXISTED=false
    XANMOD_BACKUP_SNAPSHOT_PATHS=()
    XANMOD_BACKUP_NEW_ARCHIVES=()
}

discard_xanmod_backup_group_snapshot() {
    cleanup_xanmod_backup_stage || return 1
    if [[ "$XANMOD_BACKUP_SNAPSHOT_REMOVED" == "true" ]]; then
        cleanup_new_empty_xanmod_backup_state_dir || return 1
    elif [[ -n "$XANMOD_BACKUP_GROUP_SNAPSHOT_DIR" ]]; then
        if ! remove_xanmod_temp_directory "$XANMOD_BACKUP_GROUP_SNAPSHOT_DIR" "XanMod backup 组快照"; then
            return 1
        fi
    fi
    XANMOD_BACKUP_GROUP_SNAPSHOT_DIR=""
    XANMOD_BACKUP_SNAPSHOT_BUILDING=false
    XANMOD_BACKUP_SNAPSHOT_REMOVED=false
    XANMOD_BACKUP_TRANSACTION_ACTIVE=false
    XANMOD_BACKUP_STATE_DIR_CREATING=false
    XANMOD_BACKUP_STATE_DIR_CREATED=false
    XANMOD_BACKUP_STATE_DIR_PREEXISTED=false
    XANMOD_BACKUP_SNAPSHOT_PATHS=()
    XANMOD_BACKUP_NEW_ARCHIVES=()
}

prepare_persistent_xanmod_backups() {
    local target
    local staged_prefix

    ensure_xanmod_backup_state_dir || return 1
    validate_xanmod_backup_group_items || return 1
    create_xanmod_backup_group_snapshot || return 1
    XANMOD_BACKUP_TRANSACTION_ID=$(basename "$XANMOD_BACKUP_GROUP_SNAPSHOT_DIR")
    if ! xanmod_allocate_temp_directory XANMOD_BACKUP_STAGE_DIR \
        XANMOD_BACKUP_STAGE_BUILDING "$XANMOD_BACKUP_STATE_DIR" .xanmod-backup-stage 0700; then
        restore_xanmod_backup_group_snapshot || true
        return 1
    fi
    XANMOD_BACKUP_STAGE_BUILDING=false

    if xanmod_configuration_looks_previously_managed; then
        XANMOD_CONFIGURATION_PREVIOUSLY_MANAGED=true
    else
        XANMOD_CONFIGURATION_PREVIOUSLY_MANAGED=false
    fi

    if ! stage_legacy_xanmod_backup_migration; then
        restore_xanmod_backup_group_snapshot || true
        return 1
    fi
    for target in "${XANMOD_MANAGED_PATHS[@]}"; do
        staged_prefix="$XANMOD_BACKUP_STAGE_DIR/$(basename "$target")"
        if ! stage_xanmod_initial_state "$target" "$staged_prefix" ||
            ! capture_xanmod_persistent_state "$target" "$staged_prefix" previous; then
            restore_xanmod_backup_group_snapshot || true
            return 1
        fi
    done
    if ! commit_xanmod_backup_group; then
        restore_xanmod_backup_group_snapshot || true
        return 1
    fi
    discard_xanmod_backup_group_snapshot
}

prepare_xanmod_transaction() {
    prepare_persistent_xanmod_backups
}

abort_pending_xanmod_backup_transaction() {
    if [[ "$XANMOD_BACKUP_TRANSACTION_ACTIVE" == "true" ]]; then
        restore_xanmod_backup_group_snapshot
    elif [[ "$XANMOD_BACKUP_SNAPSHOT_BUILDING" == "true" ||
        -n "$XANMOD_BACKUP_GROUP_SNAPSHOT_DIR" ||
        -n "$XANMOD_BACKUP_STAGE_DIR" ]]; then
        cleanup_incomplete_xanmod_backup_snapshot
    elif [[ "$XANMOD_BACKUP_STATE_DIR_CREATING" == "true" ||
        "$XANMOD_BACKUP_STATE_DIR_CREATED" == "true" ]]; then
        cleanup_new_empty_xanmod_backup_state_dir
    fi
}

classify_xanmod_persistent_state() {
    local target="$1"
    local scope="$2"
    local prefix
    local state_type

    prefix=$(get_xanmod_backup_prefix "$target") || return 1
    state_type=$(classify_xanmod_state_prefix "$prefix" "$scope" "$( [[ "$scope" == initial ]] && echo true || echo false )") || return 1
    case "$state_type" in
        none|unknown) return 2 ;;
        backup-new|backup-legacy) printf 'backup\n' ;;
        absent) printf 'absent\n' ;;
        *) return 1 ;;
    esac
}

restore_xanmod_persistent_item() {
    local target="$1"
    local scope="$2"
    local state_type="$3"
    local prefix
    local backup
    local metadata_file
    local staged=""
    local metadata_values=""
    local backup_type=""
    local original_uid=""
    local original_gid=""
    local original_mode=""
    local link_target=""

    prefix=$(get_xanmod_backup_prefix "$target") || return 1
    backup="${prefix}.${scope}-backup"
    metadata_file="${prefix}.${scope}-backup-meta"

    if [[ -d "$target" && ! -L "$target" ]]; then
        error "拒绝用备份文件覆盖目录: $target"
        return 1
    fi
    case "$state_type" in
        absent)
            rm -f -- "$target"
            ;;
        backup)
            make_xanmod_stage_file XANMOD_RESTORE_STAGE "$target" .restore || return 1
            staged="$XANMOD_RESTORE_STAGE"
            if ! remove_xanmod_temp_file "$staged" "XanMod restore stage"; then
                return 1
            fi
            if xanmod_state_path_exists "$metadata_file"; then
                metadata_values=$(xanmod_backup_metadata_values "$metadata_file") || return 1
                read -r backup_type original_uid original_gid original_mode <<< "$metadata_values"
                if [[ "$backup_type" == file ]]; then
                    if ! cat "$backup" > "$staged"; then
                        remove_xanmod_temp_file "$staged" "XanMod restore stage" || true
                        return 1
                    fi
                    if [[ "${XANMOD_TEST_MODE:-0}" == "1" ]]; then
                        if [[ "$original_uid" != "$XANMOD_TRUSTED_UID" ||
                            "$original_gid" != "$XANMOD_TRUSTED_GID" ]] ||
                            ! chgrp "$original_gid" "$staged"; then
                            remove_xanmod_temp_file "$staged" "XanMod restore stage" || true
                            return 1
                        fi
                    elif ! chown "$original_uid:$original_gid" "$staged"; then
                        remove_xanmod_temp_file "$staged" "XanMod restore stage" || true
                        return 1
                    fi
                    if ! chmod "$original_mode" "$staged"; then
                        remove_xanmod_temp_file "$staged" "XanMod restore stage" || true
                        return 1
                    fi
                else
                    link_target=$(<"$backup")
                    if [[ -z "$link_target" ]] || ! ln -s "$link_target" "$staged"; then
                        remove_xanmod_temp_file "$staged" "XanMod restore stage" || true
                        return 1
                    fi
                    if [[ "${XANMOD_TEST_MODE:-0}" == "1" ]]; then
                        if [[ "$original_uid" != "$XANMOD_TRUSTED_UID" ||
                            "$original_gid" != "$XANMOD_TRUSTED_GID" ]]; then
                            remove_xanmod_temp_file "$staged" "XanMod restore stage" || true
                            return 1
                        fi
                    elif ! chown -h "$original_uid:$original_gid" "$staged"; then
                        remove_xanmod_temp_file "$staged" "XanMod restore stage" || true
                        return 1
                    fi
                fi
            elif ! cp -a -- "$backup" "$staged"; then
                remove_xanmod_temp_file "$staged" "XanMod restore stage" || true
                return 1
            fi
            if ! mv -fT -- "$staged" "$target"; then
                remove_xanmod_temp_file "$staged" "XanMod restore stage" || true
                return 1
            fi
            XANMOD_RESTORE_STAGE=""
            ;;
        *)
            return 1
            ;;
    esac
}

restore_xanmod_group() {
    local scope="$1"
    local target
    local state_type
    local state_status=0
    local index
    local apply_failed=false
    local -a state_types=()

    XANMOD_RESTORED_COUNT=0
    state_status=0
    validate_existing_xanmod_backup_state_dir || state_status=$?
    case "$state_status" in
        0)
            XANMOD_BACKUP_STATE_DIR_CREATING=false
            XANMOD_BACKUP_STATE_DIR_CREATED=false
            XANMOD_BACKUP_STATE_DIR_PREEXISTED=true
            ;;
        2)
            warn "没有 XanMod backup state 目录，不进行 $scope 恢复"
            return 2
            ;;
        *) return 1 ;;
    esac
    validate_xanmod_backup_group_items || return 1

    for target in "${XANMOD_MANAGED_PATHS[@]}"; do
        state_status=0
        state_type=$(classify_xanmod_persistent_state "$target" "$scope") || state_status=$?
        case "$state_status" in
            0) state_types+=("$state_type") ;;
            2)
                warn "XanMod $scope 组状态缺失或未知，不进行部分恢复"
                return 2
                ;;
            *)
                error "XanMod $scope 组备份状态不可信，不进行部分恢复"
                return 1
                ;;
        esac
    done

    XANMOD_APT_MAY_BE_PARTIAL=false
    install_xanmod_transaction_guards || return 1
    if ! create_xanmod_runtime_snapshot; then
        if cleanup_xanmod_transaction_state; then
            clear_xanmod_transaction_guards
        fi
        return 1
    fi
    XANMOD_CONFIG_MODIFIED=true
    for index in "${!XANMOD_MANAGED_PATHS[@]}"; do
        if ! restore_xanmod_persistent_item \
            "${XANMOD_MANAGED_PATHS[$index]}" "$scope" "${state_types[$index]}"; then
            error "恢复 XanMod 配置失败: ${XANMOD_MANAGED_PATHS[$index]}"
            apply_failed=true
            break
        fi
    done

    if [[ "$apply_failed" == "true" ]]; then
        abort_xanmod_install_transaction || true
        return 1
    fi
    if ! complete_xanmod_install_transaction; then
        return 1
    fi

    XANMOD_RESTORED_COUNT=${#XANMOD_MANAGED_PATHS[@]}
    if ! apt-get update -qq; then
        warn "XanMod 软件源配置已恢复，但 APT 索引更新失败；已保留请求恢复的配置"
        return 1
    fi
}

restore_xanmod_saved_trap() {
    local signal_name="$1"
    local trap_definition="$2"

    trap - "$signal_name"
    if [[ -n "$trap_definition" ]]; then
        # shellcheck disable=SC2294
        eval "$trap_definition"
    fi
}

install_xanmod_transaction_guards() {
    if [[ "$XANMOD_GUARD_ACTIVE" == "true" ]]; then
        error "XanMod 事务保护已经启用"
        return 1
    fi

    XANMOD_SAVED_TRAP_EXIT=$(trap -p EXIT || true)
    XANMOD_SAVED_TRAP_HUP=$(trap -p HUP || true)
    XANMOD_SAVED_TRAP_INT=$(trap -p INT || true)
    XANMOD_SAVED_TRAP_TERM=$(trap -p TERM || true)
    XANMOD_GUARD_ACTIVE=true
    XANMOD_GUARD_HANDLING=false
    XANMOD_ALLOCATION_CRITICAL=false
    XANMOD_ALLOCATION_PENDING_SIGNAL=""
    XANMOD_ALLOCATION_PENDING_SIGNAL_STATUS=0
    trap 'xanmod_transaction_exit_handler $?' EXIT
    trap 'xanmod_transaction_signal_handler HUP 129' HUP
    trap 'xanmod_transaction_signal_handler INT 130' INT
    trap 'xanmod_transaction_signal_handler TERM 143' TERM
}

clear_xanmod_transaction_guards() {
    local saved_exit="$XANMOD_SAVED_TRAP_EXIT"
    local saved_hup="$XANMOD_SAVED_TRAP_HUP"
    local saved_int="$XANMOD_SAVED_TRAP_INT"
    local saved_term="$XANMOD_SAVED_TRAP_TERM"

    trap - EXIT HUP INT TERM
    XANMOD_GUARD_ACTIVE=false
    XANMOD_GUARD_HANDLING=false
    XANMOD_ALLOCATION_CRITICAL=false
    XANMOD_ALLOCATION_PENDING_SIGNAL=""
    XANMOD_ALLOCATION_PENDING_SIGNAL_STATUS=0
    XANMOD_SAVED_TRAP_EXIT=""
    XANMOD_SAVED_TRAP_HUP=""
    XANMOD_SAVED_TRAP_INT=""
    XANMOD_SAVED_TRAP_TERM=""
    restore_xanmod_saved_trap EXIT "$saved_exit"
    restore_xanmod_saved_trap HUP "$saved_hup"
    restore_xanmod_saved_trap INT "$saved_int"
    restore_xanmod_saved_trap TERM "$saved_term"
}

warn_xanmod_partial_install() {
    warn "APT 可能已部分安装内核包；为避免误删可启动内核，脚本不会自动卸载任何包"
    warn "请检查: dpkg --audit；必要时执行 apt-get -f install，并确认引导菜单中的可用内核"
}

cleanup_xanmod_transaction_state() {
    local cleanup_failed=false

    cleanup_xanmod_pending_allocation || cleanup_failed=true
    cleanup_xanmod_stages || cleanup_failed=true
    cleanup_xanmod_active_apt_lists || cleanup_failed=true
    abort_pending_xanmod_backup_transaction || cleanup_failed=true
    if [[ "$XANMOD_RUNTIME_SNAPSHOT_BUILDING" == "true" ||
        ( -n "$XANMOD_RUNTIME_SNAPSHOT_DIR" && "$XANMOD_TRANSACTION_ACTIVE" != "true" ) ]]; then
        cleanup_incomplete_xanmod_runtime_snapshot || cleanup_failed=true
    fi
    if [[ "$XANMOD_TRANSACTION_ACTIVE" == "true" ]]; then
        if [[ "$XANMOD_CONFIG_MODIFIED" == "true" ]]; then
            restore_xanmod_runtime_snapshot || cleanup_failed=true
        else
            discard_xanmod_runtime_snapshot || cleanup_failed=true
        fi
    fi
    if [[ "$XANMOD_APT_MAY_BE_PARTIAL" == "true" ]]; then
        warn_xanmod_partial_install
        XANMOD_APT_MAY_BE_PARTIAL=false
    fi

    [[ "$cleanup_failed" == "false" ]]
}

xanmod_transaction_signal_handler() {
    local signal_name="$1"
    local exit_status="$2"
    local saved_exit="$XANMOD_SAVED_TRAP_EXIT"

    if [[ "$XANMOD_ALLOCATION_CRITICAL" == true ]]; then
        if [[ -z "$XANMOD_ALLOCATION_PENDING_SIGNAL" ]]; then
            XANMOD_ALLOCATION_PENDING_SIGNAL_STATUS="$exit_status"
            XANMOD_ALLOCATION_PENDING_SIGNAL="$signal_name"
        fi
        return 0
    fi
    if [[ "$XANMOD_GUARD_HANDLING" == "true" ]]; then
        exit "$exit_status"
    fi
    XANMOD_GUARD_HANDLING=true
    trap - EXIT
    trap '' HUP INT TERM
    error "收到 $signal_name，正在安全清理 XanMod 事务"
    cleanup_xanmod_transaction_state || true
    XANMOD_GUARD_ACTIVE=false
    restore_xanmod_saved_trap EXIT "$saved_exit"
    exit "$exit_status"
}

xanmod_transaction_exit_handler() {
    local exit_status="$1"
    local saved_exit="$XANMOD_SAVED_TRAP_EXIT"

    if [[ "$XANMOD_GUARD_ACTIVE" != "true" || "$XANMOD_GUARD_HANDLING" == "true" ]]; then
        return
    fi
    XANMOD_GUARD_HANDLING=true
    trap - EXIT
    trap '' HUP INT TERM
    error "XanMod 事务异常退出，正在恢复运行前状态"
    cleanup_xanmod_transaction_state || true
    XANMOD_GUARD_ACTIVE=false
    if (( exit_status == 0 )); then
        exit_status=1
    fi
    restore_xanmod_saved_trap EXIT "$saved_exit"
    exit "$exit_status"
}

begin_xanmod_install_transaction() {
    XANMOD_APT_MAY_BE_PARTIAL=false
    XANMOD_CONFIG_MODIFIED=false
    install_xanmod_transaction_guards || return 1
    if ! prepare_xanmod_transaction; then
        if cleanup_xanmod_transaction_state; then
            clear_xanmod_transaction_guards
        fi
        return 1
    fi
    if ! create_xanmod_runtime_snapshot; then
        if cleanup_xanmod_transaction_state; then
            clear_xanmod_transaction_guards
        fi
        return 1
    fi
}

make_xanmod_stage_file() {
    local path_variable="$1"
    local target="$2"
    local suffix="$3"
    local target_dir
    local prefix

    target_dir=$(dirname "$target") || return 1
    install -d -m 0755 "$target_dir" || return 1
    prefix=".xanmod-stage.$(basename "$target")"
    xanmod_allocate_temp_file "$path_variable" "$target_dir" "$prefix" "$suffix" 0600
}

cleanup_xanmod_stages() {
    local cleanup_failed=false

    if [[ -n "$XANMOD_STAGED_KEY" ]]; then
        if [[ ! -e "$XANMOD_STAGED_KEY" && ! -L "$XANMOD_STAGED_KEY" ]] ||
            remove_xanmod_temp_file "$XANMOD_STAGED_KEY" "XanMod staged key"; then
            XANMOD_STAGED_KEY=""
        else
            cleanup_failed=true
        fi
    fi
    if [[ -n "$XANMOD_STAGED_SOURCE" ]]; then
        if [[ ! -e "$XANMOD_STAGED_SOURCE" && ! -L "$XANMOD_STAGED_SOURCE" ]] ||
            remove_xanmod_temp_file "$XANMOD_STAGED_SOURCE" "XanMod staged source"; then
            XANMOD_STAGED_SOURCE=""
        else
            cleanup_failed=true
        fi
    fi
    if [[ -n "$XANMOD_CANDIDATE_SOURCE" ]]; then
        if [[ ! -e "$XANMOD_CANDIDATE_SOURCE" && ! -L "$XANMOD_CANDIDATE_SOURCE" ]] ||
            remove_xanmod_temp_file "$XANMOD_CANDIDATE_SOURCE" "XanMod candidate source"; then
            XANMOD_CANDIDATE_SOURCE=""
        else
            cleanup_failed=true
        fi
    fi
    if [[ -n "$XANMOD_ARMORED_KEY_TEMP" ]]; then
        if [[ ! -e "$XANMOD_ARMORED_KEY_TEMP" && ! -L "$XANMOD_ARMORED_KEY_TEMP" ]] ||
            remove_xanmod_temp_file "$XANMOD_ARMORED_KEY_TEMP" "XanMod armored key"; then
            XANMOD_ARMORED_KEY_TEMP=""
        else
            cleanup_failed=true
        fi
    fi
    if [[ -n "$XANMOD_RESTORE_STAGE" ]]; then
        if [[ ! -e "$XANMOD_RESTORE_STAGE" && ! -L "$XANMOD_RESTORE_STAGE" ]] ||
            remove_xanmod_temp_file "$XANMOD_RESTORE_STAGE" "XanMod restore stage"; then
            XANMOD_RESTORE_STAGE=""
        else
            cleanup_failed=true
        fi
    fi

    [[ "$cleanup_failed" == "false" ]]
}

stage_xanmod_key() {
    local key_url

    make_xanmod_stage_file XANMOD_STAGED_KEY "$XANMOD_KEYRING" .gpg || return 1

    if xanmod_keyring_valid "$XANMOD_KEYRING"; then
        if install -m 0600 "$XANMOD_KEYRING" "$XANMOD_STAGED_KEY" &&
            set_xanmod_staged_file_metadata "$XANMOD_STAGED_KEY" &&
            xanmod_keyring_valid "$XANMOD_STAGED_KEY"; then
            return 0
        fi
        cleanup_xanmod_stages || true
        return 1
    fi

    if [[ -e "$XANMOD_KEYRING" || -L "$XANMOD_KEYRING" ]]; then
        warn "现有 XanMod 密钥不满足严格内容校验，将重新获取"
    fi

    if ! xanmod_allocate_temp_file XANMOD_ARMORED_KEY_TEMP \
        "${TMPDIR:-/tmp}" xanmod-key .asc 0600; then
        cleanup_xanmod_stages || true
        return 1
    fi

    for key_url in "$XANMOD_KEY_URL" "$XANMOD_KEY_FALLBACK_UBUNTU"; do
        info "下载 XanMod 软件源签名密钥: $key_url"
        if ! : > "$XANMOD_ARMORED_KEY_TEMP" ||
            ! curl -fsSL --connect-timeout 10 --max-time 30 \
                "$key_url" -o "$XANMOD_ARMORED_KEY_TEMP"; then
            warn "该密钥来源下载失败，尝试下一个来源"
            continue
        fi
        if ! xanmod_keyring_valid "$XANMOD_ARMORED_KEY_TEMP"; then
            warn "该密钥来源未通过严格主密钥指纹与 UID 校验，尝试下一个来源"
            continue
        fi

        remove_xanmod_temp_file "$XANMOD_STAGED_KEY" "XanMod staged key" || break
        if ! gpg --batch --yes --dearmor --output "$XANMOD_STAGED_KEY" "$XANMOD_ARMORED_KEY_TEMP"; then
            warn "XanMod 签名密钥转换失败，尝试下一个来源"
            remove_xanmod_temp_file "$XANMOD_STAGED_KEY" "XanMod staged key" || break
            make_xanmod_stage_file XANMOD_STAGED_KEY "$XANMOD_KEYRING" .gpg || break
            continue
        fi
        if ! set_xanmod_staged_file_metadata "$XANMOD_STAGED_KEY"; then
            break
        fi
        if xanmod_keyring_valid "$XANMOD_STAGED_KEY"; then
            if ! remove_xanmod_temp_file "$XANMOD_ARMORED_KEY_TEMP" "XanMod armored key"; then
                cleanup_xanmod_stages || true
                return 1
            fi
            XANMOD_ARMORED_KEY_TEMP=""
            return 0
        fi

        warn "转换后的 XanMod 密钥未通过严格校验，尝试下一个来源"
        remove_xanmod_temp_file "$XANMOD_STAGED_KEY" "XanMod staged key" || break
        make_xanmod_stage_file XANMOD_STAGED_KEY "$XANMOD_KEYRING" .gpg || break
    done

    cleanup_xanmod_stages || true
    error "无法获得指纹为 $XANMOD_KEY_FINGERPRINT 且 UID 匹配的 XanMod 签名密钥"
    return 1
}

stage_xanmod_source() {
    local codename="$1"
    local repository
    local source_status=0

    make_xanmod_stage_file XANMOD_CANDIDATE_SOURCE "$XANMOD_SOURCE_DEB822" .sources || return 1
    XANMOD_SELECTED_REPOSITORY=""

    for repository in "${XANMOD_REPOSITORIES[@]}"; do
        info "探测 XanMod 软件源: $repository"
        if ! write_xanmod_deb822_source \
            "$XANMOD_CANDIDATE_SOURCE" "$repository" "$codename" "$XANMOD_STAGED_KEY" ||
            ! set_xanmod_staged_file_metadata "$XANMOD_CANDIDATE_SOURCE"; then
            cleanup_xanmod_stages || true
            return 1
        fi

        source_status=0
        xanmod_source_is_usable "$XANMOD_CANDIDATE_SOURCE" || source_status=$?
        if (( source_status == 0 )); then
            XANMOD_SELECTED_REPOSITORY="$repository"
            break
        fi
        if (( source_status == 125 )); then
            cleanup_xanmod_stages || true
            return 1
        fi
        warn "XanMod 软件源不可用: $repository"
    done

    if ! remove_xanmod_temp_file "$XANMOD_CANDIDATE_SOURCE" "XanMod candidate source"; then
        return 1
    fi
    XANMOD_CANDIDATE_SOURCE=""
    if [[ -z "$XANMOD_SELECTED_REPOSITORY" ]]; then
        error "所有 XanMod 软件源均不可用，未修改正式 APT 配置"
        return 1
    fi

    make_xanmod_stage_file XANMOD_STAGED_SOURCE "$XANMOD_SOURCE_DEB822" .sources || return 1
    write_xanmod_deb822_source \
        "$XANMOD_STAGED_SOURCE" "$XANMOD_SELECTED_REPOSITORY" "$codename" "$XANMOD_KEYRING" || return 1
    set_xanmod_staged_file_metadata "$XANMOD_STAGED_SOURCE"
}

xanmod_repository_files_ready() {
    local codename="$1"

    xanmod_deb822_source_configured &&
        [[ ! -e "$XANMOD_SOURCE_LIST" && ! -L "$XANMOD_SOURCE_LIST" ]] &&
        xanmod_source_matches_codename "$XANMOD_SOURCE_DEB822" "$codename"
}

xanmod_repository_ready() {
    local codename="$1"

    xanmod_repository_files_ready "$codename" || return 1
    xanmod_source_is_usable "$XANMOD_SOURCE_DEB822"
}

xanmod_after_formal_commit_hook() {
    :
}

configure_xanmod_repository() {
    local codename="$1"
    local ready_status=0
    local formal_status=0

    [[ "$XANMOD_TRANSACTION_ACTIVE" == "true" ]] || {
        error "拒绝在事务外修改 XanMod 配置"
        return 1
    }

    ensure_package "gpg" "gpg" || return 1
    install -d -m 0755 "$(dirname "$XANMOD_KEYRING")" || return 1
    install -d -m 0755 "$(dirname "$XANMOD_SOURCE_DEB822")" || return 1

    xanmod_repository_ready "$codename" || ready_status=$?
    if (( ready_status == 0 )); then
        echo "XanMod 软件源: 已配置并可用（$XANMOD_SOURCE_DEB822）"
        return 0
    fi
    if (( ready_status == 125 )); then
        return 1
    fi

    warn "现有 XanMod 软件源缺失、不安全、不匹配或不可用，将事务式重新配置"
    stage_xanmod_key || return 1
    if ! stage_xanmod_source "$codename"; then
        cleanup_xanmod_stages || true
        return 1
    fi
    xanmod_regular_file_trusted "$XANMOD_STAGED_KEY" 644 || return 1
    xanmod_regular_file_trusted "$XANMOD_STAGED_SOURCE" 644 || return 1

    XANMOD_CONFIG_MODIFIED=true
    if ! mv -fT -- "$XANMOD_STAGED_KEY" "$XANMOD_KEYRING"; then
        cleanup_xanmod_stages || true
        return 1
    fi
    XANMOD_STAGED_KEY=""

    if ! mv -fT -- "$XANMOD_STAGED_SOURCE" "$XANMOD_SOURCE_DEB822"; then
        cleanup_xanmod_stages || true
        return 1
    fi
    XANMOD_STAGED_SOURCE=""

    rm -f -- "$XANMOD_SOURCE_LIST" || return 1
    xanmod_after_formal_commit_hook || return 1

    if ! xanmod_formal_keyring_valid ||
        ! xanmod_deb822_source_configured ||
        ! xanmod_source_matches_codename "$XANMOD_SOURCE_DEB822" "$codename"; then
        error "正式 XanMod 文件未通过内容、owner 或 mode 校验"
        return 1
    fi
    xanmod_source_is_usable "$XANMOD_SOURCE_DEB822" || formal_status=$?
    if (( formal_status != 0 )); then
        if (( formal_status != 125 )); then
            error "正式 XanMod 软件源未通过隔离 APT 验证"
        fi
        return 1
    fi

    echo "XanMod 软件源: 已配置（Deb822 / $codename / $XANMOD_SELECTED_REPOSITORY）"
}
get_installed_xanmod_packages() {
    dpkg-query -W -f='${binary:Package} ${db:Status-Status}\n' \
        "linux-xanmod-*" 2>/dev/null |
        awk '$2 == "installed" { sub(/:amd64$/, "", $1); print $1 }' |
        sort -u
}

reset_xanmod_plan() {
    XANMOD_PLAN_ACTION=""
    XANMOD_PLAN_REASON=""
    XANMOD_PLAN_CODENAME=""
    XANMOD_PLAN_PSABI=""
    XANMOD_PLAN_TARGET_PACKAGE=""
    XANMOD_PLAN_INSTALLED_PACKAGES=""
    XANMOD_PLAN_PACKAGE_INSTALLED=false
    XANMOD_PLAN_REPOSITORY_READY=false
    XANMOD_PLAN_NEEDS_REPOSITORY_CHANGE=false
    XANMOD_PLAN_NEEDS_PACKAGE_INSTALL=false
}

resolve_xanmod_plan() {
    local detect_status=0

    reset_xanmod_plan
    XANMOD_PLAN_CODENAME=$(get_os_codename || true)
    if [[ -z "$XANMOD_PLAN_CODENAME" ]]; then
        XANMOD_PLAN_ACTION="skip"
        XANMOD_PLAN_REASON="无法识别系统发行版代号"
        return 0
    fi
    if ! xanmod_codename_safe "$XANMOD_PLAN_CODENAME" ||
        ! xanmod_codename_supported "$XANMOD_PLAN_CODENAME"; then
        XANMOD_PLAN_ACTION="skip"
        XANMOD_PLAN_REASON="当前入口不支持发行版代号 $XANMOD_PLAN_CODENAME"
        return 0
    fi
    if ! is_amd64; then
        XANMOD_PLAN_ACTION="skip"
        XANMOD_PLAN_REASON="当前架构不是受支持的 amd64/x86_64"
        return 0
    fi

    detect_status=0
    XANMOD_PLAN_TARGET_PACKAGE=$(detect_xanmod_package) || detect_status=$?
    case "$detect_status" in
        0)
            XANMOD_PLAN_PSABI=$(detect_x86_64_psabi_level || true)
            ;;
        2)
            XANMOD_PLAN_ACTION="skip"
            XANMOD_PLAN_PSABI="v1"
            XANMOD_PLAN_REASON="当前 CPU 仅达到 x86-64-v1，XanMod MAIN 至少需要 x86-64-v2"
            return 0
            ;;
        3)
            XANMOD_PLAN_TARGET_PACKAGE=$(get_running_xanmod_package || true)
            if [[ -z "$XANMOD_PLAN_TARGET_PACKAGE" ]]; then
                XANMOD_PLAN_ACTION="skip"
                XANMOD_PLAN_REASON="无法读取 CPU 指令集，且当前没有可作为兼容性证据的 XanMod 分支"
                return 0
            fi
            XANMOD_PLAN_PSABI="unknown-running-compatible"
            ;;
        *)
            XANMOD_PLAN_ACTION="skip"
            XANMOD_PLAN_REASON="无法确认适用的 XanMod 内核包"
            return 0
            ;;
    esac

    XANMOD_PLAN_INSTALLED_PACKAGES=$(get_installed_xanmod_packages || true)
    if package_is_installed "$XANMOD_PLAN_TARGET_PACKAGE"; then
        XANMOD_PLAN_PACKAGE_INSTALLED=true
    fi
    if xanmod_repository_files_ready "$XANMOD_PLAN_CODENAME"; then
        XANMOD_PLAN_REPOSITORY_READY=true
    fi

    if [[ "$XANMOD_PLAN_PACKAGE_INSTALLED" == "true" &&
        "$XANMOD_PLAN_REPOSITORY_READY" == "true" ]]; then
        XANMOD_PLAN_ACTION="noop"
        XANMOD_PLAN_REASON="目标包已安装，正式 XanMod 仓库文件严格安全有效"
        return 0
    fi

    XANMOD_PLAN_ACTION="modify"
    if [[ "$XANMOD_PLAN_REPOSITORY_READY" != "true" ]]; then
        XANMOD_PLAN_NEEDS_REPOSITORY_CHANGE=true
    fi
    if [[ "$XANMOD_PLAN_PACKAGE_INSTALLED" != "true" ]]; then
        XANMOD_PLAN_NEEDS_PACKAGE_INSTALL=true
    fi
}

show_xanmod_plan_result() {
    case "$XANMOD_PLAN_ACTION" in
        skip)
            warn "$XANMOD_PLAN_REASON，已安全跳过 XanMod"
            ;;
        noop)
            echo "XanMod: 无需修改（$XANMOD_PLAN_REASON）"
            ;;
        modify)
            echo "XanMod 修改计划："
            echo "  发行版代号: $XANMOD_PLAN_CODENAME"
            echo "  目标包: $XANMOD_PLAN_TARGET_PACKAGE"
            case "$XANMOD_PLAN_PSABI" in
                unknown-running-compatible) echo "  CPU psABI: 无法读取；沿用当前运行分支" ;;
                "") ;;
                *) echo "  CPU psABI: x86-64-$XANMOD_PLAN_PSABI" ;;
            esac
            if [[ "$XANMOD_PLAN_NEEDS_REPOSITORY_CHANGE" == "true" ]]; then
                echo "  APT 配置: 需要事务式重新生成 key/list/source"
            else
                echo "  APT 配置: 正式文件严格安全；安装前仍会隔离验证可用性"
            fi
            if [[ "$XANMOD_PLAN_NEEDS_PACKAGE_INSTALL" == "true" ]]; then
                echo "  内核包: 需要安装；系统原内核和其他 XanMod 分支会保留"
            else
                echo "  内核包: 已安装，仅修复正式仓库文件"
            fi
            ;;
    esac
}

abort_xanmod_install_transaction() {
    local config_was_modified="$XANMOD_CONFIG_MODIFIED"

    if cleanup_xanmod_transaction_state; then
        clear_xanmod_transaction_guards
    fi
    if [[ "$config_was_modified" == "true" && "$XANMOD_CONFIG_MODIFIED" == "false" ]]; then
        warn "XanMod APT 配置已恢复到本次运行前状态"
    elif [[ "$config_was_modified" == "true" ]]; then
        error "XanMod APT 配置回滚不完整，请立即人工检查三个受管文件"
    fi
    return 1
}

complete_xanmod_install_transaction() {
    XANMOD_CONFIG_MODIFIED=false
    XANMOD_APT_MAY_BE_PARTIAL=false
    if ! cleanup_xanmod_transaction_state; then
        return 1
    fi
    clear_xanmod_transaction_guards
}

install_xanmod() {
    local policy_output=""
    local candidate_version=""

    [[ "$XANMOD_PLAN_ACTION" == "modify" ]] || {
        error "没有可执行的 XanMod 修改计划"
        return 1
    }

    echo "检测到适合当前环境的 XanMod 包: $XANMOD_PLAN_TARGET_PACKAGE"
    if [[ -n "$XANMOD_PLAN_INSTALLED_PACKAGES" &&
        "$XANMOD_PLAN_PACKAGE_INSTALLED" != "true" ]]; then
        warn "已安装的 XanMod 包与 CPU 检测结果不匹配: $(tr '\n' ' ' <<< "$XANMOD_PLAN_INSTALLED_PACKAGES")"
        warn "将安装检测到的正确版本: $XANMOD_PLAN_TARGET_PACKAGE"
        echo "说明: 旧 XanMod 包将保留，确认新内核可正常启动后再手动清理。"
    fi

    if ! begin_xanmod_install_transaction; then
        error "无法建立 XanMod 安装事务"
        return 1
    fi

    if ! configure_xanmod_repository "$XANMOD_PLAN_CODENAME"; then
        error "XanMod 软件源配置失败"
        abort_xanmod_install_transaction || true
        return 1
    fi

    if package_is_installed "$XANMOD_PLAN_TARGET_PACKAGE"; then
        if ! complete_xanmod_install_transaction; then
            error "XanMod 配置已提交，但临时事务状态清理失败"
            return 1
        fi
        echo "XanMod 目标包: 已安装（$XANMOD_PLAN_TARGET_PACKAGE）"
        return 0
    fi

    info "更新软件包索引..."
    if ! apt-get update; then
        error "XanMod 软件源索引更新失败"
        abort_xanmod_install_transaction || true
        return 1
    fi

    if ! policy_output=$(apt-cache policy "$XANMOD_PLAN_TARGET_PACKAGE"); then
        error "无法查询 XanMod 候选版本"
        abort_xanmod_install_transaction || true
        return 1
    fi
    candidate_version=$(awk '/Candidate:/ {print $2; exit}' <<< "$policy_output")
    if [[ -z "$candidate_version" || "$candidate_version" == "(none)" ]]; then
        error "XanMod 软件源没有可安装的 $XANMOD_PLAN_TARGET_PACKAGE 候选版本"
        abort_xanmod_install_transaction || true
        return 1
    fi

    info "安装 XanMod 内核包: $XANMOD_PLAN_TARGET_PACKAGE（$candidate_version）"
    XANMOD_APT_MAY_BE_PARTIAL=true
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y "$XANMOD_PLAN_TARGET_PACKAGE"; then
        error "XanMod 内核安装失败"
        abort_xanmod_install_transaction || true
        return 1
    fi
    if ! package_is_installed "$XANMOD_PLAN_TARGET_PACKAGE"; then
        error "XanMod 内核安装后验证失败"
        abort_xanmod_install_transaction || true
        return 1
    fi

    if ! complete_xanmod_install_transaction; then
        error "XanMod 已安装，但临时事务状态清理失败"
        return 1
    fi
    success "XanMod 内核已安装: $XANMOD_PLAN_TARGET_PACKAGE"
    echo "当前运行内核: $(uname -r)"
    echo "说明: 系统原内核未被移除；XanMod 将在下次系统重启后生效。"
}

show_xanmod_status() {
    local psabi_level=""
    local recommended_package=""
    local running_package=""
    local source_file=""
    local installed_packages=""
    local codename=""
    local repository_supported=true

    codename=$(get_os_codename || true)
    if [[ -z "$codename" ]] || ! xanmod_codename_safe "$codename" ||
        ! xanmod_codename_supported "$codename"; then
        repository_supported=false
    fi

    echo
    echo "XanMod 状态："
    echo "  当前架构: $(dpkg --print-architecture) / $(uname -m)"
    echo "  当前内核: $(uname -r)"

    if psabi_level=$(detect_x86_64_psabi_level); then
        echo "  CPU psABI: x86-64-$psabi_level"
        recommended_package=$(get_xanmod_package_for_psabi_level "$psabi_level" || true)
    else
        case $? in
            2) echo "  CPU psABI: x86-64-v1（MAIN 不支持）" ;;
            *) echo "  CPU psABI: 无法确认" ;;
        esac
    fi

    running_package=$(get_running_xanmod_package || true)
    if [[ -n "$running_package" ]]; then
        echo "  当前运行包: $running_package"
    else
        echo "  当前运行包: 无（当前为非 XanMod 内核）"
    fi

    if [[ "$repository_supported" != "true" ]]; then
        echo "  推荐包: 不适用（当前入口不支持 ${codename:-当前发行版}）"
        echo "  软件源: 不适用"
    else
        if [[ -n "$recommended_package" ]]; then
            echo "  推荐包: $recommended_package"
        elif [[ -n "$running_package" ]]; then
            echo "  推荐包: 无法检测；当前运行包可作为兼容性证据"
        else
            echo "  推荐包: 无"
        fi

        if source_file=$(get_xanmod_source_file); then
            case "$source_file" in
                *.sources) echo "  软件源: 已配置（Deb822，owner/mode 安全）" ;;
                *) echo "  软件源: 已配置（传统 list，owner/mode 安全）" ;;
            esac
            echo "  软件源文件: $source_file"
        else
            echo "  软件源: 未配置，或内容/owner/mode 未通过校验"
        fi
    fi

    installed_packages=$(get_installed_xanmod_packages || true)
    if [[ -n "$installed_packages" ]]; then
        echo "  已安装包: $(tr '\n' ' ' <<< "$installed_packages")"
    else
        echo "  已安装包: 无"
    fi
}

xanmod_lock_file_trusted() {
    local metadata=""
    local owner=""
    local group=""
    local mode=""
    local mode_value=0

    [[ -f "$XANMOD_LOCK" && ! -L "$XANMOD_LOCK" ]] || return 1
    metadata=$(stat -c '%u:%g:%a' -- "$XANMOD_LOCK") || return 1
    IFS=: read -r owner group mode <<< "$metadata"
    [[ "$owner" == "$XANMOD_TRUSTED_UID" && "$group" == "$XANMOD_TRUSTED_GID" ]] || return 1
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    mode_value=$((8#$mode))
    (( (mode_value & 0022) == 0 ))
}

take_xanmod_lock() {
    install -d -m 0755 "$(dirname "$XANMOD_LOCK")" || return 1
    if [[ ! -e "$XANMOD_LOCK" && ! -L "$XANMOD_LOCK" ]]; then
        install -m 0600 /dev/null "$XANMOD_LOCK" || return 1
    fi
    if ! xanmod_lock_file_trusted; then
        error "XanMod 锁文件类型、owner 或权限不可信: $XANMOD_LOCK"
        return 1
    fi

    exec 9>> "$XANMOD_LOCK"
    if ! xanmod_lock_file_trusted; then
        exec 9>&-
        error "XanMod 锁文件在打开时发生变化"
        return 1
    fi
    if ! flock -n 9; then
        exec 9>&-
        error "另一个 XanMod 安装或恢复任务正在运行"
        return 1
    fi
    XANMOD_LOCK_HELD=true
}

release_xanmod_lock() {
    local release_failed=false

    if [[ "$XANMOD_LOCK_HELD" == "true" ]]; then
        flock -u 9 || release_failed=true
        exec 9>&- || release_failed=true
        XANMOD_LOCK_HELD=false
    fi
    [[ "$release_failed" == "false" ]]
}

run_locked_xanmod_plan() {
    local execution_status=0

    take_xanmod_lock || return 1
    if ! resolve_xanmod_plan; then
        execution_status=1
    else
        case "$XANMOD_PLAN_ACTION" in
            modify) install_xanmod || execution_status=$? ;;
            skip|noop) show_xanmod_plan_result ;;
            *) execution_status=1 ;;
        esac
    fi
    release_xanmod_lock || execution_status=1
    return "$execution_status"
}

restore_system_customization(){ local scope="${1:-previous}" target result mr=0 xr=0 count=0 failed=false lr=false;local -a locales=(/etc/locale.gen /etc/locale.conf /etc/default/locale);[[ "$scope" == previous||"$scope" == initial ]]||return 1;motd_restore_group "$scope"||mr=$?;((mr==0))&&count=$((count+MOTD_RESTORED_COUNT));((mr==1))&&failed=true;for target in "${locales[@]}";do if restore_managed_file "$target" "$scope";then ((count+=1));lr=true;else result=$?;((result==1))&&failed=true;fi;done;restore_xanmod_group "$scope"||xr=$?;count=$((count+XANMOD_RESTORED_COUNT));((xr==1))&&failed=true;((count>0))||return 1;if [[ "$lr" == true ]];then command -v locale-gen>/dev/null&&locale-gen||failed=true;fi;echo "说明: 已安装的 XanMod 内核包不会被卸载。";[[ "$failed" == false ]]||return 1;success "系统定制配置已恢复到 $scope 状态（$count 个文件状态）"; }

# === 主流程 ===
show_help() {
    cat <<'EOF'
用法：
  system-customize.sh                 交互执行全部功能
  system-customize.sh all             交互执行全部功能
  system-customize.sh motd            仅配置动态欢迎信息
  system-customize.sh locale          仅配置中文环境
  system-customize.sh xanmod [--yes|-y]
                                      只读规划；必要时安装或修复 XanMod
  system-customize.sh status          查看 XanMod 状态
  system-customize.sh restore         恢复上一次运行前的配置
  system-customize.sh restore initial 恢复首次运行前的可信配置
  system-customize.sh help            显示本帮助

直接 xanmod 先执行只读规划。仅计划确实包含修改时使用 [y/N]；无 TTY 必须传入 --yes。
all 模式无 TTY 时仍完成 MOTD/Locale，但只跳过确需修改的 XanMod 步骤。
EOF
}

require_xanmod_plan_commands() {
    require_xanmod_commands awk dpkg dpkg-query grep sort stat tr uname
}

require_xanmod_mutation_commands() {
    require_xanmod_commands apt-cache apt-get awk basename cat chgrp chmod chown cp curl dirname \
        dpkg dpkg-query find flock grep id install ln mkdir mv od readlink rm rmdir sort stat tr uname
}

run_authorized_xanmod_install() {
    require_xanmod_mutation_commands || return 1
    run_locked_xanmod_plan
}

run_direct_xanmod_action() {
    local authorization_status=0
    local execution_status=0

    require_xanmod_plan_commands || return 1
    resolve_xanmod_plan || return 1
    show_xanmod_plan_result
    if [[ "$XANMOD_PLAN_ACTION" != "modify" ]]; then
        show_xanmod_status
        return 0
    fi

    authorize_xanmod_install || authorization_status=$?
    case "$authorization_status" in
        0) ;;
        2) return 0 ;;
        *) return 1 ;;
    esac

    require_root
    run_authorized_xanmod_install || execution_status=$?
    if (( execution_status == 0 )); then
        show_xanmod_status
    fi
    return "$execution_status"
}

main() {
    local action="${1:-all}"
    local authorization_status=0
    local xanmod_status=0
    local restore_status=0

    XANMOD_ASSUME_YES=false
    case "$action" in
        help|--help|-h)
            (( $# == 1 )) || { error "help 不接受额外参数"; return 1; }
            show_help
            return 0
            ;;
        xanmod)
            case $# in
                1) ;;
                2)
                    case "$2" in
                        --yes|-y) XANMOD_ASSUME_YES=true ;;
                        *) error "未知 XanMod 参数: $2"; show_help; return 1 ;;
                    esac
                    ;;
                *) error "xanmod 参数过多"; show_help; return 1 ;;
            esac
            run_direct_xanmod_action
            return
            ;;
        all)
            (( $# <= 1 )) || { error "all 不接受额外参数"; show_help; return 1; }
            ;;
        motd|locale|status)
            (( $# == 1 )) || { error "$action 不接受额外参数"; show_help; return 1; }
            ;;
        restore)
            (( $# <= 2 )) || { error "restore 参数过多"; show_help; return 1; }
            ;;
        *)
            error "未知参数: $action"
            show_help
            return 1
            ;;
    esac

    require_root

    local required_command
    for required_command in apt-get apt-cache awk bash basename cat chmod chown cp curl df dirname dpkg flock grep \
        hostname id install ln mkdir mktemp mv od readlink rm sed sha256sum sleep sort stat touch tr uname uptime wc; do
        if ! command -v "$required_command" >/dev/null 2>&1; then
            error "缺少必要命令: $required_command"
            return 1
        fi
    done

    case "$action" in
        all)
            info "🎨 配置系统定制功能..."
            echo
            configure_motd
            echo
            configure_chinese_locale
            echo

            require_xanmod_plan_commands || return 1
            resolve_xanmod_plan || return 1
            show_xanmod_plan_result
            if [[ "$XANMOD_PLAN_ACTION" == "modify" ]]; then
                if ! is_interactive_terminal; then
                    echo "XanMod 修改: 无交互终端，all 模式已安全跳过；如需执行请运行 xanmod --yes"
                else
                    authorize_xanmod_install || authorization_status=$?
                    case "$authorization_status" in
                        0) run_authorized_xanmod_install || xanmod_status=$? ;;
                        2) ;;
                        *) return 1 ;;
                    esac
                fi
            fi
            show_xanmod_status
            if (( xanmod_status != 0 )); then
                return "$xanmod_status"
            fi
            success "系统定制配置完成"
            ;;
        motd)
            configure_motd
            ;;
        locale)
            configure_chinese_locale
            ;;
        status)
            show_xanmod_status
            ;;
        restore)
            require_xanmod_commands basename cat chmod chgrp chown dirname flock ln mkdir mv od readlink rm rmdir sha256sum stat touch tr wc || return 1
            take_xanmod_lock || return 1
            restore_system_customization "${2:-previous}" || restore_status=$?
            release_xanmod_lock || restore_status=1
            return "$restore_status"
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    trap 'error "系统定制脚本在第 $LINENO 行执行失败"' ERR
    main "$@"
fi
