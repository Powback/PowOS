#!/bin/bash
# test-verify-executable.sh - every tools/phone/verify/*.sh the verify queue runs BY NAME is committed executable.
#
# The runner execs the queued command (`env ... tools/phone/verify/X.sh`), so a check committed 100644 fails on the
# phone window with rc=126 "Permission denied" before it runs at all (11-07: steam-launch-placeholder.sh failed twice
# that way). Checks the GIT INDEX mode (what the verify checkout gets), not the working tree.
# A script run by name = a top-level tools/phone/verify/*.sh with a #! line that is not phone-side (*-phone.sh, pushed
# and run with sh/bash) or a library (*-lib.sh), plus any tools/phone/verify/*.sh named right after `queue.sh add`
# anywhere in the repo.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; cd "$ROOT" || exit 1
PASS=0; FAIL=0
ok()  { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL - $1"; FAIL=$((FAIL+1)); }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "  skip - not a git checkout"; echo "== Results: 0 passed, 0 failed =="; exit 0; }
echo "== tools/phone/verify run-by-name modes =="
declare -A want=()
while read -r mode _ _ path; do
  case "$path" in tools/phone/verify/*/*|*-phone.sh|*-lib.sh) continue ;; esac
  head -c2 "$path" 2>/dev/null | grep -q '^#!' && want[$path]=$mode
done < <(git ls-files -s 'tools/phone/verify/*.sh')
while read -r p; do
  m=$(git ls-files -s -- "$p" | awk '{print $1}'); [ -n "$m" ] && want[$p]=$m
done < <(git grep -hoE 'queue\.sh add [^`|;]*' -- ':!test/tier1/test-verify-executable.sh' 2>/dev/null |
         grep -oE 'tools/phone/verify/[A-Za-z0-9_.-]+\.sh' | sort -u)
nonx=(); for p in "${!want[@]}"; do [ "${want[$p]}" = 100755 ] || nonx+=("$p"); done
if [ ${#nonx[@]} -eq 0 ]; then ok "${#want[@]} run-by-name verify scripts are committed 100755"
else for p in "${nonx[@]}"; do bad "$p is ${want[$p]} - git update-index --chmod=+x $p"; done; fi
echo ""; echo "== Results: $PASS passed, $FAIL failed =="; [ "$FAIL" -eq 0 ]
