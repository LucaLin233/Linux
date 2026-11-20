#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=modules/docker-setup.sh
source "$ROOT_DIR/modules/docker-setup.sh"

docker_ce_installed() { return 1; }
configure_docker_repository() { return 0; }
apt_update_once() { return 0; }
package_is_installed() { [[ "$1" == docker.io ]]; }
apt-get() {
    if [[ "$1" == --simulate && "$2" == install ]]; then
        printf 'E: Package docker-ce has no installation candidate\n' >&2
        return 100
    fi
    printf 'Unexpected package operation: %s\n' "$*" >> "$mutation_log"
    return 1
}

test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT
mutation_log="$test_dir/package-mutations"

if install_docker <<< 'y'; then
    printf 'FAIL: Docker CE installation succeeded without a candidate\n' >&2
    exit 1
fi
if [[ -e "$mutation_log" ]]; then
    cat "$mutation_log" >&2
    printf 'FAIL: Docker CE installation changed packages without a candidate\n' >&2
    exit 1
fi
printf 'PASS: no package changes when Docker CE has no installation candidate\n'
