#!/usr/bin/env bash
set -euo pipefail
# Inert local Git fixture only; never execute production scripts.
unset GH_TOKEN GITHUB_TOKEN SSH_PRIVATE_KEY_B64
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_CONFIG_COUNT
root=$(mktemp -d)
trap "rm -rf -- \"$root\"" EXIT
git init -q "$root"
cd "$root"
mkdir -p new/deep tests/nested
touch entry.sh new/deep/production.sh "new/space name.sh" tests/direct.sh tests/nested/deep.sh ignored.zsh
git add .
touch untracked.sh
mapfile -d "" -t production < <(git ls-files -z -- "*.sh" ":!:tests/**")
mapfile -d "" -t tests < <(git ls-files -z -- "tests/*.sh")
[[ ${#production[@]} == 3 && ${#tests[@]} == 2 ]]
[[ ${production[0]} == entry.sh ]]
[[ ${production[1]} == new/deep/production.sh ]]
[[ ${production[2]} == "new/space name.sh" ]]
[[ ${tests[0]} == tests/direct.sh && ${tests[1]} == tests/nested/deep.sh ]]
printf "PASS: recursive tracked production/test lint coverage\n"
