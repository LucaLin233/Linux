#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/test-motd-common.sh"

for group_impl in tool module; do
    for group_change in motd-content issue-mode custom-inode; do
    (
        root="$TEST_DIR/final-group-$group_impl-$group_change"; create_fixture "$root"; export_paths "$root"; before=$(target_hash "$root")
        if [[ "$group_impl" == tool ]]; then load_motd; else . "$ROOT_DIR/modules/system-customize.sh"; fi
        motd_transaction_phase_hook() { local phase="$1" path replacement; [[ "$phase" == target-committed-motd_news ]] || return 0; case "$group_change" in motd-content) printf changed > "$MOTD_ETC_ROOT/motd" ;; issue-mode) chmod 0600 "$MOTD_ETC_ROOT/issue" ;; custom-inode) path="$MOTD_ETC_ROOT/update-motd.d/00-custom-welcome"; replacement="${path}.replacement"; cp "$path" "$replacement"; chmod 0755 "$replacement"; mv -Tf "$replacement" "$path" ;; esac; }
        assert_fail "$group_impl final group rejects $group_change" motd_run_locked_operation install
        assert_eq "$before" "$(target_hash "$root")" "$group_impl final group $group_change rolls back all targets"
        [[ ! -e "$MOTD_STATE_DIR/pending" ]] || fail "$group_impl final group $group_change left pending"
        assert_no_motd_residue "$root"; motd_take_lock; motd_release_lock
    )
    done
done

for illegal_legacy_name in motd.previous-unknown issue.previous-unknown motd.invalid-backup evil.initial-backup; do
(
    root="$TEST_DIR/legacy-name-${illegal_legacy_name//[^a-zA-Z0-9]/-}"; create_fixture "$root"; export_paths "$root"; load_motd; motd_run_locked_operation install
    object="$MOTD_STATE_DIR/$illegal_legacy_name"; printf invalid > "$object"; chmod 0600 "$object"; before=$(target_hash "$root"); pointers="$(cat "$MOTD_STATE_DIR/initial.current")|$(cat "$MOTD_STATE_DIR/previous.current")"
    assert_fail "illegal legacy name $illegal_legacy_name rejected" motd_run_locked_operation install
    assert_eq "$before" "$(target_hash "$root")" "illegal legacy name $illegal_legacy_name preserves targets"
    assert_eq "$pointers" "$(cat "$MOTD_STATE_DIR/initial.current")|$(cat "$MOTD_STATE_DIR/previous.current")" "illegal legacy name $illegal_legacy_name preserves pointers"
    [[ -e "$object" || -L "$object" ]] || fail "illegal legacy name $illegal_legacy_name evidence removed"; [[ ! -e "$MOTD_STATE_DIR/pending" ]] || fail "illegal legacy name $illegal_legacy_name created pending"; motd_take_lock; motd_release_lock
)
done

for legacy_backup_kind in directory fifo socket writable wrong-owner wrong-gid device; do
(
    root="$TEST_DIR/legacy-backup-$legacy_backup_kind"; create_fixture "$root"; export_paths "$root"; load_motd; motd_run_locked_operation install; object="$MOTD_STATE_DIR/motd.initial-backup"
    case "$legacy_backup_kind" in
        directory) mkdir "$object" ;; fifo) mkfifo "$object" ;;
        socket) if command -v python3 >/dev/null 2>&1; then python3 - "$object" <<'PY'
import socket,sys
s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()
PY
        else pass "socket legacy test skipped without python3"; exit 0; fi ;;
        writable) printf bad > "$object"; chmod 0666 "$object" ;;
        wrong-owner) if (( EUID == 0 )); then printf bad > "$object"; chmod 0600 "$object"; chown "$((MOTD_TRUSTED_UID+1)):$MOTD_TRUSTED_GID" "$object"; else pass "wrong-owner legacy test skipped without privilege"; exit 0; fi ;;
        wrong-gid) if (( EUID == 0 )); then printf bad > "$object"; chmod 0600 "$object"; chown "$MOTD_TRUSTED_UID:$((MOTD_TRUSTED_GID+1))" "$object"; else pass "wrong-gid legacy test skipped without privilege"; exit 0; fi ;;
        device) if (( EUID == 0 )) && mknod "$object" c 1 3 2>/dev/null; then :; else pass "device legacy test skipped without privilege"; exit 0; fi ;;
    esac
    before=$(target_hash "$root"); pointers="$(cat "$MOTD_STATE_DIR/initial.current")|$(cat "$MOTD_STATE_DIR/previous.current")"
    assert_fail "legacy backup $legacy_backup_kind rejected" motd_run_locked_operation restore initial
    assert_eq "$before" "$(target_hash "$root")" "legacy backup $legacy_backup_kind preserves targets"
    assert_eq "$pointers" "$(cat "$MOTD_STATE_DIR/initial.current")|$(cat "$MOTD_STATE_DIR/previous.current")" "legacy backup $legacy_backup_kind preserves pointers"
    [[ -e "$object" || -L "$object" ]] || fail "legacy backup $legacy_backup_kind evidence removed"; [[ ! -e "$MOTD_STATE_DIR/pending" ]] || fail "legacy backup $legacy_backup_kind created pending"; motd_take_lock; motd_release_lock
)
done

for legacy_marker_name in motd.initial-absent issue.initial-unknown motd.previous-absent; do
    for legacy_marker_kind in symlink directory fifo writable; do
    (
        root="$TEST_DIR/legacy-marker-${legacy_marker_name//[^a-zA-Z0-9]/-}-$legacy_marker_kind"; create_fixture "$root"; export_paths "$root"; load_motd; motd_run_locked_operation install; object="$MOTD_STATE_DIR/$legacy_marker_name"
        case "$legacy_marker_kind" in symlink) ln -s "$root/missing" "$object" ;; directory) mkdir "$object" ;; fifo) mkfifo "$object" ;; writable) printf bad > "$object"; chmod 0666 "$object" ;; esac
        before=$(target_hash "$root"); pointers="$(cat "$MOTD_STATE_DIR/initial.current")|$(cat "$MOTD_STATE_DIR/previous.current")"
        assert_fail "legacy marker $legacy_marker_name $legacy_marker_kind rejected" motd_run_locked_operation install
        assert_eq "$before" "$(target_hash "$root")" "legacy marker $legacy_marker_name $legacy_marker_kind preserves targets"
        assert_eq "$pointers" "$(cat "$MOTD_STATE_DIR/initial.current")|$(cat "$MOTD_STATE_DIR/previous.current")" "legacy marker $legacy_marker_name $legacy_marker_kind preserves pointers"
        [[ -e "$object" || -L "$object" ]] || fail "legacy marker $legacy_marker_name $legacy_marker_kind evidence removed"; [[ ! -e "$MOTD_STATE_DIR/pending" ]] || fail "legacy marker $legacy_marker_name $legacy_marker_kind created pending"; motd_take_lock; motd_release_lock
    )
    done
done

(
    root="$TEST_DIR/legal-state-root-legacy"; create_fixture "$root"; export_paths "$root"; mkdir -p "$MOTD_STATE_DIR"; chmod 0700 "$MOTD_STATE_DIR"
    cp -a "$MOTD_ETC_ROOT/motd" "$MOTD_STATE_DIR/motd.initial-backup"; printf target > "$root/symlink-target"; ln -s "$root/symlink-target" "$MOTD_STATE_DIR/issue.initial-backup"
    : > "$MOTD_STATE_DIR/issue.net.initial-absent"; chmod 0600 "$MOTD_STATE_DIR/issue.net.initial-absent"; : > "$MOTD_STATE_DIR/00-custom-welcome.initial-unknown"; chmod 0600 "$MOTD_STATE_DIR/00-custom-welcome.initial-unknown"
    cp -a "$MOTD_ETC_ROOT/update-motd.d/10-uname" "$MOTD_STATE_DIR/10-uname.initial-backup"; : > "$MOTD_STATE_DIR/50-motd-news.initial-absent"; chmod 0600 "$MOTD_STATE_DIR/50-motd-news.initial-absent"
    touch -a -d @1000000000 "$MOTD_STATE_DIR/motd.initial-backup"; touch -m -d @1000200000 "$MOTD_STATE_DIR/motd.initial-backup"; legacy_times=$(stat -c %X:%Y "$MOTD_STATE_DIR/motd.initial-backup")
    load_motd; motd_run_locked_operation restore initial
    [[ -L "$MOTD_ETC_ROOT/issue" && "$(readlink "$MOTD_ETC_ROOT/issue")" == "$root/symlink-target" ]] || fail "legal state root symlink backup not imported"
    assert_eq original "$(cat "$MOTD_ETC_ROOT/motd")" "legal state root regular backup imported"; [[ -e "$MOTD_STATE_DIR/initial.current" ]] || fail "legal state root import did not publish initial pointer"
    assert_eq "$legacy_times" "$(stat -c %X:%Y "$MOTD_STATE_DIR/motd.initial-backup")" "legacy root metadata validation/import preserves timestamps"; pass "legal state root regular, symlink, and markers import"
)


for rollback_impl in tool module; do
    for rollback_damage in motd-content issue-mode custom-inode absent-regular absent-symlink absent-fifo symlink-target; do
    (
        root="$TEST_DIR/rollback-final-$rollback_impl-$rollback_damage"; create_fixture "$root"; export_paths "$root"
        if [[ "$rollback_impl" == tool ]]; then load_motd; else . "$ROOT_DIR/modules/system-customize.sh"; fi
        motd_run_locked_operation install
        case "$rollback_damage" in
            motd-content) printf 'pre-run-motd\n' > "$MOTD_ETC_ROOT/motd" ;;
            issue-mode) chmod 0600 "$MOTD_ETC_ROOT/issue" ;;
            custom-inode) printf 'pre-run-custom\n' > "$MOTD_ETC_ROOT/update-motd.d/00-custom-welcome"; chmod 0700 "$MOTD_ETC_ROOT/update-motd.d/00-custom-welcome" ;;
            absent-regular|absent-symlink|absent-fifo) rm -f "$MOTD_ETC_ROOT/update-motd.d/50-motd-news" ;;
            symlink-target) rm -f "$MOTD_ETC_ROOT/update-motd.d/10-uname"; ln -s "$root/original-link" "$MOTD_ETC_ROOT/update-motd.d/10-uname" ;;
        esac
        before=$(target_hash "$root")
        before_pointers="$(cat "$MOTD_STATE_DIR/initial.current")|$(cat "$MOTD_STATE_DIR/previous.current")"
        motd_target_commit_hook() { [[ "$2" != issue_net ]]; }
        motd_rollback_hook() {
            local id="$1" path target
            [[ "$id" == motd_news ]] || return 0
            case "$rollback_damage" in
                motd-content) printf 'rollback-corrupt\n' > "$MOTD_ETC_ROOT/motd" ;;
                issue-mode) chmod 0777 "$MOTD_ETC_ROOT/issue" ;;
                custom-inode)
                    path="$MOTD_ETC_ROOT/update-motd.d/00-custom-welcome"
                    cp "$path" "${path}.replacement"; chmod 0700 "${path}.replacement"; mv -Tf "${path}.replacement" "$path"
                    ;;
                absent-regular|absent-symlink|absent-fifo)
                    ROLLBACK_RECREATE_TARGET="$MOTD_ETC_ROOT/update-motd.d/50-motd-news"
                    rm() {
                        local status
                        command rm "$@"; status=$?; unset -f rm
                        case "$rollback_damage" in
                            absent-regular) printf recreated > "$ROLLBACK_RECREATE_TARGET"; chmod 0755 "$ROLLBACK_RECREATE_TARGET" ;;
                            absent-symlink) ln -s "$root/recreated-link" "$ROLLBACK_RECREATE_TARGET" ;;
                            absent-fifo) mkfifo "$ROLLBACK_RECREATE_TARGET" ;;
                        esac
                        return "$status"
                    }
                    ;;
                symlink-target) rm -f "$MOTD_ETC_ROOT/update-motd.d/10-uname"; ln -s "$root/changed-link" "$MOTD_ETC_ROOT/update-motd.d/10-uname" ;;
            esac
            return 0
        }
        assert_fail "$rollback_impl rollback final group rejects $rollback_damage" motd_run_locked_operation install
        [[ -e "$MOTD_STATE_DIR/pending" ]] || fail "$rollback_impl rollback $rollback_damage lost pending"
        transaction=$(cat "$MOTD_STATE_DIR/pending")
        journal="$MOTD_TRANSACTION_PARENT/$transaction/journal"
        grep -Fxq 'phase=active' "$journal" || fail "$rollback_impl rollback $rollback_damage journal not active"
        [[ -d "$MOTD_TRANSACTION_PARENT/$transaction/rollback" ]] || fail "$rollback_impl rollback $rollback_damage lost rollback snapshot"
        pass "$rollback_impl rollback $rollback_damage preserves active recovery evidence"
        motd_target_commit_hook() { :; }; motd_rollback_hook() { :; }
        motd_take_lock; motd_reconcile_state; motd_release_lock
        assert_eq "$before" "$(target_hash "$root")" "$rollback_impl rollback $rollback_damage retry restores targets"
        assert_eq "$before_pointers" "$(cat "$MOTD_STATE_DIR/initial.current")|$(cat "$MOTD_STATE_DIR/previous.current")" "$rollback_impl rollback $rollback_damage retry restores pointers"
        [[ ! -e "$MOTD_STATE_DIR/pending" && -z "$(find "$MOTD_TRANSACTION_PARENT" -mindepth 1 -print -quit)" ]] || fail "$rollback_impl rollback $rollback_damage retry left journal"
        assert_no_motd_residue "$root"; assert_eq 2 "$(generation_count "$MOTD_STATE_DIR/generations")" "$rollback_impl rollback $rollback_damage retry keeps bounded generations"
        motd_take_lock; motd_release_lock
    )
    done

done

for rollback_impl in tool module; do
(
    root="$TEST_DIR/rollback-final-success-$rollback_impl"; create_fixture "$root"; export_paths "$root"
    if [[ "$rollback_impl" == tool ]]; then load_motd; else . "$ROOT_DIR/modules/system-customize.sh"; fi
    motd_run_locked_operation install; printf 'normal-pre-run\n' > "$MOTD_ETC_ROOT/motd"; before=$(target_hash "$root")
    motd_target_commit_hook() { [[ "$2" != issue_net ]]; }
    assert_fail "$rollback_impl normal rollback still returns original operation failure" motd_run_locked_operation install
    assert_eq "$before" "$(target_hash "$root")" "$rollback_impl normal rollback final group succeeds"
    [[ ! -e "$MOTD_STATE_DIR/pending" && -z "$(find "$MOTD_TRANSACTION_PARENT" -mindepth 1 -print -quit)" ]] || fail "$rollback_impl normal rollback left journal"
    assert_no_motd_residue "$root"
)
done

printf 'All MOTD rollback final validation tests passed.\n'
