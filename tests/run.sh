#!/usr/bin/env bash
set -euo pipefail

readonly ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# Positional, not exported: nested selection fixtures must still run all suites.
shard=${1:-all}
if (( $# > 1 )); then
    printf 'Usage: tests/run.sh [all|motd|push-worker|push|cloudflare|other]\n' >&2
    exit 2
fi
case "$shard" in
    all|motd|push-worker|push|cloudflare|other) ;;
    *) printf 'Invalid test shard: %s\n' "$shard" >&2; exit 2 ;;
esac

declare -A selected=()
full=true
if [[ -n "${TEST_BASE_SHA:-}" && -n "${TEST_HEAD_SHA:-}" ]]; then
    changes=$(mktemp)
    trap 'rm -f "$changes"' EXIT
    if git -C "$ROOT_DIR" diff --name-only --no-renames -z "$TEST_BASE_SHA...$TEST_HEAD_SHA" -- > "$changes"; then
        full=false
        while IFS= read -r -d '' path; do
            case "$path" in
                tools/setup-motd.sh) selected[test-motd.sh]=1 ;;
                modules/system-customize.sh) selected[test-motd.sh]=1; selected[test-xanmod.sh]=1 ;;
                tools/xanmod-install.sh) selected[test-xanmod.sh]=1 ;;
                tools/push.sh) selected[test-push.sh]=1; selected[test-push-worker-registration.sh]=1 ;;
                tools/cloudflare_tunnel.sh) selected[test-cloudflare-tunnel.sh]=1 ;;
                modules/ssh-security.sh) selected[test-ssh-security.sh]=1 ;;
                modules/system-optimize.sh) selected[test-system-optimize.sh]=1 ;;
                linux_setup.sh) selected[test-linux-setup.sh]=1; selected[test-setup-exec.sh]=1 ;;
                modules/zsh-setup.sh|p10k-config.zsh) selected[test-linux-setup.sh]=1 ;;
                tests/test-*.sh)
                    if [[ -f "$ROOT_DIR/$path" ]]; then selected["${path##*/}"]=1; else full=true; fi ;;
                README.md|LICENSE) ;;
                *) full=true ;;
            esac
        done < "$changes"
    else
        printf 'Selection unavailable; running all suites.\n' >&2
    fi
fi
printf 'Test selection: full=%s\n' "$full"

plan=()
for test_file in "$ROOT_DIR"/tests/test-*.sh; do
    test_name=$(basename "$test_file")
    if [[ "$full" != true && -z "${selected[${test_name}]:-}" ]]; then
        printf 'SKIP: %s (unaffected by PR diff)\n' "$test_name"
        continue
    fi
    # One suite per heavy family so CI can schedule them independently; every
    # other suite shares `other`.
    case "$test_name" in
        test-motd.sh) suite_shard=motd ;;
        test-push-worker-registration.sh) suite_shard=push-worker ;;
        test-push.sh) suite_shard=push ;;
        test-cloudflare-tunnel.sh) suite_shard=cloudflare ;;
        *) suite_shard=other ;;
    esac
    if [[ "$shard" != all && "$shard" != "$suite_shard" ]]; then
        printf 'SKIP: %s (assigned to %s shard)\n' "$test_name" "$suite_shard"
        continue
    fi
    plan+=("$test_file")
done

run_suite() {
    local test_file=$1 test_name started status elapsed
    test_name=$(basename "$test_file")
    started=$SECONDS
    printf '\n==> %s\n' "$test_name"
    # Keep the child shell standalone: an if/|| wrapper can change errexit behavior.
    # Nested fixtures re-enter this script, so neither setting may leak to them.
    set +e
    bash "$test_file"
    status=$?
    set -e
    elapsed=$((SECONDS - started))
    printf 'TIMING: %s elapsed=%ss exit=%s\n' "$test_name" "$elapsed" "$status"
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
        printf -- '- `%s`: %ss, exit %s\n' "$test_name" "$elapsed" "$status" >> "$GITHUB_STEP_SUMMARY"
    fi
    return "$status"
}

for test_file in "${plan[@]:-}"; do
    [[ -n "$test_file" ]] || continue
    run_suite "$test_file" || exit "$?"
done

printf '\nAll selected shell tests passed.\n'
