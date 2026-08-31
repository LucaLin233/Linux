#!/usr/bin/env bash
# Debian 动态 MOTD 配置脚本
# 内容与 modules/system-customize.sh 的 MOTD 功能保持一致。
set -euo pipefail
log(){ local msg="$1" level="${2:-info}";local -A c=([info]="\033[0;36m" [warn]="\033[0;33m" [error]="\033[0;31m" [success]="\033[0;32m");echo -e "${c[$level]}${msg}\033[0m"; }
info(){ log "$1" info; };warn(){ log "$1" warn; };error(){ log "$1" error; };success(){ log "$1" success; }
require_root(){ if ((EUID!=0))&&[[ "${MOTD_TEST_MODE:-0}" != 1 ]];then error "需要 root 权限运行";return 1;fi; }
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
declare -gA MOTD_STAGE_MODE=() MOTD_STAGE_DIGEST=() MOTD_STAGE_LINK=()
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
    local path="$1" metadata type owner gid mode atime mtime dev inode path_identity fd_meta after
    local parent
    parent=$(motd_path_parent "$path") || return 1
    motd_validate_directory_chain "$parent" || return 1
    [[ -f "$path" && ! -L "$path" ]] || return 1
    motd_legacy_io_hook stat "$path" || return 1
    metadata=$(stat -c '%F:%u:%g:%a:%X:%Y:%d:%i' -- "$path") || return 1
    IFS=: read -r type owner gid mode atime mtime dev inode <<< "$metadata"
    [[ "$type" == "regular file" || "$type" == "regular empty file" ]] || return 1
    [[ "$owner" == "$MOTD_TRUSTED_UID" && "$gid" == "$MOTD_TRUSTED_GID" && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$mode & 0022) == 0 )) || return 1
    path_identity="$dev:$inode"
    motd_legacy_io_hook open "$path" || return 1
    { exec {MOTD_LEGACY_FD}<"$path"; } 2>/dev/null || return 1
    fd_meta=$(stat -Lc '%F:%u:%g:%a:%d:%i' -- "/proc/$BASHPID/fd/$MOTD_LEGACY_FD") || { exec {MOTD_LEGACY_FD}>&- || true; MOTD_LEGACY_FD=""; return 1; }
    IFS=: read -r type owner gid mode dev inode <<< "$fd_meta"
    after=$(stat -c '%d:%i' -- "$path" 2>/dev/null) || after=""
    if [[ "$type" != "regular file" && "$type" != "regular empty file" ]] || [[ "$owner" != "$MOTD_TRUSTED_UID" || "$gid" != "$MOTD_TRUSTED_GID" || "$dev:$inode" != "$path_identity" || "$after" != "$path_identity" ]]; then
        exec {MOTD_LEGACY_FD}>&- || true
        MOTD_LEGACY_FD=""
        return 1
    fi
    MOTD_LEGACY_UID=$owner; MOTD_LEGACY_GID=$gid; MOTD_LEGACY_MODE=${metadata#*:*:*:}; MOTD_LEGACY_MODE=${MOTD_LEGACY_MODE%%:*}
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
    mv -T -- "$stage" "$final" || return 1
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
    motd_legacy_io_hook mv "$final" || return 1
    mv -T -- "$stage" "$final" || return 1
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

motd_set_pointer() {
    local scope="$1" generation="$2" pointer stage
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
    if [[ "$MOTD_ROLLBACK_MODE" == false ]]; then motd_snapshot_commit_hook "$scope" "$generation" pointer || return 1; fi
    mv -Tf -- "$stage" "$pointer" || return 1
    motd_array_remove_value MOTD_POINTER_STAGE_PATHS "$stage"
    motd_read_pointer "$scope" >/dev/null
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
    local pending="$MOTD_STATE_DIR/pending" stage stage_id pending_id
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
    motd_validate_secure_file "$stage" || return 1
    stage_id=$(stat -c '%d:%i' -- "$stage") || return 1
    motd_transaction_phase_hook pending-publish || return 1
    ln -- "$stage" "$pending" || return 1
    pending_id=$(stat -c '%d:%i' -- "$pending") || return 1
    [[ "$pending_id" == "$stage_id" ]] || return 1
    rm -f -- "$stage" || return 1
    motd_array_remove_value MOTD_PENDING_STAGE_PATHS "$stage"
    motd_validate_secure_file "$pending" || return 1
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
    motd_validate_secure_file "$pending" || return 1
    IFS= read -r value < "$pending" || return 1
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
    [[ "$MOTD_PREVIOUS_OLD" =~ ^[0-9a-f]{32}$ ]] || return 0
    current_initial=$(motd_read_pointer initial) || return 1
    current_previous=$(motd_read_pointer previous) || return 1
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
    local path name failed=false
    shopt -s nullglob
    for path in "$MOTD_STATE_DIR"/.initial.pointer.* "$MOTD_STATE_DIR"/.previous.pointer.* "$MOTD_STATE_DIR"/.pending.*; do
        name=${path##*/}
        [[ "$name" =~ ^\.(initial|previous)\.pointer\.[0-9a-f]{32}$ || "$name" =~ ^\.pending\.[0-9a-f]{32}$ ]] || { error "未知 MOTD root residue: $path"; failed=true; continue; }
        motd_validate_secure_file "$path" && rm -f -- "$path" || { error "不可信或无法清理的 MOTD residue: $path"; failed=true; }
    done
    shopt -u nullglob
    [[ "$failed" == false ]]
}

motd_cleanup_generation_stages() {
    local path failed=false
    shopt -s nullglob
    for path in "$MOTD_STATE_DIR/generations"/.*.stage; do
        [[ "${path##*/}" =~ ^\.[0-9a-f]{32}\.stage$ ]] && motd_validate_secure_directory "$path" && rm -rf -- "$path" || { error "不可信或无法清理的 generation stage: $path"; failed=true; }
    done
    shopt -u nullglob
    [[ "$failed" == false ]]
}

motd_scan_transactions_without_pending() {
    local path name failed=false
    shopt -s nullglob
    for path in "$MOTD_TRANSACTION_PARENT"/* "$MOTD_TRANSACTION_PARENT"/.*.stage; do
        [[ -e "$path" || -L "$path" ]] || continue
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
                    if motd_validate_journal_generations rolledback "$MOTD_JOURNAL_INITIAL_OLD" "$MOTD_JOURNAL_PREVIOUS_OLD" "$MOTD_JOURNAL_INITIAL_NEW" "$MOTD_JOURNAL_PREVIOUS_NEW"; then
                        rm -rf -- "$path" || { error "无法清理 rolledback transaction: $path"; failed=true; }
                    else error "rolledback transaction generation 不一致: $path"; failed=true; fi
                    ;;
                committed)
                    if motd_validate_journal_generations committed "$MOTD_JOURNAL_INITIAL_OLD" "$MOTD_JOURNAL_PREVIOUS_OLD" "$MOTD_JOURNAL_INITIAL_NEW" "$MOTD_JOURNAL_PREVIOUS_NEW"; then
                        MOTD_PREVIOUS_OLD=$MOTD_JOURNAL_PREVIOUS_OLD; MOTD_PREVIOUS_NEW=$MOTD_JOURNAL_PREVIOUS_NEW
                        motd_cleanup_replaced_previous_generation || failed=true
                        rm -rf -- "$path" || { error "无法清理 committed transaction: $path"; failed=true; }
                        MOTD_PREVIOUS_OLD=absent; MOTD_PREVIOUS_NEW=-
                    else
                        error "committed transaction generation 不一致: $path"; failed=true
                    fi
                    ;;
                *) error "active transaction 缺少 pending: $path"; failed=true ;;
            esac
        else
            error "未知 transaction residue: $path"; failed=true
        fi
    done
    shopt -u nullglob
    [[ "$failed" == false ]]
}

motd_prune_unreferenced_generations() {
    local path name initial previous failed=false
    initial=$(motd_read_pointer_or_absent initial) || return 1
    previous=$(motd_read_pointer_or_absent previous) || return 1
    shopt -s nullglob
    for path in "$MOTD_STATE_DIR/generations"/*; do
        name=${path##*/}
        [[ "$name" =~ ^[0-9a-f]{32}$ ]] || { error "未知 generation 对象: $path"; failed=true; continue; }
        [[ "$name" == "$initial" || "$name" == "$previous" ]] && continue
        motd_validate_snapshot "$path" initial "$name" >/dev/null 2>&1 || motd_validate_snapshot "$path" previous "$name" >/dev/null 2>&1 || { error "不可信 generation: $path"; failed=true; continue; }
        rm -rf -- "$path" || { error "无法清理 generation: $path"; failed=true; }
    done
    shopt -u nullglob
    [[ "$failed" == false ]]
}

motd_begin_transaction() {
    local operation="$1" transaction stage final
    MOTD_INITIAL_OLD=$(motd_read_pointer_or_absent initial) || return 1
    MOTD_PREVIOUS_OLD=$(motd_read_pointer_or_absent previous) || return 1
    MOTD_INITIAL_NEW=-; MOTD_PREVIOUS_NEW=-
    transaction=$(motd_random_id) || return 1
    stage="$MOTD_TRANSACTION_PARENT/.${transaction}.stage"
    final="$MOTD_TRANSACTION_PARENT/$transaction"
    MOTD_TRANSACTION_ID=$transaction
    MOTD_TRANSACTION_OPERATION=$operation
    MOTD_TRANSACTION_BUILDING_PATH=$stage
    MOTD_TRANSACTION_FINAL_PATH=$final
    [[ ! -e "$stage" && ! -L "$stage" && ! -e "$final" && ! -L "$final" ]] || return 1
    mkdir -m 0700 -- "$stage" || return 1
    chown "$MOTD_TRUSTED_UID:$MOTD_TRUSTED_GID" "$stage" || return 1
    motd_transaction_phase_hook transaction-snapshot-building || return 1
    motd_capture_snapshot_to_dir "$stage/rollback" runtime "$transaction" false || return 1
    MOTD_TRANSACTION_DIR=$stage
    motd_write_journal prepared || return 1
    motd_transaction_phase_hook snapshot-commit || return 1
    motd_transaction_phase_hook transaction-final-move || return 1
    mv -T -- "$stage" "$final" || return 1
    MOTD_TRANSACTION_DIR=$final
    MOTD_TRANSACTION_BUILDING_PATH=""
    motd_transaction_phase_hook transaction-final-moved || return 1
    motd_publish_pending || return 1
    MOTD_TRANSACTION_ACTIVE=true
    motd_transaction_phase_hook pending-published || return 1
    motd_write_journal active || return 1
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
    local path="$MOTD_TRANSACTION_DIR"
    [[ -n "$path" ]] || return 0
    motd_remove_tracked_dir "$path" "$MOTD_TRANSACTION_PARENT" "$MOTD_TRANSACTION_ID"
}

motd_abort_transaction() {
    local rollback_failed=false cleanup_failed=false
    if [[ "$MOTD_TRANSACTION_ACTIVE" == true && "$MOTD_TRANSACTION_COMMITTED" == false ]]; then
        motd_rollback_current_transaction || rollback_failed=true
    fi
    motd_cleanup_stage_arrays || cleanup_failed=true
    if [[ "$rollback_failed" == true || "$cleanup_failed" == true ]]; then
        error "MOTD rollback/cleanup 不完整，保留 journal: $MOTD_TRANSACTION_DIR"
        return 1
    fi
    motd_write_journal rolledback || return 1
    motd_cleanup_new_generations || return 1
    motd_remove_pending_for_transaction || return 1
    motd_remove_transaction_directory || return 1
    motd_clear_transaction_globals
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
    MOTD_TRANSACTION_COMMITTED=true
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
    MOTD_TRANSACTION_ACTIVE=false; MOTD_TRANSACTION_COMMITTED=false; MOTD_ROLLBACK_MODE=false
    MOTD_TRANSACTION_ID=""; MOTD_TRANSACTION_OPERATION=""; MOTD_TRANSACTION_BUILDING_PATH=""; MOTD_TRANSACTION_FINAL_PATH=""; MOTD_TRANSACTION_DIR=""
    MOTD_INITIAL_OLD=absent; MOTD_PREVIOUS_OLD=absent; MOTD_INITIAL_NEW=-; MOTD_PREVIOUS_NEW=-
    MOTD_TARGET_ACTION=(); MOTD_TARGET_STAGE=(); MOTD_STAGE_DEV=(); MOTD_STAGE_INO=(); MOTD_STAGE_TYPE=(); MOTD_STAGE_UID=(); MOTD_STAGE_GID=(); MOTD_STAGE_MODE=(); MOTD_STAGE_DIGEST=(); MOTD_STAGE_LINK=()
    MOTD_SNAPSHOT_BUILDING_PATHS=(); MOTD_SNAPSHOT_FINAL_PATHS=(); MOTD_POINTER_STAGE_PATHS=(); MOTD_PENDING_STAGE_PATHS=(); MOTD_NEW_GENERATIONS=(); MOTD_ALL_TARGET_STAGE_PATHS=()
}

motd_reset_target_plan() {
    MOTD_TARGET_ACTION=(); MOTD_TARGET_STAGE=(); MOTD_STAGE_DEV=(); MOTD_STAGE_INO=(); MOTD_STAGE_TYPE=()
    MOTD_STAGE_UID=(); MOTD_STAGE_GID=(); MOTD_STAGE_MODE=(); MOTD_STAGE_DIGEST=(); MOTD_STAGE_LINK=()
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

motd_lstat_stage() {
    local path="$1" metadata
    metadata=$(stat -c '%F:%u:%g:%a:%d:%i' -- "$path" 2>/dev/null) || return 1
    printf '%s\n' "$metadata"
}

motd_record_target_stage() {
    local id="$1" expected_type="$2" expected_uid="$3" expected_gid="$4" expected_mode="$5" expected_digest="$6" expected_link="$7"
    local path=${MOTD_TARGET_STAGE[$id]} metadata type uid gid mode dev inode actual
    [[ -n "$path" ]] || return 1
    metadata=$(motd_lstat_stage "$path") || return 1
    IFS=: read -r type uid gid mode dev inode <<< "$metadata"
    case "$expected_type" in
        regular)
            [[ -f "$path" && ! -L "$path" && ( "$type" == "regular file" || "$type" == "regular empty file" ) ]] || return 1
            actual=$(sha256sum "$path") || return 1
            [[ "${actual%% *}" == "$expected_digest" ]] || return 1
            ;;
        symlink)
            [[ -L "$path" && "$type" == "symbolic link" ]] || return 1
            actual=$(readlink -- "$path") || return 1
            [[ "$actual" == "$expected_link" ]] || return 1
            ;;
        *) return 1 ;;
    esac
    [[ "$uid" == "$expected_uid" && "$gid" == "$expected_gid" && "$mode" == "$expected_mode" ]] || return 1
    MOTD_STAGE_DEV[$id]=$dev; MOTD_STAGE_INO[$id]=$inode; MOTD_STAGE_TYPE[$id]=$expected_type
    MOTD_STAGE_UID[$id]=$expected_uid; MOTD_STAGE_GID[$id]=$expected_gid; MOTD_STAGE_MODE[$id]=$expected_mode
    MOTD_STAGE_DIGEST[$id]=$expected_digest; MOTD_STAGE_LINK[$id]=$expected_link
}

motd_validate_target_stage() {
    local id="$1" path=${MOTD_TARGET_STAGE[$1]:-} metadata type uid gid mode dev inode actual
    [[ "${MOTD_TARGET_ACTION[$id]:-}" == replace && -n "$path" ]] || return 1
    metadata=$(motd_lstat_stage "$path") || return 1
    IFS=: read -r type uid gid mode dev inode <<< "$metadata"
    [[ "$dev" == "${MOTD_STAGE_DEV[$id]}" && "$inode" == "${MOTD_STAGE_INO[$id]}" && "$uid" == "${MOTD_STAGE_UID[$id]}" && "$gid" == "${MOTD_STAGE_GID[$id]}" && "$mode" == "${MOTD_STAGE_MODE[$id]}" ]] || return 1
    case "${MOTD_STAGE_TYPE[$id]}" in
        regular)
            [[ -f "$path" && ! -L "$path" && ( "$type" == "regular file" || "$type" == "regular empty file" ) ]] || return 1
            actual=$(sha256sum "$path") || return 1
            [[ "${actual%% *}" == "${MOTD_STAGE_DIGEST[$id]}" ]] || return 1
            ;;
        symlink)
            [[ -L "$path" && "$type" == "symbolic link" ]] || return 1
            actual=$(readlink -- "$path") || return 1
            [[ "$actual" == "${MOTD_STAGE_LINK[$id]}" ]] || return 1
            ;;
        *) return 1 ;;
    esac
}

motd_validate_all_target_stages() {
    local id
    for id in "${MOTD_TARGET_IDS[@]}"; do
        case "${MOTD_TARGET_ACTION[$id]:-}" in
            replace) motd_validate_target_stage "$id" || { error "MOTD stage 完整性失败: $id"; return 1; } ;;
            delete|noop) [[ -z "${MOTD_TARGET_STAGE[$id]:-}" ]] || return 1 ;;
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
    touch -a -d "@$atime" "$stage" || return 1
    touch -m -d "@$mtime" "$stage" || return 1
    MOTD_TARGET_ACTION[$id]=replace
    motd_record_target_stage "$id" regular "$uid" "$gid" "$mode" "$digest" ""
}

motd_prepare_symlink_stage() {
    local id="$1" link="$2" stage
    motd_allocate_target_stage "$id" || return 1
    stage=$MOTD_ALLOCATED_PATH
    ln -s -- "$link" "$stage" || return 1
    MOTD_TARGET_ACTION[$id]=replace
    motd_record_target_stage "$id" symlink "$MOTD_TRUSTED_UID" "$MOTD_TRUSTED_GID" 777 "" "$link"
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
                motd_allocate_target_stage "$id" || return 1
    stage=$MOTD_ALLOCATED_PATH
                (umask 022; set -o noclobber; : > "$stage") 2>/dev/null || return 1
                chown "$MOTD_TRUSTED_UID:$MOTD_TRUSTED_GID" "$stage" || return 1
                chmod 0644 "$stage" || return 1
                MOTD_TARGET_ACTION[$id]=replace
                motd_record_target_stage "$id" regular "$MOTD_TRUSTED_UID" "$MOTD_TRUSTED_GID" 644 "$empty_digest" "" || return 1
                ;;
            custom_welcome)
                motd_allocate_target_stage "$id" || return 1
    stage=$MOTD_ALLOCATED_PATH
                motd_write_payload "$stage" || return 1
                chown "$MOTD_TRUSTED_UID:$MOTD_TRUSTED_GID" "$stage" || return 1
                chmod 0755 "$stage" || return 1
                bash -n "$stage" || return 1
                digest=$(sha256sum "$stage") || return 1
                [[ "${digest%% *}" == "$MOTD_PAYLOAD_SHA256" ]] || return 1
                MOTD_TARGET_ACTION[$id]=replace
                motd_record_target_stage "$id" regular "$MOTD_TRUSTED_UID" "$MOTD_TRUSTED_GID" 755 "$MOTD_PAYLOAD_SHA256" "" || return 1
                ;;
            uname|motd_news)
                if [[ ! -e "$path" && ! -L "$path" ]]; then
                    MOTD_TARGET_ACTION[$id]=noop; MOTD_TARGET_STAGE[$id]=""
                elif [[ -L "$path" ]]; then
                    # Delete the entry itself; never follow or modify the external target.
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
        if [[ "$action" == replace ]]; then motd_validate_target_stage "$id" || { error "提交前 stage 已变化: $id"; return 1; }; fi
        if [[ "$rollback_mode" == true ]]; then
            motd_rollback_hook "$id" "$path" || { error "rollback hook 失败: $id"; failed=true; continue; }
        else
            motd_target_commit_hook "$operation" "$id" "$path" || { error "target commit hook 失败: $id"; return 1; }
        fi
        case "$action" in
            replace)
                mv -Tf -- "$stage" "$path" || { error "目标原子替换失败: $id"; [[ "$rollback_mode" == true ]] && { failed=true; continue; }; return 1; }
                MOTD_TARGET_STAGE[$id]=""
                motd_array_remove_value MOTD_ALL_TARGET_STAGE_PATHS "$stage"
                ;;
            delete)
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
    local directory="$1" path name failed=false
    shopt -s nullglob
    for path in "$directory"/* "$directory"/.*; do
        [[ -e "$path" || -L "$path" ]] || continue
        name=${path##*/}
        [[ "$name" == . || "$name" == .. ]] && continue
        case "$name" in
            rollback) motd_validate_secure_directory "$path" || failed=true ;;
            journal) motd_validate_secure_file "$path" || failed=true ;;
            .journal.*) [[ "$name" =~ ^\.journal\.[0-9a-f]{32}$ ]] && motd_validate_secure_file "$path" || failed=true ;;
            *) failed=true ;;
        esac
    done
    shopt -u nullglob
    [[ "$failed" == false ]]
}

motd_cleanup_target_residue_for_transaction() {
    local transaction="$1" path name failed=false
    [[ "$transaction" =~ ^[0-9a-f]{32}$ ]] || return 1
    shopt -s nullglob
    for path in "$MOTD_ETC_ROOT"/.linux-setup-motd.* "$MOTD_ETC_ROOT/update-motd.d"/.linux-setup-motd.*; do
        name=${path##*/}
        [[ "$name" =~ ^\.linux-setup-motd\.${transaction}\.(motd|issue|issue_net|custom_welcome|uname|motd_news)\.[0-9a-f]{32}$ ]] || { error "未知 target stage residue: $path"; failed=true; continue; }
        if [[ -d "$path" && ! -L "$path" ]] || ! rm -f -- "$path"; then error "无法清理 target stage residue: $path"; failed=true; fi
    done
    shopt -u nullglob
    [[ "$failed" == false ]]
}

motd_assert_no_target_residue() {
    local path
    shopt -s nullglob
    for path in "$MOTD_ETC_ROOT"/.linux-setup-motd.* "$MOTD_ETC_ROOT/update-motd.d"/.linux-setup-motd.*; do
        error "未识别 target stage residue: $path"
        shopt -u nullglob
        return 1
    done
    shopt -u nullglob
}

configure_motd(){ motd_install_group; }
restore_motd(){ local n=0;motd_restore_group "${1:-previous}"||n=$?;((n!=2))||{ error "没有可恢复的可信 MOTD 组 snapshot";return 1;};return "$n"; }
show_status(){ if [[ -x "$MOTD_SCRIPT" ]]&&grep -Fq '# linux-setup:managed-motd' "$MOTD_SCRIPT";then echo "MOTD 状态: 已安装并受管";elif [[ -e "$MOTD_SCRIPT"||-L "$MOTD_SCRIPT" ]];then echo "MOTD 状态: 存在但不受本工具管理";else echo "MOTD 状态: 未安装";fi; }
show_help(){ echo '用法: setup-motd.sh [install|status|restore|help]'; }
require_motd_commands(){ local c;for c in awk bash basename cat chmod chown cp dirname flock grep hostname install ln mkdir mv od readlink rm sha256sum stat touch tr uname uptime df sed wc;do command -v "$c">/dev/null||return 1;done; }
main(){ local a="${1:-install}";case $a in help|-h|--help)show_help;;status)show_status;;install)require_root&&require_motd_commands&&configure_motd;;restore)require_root&&require_motd_commands&&restore_motd "${2:-previous}";;*)return 1;;esac; }
if [[ "${BASH_SOURCE[0]}" == "$0" ]];then trap 'error "MOTD 配置脚本在第 $LINENO 行执行失败"' ERR;main "$@";fi
