#!/usr/bin/env bash
# shellcheck disable=SC2034  # Test globals are consumed by sourced tools/push.sh functions.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly ROOT_DIR
readonly SCRIPT="$ROOT_DIR/tools/push.sh"
TEST_DIR=$(mktemp -d)
readonly TEST_DIR
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

process_is_running() {
    local pid="$1" state=""
    [[ -r "/proc/$pid/stat" ]] || return 1
    state=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null) || return 1
    [[ "$state" != Z ]]
}

fixture_current_identity() {
    local pid="$1" stat_line="" stat_rest=""
    local -a fields=()
    FIXTURE_STATE=""; FIXTURE_START=""; FIXTURE_PPID=""; FIXTURE_PGID=""; FIXTURE_SID=""; FIXTURE_COMM=""
    [[ "$pid" =~ ^[1-9][0-9]*$ && -r "/proc/$pid/stat" ]] || return 1
    IFS= read -r stat_line < "/proc/$pid/stat" || return 1
    [[ "$stat_line" == "$pid ("* && "$stat_line" == *") "* ]] || return 1
    FIXTURE_COMM=${stat_line#*\(}; FIXTURE_COMM=${FIXTURE_COMM%%\) *}
    stat_rest=${stat_line##*) }; read -r -a fields <<< "$stat_rest"
    (( ${#fields[@]} >= 20 )) || return 1
    FIXTURE_STATE=${fields[0]}; FIXTURE_PPID=${fields[1]}; FIXTURE_PGID=${fields[2]}
    FIXTURE_SID=${fields[3]}; FIXTURE_START=${fields[19]}
}

fixture_identity_same() {
    fixture_current_identity "$1" && [[ "$FIXTURE_START" == "$2" ]]
}

wait_fixture_start() {
    local pid="$1" _
    for _ in {1..100}; do
        if fixture_current_identity "$pid"; then printf '%s\n' "$FIXTURE_START"; return 0; fi
        sleep 0.005
    done
    return 1
}

read_fixture_identity() {
    local file="$1" line="" key="" value="" count=0 metadata owner gid mode trusted_gid
    FIXTURE_ROLE=""; FIXTURE_FILE_PID=""; FIXTURE_FILE_START=""; FIXTURE_FILE_PPID=""
    FIXTURE_FILE_PGID=""; FIXTURE_FILE_SID=""; FIXTURE_FILE_STATE=""; FIXTURE_FILE_COMM=""
    [[ -f "$file" && ! -L "$file" ]] || return 1
    metadata=$(stat -Lc '%u:%g:%a' -- "$file") || return 1
    IFS=: read -r owner gid mode <<< "$metadata"; trusted_gid=$(current_gid) || return 1
    [[ "$owner" == "$EUID" && "$gid" == "$trusted_gid" && "$mode" == 600 ]] || return 1
    while IFS= read -r line; do
        ((count += 1)); [[ "$line" == *=* ]] || return 1
        key=${line%%=*}; value=${line#*=}
        case "$key" in
            role) FIXTURE_ROLE=$value ;; pid) FIXTURE_FILE_PID=$value ;; start) FIXTURE_FILE_START=$value ;;
            ppid) FIXTURE_FILE_PPID=$value ;; pgid) FIXTURE_FILE_PGID=$value ;; sid) FIXTURE_FILE_SID=$value ;;
            state) FIXTURE_FILE_STATE=$value ;; comm) FIXTURE_FILE_COMM=$value ;; *) return 1 ;;
        esac
    done < "$file"
    (( count == 8 )) && [[ "$FIXTURE_FILE_PID" =~ ^[1-9][0-9]*$ && "$FIXTURE_FILE_START" =~ ^[1-9][0-9]*$ &&
        "$FIXTURE_FILE_PPID" =~ ^[0-9]+$ && "$FIXTURE_FILE_PGID" =~ ^[1-9][0-9]*$ && "$FIXTURE_FILE_SID" =~ ^[1-9][0-9]*$ ]]
}

wait_fixture_identity_gone() {
    local pid="$1" start="$2" _
    for _ in {1..100}; do fixture_identity_same "$pid" "$start" || return 0; sleep 0.05; done
    return 1
}

dump_fixture_process() {
    local role="$1" pid="$2" start="$3"
    printf '%s\n' "=== $role pid=$pid expected_start=$start ===" >&2
    if fixture_current_identity "$pid"; then
        printf 'state=%s start=%s ppid=%s pgid=%s sid=%s comm=%s same=%s\n' \
            "$FIXTURE_STATE" "$FIXTURE_START" "$FIXTURE_PPID" "$FIXTURE_PGID" "$FIXTURE_SID" "$FIXTURE_COMM" \
            "$([[ "$FIXTURE_START" == "$start" ]] && echo yes || echo no)" >&2
        cat "/proc/$pid/stat" >&2 2>/dev/null || true
        cat "/proc/$pid/status" >&2 2>/dev/null || true
        tr '\0' ' ' < "/proc/$pid/cmdline" >&2 2>/dev/null || true; echo >&2
    else
        echo absent >&2
    fi
}

signal_test_watchdog() {
    local root="$1" target_pid="$2" timer="" stage=""
    trap '[[ -z "$timer" ]] || kill "$timer" 2>/dev/null || true; [[ -z "$timer" ]] || wait "$timer" 2>/dev/null || true; exit 0' HUP INT TERM
    sleep 30 & timer=$!; wait "$timer" 2>/dev/null || exit 0
    stage="$root/.watchdog-fired.$BASHPID.stage"
    (umask 077; set -o noclobber; : > "$stage") || exit 1
    mv -fT "$stage" "$root/watchdog-fired"
    kill -KILL "$target_pid" 2>/dev/null || true
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
assert_eq admin@example.com "$PARSED_SSH_TARGET" "parse DNS SSH target"
assert_eq admin@example.com "$PARSED_RSYNC_TARGET" "parse DNS rsync target"
assert_eq 2222 "$PARSED_PORT" "parse explicit port"
parse_server_info "root@192.0.2.10" || fail "parse IPv4 server"
assert_eq root@192.0.2.10 "$PARSED_SSH_TARGET" "parse IPv4 SSH target"
parse_server_info "root@[2001:db8::1]:2200" || fail "parse IPv6 server"
assert_eq 'root@2001:db8::1' "$PARSED_SSH_TARGET" "direct SSH IPv6 target omits brackets"
assert_eq 'root@[2001:db8::1]' "$PARSED_RSYNC_TARGET" "rsync IPv6 target preserves brackets"
assert_eq 'root@[2001:db8::1]' "$PARSED_DISPLAY_TARGET" "display IPv6 target preserves brackets"
assert_eq 2200 "$PARSED_PORT" "parse IPv6 port"
assert_fail "reject bare IPv6" parse_server_info "2001:db8::1"
assert_fail "reject leading-dash user" parse_server_info "-o@host"
assert_fail "reject leading-dash host" parse_server_info "root@-host"
assert_fail "reject whitespace in server" parse_server_info "root@bad host"
assert_fail "reject newline in server" parse_server_info $'root@host\n-oProxyCommand=x'
assert_fail "reject port zero" parse_server_info "root@host:0"
assert_fail "reject port above 65535" parse_server_info "root@host:65536"

(
    trap - EXIT HUP INT TERM
    proc_pid=$BASHPID
    original_comm=$(<"/proc/$proc_pid/comm")
    printf 'push ) worker' > "/proc/$proc_pid/comm"
    read_process_record "$proc_pid" || fail "proc parser rejected comm with space and right parenthesis"
    parsed_start="$PROC_START"
    [[ "$PROC_PGID" =~ ^[0-9]+$ && "$PROC_SID" =~ ^[0-9]+$ && "$parsed_start" =~ ^[0-9]+$ ]] || fail "proc parser returned invalid identity fields"
    process_identity_matches "$proc_pid" "$parsed_start" || fail "proc identity check failed for complex comm"
    pass "proc stat parser handles comm with spaces and right parenthesis"
    printf '%s\n' "$original_comm" > "/proc/$proc_pid/comm"
)

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
    runtime_allocator_process() { return 1; }
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

cat > "$TEST_DIR/runtime-building-signal-child.sh" <<'RUNTIME_BUILDING_SIGNAL_CHILD'
#!/usr/bin/env bash
set -euo pipefail
root="$1"
script="$2"
mkdir -m 0700 "$root/runtime"
export TMPDIR="$root/runtime"
source "$script"
runtime_building_hook() {
    printf '%s\n' "$1" > "$root/building-path"
    touch "$root/ready"
    while :; do :; done
}
install_runtime_traps
initialize_runtime
RUNTIME_BUILDING_SIGNAL_CHILD
chmod 0700 "$TEST_DIR/runtime-building-signal-child.sh"

run_runtime_building_signal_case() {
    local signal_name="$1" expected_status="$2" root=""
    local pid rc=0
    root="$TEST_DIR/runtime-building-$signal_name"
    mkdir -m 0700 "$root"
    env --default-signal=HUP,INT,TERM \
        bash "$TEST_DIR/runtime-building-signal-child.sh" "$root" "$SCRIPT" > "$root/output.log" 2>&1 &
    pid=$!
    for _ in $(seq 1 200); do [[ -e "$root/ready" ]] && break; sleep 0.05; done
    [[ -e "$root/ready" ]] || { cat "$root/output.log"; kill "$pid" 2>/dev/null || true; fail "$signal_name runtime building hook did not block"; }
    kill "-$signal_name" "$pid"
    wait "$pid" || rc=$?
    assert_eq "$expected_status" "$rc" "$signal_name during first runtime metadata window returns conventional status"
    [[ -z "$(find "$root/runtime" -mindepth 1 -maxdepth 1 -name 'push-runtime.*' -print -quit)" ]] || fail "$signal_name runtime building signal left runtime"
    pass "$signal_name runtime building cleanup removes incomplete directory and files"
}

run_runtime_building_signal_case HUP 129
run_runtime_building_signal_case INT 130
run_runtime_building_signal_case TERM 143

cat > "$TEST_DIR/runtime-allocator-signal-child.sh" <<'RUNTIME_ALLOCATOR_SIGNAL_CHILD'
#!/usr/bin/env bash
set -euo pipefail
root="$1"
script="$2"
mkdir -m 0700 "$root/runtime"
export TMPDIR="$root/runtime"
source "$script"
runtime_allocator_after_create_hook() {
    printf '%s\n' "$1" > "$root/allocator-path"
    touch "$root/ready"
    while :; do :; done
}
install_runtime_traps
initialize_runtime
RUNTIME_ALLOCATOR_SIGNAL_CHILD
chmod 0700 "$TEST_DIR/runtime-allocator-signal-child.sh"

run_runtime_allocator_signal_case() {
    local delivery="$1" signal_name="$2" expected_status="$3" root=""
    local pid rc=0 watchdog
    root="$TEST_DIR/runtime-allocator-$delivery-$signal_name"
    mkdir -m 0700 "$root"
    setsid env --default-signal=HUP,INT,TERM \
        bash "$TEST_DIR/runtime-allocator-signal-child.sh" "$root" "$SCRIPT" > "$root/output.log" 2>&1 &
    pid=$!
    for _ in $(seq 1 200); do [[ -e "$root/ready" ]] && break; sleep 0.05; done
    [[ -e "$root/ready" ]] || { cat "$root/output.log"; kill "$pid" 2>/dev/null || true; fail "$delivery/$signal_name allocator did not block after mkdir"; }
    signal_test_watchdog "$root" "$pid" & watchdog=$!
    if [[ "$delivery" == direct ]]; then
        kill "-$signal_name" "$pid"
    else
        kill "-$signal_name" -- "-$pid"
    fi
    wait "$pid" || rc=$?
    kill -TERM "$watchdog" 2>/dev/null || true; wait "$watchdog" 2>/dev/null || true
    [[ ! -e "$root/watchdog-fired" ]] || fail "$delivery/$signal_name allocator watchdog fired"
    assert_eq "$expected_status" "$rc" "$delivery $signal_name during allocator post-mkdir window returns conventional status"
    # allocator helper 与 parent 的 building 清理在高负载下可能晚于主 PID 退出；最多等待 15 秒观察受管 candidate 消失。
    for _ in $(seq 1 300); do
        [[ -z "$(find "$root/runtime" -mindepth 1 -maxdepth 1 -name 'push-runtime.*' -print -quit)" ]] && break
        sleep 0.05
    done
    [[ -z "$(find "$root/runtime" -mindepth 1 -maxdepth 1 -name 'push-runtime.*' -print -quit)" ]] || fail "$delivery/$signal_name allocator signal left candidate"
    pass "$delivery $signal_name allocator helper and parent leave no runtime candidate"
}

for allocator_delivery in direct group; do
    run_runtime_allocator_signal_case "$allocator_delivery" HUP 129
    run_runtime_allocator_signal_case "$allocator_delivery" INT 130
    run_runtime_allocator_signal_case "$allocator_delivery" TERM 143
done

(
    trap - EXIT HUP INT TERM
    root="$TEST_DIR/runtime-collision"; mkdir -m 0700 "$root" "$root/runtime"
    collision="$root/runtime/push-runtime.collision"
    mkdir -m 0700 "$collision"; printf keep > "$collision/owner-data"
    counter="$root/token-counter"; printf 0 > "$counter"
    runtime_random_token() {
        local count; count=$(<"$counter"); ((count += 1)); printf '%s' "$count" > "$counter"
        (( count == 1 )) && printf 'collision\n' || printf 'unique\n'
    }
    TMPDIR="$root/runtime"
    initialize_runtime
    [[ "$TEMP_DIR" == "$root/runtime/push-runtime.unique" ]] || fail "allocator collision did not retry a new candidate"
    assert_file_eq keep "$collision/owner-data" "allocator collision preserves foreign directory"
    cleanup_runtime
    [[ -d "$collision" ]] || fail "runtime cleanup deleted collision directory"
    pass "allocator collision is never classified as owned"
    command rm -rf "$collision"
)

(
    trap - EXIT HUP INT TERM
    root="$TEST_DIR/runtime-helper-fail"; mkdir -m 0700 "$root" "$root/runtime"
    TMPDIR="$root/runtime"
    runtime_allocator_after_create_hook() { return 1; }
    assert_fail "allocator helper failure returns nonzero" initialize_runtime
    [[ "$RUNTIME_STATE" != initialized ]] || fail "allocator helper failure published initialized state"
    [[ -z "$(find "$root/runtime" -name 'push-runtime.*' -print -quit)" ]] || fail "allocator helper failure left candidate"
    pass "allocator helper cleans its candidate before failed handoff"
)

(
    trap - EXIT HUP INT TERM
    root="$TEST_DIR/runtime-unsafe-parent"; mkdir -m 0777 "$root"; mkdir -m 0700 "$root/child"
    TMPDIR="$root/child"
    assert_fail "reject non-sticky writable TMPDIR ancestor" initialize_runtime
    [[ -z "$(find "$root" -name 'push-runtime.*' -print -quit)" ]] || fail "unsafe TMPDIR ancestor created runtime"
    pass "unsafe TMPDIR ancestor fails before mktemp"
)

(
    trap - EXIT HUP INT TERM
    TMPDIR=/tmp
    initialize_runtime
    runtime_path="$TEMP_DIR"
    assert_eq 700 "$(stat -c %a "$runtime_path")" "sticky /tmp supports EUID-owned 0700 runtime"
    cleanup_runtime
)

cat > "$TEST_DIR/runtime-exit-cleanup-child.sh" <<'RUNTIME_EXIT_CLEANUP_CHILD'
#!/usr/bin/env bash
set -euo pipefail
root="$1"
script="$2"
requested_status="$3"
mkdir -m 0700 "$root/runtime"
export TMPDIR="$root/runtime"
source "$script"
install_runtime_traps
initialize_runtime
printf '%s\n' "$TEMP_DIR" > "$root/runtime-path"
rm() {
    local last=${!#}
    [[ "$last" == "$TEMP_DIR" ]] && return 1
    command rm "$@"
}
exit "$requested_status"
RUNTIME_EXIT_CLEANUP_CHILD
chmod 0700 "$TEST_DIR/runtime-exit-cleanup-child.sh"

run_runtime_exit_cleanup_failure_case() {
    local original_status="$1" expected_status="$2" root="$TEST_DIR/runtime-exit-fail-$1" rc=0 path=""
    mkdir -m 0700 "$root"
    bash "$TEST_DIR/runtime-exit-cleanup-child.sh" "$root" "$SCRIPT" "$original_status" > "$root/output.log" 2>&1 || rc=$?
    assert_eq "$expected_status" "$rc" "EXIT cleanup failure maps original $original_status to $expected_status"
    path=$(<"$root/runtime-path")
    [[ -d "$path" ]] || fail "EXIT cleanup failure did not preserve runtime path"
    grep -Fq "$path" "$root/output.log" || fail "EXIT cleanup failure omitted runtime residue path"
    pass "EXIT cleanup failure preserves and reports runtime residue"
    command rm -rf -- "$path"
}

run_runtime_exit_cleanup_failure_case 0 1
run_runtime_exit_cleanup_failure_case 7 7

(
    trap - EXIT HUP INT TERM
    root="$TEST_DIR/runtime-unowned-state"; mkdir -m 0700 "$root"
    TEMP_DIR="$root"; RUNTIME_STATE=none; RUNTIME_INITIALIZED=false
    assert_fail "runtime path without lifecycle state is residue error" cleanup_runtime
    [[ -d "$root" ]] || fail "state-less runtime cleanup deleted unproven path"
    pass "state-less runtime cleanup preserves unproven path"
    TEMP_DIR=""
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
chmod 0400 "$config"
load_config "$config"
pass "accept owner-only 0400 config"
chmod 0644 "$config"
assert_fail "reject 0644 config before source" load_config "$config"
chmod 0640 "$config"
assert_fail "reject 0640 config before source" load_config "$config"
chmod 0440 "$config"
assert_fail "reject 0440 config before source" load_config "$config"
chmod 0660 "$config"
assert_fail "reject 0660 config before source" load_config "$config"
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
        PASSWORD_METHOD="file"; PASSWORD_FILE="$password_file"
        assert_fail "reject password file $password_case" prepare_password_credentials
        cleanup_runtime
    )
done

(
    trap - EXIT HUP INT TERM
    root="$TEST_DIR/password-owner"; mkdir -m 0700 "$root"; make_runtime "$root/runtime"
    password_file="$root/password"; printf 'secret\n' > "$password_file"; chmod 0600 "$password_file"; PASSWORD_METHOD="file"; PASSWORD_FILE="$password_file"
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
    PASSWORD_METHOD="file"; PASSWORD_FILE="$password_file"
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
    PASSWORD_METHOD="env"; PASSWORD_ENV_VAR=PUSH_TEST_PASSWORD
    prepare_password_credentials
    assert_eq env-secret "$SSHPASS" "password env method remains supported"
    unset SSHPASS
    PASSWORD_METHOD="inline"; PASSWORD=inline-secret
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
    PASSWORD_METHOD="file"; PASSWORD_FILE="$password_file"
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

for forbidden_known_suffix in 'known hosts' '%h' '${VAR}' '"quoted"' 'back\slash' '../escape' './known'; do
    (
        trap - EXIT HUP INT TERM
        root=$(mktemp -d "$TEST_DIR/known-literal.XXXXXX"); chmod 0700 "$root"
        USER_KNOWN_HOSTS_FILE="$root/$forbidden_known_suffix"
        ALLOW_INSECURE_HOST_KEY_STORAGE=false
        assert_fail "reject known_hosts literal path $forbidden_known_suffix" prepare_known_hosts
    )
done

(
    trap - EXIT HUP INT TERM
    root="$TEST_DIR/known-unsafe-ancestor"; mkdir -m 0777 "$root"; mkdir -m 0700 "$root/child"
    USER_KNOWN_HOSTS_FILE="$root/child/known_hosts"; ALLOW_INSECURE_HOST_KEY_STORAGE=false
    assert_fail "reject non-sticky writable known_hosts ancestor" prepare_known_hosts
)

# --test-auth must execute real fake SSH true calls for every server without rsync.
(
    trap - EXIT HUP INT TERM
    root="$TEST_DIR/auth-key"; mkdir -m 0700 "$root" "$root/bin" "$root/capture"
    cat > "$root/bin/timeout" <<'EOF'
#!/usr/bin/env bash
[[ ${1:-} == --kill-after=* ]] && shift
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
for argument in "$@"; do
    [[ "$argument" == *@\[* ]] && exit 90
done
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
    mkdir -p "$root/home/.ssh"
    printf 'IdentityFile /tmp/hostile-key\nControlMaster auto\n' > "$root/home/.ssh/config"
    export HOME="$root/home" SSH_AUTH_SOCK="$root/hostile-agent.sock"
    initialize_runtime; prepare_ssh_runtime
    runtime_key="$RUNTIME_KEY_FILE"
    test_authentication
    assert_eq 3 "$(<"$root/capture/count")" "test-auth executes SSH for every configured server"
    for call in "$root/capture"/ssh.*; do
        grep -Fxq true "$call" || fail "test-auth omitted no-op true command"
        for required_option in 'BatchMode=yes' 'IdentitiesOnly=yes' 'IdentityAgent=none' \
            'IdentityFile=none' 'CertificateFile=none' \
            'PreferredAuthentications=publickey' 'PasswordAuthentication=no' \
            'KbdInteractiveAuthentication=no' 'ControlMaster=no' 'ControlPath=none' \
            'ClearAllForwardings=yes' 'ForkAfterAuthentication=no'; do
            grep -Fxq "$required_option" "$call" || fail "key test-auth omitted $required_option"
        done
        grep -Fxq none "$call" || fail "key test-auth omitted -F none"
        grep -Fxq "$runtime_key" "$call" || fail "key test-auth did not use runtime key copy"
        if grep -Fq /tmp/hostile-key "$call"; then fail "hostile SSH IdentityFile leaked into argv"; fi
    done
    pass "key test-auth isolates identity, agent, config, and connection sharing"
    grep -Fxq 'root@2001:db8::1' "$root/capture/ssh.3" || fail "direct SSH IPv6 target retained brackets"
    pass "direct SSH IPv6 target is unbracketed"
    grep -Fxq 'UserKnownHostsFile='"$USER_KNOWN_HOSTS_FILE" "$root/capture/ssh.1" || fail "test-auth omitted known_hosts path"
    [[ ! -e "$root/capture/rsync-called" ]] || fail "test-auth called rsync"
    pass "test-auth performs no rsync or remote write"
    auth_count_before=$(<"$root/capture/count")
    command mv "$USER_KNOWN_HOSTS_FILE" "$USER_KNOWN_HOSTS_FILE.real"
    ln -s "$USER_KNOWN_HOSTS_FILE.real" "$USER_KNOWN_HOSTS_FILE"
    assert_fail "SSH start revalidates known_hosts path" test_authentication
    assert_eq "$auth_count_before" "$(<"$root/capture/count")" "failed known_hosts revalidation starts no SSH"
    command rm -f "$USER_KNOWN_HOSTS_FILE"
    command mv "$USER_KNOWN_HOSTS_FILE.real" "$USER_KNOWN_HOSTS_FILE"
    cleanup_runtime
    [[ ! -e "$runtime_key" ]] || fail "test-auth cleanup left runtime key"
)

(
    trap - EXIT HUP INT TERM
    root="$TEST_DIR/auth-password"; mkdir -m 0700 "$root" "$root/bin" "$root/capture"
    cat > "$root/bin/timeout" <<'EOF'
#!/usr/bin/env bash
[[ ${1:-} == --kill-after=* ]] && shift
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
    AUTH_METHOD=password; PASSWORD_METHOD="env"; PASSWORD_ENV_VAR=AUTH_TEST_PASSWORD; export AUTH_TEST_PASSWORD=secret
    STRICT_HOST_KEY_CHECKING=yes; USER_KNOWN_HOSTS_FILE="$root/known_hosts"; ALLOW_INSECURE_HOST_KEY_STORAGE=false
    CONNECTION_TIMEOUT=10; TOTAL_TIMEOUT=15; SERVERS=("user@example.com")
    initialize_runtime; prepare_ssh_runtime
    test_authentication
    assert_file_eq secret "$root/capture/password-seen" "password test-auth passes SSHPASS through sshpass -e"
    for required_option in 'PreferredAuthentications=password' 'PubkeyAuthentication=no' \
        'PasswordAuthentication=yes' 'KbdInteractiveAuthentication=no' \
        'NumberOfPasswordPrompts=1' 'ControlMaster=no' 'ControlPath=none'; do
        grep -Fxq "$required_option" "$root/capture/ssh" || fail "password wrapper omitted $required_option"
    done
    grep -Fxq none "$root/capture/ssh" || fail "password wrapper omitted -F none"
    pass "password test-auth disables publickey and limits password prompts"
    SERVERS=("user@bad.example")
    assert_fail "test-auth returns nonzero when any server fails" test_authentication
    cleanup_runtime
    [[ -z "${SSHPASS:-}" ]] || fail "test-auth cleanup retained SSHPASS"
    pass "test-auth cleanup unsets SSHPASS"
)

readonly AUTH_SIGNAL_READINESS_SECONDS=15
# 生产清理上界约为主进程等待 worker 7s + 两轮 managed-session 2.2s + building 清理 2s；30s 超过两倍余量。
readonly AUTH_SIGNAL_WATCHDOG_SECONDS=30

declare -gA AUTH_READY_PID=() AUTH_READY_START=()
AUTH_READY_STATE_FILE=""
AUTH_READY_STATE_IDENTITY=""
AUTH_READY_STATE_CONTENT=""
AUTH_READY_PID_SIGNATURE=""
AUTH_CASE_MAIN_PID=""; AUTH_CASE_MAIN_START=""
AUTH_CASE_WATCHDOG_PID=""; AUTH_CASE_WATCHDOG_START=""
AUTH_CASE_UNRELATED_PID=""; AUTH_CASE_UNRELATED_START=""

write_auth_signal_fixture() {
    local root="$1" mode="$2"
    mkdir -m 0700 "$root" "$root/bin" "$root/runtime" "$root/ssh" "$root/pids"
    if [[ "$mode" == key ]]; then
        printf key-material > "$root/key"; chmod 0600 "$root/key"
        auth_config=$(cat <<EOF
AUTH_METHOD="key"
KEY_FILE="$root/key"
EOF
)
    else
        auth_config=$(cat <<'EOF'
AUTH_METHOD="password"
PASSWORD_METHOD="inline"
PASSWORD="auth-signal-secret"
EOF
)
    fi
    cat > "$root/config.conf" <<EOF
$auth_config
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
SERVERS=("root@[2001:db8::10]:2222")
declare -A TASKS=()
ENABLE_LOGGING="false"
STRICT_HOST_KEY_CHECKING="accept-new"
USER_KNOWN_HOSTS_FILE="$root/ssh/known_hosts"
ALLOW_INSECURE_HOST_KEY_STORAGE="false"
EOF
    chmod 0600 "$root/config.conf"
    cat > "$root/bin/timeout" <<'EOF'
#!/usr/bin/env bash
self=$BASHPID
stage="$PID_DIR/.timeout.pid.$self"
(umask 077; printf '%s\n' "$self" > "$stage")
mv -fT -- "$stage" "$PID_DIR/timeout.pid"
child=""
cleanup() { local status="$1"; trap - HUP INT TERM; [[ -z "$child" ]] || { kill -TERM "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true; }; exit "$status"; }
trap 'cleanup 129' HUP; trap 'cleanup 130' INT; trap 'cleanup 143' TERM
[[ ${1:-} == --kill-after=* ]] && shift
shift
"$@" & child=$!
wait "$child"; status=$?; child=""; exit "$status"
EOF
    cat > "$root/bin/sshpass" <<'EOF'
#!/usr/bin/env bash
self=$BASHPID
stage="$PID_DIR/.sshpass.pid.$self"
(umask 077; printf '%s\n' "$self" > "$stage")
mv -fT -- "$stage" "$PID_DIR/sshpass.pid"
child=""
cleanup() { local status="$1"; trap - HUP INT TERM; [[ -z "$child" ]] || { kill -TERM "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true; }; exit "$status"; }
trap 'cleanup 129' HUP; trap 'cleanup 130' INT; trap 'cleanup 143' TERM
[[ ${1:-} == -e ]] && shift
"$@" & child=$!
wait "$child"; status=$?; child=""; exit "$status"
EOF
    cat > "$root/bin/ssh" <<'EOF'
#!/usr/bin/env bash
self=$BASHPID
stage="$PID_DIR/.ssh.pid.$self"
(umask 077; printf '%s\n' "$self" > "$stage")
mv -fT -- "$stage" "$PID_DIR/ssh.pid"
leaf=""
cleanup() { local status="$1"; trap - HUP INT TERM; [[ -z "$leaf" ]] || { kill -TERM "$leaf" 2>/dev/null || true; wait "$leaf" 2>/dev/null || true; }; exit "$status"; }
trap 'cleanup 129' HUP; trap 'cleanup 130' INT; trap 'cleanup 143' TERM
for argument in "$@"; do [[ "$argument" == *@\[* ]] && exit 90; done
sleep 300 & leaf=$!
stage="$PID_DIR/.leaf.pid.$BASHPID"
(umask 077; printf '%s\n' "$leaf" > "$stage")
mv -fT -- "$stage" "$PID_DIR/leaf.pid"
wait "$leaf"; status=$?; leaf=""; exit "$status"
EOF
    cat > "$root/bin/rsync" <<'EOF'
#!/usr/bin/env bash
touch "$PID_DIR/rsync-unexpected"
exit 1
EOF
    chmod 0700 "$root/bin"/*
}

read_auth_fixture_pid() {
    local file="$1" name="$2" pid line_count
    [[ -f "$file" && ! -L "$file" ]] || return 1
    IFS= read -r pid < "$file" || return 1
    line_count=$(wc -l < "$file") || return 1
    [[ "$line_count" == 1 && "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    read_process_record "$pid" || return 1
    [[ "$PROC_UID" == "$EUID" && "$PROC_STATE" != Z ]] || return 1
    AUTH_READY_PID[$name]=$pid
    AUTH_READY_START[$name]=$PROC_START
}

capture_auth_session_readiness() {
    local root="$1" mode="$2" main_pid="$3" saved state_file metadata owner gid mode_bits dev inode
    local content line key value line_count=0 name pid signature=""
    local -a state_files=() required=(timeout ssh leaf)
    local -A values=() seen=()

    AUTH_READY_PID=(); AUTH_READY_START=(); AUTH_READY_STATE_FILE=""; AUTH_READY_STATE_IDENTITY=""
    AUTH_READY_STATE_CONTENT=""; AUTH_READY_PID_SIGNATURE=""
    read_process_record "$main_pid" || return 1
    [[ "$PROC_UID" == "$EUID" && "$PROC_STATE" != Z ]] || return 1
    [[ "$mode" == key ]] || required+=(sshpass)
    for name in "${required[@]}"; do
        read_auth_fixture_pid "$root/pids/$name.pid" "$name" || return 1
    done

    saved=$(shopt -p nullglob || true); shopt -s nullglob
    state_files=("$root"/runtime/push-runtime.*/worker-session.*.state)
    eval "$saved"
    (( ${#state_files[@]} == 1 )) || return 1
    state_file=${state_files[0]}
    [[ -f "$state_file" && ! -L "$state_file" ]] || return 1
    metadata=$(stat -c '%u:%g:%a:%d:%i' -- "$state_file") || return 1
    IFS=: read -r owner gid mode_bits dev inode <<< "$metadata"
    [[ "$owner" == "$EUID" && "$gid" == "$(id -g)" && "$mode_bits" == 600 ]] || return 1
    content=$(cat -- "$state_file" && printf '%s' '__AUTH_STATE_END__') || return 1
    content=${content%__AUTH_STATE_END__}
    while IFS= read -r line || [[ -n "$line" ]]; do
        ((line_count += 1)); [[ "$line" == *=* ]] || return 1
        key=${line%%=*}; value=${line#*=}; [[ -z "${seen[$key]:-}" ]] || return 1; seen[$key]=1
        case "$key" in
            version) [[ "$value" == 1 ]] || return 1 ;;
            state|worker_pid|worker_start|leader_pid|leader_start|pgid|sid) values[$key]=$value ;;
            *) return 1 ;;
        esac
    done < "$state_file"
    (( line_count == 8 && ${#seen[@]} == 8 )) || return 1
    [[ "${values[state]:-}" == active ]] || return 1
    for key in worker_pid worker_start leader_pid leader_start pgid sid; do
        [[ "${values[$key]:-}" =~ ^[1-9][0-9]*$ ]] || return 1
    done
    [[ "${state_file##*/}" == "worker-session.${values[worker_pid]}.state" ]] || return 1
    [[ "${values[leader_pid]}" == "${values[pgid]}" && "${values[leader_pid]}" == "${values[sid]}" ]] || return 1

    read_process_record "${values[worker_pid]}" || return 1
    [[ "$PROC_UID" == "$EUID" && "$PROC_STATE" != Z && "$PROC_START" == "${values[worker_start]}" ]] || return 1
    read_process_record "${values[leader_pid]}" || return 1
    [[ "$PROC_UID" == "$EUID" && "$PROC_STATE" != Z && "$PROC_START" == "${values[leader_start]}" &&
        "$PROC_PGID" == "${values[pgid]}" && "$PROC_SID" == "${values[sid]}" ]] || return 1
    for name in "${required[@]}"; do
        pid=${AUTH_READY_PID[$name]}
        read_process_record "$pid" || return 1
        [[ "$PROC_UID" == "$EUID" && "$PROC_STATE" != Z && "$PROC_START" == "${AUTH_READY_START[$name]}" &&
            "$PROC_PGID" == "${values[pgid]}" && "$PROC_SID" == "${values[sid]}" ]] || return 1
        signature+="$name:$pid:${AUTH_READY_START[$name]}|"
    done
    AUTH_READY_STATE_FILE=$state_file
    AUTH_READY_STATE_IDENTITY="$dev:$inode"
    AUTH_READY_STATE_CONTENT=$content
    AUTH_READY_PID_SIGNATURE=$signature
}

dump_auth_readiness_diagnostics() {
    local root="$1" file pid
    printf '%s\n' '--- auth readiness output.log ---' >&2
    cat "$root/output.log" >&2 2>/dev/null || true
    printf '%s\n' '--- auth readiness pid files ---' >&2
    for file in "$root"/pids/*.pid; do
        [[ -e "$file" || -L "$file" ]] || continue
        printf '%s: ' "$file" >&2; cat "$file" >&2 2>/dev/null || true
        pid=$(<"$file")
        if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && read_process_record "$pid"; then
            printf 'proc pid=%s state=%s start=%s pgid=%s sid=%s uid=%s\n' "$pid" "$PROC_STATE" "$PROC_START" "$PROC_PGID" "$PROC_SID" "$PROC_UID" >&2
        fi
    done
    printf '%s\n' '--- auth readiness runtime files ---' >&2
    find "$root/runtime" -mindepth 1 -maxdepth 3 -printf '%y %m %p\n' 2>/dev/null | sort >&2 || true
    printf '%s\n' '--- auth readiness session states ---' >&2
    for file in "$root"/runtime/push-runtime.*/worker-session.*.state; do
        [[ -e "$file" || -L "$file" ]] || continue
        printf '[%s]\n' "$file" >&2; cat "$file" >&2 2>/dev/null || true
    done
}

wait_for_auth_session_ready() {
    local root="$1" mode="$2" main_pid="$3" deadline first_file first_identity first_content first_signature
    deadline=$((SECONDS + AUTH_SIGNAL_READINESS_SECONDS))
    while (( SECONDS < deadline )); do
        if capture_auth_session_readiness "$root" "$mode" "$main_pid"; then
            first_file=$AUTH_READY_STATE_FILE; first_identity=$AUTH_READY_STATE_IDENTITY
            first_content=$AUTH_READY_STATE_CONTENT; first_signature=$AUTH_READY_PID_SIGNATURE
            sleep 0.05
            if capture_auth_session_readiness "$root" "$mode" "$main_pid" &&
                [[ "$AUTH_READY_STATE_FILE" == "$first_file" && "$AUTH_READY_STATE_IDENTITY" == "$first_identity" &&
                    "$AUTH_READY_STATE_CONTENT" == "$first_content" && "$AUTH_READY_PID_SIGNATURE" == "$first_signature" ]]; then
                return 0
            fi
        fi
        sleep 0.05
    done
    dump_auth_readiness_diagnostics "$root"
    return 1
}

wait_for_test_process_start() {
    local pid="$1" output_name="$2" _
    for _ in {1..200}; do
        if read_process_record "$pid" && [[ "$PROC_UID" == "$EUID" && "$PROC_STATE" != Z ]]; then
            printf -v "$output_name" '%s' "$PROC_START"
            return 0
        fi
        sleep 0.01
    done
    return 1
}

cleanup_auth_signal_case() {
    local name pid start _
    trap - EXIT HUP INT TERM
    for name in watchdog main unrelated; do
        case "$name" in
            watchdog) pid=$AUTH_CASE_WATCHDOG_PID; start=$AUTH_CASE_WATCHDOG_START ;;
            main) pid=$AUTH_CASE_MAIN_PID; start=$AUTH_CASE_MAIN_START ;;
            unrelated) pid=$AUTH_CASE_UNRELATED_PID; start=$AUTH_CASE_UNRELATED_START ;;
        esac
        [[ -n "$pid" && -n "$start" ]] || continue
        if process_identity_matches "$pid" "$start" && process_is_running "$pid"; then kill -TERM "$pid" 2>/dev/null || true; fi
    done
    for name in "${!AUTH_READY_PID[@]}"; do
        pid=${AUTH_READY_PID[$name]}; start=${AUTH_READY_START[$name]:-}
        [[ -n "$start" ]] || continue
        if process_identity_matches "$pid" "$start" && process_is_running "$pid"; then kill -TERM "$pid" 2>/dev/null || true; fi
    done
    for _ in {1..40}; do
        local active=false
        for name in watchdog main unrelated; do
            case "$name" in watchdog) pid=$AUTH_CASE_WATCHDOG_PID; start=$AUTH_CASE_WATCHDOG_START ;; main) pid=$AUTH_CASE_MAIN_PID; start=$AUTH_CASE_MAIN_START ;; unrelated) pid=$AUTH_CASE_UNRELATED_PID; start=$AUTH_CASE_UNRELATED_START ;; esac
            [[ -n "$pid" && -n "$start" ]] || continue
            process_identity_matches "$pid" "$start" && process_is_running "$pid" && active=true
        done
        [[ "$active" == false ]] && break
        sleep 0.05
    done
    for name in watchdog main unrelated; do
        case "$name" in watchdog) pid=$AUTH_CASE_WATCHDOG_PID; start=$AUTH_CASE_WATCHDOG_START ;; main) pid=$AUTH_CASE_MAIN_PID; start=$AUTH_CASE_MAIN_START ;; unrelated) pid=$AUTH_CASE_UNRELATED_PID; start=$AUTH_CASE_UNRELATED_START ;; esac
        [[ -n "$pid" && -n "$start" ]] || continue
        if process_identity_matches "$pid" "$start" && process_is_running "$pid"; then kill -KILL "$pid" 2>/dev/null || true; fi
        wait "$pid" 2>/dev/null || true
    done
    for name in "${!AUTH_READY_PID[@]}"; do
        pid=${AUTH_READY_PID[$name]}; start=${AUTH_READY_START[$name]:-}
        [[ -n "$start" ]] || continue
        if process_identity_matches "$pid" "$start" && process_is_running "$pid"; then kill -KILL "$pid" 2>/dev/null || true; fi
    done
}

run_auth_process_tree_signal_case() (
    local repeat="$1" mode="$2" signal_name="$3" expected_status="$4"
    local root="$TEST_DIR/auth-process-$repeat-$mode-$signal_name" rc=0 child_pid child_start watchdog_stage
    AUTH_READY_PID=(); AUTH_READY_START=()
    AUTH_CASE_MAIN_PID=""; AUTH_CASE_MAIN_START=""; AUTH_CASE_WATCHDOG_PID=""; AUTH_CASE_WATCHDOG_START=""
    AUTH_CASE_UNRELATED_PID=""; AUTH_CASE_UNRELATED_START=""
    trap cleanup_auth_signal_case EXIT HUP INT TERM
    write_auth_signal_fixture "$root" "$mode"
    sleep 60 & AUTH_CASE_UNRELATED_PID=$!
    wait_for_test_process_start "$AUTH_CASE_UNRELATED_PID" AUTH_CASE_UNRELATED_START || fail "$mode/$signal_name cannot identify unrelated process"
    (
        cd "$root"
        exec env --default-signal=HUP,INT,TERM PATH="$root/bin:$PATH" TMPDIR="$root/runtime" PID_DIR="$root/pids" \
            "$SCRIPT" --test-auth
    ) > "$root/output.log" 2>&1 &
    AUTH_CASE_MAIN_PID=$!
    wait_for_test_process_start "$AUTH_CASE_MAIN_PID" AUTH_CASE_MAIN_START || fail "$mode/$signal_name cannot identify push process"
    wait_for_auth_session_ready "$root" "$mode" "$AUTH_CASE_MAIN_PID" || fail "$mode/$signal_name auth session readiness timed out"
    (
        sleep_pid=""
        trap '[[ -z "$sleep_pid" ]] || { kill -TERM "$sleep_pid" 2>/dev/null || true; wait "$sleep_pid" 2>/dev/null || true; }; exit 0' HUP INT TERM
        sleep "$AUTH_SIGNAL_WATCHDOG_SECONDS" & sleep_pid=$!
        wait "$sleep_pid" || exit 0
        watchdog_stage="$root/pids/.watchdog-fired.$BASHPID"
        (umask 077; printf 'fired\n' > "$watchdog_stage")
        mv -fT -- "$watchdog_stage" "$root/pids/watchdog-fired"
        kill -KILL "$AUTH_CASE_MAIN_PID" 2>/dev/null || true
    ) &
    AUTH_CASE_WATCHDOG_PID=$!
    wait_for_test_process_start "$AUTH_CASE_WATCHDOG_PID" AUTH_CASE_WATCHDOG_START || fail "$mode/$signal_name cannot identify watchdog"
    kill "-$signal_name" "$AUTH_CASE_MAIN_PID"
    wait "$AUTH_CASE_MAIN_PID" || rc=$?
    AUTH_CASE_MAIN_PID=""; AUTH_CASE_MAIN_START=""
    if process_identity_matches "$AUTH_CASE_WATCHDOG_PID" "$AUTH_CASE_WATCHDOG_START" && process_is_running "$AUTH_CASE_WATCHDOG_PID"; then
        kill -TERM "$AUTH_CASE_WATCHDOG_PID" 2>/dev/null || true
    fi
    wait "$AUTH_CASE_WATCHDOG_PID" 2>/dev/null || true
    if process_identity_matches "$AUTH_CASE_WATCHDOG_PID" "$AUTH_CASE_WATCHDOG_START" && process_is_running "$AUTH_CASE_WATCHDOG_PID"; then
        fail "$mode/$signal_name left watchdog process"
    fi
    AUTH_CASE_WATCHDOG_PID=""; AUTH_CASE_WATCHDOG_START=""
    [[ ! -e "$root/pids/watchdog-fired" ]] || fail "push signal cleanup exceeded watchdog deadline"
    pass "$mode test-auth $signal_name run $repeat reaps watchdog before deadline"
    assert_eq "$expected_status" "$rc" "$mode test-auth $signal_name run $repeat returns conventional status"
    for name in "${!AUTH_READY_PID[@]}"; do
        child_pid=${AUTH_READY_PID[$name]}; child_start=${AUTH_READY_START[$name]}
        if process_identity_matches "$child_pid" "$child_start" && process_is_running "$child_pid"; then
            dump_fixture_process "$name" "$child_pid" "$child_start"
            cat "$root/output.log" >&2 2>/dev/null || true
            fail "$mode/$signal_name run $repeat left $name process"
        fi
    done
    pass "$mode test-auth $signal_name run $repeat terminates timeout, sshpass/ssh, and leaf descendants"
    [[ -z "$(find "$root/runtime" -mindepth 1 -maxdepth 1 -name 'push-runtime.*' -print -quit)" ]] || fail "$mode/$signal_name run $repeat left auth runtime"
    [[ -z "$(find "$root/runtime" -name 'worker-session.*.state' -print -quit)" ]] || fail "$mode/$signal_name run $repeat left session state"
    [[ ! -e "$root/pids/rsync-unexpected" ]] || fail "$mode/$signal_name run $repeat test-auth called rsync"
    pass "$mode test-auth $signal_name run $repeat removes runtime and session state without rsync"
    process_identity_matches "$AUTH_CASE_UNRELATED_PID" "$AUTH_CASE_UNRELATED_START" && process_is_running "$AUTH_CASE_UNRELATED_PID" || fail "$mode/$signal_name run $repeat terminated unrelated process"
    kill -TERM "$AUTH_CASE_UNRELATED_PID" 2>/dev/null || true; wait "$AUTH_CASE_UNRELATED_PID" 2>/dev/null || true
    AUTH_CASE_UNRELATED_PID=""; AUTH_CASE_UNRELATED_START=""
    [[ -z "${SSHPASS:-}" ]] || fail "$mode/$signal_name run $repeat leaked SSHPASS"
    pass "$mode test-auth $signal_name run $repeat preserves unrelated process, reaps watchdog, and leaves no SSHPASS"
    trap - EXIT HUP INT TERM
)

for auth_repeat in 1 2 3; do
    for auth_mode in key password; do
        run_auth_process_tree_signal_case "$auth_repeat" "$auth_mode" HUP 129
        run_auth_process_tree_signal_case "$auth_repeat" "$auth_mode" INT 130
        run_auth_process_tree_signal_case "$auth_repeat" "$auth_mode" TERM 143
    done
done

# rsync argv boundaries, protect-args, special paths, option matrices, and no shell injection.
(
    trap - EXIT HUP INT TERM
    root="$TEST_DIR/rsync-argv"; mkdir -m 0700 "$root" "$root/bin" "$root/capture" "$root/runtime"
    cat > "$root/bin/timeout" <<'EOF'
#!/usr/bin/env bash
[[ ${1:-} == --kill-after=* ]] && shift
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
    STRICT_HOST_KEY_CHECKING=accept-new; USER_KNOWN_HOSTS_FILE="$root/known_hosts"; ALLOW_INSECURE_HOST_KEY_STORAGE=false
    prepare_known_hosts
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
[[ ${1:-} == --kill-after=* ]] && shift
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
    STRICT_HOST_KEY_CHECKING=accept-new; USER_KNOWN_HOSTS_FILE="$root/known"; ALLOW_INSECURE_HOST_KEY_STORAGE=false
    prepare_known_hosts
    CONNECTION_TIMEOUT=5; TOTAL_TIMEOUT=10; MAX_RETRIES=1; RETRY_DELAY=1
    RSYNC_ARCHIVE=true; RSYNC_COMPRESS=false; DELETE_EXTRA=false; MAX_PARALLEL=2
    SERVERS=(good1 good2 good3 good4)
    run_transfer source destination
    assert_eq 2 "$(<"$root/state/max")" "sliding concurrency respects MAX_PARALLEL while keeping window full"
    [[ "$BATCH_WORKER_FAILED" == false ]] || fail "sliding batch left lifecycle failure flag"
    if (( ${#ACTIVE_WORKERS[@]} != 0 || ${#ACTIVE_WORKER_STATE_FILES[@]} != 0 ||
        ${#ACTIVE_WORKER_STATE_STARTS[@]} != 0 || ${#REGISTERING_WORKERS[@]} != 0 ||
        ${#WORKER_REGISTRATION_READY_FILES[@]} != 0 || ${#WORKER_REGISTRATION_RELEASE_FILES[@]} != 0 ||
        ${#WORKER_REGISTRATION_STARTS[@]} != 0 || ${#WORKER_REGISTRATION_STAGE_FILES[@]} != 0 )); then
        declare -p ACTIVE_WORKERS ACTIVE_WORKER_STATE_FILES ACTIVE_WORKER_STATE_STARTS REGISTERING_WORKERS \
            WORKER_REGISTRATION_READY_FILES WORKER_REGISTRATION_RELEASE_FILES WORKER_REGISTRATION_STARTS \
            WORKER_REGISTRATION_STAGE_FILES >&2
        fail "sliding batch left lifecycle maps"
    fi
    runtime_has_published_worker_state && fail "sliding batch left worker-session state"
    runtime_has_worker_registration_state && fail "sliding batch left registration state"
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

# TOTAL_TIMEOUT is a hard TERM-to-KILL boundary for resistant transfer and auth trees.
(
    trap - EXIT HUP INT TERM
    root="$TEST_DIR/hard-timeout-transfer"; mkdir -m 0700 "$root" "$root/bin" "$root/runtime" "$root/pids"
    cat > "$root/bin/rsync" <<'EOF'
#!/usr/bin/env bash
trap '' TERM
printf '%s\n' "$$" > "$PID_DIR/rsync.pid"
bash -c 'trap "" TERM; printf "%s\n" "$$" > "$PID_DIR/leaf.pid"; while :; do kill -STOP "$$"; done' &
wait "$!"
EOF
    chmod 0700 "$root/bin/rsync"
    PATH="$root/bin:$PATH"; export PATH PID_DIR="$root/pids"
    TMPDIR="$root/runtime"; initialize_runtime
    AUTH_METHOD=key; RUNTIME_KEY_FILE="$TEMP_DIR/key"; printf key > "$RUNTIME_KEY_FILE"; chmod 0600 "$RUNTIME_KEY_FILE"
    SSH_WRAPPER="$TEMP_DIR/wrapper"; printf '#!/usr/bin/env bash\nexit 0\n' > "$SSH_WRAPPER"; chmod 0700 "$SSH_WRAPPER"
    STRICT_HOST_KEY_CHECKING=accept-new; USER_KNOWN_HOSTS_FILE="$root/known_hosts"; ALLOW_INSECURE_HOST_KEY_STORAGE=false; prepare_known_hosts
    CONNECTION_TIMEOUT=2; TOTAL_TIMEOUT=1; TIMEOUT_KILL_AFTER=1; MAX_RETRIES=1; RETRY_DELAY=1
    RSYNC_ARCHIVE=true; RSYNC_COMPRESS=false; DELETE_EXTRA=false
    start=$(date +%s)
    assert_fail "TERM-resistant transfer hits hard timeout" retry_rsync good.example source destination
    duration=$(($(date +%s) - start))
    (( duration <= 5 )) || fail "hard transfer timeout exceeded bounded grace"
    for pid_file in rsync leaf; do child_pid=$(<"$root/pids/$pid_file.pid"); process_is_running "$child_pid" && fail "hard transfer timeout left $pid_file"; done
    pass "hard transfer timeout KILLs resistant command and descendants before retry"
    cleanup_runtime
)

(
    trap - EXIT HUP INT TERM
    root="$TEST_DIR/hard-timeout-auth"; mkdir -m 0700 "$root" "$root/bin" "$root/runtime" "$root/pids"
    cat > "$root/bin/ssh" <<'EOF'
#!/usr/bin/env bash
trap '' TERM
printf '%s\n' "$$" > "$PID_DIR/ssh.pid"
bash -c 'trap "" TERM; printf "%s\n" "$$" > "$PID_DIR/leaf.pid"; while :; do kill -STOP "$$"; done' &
wait "$!"
EOF
    chmod 0700 "$root/bin/ssh"
    PATH="$root/bin:$PATH"; export PATH PID_DIR="$root/pids"
    TMPDIR="$root/runtime"; initialize_runtime
    key="$root/key"; printf key > "$key"; chmod 0600 "$key"
    AUTH_METHOD=key; KEY_FILE="$key"; STRICT_HOST_KEY_CHECKING=accept-new
    USER_KNOWN_HOSTS_FILE="$root/known_hosts"; ALLOW_INSECURE_HOST_KEY_STORAGE=false
    CONNECTION_TIMEOUT=2; TOTAL_TIMEOUT=1; TIMEOUT_KILL_AFTER=1; SERVERS=(good.example)
    prepare_ssh_runtime
    start=$(date +%s)
    assert_fail "TERM-resistant auth hits hard timeout" test_authentication
    duration=$(($(date +%s) - start))
    (( duration <= 5 )) || fail "hard auth timeout exceeded bounded grace"
    for pid_file in ssh leaf; do child_pid=$(<"$root/pids/$pid_file.pid"); process_is_running "$child_pid" && fail "hard auth timeout left $pid_file"; done
    pass "hard auth timeout KILLs resistant SSH and descendants"
    cleanup_runtime
)

(
    trap - EXIT HUP INT TERM
    root="$TEST_DIR/cleanup-barrier-transfer"; mkdir -m 0700 "$root" "$root/bin" "$root/runtime" "$root/capture"
    cat > "$root/bin/timeout" <<'EOF'
#!/usr/bin/env bash
[[ ${1:-} == --kill-after=* ]] && shift
shift
exec "$@"
EOF
    cat > "$root/bin/rsync" <<'EOF'
#!/usr/bin/env bash
count=0; [[ -f "$CAPTURE_DIR/count" ]] && count=$(<"$CAPTURE_DIR/count")
((count += 1)); printf '%s' "$count" > "$CAPTURE_DIR/count"
sleep 0.2
exit 0
EOF
    chmod 0700 "$root/bin"/*
    PATH="$root/bin:$PATH"; export PATH CAPTURE_DIR="$root/capture"
    TMPDIR="$root/runtime"; initialize_runtime
    AUTH_METHOD=key; RUNTIME_KEY_FILE="$TEMP_DIR/key"; printf key > "$RUNTIME_KEY_FILE"; chmod 0600 "$RUNTIME_KEY_FILE"
    SSH_WRAPPER="$TEMP_DIR/wrapper"; printf '#!/usr/bin/env bash\nexit 0\n' > "$SSH_WRAPPER"; chmod 0700 "$SSH_WRAPPER"
    STRICT_HOST_KEY_CHECKING=accept-new; USER_KNOWN_HOSTS_FILE="$root/known_hosts"; ALLOW_INSECURE_HOST_KEY_STORAGE=false; prepare_known_hosts
    CONNECTION_TIMEOUT=2; TOTAL_TIMEOUT=5; TIMEOUT_KILL_AFTER=1; MAX_RETRIES=3; RETRY_DELAY=1
    RSYNC_ARCHIVE=true; RSYNC_COMPRESS=false; DELETE_EXTRA=false
    eval "$(declare -f terminate_managed_session | sed '1s/terminate_managed_session/original_terminate_managed_session/')"
    terminate_managed_session() { return 1; }
    rc=0; retry_rsync good.example source destination > "$root/output.log" 2>&1 || rc=$?
    assert_eq "$MANAGED_CLEANUP_FAILURE_STATUS" "$rc" "transfer cleanup failure returns dedicated barrier status"
    assert_eq 1 "$(<"$root/capture/count")" "cleanup failure prevents second rsync attempt"
    [[ "$WORKER_TRANSFER_CLEANUP_FAILED" == true && -n "$WORKER_TRANSFER_SID" && -f "$WORKER_SESSION_STATE_FILE" ]] || fail "cleanup failure did not preserve managed state"
    state_hash=$(sha256sum "$WORKER_SESSION_STATE_FILE")
    rc=0; run_managed_command "$TEMP_DIR/blocked-command" true || rc=$?
    assert_eq "$MANAGED_CLEANUP_FAILURE_STATUS" "$rc" "retry barrier rejects new managed command"
    assert_eq "$state_hash" "$(sha256sum "$WORKER_SESSION_STATE_FILE")" "retry barrier preserves old session state"
    pass "cleanup failure state is not overwritten"
    eval "$(declare -f original_terminate_managed_session | sed '1s/original_terminate_managed_session/terminate_managed_session/')"
    terminate_worker_transfer
    cleanup_runtime
)

(
    trap - EXIT HUP INT TERM
    root="$TEST_DIR/cleanup-barrier-auth"; mkdir -m 0700 "$root" "$root/bin" "$root/runtime" "$root/capture"
    cat > "$root/bin/timeout" <<'EOF'
#!/usr/bin/env bash
[[ ${1:-} == --kill-after=* ]] && shift
shift
exec "$@"
EOF
    cat > "$root/bin/ssh" <<'EOF'
#!/usr/bin/env bash
count=0; [[ -f "$CAPTURE_DIR/count" ]] && count=$(<"$CAPTURE_DIR/count")
((count += 1)); printf '%s' "$count" > "$CAPTURE_DIR/count"
sleep 0.2
exit 0
EOF
    chmod 0700 "$root/bin"/*
    PATH="$root/bin:$PATH"; export PATH CAPTURE_DIR="$root/capture"
    TMPDIR="$root/runtime"; initialize_runtime
    key="$root/key"; printf key > "$key"; chmod 0600 "$key"
    AUTH_METHOD=key; KEY_FILE="$key"; STRICT_HOST_KEY_CHECKING=accept-new
    USER_KNOWN_HOSTS_FILE="$root/known_hosts"; ALLOW_INSECURE_HOST_KEY_STORAGE=false
    CONNECTION_TIMEOUT=2; TOTAL_TIMEOUT=5; TIMEOUT_KILL_AFTER=1; SERVERS=(one.example two.example)
    prepare_ssh_runtime
    eval "$(declare -f terminate_managed_session | sed '1s/terminate_managed_session/original_terminate_managed_session/')"
    terminate_managed_session() { return 1; }
    rc=0; test_authentication > "$root/output.log" 2>&1 || rc=$?
    assert_eq "$MANAGED_CLEANUP_FAILURE_STATUS" "$rc" "auth cleanup failure returns dedicated barrier status"
    assert_eq 1 "$(<"$root/capture/count")" "auth cleanup failure stops later servers"
    [[ -f "$WORKER_SESSION_STATE_FILE" ]] || fail "auth cleanup failure did not retain state file"
    eval "$(declare -f original_terminate_managed_session | sed '1s/original_terminate_managed_session/terminate_managed_session/')"
    terminate_worker_transfer
    cleanup_runtime
)

(
    trap - EXIT HUP INT TERM
    root="$TEST_DIR/worker-state-fallback"; mkdir -m 0700 "$root" "$root/bin" "$root/runtime"
    cat > "$root/bin/timeout" <<'EOF'
#!/usr/bin/env bash
[[ ${1:-} == --kill-after=* ]] && shift
shift
exec "$@"
EOF
    cat > "$root/bin/rsync" <<'EOF'
#!/usr/bin/env bash
sleep 0.1
exit 0
EOF
    chmod 0700 "$root/bin"/*
    PATH="$root/bin:$PATH"; export PATH
    TMPDIR="$root/runtime"; initialize_runtime
    AUTH_METHOD=key; RUNTIME_KEY_FILE="$TEMP_DIR/key"; printf key > "$RUNTIME_KEY_FILE"; chmod 0600 "$RUNTIME_KEY_FILE"
    SSH_WRAPPER="$TEMP_DIR/wrapper"; printf '#!/usr/bin/env bash\nexit 0\n' > "$SSH_WRAPPER"; chmod 0700 "$SSH_WRAPPER"
    STRICT_HOST_KEY_CHECKING=accept-new; USER_KNOWN_HOSTS_FILE="$root/known_hosts"; ALLOW_INSECURE_HOST_KEY_STORAGE=false; prepare_known_hosts
    CONNECTION_TIMEOUT=2; TOTAL_TIMEOUT=5; TIMEOUT_KILL_AFTER=1; MAX_RETRIES=1; RETRY_DELAY=1
    RSYNC_ARCHIVE=true; RSYNC_COMPRESS=false; DELETE_EXTRA=false; MAX_PARALLEL=1
    eval "$(declare -f terminate_managed_session | sed '1s/terminate_managed_session/original_terminate_managed_session/')"
    main_state_owner_pid=$BASHPID
    terminate_managed_session() {
        if [[ "$BASHPID" != "$main_state_owner_pid" ]]; then return 1; fi
        original_terminate_managed_session "$@"
    }
    rc=0; run_server_batch source destination good.example || rc=$?
    assert_eq "$MANAGED_CLEANUP_FAILURE_STATUS" "$rc" "worker cleanup failure makes batch return lifecycle status"
    assert_eq 0 "${#ACTIVE_WORKERS[@]}" "main fallback leaves no active worker"
    assert_eq 0 "${#ACTIVE_WORKER_STATE_FILES[@]}" "main fallback consumes worker cleanup state"
    [[ "$BATCH_WORKER_FAILED" == true ]] || fail "worker cleanup failure did not retain global batch barrier"
    pass "worker cleanup failure is recovered by main but barrier remains"
    eval "$(declare -f original_terminate_managed_session | sed '1s/original_terminate_managed_session/terminate_managed_session/')"
    reset_batch_lifecycle_barrier
    cleanup_runtime
)

setup_batch_lifecycle_fixture() {
    local root="$1"
    mkdir -m 0700 "$root" "$root/bin" "$root/runtime" "$root/capture"
    cat > "$root/bin/timeout" <<'EOF'
#!/usr/bin/env bash
[[ ${1:-} == --kill-after=* ]] && shift
shift
exec "$@"
EOF
    cat > "$root/bin/rsync" <<'EOF'
#!/usr/bin/env bash
last=${!#}
exec 9>>"$CAPTURE_DIR/calls.lock"
flock -x 9
printf '%s\n' "$last" >> "$CAPTURE_DIR/calls"
flock -u 9
for host in one.example two.example three.example four.example recovered.example; do
    [[ "$last" == *"$host"* ]] && touch "$CAPTURE_DIR/$host"
done
# 并行 barrier 用例必须等两个 worker 都发布调用；CI 高负载下给出 15 秒确定性上限。
for _ in {1..300}; do
    current=$(wc -l < "$CAPTURE_DIR/calls")
    (( current >= ${BATCH_FIXTURE_EXPECTED_STARTS:-1} )) && break
    sleep 0.05
done
sleep 0.2
exit 0
EOF
    chmod 0700 "$root/bin"/*
    PATH="$root/bin:$PATH"; export PATH CAPTURE_DIR="$root/capture"
    BATCH_FIXTURE_EXPECTED_STARTS=1; export BATCH_FIXTURE_EXPECTED_STARTS
    TMPDIR="$root/runtime"; initialize_runtime
    AUTH_METHOD=key; RUNTIME_KEY_FILE="$TEMP_DIR/key"; printf key > "$RUNTIME_KEY_FILE"; chmod 0600 "$RUNTIME_KEY_FILE"
    SSH_WRAPPER="$TEMP_DIR/wrapper"; printf '#!/usr/bin/env bash\nexit 0\n' > "$SSH_WRAPPER"; chmod 0700 "$SSH_WRAPPER"
    STRICT_HOST_KEY_CHECKING=accept-new; USER_KNOWN_HOSTS_FILE="$root/known_hosts"; ALLOW_INSECURE_HOST_KEY_STORAGE=false; prepare_known_hosts
    CONNECTION_TIMEOUT=2; TOTAL_TIMEOUT=5; TIMEOUT_KILL_AFTER=1; MAX_RETRIES=1; RETRY_DELAY=1
    RSYNC_ARCHIVE=true; RSYNC_COMPRESS=false; DELETE_EXTRA=false
}

(
    trap - EXIT HUP INT TERM
    root="$TEST_DIR/batch-barrier-serial"
    setup_batch_lifecycle_fixture "$root"
    MAX_PARALLEL=1
    eval "$(declare -f terminate_managed_session | sed '1s/terminate_managed_session/original_terminate_managed_session/')"
    terminate_managed_session() { return 1; }

    rc=0; run_server_batch source destination one.example two.example three.example > "$root/first.log" 2>&1 || rc=$?
    assert_eq "$MANAGED_CLEANUP_FAILURE_STATUS" "$rc" "serial batch returns lifecycle cleanup status"
    assert_eq 1 "$(wc -l < "$root/capture/calls")" "serial cleanup failure starts exactly one rsync"
    [[ -e "$root/capture/one.example" && ! -e "$root/capture/two.example" && ! -e "$root/capture/three.example" ]] || fail "serial barrier launched a later server"
    if grep -Fq '成功:' "$root/first.log"; then fail "serial lifecycle failure printed success summary"; fi
    assert_eq 1 "${#ACTIVE_WORKER_STATE_FILES[@]}" "serial failure preserves first worker state file"
    state_file=${ACTIVE_WORKER_STATE_FILES[${!ACTIVE_WORKER_STATE_FILES[@]}]}
    state_hash=$(sha256sum "$state_file")

    rc=0; run_server_batch source destination four.example > "$root/second.log" 2>&1 || rc=$?
    assert_eq "$MANAGED_CLEANUP_FAILURE_STATUS" "$rc" "second batch is rejected by lifecycle barrier"
    assert_eq 1 "$(wc -l < "$root/capture/calls")" "second batch starts no additional rsync"
    assert_eq "$state_hash" "$(sha256sum "$state_file")" "second batch preserves old worker state"
    pass "serial cleanup barrier blocks later servers and subsequent batches"

    eval "$(declare -f original_terminate_managed_session | sed '1s/original_terminate_managed_session/terminate_managed_session/')"
    terminate_active_workers
    assert_eq 0 "${#ACTIVE_WORKERS[@]}" "barrier recovery clears active workers"
    assert_eq 0 "${#ACTIVE_WORKER_STATE_FILES[@]}" "barrier recovery clears published states"
    assert_eq 0 "${#ACTIVE_WORKER_STATE_STARTS[@]}" "barrier recovery clears state identities"
    runtime_has_published_worker_state && fail "barrier recovery left a runtime state file"
    reset_batch_lifecycle_barrier
    [[ "$BATCH_WORKER_FAILED" == false ]] || fail "safe barrier reset did not clear flag"
    run_server_batch source destination recovered.example
    assert_eq 2 "$(wc -l < "$root/capture/calls")" "new batch starts only after explicit safe reset"
    [[ -e "$root/capture/recovered.example" ]] || fail "recovered batch did not run"
    pass "barrier recovery permits a new batch after complete cleanup and reset"
    cleanup_runtime
)

(
    trap - EXIT HUP INT TERM
    root="$TEST_DIR/batch-barrier-parallel"
    setup_batch_lifecycle_fixture "$root"
    MAX_PARALLEL=2
    BATCH_FIXTURE_EXPECTED_STARTS=2; export BATCH_FIXTURE_EXPECTED_STARTS
    sleep 60 & unrelated=$!
    eval "$(declare -f terminate_managed_session | sed '1s/terminate_managed_session/original_terminate_managed_session/')"
    main_batch_owner=$BASHPID
    terminate_managed_session() {
        if [[ "$BASHPID" != "$main_batch_owner" ]]; then return 1; fi
        original_terminate_managed_session "$@"
    }

    rc=0; run_server_batch source destination one.example two.example three.example four.example > "$root/output.log" 2>&1 || rc=$?
    assert_eq "$MANAGED_CLEANUP_FAILURE_STATUS" "$rc" "parallel batch returns lifecycle cleanup status"
    assert_eq 2 "$(wc -l < "$root/capture/calls")" "parallel cleanup failure starts only first two rsync commands"
    [[ -e "$root/capture/one.example" && -e "$root/capture/two.example" ]] || fail "parallel fixture did not start first two servers"
    [[ ! -e "$root/capture/three.example" && ! -e "$root/capture/four.example" ]] || fail "parallel barrier launched waiting servers"
    assert_eq 0 "${#ACTIVE_WORKERS[@]}" "parallel barrier safely stops or waits active workers"
    assert_eq 0 "${#ACTIVE_WORKER_STATE_FILES[@]}" "parallel barrier executes published session fallback"
    kill -0 "$unrelated" 2>/dev/null || fail "parallel barrier terminated unrelated process"
    pass "parallel barrier stops scheduling and preserves unrelated processes"

    eval "$(declare -f original_terminate_managed_session | sed '1s/original_terminate_managed_session/terminate_managed_session/')"
    reset_batch_lifecycle_barrier
    kill "$unrelated" 2>/dev/null || true; wait "$unrelated" 2>/dev/null || true
    cleanup_runtime
)

run_accounting_failure_case() {
    local failure_kind="$1" root="$TEST_DIR/accounting-$1"
    (
        trap - EXIT HUP INT TERM
        mkdir -m 0700 "$root" "$root/bin" "$root/runtime"
        cat > "$root/bin/timeout" <<'EOF'
#!/usr/bin/env bash
[[ ${1:-} == --kill-after=* ]] && shift
shift
exec "$@"
EOF
        cat > "$root/bin/rsync" <<'EOF'
#!/usr/bin/env bash
sleep 0.1
exit 0
EOF
        chmod 0700 "$root/bin"/*
        PATH="$root/bin:$PATH"; export PATH
        TMPDIR="$root/runtime"; initialize_runtime
        AUTH_METHOD=key; RUNTIME_KEY_FILE="$TEMP_DIR/key"; printf key > "$RUNTIME_KEY_FILE"; chmod 0600 "$RUNTIME_KEY_FILE"
        SSH_WRAPPER="$TEMP_DIR/wrapper"; printf '#!/usr/bin/env bash\nexit 0\n' > "$SSH_WRAPPER"; chmod 0700 "$SSH_WRAPPER"
        STRICT_HOST_KEY_CHECKING=accept-new; USER_KNOWN_HOSTS_FILE="$root/known_hosts"; ALLOW_INSECURE_HOST_KEY_STORAGE=false; prepare_known_hosts
        CONNECTION_TIMEOUT=2; TOTAL_TIMEOUT=5; TIMEOUT_KILL_AFTER=1; MAX_RETRIES=1; RETRY_DELAY=1
        RSYNC_ARCHIVE=true; RSYNC_COMPRESS=false; DELETE_EXTRA=false; MAX_PARALLEL=1; SERVERS=(good.example)
        case "$failure_kind" in
            flock) flock() { return 1; } ;;
            append) append_result_record() { return 1; } ;;
            close) close_result_lock_fd() { return 1; } ;;
        esac
        assert_fail "$failure_kind result recording failure makes push fail" run_transfer source destination > "$root/output.log" 2>&1
        if grep -Fq '成功: 1/1' "$root/output.log"; then fail "$failure_kind accounting failure printed false success summary"; fi
        grep -Fq '结果记录不完整' "$root/output.log" || fail "$failure_kind accounting failure omitted explicit error"
        pass "$failure_kind accounting failure suppresses false success summary"
        cleanup_runtime
    )
}

run_accounting_failure_case flock
run_accounting_failure_case append
run_accounting_failure_case close

# Delete authorization remains explicit.
(
    trap - EXIT HUP INT TERM
    DELETE_EXTRA=true; ALLOW_DELETE_EXTRA=false
    assert_fail "non-interactive delete requires explicit authorization" prepare_delete_authorization
    ALLOW_DELETE_EXTRA=true
    prepare_delete_authorization
    pass "explicit non-interactive delete authorization remains supported"
)

# EXIT cleanup preserves normal success and ordinary failure statuses.
run_exit_cleanup_case() {
    local requested_status="$1" root="$TEST_DIR/exit-$1" rc=0
    mkdir -m 0700 "$root" "$root/runtime"
    env SCRIPT="$SCRIPT" TMPDIR="$root/runtime" REQUESTED_STATUS="$requested_status" bash -c '
set -euo pipefail
source "$SCRIPT"
initialize_runtime
install_runtime_traps
exit "$REQUESTED_STATUS"
' || rc=$?
    assert_eq "$requested_status" "$rc" "EXIT cleanup preserves status $requested_status"
    [[ -z "$(find "$root/runtime" -mindepth 1 -maxdepth 1 -name 'push-runtime.*' -print -quit)" ]] || fail "EXIT status $requested_status left runtime directory"
    pass "EXIT status $requested_status removes runtime directory"
}

run_exit_cleanup_case 0
run_exit_cleanup_case 7

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
    cat > "$root/bin/record-process" <<'EOF'
record_process_identity() {
    local role="$1" pid="$2" stat_line="" stat_rest="" state ppid pgid sid start comm stage identity pid_stage
    local -a fields=()
    for _ in {1..100}; do
        [[ -r "/proc/$pid/stat" ]] && { IFS= read -r stat_line < "/proc/$pid/stat" || true; }
        [[ -n "$stat_line" ]] && break
        sleep 0.005
    done
    [[ -n "$stat_line" ]] || exit 92
    comm=${stat_line#*\(}; comm=${comm%%\) *}; stat_rest=${stat_line##*) }
    read -r -a fields <<< "$stat_rest"; (( ${#fields[@]} >= 20 )) || exit 92
    state=${fields[0]}; ppid=${fields[1]}; pgid=${fields[2]}; sid=${fields[3]}; start=${fields[19]}
    identity="$PID_DIR/$role.identity"; stage="$PID_DIR/.$role.$pid.identity.stage"
    pid_stage="$PID_DIR/.$role.$pid.pid.stage"
    (umask 077; set -o noclobber; : > "$stage"; : > "$pid_stage") || exit 93
    printf 'role=%s\npid=%s\nstart=%s\nppid=%s\npgid=%s\nsid=%s\nstate=%s\ncomm=%s\n' \
        "$role" "$pid" "$start" "$ppid" "$pgid" "$sid" "$state" "$comm" > "$stage"
    printf '%s\n' "$pid" > "$pid_stage"
    chmod 0600 "$stage" "$pid_stage"
    mv -fT "$stage" "$identity"; mv -fT "$pid_stage" "$PID_DIR/$role.pid"
}
EOF
    cat > "$root/bin/timeout" <<'EOF'
#!/usr/bin/env bash
trap '' HUP INT TERM
source "$RECORD_PROCESS_LIB"
record_process_identity timeout "$$"
[[ ${1:-} == --kill-after=* ]] && shift
shift
"$@" & child=$!
wait "$child"
EOF
    cat > "$root/bin/sshpass" <<'EOF'
#!/usr/bin/env bash
trap '' HUP INT TERM
source "$RECORD_PROCESS_LIB"
record_process_identity sshpass "$$"
[[ ${1:-} == -e ]] && shift
"$@" & child=$!
wait "$child"
EOF
    cat > "$root/bin/rsync" <<'EOF'
#!/usr/bin/env bash
trap '' HUP INT TERM
source "$RECORD_PROCESS_LIB"
set -m
record_process_identity rsync "$$"
ssh fake-target & child=$!
wait "$child"
EOF
    cat > "$root/bin/ssh" <<'EOF'
#!/usr/bin/env bash
trap '' HUP INT TERM
source "$RECORD_PROCESS_LIB"
record_process_identity ssh "$$"
sleep 300 & child=$!
record_process_identity leaf "$child"
wait "$child"
EOF
    chmod 0700 "$root/bin"/*
}

wait_for_signal_fixture_readiness() {
    local root="$1" role identity pid_file metadata owner gid mode trusted_gid state_count=0 state_file=""
    local first_signature="" second_signature="" saved_temp="$TEMP_DIR"
    for _ in {1..600}; do
        state_count=$(find "$root/runtime" -type f -name 'worker-session.*.state' | wc -l)
        ready=true
        for role in timeout sshpass rsync ssh leaf; do
            [[ -f "$root/pids/$role.identity" && -f "$root/pids/$role.pid" ]] || ready=false
        done
        [[ "$state_count" == 1 && "$ready" == true ]] && break
        sleep 0.05
    done
    [[ "$state_count" == 1 && "$ready" == true ]] || return 1
    state_file=$(find "$root/runtime" -type f -name 'worker-session.*.state' -print -quit)
    TEMP_DIR=$(dirname "$state_file")
    worker_session_state_file_trusted "$state_file" || { TEMP_DIR=$saved_temp; return 1; }
    read_worker_session_state "$state_file" || { TEMP_DIR=$saved_temp; return 1; }
    SIGNAL_STATE_FILE=$state_file
    SIGNAL_WORKER_PID=$SESSION_WORKER_PID; SIGNAL_WORKER_START=$SESSION_WORKER_START
    SIGNAL_LEADER_PID=$SESSION_LEADER_PID; SIGNAL_LEADER_START=$SESSION_LEADER_START
    SIGNAL_MANAGED_PGID=$SESSION_PGID; SIGNAL_MANAGED_SID=$SESSION_SID
    fixture_identity_same "$SIGNAL_WORKER_PID" "$SIGNAL_WORKER_START" || { TEMP_DIR=$saved_temp; return 1; }
    fixture_identity_same "$SIGNAL_LEADER_PID" "$SIGNAL_LEADER_START" || { TEMP_DIR=$saved_temp; return 1; }
    [[ "$FIXTURE_PGID" == "$SIGNAL_MANAGED_PGID" && "$FIXTURE_SID" == "$SIGNAL_MANAGED_SID" ]] || { TEMP_DIR=$saved_temp; return 1; }
    trusted_gid=$(current_gid) || { TEMP_DIR=$saved_temp; return 1; }
    for role in timeout sshpass rsync ssh leaf; do
        identity="$root/pids/$role.identity"; pid_file="$root/pids/$role.pid"
        read_fixture_identity "$identity" || { TEMP_DIR=$saved_temp; return 1; }
        metadata=$(stat -Lc '%u:%g:%a' -- "$pid_file") || { TEMP_DIR=$saved_temp; return 1; }
        IFS=: read -r owner gid mode <<< "$metadata"
        [[ -f "$pid_file" && ! -L "$pid_file" && "$owner" == "$EUID" && "$gid" == "$trusted_gid" && "$mode" == 600 ]] || { TEMP_DIR=$saved_temp; return 1; }
        [[ "$(wc -l < "$pid_file")" == 1 && "$(<"$pid_file")" == "$FIXTURE_FILE_PID" ]] || { TEMP_DIR=$saved_temp; return 1; }
        fixture_identity_same "$FIXTURE_FILE_PID" "$FIXTURE_FILE_START" || { TEMP_DIR=$saved_temp; return 1; }
        [[ "$FIXTURE_SID" == "$SIGNAL_MANAGED_SID" && "$FIXTURE_FILE_SID" == "$SIGNAL_MANAGED_SID" ]] || { TEMP_DIR=$saved_temp; return 1; }
        if [[ "$role" == timeout ]]; then
            [[ "$FIXTURE_FILE_PID" == "$SIGNAL_LEADER_PID" && "$FIXTURE_FILE_START" == "$SIGNAL_LEADER_START" &&
                "$FIXTURE_FILE_PGID" == "$SIGNAL_MANAGED_PGID" ]] || { TEMP_DIR=$saved_temp; return 1; }
        fi
    done
    first_signature="$(stat -Lc '%d:%i:%u:%g:%a:%s' -- "$state_file")|$(sha256sum "$state_file")|$(cat "$root"/pids/*.identity | sha256sum)"
    sleep 0.06
    read_worker_session_state "$state_file" || { TEMP_DIR=$saved_temp; return 1; }
    second_signature="$(stat -Lc '%d:%i:%u:%g:%a:%s' -- "$state_file")|$(sha256sum "$state_file")|$(cat "$root"/pids/*.identity | sha256sum)"
    TEMP_DIR=$saved_temp
    [[ "$first_signature" == "$second_signature" ]]
}

run_process_tree_signal_case() (
    local signal_name="$1" expected_status="$2"
    local root="$TEST_DIR/process-$signal_name" main_pid="" main_start="" rc=0 watchdog="" watchdog_start=""
    local unrelated="" unrelated_start="" role child_pid child_start timeout_pgid ssh_pgid
    local -a session_pids=()
    local -A process_pids=() process_starts=() session_starts=() session_ppids=() session_pgids=() session_states=()
    cleanup_signal_fixture() {
        local cleanup_role cleanup_pid cleanup_start
        for cleanup_role in worker timeout sshpass rsync ssh leaf; do
            cleanup_pid=${process_pids[$cleanup_role]:-}; cleanup_start=${process_starts[$cleanup_role]:-}
            [[ -n "$cleanup_pid" && -n "$cleanup_start" ]] || continue
            fixture_identity_same "$cleanup_pid" "$cleanup_start" && kill -KILL "$cleanup_pid" 2>/dev/null || true
        done
        [[ -z "$main_pid" || -z "$main_start" ]] || { fixture_identity_same "$main_pid" "$main_start" && kill -KILL "$main_pid" 2>/dev/null || true; }
        [[ -z "$watchdog" || -z "$watchdog_start" ]] || { fixture_identity_same "$watchdog" "$watchdog_start" && kill -TERM "$watchdog" 2>/dev/null || true; }
        [[ -z "$unrelated" || -z "$unrelated_start" ]] || { fixture_identity_same "$unrelated" "$unrelated_start" && kill -TERM "$unrelated" 2>/dev/null || true; }
        [[ -z "$main_pid" ]] || wait "$main_pid" 2>/dev/null || true
        [[ -z "$watchdog" ]] || wait "$watchdog" 2>/dev/null || true
        [[ -z "$unrelated" ]] || wait "$unrelated" 2>/dev/null || true
    }
    trap cleanup_signal_fixture EXIT
    write_signal_fixture "$root"; mkdir -m 0700 "$root/pids"
    sleep 60 & unrelated=$!; unrelated_start=$(wait_fixture_start "$unrelated")
    (
        cd "$root"
        exec env --default-signal=HUP,INT,TERM PATH="$root/bin:$PATH" TMPDIR="$root/runtime" PID_DIR="$root/pids" \
            RECORD_PROCESS_LIB="$root/bin/record-process" "$SCRIPT" "$root/source" '/remote/path'
    ) > "$root/output.log" 2>&1 &
    main_pid=$!; main_start=$(wait_fixture_start "$main_pid")
    if ! wait_for_signal_fixture_readiness "$root"; then
        cat "$root/output.log" >&2 || true
        fail "$signal_name process tree did not reach authoritative session readiness"
    fi
    process_pids[worker]=$SIGNAL_WORKER_PID; process_starts[worker]=$SIGNAL_WORKER_START
    for role in timeout sshpass rsync ssh leaf; do
        read_fixture_identity "$root/pids/$role.identity" || fail "$signal_name cannot read $role identity"
        process_pids[$role]=$FIXTURE_FILE_PID; process_starts[$role]=$FIXTURE_FILE_START
        [[ "$role" == timeout ]] && timeout_pgid=$FIXTURE_FILE_PGID
        [[ "$role" == ssh ]] && ssh_pgid=$FIXTURE_FILE_PGID
    done
    assert_eq "$SIGNAL_MANAGED_SID" "$(read_fixture_identity "$root/pids/ssh.identity"; printf '%s' "$FIXTURE_FILE_SID")" "$signal_name SSH remains in managed SID"
    [[ "$timeout_pgid" != "$ssh_pgid" ]] || fail "$signal_name fixture did not create a second PGID"
    pass "$signal_name cleanup fixture contains multiple PGIDs in one SID"

    signal_test_watchdog "$root" "$main_pid" & watchdog=$!; watchdog_start=$(wait_fixture_start "$watchdog")
    printf 'signal-sent %s main=%s:%s worker=%s:%s sid=%s\n' "$(date +%s%N)" "$main_pid" "$main_start" \
        "$SIGNAL_WORKER_PID" "$SIGNAL_WORKER_START" "$SIGNAL_MANAGED_SID" > "$root/exit-order.log"
    kill "-$signal_name" "$main_pid"
    wait "$main_pid" || rc=$?
    printf 'main-reaped %s status=%s\n' "$(date +%s%N)" "$rc" >> "$root/exit-order.log"
    kill -TERM "$watchdog" 2>/dev/null || true; wait "$watchdog" 2>/dev/null || true
    [[ ! -e "$root/watchdog-fired" ]] || fail "$signal_name watchdog fired"
    fixture_identity_same "$watchdog" "$watchdog_start" && fail "$signal_name watchdog identity remains"
    assert_eq "$expected_status" "$rc" "$signal_name returns conventional push signal status"

    for role in timeout sshpass rsync ssh leaf worker; do
        child_pid=${process_pids[$role]}; child_start=${process_starts[$role]}
        if ! wait_fixture_identity_gone "$child_pid" "$child_start"; then
            dump_fixture_process "$role" "$child_pid" "$child_start"
            cat "$root/exit-order.log" >&2 || true; cat "$root/output.log" >&2 || true
            fail "$signal_name left original $role identity $child_pid/$child_start"
        fi
        if fixture_current_identity "$child_pid"; then
            printf 'pid-reuse %s role=%s pid=%s expected=%s actual=%s state=%s\n' "$(date +%s%N)" "$role" "$child_pid" "$child_start" "$FIXTURE_START" "$FIXTURE_STATE" >> "$root/exit-order.log"
        else
            printf 'identity-gone %s role=%s pid=%s start=%s\n' "$(date +%s%N)" "$role" "$child_pid" "$child_start" >> "$root/exit-order.log"
        fi
    done
    collect_owned_session_records "$SIGNAL_MANAGED_SID" session_pids session_starts session_ppids session_pgids session_states || fail "$signal_name cannot verify managed SID"
    (( ${#session_pids[@]} == 0 )) || { printf 'remaining SID members: %s\n' "${session_pids[*]}" >&2; fail "$signal_name left managed SID member"; }
    pass "$signal_name terminates and reaps worker, timeout, sshpass, rsync, ssh, and leaf identities"
    [[ -z "$(find "$root/runtime" -mindepth 1 -maxdepth 1 -name 'push-runtime.*' -print -quit)" ]] || fail "$signal_name left runtime directory"
    pass "$signal_name removes runtime directory"
    [[ -f "$root/config.conf" && -f "$root/ssh/known_hosts" ]] || fail "$signal_name deleted config or known_hosts"
    pass "$signal_name preserves config and known_hosts"
    fixture_identity_same "$unrelated" "$unrelated_start" || fail "$signal_name terminated or replaced unrelated process"
    pass "$signal_name preserves unrelated process identity"
    kill -TERM "$unrelated"; wait "$unrelated" 2>/dev/null || true; unrelated=""; unrelated_start=""
    [[ -z "${SSHPASS:-}" ]] || fail "$signal_name leaked SSHPASS to parent test shell"
    pass "$signal_name leaves no observable SSHPASS in subsequent test process"
    main_pid=""; main_start=""; watchdog=""; watchdog_start=""
    trap - EXIT
)

run_process_tree_signal_case HUP 129
run_process_tree_signal_case INT 130
run_process_tree_signal_case TERM 143

cat > "$TEST_DIR/worker-grace-child.sh" <<'WORKER_GRACE_CHILD'
#!/usr/bin/env bash
set -euo pipefail
script="$1"
shift
source "$script"
worker_after_session_cleanup_hook() {
    touch "$WORKER_GRACE_MARKER"
    sleep 0.5
}
main "$@"
WORKER_GRACE_CHILD
chmod 0700 "$TEST_DIR/worker-grace-child.sh"

(
    trap - EXIT HUP INT TERM
    root="$TEST_DIR/worker-grace"; write_signal_fixture "$root"; mkdir -m 0700 "$root/pids"
    marker="$root/worker-cleanup-finished"; rc=0
    (
        cd "$root"
        exec env --default-signal=HUP,INT,TERM PATH="$root/bin:$PATH" TMPDIR="$root/runtime" PID_DIR="$root/pids" \
            RECORD_PROCESS_LIB="$root/bin/record-process" WORKER_GRACE_MARKER="$marker" bash "$TEST_DIR/worker-grace-child.sh" "$SCRIPT" "$root/source" /remote/path
    ) > "$root/output.log" 2>&1 &
    pid=$!
    if ! wait_for_signal_fixture_readiness "$root"; then
        cat "$root/output.log" >&2 || true
        kill "$pid" 2>/dev/null || true
        fail "worker grace fixture did not reach authoritative session readiness"
    fi
    kill -TERM "$pid"
    wait "$pid" || rc=$?
    assert_eq 143 "$rc" "main preserves TERM status while waiting for worker cleanup"
    [[ -e "$marker" ]] || { cat "$root/output.log" >&2 || true; fail "main killed worker before managed-session cleanup hook"; }
    pass "main TERM grace exceeds worker TERM/KILL/final-verification duration"
)

printf 'All push tests passed.\n'
