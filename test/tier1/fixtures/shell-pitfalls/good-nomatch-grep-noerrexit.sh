#!/bin/bash
# shellcheck disable=SC2034,SC2154,SC2155  # lint fixture: unused/unset names and local x=$(...) are the point
# lint fixture: pipefail without errexit - a failing pipeline doesn't end the script, so no nomatch-grep hit
set -uo pipefail
changed=$(git status --porcelain | grep -v node_modules | sort)
grep -E '^(FAIL|ok)' gate.log | sort > /tmp/verdicts
