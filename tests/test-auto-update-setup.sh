#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT
# shellcheck source=../modules/auto-update-setup.sh
source "$ROOT_DIR/modules/auto-update-setup.sh"

fixture_script="$test_dir/auto-update.sh"
printf '#!/usr/bin/env bash\nprintf "old updater\\n"\n' > "$fixture_script"
chmod 700 "$fixture_script"
cp -- "$fixture_script" "$test_dir/original"
printf '0 1 * * 0 %s\n' "$fixture_script" > "$test_dir/cron"

crontab() {
    if [[ "$1" == -l ]]; then
        cat "$test_dir/cron"
    else
        touch "$test_dir/install-attempted"
        grep -Fq "0 2 * * 0 $fixture_script" "$1" && touch "$test_dir/schedule-matched"
        return 1
    fi
}

if install_update_schedule '0 2 * * 0' "$fixture_script"; then
    printf 'FAIL: failed crontab installation was reported as success\n' >&2
    exit 1
fi
[[ -e "$test_dir/install-attempted" && -e "$test_dir/schedule-matched" ]]
grep -Fxq "0 1 * * 0 $fixture_script" "$test_dir/cron"
cmp -s -- "$test_dir/original" "$fixture_script"
[[ -x "$fixture_script" ]]
printf 'PASS: failed crontab installation leaves the old updater in place\n'

rm -f -- "$test_dir/install-attempted"
(
    printf() {
        if [[ "$*" == *"$CRON_COMMENT"* ]]; then
            builtin printf 'partial cron table\n'
            touch "$test_dir/partial-write"
            return 1
        fi
        builtin printf "$@"
    }
    if install_update_schedule '0 2 * * 0' "$fixture_script"; then
        exit 1
    fi
)
[[ -e "$test_dir/partial-write" && ! -e "$test_dir/install-attempted" ]]
grep -Fxq "0 1 * * 0 $fixture_script" "$test_dir/cron"
cmp -s -- "$test_dir/original" "$fixture_script"
printf 'PASS: a staging write error preserves the existing cron table and updater\n'
