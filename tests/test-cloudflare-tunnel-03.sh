#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/test-cloudflare-tunnel-common.sh"

for restore_id in auto_update_script auto_update_service auto_update_timer source current legacy_marker; do
    (
        new_case
        trap - EXIT
        configure_repository || fail "six target configure"
        mkdir -p "$(dirname "$AUTO_UPDATE_SCRIPT")" "$(dirname "$AUTO_UPDATE_SERVICE")"
        write_auto_update_files || fail "six target auto update"
        printf managed > "$STATE_DIR/repository-managed"
        chmod 0600 "$STATE_DIR/repository-managed"
        acquire_repository_lock || fail "six target lock"
        begin_uninstall_transaction || fail "six target capture"
        snapshot=$UNINSTALL_SNAPSHOT_DIR
        while IFS= read -r id; do rm -- "$(uninstall_target_path "$id")"; done < <(uninstall_snapshot_targets)
        repository_install_file() {
            [[ "$2" != "$snapshot/files/target-$restore_id" ]] || return 1
            command install -o 0 -g 0 -m "$1" -- "$2" "$3"
        }
        if uninstall_cleanup six-target-failure; then fail "restore fault accepted"; fi
        while IFS= read -r id; do
            [[ -f "$snapshot/files/target-$id" ]] || fail "snapshot payload lost $id"
            if [[ "$id" != "$restore_id" ]]; then
                cmp "$(uninstall_target_path "$id")" "$snapshot/files/target-$id" || fail "restore skipped $id"
                validate_secure_file "$(uninstall_target_path "$id")" "$(uninstall_target_mode "$id")" || fail "restore metadata $id"
            fi
        done < <(uninstall_snapshot_targets)
        [[ -f "$UNINSTALL_PENDING" ]] || fail "restore pending lost"
        uninstall_journal_valid "$snapshot/journal" ACTIVE || fail "failure overwrote original journal"
    ) > "$TEST_DIR/restore-$restore_id.log" 2>&1 || {
        cat "$TEST_DIR/restore-$restore_id.log"
        fail "restore failure $restore_id"
    }
    pass "restore failure $restore_id continues remaining five targets and preserves original evidence"
done

for target_id in auto_update_script auto_update_service auto_update_timer source current legacy_marker; do
    for bad_metadata in mode owner gid symlink directory fifo; do
        (
            new_case
            trap - EXIT
            configure_repository || fail "metadata configure"
            mkdir -p "$(dirname "$AUTO_UPDATE_SCRIPT")" "$(dirname "$AUTO_UPDATE_SERVICE")"
            write_auto_update_files || fail "metadata auto update"
            printf managed > "$STATE_DIR/repository-managed"
            chmod 0600 "$STATE_DIR/repository-managed"
            target=$(uninstall_target_path "$target_id")
            case "$bad_metadata" in
                mode) chmod 0666 "$target" ;;
                owner) chown 1:0 "$target" ;;
                gid) chown 0:1 "$target" ;;
                symlink) mv "$target" "$target.external"; ln -s "$target.external" "$target" ;;
                directory) rm "$target"; mkdir "$target" ;;
                fifo) rm "$target"; mkfifo "$target" ;;
            esac
            acquire_repository_lock || fail "metadata lock"
            if begin_uninstall_transaction; then fail "bad target captured"; fi
            uninstall_cleanup bad-metadata >/dev/null 2>&1 || :
            [[ -e "$target" || -L "$target" ]] || fail "untrusted target deleted"
            [[ "$UNINSTALL_TRANSACTION_STATE" == FAILED ]] || fail "capture failure state lost"
        ) > "$TEST_DIR/meta-$target_id-$bad_metadata.log" 2>&1 || {
            cat "$TEST_DIR/meta-$target_id-$bad_metadata.log"
            fail "metadata $target_id $bad_metadata"
        }
        pass "capture rejects $target_id $bad_metadata without deleting target"
    done
done

(
    unset CLOUDFLARED_TRUST_ANCHOR
    init_runtime_config
    [[ "$TRUST_ANCHOR" == / ]] || exit 1
    path_is_beneath_anchor / || exit 1
    path_is_beneath_anchor /var/lib || exit 1
    CLOUDFLARED_TRUST_ANCHOR=/var
    path_is_beneath_anchor /var || exit 1
    path_is_beneath_anchor /var/lib || exit 1
    if path_is_beneath_anchor /variable; then exit 1; fi
    if path_is_beneath_anchor /var/../etc; then exit 1; fi
    path_is_beneath_anchor /var/lib/../lib || exit 1
) || fail "pure anchor boundaries"
pass "pure paths validate default root anchor and normalized non-root boundaries"

for creation_phase in before-create-marker before-create-manifest-stage before-create-manifest-rename before-create-publish after-create-publish; do
    for creation_fault in failure HUP INT TERM; do
        (
            new_case
            trap - EXIT
            configure_repository || fail "creation configure"
            printf payload > "$CASE_DIR/payload"
            chmod 0600 "$CASE_DIR/payload"
            rc=0
            (
                trap - EXIT
                acquire_repository_lock || exit 1
                begin_uninstall_transaction || exit 1
                uninstall_transaction_hook() {
                    [[ "$1" == "$creation_phase" ]] || return 0
                    if [[ "$creation_fault" == failure ]]; then return 1; fi
                    kill -s "$creation_fault" "$BASHPID"
                }
                if uninstall_create_absent_target auto_update_script "$CASE_DIR/payload"; then exit 90; fi
                uninstall_cleanup creation-failure || :
                exit 1
            ) > "$CASE_DIR/creation.log" 2>&1 || rc=$?
            case "$creation_fault" in failure) expected=1 ;; HUP) expected=129 ;; INT) expected=130 ;; TERM) expected=143 ;; esac
            [[ "$rc" == "$expected" ]] || fail "creation status $rc"
            [[ ! -e "$AUTO_UPDATE_SCRIPT" && ! -L "$AUTO_UPDATE_SCRIPT" ]] || fail "owned publication not recovered"
            [[ ! -d "$CLOUDFLARED_STATE_DIR.lock" ]] || fail "creation lock leaked"
        ) > "$TEST_DIR/create-$creation_phase-$creation_fault.log" 2>&1 || {
            cat "$TEST_DIR/create-$creation_phase-$creation_fault.log"
            fail "creation $creation_phase $creation_fault"
        }
        pass "creation $creation_phase $creation_fault preserves ownership across publication"
    done
done

for bookkeeping_fault in marker stage rename; do
    (
        new_case
        trap - EXIT
        configure_repository || fail "bookkeeping configure"
        printf payload > "$CASE_DIR/payload"; chmod 0600 "$CASE_DIR/payload"
        acquire_repository_lock || fail "bookkeeping lock"
        begin_uninstall_transaction || fail "bookkeeping capture"
        uninstall_transaction_hook() {
            if [[ "$bookkeeping_fault" == marker && "$1" == before-create-marker ]]; then
                mkdir "$UNINSTALL_SNAPSHOT_DIR/created-auto_update_script"
            fi
            return 0
        }
        mktemp() {
            if [[ "$bookkeeping_fault" == stage && "$1" == */manifest.stage.* ]]; then return 1; fi
            command mktemp "$@"
        }
        repository_rename() {
            if [[ "$bookkeeping_fault" == rename && "$1" == */manifest.stage.* ]]; then return 1; fi
            command mv -fT -- "$1" "$2"
        }
        if uninstall_create_absent_target auto_update_script "$CASE_DIR/payload"; then fail "bookkeeping fault ignored"; fi
        [[ ! -e "$AUTO_UPDATE_SCRIPT" ]] || fail "published before durable bookkeeping"
        uninstall_cleanup bookkeeping-failure || :
    ) > "$TEST_DIR/bookkeeping-$bookkeeping_fault.log" 2>&1 || {
        cat "$TEST_DIR/bookkeeping-$bookkeeping_fault.log"
        fail "bookkeeping $bookkeeping_fault"
    }
    pass "actual $bookkeeping_fault failure precedes ln publication"
done

new_case
configure_repository || fail "URL configure"
grep '^curl:' "$FAKE_LOG" | grep -Fq 'https://pkg.cloudflare.com/cloudflare-main.gpg' || fail "key download URL changed"
printf 'deb [signed-by=%s] https://pkg.cloudflare.com/cloudflared any main\n' "$CLOUDFLARED_KEYRING" > "$CASE_DIR/official-source"
assert_same "$CLOUDFLARED_SOURCE_FILE" "$CASE_DIR/official-source" "APT repository URL incorrect"
validate_current_repository_manifest || fail "official current rejected"
remove_managed_repository || fail "official source removal failed"
assert_absent "$CLOUDFLARED_SOURCE_FILE" "official source not removed"
pass "literal key URL and repository source validate current and real removal"

new_case
printf 'deb [signed-by=%s] https://pkg.cloudflare.com/cloudflare-main.gpg any main\n' "$CLOUDFLARED_KEYRING" > "$CLOUDFLARED_SOURCE_FILE"
chmod 0644 "$CLOUDFLARED_SOURCE_FILE"
cp "$CLOUDFLARED_SOURCE_FILE" "$CASE_DIR/wrong-source"
if configure_repository > "$CASE_DIR/rejected.log" 2>&1; then fail "gpg repository accepted"; fi
assert_same "$CLOUDFLARED_SOURCE_FILE" "$CASE_DIR/wrong-source" "unowned wrong source overwritten"
[[ ! -s "$FAKE_LOG" ]] || fail "invalid source triggered external operation"
pass "gpg repository URL rejected without overwrite or download"

for capture_file in old-key old-source old-current; do
    for capture_fault in copy partial chmod HUP INT TERM exit0; do
        (
            new_case
            trap - EXIT
            configure_repository || fail "capture fixture"
            for object in "$KEYRING" "$SOURCE_FILE" "$REPOSITORY_STATE_DIR/current"; do
                cp -p "$object" "$CASE_DIR/$(basename "$object").before"
            done
            : > "$FAKE_LOG"
            rc=0
            (
                trap - EXIT
                repository_copy_file() {
                    if [[ "$2" == */"$capture_file" ]]; then
                        case "$capture_fault" in
                            copy) return 1 ;;
                            partial) printf partial > "$2"; return 1 ;;
                            HUP|INT|TERM) kill -s "$capture_fault" "$BASHPID" ;;
                            exit0) exit 0 ;;
                        esac
                    fi
                    command cp -- "$1" "$2"
                }
                chmod() {
                    if [[ "$capture_fault" == chmod && "$2" == */"$capture_file" ]]; then return 1; fi
                    command chmod "$@"
                }
                configure_repository
            ) > "$CASE_DIR/capture.log" 2>&1 || rc=$?
            case "$capture_fault" in HUP) expected=129 ;; INT) expected=130 ;; TERM) expected=143 ;; *) expected=1 ;; esac
            [[ "$rc" == "$expected" ]] || fail "capture status $rc"
            for object in "$KEYRING" "$SOURCE_FILE" "$REPOSITORY_STATE_DIR/current"; do
                cmp "$object" "$CASE_DIR/$(basename "$object").before" || fail "capture modified formal bytes"
                [[ "$(stat -c '%u:%g:%a' "$object")" == "$(stat -c '%u:%g:%a' "$CASE_DIR/$(basename "$object").before")" ]] || fail "capture modified metadata"
            done
            [[ ! -s "$FAKE_LOG" ]] || fail "capture downloaded or called APT"
            grep -q '未恢复或删除正式文件' "$CASE_DIR/capture.log" || fail "capture diagnostic missing"
            acquire_repository_lock || fail "capture lock retained"
            release_repository_lock || fail "capture lock release"
        ) > "$TEST_DIR/capture-boundary-$capture_file-$capture_fault.log" 2>&1 || {
            cat "$TEST_DIR/capture-boundary-$capture_file-$capture_fault.log"
            fail "capture boundary $capture_file $capture_fault"
        }
        pass "repository capture $capture_file $capture_fault preserves formal bytes and metadata"
    done
done

(
    new_case
    trap - EXIT
    set_old_generation
    rc=0
    (
        trap - EXIT
        begin_repository_transaction || exit 1
        exit 0
    ) > "$CASE_DIR/active-exit.log" 2>&1 || rc=$?
    [[ "$rc" == 1 ]] || fail "active exit zero accepted"
    assert_old_generation
    [[ ! -e "$REPOSITORY_STATE_DIR/current" ]] || fail "absent current restored incorrectly"
    acquire_repository_lock || fail "active exit lock retained"
    release_repository_lock || fail "active exit release"
) || fail "active exit zero"
pass "complete repository transaction exit zero returns nonzero and restores absent current"

for build_case in absent archive-failure; do
    (
        new_case
        trap - EXIT
        if [[ "$build_case" == archive-failure ]]; then set_old_generation; fi
        trap ':' HUP
        before_traps=$(trap -p HUP INT TERM EXIT)
        repository_copy_file() { printf partial > "$2"; return 1; }
        if [[ "$build_case" == absent ]]; then
            # No formal object exists; fail before any download via snapshot wrapper.
            chmod() {
                [[ "$2" != */transaction-* ]] || return 1
                command chmod "$@"
            }
            repository_transaction_hook() { exit 0; }
            rc=0
            (begin_repository_transaction) > "$CASE_DIR/absent.log" 2>&1 || rc=$?
            [[ "$rc" != 0 ]] || fail "absent abnormal exit accepted"
            [[ ! -e "$KEYRING" && ! -e "$SOURCE_FILE" && ! -e "$REPOSITORY_STATE_DIR/current" ]] || fail "absent formal object created"
        else
            repository_rename() { return 1; }
            if configure_repository > "$CASE_DIR/build.log" 2>&1; then fail "failed capture accepted"; fi
            assert_old_generation
            [[ -f "$REPOSITORY_TRANSACTION_DIR/old-key" ]] || fail "partial evidence lost"
            [[ -f "$REPOSITORY_TRANSACTION_DIR/rollback.log" ]] || fail "failure diagnostic lost"
            grep -q '回滚不完整' "$CASE_DIR/build.log" || fail "cleanup error not reported"
        fi
        [[ "$(trap -p HUP INT TERM EXIT)" == "$before_traps" ]] || fail "build traps changed"
        acquire_repository_lock || fail "build cleanup lock retained"
        release_repository_lock || fail "build cleanup lock release"
    ) > "$TEST_DIR/build-$build_case.log" 2>&1 || {
        cat "$TEST_DIR/build-$build_case.log"
        fail "build $build_case"
    }
    pass "repository building $build_case preserves objects traps and evidence"
done
