#!/bin/bash
# lanes: phone
# needs: kwin
# game-input-alive.sh [OUT] (Mac side; board game-runs-and-renders-but-input-stops-reaching-i): input keeps reaching a
# running game. The stalls followed Xwayland's BUG at Xi/exevents.c:1396 (RetrieveTouchDeliveryData: a touch listener
# whose client deselected mid-sequence - Wine on Broforce's focus flips - kept as an owner that never ends, so every
# later touch went nowhere). xwayland-kgsl 24.1.13-13 (0017) rejects that listener instead and logs "Xwayland touch:".
#   1. the installed xwayland-kgsl is 24.1.13-13 or newer (else ENV: queue xwayland-install.sh first);
#   2. INPUT=touch bf-pacing.sh play: Broforce started through the queue's own path, taken into a level by the
#      on-screen pad's gamepad (bf-play.sh: pad -> Steam Input -> the game), one injected touch per second over the
#      30 s measurement - the touch path that used to stall; bf-pacing's own validity rules (game on screen) apply;
#   3. the session log (hyprland.log, KWin's + Xwayland's stderr) over that run: no "BUG" at exevents.c, and the
#      game kept presenting after the touches (bf-pacing's result line has an fps).
# Prints "Xwayland touch: <n> lines" (0 is fine: the race needs a focus flip mid-touch) and the bf-pacing result.
# Exit: 0 passed; 1 FAIL; 3 not now (bf-pacing's own 3: a real touch / not on screen); 5 can't run.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..
OUT=${1:-$HOME/.cache/powos-verify/game-input-alive-$(date +%m%d-%H%M)}; mkdir -p "$OUT"
LOG=/data/powos/root/run/powos-app/hyprland.log
MIN=24.1.13-13
rs() { printf '%s\n' "$1" > "$OUT/r.sh"; "$T/root.sh" "$OUT/r.sh" 2>/dev/null | grep -v "file pushed" | tr -d '\r'; }

v=$(rs 'pacman -Q xwayland-kgsl 2>/dev/null | cut -d" " -f2' | tail -1)
[ -n "$v" ] || { echo "ENV: no xwayland-kgsl installed"; exit 5; }
# vercmp's rule for pkgver-pkgrel: sort -V puts the older first
[ "$(printf '%s\n%s\n' "$MIN" "$v" | sort -V | head -1)" = "$MIN" ] ||
  { echo "ENV: xwayland-kgsl $v is older than $MIN: queue tools/phone/verify/xwayland-install.sh $MIN first"; exit 5; }
echo "xwayland-kgsl $v"

l0=$(rs "wc -l < $LOG" | tail -1); l0=${l0:-0}
INPUT=touch "$here/bf-pacing.sh" play 2>&1 | tee "$OUT/bf-pacing.txt"
rc=${PIPESTATUS[0]}
rs "tail -n +$((l0 + 1)) $LOG" > "$OUT/session.log"
[ "$rc" = 3 ] && { echo "not now: bf-pacing exit 3"; exit 3; }
[ "$rc" = 5 ] && { echo "ENV: bf-pacing couldn't start the game"; exit 5; }

fails=""
bugs=$(grep -c -E "BUG.*exevents\.c|exevents\.c:[0-9]+.*BUG" "$OUT/session.log")
touch_lines=$(grep -c "Xwayland touch:" "$OUT/session.log")
echo "Xwayland touch: $touch_lines lines; exevents BUG lines: $bugs"
grep -m3 "Xwayland touch:" "$OUT/session.log"
[ "$bugs" = 0 ] || { fails="$fails exevents-BUG($bugs)"; grep -m3 -E "BUG" "$OUT/session.log"; }
grep -q "^play: play [0-9]* keys" "$OUT/bf-pacing.txt" || fails="$fails play-never-reached-the-game"
[ "$rc" = 0 ] || fails="$fails bf-pacing-rc=$rc"
if [ -n "$fails" ]; then
  echo "FAIL:$fails (artefacts $OUT)"; exit 1
fi
echo "PASS: input reached Broforce through play + touches, no exevents BUG (artefacts $OUT)"
