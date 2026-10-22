#!/bin/bash
# test-complexity.sh - the strict complexity limits hold for all the code they cover, and the baselines only shrink.
#
#   TS/TSX/JS (shell/, apps/*/ui): shell/dev/lint-complexity.sh --apps - per function cyclomatic 10, cognitive 10,
#     depth 3, 60 lines, 4 params; old debt frozen in shell/dev/complexity-baseline*.json (a count per file and rule).
#     A new violation fails; an entry no longer needed fails until pruned; an entry above HEAD's fails.
#   Kotlin (targets/android/app): targets/android/lint-complexity.sh - detekt, the same limits, baseline
#     targets/android/app/config/detekt-baseline.xml (one id per function).
#   Rust (apps/*/module): tools/lint/rust-complexity.sh - clippy, the same limits, tools/lint/rust-complexity-baseline.txt.
#   Bash (bin/, lib/, build/): build/complexity.py --check (the CC ratchet, build/complexity-budget.txt).
#
# Needs shell/node_modules (npm ci in shell/) for the TS half; skipped (not failed) without it.
# Usage:  bash test/tier1/test-complexity.sh

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PASS=0; FAIL=0
ok()  { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL - $1"; FAIL=$((FAIL+1)); }

echo "== TypeScript (shell + apps UIs) =="
out=$(bash "$ROOT/shell/dev/lint-complexity.sh" --apps 2>&1); rc=$?
case $rc in
    0) ok "no function over the limits beyond the baseline; the baseline has no stale entries" ;;
    2) echo "  skip - $out" ;;
    *) bad "complexity lint"; echo "$out" | sed 's/^/       /' | head -40 ;;
esac

echo "== the baselines only shrink, across history =="
if out=$(python3 "$ROOT/shell/dev/complexity-history.py" "$ROOT" 2>&1); then ok "no commit raised a baseline count without [baseline-reset]"
else bad "a commit raised the complexity baseline"; echo "$out" | head -20 | sed 's/^/       /'; fi

echo "== the lint catches a new violation =="
probe="$ROOT/shell/ui/__complexity_probe_$$.ts"
printf 'export function p(a: number, b: number, c: number, d: number, e: number) {\n  if (a) { if (b) { if (c) { if (d) { return e; } } } }\n  return 0;\n}\n' > "$probe"
out=$(bash "$ROOT/shell/dev/lint-complexity.sh" "ui/$(basename "$probe")" 2>&1); rc=$?
rm -f "$probe"
case $rc in
    1) echo "$out" | grep -q "max-params" && echo "$out" | grep -q "max-depth" \
         && ok "5 params + depth 4 in a new file fail" || bad "new violation failed without naming the rules" ;;
    2) echo "  skip - no shell/node_modules" ;;
    *) bad "a function with 5 params and depth 4 passed the lint" ;;
esac

echo "== Kotlin (targets/android/app) =="
out=$(bash "$ROOT/targets/android/lint-complexity.sh" 2>&1); rc=$?
case $rc in
    0) ok "detekt: no function over the limits beyond app/config/detekt-baseline.xml, no stale ids" ;;
    2) echo "  skip - $out" ;;
    *) bad "kotlin complexity lint"; echo "$out" | sed 's/^/       /' | head -30 ;;
esac

echo "== Rust (apps/*/module) =="
out=$(bash "$ROOT/tools/lint/rust-complexity.sh" 2>&1); rc=$?
case $rc in
    0) ok "clippy: no count above tools/lint/rust-complexity-baseline.txt, none paid off unpruned" ;;
    2) echo "  skip - $out" ;;
    *) bad "rust complexity lint"; echo "$out" | sed 's/^/       /' | head -30 ;;
esac

echo "== Bash (bin/, lib/, build/) =="
cd "$ROOT" || exit 1
files=()   # bash 3.2 (the Mac): no mapfile
while IFS= read -r f; do files+=("$f"); done < <( { grep -lE '^#!\s*(/usr)?/bin/(env +)?(ba)?sh\b' bin/* 2>/dev/null; git ls-files 'lib/**/*.sh' 'lib/*.sh' 'build/*.sh' 'sources/**/*.sh'; } | sort -u)
if out=$(python3 build/complexity.py --check "${files[@]}" 2>&1); then ok "bash CC ratchet (build/complexity-budget.txt)"
else bad "bash CC ratchet"; echo "$out" | tail -15 | sed 's/^/       /'; fi

echo ""
echo "== Results: $PASS passed, $FAIL failed =="
[[ $FAIL -eq 0 ]]
