#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT
module_source=$(<"$ROOT_DIR/modules/docker-setup.sh")
original_dir='readonly DOCKER_DAEMON_DIR="/etc/docker"'
fixture_dir='readonly DOCKER_DAEMON_DIR="$test_dir/docker"'
[[ "$module_source" == *"$original_dir"* ]]
# shellcheck source=../modules/docker-setup.sh
source <(printf '%s\n' "${module_source/"$original_dir"/"$fixture_dir"}")
[[ "$DOCKER_DAEMON_DIR" == "$test_dir/docker" ]]

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

require_root() { :; }
install_docker() { :; }
start_docker_service() { :; }
curl() { return 1; }
dockerd() { :; }
ensure_docker_plugins() { return "$plugin_status"; }
show_docker_summary() { :; }
systemctl() {
    case "$*" in
        'is-active --quiet docker') return 0 ;;
        'restart docker') ((restarts += 1)); return 1 ;;
        *) return 1 ;;
    esac
}
cp() {
    local source_path="${@: -2:1}"
    if [[ "$scenario" == restore-failure && "$source_path" == "$DOCKER_DAEMON_PREVIOUS_BACKUP" ]]; then
        restore_attempted=true
        return 1
    fi
    command cp "$@"
}

for scenario in plugin-failure restore-failure restart-failure; do
    plugin_status=0 restarts=0 restore_attempted=false choice=y
    case "$scenario" in
        plugin-failure) plugin_status=1; choice=n; expected_status=2 ;;
        *) expected_status=1 ;;
    esac
    mkdir -p "$DOCKER_DAEMON_DIR"
    printf '{}\n' > "$DOCKER_DAEMON_CONFIG"
    status=0
    main <<< "$choice" > "$test_dir/output" || status=$?
    if [[ "$status" != "$expected_status" ]] || grep -Fq 'Docker 配置完成' "$test_dir/output"; then
        cat "$test_dir/output" >&2
        printf 'FAIL: %s gave exit %s, expected %s\n' "$scenario" "$status" "$expected_status" >&2
        exit 1
    fi
    if [[ "$scenario" == restore-failure ]]; then
        [[ "$restore_attempted" == true && "$restarts" == 1 ]]
    elif [[ "$scenario" == restart-failure ]]; then
        [[ "$restarts" == 2 && $(<"$DOCKER_DAEMON_CONFIG") == '{}' ]]
    fi
    printf 'PASS: %s reports module status %s\n' "$scenario" "$status"
done
