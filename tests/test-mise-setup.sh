#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT
export HOME="$test_dir"
# shellcheck source=../modules/mise-setup.sh
source "$ROOT_DIR/modules/mise-setup.sh"

get_mise_executable() { printf 'fixture_mise\n'; }
get_active_tool_version() { printf '1.2.3\n'; }
ensure_node_runtime_dependencies() { :; }
fixture_mise() {
    case "$1" in
        latest) printf '2.3.4\n' ;;
        exec) printf 'fixture output\n' ;;
        install|use) touch "$test_dir/version-change" ;;
    esac
}
mv() {
    touch "$test_dir/backup-publication-attempted"
    return 1
}

for tool in python node; do
    rm -f -- "$test_dir/backup-publication-attempted" "$test_dir/version-change"
    if "setup_$tool" <<< '1'; then
        printf 'FAIL: %s migration succeeded after backup publication failed\n' "$tool" >&2
        exit 1
    fi
    if [[ ! -e "$test_dir/backup-publication-attempted" || -e "$test_dir/version-change" ]]; then
        printf 'FAIL: %s migration did not stop at backup publication\n' "$tool" >&2
        exit 1
    fi
    printf 'PASS: %s migration stops before installing or selecting a new version\n' "$tool"
done
