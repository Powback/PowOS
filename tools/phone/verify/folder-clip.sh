#!/bin/bash
# folder-clip.sh [OUT]: a short screen recording of an app library folder opening (the morph out of its card) and
# closing (a tap outside) on the screen that's on, its frames for review (frame-*.png, the board task's --image when
# BOARD_TASK is set). Transient only: swipes to the last page, opens and closes a folder, Home after; no layout change.
# Exit 1 + "FAIL:" when the folder didn't open/close or the new folder view isn't live; 3 on a real touch (restored).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"
OUT=${1:-$HOME/.cache/powos-verify/folder-clip-$(date +%m%d-%H%M)}; mkdir -p "$OUT"
L=$HOME/.cache/powos-verify.lock
sh_() { "$A" shell "su -c '$*'" 2>/dev/null | tr -d '\r'; }
irq() { sh_ "awk '/touch-0/{s+=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9} END{print s}' /proc/interrupts"; }
restore() { sh_ "pkill -INT screenrecord; input keyevent 4; am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; }
. "$here/window-lock.sh"; window_lock folder-clip 120 "${MAX_WAIT:-10800}"
trap 'restore; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"' EXIT
I0=$(irq); FAILS=0
chk() { [ "$(irq)" = "$I0" ] || { echo "STOP: a real touch at $1 - restoring"; exit 3; }; }
fail() { echo "FAIL: $*" | tee -a "$OUT/log.txt"; FAILS=$((FAILS + 1)); }
q() { "$T/cdp.sh" eval home "$1" 2>/dev/null | tail -1 | tr -d '"\\\r'; }

s=$(sh_ "dumpsys power | sed -n s/.*mWakefulness=//p | head -1")
[ "$s" = Awake ] || { echo "the screen is $s - not woken (rule); nothing done"; exit 3; }
if sh_ "dumpsys window | grep -m1 mCurrentFocus" | grep -qi "PowosLock"; then
  wh=$(sh_ "wm size" | sed -nE 's/.*(Override|Physical) size: ([0-9]+)x([0-9]+).*/\2 \3/p' | tail -1)
  sh_ "input swipe $((${wh% *} / 2)) $((${wh#* } * 9 / 10)) $((${wh% *} / 2)) $((${wh#* } / 4)) 300"; sleep 1.5
fi
sh_ "am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; sleep 1.5; chk home
did=$(sh_ "dumpsys display" | sed -nE 's/.*DisplayDeviceInfo.*uniqueId="local:([0-9]+)", ([0-9]+) x ([0-9]+),.* state ON,.*/\1 \2 \3/p' | head -1)
set -- $did; [ $# -ge 3 ] || { echo "no display on"; exit 3; }; DID=$1; W=$2; H=$3

for _ in 1 2 3 4 5 6; do
  [ "$(q '(()=>{const l=document.querySelector(".page.library");return !!l&&Math.abs(l.getBoundingClientRect().left)<4})()')" = true ] && break
  sh_ "input swipe $((W * 8 / 10)) $((H * 45 / 100)) $((W * 2 / 10)) $((H * 45 / 100)) 220"; sleep 1; chk swipe
done
at=$(q '(()=>{const c=document.querySelector(".page.library .lib-card");if(!c||!document.querySelector(".lib-card .lib-count"))return "";const r=c.getBoundingClientRect(),d=devicePixelRatio;return Math.round((r.left+r.width/2)*d)+" "+Math.round((r.top+r.height/2)*d)})()')
[ -n "$at" ] || { fail "no app library card with the new markup (the folder morph isn't live yet?)"; exit 1; }
set -- $at
sh_ "screenrecord --display-id $DID --bit-rate 20000000 --time-limit 6 /data/local/tmp/folder-clip.mp4 >/dev/null 2>&1 &"
sleep 1.2; sh_ "input tap $1 $2"; sleep 1.4; chk open
[ "$(q '!!document.querySelector(".folder-view.open")')" = true ] || fail "the folder didn't open on a tap"
[ "$(q '[...document.querySelectorAll(".folder-view.open [style]")].filter(e=>e.style.transform||e.style.transition).length')" = 0 ] || fail "the open folder kept its morph's inline styles (it never came to rest)"
sh_ "input tap $((W / 2)) $((H / 14))"; sleep 1.4; chk close
[ "$(q '!!document.querySelector(".folder-view")')" = false ] || fail "a tap outside didn't close the folder"
sleep 2.5
"$A" pull /data/local/tmp/folder-clip.mp4 "$OUT/clip.mp4" >/dev/null 2>&1; sh_ "rm -f /data/local/tmp/folder-clip.mp4"
if [ -s "$OUT/clip.mp4" ]; then
  # Frames every 60 ms around the open and the close, scaled for review.
  ffmpeg -loglevel error -y -i "$OUT/clip.mp4" -vf "fps=16,scale=540:-2" "$OUT/frame-%03d.png"
  echo "frames: $(ls "$OUT"/frame-*.png 2>/dev/null | wc -l | tr -d ' ') in $OUT" | tee -a "$OUT/log.txt"
  if [ -n "${BOARD_TASK:-}" ]; then
    imgs=(); for f in $(ls "$OUT"/frame-*.png | awk 'NR>=18 && NR<=30 && NR%3==0 || NR>=40 && NR<=52 && NR%3==0'); do imgs+=(--image "$f"); done
    "$T/../../lib/ai/agents/powos-agents-cli" task set "$BOARD_TASK" "${imgs[@]}" >/dev/null 2>&1 || true
  fi
else fail "no recording pulled"; fi

restore; trap - EXIT; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"
echo "artefacts: $OUT"
[ "$FAILS" = 0 ] && echo "PASS: folder opens and closes as a morph (clip + frames)" || { echo "FAIL: $FAILS step(s)"; exit 1; }
