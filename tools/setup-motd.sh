#!/usr/bin/env bash
# Debian 动态 MOTD 配置脚本
# 内容与 modules/system-customize.sh 的 MOTD 功能保持一致。
set -euo pipefail
log(){ local msg="$1" level="${2:-info}";local -A c=([info]="\033[0;36m" [warn]="\033[0;33m" [error]="\033[0;31m" [success]="\033[0;32m");echo -e "${c[$level]}${msg}\033[0m"; }
info(){ log "$1" info; };warn(){ log "$1" warn; };error(){ log "$1" error; };success(){ log "$1" success; }
require_root(){ if ((EUID!=0))&&[[ "${MOTD_TEST_MODE:-0}" != 1 ]];then error "需要 root 权限运行";return 1;fi; }
# === MOTD group transaction ===
if [[ "${MOTD_TEST_MODE:-0}" == "1" ]]; then MOTD_ETC_ROOT="${MOTD_ETC_ROOT:-/etc}"; MOTD_STATE_DIR="${MOTD_STATE_DIR:-/var/lib/linux-setup/motd-backups}"; MOTD_LOCK_FILE="${MOTD_LOCK_FILE:-/run/lock/linux-setup-motd.lock}"; MOTD_TRANSACTION_PARENT="${MOTD_TRANSACTION_PARENT:-$MOTD_STATE_DIR/transactions}"; MOTD_TRUSTED_UID=$EUID; MOTD_TRUSTED_GID=$(id -g); else MOTD_ETC_ROOT=/etc; MOTD_STATE_DIR=/var/lib/linux-setup/motd-backups; MOTD_LOCK_FILE=/run/lock/linux-setup-motd.lock; MOTD_TRANSACTION_PARENT="$MOTD_STATE_DIR/transactions"; MOTD_TRUSTED_UID=0; MOTD_TRUSTED_GID=0; fi
readonly MOTD_ETC_ROOT MOTD_STATE_DIR MOTD_LOCK_FILE MOTD_TRANSACTION_PARENT MOTD_TRUSTED_UID MOTD_TRUSTED_GID
readonly MOTD_SCRIPT="$MOTD_ETC_ROOT/update-motd.d/00-custom-welcome" MOTD_SNAPSHOT_VERSION=1
readonly -a MOTD_TARGET_IDS=(motd issue issue_net custom_welcome uname motd_news)
readonly -a MOTD_TARGET_PATHS=("$MOTD_ETC_ROOT/motd" "$MOTD_ETC_ROOT/issue" "$MOTD_ETC_ROOT/issue.net" "$MOTD_SCRIPT" "$MOTD_ETC_ROOT/update-motd.d/10-uname" "$MOTD_ETC_ROOT/update-motd.d/50-motd-news")
declare -A MOTD_PATH_BY_ID=() MOTD_SNAPSHOT_STATE=() MOTD_SNAPSHOT_UID=() MOTD_SNAPSHOT_GID=() MOTD_SNAPSHOT_MODE=() MOTD_SNAPSHOT_ATIME=() MOTD_SNAPSHOT_MTIME=() MOTD_TARGET_ACTION=() MOTD_TARGET_STAGE=()
for MOTD_INDEX in "${!MOTD_TARGET_IDS[@]}"; do MOTD_PATH_BY_ID["${MOTD_TARGET_IDS[$MOTD_INDEX]}"]="${MOTD_TARGET_PATHS[$MOTD_INDEX]}"; done; unset MOTD_INDEX
MOTD_LOCK_FD="" MOTD_LOCK_HELD=false MOTD_TRANSACTION_ACTIVE=false MOTD_TRANSACTION_COMMITTED=false MOTD_TRANSACTION_ID="" MOTD_TRANSACTION_DIR="" MOTD_TRANSACTION_BUILDING_PATH="" MOTD_TRANSACTION_OPERATION=""
MOTD_INITIAL_OLD=absent MOTD_PREVIOUS_OLD=absent MOTD_INITIAL_NEW=- MOTD_PREVIOUS_NEW=- MOTD_SNAPSHOT_BUILDING_PATH="" MOTD_LAST_GENERATION="" MOTD_RESTORED_COUNT=0
MOTD_SAVED_TRAP_EXIT="" MOTD_SAVED_TRAP_HUP="" MOTD_SAVED_TRAP_INT="" MOTD_SAVED_TRAP_TERM="" MOTD_LEGACY_KIND="" MOTD_LEGACY_PATH="" MOTD_STATE_DIR_CREATED=false
motd_lock_acquired_hook(){ :; }; motd_state_directory_created_hook(){ :; }; motd_lock_open_hook(){ :; }; motd_lock_close_hook(){ :; }; motd_snapshot_capture_hook(){ :; }; motd_snapshot_commit_hook(){ :; }; motd_snapshot_manifest_hook(){ :; }; motd_target_commit_hook(){ :; }; motd_rollback_hook(){ :; }; motd_transaction_phase_hook(){ :; }; motd_preview_hook(){ "$MOTD_SCRIPT"; }
motd_random_id(){ local v=""; v=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null|tr -d ' \n')||return 1; [[ "$v" =~ ^[0-9a-f]{32}$ ]]||return 1; printf '%s\n' "$v"; }
motd_path_parent(){ local p="$1"; [[ "$p" == */* ]]||return 1; p=${p%/*}; [[ -n "$p" ]]||p=/; printf '%s\n' "$p"; }
motd_validate_ancestor_directory(){ local p="$1" m o g a v; [[ -d "$p"&&! -L "$p" ]]||return 1; m=$(stat -c '%u:%g:%a' -- "$p" 2>/dev/null)||return 1; IFS=: read -r o g a<<<"$m"; [[ "$a" =~ ^[0-7]{3,4}$ ]]||return 1; v=$((8#$a)); if [[ "$o" != 0 ]];then [[ "${MOTD_TEST_MODE:-0}" == 1&&"$o" == "$MOTD_TRUSTED_UID"&&"$g" == "$MOTD_TRUSTED_GID" ]]||return 1; elif [[ "$g" != 0&&"${MOTD_TEST_MODE:-0}" != 1 ]];then return 1;fi; (( (v&0002)==0||(v&01000)!=0&&o==0 ))||return 1; (( (v&0020)==0 ))||[[ "$o" == 0&&"$g" == 0 ]]; }
motd_validate_directory_chain(){
 local path="$1" current=/ component;local -a path_components=();[[ "$path" == /* ]]||return 1;IFS=/ read -r -a path_components<<<"${path#/}";motd_validate_ancestor_directory /||return 1
 for component in "${path_components[@]}";do [[ -n "$component"&&"$component" != .&&"$component" != .. ]]||continue;[[ "$current" == / ]]&&current="/$component"||current="$current/$component";[[ -e "$current"||-L "$current" ]]||return 1;motd_validate_ancestor_directory "$current"||return 1;done
}
motd_ensure_parent_chain(){
 local path="$1" parent current=/ component;local -a parent_components=();parent=$(motd_path_parent "$path")||return 1;IFS=/ read -r -a parent_components<<<"${parent#/}";motd_validate_ancestor_directory /||return 1
 for component in "${parent_components[@]}";do [[ -n "$component"&&"$component" != .&&"$component" != .. ]]||continue;[[ "$current" == / ]]&&current="/$component"||current="$current/$component";if [[ ! -e "$current"&&! -L "$current" ]];then mkdir -m700 "$current"||return 1;chown "$MOTD_TRUSTED_UID:$MOTD_TRUSTED_GID" "$current"||return 1;fi;motd_validate_ancestor_directory "$current"||return 1;done
}
motd_validate_secure_directory(){ local p="$1" m o g a;[[ -d "$p"&&! -L "$p" ]]||return 1;m=$(stat -c '%u:%g:%a' -- "$p" 2>/dev/null)||return 1;IFS=: read -r o g a<<<"$m";[[ "$o" == "$MOTD_TRUSTED_UID"&&"$g" == "$MOTD_TRUSTED_GID"&&"$a" == 700 ]]; }
motd_ensure_secure_directory(){ local p="$1";motd_ensure_parent_chain "$p"||return 1;if [[ ! -e "$p"&&! -L "$p" ]];then mkdir -m700 -- "$p"||return 1;chown "$MOTD_TRUSTED_UID:$MOTD_TRUSTED_GID" "$p"||return 1;fi;motd_validate_secure_directory "$p"; }
motd_validate_secure_file(){ local p="$1" m o g a;[[ -f "$p"&&! -L "$p" ]]||return 1;m=$(stat -c '%u:%g:%a' -- "$p" 2>/dev/null)||return 1;IFS=: read -r o g a<<<"$m";[[ "$o" == "$MOTD_TRUSTED_UID"&&"$g" == "$MOTD_TRUSTED_GID"&&"$a" == 600 ]]; }
motd_take_lock(){ local d pre fm pi o g a dev ino;[[ "$MOTD_LOCK_HELD" == false ]]||return 1;d=$(motd_path_parent "$MOTD_LOCK_FILE")||return 1;motd_validate_directory_chain "$d"||{ error "MOTD 锁父目录不可信: $d";return 1;};if [[ ! -e "$MOTD_LOCK_FILE"&&! -L "$MOTD_LOCK_FILE" ]];then (umask 077;set -o noclobber;: >"$MOTD_LOCK_FILE")2>/dev/null||return 1;chown "$MOTD_TRUSTED_UID:$MOTD_TRUSTED_GID" "$MOTD_LOCK_FILE"||return 1;chmod 600 "$MOTD_LOCK_FILE"||return 1;fi;motd_validate_secure_file "$MOTD_LOCK_FILE"||{ error "MOTD 锁文件类型、owner 或 mode 不可信: $MOTD_LOCK_FILE";return 1;};pre=$(stat -c '%d:%i' -- "$MOTD_LOCK_FILE")||return 1;motd_lock_open_hook "$MOTD_LOCK_FILE";{ exec {MOTD_LOCK_FD}<>"$MOTD_LOCK_FILE"; } 2>/dev/null||return 1;[[ -f "/proc/$BASHPID/fd/$MOTD_LOCK_FD" ]]||return 1;fm=$(stat -Lc '%u:%g:%a:%d:%i' -- "/proc/$BASHPID/fd/$MOTD_LOCK_FD")||return 1;IFS=: read -r o g a dev ino<<<"$fm";pi=$(stat -c '%d:%i' -- "$MOTD_LOCK_FILE" 2>/dev/null)||pi="";if [[ "$o" != "$MOTD_TRUSTED_UID"||"$g" != "$MOTD_TRUSTED_GID"||"$a" != 600||"$dev:$ino" != "$pre"||"$pi" != "$pre" ]];then error "MOTD 锁文件在检查和打开之间被替换";exec {MOTD_LOCK_FD}>&-||true;MOTD_LOCK_FD="";return 1;fi;flock -n "$MOTD_LOCK_FD"||{ error "已有 MOTD install/restore 正在运行";exec {MOTD_LOCK_FD}>&-||true;MOTD_LOCK_FD="";return 1;};MOTD_LOCK_HELD=true;if ! motd_lock_acquired_hook "$MOTD_LOCK_FILE";then motd_release_lock||true;return 1;fi; }
motd_release_lock(){ local f=false;[[ "$MOTD_LOCK_HELD" == true ]]||return 0;flock -u "$MOTD_LOCK_FD"||{ error "释放 MOTD 锁失败";f=true;};motd_lock_close_hook "$MOTD_LOCK_FD"||{ error "关闭 MOTD 锁 fd 失败";f=true;};exec {MOTD_LOCK_FD}>&-||{ error "关闭 MOTD 锁 fd 失败";f=true;};MOTD_LOCK_FD="";MOTD_LOCK_HELD=false;[[ "$f" == false ]]; }
motd_snapshot_object_path(){ printf '%s/objects/%s\n' "$1" "$2"; }
motd_reset_snapshot_metadata(){ MOTD_SNAPSHOT_STATE=();MOTD_SNAPSHOT_UID=();MOTD_SNAPSHOT_GID=();MOTD_SNAPSHOT_MODE=();MOTD_SNAPSHOT_ATIME=();MOTD_SNAPSHOT_MTIME=(); }
motd_validate_snapshot(){ local d="$1" es="$2" eg="${3:-}" mf l k gen="" sc="" id st u g m at mt dg ex obj md calc;local n=0 i=0;motd_validate_secure_directory "$d"||return 1;mf="$d/manifest";motd_validate_secure_file "$mf"||return 1;motd_validate_secure_directory "$d/objects"||return 1;motd_reset_snapshot_metadata;while IFS= read -r l||[[ -n "$l" ]];do ((n+=1));case "$n" in 1)[[ "$l" == "version=$MOTD_SNAPSHOT_VERSION" ]]||return 1;;2)sc=${l#scope=};[[ "$l" == scope=*&&"$sc" == "$es" ]]||return 1;;3)gen=${l#generation=};[[ "$l" == generation=*&&"$gen" =~ ^[0-9a-f]{32}$&& ( -z "$eg" || "$gen" == "$eg" ) ]]||return 1;;*)IFS='|' read -r k id st u g m at mt dg ex<<<"$l";[[ "$k" == target&&-z "$ex"&&"$id" == "${MOTD_TARGET_IDS[$i]:-}" ]]||return 1;obj=$(motd_snapshot_object_path "$d" "$id");case "$st" in regular)[[ "$u" =~ ^[0-9]+$&&"$g" =~ ^[0-9]+$&&"$m" =~ ^[0-7]{3,4}$&&"$at" =~ ^[0-9]+$&&"$mt" =~ ^[0-9]+$&&"$dg" =~ ^[0-9a-f]{64}$ ]]||return 1;motd_validate_secure_file "$obj"||return 1;calc=$(sha256sum "$obj");[[ "${calc%% *}" == "$dg" ]]||return 1;;symlink)[[ "$u$g$m$at$mt$dg" == ------&&-L "$obj" ]]||return 1;md=$(stat -c '%u:%g' -- "$obj")||return 1;[[ "$md" == "$MOTD_TRUSTED_UID:$MOTD_TRUSTED_GID" ]]||return 1;;absent)[[ "$u$g$m$at$mt$dg" == ------&&! -e "$obj"&&! -L "$obj" ]]||return 1;;unknown)[[ "$es" == initial&&"$u$g$m$at$mt$dg" == ------&&! -e "$obj"&&! -L "$obj" ]]||return 1;;*)return 1;;esac;MOTD_SNAPSHOT_STATE[$id]=$st;MOTD_SNAPSHOT_UID[$id]=$u;MOTD_SNAPSHOT_GID[$id]=$g;MOTD_SNAPSHOT_MODE[$id]=$m;MOTD_SNAPSHOT_ATIME[$id]=$at;MOTD_SNAPSHOT_MTIME[$id]=$mt;((i+=1));;esac;done<"$mf";[[ "$n" == 9&&"$i" == 6 ]]; }
motd_target_configuration_is_managed(){ [[ -f "$MOTD_SCRIPT"&&! -L "$MOTD_SCRIPT" ]]&&grep -Eq '# linux-setup:managed-motd|由 (system-customize|setup-motd)\.sh 自动生成' "$MOTD_SCRIPT"; }
motd_append_captured_target(){ local p="$1" id="$2" d="$3" mf="$4" unk="$5" obj md u g m at mt dg bdev bino before after link;obj=$(motd_snapshot_object_path "$d" "$id");motd_snapshot_capture_hook "$id" "$p"||return 1;if [[ "$unk" == true ]];then printf 'target|%s|unknown|-|-|-|-|-|-\n' "$id">>"$mf";return;fi;if [[ -L "$p" ]];then link=$(readlink -- "$p")||return 1;ln -s -- "$link" "$obj"||return 1;printf 'target|%s|symlink|-|-|-|-|-|-\n' "$id">>"$mf";return;fi;if [[ -f "$p" ]];then md=$(stat -c '%u:%g:%a:%X:%Y:%d:%i' -- "$p")||return 1;IFS=: read -r u g m at mt bdev bino<<<"$md";before="$bdev:$bino";(umask 077;set -o noclobber;: >"$obj")2>/dev/null||return 1;cat -- "$p">"$obj"||return 1;chown "$MOTD_TRUSTED_UID:$MOTD_TRUSTED_GID" "$obj"||return 1;chmod 600 "$obj"||return 1;after=$(stat -c '%d:%i' -- "$p")||return 1;[[ "$after" == "$before" ]]||return 1;dg=$(sha256sum "$obj");printf 'target|%s|regular|%s|%s|%s|%s|%s|%s\n' "$id" "$u" "$g" "$m" "$at" "$mt" "${dg%% *}">>"$mf";return;fi;if [[ ! -e "$p" ]];then printf 'target|%s|absent|-|-|-|-|-|-\n' "$id">>"$mf";return;fi;error "MOTD 目标类型不受支持: $p";return 1; }
motd_capture_snapshot_to_dir(){ local d="$1" sc="$2" gen="$3" unk="${4:-false}" mf id p;mkdir -m700 "$d"||return 1;chown "$MOTD_TRUSTED_UID:$MOTD_TRUSTED_GID" "$d"||return 1;mkdir -m700 "$d/objects"||return 1;chown "$MOTD_TRUSTED_UID:$MOTD_TRUSTED_GID" "$d/objects"||return 1;mf="$d/manifest";(umask 077;set -o noclobber;: >"$mf")2>/dev/null||return 1;chown "$MOTD_TRUSTED_UID:$MOTD_TRUSTED_GID" "$mf"||return 1;chmod 600 "$mf"||return 1;printf 'version=%s\nscope=%s\ngeneration=%s\n' "$MOTD_SNAPSHOT_VERSION" "$sc" "$gen">"$mf"||return 1;for id in "${MOTD_TARGET_IDS[@]}";do p=${MOTD_PATH_BY_ID[$id]};motd_append_captured_target "$p" "$id" "$d" "$mf" "$unk"||return 1;done;motd_snapshot_manifest_hook "$sc" "$mf"||return 1;motd_validate_snapshot "$d" "$sc" "$gen"; }
motd_remove_trusted_tree(){ local p="$1" parent="$2";[[ "$p" == "$parent"/*&&-d "$p"&&! -L "$p" ]]||return 1;motd_validate_secure_directory "$p"||return 1;rm -rf -- "$p"; }
motd_create_persistent_snapshot(){ local sc="$1" unk="${2:-false}" gen st fn;gen=$(motd_random_id)||return 1;st="$MOTD_STATE_DIR/generations/.${gen}.stage";fn="$MOTD_STATE_DIR/generations/$gen";[[ ! -e "$st"&&! -L "$st"&&! -e "$fn"&&! -L "$fn" ]]||return 1;MOTD_SNAPSHOT_BUILDING_PATH=$st;motd_capture_snapshot_to_dir "$st" "$sc" "$gen" "$unk"||return 1;motd_snapshot_commit_hook "$sc" "$gen" directory||return 1;mv -T "$st" "$fn"||return 1;MOTD_SNAPSHOT_BUILDING_PATH="";MOTD_LAST_GENERATION=$gen; }
motd_pointer_path(){ printf '%s/%s.current\n' "$MOTD_STATE_DIR" "$1"; }
motd_read_pointer(){ local sc="$1" p gen;p=$(motd_pointer_path "$sc");motd_validate_secure_file "$p"||return 1;IFS= read -r gen<"$p"||return 1;[[ "$gen" =~ ^[0-9a-f]{32}$&&"$(wc -l<"$p")" == 1 ]]||return 1;motd_validate_snapshot "$MOTD_STATE_DIR/generations/$gen" "$sc" "$gen"||return 1;printf '%s\n' "$gen"; }
motd_read_pointer_or_absent(){ local p;p=$(motd_pointer_path "$1");if [[ ! -e "$p"&&! -L "$p" ]];then printf 'absent\n';else motd_read_pointer "$1";fi; }
motd_set_pointer(){ local sc="$1" gen="$2" p tok st;p=$(motd_pointer_path "$sc")||return 1;if [[ "$gen" == absent ]];then if [[ -e "$p"||-L "$p" ]];then motd_validate_secure_file "$p"||return 1;rm -f "$p"||return 1;fi;return 0;fi;motd_validate_snapshot "$MOTD_STATE_DIR/generations/$gen" "$sc" "$gen"||return 1;tok=$(motd_random_id)||return 1;st="$MOTD_STATE_DIR/.${sc}.pointer.$tok";(umask 077;set -o noclobber;: >"$st")2>/dev/null||return 1;printf '%s\n' "$gen">"$st"||return 1;chown "$MOTD_TRUSTED_UID:$MOTD_TRUSTED_GID" "$st"||return 1;chmod 600 "$st"||return 1;motd_snapshot_commit_hook "$sc" "$gen" pointer||return 1;mv -Tf "$st" "$p"||return 1;motd_read_pointer "$sc">/dev/null; }
motd_legacy_prefixes_for_id(){ local id="$1" p=${MOTD_PATH_BY_ID[$1]};printf '%s\n%s/%s\n' "$p" "$MOTD_STATE_DIR" "$(basename "$p")"; }
motd_find_legacy_state(){ local id="$1" sc="$2" p s c n=0;MOTD_LEGACY_KIND="";MOTD_LEGACY_PATH="";while IFS= read -r p;do for s in backup absent unknown;do [[ "$s" == unknown&&"$sc" != initial ]]&&continue;c="${p}.${sc}-${s}";[[ -e "$c"||-L "$c" ]]||continue;((n+=1));MOTD_LEGACY_KIND=$s;MOTD_LEGACY_PATH=$c;done;done< <(motd_legacy_prefixes_for_id "$id");((n==1))||{ ((n==0))&&return 2;error "legacy MOTD 状态冲突: $id/$sc";return 1;}; }
motd_validate_legacy_entry(){ local p="$1" k="$2" d md o g m v;d=$(motd_path_parent "$p");motd_validate_directory_chain "$d"||return 1;md=$(stat -c '%u:%g:%a' -- "$p")||return 1;IFS=: read -r o g m<<<"$md";[[ "$o" == "$MOTD_TRUSTED_UID"&&"$g" == "$MOTD_TRUSTED_GID" ]]||return 1;if [[ "$k" == backup&&-L "$p" ]];then return;fi;v=$((8#$m));(( (v&0022)==0 ))||return 1;[[ -f "$p"&&! -L "$p" ]]; }
motd_append_legacy_target(){ local id="$1" k="$2" p="$3" d="$4" mf="$5" obj md u g m at mt dg link;obj=$(motd_snapshot_object_path "$d" "$id");motd_validate_legacy_entry "$p" "$k"||return 1;case "$k" in backup)if [[ -L "$p" ]];then link=$(readlink -- "$p");ln -s -- "$link" "$obj";printf 'target|%s|symlink|-|-|-|-|-|-\n' "$id">>"$mf";else md=$(stat -c '%u:%g:%a:%X:%Y' -- "$p");IFS=: read -r u g m at mt<<<"$md";(umask 077;: >"$obj");cat -- "$p">"$obj";chown "$MOTD_TRUSTED_UID:$MOTD_TRUSTED_GID" "$obj";chmod 600 "$obj";dg=$(sha256sum "$obj");printf 'target|%s|regular|%s|%s|%s|%s|%s|%s\n' "$id" "$u" "$g" "$m" "$at" "$mt" "${dg%% *}">>"$mf";fi;;absent|unknown)printf 'target|%s|%s|-|-|-|-|-|-\n' "$id" "$k">>"$mf";;esac; }
motd_import_legacy_snapshot(){ local sc="$1" id r=0 n=0 gen st fn mf;local -A ks=() ps=();for id in "${MOTD_TARGET_IDS[@]}";do r=0;motd_find_legacy_state "$id" "$sc"||r=$?;case "$r" in 0)((n+=1));ks[$id]=$MOTD_LEGACY_KIND;ps[$id]=$MOTD_LEGACY_PATH;;2);;*)return 1;;esac;done;((n>0))||return 2;((n==6))||{ error "legacy MOTD $sc 状态不完整，拒绝伪装成组 snapshot";return 1;};gen=$(motd_random_id);st="$MOTD_STATE_DIR/generations/.${gen}.stage";fn="$MOTD_STATE_DIR/generations/$gen";MOTD_SNAPSHOT_BUILDING_PATH=$st;mkdir -m700 "$st" "$st/objects"||return 1;chown "$MOTD_TRUSTED_UID:$MOTD_TRUSTED_GID" "$st" "$st/objects"||return 1;mf="$st/manifest";(umask 077;: >"$mf");printf 'version=%s\nscope=%s\ngeneration=%s\n' "$MOTD_SNAPSHOT_VERSION" "$sc" "$gen">"$mf";chown "$MOTD_TRUSTED_UID:$MOTD_TRUSTED_GID" "$mf";chmod 600 "$mf";for id in "${MOTD_TARGET_IDS[@]}";do motd_append_legacy_target "$id" "${ks[$id]}" "${ps[$id]}" "$st" "$mf"||return 1;done;motd_snapshot_manifest_hook "$sc" "$mf"||return 1;motd_validate_snapshot "$st" "$sc" "$gen"||return 1;motd_snapshot_commit_hook "$sc" "$gen" legacy-directory||return 1;mv -T "$st" "$fn"||return 1;MOTD_SNAPSHOT_BUILDING_PATH="";MOTD_LAST_GENERATION=$gen;[[ "$sc" == initial ]]&&MOTD_INITIAL_NEW=$gen||MOTD_PREVIOUS_NEW=$gen;motd_write_journal active||return 1;motd_set_pointer "$sc" "$gen"; }
motd_write_journal(){
 local phase="$1" journal stage token;journal="$MOTD_TRANSACTION_DIR/journal";token=$(motd_random_id)||return 1;stage="$MOTD_TRANSACTION_DIR/.journal.$token";(umask 077;set -o noclobber;: >"$stage")2>/dev/null||return 1
 printf 'version=1\ntransaction=%s\noperation=%s\nphase=%s\ninitial_old=%s\nprevious_old=%s\ninitial_new=%s\nprevious_new=%s\n' "$MOTD_TRANSACTION_ID" "$MOTD_TRANSACTION_OPERATION" "$phase" "$MOTD_INITIAL_OLD" "$MOTD_PREVIOUS_OLD" "$MOTD_INITIAL_NEW" "$MOTD_PREVIOUS_NEW">"$stage"||return 1
 chown "$MOTD_TRUSTED_UID:$MOTD_TRUSTED_GID" "$stage"&&chmod 600 "$stage"&&mv -Tf -- "$stage" "$journal"||{ rm -f "$stage";return 1;}
}
motd_read_journal(){
 local directory="$1" journal line value n=0;journal="$directory/journal";motd_validate_secure_file "$journal"||return 1
 while IFS= read -r line||[[ -n "$line" ]];do ((n+=1));case $n in 1)[[ "$line" == version=1 ]]||return 1;;2)[[ "$line" == transaction=* ]]||return 1;MOTD_JOURNAL_TRANSACTION=${line#transaction=};;3)[[ "$line" == operation=install||"$line" == operation=restore ]]||return 1;MOTD_JOURNAL_OPERATION=${line#operation=};;4)[[ "$line" == phase=active||"$line" == phase=committed ]]||return 1;MOTD_JOURNAL_PHASE=${line#phase=};;5)[[ "$line" == initial_old=* ]]||return 1;MOTD_JOURNAL_INITIAL_OLD=${line#initial_old=};;6)[[ "$line" == previous_old=* ]]||return 1;MOTD_JOURNAL_PREVIOUS_OLD=${line#previous_old=};;7)[[ "$line" == initial_new=* ]]||return 1;MOTD_JOURNAL_INITIAL_NEW=${line#initial_new=};;8)[[ "$line" == previous_new=* ]]||return 1;MOTD_JOURNAL_PREVIOUS_NEW=${line#previous_new=};;*)return 1;;esac;done<"$journal"
 ((n==8))||return 1;[[ "$MOTD_JOURNAL_TRANSACTION" =~ ^[0-9a-f]{32}$ ]]||return 1;for value in "$MOTD_JOURNAL_INITIAL_OLD" "$MOTD_JOURNAL_PREVIOUS_OLD";do [[ "$value" == absent||"$value" =~ ^[0-9a-f]{32}$ ]]||return 1;done;for value in "$MOTD_JOURNAL_INITIAL_NEW" "$MOTD_JOURNAL_PREVIOUS_NEW";do [[ "$value" == -||"$value" =~ ^[0-9a-f]{32}$ ]]||return 1;done
}
motd_publish_pending(){ local token stage pending="$MOTD_STATE_DIR/pending";token=$(motd_random_id)||return 1;stage="$MOTD_STATE_DIR/.pending.$token";(umask 077;set -o noclobber;: >"$stage")2>/dev/null||return 1;printf '%s\n' "$MOTD_TRANSACTION_ID">"$stage"||return 1;chown "$MOTD_TRUSTED_UID:$MOTD_TRUSTED_GID" "$stage"&&chmod 600 "$stage"&&mv -Tf -- "$stage" "$pending"||{ rm -f "$stage";return 1;}; }
motd_read_pending(){ local p="$MOTD_STATE_DIR/pending" t;motd_validate_secure_file "$p"||return 1;IFS= read -r t<"$p"||return 1;[[ "$t" =~ ^[0-9a-f]{32}$&&"$(wc -l<"$p")" == 1 ]]||return 1;printf '%s\n' "$t"; }
motd_begin_transaction(){ local op="$1" t st fn;MOTD_INITIAL_OLD=$(motd_read_pointer_or_absent initial)||return 1;MOTD_PREVIOUS_OLD=$(motd_read_pointer_or_absent previous)||return 1;t=$(motd_random_id)||return 1;st="$MOTD_TRANSACTION_PARENT/.${t}.stage";fn="$MOTD_TRANSACTION_PARENT/$t";MOTD_TRANSACTION_ID=$t;MOTD_TRANSACTION_OPERATION=$op;MOTD_TRANSACTION_BUILDING_PATH=$st;mkdir -m700 "$st"||return 1;chown "$MOTD_TRUSTED_UID:$MOTD_TRUSTED_GID" "$st"||return 1;motd_transaction_phase_hook snapshot-building||return 1;motd_capture_snapshot_to_dir "$st/rollback" runtime "$t" false||return 1;MOTD_TRANSACTION_DIR=$st;motd_write_journal active||return 1;motd_transaction_phase_hook snapshot-commit||return 1;mv -T "$st" "$fn"||return 1;MOTD_TRANSACTION_BUILDING_PATH="";MOTD_TRANSACTION_DIR=$fn;motd_publish_pending||return 1;MOTD_TRANSACTION_ACTIVE=true;MOTD_TRANSACTION_COMMITTED=false;motd_transaction_phase_hook active||return 1; }
motd_restore_old_pointers(){ local f=false;motd_set_pointer initial "$MOTD_INITIAL_OLD"||f=true;motd_set_pointer previous "$MOTD_PREVIOUS_OLD"||f=true;[[ "$f" == false ]]; }
motd_cleanup_transaction_files(){ local f=false p="$MOTD_STATE_DIR/pending";[[ ! -e "$p"&&! -L "$p" ]]||{ motd_validate_secure_file "$p"&&rm -f "$p"||f=true;};for p in "$MOTD_TRANSACTION_DIR" "$MOTD_TRANSACTION_BUILDING_PATH" "$MOTD_SNAPSHOT_BUILDING_PATH";do [[ -z "$p"|| ( ! -e "$p" && ! -L "$p" ) ]]||motd_remove_trusted_tree "$p" "$(motd_path_parent "$p")"||f=true;done;[[ "$f" == false ]]; }
motd_clear_transaction_globals(){ MOTD_TRANSACTION_ACTIVE=false;MOTD_TRANSACTION_COMMITTED=false;MOTD_TRANSACTION_ID="";MOTD_TRANSACTION_DIR="";MOTD_TRANSACTION_BUILDING_PATH="";MOTD_SNAPSHOT_BUILDING_PATH="";MOTD_INITIAL_OLD=absent;MOTD_PREVIOUS_OLD=absent;MOTD_INITIAL_NEW=-;MOTD_PREVIOUS_NEW=-;MOTD_TARGET_ACTION=();MOTD_TARGET_STAGE=(); }
motd_validate_target_parents(){ local p;motd_validate_directory_chain "$MOTD_ETC_ROOT"||return 1;[[ -e "$MOTD_ETC_ROOT/update-motd.d"||-L "$MOTD_ETC_ROOT/update-motd.d" ]]||{ mkdir -m755 "$MOTD_ETC_ROOT/update-motd.d";chown "$MOTD_TRUSTED_UID:$MOTD_TRUSTED_GID" "$MOTD_ETC_ROOT/update-motd.d";};motd_validate_directory_chain "$MOTD_ETC_ROOT/update-motd.d"||return 1;for p in "${MOTD_TARGET_PATHS[@]}";do if [[ -e "$p"&&! -L "$p"&&! -f "$p" ]];then error "MOTD 目标类型不支持: $p";return 1;fi;done; }
motd_allocate_target_stage_path(){ local p="$1" id="$2" d t c;d=$(motd_path_parent "$p");for _ in {1..64};do t=$(motd_random_id);c="$d/.linux-setup-motd.$MOTD_TRANSACTION_ID.$id.$t";[[ -e "$c"||-L "$c" ]]||{ printf '%s\n' "$c";return;};done;return 1; }
motd_prepare_snapshot_plan(){ local snap="$1" sc="$2" id p st obj link;motd_validate_snapshot "$snap" "$sc"||return 1;MOTD_TARGET_ACTION=();MOTD_TARGET_STAGE=();MOTD_RESTORED_COUNT=0;for id in "${MOTD_TARGET_IDS[@]}";do p=${MOTD_PATH_BY_ID[$id]};case ${MOTD_SNAPSHOT_STATE[$id]} in regular)st=$(motd_allocate_target_stage_path "$p" "$id")||return 1;obj=$(motd_snapshot_object_path "$snap" "$id")||return 1;(umask 077;set -o noclobber;: >"$st")2>/dev/null||return 1;cat "$obj">"$st"||return 1;chown "${MOTD_SNAPSHOT_UID[$id]}:${MOTD_SNAPSHOT_GID[$id]}" "$st"||return 1;chmod "${MOTD_SNAPSHOT_MODE[$id]}" "$st"||return 1;touch -a -d "@${MOTD_SNAPSHOT_ATIME[$id]}" "$st"||return 1;touch -m -d "@${MOTD_SNAPSHOT_MTIME[$id]}" "$st"||return 1;MOTD_TARGET_ACTION[$id]=replace;MOTD_TARGET_STAGE[$id]=$st;((MOTD_RESTORED_COUNT+=1));;symlink)st=$(motd_allocate_target_stage_path "$p" "$id")||return 1;link=$(readlink "$(motd_snapshot_object_path "$snap" "$id")")||return 1;ln -s "$link" "$st"||return 1;MOTD_TARGET_ACTION[$id]=replace;MOTD_TARGET_STAGE[$id]=$st;((MOTD_RESTORED_COUNT+=1));;absent)MOTD_TARGET_ACTION[$id]=delete;MOTD_TARGET_STAGE[$id]="";((MOTD_RESTORED_COUNT+=1));;unknown)warn "MOTD 初始状态未知，显式 no-op: $p";MOTD_TARGET_ACTION[$id]=noop;MOTD_TARGET_STAGE[$id]="";;*)return 1;;esac;done; }
motd_cleanup_target_stages(){ local id st;for id in "${MOTD_TARGET_IDS[@]}";do st=${MOTD_TARGET_STAGE[$id]:-};[[ -z "$st"|| ( ! -e "$st" && ! -L "$st" ) ]]||rm -f -- "$st"||return 1;done; }
motd_commit_target_plan(){ local op="$1" rb="${2:-false}" id p a st f=false;for id in "${MOTD_TARGET_IDS[@]}";do p=${MOTD_PATH_BY_ID[$id]};a=${MOTD_TARGET_ACTION[$id]};st=${MOTD_TARGET_STAGE[$id]:-};if [[ "$rb" == true ]];then motd_rollback_hook "$id" "$p"||{ error "MOTD rollback hook 失败: $id";f=true;continue;};else motd_target_commit_hook "$op" "$id" "$p"||{ error "MOTD target commit hook 失败: $id";return 1;};fi;case $a in replace)mv -Tf -- "$st" "$p"||{ [[ "$rb" == true ]]&&{ f=true;continue;};return 1;};MOTD_TARGET_STAGE[$id]="";;delete)rm -f -- "$p"||{ [[ "$rb" == true ]]&&{ f=true;continue;};return 1;};;noop);;esac;done;[[ "$f" == false ]]; }
motd_prepare_install_plan(){ local id p st md u g m at mt link nm;MOTD_TARGET_ACTION=();MOTD_TARGET_STAGE=();for id in "${MOTD_TARGET_IDS[@]}";do p=${MOTD_PATH_BY_ID[$id]};case $id in motd|issue|issue_net)st=$(motd_allocate_target_stage_path "$p" "$id")||return 1;(umask 022;set -o noclobber;: >"$st")2>/dev/null||return 1;chown "$MOTD_TRUSTED_UID:$MOTD_TRUSTED_GID" "$st"||return 1;chmod 644 "$st"||return 1;MOTD_TARGET_ACTION[$id]=replace;MOTD_TARGET_STAGE[$id]=$st;;custom_welcome)st=$(motd_allocate_target_stage_path "$p" "$id")||return 1;motd_write_payload "$st"||return 1;chown "$MOTD_TRUSTED_UID:$MOTD_TRUSTED_GID" "$st"||return 1;chmod 755 "$st"||return 1;grep -Fq '# linux-setup:managed-motd' "$st"&&bash -n "$st"||return 1;MOTD_TARGET_ACTION[$id]=replace;MOTD_TARGET_STAGE[$id]=$st;;uname|motd_news)if [[ ! -e "$p"&&! -L "$p" ]];then MOTD_TARGET_ACTION[$id]=noop;MOTD_TARGET_STAGE[$id]="";elif [[ -L "$p" ]];then st=$(motd_allocate_target_stage_path "$p" "$id")||return 1;link=$(readlink "$p")||return 1;ln -s "$link" "$st"||return 1;MOTD_TARGET_ACTION[$id]=replace;MOTD_TARGET_STAGE[$id]=$st;elif [[ -f "$p" ]];then md=$(stat -c '%u:%g:%a:%X:%Y' "$p")||return 1;IFS=: read -r u g m at mt<<<"$md";nm=$((8#$m&~8#111));printf -v nm '%04o' "$nm";st=$(motd_allocate_target_stage_path "$p" "$id")||return 1;(umask 077;set -o noclobber;: >"$st")2>/dev/null||return 1;cat "$p">"$st"||return 1;chown "$u:$g" "$st"||return 1;chmod "$nm" "$st"||return 1;touch -a -d "@$at" "$st"||return 1;touch -m -d "@$mt" "$st"||return 1;MOTD_TARGET_ACTION[$id]=replace;MOTD_TARGET_STAGE[$id]=$st;else return 1;fi;;esac;done; }
motd_rollback_current_transaction(){ local f=false;motd_prepare_snapshot_plan "$MOTD_TRANSACTION_DIR/rollback" runtime||return 1;motd_commit_target_plan rollback true||f=true;motd_restore_old_pointers||f=true;motd_cleanup_target_stages||f=true;[[ "$f" == false ]]||{ error "MOTD rollback 不完整，保留 journal: $MOTD_TRANSACTION_DIR";return 1;}; }
motd_cleanup_new_state_directory(){ [[ "$MOTD_STATE_DIR_CREATED" == true ]]||return 0;[[ -e "$MOTD_STATE_DIR/initial.current"||-e "$MOTD_STATE_DIR/previous.current"||-e "$MOTD_STATE_DIR/pending" ]]&&return 0;motd_remove_trusted_tree "$MOTD_STATE_DIR" "$(motd_path_parent "$MOTD_STATE_DIR")";MOTD_STATE_DIR_CREATED=false; }
motd_abort_transaction(){ local f=false;[[ "$MOTD_TRANSACTION_ACTIVE" == true&&"$MOTD_TRANSACTION_COMMITTED" == false ]]&&motd_rollback_current_transaction||{ [[ "$MOTD_TRANSACTION_ACTIVE" == true&&"$MOTD_TRANSACTION_COMMITTED" == false ]]&&f=true;};if [[ "$f" == false ]];then motd_cleanup_target_stages||f=true;motd_cleanup_transaction_files||f=true;motd_cleanup_new_state_directory||f=true;fi;[[ "$f" == true ]]||motd_clear_transaction_globals;[[ "$f" == false ]]; }
motd_complete_transaction(){ motd_cleanup_target_stages&&motd_cleanup_transaction_files||{ error "MOTD transaction 已提交但清理不完整: $MOTD_TRANSACTION_DIR";return 1;};motd_clear_transaction_globals;MOTD_STATE_DIR_CREATED=false; }
motd_mark_transaction_committed(){ motd_write_journal committed||return 1;MOTD_TRANSACTION_COMMITTED=true;motd_transaction_phase_hook committed||return 1; }
motd_recover_pending_transaction(){ local t d;[[ -e "$MOTD_STATE_DIR/pending" ]]||return 0;t=$(motd_read_pending)||return 1;d="$MOTD_TRANSACTION_PARENT/$t";motd_validate_secure_directory "$d"&&motd_read_journal "$d"||return 1;MOTD_TRANSACTION_ID=$t;MOTD_TRANSACTION_DIR=$d;MOTD_TRANSACTION_OPERATION=$MOTD_JOURNAL_OPERATION;MOTD_INITIAL_OLD=$MOTD_JOURNAL_INITIAL_OLD;MOTD_PREVIOUS_OLD=$MOTD_JOURNAL_PREVIOUS_OLD;MOTD_INITIAL_NEW=$MOTD_JOURNAL_INITIAL_NEW;MOTD_PREVIOUS_NEW=$MOTD_JOURNAL_PREVIOUS_NEW;MOTD_TRANSACTION_ACTIVE=true;if [[ "$MOTD_JOURNAL_PHASE" == committed ]];then MOTD_TRANSACTION_COMMITTED=true;warn "清理已提交但未完成清理的 MOTD transaction: $t";motd_complete_transaction;else warn "检测到 pending MOTD transaction，先执行完整回滚: $t";motd_abort_transaction;fi; }
motd_restore_saved_trap(){ local s="$1" d="$2";trap - "$s";[[ -z "$d" ]]||eval "$d"; }
motd_install_transaction_traps(){ MOTD_SAVED_TRAP_EXIT=$(trap -p EXIT||true);MOTD_SAVED_TRAP_HUP=$(trap -p HUP||true);MOTD_SAVED_TRAP_INT=$(trap -p INT||true);MOTD_SAVED_TRAP_TERM=$(trap -p TERM||true);trap 'motd_transaction_exit_handler $?' EXIT;trap 'motd_transaction_signal_handler HUP 129' HUP;trap 'motd_transaction_signal_handler INT 130' INT;trap 'motd_transaction_signal_handler TERM 143' TERM; }
motd_restore_transaction_traps(){ local e="$MOTD_SAVED_TRAP_EXIT" h="$MOTD_SAVED_TRAP_HUP" i="$MOTD_SAVED_TRAP_INT" t="$MOTD_SAVED_TRAP_TERM";trap - EXIT HUP INT TERM;motd_restore_saved_trap EXIT "$e";motd_restore_saved_trap HUP "$h";motd_restore_saved_trap INT "$i";motd_restore_saved_trap TERM "$t"; }
motd_transaction_signal_handler(){ local s="$1" n="$2";trap - EXIT HUP INT TERM;motd_abort_transaction||true;motd_release_lock||true;motd_restore_transaction_traps;exit "$n"; }
motd_transaction_exit_handler(){ local n="$1";trap - EXIT HUP INT TERM;if [[ "$MOTD_TRANSACTION_ACTIVE" == true||-n "$MOTD_TRANSACTION_BUILDING_PATH"||-n "$MOTD_SNAPSHOT_BUILDING_PATH"||"$MOTD_STATE_DIR_CREATED" == true ]];then motd_abort_transaction||true;((n==0))&&n=1;fi;motd_release_lock||{ ((n==0))&&n=1;};motd_restore_transaction_traps;exit "$n"; }
motd_prepare_state_layout(){ if [[ ! -e "$MOTD_STATE_DIR"&&! -L "$MOTD_STATE_DIR" ]];then motd_ensure_parent_chain "$MOTD_STATE_DIR"||return 1;mkdir -m700 "$MOTD_STATE_DIR"||return 1;MOTD_STATE_DIR_CREATED=true;chown "$MOTD_TRUSTED_UID:$MOTD_TRUSTED_GID" "$MOTD_STATE_DIR"||return 1;motd_state_directory_created_hook "$MOTD_STATE_DIR"||return 1;elif ! motd_validate_secure_directory "$MOTD_STATE_DIR";then return 1;fi;motd_ensure_secure_directory "$MOTD_STATE_DIR/generations"||return 1;motd_ensure_secure_directory "$MOTD_TRANSACTION_PARENT"||return 1; }
motd_ensure_snapshot_pointer(){ local sc="$1" r=0 unk=false;motd_read_pointer "$sc">/dev/null 2>&1&&return 0;[[ ! -e "$(motd_pointer_path "$sc")"&&! -L "$(motd_pointer_path "$sc")" ]]||return 1;motd_import_legacy_snapshot "$sc"||r=$?;case $r in 0)return 0;;2);;*)return 1;;esac;[[ "$sc" == initial ]]||return 2;motd_target_configuration_is_managed&&unk=true;motd_create_persistent_snapshot initial "$unk"||return 1;MOTD_INITIAL_NEW=$MOTD_LAST_GENERATION;motd_write_journal active||return 1;motd_set_pointer initial "$MOTD_INITIAL_NEW"; }
motd_refresh_previous_snapshot(){ motd_create_persistent_snapshot previous false||return 1;MOTD_PREVIOUS_NEW=$MOTD_LAST_GENERATION;motd_write_journal active||return 1;motd_set_pointer previous "$MOTD_PREVIOUS_NEW"; }
motd_install_body(){ motd_prepare_state_layout||return 1;motd_validate_target_parents||return 1;motd_recover_pending_transaction||return 1;motd_begin_transaction install||return 1;motd_ensure_snapshot_pointer initial||return 1;motd_refresh_previous_snapshot||return 1;motd_prepare_install_plan||return 1;motd_transaction_phase_hook target-commit||return 1;motd_commit_target_plan install false||return 1;motd_mark_transaction_committed||return 1;motd_complete_transaction; }
motd_restore_body(){ local sc="$1" r=0 gen;motd_prepare_state_layout||return 1;motd_validate_target_parents||return 1;motd_recover_pending_transaction||return 1;motd_begin_transaction restore||return 1;motd_ensure_snapshot_pointer "$sc"||r=$?;if ((r!=0));then motd_abort_transaction||true;return "$r";fi;gen=$(motd_read_pointer "$sc")||return 1;motd_prepare_snapshot_plan "$MOTD_STATE_DIR/generations/$gen" "$sc"||return 1;motd_transaction_phase_hook restore-commit||return 1;motd_commit_target_plan restore false||return 1;motd_mark_transaction_committed||return 1;motd_complete_transaction; }
motd_run_locked_operation(){ local op="$1" sc="${2:-}" n=0 rel=0;motd_take_lock||return 1;motd_install_transaction_traps||return 1;case $op in install)motd_install_body||n=$?;;restore)motd_restore_body "$sc"||n=$?;;esac;if ((n!=0))&&[[ "$MOTD_TRANSACTION_ACTIVE" == true||-n "$MOTD_TRANSACTION_BUILDING_PATH"||-n "$MOTD_SNAPSHOT_BUILDING_PATH"||"$MOTD_STATE_DIR_CREATED" == true ]];then motd_abort_transaction||n=1;fi;motd_release_lock||rel=1;motd_restore_transaction_traps;((rel==0))||n=1;return "$n"; }
motd_install_group(){ info "配置动态欢迎信息...";motd_run_locked_operation install||return $?;echo "欢迎信息: 已配置";echo;echo "预览：";echo ----------------------------------------;motd_preview_hook||warn "MOTD 已成功提交，但预览执行失败";echo ----------------------------------------; }
motd_restore_group(){ local sc="${1:-previous}" n=0;[[ "$sc" == previous||"$sc" == initial ]]||return 1;motd_run_locked_operation restore "$sc"||n=$?;((n!=2))||{ warn "没有 $sc MOTD 组 snapshot";return 2;};((n==0))||return "$n";success "MOTD 已恢复到 $sc 状态"; }

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

configure_motd(){ motd_install_group; }
restore_motd(){ local n=0;motd_restore_group "${1:-previous}"||n=$?;((n!=2))||{ error "没有可恢复的可信 MOTD 组 snapshot";return 1;};return "$n"; }
show_status(){ if [[ -x "$MOTD_SCRIPT" ]]&&grep -Fq '# linux-setup:managed-motd' "$MOTD_SCRIPT";then echo "MOTD 状态: 已安装并受管";elif [[ -e "$MOTD_SCRIPT"||-L "$MOTD_SCRIPT" ]];then echo "MOTD 状态: 存在但不受本工具管理";else echo "MOTD 状态: 未安装";fi; }
show_help(){ echo '用法: setup-motd.sh [install|status|restore|help]'; }
require_motd_commands(){ local c;for c in awk bash basename cat chmod chown cp dirname flock grep hostname install ln mkdir mv od readlink rm sha256sum stat touch tr uname uptime df sed wc;do command -v "$c">/dev/null||return 1;done; }
main(){ local a="${1:-install}";case $a in help|-h|--help)show_help;;status)show_status;;install)require_root&&require_motd_commands&&configure_motd;;restore)require_root&&require_motd_commands&&restore_motd "${2:-previous}";;*)return 1;;esac; }
if [[ "${BASH_SOURCE[0]}" == "$0" ]];then trap 'error "MOTD 配置脚本在第 $LINENO 行执行失败"' ERR;main "$@";fi
