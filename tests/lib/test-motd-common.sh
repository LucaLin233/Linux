#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.."&&pwd);
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
