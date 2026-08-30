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
assert_ok() { local name="$1"; shift; "$@" || fail "$name"; pass "$name"; }
assert_fail() { local name="$1"; shift; if "$@"; then fail "$name: unexpectedly succeeded"; fi; pass "$name"; }
assert_file_eq() {
    local expected="$1" file="$2" name="$3"
    [[ -f "$file" && ! -L "$file" ]] || fail "$name: expected regular file $file"
    assert_eq "$expected" "$(<"$file")" "$name"
}

make_layout() {
    local root="$1"
    mkdir -p "$root/etc/keyrings" "$root/etc/sources" "$root/run" "$root/tmp"
    printf 'VERSION_CODENAME=trixie\n' > "$root/os-release"
    printf '%s\n' \
        'flags : lm cmov cx8 fpu fxsr mmx syscall sse2 cx16 lahf_lm popcnt sse4_1 sse4_2 ssse3 avx avx2 bmi1 bmi2 f16c fma abm movbe xsave' \
        > "$root/cpuinfo"
}

valid_colons() {
    printf '%s\n' \
        'pub:-:4096:1:86F7D09EE734E623:0:0::-:::scESC::::::23::0:' \
        'fpr:::::::::D38D7D1DA1349567ADED882D86F7D09EE734E623:' \
        'uid:-::::0::hash::XanMod Kernel <kernel@xanmod.org>::::::::::0:' \
        'sub:-:4096:1:1111111111111111:0:0:::::e::::::23:' \
        'fpr:::::::::1111111111111111111111111111111111111111:'
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
OTHER_UID=65534; [[ "$OTHER_UID" == "$XANMOD_TRUSTED_UID" ]] && OTHER_UID=0
OTHER_GID=65534; [[ "$OTHER_GID" == "$XANMOD_TRUSTED_GID" ]] && OTHER_GID=0

assert_eq "$TEST_DIR/tool/etc/keyrings/xanmod.gpg" "$XANMOD_KEYRING" "tool test mode overrides keyring"
assert_eq "$TEST_DIR/tool/etc/sources/xanmod.list" "$XANMOD_SOURCE_LIST" "tool test mode overrides list"
assert_eq "$TEST_DIR/tool/etc/sources/xanmod.sources" "$XANMOD_SOURCE_DEB822" "tool test mode overrides Deb822"
assert_eq "$TEST_DIR/tool/run/xanmod.lock" "$XANMOD_LOCK" "tool test mode overrides lock"
assert_eq "$EUID" "$XANMOD_TRUSTED_UID" "test mode trusts current UID"
assert_eq "$(id -g)" "$XANMOD_TRUSTED_GID" "test mode trusts current GID"
[[ -z "$(trap -p ERR)" ]] || fail "sourcing tool installed ERR trap"
pass "sourcing tool leaves ERR trap unchanged"

tool_production=$(env -u XANMOD_TEST_MODE XANMOD_KEYRING_PATH=/tmp/evil bash -c \
    'source "$1"; printf "%s|%s|%s" "$XANMOD_KEYRING" "$XANMOD_TRUSTED_UID" "$XANMOD_TRUSTED_GID"' _ "$TOOL")
assert_eq '/etc/apt/keyrings/xanmod-archive-keyring.gpg|0|0' "$tool_production" \
    "tool production trust ignores overrides"
module_production=$(env -u XANMOD_TEST_MODE XANMOD_KEYRING_PATH=/tmp/evil \
    XANMOD_BACKUP_STATE_DIR=/tmp/evil-state bash -c \
    'source "$1"; printf "%s|%s|%s|%s" "$XANMOD_KEYRING" "$XANMOD_BACKUP_STATE_DIR" "$XANMOD_TRUSTED_UID" "$XANMOD_TRUSTED_GID"' _ "$MODULE")
assert_eq '/etc/apt/keyrings/xanmod-archive-keyring.gpg|/var/lib/linux-setup/apt-source-backups|0|0' \
    "$module_production" "module production trust ignores overrides"
for script in "$TOOL" "$MODULE"; do
    grep -Fq 'if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then' "$script" || fail "$(basename "$script") lacks source guard"
    pass "$(basename "$script") has source guard"
done
if grep -RFn '.new' "$TOOL" "$MODULE" >/dev/null; then fail "fixed .new path remains"; fi
pass "XanMod implementations avoid fixed .new paths"
if grep -Rq '^xanmod_source_has_supported_uri()' "$TOOL" "$MODULE"; then fail "unused URI validator remains"; fi
pass "unused XanMod URI validator is removed"
for script in "$TOOL" "$MODULE"; do
    grep -Fq 'DEBIAN_FRONTEND=noninteractive apt-get install -y "$XANMOD_PLAN_TARGET_PACKAGE"' "$script" ||
        fail "$(basename "$script") kernel install is not explicit noninteractive"
    pass "$(basename "$script") uses explicit noninteractive kernel install"
done

(
    parse_xanmod_arguments
    assert_eq install "$XANMOD_ACTION" "tool defaults to install"
    parse_xanmod_arguments --yes
    assert_eq true "$XANMOD_ASSUME_YES" "tool accepts --yes"
    parse_xanmod_arguments install -y
    assert_eq true "$XANMOD_ASSUME_YES" "tool accepts install -y"
    parse_xanmod_arguments status
    assert_eq status "$XANMOD_ACTION" "tool accepts status"
    assert_fail "tool rejects status --yes" parse_xanmod_arguments status --yes
    assert_fail "tool rejects reversed arguments" parse_xanmod_arguments --yes install
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
assert_eq v1 "$(detect_x86_64_psabi_level "$TEST_DIR/v1.cpu")" "detect v1"
assert_eq v2 "$(detect_x86_64_psabi_level "$TEST_DIR/v2.cpu")" "detect v2"
assert_eq v3 "$(detect_x86_64_psabi_level "$TEST_DIR/v3.cpu")" "detect v3"
assert_eq v4 "$(detect_x86_64_psabi_level "$TEST_DIR/v4.cpu")" "detect v4"
assert_eq linux-xanmod-x64v2 "$(get_xanmod_package_for_psabi_level v2)" "v2 package mapping"
assert_eq linux-xanmod-x64v3 "$(get_xanmod_package_for_psabi_level v4)" "v4 uses v3 package"
(
    is_amd64() { return 0; }
    detect_xanmod_package() { return 3; }
    get_running_xanmod_package() { echo linux-xanmod-x64v2; }
    get_os_codename() { echo trixie; }
    get_installed_xanmod_packages() { :; }
    package_is_installed() { return 1; }
    xanmod_repository_files_ready() { return 1; }
    resolve_xanmod_plan
    assert_eq linux-xanmod-x64v2 "$XANMOD_PLAN_TARGET_PACKAGE" "CPU unreadable plan reuses running XanMod branch"
)

(
    gpg() {
        case "$(<"${!#}")" in
            valid) valid_colons ;;
            extra) valid_colons; printf '%s\n' pub::::::::: fpr:::::::::AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA: ;;
            wrong) valid_colons | sed 's/XanMod Kernel <kernel@xanmod.org>/Wrong <wrong@example.org>/' ;;
            *) return 1 ;;
        esac
    }
    printf valid > "$TEST_DIR/valid.key"; printf extra > "$TEST_DIR/extra.key"; printf wrong > "$TEST_DIR/wrong.key"
    assert_ok "strict key accepts official primary and subkey" xanmod_keyring_valid "$TEST_DIR/valid.key"
    assert_fail "strict key rejects extra primary" xanmod_keyring_valid "$TEST_DIR/extra.key"
    assert_fail "strict key rejects wrong UID" xanmod_keyring_valid "$TEST_DIR/wrong.key"
)

reset_tool_files() {
    command rm -rf "$TEST_DIR/tool/etc" "$TEST_DIR/tool/original" "$TEST_DIR/tool/installed" "$TEST_DIR/tool/run"
    mkdir -p "$TEST_DIR/tool/etc/keyrings" "$TEST_DIR/tool/etc/sources" "$TEST_DIR/tool/original" "$TEST_DIR/tool/run" "$TEST_DIR/tool/tmp"
    printf 'VERSION_CODENAME=trixie\n' > "$XANMOD_OS_RELEASE"
    cp "$TEST_DIR/v3.cpu" "$XANMOD_CPUINFO"
    XANMOD_RUNTIME_SNAPSHOT_DIR=""; XANMOD_RUNTIME_SNAPSHOT_BUILDING=false
    XANMOD_TRANSACTION_ACTIVE=false; XANMOD_CONFIG_MODIFIED=false
    XANMOD_STAGED_KEY=""; XANMOD_STAGED_SOURCE=""; XANMOD_CANDIDATE_SOURCE=""
    XANMOD_ARMORED_KEY_TEMP=""; XANMOD_ACTIVE_APT_LISTS_DIR=""; XANMOD_ACTIVE_APT_LISTS_BUILDING=false
    XANMOD_ALLOCATION_CANDIDATE=""; XANMOD_ALLOCATION_KIND=""; XANMOD_ALLOCATION_OWNER_TOKEN=""
    XANMOD_ALLOCATION_EXPECTED_MODE=""; XANMOD_ALLOCATION_PROOF_OWNED=false; XANMOD_ALLOCATION_STATE=""
    XANMOD_ALLOCATION_CRITICAL=false; XANMOD_ALLOCATION_PENDING_SIGNAL=""; XANMOD_ALLOCATION_PENDING_SIGNAL_STATUS=0
    XANMOD_RESTORE_STAGE=""
    XANMOD_GUARD_ACTIVE=false; XANMOD_LOCK_HELD=false
    reset_xanmod_plan
}

make_safe_repository() {
    printf valid > "$XANMOD_KEYRING"; chmod 0644 "$XANMOD_KEYRING"
    write_xanmod_deb822_source "$XANMOD_SOURCE_DEB822" https://deb.xanmod.org trixie "$XANMOD_KEYRING"
    chmod 0644 "$XANMOD_SOURCE_DEB822"
    command rm -f "$XANMOD_SOURCE_LIST"
}

(
    reset_tool_files
    gpg() { valid_colons; }
    make_safe_repository
    assert_ok "formal keyring accepts exact owner and 0644" xanmod_formal_keyring_valid
    assert_ok "formal Deb822 accepts exact owner and 0644" xanmod_deb822_source_configured
    chmod 0666 "$XANMOD_KEYRING"
    assert_fail "formal keyring rejects 0666" xanmod_formal_keyring_valid
    apt_calls=0
    apt-get() { ((apt_calls += 1)); return 0; }
    assert_fail "repository_ready rejects unsafe key mode before APT" xanmod_repository_ready trixie
    assert_eq 0 "$apt_calls" "unsafe formal metadata blocks APT validation"
    chmod 0644 "$XANMOD_KEYRING"; chmod 0646 "$XANMOD_SOURCE_DEB822"
    assert_fail "formal Deb822 rejects 0646" xanmod_deb822_source_configured
    chmod 0644 "$XANMOD_SOURCE_DEB822"
    printf 'deb [signed-by=%s] https://deb.xanmod.org trixie main\n' "$XANMOD_KEYRING" > "$XANMOD_SOURCE_LIST"
    chmod 0666 "$XANMOD_SOURCE_LIST"
    assert_fail "formal legacy list rejects 0666" xanmod_list_source_configured
)

(
    reset_tool_files
    gpg() { valid_colons; }
    make_safe_repository
    stat() {
        local last=${!#}
        if [[ "$last" == "$XANMOD_KEYRING" && "$*" == *'%u:%g:%a'* ]]; then
            printf '%s:%s:644\n' "$OTHER_UID" "$XANMOD_TRUSTED_GID"
        else
            command stat "$@"
        fi
    }
    assert_fail "formal keyring rejects wrong owner" xanmod_formal_keyring_valid
    assert_fail "repository files reject wrong key owner" xanmod_repository_files_ready trixie
)

(
    gpg() { valid_colons; }
    for bad_mode in 0666 0646; do
        reset_tool_files; make_safe_repository; chmod "$bad_mode" "$XANMOD_KEYRING"
        assert_fail "formal keyring rejects $bad_mode" xanmod_formal_keyring_valid
        reset_tool_files; make_safe_repository; chmod "$bad_mode" "$XANMOD_SOURCE_DEB822"
        assert_fail "formal Deb822 rejects $bad_mode" xanmod_deb822_source_configured
        reset_tool_files; make_safe_repository
        printf 'deb [signed-by=%s] https://deb.xanmod.org trixie main\n' "$XANMOD_KEYRING" > "$XANMOD_SOURCE_LIST"
        chmod "$bad_mode" "$XANMOD_SOURCE_LIST"
        assert_fail "formal legacy list rejects $bad_mode" xanmod_list_source_configured
    done
)

for wrong_owner_target in key source list; do
    (
        reset_tool_files
        gpg() { valid_colons; }
        make_safe_repository
        if [[ "$wrong_owner_target" == list ]]; then
            printf 'deb [signed-by=%s] https://deb.xanmod.org trixie main\n' "$XANMOD_KEYRING" > "$XANMOD_SOURCE_LIST"
            chmod 0644 "$XANMOD_SOURCE_LIST"
            owner_path="$XANMOD_SOURCE_LIST"
        elif [[ "$wrong_owner_target" == source ]]; then
            owner_path="$XANMOD_SOURCE_DEB822"
        else
            owner_path="$XANMOD_KEYRING"
        fi
        stat() {
            local last=${!#}
            if [[ "$last" == "$owner_path" && "$*" == *'%u:%g:%a'* ]]; then
                printf '%s:%s:644\n' "$OTHER_UID" "$XANMOD_TRUSTED_GID"
            else
                command stat "$@"
            fi
        }
        case "$wrong_owner_target" in
            key) assert_fail "formal keyring rejects wrong owner individually" xanmod_formal_keyring_valid ;;
            source) assert_fail "formal Deb822 rejects wrong owner individually" xanmod_deb822_source_configured ;;
            list) assert_fail "formal legacy list rejects wrong owner individually" xanmod_list_source_configured ;;
        esac
    )
done

(
    reset_tool_files
    gpg() { valid_colons; }
    make_safe_repository
    stat() {
        local last=${!#}
        if [[ "$last" == "$XANMOD_KEYRING" && "$*" == *'%u:%g:%a'* ]]; then
            printf '%s:%s:644\n' "$XANMOD_TRUSTED_UID" "$OTHER_GID"
        else
            command stat "$@"
        fi
    }
    assert_fail "formal keyring rejects wrong GID" xanmod_formal_keyring_valid
)

(
    reset_tool_files
    gpg() { valid_colons; }
    make_safe_repository
    command mv "$XANMOD_SOURCE_DEB822" "$TEST_DIR/tool/real.sources"
    ln -s "$TEST_DIR/tool/real.sources" "$XANMOD_SOURCE_DEB822"
    assert_fail "formal source rejects symlink" xanmod_deb822_source_configured
)

(
    reset_tool_files
    gpg() { valid_colons; }
    make_safe_repository
    dpkg() { echo amd64; }
    uname() { [[ ${1:-} == -m ]] && echo x86_64 || echo 6.1.0-amd64; }
    get_installed_xanmod_packages() { echo linux-xanmod-x64v3; }
    package_is_installed() { return 0; }
    is_interactive_terminal() { return 1; }
    require_root() { fail "no-op main required root"; }
    take_xanmod_lock() { fail "no-op main took lock"; }
    curl() { fail "no-op main downloaded"; }
    apt-get() { fail "no-op main used APT"; }
    main install >/dev/null
    pass "real tool main returns success without authorization for strict no-op"
)

(
    reset_tool_files
    printf 'VERSION_CODENAME=BAD!\n' > "$XANMOD_OS_RELEASE"
    dpkg() { echo amd64; }
    uname() { [[ ${1:-} == -m ]] && echo x86_64 || echo 6.1.0; }
    is_interactive_terminal() { return 1; }
    require_root() { fail "unsafe codename required root"; }
    take_xanmod_lock() { fail "unsafe codename took lock"; }
    apt-get() { fail "unsafe codename used APT"; }
    main install >/dev/null
    pass "unsafe codename skips without authorization"
)

(
    reset_tool_files
    dpkg() { echo arm64; }
    uname() { [[ ${1:-} == -m ]] && echo aarch64 || echo 6.1.0; }
    is_interactive_terminal() { return 1; }
    require_root() { fail "non-amd64 required root"; }
    take_xanmod_lock() { fail "non-amd64 took lock"; }
    main install >/dev/null
    pass "non-amd64 skips without authorization"
)

(
    reset_tool_files
    cp "$TEST_DIR/v1.cpu" "$XANMOD_CPUINFO"
    dpkg() { echo amd64; }
    uname() { [[ ${1:-} == -m ]] && echo x86_64 || echo 6.1.0; }
    is_interactive_terminal() { return 1; }
    require_root() { fail "v1 required root"; }
    take_xanmod_lock() { fail "v1 took lock"; }
    main install >/dev/null
    pass "x86-64-v1 skips without authorization"
)

(
    reset_tool_files
    calls="$TEST_DIR/preauth.calls"; : > "$calls"
    dpkg() { echo amd64; }
    uname() { [[ ${1:-} == -m ]] && echo x86_64 || echo 6.1.0; }
    get_installed_xanmod_packages() { :; }
    package_is_installed() { return 1; }
    is_interactive_terminal() { return 1; }
    require_root() { echo root >> "$calls"; }
    take_xanmod_lock() { echo lock >> "$calls"; }
    curl() { echo curl >> "$calls"; }
    apt-get() { echo apt >> "$calls"; }
    rc=0; main install > "$TEST_DIR/preauth.log" 2>&1 || rc=$?
    assert_eq 1 "$rc" "real tool main requires --yes only for a modifying plan"
    [[ ! -s "$calls" ]] || fail "pre-authorization path performed a side effect"
    pass "real tool main does not lock, download, use APT, or write before authorization"
)

run_install_scenario() (
    set -euo pipefail
    trap - EXIT
    local mode="$1" expected_rc="$2" root="$TEST_DIR/install-$1" rc=0
    reset_tool_files
    mkdir -p "$root" "$TEST_DIR/tool/original"
    printf old-key > "$TEST_DIR/tool/original/key"
    ln -s "$TEST_DIR/tool/original/key" "$XANMOD_KEYRING"
    printf old-list > "$XANMOD_SOURCE_LIST"
    command rm -f "$XANMOD_SOURCE_DEB822"
    : > "$root/apt.log"; : > "$root/output.log"
    if [[ "$mode" == unsafe-mode ]]; then
        command rm -f "$XANMOD_KEYRING" "$XANMOD_SOURCE_LIST"
        printf valid > "$XANMOD_KEYRING"; chmod 0666 "$XANMOD_KEYRING"
        write_xanmod_deb822_source "$XANMOD_SOURCE_DEB822" https://deb.xanmod.org trixie "$XANMOD_KEYRING"
        chmod 0666 "$XANMOD_SOURCE_DEB822"
    fi

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
        for argument in "$@"; do [[ "$previous" == -o ]] && output="$argument"; previous="$argument"; done
        if [[ "$mode" == bad-key ]]; then printf wrong > "$output"; else printf valid > "$output"; fi
    }
    dpkg() { echo amd64; }
    uname() { [[ ${1:-} == -m ]] && echo x86_64 || echo 6.1.0-amd64; }
    get_installed_xanmod_packages() { :; }
    package_is_installed() { [[ -f "$TEST_DIR/tool/installed" ]]; }
    apt-cache() {
        if [[ "$mode" == candidate-none ]]; then echo '  Candidate: (none)'; else echo '  Candidate: 6.12.1-xanmod1'; fi
    }
    apt-get() {
        printf 'DEBIAN_FRONTEND=%s|%s\n' "${DEBIAN_FRONTEND:-}" "$*" >> "$root/apt.log"
        local source_file="" argument
        for argument in "$@"; do case "$argument" in Dir::Etc::sourcelist=*) source_file=${argument#*=};; esac; done
        if [[ -n "$source_file" ]]; then
            [[ "$mode" == probe-fail ]] && return 41
            [[ "$mode" == formal-apt-fail && "$source_file" == "$XANMOD_SOURCE_DEB822" ]] && return 42
            return 0
        fi
        [[ ${1:-} == update && "$mode" == update-fail ]] && return 43
        if [[ ${1:-} == install ]]; then
            [[ "$mode" == install-fail ]] && return 44
            [[ "$mode" == postcheck-fail ]] || touch "$TEST_DIR/tool/installed"
        fi
        return 0
    }
    if [[ "$mode" == formal-hook-fail ]]; then xanmod_after_formal_commit_hook() { return 1; }; fi
    if [[ "$mode" == source-move-fail ]]; then
        mv() { local last=${!#}; [[ "$last" == "$XANMOD_SOURCE_DEB822" ]] && return 45; command mv "$@"; }
    fi

    resolve_xanmod_plan
    [[ "$XANMOD_PLAN_ACTION" == modify ]] || fail "$mode did not resolve to modify"
    install_xanmod > "$root/output.log" 2>&1 || rc=$?
    assert_eq "$expected_rc" "$rc" "$mode returns expected status"
    if (( expected_rc == 0 )); then
        assert_file_eq valid "$XANMOD_KEYRING" "$mode installs exact key"
        assert_eq "$XANMOD_TRUSTED_UID:$XANMOD_TRUSTED_GID:644" \
            "$(stat -c '%u:%g:%a' "$XANMOD_KEYRING")" "$mode key owner and mode"
        assert_eq "$XANMOD_TRUSTED_UID:$XANMOD_TRUSTED_GID:644" \
            "$(stat -c '%u:%g:%a' "$XANMOD_SOURCE_DEB822")" "$mode source owner and mode"
        [[ ! -e "$XANMOD_SOURCE_LIST" && ! -L "$XANMOD_SOURCE_LIST" ]] || fail "$mode retained list"
        pass "$mode removes legacy list"
        grep -Fq 'DEBIAN_FRONTEND=noninteractive|install -y linux-xanmod-x64v3' "$root/apt.log" || fail "$mode install command mismatch"
        pass "$mode uses noninteractive kernel install"
    else
        if [[ "$mode" == unsafe-mode ]]; then
            fail "unsafe-mode unexpectedly failed"
        fi
        [[ -L "$XANMOD_KEYRING" ]] || fail "$mode did not restore key symlink"
        assert_file_eq old-list "$XANMOD_SOURCE_LIST" "$mode restores old list"
        [[ ! -e "$XANMOD_SOURCE_DEB822" && ! -L "$XANMOD_SOURCE_DEB822" ]] || fail "$mode did not restore missing source"
        pass "$mode restores missing source"
    fi
    assert_eq false "$XANMOD_GUARD_ACTIVE" "$mode clears transaction guards"
    assert_eq false "$XANMOD_APT_MAY_BE_PARTIAL" "$mode clears partial-install transaction state"
    assert_eq false "$XANMOD_TRANSACTION_ACTIVE" "$mode clears runtime snapshot state"
    [[ -z "$(find "$TEST_DIR/tool" \( -name '.xanmod-stage.*' -o -name 'xanmod-runtime-snapshot.*' -o -name 'xanmod-apt-lists.*' \) -print -quit)" ]] || fail "$mode left temporary files"
    pass "$mode leaves no stage, snapshot, or APT-list residue"
    if [[ "$mode" == install-fail || "$mode" == postcheck-fail ]]; then
        grep -Fq '不会自动卸载任何包' "$root/output.log" || fail "$mode omits partial-install warning"
        pass "$mode warns that partial packages are not auto-removed"
    fi
)

run_install_scenario success 0
run_install_scenario unsafe-mode 0
run_install_scenario formal-hook-fail 1
run_install_scenario bad-key 1
run_install_scenario probe-fail 1
run_install_scenario formal-apt-fail 1
run_install_scenario source-move-fail 1
run_install_scenario update-fail 1
run_install_scenario candidate-none 1
run_install_scenario install-fail 1
run_install_scenario postcheck-fail 1

(
    reset_tool_files
    mkdir -p "$(dirname "$XANMOD_LOCK")"
    install -m 0600 /dev/null "$XANMOD_LOCK"
    assert_ok "trusted lock file is accepted" take_xanmod_lock
    assert_ok "trusted lock can be released" release_xanmod_lock
    flock "$XANMOD_LOCK" -c 'sleep 3' & holder=$!
    sleep 0.2
    assert_fail "concurrent XanMod lock is rejected" take_xanmod_lock
    kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true
    chmod 0666 "$XANMOD_LOCK"
    assert_fail "group-writable lock is rejected" take_xanmod_lock
    command rm -f "$XANMOD_LOCK"; printf protected > "$TEST_DIR/lock-target"; ln -s "$TEST_DIR/lock-target" "$XANMOD_LOCK"
    assert_fail "lock symlink is rejected" take_xanmod_lock
    assert_eq protected "$(<"$TEST_DIR/lock-target")" "lock symlink rejection does not truncate target"
)

(
    reset_tool_files
    install -m 0600 /dev/null "$XANMOD_LOCK"
    stat() {
        local last=${!#}
        if [[ "$last" == "$XANMOD_LOCK" ]]; then
            case "$*" in *'%u:%g:%a'*) printf '%s:%s:600\n' "$OTHER_UID" "$XANMOD_TRUSTED_GID";; *) command stat "$@";; esac
        else command stat "$@"; fi
    }
    assert_fail "wrong-owner lock is rejected" take_xanmod_lock
)
(
    reset_tool_files
    install -m 0600 /dev/null "$XANMOD_LOCK"
    stat() {
        local last=${!#}
        if [[ "$last" == "$XANMOD_LOCK" && "$*" == *'%u:%g:%a'* ]]; then
            printf '%s:%s:600\n' "$XANMOD_TRUSTED_UID" "$OTHER_GID"
        else command stat "$@"; fi
    }
    assert_fail "wrong-GID lock is rejected" take_xanmod_lock
)

(
    reset_tool_files
    XANMOD_STAGED_KEY="$TEST_DIR/tool/stage-key"; printf residue > "$XANMOD_STAGED_KEY"
    rm() { local last=${!#}; [[ "$last" == "$XANMOD_STAGED_KEY" ]] && return 1; command rm "$@"; }
    rc=0; cleanup_xanmod_stages > "$TEST_DIR/stage-cleanup.log" 2>&1 || rc=$?
    assert_eq 1 "$rc" "stage deletion failure returns nonzero"
    grep -Fq "$XANMOD_STAGED_KEY" "$TEST_DIR/stage-cleanup.log" || fail "stage cleanup did not report residue path"
    pass "stage deletion failure reports exact residue path"
    unset -f rm; command rm -f "$XANMOD_STAGED_KEY"; XANMOD_STAGED_KEY=""
)

(
    reset_tool_files
    printf key > "$XANMOD_KEYRING"; printf list > "$XANMOD_SOURCE_LIST"; printf source > "$XANMOD_SOURCE_DEB822"
    create_xanmod_runtime_snapshot
    snapshot="$XANMOD_RUNTIME_SNAPSHOT_DIR"
    rm() { local last=${!#}; [[ "$last" == "$snapshot" ]] && return 1; command rm "$@"; }
    rc=0; discard_xanmod_runtime_snapshot > "$TEST_DIR/snapshot-cleanup.log" 2>&1 || rc=$?
    assert_eq 1 "$rc" "snapshot deletion failure returns nonzero"
    assert_eq "$snapshot" "$XANMOD_RUNTIME_SNAPSHOT_DIR" "snapshot deletion failure preserves path"
    assert_eq true "$XANMOD_TRANSACTION_ACTIVE" "snapshot deletion failure preserves active state"
    grep -Fq "$snapshot" "$TEST_DIR/snapshot-cleanup.log" || fail "snapshot cleanup did not report residue path"
    pass "snapshot deletion failure reports exact residue path"
    unset -f rm
    discard_xanmod_runtime_snapshot
    [[ ! -e "$snapshot" ]] || fail "snapshot deletion retry left directory"
    assert_eq false "$XANMOD_TRANSACTION_ACTIVE" "snapshot deletion retry clears active state"
)

(
    reset_tool_files
    printf original-key > "$XANMOD_KEYRING"; printf original-list > "$XANMOD_SOURCE_LIST"; printf original-source > "$XANMOD_SOURCE_DEB822"
    create_xanmod_runtime_snapshot
    snapshot="$XANMOD_RUNTIME_SNAPSHOT_DIR"
    XANMOD_CONFIG_MODIFIED=true
    printf changed-key > "$XANMOD_KEYRING"; printf changed-list > "$XANMOD_SOURCE_LIST"; printf changed-source > "$XANMOD_SOURCE_DEB822"
    cp() { local source=${@: -2:1}; [[ "$source" == "$snapshot/item-1.data" ]] && return 1; command cp "$@"; }
    rc=0; restore_xanmod_runtime_snapshot > "$TEST_DIR/runtime-cp-restore.log" 2>&1 || rc=$?
    assert_eq 1 "$rc" "runtime restore cp failure returns nonzero"
    [[ -d "$snapshot" ]] || fail "runtime restore cp failure deleted snapshot"
    pass "runtime restore cp failure preserves snapshot directory"
    assert_eq true "$XANMOD_TRANSACTION_ACTIVE" "runtime restore cp failure preserves active state"
    assert_eq true "$XANMOD_CONFIG_MODIFIED" "runtime restore cp failure preserves modified state"
    grep -Fq "$snapshot" "$TEST_DIR/runtime-cp-restore.log" || fail "runtime restore cp failure omitted snapshot path"
    pass "runtime restore cp failure reports retained snapshot path"
    unset -f cp
    restore_xanmod_runtime_snapshot
    assert_file_eq original-key "$XANMOD_KEYRING" "runtime cp retry restores key"
    assert_file_eq original-list "$XANMOD_SOURCE_LIST" "runtime cp retry restores list"
    assert_file_eq original-source "$XANMOD_SOURCE_DEB822" "runtime cp retry restores source"
    [[ ! -e "$snapshot" ]] || fail "runtime cp retry left snapshot"
    assert_eq false "$XANMOD_TRANSACTION_ACTIVE" "runtime cp retry clears active state"
    assert_eq false "$XANMOD_CONFIG_MODIFIED" "runtime cp retry clears modified state"
)

(
    reset_tool_files
    printf original-key > "$XANMOD_KEYRING"; printf original-list > "$XANMOD_SOURCE_LIST"; printf original-source > "$XANMOD_SOURCE_DEB822"
    create_xanmod_runtime_snapshot
    snapshot="$XANMOD_RUNTIME_SNAPSHOT_DIR"
    XANMOD_CONFIG_MODIFIED=true
    printf changed-key > "$XANMOD_KEYRING"; printf changed-list > "$XANMOD_SOURCE_LIST"; printf changed-source > "$XANMOD_SOURCE_DEB822"
    rm() { local last=${!#}; [[ "$last" == "$XANMOD_SOURCE_LIST" ]] && return 1; command rm "$@"; }
    rc=0; restore_xanmod_runtime_snapshot > "$TEST_DIR/runtime-rm-restore.log" 2>&1 || rc=$?
    assert_eq 1 "$rc" "runtime restore rm failure returns nonzero"
    [[ -d "$snapshot" ]] || fail "runtime restore rm failure deleted snapshot"
    pass "runtime restore rm failure preserves snapshot directory"
    assert_eq true "$XANMOD_TRANSACTION_ACTIVE" "runtime restore rm failure preserves active state"
    assert_eq true "$XANMOD_CONFIG_MODIFIED" "runtime restore rm failure preserves modified state"
    grep -Fq "$snapshot" "$TEST_DIR/runtime-rm-restore.log" || fail "runtime restore rm failure omitted snapshot path"
    pass "runtime restore rm failure reports retained snapshot path"
    unset -f rm
    restore_xanmod_runtime_snapshot
    assert_file_eq original-list "$XANMOD_SOURCE_LIST" "runtime rm retry restores list"
    [[ ! -e "$snapshot" ]] || fail "runtime rm retry left snapshot"
    assert_eq false "$XANMOD_TRANSACTION_ACTIVE" "runtime rm retry clears active state"
)

(
    reset_tool_files
    snapshot="$TMPDIR/xanmod-runtime-snapshot.incomplete"
    mkdir -m 0700 "$snapshot"
    XANMOD_RUNTIME_SNAPSHOT_DIR="$snapshot"
    XANMOD_RUNTIME_SNAPSHOT_BUILDING=true
    XANMOD_TRANSACTION_ACTIVE=false
    rm() { local last=${!#}; [[ "$last" == "$snapshot" ]] && return 1; command rm "$@"; }
    rc=0; cleanup_incomplete_xanmod_runtime_snapshot > "$TEST_DIR/incomplete-runtime-cleanup.log" 2>&1 || rc=$?
    assert_eq 1 "$rc" "incomplete runtime snapshot deletion failure returns nonzero"
    assert_eq "$snapshot" "$XANMOD_RUNTIME_SNAPSHOT_DIR" "incomplete runtime deletion failure preserves path"
    assert_eq true "$XANMOD_RUNTIME_SNAPSHOT_BUILDING" "incomplete runtime deletion failure preserves building state"
    grep -Fq "$snapshot" "$TEST_DIR/incomplete-runtime-cleanup.log" || fail "incomplete runtime cleanup omitted residue path"
    pass "incomplete runtime snapshot deletion failure reports exact path"
    unset -f rm; command rm -rf "$snapshot"; XANMOD_RUNTIME_SNAPSHOT_DIR=""; XANMOD_RUNTIME_SNAPSHOT_BUILDING=false
)

(
    reset_tool_files
    candidate="$TEST_DIR/tool/candidate.sources"; printf 'Types: deb\n' > "$candidate"
    apt-get() { return 0; }
    rm() { local last=${!#}; [[ -d "$last" && "$(basename "$last")" == xanmod-apt-lists.* ]] && return 1; command rm "$@"; }
    rc=0; xanmod_source_is_usable "$candidate" > "$TEST_DIR/lists-cleanup.log" 2>&1 || rc=$?
    assert_eq 125 "$rc" "APT lists deletion failure returns cleanup status"
    grep -Fq '临时 APT lists 残留:' "$TEST_DIR/lists-cleanup.log" || fail "APT lists cleanup omitted residue path"
    pass "APT lists deletion failure reports exact residue path"
    unset -f rm; command find "$TMPDIR" -maxdepth 1 -type d -name 'xanmod-apt-lists.*' -exec rm -rf {} +
    XANMOD_ACTIVE_APT_LISTS_DIR=""
)

(
    reset_tool_files
    dangling="$TEST_DIR/tool/dangling-lists"
    ln -s "$TEST_DIR/tool/missing-lists-target" "$dangling"
    XANMOD_ACTIVE_APT_LISTS_DIR="$dangling"
    cleanup_xanmod_active_apt_lists
    [[ ! -e "$dangling" && ! -L "$dangling" ]] || fail "dangling APT lists symlink remained"
    assert_eq '' "$XANMOD_ACTIVE_APT_LISTS_DIR" "dangling APT lists cleanup clears variable only after deletion"
)

(
    reset_tool_files
    dangling="$TEST_DIR/tool/dangling-lists-fail"
    ln -s "$TEST_DIR/tool/missing-lists-target" "$dangling"
    XANMOD_ACTIVE_APT_LISTS_DIR="$dangling"
    rm() { local last=${!#}; [[ "$last" == "$dangling" ]] && return 1; command rm "$@"; }
    rc=0; cleanup_xanmod_active_apt_lists > "$TEST_DIR/dangling-lists-fail.log" 2>&1 || rc=$?
    assert_eq 1 "$rc" "dangling APT lists rm failure returns nonzero"
    assert_eq "$dangling" "$XANMOD_ACTIVE_APT_LISTS_DIR" "dangling APT lists rm failure preserves variable"
    grep -Fq "$dangling" "$TEST_DIR/dangling-lists-fail.log" || fail "dangling APT lists failure omitted residue path"
    pass "dangling APT lists rm failure reports exact path"
    unset -f rm; command rm -f "$dangling"; XANMOD_ACTIVE_APT_LISTS_DIR=""
)

(
    reset_tool_files
    parent="$TEST_DIR/tool/tmp"
    collision="$parent/alloc-dir.collision"
    mkdir -m 0700 "$collision"; printf keep > "$collision/owner-data"
    token_counter="$TEST_DIR/tool/dir-token-counter"; printf 0 > "$token_counter"
    xanmod_random_token() { local count; count=$(<"$token_counter"); ((count += 1)); printf '%s' "$count" > "$token_counter"; (( count == 1 )) && echo collision || echo unique; }
    ALLOCATED_DIR=""; ALLOCATED_DIR_BUILDING=false
    xanmod_allocate_temp_directory ALLOCATED_DIR ALLOCATED_DIR_BUILDING "$parent" alloc-dir 0700
    assert_eq "$parent/alloc-dir.unique" "$ALLOCATED_DIR" "directory allocator retries collision with new token"
    assert_file_eq keep "$collision/owner-data" "directory allocator does not delete collision path"
    command rm -rf "$ALLOCATED_DIR" "$collision"; ALLOCATED_DIR=""; ALLOCATED_DIR_BUILDING=false
)

(
    reset_tool_files
    parent="$TEST_DIR/tool/tmp"
    collision="$parent/alloc-file.collision.tmp"
    printf keep > "$collision"
    token_counter="$TEST_DIR/tool/file-token-counter"; printf 0 > "$token_counter"
    xanmod_random_token() { local count; count=$(<"$token_counter"); ((count += 1)); printf '%s' "$count" > "$token_counter"; (( count == 1 )) && echo collision || echo unique; }
    ALLOCATED_FILE=""
    xanmod_allocate_temp_file ALLOCATED_FILE "$parent" alloc-file .tmp 0600
    assert_eq "$parent/alloc-file.unique.tmp" "$ALLOCATED_FILE" "file allocator retries collision with new token"
    assert_file_eq keep "$collision" "file allocator does not delete collision path"
    command rm -f "$ALLOCATED_FILE" "$collision"; ALLOCATED_FILE=""
)

(
    reset_tool_files
    parent="$TEST_DIR/tool/tmp"
    token_counter="$TEST_DIR/tool/dir-partial-counter"; printf 0 > "$token_counter"
    xanmod_random_token() {
        local count; count=$(<"$token_counter"); ((count += 1)); printf '%s' "$count" > "$token_counter"
        case "$count" in 1) echo partial;; 2) echo owner;; *) echo unexpected;; esac
    }
    xanmod_write_allocation_proof() { printf '%s\n' "$2" > "$1"; return 1; }
    ALLOCATED_DIR=""; ALLOCATED_DIR_BUILDING=false
    rc=0; xanmod_allocate_temp_directory ALLOCATED_DIR ALLOCATED_DIR_BUILDING \
        "$parent" alloc-dir 0700 > "$TEST_DIR/dir-partial-clean.log" 2>&1 || rc=$?
    assert_eq 1 "$rc" "directory partial proof returns nonzero"
    assert_eq '' "$ALLOCATED_DIR" "directory partial proof does not publish final path"
    assert_eq 2 "$(<"$token_counter")" "directory partial proof does not retry with another token"
    [[ -z "$(find "$parent" -maxdepth 1 -name 'alloc-dir.*' -print -quit)" ]] || fail "directory partial proof left candidate"
    pass "directory partial proof cleans candidate and proof"
    assert_eq '' "$XANMOD_ALLOCATION_CANDIDATE" "directory partial proof clears pending candidate after successful cleanup"
)

(
    reset_tool_files
    parent="$TEST_DIR/tool/tmp"
    token_counter="$TEST_DIR/tool/dir-partial-residue-counter"; printf 0 > "$token_counter"
    xanmod_random_token() {
        local count; count=$(<"$token_counter"); ((count += 1)); printf '%s' "$count" > "$token_counter"
        case "$count" in 1) echo partial-residue;; 2) echo owner;; *) echo unexpected;; esac
    }
    xanmod_write_allocation_proof() { printf '%s\n' "$2" > "$1"; return 1; }
    rm() { local last=${!#}; [[ "$last" == */.xanmod-allocation-owner ]] && return 1; command rm "$@"; }
    ALLOCATED_DIR=""; ALLOCATED_DIR_BUILDING=false
    rc=0; xanmod_allocate_temp_directory ALLOCATED_DIR ALLOCATED_DIR_BUILDING \
        "$parent" alloc-dir 0700 > "$TEST_DIR/dir-partial-residue.log" 2>&1 || rc=$?
    assert_eq 1 "$rc" "directory partial proof cleanup failure returns nonzero"
    candidate="$parent/alloc-dir.partial-residue"
    proof="$candidate/.xanmod-allocation-owner"
    [[ -d "$candidate" && -f "$proof" ]] || fail "directory partial proof cleanup failure lost residue"
    pass "directory partial proof cleanup failure preserves owned residue"
    assert_eq residue "$XANMOD_ALLOCATION_STATE" "directory cleanup failure records residue state"
    assert_eq true "$XANMOD_ALLOCATION_PROOF_OWNED" "directory cleanup failure records proof ownership"
    assert_eq 2 "$(<"$token_counter")" "directory cleanup failure stops allocation retries"
    grep -Fq "$candidate" "$TEST_DIR/dir-partial-residue.log" || fail "directory cleanup failure omitted candidate path"
    grep -Fq "$proof" "$TEST_DIR/dir-partial-residue.log" || fail "directory cleanup failure omitted proof path"
    pass "directory cleanup failure reports candidate and proof paths"
    unset -f rm
    cleanup_xanmod_pending_allocation
    [[ ! -e "$candidate" && ! -L "$candidate" ]] || fail "directory residue retry left candidate"
    assert_eq '' "$XANMOD_ALLOCATION_CANDIDATE" "directory residue retry clears pending state"
)

(
    reset_tool_files
    parent="$TEST_DIR/tool/tmp"
    token_counter="$TEST_DIR/tool/file-partial-counter"; printf 0 > "$token_counter"
    xanmod_random_token() {
        local count; count=$(<"$token_counter"); ((count += 1)); printf '%s' "$count" > "$token_counter"
        case "$count" in 1) echo partial;; 2) echo owner;; *) echo unexpected;; esac
    }
    xanmod_write_allocation_proof() { printf '%s\n' "$2" > "$1"; return 1; }
    ALLOCATED_FILE=""
    rc=0; xanmod_allocate_temp_file ALLOCATED_FILE "$parent" alloc-file .tmp 0600 \
        > "$TEST_DIR/file-partial-clean.log" 2>&1 || rc=$?
    assert_eq 1 "$rc" "file partial proof returns nonzero"
    assert_eq '' "$ALLOCATED_FILE" "file partial proof does not publish final path"
    assert_eq 2 "$(<"$token_counter")" "file partial proof does not retry with another token"
    [[ -z "$(find "$parent" -maxdepth 1 \
        \( -name 'alloc-file.*' -o -name '*.xanmod-owner.*' \) -print -quit)" ]] || fail "file partial proof left candidate or proof"
    pass "file partial proof cleans candidate and sidecar"
)

(
    reset_tool_files
    parent="$TEST_DIR/tool/tmp"
    token_counter="$TEST_DIR/tool/file-partial-residue-counter"; printf 0 > "$token_counter"
    xanmod_random_token() {
        local count; count=$(<"$token_counter"); ((count += 1)); printf '%s' "$count" > "$token_counter"
        case "$count" in 1) echo partial-residue;; 2) echo owner;; *) echo unexpected;; esac
    }
    xanmod_write_allocation_proof() { printf '%s\n' "$2" > "$1"; return 1; }
    rm() { local last=${!#}; [[ "$last" == *.xanmod-owner.* ]] && return 1; command rm "$@"; }
    ALLOCATED_FILE=""
    rc=0; xanmod_allocate_temp_file ALLOCATED_FILE "$parent" alloc-file .tmp 0600 \
        > "$TEST_DIR/file-partial-residue.log" 2>&1 || rc=$?
    assert_eq 1 "$rc" "file partial proof cleanup failure returns nonzero"
    candidate="$parent/alloc-file.partial-residue.tmp"
    proof="$candidate.xanmod-owner.owner"
    [[ ! -e "$candidate" && -f "$proof" ]] || fail "file partial proof cleanup failure did not preserve expected proof residue"
    pass "file partial proof cleanup failure preserves owned sidecar residue"
    assert_eq residue "$XANMOD_ALLOCATION_STATE" "file cleanup failure records residue state"
    assert_eq true "$XANMOD_ALLOCATION_PROOF_OWNED" "file cleanup failure records proof ownership"
    assert_eq 2 "$(<"$token_counter")" "file cleanup failure stops allocation retries"
    grep -Fq "$proof" "$TEST_DIR/file-partial-residue.log" || fail "file cleanup failure omitted proof path"
    pass "file cleanup failure reports exact proof path"
    unset -f rm
    cleanup_xanmod_pending_allocation
    [[ ! -e "$proof" && ! -L "$proof" ]] || fail "file residue retry left proof"
    assert_eq '' "$XANMOD_ALLOCATION_CANDIDATE" "file residue retry clears pending state"
)

(
    reset_tool_files
    parent="$TEST_DIR/tool/tmp"
    token_counter="$TEST_DIR/tool/file-proof-collision-counter"; printf 0 > "$token_counter"
    xanmod_random_token() {
        local count; count=$(<"$token_counter"); ((count += 1)); printf '%s' "$count" > "$token_counter"
        case "$count" in 1) echo fresh;; 2) echo proof-collision;; *) echo unexpected;; esac
    }
    candidate="$parent/alloc-file.fresh.tmp"
    proof="$candidate.xanmod-owner.proof-collision"
    printf keep > "$proof"
    ALLOCATED_FILE=""
    rc=0; xanmod_allocate_temp_file ALLOCATED_FILE "$parent" alloc-file .tmp 0600         > "$TEST_DIR/file-proof-collision.log" 2>&1 || rc=$?
    assert_eq 1 "$rc" "preexisting proof sidecar collision returns nonzero"
    [[ ! -e "$candidate" && ! -L "$candidate" ]] || fail "proof sidecar collision left owned candidate"
    assert_file_eq keep "$proof" "preexisting proof sidecar collision preserves foreign proof"
    assert_eq 2 "$(<"$token_counter")" "proof sidecar collision does not retry as candidate collision"
    assert_eq '' "$XANMOD_ALLOCATION_CANDIDATE" "proof sidecar collision clears pending state after owned candidate cleanup"
    command rm -f "$proof"
)

(
    reset_tool_files
    parent="$TEST_DIR/tool/tmp"
    release_failed=true
    rm() {
        local last=${!#}
        if [[ "$release_failed" == true && "$last" == *.xanmod-owner.* ]]; then
            return 1
        fi
        command rm "$@"
    }
    rc=0; xanmod_allocate_temp_file XANMOD_STAGED_KEY "$parent" release-proof .tmp 0600 \
        > "$TEST_DIR/proof-release-fail.log" 2>&1 || rc=$?
    assert_eq 1 "$rc" "proof release failure returns nonzero"
    [[ -f "$XANMOD_STAGED_KEY" ]] || fail "proof release failure lost final temp path"
    proof=$(xanmod_allocation_proof_path file "$XANMOD_ALLOCATION_CANDIDATE" "$XANMOD_ALLOCATION_OWNER_TOKEN")
    [[ -f "$proof" ]] || fail "proof release failure lost proof"
    pass "proof release failure preserves final path and proof for retry"
    assert_eq active "$XANMOD_ALLOCATION_STATE" "proof release failure preserves active allocation state"
    assert_eq true "$XANMOD_ALLOCATION_PROOF_OWNED" "proof release failure preserves proof ownership"
    grep -Fq "$proof" "$TEST_DIR/proof-release-fail.log" || fail "proof release failure omitted proof path"
    pass "proof release failure reports exact proof path"
    release_failed=false
    cleanup_xanmod_transaction_state
    assert_eq '' "$XANMOD_ALLOCATION_CANDIDATE" "proof release cleanup clears pending candidate"
    assert_eq false "$XANMOD_ALLOCATION_PROOF_OWNED" "proof release cleanup clears proof ownership"
    assert_eq '' "$XANMOD_STAGED_KEY" "proof release cleanup clears final temp path"
    [[ ! -e "$proof" && ! -L "$proof" ]] || fail "proof release cleanup left proof"
    pass "proof release cleanup removes final path and proof"
)

cat > "$TEST_DIR/signal-child.sh" <<'SIGNAL_CHILD'
#!/usr/bin/env bash
set -euo pipefail
root="$1"
stage="$2"
tool="$3"
mkdir -p "$root/etc/keyrings" "$root/etc/sources" "$root/original" "$root/tmp"
printf 'VERSION_CODENAME=trixie\n' > "$root/os-release"
printf '%s\n' 'flags : lm cmov cx8 fpu fxsr mmx syscall sse2 cx16 lahf_lm popcnt sse4_1 sse4_2 ssse3 avx avx2 bmi1 bmi2 f16c fma abm movbe xsave' > "$root/cpuinfo"
printf old-key > "$root/original/key"
ln -s "$root/original/key" "$root/etc/keyrings/xanmod.gpg"
printf old-list > "$root/etc/sources/xanmod.list"
export XANMOD_TEST_MODE=1
export XANMOD_KEYRING_PATH="$root/etc/keyrings/xanmod.gpg"
export XANMOD_SOURCE_LIST_PATH="$root/etc/sources/xanmod.list"
export XANMOD_SOURCE_DEB822_PATH="$root/etc/sources/xanmod.sources"
export XANMOD_LOCK_PATH="$root/xanmod.lock"
export XANMOD_OS_RELEASE_PATH="$root/os-release"
export XANMOD_CPUINFO_PATH="$root/cpuinfo"
export XANMOD_BACKUP_STATE_DIR="$root/backups"
export TMPDIR="$root/tmp"
source "$tool"
gpg() {
    if [[ " $* " == *' --show-keys '* ]]; then
        [[ $(<"${!#}") == valid ]] || return 1
        printf '%s\n' pub::::::::: \
            fpr:::::::::D38D7D1DA1349567ADED882D86F7D09EE734E623: \
            'uid:::::::::XanMod Kernel <kernel@xanmod.org>:'
    else
        local output="" previous="" input=${!#}
        for argument in "$@"; do [[ "$previous" == --output ]] && output="$argument"; previous="$argument"; done
        cp "$input" "$output"
    fi
}
curl() {
    local output="" previous=""
    for argument in "$@"; do [[ "$previous" == -o ]] && output="$argument"; previous="$argument"; done
    printf valid > "$output"
}
dpkg() { echo amd64; }
uname() { [[ ${1:-} == -m ]] && echo x86_64 || echo 6.1.0-amd64; }
get_installed_xanmod_packages() { :; }
package_is_installed() { return 1; }
apt-cache() { echo 'Candidate: 1'; }
block_for_signal() {
    touch "$root/ready"
    while :; do sleep 1; done
}
apt-get() {
    local source_file="" argument
    for argument in "$@"; do case "$argument" in Dir::Etc::sourcelist=*) source_file=${argument#*=};; esac; done
    if [[ -n "$source_file" ]]; then
        [[ "$stage" == probe ]] && block_for_signal
        return 0
    fi
    if [[ ${1:-} == install && "$stage" == install ]]; then block_for_signal; fi
    return 0
}
if [[ "$stage" == commit ]]; then xanmod_after_formal_commit_hook() { block_for_signal; }; fi
if [[ "$stage" == runtime-build ]]; then
    eval "$(declare -f capture_xanmod_snapshot_item | sed '1s/capture_xanmod_snapshot_item/original_capture_xanmod_snapshot_item/')"
    capture_calls=0
    capture_xanmod_snapshot_item() {
        ((capture_calls += 1))
        if (( capture_calls == 1 )); then block_for_signal; fi
        original_capture_xanmod_snapshot_item "$@"
    }
fi
resolve_xanmod_plan
take_xanmod_lock
install_xanmod
SIGNAL_CHILD
chmod 0755 "$TEST_DIR/signal-child.sh"

run_signal_case() {
    local signal_name="$1" expected_status="$2" stage="$3"
    local root="$TEST_DIR/signal-${signal_name}-${stage}"
    local pid rc=0

    mkdir -p "$root"
    env --default-signal=HUP,INT,TERM \
        bash "$TEST_DIR/signal-child.sh" "$root" "$stage" "$TOOL" > "$root/output.log" 2>&1 &
    pid=$!
    for _ in $(seq 1 200); do
        [[ -e "$root/ready" ]] && break
        sleep 0.05
    done
    [[ -e "$root/ready" ]] || { cat "$root/output.log"; kill "$pid" 2>/dev/null || true; fail "$signal_name/$stage did not reach block"; }
    kill "-$signal_name" "$pid"
    wait "$pid" || rc=$?
    assert_eq "$expected_status" "$rc" "$signal_name during $stage returns conventional status"
    [[ -L "$root/etc/keyrings/xanmod.gpg" ]] || fail "$signal_name/$stage did not restore key symlink"
    assert_eq "$root/original/key" "$(readlink "$root/etc/keyrings/xanmod.gpg")" "$signal_name/$stage restores key target"
    assert_file_eq old-list "$root/etc/sources/xanmod.list" "$signal_name/$stage restores list"
    [[ ! -e "$root/etc/sources/xanmod.sources" && ! -L "$root/etc/sources/xanmod.sources" ]] || fail "$signal_name/$stage kept Deb822 source"
    pass "$signal_name during $stage restores missing Deb822 source"
    flock -n "$root/xanmod.lock" -c true || fail "$signal_name/$stage did not release lock"
    pass "$signal_name during $stage releases lock"
    [[ -z "$(find "$root" \( -name '.xanmod-stage.*' -o -name 'xanmod-runtime-snapshot.*' -o -name 'xanmod-apt-lists.*' \) -print -quit)" ]] || fail "$signal_name/$stage left temporary files"
    pass "$signal_name during $stage leaves no stage, snapshot, or APT-list residue"
    if [[ "$stage" == install ]]; then
        grep -Fq '不会自动卸载任何包' "$root/output.log" || fail "$signal_name install signal omitted partial warning"
        pass "$signal_name during apt install prints no-auto-remove warning"
    else
        if grep -Fq '不会自动卸载任何包' "$root/output.log"; then fail "$signal_name commit signal printed false partial warning"; fi
        pass "$signal_name before apt install does not print partial warning"
    fi
}

run_signal_case HUP 129 commit
run_signal_case INT 130 commit
run_signal_case TERM 143 commit
run_signal_case TERM 143 install
run_signal_case TERM 143 probe
run_signal_case HUP 129 runtime-build
run_signal_case INT 130 runtime-build
run_signal_case TERM 143 runtime-build

cat > "$TEST_DIR/allocation-window-child.sh" <<'ALLOCATION_WINDOW_CHILD'
#!/usr/bin/env bash
set -euo pipefail
root="$1"
kind="$2"
tool="$3"
mkdir -p "$root/tmp"
printf key-before > "$root/key.gpg"
printf list-before > "$root/release.list"
printf source-before > "$root/release.sources"
export XANMOD_TEST_MODE=1
export XANMOD_KEYRING_PATH="$root/key.gpg"
export XANMOD_SOURCE_LIST_PATH="$root/release.list"
export XANMOD_SOURCE_DEB822_PATH="$root/release.sources"
export XANMOD_LOCK_PATH="$root/xanmod.lock"
export XANMOD_OS_RELEASE_PATH="$root/os-release"
export XANMOD_CPUINFO_PATH="$root/cpuinfo"
export TMPDIR="$root/tmp"
source "$tool"
block_for_signal() {
    touch "$root/ready"
    while :; do sleep 1; done
}
xanmod_after_allocation_attempt_hook() {
    local attempted_kind="$1"
    local create_status="$3"

    if [[ "$attempted_kind" == "$kind" && "$create_status" == 0 ]]; then
        block_for_signal
    fi
}
install_xanmod_transaction_guards
take_xanmod_lock
if [[ "$kind" == directory ]]; then
    xanmod_allocate_temp_directory XANMOD_RUNTIME_SNAPSHOT_DIR \
        XANMOD_RUNTIME_SNAPSHOT_BUILDING "$root/tmp" allocation-directory 0700
else
    xanmod_allocate_temp_file XANMOD_STAGED_KEY "$root/tmp" allocation-file .tmp 0600
fi
ALLOCATION_WINDOW_CHILD
chmod 0755 "$TEST_DIR/allocation-window-child.sh"

run_allocation_window_signal_case() {
    local signal_name="$1" expected_status="$2" kind="$3"
    local root="$TEST_DIR/allocation-$kind-$signal_name"
    local pid rc=0

    mkdir -p "$root"
    setsid env --default-signal=HUP,INT,TERM \
        bash "$TEST_DIR/allocation-window-child.sh" "$root" "$kind" "$TOOL" > "$root/output.log" 2>&1 &
    pid=$!
    for _ in $(seq 1 200); do
        [[ -e "$root/ready" ]] && break
        sleep 0.05
    done
    [[ -e "$root/ready" ]] || { cat "$root/output.log"; kill "$pid" 2>/dev/null || true; fail "$signal_name/$kind allocation did not block"; }
    kill "-$signal_name" -- "-$pid"
    wait "$pid" || rc=$?
    assert_eq "$expected_status" "$rc" "$signal_name during $kind allocation returns conventional status"
    assert_file_eq key-before "$root/key.gpg" "$signal_name/$kind allocation leaves key unchanged"
    assert_file_eq list-before "$root/release.list" "$signal_name/$kind allocation leaves list unchanged"
    assert_file_eq source-before "$root/release.sources" "$signal_name/$kind allocation leaves source unchanged"
    [[ -z "$(find "$root" \( -name 'allocation-directory.*' -o -name 'allocation-file.*' \) -print -quit)" ]] || fail "$signal_name/$kind allocation left resource"
    pass "$signal_name during $kind allocation leaves no resource"
    flock -n "$root/xanmod.lock" -c true || fail "$signal_name/$kind allocation did not release lock"
    pass "$signal_name during $kind allocation releases lock"
}

for allocation_signal in HUP INT TERM; do
    case "$allocation_signal" in HUP) allocation_status=129;; INT) allocation_status=130;; TERM) allocation_status=143;; esac
    run_allocation_window_signal_case "$allocation_signal" "$allocation_status" directory
    run_allocation_window_signal_case "$allocation_signal" "$allocation_status" file
 done

cat > "$TEST_DIR/allocation-critical-signal-child.sh" <<'ALLOCATION_CRITICAL_SIGNAL_CHILD'
#!/usr/bin/env bash
set -euo pipefail
root="$1"
tool="$2"
mkdir -p "$root/tmp"
printf key-before > "$root/key.gpg"
printf list-before > "$root/release.list"
printf source-before > "$root/release.sources"
export XANMOD_TEST_MODE=1
export XANMOD_KEYRING_PATH="$root/key.gpg"
export XANMOD_SOURCE_LIST_PATH="$root/release.list"
export XANMOD_SOURCE_DEB822_PATH="$root/release.sources"
export XANMOD_LOCK_PATH="$root/xanmod.lock"
export XANMOD_OS_RELEASE_PATH="$root/os-release"
export XANMOD_CPUINFO_PATH="$root/cpuinfo"
export TMPDIR="$root/tmp"
source "$tool"
eval "$(declare -f xanmod_write_allocation_proof | sed '1s/xanmod_write_allocation_proof/original_xanmod_write_allocation_proof/')"
xanmod_write_allocation_proof() {
    original_xanmod_write_allocation_proof "$@"
    touch "$root/ready"
    sleep 1
}
install_xanmod_transaction_guards
take_xanmod_lock
xanmod_allocate_temp_directory XANMOD_RUNTIME_SNAPSHOT_DIR \
    XANMOD_RUNTIME_SNAPSHOT_BUILDING "$root/tmp" allocation-critical 0700
ALLOCATION_CRITICAL_SIGNAL_CHILD
chmod 0755 "$TEST_DIR/allocation-critical-signal-child.sh"

run_allocation_critical_signal_case() {
    local signal_name="$1" expected_status="$2"
    local root="$TEST_DIR/allocation-critical-$signal_name"
    local pid rc=0

    mkdir -p "$root"
    setsid env --default-signal=HUP,INT,TERM \
        bash "$TEST_DIR/allocation-critical-signal-child.sh" \
        "$root" "$TOOL" > "$root/output.log" 2>&1 &
    pid=$!
    for _ in $(seq 1 200); do
        [[ -e "$root/ready" ]] && break
        sleep 0.05
    done
    [[ -e "$root/ready" ]] || { cat "$root/output.log"; kill "$pid" 2>/dev/null || true; fail "$signal_name allocation critical section did not block"; }
    kill "-$signal_name" -- "-$pid"
    wait "$pid" || rc=$?
    assert_eq "$expected_status" "$rc" "$signal_name during allocation proof write returns conventional status"
    assert_file_eq key-before "$root/key.gpg" "$signal_name allocation proof write leaves key unchanged"
    assert_file_eq list-before "$root/release.list" "$signal_name allocation proof write leaves list unchanged"
    assert_file_eq source-before "$root/release.sources" "$signal_name allocation proof write leaves source unchanged"
    [[ -z "$(find "$root" \( -name 'allocation-critical.*' -o -name '.xanmod-allocation-owner' \) -print -quit)" ]] || fail "$signal_name allocation proof write left candidate or proof"
    pass "$signal_name allocation proof write defers signal until owned resource can be cleaned"
    flock -n "$root/xanmod.lock" -c true || fail "$signal_name allocation proof write did not release lock"
    pass "$signal_name allocation proof write releases lock"
}

run_allocation_critical_signal_case HUP 129
run_allocation_critical_signal_case INT 130
run_allocation_critical_signal_case TERM 143

cat > "$TEST_DIR/allocation-collision-signal-child.sh" <<'ALLOCATION_COLLISION_SIGNAL_CHILD'
#!/usr/bin/env bash
set -euo pipefail
root="$1"
kind="$2"
tool="$3"
mkdir -p "$root/tmp"
printf key-before > "$root/key.gpg"
printf list-before > "$root/release.list"
printf source-before > "$root/release.sources"
export XANMOD_TEST_MODE=1
export XANMOD_KEYRING_PATH="$root/key.gpg"
export XANMOD_SOURCE_LIST_PATH="$root/release.list"
export XANMOD_SOURCE_DEB822_PATH="$root/release.sources"
export XANMOD_LOCK_PATH="$root/xanmod.lock"
export XANMOD_OS_RELEASE_PATH="$root/os-release"
export XANMOD_CPUINFO_PATH="$root/cpuinfo"
export TMPDIR="$root/tmp"
source "$tool"
case "$kind" in
    directory)
        collision_path="$root/tmp/allocation-directory.collision"
        mkdir -m 0700 "$collision_path"
        printf owner-data > "$collision_path/owner-data"
        ;;
    file)
        collision_path="$root/tmp/allocation-file.collision.tmp"
        printf keep > "$collision_path"
        ;;
    file-symlink)
        collision_path="$root/tmp/allocation-file.collision.tmp"
        printf link-target > "$root/link-target"
        ln -s "$root/link-target" "$collision_path"
        ;;
    *) exit 2 ;;
esac
token_call=0
xanmod_random_token() {
    ((token_call += 1))
    case "$token_call" in
        1) printf 'collision\n' ;;
        2) printf 'allocation-owner\n' ;;
        *) printf 'unexpected-%s\n' "$token_call" ;;
    esac
}
block_for_signal() {
    touch "$root/ready"
    while :; do sleep 1; done
}
xanmod_after_allocation_attempt_hook() {
    local attempted_path="$2"
    local create_status="$3"

    if [[ "$attempted_path" == "$collision_path" && "$create_status" != 0 ]]; then
        block_for_signal
    fi
}
install_xanmod_transaction_guards
take_xanmod_lock
if [[ "$kind" == directory ]]; then
    xanmod_allocate_temp_directory XANMOD_RUNTIME_SNAPSHOT_DIR \
        XANMOD_RUNTIME_SNAPSHOT_BUILDING "$root/tmp" allocation-directory 0700
else
    xanmod_allocate_temp_file XANMOD_STAGED_KEY "$root/tmp" allocation-file .tmp 0600
fi
ALLOCATION_COLLISION_SIGNAL_CHILD
chmod 0755 "$TEST_DIR/allocation-collision-signal-child.sh"

run_allocation_collision_signal_case() {
    local signal_name="$1" expected_status="$2" kind="$3"
    local root="$TEST_DIR/allocation-collision-$kind-$signal_name"
    local collision=""
    local pid rc=0

    mkdir -p "$root"
    setsid env --default-signal=HUP,INT,TERM \
        bash "$TEST_DIR/allocation-collision-signal-child.sh" \
        "$root" "$kind" "$TOOL" > "$root/output.log" 2>&1 &
    pid=$!
    for _ in $(seq 1 200); do
        [[ -e "$root/ready" ]] && break
        sleep 0.05
    done
    [[ -e "$root/ready" ]] || { cat "$root/output.log"; kill "$pid" 2>/dev/null || true; fail "$signal_name/$kind collision did not block"; }
    kill "-$signal_name" -- "-$pid"
    wait "$pid" || rc=$?
    assert_eq "$expected_status" "$rc" "$signal_name during $kind collision returns conventional status"
    case "$kind" in
        directory)
            collision="$root/tmp/allocation-directory.collision"
            [[ -d "$collision" && ! -L "$collision" ]] || fail "$signal_name directory collision was deleted"
            assert_file_eq owner-data "$collision/owner-data" "$signal_name directory collision preserves owner data"
            ;;
        file)
            collision="$root/tmp/allocation-file.collision.tmp"
            assert_file_eq keep "$collision" "$signal_name file collision preserves content"
            ;;
        file-symlink)
            collision="$root/tmp/allocation-file.collision.tmp"
            [[ -L "$collision" ]] || fail "$signal_name file symlink collision was deleted"
            assert_eq "$root/link-target" "$(readlink "$collision")" "$signal_name file symlink collision preserves target"
            assert_file_eq link-target "$root/link-target" "$signal_name file symlink collision preserves target content"
            ;;
    esac
    [[ -z "$(find "$root/tmp" -mindepth 1 -maxdepth 1 \
        \( -name 'allocation-directory.*' -o -name 'allocation-file.*' \) \
        ! -path "$collision" -print -quit)" ]] || fail "$signal_name/$kind collision left owned allocation residue"
    pass "$signal_name during $kind collision creates no owned allocation residue"
    assert_file_eq key-before "$root/key.gpg" "$signal_name/$kind collision leaves key unchanged"
    assert_file_eq list-before "$root/release.list" "$signal_name/$kind collision leaves list unchanged"
    assert_file_eq source-before "$root/release.sources" "$signal_name/$kind collision leaves source unchanged"
    flock -n "$root/xanmod.lock" -c true || fail "$signal_name/$kind collision did not release lock"
    pass "$signal_name during $kind collision releases lock"
}

for allocation_signal in HUP INT TERM; do
    case "$allocation_signal" in HUP) allocation_status=129;; INT) allocation_status=130;; TERM) allocation_status=143;; esac
    run_allocation_collision_signal_case "$allocation_signal" "$allocation_status" directory
    run_allocation_collision_signal_case "$allocation_signal" "$allocation_status" file
    run_allocation_collision_signal_case "$allocation_signal" "$allocation_status" file-symlink
done

(
    trap - EXIT
    reset_tool_files
    printf committed-key > "$XANMOD_KEYRING"
    printf committed-list > "$XANMOD_SOURCE_LIST"
    printf committed-source > "$XANMOD_SOURCE_DEB822"
    install_xanmod_transaction_guards
    create_xanmod_runtime_snapshot
    snapshot="$XANMOD_RUNTIME_SNAPSHOT_DIR"
    XANMOD_CONFIG_MODIFIED=false
    rm() { local last=${!#}; [[ "$last" == "$snapshot" ]] && return 1; command rm "$@"; }
    rc=0; complete_xanmod_install_transaction > "$TEST_DIR/complete-snapshot-delete-fail.log" 2>&1 || rc=$?
    assert_eq 1 "$rc" "complete runtime snapshot deletion failure returns nonzero"
    assert_eq true "$XANMOD_GUARD_ACTIVE" "complete deletion failure keeps transaction guards active"
    assert_eq true "$XANMOD_TRANSACTION_ACTIVE" "complete deletion failure preserves runtime snapshot state"
    assert_eq "$snapshot" "$XANMOD_RUNTIME_SNAPSHOT_DIR" "complete deletion failure preserves runtime snapshot path"
    grep -Fq "$snapshot" "$TEST_DIR/complete-snapshot-delete-fail.log" || fail "complete deletion failure omitted snapshot path"
    pass "complete deletion failure reports exact runtime snapshot path"
    unset -f rm
    complete_xanmod_install_transaction
    assert_eq false "$XANMOD_GUARD_ACTIVE" "complete deletion retry clears transaction guards"
    assert_eq false "$XANMOD_TRANSACTION_ACTIVE" "complete deletion retry clears runtime snapshot state"
    [[ ! -e "$snapshot" ]] || fail "complete deletion retry left runtime snapshot"
    pass "complete deletion retry removes runtime snapshot"
)

cat > "$TEST_DIR/complete-finalization-signal-child.sh" <<'COMPLETE_FINALIZATION_SIGNAL_CHILD'
#!/usr/bin/env bash
set -euo pipefail
root="$1"
tool="$2"
mkdir -p "$root/tmp"
printf old-key > "$root/key.gpg"
printf old-list > "$root/release.list"
printf old-source > "$root/release.sources"
export XANMOD_TEST_MODE=1
export XANMOD_KEYRING_PATH="$root/key.gpg"
export XANMOD_SOURCE_LIST_PATH="$root/release.list"
export XANMOD_SOURCE_DEB822_PATH="$root/release.sources"
export XANMOD_LOCK_PATH="$root/xanmod.lock"
export XANMOD_OS_RELEASE_PATH="$root/os-release"
export XANMOD_CPUINFO_PATH="$root/cpuinfo"
export TMPDIR="$root/tmp"
source "$tool"
take_xanmod_lock
install_xanmod_transaction_guards
create_xanmod_runtime_snapshot
snapshot="$XANMOD_RUNTIME_SNAPSHOT_DIR"
xanmod_allocate_temp_file XANMOD_STAGED_KEY "$root/tmp" final-stage .tmp 0600
printf stage > "$XANMOD_STAGED_KEY"
xanmod_allocate_temp_directory XANMOD_ACTIVE_APT_LISTS_DIR \
    XANMOD_ACTIVE_APT_LISTS_BUILDING "$root/tmp" final-lists 0755
XANMOD_ACTIVE_APT_LISTS_BUILDING=false
printf new-key > "$XANMOD_KEYRING"
printf new-list > "$XANMOD_SOURCE_LIST"
printf new-source > "$XANMOD_SOURCE_DEB822"
XANMOD_CONFIG_MODIFIED=true
eval "$(declare -f remove_xanmod_temp_directory | sed '1s/remove_xanmod_temp_directory/original_remove_xanmod_temp_directory/')"
remove_xanmod_temp_directory() {
    if [[ "$1" == "$snapshot" && ! -e "$root/discard-started" ]]; then
        touch "$root/discard-started" "$root/ready"
        while :; do sleep 1; done
    fi
    original_remove_xanmod_temp_directory "$@"
}
complete_xanmod_install_transaction
COMPLETE_FINALIZATION_SIGNAL_CHILD
chmod 0755 "$TEST_DIR/complete-finalization-signal-child.sh"

run_complete_finalization_signal_case() {
    local signal_name="$1" expected_status="$2"
    local root="$TEST_DIR/complete-finalization-$signal_name"
    local pid rc=0

    mkdir -p "$root"
    setsid env --default-signal=HUP,INT,TERM \
        bash "$TEST_DIR/complete-finalization-signal-child.sh" \
        "$root" "$TOOL" > "$root/output.log" 2>&1 &
    pid=$!
    for _ in $(seq 1 200); do
        [[ -e "$root/ready" ]] && break
        sleep 0.05
    done
    [[ -e "$root/ready" ]] || { cat "$root/output.log"; kill "$pid" 2>/dev/null || true; fail "$signal_name complete finalization did not block"; }
    kill "-$signal_name" -- "-$pid"
    wait "$pid" || rc=$?
    assert_eq "$expected_status" "$rc" "$signal_name during complete finalization returns conventional status"
    assert_file_eq new-key "$root/key.gpg" "$signal_name complete finalization keeps committed key"
    assert_file_eq new-list "$root/release.list" "$signal_name complete finalization keeps committed list"
    assert_file_eq new-source "$root/release.sources" "$signal_name complete finalization keeps committed source"
    [[ -z "$(find "$root" \( -name 'xanmod-runtime-snapshot.*' -o -name 'final-stage.*' \
        -o -name 'final-lists.*' -o -name '.xanmod-allocation-owner' \
        -o -name '*.xanmod-owner.*' \) -print -quit)" ]] || fail "$signal_name complete finalization left transaction residue"
    pass "$signal_name complete finalization removes runtime snapshot, stage, APT lists, and proof"
    flock -n "$root/xanmod.lock" -c true || fail "$signal_name complete finalization did not release lock"
    pass "$signal_name complete finalization releases lock"
}

run_complete_finalization_signal_case HUP 129
run_complete_finalization_signal_case INT 130
run_complete_finalization_signal_case TERM 143

cat > "$TEST_DIR/exit-zero-child.sh" <<'EXIT_ZERO_CHILD'
#!/usr/bin/env bash
set -euo pipefail
root="$1"
tool="$2"
mkdir -p "$root/etc/keyrings" "$root/etc/sources" "$root/tmp"
printf key-before > "$root/etc/keyrings/xanmod.gpg"
printf list-before > "$root/etc/sources/xanmod.list"
printf source-before > "$root/etc/sources/xanmod.sources"
export XANMOD_TEST_MODE=1
export XANMOD_KEYRING_PATH="$root/etc/keyrings/xanmod.gpg"
export XANMOD_SOURCE_LIST_PATH="$root/etc/sources/xanmod.list"
export XANMOD_SOURCE_DEB822_PATH="$root/etc/sources/xanmod.sources"
export XANMOD_LOCK_PATH="$root/xanmod.lock"
export XANMOD_OS_RELEASE_PATH="$root/os-release"
export XANMOD_CPUINFO_PATH="$root/cpuinfo"
export TMPDIR="$root/tmp"
source "$tool"
install_xanmod_transaction_guards
create_xanmod_runtime_snapshot
exit 0
EXIT_ZERO_CHILD
chmod 0755 "$TEST_DIR/exit-zero-child.sh"
(
    root="$TEST_DIR/exit-zero"
    mkdir -p "$root"
    rc=0
    bash "$TEST_DIR/exit-zero-child.sh" "$root" "$TOOL" > "$root/output.log" 2>&1 || rc=$?
    assert_eq 1 "$rc" "active transaction exit 0 becomes failure"
    assert_file_eq key-before "$root/etc/keyrings/xanmod.gpg" "exit 0 leaves key unchanged"
    assert_file_eq list-before "$root/etc/sources/xanmod.list" "exit 0 leaves list unchanged"
    assert_file_eq source-before "$root/etc/sources/xanmod.sources" "exit 0 leaves source unchanged"
    [[ -z "$(find "$root" -name 'xanmod-runtime-snapshot.*' -print -quit)" ]] || fail "exit 0 left runtime snapshot"
    pass "exit 0 cleans runtime snapshot"
    grep -Fq 'XanMod 事务异常退出' "$root/output.log" || fail "exit 0 omitted abnormal transaction message"
    pass "exit 0 reports abnormal active transaction"
)

cat > "$TEST_DIR/backup-build-signal-child.sh" <<'BACKUP_BUILD_CHILD'
#!/usr/bin/env bash
set -euo pipefail
root="$1"
module="$2"
mkdir -p "$root/tmp"
printf key-before > "$root/key.gpg"
printf list-before > "$root/release.list"
printf source-before > "$root/release.sources"
printf backup-key > "$root/key.gpg.previous-backup"; chmod 0600 "$root/key.gpg.previous-backup"
printf backup-list > "$root/release.list.previous-backup"; chmod 0600 "$root/release.list.previous-backup"
printf backup-source > "$root/release.sources.previous-backup"; chmod 0600 "$root/release.sources.previous-backup"
printf 'VERSION_CODENAME=trixie\n' > "$root/os-release"
printf '%s\n' 'flags : lm cmov cx8 fpu fxsr mmx syscall sse2 cx16 lahf_lm popcnt sse4_1 sse4_2 ssse3' > "$root/cpuinfo"
export XANMOD_TEST_MODE=1
export XANMOD_KEYRING_PATH="$root/key.gpg"
export XANMOD_SOURCE_LIST_PATH="$root/release.list"
export XANMOD_SOURCE_DEB822_PATH="$root/release.sources"
export XANMOD_LOCK_PATH="$root/xanmod.lock"
export XANMOD_OS_RELEASE_PATH="$root/os-release"
export XANMOD_CPUINFO_PATH="$root/cpuinfo"
export XANMOD_BACKUP_STATE_DIR="$root/backups"
export TMPDIR="$root/tmp"
source "$module"
dpkg() { echo amd64; }
uname() { [[ ${1:-} == -m ]] && echo x86_64 || echo 6.1.0-amd64; }
get_installed_xanmod_packages() { :; }
package_is_installed() { return 1; }
block_for_signal() {
    touch "$root/ready"
    while :; do sleep 1; done
}
eval "$(declare -f capture_xanmod_snapshot_item | sed '1s/capture_xanmod_snapshot_item/original_capture_xanmod_snapshot_item/')"
capture_calls=0
capture_xanmod_snapshot_item() {
    ((capture_calls += 1))
    if (( capture_calls == 1 )); then block_for_signal; fi
    original_capture_xanmod_snapshot_item "$@"
}
resolve_xanmod_plan
take_xanmod_lock
install_xanmod
BACKUP_BUILD_CHILD
chmod 0755 "$TEST_DIR/backup-build-signal-child.sh"

run_backup_build_signal_case() {
    local signal_name="$1" expected_status="$2"
    local root="$TEST_DIR/backup-build-$signal_name"
    local pid rc=0

    mkdir -p "$root"
    env --default-signal=HUP,INT,TERM \
        bash "$TEST_DIR/backup-build-signal-child.sh" "$root" "$MODULE" > "$root/output.log" 2>&1 &
    pid=$!
    for _ in $(seq 1 200); do
        [[ -e "$root/ready" ]] && break
        sleep 0.05
    done
    [[ -e "$root/ready" ]] || { cat "$root/output.log"; kill "$pid" 2>/dev/null || true; fail "$signal_name backup build did not block"; }
    kill "-$signal_name" "$pid"
    wait "$pid" || rc=$?
    assert_eq "$expected_status" "$rc" "$signal_name during backup snapshot build returns conventional status"
    assert_file_eq key-before "$root/key.gpg" "$signal_name backup build leaves key unchanged"
    assert_file_eq list-before "$root/release.list" "$signal_name backup build leaves list unchanged"
    assert_file_eq source-before "$root/release.sources" "$signal_name backup build leaves source unchanged"
    assert_file_eq backup-key "$root/key.gpg.previous-backup" "$signal_name backup build preserves key backup"
    assert_file_eq backup-list "$root/release.list.previous-backup" "$signal_name backup build preserves list backup"
    assert_file_eq backup-source "$root/release.sources.previous-backup" "$signal_name backup build preserves source backup"
    [[ ! -e "$root/backups" && ! -L "$root/backups" ]] || fail "$signal_name backup build left new backup directory"
    pass "$signal_name backup build removes newly created empty backup directory"
    [[ -z "$(find "$root" \( -name 'xanmod-backup-group.*' -o -name '.xanmod-backup-stage.*' \) -print -quit)" ]] || fail "$signal_name backup build left snapshot or stage"
    pass "$signal_name backup build leaves no backup snapshot or stage"
    flock -n "$root/xanmod.lock" -c true || fail "$signal_name backup build did not release lock"
    pass "$signal_name backup build releases lock"
}

run_backup_build_signal_case HUP 129
run_backup_build_signal_case INT 130
run_backup_build_signal_case TERM 143

cat > "$TEST_DIR/backup-dir-window-child.sh" <<'BACKUP_DIR_WINDOW_CHILD'
#!/usr/bin/env bash
set -euo pipefail
root="$1"
module="$2"
mkdir -p "$root/tmp"
printf key-before > "$root/key.gpg"
printf list-before > "$root/release.list"
printf source-before > "$root/release.sources"
printf backup-key > "$root/key.gpg.previous-backup"; chmod 0600 "$root/key.gpg.previous-backup"
printf backup-list > "$root/release.list.previous-backup"; chmod 0600 "$root/release.list.previous-backup"
printf backup-source > "$root/release.sources.previous-backup"; chmod 0600 "$root/release.sources.previous-backup"
export XANMOD_TEST_MODE=1
export XANMOD_KEYRING_PATH="$root/key.gpg"
export XANMOD_SOURCE_LIST_PATH="$root/release.list"
export XANMOD_SOURCE_DEB822_PATH="$root/release.sources"
export XANMOD_LOCK_PATH="$root/xanmod.lock"
export XANMOD_OS_RELEASE_PATH="$root/os-release"
export XANMOD_CPUINFO_PATH="$root/cpuinfo"
export XANMOD_BACKUP_STATE_DIR="$root/backups"
export TMPDIR="$root/tmp"
source "$module"
block_for_signal() {
    touch "$root/ready"
    while :; do sleep 1; done
}
xanmod_after_allocation_attempt_hook() {
    local attempted_kind="$1"
    local create_status="$3"

    if [[ "$attempted_kind" == backup-state && "$create_status" == 0 ]]; then
        block_for_signal
    fi
}
install_xanmod_transaction_guards
take_xanmod_lock
ensure_xanmod_backup_state_dir
BACKUP_DIR_WINDOW_CHILD
chmod 0755 "$TEST_DIR/backup-dir-window-child.sh"

run_backup_dir_window_signal_case() {
    local signal_name="$1" expected_status="$2"
    local root="$TEST_DIR/backup-dir-window-$signal_name"
    local pid rc=0

    mkdir -p "$root"
    setsid env --default-signal=HUP,INT,TERM \
        bash "$TEST_DIR/backup-dir-window-child.sh" "$root" "$MODULE" > "$root/output.log" 2>&1 &
    pid=$!
    for _ in $(seq 1 200); do
        [[ -e "$root/ready" ]] && break
        sleep 0.05
    done
    [[ -e "$root/ready" ]] || { cat "$root/output.log"; kill "$pid" 2>/dev/null || true; fail "$signal_name backup dir allocation did not block"; }
    kill "-$signal_name" -- "-$pid"
    wait "$pid" || rc=$?
    assert_eq "$expected_status" "$rc" "$signal_name during backup directory creation returns conventional status"
    [[ ! -e "$root/backups" && ! -L "$root/backups" ]] || fail "$signal_name backup directory creation left empty directory"
    pass "$signal_name backup directory creation removes owned empty directory"
    assert_file_eq key-before "$root/key.gpg" "$signal_name backup directory creation leaves key unchanged"
    assert_file_eq list-before "$root/release.list" "$signal_name backup directory creation leaves list unchanged"
    assert_file_eq source-before "$root/release.sources" "$signal_name backup directory creation leaves source unchanged"
    assert_file_eq backup-key "$root/key.gpg.previous-backup" "$signal_name backup directory creation preserves key backup"
    assert_file_eq backup-list "$root/release.list.previous-backup" "$signal_name backup directory creation preserves list backup"
    assert_file_eq backup-source "$root/release.sources.previous-backup" "$signal_name backup directory creation preserves source backup"
    flock -n "$root/xanmod.lock" -c true || fail "$signal_name backup directory creation did not release lock"
    pass "$signal_name backup directory creation releases lock"
}

run_backup_dir_window_signal_case HUP 129
run_backup_dir_window_signal_case INT 130
run_backup_dir_window_signal_case TERM 143

cat > "$TEST_DIR/backup-dir-race-signal-child.sh" <<'BACKUP_DIR_RACE_SIGNAL_CHILD'
#!/usr/bin/env bash
set -euo pipefail
root="$1"
module="$2"
mkdir -p "$root/tmp"
printf key-before > "$root/key.gpg"
printf list-before > "$root/release.list"
printf source-before > "$root/release.sources"
export XANMOD_TEST_MODE=1
export XANMOD_KEYRING_PATH="$root/key.gpg"
export XANMOD_SOURCE_LIST_PATH="$root/release.list"
export XANMOD_SOURCE_DEB822_PATH="$root/release.sources"
export XANMOD_LOCK_PATH="$root/xanmod.lock"
export XANMOD_OS_RELEASE_PATH="$root/os-release"
export XANMOD_CPUINFO_PATH="$root/cpuinfo"
export XANMOD_BACKUP_STATE_DIR="$root/backups"
export TMPDIR="$root/tmp"
source "$module"
block_for_signal() {
    touch "$root/ready"
    while :; do sleep 1; done
}
xanmod_create_backup_state_dir() {
    command mkdir -m 0700 -- "$XANMOD_BACKUP_STATE_DIR"
    printf owner-data > "$XANMOD_BACKUP_STATE_DIR/owner-data"
    return 1
}
xanmod_after_allocation_attempt_hook() {
    local attempted_kind="$1"
    local create_status="$3"

    if [[ "$attempted_kind" == backup-state && "$create_status" != 0 ]]; then
        block_for_signal
    fi
}
install_xanmod_transaction_guards
take_xanmod_lock
ensure_xanmod_backup_state_dir
BACKUP_DIR_RACE_SIGNAL_CHILD
chmod 0755 "$TEST_DIR/backup-dir-race-signal-child.sh"

run_backup_dir_race_signal_case() {
    local signal_name="$1" expected_status="$2"
    local root="$TEST_DIR/backup-dir-race-$signal_name"
    local pid rc=0

    mkdir -p "$root"
    setsid env --default-signal=HUP,INT,TERM \
        bash "$TEST_DIR/backup-dir-race-signal-child.sh" \
        "$root" "$MODULE" > "$root/output.log" 2>&1 &
    pid=$!
    for _ in $(seq 1 200); do
        [[ -e "$root/ready" ]] && break
        sleep 0.05
    done
    [[ -e "$root/ready" ]] || { cat "$root/output.log"; kill "$pid" 2>/dev/null || true; fail "$signal_name backup directory race did not block"; }
    kill "-$signal_name" -- "-$pid"
    wait "$pid" || rc=$?
    assert_eq "$expected_status" "$rc" "$signal_name during backup directory race returns conventional status"
    [[ -d "$root/backups" && ! -L "$root/backups" ]] || fail "$signal_name backup directory race deleted competing directory"
    assert_eq 700 "$(stat -c %a "$root/backups")" "$signal_name backup directory race preserves 0700 mode"
    assert_file_eq owner-data "$root/backups/owner-data" "$signal_name backup directory race preserves owner data"
    [[ ! -e "$root/backups/.xanmod-allocation-owner" ]] || fail "$signal_name backup directory race wrote ownership proof into competing directory"
    pass "$signal_name backup directory race does not claim competing directory"
    assert_file_eq key-before "$root/key.gpg" "$signal_name backup directory race leaves key unchanged"
    assert_file_eq list-before "$root/release.list" "$signal_name backup directory race leaves list unchanged"
    assert_file_eq source-before "$root/release.sources" "$signal_name backup directory race leaves source unchanged"
    flock -n "$root/xanmod.lock" -c true || fail "$signal_name backup directory race did not release lock"
    pass "$signal_name backup directory race releases lock"
}

run_backup_dir_race_signal_case HUP 129
run_backup_dir_race_signal_case INT 130
run_backup_dir_race_signal_case TERM 143

cat > "$TEST_DIR/backup-parent-child.sh" <<'BACKUP_PARENT_CHILD'
#!/usr/bin/env bash
set -euo pipefail
root="$1"
case_name="$2"
module="$3"
state_dir="$root/missing-parent/missing-child/apt-source-backups"
parent_dir=$(dirname "$state_dir")
mkdir -p "$root/tmp"
printf key-before > "$root/key.gpg"
printf list-before > "$root/release.list"
printf source-before > "$root/release.sources"
case "$case_name" in
    success) ;;
    symlink)
        mkdir -p "$root/real-parent"
        ln -s "$root/real-parent" "$root/missing-parent"
        state_dir="$root/missing-parent/apt-source-backups"
        parent_dir=$(dirname "$state_dir")
        ;;
    writable)
        mkdir -p "$parent_dir"
        chmod 0777 "$parent_dir"
        ;;
    wrong-owner|wrong-gid)
        mkdir -p "$parent_dir"
        chmod 0755 "$parent_dir"
        ;;
    *) exit 2 ;;
esac
export XANMOD_TEST_MODE=1
export XANMOD_KEYRING_PATH="$root/key.gpg"
export XANMOD_SOURCE_LIST_PATH="$root/release.list"
export XANMOD_SOURCE_DEB822_PATH="$root/release.sources"
export XANMOD_LOCK_PATH="$root/xanmod.lock"
export XANMOD_OS_RELEASE_PATH="$root/os-release"
export XANMOD_CPUINFO_PATH="$root/cpuinfo"
export XANMOD_BACKUP_STATE_DIR="$state_dir"
export TMPDIR="$root/tmp"
source "$module"
fail() { printf 'FAIL: backup parent %s: %s
' "$case_name" "$*" >&2; exit 1; }
pass() { printf 'PASS: backup parent %s %s
' "$case_name" "$*"; }
assert_file() {
    local expected="$1" file="$2" label="$3"
    [[ -f "$file" && ! -L "$file" && "$(<"$file")" == "$expected" ]] || fail "$label"
    pass "$label"
}
if [[ "$case_name" == wrong-owner || "$case_name" == wrong-gid ]]; then
    other_uid=65534; [[ "$other_uid" == "$XANMOD_TRUSTED_UID" ]] && other_uid=0
    other_gid=65534; [[ "$other_gid" == "$XANMOD_TRUSTED_GID" ]] && other_gid=0
    stat() {
        local last=${!#}
        if [[ "$last" == "$parent_dir" && "$*" == *'%u:%g:%a'* ]]; then
            if [[ "$case_name" == wrong-owner ]]; then
                printf '%s:%s:755
' "$other_uid" "$XANMOD_TRUSTED_GID"
            else
                printf '%s:%s:755
' "$XANMOD_TRUSTED_UID" "$other_gid"
            fi
        else
            command stat "$@"
        fi
    }
fi
rc=0; ensure_xanmod_backup_state_dir > "$root/ensure.log" 2>&1 || rc=$?
if [[ "$case_name" == success ]]; then
    [[ "$rc" == 0 ]] || { cat "$root/ensure.log"; fail "multi-level missing parent ensure failed"; }
    [[ -d "$root/missing-parent" && ! -L "$root/missing-parent" ]] || fail "first missing parent is not a regular directory"
    [[ -d "$parent_dir" && ! -L "$parent_dir" ]] || fail "immediate missing parent is not a regular directory"
    [[ -d "$state_dir" && ! -L "$state_dir" ]] || fail "leaf is not a regular directory"
    [[ "$(stat -c %a "$state_dir")" == 700 ]] || fail "leaf mode is not 0700"
    pass "creates trusted multi-level parent and 0700 leaf"
    cleanup_new_empty_xanmod_backup_state_dir || fail "could not remove owned empty leaf"
    [[ -d "$parent_dir" && ! -L "$parent_dir" ]] || fail "cleanup deleted trusted parent"
    ensure_xanmod_backup_state_dir || fail "second ensure could not recreate leaf"
    [[ "$(stat -c %a "$state_dir")" == 700 ]] || fail "recreated leaf mode is not 0700"
    pass "keeps trusted parent and recreates trusted leaf"
else
    [[ "$rc" == 1 ]] || fail "untrusted parent was not rejected"
    [[ ! -e "$state_dir" && ! -L "$state_dir" ]] || fail "rejected parent still created leaf"
    pass "rejects parent before leaf creation"
fi
assert_file key-before "$root/key.gpg" "leaves key unchanged"
assert_file list-before "$root/release.list" "leaves list unchanged"
assert_file source-before "$root/release.sources" "leaves source unchanged"
BACKUP_PARENT_CHILD
chmod 0755 "$TEST_DIR/backup-parent-child.sh"

for backup_parent_case in success symlink writable wrong-owner wrong-gid; do
    backup_parent_root="$TEST_DIR/backup-parent-$backup_parent_case"
    mkdir -p "$backup_parent_root"
    bash "$TEST_DIR/backup-parent-child.sh" \
        "$backup_parent_root" "$backup_parent_case" "$MODULE"
done

cat > "$TEST_DIR/restore-no-backup-child.sh" <<'RESTORE_NO_BACKUP_CHILD'
#!/usr/bin/env bash
set -euo pipefail
root="$1"
module="$2"
state_dir="$root/missing-parent/apt-source-backups"
printf key-before > "$root/key.gpg"
printf list-before > "$root/release.list"
printf source-before > "$root/release.sources"
mkdir -p "$root/tmp"
export XANMOD_TEST_MODE=1
export XANMOD_KEYRING_PATH="$root/key.gpg"
export XANMOD_SOURCE_LIST_PATH="$root/release.list"
export XANMOD_SOURCE_DEB822_PATH="$root/release.sources"
export XANMOD_LOCK_PATH="$root/xanmod.lock"
export XANMOD_OS_RELEASE_PATH="$root/os-release"
export XANMOD_CPUINFO_PATH="$root/cpuinfo"
export XANMOD_BACKUP_STATE_DIR="$state_dir"
export TMPDIR="$root/tmp"
source "$module"
apt-get() { printf 'unexpected apt\n' >&2; return 1; }
for scope in previous initial; do
    rc=0; restore_xanmod_group "$scope" > "$root/$scope.log" 2>&1 || rc=$?
    [[ "$rc" == 2 ]] || { cat "$root/$scope.log"; printf 'FAIL: restore without backup %s returned %s\n' "$scope" "$rc" >&2; exit 1; }
    printf 'PASS: real restore without backup %s returns missing state\n' "$scope"
done
[[ ! -e "$root/missing-parent" && ! -L "$root/missing-parent" ]] || { printf 'FAIL: restore without backup created parent\n' >&2; exit 1; }
[[ ! -e "$state_dir" && ! -L "$state_dir" ]] || { printf 'FAIL: restore without backup created state directory\n' >&2; exit 1; }
[[ -z "$(find "$root" \( -name '.xanmod-allocation-owner' -o -name '*.xanmod-owner.*' \) -print -quit)" ]] || { printf 'FAIL: restore without backup left proof\n' >&2; exit 1; }
[[ "$(<"$root/key.gpg")" == key-before && "$(<"$root/release.list")" == list-before && "$(<"$root/release.sources")" == source-before ]] || { printf 'FAIL: restore without backup changed formal files\n' >&2; exit 1; }
printf 'PASS: real restore without backup creates no parent, state directory, or proof\n'
printf 'PASS: real restore without backup leaves formal files unchanged\n'
RESTORE_NO_BACKUP_CHILD
chmod 0755 "$TEST_DIR/restore-no-backup-child.sh"
restore_no_backup_root="$TEST_DIR/restore-no-backup"
mkdir -p "$restore_no_backup_root"
bash "$TEST_DIR/restore-no-backup-child.sh" "$restore_no_backup_root" "$MODULE"

cat > "$TEST_DIR/restore-allocation-signal-child.sh" <<'RESTORE_ALLOCATION_SIGNAL_CHILD'
#!/usr/bin/env bash
set -euo pipefail
root="$1"
module="$2"
mkdir -p "$root/tmp"
export XANMOD_TEST_MODE=1
export XANMOD_KEYRING_PATH="$root/key.gpg"
export XANMOD_SOURCE_LIST_PATH="$root/release.list"
export XANMOD_SOURCE_DEB822_PATH="$root/release.sources"
export XANMOD_LOCK_PATH="$root/xanmod.lock"
export XANMOD_OS_RELEASE_PATH="$root/os-release"
export XANMOD_CPUINFO_PATH="$root/cpuinfo"
export XANMOD_BACKUP_STATE_DIR="$root/state/apt-source-backups"
export TMPDIR="$root/tmp"
source "$module"
apt-get() { :; }
write_generation() {
    local generation="$1"
    printf '%s-key' "$generation" > "$XANMOD_KEYRING"
    printf '%s-list' "$generation" > "$XANMOD_SOURCE_LIST"
    printf '%s-source' "$generation" > "$XANMOD_SOURCE_DEB822"
}
write_generation A
prepare_persistent_xanmod_backups
write_generation B
prepare_persistent_xanmod_backups
write_generation C
block_for_signal() {
    touch "$root/ready"
    while :; do sleep 1; done
}
xanmod_after_allocation_attempt_hook() {
    local attempted_kind="$1"
    local attempted_path="$2"
    local create_status="$3"

    if [[ "$attempted_kind" == directory &&
        "$(basename "$attempted_path")" == xanmod-runtime-snapshot.* &&
        "$create_status" == 0 ]]; then
        block_for_signal
    fi
}
take_xanmod_lock
restore_xanmod_group previous
RESTORE_ALLOCATION_SIGNAL_CHILD
chmod 0755 "$TEST_DIR/restore-allocation-signal-child.sh"

run_restore_allocation_signal_case() {
    local signal_name="$1" expected_status="$2"
    local root="$TEST_DIR/restore-allocation-$signal_name"
    local pid rc=0

    mkdir -p "$root"
    setsid env --default-signal=HUP,INT,TERM \
        bash "$TEST_DIR/restore-allocation-signal-child.sh" \
        "$root" "$MODULE" > "$root/output.log" 2>&1 &
    pid=$!
    for _ in $(seq 1 200); do
        [[ -e "$root/ready" ]] && break
        sleep 0.05
    done
    [[ -e "$root/ready" ]] || { cat "$root/output.log"; kill "$pid" 2>/dev/null || true; fail "$signal_name real restore allocation did not block"; }
    kill "-$signal_name" -- "-$pid"
    wait "$pid" || rc=$?
    assert_eq "$expected_status" "$rc" "$signal_name during real restore allocation returns conventional status"
    assert_file_eq C-key "$root/key.gpg" "$signal_name real restore allocation leaves key unchanged"
    assert_file_eq C-list "$root/release.list" "$signal_name real restore allocation leaves list unchanged"
    assert_file_eq C-source "$root/release.sources" "$signal_name real restore allocation leaves source unchanged"
    assert_eq 700 "$(stat -c %a "$root/state/apt-source-backups")" "$signal_name real restore preserves trusted backup state mode"
    [[ -z "$(find "$root" \( -name 'xanmod-runtime-snapshot.*' -o -name '.xanmod-stage.*' \
        -o -name '.xanmod-allocation-owner' -o -name '*.xanmod-owner.*' \) -print -quit)" ]] || fail "$signal_name real restore left allocation or proof residue"
    pass "$signal_name real restore allocation leaves no candidate, proof, snapshot, or restore stage"
    flock -n "$root/xanmod.lock" -c true || fail "$signal_name real restore allocation did not release lock"
    pass "$signal_name real restore allocation releases lock"
}

run_restore_allocation_signal_case HUP 129
run_restore_allocation_signal_case INT 130
run_restore_allocation_signal_case TERM 143

module_root="$TEST_DIR/module"
make_layout "$module_root"
env XANMOD_TEST_MODE=1 \
    XANMOD_KEYRING_PATH="$module_root/key.gpg" XANMOD_SOURCE_LIST_PATH="$module_root/release.list" \
    XANMOD_SOURCE_DEB822_PATH="$module_root/release.sources" XANMOD_LOCK_PATH="$module_root/xanmod.lock" \
    XANMOD_OS_RELEASE_PATH="$module_root/os-release" XANMOD_CPUINFO_PATH="$module_root/cpuinfo" \
    XANMOD_BACKUP_STATE_DIR="$module_root/backups" TMPDIR="$module_root/tmp" \
    MODULE="$MODULE" ROOT="$module_root" bash <<'MODULE_TESTS'
set -euo pipefail
fail() { printf 'FAIL: module: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: module %s\n' "$*"; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected '$1', got '$2'"; pass "$3"; }
assert_fail() { local name="$1"; shift; if "$@"; then fail "$name: unexpectedly succeeded"; fi; pass "$name"; }
source "$MODULE"
OTHER_UID=65534; [[ "$OTHER_UID" == "$XANMOD_TRUSTED_UID" ]] && OTHER_UID=0
OTHER_GID=65534; [[ "$OTHER_GID" == "$XANMOD_TRUSTED_GID" ]] && OTHER_GID=0
[[ -z "$(trap -p ERR)" ]] || fail "source installed ERR trap"
pass "source leaves ERR trap unchanged"

valid_colons() {
    printf '%s\n' pub::::::::: \
        fpr:::::::::D38D7D1DA1349567ADED882D86F7D09EE734E623: \
        'uid:::::::::XanMod Kernel <kernel@xanmod.org>:'
}
gpg() { valid_colons; }
curl() { fail "module test attempted real curl"; }
hostname() { fail "module test attempted real hostname"; }
uptime() { fail "module test attempted real uptime"; }
dpkg() { echo amd64; }
uname() { [[ ${1:-} == -m ]] && echo x86_64 || echo 6.1.0-amd64; }
get_installed_xanmod_packages() { echo linux-xanmod-x64v3; }
package_is_installed() { return 0; }

printf valid > "$XANMOD_KEYRING"; chmod 0644 "$XANMOD_KEYRING"
write_xanmod_deb822_source "$XANMOD_SOURCE_DEB822" https://deb.xanmod.org trixie "$XANMOD_KEYRING"; chmod 0644 "$XANMOD_SOURCE_DEB822"
is_interactive_terminal() { return 1; }
require_root() { fail "strict no-op required root"; }
main xanmod >/dev/null
pass "real module main returns success without authorization for strict no-op"

printf 'VERSION_CODENAME=forky\n' > "$XANMOD_OS_RELEASE"
rm -f "$XANMOD_KEYRING" "$XANMOD_SOURCE_DEB822"
main xanmod >/dev/null
pass "module keeps original policy and skips unsupported forky without authorization"
printf 'VERSION_CODENAME=trixie\n' > "$XANMOD_OS_RELEASE"

get_installed_xanmod_packages() { :; }
package_is_installed() { return 1; }
calls="$ROOT/preauth.calls"; : > "$calls"
require_root() { echo root >> "$calls"; }
take_xanmod_lock() { echo lock >> "$calls"; }
apt-get() { echo apt >> "$calls"; }
rc=0; main xanmod > "$ROOT/preauth.log" 2>&1 || rc=$?
assert_eq 1 "$rc" "module modifying plan needs --yes without TTY"
[[ ! -s "$calls" ]] || fail "module pre-authorization path had side effects"
pass "module confirmation precedes root, lock, APT, and writes"

require_root() { :; }
configure_motd() { echo motd >> "$calls"; }
configure_chinese_locale() { echo locale >> "$calls"; }
show_xanmod_status() { echo status >> "$calls"; }
run_authorized_xanmod_install() { fail "no-TTY all executed modifying XanMod plan"; }
: > "$calls"; main all >/dev/null
assert_eq $'motd\nlocale\nstatus' "$(<"$calls")" "module all without TTY only skips modifying XanMod step"

# Restore real helpers in a fresh state within this process.
unset -f require_root configure_motd configure_chinese_locale show_xanmod_status run_authorized_xanmod_install apt-get
apt-get() { printf '%s\n' "$*" >> "$ROOT/apt.log"; return "${APT_RESULT:-0}"; }
: > "$ROOT/apt.log"

reset_state() {
    trap - EXIT HUP INT TERM
    command rm -rf "$XANMOD_KEYRING" "$XANMOD_SOURCE_LIST" "$XANMOD_SOURCE_DEB822" \
        "$XANMOD_BACKUP_STATE_DIR" "$XANMOD_LOCK" "$ROOT/tmp"
    mkdir -p "$ROOT/tmp"
    printf 'VERSION_CODENAME=trixie\n' > "$XANMOD_OS_RELEASE"
    XANMOD_RUNTIME_SNAPSHOT_DIR=""; XANMOD_RUNTIME_SNAPSHOT_BUILDING=false
    XANMOD_TRANSACTION_ACTIVE=false; XANMOD_CONFIG_MODIFIED=false
    XANMOD_GUARD_ACTIVE=false; XANMOD_GUARD_HANDLING=false; XANMOD_LOCK_HELD=false
    XANMOD_STAGED_KEY=""; XANMOD_STAGED_SOURCE=""; XANMOD_CANDIDATE_SOURCE=""
    XANMOD_ARMORED_KEY_TEMP=""; XANMOD_ACTIVE_APT_LISTS_DIR=""; XANMOD_ACTIVE_APT_LISTS_BUILDING=false
    XANMOD_ALLOCATION_CANDIDATE=""; XANMOD_ALLOCATION_KIND=""; XANMOD_ALLOCATION_OWNER_TOKEN=""
    XANMOD_ALLOCATION_EXPECTED_MODE=""; XANMOD_ALLOCATION_PROOF_OWNED=false; XANMOD_ALLOCATION_STATE=""
    XANMOD_ALLOCATION_CRITICAL=false; XANMOD_ALLOCATION_PENDING_SIGNAL=""; XANMOD_ALLOCATION_PENDING_SIGNAL_STATUS=0
    XANMOD_RESTORE_STAGE=""
    XANMOD_BACKUP_STATE_DIR_CREATING=false; XANMOD_BACKUP_STATE_DIR_CREATED=false; XANMOD_BACKUP_STATE_DIR_PREEXISTED=false
    XANMOD_BACKUP_TRANSACTION_ACTIVE=false; XANMOD_BACKUP_SNAPSHOT_BUILDING=false; XANMOD_BACKUP_SNAPSHOT_REMOVED=false
    XANMOD_BACKUP_GROUP_SNAPSHOT_DIR=""; XANMOD_BACKUP_STAGE_DIR=""; XANMOD_BACKUP_STAGE_BUILDING=false
    XANMOD_BACKUP_SNAPSHOT_PATHS=(); XANMOD_BACKUP_LEGACY_PATHS=(); XANMOD_BACKUP_NEW_ARCHIVES=()
    APT_RESULT=0; : > "$ROOT/apt.log"
}
write_generation() {
    local name="$1"
    printf '%s-key' "$name" > "$XANMOD_KEYRING"
    printf '%s-list' "$name" > "$XANMOD_SOURCE_LIST"
    printf '%s-source' "$name" > "$XANMOD_SOURCE_DEB822"
}
assert_generation() {
    local name="$1" label="$2"
    assert_eq "$name-key" "$(<"$XANMOD_KEYRING")" "$label key"
    assert_eq "$name-list" "$(<"$XANMOD_SOURCE_LIST")" "$label list"
    assert_eq "$name-source" "$(<"$XANMOD_SOURCE_DEB822")" "$label source"
}
restore_previous_generation() {
    local expected="$1" label="$2"
    write_generation C
    restore_xanmod_group previous >/dev/null
    assert_generation "$expected" "$label"
}
save_function() {
    local function_name="$1" saved_name="$2"
    eval "$(declare -f "$function_name" | sed "1s/$function_name/$saved_name/")"
}
restore_function() {
    local saved_name="$1" function_name="$2"
    eval "$(declare -f "$saved_name" | sed "1s/$saved_name/$function_name/")"
}

reset_state
write_generation A
take_xanmod_lock
proof_release_failed=true
rm() {
    local last=${!#}
    if [[ "$proof_release_failed" == true &&
        "$last" == "$ROOT/tmp"/xanmod-backup-group.*/.xanmod-allocation-owner ]]; then
        proof_release_failed=false
        return 1
    fi
    command rm "$@"
}
rc=0; begin_xanmod_install_transaction > "$ROOT/begin-backup-proof-fail.log" 2>&1 || rc=$?
assert_eq 1 "$rc" "begin backup snapshot proof release failure returns nonzero"
assert_eq false "$XANMOD_GUARD_ACTIVE" "begin prepare failure clears transaction guards after cleanup"
assert_eq '' "$XANMOD_ALLOCATION_CANDIDATE" "begin prepare failure clears pending allocation candidate"
assert_eq false "$XANMOD_ALLOCATION_PROOF_OWNED" "begin prepare failure clears proof ownership state"
assert_eq '' "$XANMOD_BACKUP_GROUP_SNAPSHOT_DIR" "begin prepare failure clears backup snapshot path"
assert_eq '' "$XANMOD_BACKUP_STAGE_DIR" "begin prepare failure clears backup stage path"
assert_eq false "$XANMOD_BACKUP_TRANSACTION_ACTIVE" "begin prepare failure clears backup transaction state"
[[ ! -e "$XANMOD_BACKUP_STATE_DIR" && ! -L "$XANMOD_BACKUP_STATE_DIR" ]] || fail "begin prepare failure left new empty state directory"
pass "begin prepare failure removes new empty backup state directory"
[[ -z "$(find "$ROOT" \( -name 'xanmod-backup-group.*' -o -name '.xanmod-backup-stage.*'     -o -name '.xanmod-allocation-owner' -o -name '*.xanmod-owner.*' \) -print -quit)" ]] || fail "begin prepare failure left candidate, proof, snapshot, or stage"
pass "begin prepare failure leaves no candidate, proof, snapshot, or stage residue"
assert_generation A "begin prepare failure formal generation"
unset -f rm
release_xanmod_lock
flock -n "$XANMOD_LOCK" -c true || fail "begin prepare failure did not release lock"
pass "begin prepare failure lock can be reacquired"

reset_state
ensure_xanmod_backup_state_dir
snapshot="$ROOT/tmp/xanmod-backup-group.incomplete"
mkdir -m 0700 "$snapshot"
XANMOD_BACKUP_GROUP_SNAPSHOT_DIR="$snapshot"
XANMOD_BACKUP_SNAPSHOT_BUILDING=true
XANMOD_BACKUP_TRANSACTION_ACTIVE=false
rm() { local last=${!#}; [[ "$last" == "$snapshot" ]] && return 1; command rm "$@"; }
rc=0; abort_pending_xanmod_backup_transaction > "$ROOT/incomplete-backup-cleanup.log" 2>&1 || rc=$?
assert_eq 1 "$rc" "incomplete backup snapshot deletion failure returns nonzero"
assert_eq "$snapshot" "$XANMOD_BACKUP_GROUP_SNAPSHOT_DIR" "incomplete backup deletion failure preserves path"
assert_eq true "$XANMOD_BACKUP_SNAPSHOT_BUILDING" "incomplete backup deletion failure preserves building state"
grep -Fq "$snapshot" "$ROOT/incomplete-backup-cleanup.log" || fail "incomplete backup cleanup omitted residue path"
pass "incomplete backup snapshot deletion failure reports exact path"
unset -f rm; command rm -rf "$snapshot"; XANMOD_BACKUP_GROUP_SNAPSHOT_DIR=""; XANMOD_BACKUP_SNAPSHOT_BUILDING=false; XANMOD_BACKUP_STATE_DIR_CREATED=false

reset_state
ensure_xanmod_backup_state_dir
rmdir() { [[ "$1" == "$XANMOD_BACKUP_STATE_DIR" ]] && return 1; command rmdir "$@"; }
rc=0; cleanup_new_empty_xanmod_backup_state_dir > "$ROOT/backup-rmdir-fail.log" 2>&1 || rc=$?
assert_eq 1 "$rc" "new empty backup directory rmdir failure returns nonzero"
assert_eq true "$XANMOD_BACKUP_STATE_DIR_CREATED" "backup directory rmdir failure preserves ownership state"
[[ -d "$XANMOD_BACKUP_STATE_DIR" ]] || fail "backup directory rmdir failure lost directory"
grep -Fq "$XANMOD_BACKUP_STATE_DIR" "$ROOT/backup-rmdir-fail.log" || fail "backup directory rmdir failure omitted path"
pass "backup directory rmdir failure reports exact path"
unset -f rmdir
cleanup_new_empty_xanmod_backup_state_dir
[[ ! -e "$XANMOD_BACKUP_STATE_DIR" ]] || fail "backup directory rmdir retry left directory"
pass "backup directory rmdir retry completes cleanup"

reset_state
write_generation A; prepare_persistent_xanmod_backups
write_generation B; prepare_persistent_xanmod_backups
assert_eq 700 "$(stat -c %a "$XANMOD_BACKUP_STATE_DIR")" "backup directory mode is 0700"
for target in "${XANMOD_MANAGED_PATHS[@]}"; do
    prefix=$(get_xanmod_backup_prefix "$target")
    assert_eq "$XANMOD_TRUSTED_UID:$XANMOD_TRUSTED_GID:600" "$(stat -c '%u:%g:%a' "${prefix}.previous-backup")" "previous backup item is trusted"
    assert_eq "$XANMOD_TRUSTED_UID:$XANMOD_TRUSTED_GID:600" "$(stat -c '%u:%g:%a' "${prefix}.previous-backup-meta")" "previous metadata item is trusted"
done
restore_previous_generation B "normal previous restore"
restore_xanmod_group initial >/dev/null
assert_generation A "normal initial restore"

# Capture failure on the second previous item must leave the full A generation.
reset_state
write_generation A; prepare_persistent_xanmod_backups
initial_hash_before=$(find "$XANMOD_BACKUP_STATE_DIR" -maxdepth 1 -name '*.initial-*' -type f -print0 | sort -z | xargs -0 sha256sum)
write_generation B
save_function capture_xanmod_persistent_state original_capture_xanmod_persistent_state
capture_calls=0
capture_xanmod_persistent_state() {
    if [[ "$3" == previous ]]; then ((capture_calls += 1)); (( capture_calls == 2 )) && return 1; fi
    original_capture_xanmod_persistent_state "$@"
}
rc=0; prepare_persistent_xanmod_backups || rc=$?
assert_eq 1 "$rc" "second previous capture failure returns nonzero"
restore_function original_capture_xanmod_persistent_state capture_xanmod_persistent_state
initial_hash_after=$(find "$XANMOD_BACKUP_STATE_DIR" -maxdepth 1 -name '*.initial-*' -type f -print0 | sort -z | xargs -0 sha256sum)
assert_eq "$initial_hash_before" "$initial_hash_after" "capture failure preserves trusted initial group"
restore_previous_generation A "capture failure preserves A generation"

# Initial creation failure must not create a partial initial group or mix previous.
reset_state
write_generation A; prepare_persistent_xanmod_backups
command rm -f "$XANMOD_BACKUP_STATE_DIR"/*.initial-*
write_generation B
save_function capture_xanmod_persistent_state original_capture_xanmod_persistent_state
initial_calls=0
capture_xanmod_persistent_state() {
    if [[ "$3" == initial ]]; then ((initial_calls += 1)); (( initial_calls == 2 )) && return 1; fi
    original_capture_xanmod_persistent_state "$@"
}
rc=0; prepare_persistent_xanmod_backups || rc=$?
assert_eq 1 "$rc" "initial creation failure returns nonzero"
restore_function original_capture_xanmod_persistent_state capture_xanmod_persistent_state
[[ -z "$(find "$XANMOD_BACKUP_STATE_DIR" -maxdepth 1 -name '*.initial-*' -print -quit)" ]] || fail "initial failure left partial initial state"
pass "initial creation failure restores the old absent initial group"
restore_previous_generation A "initial failure preserves A previous generation"

# Trusted legacy initial sidecars migrate into the secure grouped format.
reset_state
write_generation B
printf A-key > "$XANMOD_KEYRING.initial-backup"; chmod 0600 "$XANMOD_KEYRING.initial-backup"
printf A-list > "$XANMOD_SOURCE_LIST.initial-backup"; chmod 0600 "$XANMOD_SOURCE_LIST.initial-backup"
printf A-source > "$XANMOD_SOURCE_DEB822.initial-backup"; chmod 0600 "$XANMOD_SOURCE_DEB822.initial-backup"
prepare_persistent_xanmod_backups
[[ ! -e "$XANMOD_KEYRING.initial-backup" && ! -e "$XANMOD_SOURCE_LIST.initial-backup" && ! -e "$XANMOD_SOURCE_DEB822.initial-backup" ]] || fail "legacy sidecars remained after migration"
pass "trusted legacy sidecars migrate out of formal directories"
write_generation C
restore_xanmod_group initial >/dev/null
assert_generation A "successful legacy initial migration"

# Legacy migration staging failure must restore active and legacy state together.
reset_state
write_generation A; prepare_persistent_xanmod_backups
printf legacy-key > "$XANMOD_KEYRING.initial-backup"; chmod 0600 "$XANMOD_KEYRING.initial-backup"
printf legacy-list > "$XANMOD_SOURCE_LIST.initial-backup"; chmod 0600 "$XANMOD_SOURCE_LIST.initial-backup"
write_generation B
save_function stage_xanmod_legacy_backup_item original_stage_xanmod_legacy_backup_item
legacy_calls=0
stage_xanmod_legacy_backup_item() {
    ((legacy_calls += 1)); (( legacy_calls == 2 )) && return 1
    original_stage_xanmod_legacy_backup_item "$@"
}
rc=0; prepare_persistent_xanmod_backups || rc=$?
assert_eq 1 "$rc" "legacy migration middle failure returns nonzero"
restore_function original_stage_xanmod_legacy_backup_item stage_xanmod_legacy_backup_item
assert_eq legacy-key "$(<"$XANMOD_KEYRING.initial-backup")" "legacy failure restores key sidecar"
assert_eq legacy-list "$(<"$XANMOD_SOURCE_LIST.initial-backup")" "legacy failure restores list sidecar"
restore_previous_generation A "legacy migration failure preserves A generation"

# Commit failure after one state commit must restore the full old group.
reset_state
write_generation A; prepare_persistent_xanmod_backups
write_generation B
save_function commit_xanmod_persistent_state original_commit_xanmod_persistent_state
commit_calls=0
commit_xanmod_persistent_state() {
    ((commit_calls += 1)); (( commit_calls == 2 )) && return 1
    original_commit_xanmod_persistent_state "$@"
}
rc=0; prepare_persistent_xanmod_backups || rc=$?
assert_eq 1 "$rc" "backup commit middle failure returns nonzero"
restore_function original_commit_xanmod_persistent_state commit_xanmod_persistent_state
restore_previous_generation A "backup commit failure preserves A generation"

# Snapshot deletion failure must retain a newly created 0700 state directory until retry.
reset_state
write_generation A
ensure_xanmod_backup_state_dir
assert_eq true "$XANMOD_BACKUP_STATE_DIR_CREATED" "new backup state directory records owned creation"
create_xanmod_backup_group_snapshot
backup_snapshot="$XANMOD_BACKUP_GROUP_SNAPSHOT_DIR"
backup_path_count=${#XANMOD_BACKUP_SNAPSHOT_PATHS[@]}
backup_archive="$XANMOD_BACKUP_STATE_DIR/retry-archive"
printf archive > "$backup_archive"
XANMOD_BACKUP_NEW_ARCHIVES=("$backup_archive")
xanmod_allocate_temp_directory XANMOD_BACKUP_STAGE_DIR \
    XANMOD_BACKUP_STAGE_BUILDING "$XANMOD_BACKUP_STATE_DIR" .retry-stage 0700
XANMOD_BACKUP_STAGE_BUILDING=false
backup_stage="$XANMOD_BACKUP_STAGE_DIR"
printf stage > "$XANMOD_BACKUP_STAGE_DIR/staged"
rm() { local last=${!#}; [[ "$last" == "$backup_snapshot" ]] && return 1; command rm "$@"; }
rc=0; restore_xanmod_backup_group_snapshot > "$ROOT/backup-new-state-snapshot-delete.log" 2>&1 || rc=$?
assert_eq 1 "$rc" "new-state snapshot deletion failure returns nonzero"
[[ -d "$XANMOD_BACKUP_STATE_DIR" && ! -L "$XANMOD_BACKUP_STATE_DIR" ]] || fail "snapshot deletion failure removed new backup state directory"
assert_eq 700 "$(stat -c %a "$XANMOD_BACKUP_STATE_DIR")" "snapshot deletion failure keeps new state directory at 0700"
assert_eq false "$XANMOD_BACKUP_STATE_DIR_CREATING" "snapshot deletion failure preserves completed creating state"
assert_eq true "$XANMOD_BACKUP_STATE_DIR_CREATED" "snapshot deletion failure preserves created ownership state"
assert_eq false "$XANMOD_BACKUP_STATE_DIR_PREEXISTED" "snapshot deletion failure preserves non-preexisting state"
assert_eq true "$XANMOD_BACKUP_TRANSACTION_ACTIVE" "snapshot deletion failure preserves backup transaction"
assert_eq false "$XANMOD_BACKUP_SNAPSHOT_REMOVED" "snapshot deletion failure records snapshot as retained"
assert_eq "$backup_snapshot" "$XANMOD_BACKUP_GROUP_SNAPSHOT_DIR" "snapshot deletion failure preserves snapshot path"
assert_eq "$backup_path_count" "${#XANMOD_BACKUP_SNAPSHOT_PATHS[@]}" "snapshot deletion failure preserves restore array"
[[ -d "$backup_snapshot" ]] || fail "snapshot deletion failure lost snapshot directory"
[[ ! -e "$backup_archive" && ! -e "$backup_stage" ]] || fail "snapshot deletion failure left archive or stage"
pass "snapshot deletion failure cleans archive and stage before retaining snapshot"
unset -f rm
restore_xanmod_backup_group_snapshot
[[ ! -e "$backup_snapshot" ]] || fail "new-state restore retry left snapshot"
[[ ! -e "$XANMOD_BACKUP_STATE_DIR" && ! -L "$XANMOD_BACKUP_STATE_DIR" ]] || fail "new-state restore retry left empty state directory"
pass "new-state restore retry deletes snapshot before owned empty state directory"
assert_eq false "$XANMOD_BACKUP_TRANSACTION_ACTIVE" "new-state restore retry clears active state"
assert_eq 0 "${#XANMOD_BACKUP_SNAPSHOT_PATHS[@]}" "new-state restore retry clears restore array"
assert_eq false "$XANMOD_BACKUP_STATE_DIR_CREATED" "new-state restore retry clears created state"
ensure_xanmod_backup_state_dir
assert_eq 700 "$(stat -c %a "$XANMOD_BACKUP_STATE_DIR")" "post-retry ensure creates trusted 0700 state directory"
cleanup_new_empty_xanmod_backup_state_dir

# Snapshot deletion retry must never remove a preexisting trusted state directory.
reset_state
write_generation A
mkdir -m 0700 "$XANMOD_BACKUP_STATE_DIR"
printf keep > "$XANMOD_BACKUP_STATE_DIR/owner-data"
ensure_xanmod_backup_state_dir
assert_eq true "$XANMOD_BACKUP_STATE_DIR_PREEXISTED" "preexisting backup state directory is recorded"
create_xanmod_backup_group_snapshot
backup_snapshot="$XANMOD_BACKUP_GROUP_SNAPSHOT_DIR"
backup_path_count=${#XANMOD_BACKUP_SNAPSHOT_PATHS[@]}
rm() { local last=${!#}; [[ "$last" == "$backup_snapshot" ]] && return 1; command rm "$@"; }
rc=0; restore_xanmod_backup_group_snapshot > "$ROOT/backup-preexisting-snapshot-delete.log" 2>&1 || rc=$?
assert_eq 1 "$rc" "preexisting-state snapshot deletion failure returns nonzero"
assert_eq true "$XANMOD_BACKUP_STATE_DIR_PREEXISTED" "preexisting-state failure preserves preexisting state"
assert_eq false "$XANMOD_BACKUP_STATE_DIR_CREATED" "preexisting-state failure does not claim directory ownership"
assert_eq true "$XANMOD_BACKUP_TRANSACTION_ACTIVE" "preexisting-state failure preserves active transaction"
assert_eq "$backup_path_count" "${#XANMOD_BACKUP_SNAPSHOT_PATHS[@]}" "preexisting-state failure preserves restore array"
assert_eq 700 "$(stat -c %a "$XANMOD_BACKUP_STATE_DIR")" "preexisting-state failure preserves 0700 mode"
assert_eq keep "$(<"$XANMOD_BACKUP_STATE_DIR/owner-data")" "preexisting-state failure preserves owner data"
unset -f rm
restore_xanmod_backup_group_snapshot
[[ ! -e "$backup_snapshot" ]] || fail "preexisting-state retry left snapshot"
[[ -d "$XANMOD_BACKUP_STATE_DIR" && ! -L "$XANMOD_BACKUP_STATE_DIR" ]] || fail "preexisting-state retry removed directory"
assert_eq 700 "$(stat -c %a "$XANMOD_BACKUP_STATE_DIR")" "preexisting-state retry keeps 0700 mode"
assert_eq keep "$(<"$XANMOD_BACKUP_STATE_DIR/owner-data")" "preexisting-state retry keeps owner data"
assert_eq false "$XANMOD_BACKUP_TRANSACTION_ACTIVE" "preexisting-state retry clears active transaction"
assert_eq 0 "${#XANMOD_BACKUP_SNAPSHOT_PATHS[@]}" "preexisting-state retry clears restore array"

# A failed backup-group restore preserves the only snapshot and supports retry.
reset_state
write_generation A; prepare_persistent_xanmod_backups
create_xanmod_backup_group_snapshot
backup_snapshot="$XANMOD_BACKUP_GROUP_SNAPSHOT_DIR"
backup_path_count=${#XANMOD_BACKUP_SNAPSHOT_PATHS[@]}
key_previous="$(get_xanmod_backup_prefix "$XANMOD_KEYRING").previous-backup"
list_previous="$(get_xanmod_backup_prefix "$XANMOD_SOURCE_LIST").previous-backup"
source_previous="$(get_xanmod_backup_prefix "$XANMOD_SOURCE_DEB822").previous-backup"
printf unexpected-key > "$key_previous"; printf unexpected-list > "$list_previous"; printf unexpected-source > "$source_previous"
save_function restore_xanmod_snapshot_item original_restore_xanmod_snapshot_item
restore_xanmod_snapshot_item() {
    if [[ "$1" == "$list_previous" ]]; then return 1; fi
    original_restore_xanmod_snapshot_item "$@"
}
rc=0; restore_xanmod_backup_group_snapshot > "$ROOT/backup-restore-fail.log" 2>&1 || rc=$?
assert_eq 1 "$rc" "backup group restore failure returns nonzero"
[[ -d "$backup_snapshot" ]] || fail "backup group restore failure deleted snapshot"
pass "backup group restore failure preserves snapshot directory"
assert_eq true "$XANMOD_BACKUP_TRANSACTION_ACTIVE" "backup group restore failure preserves active state"
assert_eq "$backup_path_count" "${#XANMOD_BACKUP_SNAPSHOT_PATHS[@]}" "backup group restore failure preserves path array"
assert_eq unexpected-list "$(<"$list_previous")" "failed backup target remains available for retry"
grep -Fq "$backup_snapshot" "$ROOT/backup-restore-fail.log" || fail "backup group restore failure omitted snapshot path"
pass "backup group restore failure reports retained snapshot path"
restore_function original_restore_xanmod_snapshot_item restore_xanmod_snapshot_item
restore_xanmod_backup_group_snapshot
assert_eq A-key "$(<"$key_previous")" "backup group retry restores key generation"
assert_eq A-list "$(<"$list_previous")" "backup group retry restores list generation"
assert_eq A-source "$(<"$source_previous")" "backup group retry restores source generation"
[[ ! -e "$backup_snapshot" ]] || fail "backup group retry left snapshot"
assert_eq false "$XANMOD_BACKUP_TRANSACTION_ACTIVE" "backup group retry clears active state"
assert_eq 0 "${#XANMOD_BACKUP_SNAPSHOT_PATHS[@]}" "backup group retry clears path array"

# A complete backup snapshot deletion failure keeps recovery state until retry.
reset_state
write_generation A; prepare_persistent_xanmod_backups
create_xanmod_backup_group_snapshot
backup_snapshot="$XANMOD_BACKUP_GROUP_SNAPSHOT_DIR"
backup_path_count=${#XANMOD_BACKUP_SNAPSHOT_PATHS[@]}
rm() { local last=${!#}; [[ "$last" == "$backup_snapshot" ]] && return 1; command rm "$@"; }
rc=0; discard_xanmod_backup_group_snapshot > "$ROOT/backup-discard-fail.log" 2>&1 || rc=$?
assert_eq 1 "$rc" "complete backup snapshot deletion failure returns nonzero"
assert_eq "$backup_snapshot" "$XANMOD_BACKUP_GROUP_SNAPSHOT_DIR" "backup deletion failure preserves path"
assert_eq true "$XANMOD_BACKUP_TRANSACTION_ACTIVE" "backup deletion failure preserves active state"
assert_eq "$backup_path_count" "${#XANMOD_BACKUP_SNAPSHOT_PATHS[@]}" "backup deletion failure preserves recovery array"
grep -Fq "$backup_snapshot" "$ROOT/backup-discard-fail.log" || fail "backup deletion failure omitted snapshot path"
pass "backup snapshot deletion failure reports exact path"
unset -f rm
discard_xanmod_backup_group_snapshot
[[ ! -e "$backup_snapshot" ]] || fail "backup snapshot deletion retry left snapshot"
assert_eq false "$XANMOD_BACKUP_TRANSACTION_ACTIVE" "backup deletion retry clears active state"
assert_eq 0 "${#XANMOD_BACKUP_SNAPSHOT_PATHS[@]}" "backup deletion retry clears recovery array"

# Previously managed files without history become one initial-unknown group.
reset_state
printf managed-key > "$XANMOD_KEYRING"
write_xanmod_deb822_source "$XANMOD_SOURCE_DEB822" https://deb.xanmod.org trixie "$XANMOD_KEYRING"
rm -f "$XANMOD_SOURCE_LIST"
prepare_persistent_xanmod_backups
for target in "${XANMOD_MANAGED_PATHS[@]}"; do
    prefix=$(get_xanmod_backup_prefix "$target")
    [[ -f "${prefix}.initial-unknown" ]] || fail "managed initial group missed $(basename "$target") unknown marker"
done
pass "previously managed files create a complete initial-unknown group"
write_generation B
rc=0; restore_xanmod_group initial >/dev/null 2>&1 || rc=$?
assert_eq 2 "$rc" "initial-unknown group refuses restore"
assert_generation B "initial-unknown refusal"

# Trust rejection paths must not touch formal files.
assert_formal_unchanged() { assert_generation B "$1 leaves formal files unchanged"; }
reset_state
write_generation B; mkdir -m 0700 "$XANMOD_BACKUP_STATE_DIR"
stat() {
    local last=${!#}
    if [[ "$last" == "$XANMOD_BACKUP_STATE_DIR" && "$*" == *'%u:%g:%a'* ]]; then
        printf '%s:%s:700\n' "$OTHER_UID" "$XANMOD_TRUSTED_GID"
    else command stat "$@"; fi
}
assert_fail "wrong-owner backup directory is rejected" prepare_persistent_xanmod_backups
unset -f stat
assert_formal_unchanged "wrong-owner backup directory rejection"
[[ -z "$(find "$XANMOD_BACKUP_STATE_DIR" -mindepth 1 -print -quit)" ]] || fail "wrong-owner directory rejection wrote backup state"
pass "wrong-owner backup directory rejection writes no backup item"

reset_state
write_generation B; mkdir -m 0700 "$XANMOD_BACKUP_STATE_DIR"
stat() {
    local last=${!#}
    if [[ "$last" == "$XANMOD_BACKUP_STATE_DIR" && "$*" == *'%u:%g:%a'* ]]; then
        printf '%s:%s:700\n' "$XANMOD_TRUSTED_UID" "$OTHER_GID"
    else command stat "$@"; fi
}
assert_fail "wrong-GID backup directory is rejected" prepare_persistent_xanmod_backups
unset -f stat
assert_formal_unchanged "wrong-GID backup directory rejection"

reset_state
write_generation B; mkdir "$ROOT/real-backups"; chmod 0700 "$ROOT/real-backups"; ln -s "$ROOT/real-backups" "$XANMOD_BACKUP_STATE_DIR"
assert_fail "backup directory symlink is rejected" prepare_persistent_xanmod_backups
assert_formal_unchanged "backup directory symlink rejection"

reset_state
write_generation B; mkdir -m 0700 "$XANMOD_BACKUP_STATE_DIR"; printf marker > "$ROOT/marker-target"; ln -s "$ROOT/marker-target" "$XANMOD_BACKUP_STATE_DIR/key.gpg.initial-absent"
assert_fail "marker symlink is rejected" prepare_persistent_xanmod_backups
assert_formal_unchanged "marker symlink rejection"

reset_state
write_generation B; mkdir -m 0700 "$XANMOD_BACKUP_STATE_DIR"; mkdir "$XANMOD_BACKUP_STATE_DIR/key.gpg.initial-backup"
assert_fail "backup state directory item is rejected" prepare_persistent_xanmod_backups
assert_formal_unchanged "backup type rejection"

reset_state
write_generation B; mkdir -m 0700 "$XANMOD_BACKUP_STATE_DIR"; printf unsafe > "$XANMOD_BACKUP_STATE_DIR/key.gpg.initial-backup"; chmod 0622 "$XANMOD_BACKUP_STATE_DIR/key.gpg.initial-backup"
assert_fail "group/other writable backup item is rejected" prepare_persistent_xanmod_backups
assert_formal_unchanged "writable backup rejection"

reset_state
write_generation B; mkdir -m 0700 "$XANMOD_BACKUP_STATE_DIR"; install -m 0600 /dev/null "$XANMOD_BACKUP_STATE_DIR/key.gpg.initial-absent"
stat() {
    local last=${!#}
    if [[ "$last" == "$XANMOD_BACKUP_STATE_DIR/key.gpg.initial-absent" && "$*" == *'%u:%g:%a'* ]]; then
        printf '%s:%s:600\n' "$OTHER_UID" "$XANMOD_TRUSTED_GID"
    else command stat "$@"; fi
}
assert_fail "wrong-owner state item is rejected" prepare_persistent_xanmod_backups
unset -f stat
assert_formal_unchanged "wrong-owner state rejection"

reset_state
write_generation B; mkdir -m 0700 "$XANMOD_BACKUP_STATE_DIR"; install -m 0622 /dev/null "$XANMOD_BACKUP_STATE_DIR/key.gpg.initial-absent"
assert_fail "group/other writable marker is rejected" prepare_persistent_xanmod_backups
assert_formal_unchanged "writable marker rejection"

# Restore apply failure rolls all three formal paths back.
reset_state
write_generation A; prepare_persistent_xanmod_backups
write_generation B
save_function restore_xanmod_persistent_item original_restore_xanmod_persistent_item
restore_calls=0
restore_xanmod_persistent_item() {
    ((restore_calls += 1)); (( restore_calls == 2 )) && return 1
    original_restore_xanmod_persistent_item "$@"
}
rc=0; restore_xanmod_group previous >/dev/null 2>&1 || rc=$?
assert_eq 1 "$rc" "restore middle failure returns nonzero"
restore_function original_restore_xanmod_persistent_item restore_xanmod_persistent_item
assert_generation B "restore middle failure runtime rollback"

# APT refresh failure keeps the requested restored generation.
reset_state
write_generation A; prepare_persistent_xanmod_backups
write_generation B; prepare_persistent_xanmod_backups
write_generation C; APT_RESULT=1
rc=0; restore_xanmod_group previous >/dev/null 2>&1 || rc=$?
assert_eq 1 "$rc" "restore APT refresh failure returns nonzero"
assert_generation B "restore APT failure preserves requested generation"
if grep -Eq '(^| )(remove|purge)( |$)' "$ROOT/apt.log"; then fail "restore removed a kernel"; fi
pass "restore never removes a kernel package"
MODULE_TESTS

common_functions=(
    get_os_codename xanmod_codename_safe is_amd64 package_is_installed get_running_xanmod_package
    detect_x86_64_psabi_level get_xanmod_package_for_psabi_level detect_xanmod_package
    xanmod_regular_file_trusted set_xanmod_staged_file_metadata xanmod_keyring_valid
    xanmod_formal_keyring_valid xanmod_list_source_configured xanmod_deb822_source_configured
    get_xanmod_source_file xanmod_source_matches_codename write_xanmod_deb822_source
    remove_xanmod_temp_directory remove_xanmod_temp_file xanmod_random_token
    xanmod_allocation_proof_path xanmod_create_allocation_proof_file xanmod_write_allocation_proof
    xanmod_cleanup_created_allocation xanmod_create_temp_directory_at_path xanmod_create_temp_file_at_path
    xanmod_begin_pending_allocation xanmod_clear_pending_allocation
    xanmod_begin_allocation_critical_section xanmod_end_allocation_critical_section
    xanmod_after_allocation_attempt_hook
    xanmod_run_pending_allocation_create xanmod_pending_allocation_proof_trusted
    xanmod_pending_allocation_owned xanmod_mark_pending_allocation_residue
    xanmod_release_pending_allocation_proof cleanup_xanmod_pending_allocation xanmod_finish_pending_allocation
    xanmod_allocate_temp_directory xanmod_allocate_temp_file cleanup_xanmod_active_apt_lists xanmod_source_is_usable
    capture_xanmod_snapshot_item cleanup_incomplete_xanmod_runtime_snapshot create_xanmod_runtime_snapshot restore_xanmod_snapshot_item
    restore_xanmod_runtime_snapshot discard_xanmod_runtime_snapshot restore_xanmod_saved_trap
    install_xanmod_transaction_guards clear_xanmod_transaction_guards warn_xanmod_partial_install
    cleanup_xanmod_transaction_state xanmod_transaction_signal_handler xanmod_transaction_exit_handler
    begin_xanmod_install_transaction make_xanmod_stage_file cleanup_xanmod_stages
    stage_xanmod_key stage_xanmod_source xanmod_repository_files_ready xanmod_repository_ready
    xanmod_after_formal_commit_hook configure_xanmod_repository get_installed_xanmod_packages
    reset_xanmod_plan resolve_xanmod_plan show_xanmod_plan_result abort_xanmod_install_transaction
    complete_xanmod_install_transaction install_xanmod show_xanmod_status xanmod_lock_file_trusted
    take_xanmod_lock release_xanmod_lock run_locked_xanmod_plan
)
for function_name in "${common_functions[@]}"; do
    tool_body=$(env XANMOD_TEST_MODE=1 bash -c 'source "$1"; declare -f "$2"' _ "$TOOL" "$function_name")
    module_body=$(env XANMOD_TEST_MODE=1 bash -c 'source "$1"; declare -f "$2"' _ "$MODULE" "$function_name")
    assert_eq "$tool_body" "$module_body" "tool and module share $function_name contract"
done

assert_ok "standalone tool keeps dynamic safe codename policy" xanmod_codename_supported forky
module_policy=$(env XANMOD_TEST_MODE=1 bash -c 'source "$1"; if xanmod_codename_supported forky; then echo supported; else echo rejected; fi' _ "$MODULE")
assert_eq rejected "$module_policy" "module keeps original restricted codename policy"

(
    reset_tool_files
    printf 'VERSION_CODENAME=forky\n' > "$XANMOD_OS_RELEASE"
    dpkg() { echo amd64; }
    uname() { [[ ${1:-} == -m ]] && echo x86_64 || echo 6.1.0; }
    get_installed_xanmod_packages() { :; }
    package_is_installed() { return 1; }
    resolve_xanmod_plan
    assert_eq modify "$XANMOD_PLAN_ACTION" "standalone tool dynamically plans a safe forky repository probe"
)

(
    reset_tool_files
    gpg() { valid_colons; }
    printf valid > "$XANMOD_KEYRING"; chmod 0644 "$XANMOD_KEYRING"
    write_xanmod_deb822_source "$XANMOD_SOURCE_DEB822" https://deb.xanmod.org forky "$XANMOD_KEYRING"
    chmod 0644 "$XANMOD_SOURCE_DEB822"
    assert_ok "shared source parser accepts a syntactically safe dynamic codename" xanmod_deb822_source_configured
)

(
    reset_tool_files
    deb822="$TEST_DIR/tool/codename.sources"
    list="$TEST_DIR/tool/codename.list"
    write_xanmod_deb822_source "$deb822" https://deb.xanmod.org foo.bar "$XANMOD_KEYRING"
    assert_ok "Deb822 codename matches foo.bar exactly" xanmod_source_matches_codename "$deb822" foo.bar
    cat > "$deb822" <<EOF
Types: deb
URIs: https://deb.xanmod.org
Suites: fooXbar
Components: main
Signed-By: $XANMOD_KEYRING
EOF
    assert_fail "Deb822 expected foo.bar rejects fooXbar suite" xanmod_source_matches_codename "$deb822" foo.bar
    write_xanmod_deb822_source "$deb822" https://deb.xanmod.org foo+bar "$XANMOD_KEYRING"
    assert_ok "Deb822 codename matches foo+bar literally" xanmod_source_matches_codename "$deb822" foo+bar
    write_xanmod_deb822_source "$deb822" https://deb.xanmod.org fooooobar "$XANMOD_KEYRING"
    assert_fail "Deb822 foo+bar is not a regex quantifier" xanmod_source_matches_codename "$deb822" foo+bar

    printf 'deb [signed-by=%s] https://deb.xanmod.org foo.bar main\n' "$XANMOD_KEYRING" > "$list"
    assert_ok "legacy list codename matches foo.bar exactly" xanmod_source_matches_codename "$list" foo.bar
    assert_fail "legacy list foo.bar does not match fooXbar" xanmod_source_matches_codename "$list" fooXbar
    printf 'deb [signed-by=%s] https://deb.xanmod.org fooooobar main\n' "$XANMOD_KEYRING" > "$list"
    assert_fail "legacy list foo+bar is not a regex quantifier" xanmod_source_matches_codename "$list" foo+bar
)

grep -Fq '只读规划' "$ROOT_DIR/README.md" || fail "README omits read-only XanMod planning"
pass "README documents read-only planning before authorization"
grep -Fq 'root:root' "$ROOT_DIR/README.md" || fail "README omits production owner requirements"
pass "README documents production owner requirements"
grep -Fq 'SIGKILL' "$ROOT_DIR/README.md" || fail "README omits unhandleable SIGKILL risk"
pass "README documents SIGKILL limitation"
grep -Fq '不会自动卸载任何内核包' "$ROOT_DIR/README.md" || fail "README omits partial install warning"
pass "README documents no automatic kernel removal"

printf 'All XanMod tests passed.\n'
