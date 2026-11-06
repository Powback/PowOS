#!/bin/bash
# bf-resize.sh's G1 test (board task games-resize-live-to-their-container-portrait-la): the game's X window must BE its
# screen's size (within 1 % per side), not just its shape - the old aspect-only match passed a half-size window
# (1134x1220 on the 2268x2440 inner screen) and a 314x208 Unity first map on a wide screen. Also: the start doesn't
# wait out the 130 s sleep grace (GRACE_S=0), the wait that ran the 10-28 check out of its 300 s budget.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd); V=$ROOT/tools/phone/verify
pass=0 fail=0
ok() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $1: got '$2', want '$3'"; fi; }
f=$(mktemp); trap 'rm -f "$f"' EXIT
sed -n '/^fits() {/,/; }$/p' "$V/bf-resize.sh" > "$f"
ok "fits() found" "$(grep -c '^fits()' "$f")" 1
. "$f"
fit() { fits "$1" "$2" && echo yes || echo no; }
ok "inner, 1 px short" "$(fit 2268x2439 2268x2440)" yes
ok "inner, exact" "$(fit 2268x2440 2268x2440)" yes
ok "inner landscape" "$(fit 2440x2268 2440x2268)" yes
ok "cover landscape" "$(fit 2484x1116 2484x1116)" yes
ok "cover portrait" "$(fit 1116x2484 1116x2484)" yes
ok "half size (scaled)" "$(fit 1134x1220 2268x2440)" no
ok "launch size kept" "$(fit 314x208 2484x1116)" no
ok "not rotated" "$(fit 2268x2440 2440x2268)" no
ok "cover size on inner" "$(fit 2484x1116 2440x2268)" no
ok "no window" "$(fit 0x0 2268x2440)" no
ok "no screen" "$(fit 2268x2440 '')" no
ok "start without the grace" "$(grep -c 'GRACE_S=0 bash' "$V/bf-resize.sh")" 1
ok "fold-phone honours GRACE_S" "$(grep -c 'g=${GRACE_S:-130}' "$V/bf-fold-phone.sh")" 1
echo "Results: $pass passed, $fail failed"
[ $fail = 0 ]
