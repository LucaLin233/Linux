#!/usr/bin/env bash
set -euo pipefail

readonly ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
readonly TOOL="$ROOT_DIR/tools/xanmod-install.sh"
readonly MODULE="$ROOT_DIR/modules/system-customize.sh"

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
assert_ok() { local name="$1"; shift; "$@" || fail "$name"; pass "$name"; }
assert_fail() { local name="$1"; shift; if "$@"; then fail "$name: unexpectedly succeeded"; fi; pass "$name"; }

make_layout() {
    local root="$1"
    mkdir -p "$root/etc/keyrings" "$root/etc/sources" "$root/run" "$root/tmp"
    printf 'VERSION_CODENAME=trixie\n' > "$root/os-release"
    printf '%s\n' 'flags : lm cmov cx8 fpu fxsr mmx syscall sse2 cx16 lahf_lm popcnt sse4_1 sse4_2 ssse3 avx avx2 bmi1 bmi2 f16c fma abm movbe xsave' > "$root/cpuinfo"
}

export XANMOD_TEST_MODE=1
export XANMOD_KEYRING_PATH="$TEST_DIR/tool/etc/keyrings/xanmod.gpg"
export XANMOD_SOURCE_LIST_PATH="$TEST_DIR/tool/etc/sources/xanmod.list"
export XANMOD_SOURCE_DEB822_PATH="$TEST_DIR/tool/etc/sources/xanmod.sources"
export XANMOD_LOCK_PATH="$TEST_DIR/tool/run/xanmod.lock"
export XANMOD_OS_RELEASE_PATH="$TEST_DIR/tool/os-release"
export XANMOD_CPUINFO_PATH="$TEST_DIR/tool/cpuinfo"
export XANMOD_BACKUP_STATE_DIR="$TEST_DIR/tool/backups"
export TMPDIR="$TEST_DIR/tool/tmp"
make_layout "$TEST_DIR/tool"
# shellcheck source=../tools/xanmod-install.sh
source "$TOOL"
trap 'rm -rf "$TEST_DIR"' EXIT

assert_eq "$XANMOD_KEYRING_PATH" "$XANMOD_KEYRING" "tool test mode overrides keyring path"
assert_eq "$XANMOD_SOURCE_LIST_PATH" "$XANMOD_SOURCE_LIST" "tool test mode overrides list path"
assert_eq "$XANMOD_SOURCE_DEB822_PATH" "$XANMOD_SOURCE_DEB822" "tool test mode overrides Deb822 path"
assert_eq "$XANMOD_LOCK_PATH" "$XANMOD_LOCK" "tool test mode overrides lock path"
assert_eq "$XANMOD_OS_RELEASE_PATH" "$XANMOD_OS_RELEASE" "tool test mode overrides os-release path"
assert_eq "$XANMOD_CPUINFO_PATH" "$XANMOD_CPUINFO" "tool test mode overrides cpuinfo path"
assert_eq "$TEST_DIR/tool/backups" "$XANMOD_BACKUP_STATE_DIR" "tool test mode overrides backup state directory"
[[ -z "$(trap -p ERR)" ]] || fail "sourcing tool installed ERR trap"
pass "sourcing tool leaves ERR trap unchanged"

for script in "$TOOL" "$MODULE"; do
    production_paths=$(env -u XANMOD_TEST_MODE XANMOD_KEYRING_PATH=/tmp/evil-key \
        XANMOD_SOURCE_LIST_PATH=/tmp/evil-list XANMOD_SOURCE_DEB822_PATH=/tmp/evil-sources \
        XANMOD_LOCK_PATH=/tmp/evil-lock XANMOD_OS_RELEASE_PATH=/tmp/evil-os \
        XANMOD_CPUINFO_PATH=/tmp/evil-cpu XANMOD_BACKUP_STATE_DIR=/tmp/evil-backups \
        bash -c 'source "$1"; printf "%s|%s|%s|%s|%s|%s|%s|%s" \
            "$XANMOD_KEYRING" "$XANMOD_SOURCE_LIST" "$XANMOD_SOURCE_DEB822" "$XANMOD_LOCK" \
            "$XANMOD_OS_RELEASE" "$XANMOD_CPUINFO" "$XANMOD_BACKUP_STATE_DIR" "$(trap -p ERR)"' _ "$script")
    assert_eq '/etc/apt/keyrings/xanmod-archive-keyring.gpg|/etc/apt/sources.list.d/xanmod-release.list|/etc/apt/sources.list.d/xanmod-release.sources|/run/lock/xanmod-install.lock|/etc/os-release|/proc/cpuinfo|/var/lib/linux-setup/apt-source-backups|' "$production_paths" \
        "$(basename "$script") production paths ignore overrides"
    grep -Fq 'if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then' "$script" || fail "$(basename "$script") lacks direct execution guard"
    pass "$(basename "$script") has direct execution guard"
done
if grep -RFn '.new' "$TOOL" "$MODULE" >/dev/null; then fail "fixed .new path remains"; fi
pass "XanMod implementations avoid fixed .new paths"
for script in "$TOOL" "$MODULE"; do
    grep -Fq 'DEBIAN_FRONTEND=noninteractive apt-get install -y "$target_package"' "$script" || fail "$(basename "$script") install is interactive"
    pass "$(basename "$script") uses noninteractive kernel install"
done

(
    parse_xanmod_arguments
    assert_eq install "$XANMOD_ACTION" "tool defaults to install"
    assert_eq false "$XANMOD_ASSUME_YES" "tool default is not authorized"
    parse_xanmod_arguments --yes
    assert_eq true "$XANMOD_ASSUME_YES" "tool accepts --yes"
    parse_xanmod_arguments install -y
    assert_eq true "$XANMOD_ASSUME_YES" "tool accepts install -y"
    parse_xanmod_arguments status
    assert_eq status "$XANMOD_ACTION" "tool accepts status"
    parse_xanmod_arguments help
    assert_eq help "$XANMOD_ACTION" "tool accepts help"
    assert_fail "tool rejects status --yes" parse_xanmod_arguments status --yes
    assert_fail "tool rejects reversed install arguments" parse_xanmod_arguments --yes install
    assert_fail "tool rejects unknown action" parse_xanmod_arguments remove
    assert_fail "tool rejects excess arguments" parse_xanmod_arguments install --yes extra
)

(
    calls="$TEST_DIR/refusal.calls"; : > "$calls"
    is_interactive_terminal() { return 1; }
    require_root() { echo root >> "$calls"; }
    require_commands() { echo dependencies >> "$calls"; }
    take_xanmod_lock() { echo lock >> "$calls"; }
    install_xanmod() { echo install >> "$calls"; }
    show_xanmod_status() { echo status >> "$calls"; }
    rc=0; main install > "$TEST_DIR/refusal.log" 2>&1 || rc=$?
    assert_eq 1 "$rc" "tool refuses noninteractive install without --yes"
    [[ ! -s "$calls" ]] || fail "tool refusal reached an operation"
    pass "tool refusal precedes dependencies, lock, and writes"
    grep -Fq -- '--yes' "$TEST_DIR/refusal.log" || fail "tool refusal omits guidance"
    pass "tool refusal explains --yes"
)
(
    calls="$TEST_DIR/yes.calls"; : > "$calls"
    is_interactive_terminal() { fail "authorized install checked TTY"; }
    require_root() { echo root >> "$calls"; }
    require_commands() { echo dependencies >> "$calls"; }
    take_xanmod_lock() { echo lock >> "$calls"; }
    install_xanmod() { echo install >> "$calls"; }
    show_xanmod_status() { echo status >> "$calls"; }
    main install --yes
    assert_eq $'root\ndependencies\nlock\ninstall\nstatus' "$(<"$calls")" "tool --yes authorizes complete flow"
)
(
    calls="$TEST_DIR/confirm.calls"; : > "$calls"
    is_interactive_terminal() { return 0; }
    require_root() { echo root >> "$calls"; }
    main install <<< ""
    [[ ! -s "$calls" ]] || fail "empty input authorized install"
    pass "empty XanMod confirmation defaults to no"
    main install < /dev/null
    [[ ! -s "$calls" ]] || fail "EOF authorized install"
    pass "EOF XanMod confirmation defaults to no"
)

make_cpuinfo() { local file="$1"; shift; printf 'flags : %s\n' "$*" > "$file"; }
V1='lm cmov cx8 fpu fxsr mmx syscall sse2'
V2='cx16 lahf_lm popcnt sse4_1 sse4_2 ssse3'
V3='avx avx2 bmi1 bmi2 f16c fma abm movbe xsave'
V4='avx512f avx512bw avx512cd avx512dq avx512vl'
make_cpuinfo "$TEST_DIR/v1.cpu" $V1
make_cpuinfo "$TEST_DIR/v2.cpu" $V1 $V2
make_cpuinfo "$TEST_DIR/v3.cpu" $V1 $V2 $V3
make_cpuinfo "$TEST_DIR/v4.cpu" $V1 $V2 $V3 $V4
assert_eq v1 "$(detect_x86_64_psabi_level "$TEST_DIR/v1.cpu")" "detect x86-64-v1"
assert_eq v2 "$(detect_x86_64_psabi_level "$TEST_DIR/v2.cpu")" "detect x86-64-v2"
assert_eq v3 "$(detect_x86_64_psabi_level "$TEST_DIR/v3.cpu")" "detect x86-64-v3"
assert_eq v4 "$(detect_x86_64_psabi_level "$TEST_DIR/v4.cpu")" "detect x86-64-v4"
assert_eq linux-xanmod-x64v2 "$(get_xanmod_package_for_psabi_level v2)" "v2 maps to x64v2"
assert_eq linux-xanmod-x64v3 "$(get_xanmod_package_for_psabi_level v3)" "v3 maps to x64v3"
assert_eq linux-xanmod-x64v3 "$(get_xanmod_package_for_psabi_level v4)" "v4 maps to x64v3"
assert_fail "v1 has no MAIN package" get_xanmod_package_for_psabi_level v1
(
    is_amd64() { return 0; }
    detect_x86_64_psabi_level() { echo v1; }
    rc=0; detect_xanmod_package >/dev/null || rc=$?
    assert_eq 2 "$rc" "v1 package detection returns safe-skip status"
)
printf 'processor : 0\n' > "$TEST_DIR/no-flags.cpu"
rc=0; detect_x86_64_psabi_level "$TEST_DIR/no-flags.cpu" >/dev/null || rc=$?
assert_eq 3 "$rc" "missing CPU flags returns unreadable status"

valid_colons() {
    printf '%s\n' 'pub:-:4096:1:86F7D09EE734E623:0:0::-:::scESC::::::23::0:' \
        'fpr:::::::::D38D7D1DA1349567ADED882D86F7D09EE734E623:' \
        'uid:-::::0::hash::XanMod Kernel <kernel@xanmod.org>::::::::::0:' \
        'sub:-:4096:1:1111111111111111:0:0:::::e::::::23:' \
        'fpr:::::::::1111111111111111111111111111111111111111:'
}
(
    gpg() {
        case "$(<"${!#}")" in
            valid) valid_colons ;;
            wrong-fpr) valid_colons | sed "s/$XANMOD_KEY_FINGERPRINT/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/" ;;
            wrong-uid) valid_colons | sed "s/XanMod Kernel <kernel@xanmod.org>/Other Key <other@example.org>/" ;;
            extra-pub) valid_colons; printf '%s\n' 'pub:::::::::' 'fpr:::::::::AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA:' ;;
            no-uid) valid_colons | grep -v '^uid:' ;;
            *) return 1 ;;
        esac
    }
    for marker in valid wrong-fpr wrong-uid extra-pub no-uid; do printf '%s' "$marker" > "$TEST_DIR/$marker.key"; done
    assert_ok "key validator accepts expected primary and subkey" xanmod_keyring_valid "$TEST_DIR/valid.key"
    assert_fail "key validator rejects wrong fingerprint" xanmod_keyring_valid "$TEST_DIR/wrong-fpr.key"
    assert_fail "key validator rejects wrong UID" xanmod_keyring_valid "$TEST_DIR/wrong-uid.key"
    assert_fail "key validator rejects extra primary" xanmod_keyring_valid "$TEST_DIR/extra-pub.key"
    assert_fail "key validator rejects missing UID" xanmod_keyring_valid "$TEST_DIR/no-uid.key"
)

(
    rm -rf "$XANMOD_KEYRING" "$XANMOD_SOURCE_LIST" "$XANMOD_SOURCE_DEB822"
    mkdir -p "$(dirname "$XANMOD_KEYRING")" "$(dirname "$XANMOD_SOURCE_LIST")"
    printf valid > "$XANMOD_KEYRING"
    gpg() { valid_colons; }
    write_xanmod_deb822_source "$XANMOD_SOURCE_DEB822" https://deb.xanmod.org trixie "$XANMOD_KEYRING"
    assert_ok "strict Deb822 validator accepts generated source" xanmod_deb822_source_configured
    cat >> "$XANMOD_SOURCE_DEB822" <<EOF

Types: deb
URIs: https://deb.xanmod.org
Suites: trixie
Components: main
Signed-By: $XANMOD_KEYRING
EOF
    assert_fail "strict Deb822 validator rejects an extra stanza" xanmod_deb822_source_configured
    rm -f "$XANMOD_SOURCE_DEB822"
    printf 'deb [signed-by=%s] https://deb.xanmod.org trixie main\n' "$XANMOD_KEYRING" > "$XANMOD_SOURCE_LIST"
    assert_ok "strict list validator accepts one generated entry" xanmod_list_source_configured
    printf 'deb [signed-by=%s] https://deb.xanmod.org trixie main\n' "$XANMOD_KEYRING" >> "$XANMOD_SOURCE_LIST"
    assert_fail "strict list validator rejects an extra entry" xanmod_list_source_configured
    rm -f "$XANMOD_SOURCE_LIST"
    write_xanmod_deb822_source "$TEST_DIR/real-source" https://deb.xanmod.org trixie "$XANMOD_KEYRING"
    ln -s "$TEST_DIR/real-source" "$XANMOD_SOURCE_DEB822"
    assert_fail "formal Deb822 source rejects symlink state" xanmod_deb822_source_configured
)

(
    rm -rf "$XANMOD_KEYRING" "$XANMOD_SOURCE_LIST" "$XANMOD_SOURCE_DEB822"
    mkdir -p "$(dirname "$XANMOD_KEYRING")" "$(dirname "$XANMOD_SOURCE_LIST")" "$TEST_DIR/link-target"
    printf original-key > "$XANMOD_KEYRING"
    printf target > "$TEST_DIR/link-target/source"
    ln -s "$TEST_DIR/link-target/source" "$XANMOD_SOURCE_DEB822"
    create_xanmod_runtime_snapshot
    snapshot_dir="$XANMOD_RUNTIME_SNAPSHOT_DIR"
    printf changed > "$XANMOD_KEYRING"; printf list > "$XANMOD_SOURCE_LIST"
    rm -f "$XANMOD_SOURCE_DEB822"; printf source > "$XANMOD_SOURCE_DEB822"
    restore_xanmod_runtime_snapshot
    assert_file_eq original-key "$XANMOD_KEYRING" "snapshot restores regular file"
    [[ ! -e "$XANMOD_SOURCE_LIST" && ! -L "$XANMOD_SOURCE_LIST" ]] || fail "snapshot did not restore absence"
    pass "snapshot restores missing path"
    [[ -L "$XANMOD_SOURCE_DEB822" ]] || fail "snapshot did not restore symlink"
    assert_eq "$TEST_DIR/link-target/source" "$(readlink "$XANMOD_SOURCE_DEB822")" "snapshot restores symlink target"
    [[ ! -e "$snapshot_dir" ]] || fail "snapshot directory remained"
    pass "snapshot cleanup removes runtime directory"
)
(
    rm -f "$XANMOD_KEYRING" "$XANMOD_SOURCE_LIST" "$XANMOD_SOURCE_DEB822"
    printf before-key > "$XANMOD_KEYRING"; printf before-list > "$XANMOD_SOURCE_LIST"; printf before-source > "$XANMOD_SOURCE_DEB822"
    create_xanmod_runtime_snapshot
    printf invalid > "$XANMOD_RUNTIME_SNAPSHOT_DIR/item-0.state"
    printf after-key > "$XANMOD_KEYRING"; printf after-list > "$XANMOD_SOURCE_LIST"; printf after-source > "$XANMOD_SOURCE_DEB822"
    rc=0; restore_xanmod_runtime_snapshot >/dev/null 2>&1 || rc=$?
    assert_eq 1 "$rc" "incomplete rollback returns nonzero"
    assert_file_eq before-list "$XANMOD_SOURCE_LIST" "rollback continues after an item failure"
    assert_file_eq before-source "$XANMOD_SOURCE_DEB822" "rollback restores later items"
    assert_eq false "$XANMOD_TRANSACTION_ACTIVE" "incomplete rollback still closes transaction"
)

run_install_scenario() (
    set -euo pipefail
    local mode="$1" expected_rc="$2" root="$TEST_DIR/scenario-$1" rc=0
    rm -rf "$root" "$TEST_DIR/tool/etc" "$TEST_DIR/tool/original" "$TEST_DIR/tool/installed"
    make_layout "$root"
    mkdir -p "$TEST_DIR/tool/etc/keyrings" "$TEST_DIR/tool/etc/sources" "$TEST_DIR/tool/original" "$TEST_DIR/tool/tmp"
    printf original-key > "$TEST_DIR/tool/original/key"
    ln -s "$TEST_DIR/tool/original/key" "$XANMOD_KEYRING"
    printf original-list > "$XANMOD_SOURCE_LIST"
    rm -f "$XANMOD_SOURCE_DEB822"
    printf 'VERSION_CODENAME=trixie\n' > "$XANMOD_OS_RELEASE"
    cp "$root/cpuinfo" "$XANMOD_CPUINFO"
    : > "$root/apt.log"; : > "$root/curl.log"; : > "$root/candidate-keys.log"
    XANMOD_RUNTIME_SNAPSHOT_DIR=""; XANMOD_TRANSACTION_ACTIVE=false
    XANMOD_STAGED_KEY=""; XANMOD_STAGED_SOURCE=""; XANMOD_SELECTED_REPOSITORY=""

    gpg() {
        if [[ " $* " == *' --show-keys '* ]]; then
            [[ $(<"${!#}") == valid ]] || return 1
            valid_colons
            return 0
        fi
        local output="" previous="" input=${!#}
        for argument in "$@"; do [[ "$previous" == --output ]] && output="$argument"; previous="$argument"; done
        cp "$input" "$output"
    }
    curl() {
        local output="" previous=""
        printf '%s\n' "$*" >> "$root/curl.log"
        if [[ "$mode" == fallback-key && $(wc -l < "$root/curl.log") -eq 1 ]]; then return 22; fi
        for argument in "$@"; do [[ "$previous" == -o ]] && output="$argument"; previous="$argument"; done
        if [[ "$mode" == bad-key ]]; then printf wrong > "$output"; else printf valid > "$output"; fi
    }
    dpkg() { [[ "$1" == --print-architecture ]] && printf 'amd64\n'; }
    uname() { case "${1:-}" in -m) echo x86_64;; -r) echo 6.1.0-amd64;; *) echo Linux;; esac; }
    package_is_installed() { [[ -f "$TEST_DIR/tool/installed" ]]; }
    get_installed_xanmod_packages() { [[ "$mode" == other-branch ]] && echo linux-xanmod-x64v2; return 0; }
    apt-cache() {
        printf 'apt-cache %s\n' "$*" >> "$root/apt.log"
        [[ "$mode" == candidate-query-fail ]] && return 1
        if [[ "$mode" == candidate-none ]]; then echo '  Candidate: (none)'; else echo '  Candidate: 6.12.1-xanmod1'; fi
    }
    apt-get() {
        printf 'apt-get|DEBIAN_FRONTEND=%s|%s\n' "${DEBIAN_FRONTEND:-}" "$*" >> "$root/apt.log"
        local source_file="" argument signed_by
        for argument in "$@"; do case "$argument" in Dir::Etc::sourcelist=*) source_file=${argument#*=};; esac; done
        if [[ -n "$source_file" ]]; then
            signed_by=$(awk -F': ' '/^Signed-By:/ {print $2; exit}' "$source_file")
            [[ -r "$signed_by" ]] || return 90
            [[ "$source_file" == "$XANMOD_SOURCE_DEB822" ]] || echo "$signed_by" >> "$root/candidate-keys.log"
            [[ "$mode" == probe-fail ]] && return 41
            [[ "$mode" == formal-fail && "$source_file" == "$XANMOD_SOURCE_DEB822" ]] && return 42
            return 0
        fi
        if [[ "${1:-}" == update ]]; then [[ "$mode" == update-fail ]] && return 43; return 0; fi
        if [[ "${1:-}" == install ]]; then
            [[ "$mode" == install-fail ]] && return 44
            [[ "$mode" == postcheck-fail ]] || touch "$TEST_DIR/tool/installed"
            return 0
        fi
    }
    if [[ "$mode" == source-move-fail ]]; then
        mv() { local last=${!#}; [[ "$last" == "$XANMOD_SOURCE_DEB822" ]] && return 45; command mv "$@"; }
    fi
    if [[ "$mode" == other-branch ]]; then read() { fail "--yes performed a second confirmation"; }; fi

    install_xanmod > "$root/output.log" 2>&1 || rc=$?
    if [[ "$mode" == other-branch ]]; then unset -f read; fi
    assert_eq "$expected_rc" "$rc" "$mode returns expected status"
    if (( expected_rc == 0 )); then
        assert_file_eq valid "$XANMOD_KEYRING" "$mode installs validated key"
        [[ ! -e "$XANMOD_SOURCE_LIST" && ! -L "$XANMOD_SOURCE_LIST" ]] || fail "$mode retained list"
        pass "$mode removes legacy list"
        grep -Fq "Signed-By: $XANMOD_KEYRING" "$XANMOD_SOURCE_DEB822" || fail "$mode source lacks formal key path"
        pass "$mode final source uses formal key path"
        [[ -f "$TEST_DIR/tool/installed" ]] || fail "$mode did not install package"
        pass "$mode verifies installed package"
        grep -Fq 'apt-get|DEBIAN_FRONTEND=noninteractive|install -y linux-xanmod-x64v3' "$root/apt.log" || fail "$mode install command mismatch"
        pass "$mode uses exact noninteractive install command"
        [[ -s "$root/candidate-keys.log" ]] || fail "$mode skipped candidate validation"
        while IFS= read -r candidate_key; do [[ "$candidate_key" != "$XANMOD_KEYRING" ]] || fail "$mode candidate used formal key"; done < "$root/candidate-keys.log"
        pass "$mode candidate uses staged key"
    else
        [[ -L "$XANMOD_KEYRING" ]] || fail "$mode did not restore key symlink"
        assert_eq "$TEST_DIR/tool/original/key" "$(readlink "$XANMOD_KEYRING")" "$mode restores key symlink"
        assert_file_eq original-list "$XANMOD_SOURCE_LIST" "$mode restores list"
        [[ ! -e "$XANMOD_SOURCE_DEB822" && ! -L "$XANMOD_SOURCE_DEB822" ]] || fail "$mode did not restore missing source"
        pass "$mode restores missing Deb822 source"
    fi
    assert_eq false "$XANMOD_TRANSACTION_ACTIVE" "$mode closes transaction"
    [[ -z "$(find "$TEST_DIR/tool" \( -name '.xanmod-stage.*' -o -name 'xanmod-runtime-snapshot.*' -o -name 'xanmod-apt-lists.*' \) -print -quit)" ]] || fail "$mode left temporary artifacts"
    pass "$mode removes stage, snapshot, and APT-list artifacts"
    if [[ "$mode" == install-fail || "$mode" == postcheck-fail ]]; then
        grep -Fq '不会自动卸载任何包' "$root/output.log" || fail "$mode omits partial-install warning"
        pass "$mode warns about partial installation"
        if grep -Eq 'apt-get\|.*\|(remove|purge)' "$root/apt.log"; then fail "$mode removed a kernel"; fi
        pass "$mode never auto-removes a kernel"
    fi
    if [[ "$mode" == fallback-key ]]; then
        assert_eq 2 "$(wc -l < "$root/curl.log" | tr -d ' ')" "key download uses fallback"
    fi
)

run_install_scenario success 0
run_install_scenario fallback-key 0
run_install_scenario other-branch 0
for scenario in bad-key probe-fail formal-fail source-move-fail update-fail candidate-query-fail candidate-none install-fail postcheck-fail; do
    run_install_scenario "$scenario" 1
done

(
    root="$TEST_DIR/idempotent"; make_layout "$root"
    rm -rf "$TEST_DIR/tool/etc" "$TEST_DIR/tool/installed"
    mkdir -p "$TEST_DIR/tool/etc/keyrings" "$TEST_DIR/tool/etc/sources" "$TEST_DIR/tool/tmp"
    printf valid > "$XANMOD_KEYRING"
    write_xanmod_deb822_source "$XANMOD_SOURCE_DEB822" https://deb.xanmod.org trixie "$XANMOD_KEYRING"
    touch "$TEST_DIR/tool/installed"; : > "$root/apt.log"
    gpg() { valid_colons; }
    dpkg() { echo amd64; }
    uname() { [[ ${1:-} == -m ]] && echo x86_64 || echo 6.1.0-amd64; }
    package_is_installed() { return 0; }
    get_installed_xanmod_packages() { echo linux-xanmod-x64v3; }
    curl() { fail "idempotent path downloaded key"; }
    apt-cache() { fail "idempotent path queried candidate"; }
    apt-get() { echo "$*" >> "$root/apt.log"; [[ "$*" == *Dir::Etc::sourcelist=* ]] || fail "idempotent path ran normal APT"; }
    install_xanmod >/dev/null
    assert_eq 1 "$(wc -l < "$root/apt.log" | tr -d ' ')" "idempotent path only validates formal source"
    assert_eq false "$XANMOD_TRANSACTION_ACTIVE" "idempotent path closes snapshot"
)

(
    mkdir -p "$(dirname "$XANMOD_LOCK")"
    flock "$XANMOD_LOCK" -c 'sleep 3' & holder=$!
    sleep 0.2
    assert_fail "lock rejects concurrent XanMod operation" take_xanmod_lock
    kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true
    rm -f "$XANMOD_LOCK"
    printf protected > "$TEST_DIR/lock-target"
    ln -s "$TEST_DIR/lock-target" "$XANMOD_LOCK"
    assert_fail "lock rejects a symlink path" take_xanmod_lock
    assert_eq protected "$(<"$TEST_DIR/lock-target")" "lock refusal does not truncate symlink target"
    rm -f "$XANMOD_LOCK"
)

common_functions=(
    get_os_codename xanmod_codename_supported is_amd64 package_is_installed get_running_xanmod_package
    detect_x86_64_psabi_level get_xanmod_package_for_psabi_level detect_xanmod_package xanmod_keyring_valid
    xanmod_source_has_supported_uri xanmod_list_source_configured xanmod_deb822_source_configured
    get_xanmod_source_file xanmod_source_matches_codename write_xanmod_deb822_source xanmod_source_is_usable
    capture_xanmod_snapshot_item create_xanmod_runtime_snapshot restore_xanmod_snapshot_item
    restore_xanmod_runtime_snapshot discard_xanmod_runtime_snapshot begin_xanmod_install_transaction
    make_xanmod_stage_file cleanup_xanmod_stages stage_xanmod_key stage_xanmod_source
    xanmod_repository_ready configure_xanmod_repository abort_xanmod_install_transaction
    get_installed_xanmod_packages install_xanmod show_xanmod_status take_xanmod_lock
)
for function_name in "${common_functions[@]}"; do
    tool_body=$(env XANMOD_TEST_MODE=1 bash -c 'source "$1"; declare -f "$2"' _ "$TOOL" "$function_name")
    module_body=$(env XANMOD_TEST_MODE=1 bash -c 'source "$1"; declare -f "$2"' _ "$MODULE" "$function_name")
    assert_eq "$tool_body" "$module_body" "tool and module share $function_name contract"
done

module_cli="$TEST_DIR/module-cli"; make_layout "$module_cli"
env XANMOD_TEST_MODE=1 \
    XANMOD_KEYRING_PATH="$module_cli/key.gpg" XANMOD_SOURCE_LIST_PATH="$module_cli/release.list" \
    XANMOD_SOURCE_DEB822_PATH="$module_cli/release.sources" XANMOD_LOCK_PATH="$module_cli/xanmod.lock" \
    XANMOD_OS_RELEASE_PATH="$module_cli/os-release" XANMOD_CPUINFO_PATH="$module_cli/cpuinfo" \
    XANMOD_BACKUP_STATE_DIR="$module_cli/backups" TMPDIR="$module_cli/tmp" \
    MODULE="$MODULE" ROOT="$module_cli" bash <<'MODULE_CLI'
set -euo pipefail
fail() { printf 'FAIL: module CLI: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: module %s\n' "$*"; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected '$1', got '$2'"; pass "$3"; }
source "$MODULE"
[[ -z "$(trap -p ERR)" ]] || fail "source installed ERR trap"
pass "source leaves ERR trap unchanged"
assert_eq "$ROOT/key.gpg" "$XANMOD_KEYRING" "test mode overrides keyring"

calls="$ROOT/calls"; : > "$calls"
is_interactive_terminal() { return 1; }
require_root() { echo root >> "$calls"; }
rc=0; main xanmod > "$ROOT/refusal.log" 2>&1 || rc=$?
assert_eq 1 "$rc" "direct xanmod rejects no-TTY install without --yes"
[[ ! -s "$calls" ]] || fail "direct refusal reached root"
pass "direct refusal precedes root, dependencies, lock, and writes"

: > "$calls"
require_root() { echo root >> "$calls"; }
require_xanmod_commands() { echo dependencies >> "$calls"; }
take_xanmod_lock() { echo lock >> "$calls"; }
install_xanmod() { echo install >> "$calls"; }
show_xanmod_status() { echo status >> "$calls"; }
main xanmod --yes
assert_eq $'root\ndependencies\nlock\ninstall\nstatus' "$(<"$calls")" "xanmod --yes authorizes one complete flow"

: > "$calls"
require_root() { echo root >> "$calls"; }
configure_motd() { echo motd >> "$calls"; }
configure_chinese_locale() { echo locale >> "$calls"; }
run_authorized_xanmod_install() { fail "no-TTY all attempted XanMod"; }
show_xanmod_status() { echo status >> "$calls"; }
is_interactive_terminal() { return 1; }
main
assert_eq $'root\nmotd\nlocale\nstatus' "$(<"$calls")" "no-argument all finishes MOTD and Locale then skips XanMod"
: > "$calls"; main all
assert_eq $'root\nmotd\nlocale\nstatus' "$(<"$calls")" "explicit all without TTY skips XanMod"

: > "$calls"
is_interactive_terminal() { return 0; }
confirm_xanmod_install() { return 1; }
main all
assert_eq $'root\nmotd\nlocale\nstatus' "$(<"$calls")" "interactive all defaults XanMod to no"
: > "$calls"
confirm_xanmod_install() { return 0; }
run_authorized_xanmod_install() { echo install >> "$calls"; }
main all
assert_eq $'root\nmotd\nlocale\ninstall\nstatus' "$(<"$calls")" "interactive all runs XanMod once after authorization"

: > "$calls"
require_root() { echo root >> "$calls"; }
main help >/dev/null
[[ ! -s "$calls" ]] || fail "help required root"
pass "help remains read-only and does not require root"
MODULE_CLI

module_state="$TEST_DIR/module-state"; make_layout "$module_state"
env XANMOD_TEST_MODE=1 \
    XANMOD_KEYRING_PATH="$module_state/key.gpg" XANMOD_SOURCE_LIST_PATH="$module_state/release.list" \
    XANMOD_SOURCE_DEB822_PATH="$module_state/release.sources" XANMOD_LOCK_PATH="$module_state/xanmod.lock" \
    XANMOD_OS_RELEASE_PATH="$module_state/os-release" XANMOD_CPUINFO_PATH="$module_state/cpuinfo" \
    XANMOD_BACKUP_STATE_DIR="$module_state/backups" TMPDIR="$module_state/tmp" \
    MODULE="$MODULE" ROOT="$module_state" bash <<'MODULE_STATE'
set -euo pipefail
fail() { printf 'FAIL: module state: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: module %s\n' "$*"; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected '$1', got '$2'"; pass "$3"; }
source "$MODULE"
APT_RESULT=0; : > "$ROOT/apt.log"
apt-get() { printf '%s\n' "$*" >> "$ROOT/apt.log"; return "$APT_RESULT"; }

printf initial-key > "$XANMOD_KEYRING"
mkdir -p "$ROOT/links"; printf target > "$ROOT/links/list"
ln -s links/list "$XANMOD_SOURCE_LIST"; rm -f "$XANMOD_SOURCE_DEB822"
prepare_persistent_xanmod_backups
assert_eq 700 "$(stat -c %a "$XANMOD_BACKUP_STATE_DIR")" "backup state directory mode is 0700"
printf previous-key > "$XANMOD_KEYRING"; rm -f "$XANMOD_SOURCE_LIST"; printf previous-source > "$XANMOD_SOURCE_DEB822"
prepare_persistent_xanmod_backups
printf current-key > "$XANMOD_KEYRING"; printf current-list > "$XANMOD_SOURCE_LIST"; printf current-source > "$XANMOD_SOURCE_DEB822"
restore_xanmod_group previous
assert_eq previous-key "$(<"$XANMOD_KEYRING")" "previous group restores key"
[[ ! -e "$XANMOD_SOURCE_LIST" && ! -L "$XANMOD_SOURCE_LIST" ]] || fail "previous group did not restore absence"
pass "previous group restores missing list"
assert_eq previous-source "$(<"$XANMOD_SOURCE_DEB822")" "previous group restores Deb822 source"
restore_xanmod_group initial
assert_eq initial-key "$(<"$XANMOD_KEYRING")" "initial group restores key"
[[ -L "$XANMOD_SOURCE_LIST" ]] || fail "initial group did not restore symlink"
assert_eq links/list "$(readlink "$XANMOD_SOURCE_LIST")" "initial group restores symlink target"
[[ ! -e "$XANMOD_SOURCE_DEB822" && ! -L "$XANMOD_SOURCE_DEB822" ]] || fail "initial group did not restore absence"
pass "initial group restores missing Deb822 source"

printf live-key > "$XANMOD_KEYRING"; printf live-list > "$XANMOD_SOURCE_LIST"; printf live-source > "$XANMOD_SOURCE_DEB822"
rm -f "$XANMOD_BACKUP_STATE_DIR/release.list.previous-absent"
rc=0; restore_xanmod_group previous >/dev/null 2>&1 || rc=$?
assert_eq 2 "$rc" "missing group state refuses partial restore"
assert_eq live-key "$(<"$XANMOD_KEYRING")" "missing state leaves key untouched"
assert_eq live-list "$(<"$XANMOD_SOURCE_LIST")" "missing state leaves list untouched"
assert_eq live-source "$(<"$XANMOD_SOURCE_DEB822")" "missing state leaves source untouched"

prepare_persistent_xanmod_backups
printf runtime-key > "$XANMOD_KEYRING"; printf runtime-list > "$XANMOD_SOURCE_LIST"; printf runtime-source > "$XANMOD_SOURCE_DEB822"
eval "$(declare -f restore_xanmod_persistent_item | sed '1s/restore_xanmod_persistent_item/original_restore_xanmod_persistent_item/')"
restore_calls=0
restore_xanmod_persistent_item() {
    ((restore_calls += 1))
    if (( restore_calls == 2 )); then return 1; fi
    original_restore_xanmod_persistent_item "$@"
}
rc=0; restore_xanmod_group previous >/dev/null 2>&1 || rc=$?
assert_eq 1 "$rc" "middle group failure returns nonzero"
assert_eq runtime-key "$(<"$XANMOD_KEYRING")" "middle failure rolls key back"
assert_eq runtime-list "$(<"$XANMOD_SOURCE_LIST")" "middle failure rolls list back"
assert_eq runtime-source "$(<"$XANMOD_SOURCE_DEB822")" "middle failure rolls source back"
eval "$(declare -f original_restore_xanmod_persistent_item | sed '1s/original_restore_xanmod_persistent_item/restore_xanmod_persistent_item/')"

rm -f "$XANMOD_SOURCE_LIST"
printf runtime-list > "$XANMOD_SOURCE_LIST"
prepare_persistent_xanmod_backups
printf after-key > "$XANMOD_KEYRING"; printf after-list > "$XANMOD_SOURCE_LIST"; printf after-source > "$XANMOD_SOURCE_DEB822"
APT_RESULT=1
rc=0; restore_xanmod_group previous >/dev/null 2>&1 || rc=$?
assert_eq 1 "$rc" "APT refresh failure returns nonzero"
assert_eq runtime-key "$(<"$XANMOD_KEYRING")" "APT failure preserves requested key restore"
assert_eq runtime-list "$(<"$XANMOD_SOURCE_LIST")" "APT failure preserves requested list restore"
assert_eq runtime-source "$(<"$XANMOD_SOURCE_DEB822")" "APT failure preserves requested source restore"
if grep -Eq '(^| )(remove|purge)( |$)' "$ROOT/apt.log"; then fail "restore removed a kernel"; fi
pass "restore never removes an installed kernel"
MODULE_STATE

unknown_root="$TEST_DIR/module-unknown"; make_layout "$unknown_root"
env XANMOD_TEST_MODE=1 \
    XANMOD_KEYRING_PATH="$unknown_root/key.gpg" XANMOD_SOURCE_LIST_PATH="$unknown_root/release.list" \
    XANMOD_SOURCE_DEB822_PATH="$unknown_root/release.sources" XANMOD_LOCK_PATH="$unknown_root/lock" \
    XANMOD_OS_RELEASE_PATH="$unknown_root/os-release" XANMOD_CPUINFO_PATH="$unknown_root/cpuinfo" \
    XANMOD_BACKUP_STATE_DIR="$unknown_root/backups" TMPDIR="$unknown_root/tmp" \
    MODULE="$MODULE" ROOT="$unknown_root" bash <<'MODULE_UNKNOWN'
set -euo pipefail
fail() { printf 'FAIL: module unknown: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: module %s\n' "$*"; }
source "$MODULE"
printf old-key > "$XANMOD_KEYRING"
write_xanmod_deb822_source "$XANMOD_SOURCE_DEB822" https://deb.xanmod.org trixie "$XANMOD_KEYRING"
prepare_persistent_xanmod_backups
for target in "${XANMOD_MANAGED_PATHS[@]}"; do
    prefix=$(get_xanmod_backup_prefix "$target")
    [[ -f "${prefix}.initial-unknown" ]] || fail "managed group did not mark $(basename "$target") unknown"
done
pass "previously managed group records all missing initial states as unknown"
printf live-key > "$XANMOD_KEYRING"; printf live-list > "$XANMOD_SOURCE_LIST"; printf live-source > "$XANMOD_SOURCE_DEB822"
rc=0; restore_xanmod_group initial >/dev/null 2>&1 || rc=$?
[[ "$rc" == 2 ]] || fail "initial unknown group returned $rc"
[[ $(<"$XANMOD_KEYRING") == live-key && $(<"$XANMOD_SOURCE_LIST") == live-list && $(<"$XANMOD_SOURCE_DEB822") == live-source ]] || fail "unknown group partially restored"
pass "initial-unknown group refuses all partial changes"
MODULE_UNKNOWN

grep -Fq 'xanmod-install.sh) --yes' "$ROOT_DIR/README.md" || fail "README omits standalone --yes example"
pass "README documents standalone --yes"
grep -Fq 'xanmod-install.sh) install --yes' "$ROOT_DIR/README.md" || fail "README omits install --yes example"
pass "README documents install --yes"
grep -Fq 'system-customize.sh") xanmod --yes' "$ROOT_DIR/README.md" || fail "README omits module --yes example"
pass "README documents module --yes"
grep -Fq 'all` 或无参数模式' "$ROOT_DIR/README.md" || fail "README omits no-TTY all behavior"
pass "README documents no-TTY all skip"
grep -Fq '不会自动卸载任何内核包' "$ROOT_DIR/README.md" || fail "README omits partial APT warning"
pass "README documents no automatic kernel removal"

printf 'All XanMod tests passed.\n'
