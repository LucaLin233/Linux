#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly ROOT_DIR
TEMP_DIR=$(mktemp -d)
readonly TEMP_DIR
trap 'rm -rf "$TEMP_DIR"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_eq() {
    local expected="$1" actual="$2" name="$3"
    [[ "$actual" == "$expected" ]] || fail "$name: expected '$expected', got '$actual'"
    printf 'PASS: %s\n' "$name"
}

assert_ok() {
    local name="$1"
    shift
    "$@" || fail "$name"
    printf 'PASS: %s\n' "$name"
}

assert_fail() {
    local name="$1"
    shift
    if "$@"; then
        fail "$name: command unexpectedly succeeded"
    fi
    printf 'PASS: %s\n' "$name"
}

# --- apply -> backup/restore 全路径（测试侧常量副本，置换首次 source）---
# 只精确替换 SSH_CONFIG / SSH_PREVIOUS_BACKUP / SSH_INITIAL_BACKUP 三条完整声明，
# 其余字节不变；备份、install、chmod、rm 仍是真实文件操作，仅 mock systemctl/sshd/ss/sleep。
TEST_ROOT="$TEMP_DIR/apply"
mkdir -p "$TEST_ROOT/etc/ssh" "$TEST_ROOT/root/.ssh"
MODULE_COPY="$TEST_ROOT/ssh-security.sh"

text_count() {
    local hay="$1" needle="$2" n=0 rest="$hay"
    while [[ "$rest" == *"$needle"* ]]; do
        n=$((n + 1))
        rest=${rest#*"$needle"}
    done
    printf '%s' "$n"
}

require_single() {
    local hay="$1" needle="$2" label="$3" n
    n=$(text_count "$hay" "$needle")
    [[ "$n" == 1 ]] || fail "$label: expected exactly one declaration, got $n"
}

module_text=$(cat "$ROOT_DIR/modules/ssh-security.sh")
require_single "$module_text" 'readonly SSH_CONFIG="/etc/ssh/sshd_config"' SSH_CONFIG
require_single "$module_text" 'readonly SSH_PREVIOUS_BACKUP="/etc/ssh/sshd_config.previous-backup"' SSH_PREVIOUS_BACKUP
require_single "$module_text" 'readonly SSH_INITIAL_BACKUP="/etc/ssh/sshd_config.initial-backup"' SSH_INITIAL_BACKUP
printf -v replacement 'readonly SSH_CONFIG=%q' \
    "$TEST_ROOT/etc/ssh/sshd_config"
module_text=${module_text/'readonly SSH_CONFIG="/etc/ssh/sshd_config"'/"$replacement"}

printf -v replacement 'readonly SSH_PREVIOUS_BACKUP=%q' \
    "$TEST_ROOT/etc/ssh/sshd_config.previous-backup"
module_text=${module_text/'readonly SSH_PREVIOUS_BACKUP="/etc/ssh/sshd_config.previous-backup"'/"$replacement"}

printf -v replacement 'readonly SSH_INITIAL_BACKUP=%q' \
    "$TEST_ROOT/etc/ssh/sshd_config.initial-backup"
module_text=${module_text/'readonly SSH_INITIAL_BACKUP="/etc/ssh/sshd_config.initial-backup"'/"$replacement"}
unset replacement
printf '%s\n' "$module_text" > "$MODULE_COPY"
unset module_text


# shellcheck source=/dev/null
source "$MODULE_COPY"
[[ "$SSH_CONFIG" == "$TEST_ROOT/etc/ssh/sshd_config" ]] || fail "SSH_CONFIG was not redirected"
[[ "$SSH_PREVIOUS_BACKUP" == "$TEST_ROOT/etc/ssh/sshd_config.previous-backup" ]] || fail "previous backup was not redirected"
[[ "$SSH_INITIAL_BACKUP" == "$TEST_ROOT/etc/ssh/sshd_config.initial-backup" ]] || fail "initial backup was not redirected"
printf 'PASS: test copy keeps only the three path constants redirected\n'

SSHD_OUTPUT=''
sshd() {
    printf '%s\n' "$SSHD_OUTPUT"
}

SSHD_OUTPUT=$'listenaddress 10.0.0.5:22\nlistenaddress [2001:db8::5]:2222'
assert_eq $'10.0.0.5\n2001:db8::5' "$(get_effective_listen_addresses)" \
    "strip ports while preserving restricted IPv4 and IPv6 addresses"

SSHD_OUTPUT=$'listenaddress 0.0.0.0:22\nlistenaddress [::]:22'
assert_eq $'0.0.0.0\n::' "$(get_effective_listen_addresses)" \
    "preserve wildcard scope when it was already effective"

run_locale_case() {
    local locale_name="$1" output
    if ! locale -a 2>/dev/null | grep -Fqx "$locale_name"; then
        printf 'SKIP: locale %s is unavailable\n' "$locale_name"
        return 0
    fi
    output=$(LC_ALL="$locale_name" SSHD_OUTPUT=$'listenaddress [::]:22\nlistenaddress 0.0.0.0:22\nlistenaddress [::]:2222\nlistenaddress 0.0.0.0:2222' \
        bash -c '
            sshd() { printf "%s\n" "$SSHD_OUTPUT"; }
            source "$1"
            get_effective_listen_addresses
        ' _ "$ROOT_DIR/modules/ssh-security.sh") ||
        fail "locale $locale_name invocation failed"
    assert_eq $'0.0.0.0\n::' "$output" "stable deduplicated wildcard ordering under locale $locale_name"
}

run_locale_case C
non_c_locale=$(locale -a 2>/dev/null | grep -Ev '^(C|C\.utf8|POSIX)$' | head -n 1 || true)
if [[ -n "$non_c_locale" ]]; then
    run_locale_case "$non_c_locale"
else
    printf 'SKIP: no non-C locale is available\n'
fi

CONFIG_FIXTURE="$TEMP_DIR/sshd_config"
mktemp() {
    printf '%s\n' "$CONFIG_FIXTURE"
}
restricted_addresses=$'10.0.0.5\n2001:db8::5'
created=$(create_temp_ssh_config $'22\n2222' no prohibit-password "$restricted_addresses")
assert_eq "$CONFIG_FIXTURE" "$created" "create SSH configuration in temporary file"
grep -Fqx 'ListenAddress 10.0.0.5' "$CONFIG_FIXTURE" || fail "restricted IPv4 address was not rendered"
grep -Fqx 'ListenAddress 2001:db8::5' "$CONFIG_FIXTURE" || fail "restricted IPv6 address was not rendered"
if grep -Fqx 'ListenAddress 0.0.0.0' "$CONFIG_FIXTURE" || grep -Fqx 'ListenAddress ::' "$CONFIG_FIXTURE"; then
    fail "restricted configuration was widened to wildcard addresses"
fi
printf 'PASS: generated configuration does not widen ListenAddress\n'

SSHD_OUTPUT=$'port 22\nport 2222\nlistenaddress 10.0.0.5:22\nlistenaddress [2001:db8::5]:2222\npermitrootlogin prohibit-password\npasswordauthentication no\nkbdinteractiveauthentication no\npubkeyauthentication yes\nallowtcpforwarding yes'
assert_ok "verify restricted effective SSH settings" verify_effective_settings \
    "$CONFIG_FIXTURE" $'22\n2222' no prohibit-password "$restricted_addresses"

SSHD_OUTPUT=$'port 22\nport 2222\nlistenaddress 0.0.0.0:22\nlistenaddress [::]:22\npermitrootlogin prohibit-password\npasswordauthentication no\nkbdinteractiveauthentication no\npubkeyauthentication yes\nallowtcpforwarding yes'
assert_fail "reject widened effective SSH listen scope" verify_effective_settings \
    "$CONFIG_FIXTURE" $'22\n2222' no prohibit-password "$restricted_addresses"

# --- seam 级：运行模式与调用顺序（CALL_LOG 文件跨命令替换持久）---
# 生产的模式探测与 reload 都在 $( ) 内执行，数组记录会丢失在子 shell；统一写
# $TEST_ROOT/calls.log，再由 call_sequence 读回。
call_sequence() {
    local seq='' line
    while IFS= read -r line; do
        [[ -z "$seq" ]] && seq="$line" || seq="$seq|$line"
    done < "$TEST_ROOT/calls.log"
    printf '%s' "$seq"
}

systemctl() {
    printf '%s\n' "$*" >> "$TEST_ROOT/calls.log"
    case "$*" in
        "is-active --quiet ssh.socket") [[ "$SOCKET_STATE" == active ]] ;;
        "is-active --quiet ssh") return 1 ;;
        daemon-reload) return "$DAEMON_RELOAD_RC" ;;
        "restart ssh.socket"|"reload ssh") return 0 ;;
        *) fail "unexpected systemctl command: $*" ;;
    esac
}

# Ubuntu socket activation: ports only move after the generator reruns and the
# socket restarts; a plain sshd reload would keep the old listener.
: > "$TEST_ROOT/calls.log"
SOCKET_STATE=active
DAEMON_RELOAD_RC=0
reload_ssh_runtime ssh
assert_eq "is-active --quiet ssh.socket|daemon-reload|restart ssh.socket" \
    "$(call_sequence)" "socket activation regenerates and restarts ssh.socket"
assert_ok "socket activation counts as a running SSH service" ssh_runtime_active ssh

: > "$TEST_ROOT/calls.log"
SOCKET_STATE=inactive
reload_ssh_runtime ssh
assert_eq "is-active --quiet ssh.socket|reload ssh" \
    "$(call_sequence)" "classic service mode keeps reloading sshd"
assert_fail "inactive service without socket is not running" ssh_runtime_active ssh

# --- 回滚沿用 apply 前固定的运行模式（seam 级）---
: > "$TEST_ROOT/calls.log"
SOCKET_STATE=inactive
DAEMON_RELOAD_RC=0
assert_ok "pinned socket mode reloads the socket even when it is already down" \
    reload_ssh_runtime ssh socket
assert_eq "daemon-reload|restart ssh.socket" "$(call_sequence)" \
    "pinned socket mode keeps the socket path"
: > "$TEST_ROOT/calls.log"
SOCKET_STATE=active
assert_ok "pinned service mode ignores an active socket" reload_ssh_runtime ssh service
assert_eq "reload ssh" "$(call_sequence)" "pinned service mode keeps reloading sshd"
: > "$TEST_ROOT/calls.log"
DAEMON_RELOAD_RC=1
assert_fail "socket generator failure is reported as a failure" \
    reload_ssh_runtime ssh socket
assert_eq "daemon-reload" "$(call_sequence)" \
    "failed generator neither redetects mode nor restarts socket"
DAEMON_RELOAD_RC=0


# systemctl 记录写入 CALL_LOG：生产 detect_ssh_runtime_mode 在 $( ) 子 shell 内运行，
# 数组记录会丢失；文件可跨命令替换持久观察，且不删除任何预期记录。
reset_runtime() {
    SOCKET_STATE="$1"
    SERVICE_ACTIVE="$2"
    SOCKET_RESTART_PLAN="$3"
    DAEMON_RELOAD_PLAN="$4"
    SERVICE_RELOAD_RC="${5:-1}"
    GENERATED_CONFIG=''
    LISTENING=''
    : > "$TEST_ROOT/calls.log"
    printf '0\n' > "$TEST_ROOT/socket_restarts"
    printf '0\n' > "$TEST_ROOT/daemon_reloads"
}

count_calls() {
    local want="$1" total=0 line
    while IFS= read -r line; do
        [[ "$line" == "$want" ]] && total=$((total + 1))
    done < "$TEST_ROOT/calls.log"
    printf '%s' "$total"
}


install_runtime_mocks() {
    systemctl() {
        printf '%s\n' "$*" >> "$TEST_ROOT/calls.log"
        case "$*" in
            "is-active --quiet ssh.socket") [[ "$SOCKET_STATE" == active ]] ;;
            "is-active --quiet ssh") [[ "$SERVICE_ACTIVE" == active ]] ;;
            daemon-reload)
                local n rc
                n=$(cat "$TEST_ROOT/daemon_reloads")
                rc=${DAEMON_RELOAD_PLAN:$((n * 2)):1}
                printf '%s\n' "$((n + 1))" > "$TEST_ROOT/daemon_reloads"
                if [[ "$rc" == 0 ]]; then
                    GENERATED_CONFIG=$(cat "$SSH_CONFIG")
                fi
                return "${rc:-1}"
                ;;
            "restart ssh.socket")
                local n rc
                n=$(cat "$TEST_ROOT/socket_restarts")
                rc=${SOCKET_RESTART_PLAN:$((n * 2)):1}
                printf '%s\n' "$((n + 1))" > "$TEST_ROOT/socket_restarts"
                if [[ "$rc" == 0 ]]; then
                    LISTENING="$GENERATED_CONFIG"
                    SOCKET_STATE=active
                else
                    LISTENING=''
                    SOCKET_STATE=inactive
                fi
                return "${rc:-1}"
                ;;
            reload\ ssh)
                if [[ "$SERVICE_RELOAD_RC" == 0 ]]; then
                    LISTENING=$(cat "$SSH_CONFIG")
                fi
                return "$SERVICE_RELOAD_RC"
                ;;
            *) printf 'unknown systemctl %s\n' "$*" >> "$TEST_ROOT/unknown.log"; return 99 ;;
        esac
    }
    sshd() {
        if [[ $# -eq 3 && "$1" == -t && "$2" == -f && "$3" == "$SSH_CONFIG" ]]; then
            return 0
        fi
        printf 'unknown sshd %s\n' "$*" >> "$TEST_ROOT/unknown.log"
        return 99
    }
    ss() {
        if [[ $# -ne 1 || "$1" != -ltnH ]]; then
            printf 'unknown ss %s\n' "$*" >> "$TEST_ROOT/unknown.log"
            return 99
        fi
        printf '%s\n' "$*" >> "$TEST_ROOT/ss.calls"
        local line port
        while IFS= read -r line; do
            case "$line" in
                'Port '*)
                    port=${line#Port }
                    printf 'LISTEN 0 128 [::]:%s [::]:*\n' "$port"
                    ;;
            esac
        done <<< "$LISTENING"
    }
    sleep() {
        if [[ $# -eq 1 && "$1" == 1 ]]; then return 0; fi
        printf 'unknown sleep %s\n' "$*" >> "$TEST_ROOT/unknown.log"
        return 99
    }
}

run_apply_case() {
    local name="$1"
    : > "$TEST_ROOT/unknown.log"
    : > "$TEST_ROOT/ss.calls"
    printf 'Port 22\nListenAddress 0.0.0.0\n' > "$SSH_CONFIG"
    cp -a "$SSH_CONFIG" "$TEST_ROOT/live.before"
    rm -f "$SSH_PREVIOUS_BACKUP" "$SSH_INITIAL_BACKUP"
    printf 'Port 2222\nListenAddress 0.0.0.0\n' > "$TEST_ROOT/next.conf"
    cp -a "$TEST_ROOT/next.conf" "$TEST_ROOT/next.expected"
    local rc=0
    apply_ssh_config "$TEST_ROOT/next.conf" ssh 2222 > "$TEST_ROOT/out.log" 2>&1 || rc=$?
    printf '%s\n' "$rc" > "$TEST_ROOT/rc"
}

assert_no_unknown() {
    [[ -s "$TEST_ROOT/unknown.log" ]] && fail "$1: unexpected systemctl command recorded"
    return 0
}

# 用例1：socket 初活跃，首次 restart 失败，回滚时 generator 与 socket 恢复成功
reset_runtime active inactive '1 0' '0 0'
install_runtime_mocks
run_apply_case "socket first restart failure"
[[ "$(cat "$TEST_ROOT/rc")" == 1 ]] || fail "case1: apply must fail"
cmp -s "$SSH_CONFIG" "$TEST_ROOT/live.before" || fail "case1: live configuration not restored"
cmp -s "$SSH_PREVIOUS_BACKUP" "$TEST_ROOT/live.before" || fail "case1: previous backup is not the original"
cmp -s "$SSH_INITIAL_BACKUP" "$TEST_ROOT/live.before" || fail "case1: initial backup is not the original"
[[ "$GENERATED_CONFIG" == "$(cat "$SSH_CONFIG")" ]] || fail "case1: generator output not refreshed on rollback"
[[ "$LISTENING" == "$(cat "$SSH_CONFIG")" ]] || fail "case1: listening ports not restored"
[[ "$SOCKET_STATE" == active ]] || fail "case1: ssh.socket not active after rollback"
[[ "$(count_calls 'reload ssh')" == 0 ]] || fail "case1: socket path used a service reload"
[[ "$(count_calls 'restart ssh')" == 0 ]] || fail "case1: socket path fell back to restarting sshd"
[[ ! -e "$TEST_ROOT/next.conf" ]] || fail "case1: generated next.conf was not removed"
[[ "$(call_sequence)" == "is-active --quiet ssh.socket|daemon-reload|restart ssh.socket|daemon-reload|restart ssh.socket" ]] \
    || fail "case1: unexpected systemctl sequence $(call_sequence)"
assert_no_unknown case1
printf 'PASS: socket rollback reruns the generator and restores the old listener\n'

# 用例2：首次 daemon-reload 失败 -> 不得 restart，回滚重跑 generator 后重启成功
reset_runtime active inactive '0 0' '1 0'
install_runtime_mocks
run_apply_case "socket first daemon-reload failure"
[[ "$(cat "$TEST_ROOT/rc")" == 1 ]] || fail "case2: apply must fail"
cmp -s "$SSH_CONFIG" "$TEST_ROOT/live.before" || fail "case2: live configuration not restored"
[[ "$LISTENING" == "$(cat "$SSH_CONFIG")" ]] || fail "case2: listening ports not restored"
[[ "$(count_calls 'restart ssh.socket')" == 1 ]] || fail "case2: failed generator must not restart the socket"
[[ "$(count_calls 'daemon-reload')" == 2 ]] || fail "case2: rollback did not retry the generator"
[[ "$(call_sequence)" == "is-active --quiet ssh.socket|daemon-reload|daemon-reload|restart ssh.socket" ]] \
    || fail "case2: unexpected systemctl sequence $(call_sequence)"
assert_no_unknown case2
printf 'PASS: failed generator skips the socket restart and rollback succeeds\n'

# 用例3：两次 restart 均失败 -> 配置恢复但 socket 未起，需人工，且无 service 兜底
reset_runtime active inactive '1 1' '0 0'
install_runtime_mocks
run_apply_case "socket restart failures twice"
[[ "$(cat "$TEST_ROOT/rc")" == 1 ]] || fail "case3: apply must fail"
cmp -s "$SSH_CONFIG" "$TEST_ROOT/live.before" || fail "case3: live configuration not restored"
[[ "$SOCKET_STATE" == inactive ]] || fail "case3: socket must stay down"
[[ -z "$LISTENING" ]] || fail "case3: listening must stay empty"
[[ "$(count_calls 'restart ssh')" == 0 ]] || fail "case3: must not fall back to restarting sshd"
[[ "$(count_calls 'reload ssh')" == 0 ]] || fail "case3: must not fall back to a service reload"
pending=0
while IFS= read -r line; do
    [[ "$line" == *"需要人工处理"* ]] && pending=1
    [[ "$line" == *"SSH 安全配置完成"* ]] && fail "case3: success message printed on failure"
    [[ "$line" == *"已恢复 SSH 配置并"* ]] && fail "case3: rollback reported success while the socket stayed down"
done < "$TEST_ROOT/out.log"
[[ "$pending" == 1 ]] || fail "case3: output did not ask for manual intervention"
assert_eq "is-active --quiet ssh.socket|daemon-reload|restart ssh.socket|daemon-reload|restart ssh.socket" \
    "$(call_sequence)" "case3: two socket attempts behind two generator runs"
assert_no_unknown case3
printf 'PASS: double socket failure surfaces a manual-intervention result\n'

# 用例4：service 模式正常 apply -> 成功、新配置生效、旧配置留在备份、仅 reload service
reset_runtime inactive active '0' '0' 0
install_runtime_mocks
run_apply_case "service mode normal apply"
[[ "$(cat "$TEST_ROOT/rc")" == 0 ]] || fail "case4: service apply must succeed"
cmp -s "$SSH_PREVIOUS_BACKUP" "$TEST_ROOT/live.before" || fail "case4: previous backup is not the original"
cmp -s "$SSH_CONFIG" "$TEST_ROOT/next.expected" || fail "case4: new configuration was not installed"
assert_eq \
    "is-active --quiet ssh.socket|reload ssh|is-active --quiet ssh" \
    "$(call_sequence)" "service apply uses only the service path"
assert_eq "$(cat "$TEST_ROOT/next.expected")" "$LISTENING" \
    "service listener reflects the installed configuration"
assert_eq "-ltnH" "$(cat "$TEST_ROOT/ss.calls")" \
    "service apply actually verifies listening ports"
cmp -s "$SSH_INITIAL_BACKUP" "$TEST_ROOT/live.before" ||
    fail "case4: initial backup is not the original"
[[ ! -e "$TEST_ROOT/next.conf" ]] ||
    fail "case4: next.conf was not removed"
assert_no_unknown case4
printf 'PASS: service mode applies with a plain reload and keeps the previous backup\n'

printf 'All SSH security tests passed.\n'
