#!/usr/bin/env bash
set -euo pipefail

if (( EUID != 0 )); then
    exec sudo --preserve-env=PATH bash "$0" "$@"
fi

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly ROOT_DIR
TEST_DIR=$(mktemp -d -p "$ROOT_DIR")
readonly TEST_DIR
trap 'rm -rf "$TEST_DIR"' EXIT

pass_count=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { pass_count=$((pass_count + 1)); printf 'PASS: %s\n' "$*"; }
assert_same() { cmp -s -- "$1" "$2" || fail "$3"; }
assert_absent() { [[ ! -e "$1" && ! -L "$1" ]] || fail "$2"; }

make_fake_commands() {
    local bin="$1"
    mkdir -p "$bin"
    cat > "$bin/curl" <<'FAKE'
#!/usr/bin/env bash
set -eu
printf 'curl:%s\n' "$*" >> "$FAKE_LOG"
[[ "${FAKE_CURL_FAIL:-}" != 1 ]] || exit 22
output=""
while (( $# )); do
    if [[ "$1" == -o ]]; then output="$2"; shift 2; continue; fi
    shift
done
[[ -n "$output" ]]
printf 'fake-cloudflare-key\n' > "$output"
FAKE
    cat > "$bin/gpg" <<'FAKE'
#!/usr/bin/env bash
set -eu
printf 'gpg:%s\n' "$*" >> "$FAKE_LOG"
[[ "${FAKE_GPG_FAIL:-}" != 1 ]] || exit 2
case "${FAKE_GPG_CASE:-good}" in
    good)
        cat <<'EOF'
pub:-:4096:1:8A682D308D4E5E73:1761229688:::-:::scESC::::::23::0:
fpr:::::::::CC94B39C77AE7342A68B89628A682D308D4E5E73:
uid:-::::1761229688::HASH::CloudFlare Software Packaging 2025 <help@cloudflare.com>::::::::::0:
sub:-:4096:1:029E1444B7D9F50F:1761229688::::::e::::::23:
fpr:::::::::06C89DB3B80A8F4349697C76029E1444B7D9F50F:
EOF
        ;;
    fingerprint)
        cat <<'EOF'
pub:-:4096:1:BAD:0:::-:::scESC:
fpr:::::::::0000000000000000000000000000000000000000:
uid:-::::0::HASH::CloudFlare Software Packaging 2025 <help@cloudflare.com>:::
EOF
        ;;
    uid)
        cat <<'EOF'
pub:-:4096:1:8A682D308D4E5E73:0:::-:::scESC:
fpr:::::::::CC94B39C77AE7342A68B89628A682D308D4E5E73:
uid:-::::0::HASH::Attacker <attacker@example.invalid>:::
EOF
        ;;
    multi)
        cat <<'EOF'
pub:-:4096:1:8A682D308D4E5E73:0:::-:::scESC:
fpr:::::::::CC94B39C77AE7342A68B89628A682D308D4E5E73:
uid:-::::0::HASH::CloudFlare Software Packaging 2025 <help@cloudflare.com>:::
pub:-:4096:1:BAD:0:::-:::scESC:
fpr:::::::::0000000000000000000000000000000000000000:
uid:-::::0::HASH::Other <other@example.invalid>:::
EOF
        ;;
esac
FAKE
    cat > "$bin/apt-get" <<'FAKE'
#!/usr/bin/env bash
set -eu
printf 'apt-get:%s\n' "$*" >> "$FAKE_LOG"
case "${1:-}" in
    update) [[ "${FAKE_APT_UPDATE_FAIL:-}" != 1 ]] ;;
    install) [[ "${FAKE_APT_INSTALL_FAIL:-}" != 1 ]] ;;
    *) exit 0 ;;
esac
FAKE
    cat > "$bin/systemctl" <<'FAKE'
#!/usr/bin/env bash
printf 'systemctl:%s\n' "$*" >> "$FAKE_LOG"
exit 0
FAKE
    cat > "$bin/cloudflared" <<'FAKE'
#!/usr/bin/env bash
printf 'cloudflared:%s\n' "$*" >> "$FAKE_LOG"
exit 0
FAKE
    chmod 0755 "$bin"/*
}

new_case() {
    CASE_DIR="$TEST_DIR/case"
    rm -rf "$CASE_DIR"
    mkdir -p "$CASE_DIR"
    export CASE_DIR FAKE_LOG="$CASE_DIR/fake.log"
    : > "$FAKE_LOG"
    mkdir -p "$CASE_DIR/root/usr/share/keyrings" "$CASE_DIR/root/etc/apt/sources.list.d" \
        "$CASE_DIR/root/var/lib"
    chmod 0755 "$CASE_DIR/root" "$CASE_DIR/root/usr" "$CASE_DIR/root/usr/share" \
        "$CASE_DIR/root/usr/share/keyrings" "$CASE_DIR/root/etc" "$CASE_DIR/root/etc/apt" \
        "$CASE_DIR/root/etc/apt/sources.list.d" "$CASE_DIR/root/var" "$CASE_DIR/root/var/lib"
    make_fake_commands "$CASE_DIR/bin"
    export PATH="$CASE_DIR/bin:$ORIGINAL_PATH"
    export CLOUDFLARED_TRUST_ANCHOR="$CASE_DIR"
    export CLOUDFLARED_KEYRING="$CASE_DIR/root/usr/share/keyrings/cloudflare-main.gpg"
    export CLOUDFLARED_SOURCE_FILE="$CASE_DIR/root/etc/apt/sources.list.d/cloudflared.list"
    export CLOUDFLARED_APT_SOURCE_ROOT="$CASE_DIR/root/etc/apt"
    export CLOUDFLARED_STATE_DIR="$CASE_DIR/root/var/lib/cloudflared-wrapper"
    export CLOUDFLARED_REPOSITORY_STATE_DIR="$CLOUDFLARED_STATE_DIR/repository"
    export CLOUDFLARED_LEGACY_BIN="$CASE_DIR/legacy-cloudflared"
    export CLOUDFLARED_APT_BIN="$CASE_DIR/usr-bin-cloudflared"
    export CLOUDFLARED_LEGACY_UPDATER="$CASE_DIR/cloudflared-update"
    export CLOUDFLARED_LEGACY_SERVICE="$CASE_DIR/cloudflared-updater.service"
    export CLOUDFLARED_LEGACY_TIMER="$CASE_DIR/cloudflared-updater.timer"
    export CLOUDFLARED_AUTO_UPDATE_SCRIPT="$CASE_DIR/cloudflared-apt-update"
    export CLOUDFLARED_AUTO_UPDATE_SERVICE="$CASE_DIR/cloudflared-apt-update.service"
    export CLOUDFLARED_AUTO_UPDATE_TIMER="$CASE_DIR/cloudflared-apt-update.timer"
    export CLOUDFLARED_SERVICE_FILE="$CASE_DIR/cloudflared.service"
    export CLOUDFLARED_BINARY_UPDATE_SERVICE="$CASE_DIR/cloudflared-update.service"
    export CLOUDFLARED_BINARY_UPDATE_TIMER="$CASE_DIR/cloudflared-update.timer"
    export CLOUDFLARED_TEST_INTERNALS=1
    unset FAKE_CURL_FAIL FAKE_GPG_FAIL FAKE_GPG_CASE FAKE_APT_UPDATE_FAIL FAKE_APT_INSTALL_FAIL
    unset FAIL_INSTALL_CALL FAIL_RENAME_CALL INSTALL_CALL RENAME_CALL SIGNAL_PHASE
    if [[ "${SCRIPT_SOURCED:-}" != 1 ]]; then
        # shellcheck source=../tools/cloudflare_tunnel.sh
        source "$ROOT_DIR/tools/cloudflare_tunnel.sh"
        SCRIPT_SOURCED=1
    fi
    init_runtime_config
}

set_old_generation() {
    printf 'old-key\n' > "$CLOUDFLARED_KEYRING"
    repository_legacy_source_content > "$CLOUDFLARED_SOURCE_FILE"
    chmod 0644 "$CLOUDFLARED_KEYRING" "$CLOUDFLARED_SOURCE_FILE"
    cp "$CLOUDFLARED_KEYRING" "$CASE_DIR/expected-key"
    cp "$CLOUDFLARED_SOURCE_FILE" "$CASE_DIR/expected-source"
}

assert_old_generation() {
    assert_same "$CLOUDFLARED_KEYRING" "$CASE_DIR/expected-key" "old key was not restored"
    assert_same "$CLOUDFLARED_SOURCE_FILE" "$CASE_DIR/expected-source" "old source was not restored"
}

run_failure_case() {
    local name="$1" setup="$2" action="${3:-configure_repository}"
    new_case
    set_old_generation
    eval "$setup"
    set +e
    eval "$action" >"$CASE_DIR/out" 2>"$CASE_DIR/err"
    status=$?
    set -e
    if (( status == 0 )); then
        fail "$name unexpectedly succeeded"
    fi
    assert_old_generation
    [[ ! -d "$CLOUDFLARED_STATE_DIR.lock" ]] || fail "$name left lock"
    find "$CLOUDFLARED_REPOSITORY_STATE_DIR" -maxdepth 1 -type d -name 'failure-*' -print -quit | grep -q . ||
        fail "$name did not preserve failure evidence"
    pass "$name"
}

ORIGINAL_PATH=$PATH

new_case
before=$(find "$CASE_DIR/root" -mindepth 1 -printf '%P %y %m\n' | sort)
repository_source_content > "$CASE_DIR/source-output"
after=$(find "$CASE_DIR/root" -mindepth 1 -printf '%P %y %m\n' | sort)
[[ "$before" == "$after" ]] || fail "source rendering had side effects"
[[ "$(cat "$CASE_DIR/source-output")" == "deb [signed-by=$CLOUDFLARED_KEYRING] https://pkg.cloudflare.com/cloudflared any main" ]] ||
    fail "source is not exact official definition"
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

entrypoint_output=$(bash -c "$(cat "$ROOT_DIR/tools/cloudflare_tunnel.sh")" cloudflare_tunnel.sh help)
grep -Fq 'cloudflare_tunnel.sh install' <<< "$entrypoint_output" || fail "bash -c entrypoint broken"
pass "bash -c entrypoint remains compatible"

printf 'All cloudflare wrapper tests passed. PASS=%d\n' "$pass_count"
