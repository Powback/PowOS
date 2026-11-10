#!/bin/bash
# test-check-shell-pitfalls.sh - tools/agents/shell-pitfalls.py: the lint over the phone checks' shell catches the
# three pitfalls that produced false check FAILs on 11-10 (BSD-awk ternary redirect, SIGPIPE under pipefail, single
# quotes nested in su -c '...'), stays quiet on their fixed forms, and the tree itself is clean.
# No pipefail here on purpose (see test-base.sh): assertions use `grep -c` on captured output.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
LINT="$ROOT/tools/agents/shell-pitfalls.py"
FX="$ROOT/test/tier1/fixtures/shell-pitfalls"
PASS=0; FAIL=0
ok()  { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL - $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/         /'; FAIL=$((FAIL+1)); }

expect() {  # expect <fixture> <kind> <count>
  local out n
  out=$(python3 "$LINT" "$FX/$1" 2>&1)
  n=$(printf '%s\n' "$out" | grep -c ": $2: ")
  [ "$n" = "$3" ] && ok "$1: $3 $2 hit(s)" || bad "$1: want $3 $2, got $n" "$out"
  [ "$(printf '%s\n' "$out" | grep -c ': ')" = "$3" ] || bad "$1: hits of another kind" "$out"
}

echo "== bad fixtures are caught =="
expect bad-awk-ternary.sh awk-ternary 3
expect bad-sigpipe.sh sigpipe 7
expect bad-nested-quote.sh nested-quote 4

echo "== fixed forms, lint-ok escapes, no-pipefail files stay quiet =="
for f in good-awk-ternary.sh good-sigpipe.sh good-sigpipe-nopipefail.sh good-nested-quote.sh; do
  out=$(python3 "$LINT" "$FX/$f" 2>&1); rc=$?
  [ "$rc" = 0 ] && [ -z "$out" ] && ok "$f clean" || bad "$f: rc=$rc" "$out"
done

echo "== the fixtures are valid bash =="
for f in "$FX"/*.sh; do bash -n "$f" 2>/dev/null && ok "bash -n $(basename "$f")" || bad "bash -n $(basename "$f")"; done

echo "== the tree: tools/phone/**/*.sh + tools/agents/*.sh =="
out=$(python3 "$LINT" 2>&1); rc=$?
[ "$rc" = 0 ] && ok "no shell pitfalls in the checks" || bad "shell pitfalls (fix, or '# lint-ok: <why>')" "$out"

echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" = 0 ]
