#!/usr/bin/env bash
set -euo pipefail

readonly ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly SCRIPT="$ROOT_DIR/tools/push.sh"
readonly TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }
assert_eq() {
    local expected="$1" actual="$2" name="$3"
    [[ "$actual" == "$expected" ]] || fail "$name: expected '$expected', got '$actual'"
    pass "$name"
}
assert_file_eq() {
    local expected="$1" file="$2" name="$3"
    [[ -f "$file" && ! -L "$file" ]] || fail "$name: expected regular file $file"
    assert_eq "$expected" "$(<"$file")" "$name"
}
assert_fail() {
    local name="$1"; shift
    if "$@"; then fail "$name: unexpectedly succeeded"; fi
    pass "$name"
}

# Source must not create runtime files, inspect configuration, modify SSHPASS, or replace traps.
source_root="$TEST_DIR/source"
mkdir -m 0700 "$source_root"
source_result=$(env TMPDIR="$source_root" SCRIPT="$SCRIPT" bash -c '
set -euo pipefail
trap "printf hup >/dev/null" HUP
trap "printf int >/dev/null" INT
trap "printf term >/dev/null" TERM
trap "printf exit >/dev/null" EXIT
before_hup=$(trap -p HUP); before_int=$(trap -p INT); before_term=$(trap -p TERM); before_exit=$(trap -p EXIT)
export SSHPASS=keep
source "$SCRIPT"
[[ -z "$TEMP_DIR" && -z "$SUCCESS_FILE" && -z "$FAILED_FILE" && -z "$SSH_WRAPPER" ]]
[[ "$before_hup" == "$(trap -p HUP)" && "$before_int" == "$(trap -p INT)" && "$before_term" == "$(trap -p TERM)" && "$before_exit" == "$(trap -p EXIT)" ]]
[[ "$SSHPASS" == keep ]]
[[ -z "$(find "$TMPDIR" -mindepth 1 -print -quit)" ]]
printf source-safe
')
assert_eq source-safe "$source_result" "source has no filesystem, trap, config, or credential side effects"

[[ -x "$SCRIPT" ]] || fail "tools/push.sh is not executable"
pass "tools/push.sh is executable"
push_mode=$(git -c safe.directory="$ROOT_DIR" -C "$ROOT_DIR" ls-files -s tools/push.sh | awk '{print $1}')
assert_eq 100755 "$push_mode" "tools/push.sh Git mode is 100755"

# shellcheck source=../tools/push.sh
source "$SCRIPT"
trap 'rm -rf "$TEST_DIR"' EXIT

DEFAULT_USER=root
DEFAULT_PORT=22
parse_server_info "admin@example.com:2222" || fail "parse DNS server"
assert_eq admin@example.com "$PARSED_TARGET" "parse DNS target"
assert_eq 2222 "$PARSED_PORT" "parse explicit port"
parse_server_info "root@192.0.2.10" || fail "parse IPv4 server"
assert_eq root@192.0.2.10 "$PARSED_TARGET" "parse IPv4 target"
parse_server_info "root@[2001:db8::1]:2200" || fail "parse IPv6 server"
assert_eq 'root@[2001:db8::1]' "$PARSED_TARGET" "preserve IPv6 brackets"
assert_eq 2200 "$PARSED_PORT" "parse IPv6 port"
assert_fail "reject bare IPv6" parse_server_info "2001:db8::1"
assert_fail "reject leading-dash user" parse_server_info "-o@host"
assert_fail "reject leading-dash host" parse_server_info "root@-host"
assert_fail "reject whitespace in server" parse_server_info "root@bad host"
assert_fail "reject newline in server" parse_server_info $'root@host\n-oProxyCommand=x'
assert_fail "reject port zero" parse_server_info "root@host:0"
assert_fail "reject port above 65535" parse_server_info "root@host:65536"

# Runtime initialization publishes only a verified 0700 directory and supports idempotent cleanup.
(
    trap - EXIT HUP INT TERM
    runtime_parent="$TEST_DIR/runtime"
    mkdir -m 0700 "$runtime_parent"
    TMPDIR="$runtime_parent"
    initialize_runtime
    runtime_path="$TEMP_DIR"
    assert_eq 700 "$(stat -c %a "$TEMP_DIR")" "runtime directory mode is 0700"
    [[ -f "$SUCCESS_FILE" && -f "$FAILED_FILE" ]] || fail "runtime result files missing"
    [[ "$SUCCESS_FILE" == "$TEMP_DIR"/* && "$FAILED_FILE" == "$TEMP_DIR"/* && "$SSH_WRAPPER" == "$TEMP_DIR"/* ]] || fail "runtime paths escaped runtime directory"
    pass "runtime publishes only in-directory state paths"
    cleanup_runtime
    [[ ! -e "$runtime_path" && -z "$TEMP_DIR" ]] || fail "runtime cleanup left directory or state"
    pass "runtime cleanup removes owned directory"
    cleanup_runtime
    pass "runtime cleanup is idempotent"
)

(
    trap - EXIT HUP INT TERM
    TMPDIR="$TEST_DIR/runtime-create-fail"
    mkdir -m 0700 "$TMPDIR"
    mktemp() { return 1; }
    assert_fail "runtime creation failure returns nonzero" initialize_runtime
    assert_eq '' "$TEMP_DIR" "runtime creation failure publishes no directory"
)

(
    trap - EXIT HUP INT TERM
    TMPDIR="$TEST_DIR/runtime-delete-fail"
    mkdir -m 0700 "$TMPDIR"
    initialize_runtime
    runtime_path="$TEMP_DIR"
    rm() { local last=${!#}; [[ "$last" == "$runtime_path" ]] && return 1; command rm "$@"; }
    assert_fail "runtime deletion failure returns nonzero" cleanup_runtime
    assert_eq "$runtime_path" "$TEMP_DIR" "runtime deletion failure preserves owned path for retry"
    [[ -d "$runtime_path" ]] || fail "runtime deletion failure lost directory"
    unset -f rm
    cleanup_runtime
    [[ ! -e "$runtime_path" ]] || fail "runtime deletion retry left directory"
    pass "runtime deletion retry succeeds"
)

(
    trap - EXIT HUP INT TERM
    TMPDIR="$TEST_DIR/runtime-replaced"
    mkdir -m 0700 "$TMPDIR"
    initialize_runtime
    runtime_path="$TEMP_DIR"
    command mv "$runtime_path" "$runtime_path.real"
    command ln -s "$runtime_path.real" "$runtime_path"
    assert_fail "runtime cleanup rejects replaced symlink" cleanup_runtime
    [[ -d "$runtime_path.real" ]] || fail "runtime cleanup deleted replacement target"
    pass "runtime cleanup preserves unproven replacement target"
    command rm -f "$runtime_path"
    command mv "$runtime_path.real" "$runtime_path"
    cleanup_runtime
)

# Config loading uses an opened, verified fd and preserves indexed/associative arrays.
config_root="$TEST_DIR/config"
mkdir -m 0700 "$config_root"
config="$config_root/config.conf"
cat > "$config" <<'EOF'
DEFAULT_USER="alice"
SERVERS=("one.example" "two.example:2200")
declare -A TASKS=([copy]="/src/:/dst/")
EOF
chmod 0600 "$config"
load_config "$config"
assert_eq alice "$DEFAULT_USER" "load protected config scalar"
assert_eq two.example:2200 "${SERVERS[1]}" "load protected config indexed array"
assert_eq '/src/:/dst/' "${TASKS[copy]}" "load protected config associative array"

ln -s "$config" "$config_root/config-link.conf"
assert_fail "reject symlink config" load_config "$config_root/config-link.conf"
chmod 0622 "$config"
assert_fail "reject group-writable config" load_config "$config"
chmod 0000 "$config"
assert_fail "reject unreadable config" load_config "$config"
chmod 0600 "$config"

(
    trap - EXIT HUP INT TERM
    malicious="$config_root/malicious.conf"
    marker="$config_root/config-injection"
    cat > "$config" <<'EOF'
DEFAULT_USER="fd-safe"
SERVERS=("safe.example")
declare -A TASKS=([safe]="a:b")
EOF
    cat > "$malicious" <<EOF
touch "$marker"
DEFAULT_USER="replaced"
SERVERS=("evil.example")
declare -A TASKS=([evil]="x:y")
EOF
    chmod 0600 "$config" "$malicious"
    secure_fd_open_hook() {
        if [[ "$1" == config ]]; then
            command mv "$2" "$2.opened"
            command cp "$malicious" "$2"
            chmod 0600 "$2"
        fi
    }
    load_config "$config"
    assert_eq fd-safe "$DEFAULT_USER" "config TOCTOU loads opened inode"
    [[ ! -e "$marker" ]] || fail "replacement config command executed"
    pass "config TOCTOU replacement command is not executed"
    command mv -f "$config.opened" "$config"
)

(
    trap - EXIT HUP INT TERM
    other_uid=65534; [[ "$other_uid" == "$EUID" ]] && other_uid=1
    stat() {
        local last=${!#}
        if [[ "$last" == "$config" && "$*" == *'%d:%i:%u:%g:%a'* ]]; then
            command stat -Lc '%d:%i' -- "$config" | awk -F: -v uid="$other_uid" -v gid="$(id -g)" '{print $1":"$2":"uid":"gid":600"}'
        else
            command stat "$@"
        fi
    }
    assert_fail "reject wrong-owner config" load_config "$config"
)

# Safe config generation never overwrites an existing path or symlink target.
(
    trap - EXIT HUP INT TERM
    root="$TEST_DIR/generate"
    mkdir -m 0700 "$root"
    generate_config "$root/config.conf" >/dev/null
    assert_eq 600 "$(stat -c %a "$root/config.conf")" "generated config mode is 0600"
    original_hash=$(sha256sum "$root/config.conf")
    assert_fail "generate-config refuses existing file" generate_config "$root/config.conf"
    assert_eq "$original_hash" "$(sha256sum "$root/config.conf")" "generate-config preserves existing file"
    printf target > "$root/target"
    ln -s "$root/target" "$root/link.conf"
    assert_fail "generate-config refuses symlink" generate_config "$root/link.conf"
    assert_file_eq target "$root/target" "generate-config does not overwrite symlink target"
    [[ -z "$(find "$root" -name '.config.conf.tmp.*' -print -quit)" ]] || fail "generate-config left stage"
    pass "generate-config leaves no half-written stage"
)

# Reusable secure credential validation, fd pinning, runtime key copy, and password cleanup.
make_runtime() {
    TMPDIR="$1"
    mkdir -m 0700 "$TMPDIR"
    initialize_runtime
}

(
    trap - EXIT HUP INT TERM
    root="$TEST_DIR/key-valid"
    mkdir -m 0700 "$root"
    make_runtime "$root/runtime"
    key="$root/id key"
    printf original-key > "$key"; chmod 0600 "$key"
    KEY_FILE="$key"; AUTH_METHOD=key
    prepare_key_credentials
    runtime_key="$RUNTIME_KEY_FILE"
    assert_eq 600 "$(stat -c %a "$runtime_key")" "runtime key copy mode is 0600"
    assert_file_eq original-key "$runtime_key" "runtime key copy preserves verified fd content"
    [[ "$runtime_key" != "$KEY_FILE" ]] || fail "runtime key path reused original key"
    pass "runtime key path differs from original KEY_FILE"
    cleanup_runtime
    [[ ! -e "$runtime_key" ]] || fail "runtime cleanup left key copy"
    pass "runtime cleanup removes key copy"
)

for bad_key_case in symlink 0644 0660 unreadable; do
    (
        trap - EXIT HUP INT TERM
        root="$TEST_DIR/key-$bad_key_case"; mkdir -m 0700 "$root"; make_runtime "$root/runtime"
        key="$root/key"; printf key > "$key"; chmod 0600 "$key"
        case "$bad_key_case" in
            symlink) command mv "$key" "$key.real"; ln -s "$key.real" "$key" ;;
            0644) chmod 0644 "$key" ;;
            0660) chmod 0660 "$key" ;;
            unreadable) chmod 0000 "$key" ;;
        esac
        KEY_FILE="$key"; AUTH_METHOD=key
        assert_fail "reject private key $bad_key_case" prepare_key_credentials
        cleanup_runtime
    )
done

(
    trap - EXIT HUP INT TERM
    root="$TEST_DIR/key-owner"; mkdir -m 0700 "$root"; make_runtime "$root/runtime"
    key="$root/key"; printf key > "$key"; chmod 0600 "$key"; KEY_FILE="$key"
    other_uid=65534; [[ "$other_uid" == "$EUID" ]] && other_uid=1
    stat() {
        local last=${!#}
        if [[ "$last" == "$key" && "$*" == *'%d:%i:%u:%g:%a'* ]]; then
            command stat -Lc '%d:%i' -- "$key" | awk -F: -v uid="$other_uid" -v gid="$(id -g)" '{print $1":"$2":"uid":"gid":600"}'
        else command stat "$@"; fi
    }
    assert_fail "reject wrong-owner private key" prepare_key_credentials
    cleanup_runtime
)

(
    trap - EXIT HUP INT TERM
    root="$TEST_DIR/key-toctou"; mkdir -m 0700 "$root"; make_runtime "$root/runtime"
    key="$root/key"; replacement="$root/replacement"
    printf verified-key > "$key"; printf replaced-key > "$replacement"; chmod 0600 "$key" "$replacement"
    KEY_FILE="$key"
    secure_fd_open_hook() {
        if [[ "$1" == private-key ]]; then
            command mv "$2" "$2.opened"
            command cp "$replacement" "$2"
            chmod 0600 "$2"
        fi
    }
    prepare_key_credentials
    assert_file_eq verified-key "$RUNTIME_KEY_FILE" "private key TOCTOU copies opened inode"
    cleanup_runtime
)

for password_case in symlink 0644 0660 unreadable empty; do
    (
        trap - EXIT HUP INT TERM
        root="$TEST_DIR/password-$password_case"; mkdir -m 0700 "$root"; make_runtime "$root/runtime"
        password_file="$root/password"; printf 'secret\n' > "$password_file"; chmod 0600 "$password_file"
        case "$password_case" in
            symlink) command mv "$password_file" "$password_file.real"; ln -s "$password_file.real" "$password_file" ;;
            0644) chmod 0644 "$password_file" ;;
            0660) chmod 0660 "$password_file" ;;
            unreadable) chmod 0000 "$password_file" ;;
            empty) : > "$password_file" ;;
        esac
        PASSWORD_METHOD=file; PASSWORD_FILE="$password_file"
        assert_fail "reject password file $password_case" prepare_password_credentials
        cleanup_runtime
    )
done

(
    trap - EXIT HUP INT TERM
    root="$TEST_DIR/password-owner"; mkdir -m 0700 "$root"; make_runtime "$root/runtime"
    password_file="$root/password"; printf 'secret\n' > "$password_file"; chmod 0600 "$password_file"; PASSWORD_METHOD=file; PASSWORD_FILE="$password_file"
    other_uid=65534; [[ "$other_uid" == "$EUID" ]] && other_uid=1
    stat() {
        local last=${!#}
        if [[ "$last" == "$password_file" && "$*" == *'%d:%i:%u:%g:%a'* ]]; then
            command stat -Lc '%d:%i' -- "$password_file" | awk -F: -v uid="$other_uid" -v gid="$(id -g)" '{print $1":"$2":"uid":"gid":600"}'
        else command stat "$@"; fi
    }
    assert_fail "reject wrong-owner password file" prepare_password_credentials
    cleanup_runtime
)

(
    trap - EXIT HUP INT TERM
    root="$TEST_DIR/password-toctou"; mkdir -m 0700 "$root"; make_runtime "$root/runtime"
    password_file="$root/password"; replacement="$root/replacement"
    printf 'verified-password\nsecond\n' > "$password_file"; printf 'replaced-password\n' > "$replacement"; chmod 0600 "$password_file" "$replacement"
    PASSWORD_METHOD=file; PASSWORD_FILE="$password_file"
    secure_fd_open_hook() {
        if [[ "$1" == password-file ]]; then
            command mv "$2" "$2.opened"
            command cp "$replacement" "$2"
            chmod 0600 "$2"
        fi
    }
    prepare_password_credentials
    assert_eq verified-password "$SSHPASS" "password TOCTOU reads first line from opened fd"
    runtime_path="$TEMP_DIR"
    cleanup_runtime
    [[ -z "${SSHPASS:-}" && ! -e "$runtime_path" ]] || fail "password cleanup retained SSHPASS or runtime"
    pass "password cleanup unsets SSHPASS and removes runtime"
)

(
    trap - EXIT HUP INT TERM
    root="$TEST_DIR/password-methods"; mkdir -m 0700 "$root"; make_runtime "$root/runtime"
    export PUSH_TEST_PASSWORD=env-secret
    PASSWORD_METHOD=env; PASSWORD_ENV_VAR=PUSH_TEST_PASSWORD
    prepare_password_credentials
    assert_eq env-secret "$SSHPASS" "password env method remains supported"
    unset SSHPASS
    PASSWORD_METHOD=inline; PASSWORD=inline-secret
    prepare_password_credentials >/dev/null 2>"$root/inline.log"
    assert_eq inline-secret "$SSHPASS" "password inline method remains supported"
    grep -Fq '不推荐' "$root/inline.log" || fail "inline password warning missing"
    pass "inline password emits explicit warning"
    cleanup_runtime
)

# known_hosts directory and file trust policy.
(
    trap - EXIT HUP INT TERM
    root="$TEST_DIR/known-new"; mkdir -m 0700 "$root"
    USER_KNOWN_HOSTS_FILE="$root/ssh/nested/known_hosts"; ALLOW_INSECURE_HOST_KEY_STORAGE=false
    prepare_known_hosts
    assert_eq 700 "$(stat -c %a "$root/ssh")" "new known_hosts parent mode is 0700"
    assert_eq 700 "$(stat -c %a "$root/ssh/nested")" "new nested known_hosts parent mode is 0700"
    assert_eq 600 "$(stat -c %a "$USER_KNOWN_HOSTS_FILE")" "new known_hosts mode is 0600"
    chmod 0644 "$USER_KNOWN_HOSTS_FILE"
    prepare_known_hosts
    pass "existing safe 0644 known_hosts is accepted"
)

for known_case in file-symlink parent-symlink file-writable dir-writable; do
    (
        trap - EXIT HUP INT TERM
        root="$TEST_DIR/known-$known_case"; mkdir -m 0700 "$root"
        mkdir -m 0700 "$root/ssh"; printf host > "$root/ssh/known_hosts"; chmod 0600 "$root/ssh/known_hosts"
        USER_KNOWN_HOSTS_FILE="$root/ssh/known_hosts"; ALLOW_INSECURE_HOST_KEY_STORAGE=false
        case "$known_case" in
            file-symlink) command mv "$USER_KNOWN_HOSTS_FILE" "$USER_KNOWN_HOSTS_FILE.real"; ln -s "$USER_KNOWN_HOSTS_FILE.real" "$USER_KNOWN_HOSTS_FILE" ;;
            parent-symlink) command mv "$root/ssh" "$root/ssh.real"; ln -s "$root/ssh.real" "$root/ssh" ;;
            file-writable) chmod 0666 "$USER_KNOWN_HOSTS_FILE" ;;
            dir-writable) chmod 0777 "$root/ssh" ;;
        esac
        assert_fail "reject known_hosts $known_case" prepare_known_hosts
    )
done

(
    trap - EXIT HUP INT TERM
    root="$TEST_DIR/known-ancestor-symlink"; mkdir -m 0700 "$root" "$root/real" "$root/real/child"
    ln -s "$root/real" "$root/link"
    USER_KNOWN_HOSTS_FILE="$root/link/child/known_hosts"; ALLOW_INSECURE_HOST_KEY_STORAGE=false
    assert_fail "reject known_hosts symlink in ancestor component" prepare_known_hosts
)

(
    trap - EXIT HUP INT TERM
    USER_KNOWN_HOSTS_FILE=/dev/null; ALLOW_INSECURE_HOST_KEY_STORAGE=false
    assert_fail "reject unauthorized /dev/null known_hosts" prepare_known_hosts
    ALLOW_INSECURE_HOST_KEY_STORAGE=true
    prepare_known_hosts 2>"$TEST_DIR/dev-null-warning"
    grep -Fq 'MITM' "$TEST_DIR/dev-null-warning" || fail "/dev/null warning missing MITM"
    pass "explicitly authorized /dev/null emits MITM warning"
)

# Static help and config generation must not initialize runtime state.
(
    trap - EXIT HUP INT TERM
    root="$TEST_DIR/static-actions"; mkdir -m 0700 "$root" "$root/runtime"
    (cd "$root" && env TMPDIR="$root/runtime" "$SCRIPT" --help >/dev/null)
    [[ -z "$(find "$root/runtime" -mindepth 1 -print -quit)" ]] || fail "static help created runtime files"
    pass "static help creates no runtime directory"
    (cd "$root" && env TMPDIR="$root/runtime" "$SCRIPT" --generate-config >/dev/null)
    [[ -f "$root/config.conf" && "$(stat -c %a "$root/config.conf")" == 600 ]] || fail "CLI generate-config did not create secure config"
    [[ -z "$(find "$root/runtime" -mindepth 1 -print -quit)" ]] || fail "generate-config created runtime files"
    pass "CLI generate-config creates secure config without runtime directory"
)

# Explicit GID and known_hosts owner/GID rejection paths.
(
    trap - EXIT HUP INT TERM
    other_gid=65534; [[ "$other_gid" == "$(id -g)" ]] && other_gid=1
    stat() {
        local last=${!#}
        if [[ "$last" == "$config" && "$*" == *'%d:%i:%u:%g:%a'* ]]; then
            command stat -Lc '%d:%i' -- "$config" | awk -F: -v uid="$EUID" -v gid="$other_gid" '{print $1":"$2":"uid":"gid":600"}'
        else command stat "$@"; fi
    }
    assert_fail "reject wrong-GID config" load_config "$config"
)

(
    trap - EXIT HUP INT TERM
    root="$TEST_DIR/key-gid"; mkdir -m 0700 "$root"; make_runtime "$root/runtime"
    key="$root/key"; printf key > "$key"; chmod 0600 "$key"; KEY_FILE="$key"
    other_gid=65534; [[ "$other_gid" == "$(id -g)" ]] && other_gid=1
    stat() {
        local last=${!#}
        if [[ "$last" == "$key" && "$*" == *'%d:%i:%u:%g:%a'* ]]; then
            command stat -Lc '%d:%i' -- "$key" | awk -F: -v uid="$EUID" -v gid="$other_gid" '{print $1":"$2":"uid":"gid":600"}'
        else command stat "$@"; fi
    }
    assert_fail "reject wrong-GID private key" prepare_key_credentials
    cleanup_runtime
)

(
    trap - EXIT HUP INT TERM
    root="$TEST_DIR/password-gid"; mkdir -m 0700 "$root"; make_runtime "$root/runtime"
    password_file="$root/password"; printf 'secret\n' > "$password_file"; chmod 0600 "$password_file"
    PASSWORD_METHOD=file; PASSWORD_FILE="$password_file"
    other_gid=65534; [[ "$other_gid" == "$(id -g)" ]] && other_gid=1
    stat() {
        local last=${!#}
        if [[ "$last" == "$password_file" && "$*" == *'%d:%i:%u:%g:%a'* ]]; then
            command stat -Lc '%d:%i' -- "$password_file" | awk -F: -v uid="$EUID" -v gid="$other_gid" '{print $1":"$2":"uid":"gid":600"}'
        else command stat "$@"; fi
    }
    assert_fail "reject wrong-GID password file" prepare_password_credentials
    cleanup_runtime
)

for known_identity_case in file-owner file-gid dir-owner dir-gid; do
    (
        trap - EXIT HUP INT TERM
        root="$TEST_DIR/known-$known_identity_case"; mkdir -m 0700 "$root" "$root/ssh"
        printf host > "$root/ssh/known_hosts"; chmod 0600 "$root/ssh/known_hosts"
        USER_KNOWN_HOSTS_FILE="$root/ssh/known_hosts"; ALLOW_INSECURE_HOST_KEY_STORAGE=false
        other_uid=65534; [[ "$other_uid" == "$EUID" ]] && other_uid=1
        other_gid=65534; [[ "$other_gid" == "$(id -g)" ]] && other_gid=1
        stat() {
            local last=${!#}
            if [[ "$last" == "$USER_KNOWN_HOSTS_FILE" && "$known_identity_case" == file-owner && "$*" == *'%u:%g:%a'* ]]; then
                printf '%s:%s:600\n' "$other_uid" "$(id -g)"
            elif [[ "$last" == "$USER_KNOWN_HOSTS_FILE" && "$known_identity_case" == file-gid && "$*" == *'%u:%g:%a'* ]]; then
                printf '%s:%s:600\n' "$EUID" "$other_gid"
            elif [[ "$last" == "$root/ssh" && "$known_identity_case" == dir-owner && "$*" == *'%u:%g:%a'* ]]; then
                printf '%s:%s:700\n' "$other_uid" "$(id -g)"
            elif [[ "$last" == "$root/ssh" && "$known_identity_case" == dir-gid && "$*" == *'%u:%g:%a'* ]]; then
                printf '%s:%s:700\n' "$EUID" "$other_gid"
            else command stat "$@"; fi
        }
        assert_fail "reject known_hosts $known_identity_case" prepare_known_hosts
    )
done

# --test-auth must execute real fake SSH true calls for every server without rsync.
(
    trap - EXIT HUP INT TERM
    root="$TEST_DIR/auth-key"; mkdir -m 0700 "$root" "$root/bin" "$root/capture"
    cat > "$root/bin/timeout" <<'EOF'
#!/usr/bin/env bash
shift
exec "$@"
EOF
    cat > "$root/bin/sshpass" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${SSHPASS:+set}" >> "$CAPTURE_DIR/sshpass"
[[ ${1:-} == -e ]] && shift
exec "$@"
EOF
    cat > "$root/bin/ssh" <<'EOF'
#!/usr/bin/env bash
count=0; [[ -f "$CAPTURE_DIR/count" ]] && count=$(<"$CAPTURE_DIR/count")
((count += 1)); printf '%s' "$count" > "$CAPTURE_DIR/count"
printf '%s\n' "$@" > "$CAPTURE_DIR/ssh.$count"
[[ " $* " == *' bad.example '* ]] && exit 1
exit 0
EOF
    cat > "$root/bin/rsync" <<'EOF'
#!/usr/bin/env bash
touch "$CAPTURE_DIR/rsync-called"
exit 1
EOF
    chmod 0700 "$root/bin"/*
    PATH="$root/bin:$PATH"; export PATH CAPTURE_DIR="$root/capture"
    TMPDIR="$root/runtime"; mkdir -m 0700 "$TMPDIR"
    key="$root/key"; printf key-material > "$key"; chmod 0600 "$key"
    AUTH_METHOD=key; KEY_FILE="$key"; STRICT_HOST_KEY_CHECKING=accept-new
    USER_KNOWN_HOSTS_FILE="$root/ssh/known_hosts"; ALLOW_INSECURE_HOST_KEY_STORAGE=false
    CONNECTION_TIMEOUT=12; TOTAL_TIMEOUT=20
    SERVERS=("root@example.com:2200" "admin@192.0.2.1" "root@[2001:db8::1]:2222")
    initialize_runtime; prepare_ssh_runtime
    runtime_key="$RUNTIME_KEY_FILE"
    test_authentication
    assert_eq 3 "$(<"$root/capture/count")" "test-auth executes SSH for every configured server"
    for call in "$root/capture"/ssh.*; do
        grep -Fxq true "$call" || fail "test-auth omitted no-op true command"
        grep -Fxq 'BatchMode=yes' "$call" || fail "key test-auth omitted BatchMode=yes"
        grep -Fxq "$runtime_key" "$call" || fail "key test-auth did not use runtime key copy"
    done
    pass "key test-auth uses BatchMode and verified runtime key copy"
    grep -Fxq 'UserKnownHostsFile='"$USER_KNOWN_HOSTS_FILE" "$root/capture/ssh.1" || fail "test-auth omitted known_hosts path"
    [[ ! -e "$root/capture/rsync-called" ]] || fail "test-auth called rsync"
    pass "test-auth performs no rsync or remote write"
    cleanup_runtime
    [[ ! -e "$runtime_key" ]] || fail "test-auth cleanup left runtime key"
)

(
    trap - EXIT HUP INT TERM
    root="$TEST_DIR/auth-password"; mkdir -m 0700 "$root" "$root/bin" "$root/capture"
    cat > "$root/bin/timeout" <<'EOF'
#!/usr/bin/env bash
shift
exec "$@"
EOF
    cat > "$root/bin/sshpass" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${SSHPASS:-}" > "$CAPTURE_DIR/password-seen"
[[ ${1:-} == -e ]] && shift
exec "$@"
EOF
    cat > "$root/bin/ssh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CAPTURE_DIR/ssh"
[[ "$*" == *bad.example* ]] && exit 1
exit 0
EOF
    chmod 0700 "$root/bin"/*
    PATH="$root/bin:$PATH"; export PATH CAPTURE_DIR="$root/capture"
    TMPDIR="$root/runtime"; mkdir -m 0700 "$TMPDIR"
    AUTH_METHOD=password; PASSWORD_METHOD=env; PASSWORD_ENV_VAR=AUTH_TEST_PASSWORD; export AUTH_TEST_PASSWORD=secret
    STRICT_HOST_KEY_CHECKING=yes; USER_KNOWN_HOSTS_FILE="$root/known_hosts"; ALLOW_INSECURE_HOST_KEY_STORAGE=false
    CONNECTION_TIMEOUT=10; TOTAL_TIMEOUT=15; SERVERS=("user@example.com")
    initialize_runtime; prepare_ssh_runtime
    test_authentication
    assert_file_eq secret "$root/capture/password-seen" "password test-auth passes SSHPASS through sshpass -e"
    grep -Fxq 'PreferredAuthentications=password' "$root/capture/ssh" || fail "password wrapper omitted PreferredAuthentications"
    grep -Fxq 'NumberOfPasswordPrompts=1' "$root/capture/ssh" || fail "password wrapper omitted prompt limit"
    pass "password test-auth limits authentication and password prompts"
    SERVERS=("user@bad.example")
    assert_fail "test-auth returns nonzero when any server fails" test_authentication
    cleanup_runtime
    [[ -z "${SSHPASS:-}" ]] || fail "test-auth cleanup retained SSHPASS"
    pass "test-auth cleanup unsets SSHPASS"
)

# rsync argv boundaries, protect-args, special paths, option matrices, and no shell injection.
(
    trap - EXIT HUP INT TERM
    root="$TEST_DIR/rsync-argv"; mkdir -m 0700 "$root" "$root/bin" "$root/capture" "$root/runtime"
    cat > "$root/bin/timeout" <<'EOF'
#!/usr/bin/env bash
shift
exec "$@"
EOF
    cat > "$root/bin/sshpass" <<'EOF'
#!/usr/bin/env bash
printf called > "$CAPTURE_DIR/sshpass"
[[ ${1:-} == -e ]] && shift
exec "$@"
EOF
    cat > "$root/bin/rsync" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CAPTURE_DIR/rsync-args"
sleep 0.1
EOF
    chmod 0700 "$root/bin"/*
    PATH="$root/bin:$PATH"; export PATH CAPTURE_DIR="$root/capture"
    TMPDIR="$root/runtime"; initialize_runtime
    AUTH_METHOD=key; RUNTIME_KEY_FILE="$TEMP_DIR/key"; printf key > "$RUNTIME_KEY_FILE"; chmod 0600 "$RUNTIME_KEY_FILE"
    SSH_WRAPPER="$TEMP_DIR/ssh-wrapper"; printf '#!/usr/bin/env bash\nexit 0\n' > "$SSH_WRAPPER"; chmod 0700 "$SSH_WRAPPER"
    STRICT_HOST_KEY_CHECKING=accept-new; USER_KNOWN_HOSTS_FILE="$root/known hosts"
    CONNECTION_TIMEOUT=9; TOTAL_TIMEOUT=20; MAX_RETRIES=1; RETRY_DELAY=1
    RSYNC_ARCHIVE=true; RSYNC_COMPRESS=true; DELETE_EXTRA=true
    cd "$root"
    src='-source path'
    dst='remote path;$(touch injected-marker) (value)'
    retry_rsync 'user@example.com:2222' "$src" "$dst"
    mapfile -t args < "$root/capture/rsync-args"
    protect_index=-1; separator_index=-1; source_index=-1
    for i in "${!args[@]}"; do
        [[ "${args[$i]}" == --protect-args ]] && protect_index=$i
        [[ "${args[$i]}" == -- ]] && separator_index=$i
        [[ "${args[$i]}" == "$src" ]] && source_index=$i
    done
    (( protect_index >= 0 )) || fail "rsync omitted --protect-args"
    (( separator_index >= 0 && source_index == separator_index + 1 )) || fail "rsync -- is not immediately before source"
    assert_eq "user@example.com:$dst" "${args[$((source_index + 1))]}" "rsync preserves remote destination as one argv"
    grep -Fxq -- "$src" "$root/capture/rsync-args" || fail "rsync lost leading-dash source"
    grep -Fxq -- -a "$root/capture/rsync-args" || fail "archive=true omitted -a"
    grep -Fxq -- -z "$root/capture/rsync-args" || fail "compress=true omitted -z"
    grep -Fxq -- --delete "$root/capture/rsync-args" || fail "delete=true omitted --delete"
    [[ ! -e "$root/injected-marker" ]] || fail "remote destination executed shell injection"
    pass "rsync special paths remain argv data and create no injection marker"

    : > "$root/capture/rsync-args"; rm -f "$root/capture/sshpass"
    AUTH_METHOD=password; export SSHPASS=secret
    RSYNC_ARCHIVE=false; RSYNC_COMPRESS=false; DELETE_EXTRA=false
    retry_rsync 'root@[2001:db8::2]:2201' 'source with spaces' 'destination $x;()'
    grep -Fxq -- -r "$root/capture/rsync-args" || fail "archive=false omitted -r"
    if grep -Fxq -- -a "$root/capture/rsync-args" || grep -Fxq -- -z "$root/capture/rsync-args" || grep -Fxq -- --delete "$root/capture/rsync-args"; then
        fail "disabled archive/compress/delete option leaked into rsync argv"
    fi
    assert_file_eq called "$root/capture/sshpass" "password rsync uses sshpass"
    grep -Fxq 'root@[2001:db8::2]:destination $x;()' "$root/capture/rsync-args" || fail "IPv6 remote destination boundary lost"
    pass "rsync option matrix and IPv6 destination are preserved"
    cd "$ROOT_DIR"
    cleanup_runtime
)

# Sliding concurrency and normal/partial/all-failure result status with fake rsync.
(
    trap - EXIT HUP INT TERM
    root="$TEST_DIR/rsync-status"; mkdir -m 0700 "$root" "$root/bin" "$root/state" "$root/runtime"
    cat > "$root/bin/timeout" <<'EOF'
#!/usr/bin/env bash
shift
exec "$@"
EOF
    cat > "$root/bin/rsync" <<'EOF'
#!/usr/bin/env bash
last=${!#}
exec 9>"$STATE_DIR/lock"
flock -x 9
current=0; [[ -f "$STATE_DIR/current" ]] && current=$(<"$STATE_DIR/current")
((current += 1)); printf '%s' "$current" > "$STATE_DIR/current"
max=0; [[ -f "$STATE_DIR/max" ]] && max=$(<"$STATE_DIR/max")
(( current > max )) && printf '%s' "$current" > "$STATE_DIR/max"
flock -u 9
sleep 0.2
flock -x 9
current=$(<"$STATE_DIR/current"); ((current -= 1)); printf '%s' "$current" > "$STATE_DIR/current"
flock -u 9
[[ "$last" == *bad* ]] && exit 1
exit 0
EOF
    chmod 0700 "$root/bin"/*
    PATH="$root/bin:$PATH"; export PATH STATE_DIR="$root/state"
    TMPDIR="$root/runtime"; initialize_runtime
    AUTH_METHOD=key; RUNTIME_KEY_FILE="$TEMP_DIR/key"; printf key > "$RUNTIME_KEY_FILE"; chmod 0600 "$RUNTIME_KEY_FILE"
    SSH_WRAPPER="$TEMP_DIR/wrapper"; printf '#!/usr/bin/env bash\nexit 0\n' > "$SSH_WRAPPER"; chmod 0700 "$SSH_WRAPPER"
    STRICT_HOST_KEY_CHECKING=accept-new; USER_KNOWN_HOSTS_FILE="$root/known"
    CONNECTION_TIMEOUT=5; TOTAL_TIMEOUT=10; MAX_RETRIES=1; RETRY_DELAY=1
    RSYNC_ARCHIVE=true; RSYNC_COMPRESS=false; DELETE_EXTRA=false; MAX_PARALLEL=2
    SERVERS=(good1 good2 good3 good4)
    run_transfer source destination
    assert_eq 2 "$(<"$root/state/max")" "sliding concurrency respects MAX_PARALLEL while keeping window full"
    : > "$SUCCESS_FILE"; : > "$FAILED_FILE"; : > "$root/state/current"; : > "$root/state/max"
    SERVERS=(good1 bad1 good2)
    assert_fail "partial server failure returns nonzero" run_transfer source destination
    assert_eq 1 "$(wc -l < "$FAILED_FILE")" "partial failure records one failed server"
    : > "$SUCCESS_FILE"; : > "$FAILED_FILE"; : > "$root/state/current"; : > "$root/state/max"
    SERVERS=(bad1 bad2)
    assert_fail "all server failures return nonzero" run_transfer source destination
    assert_eq 2 "$(wc -l < "$FAILED_FILE")" "all failures record every server"
    cleanup_runtime
)

# Delete authorization remains explicit.
(
    trap - EXIT HUP INT TERM
    DELETE_EXTRA=true; ALLOW_DELETE_EXTRA=false
    assert_fail "non-interactive delete requires explicit authorization" prepare_delete_authorization
    ALLOW_DELETE_EXTRA=true
    prepare_delete_authorization
    pass "explicit non-interactive delete authorization remains supported"
)

# Full CLI success/failure keeps exit status and performs idempotent EXIT cleanup.
run_cli_status_case() {
    local name="$1" expected="$2" servers_literal="$3"
    local root="$TEST_DIR/cli-$name" rc=0
    mkdir -m 0700 "$root" "$root/bin" "$root/runtime" "$root/ssh"
    printf source > "$root/source"
    cat > "$root/config.conf" <<EOF
AUTH_METHOD="password"
PASSWORD_METHOD="inline"
PASSWORD="cli-secret"
DEFAULT_PORT=22
DEFAULT_USER="root"
MAX_PARALLEL=2
CONNECTION_TIMEOUT=5
TOTAL_TIMEOUT=10
MAX_RETRIES=1
RETRY_DELAY=1
DELETE_EXTRA="false"
ALLOW_DELETE_EXTRA="false"
RSYNC_ARCHIVE="true"
RSYNC_COMPRESS="false"
SERVERS=($servers_literal)
declare -A TASKS=()
ENABLE_LOGGING="false"
STRICT_HOST_KEY_CHECKING="accept-new"
USER_KNOWN_HOSTS_FILE="$root/ssh/known_hosts"
ALLOW_INSECURE_HOST_KEY_STORAGE="false"
EOF
    chmod 0600 "$root/config.conf"
    cat > "$root/bin/timeout" <<'EOF'
#!/usr/bin/env bash
shift
exec "$@"
EOF
    cat > "$root/bin/sshpass" <<'EOF'
#!/usr/bin/env bash
[[ ${1:-} == -e ]] && shift
exec "$@"
EOF
    cat > "$root/bin/rsync" <<'EOF'
#!/usr/bin/env bash
last=${!#}
sleep 0.05
[[ "$last" == *bad* ]] && exit 1
exit 0
EOF
    cat > "$root/bin/ssh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod 0700 "$root/bin"/*
    (
        cd "$root"
        env PATH="$root/bin:$PATH" TMPDIR="$root/runtime" \
            "$SCRIPT" "$root/source" /remote/path
    ) > "$root/output.log" 2>&1 || rc=$?
    assert_eq "$expected" "$rc" "full CLI $name preserves result status"
    [[ -z "$(find "$root/runtime" -mindepth 1 -maxdepth 1 -name 'push-runtime.*' -print -quit)" ]] || fail "full CLI $name left runtime directory"
    pass "full CLI $name EXIT cleanup removes runtime directory"
    [[ -f "$root/config.conf" && -f "$root/ssh/known_hosts" ]] || fail "full CLI $name deleted persistent files"
    pass "full CLI $name preserves config and known_hosts"
}

run_cli_status_case success 0 '"good.example"'
run_cli_status_case partial 1 '"good.example" "bad.example"'
run_cli_status_case failure 1 '"bad1.example" "bad2.example"'

# Real process-tree cleanup under HUP/INT/TERM; all commands are local fakes.
write_signal_fixture() {
    local root="$1"
    mkdir -m 0700 "$root" "$root/bin" "$root/runtime" "$root/ssh"
    printf source > "$root/source"
    cat > "$root/config.conf" <<EOF
AUTH_METHOD="password"
PASSWORD_METHOD="inline"
PASSWORD="signal-secret"
DEFAULT_PORT=22
DEFAULT_USER="root"
MAX_PARALLEL=1
CONNECTION_TIMEOUT=5
TOTAL_TIMEOUT=60
MAX_RETRIES=1
RETRY_DELAY=1
DELETE_EXTRA="false"
ALLOW_DELETE_EXTRA="false"
RSYNC_ARCHIVE="true"
RSYNC_COMPRESS="false"
SERVERS=("root@example.com")
declare -A TASKS=()
ENABLE_LOGGING="false"
STRICT_HOST_KEY_CHECKING="accept-new"
USER_KNOWN_HOSTS_FILE="$root/ssh/known_hosts"
ALLOW_INSECURE_HOST_KEY_STORAGE="false"
EOF
    chmod 0600 "$root/config.conf"
    cat > "$root/bin/timeout" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$PID_DIR/timeout.pid"
shift
"$@" &
wait "$!"
EOF
    cat > "$root/bin/sshpass" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$PID_DIR/sshpass.pid"
[[ ${1:-} == -e ]] && shift
"$@" &
wait "$!"
EOF
    cat > "$root/bin/rsync" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$PID_DIR/rsync.pid"
ssh fake-target &
wait "$!"
EOF
    cat > "$root/bin/ssh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$PID_DIR/ssh.pid"
sleep 300 &
printf '%s\n' "$!" > "$PID_DIR/leaf.pid"
wait "$!"
EOF
    chmod 0700 "$root/bin"/*
}

process_is_running() {
    local pid="$1" state=""
    [[ -r "/proc/$pid/stat" ]] || return 1
    state=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null) || return 1
    [[ "$state" != Z ]]
}

run_process_tree_signal_case() {
    local signal_name="$1" expected_status="$2"
    local root="$TEST_DIR/process-$signal_name" pid rc=0 watchdog unrelated worker_pid timeout_pid
    write_signal_fixture "$root"
    mkdir -m 0700 "$root/pids"
    sleep 60 & unrelated=$!
    (
        cd "$root"
        exec env PATH="$root/bin:$PATH" TMPDIR="$root/runtime" PID_DIR="$root/pids" \
            "$SCRIPT" "$root/source" '/remote/path'
    ) > "$root/output.log" 2>&1 &
    pid=$!
    for _ in $(seq 1 300); do
        [[ -f "$root/pids/timeout.pid" && -f "$root/pids/sshpass.pid" && -f "$root/pids/rsync.pid" && -f "$root/pids/ssh.pid" && -f "$root/pids/leaf.pid" ]] && break
        sleep 0.05
    done
    [[ -f "$root/pids/leaf.pid" ]] || { cat "$root/output.log"; kill "$pid" "$unrelated" 2>/dev/null || true; fail "$signal_name process tree did not start"; }
    timeout_pid=$(<"$root/pids/timeout.pid")
    worker_pid=$(awk '{print $4}' "/proc/$timeout_pid/stat")
    (sleep 15; kill -KILL "$pid" 2>/dev/null || true) & watchdog=$!
    kill "-$signal_name" "$pid"
    wait "$pid" || rc=$?
    kill "$watchdog" 2>/dev/null || true; wait "$watchdog" 2>/dev/null || true
    assert_eq "$expected_status" "$rc" "$signal_name returns conventional push signal status"
    for pid_file in timeout sshpass rsync ssh leaf; do
        child_pid=$(<"$root/pids/$pid_file.pid")
        for _ in $(seq 1 100); do
            process_is_running "$child_pid" || break
            sleep 0.05
        done
        process_is_running "$child_pid" && fail "$signal_name left $pid_file process $child_pid"
    done
    process_is_running "$worker_pid" && fail "$signal_name left worker process $worker_pid"
    pass "$signal_name terminates worker, timeout, sshpass, rsync, ssh, and leaf processes"
    [[ -z "$(find "$root/runtime" -mindepth 1 -maxdepth 1 -name 'push-runtime.*' -print -quit)" ]] || fail "$signal_name left runtime directory"
    pass "$signal_name removes runtime directory"
    [[ -f "$root/config.conf" && -f "$root/ssh/known_hosts" ]] || fail "$signal_name deleted config or known_hosts"
    pass "$signal_name preserves config and known_hosts"
    kill -0 "$unrelated" 2>/dev/null || fail "$signal_name terminated unrelated process"
    pass "$signal_name preserves unrelated process"
    kill "$unrelated" 2>/dev/null || true; wait "$unrelated" 2>/dev/null || true
    [[ -z "${SSHPASS:-}" ]] || fail "$signal_name leaked SSHPASS to parent test shell"
    pass "$signal_name leaves no observable SSHPASS in subsequent test process"
}

run_process_tree_signal_case HUP 129
run_process_tree_signal_case INT 130
run_process_tree_signal_case TERM 143

printf 'All push tests passed.\n'
