#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/test-motd-common.sh"

for journal_case in pending-directory journal-transaction generation-scope generation-missing old-new-mix; do
(
    root="$TEST_DIR/journal-$journal_case"; create_fixture "$root"; export_paths "$root"
    bash -c '. "$1"; motd_run_locked_operation install' _ "$ROOT_DIR/tools/setup-motd.sh"
    rc=0
    if [[ "$journal_case" == pending-directory || "$journal_case" == journal-transaction ]]; then
        bash "$TEST_DIR/kill-pending-child.sh" "$ROOT_DIR/tools/setup-motd.sh" >/dev/null 2>&1 || rc=$?
    else
        bash "$TEST_DIR/kill-previous-pointer-child.sh" "$ROOT_DIR/tools/setup-motd.sh" >/dev/null 2>&1 || rc=$?
    fi
    assert_eq 137 "$rc" "$journal_case fixture stops with SIGKILL"
    transaction=$(cat "$MOTD_STATE_DIR/pending")
    journal="$MOTD_TRANSACTION_PARENT/$transaction/journal"
    case "$journal_case" in
        pending-directory) printf '%032x\n' 1 > "$MOTD_STATE_DIR/pending" ;;
        journal-transaction) sed -i 's/^transaction=.*/transaction=00000000000000000000000000000001/' "$journal" ;;
        generation-scope) initial=$(cat "$MOTD_STATE_DIR/initial.current"); sed -i "s/^previous_new=.*/previous_new=$initial/" "$journal" ;;
        generation-missing) sed -i 's/^previous_new=.*/previous_new=ffffffffffffffffffffffffffffffff/' "$journal" ;;
        old-new-mix) initial=$(cat "$MOTD_STATE_DIR/initial.current"); sed -i "s/^previous_old=.*/previous_old=$initial/" "$journal" ;;
    esac
    before=$(target_hash "$root")
    load_motd
    assert_fail "$journal_case pending/journal mismatch rejected" motd_run_locked_operation install
    assert_eq "$before" "$(target_hash "$root")" "$journal_case mismatch changes no target"
    [[ -e "$MOTD_STATE_DIR/pending" ]] || fail "$journal_case evidence removed"
)
done

for tamper_case in content mode inode regular-to-symlink; do
(
    root="$TEST_DIR/stage-$tamper_case"; create_fixture "$root"; export_paths "$root"
    printf news > "$MOTD_ETC_ROOT/update-motd.d/50-motd-news"; chmod 0755 "$MOTD_ETC_ROOT/update-motd.d/50-motd-news"
    before=$(target_hash "$root")
    load_motd
    motd_transaction_phase_hook() {
        [[ "$1" == install-plan-ready ]] || return 0
        case "$tamper_case" in
            content) printf tampered > "${MOTD_TARGET_STAGE[motd]}" ;;
            mode) chmod 0600 "${MOTD_TARGET_STAGE[issue_net]}" ;;
            inode) cp "$MOTD_ETC_ROOT/update-motd.d/50-motd-news" "${MOTD_TARGET_STAGE[motd_news]}.replacement"; chmod 0644 "${MOTD_TARGET_STAGE[motd_news]}.replacement"; mv -Tf "${MOTD_TARGET_STAGE[motd_news]}.replacement" "${MOTD_TARGET_STAGE[motd_news]}" ;;
            regular-to-symlink) rm -f "${MOTD_TARGET_STAGE[issue_net]}"; ln -s "$root/elsewhere" "${MOTD_TARGET_STAGE[issue_net]}" ;;
        esac
    }
    motd_target_commit_hook() { : > "$root/commit-called"; }
    assert_fail "$tamper_case stage tamper rejected before commit" motd_run_locked_operation install
    [[ ! -e "$root/commit-called" ]] || fail "$tamper_case reached first formal commit"
    assert_eq "$before" "$(target_hash "$root")" "$tamper_case stage tamper changes no target"
    assert_no_motd_residue "$root"
)
done

(
    root="$TEST_DIR/stage-symlink-target"; create_fixture "$root"; export_paths "$root"
    printf external > "$root/external"; ln -sf "$root/external" "$MOTD_ETC_ROOT/issue"
    load_motd; motd_run_locked_operation install
    before=$(target_hash "$root")
    motd_transaction_phase_hook() {
        [[ "$1" == restore-plan-ready ]] || return 0
        rm -f "${MOTD_TARGET_STAGE[issue]}"; ln -s "$root/other" "${MOTD_TARGET_STAGE[issue]}"
    }
    motd_target_commit_hook() { : > "$root/commit-called"; }
    assert_fail "symlink target stage tamper rejected before restore commit" motd_run_locked_operation restore previous
    [[ ! -e "$root/commit-called" ]] || fail "symlink target tamper reached formal commit"
    assert_eq "$before" "$(target_hash "$root")" "symlink target tamper changes no target"
)

for native_id in uname motd_news; do
(
    root="$TEST_DIR/native-symlink-$native_id"; create_fixture "$root"; export_paths "$root"
    case "$native_id" in uname) native_path="$MOTD_ETC_ROOT/update-motd.d/10-uname" ;; motd_news) native_path="$MOTD_ETC_ROOT/update-motd.d/50-motd-news" ;; esac
    rm -f "$native_path"
    printf 'external-%s\n' "$native_id" > "$root/external-$native_id"; chmod 0755 "$root/external-$native_id"
    external_hash=$(sha256sum "$root/external-$native_id"); external_mode=$(stat -c %a "$root/external-$native_id")
    ln -s "$root/external-$native_id" "$native_path"
    load_motd
    motd_run_locked_operation install
    [[ ! -e "$native_path" && ! -L "$native_path" ]] || fail "$native_id symlink entry remains enabled"
    assert_eq "$external_hash" "$(sha256sum "$root/external-$native_id")" "$native_id external content unchanged"
    assert_eq "$external_mode" "$(stat -c %a "$root/external-$native_id")" "$native_id external mode unchanged"
    motd_run_locked_operation restore previous
    [[ -L "$native_path" && "$(readlink "$native_path")" == "$root/external-$native_id" ]] || fail "$native_id previous symlink not restored"
)
done

cat > "$TEST_DIR/sigkill-child.sh" <<'CHILD'
#!/usr/bin/env bash
set -euo pipefail
. "$1"
motd_transaction_phase_hook() {
    [[ "$1" == "$KILL_PHASE" ]] && kill -KILL "$BASHPID"
    return 0
}
motd_run_locked_operation install
CHILD
chmod 0700 "$TEST_DIR/sigkill-child.sh"

for kill_phase in transaction-snapshot-building transaction-final-moved target-committed-motd target-committed-issue_net target-committed-motd_news committed-cleanup committed-old-generation-cleaned committed-pending-removed; do
(
    root="$TEST_DIR/sigkill-$kill_phase"; create_fixture "$root"; export_paths "$root"
    printf news > "$MOTD_ETC_ROOT/update-motd.d/50-motd-news"; chmod 0755 "$MOTD_ETC_ROOT/update-motd.d/50-motd-news"
    bash -c '. "$1"; motd_run_locked_operation install' _ "$ROOT_DIR/tools/setup-motd.sh"
    before=$(target_hash "$root")
    rc=0
    KILL_PHASE="$kill_phase" bash "$TEST_DIR/sigkill-child.sh" "$ROOT_DIR/tools/setup-motd.sh" >/dev/null 2>&1 || rc=$?
    assert_eq 137 "$rc" "SIGKILL at $kill_phase terminates process"
    after_kill=$(target_hash "$root")
    load_motd
    motd_take_lock; motd_prepare_state_layout; motd_reconcile_state; motd_release_lock
    if [[ "$kill_phase" == committed-* ]]; then
        assert_eq "$after_kill" "$(target_hash "$root")" "committed cleanup SIGKILL does not roll back"
    else
        assert_eq "$before" "$(target_hash "$root")" "SIGKILL at $kill_phase rolls back to pre-transaction state"
    fi
    assert_eq 2 "$(generation_count "$MOTD_STATE_DIR/generations")" "SIGKILL at $kill_phase leaves bounded generations"
    assert_no_motd_residue "$root"
    motd_take_lock; motd_release_lock
)
done

(
    root="$TEST_DIR/generation-bounded"; create_fixture "$root"; export_paths "$root"
    load_motd
    for _ in {1..6}; do motd_run_locked_operation install; done
    assert_eq 2 "$(generation_count "$MOTD_STATE_DIR/generations")" "repeated install keeps two generations"
)

(
    root="$TEST_DIR/generation-commit-failure"; create_fixture "$root"; export_paths "$root"
    load_motd; motd_run_locked_operation install
    before_count=$(generation_count "$MOTD_STATE_DIR/generations")
    motd_target_commit_hook() { [[ "$2" != issue_net ]]; }
    assert_fail "target commit failure returns nonzero for generation cleanup" motd_run_locked_operation install
    assert_eq "$before_count" "$(generation_count "$MOTD_STATE_DIR/generations")" "target commit failure leaves no orphan generation"
)

(
    root="$TEST_DIR/interop-module-tool"; create_fixture "$root"; export_paths "$root"
    original=$(target_hash "$root")
    bash -c '. "$1/modules/system-customize.sh"; ask_yes_no(){ return 0; }; motd_preview_hook(){ :; }; configure_motd' _ "$ROOT_DIR" >/dev/null
    printf changed > "$MOTD_ETC_ROOT/motd"
    bash -c '. "$1/tools/setup-motd.sh"; motd_run_locked_operation restore previous' _ "$ROOT_DIR"
    assert_eq "$original" "$(target_hash "$root")" "module install to tool previous restore"
    printf changed > "$MOTD_ETC_ROOT/motd"
    bash -c '. "$1/tools/setup-motd.sh"; motd_run_locked_operation restore initial' _ "$ROOT_DIR"
    assert_eq "$original" "$(target_hash "$root")" "module install to tool initial restore"
)

(
    root="$TEST_DIR/interop-tool-module"; create_fixture "$root"; export_paths "$root"
    original=$(target_hash "$root")
    bash -c '. "$1/tools/setup-motd.sh"; motd_run_locked_operation install' _ "$ROOT_DIR"
    printf between > "$MOTD_ETC_ROOT/motd"; between=$(target_hash "$root")
    bash -c '. "$1/modules/system-customize.sh"; ask_yes_no(){ return 0; }; motd_preview_hook(){ :; }; configure_motd' _ "$ROOT_DIR" >/dev/null
    bash -c '. "$1/modules/system-customize.sh"; motd_run_locked_operation restore previous' _ "$ROOT_DIR"
    assert_eq "$between" "$(target_hash "$root")" "tool install to module previous restore"
    printf changed > "$MOTD_ETC_ROOT/motd"
    bash -c '. "$1/modules/system-customize.sh"; motd_run_locked_operation restore initial' _ "$ROOT_DIR"
    assert_eq "$original" "$(target_hash "$root")" "tool install to module initial restore"
)


(
    root="$TEST_DIR/cleanup-old-generation-failure"; create_fixture "$root"; export_paths "$root"
    load_motd; motd_run_locked_operation install
    old_previous=$(cat "$MOTD_STATE_DIR/previous.current"); blocked="$MOTD_STATE_DIR/generations/$old_previous"
    motd_cleanup_path_hook() { [[ "$1" != "$blocked" ]]; }
    assert_fail "old previous generation delete failure returns nonzero" motd_run_locked_operation install
    [[ -e "$MOTD_STATE_DIR/pending" ]] || fail "old generation delete failure lost pending journal"
    transaction=$(cat "$MOTD_STATE_DIR/pending"); grep -Fq 'phase=committed' "$MOTD_TRANSACTION_PARENT/$transaction/journal" || fail "old generation failure journal not committed"
    [[ -d "$blocked" ]] || fail "blocked old generation unexpectedly removed"
    motd_cleanup_path_hook() { :; }
    motd_run_locked_operation install
    [[ ! -e "$MOTD_STATE_DIR/pending" ]] || fail "old generation cleanup retry left pending"
)

(
    root="$TEST_DIR/cleanup-rollback-generation-failure"; create_fixture "$root"; export_paths "$root"
    load_motd; motd_run_locked_operation install
    current_initial=$(cat "$MOTD_STATE_DIR/initial.current"); current_previous=$(cat "$MOTD_STATE_DIR/previous.current")
    motd_cleanup_path_hook() {
        local name=${1##*/}
        if [[ "$1" == "$MOTD_STATE_DIR/generations/"* && "$name" != "$current_initial" && "$name" != "$current_previous" ]]; then return 1; fi
        return 0
    }
    motd_target_commit_hook() { [[ "$2" != issue_net ]]; }
    assert_fail "rollback generation delete failure returns nonzero" motd_run_locked_operation install
    [[ -e "$MOTD_STATE_DIR/pending" ]] || fail "rollback generation failure lost pending"
    transaction=$(cat "$MOTD_STATE_DIR/pending"); grep -Fq 'phase=rolledback' "$MOTD_TRANSACTION_PARENT/$transaction/journal" || fail "rollback generation failure journal not rolledback"
    motd_cleanup_path_hook() { :; }; motd_target_commit_hook() { :; }
    motd_run_locked_operation install
    [[ ! -e "$MOTD_STATE_DIR/pending" ]] || fail "rolledback cleanup retry left pending"
    assert_eq 2 "$(generation_count "$MOTD_STATE_DIR/generations")" "rolledback cleanup retry restores bounded generations"
)


for hook_case in content-motd mode-issue_net inode-motd_news type-issue_net; do
(
    root="$TEST_DIR/hook-target-$hook_case"; create_fixture "$root"; export_paths "$root"
    printf news > "$MOTD_ETC_ROOT/update-motd.d/50-motd-news"; chmod 0755 "$MOTD_ETC_ROOT/update-motd.d/50-motd-news"
    before=$(target_hash "$root")
    load_motd
    motd_target_commit_hook() {
        local id="$2" stage replacement
        case "$hook_case:$id" in
            content-motd:motd) printf changed > "${MOTD_TARGET_STAGE[motd]}" ;;
            mode-issue_net:issue_net) chmod 0600 "${MOTD_TARGET_STAGE[issue_net]}" ;;
            inode-motd_news:motd_news)
                stage=${MOTD_TARGET_STAGE[motd_news]}; replacement="${stage}.replacement"
                cp "$stage" "$replacement"; chmod "${MOTD_STAGE_MODE[motd_news]}" "$replacement"; mv -Tf "$replacement" "$stage"
                ;;
            type-issue_net:issue_net) rm -f "${MOTD_TARGET_STAGE[issue_net]}"; ln -s "$root/other" "${MOTD_TARGET_STAGE[issue_net]}" ;;
        esac
        return 0
    }
    assert_fail "$hook_case target hook tamper rejected" motd_run_locked_operation install
    assert_eq "$before" "$(target_hash "$root")" "$hook_case leaves formal targets unchanged"
    assert_no_motd_residue "$root"
)
done

(
    root="$TEST_DIR/hook-rollback-stage"; create_fixture "$root"; export_paths "$root"
    load_motd; motd_run_locked_operation install
    before=$(target_hash "$root")
    motd_target_commit_hook() { [[ "$2" != issue_net ]]; }
    motd_rollback_hook() { [[ "$1" != motd ]] || printf tampered > "${MOTD_TARGET_STAGE[motd]}"; return 0; }
    assert_fail "rollback hook stage tamper rejected" motd_run_locked_operation install
    [[ -e "$MOTD_STATE_DIR/pending" ]] || fail "rollback hook tamper did not preserve pending journal"
    motd_target_commit_hook() { :; }; motd_rollback_hook() { :; }
    motd_run_locked_operation install
    [[ ! -e "$MOTD_STATE_DIR/pending" ]] || fail "rollback hook retry left pending"
    assert_eq "$before" "$(target_hash "$root")" "rollback hook retry restores original group before next install"
)

for pointer_case in old-generation other-generation extra-line inode; do
(
    root="$TEST_DIR/pointer-hook-$pointer_case"; create_fixture "$root"; export_paths "$root"
    load_motd; motd_run_locked_operation install
    before=$(target_hash "$root"); old_pointer=$(cat "$MOTD_STATE_DIR/previous.current"); before_count=$(generation_count "$MOTD_STATE_DIR/generations")
    motd_snapshot_commit_hook() {
        local scope="$1" generation="$2" kind="$3" stage other source
        [[ "$scope" == previous && "$kind" == pointer ]] || return 0
        stage=${MOTD_POINTER_STAGE_PATHS[${#MOTD_POINTER_STAGE_PATHS[@]}-1]}
        case "$pointer_case" in
            old-generation) printf '%s\n' "$old_pointer" > "$stage" ;;
            other-generation)
                other=11111111111111111111111111111111; source="$MOTD_STATE_DIR/generations/$generation"
                cp -a "$source" "$MOTD_STATE_DIR/generations/$other"
                sed -i "s/^generation=.*/generation=$other/" "$MOTD_STATE_DIR/generations/$other/manifest"
                MOTD_NEW_GENERATIONS+=("$other")
                printf '%s\n' "$other" > "$stage"
                ;;
            extra-line) printf 'extra\n' >> "$stage" ;;
            inode) cp "$stage" "${stage}.replacement"; chmod 0600 "${stage}.replacement"; mv -Tf "${stage}.replacement" "$stage" ;;
        esac
    }
    assert_fail "pointer hook $pointer_case rejected" motd_run_locked_operation install
    assert_eq "$old_pointer" "$(cat "$MOTD_STATE_DIR/previous.current")" "pointer hook $pointer_case preserves pointer"
    assert_eq "$before" "$(target_hash "$root")" "pointer hook $pointer_case preserves targets"
    assert_eq "$before_count" "$(generation_count "$MOTD_STATE_DIR/generations")" "pointer hook $pointer_case preserves generation count"
    assert_no_motd_residue "$root"
)
done
