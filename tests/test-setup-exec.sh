#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
unset GH_TOKEN GITHUB_TOKEN SSH_PRIVATE_KEY_B64
export ROOT_DIR LINUX_SETUP_TEST_MODE=1 LINUX_SETUP_LOG_FILE="$root/log"
export FIXTURE_ROOT="$root" COMMIT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
cat > "$root/replacement.sh" <<'CHILD'
#!/usr/bin/env bash
set -eu
[[ "$RUN_COMMIT" == "$COMMIT" && ! -e "$OLD_TEMP" ]]
# The replacement can read its unlinked script through its inherited FD.
[[ -r "$0" ]]
printf '%s\n' "$0" > "$CASE_ROOT/executed"
mkdir "$CASE_ROOT/new-runtime"
printf keep > "$CASE_ROOT/new-runtime/sentinel"
exit 0
CHILD
cat > "$root/driver.sh" <<'DRIVER'
#!/usr/bin/env bash
set -uo pipefail
source "$ROOT_DIR/linux_setup.sh"
# Keep allocations inside the inert fixture, exercising the real allocator.
mktemp() {
    if [[ ${1:-} == -d && ${2:-} == -p && ${3:-} == /tmp ]]; then
        command mktemp -d -p "$CASE_ROOT" "${4}"
    else
        command mktemp "$@"
    fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
create_temp_dir || exit 90
export OLD_TEMP="$TEMP_DIR"
printf '%s\n' "$TEMP_DIR" > "$CASE_ROOT/old-path"
if [[ "$CASE_MODE" == cache ]]; then
    write_cached_script_atomically "$FIXTURE_ROOT/replacement.sh" "$COMMIT" || exit 91
else
    cp "$FIXTURE_ROOT/replacement.sh" "$TEMP_DIR/replacement.sh"
    chmod 700 "$TEMP_DIR/replacement.sh"
    PREPARED_SCRIPT="$TEMP_DIR/replacement.sh"
fi
case "$CASE_MODE" in
    remove-fail) rm() { return 1; } ;;
    replace-dir)
        mv "$TEMP_DIR" "$CASE_ROOT/original"
        mkdir -m 700 "$TEMP_DIR"; printf keep > "$TEMP_DIR/sentinel"
        ;;
    symlink-dir)
        mv "$TEMP_DIR" "$CASE_ROOT/original"
        mkdir "$CASE_ROOT/foreign"; printf keep > "$CASE_ROOT/foreign/sentinel"
        ln -s "$CASE_ROOT/foreign" "$TEMP_DIR"
        ;;
    exec-fail)
        # Real exec failure: remove PATH only after inode validation/cleanup.
        log() { if [[ "$1" == *重新启动* ]]; then PATH=/nonexistent; fi; }
        ;;
    HUP|INT|TERM)
        kill -s "$CASE_MODE" "$BASHPID"
        exit 92
        ;;
esac
exec_prepared_script "$COMMIT"
status=$?
printf '%s\n' "$status" > "$CASE_ROOT/returned"
exit "$status"
DRIVER
for mode in cache fallback remove-fail replace-dir symlink-dir exec-fail HUP INT TERM; do
    case_root="$root/$mode"; mkdir "$case_root"
    rc=0
    env --default-signal=HUP,INT,TERM -u RUN_COMMIT CASE_MODE="$mode" CASE_ROOT="$case_root" \
        LINUX_SETUP_CACHE_DIR="$case_root/linux-setup" \
        timeout --signal=TERM --kill-after=1s 10s bash "$root/driver.sh" > "$case_root/output" 2>&1 || rc=$?
    old=$(cat "$case_root/old-path")
    case "$mode" in
        cache|fallback)
            [[ $rc == 0 && ! -e "$old" && -f "$case_root/executed" && -f "$case_root/new-runtime/sentinel" ]] || { cat "$case_root/output"; exit 1; }
            [[ ! -e "$case_root/returned" ]]
            ;;
        exec-fail)
            [[ $rc == 127 && ! -e "$old" && ! -e "$case_root/executed" && $(cat "$case_root/returned") == 127 ]] || { cat "$case_root/output"; exit 1; }
            ;;
        remove-fail)
            [[ $rc == 1 && -d "$old" && ! -e "$case_root/executed" ]] ;;
        replace-dir)
            [[ $rc == 1 && -f "$old/sentinel" && -f "$case_root/original/replacement.sh" ]] ;;
        symlink-dir)
            [[ $rc == 1 && -L "$old" && -f "$case_root/foreign/sentinel" ]] ;;
        HUP) [[ $rc == 129 && -d "$old" ]] ;;
        INT) [[ $rc == 130 && -d "$old" ]] ;;
        TERM) [[ $rc == 143 && -d "$old" ]] ;;
    esac
    printf 'PASS: prepared exec lifecycle %s exit=%s\n' "$mode" "$rc"
done
# Exercise actual main -> self_update -> prepare_main_script -> exec path.
# Only network and production system steps are replaced; no function wrapping.
for source_mode in cache download; do
    case_root="$root/main-$source_mode"; mkdir "$case_root"
    env -u RUN_COMMIT CASE_ROOT="$case_root" SOURCE_MODE="$source_mode" \
        LINUX_SETUP_CACHE_DIR="$case_root/linux-setup" \
        timeout --signal=TERM --kill-after=1s 10s bash -c '
        source "$ROOT_DIR/linux_setup.sh"
        mktemp() {
            if [[ ${1:-} == -d && ${2:-} == -p && ${3:-} == /tmp ]]; then
                command mktemp -d -p "$CASE_ROOT" "${4}"
            else command mktemp "$@"; fi
        }
        get_latest_commit() { printf "%s\n" "$COMMIT"; }
        pre_check() { exit 93; }
        clear() { :; }
        download_with_retry() {
            cp "$FIXTURE_ROOT/replacement.sh" "$2" || return 1
            export OLD_TEMP="$TEMP_DIR"
        }
        if [[ "$SOURCE_MODE" == cache ]]; then
            write_cached_script_atomically "$FIXTURE_ROOT/replacement.sh" "$COMMIT" || exit 94
            # No TEMP_DIR is known before main allocates it: replacement checks
            # the fixture for leaked allocator paths directly in this case.
            export OLD_TEMP="$CASE_ROOT/nonexistent"
        else
            prepare_cache_dir() { return 1; }
        fi
        main
        ' > "$case_root/output" 2>&1 || { cat "$case_root/output"; exit 1; }
    [[ -f "$case_root/executed" ]]
    [[ -z $(find "$case_root" -maxdepth 1 -name 'linux-setup.*' -print -quit) ]]
    printf 'PASS: actual main self-update %s path\n' "$source_mode"
done
# A bounded counterexample demonstrates why the old successful exec leaked.
case_root="$root/old-exec"; mkdir "$case_root"
env CASE_ROOT="$case_root" timeout 5s bash -c '
    old=$(mktemp -d "$CASE_ROOT/linux-setup.XXXXXX")
    printf "%s\n" "$old" > "$CASE_ROOT/path"
    trap '\''rm -rf -- "$old"'\'' EXIT
    exec bash -c '\''exit 0'\''
'
[[ -d $(cat "$case_root/path") ]]
printf 'PASS: old successful exec bypasses EXIT cleanup counterexample\n'
# Existing fixed versions exercise both the consent and refusal branches.
for choice in y n; do
    case_root="$root/update-$choice"; mkdir "$case_root"
    env CASE_ROOT="$case_root" CHOICE="$choice" RUN_COMMIT=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
        LINUX_SETUP_CACHE_DIR="$case_root/linux-setup" timeout 10s bash -c '
        source "$ROOT_DIR/linux_setup.sh"
        mktemp() {
            if [[ ${1:-} == -d && ${2:-} == -p && ${3:-} == /tmp ]]; then
                command mktemp -d -p "$CASE_ROOT" "${4}"
            else command mktemp "$@"; fi
        }
        create_temp_dir || exit 90
        trap cleanup EXIT
        export OLD_TEMP="$TEMP_DIR"
        get_latest_commit() { printf "%s\n" "$COMMIT"; }
        write_cached_script_atomically "$FIXTURE_ROOT/replacement.sh" "$COMMIT" || exit 91
        self_update <<< "$CHOICE"
        status=$?
        [[ "$CHOICE" == n && $status == 0 && -d "$TEMP_DIR" ]] || exit 92
        printf retained > "$CASE_ROOT/refused"
        ' > "$case_root/output" 2>&1 || { cat "$case_root/output"; exit 1; }
    [[ -z $(find "$case_root" -maxdepth 1 -name 'linux-setup.*' -print -quit) ]]
    if [[ $choice == y ]]; then [[ -f "$case_root/executed" ]]; else [[ -f "$case_root/refused" && ! -e "$case_root/executed" ]]; fi
    printf 'PASS: fixed-version self-update choice=%s\n' "$choice"
done
