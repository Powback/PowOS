#!/bin/bash
# lanes: emu phone
# unfolded-checks.sh [OUT]: the owed UNFOLDED checks in one go, for a phone left unattended (the user said so):
#   inner screen forced (cmd device_state state 3 = open), PowOS's lock face swiped away (no PIN), home's merged tiles,
#   the keyboard padding on PowOS AI's page and in the side-button overlay (assist), the chat's image thumbnails;
#   every capture through tools/phone/shot.sh (the ON display; refuses off/black). Restores after: Back out of what it
#   opened, home, `cmd device_state state reset` (the fold state follows the hinge again - not a forced 0, which would
#   blank the inner screen of a phone that is physically open).
# Injected input only; stops at once (and restores) if a real touch comes (touch-panel IRQs move).
# Captures + log: OUT (default ~/.cache/powos-verify/unfolded-<time>), attached to the owners' board tasks.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"; ROOT=$(cd "$T/../.." && pwd)
OUT=${1:-$HOME/.cache/powos-verify/unfolded-$(date +%m%d-%H%M)}; mkdir -p "$OUT"
L=$HOME/.cache/powos-verify.lock
B() { python3 "$ROOT/lib/ai/agents/powos-agents-cli" "$@" >/dev/null 2>&1; }
sh_() { "$A" shell "su -c '$*'" 2>/dev/null | tr -d '\r'; }
irq() { sh_ "awk '/touch-0/{s+=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9} END{print s}' /proc/interrupts"; }
restore() {
  echo "== restore"
  sh_ "input keyevent 4; input keyevent 4; am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null; cmd device_state state reset"
}
# A free window, then the verify lock (window-lock.sh; under queue.sh, LOCK_HELD=1: the runner holds both already).
. "$here/window-lock.sh"; window_lock unfolded-checks 120 "${MAX_WAIT:-10800}"
trap 'restore; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"' EXIT
I0=$(irq)
chk() { [ "$(irq)" = "$I0" ] || { echo "STOP: a real touch at $1 - restoring"; exit 3; }; }
shot() { "$T/shot.sh" "$OUT/$1.png" 2>&1 | tee -a "$OUT/log.txt"; }
step() { echo "== $*" | tee -a "$OUT/log.txt"; }

step "screen state"; s=$(sh_ "dumpsys power | sed -n s/.*mWakefulness=//p | head -1"); echo "$s"
[ "$s" = Awake ] || { echo "the screen is $s - not woken (rule); nothing done"; exit 3; }
step "inner screen"; sh_ "cmd device_state state 3"; sleep 3; chk unfold
WH=$(sh_ "wm size" | sed -nE 's/.*(Override|Physical) size: ([0-9]+)x([0-9]+).*/\2 \3/p' | tail -1)
W=${WH% *}; H=${WH#* }; echo "on: ${W}x${H}"
[ "${W:-0}" -gt 0 ] && [ "${H:-0}" -gt 0 ] || { echo "ENV: no screen size (wm size) - stopping before any input"; exit 5; }
[ "$W" -gt 2000 ] || echo "WARN: display 0 isn't the inner screen (${W}x${H})"
x() { echo $(( W * $1 / 1000 )); }; y() { echo $(( H * $1 / 1000 )); }

step "lock face"
# Android's keyguard (its window is "NotificationShade" - not named lock) behind PowOS's face: while it shows, the
# screen dozes after ~10 s, so dismiss it first (no PIN: wm dismiss-keyguard), then swipe PowOS's face if it's up.
kg() { sh_ "dumpsys window policy | grep -m1 -E \"mIsShowing=\""; }
if kg | grep -q true; then
  sh_ "wm dismiss-keyguard"; sleep 1.5
  kg | grep -q true && { sh_ "input swipe $(x 500) $(y 900) $(x 500) $(y 250) 300"; sleep 1.5; }
  kg | grep -q true && { shot lock-still-showing; echo "ENV: the keyguard didn't go (a PIN?) - stopping"; exit 5; }
fi
if sh_ "dumpsys window | grep -m1 mCurrentFocus" | grep -qi "PowosLock"; then sh_ "input swipe $(x 500) $(y 900) $(x 500) $(y 250) 300"; sleep 1.5; fi
chk lock
step "home: merged tiles"; sh_ "am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; sleep 1.5; chk home
# The 22:25 capture was the app drawer, not home (the lock face's swipe up had opened it): Back closes it first.
q() { "$T/cdp.sh" eval "" "$1" 2>/dev/null | tr -d '"\\'; }
for _ in 1 2; do [ "$(q '!!document.querySelector(".home.open")')" = true ] || break; sh_ "input keyevent 4"; sleep 1; done; chk home-drawer
shot home-unfolded
# Read only: each merged face and seam piece (page px: left top right bottom), so the log says whether they join exactly.
q 'JSON.stringify([...document.querySelectorAll(".page .home-tile.joined, .page .seam")].map(t=>{const p=t.closest(".page").getBoundingClientRect(),r=(t.querySelector(":scope > .tile")||t).getBoundingClientRect(),f=(n)=>Math.round(n*10)/10;return [(t.dataset.key||t.className).slice(0,24),f(r.left-p.left),f(r.top-p.top),f(r.right-p.left),f(r.bottom-p.top)]}))' | tee -a "$OUT/log.txt"

field() { # page [need-ai] -> "x y" of the compose field's centre in device px, only if it is on screen (read only, CDP)
  "$T/cdp.sh" eval "$1" 'JSON.stringify((()=>{const e=document.querySelector(".ai-compose textarea, .ai-compose input");if(!e)return [0,0];'"${2:+const a=e.closest(\".ai-screen\");if(a&&!a.classList.contains(\"shown\"))return [0,0];}"'const r=e.getBoundingClientRect();if(r.width<20||r.height<10||r.x<0||r.y<0||r.x+r.width>innerWidth+1||r.y+r.height>innerHeight+1)return [0,0];return [Math.round((r.x+r.width/2)*devicePixelRatio),Math.round((r.y+r.height/2)*devicePixelRatio)]})())' 2>/dev/null | tr -dc '0-9,' | tr ',' ' '
}
step "PowOS AI page + keyboard"; sh_ "input swipe $(x 300) $(y 500) $(x 900) $(y 500) 350"; sleep 1.5; chk ai
shot ai-unfolded
set -- $(field home ai); if [ "${1:-0}" -gt 0 ]; then
  sh_ "input tap $1 $2"; sleep 1.5; chk kbd; shot ai-keyboard-unfolded; sh_ "input keyevent 4"; sleep 0.8
else echo "no compose field found on the AI page"; fi
step "chat thumbnails"; sh_ "input swipe $(x 500) $(y 400) $(x 500) $(y 750) 300"; sleep 1.2; chk chat; shot ai-chat-thumbnails-unfolded
sh_ "input swipe $(x 900) $(y 500) $(x 150) $(y 500) 300"; sleep 1; chk back-home

step "side-button overlay (assist) + keyboard"
sh_ "cmd voiceinteraction show 2>/dev/null || am start -a android.intent.action.ASSIST >/dev/null"; sleep 2; chk assist
shot assist-unfolded
set -- $(field assist); if [ "${1:-0}" -gt 0 ]; then
  sh_ "input tap $1 $2"; sleep 1.5; chk assist-kbd; shot assist-keyboard-unfolded; sh_ "input keyevent 4"; sleep 0.6
else echo "no compose field found in the assist overlay"; fi
sh_ "input keyevent 4"; sleep 0.8

restore; trap - EXIT; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"
attach() { local t=$1; shift; for f in "$@"; do [ -f "$OUT/$f" ] || continue
  "$T/review-image.sh" "$OUT/$f" >/dev/null && B task set "$t" --image "/home/powos/design-qa/$(basename "$f")" && echo "attached $f -> $t"; done; }
for f in "$OUT"/*.png; do [ -f "$f" ] && mv "$f" "$OUT/unf-$(date +%H%M)-$(basename "$f")"; done
cd "$OUT" || exit 1
attach merged-widgets-misaligned-ragged-edges-unfolded *home-unfolded.png
attach keyboard-compose-bottom-padding-in-ai-overlay *ai-keyboard-unfolded.png *assist-keyboard-unfolded.png *assist-unfolded.png
attach chat-sent-images-as-thumbnails *ai-chat-thumbnails-unfolded.png
attach owed-device-checks *home-unfolded.png *ai-unfolded.png
echo "artefacts: $OUT"
