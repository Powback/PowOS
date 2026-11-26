#!/bin/bash
# test-verify-exit-status.sh - no tools/phone/verify script the queue runs by name ends on a bare "[ ... ] && ..." chain.
#
# A script's exit status is its last command's: "[ -n "$X" ] && { ...; exit 2; }" as the last line exits 1 whenever the
# test is false. board-look-windows.sh ended that way, so every all-pass recent-drag round went to done/ as
# "FAIL rc=1: PASS ... 6 passed, 0 failed" (round 1126-1850). A last line with "||" (the PASS-or-FAIL idiom) is fine.
# Also: e2e_finish's summary says "(interrupted)" only when some step was skipped.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; cd "$ROOT" || exit 1
PASS=0; FAIL=0
ok()  { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL - $1"; FAIL=$((FAIL+1)); }
echo "== verify scripts' last line =="
n=0
for f in tools/phone/verify/*.sh; do
  case "$f" in *-lib.sh|*-phone.sh) continue ;; esac
  last=$(grep -vE '^[[:space:]]*(#|$)' "$f" | tail -1)
  n=$((n + 1))
  if printf '%s\n' "$last" | grep -qE '^\[\[? .*&&' && ! printf '%s\n' "$last" | grep -q '||'; then
    bad "$f ends on a bare test chain (exit 1 when false): $last - use if ...; then ...; fi"
  fi
done
[ "$FAIL" = 0 ] && ok "$n verify scripts: none ends on a bare [ ] && chain"
echo "== the bug itself: a script ending '[ -n \"\" ] && ...' exits 1, the if form 0 =="
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
printf 'X=\n[ -n "$X" ] && { echo no; exit 2; }\n' > "$t/bare.sh"
printf 'X=\nif [ -n "$X" ]; then echo no; exit 2; fi\n' > "$t/if.sh"
bash "$t/bare.sh"; rb=$?; bash "$t/if.sh"; ri=$?
if [ "$rb" = 1 ] && [ "$ri" = 0 ]; then ok "bare chain rc $rb, if form rc $ri"; else bad "bare chain rc $rb (want 1), if form rc $ri (want 0)"; fi
echo "== e2e_finish summary: '(interrupted)' only with skipped steps =="
# The two lines of e2e_finish that build the summary, run as they are.
code=$(grep -A1 'local s int=""' tools/phone/verify/e2e-lib.sh | sed 's/^ *local s //')
# shellcheck disable=SC2154,SC2034 # s is assigned and the counts read by the eval'd e2e-lib lines
summ() { ( JOURNEY=j ROUND=r PART=1 LAST=1 NPASS=6 NFAIL=0 NSKIP=$1 UDIR=/u; eval "$code"; echo "$s" ); }
a=$(summ 0); b=$(summ 2)
case "$a" in *interrupted*) bad "all-pass summary says interrupted: $a" ;; *"6 passed, 0 failed, 0 skipped - /u") ok "all-pass: $a" ;; *) bad "all-pass summary unreadable: '$a'" ;; esac
case "$b" in *"2 skipped (interrupted)"*) ok "with skips: $b" ;; *) bad "2 skipped not marked interrupted: $b" ;; esac
echo ""; echo "== Results: $PASS passed, $FAIL failed =="; [ "$FAIL" -eq 0 ]
