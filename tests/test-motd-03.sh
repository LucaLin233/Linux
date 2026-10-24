#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/test-motd-common.sh"

for pending_hook_case in id extra-line inode; do
(
    root="$TEST_DIR/pending-hook-$pending_hook_case"; create_fixture "$root"; export_paths "$root"
    load_motd; motd_run_locked_operation install
    before=$(target_hash "$root")
    motd_transaction_phase_hook() {
        local phase="$1" stage
        [[ "$phase" == pending-publish ]] || return 0
        stage=${MOTD_PENDING_STAGE_PATHS[${#MOTD_PENDING_STAGE_PATHS[@]}-1]}
        case "$pending_hook_case" in
            id) printf '%032x\n' 1 > "$stage" ;;
            extra-line) printf 'extra\n' >> "$stage" ;;
            inode) cp "$stage" "${stage}.replacement"; chmod 0600 "${stage}.replacement"; mv -Tf "${stage}.replacement" "$stage" ;;
        esac
    }
    motd_target_commit_hook() { : > "$root/commit-called"; }
    assert_fail "pending publish hook $pending_hook_case rejected" motd_run_locked_operation install
    [[ ! -e "$root/commit-called" ]] || fail "pending hook $pending_hook_case reached formal target commit"
    assert_eq "$before" "$(target_hash "$root")" "pending hook $pending_hook_case preserves targets"
    [[ ! -e "$MOTD_STATE_DIR/pending" && ! -L "$MOTD_STATE_DIR/pending" ]] || fail "pending hook $pending_hook_case left pending"
    assert_no_motd_residue "$root"
)
done

cat > "$TEST_DIR/building-signal-child.sh" <<'CHILD'
#!/usr/bin/env bash
set -euo pipefail
trap - HUP INT TERM
. "$1"
send_building_signal() { kill -"$SIGNAL_NAME" "$BASHPID"; }
motd_transaction_phase_hook() {
    case "$FAIL_PHASE:$1" in
        transaction-snapshot-building:transaction-snapshot-building|snapshot-commit:snapshot-commit|transaction-final-move:transaction-final-move) send_building_signal ;;
    esac
    return 0
}
motd_snapshot_capture_hook() {
    [[ "$MOTD_TRANSACTION_LIFECYCLE" == building ]] || return 0
    case "$FAIL_PHASE:$1" in capture-motd:motd|capture-issue_net:issue_net|capture-motd_news:motd_news) send_building_signal ;; esac
    return 0
}
motd_run_locked_operation install
CHILD
chmod 0700 "$TEST_DIR/building-signal-child.sh"

for building_phase in transaction-snapshot-building capture-motd capture-issue_net capture-motd_news snapshot-commit transaction-final-move; do
(
    root="$TEST_DIR/building-fail-$building_phase"; create_fixture "$root"; export_paths "$root"
    load_motd; motd_run_locked_operation install
    before=$(target_hash "$root"); before_pointers="$(cat "$MOTD_STATE_DIR/initial.current")|$(cat "$MOTD_STATE_DIR/previous.current")"; before_count=$(generation_count "$MOTD_STATE_DIR/generations")
    motd_transaction_phase_hook() { case "$building_phase:$1" in transaction-snapshot-building:transaction-snapshot-building|snapshot-commit:snapshot-commit|transaction-final-move:transaction-final-move) return 1 ;; esac; return 0; }
    motd_snapshot_capture_hook() { [[ "$MOTD_TRANSACTION_LIFECYCLE" == building ]] || return 0; case "$building_phase:$1" in capture-motd:motd|capture-issue_net:issue_net|capture-motd_news:motd_news) return 1 ;; esac; return 0; }
    assert_fail "$building_phase ordinary failure returns nonzero" motd_run_locked_operation install
    assert_eq "$before" "$(target_hash "$root")" "$building_phase ordinary failure preserves targets"
    assert_eq "$before_pointers" "$(cat "$MOTD_STATE_DIR/initial.current")|$(cat "$MOTD_STATE_DIR/previous.current")" "$building_phase ordinary failure preserves pointers"
    assert_eq "$before_count" "$(generation_count "$MOTD_STATE_DIR/generations")" "$building_phase ordinary failure preserves generations"
    assert_no_motd_residue "$root"
    motd_take_lock; motd_release_lock
)
    for signal_name in HUP INT TERM; do
    (
        root="$TEST_DIR/building-$building_phase-$signal_name"; create_fixture "$root"; export_paths "$root"
        bash -c '. "$1"; motd_run_locked_operation install' _ "$ROOT_DIR/tools/setup-motd.sh"
        before=$(target_hash "$root"); before_pointers="$(cat "$MOTD_STATE_DIR/initial.current")|$(cat "$MOTD_STATE_DIR/previous.current")"; before_count=$(generation_count "$MOTD_STATE_DIR/generations")
        rc=0
        env --default-signal=HUP,INT,TERM FAIL_PHASE="$building_phase" SIGNAL_NAME="$signal_name" bash "$TEST_DIR/building-signal-child.sh" "$ROOT_DIR/tools/setup-motd.sh" >/dev/null 2>&1 || rc=$?
        case "$signal_name" in HUP) expected=129 ;; INT) expected=130 ;; TERM) expected=143 ;; esac
        assert_eq "$expected" "$rc" "$building_phase $signal_name status"
        assert_eq "$before" "$(target_hash "$root")" "$building_phase $signal_name preserves targets"
        assert_eq "$before_pointers" "$(cat "$MOTD_STATE_DIR/initial.current")|$(cat "$MOTD_STATE_DIR/previous.current")" "$building_phase $signal_name preserves pointers"
        assert_eq "$before_count" "$(generation_count "$MOTD_STATE_DIR/generations")" "$building_phase $signal_name preserves generations"
        assert_no_motd_residue "$root"
        bash -c '. "$1"; motd_take_lock; motd_release_lock' _ "$ROOT_DIR/tools/setup-motd.sh"
    )
    done
done

for previous_impl in tool module; do
(
    root="$TEST_DIR/previous-only-$previous_impl"; create_fixture "$root"; export_paths "$root"
    create_complete_legacy_scope previous
    case "$previous_impl" in tool) script="$ROOT_DIR/tools/setup-motd.sh" ;; module) script="$ROOT_DIR/modules/system-customize.sh" ;; esac
    # shellcheck source=/dev/null
    . "$script"
    motd_run_locked_operation restore previous
    [[ ! -e "$MOTD_STATE_DIR/initial.current" && ! -L "$MOTD_STATE_DIR/initial.current" ]] || fail "$previous_impl previous-only created initial pointer"
    [[ -e "$MOTD_STATE_DIR/previous.current" ]] || fail "$previous_impl previous-only missing previous pointer"
    motd_run_locked_operation restore previous
    [[ ! -e "$MOTD_STATE_DIR/pending" && -z "$(find "$MOTD_TRANSACTION_PARENT" -mindepth 1 -print -quit)" ]] || fail "$previous_impl repeated previous restore left transaction"
    motd_run_locked_operation install
    [[ -e "$MOTD_STATE_DIR/initial.current" && -e "$MOTD_STATE_DIR/previous.current" ]] || fail "$previous_impl install did not complete initial/previous pointers"
    assert_eq 2 "$(generation_count "$MOTD_STATE_DIR/generations")" "$previous_impl previous-only lifecycle bounded"
)
done

for time_direction in tool-module module-tool; do
(
    root="$TEST_DIR/timestamps-$time_direction"; create_fixture "$root"; export_paths "$root"
    printf news > "$MOTD_ETC_ROOT/update-motd.d/50-motd-news"; chmod 0755 "$MOTD_ETC_ROOT/update-motd.d/50-motd-news"
    for native in 10-uname 50-motd-news; do touch -a -d @1000000000 "$MOTD_ETC_ROOT/update-motd.d/$native"; touch -m -d @1000200000 "$MOTD_ETC_ROOT/update-motd.d/$native"; done
    expected_uname=$(stat -c %X:%Y "$MOTD_ETC_ROOT/update-motd.d/10-uname"); expected_news=$(stat -c %X:%Y "$MOTD_ETC_ROOT/update-motd.d/50-motd-news")
    case "$time_direction" in
        tool-module) install_script="$ROOT_DIR/tools/setup-motd.sh"; restore_script="$ROOT_DIR/modules/system-customize.sh" ;;
        module-tool) install_script="$ROOT_DIR/modules/system-customize.sh"; restore_script="$ROOT_DIR/tools/setup-motd.sh" ;;
    esac
    # shellcheck source=/dev/null
    . "$install_script"; motd_run_locked_operation install
    assert_eq "$expected_uname" "$(stat -c %X:%Y "$MOTD_ETC_ROOT/update-motd.d/10-uname")" "$time_direction install preserves uname timestamps"
    assert_eq "$expected_news" "$(stat -c %X:%Y "$MOTD_ETC_ROOT/update-motd.d/50-motd-news")" "$time_direction install preserves news timestamps"
    for native in 10-uname 50-motd-news; do touch -a -d @1100000000 "$MOTD_ETC_ROOT/update-motd.d/$native"; touch -m -d @1100200000 "$MOTD_ETC_ROOT/update-motd.d/$native"; done
    bash -c '. "$1"; motd_run_locked_operation restore previous' _ "$restore_script"
    assert_eq "$expected_uname" "$(stat -c %X:%Y "$MOTD_ETC_ROOT/update-motd.d/10-uname")" "$time_direction previous restores uname timestamps"
    assert_eq "$expected_news" "$(stat -c %X:%Y "$MOTD_ETC_ROOT/update-motd.d/50-motd-news")" "$time_direction previous restores news timestamps"
    for native in 10-uname 50-motd-news; do touch -a -d @1200000000 "$MOTD_ETC_ROOT/update-motd.d/$native"; touch -m -d @1200200000 "$MOTD_ETC_ROOT/update-motd.d/$native"; done
    bash -c '. "$1"; motd_run_locked_operation restore initial' _ "$restore_script"
    assert_eq "$expected_uname" "$(stat -c %X:%Y "$MOTD_ETC_ROOT/update-motd.d/10-uname")" "$time_direction initial restores uname timestamps"
    assert_eq "$expected_news" "$(stat -c %X:%Y "$MOTD_ETC_ROOT/update-motd.d/50-motd-news")" "$time_direction initial restores news timestamps"
)
done

for hidden_location in transactions generations root; do
    for hidden_kind in file symlink fifo dir; do
    (
        root="$TEST_DIR/hidden-$hidden_location-$hidden_kind"; create_fixture "$root"; export_paths "$root"
        load_motd; motd_run_locked_operation install
        case "$hidden_location" in transactions) parent="$MOTD_TRANSACTION_PARENT" ;; generations) parent="$MOTD_STATE_DIR/generations" ;; root) parent="$MOTD_STATE_DIR" ;; esac
        object="$parent/.evil-$hidden_kind"
        case "$hidden_kind" in file) printf evil > "$object" ;; symlink) ln -s "$root/missing" "$object" ;; fifo) mkfifo "$object" ;; dir) mkdir "$object" ;; esac
        before=$(target_hash "$root"); pointers="$(cat "$MOTD_STATE_DIR/initial.current")|$(cat "$MOTD_STATE_DIR/previous.current")"
        if [[ "$hidden_kind" == file || "$hidden_kind" == fifo ]]; then operation=(install); else operation=(restore previous); fi
        assert_fail "$hidden_location hidden $hidden_kind rejected" motd_run_locked_operation "${operation[@]}"
        assert_eq "$before" "$(target_hash "$root")" "$hidden_location hidden $hidden_kind preserves targets"
        assert_eq "$pointers" "$(cat "$MOTD_STATE_DIR/initial.current")|$(cat "$MOTD_STATE_DIR/previous.current")" "$hidden_location hidden $hidden_kind preserves pointers"
        [[ -e "$object" || -L "$object" ]] || fail "$hidden_location hidden $hidden_kind evidence removed"
        motd_take_lock; motd_release_lock
    )
    done
done

(
    root="$TEST_DIR/hidden-transaction-short"; create_fixture "$root"; export_paths "$root"
    load_motd; motd_run_locked_operation install
    printf evil > "$MOTD_TRANSACTION_PARENT/.123"
    before=$(target_hash "$root")
    assert_fail "transactions .123 rejected" motd_run_locked_operation install
    assert_eq "$before" "$(target_hash "$root")" "transactions .123 preserves targets"
    [[ -e "$MOTD_TRANSACTION_PARENT/.123" ]] || fail "transactions .123 evidence removed"
    motd_take_lock; motd_release_lock
)

(
    transaction_block="$TEST_DIR/transaction-block"
    sed -n '/# === MOTD group transaction ===/,/^configure_motd()/p' "$ROOT_DIR/tools/setup-motd.sh" > "$transaction_block"
    if grep -Eq "stat .*%F|regular file|regular empty file|symbolic link" "$transaction_block"; then fail "MOTD transaction depends on localized stat type text"; fi
    pass "MOTD transaction avoids localized stat type text"
)

(
    root="$TEST_DIR/locale-types"; create_fixture "$root"; export_paths "$root"
    printf outside > "$root/outside"; rm -f "$MOTD_ETC_ROOT/issue"; ln -s "$root/outside" "$MOTD_ETC_ROOT/issue"
    create_complete_legacy_scope initial
    load_motd
    stat() {
        if [[ "$*" == *"%F"* ]]; then printf '本地化文件类型\n'; else command stat "$@"; fi
    }
    LANG=zh_CN.UTF-8 motd_run_locked_operation restore initial
    [[ -L "$MOTD_ETC_ROOT/issue" ]] || fail "localized stat wrapper broke symlink restore"
    assert_eq original "$(cat "$MOTD_ETC_ROOT/motd")" "localized stat wrapper preserves regular legacy import"
    LANG=zh_CN.UTF-8 bash -c '. "$1"; motd_run_locked_operation install' _ "$ROOT_DIR/modules/system-customize.sh"
)

for missing_command in bash chown flock ln od readlink sha256sum touch wc; do
(
    root="$TEST_DIR/module-missing-$missing_command"; create_fixture "$root"; export_paths "$root"
    before=$(target_hash "$root"); rc=0; mkdir "$root/bin"
    for available_command in apt-get apt-cache awk bash basename cat chmod chown cp curl df dirname dpkg flock grep hostname id install ln mkdir mktemp mv od readlink rm sed sha256sum sleep sort stat touch tr uname uptime wc; do
        [[ "$available_command" == "$missing_command" ]] && continue
        available_path=$(command -v "$available_command" || true)
        if [[ -n "$available_path" ]]; then ln -s "$available_path" "$root/bin/$available_command"
        else printf '#!/bin/sh\nexit 0\n' > "$root/bin/$available_command"; chmod 0755 "$root/bin/$available_command"; fi
    done
    PATH="$root/bin" /bin/bash -c '
        . "$1"
        require_root() { :; }
        main motd
    ' _ "$ROOT_DIR/modules/system-customize.sh" > "$root/output" 2>&1 || rc=$?
    assert_eq 1 "$rc" "module missing $missing_command fails before action"
    grep -Fq "缺少必要命令: $missing_command" "$root/output" || fail "module missing $missing_command not reported"
    pass "module preflight reports missing $missing_command"
    assert_eq "$before" "$(target_hash "$root")" "module missing $missing_command preserves MOTD"
    [[ ! -e "$MOTD_STATE_DIR" && ! -e "$MOTD_LOCK_FILE" ]] || fail "module missing $missing_command created lock/state"
)
done

grep -Fq 'error "缺少必要命令: $required_command"' "$ROOT_DIR/modules/system-customize.sh" || fail "module missing-command error output branch absent"
pass "module dependency preflight retains missing-command output"


for noop_impl in tool module; do
    for noop_created_type in regular symlink fifo; do
    (
        root="$TEST_DIR/noop-absent-$noop_impl-$noop_created_type"; create_fixture "$root"; export_paths "$root"
        path="$MOTD_ETC_ROOT/update-motd.d/50-motd-news"; before=$(target_hash "$root")
        if [[ "$noop_impl" == tool ]]; then load_motd; else . "$ROOT_DIR/modules/system-customize.sh"; fi
        motd_target_commit_hook() { if [[ "$2" == motd_news ]]; then case "$noop_created_type" in regular) printf created > "$3"; chmod 0755 "$3" ;; symlink) ln -s "$root/external" "$3" ;; fifo) mkfifo "$3" ;; esac; fi; return 0; }
        assert_fail "$noop_impl absent noop rejects $noop_created_type creation" motd_run_locked_operation install
        assert_eq "$before" "$(target_hash "$root")" "$noop_impl absent noop $noop_created_type rolls back group"
        [[ ! -e "$path" && ! -L "$path" ]] || fail "$noop_impl absent noop $noop_created_type left created object"
        assert_no_motd_residue "$root"; motd_take_lock; motd_release_lock
    )
    done
done

for noop_impl in tool module; do
    for noop_change in regular-content regular-mode regular-inode regular-symlink symlink-target absent-regular; do
    (
        root="$TEST_DIR/noop-unknown-$noop_impl-$noop_change"; create_fixture "$root"; export_paths "$root"
        printf '# linux-setup:managed-motd\n' > "$MOTD_ETC_ROOT/update-motd.d/00-custom-welcome"; chmod 0755 "$MOTD_ETC_ROOT/update-motd.d/00-custom-welcome"
        if [[ "$noop_impl" == tool ]]; then load_motd; else . "$ROOT_DIR/modules/system-customize.sh"; fi
        motd_run_locked_operation install
        case "$noop_change" in regular-content|regular-symlink) target_id=motd ;; regular-mode) target_id=issue ;; regular-inode) target_id=custom_welcome ;; symlink-target) target_id="uname"; rm -f "${MOTD_PATH_BY_ID[$target_id]}"; ln -s "$root/link-one" "${MOTD_PATH_BY_ID[$target_id]}" ;; absent-regular) target_id=motd_news ;; esac
        before=$(target_hash "$root")
        motd_target_commit_hook() { local id="$2" path="$3" replacement; [[ "$id" == "$target_id" ]] || return 0; case "$noop_change" in regular-content) printf changed > "$path" ;; regular-mode) chmod 0600 "$path" ;; regular-inode) replacement="${path}.replacement"; cp "$path" "$replacement"; chmod 0755 "$replacement"; mv -Tf "$replacement" "$path" ;; regular-symlink) rm -f "$path"; ln -s "$root/other" "$path" ;; symlink-target) rm -f "$path"; ln -s "$root/link-two" "$path" ;; absent-regular) printf created > "$path"; chmod 0755 "$path" ;; esac; return 0; }
        assert_fail "$noop_impl unknown noop rejects $noop_change" motd_run_locked_operation restore initial
        assert_eq "$before" "$(target_hash "$root")" "$noop_impl unknown noop $noop_change rolls back group"
        assert_no_motd_residue "$root"; motd_take_lock; motd_release_lock
    )
    done
done
