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
# Time: one play run is ~3.5 min, under the queue's 300 s budget (BUDGET_S) with no screenrecord (BF_REC_S=0: its 48 MB
# pull + the Mac's docker ffmpeg decode in "comparing play" took the 11-10 07:01 run past it - and this check needs no
# stale-frame numbers). Its own deadline, BUDGET_S - 50 s: bf-pacing is stopped (its trap closes the game, ~25 s) and
# the check FAILs with the step it hung at, so it never reaches the queue's kill without a reason or with the game up.
set -uo pipefail
T0=$(date +%s) BUDGET_S=${BUDGET_S:-300}
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
# kids <pid>: TERM it and everything under it (the adb call bf-pacing waits on: adb.sh -> docker exec, whose pipe would
# keep bf-pacing's `| tr` waiting) - bash runs bf-pacing's trap only once that call returns.
kids() { local c; for c in $(pgrep -P "$1"); do kids "$c"; done; kill -TERM "$1" 2>/dev/null; }
dl=$(( T0 + BUDGET_S - 50 ))
BF_REC_S=0 BUDGET_S=$(( dl - $(date +%s) )) INPUT=touch "$here/bf-pacing.sh" play > "$OUT/bf-pacing.txt" 2>&1 &
# Into the job log as it goes; not a `| tee` / >(tee): that tee would be under bf-pacing's pid and die with kids below.
pid=$! late=; tail -n +1 -f "$OUT/bf-pacing.txt" & tl=$!
while kill -0 $pid 2>/dev/null; do
  [ "$(date +%s)" -lt "$dl" ] || { late=$(grep '^-- ' "$OUT/bf-pacing.txt" | tail -1 | cut -c13-)
    echo "-- $(date +%T) deadline ($(( dl - T0 )) s): bf-pacing still at \"$late\" - stopping it, it closes the game"
    kill -TERM $pid; for c in $(pgrep -P $pid); do kids $c; done; break; }
  sleep 2
done
wait $pid; rc=$?; sleep 1; kill $tl 2>/dev/null  # tail's last lines first
# Only the lines this check reads, filtered on the phone (the whole log tail was ~5k lines over adb).
rs "tail -n +$((l0 + 1)) $LOG | grep -E 'BUG|Xwayland touch:'" > "$OUT/session.log"
[ -n "$late" ] && { echo "FAIL timeout at step: $late (bf-pacing past this check's ${BUDGET_S}s budget minus 50 s; game closed by its trap; artefacts $OUT)"; exit 1; }
grep -q "transport unavailable" "$OUT/bf-pacing.txt" && { echo "ENV: the adb transport went away mid-run (powos-vadb) - see $OUT/bf-pacing.txt"; exit 5; }
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
