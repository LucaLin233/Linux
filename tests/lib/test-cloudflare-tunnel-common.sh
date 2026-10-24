#!/usr/bin/env bash
set -euo pipefail

if (( EUID != 0 )); then
    exec sudo --preserve-env=PATH bash "$0" "$@"
fi

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
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
