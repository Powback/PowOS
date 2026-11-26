#!/bin/bash
# gate.sh's composed tree (dry: GATE_SCOPE_DRY + GATE_COMPOSE_DUMP) in a throwaway sparse clone of this checkout: an
# agent's default gate tests HEAD + the uncommitted shell changes (modified, staged, untracked, deleted); --head and a
# push naming its files test HEAD (+ those files) and say which uncommitted files they leave out. ~10 s.
# shellcheck disable=SC2034  # out is read inside ok's eval strings
set -uo pipefail
D=$(cd "$(dirname "$0")" && pwd); top=$(git -C "$D" rev-parse --show-toplevel)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
ok() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=1; fi; }
git clone -q --no-checkout --shared "$top" "$T/r" && git -C "$T/r" sparse-checkout set --no-cone /shell/ /tools/ >/dev/null &&
  git -C "$T/r" checkout -q "$(git -C "$top" rev-parse HEAD)" || { echo "FAIL clone"; exit 1; }
# The gate under test is this checkout's (maybe uncommitted) gate.sh: committed in the clone, so it isn't itself a change.
cp "$D/gate.sh" "$T/r/shell/dev/gate.sh" && git -C "$T/r" -c user.name=t -c user.email=t@t commit -qam "gate under test" >/dev/null 2>&1
git -C "$T/r" update-ref refs/remotes/origin/main HEAD
R=$T/r/shell
run() { rm -rf "$T/dump"; (cd "$T/r" && GATE_SCOPE_DRY=1 GATE_NOCACHE=1 GATE_COMPOSE_DUMP=$T/dump bash shell/dev/gate.sh "$@" 2>&1); }
echo '/* uncommitted */' >> "$R/theme.css"                 # modified, unstaged
echo 'export const x = 1;' > "$R/ui/zz-new.ts"              # untracked
echo '// staged' >> "$R/app.tsx"; git -C "$T/r" add shell/app.tsx   # staged
del=$(cd "$R" && git ls-files ui | grep '\.css$' | head -1); rm "$R/$del"   # deleted
out=$(run)
ok "default: says it tests HEAD + 4 uncommitted" '[[ "$out" == *"tests HEAD + 4 uncommitted shell file(s)"* ]]'
ok "default: modified file composed in" 'tail -1 "$T/dump/theme.css" | grep -q uncommitted'
ok "default: untracked file composed in" '[ -f "$T/dump/ui/zz-new.ts" ]'
ok "default: staged file composed in" 'tail -1 "$T/dump/app.tsx" | grep -q staged'
ok "default: deleted file gone" '[ ! -e "$T/dump/$del" ]'
out=$(run --head)
ok "--head: HEAD only" '! tail -1 "$T/dump/theme.css" | grep -q uncommitted && [ ! -f "$T/dump/ui/zz-new.ts" ] && [ -e "$T/dump/$del" ]'
ok "--head: names what it leaves out" '[[ "$out" == *"NOTE - 4 uncommitted shell file(s) are NOT in this run (--head)"* ]]'
out=$(run ui/zz-new.ts)
ok "named file: composed in, the rest left out and said" '[ -f "$T/dump/ui/zz-new.ts" ] && ! tail -1 "$T/dump/theme.css" | grep -q uncommitted && [[ "$out" == *"NOT in this run (named files only)"* ]]'
git -C "$T/r" reset -q && git -C "$T/r" checkout -q -- shell && rm -f "$R/ui/zz-new.ts"
out=$(run)
ok "clean tree: no note" '[[ "$out" != *"uncommitted"* ]]'
[ $fails = 0 ] && echo "gate-tree-test: pass" || echo "gate-tree-test: FAIL"
exit $fails
