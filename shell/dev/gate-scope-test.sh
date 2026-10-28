#!/bin/bash
# gate.sh's scope (dev/gate-scope.map), dry (GATE_SCOPE_DRY=1: prints the scene filter, runs nothing): a CSS-only change
# skips tsc and runs the mapped scenes, an unmapped file / --all / a TS change keeps every scene (and tsc), repo-style
# paths work (f305), every map regex is valid.
set -uo pipefail
D=$(cd "$(dirname "$0")" && pwd); G=$D/gate.sh; fails=0
ok() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=1; fi; }
dry() { GATE_SCOPE_DRY=1 GATE_NOCACHE=1 bash "$G" "$@" 2>&1 | grep '^gate: GATE_ONLY'; }
ok "pet.css: pet scene only + boots, no tsc" '[[ "$(dry ui/pet.css)" == *"|^pet$"* && "$(dry ui/pet.css)" == *"skip_tsc=1" ]]'
ok "repo-style path works (f305)" '[[ "$(dry shell/ui/pet.css)" == *"|^pet$"* ]]'
ok "a .ts change keeps tsc" '[[ "$(dry ui/desktops.ts)" == *"skip_tsc=0" ]]'
ok "unmapped file: every scene" '[[ "$(dry ui/grid.tsx)" == "gate: GATE_ONLY= skip_tsc=0" ]]'
ok "--all: every scene" '[[ "$(dry --all ui/pet.css)" == "gate: GATE_ONLY= skip_tsc=0" ]]'
ok "ship gate: every scene" '[[ "$(GATE_PRIORITY=ship dry ui/pet.css)" == "gate: GATE_ONLY= skip_tsc=0" ]]'
ok "two mapped files: both filters" '[[ "$(dry ui/pet.css ui/desktop.css)" == *"^pet$|^(desktops"* ]]'
ok "shell.css: all but apps" '[[ "$(dry ui/shell.css)" == *"(?!app )"* ]]'
# Every regex in the map is valid JavaScript (an invalid one would crash gate.mjs).
while IFS= read -r re; do
  [[ "$re" =~ ^(none|ALL)$ ]] && continue
  node -e "new RegExp(process.argv[1])" "$re" 2>/dev/null || { echo "FAIL bad regex $re"; fails=1; }
done < <(grep -vE '^\s*(#|$)' "$D/gate-scope.map" | sed -E 's/^[^[:space:]]+[[:space:]]+//' | grep -vE '^(none|ALL)$')
exit $fails
