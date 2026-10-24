#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/test-cloudflare-tunnel-common.sh"

pass "active uninstall exit 0 returns 1 and cleans transaction"

for manifest_case in missing duplicate unknown generation key-digest source-digest source-content symlink directory fifo owner gid mode; do
    new_case
    set_old_generation
    configure_repository
    current="$CLOUDFLARED_REPOSITORY_STATE_DIR/current"
    case "$manifest_case" in
        missing) sed -i '/^source_sha256=/d' "$current" ;;
        duplicate) cat "$current" >> "$current.copy"; cat "$current.copy" >> "$current"; rm "$current.copy" ;;
        unknown) printf 'unknown=value\n' >> "$current" ;;
        generation) sed -i 's/^generation=.*/generation=invalid/' "$current" ;;
        key-digest) sed -i 's/^key_sha256=.*/key_sha256=0000000000000000000000000000000000000000000000000000000000000000/' "$current" ;;
        source-digest) sed -i 's/^source_sha256=.*/source_sha256=0000000000000000000000000000000000000000000000000000000000000000/' "$current" ;;
        source-content) printf '# tampered\n' >> "$CLOUDFLARED_SOURCE_FILE" ;;
        symlink) rm "$current"; ln -s "$CASE_DIR/external" "$current"; printf external > "$CASE_DIR/external" ;;
        directory) rm "$current"; mkdir "$current" ;;
        fifo) rm "$current"; mkfifo "$current" ;;
        owner) chown 65534:0 "$current" ;;
        gid) chown 0:65534 "$current" ;;
        mode) chmod 0644 "$current" ;;
    esac
    if remove_managed_repository >/dev/null 2>&1; then fail "current $manifest_case unexpectedly trusted"; fi
    [[ -f "$CLOUDFLARED_KEYRING" ]] || fail "current $manifest_case deleted keyring"
    [[ -e "$CLOUDFLARED_SOURCE_FILE" ]] || fail "current $manifest_case deleted source"
    [[ ! -e "$CASE_DIR/external" || "$(cat "$CASE_DIR/external")" == external ]] || fail "current symlink target changed"
    [[ ! -d "$CLOUDFLARED_STATE_DIR.lock" ]] || fail "current $manifest_case left lock"
    pass "current manifest rejects $manifest_case"
done

new_case
set_old_generation
export FAKE_APT_INSTALL_FAIL=1
if run_repository_apt_transaction install >/dev/null 2>&1; then fail "old generation rollback test succeeded"; fi
assert_old_generation
pass "old key/source preserved on transaction failure"

new_case
run_repository_apt_transaction install
grep -Fxq 'apt-get:update' "$FAKE_LOG" || fail "APT probe not called"
grep -Fxq 'apt-get:install -y cloudflared' "$FAKE_LOG" || fail "cloudflared package selection changed"
if grep -Eqi 'remove|purge|autoremove|linux-image|linux-headers' "$FAKE_LOG"; then
    fail "repository transaction performed unrelated APT changes"
fi
pass "no kernel deletion or unrelated APT change"

script_hashes_before=$(sha256sum "$ROOT_DIR/linux_setup.sh" "$ROOT_DIR"/modules/*.sh "$ROOT_DIR"/tools/push.sh \
    "$ROOT_DIR"/tools/setup-motd.sh "$ROOT_DIR"/tools/xanmod-install.sh)
script_hashes_after=$(sha256sum "$ROOT_DIR/linux_setup.sh" "$ROOT_DIR"/modules/*.sh "$ROOT_DIR"/tools/push.sh \
    "$ROOT_DIR"/tools/setup-motd.sh "$ROOT_DIR"/tools/xanmod-install.sh)
[[ "$script_hashes_before" == "$script_hashes_after" ]] || fail "payload or unrelated scripts changed during tests"
pass "payload and unrelated scripts remain unchanged"

# Keep prior lifecycle coverage with fake systemctl only.
new_case
cat > "$CLOUDFLARED_SERVICE_FILE" <<EOF
[Service]
ExecStart=$CLOUDFLARED_LEGACY_BIN --no-autoupdate --token-file /etc/cloudflared/token
EOF
cat > "$CLOUDFLARED_LEGACY_BIN" <<'EOF'
#!/usr/bin/env bash
echo 'cloudflared version 2025.1.0'
EOF
chmod 0755 "$CLOUDFLARED_LEGACY_BIN"
migrate_legacy_binary
assert_absent "$CLOUDFLARED_LEGACY_BIN" "recognized legacy binary was not migrated"
grep -Fq "ExecStart=$CLOUDFLARED_APT_BIN --no-autoupdate --token-file /etc/cloudflared/token" "$CLOUDFLARED_SERVICE_FILE" ||
    fail "legacy service path was not preserved"
pass "legacy binary and service migration behavior remains"


# Each malformed snapshot runs in a separate process: transaction traps and
# intentional corrupt fixtures must not leak into subsequent cases.
for schema_case in version generation duplicate unknown order state mode uid gid digest created payload-name payload-missing payload-extra payload-fifo payload-symlink manifest-fifo ancestor; do
    (
        new_case
        configure_repository || fail "schema fixture configure"
        acquire_repository_lock || fail "schema fixture lock"
        begin_uninstall_transaction || fail "schema fixture capture"
        manifest="$UNINSTALL_SNAPSHOT_DIR/manifest"
        case "$schema_case" in
            version) sed -i '1d' "$manifest" ;;
            generation) sed -i '2s/.*/generation=20000101T000000Z-1-1/' "$manifest" ;;
            duplicate) sed -i '3s/.*/version=1/' "$manifest" ;;
            unknown) sed -i '10s/.*/path=\/tmp\/forbidden/' "$manifest" ;;
            order) sed -i '3s/auto_update_script/auto_update_timer/' "$manifest" ;;
            state) sed -i '4s/.*/state=invalid/' "$manifest" ;;
            mode) sed -i '5s/.*/mode=777/' "$manifest" ;;
            uid) sed -i '6s/.*/uid=1/' "$manifest" ;;
            gid) sed -i '7s/.*/gid=1/' "$manifest" ;;
            digest) sed -i '8s/.*/sha256=invalid/' "$manifest" ;;
            created) sed -i '0,/^transaction_created=false$/s//transaction_created=invalid/' "$manifest" ;;
            payload-name) sed -i 's/^snapshot=target-source$/snapshot=target-current/' "$manifest" ;;
            payload-missing) rm -- "$UNINSTALL_SNAPSHOT_DIR/files/target-source" ;;
            payload-extra) printf extra > "$UNINSTALL_SNAPSHOT_DIR/files/target-extra"; chmod 600 "$UNINSTALL_SNAPSHOT_DIR/files/target-extra" ;;
            payload-fifo) mkfifo "$UNINSTALL_SNAPSHOT_DIR/files/.fifo" ;;
            payload-symlink) ln -s target-source "$UNINSTALL_SNAPSHOT_DIR/files/.link" ;;
            manifest-fifo) rm -- "$manifest"; mkfifo "$manifest" ;;
            ancestor) chmod 0777 "$UNINSTALL_SNAPSHOT_DIR/files" ;;
        esac
        if uninstall_manifest_valid "$manifest"; then fail "schema accepted $schema_case"; fi
        # No rollback is appropriate for this read-only parser test.
        UNINSTALL_TRANSACTION_ACTIVE=false
        UNINSTALL_SNAPSHOT_BUILDING=false
        UNINSTALL_TRANSACTION_STATE=NONE
        restore_repository_traps
        # Parent alone owns TEST_DIR cleanup; do not run its EXIT trap here.
        trap - EXIT
        release_repository_lock || fail "schema fixture release"
    ) > "$TEST_DIR/schema-$schema_case.log" 2>&1 || fail "schema $schema_case (see $TEST_DIR/schema-$schema_case.log)"
    pass "uninstall manifest rejects $schema_case"
done


for ownership_case in owned foreign inode mode owner gid symlink directory fifo; do
    (
        new_case
        uninstall_transaction_hook() { :; }
        trap - EXIT
        configure_repository || fail "ownership configure"
        acquire_repository_lock || fail "ownership lock"
        begin_uninstall_transaction || fail "ownership capture"
        target="$AUTO_UPDATE_SCRIPT"
        printf 'owned-content\n' > "$CASE_DIR/payload"
        chmod 0600 "$CASE_DIR/payload"
        if [[ "$ownership_case" == foreign ]]; then
            printf foreign > "$target"
            chmod 0755 "$target"
        else
            uninstall_create_absent_target auto_update_script "$CASE_DIR/payload" || fail "exclusive creation"
            case "$ownership_case" in
                inode) mv "$target" "$target.original"; cp "$target.original" "$target" ;;
                mode) chmod 0644 "$target" ;;
                owner) chown 65534:0 "$target" ;;
                gid) chown 0:65534 "$target" ;;
                symlink) rm "$target"; ln -s "$CASE_DIR/payload" "$target" ;;
                directory) rm "$target"; mkdir "$target" ;;
                fifo) rm "$target"; mkfifo "$target" ;;
            esac
        fi
        if [[ "$ownership_case" == owned ]]; then
            uninstall_cleanup ownership-test || fail "owned rollback"
            assert_absent "$target" "owned file survived"
        else
            if uninstall_cleanup ownership-test; then fail "foreign identity accepted"; fi
            [[ -e "$target" || -L "$target" ]] || fail "foreign object deleted"
            [[ -f "$UNINSTALL_SNAPSHOT_DIR/manifest" ]] || fail "manifest lost"
            [[ -f "$UNINSTALL_SNAPSHOT_DIR/files/target-source" ]] || fail "payload lost"
        fi
        trap - EXIT
    ) > "$TEST_DIR/ownership-$ownership_case.log" 2>&1 || { cat "$TEST_DIR/ownership-$ownership_case.log"; fail "ownership $ownership_case"; }
    pass "absent ownership $ownership_case"
done

for journal_case in generation duplicate state unknown reason; do
    (
        new_case
        trap - EXIT
        uninstall_transaction_hook() { :; }
        configure_repository || fail "journal configure"
        acquire_repository_lock || fail "journal lock"
        begin_uninstall_transaction || fail "journal capture"
        journal="$UNINSTALL_SNAPSHOT_DIR/journal"
        case "$journal_case" in
            generation) sed -i '2s/.*/generation=wrong/' "$journal" ;;
            duplicate) printf 'state=ACTIVE\n' >> "$journal" ;;
            state) sed -i '3s/.*/state=COMMITTED/' "$journal" ;;
            unknown) sed -i '1s/.*/unknown=1/' "$journal" ;;
            reason) sed -i '4s/.*/path=invalid/' "$journal" ;;
        esac
        if uninstall_journal_valid "$journal" ACTIVE; then fail "bad journal accepted"; fi
        UNINSTALL_TRANSACTION_STATE=FAILED
        UNINSTALL_TRANSACTION_ACTIVE=false
        UNINSTALL_SNAPSHOT_BUILDING=false
        restore_repository_traps
        release_repository_lock || fail "journal release"
    ) > "$TEST_DIR/journal-$journal_case.log" 2>&1 || fail "journal $journal_case"
    pass "journal rejects $journal_case"
done

for finalization_case in journal archive release restore; do
    (
        new_case
        trap - EXIT
        uninstall_transaction_hook() { :; }
        configure_repository || fail "finalization configure"
        acquire_repository_lock || fail "finalization lock"
        begin_uninstall_transaction || fail "finalization capture"
        snapshot_before="$UNINSTALL_SNAPSHOT_DIR"
        case "$finalization_case" in
            journal|archive)
                repository_rename() {
                    if [[ "$finalization_case" == journal && "$2" == */journal ]] ||
                       [[ "$finalization_case" == archive && "$1" == "$snapshot_before" ]]; then return 1; fi
                    command mv -fT -- "$1" "$2"
                }
                ;;
            release)
                # A nonempty lock is an actual rmdir failure, not a core stub.
                printf retained > "$REPOSITORY_LOCK_DIR/injected"
                ;;
            restore)
                repository_install_file() {
                    [[ "$2" != */target-source ]] || return 1
                    command install -o 0 -g 0 -m "$1" -- "$2" "$3"
                }
                ;;
        esac
        if uninstall_cleanup "injected-$finalization_case"; then fail "finalization failure accepted"; fi
        [[ "$UNINSTALL_TRANSACTION_STATE" == FAILED ]] || fail "failed guard state"
        [[ "$UNINSTALL_TRANSACTION_ACTIVE" == false ]] || fail "active guard survived"
        [[ -f "$UNINSTALL_SNAPSHOT_DIR/manifest" ]] || fail "manifest deleted"
        [[ -f "$UNINSTALL_SNAPSHOT_DIR/files/target-source" ]] || fail "source payload deleted"
        [[ -f "$UNINSTALL_SNAPSHOT_DIR/files/target-current" ]] || fail "current payload deleted"
        cmp "$SOURCE_FILE" "$UNINSTALL_SNAPSHOT_DIR/files/target-source" || fail "source changed"
        [[ -f "$KEYRING" ]] || fail "keyring deleted"
        if [[ "$finalization_case" == release ]]; then
            [[ -d "$CLOUDFLARED_STATE_DIR.lock" ]] || fail "lock evidence missing"
        fi
    ) > "$TEST_DIR/finalization-$finalization_case.log" 2>&1 || {
        cat "$TEST_DIR/finalization-$finalization_case.log"
        fail "finalization $finalization_case"
    }
    pass "finalization $finalization_case failure preserves complete evidence"
done

for capture_id in auto_update_script auto_update_timer legacy_marker; do
    (
        new_case
        trap - EXIT
        configure_repository || fail "capture configure"
        cp "$SOURCE_FILE" "$CASE_DIR/source-before"
        cp "$KEYRING" "$CASE_DIR/key-before"
        acquire_repository_lock || fail "capture lock"
        uninstall_transaction_hook() { [[ "$1" != "capture-$capture_id" ]]; }
        if begin_uninstall_transaction; then fail "capture fault ignored"; fi
        [[ "$UNINSTALL_TRANSACTION_STATE" == BUILDING ]] || fail "partial capture activated"
        if uninstall_cleanup capture-failed; then fail "partial capture reported recovery"; fi
        cmp "$SOURCE_FILE" "$CASE_DIR/source-before" || fail "partial source changed"
        cmp "$KEYRING" "$CASE_DIR/key-before" || fail "partial key changed"
        [[ -f "$UNINSTALL_SNAPSHOT_DIR/journal" ]] || fail "partial journal missing"
        [[ "$UNINSTALL_TRANSACTION_ACTIVE" == false ]] || fail "partial guard active"
    ) > "$TEST_DIR/capture-$capture_id.log" 2>&1 || {
        cat "$TEST_DIR/capture-$capture_id.log"
        fail "capture $capture_id"
    }
    pass "capture failure $capture_id retains partial evidence without restoration"
done

for archive_case in intact payload journal; do
    (
        new_case
        trap - EXIT
        uninstall_transaction_hook() { :; }
        configure_repository || fail "archive configure"
        acquire_repository_lock || fail "archive lock"
        begin_uninstall_transaction || fail "archive capture"
        uninstall_transaction_hook() {
            [[ "$1" == after-evidence-rename ]] || return 0
            case "$archive_case" in
                payload) printf corrupt >> "$UNINSTALL_SNAPSHOT_DIR/files/target-source" ;;
                journal) printf 'unknown=1\n' >> "$UNINSTALL_SNAPSHOT_DIR/journal" ;;
            esac
            return 0
        }
        rc=0
        uninstall_cleanup archive-verification || rc=$?
        if [[ "$archive_case" == intact ]]; then
            [[ "$rc" == 0 && "$UNINSTALL_TRANSACTION_STATE" == ROLLED_BACK ]] || fail "valid archive rejected"
        else
            [[ "$rc" != 0 && "$UNINSTALL_TRANSACTION_STATE" == FAILED ]] || fail "corrupt archive accepted"
        fi
        [[ -f "$UNINSTALL_SNAPSHOT_DIR/manifest" && -f "$UNINSTALL_SNAPSHOT_DIR/journal" ]] || fail "archive evidence lost"
        [[ -f "$UNINSTALL_SNAPSHOT_DIR/files/target-current" ]] || fail "archive payload lost"
    ) > "$TEST_DIR/archive-$archive_case.log" 2>&1 || {
        cat "$TEST_DIR/archive-$archive_case.log"
        fail "archive $archive_case"
    }
    pass "post-rename archive verification $archive_case"
done

for interrupted_phase in before-snapshot-create after-snapshot-active after-evidence-rename after-evidence-seal before-pending-clear; do
    (
        new_case
        trap - EXIT
        configure_repository || fail "kill configure"
        cp "$SOURCE_FILE" "$CASE_DIR/source-before"
        (
            trap - EXIT
            acquire_repository_lock || exit 1
            uninstall_transaction_hook() {
                if [[ "$1" == "$interrupted_phase" ]]; then kill -KILL "$BASHPID"; fi
            }
            begin_uninstall_transaction || exit 1
            uninstall_cleanup kill-test
        ) > "$CASE_DIR/killed.log" 2>&1 &
        child=$!
        rc=0
        wait "$child" || rc=$?
        [[ "$rc" == 137 ]] || fail "SIGKILL did not reach $interrupted_phase"
        # Simulate operator removing only the stale lock; pending must still block.
        rmdir "$CLOUDFLARED_STATE_DIR.lock" || fail "stale lock remove"
        : > "$FAKE_LOG"
        for operation in install_cloudflared upgrade_cloudflared uninstall_cloudflared disable_auto_update; do
            (
                trap - EXIT
                "$operation" --confirmed
            ) > "$CASE_DIR/retry-$operation.log" 2>&1 && fail "pending allowed $operation"
        done
        [[ ! -s "$FAKE_LOG" ]] || fail "pending executed external command"
        cmp "$SOURCE_FILE" "$CASE_DIR/source-before" || fail "pending changed source"
        compgen -G "$CLOUDFLARED_STATE_DIR/repository/pending-uninstall-*" >/dev/null || fail "pending evidence missing"
    ) > "$TEST_DIR/kill-$interrupted_phase.log" 2>&1 || {
        cat "$TEST_DIR/kill-$interrupted_phase.log"
        fail "SIGKILL $interrupted_phase"
    }
    pass "SIGKILL $interrupted_phase fails closed in independent entrypoints"
done

for stage_case in owned foreign; do
    (
        new_case
        trap - EXIT
        configure_repository || fail "stage configure"
        acquire_repository_lock || fail "stage lock"
        begin_uninstall_transaction || fail "stage capture"
        stage=$(mktemp "$CASE_DIR/root/.cloudflared-create.XXXXXX")
        uninstall_register_stage "$stage" || fail "stage register"
        if [[ "$stage_case" == foreign ]]; then
            mv "$stage" "$stage.original"
            printf foreign > "$stage"
        fi
        rc=0
        uninstall_cleanup stage-test || rc=$?
        if [[ "$stage_case" == owned ]]; then
            [[ "$rc" == 0 && ! -e "$stage" ]] || fail "owned stage not cleaned"
            [[ "$(stat -c %a "$UNINSTALL_SNAPSHOT_DIR")" == 500 ]] || fail "archive writable"
            [[ "$(stat -c %a "$UNINSTALL_SNAPSHOT_DIR/manifest")" == 400 ]] || fail "manifest writable"
            validate_uninstall_archive "$UNINSTALL_SNAPSHOT_DIR" "$UNINSTALL_GENERATION" || fail "sealed archive invalid"
        else
            [[ "$rc" != 0 && "$(cat "$stage")" == foreign ]] || fail "foreign stage removed"
            [[ -f "$UNINSTALL_PENDING" ]] || fail "stage failure lost pending"
        fi
    ) > "$TEST_DIR/stage-$stage_case.log" 2>&1 || {
        cat "$TEST_DIR/stage-$stage_case.log"
        fail "stage $stage_case"
    }
    pass "stage cleanup verifies $stage_case identity"
done

for terminal_signal in HUP INT TERM; do
    case "$terminal_signal" in HUP) expected=129 ;; INT) expected=130 ;; TERM) expected=143 ;; esac
    (
        new_case
        trap - EXIT
        configure_repository || fail "terminal signal configure"
        rc=0
        (
            trap - EXIT
            acquire_repository_lock || exit 1
            uninstall_transaction_hook() {
                if [[ "$1" == after-evidence-seal ]]; then kill -s "$terminal_signal" "$BASHPID"; fi
            }
            begin_uninstall_transaction || exit 1
            uninstall_cleanup terminal-signal
        ) > "$CASE_DIR/signal.log" 2>&1 || rc=$?
        [[ "$rc" == "$expected" ]] || fail "terminal signal status $rc"
        [[ ! -d "$CLOUDFLARED_STATE_DIR.lock" ]] || fail "terminal signal lock retained"
        compgen -G "$CLOUDFLARED_STATE_DIR/repository/pending-uninstall-*" >/dev/null || fail "terminal signal pending missing"
        [[ -f "$SOURCE_FILE" ]] || fail "terminal signal source lost"
    ) > "$TEST_DIR/terminal-$terminal_signal.log" 2>&1 || {
        cat "$TEST_DIR/terminal-$terminal_signal.log"
        fail "terminal signal $terminal_signal"
    }
    pass "terminal $terminal_signal=$expected retains evidence without repeated rollback"
done
