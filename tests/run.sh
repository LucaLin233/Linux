#!/usr/bin/env bash
set -euo pipefail

readonly ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

for test_file in "$ROOT_DIR"/tests/test-*.sh; do
    test_name=$(basename "$test_file")
    printf '\n==> %s\n' "$test_name"
    started=$SECONDS
    # Keep the child shell standalone: an if/|| wrapper can change errexit behavior.
    set +e
    bash "$test_file"
    status=$?
    set -e
    elapsed=$((SECONDS - started))
    printf 'TIMING: %s elapsed=%ss exit=%s\n' "$test_name" "$elapsed" "$status"
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
        printf -- '- `%s`: %ss, exit %s\n' "$test_name" "$elapsed" "$status" >> "$GITHUB_STEP_SUMMARY"
    fi
    if (( status != 0 )); then
        exit "$status"
    fi
done

printf '\nAll shell tests passed.\n'
