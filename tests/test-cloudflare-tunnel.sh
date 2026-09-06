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
    export CLOUDFLARED_TRUST_ANCHOR="$CASE_DIR/root"
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

new_case
mkdir -p "$CLOUDFLARED_STATE_DIR.lock"
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
    "$ROOT_DIR"/tools/setup-motd.sh "$ROOT_DIR"/tools/xanmod-install.sh "$ROOT_DIR"/tools/traffic-shape.sh)
script_hashes_after=$(sha256sum "$ROOT_DIR/linux_setup.sh" "$ROOT_DIR"/modules/*.sh "$ROOT_DIR"/tools/push.sh \
    "$ROOT_DIR"/tools/setup-motd.sh "$ROOT_DIR"/tools/xanmod-install.sh "$ROOT_DIR"/tools/traffic-shape.sh)
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

entrypoint_output=$(bash -c "$(cat "$ROOT_DIR/tools/cloudflare_tunnel.sh")" cloudflare_tunnel.sh help)
grep -Fq 'cloudflare_tunnel.sh install' <<< "$entrypoint_output" || fail "bash -c entrypoint broken"
pass "bash -c entrypoint remains compatible"

printf 'All cloudflare wrapper tests passed. PASS=%d\n' "$pass_count"
