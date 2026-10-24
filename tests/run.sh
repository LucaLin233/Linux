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
    case "$test_name" in
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

# Suites carrying CI segment guards are listed here; TEST_SEGMENTS sets how many
# processes share the work.  With TEST_SEGMENTS=1 every suite runs in one process.
readonly SEGMENTED_FAMILIES=(test-motd.sh test-cloudflare-tunnel.sh test-push-worker-registration.sh)
segments=${TEST_SEGMENTS:-1}
[[ "$segments" =~ ^[1-9][0-9]*$ ]] || { printf 'Invalid TEST_SEGMENTS: %s\n' "$segments" >&2; exit 2; }

is_segmented() {
    local name=$1 entry
    (( segments > 1 )) || return 1
    for entry in "${SEGMENTED_FAMILIES[@]}"; do
        [[ "$entry" == "$name" ]] && return 0
    done
    return 1
}

run_suite() {
    local test_file=$1 seg=${2:-} test_name started status
    test_name=$(basename "$test_file")
    if [[ -n "$seg" ]]; then
        test_name+=" [segment $((seg + 1))/$segments]"
    fi
    started=$SECONDS
    printf '\n==> %s\n' "$test_name"
    # Keep the child shell standalone: an if/|| wrapper can change errexit behavior.
    # Nested fixtures re-enter this script, so neither setting may leak to them.
    set +e
    if [[ -n "$seg" ]]; then
        env -u TEST_JOBS -u TEST_SEGMENTS TEST_SEGMENT="$seg" bash "$test_file"
    else
        env -u TEST_JOBS -u TEST_SEGMENTS bash "$test_file"
    fi
    status=$?
    set -e
    local elapsed=$((SECONDS - started))
    printf 'TIMING: %s elapsed=%ss exit=%s\n' "$test_name" "$elapsed" "$status"
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
        printf -- '- `%s`: %ss, exit %s\n' "$test_name" "$elapsed" "$status" >> "$GITHUB_STEP_SUMMARY"
    fi
    return "$status"
}

# Segments of one suite share no state, so they run together and fill the
# runner; the suites of a shard still run one after another.
run_segments() {
    local test_file=$1 dir k rc failed=0 pids=()
    dir=$(mktemp -d)
    for (( k = 0; k < segments; k++ )); do
        (
            rc=0
            run_suite "$test_file" "$k" > "$dir/$k.log" 2>&1 || rc=$?
            printf '%s' "$rc" > "$dir/$k.rc"
        ) &
        pids+=("$!")
    done
    for k in "${pids[@]}"; do wait "$k" || true; done
    for (( k = 0; k < segments; k++ )); do
        cat "$dir/$k.log"
        rc=$(cat "$dir/$k.rc" 2>/dev/null || printf 1)
        (( rc == 0 )) || failed=1
    done
    rm -rf "$dir"
    return "$failed"
}

for test_file in "${plan[@]:-}"; do
    [[ -n "$test_file" ]] || continue
    if is_segmented "$(basename "$test_file")"; then
        run_segments "$test_file" || exit 1
    else
        run_suite "$test_file" || exit "$?"
    fi
done

printf '\nAll selected shell tests passed.\n'
