#!/usr/bin/env bash
set -euo pipefail

readonly ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

for test_file in "$ROOT_DIR"/tests/test-*.sh; do
    printf '\n==> %s\n' "$(basename "$test_file")"
    bash "$test_file"
done

printf '\nAll shell tests passed.\n'
