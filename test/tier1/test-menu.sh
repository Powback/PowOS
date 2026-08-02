#!/bin/bash
# test-menu.sh - unit tests for `powos menu` dispatch mapping.
# Pure: asserts each menu choice tag maps to the right `powos` sub-command,
# without running an interactive menu.

# NOTE: deliberately NO `pipefail`. These harnesses assert with
# `echo "$out" | grep -q ...`, and `grep -q` exits on its first match — which
# SIGPIPEs the writer, making the pipeline return 141 under pipefail depending
# on scheduling. That produced random failures (test-windows.sh swung between 4
# and 11 "failures" on identical runs). Last-command status is the correct
# semantics for an assertion anyway.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Prefer the WORKING TREE over the installed copy. This used to be the other
# way round, which meant running the suite inside a PowOS image silently
# tested /usr/lib/powos (the baked, possibly months-old code) instead of the
# changes under test — failures then looked like real regressions when the
# working tree was never loaded at all.
LIB=$REPO/lib/menu.sh
[[ -f "$LIB" ]] || LIB="/usr/lib/powos/menu.sh"
# shellcheck disable=SC1090
source "$LIB"

PASS=0; FAIL=0
ok()  { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL - $1 (got: ${2:-})"; FAIL=$((FAIL+1)); }

check() {  # check <tag> <expected-argv>
    local got; got="$(menu_action "$1")"
    [[ "$got" == "$2" ]] && ok "$1 → '$2'" || bad "$1" "$got"
}

echo "== menu_action mapping =="
check status      "status"
check health      "health"
check update      "update"
check upgrade     "upgrade --check"
check self-status "self status"
check self-test   "self test"
check self-pull   "self pull"
check self-push   "self push"
check backup      "backup status"
check backup-push "backup push"
check backup-pull "backup pull"
check games       "games status"
check windows     "windows status"
check doctor      "doctor"
check rollback    "rollback"

echo "== unknown tag → non-zero, no output =="
if out="$(menu_action bogus 2>&1)"; then
    bad "unknown tag returned success" "$out"
else
    [[ -z "$out" ]] && ok "unknown tag → non-zero, silent" || bad "unknown tag printed output" "$out"
fi

echo
echo "== Results: $PASS passed, $FAIL failed =="
[[ $FAIL -eq 0 ]]
