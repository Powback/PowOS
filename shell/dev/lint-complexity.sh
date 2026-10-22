#!/bin/bash
# The complexity lint for the shell's and the PowOS apps' TypeScript (shell/eslint.config.mjs): per function at most
# cyclomatic 10, cognitive 10 (sonarjs), nesting depth 3, 60 lines, 4 parameters.
#
# Existing violations are the baseline (ESLint's bulk suppressions: a count per file and rule):
# shell/dev/complexity-baseline.json for the shell, complexity-baseline-apps.json for apps/*/ui. It only shrinks:
#   - a violation beyond the baseline fails (new or changed code can't exceed the limits);
#   - an entry no longer needed fails until pruned (`--prune` rewrites the files; commit them with the refactor);
#   - an entry above HEAD's count fails (nobody re-baselines their way past it).
#
#   shell/dev/lint-complexity.sh [--dir DIR] [--apps] [--prune] [--report N] [FILE...]
#     --dir DIR   lint that shell instead of this one (the gate's composed copy); the baseline stays this tree's.
#     FILE...     only these (paths relative to the shell dir, e.g. what a push brings); default: everything.
#     --apps      also apps/*/ui (the PowOS apps' UIs; tier-1 and apps/install.sh).
#     --prune     drop baseline entries that are no longer needed (after a refactor), then check.
#     --report N  the N worst functions over the limits (baseline ignored), with the totals.
# Exit 0 clean, 1 findings, 2 couldn't run (no shell/node_modules: npm ci in shell/).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
SHELL_DIR=$(cd "$here/.." && pwd)
ROOT=$(cd "$SHELL_DIR/.." && pwd)
base=$here/complexity-baseline.json
abase=$here/complexity-baseline-apps.json
dir=$SHELL_DIR prune="" report="" apps="" files=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) dir=$(cd "$2" && pwd); shift 2 ;;
    --prune) prune=1; shift ;;
    --report) report=$2; shift 2 ;;
    --apps) apps=1; shift ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) files+=("$1"); shift ;;
  esac
done
eslint=$SHELL_DIR/node_modules/.bin/eslint
[ -x "$eslint" ] || { echo "     complexity lint: skipped (no shell/node_modules - npm ci in shell/)"; exit 2; }
cfg=$SHELL_DIR/eslint.config.mjs
targets=()
if [ ${#files[@]} -gt 0 ]; then
  for f in "${files[@]}"; do case "$f" in (*.ts|*.tsx|*.mjs|*.js) [ -f "$dir/$f" ] && targets+=("$f") ;; esac; done
  [ ${#targets[@]} -gt 0 ] || [ -n "$apps" ] || { echo "ok   complexity lint (nothing to lint)"; exit 0; }
else
  targets=(.)
fi
apptargets=()
for a in "$ROOT"/apps/*/ui; do [ -d "$a" ] && apptargets+=("apps/$(basename "$(dirname "$a")")/ui"); done

# lint <cwd> <baseline> <targets...> [-- eslint args...]: keys in the baseline are paths relative to <cwd>.
lint() {
  local cwd=$1 sup=$2; shift 2
  local t=() a=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do t+=("$1"); shift; done
  [ $# -gt 0 ] && shift
  a=("$@")
  [ ${#t[@]} -gt 0 ] || return 0
  (cd "$cwd" && "$eslint" --config "$cfg" --suppressions-location "$sup" --no-warn-ignored --no-error-on-unmatched-pattern --no-color ${a[@]+"${a[@]}"} "${t[@]}")
}

if [ -n "$report" ]; then
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  echo '{}' > "$tmp/none.json"
  lint "$dir" "$tmp/none.json" ${targets[@]+"${targets[@]}"} -- -f json > "$tmp/s.json" 2>/dev/null
  echo '[]' > "$tmp/a.json"
  [ -n "$apps" ] && lint "$ROOT" "$tmp/none.json" ${apptargets[@]+"${apptargets[@]}"} -- -f json > "$tmp/a.json" 2>/dev/null
  python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))+json.load(open(sys.argv[2]))))' \
    "$tmp/s.json" "$tmp/a.json" | python3 "$here/complexity-report.py" "$report" "$ROOT"
  exit 0
fi

# 1. The baselines never grow: no file/rule count above HEAD's.
grew=""
for b in "$base" "$abase"; do
  rel=shell/dev/$(basename "$b")
  [ -f "$b" ] && git -C "$ROOT" cat-file -e "HEAD:$rel" 2>/dev/null || continue
  grew+=$(git -C "$ROOT" show "HEAD:$rel" | python3 -c '
import json, sys
old = json.load(sys.stdin); new = json.load(open(sys.argv[1]))
for f, rules in new.items():
    for r, v in rules.items():
        was = old.get(f, {}).get(r, {}).get("count", 0)
        now = v["count"]
        if now > was: print(f"{sys.argv[2]}: {f} {r}: {was} -> {now}")
' "$b" "$rel")
done
[ -z "$grew" ] || { echo "$grew" | sed 's/^/FAIL complexity baseline grew (it only shrinks): /'; exit 1; }

# 2. The lint against the baselines. With FILEs, ESLint checks unused entries only for the files it lints.
if [ -n "$prune" ]; then
  lint "$dir" "$base" ${targets[@]+"${targets[@]}"} -- --prune-suppressions >/dev/null 2>&1
  [ -n "$apps" ] && lint "$ROOT" "$abase" ${apptargets[@]+"${apptargets[@]}"} -- --prune-suppressions >/dev/null 2>&1
fi
fail=0 out=""
o=$(lint "$dir" "$base" ${targets[@]+"${targets[@]}"} 2>&1) || { fail=1; out+="$o"$'\n'; }
if [ -n "$apps" ]; then o=$(lint "$ROOT" "$abase" ${apptargets[@]+"${apptargets[@]}"} 2>&1) || { fail=1; out+="$o"$'\n'; }; fi
if [ $fail = 0 ]; then echo "ok   complexity lint"; exit 0; fi
echo "$out" | grep -vE '^\s*$|problems? \(' | head -40 | sed 's/^/FAIL complexity: /'
echo "FAIL complexity: limits per function - cyclomatic 10, cognitive 10, depth 3, 60 lines, 4 params (shell/eslint.config.mjs)."
echo "FAIL complexity: split the function. Paid off old debt? shell/dev/lint-complexity.sh --prune and commit the baseline."
exit 1
