#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/test-push-worker-registration-common.sh"

for publication_state in $publication_states; do
    for publication_phase in $publication_phases; do
        for publication_signal in $publication_signals; do
            case "$publication_signal" in HUP) publication_status=129 ;; INT) publication_status=130 ;; TERM) publication_status=143 ;; *) fail "unknown publication signal" ;; esac
            run_state_publication_signal_case "$publication_state" "$publication_phase" "$publication_signal" "$publication_status"
        done
    done
done

(
    # Three bounded extra probes; preserve original matrix and stop at first failure.
    for diagnostic_round in 1 2 3; do
        printf "DIAG: extra HUP probe=%s/3\n" "$diagnostic_round"
        run_state_publication_signal_case cleanup_failed after-rename HUP 129 "-probe-$diagnostic_round"
    done
    root="$TEST_DIR/normal-parallel"; setup_fixture "$root"
    : > "$root/capture/current"; : > "$root/capture/max"
    push_to_server() {
        local server="$1" lock_fd current max group
        case "$server" in one.example|two.example) group=first ;; *) group=second ;; esac
        exec {lock_fd}>>"$root/capture/lock"; flock -x "$lock_fd"
        current=$(<"$root/capture/current"); ((current += 1)); printf '%s' "$current" > "$root/capture/current"
        max=$(<"$root/capture/max"); (( current > max )) && printf '%s' "$current" > "$root/capture/max"
        printf '%s\n' "$server" >> "$root/capture/transfer-calls"; : > "$root/capture/ready.$server"
        flock -u "$lock_fd"; exec {lock_fd}>&-
        while [[ ! -e "$root/capture/release.$group" ]]; do sleep 0.02; done
        exec {lock_fd}>>"$root/capture/lock"; flock -x "$lock_fd"
        current=$(<"$root/capture/current"); ((current -= 1)); printf '%s' "$current" > "$root/capture/current"
        flock -u "$lock_fd"; exec {lock_fd}>&-
        record_result success "$server"
    }
    (
        deadline=$((SECONDS + 15))
        while (( SECONDS < deadline )); do
            if [[ -e "$root/capture/ready.one.example" && -e "$root/capture/ready.two.example" ]]; then : > "$root/capture/release.first"; break; fi
            sleep 0.02
        done
        [[ -e "$root/capture/release.first" ]] || { : > "$root/capture/coordinator-timeout"; : > "$root/capture/release.first"; : > "$root/capture/release.second"; exit 1; }
        while (( SECONDS < deadline + 15 )); do
            if [[ -e "$root/capture/ready.three.example" && -e "$root/capture/ready.four.example" ]]; then : > "$root/capture/release.second"; exit 0; fi
            sleep 0.02
        done
        : > "$root/capture/coordinator-timeout"; : > "$root/capture/release.second"; exit 1
    ) & coordinator=$!
    run_server_batch source destination one.example two.example three.example four.example
    coordinator_rc=0; wait "$coordinator" || coordinator_rc=$?
    assert_eq 0 "$coordinator_rc" "normal parallel coordinator releases both worker pairs"
    assert_eq 2 "$(<"$root/capture/max")" "normal registration preserves MAX_PARALLEL=2"
    assert_eq 4 "$(wc -l < "$root/capture/transfer-calls")" "normal registration completes four fake servers"
    assert_no_registration_residue "$root"; cleanup_runtime; assert_no_registration_residue "$root"
    pass "normal registration/session lifecycle cleans all state"
)
printf 'All push worker registration tests passed.\n'
