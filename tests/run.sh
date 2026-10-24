#!/usr/bin/env bash
set -euo pipefail

readonly ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# Positional, not exported: nested selection fixtures must still run all suites.
shard=${1:-all}
if (( $# > 1 )); then
    printf 'Usage: tests/run.sh [all|motd|push|other]\n' >&2
    exit 2
fi
case "$shard" in
    all|motd|push|other) ;;
    *) printf 'Invalid test shard: %s\n' "$shard" >&2; exit 2 ;;
esac

# Suites split across several files are named <family>-NN.sh; every part belongs
# to the family's shard and every part is selected by a change to the family.
family_of() {
    local name=${1##*/}
    name=${name%.sh}
    printf '%s.sh\n' "${name%-[0-9][0-9]}"
}

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
                tests/test-*.sh|tests/lib/*.sh)
                    if [[ -f "$ROOT_DIR/$path" ]]; then selected["$(family_of "$path")"]=1; else full=true; fi ;;
                README.md|LICENSE) ;;
                *) full=true ;;
            esac
        done < "$changes"
    else
        printf 'Selection unavailable; running all suites.\n' >&2
    fi
fi
printf 'Test selection: full=%s\n' "$full"

# Bounded parallelism: 1 keeps the original serial output byte for byte.
jobs=${TEST_JOBS:-1}
[[ "$jobs" =~ ^[1-9][0-9]*$ ]] || { printf 'Invalid TEST_JOBS: %s\n' "$jobs" >&2; exit 2; }

plan=()
for test_file in "$ROOT_DIR"/tests/test-*.sh; do
    test_name=$(basename "$test_file")
    family=$(family_of "$test_name")
    if [[ "$full" != true && -z "${selected[${family}]:-}" ]]; then
        printf 'SKIP: %s (unaffected by PR diff)\n' "$test_name"
        continue
    fi
    case "$family" in
        test-motd.sh) suite_shard=motd ;;
        test-push.sh|test-push-worker-registration.sh) suite_shard=push ;;
        *) suite_shard=other ;;
    esac
    if [[ "$shard" != all && "$shard" != "$suite_shard" ]]; then
        printf 'SKIP: %s (assigned to %s shard)\n' "$test_name" "$suite_shard"
        continue
    fi
    plan+=("$test_file")
done

run_suite() {
    local test_file=$1 test_name started status
    test_name=$(basename "$test_file")
    started=$SECONDS
    printf '\n==> %s\n' "$test_name"
    # Keep the child shell standalone: an if/|| wrapper can change errexit behavior.
    set +e
    bash "$test_file"
    status=$?
    set -e
    local elapsed=$((SECONDS - started))
    printf 'TIMING: %s elapsed=%ss exit=%s\n' "$test_name" "$elapsed" "$status"
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
        printf -- '- `%s`: %ss, exit %s\n' "$test_name" "$elapsed" "$status" >> "$GITHUB_STEP_SUMMARY"
    fi
    return "$status"
}

if (( ${#plan[@]} == 0 )); then
    printf '\nAll selected shell tests passed.\n'
    exit 0
fi

if (( jobs == 1 )); then
    for test_file in "${plan[@]}"; do
        run_suite "$test_file" || exit "$?"
    done
else
    log_dir=$(mktemp -d)
    trap 'rm -rf "$log_dir"' EXIT
    running=0
    for test_file in "${plan[@]}"; do
        test_name=$(basename "$test_file")
        (
            rc=0
            run_suite "$test_file" > "$log_dir/$test_name.log" 2>&1 || rc=$?
            printf '%s' "$rc" > "$log_dir/$test_name.rc"
        ) &
        running=$((running + 1))
        if (( running >= jobs )); then
            wait -n || true
            running=$((running - 1))
        fi
    done
    wait || true
    failed=0
    for test_file in "${plan[@]}"; do
        test_name=$(basename "$test_file")
        cat "$log_dir/$test_name.log"
        rc=$(cat "$log_dir/$test_name.rc" 2>/dev/null || printf 1)
        (( rc == 0 )) || failed=1
    done
    (( failed == 0 )) || exit 1
fi

printf '\nAll selected shell tests passed.\n'
