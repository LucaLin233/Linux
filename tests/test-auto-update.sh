#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../modules/auto-update-setup.sh
source "$ROOT_DIR/modules/auto-update-setup.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

schedule=$(printf 'n\n0 3 * * mon\n0 3 * * 1\n' | get_cron_schedule 2>/dev/null) || fail "custom schedule after a typo failed"
[[ "$schedule" == "0 3 * * 1" ]] || fail "custom schedule carried extra output: $(printf '%q' "$schedule")"
printf 'PASS: a rejected cron expression does not leak into the schedule\n'

schedule=$(printf '\n' | get_cron_schedule 2>/dev/null)
[[ "$schedule" == "$DEFAULT_CRON" ]] || fail "default schedule changed: $schedule"
printf 'PASS: empty answer keeps the default schedule\n'

if printf 'n\nbad\n' | get_cron_schedule >/dev/null 2>&1; then
    fail "EOF after an invalid expression must fail instead of looping"
fi
printf 'PASS: EOF while asking for a custom schedule fails\n'

printf 'All auto-update tests passed.\n'
