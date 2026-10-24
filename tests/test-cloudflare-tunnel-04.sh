#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/test-cloudflare-tunnel-common.sh"

for restore_object in key source current; do
    for restore_fault in partial wrong-content wrong-mode rename post-content post-mode; do
        (
            new_case
            trap - EXIT
            configure_repository || fail "restore fixture"
            begin_repository_transaction || fail "restore transaction"
            snapshot=$REPOSITORY_TRANSACTION_DIR
            printf historical > "$REPOSITORY_STATE_DIR/current.rollback"
            cp "$REPOSITORY_STATE_DIR/current.rollback" "$CASE_DIR/historical"
            case "$restore_object" in key) target=$KEYRING ;; source) target=$SOURCE_FILE ;; current) target=$REPOSITORY_STATE_DIR/current ;; esac
            cp "$target" "$CASE_DIR/pre-restore"
            : > "$CASE_DIR/attempts"
            repository_install_file() {
                printf '%s\n' "$2" >> "$CASE_DIR/attempts"
                if [[ "$2" == "$snapshot/old-$restore_object" ]]; then
                    case "$restore_fault" in
                        partial) printf partial > "$3"; return 1 ;;
                        wrong-content) command install -o 0 -g 0 -m "$1" "$2" "$3"; printf wrong > "$3"; return 0 ;;
                        wrong-mode) command install -o 0 -g 0 -m 0777 "$2" "$3"; return 0 ;;
                    esac
                fi
                command install -o 0 -g 0 -m "$1" "$2" "$3"
            }
            repository_rename() {
                if [[ "$2" == "$target" && "$1" == */.cloudflared-rollback.* ]]; then
                    [[ "$restore_fault" != rename ]] || return 1
                    command mv -fT -- "$1" "$2" || return 1
                    case "$restore_fault" in post-content) printf corrupt > "$2" ;; post-mode) chmod 0777 "$2" ;; esac
                    return 0
                fi
                command mv -fT -- "$1" "$2"
            }
            if rollback_repository_transaction injected > "$CASE_DIR/restore.log" 2>&1; then fail "restore fault accepted"; fi
            for item in key source current; do
                [[ -f "$REPOSITORY_TRANSACTION_DIR/old-$item" ]] || fail "backup lost $item"
                grep -Fxq "$snapshot/old-$item" "$CASE_DIR/attempts" || fail "restore skipped $item"
            done
            case "$restore_fault" in partial|wrong-content|wrong-mode|rename) cmp "$target" "$CASE_DIR/pre-restore" || fail "invalid stage published" ;; esac
            cmp "$REPOSITORY_STATE_DIR/current.rollback" "$CASE_DIR/historical" || fail "historical rollback touched"
            if grep -q '旧 key/source 已恢复' "$CASE_DIR/restore.log"; then fail "false recovery success"; fi
            grep -q '回滚不完整' "$CASE_DIR/restore.log" || fail "missing failure diagnosis"
            acquire_repository_lock || fail "restore lock retained"
            release_repository_lock || fail "restore lock release"
        ) > "$TEST_DIR/publish-$restore_object-$restore_fault.log" 2>&1 || {
            cat "$TEST_DIR/publish-$restore_object-$restore_fault.log"
            fail "restore publish $restore_object $restore_fault"
        }
        pass "repository restore $restore_object $restore_fault rejects corruption and retains all backups"
    done
done

for operation in install_cloudflared upgrade_cloudflared; do
    (
        new_case
        trap - EXIT
        cp "$CASE_DIR/bin/cloudflared" "$APT_BIN"
        dpkg-query() { [[ "$*" == *'db:Status-Status'* ]] && { printf installed; return 0; }; return 1; }
        timer_enabled=true
        systemctl() {
            printf 'systemctl:%s\n' "$*" >> "$FAKE_LOG"
            if [[ "$*" == *cloudflared-apt-update.timer* && ( "$1" == is-enabled || "$1" == is-active ) ]]; then
                [[ "$timer_enabled" == true ]]
            else
                return 0
            fi
        }
        write_auto_update_files || fail "timer fixture"
        auto_update_file_is_managed "$AUTO_UPDATE_SCRIPT" || fail "main script template rejected"
        auto_update_file_is_managed "$AUTO_UPDATE_SERVICE" || fail "main service template rejected"
        auto_update_file_is_managed "$AUTO_UPDATE_TIMER" || fail "main timer template rejected"
        "$operation" || fail "enabled operation"
        [[ "$PRESERVE_AUTO_UPDATE" == true ]] || fail "strategy reset by init"
        grep -Fxq 'systemctl:enable --now cloudflared-apt-update.timer' "$FAKE_LOG" || fail "timer not enabled"
        timer_enabled=false
        : > "$FAKE_LOG"
        "$operation" || fail "disabled operation"
        [[ "$PRESERVE_AUTO_UPDATE" == false ]] || fail "strategy leaked between operations"
        if grep -Fxq 'systemctl:enable --now cloudflared-apt-update.timer' "$FAKE_LOG"; then fail "disabled timer enabled"; fi
        timer_enabled=true
        export FAKE_APT_UPDATE_FAIL=1
        : > "$FAKE_LOG"
        if "$operation"; then fail "repository failure ignored"; fi
        if grep -Eq 'systemctl:(disable|stop|enable|daemon-reload)' "$FAKE_LOG"; then fail "repository failure continued lifecycle"; fi
    ) > "$TEST_DIR/policy-$operation.log" 2>&1 || {
        cat "$TEST_DIR/policy-$operation.log"
        fail "policy $operation"
    }
    pass "policy $operation preserves enabled main timer without cross-operation leakage"
done

(
    new_case
    trap - EXIT
    write_auto_update_files || fail "template fixture"
    printf '# changed\n' >> "$AUTO_UPDATE_TIMER"
    if auto_update_file_is_managed "$AUTO_UPDATE_TIMER"; then fail "partial marker trusted"; fi
    cp "$AUTO_UPDATE_TIMER" "$CASE_DIR/foreign-timer"
    if disable_auto_update --confirmed; then fail "unknown timer deleted"; fi
    cmp "$AUTO_UPDATE_TIMER" "$CASE_DIR/foreign-timer" || fail "unknown timer changed"
) || fail "strict main template"
pass "main updater templates reject extra content without deleting unknown files"

(
    new_case
    trap - EXIT
    begin_repository_transaction || fail "absent transaction"
    mv "$SOURCE_FILE" "$CASE_DIR/owned-source"
    printf foreign > "$SOURCE_FILE"; chmod 0644 "$SOURCE_FILE"
    if rollback_repository_transaction foreign; then fail "foreign absent accepted"; fi
    [[ "$(cat "$SOURCE_FILE")" == foreign ]] || fail "foreign absent deleted"
    [[ -f "$REPOSITORY_TRANSACTION_DIR/pending" ]] || fail "rollback pending missing"
    : > "$FAKE_LOG"
    if configure_repository; then fail "pending allowed restart"; fi
    [[ ! -s "$FAKE_LOG" ]] || fail "pending performed external work"
) || fail "absent ownership"
pass "repository absent foreign object survives rollback and blocks restart"

(
    new_case
    trap - EXIT
    acquire_repository_lock || fail "lock fixture"
    release_repository_lock || fail "first release"
    mkdir "$CLOUDFLARED_STATE_DIR.lock"
    release_repository_lock || fail "idempotent release"
    [[ -d "$CLOUDFLARED_STATE_DIR.lock" ]] || fail "released another operation lock"
) || fail "lock identity"
pass "repeated lock release preserves next operation lock"

(
    new_case
    trap - EXIT
    set_old_generation
    mkdir -p "$STATE_DIR"
    chmod 0700 "$STATE_DIR"
    printf unknown > "$STATE_DIR/repository-managed"
    chmod 0600 "$STATE_DIR/repository-managed"
    : > "$FAKE_LOG"
    if uninstall_cloudflared --confirmed; then fail "bad legacy marker accepted"; fi
    [[ ! -s "$FAKE_LOG" ]] || fail "legacy ownership checked after destructive operations"
) || fail "legacy preflight"
pass "legacy uninstall rejects unknown ownership before systemctl or APT"

for review_fault in timer-enable stage-identity trap-restore; do
    (
        new_case
        trap - EXIT
        case "$review_fault" in
            timer-enable)
                dpkg-query() { printf installed; }
                systemctl() {
                    printf '%s\n' "$*" >> "$FAKE_LOG"
                    [[ "$*" != 'enable --now cloudflared-apt-update.timer' ]]
                }
                if enable_auto_update > "$CASE_DIR/error.log" 2>&1; then fail "timer enable failure hidden"; fi
                grep -Fxq 'enable --now cloudflared-apt-update.timer' "$FAKE_LOG" || fail "timer injection not hit"
                ;;
            stage-identity)
                begin_repository_transaction || fail "stage fixture"
                stage=$(mktemp "$CASE_DIR/.stage.XXXXXX")
                repository_track_stage "$stage" || fail "track stage"
                mv "$stage" "$stage.owned"
                printf foreign > "$stage"
                if rollback_repository_transaction injected; then fail "foreign stage ignored"; fi
                [[ "$(cat "$stage")" == foreign ]] || fail "foreign stage deleted"
                ;;
            trap-restore)
                begin_repository_transaction || fail "trap fixture"
                restore_one_trap() { printf '%s\n' "$1" >> "$CASE_DIR/trap-attempts"; return 1; }
                if rollback_repository_transaction injected; then fail "trap failure hidden"; fi
                [[ "$(wc -l < "$CASE_DIR/trap-attempts")" == 4 ]] || fail "trap attempts skipped"
                [[ -f "$REPOSITORY_TRANSACTION_DIR/pending" ]] || fail "trap failure pending missing"
                ;;
        esac
    ) > "$TEST_DIR/review-$review_fault.log" 2>&1 || {
        cat "$TEST_DIR/review-$review_fault.log"
        fail "review $review_fault"
    }
    pass "review $review_fault injection reached and failure preserved"
done

for phase in disable-systemctl disable-backup disable-delete; do
    for fault in HUP INT TERM zero failure; do
        (
            new_case
            trap - EXIT
            configure_repository || fail "disable fixture"
            write_auto_update_files || fail "disable files"
            rc=0
            (
                trap - EXIT
                updater_transaction_hook() {
                    [[ "$1" == "$phase" ]] || return 0
                    case "$fault" in zero) exit 0 ;; failure) return 1 ;; *) kill -s "$fault" "$BASHPID" ;; esac
                }
                disable_auto_update --confirmed
            ) > "$CASE_DIR/disable.log" 2>&1 || rc=$?
            case "$fault" in HUP) expected=129 ;; INT) expected=130 ;; TERM) expected=143 ;; *) expected=1 ;; esac
            [[ "$rc" == "$expected" ]] || fail "disable exit $rc"
            [[ -f "$AUTO_UPDATE_SCRIPT" && -f "$AUTO_UPDATE_SERVICE" && -f "$AUTO_UPDATE_TIMER" ]] || fail "premature file deletion"
            compgen -G "$REPOSITORY_STATE_DIR/pending-updater-*" >/dev/null || fail "disable pending missing"
            grep -q '自动更新操作未完成' "$CASE_DIR/disable.log" || fail "disable diagnostic missing"
            acquire_repository_lock || fail "disable lock retained"
            release_repository_lock || fail "disable lock release"
        ) > "$TEST_DIR/disable-$phase-$fault.log" 2>&1 || {
            cat "$TEST_DIR/disable-$phase-$fault.log"
            fail "disable $phase $fault"
        }
        pass "independent disable $phase $fault preserves pending and exit contract"
    done
done

for phase in enable-validate enable-write enable-reload enable-timer disable-systemctl; do
    (
        new_case
        trap - EXIT
        configure_repository || fail "barrier configure"
        write_auto_update_files || fail "barrier files"
        mkfifo "$CASE_DIR/ready" "$CASE_DIR/release"
        (
            trap - EXIT
            dpkg-query() { printf installed; }
            updater_transaction_hook() {
                [[ "$1" == "$phase" ]] || return 0
                printf ready > "$CASE_DIR/ready"
                read -r _ < "$CASE_DIR/release"
            }
            if [[ "$phase" == disable-* ]]; then disable_auto_update --confirmed; else enable_auto_update; fi
        ) > "$CASE_DIR/holder.log" 2>&1 &
        holder=$!
        read -r ready < "$CASE_DIR/ready" || [[ "$ready" == ready ]] || fail "barrier readiness"
        for contender in enable_auto_update disable_auto_update uninstall_cloudflared; do
            if ( "$contender" --confirmed ) > "$CASE_DIR/contender.log" 2>&1; then fail "contender bypassed lock"; fi
        done
        printf 'release\n' > "$CASE_DIR/release"
        wait "$holder" || { cat "$CASE_DIR/holder.log"; fail "holder failed"; }
    ) > "$TEST_DIR/barrier-$phase.log" 2>&1 || { cat "$TEST_DIR/barrier-$phase.log"; fail "barrier $phase"; }
    pass "real updater barrier $phase excludes all competing mutation entrypoints"
done

for fault in backup delete release; do
    (
        new_case
        trap - EXIT
        configure_repository || fail "file fault fixture"
        write_auto_update_files || fail "file fault files"
        hit=false
        cp() {
            if [[ "$fault" == backup && "$*" == *auto-update-* ]]; then hit=true; return 1; fi
            command cp "$@"
        }
        rm() {
            if [[ "$fault" == delete && "$*" == *"$AUTO_UPDATE_SERVICE"* ]]; then hit=true; return 1; fi
            command rm "$@"
        }
        rmdir() {
            if [[ "$fault" == release ]]; then hit=true; return 1; fi
            command rmdir "$@"
        }
        before=$(trap -p HUP INT TERM EXIT)
        if disable_auto_update --confirmed > "$CASE_DIR/error.log" 2>&1; then fail "disable file fault accepted"; fi
        [[ "$hit" == true ]] || fail "file fault not hit"
        [[ "$(trap -p HUP INT TERM EXIT)" == "$before" ]] || fail "disable traps not restored"
        compgen -G "$REPOSITORY_STATE_DIR/pending-updater-*" >/dev/null || fail "file fault pending missing"
        case "$fault" in
            backup) [[ -f "$AUTO_UPDATE_SCRIPT" && -f "$AUTO_UPDATE_SERVICE" && -f "$AUTO_UPDATE_TIMER" ]] || fail "backup failure deleted files" ;;
            delete) [[ ! -e "$AUTO_UPDATE_SCRIPT" && -f "$AUTO_UPDATE_SERVICE" && -f "$AUTO_UPDATE_TIMER" ]] || fail "partial deletion group wrong" ;;
            release) [[ -d "$CLOUDFLARED_STATE_DIR.lock" ]] || fail "failed release lost lock" ;;
        esac
    ) > "$TEST_DIR/disable-file-$fault.log" 2>&1 || { cat "$TEST_DIR/disable-file-$fault.log"; fail "disable file $fault"; }
    pass "independent disable actual $fault failure retains group evidence and traps"
done

# Separate shells load the implementation independently; only file/FIFO state is shared.
(
    new_case
    trap - EXIT
    configure_repository || fail "uninstall barrier configure"
    write_auto_update_files || fail "uninstall barrier updater"
    mkfifo "$CASE_DIR/uninstall-ready" "$CASE_DIR/uninstall-release"
    bash -c '
        source "$1"
        check_platform() { :; }
        uninstall_transaction_hook() {
            [[ "$1" == after-snapshot-active ]] || return 0
            printf "%s\n" "$UNINSTALL_SNAPSHOT_DIR" > "$CASE_DIR/snapshot-path"
            printf "ready\n" > "$CASE_DIR/uninstall-ready"
            read -r _ < "$CASE_DIR/uninstall-release"
        }
        uninstall_cloudflared --confirmed
    ' _ "$ROOT_DIR/tools/cloudflare_tunnel.sh" > "$CASE_DIR/holder.log" 2>&1 &
    holder=$!
    # Timeout bounds a broken readiness handshake; no scheduling sleeps.
    timeout 30 bash -c 'read -r ready < "$CASE_DIR/uninstall-ready"; [[ "$ready" == ready ]]' || fail "uninstall never reached active snapshot"
    snapshot=$(cat "$CASE_DIR/snapshot-path")
    [[ -f "$snapshot/manifest" ]] || fail "snapshot not ready"
    lock_before=$(stat -c '%d:%i:%u:%g:%a' "$CLOUDFLARED_STATE_DIR.lock")
    find "$REPOSITORY_STATE_DIR" -type f -exec sha256sum {} + | sort > "$CASE_DIR/state-before"
    sha256sum "$AUTO_UPDATE_SCRIPT" "$AUTO_UPDATE_SERVICE" "$AUTO_UPDATE_TIMER" > "$CASE_DIR/updater-before"
    for contender in enable_auto_update disable_auto_update; do
        : > "$CASE_DIR/contender-external.log"
        rc=0
        FAKE_LOG="$CASE_DIR/contender-external.log" bash -c '
            source "$1"
            check_platform() { :; }
            "$2" --confirmed
        ' _ "$ROOT_DIR/tools/cloudflare_tunnel.sh" "$contender" > "$CASE_DIR/contender.log" 2>&1 || rc=$?
        [[ "$rc" != 0 ]] || fail "contender entered uninstall lock"
        grep -q '无法取得 Cloudflare 仓库事务锁' "$CASE_DIR/contender.log" || fail "competition not reached"
        [[ ! -s "$CASE_DIR/contender-external.log" ]] || fail "contender executed external command"
        [[ "$(stat -c '%d:%i:%u:%g:%a' "$CLOUDFLARED_STATE_DIR.lock")" == "$lock_before" ]] || fail "holder lock changed"
        find "$REPOSITORY_STATE_DIR" -type f -exec sha256sum {} + | sort > "$CASE_DIR/state-after"
        cmp "$CASE_DIR/state-before" "$CASE_DIR/state-after" || fail "snapshot or pending changed"
        sha256sum -c "$CASE_DIR/updater-before" >/dev/null || fail "contender changed updater"
    done
    printf 'release\n' > "$CASE_DIR/uninstall-release"
    wait "$holder" || { cat "$CASE_DIR/holder.log"; fail "uninstall holder failed"; }
    [[ ! -e "$SOURCE_FILE" && ! -e "$AUTO_UPDATE_TIMER" ]] || fail "uninstall did not complete"
    [[ ! -d "$CLOUDFLARED_STATE_DIR.lock" ]] || fail "uninstall retained lock"
) > "$TEST_DIR/uninstall-holder.log" 2>&1 || { cat "$TEST_DIR/uninstall-holder.log"; fail "uninstall holder barrier"; }
pass "independent uninstall holder excludes enable and disable without changing snapshot pending or lock"

for dependency_fault in update install; do
    (
        new_case
        trap - EXIT
        write_auto_update_files || fail "dependency updater fixture"
        sha256sum "$AUTO_UPDATE_SCRIPT" "$AUTO_UPDATE_SERVICE" "$AUTO_UPDATE_TIMER" > "$CASE_DIR/updater-before"
        command() {
            if [[ "$*" == '-v flock' ]]; then
                printf 'flock-missing\n' >> "$CASE_DIR/dependency-hits"
                return 1
            fi
            builtin command "$@"
        }
        dpkg-query() { printf installed; }
        apt-get() {
            printf 'apt-get:%s\n' "$*" >> "$FAKE_LOG"
            if [[ "$1" == update && "$dependency_fault" == update ]]; then return 41; fi
            if [[ "$*" == 'install -y util-linux' ]]; then return 42; fi
            return 0
        }
        trap ':' HUP
        before_traps=$(trap -p HUP INT TERM EXIT)
        rc=0
        enable_auto_update > "$CASE_DIR/dependency.log" 2>&1 || rc=$?
        case "$dependency_fault" in update) expected=41 ;; install) expected=42 ;; esac
        [[ "$rc" == "$expected" ]] || fail "dependency status $rc"
        grep -Fxq flock-missing "$CASE_DIR/dependency-hits" || fail "flock branch not reached"
        grep -Fxq apt-get:update "$FAKE_LOG" || fail "dependency update not reached"
        if [[ "$dependency_fault" == update ]]; then
            if grep -q 'apt-get:install' "$FAKE_LOG"; then fail "install continued after update failure"; fi
        else
            grep -Fxq 'apt-get:install -y util-linux' "$FAKE_LOG" || fail "util install not reached"
        fi
        if grep -Eq 'systemctl:.*(reload|enable)' "$FAKE_LOG"; then fail "dependency failure continued timer work"; fi
        sha256sum -c "$CASE_DIR/updater-before" >/dev/null || fail "dependency failure changed updater"
        validate_current_repository_manifest || fail "prior repository configuration not recorded"
        compgen -G "$REPOSITORY_STATE_DIR/pending-updater-*" >/dev/null || fail "dependency pending missing"
        [[ ! -d "$CLOUDFLARED_STATE_DIR.lock" ]] || fail "dependency lock retained"
        [[ "$(trap -p HUP INT TERM EXIT)" == "$before_traps" ]] || fail "dependency traps changed"
        grep -q '自动更新操作未完成' "$CASE_DIR/dependency.log" || fail "dependency diagnostic missing"
    ) > "$TEST_DIR/dependency-$dependency_fault.log" 2>&1 || { cat "$TEST_DIR/dependency-$dependency_fault.log"; fail "dependency $dependency_fault"; }
    pass "missing flock $dependency_fault failure stops updater after recorded repository commit"
done

entrypoint_output=$(bash -c "$(cat "$ROOT_DIR/tools/cloudflare_tunnel.sh")" cloudflare_tunnel.sh help)
grep -Fq 'cloudflare_tunnel.sh install' <<< "$entrypoint_output" || fail "bash -c entrypoint broken"
pass "bash -c entrypoint remains compatible"

printf 'All cloudflare wrapper tests passed. PASS=%d\n' "$pass_count"
