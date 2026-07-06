#!/bin/bash
# test-help.sh - Tier-1 checks that `powos help` splits commands into a CORE
# group and a clearly-labeled EXPERIMENTAL group (scope-B streamline). These are
# grep-level assertions over the rendered help text — they run on any box (Git
# Bash included), no root, no build.
#
# Usage:  bash test/tier1/test-help.sh
#   Docker: docker exec powos bash /var/lib/powos/src/test/tier1/test-help.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)"
[[ -f "$ROOT/bin/powos" ]] || ROOT="/var/lib/powos/src"
POWOS="$ROOT/bin/powos"

PASS=0; FAIL=0
ok()   { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL - $1"; FAIL=$((FAIL+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 (expected: $2)"; fi; }

echo "== render help =="
HELP="$(bash "$POWOS" help 2>/dev/null)"
check "help exits with output" '[[ -n "$HELP" ]]'

echo "== CORE vs EXPERIMENTAL split =="
check "help has a CORE section heading" 'echo "$HELP" | grep -q "CORE COMMANDS"'
check "help has an EXPERIMENTAL (unvalidated) heading" \
    'echo "$HELP" | grep -q "EXPERIMENTAL (unvalidated"'

# Line numbers: everything experimental must appear AFTER the experimental heading.
EXP_LINE="$(echo "$HELP" | grep -n "EXPERIMENTAL (unvalidated" | head -1 | cut -d: -f1)"
check "experimental heading found" '[[ -n "$EXP_LINE" ]]'

after_exp() {  # $1 = keyword; true if it first appears after the experimental heading
    local ln
    ln="$(echo "$HELP" | grep -n "$1" | head -1 | cut -d: -f1)"
    [[ -n "$ln" && "$ln" -gt "$EXP_LINE" ]]
}
# Note: bare "windows" also appears in CORE as `boot windows` (real dual-boot),
# so match the VHDX command specifically via "windows status".
for cmd in ramboot mobile "windows status" "vm status" "gpu status"; do
    check "'$cmd' listed under EXPERIMENTAL" "after_exp \"$cmd\""
done

echo "== CORE commands present (and above the experimental line) =="
before_exp() {
    local ln
    ln="$(echo "$HELP" | grep -n "$1" | head -1 | cut -d: -f1)"
    [[ -n "$ln" && "$ln" -lt "$EXP_LINE" ]]
}
# A sampling of the CORE surface — including `boot windows` (real dual-boot) which
# must stay CORE even though the VHDX `windows` command is experimental.
for cmd in "install-system" "games status" "boot windows" "backup" "rollback" "self status"; do
    check "'$cmd' listed under CORE" "before_exp \"$cmd\""
done

echo ""
echo "== Results: $PASS passed, $FAIL failed =="
[[ $FAIL -eq 0 ]]
