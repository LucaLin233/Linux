#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/test-cloudflare-tunnel-common.sh"
pass "source rendering has zero side effects and exact fields"

(
    new_case
    source_cwd=$PWD
    source_before=$(find "$CASE_DIR/root" -mindepth 1 -printf '%P %y %m\n' | sort)
    cloudflare_tunnel_source() { printf 'sentinel:%s\n' "$*"; }
    sentinel_before=$(declare -f cloudflare_tunnel_source)
    trap 'sentinel-trap' HUP
    set -o noclobber
    umask 027
    unset CLOUDFLARED_TEST_INTERNALS
    source "$ROOT_DIR/tools/cloudflare_tunnel.sh"
    sentinel_after=$(declare -f cloudflare_tunnel_source)
    [[ "$sentinel_before" == "$sentinel_after" ]] || fail "ordinary source replaced sentinel function"
    [[ "$(cloudflare_tunnel_source probe)" == sentinel:probe ]] || fail "ordinary source changed sentinel behavior"
    [[ "$(trap -p HUP)" == *sentinel-trap* ]] || fail "ordinary source changed caller trap"
    [[ "$-" == *C* ]] || fail "ordinary source changed caller shell options"
    [[ "$(umask)" == 0027 ]] || fail "ordinary source changed caller umask"
    [[ "$PWD" == "$source_cwd" ]] || fail "ordinary source changed caller cwd"
    [[ "${CLOUDFLARED_STATE_DIR+x}" == x ]] || fail "test setup lost state variable"
    after=$(find "$CASE_DIR/root" -mindepth 1 -printf '%P %y %m\n' | sort)
    [[ "$source_before" == "$after" ]] || fail "ordinary source changed filesystem"
)
pass "ordinary source preserves sentinels, shell state, and filesystem"

new_case
before=$(find "$CASE_DIR/root" -mindepth 1 -printf '%P %y %m\\n' | sort)
bash "$ROOT_DIR/tools/cloudflare_tunnel.sh" status >/dev/null 2>&1 || fail "standalone status failed in fake environment"
after=$(find "$CASE_DIR/root" -mindepth 1 -printf '%P %y %m\\n' | sort)
[[ "$before" == "$after" ]] || fail "ordinary status created state, lock, or temp files"
pass "ordinary help/status paths have zero state and lock side effects"

cat > "$TEST_DIR/source-contract.sh" <<EOF
#!/usr/bin/env bash
set +e
set +u
set +o pipefail
set -o noclobber
umask 027
cd $(printf '%q' "$TEST_DIR")
unset CLOUDFLARED_TEST_INTERNALS
trap 'true' HUP
trap 'true' INT
trap 'true' TERM
trap 'true' EXIT
sentinel=unchanged
cloudflare_tunnel_source() { printf 'sentinel\\n'; }
before_options=\$(set +o)
before_traps=\$(trap -p HUP INT TERM EXIT)
before_functions=\$(declare -F | sort)
before_function=\$(declare -f cloudflare_tunnel_source)
before_files=\$(find . -mindepth 1 -printf '%P %y %m\\n' | sort)
source $(printf '%q' "$ROOT_DIR/tools/cloudflare_tunnel.sh")
[[ \$(set +o) == "\$before_options" ]] || exit 1
[[ \$(trap -p HUP INT TERM EXIT) == "\$before_traps" ]] || exit 1
[[ \$(declare -F | sort) == "\$before_functions" ]] || exit 1
[[ \$(declare -f cloudflare_tunnel_source) == "\$before_function" ]] || exit 1
[[ \$(cloudflare_tunnel_source) == sentinel ]] || exit 1
[[ \$sentinel == unchanged && \$PWD == $(printf '%q' "$TEST_DIR") && \$(umask) == 0027 ]] || exit 1
[[ \$(find . -mindepth 1 -printf '%P %y %m\\n' | sort) == "\$before_files" ]] || exit 1
EOF
bash "$TEST_DIR/source-contract.sh" || fail "ordinary source independent subprocess contract failed"
pass "ordinary source independent subprocess preserves full shell contract"

CLOUDFLARED_TEST_INTERNALS=1 bash -c 'source "$1"; declare -F configure_repository >/dev/null' _ \
    "$ROOT_DIR/tools/cloudflare_tunnel.sh" || fail "internal source mode unavailable"
pass "explicit internal source mode exposes test functions"

new_case
configure_repository || fail "configure before real uninstall failed"
require_root() { :; }
check_platform() { :; }
uninstall_cloudflared --confirmed || fail "uninstall normal path failed"
[[ ! -d "$CLOUDFLARED_STATE_DIR.lock" ]] || fail "uninstall left repository lock"
grep -Fxq 'apt-get:remove -y cloudflared' "$FAKE_LOG" || fail "uninstall skipped package removal"
assert_absent "$CLOUDFLARED_SOURCE_FILE" "real uninstall retained source"
assert_absent "$CLOUDFLARED_REPOSITORY_STATE_DIR/current" "real uninstall retained current"
[[ -f "$CLOUDFLARED_KEYRING" ]] || fail "real uninstall removed keyring"
pass "configure then real uninstall preserves keyring and releases lock"
init_runtime_config

new_case
mkdir -p "$CLOUDFLARED_STATE_DIR.lock"
mkdir -p "$CLOUDFLARED_AUTO_UPDATE_SCRIPT"
printf marker > "$CASE_DIR/marker"
require_root() { :; }
check_platform() { :; }
if uninstall_cloudflared --confirmed >/dev/null 2>&1; then fail "uninstall lock competition unexpectedly succeeded"; fi
[[ -d "$CLOUDFLARED_STATE_DIR.lock" ]] || fail "uninstall lock competition removed lock"
[[ -d "$CLOUDFLARED_AUTO_UPDATE_SCRIPT" ]] || fail "lock competition touched auto-update path"
! grep -Eq 'remove|disable|daemon-reload|apt-get:' "$FAKE_LOG" || fail "lock competition performed mutation"
pass "uninstall lock competition fails before auto-update, systemctl, and APT"

new_case
mkdir -p "$CLOUDFLARED_STATE_DIR.lock"
if disable_auto_update --confirmed >/dev/null 2>&1; then fail "disable-auto-update lock competition unexpectedly succeeded"; fi
[[ -d "$CLOUDFLARED_STATE_DIR.lock" ]] || fail "disable-auto-update removed competing lock"
pass "auto-update lock competition fails before state mutation"
chmod 0700 "$CLOUDFLARED_STATE_DIR.lock"
if configure_repository >/dev/null 2>&1; then fail "lock competition unexpectedly succeeded"; fi
pass "key/source lock competition"

run_failure_case "key URL download failure" 'export FAKE_CURL_FAIL=1'
run_failure_case "gpg parser failure" 'export FAKE_GPG_FAIL=1'
run_failure_case "fingerprint mismatch" 'export FAKE_GPG_CASE=fingerprint'
run_failure_case "UID mismatch" 'export FAKE_GPG_CASE=uid'
run_failure_case "multiple primary keys" 'export FAKE_GPG_CASE=multi'

for target in key source; do
    for kind in symlink directory; do
        new_case
        case "$target" in key) path=$CLOUDFLARED_KEYRING ;; source) path=$CLOUDFLARED_SOURCE_FILE ;; esac
        case "$kind" in
            symlink) ln -s "$CASE_DIR/missing" "$path" ;;
            directory) mkdir "$path" ;;
        esac
        if configure_repository >/dev/null 2>&1; then fail "$target $kind accepted"; fi
        [[ -L "$path" || -d "$path" ]] || fail "$target $kind was changed"
        pass "$target rejects $kind"
    done
    for bad in owner gid mode; do
        new_case
        case "$target" in key) path=$CLOUDFLARED_KEYRING ;; source) path=$CLOUDFLARED_SOURCE_FILE ;; esac
        if [[ "$target" == source ]]; then
            repository_source_content > "$path"
        else
            printf key > "$path"
        fi
        chmod 0644 "$path"
        case "$bad" in
            owner) chown 65534:0 "$path" ;;
            gid) chown 0:65534 "$path" ;;
            mode) chmod 0664 "$path" ;;
        esac
        if configure_repository >/dev/null 2>&1; then fail "$target wrong $bad accepted"; fi
        pass "$target rejects wrong $bad"
    done
done

new_case
printf 'deb https://example.invalid stable main\n' > "$CASE_DIR/root/etc/apt/sources.list.d/extra.list"
chmod 0644 "$CASE_DIR/root/etc/apt/sources.list.d/extra.list"
configure_repository
pass "unrelated APT source remains untouched"

new_case
printf 'deb https://pkg.cloudflare.com/cloudflared any main\n' > "$CASE_DIR/root/etc/apt/sources.list.d/duplicate.list"
chmod 0644 "$CASE_DIR/root/etc/apt/sources.list.d/duplicate.list"
if configure_repository >/dev/null 2>&1; then fail "duplicate Cloudflare source accepted"; fi
assert_absent "$CLOUDFLARED_KEYRING" "duplicate source changed key"
assert_absent "$CLOUDFLARED_SOURCE_FILE" "duplicate source wrote managed source"
pass "reject duplicate or extra Cloudflare source before commit"

new_case
printf 'deb [signed-by=%s trusted=yes] https://pkg.cloudflare.com/cloudflared any main\n' \
    "$CLOUDFLARED_KEYRING" > "$CLOUDFLARED_SOURCE_FILE"
chmod 0644 "$CLOUDFLARED_SOURCE_FILE"
if configure_repository >/dev/null 2>&1; then fail "source injection accepted"; fi
pass "reject unknown source fields and injection content"

(
new_case
set_old_generation
INSTALL_CALL=0
FAIL_INSTALL_CALL=1
repository_install_file() {
    INSTALL_CALL=$((INSTALL_CALL + 1))
    (( INSTALL_CALL != FAIL_INSTALL_CALL )) || return 1
    command install -o 0 -g 0 -m "$1" -- "$2" "$3"
}
if configure_repository >/dev/null 2>&1; then fail "key stage write failure succeeded"; fi
assert_old_generation
)
pass "formal key write failure rolls back"

(
new_case
set_old_generation
INSTALL_CALL=0
FAIL_INSTALL_CALL=2
repository_install_file() {
    INSTALL_CALL=$((INSTALL_CALL + 1))
    (( INSTALL_CALL != FAIL_INSTALL_CALL )) || return 1
    command install -o 0 -g 0 -m "$1" -- "$2" "$3"
}
if configure_repository >/dev/null 2>&1; then fail "source stage write failure succeeded"; fi
assert_old_generation
)
pass "formal source write failure rolls back"

(
new_case
set_old_generation
RENAME_CALL=0
FAIL_RENAME_CALL=2
repository_rename() {
    RENAME_CALL=$((RENAME_CALL + 1))
    (( RENAME_CALL != FAIL_RENAME_CALL )) || return 1
    command mv -fT -- "$1" "$2"
}
if configure_repository >/dev/null 2>&1; then fail "source commit failure succeeded"; fi
assert_old_generation
)
pass "key success/source failure rolls back"

(
new_case
set_old_generation
RENAME_CALL=0
FAIL_RENAME_CALL=1
repository_rename() {
    RENAME_CALL=$((RENAME_CALL + 1))
    (( RENAME_CALL != FAIL_RENAME_CALL )) || return 1
    command mv -fT -- "$1" "$2"
}
if configure_repository >/dev/null 2>&1; then fail "key commit failure succeeded"; fi
assert_old_generation
)
pass "source remains old when key commit fails"

run_failure_case "APT probe failure rollback" 'export FAKE_APT_UPDATE_FAIL=1' 'run_repository_apt_transaction install'
run_failure_case "APT install failure rollback" 'export FAKE_APT_INSTALL_FAIL=1' 'run_repository_apt_transaction install'

for signal in HUP INT TERM; do
    case "$signal" in HUP) expected=129 ;; INT) expected=130 ;; TERM) expected=143 ;; esac
    for phase in download validate stage key-commit source-commit apt-probe apt-install; do
        new_case
        set_old_generation
        cat > "$CASE_DIR/signal-runner.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export PATH=$(printf '%q' "$PATH")
export FAKE_LOG=$(printf '%q' "$FAKE_LOG")
export CLOUDFLARED_TRUST_ANCHOR=$(printf '%q' "$CLOUDFLARED_TRUST_ANCHOR")
export CLOUDFLARED_KEYRING=$(printf '%q' "$CLOUDFLARED_KEYRING")
export CLOUDFLARED_SOURCE_FILE=$(printf '%q' "$CLOUDFLARED_SOURCE_FILE")
export CLOUDFLARED_APT_SOURCE_ROOT=$(printf '%q' "$CLOUDFLARED_APT_SOURCE_ROOT")
export CLOUDFLARED_STATE_DIR=$(printf '%q' "$CLOUDFLARED_STATE_DIR")
export CLOUDFLARED_REPOSITORY_STATE_DIR=$(printf '%q' "$CLOUDFLARED_REPOSITORY_STATE_DIR")
source $(printf '%q' "$ROOT_DIR/tools/cloudflare_tunnel.sh")
repository_transaction_hook() {
    if [[ \$1 == $(printf '%q' "$phase") ]]; then kill -s $(printf '%q' "$signal") \$BASHPID; fi
}
if [[ $(printf '%q' "$phase") == apt-* ]]; then
    run_repository_apt_transaction install
else
    configure_repository
fi
EOF
        chmod 0700 "$CASE_DIR/signal-runner.sh"
        set +e
        timeout 30 bash "$CASE_DIR/signal-runner.sh" >"$CASE_DIR/out" 2>"$CASE_DIR/err"
        status=$?
        set -e
        [[ "$status" == "$expected" ]] || fail "$signal at $phase returned $status, expected $expected"
        assert_old_generation
        [[ ! -d "$CLOUDFLARED_STATE_DIR.lock" ]] || fail "$signal at $phase left lock"
        pass "$signal=$expected rolls back at $phase"
    done
done

(
new_case
set_old_generation
RENAME_CALL=0
repository_rename() {
    RENAME_CALL=$((RENAME_CALL + 1))
    case "$RENAME_CALL" in 2|3) return 1 ;; esac
    command mv -fT -- "$1" "$2"
}
if configure_repository >/dev/null 2>&1; then fail "rollback failure unexpectedly succeeded"; fi
find "$CLOUDFLARED_REPOSITORY_STATE_DIR" -maxdepth 2 -type f -name rollback.log -print -quit | grep -q . ||
    fail "rollback failure did not preserve evidence"
)
pass "rollback failure returns nonzero and preserves evidence"

new_case
set_old_generation
configure_repository
current="$CLOUDFLARED_REPOSITORY_STATE_DIR/current"
[[ -f "$current" ]] || fail "generation marker missing"
key_hash=$(sha256sum "$CLOUDFLARED_KEYRING" | awk '{print $1}')
printf 'deb [signed-by=%s] https://pkg.cloudflare.com/cloudflared any main\n' "$CLOUDFLARED_KEYRING" > "$CASE_DIR/independent-source"
assert_same "$CLOUDFLARED_SOURCE_FILE" "$CASE_DIR/independent-source" "source differs from official literal"
source_hash=$(sha256sum "$CASE_DIR/independent-source" | awk '{print $1}')
grep -Fxq "key_sha256=$key_hash" "$current" || fail "key generation hash mismatch"
grep -Fxq "source_sha256=$source_hash" "$current" || fail "source generation hash mismatch"
pass "key/source commit as one recorded generation"

new_case
set_old_generation
configure_repository
validate_current_repository_manifest || fail "trusted current manifest validation failed"
remove_managed_repository
init_runtime_config
assert_absent "$CLOUDFLARED_SOURCE_FILE" "trusted current did not remove managed source"
[[ -f "$CLOUDFLARED_KEYRING" ]] || fail "managed repository removal deleted keyring"
[[ ! -f "$CLOUDFLARED_REPOSITORY_STATE_DIR/current" ]] || fail "managed repository removal retained current"
find "$CLOUDFLARED_STATE_DIR" -maxdepth 1 -type d -name 'uninstall-*' -print -quit | grep -q . ||
    fail "managed source backup missing"
[[ ! -d "$CLOUDFLARED_STATE_DIR.lock" ]] || fail "managed repository removal left lock"
pass "configure then real repository uninstall removes source and preserves keyring"

for signal in HUP INT TERM; do
    case "$signal" in HUP) expected=129 ;; INT) expected=130 ;; TERM) expected=143 ;; esac
    for phase in before-snapshot-create capture-auto_update_script capture-auto_update_timer capture-legacy_marker lock-acquired before-disable-auto-update after-disable-auto-update before-apt-remove after-apt-remove before-source-remove after-source-remove final-apt-update before-lock-release; do
        new_case
        set_old_generation
        configure_repository
        cp "$CLOUDFLARED_SOURCE_FILE" "$CASE_DIR/expected-source"
        cp "$CLOUDFLARED_REPOSITORY_STATE_DIR/current" "$CASE_DIR/expected-current"
        set +e
        CLOUDFLARED_TEST_INTERNALS=1 SIGNAL_PHASE="$phase" SIGNAL_NAME="$signal" \
            bash -c '
                source "$1"
                require_root() { :; }
                check_platform() { :; }
                uninstall_transaction_hook() {
                    [[ "$1" != "$SIGNAL_PHASE" ]] || kill -s "$SIGNAL_NAME" "$BASHPID"
                }
                uninstall_cloudflared --confirmed
            ' _ "$ROOT_DIR/tools/cloudflare_tunnel.sh" >"$CASE_DIR/out" 2>"$CASE_DIR/err"
        status=$?
        set -e
        [[ "$status" == "$expected" ]] || fail "uninstall $signal at $phase returned $status"
        [[ ! -d "$CLOUDFLARED_STATE_DIR.lock" ]] || fail "uninstall $signal at $phase left lock"
        assert_same "$CLOUDFLARED_SOURCE_FILE" "$CASE_DIR/expected-source" "uninstall $signal at $phase failed source restore"
        assert_same "$CLOUDFLARED_REPOSITORY_STATE_DIR/current" "$CASE_DIR/expected-current" "uninstall $signal at $phase failed current restore"
        acquire_repository_lock || fail "uninstall $signal at $phase lock not reusable"
        release_repository_lock || fail "uninstall $signal at $phase lock cleanup failed"
        pass "uninstall $signal=$expected cleans $phase"
    done
done

new_case
set_old_generation
configure_repository
uninstall_transaction_hook() { [[ "$1" != after-disable-auto-update ]] || exit 0; }
set +e
( uninstall_cloudflared --confirmed ) >"$CASE_DIR/out" 2>"$CASE_DIR/err"
status=$?
set -e
[[ "$status" == 1 ]] || fail "active uninstall exit 0 returned $status"
[[ ! -d "$CLOUDFLARED_STATE_DIR.lock" ]] || fail "active uninstall exit 0 left lock"
grep -R -Fq '活动卸载事务异常退出' "$CLOUDFLARED_REPOSITORY_STATE_DIR" || fail "active uninstall exit 0 lacked evidence"