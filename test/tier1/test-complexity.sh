#!/bin/bash
# test-complexity.sh - the strict complexity limits hold for all the code they cover, and the baselines only shrink.
#
#   TS/TSX/JS (shell/, apps/*/ui): shell/dev/lint-complexity.sh --apps - per function cyclomatic 10, cognitive 10,
#     depth 3, 60 lines, 4 params; old debt frozen in shell/dev/complexity-baseline*.json (a count per file and rule).
#     A new violation fails; an entry no longer needed fails until pruned; an entry above HEAD's fails.
#   Kotlin (targets/android/app): targets/android/lint-complexity.sh - detekt, the same limits, baseline
#     targets/android/app/config/detekt-baseline.xml (one id per function).
#   Rust (apps/*/module): tools/lint/rust-complexity.sh - clippy, the same limits, tools/lint/rust-complexity-baseline.txt.
#   Shell scripts (every tracked *.sh + bin/): build/complexity.py --check-length - 60 lines per function, old debt
#     in build/function-length-budget.txt (a ratchet).
#   Bash (bin/, lib/, build/): build/complexity.py --check (the CC ratchet, build/complexity-budget.txt).
#
# Fail closed: each lint installs/fetches its own tools (cached); only GATE_LINT=0 skips them.
#
# Scope: by default each language's lint runs only when that language changed against the merge base with
# origin/worktree-powos-multiplatform (committed, uncommitted or untracked): detekt only for .kt/.java (or its config),
# the TS lint for shell/ and apps/*/ui, clippy for .rs, the bash ratchets for .sh/bin/build. --all (or CX_ALL=1, no
# merge base, CI) runs everything: the ship pipeline and CI keep the full mode.
# Usage:  bash test/tier1/test-complexity.sh [--all]

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PASS=0; FAIL=0
ALL=${CX_ALL:-}; [ "${1:-}" = --all ] && ALL=1
# Which languages changed (bash 3.2: no associative arrays). Unknown merge base -> everything.
LT=0; LK=0; LR=0; LB=0
if [ -z "$ALL" ]; then
    mb=$(git -C "$ROOT" merge-base HEAD origin/worktree-powos-multiplatform 2>/dev/null) || mb=""
    if [ -z "$mb" ]; then ALL=1; else
        changed=$( { git -C "$ROOT" diff --name-only "$mb"; git -C "$ROOT" ls-files --others --exclude-standard; } | sort -u)
        echo "$changed" | grep -qE '^(shell/|apps/[^/]+/ui/|test/tier1/test-complexity)' && LT=1
        echo "$changed" | grep -qE '\.(kt|java|kts)$|^targets/android/(lint-complexity\.sh|app/config/)' && LK=1
        echo "$changed" | grep -qE '\.rs$|^apps/[^/]+/module/|^tools/lint/rust-' && LR=1
        echo "$changed" | grep -qE '\.sh$|^bin/|^build/(complexity|function-length)|^lib/' && LB=1
        echo "(changed vs merge base: ts=$LT kotlin=$LK rust=$LR bash=$LB - the rest skipped; --all runs everything)"
    fi
fi
[ -n "$ALL" ] && LT=1 LK=1 LR=1 LB=1
skipped() { echo "  skip - $1 unchanged vs the merge base (--all runs it)"; }
ok()  { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL - $1"; FAIL=$((FAIL+1)); }

echo "== TypeScript (shell + apps UIs) =="
if [ $LT = 0 ]; then skipped TypeScript; else
out=$(bash "$ROOT/shell/dev/lint-complexity.sh" --apps 2>&1); rc=$?
case $rc in
    0) ok "no function over the limits beyond the baseline; the baseline has no stale entries" ;;
    2) echo "  skip - $out" ;;
    *) bad "complexity lint"; echo "$out" | sed 's/^/       /' | head -40 ;;
esac
fi

echo "== the baselines only shrink, across history =="
if [ $LT = 0 ]; then skipped TypeScript; else
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
    2) echo "  skip - GATE_LINT=0" ;;
    *) bad "a function with 5 params and depth 4 passed the lint" ;;
esac

echo "== fail closed: a lint whose tool can't be had FAILS, never skips =="
# An empty cache, an empty npm cache and an unreachable registry / Maven mirror: nothing to install from.
neg=$(mktemp -d "${XDG_CACHE_HOME:-$HOME/.cache}/cxneg.XXXXXX")
out=$(XDG_CACHE_HOME=$neg/c npm_config_cache=$neg/npm npm_config_registry=http://127.0.0.1:9/ npm_config_fetch_retries=0 \
      npm_config_fetch_timeout=3000 bash "$ROOT/shell/dev/lint-complexity.sh" 2>&1); rc=$?
[ $rc = 1 ] && echo "$out" | grep -q "FAIL complexity: npm ci" && ok "TS lint without eslint and no registry: exit 1, says why" \
  || { bad "TS lint without eslint and no registry: exit $rc (must be 1)"; echo "$out" | head -5 | sed 's/^/       /'; }
if [ $LK = 1 ] && command -v docker >/dev/null; then
  out=$(XDG_CACHE_HOME=$neg/c DETEKT_MIRROR=http://127.0.0.1:9 bash "$ROOT/targets/android/lint-complexity.sh" 2>&1); rc=$?
  [ $rc = 1 ] && echo "$out" | grep -q "couldn't fetch detekt" && ok "Kotlin lint without detekt and no network: exit 1, says why" \
    || { bad "Kotlin lint without detekt and no network: exit $rc (must be 1)"; echo "$out" | head -5 | sed 's/^/       /'; }
fi
out=$(GATE_LINT=0 bash "$ROOT/shell/dev/lint-complexity.sh" 2>&1); rc=$?
[ $rc = 2 ] && ok "GATE_LINT=0 is the only skip (exit 2)" || bad "GATE_LINT=0: exit $rc (want 2)"
rm -rf "$neg"
fi

echo "== Kotlin (targets/android/app) =="
if [ $LK = 0 ]; then skipped Kotlin; else
out=$(bash "$ROOT/targets/android/lint-complexity.sh" 2>&1); rc=$?
case $rc in
    0) ok "detekt: no function over the limits beyond app/config/detekt-baseline.xml, no stale ids" ;;
    2) echo "  skip - $out" ;;
    *) bad "kotlin complexity lint"; echo "$out" | sed 's/^/       /' | head -30 ;;
esac
fi

echo "== Rust (apps/*/module) =="
if [ $LR = 0 ]; then skipped Rust; else
out=$(bash "$ROOT/tools/lint/rust-complexity.sh" 2>&1); rc=$?
case $rc in
    0) ok "clippy: no count above tools/lint/rust-complexity-baseline.txt, none paid off unpruned" ;;
    2) echo "  skip - $out" ;;
    *) bad "rust complexity lint"; echo "$out" | sed 's/^/       /' | head -30 ;;
esac
fi

echo "== Bash (bin/, lib/, build/) =="
cd "$ROOT" || exit 1
if [ $LB = 0 ]; then skipped Bash; else
files=()   # bash 3.2 (the Mac): no mapfile
while IFS= read -r f; do files+=("$f"); done < <( { grep -lE '^#!\s*(/usr)?/bin/(env +)?(ba)?sh\b' bin/* 2>/dev/null; git ls-files 'lib/**/*.sh' 'lib/*.sh' 'build/*.sh' 'sources/**/*.sh'; } | sort -u)
if out=$(python3 build/complexity.py --check "${files[@]}" 2>&1); then ok "bash CC ratchet (build/complexity-budget.txt)"
else bad "bash CC ratchet"; echo "$out" | tail -15 | sed 's/^/       /'; fi

files=()
while IFS= read -r f; do files+=("$f"); done < <( { git ls-files '*.sh' | grep -vE 'third_party|/reference/|/vendor/|node_modules'; grep -lE '^#!\s*(/usr)?/bin/(env +)?(ba)?sh\b' bin/* 2>/dev/null; } | sort -u)
if out=$(python3 build/complexity.py --check-length "${files[@]}" 2>&1); then ok "shell function length <= 60 for new functions (build/function-length-budget.txt)"
else bad "shell function length"; echo "$out" | grep -v "lower it" | tail -15 | sed 's/^/       /'; fi
fi

echo ""
echo "== Results: $PASS passed, $FAIL failed =="
[[ $FAIL -eq 0 ]]
