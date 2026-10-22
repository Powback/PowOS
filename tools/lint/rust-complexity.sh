#!/bin/bash
# The complexity lint for the PowOS apps' Rust modules (apps/*/module): clippy's cognitive_complexity (10),
# too_many_lines (60), too_many_arguments (4) and excessive_nesting (3) - thresholds in tools/lint/clippy.toml,
# the same limits as the TS and Kotlin lints. Runs in the rust:1-bookworm image apps/build.sh builds with, sharing
# its cargo cache volume (powos-apps-cargo) - nothing installed on the host.
#
# Old debt: tools/lint/rust-complexity-baseline.txt ("<count> <file> <lint>" - clippy names no function, so a count per
# file and lint, like the shell's). It only shrinks: a count above it fails, a count below it fails until --prune
# rewrites it (commit it with the refactor); tier-1 checks history doesn't raise it without [baseline-reset].
#
#   tools/lint/rust-complexity.sh [--prune] [--report] [APP...]   APP: apps/<app> names (default: every module)
# Exit 0 clean, 1 findings, 2 couldn't run (no docker).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
BASE=$HERE/rust-complexity-baseline.txt
prune="" report="" apps=()
while [ $# -gt 0 ]; do
  case "$1" in
    --prune) prune=1; shift ;;
    --report) report=1; shift ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
    *) apps+=("$(basename "$1")"); shift ;;
  esac
done
command -v docker >/dev/null || { echo "     rust complexity: skipped (no docker)"; exit 2; }
if [ ${#apps[@]} = 0 ]; then for m in "$ROOT"/apps/*/module/Cargo.toml; do [ -f "$m" ] && apps+=("$(basename "$(dirname "$(dirname "$m")")")"); done; fi
[ ${#apps[@]} -gt 0 ] || { echo "ok   rust complexity lint (no modules)"; exit 0; }
raw=$(docker run --rm --platform linux/arm64 --cpus 6 --memory 8g -v powos-apps-cargo:/cache -v "$ROOT/apps:/apps:ro" \
  -v "$HERE:/lint:ro" -e CARGO_HOME=/cache/cargo -e CLIPPY_CONF_DIR=/lint -e APPS="${apps[*]}" rust:1-bookworm bash -c '
  rustup component list --installed | grep -q clippy || rustup component add clippy >/dev/null 2>&1
  rustup target list --installed | grep -q wasm32-unknown-unknown || rustup target add wasm32-unknown-unknown >/dev/null 2>&1
  for a in $APPS; do cd /apps/$a/module || continue
    CARGO_TARGET_DIR=/cache/target-$a cargo clippy -q --release --target wasm32-unknown-unknown --message-format short -- \
      -A clippy::all -W clippy::cognitive_complexity -W clippy::too_many_lines -W clippy::too_many_arguments \
      -W clippy::excessive_nesting 2>&1 | sed "s|^src/|apps/$a/module/src/|"
  done' 2>&1) || { echo "     rust complexity: skipped (the clippy run failed)"; echo "$raw" | tail -5; exit 2; }
# "<file>:<l>:<c>: warning: <msg>" -> "<file> <lint>"
counts=$(echo "$raw" | sed -nE 's/^([^:]+):[0-9]+:[0-9]+: warning: (this block is too nested|the function has a cognitive complexity|this function has too many lines|this function has too many arguments).*/\1 \2/p' |
  sed -e 's/this block is too nested/excessive_nesting/' -e 's/the function has a cognitive complexity/cognitive_complexity/' \
      -e 's/this function has too many lines/too_many_lines/' -e 's/this function has too many arguments/too_many_arguments/' |
  sort | uniq -c | awk '{print $1, $2, $3}')
if [ -n "$report" ]; then
  echo "$raw" | grep -E "cognitive complexity|too many (lines|arguments)" | sort -t'(' -k2 -rn | head -10
  echo "functions/blocks over a limit: $(echo "$counts" | awk '{s+=$1} END{print s+0}') ($(echo "$counts" | awk '{a[$3]+=$1} END{for(k in a) printf "%s %d, ", k, a[k]}'))"
  exit 0
fi
# Only the apps linted this run are compared.
sel() { grep -E "^[0-9]+ apps/($(IFS='|'; echo "${apps[*]}"))/" || true; }
old=$( [ -f "$BASE" ] && sel < "$BASE" )
if [ -n "$prune" ]; then
  { [ -f "$BASE" ] && grep -vE "^[0-9]+ apps/($(IFS='|'; echo "${apps[*]}"))/" "$BASE"; echo "$counts"; } | grep . | sort -k2 > "$BASE.new"
  # never raise an entry by pruning: keep the lower of the two
  python3 - "$BASE" "$BASE.new" <<'PY'
import sys, os
def load(p):
    d = {}
    if os.path.exists(p):
        for l in open(p):
            n, f, r = l.split(); d[(f, r)] = int(n)
    return d
old, new = load(sys.argv[1]), load(sys.argv[2])
out = {k: (min(v, old[k]) if k in old else v) for k, v in new.items() if k in old or not old}
open(sys.argv[1], "w").writelines(f"{v} {f} {r}\n" for (f, r), v in sorted(out.items()))
os.remove(sys.argv[2])
PY
  old=$(sel < "$BASE")
fi
fail=0
while read -r n f r; do
  [ -n "$f" ] || continue
  was=$(echo "$old" | awk -v f="$f" -v r="$r" '$2==f && $3==r {print $1}')
  if [ "$n" -gt "${was:-0}" ]; then echo "FAIL rust complexity: $f $r: $n > baseline ${was:-0}"; echo "$raw" | grep "^$f:" | grep -iE "$(echo "$r" | sed 's/_/ /g; s/excessive nesting/too nested/; s/cognitive complexity/cognitive/')" | head -5 | sed 's/^/       /'; fail=1; fi
done <<< "$counts"
while read -r n f r; do
  [ -n "$f" ] || continue
  now=$(echo "$counts" | awk -v f="$f" -v r="$r" '$2==f && $3==r {print $1}')
  [ "${now:-0}" -lt "$n" ] && { echo "FAIL rust complexity: $f $r: paid off ($n -> ${now:-0}) - tools/lint/rust-complexity.sh --prune and commit the baseline"; fail=1; }
done <<< "$old"
[ $fail = 0 ] && echo "ok   rust complexity lint" || echo "FAIL rust complexity: limits per function - cognitive 10, 60 lines, 4 args, nesting 3 (tools/lint/clippy.toml)."
exit $fail
