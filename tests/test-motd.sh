#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.."&&pwd);
readonly ROOT_DIR
TEST_DIR=$(mktemp -d);
readonly TEST_DIR
fail(){ echo "FAIL: $*" >&2;
exit 1;
};
pass(){ echo "PASS: $*";
};
assert_eq(){ [[ "$1" == "$2" ]]||fail "$3: $1 != $2";
pass "$3";
};
assert_fail(){ local l="$1";
shift;
if "$@";
then fail "$l";
fi;
pass "$l";
}
extract_payload(){ awk '/install -m 0755 \/dev\/stdin .*<<.SCRIPT./{c=1;next}c&&$0=="SCRIPT"{exit}c{print}' "$1";
}
load_motd() {
    . "$ROOT_DIR/tools/setup-motd.sh"
}

create_fixture(){ local r="$1" e
 e="$r/e";
e+="tc";
mkdir -m700 "$r" "$e" "$e/update-motd.d" "$r/lock";
printf original>"$e/motd";
chmod 640 "$e/motd";
printf issue>"$e/issue";
chmod 644 "$e/issue";
printf old>"$e/update-motd.d/00-custom-welcome";
chmod 700 "$e/update-motd.d/00-custom-welcome";
printf uname>"$e/update-motd.d/10-uname";
chmod 754 "$e/update-motd.d/10-uname";
}
export_paths(){ local r="$1" e
 e="$r/e";
e+="tc";
export MOTD_TEST_MODE=1 MOTD_ETC_ROOT="$e" MOTD_STATE_DIR="$r/state" MOTD_LOCK_FILE="$r/lock/motd.lock" MOTD_TRANSACTION_PARENT="$r/state/transactions";
}
target_hash(){ local r="$1" e p
 e="$r/e";
e+="tc";
for p in "$e/motd" "$e/issue" "$e/issue.net" "$e/update-motd.d/00-custom-welcome" "$e/update-motd.d/10-uname" "$e/update-motd.d/50-motd-news";
do if [[ -L "$p" ]];
then echo "L|$p|$(readlink "$p")";
elif [[ -f "$p" ]];
then echo "F|$p|$(stat -c %u:%g:%a "$p")|$(sha256sum "$p"|awk '{print $1}')";
elif [[ ! -e "$p" ]];
then echo "A|$p";
else echo "O|$p|$(stat -c %F "$p")";
fi;
done;
}
extract_payload "$ROOT_DIR/tools/setup-motd.sh">"$TEST_DIR/t";
extract_payload "$ROOT_DIR/modules/system-customize.sh">"$TEST_DIR/m";
cmp -s "$TEST_DIR/t" "$TEST_DIR/m"||fail payload;
pass "MOTD payloads stay identical";
assert_eq cf2a4f8dfe2fe26bff5509cdaee56d9e0816fafd0594251b02e892201af5c4d5 "$(sha256sum "$TEST_DIR/t"|awk '{print $1}')" "payload hash"
(
 r="$TEST_DIR/source";
mkdir -m700 "$r" "$r/lock";
export_paths "$r";
b=$(trap -p EXIT HUP INT TERM ERR);
load_motd;
[[ "$b" == "$(trap -p EXIT HUP INT TERM ERR)"&&! -e "$MOTD_STATE_DIR"&&! -e "$MOTD_LOCK_FILE" ]]||fail source
);
pass "source zero side effects"
(
 r="$TEST_DIR/basic";
create_fixture "$r";
export_paths "$r";
before=$(target_hash "$r");
load_motd;
motd_run_locked_operation install;
[[ -f "$MOTD_ETC_ROOT/motd"&&! -s "$MOTD_ETC_ROOT/motd"&&-x "$MOTD_SCRIPT" ]]||fail install;
motd_run_locked_operation restore previous;
assert_eq "$before" "$(target_hash "$r")" "restore previous group";
motd_run_locked_operation install;
printf changed>"$MOTD_ETC_ROOT/motd";
motd_run_locked_operation restore initial;
assert_eq "$before" "$(target_hash "$r")" "restore initial group"
)
(
 r="$TEST_DIR/types";
create_fixture "$r";
export_paths "$r";
unlink "$MOTD_ETC_ROOT/issue";
ln -s "$r/link" "$MOTD_ETC_ROOT/issue";
before=$(target_hash "$r");
load_motd;
motd_run_locked_operation install;
g=$(motd_read_pointer previous);
motd_validate_snapshot "$MOTD_STATE_DIR/generations/$g" previous "$g";
assert_eq symlink "${MOTD_SNAPSHOT_STATE[issue]}" "symlink snapshot";
assert_eq absent "${MOTD_SNAPSHOT_STATE[issue_net]}" "absent snapshot";
motd_run_locked_operation restore previous;
assert_eq "$before" "$(target_hash "$r")" "symlink restore"
)
(
 r="$TEST_DIR/initial";
create_fixture "$r";
export_paths "$r";
before=$(target_hash "$r");
load_motd;
motd_snapshot_capture_hook(){ [[ "$1" != issue_net ]];
};
assert_fail "initial capture atomic" motd_run_locked_operation install;
[[ ! -e "$MOTD_STATE_DIR/initial.current" ]]||fail partial;
assert_eq "$before" "$(target_hash "$r")" "initial failure no target change"
)
(
 r="$TEST_DIR/previous";
create_fixture "$r";
export_paths "$r";
load_motd;
motd_run_locked_operation install;
old=$(motd_read_pointer previous);
for id in "${MOTD_TARGET_IDS[@]}";
do motd_snapshot_capture_hook(){ [[ "$1" != "$id" ]];
};
assert_fail "previous capture $id" motd_run_locked_operation install;
assert_eq "$old" "$(motd_read_pointer previous)" "previous pointer $id";
done
)
for failing_id in motd issue_net motd_news;
do
(
 r="$TEST_DIR/i-$failing_id";
create_fixture "$r";
export_paths "$r";
load_motd;
motd_run_locked_operation install;
printf current>"$MOTD_ETC_ROOT/motd";
before=$(target_hash "$r");
motd_target_commit_hook(){ [[ "$2" != "$failing_id" ]];
};
assert_fail "install failure $failing_id" motd_run_locked_operation install;
assert_eq "$before" "$(target_hash "$r")" "install rollback $failing_id"
)
(
 r="$TEST_DIR/r-$failing_id";
create_fixture "$r";
export_paths "$r";
load_motd;
motd_run_locked_operation install;
printf current>"$MOTD_ETC_ROOT/motd";
before=$(target_hash "$r");
motd_target_commit_hook(){ [[ "$1" != restore||"$2" != "$failing_id" ]];
};
assert_fail "restore failure $failing_id" motd_run_locked_operation restore previous;
assert_eq "$before" "$(target_hash "$r")" "restore rollback $failing_id"
)
done
(
 r="$TEST_DIR/manifest";
create_fixture "$r";
export_paths "$r";
load_motd;
motd_run_locked_operation install;
g=$(motd_read_pointer previous);
mf="$MOTD_STATE_DIR/generations/$g/manifest";
cp "$mf" "$r/o";
for k in missing duplicate unknown digest generation;
do cp "$r/o" "$mf";
case $k in missing)sed -i '$d' "$mf";;
duplicate)tail -n1 "$mf">>"$mf";;
unknown)echo x=y>>"$mf";;
digest)sed -i 's/[0-9a-f]\{64\}$/0000000000000000000000000000000000000000000000000000000000000000/' "$mf";;
generation)sed -i 's/^generation=.*/generation=00000000000000000000000000000000/' "$mf";;
esac;
before=$(target_hash "$r");
assert_fail "manifest $k rejected" motd_run_locked_operation restore previous;
assert_eq "$before" "$(target_hash "$r")" "manifest $k no target change";
done
)
(
 r="$TEST_DIR/lock";
create_fixture "$r";
export_paths "$r";
load_motd;
motd_lock_acquired_hook(){ : >"$r/ready";
sleep 2;
};
motd_take_lock & h=$!;
while [[ ! -e "$r/ready" ]];
do sleep .02;
done;
assert_fail "install lock contention" motd_run_locked_operation install;
assert_fail "restore lock contention" motd_run_locked_operation restore previous;
[[ ! -e "$MOTD_STATE_DIR" ]]||fail lockstate;
wait "$h";
motd_lock_acquired_hook(){ :;
};
motd_take_lock;
motd_release_lock
);
pass "shared lock nonblocking and reacquirable"
for k in symlink writable fifo;
do(
 r="$TEST_DIR/l-$k";
create_fixture "$r";
export_paths "$r";
load_motd;
case $k in symlink)printf x>"$r/x";
ln -s "$r/x" "$MOTD_LOCK_FILE";;
writable)printf x>"$MOTD_LOCK_FILE";
chmod 666 "$MOTD_LOCK_FILE";;
fifo)mkfifo "$MOTD_LOCK_FILE";;
esac;
assert_fail "lock rejects $k" motd_take_lock
);
done
for k in symlink writable;
do(
 r="$TEST_DIR/s-$k";
create_fixture "$r";
export_paths "$r";
load_motd;
case $k in symlink)mkdir -m700 "$r/s";
ln -s "$r/s" "$MOTD_STATE_DIR";;
writable)mkdir -m770 "$MOTD_STATE_DIR";;
esac;
motd_take_lock;
assert_fail "state rejects $k" motd_prepare_state_layout;
motd_release_lock
);
done
create_legacy(){ printf legacy>"$MOTD_ETC_ROOT/motd.initial-backup";
: >"$MOTD_ETC_ROOT/issue.initial-absent";
printf net>"$MOTD_ETC_ROOT/issue.net.initial-backup";
: >"$MOTD_ETC_ROOT/update-motd.d/00-custom-welcome.initial-unknown";
printf uname>"$MOTD_ETC_ROOT/update-motd.d/10-uname.initial-backup";
: >"$MOTD_ETC_ROOT/update-motd.d/50-motd-news.initial-absent";
}
(
 r="$TEST_DIR/legacy";
create_fixture "$r";
export_paths "$r";
create_legacy;
load_motd;
motd_run_locked_operation restore initial;
assert_eq legacy "$(cat "$MOTD_ETC_ROOT/motd")" "legacy complete restore";
[[ -e "$MOTD_ETC_ROOT/motd.initial-backup" ]]||fail legacymove
)
for k in partial conflict commit;
do(
 r="$TEST_DIR/lg-$k";
create_fixture "$r";
export_paths "$r";
if [[ $k == partial ]];
then printf x>"$MOTD_ETC_ROOT/motd.initial-backup";
else create_legacy;
[[ $k == conflict ]]&&: >"$MOTD_ETC_ROOT/motd.initial-absent";
fi;
load_motd;
[[ $k == commit ]]&&motd_snapshot_commit_hook(){ [[ "$3" != legacy-directory ]];
};
assert_fail "legacy $k rejected" motd_run_locked_operation restore initial
);
done
(
 r="$TEST_DIR/interop";
create_fixture "$r";
export_paths "$r";
o=$(target_hash "$r");
bash -c '. "$1/modules/system-customize.sh";ask_yes_no(){ return 0;};motd_preview_hook(){ :;};configure_motd' _ "$ROOT_DIR">/dev/null;
printf x>"$MOTD_ETC_ROOT/motd";
bash -c '. "$1/tools/setup-motd.sh";motd_run_locked_operation restore previous' _ "$ROOT_DIR";
assert_eq "$o" "$(target_hash "$r")" "module state tool restore"
)
(
 r="$TEST_DIR/exit";
create_fixture "$r";
export_paths "$r";
before=$(target_hash "$r");
n=0;
bash -c '. "$1";motd_take_lock;motd_install_transaction_traps;motd_prepare_state_layout;motd_validate_target_parents;motd_begin_transaction install;motd_prepare_install_plan;motd_commit_target_plan install false;exit 0' _ "$ROOT_DIR/tools/setup-motd.sh">/dev/null 2>&1||n=$?;
assert_eq 1 "$n" "active exit zero maps one";
assert_eq "$before" "$(target_hash "$r")" "active exit rollback"
)
(
 r="$TEST_DIR/rbf";
create_fixture "$r";
export_paths "$r";
load_motd;
motd_run_locked_operation install;
motd_target_commit_hook(){ [[ "$2" != issue_net ]];
};
motd_rollback_hook(){ echo "$1">>"$r/a";
[[ "$1" != motd&&"$1" != custom_welcome ]];
};
assert_fail "rollback failure nonzero" motd_run_locked_operation install;
assert_eq 6 "$(wc -l<"$r/a")" "rollback attempts six";
[[ -e "$MOTD_STATE_DIR/pending" ]]||fail journal
)
cat >"$TEST_DIR/sig.sh"<<'CHILD'
#!/usr/bin/env bash
set -euo pipefail
trap - HUP INT TERM
. "$1";
hit=false
send(){ [[ $hit == false ]]||return;
hit=true;
kill -"$SIGNAL_NAME" "$BASHPID";
}
motd_snapshot_capture_hook(){ [[ $PHASE == snapshot-building&&$1 == issue ]]&&send;
return 0;
}
motd_transaction_phase_hook(){ [[ $PHASE == snapshot-commit&&$1 == snapshot-commit ]]&&send;
return 0;
}
motd_snapshot_commit_hook(){ [[ $PHASE == snapshot-publish&&$1 == initial&&$3 == pointer ]]&&send;
return 0;
}
motd_target_commit_hook(){ case "$PHASE:$1:$2" in install-first:install:motd|install-middle:install:issue_net|restore-first:restore:motd|restore-middle:restore:issue_net)send;;
esac;
return 0;
}
case $PHASE in restore-*)motd_run_locked_operation restore previous;;
*)motd_run_locked_operation install;;
esac
CHILD
chmod 700 "$TEST_DIR/sig.sh"
for ph in snapshot-building snapshot-commit snapshot-publish install-first install-middle restore-first restore-middle;
do for sig in HUP INT TERM;
do(
 r="$TEST_DIR/$ph-$sig";
create_fixture "$r";
export_paths "$r";
if [[ $ph == restore-* ]];
then bash -c '. "$1";motd_run_locked_operation install' _ "$ROOT_DIR/tools/setup-motd.sh";
printf current>"$MOTD_ETC_ROOT/motd";
fi;
before=$(target_hash "$r");
n=0;
env --default-signal=HUP,INT,TERM PHASE="$ph" SIGNAL_NAME="$sig" bash "$TEST_DIR/sig.sh" "$ROOT_DIR/tools/setup-motd.sh">/dev/null 2>&1||n=$?;
case $sig in HUP)e=129;;
INT)e=130;;
TERM)e=143;;
esac;
assert_eq "$e" "$n" "$sig $ph status";
assert_eq "$before" "$(target_hash "$r")" "$sig $ph rollback"
);
done;
done
(
 r="$TEST_DIR/unknown";
create_fixture "$r";
export_paths "$r";
printf '# linux-setup:managed-motd'>"$MOTD_ETC_ROOT/update-motd.d/00-custom-welcome";
load_motd;
motd_run_locked_operation install;
g=$(motd_read_pointer initial);
motd_validate_snapshot "$MOTD_STATE_DIR/generations/$g" initial "$g";
assert_eq unknown "${MOTD_SNAPSHOT_STATE[motd]}" "unknown initial state"
)
(
 r="$TEST_DIR/readonly";
create_fixture "$r";
export_paths "$r";
bash "$ROOT_DIR/tools/setup-motd.sh" status>/dev/null;
bash "$ROOT_DIR/tools/setup-motd.sh" help>/dev/null;
[[ ! -e "$MOTD_STATE_DIR"&&! -e "$MOTD_LOCK_FILE" ]]||fail readonly
);
pass "status help no lock"
(
 r="$TEST_DIR/publish";
create_fixture "$r";
export_paths "$r";
load_motd;
motd_run_locked_operation install;
old=$(motd_read_pointer previous);
printf current>"$MOTD_ETC_ROOT/motd";
before=$(target_hash "$r");
motd_snapshot_manifest_hook(){ [[ "$1" != previous ]];
};
assert_fail "previous manifest failure" motd_run_locked_operation install;
assert_eq "$old" "$(motd_read_pointer previous)" "manifest preserves previous";
assert_eq "$before" "$(target_hash "$r")" "manifest failure rolls back";
motd_snapshot_manifest_hook(){ :;
};
motd_snapshot_commit_hook(){ [[ "$1" != previous||"$3" != directory ]];
};
assert_fail "previous directory commit failure" motd_run_locked_operation install;
assert_eq "$old" "$(motd_read_pointer previous)" "directory failure preserves previous"
)
for k in owner gid;
do(
 r="$TEST_DIR/lmeta-$k";
create_fixture "$r";
export_paths "$r";
load_motd;
printf x>"$MOTD_LOCK_FILE";
chmod 600 "$MOTD_LOCK_FILE";
stat(){ if [[ "${*: -1}" == "$MOTD_LOCK_FILE"&&"$*" == *"%u:%g:%a"* ]];
then [[ $k == owner ]]&&printf '99999:%s:600\n' "$MOTD_TRUSTED_GID"||printf '%s:99999:600\n' "$MOTD_TRUSTED_UID";
else command stat "$@";
fi;
};
assert_fail "lock wrong $k" motd_take_lock
);
done
for k in owner gid;
do(
 r="$TEST_DIR/smeta-$k";
create_fixture "$r";
export_paths "$r";
mkdir -m700 "$MOTD_STATE_DIR";
load_motd;
stat(){ if [[ "${*: -1}" == "$MOTD_STATE_DIR"&&"$*" == *"%u:%g:%a"* ]];
then [[ $k == owner ]]&&printf '99999:%s:700\n' "$MOTD_TRUSTED_GID"||printf '%s:99999:700\n' "$MOTD_TRUSTED_UID";
else command stat "$@";
fi;
};
motd_take_lock;
assert_fail "state wrong $k" motd_prepare_state_layout;
motd_release_lock
);
done
(
 r="$TEST_DIR/state-create";
create_fixture "$r";
export_paths "$r";
load_motd;
chown(){ [[ "${*: -1}" == "$MOTD_STATE_DIR" ]]&&return 1;
command chown "$@";
};
assert_fail "state create failure" motd_run_locked_operation install;
[[ ! -e "$MOTD_STATE_DIR" ]]||fail state-residue
)
(
 r="$TEST_DIR/close";
create_fixture "$r";
export_paths "$r";
load_motd;
motd_take_lock;
motd_lock_close_hook(){ return 1;
};
assert_fail "lock close failure" motd_release_lock
)
(
 r="$TEST_DIR/device";
create_fixture "$r";
export_paths "$r";
if mknod "$MOTD_ETC_ROOT/issue.net" c 1 3 2>/dev/null;
then before=$(target_hash "$r");
load_motd;
assert_fail "device rejected" motd_run_locked_operation install;
assert_eq "$before" "$(target_hash "$r")" "device no target change";
else pass "device test skipped";
fi
)
(
 r="$TEST_DIR/legacy-state";
create_fixture "$r";
export_paths "$r";
mkdir -m700 "$MOTD_STATE_DIR";
printf legacy>"$MOTD_STATE_DIR/motd.previous-backup";
chmod 600 "$MOTD_STATE_DIR/motd.previous-backup";
for x in issue issue.net 00-custom-welcome 10-uname 50-motd-news;
do : >"$MOTD_STATE_DIR/$x.previous-absent";
chmod 600 "$MOTD_STATE_DIR/$x.previous-absent";
done;
load_motd;
motd_run_locked_operation restore previous;
assert_eq legacy "$(cat "$MOTD_ETC_ROOT/motd")" "state legacy restore"
)

state_fingerprint() {
    local root="$1" path
    [[ -d "$root" ]] || { printf 'absent\n'; return; }
    while IFS= read -r path; do
        if [[ -L "$path" ]]; then printf 'L|%s|%s\n' "${path#$root/}" "$(readlink "$path")"
        elif [[ -f "$path" ]]; then printf 'F|%s|%s|%s\n' "${path#$root/}" "$(stat -c %u:%g:%a "$path")" "$(sha256sum "$path" | awk '{print $1}')"
        elif [[ -d "$path" ]]; then printf 'D|%s|%s\n' "${path#$root/}" "$(stat -c %u:%g:%a "$path")"
        fi
    done < <(find "$root" -mindepth 1 -print | sort)
}

generation_count() {
    local directory="$1"
    [[ -d "$directory" ]] || { printf '0\n'; return; }
    find "$directory" -mindepth 1 -maxdepth 1 -type d ! -name '.*.stage' | wc -l
}

assert_no_motd_residue() {
    local root="$1" residue
    residue=$(find "$root" -name '.linux-setup-motd.*' -o -name '.*.pointer.*' -o -name '.pending.*' -o -name '.*.stage' 2>/dev/null)
    [[ -z "$residue" ]] || fail "unexpected MOTD residue: $residue"
    if [[ -d "$root/state/transactions" ]]; then [[ -z "$(find "$root/state/transactions" -mindepth 1 -print -quit)" ]] || fail "transaction residue remains"; fi
}

create_complete_legacy_scope() {
    local scope="$1" prefix
    cp -a "$MOTD_ETC_ROOT/motd" "$MOTD_ETC_ROOT/motd.${scope}-backup"
    cp -a "$MOTD_ETC_ROOT/issue" "$MOTD_ETC_ROOT/issue.${scope}-backup"
    : > "$MOTD_ETC_ROOT/issue.net.${scope}-absent"; chmod 0600 "$MOTD_ETC_ROOT/issue.net.${scope}-absent"
    cp -a "$MOTD_ETC_ROOT/update-motd.d/00-custom-welcome" "$MOTD_ETC_ROOT/update-motd.d/00-custom-welcome.${scope}-backup"
    cp -a "$MOTD_ETC_ROOT/update-motd.d/10-uname" "$MOTD_ETC_ROOT/update-motd.d/10-uname.${scope}-backup"
    : > "$MOTD_ETC_ROOT/update-motd.d/50-motd-news.${scope}-absent"; chmod 0600 "$MOTD_ETC_ROOT/update-motd.d/50-motd-news.${scope}-absent"
}

for legacy_phase in random-id stat open create cat chown chmod sha256 manifest mv; do
(
    root="$TEST_DIR/legacy-io-$legacy_phase"; create_fixture "$root"; export_paths "$root"
    create_complete_legacy_scope initial
    before_targets=$(target_hash "$root")
    before_legacy=$(find "$MOTD_ETC_ROOT" -name '*.initial-*' -type f -printf '%p|%s|%m\n' | sort)
    load_motd
    motd_legacy_io_hook() { [[ "$1" != "$legacy_phase" ]]; }
    assert_fail "legacy $legacy_phase failure returns nonzero" motd_run_locked_operation restore initial
    assert_eq "$before_targets" "$(target_hash "$root")" "legacy $legacy_phase keeps formal targets"
    assert_eq "$before_legacy" "$(find "$MOTD_ETC_ROOT" -name '*.initial-*' -type f -printf '%p|%s|%m\n' | sort)" "legacy $legacy_phase keeps legacy files"
    [[ ! -e "$MOTD_STATE_DIR/initial.current" ]] || fail "legacy $legacy_phase published initial pointer"
    assert_no_motd_residue "$root"
)
done
pass "legacy I/O failure matrix preserves data and state"

cat > "$TEST_DIR/pointer-signal-child.sh" <<'CHILD'
#!/usr/bin/env bash
set -euo pipefail
trap - HUP INT TERM
. "$1"
motd_snapshot_commit_hook() {
    if [[ "$1" == previous && "$3" == pointer ]]; then kill -"$SIGNAL_NAME" "$BASHPID"; fi
}
motd_run_locked_operation install
CHILD
chmod 0700 "$TEST_DIR/pointer-signal-child.sh"

for signal_name in HUP INT TERM; do
(
    root="$TEST_DIR/pointer-signal-$signal_name"; create_fixture "$root"; export_paths "$root"
    bash -c '. "$1"; motd_run_locked_operation install' _ "$ROOT_DIR/tools/setup-motd.sh"
    old_pointer=$(cat "$MOTD_STATE_DIR/previous.current")
    before=$(target_hash "$root")
    rc=0
    env --default-signal=HUP,INT,TERM SIGNAL_NAME="$signal_name" bash "$TEST_DIR/pointer-signal-child.sh" "$ROOT_DIR/tools/setup-motd.sh" >/dev/null 2>&1 || rc=$?
    case "$signal_name" in HUP) expected=129 ;; INT) expected=130 ;; TERM) expected=143 ;; esac
    assert_eq "$expected" "$rc" "$signal_name during previous pointer stage returns conventional status"
    assert_eq "$old_pointer" "$(cat "$MOTD_STATE_DIR/previous.current")" "$signal_name preserves previous pointer"
    assert_eq "$before" "$(target_hash "$root")" "$signal_name pointer stage restores targets"
    assert_no_motd_residue "$root"
    bash -c '. "$1"; motd_take_lock; motd_release_lock' _ "$ROOT_DIR/tools/setup-motd.sh"
)
done

for pending_phase in pending-create pending-write pending-chown pending-chmod pending-publish; do
(
    root="$TEST_DIR/pending-failure-$pending_phase"; create_fixture "$root"; export_paths "$root"
    load_motd
    motd_run_locked_operation install
    before=$(target_hash "$root"); before_generations=$(generation_count "$MOTD_STATE_DIR/generations")
    motd_transaction_phase_hook() { [[ "$1" != "$pending_phase" ]]; }
    assert_fail "pending $pending_phase failure returns nonzero" motd_run_locked_operation install
    assert_eq "$before" "$(target_hash "$root")" "pending $pending_phase keeps targets"
    assert_eq "$before_generations" "$(generation_count "$MOTD_STATE_DIR/generations")" "pending $pending_phase leaves no generation orphan"
    [[ ! -e "$MOTD_STATE_DIR/pending" && ! -L "$MOTD_STATE_DIR/pending" ]] || fail "pending $pending_phase left pending"
    assert_no_motd_residue "$root"
    motd_transaction_phase_hook() { :; }
    motd_run_locked_operation install
)
done

for pending_kind in broken-symlink symlink directory fifo mode owner gid; do
(
    root="$TEST_DIR/pending-kind-$pending_kind"; create_fixture "$root"; export_paths "$root"
    load_motd; motd_run_locked_operation install
    pending="$MOTD_STATE_DIR/pending"
    case "$pending_kind" in
        broken-symlink) ln -s "$root/missing" "$pending" ;;
        symlink) printf x > "$root/pending-target"; chmod 0600 "$root/pending-target"; ln -s "$root/pending-target" "$pending" ;;
        directory) mkdir "$pending" ;;
        fifo) mkfifo "$pending" ;;
        mode) printf x > "$pending"; chmod 0666 "$pending" ;;
        owner|gid) printf x > "$pending"; chmod 0600 "$pending" ;;
    esac
    before=$(target_hash "$root")
    if [[ "$pending_kind" == owner || "$pending_kind" == gid ]]; then
        stat() {
            if [[ "${*: -1}" == "$pending" && "$*" == *"%u:%g:%a"* ]]; then
                [[ "$pending_kind" == owner ]] && printf '99999:%s:600\n' "$MOTD_TRUSTED_GID" || printf '%s:99999:600\n' "$MOTD_TRUSTED_UID"
            else command stat "$@"; fi
        }
    fi
    assert_fail "pending $pending_kind fails closed" motd_run_locked_operation install
    assert_eq "$before" "$(target_hash "$root")" "pending $pending_kind changes no target"
    [[ -e "$pending" || -L "$pending" ]] || fail "pending $pending_kind evidence was removed"
)
done

cat > "$TEST_DIR/kill-pending-child.sh" <<'CHILD'
#!/usr/bin/env bash
set -euo pipefail
. "$1"
motd_transaction_phase_hook() { [[ "$1" == pending-active ]] && kill -KILL "$BASHPID"; return 0; }
motd_run_locked_operation install
CHILD
cat > "$TEST_DIR/kill-previous-pointer-child.sh" <<'CHILD'
#!/usr/bin/env bash
set -euo pipefail
. "$1"
motd_snapshot_commit_hook() { [[ "$1" == previous && "$3" == pointer ]] && kill -KILL "$BASHPID"; return 0; }
motd_run_locked_operation install
CHILD
chmod 0700 "$TEST_DIR/kill-pending-child.sh" "$TEST_DIR/kill-previous-pointer-child.sh"

for journal_case in pending-directory journal-transaction generation-scope generation-missing old-new-mix; do
(
    root="$TEST_DIR/journal-$journal_case"; create_fixture "$root"; export_paths "$root"
    bash -c '. "$1"; motd_run_locked_operation install' _ "$ROOT_DIR/tools/setup-motd.sh"
    rc=0
    if [[ "$journal_case" == pending-directory || "$journal_case" == journal-transaction ]]; then
        bash "$TEST_DIR/kill-pending-child.sh" "$ROOT_DIR/tools/setup-motd.sh" >/dev/null 2>&1 || rc=$?
    else
        bash "$TEST_DIR/kill-previous-pointer-child.sh" "$ROOT_DIR/tools/setup-motd.sh" >/dev/null 2>&1 || rc=$?
    fi
    assert_eq 137 "$rc" "$journal_case fixture stops with SIGKILL"
    transaction=$(cat "$MOTD_STATE_DIR/pending")
    journal="$MOTD_TRANSACTION_PARENT/$transaction/journal"
    case "$journal_case" in
        pending-directory) printf '%032x\n' 1 > "$MOTD_STATE_DIR/pending" ;;
        journal-transaction) sed -i 's/^transaction=.*/transaction=00000000000000000000000000000001/' "$journal" ;;
        generation-scope) initial=$(cat "$MOTD_STATE_DIR/initial.current"); sed -i "s/^previous_new=.*/previous_new=$initial/" "$journal" ;;
        generation-missing) sed -i 's/^previous_new=.*/previous_new=ffffffffffffffffffffffffffffffff/' "$journal" ;;
        old-new-mix) initial=$(cat "$MOTD_STATE_DIR/initial.current"); sed -i "s/^previous_old=.*/previous_old=$initial/" "$journal" ;;
    esac
    before=$(target_hash "$root")
    load_motd
    assert_fail "$journal_case pending/journal mismatch rejected" motd_run_locked_operation install
    assert_eq "$before" "$(target_hash "$root")" "$journal_case mismatch changes no target"
    [[ -e "$MOTD_STATE_DIR/pending" ]] || fail "$journal_case evidence removed"
)
done

for tamper_case in content mode inode regular-to-symlink; do
(
    root="$TEST_DIR/stage-$tamper_case"; create_fixture "$root"; export_paths "$root"
    printf news > "$MOTD_ETC_ROOT/update-motd.d/50-motd-news"; chmod 0755 "$MOTD_ETC_ROOT/update-motd.d/50-motd-news"
    before=$(target_hash "$root")
    load_motd
    motd_transaction_phase_hook() {
        [[ "$1" == install-plan-ready ]] || return 0
        case "$tamper_case" in
            content) printf tampered > "${MOTD_TARGET_STAGE[motd]}" ;;
            mode) chmod 0600 "${MOTD_TARGET_STAGE[issue_net]}" ;;
            inode) cp "$MOTD_ETC_ROOT/update-motd.d/50-motd-news" "${MOTD_TARGET_STAGE[motd_news]}.replacement"; chmod 0644 "${MOTD_TARGET_STAGE[motd_news]}.replacement"; mv -Tf "${MOTD_TARGET_STAGE[motd_news]}.replacement" "${MOTD_TARGET_STAGE[motd_news]}" ;;
            regular-to-symlink) rm -f "${MOTD_TARGET_STAGE[issue_net]}"; ln -s "$root/elsewhere" "${MOTD_TARGET_STAGE[issue_net]}" ;;
        esac
    }
    motd_target_commit_hook() { : > "$root/commit-called"; }
    assert_fail "$tamper_case stage tamper rejected before commit" motd_run_locked_operation install
    [[ ! -e "$root/commit-called" ]] || fail "$tamper_case reached first formal commit"
    assert_eq "$before" "$(target_hash "$root")" "$tamper_case stage tamper changes no target"
    assert_no_motd_residue "$root"
)
done

(
    root="$TEST_DIR/stage-symlink-target"; create_fixture "$root"; export_paths "$root"
    printf external > "$root/external"; ln -sf "$root/external" "$MOTD_ETC_ROOT/issue"
    load_motd; motd_run_locked_operation install
    before=$(target_hash "$root")
    motd_transaction_phase_hook() {
        [[ "$1" == restore-plan-ready ]] || return 0
        rm -f "${MOTD_TARGET_STAGE[issue]}"; ln -s "$root/other" "${MOTD_TARGET_STAGE[issue]}"
    }
    motd_target_commit_hook() { : > "$root/commit-called"; }
    assert_fail "symlink target stage tamper rejected before restore commit" motd_run_locked_operation restore previous
    [[ ! -e "$root/commit-called" ]] || fail "symlink target tamper reached formal commit"
    assert_eq "$before" "$(target_hash "$root")" "symlink target tamper changes no target"
)

for native_id in uname motd_news; do
(
    root="$TEST_DIR/native-symlink-$native_id"; create_fixture "$root"; export_paths "$root"
    case "$native_id" in uname) native_path="$MOTD_ETC_ROOT/update-motd.d/10-uname" ;; motd_news) native_path="$MOTD_ETC_ROOT/update-motd.d/50-motd-news" ;; esac
    rm -f "$native_path"
    printf 'external-%s\n' "$native_id" > "$root/external-$native_id"; chmod 0755 "$root/external-$native_id"
    external_hash=$(sha256sum "$root/external-$native_id"); external_mode=$(stat -c %a "$root/external-$native_id")
    ln -s "$root/external-$native_id" "$native_path"
    load_motd
    motd_run_locked_operation install
    [[ ! -e "$native_path" && ! -L "$native_path" ]] || fail "$native_id symlink entry remains enabled"
    assert_eq "$external_hash" "$(sha256sum "$root/external-$native_id")" "$native_id external content unchanged"
    assert_eq "$external_mode" "$(stat -c %a "$root/external-$native_id")" "$native_id external mode unchanged"
    motd_run_locked_operation restore previous
    [[ -L "$native_path" && "$(readlink "$native_path")" == "$root/external-$native_id" ]] || fail "$native_id previous symlink not restored"
)
done

cat > "$TEST_DIR/sigkill-child.sh" <<'CHILD'
#!/usr/bin/env bash
set -euo pipefail
. "$1"
motd_transaction_phase_hook() {
    [[ "$1" == "$KILL_PHASE" ]] && kill -KILL "$BASHPID"
    return 0
}
motd_run_locked_operation install
CHILD
chmod 0700 "$TEST_DIR/sigkill-child.sh"

for kill_phase in transaction-snapshot-building transaction-final-moved target-committed-motd target-committed-issue_net target-committed-motd_news committed-cleanup committed-old-generation-cleaned committed-pending-removed; do
(
    root="$TEST_DIR/sigkill-$kill_phase"; create_fixture "$root"; export_paths "$root"
    printf news > "$MOTD_ETC_ROOT/update-motd.d/50-motd-news"; chmod 0755 "$MOTD_ETC_ROOT/update-motd.d/50-motd-news"
    bash -c '. "$1"; motd_run_locked_operation install' _ "$ROOT_DIR/tools/setup-motd.sh"
    before=$(target_hash "$root")
    rc=0
    KILL_PHASE="$kill_phase" bash "$TEST_DIR/sigkill-child.sh" "$ROOT_DIR/tools/setup-motd.sh" >/dev/null 2>&1 || rc=$?
    assert_eq 137 "$rc" "SIGKILL at $kill_phase terminates process"
    after_kill=$(target_hash "$root")
    load_motd
    motd_take_lock; motd_prepare_state_layout; motd_reconcile_state; motd_release_lock
    if [[ "$kill_phase" == committed-* ]]; then
        assert_eq "$after_kill" "$(target_hash "$root")" "committed cleanup SIGKILL does not roll back"
    else
        assert_eq "$before" "$(target_hash "$root")" "SIGKILL at $kill_phase rolls back to pre-transaction state"
    fi
    assert_eq 2 "$(generation_count "$MOTD_STATE_DIR/generations")" "SIGKILL at $kill_phase leaves bounded generations"
    assert_no_motd_residue "$root"
    motd_take_lock; motd_release_lock
)
done

(
    root="$TEST_DIR/generation-bounded"; create_fixture "$root"; export_paths "$root"
    load_motd
    for _ in {1..6}; do motd_run_locked_operation install; done
    assert_eq 2 "$(generation_count "$MOTD_STATE_DIR/generations")" "repeated install keeps two generations"
)

(
    root="$TEST_DIR/generation-commit-failure"; create_fixture "$root"; export_paths "$root"
    load_motd; motd_run_locked_operation install
    before_count=$(generation_count "$MOTD_STATE_DIR/generations")
    motd_target_commit_hook() { [[ "$2" != issue_net ]]; }
    assert_fail "target commit failure returns nonzero for generation cleanup" motd_run_locked_operation install
    assert_eq "$before_count" "$(generation_count "$MOTD_STATE_DIR/generations")" "target commit failure leaves no orphan generation"
)

(
    root="$TEST_DIR/interop-module-tool"; create_fixture "$root"; export_paths "$root"
    original=$(target_hash "$root")
    bash -c '. "$1/modules/system-customize.sh"; ask_yes_no(){ return 0; }; motd_preview_hook(){ :; }; configure_motd' _ "$ROOT_DIR" >/dev/null
    printf changed > "$MOTD_ETC_ROOT/motd"
    bash -c '. "$1/tools/setup-motd.sh"; motd_run_locked_operation restore previous' _ "$ROOT_DIR"
    assert_eq "$original" "$(target_hash "$root")" "module install to tool previous restore"
    printf changed > "$MOTD_ETC_ROOT/motd"
    bash -c '. "$1/tools/setup-motd.sh"; motd_run_locked_operation restore initial' _ "$ROOT_DIR"
    assert_eq "$original" "$(target_hash "$root")" "module install to tool initial restore"
)

(
    root="$TEST_DIR/interop-tool-module"; create_fixture "$root"; export_paths "$root"
    original=$(target_hash "$root")
    bash -c '. "$1/tools/setup-motd.sh"; motd_run_locked_operation install' _ "$ROOT_DIR"
    printf between > "$MOTD_ETC_ROOT/motd"; between=$(target_hash "$root")
    bash -c '. "$1/modules/system-customize.sh"; ask_yes_no(){ return 0; }; motd_preview_hook(){ :; }; configure_motd' _ "$ROOT_DIR" >/dev/null
    bash -c '. "$1/modules/system-customize.sh"; motd_run_locked_operation restore previous' _ "$ROOT_DIR"
    assert_eq "$between" "$(target_hash "$root")" "tool install to module previous restore"
    printf changed > "$MOTD_ETC_ROOT/motd"
    bash -c '. "$1/modules/system-customize.sh"; motd_run_locked_operation restore initial' _ "$ROOT_DIR"
    assert_eq "$original" "$(target_hash "$root")" "tool install to module initial restore"
)


(
    root="$TEST_DIR/cleanup-old-generation-failure"; create_fixture "$root"; export_paths "$root"
    load_motd; motd_run_locked_operation install
    old_previous=$(cat "$MOTD_STATE_DIR/previous.current"); blocked="$MOTD_STATE_DIR/generations/$old_previous"
    motd_cleanup_path_hook() { [[ "$1" != "$blocked" ]]; }
    assert_fail "old previous generation delete failure returns nonzero" motd_run_locked_operation install
    [[ -e "$MOTD_STATE_DIR/pending" ]] || fail "old generation delete failure lost pending journal"
    transaction=$(cat "$MOTD_STATE_DIR/pending"); grep -Fq 'phase=committed' "$MOTD_TRANSACTION_PARENT/$transaction/journal" || fail "old generation failure journal not committed"
    [[ -d "$blocked" ]] || fail "blocked old generation unexpectedly removed"
    motd_cleanup_path_hook() { :; }
    motd_run_locked_operation install
    [[ ! -e "$MOTD_STATE_DIR/pending" ]] || fail "old generation cleanup retry left pending"
)

(
    root="$TEST_DIR/cleanup-rollback-generation-failure"; create_fixture "$root"; export_paths "$root"
    load_motd; motd_run_locked_operation install
    current_initial=$(cat "$MOTD_STATE_DIR/initial.current"); current_previous=$(cat "$MOTD_STATE_DIR/previous.current")
    motd_cleanup_path_hook() {
        local name=${1##*/}
        if [[ "$1" == "$MOTD_STATE_DIR/generations/"* && "$name" != "$current_initial" && "$name" != "$current_previous" ]]; then return 1; fi
        return 0
    }
    motd_target_commit_hook() { [[ "$2" != issue_net ]]; }
    assert_fail "rollback generation delete failure returns nonzero" motd_run_locked_operation install
    [[ -e "$MOTD_STATE_DIR/pending" ]] || fail "rollback generation failure lost pending"
    transaction=$(cat "$MOTD_STATE_DIR/pending"); grep -Fq 'phase=rolledback' "$MOTD_TRANSACTION_PARENT/$transaction/journal" || fail "rollback generation failure journal not rolledback"
    motd_cleanup_path_hook() { :; }; motd_target_commit_hook() { :; }
    motd_run_locked_operation install
    [[ ! -e "$MOTD_STATE_DIR/pending" ]] || fail "rolledback cleanup retry left pending"
    assert_eq 2 "$(generation_count "$MOTD_STATE_DIR/generations")" "rolledback cleanup retry restores bounded generations"
)

printf 'All MOTD integrity tests passed.\n'
