#!/usr/bin/env bash
set -euo pipefail

readonly ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly TEST_DIR=$(mktemp -d)
readonly TEST_COMMIT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
trap 'rm -rf "$TEST_DIR"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }
assert_eq() {
    local expected="$1" actual="$2" name="$3"
    [[ "$actual" == "$expected" ]] || fail "$name: expected '$expected', got '$actual'"
    pass "$name"
}
assert_ok() { local name="$1"; shift; "$@" || fail "$name"; pass "$name"; }
assert_fail() { local name="$1"; shift; if "$@"; then fail "$name: unexpectedly succeeded"; fi; pass "$name"; }

mkdir -p "$TEST_DIR/etc/cloud" "$TEST_DIR/tmp"
export RUN_COMMIT="$TEST_COMMIT"
export LINUX_SETUP_TEST_MODE=1
export LINUX_SETUP_CACHE_DIR="$TEST_DIR/linux-setup"
export LINUX_SETUP_LOG_FILE="$TEST_DIR/linux-setup.log"
export LINUX_SETUP_SUMMARY_FILE="$TEST_DIR/deployment-summary.txt"
printf '127.0.0.1 localhost\n' > "$TEST_DIR/etc/hosts"
printf 'manage_etc_hosts: true\n' > "$TEST_DIR/etc/cloud/cloud.cfg"
export LINUX_SETUP_HOSTS_FILE="$TEST_DIR/etc/hosts"
export LINUX_SETUP_CLOUD_CONFIG_FILE="$TEST_DIR/etc/cloud/cloud.cfg"
# shellcheck source=../linux_setup.sh
source "$ROOT_DIR/linux_setup.sh"
TEMP_DIR="$TEST_DIR/tmp"
assert_eq 1 "$LINUX_SETUP_TEST_MODE" "explicit test mode is active"
assert_eq "$TEST_DIR/linux-setup" "$CACHE_DIR" "test mode enables cache override"
assert_eq "$TEST_DIR/linux-setup.log" "$LOG_FILE" "test mode enables log override"
assert_eq "$TEST_DIR/deployment-summary.txt" "$SUMMARY_FILE" "test mode enables summary override"
assert_eq "$TEST_DIR/etc/hosts" "$HOSTS_FILE" "test mode enables hosts override"
assert_eq "$TEST_DIR/etc/cloud/cloud.cfg" "$CLOUD_CONFIG_FILE" "test mode enables cloud override"
pass "path overrides require explicit test mode"
production_system_paths=$(env ROOT_DIR="$ROOT_DIR" LINUX_SETUP_TEST_MODE=0 LINUX_SETUP_HOSTS_FILE="$TEST_DIR/ignored-hosts" LINUX_SETUP_CLOUD_CONFIG_FILE="$TEST_DIR/ignored-cloud" bash -c 'source "$ROOT_DIR/linux_setup.sh"; printf "%s|%s\n" "$HOSTS_FILE" "$CLOUD_CONFIG_FILE"')
assert_eq '/etc/hosts|/etc/cloud/cloud.cfg' "$production_system_paths" "production mode ignores hosts and cloud overrides"
production_paths=$(env ROOT_DIR="$ROOT_DIR" LINUX_SETUP_TEST_MODE=0 \
    LINUX_SETUP_LOG_FILE="$TEST_DIR/ignored-log" \
    LINUX_SETUP_SUMMARY_FILE="$TEST_DIR/ignored-summary" \
    LINUX_SETUP_CACHE_DIR="$TEST_DIR/ignored-cache" \
    bash -c 'source "$ROOT_DIR/linux_setup.sh"; printf "%s|%s|%s\n" "$LOG_FILE" "$SUMMARY_FILE" "$CACHE_DIR"')
assert_eq '/var/log/linux-setup.log|/root/deployment_summary.txt|/var/cache/linux-setup' "$production_paths" "production mode ignores log, summary, and cache overrides"

! grep -Eq 'SCRIPT_COMMIT|LATEST_COMMIT' "$ROOT_DIR/linux_setup.sh" || fail "legacy commit variables remain"
grep -Fq 'module_url="$MODULE_BASE_URL/$RUN_COMMIT/modules/${module}.sh"' "$ROOT_DIR/linux_setup.sh" || fail "module download not pinned"
grep -Fq '"${MODULES_API_URL}?ref=${RUN_COMMIT}"' "$ROOT_DIR/linux_setup.sh" || fail "module discovery not pinned"
pass "pin main and modules to RUN_COMMIT"

assert_ok "accept lowercase 40-character commit" is_valid_commit "$TEST_COMMIT"
assert_fail "reject short commit" is_valid_commit abc123

original_get_latest=$(declare -f get_latest_commit)
get_latest_commit() { return 1; }
assert_ok "fixed version survives update-check outage" self_update >/dev/null
eval "$original_get_latest"

mkdir -p "$TEST_DIR/unknown/cache"
printf 'keep\n' > "$TEST_DIR/unknown/cache/sentinel"
rc=0
env -u RUN_COMMIT LINUX_SETUP_TEST_MODE=1 LINUX_SETUP_CACHE_DIR="$TEST_DIR/unknown/cache" LINUX_SETUP_LOG_FILE="$TEST_DIR/unknown/log" \
    bash "$ROOT_DIR/linux_setup.sh" --clean-cache --not-supported > "$TEST_DIR/unknown/output" 2>&1 || rc=$?
assert_eq 2 "$rc" "unknown argument returns usage error"
[[ -f "$TEST_DIR/unknown/cache/sentinel" ]] || fail "unknown argument performed cleanup"
grep -Fq '未知参数：--not-supported' "$TEST_DIR/unknown/output" || fail "unknown error missing"
pass "reject unknown argument before side effects"


mkdir -p "$TEST_DIR/clean/safe"
env ROOT_DIR="$ROOT_DIR" LINUX_SETUP_TEST_MODE=1 \
    LINUX_SETUP_CACHE_DIR="$TEST_DIR/clean/safe/linux-setup" \
    LINUX_SETUP_LOG_FILE="$TEST_DIR/clean/safe.log" \
    bash -c 'source "$ROOT_DIR/linux_setup.sh"; prepare_cache_dir'
[[ -f "$TEST_DIR/clean/safe/linux-setup/.linux-setup-managed-cache-v1" ]] || fail "managed cache marker missing"
printf 'keep\n' > "$TEST_DIR/clean/safe/linux-setup/sentinel"
env -u RUN_COMMIT LINUX_SETUP_TEST_MODE=1 \
    LINUX_SETUP_CACHE_DIR="$TEST_DIR/clean/safe/linux-setup" \
    LINUX_SETUP_LOG_FILE="$TEST_DIR/clean/safe.log" \
    bash "$ROOT_DIR/linux_setup.sh" --clean-cache >/dev/null
[[ ! -e "$TEST_DIR/clean/safe/linux-setup" ]] || fail "managed cache was not removed"
pass "clean-cache accepts safe managed directory"


mkdir -p "$TEST_DIR/clean/unmarked/linux-setup"
printf 'keep\n' > "$TEST_DIR/clean/unmarked/linux-setup/sentinel"
rc=0
env -u RUN_COMMIT LINUX_SETUP_TEST_MODE=1 \
    LINUX_SETUP_CACHE_DIR="$TEST_DIR/clean/unmarked/linux-setup" \
    LINUX_SETUP_LOG_FILE="$TEST_DIR/clean/unmarked.log" \
    bash "$ROOT_DIR/linux_setup.sh" --clean-cache >/dev/null 2>&1 || rc=$?
assert_eq 1 "$rc" "clean-cache rejects unmarked directory"
[[ -f "$TEST_DIR/clean/unmarked/linux-setup/sentinel" ]] || fail "unmarked cache target was modified"

mkdir -p "$TEST_DIR/clean/unsafe/cache"
printf 'keep\n' > "$TEST_DIR/clean/unsafe/cache/sentinel"
rc=0
env -u RUN_COMMIT LINUX_SETUP_TEST_MODE=1 \
    LINUX_SETUP_CACHE_DIR="$TEST_DIR/clean/unsafe/cache" \
    LINUX_SETUP_LOG_FILE="$TEST_DIR/clean/unsafe.log" \
    bash "$ROOT_DIR/linux_setup.sh" --clean-cache >/dev/null 2>&1 || rc=$?
assert_eq 1 "$rc" "clean-cache rejects unmanaged directory name"
[[ -f "$TEST_DIR/clean/unsafe/cache/sentinel" ]] || fail "unsafe cache target was modified"

mkdir -p "$TEST_DIR/clean/link-target" "$TEST_DIR/clean/link-parent"
printf 'keep\n' > "$TEST_DIR/clean/link-target/sentinel"
ln -s "$TEST_DIR/clean/link-target" "$TEST_DIR/clean/link-parent/linux-setup"
rc=0
env -u RUN_COMMIT LINUX_SETUP_TEST_MODE=1 \
    LINUX_SETUP_CACHE_DIR="$TEST_DIR/clean/link-parent/linux-setup" \
    LINUX_SETUP_LOG_FILE="$TEST_DIR/clean/link.log" \
    bash "$ROOT_DIR/linux_setup.sh" --clean-cache >/dev/null 2>&1 || rc=$?
assert_eq 1 "$rc" "clean-cache rejects symlink target"
[[ -f "$TEST_DIR/clean/link-target/sentinel" ]] || fail "symlink cache target was modified"
pass "clean-cache validates managed target"

rc=0
env RUN_COMMIT=invalid LINUX_SETUP_TEST_MODE=1 LINUX_SETUP_CACHE_DIR="$TEST_DIR/invalid-cache" LINUX_SETUP_LOG_FILE="$TEST_DIR/invalid-log" \
    bash "$ROOT_DIR/linux_setup.sh" > "$TEST_DIR/invalid-output" 2>&1 || rc=$?
assert_eq 2 "$rc" "invalid RUN_COMMIT is rejected"
[[ ! -e "$TEST_DIR/invalid-cache" ]] || fail "invalid commit reached cache setup"

rc=0
env -u RUN_COMMIT LINUX_SETUP_TEST_MODE=1 LINUX_SETUP_CACHE_DIR="$TEST_DIR/unproven-cache" LINUX_SETUP_LOG_FILE=/dev/null ROOT_DIR="$ROOT_DIR" \
    bash -c 'source "$ROOT_DIR/linux_setup.sh"; get_latest_commit() { return 1; }; self_update' >/dev/null 2>&1 || rc=$?
assert_eq 1 "$rc" "unproven script version is rejected"

export module_output="$TEST_DIR/module-commit"
cat > "$TEST_DIR/module-ok.sh" <<'MODULE'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$RUN_COMMIT" > "$module_output"
MODULE
chmod 700 "$TEST_DIR/module-ok.sh"
MODULE_FILES[probe]="$TEST_DIR/module-ok.sh"
assert_ok "execute fixed module" execute_module probe >/dev/null
assert_eq "$TEST_COMMIT" "$(cat "$module_output")" "module receives RUN_COMMIT"

cat > "$TEST_DIR/module-fail.sh" <<'MODULE'
#!/usr/bin/env bash
exit 9
MODULE
chmod 700 "$TEST_DIR/module-fail.sh"
MODULE_FILES[broken]="$TEST_DIR/module-fail.sh"
assert_fail "failed module propagates failure" execute_module broken >/dev/null
assert_eq failed "${MODULE_STATUS[broken]}" "record failed module"
generate_summary() { :; }
show_recommendations() { :; }
MODULE_STATUS=([ok]=success [broken]=failed)
assert_fail "deployment returns nonzero after module failure" finish_deployment
MODULE_STATUS=([ok]=success [partial]=degraded)
assert_ok "degraded module remains nonfatal" finish_deployment

cat > "$TEST_DIR/cloud-indented.in" <<'YAML'
cloud_init:
  preserve: true
  manage_etc_hosts: true
  manage_etc_hosts: false
next: value
YAML
cat > "$TEST_DIR/cloud-indented.expected" <<'YAML'
cloud_init:
  preserve: true
  manage_etc_hosts: false
next: value
YAML
render_cloud_config "$TEST_DIR/cloud-indented.in" "$TEST_DIR/cloud-indented.out"
cmp -s "$TEST_DIR/cloud-indented.expected" "$TEST_DIR/cloud-indented.out" ||
    fail "indented cloud config was not preserved as valid YAML"
pass "preserve indentation and deduplicate cloud YAML key"

hostname() { printf '%s\n' 'safe-host.example'; }
printf 'preserve: value\nmanage_etc_hosts: true\nmanage_etc_hosts: true\n' > "$CLOUD_CONFIG_FILE"
printf '127.0.0.1 localhost\n127.0.1.1 old-alias   # safe-host.example comment-only\n' > "$HOSTS_FILE"
assert_ok "hardened hosts repair" fix_hosts_file >/dev/null
assert_eq 1 "$(grep -Fxc 'manage_etc_hosts: false' "$CLOUD_CONFIG_FILE")" "deduplicate cloud setting"
grep -Fxq '127.0.1.1 old-alias safe-host.example   # safe-host.example comment-only' "$HOSTS_FILE" || fail "inline hosts comment was not preserved"
assert_ok "hostname is found before inline comment" hosts_contains_hostname "$HOSTS_FILE" safe-host.example
pass "insert hostname before inline comment"
[[ -f "${HOSTS_FILE}.initial-backup" && -f "${HOSTS_FILE}.previous-backup" ]] || fail "hosts backups missing"
pass "preserve host aliases and backups"

before=$(sha256sum "$HOSTS_FILE" | awk '{print $1}')
assert_ok "idempotent hosts repair" fix_hosts_file >/dev/null
assert_eq "$before" "$(sha256sum "$HOSTS_FILE" | awk '{print $1}')" "idempotent hosts content"
hostname() { printf '%s\n' 'bad[host'; }
assert_fail "unsafe hostname rejected" fix_hosts_file >/dev/null 2>&1
assert_eq "$before" "$(sha256sum "$HOSTS_FILE" | awk '{print $1}')" "unsafe hostname performs no write"

hostname() { printf '%s\n' 'safe-host.example'; }
rm -f "$HOSTS_FILE" "${HOSTS_FILE}.initial-backup" "${HOSTS_FILE}.previous-backup"
printf '127.0.0.1 protected\n' > "$TEST_DIR/hosts-target"
ln -s "$TEST_DIR/hosts-target" "$HOSTS_FILE"
assert_fail "symlink hosts rejected" fix_hosts_file >/dev/null 2>&1
grep -Fxq '127.0.0.1 protected' "$TEST_DIR/hosts-target" || fail "symlink target modified"
pass "protect symlink target"

rm -f "$HOSTS_FILE"
printf '127.0.0.1 localhost\n' > "$HOSTS_FILE"
printf 'manage_etc_hosts: true\n' > "$CLOUD_CONFIG_FILE"
rm -f "${HOSTS_FILE}.initial-backup" "${HOSTS_FILE}.previous-backup" \
    "${CLOUD_CONFIG_FILE}.initial-backup" "${CLOUD_CONFIG_FILE}.previous-backup"
eval "$(declare -f atomic_replace_file | sed '1s/atomic_replace_file/original_atomic_replace_file/')"
atomic_replace_file() {
    [[ "$2" == "$HOSTS_FILE" ]] && return 1
    original_atomic_replace_file "$@"
}
assert_fail "hosts write failure propagates" fix_hosts_file >/dev/null 2>&1
grep -Fxq 'manage_etc_hosts: true' "$CLOUD_CONFIG_FILE" || fail "cloud config rollback failed"
pass "rollback cloud config after hosts failure"
unset -f atomic_replace_file
eval "$(declare -f original_atomic_replace_file | sed '1s/original_atomic_replace_file/atomic_replace_file/')"

rm -rf "$CACHE_DIR"
assert_ok "atomically cache validated script" write_cached_script_atomically "$ROOT_DIR/linux_setup.sh" "$TEST_COMMIT"
cached="$CACHE_DIR/linux_setup_${TEST_COMMIT}.sh"
digest="${cached}.sha256"
assert_ok "validate fresh cache" validate_cached_script "$cached" "$TEST_COMMIT"
assert_eq 700 "$(stat -c %a "$cached")" "cached script mode"
assert_eq 600 "$(stat -c %a "$digest")" "cached digest mode"
if find "$CACHE_DIR" -maxdepth 1 -name '.linux_setup_*' | grep -q .; then fail "cache stages remain"; fi
pass "atomic cache leaves no stage"

printf '# tampered\n' >> "$cached"
assert_fail "tampered cache rejected" validate_cached_script "$cached" "$TEST_COMMIT"
assert_fail "tampered cache not loaded" load_cached_script "$TEST_COMMIT" >/dev/null 2>&1
[[ ! -e "$cached" && ! -e "$digest" ]] || fail "tampered cache not removed"
pass "remove invalid cache"

assert_ok "recreate cache" write_cached_script_atomically "$ROOT_DIR/linux_setup.sh" "$TEST_COMMIT"
chmod 0777 "$cached"
assert_fail "writable cache rejected" validate_cached_script "$cached" "$TEST_COMMIT"
remove_cached_script "$cached"
ln -s "$ROOT_DIR/linux_setup.sh" "$cached"
printf '%s\n' "$(sha256sum "$ROOT_DIR/linux_setup.sh" | awk '{print $1}')" > "$digest"
chmod 0600 "$digest"
assert_fail "symlink cache rejected" validate_cached_script "$cached" "$TEST_COMMIT"

printf '#!/usr/bin/env bash\nif then\n' > "$TEST_DIR/invalid.sh"
assert_fail "invalid cached syntax rejected" validate_bash_script "$TEST_DIR/invalid.sh"
writer=$(declare -f write_cached_script_atomically)
grep -Fq 'mktemp "$CACHE_DIR/.linux_setup_' <<< "$writer" || fail "cache lacks same-dir stage"
grep -Fq 'mv -fT -- "$script_stage" "$cached_script"' <<< "$writer" || fail "cache lacks atomic rename"
pass "cache uses same-directory atomic rename"

rm -f "$cached" "$digest"
rm -rf "$CACHE_DIR"
mkdir "$TEST_DIR/cache-target"
ln -s "$TEST_DIR/cache-target" "$CACHE_DIR"
assert_fail "symlink cache directory rejected" prepare_cache_dir >/dev/null 2>&1

grep -Fq 'readonly RUN_COMMIT="${RUN_COMMIT:-}"' "$ROOT_DIR/modules/zsh-setup.sh" || fail "zsh RUN_COMMIT missing"
grep -Fq 'Linux/${repository_ref}/p10k-config.zsh' "$ROOT_DIR/modules/zsh-setup.sh" || fail "theme URL not pinned"
pass "pin repository module resource"

printf 'All linux_setup integrity tests passed.\n'
