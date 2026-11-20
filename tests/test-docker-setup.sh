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
        if [[ "$apt_scenario" == removals ]]; then
            printf 'Remv docker.io [1.0]\n'
            return 0
        fi
        printf 'E: Package docker-ce has no installation candidate\n' >&2
        return 100
    fi
    printf 'Unexpected package operation: %s\n' "$*" >> "$mutation_log"
    return 1
}

test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT
mutation_log="$test_dir/package-mutations"

apt_scenario=no-candidate
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

apt_scenario=removals
if install_docker <<< ''; then
    printf 'FAIL: Docker CE installation accepted an empty migration confirmation\n' >&2
    exit 1
fi
if [[ -e "$mutation_log" ]]; then
    cat "$mutation_log" >&2
    printf 'FAIL: Docker CE migration changed packages without confirmation\n' >&2
    exit 1
fi
printf 'PASS: an empty response declines the Docker CE package replacement\n'

(
    backup="$test_dir/daemon.json.previous-backup"
    printf '{}\n' > "$backup"
    cp() { return 1; }
    if restore_daemon_config "$backup" "$test_dir/daemon.json"; then
        printf 'FAIL: failed restore copy was reported as success\n' >&2
        exit 1
    fi
)
printf 'PASS: a failed restore copy returns failure\n'

require_root() { :; }
install_docker() { :; }
start_docker_service() { :; }
systemctl() { return 1; }
curl() { return 1; }
ensure_docker_plugins() { return "$plugin_status"; }
configure_log_rotation() { return "$rotation_status"; }
show_docker_summary() { :; }

for scenario in plugin-failure restore-failure; do
    plugin_status=0 rotation_status=0
    case "$scenario" in
        plugin-failure) plugin_status=1; expected_status=2 ;;
        restore-failure) rotation_status=2; expected_status=1 ;;
    esac
    status=0
    main > "$test_dir/output" || status=$?
    if [[ "$status" != "$expected_status" ]] || grep -Fq 'Docker 配置完成' "$test_dir/output"; then
        cat "$test_dir/output" >&2
        printf 'FAIL: %s gave exit %s, expected %s\n' "$scenario" "$status" "$expected_status" >&2
        exit 1
    fi
    printf 'PASS: %s reports module status %s\n' "$scenario" "$status"
done
