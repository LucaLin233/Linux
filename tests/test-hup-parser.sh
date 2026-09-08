#!/usr/bin/env bash
set -euo pipefail
# Inert parser controls only; no production code, network or real credentials.
unset GH_TOKEN GITHUB_TOKEN SSH_PRIVATE_KEY_B64
root=$(mktemp -d)
cleanup() { rm -rf -- "$root"; }
trap cleanup EXIT
command -v timeout >/dev/null
printf "DIAG: parser controls bash=%s\n" "$BASH_VERSION"
cat > "$root/child.sh" <<\CHILD
#!/usr/bin/env bash
set -euo pipefail
handler() { : > "$ready.handled"; exit 129; }
mode=$1
ready=$2
trap handler HUP
: > "$ready"
end=$((SECONDS + 2))
case "$mode" in
    plain) while (( SECONDS < end )); do :; done ;;
    command) while (( SECONDS < end )); do value=$(printf x); [[ $value == x ]]; done ;;
    process) while (( SECONDS < end )); do while IFS= read -r value; do :; done < <(jobs -pr); done ;;
    *) exit 90 ;;
esac
# Reaching this point means no HUP was handled; never count it as success.
exit 91
CHILD
cat > "$root/controller.sh" <<\CONTROL
#!/usr/bin/env bash
set -euo pipefail
root=$1 mode=$2 round=$3 delay=$4
ready="$root/ready-$mode-$round"
# Signal only the short-lived direct fixture child after its readiness marker.
env --default-signal=HUP,INT,TERM bash "$root/child.sh" "$mode" "$ready" &
child=$!
end=$((SECONDS + 2))
while [[ ! -f $ready ]] && (( SECONDS < end )); do sleep 0.001; done
if [[ ! -f $ready ]]; then
    wait "$child" || true
    exit 92
fi
sleep "$delay"
kill -HUP "$child"
status=0
wait "$child" || status=$?
printf "DIAG: mode=%s round=%s delay=%s exit=%s\n" "$mode" "$round" "$delay" "$status"
[[ $status == 129 && -f $ready.handled ]]
CONTROL
# 3 modes x 6 cases, at most 5 seconds per case (including forced teardown).
# Do not retry failures. Delay varies delivery, not a claim of exact parser timing.
for mode in plain command process; do
    round=0
    for delay in 0 0.001 0.005 0.01 0.02 0.05; do
        round=$((round + 1))
        timeout --signal=TERM --kill-after=1s 4s bash "$root/controller.sh" "$root" "$mode" "$round" "$delay"
    done
done
printf "PASS: all 18 bounded HUP parser controls\n"
