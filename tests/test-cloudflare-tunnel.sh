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
[[ "$(cat "$CASE_DIR/source-output")" == "deb [signed-by=$CLOUDFLARED_KEYRING] https://pkg.cloudflare.com/cloudflare-main.gpg any main" ]] ||
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
printf 'deb [signed-by=%s trusted=yes] https://pkg.cloudflare.com/cloudflare-main.gpg any main\n' \
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
source_hash=$(sha256sum "$CLOUDFLARED_SOURCE_FILE" | awk '{print $1}')
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
    for phase in lock-acquired before-disable-auto-update after-disable-auto-update before-apt-remove after-apt-remove before-source-remove after-source-remove final-apt-update before-lock-release; do
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

entrypoint_output=$(bash -c "$(cat "$ROOT_DIR/tools/cloudflare_tunnel.sh")" cloudflare_tunnel.sh help)
grep -Fq 'cloudflare_tunnel.sh install' <<< "$entrypoint_output" || fail "bash -c entrypoint broken"
pass "bash -c entrypoint remains compatible"

printf 'All cloudflare wrapper tests passed. PASS=%d\n' "$pass_count"
