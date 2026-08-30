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
. "$ROOT_DIR/tools/setup-motd.sh";
[[ "$b" == "$(trap -p EXIT HUP INT TERM ERR)"&&! -e "$MOTD_STATE_DIR"&&! -e "$MOTD_LOCK_FILE" ]]||fail source
);
pass "source zero side effects"
(
 r="$TEST_DIR/basic";
create_fixture "$r";
export_paths "$r";
before=$(target_hash "$r");
. "$ROOT_DIR/tools/setup-motd.sh";
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
. "$ROOT_DIR/tools/setup-motd.sh";
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
. "$ROOT_DIR/tools/setup-motd.sh";
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
. "$ROOT_DIR/tools/setup-motd.sh";
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
. "$ROOT_DIR/tools/setup-motd.sh";
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
. "$ROOT_DIR/tools/setup-motd.sh";
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
. "$ROOT_DIR/tools/setup-motd.sh";
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
. "$ROOT_DIR/tools/setup-motd.sh";
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
. "$ROOT_DIR/tools/setup-motd.sh";
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
. "$ROOT_DIR/tools/setup-motd.sh";
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
. "$ROOT_DIR/tools/setup-motd.sh";
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
. "$ROOT_DIR/tools/setup-motd.sh";
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
. "$ROOT_DIR/tools/setup-motd.sh";
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
. "$ROOT_DIR/tools/setup-motd.sh";
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
. "$ROOT_DIR/tools/setup-motd.sh";
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
. "$ROOT_DIR/tools/setup-motd.sh";
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
. "$ROOT_DIR/tools/setup-motd.sh";
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
. "$ROOT_DIR/tools/setup-motd.sh";
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
. "$ROOT_DIR/tools/setup-motd.sh";
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
. "$ROOT_DIR/tools/setup-motd.sh";
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
. "$ROOT_DIR/tools/setup-motd.sh";
motd_run_locked_operation restore previous;
assert_eq legacy "$(cat "$MOTD_ETC_ROOT/motd")" "state legacy restore"
)
printf 'All MOTD tests passed.\n'
