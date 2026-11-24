#!/bin/bash
# lanes: emu phone
# scroll-own.sh [OUT]: who owns a drag on home (shell/ui/scrollown.ts, gesture.ts claimSideways, the host's
# HomePullAxis.kt; the user 11-23: "some widgets have a left/right scroller, but using it changes the home PAGE instead
# of scrolling the widget's content"; "scrolling the recent-apps bar on home SOMETIMES activates the notification screen"):
#   1. a diagonal drag (~35 deg off the horizontal) along the dock / its recent-apps strip, 5x: the shade's window never
#      shows (mid-drag dumpsys) - logcat PowosShade around it;
#   2. a widget scroller on the page on screen (a DOM element in a tile with more to show sideways, or an Android widget
#      whose frame lists a sideways native scroller), if there is one: a sideways drag scrolls it (DOM: scrollLeft) and
#      home's page stays; then dragged back;
#   3. a straight pull down on home's body still opens the shade (regression), swiped shut.
# Injected input + read-only CDP in a free window; Home after. Exit 1 + "FAIL:" on a failed step, 3 on a real touch.
# Headless twin: shell/dev/gate.mjs home-scroll-own.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"
OUT=${1:-$HOME/.cache/powos-verify/scroll-own-$(date +%m%d-%H%M)}; mkdir -p "$OUT"
L=$HOME/.cache/powos-verify.lock
sh_() { "$A" shell "su -c '$*'" 2>/dev/null | tr -d '\r'; }
irq() { sh_ "awk '\''/touch-0/{s+=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9} END{print s}'\'' /proc/interrupts"; }
q() { "$T/cdp.sh" eval home "$1" 2>/dev/null | tail -1 | tr -d '"\\\r'; }
shade_shown() { sh_ "dumpsys window windows | grep -E \"Window #.*PowOS shade\" -A20 | grep -c mViewVisibility=0x0"; }
. "$here/window-lock.sh"; window_lock scroll-own 120 "${MAX_WAIT:-10800}"
trap 'sh_ "am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"' EXIT
I0=$(irq); FAILS=0
chk() { [ "$(irq)" = "$I0" ] || { echo "STOP: a real touch at $1"; exit 3; }; }
step() { echo "== $*" | tee -a "$OUT/log.txt"; }
fail() { echo "FAIL: $*" | tee -a "$OUT/log.txt"; FAILS=$((FAILS + 1)); }
# drag <x0> <y0> <dx per step> <dy per step>: 10 moves; prints the shade windows shown mid-drag.
drag() { sh_ "input motionevent DOWN $1 $2"; for i in 1 2 3 4 5 6 7 8 9 10; do sh_ "input motionevent MOVE $(($1 + i * $3)) $(($2 + i * $4))"; done
  local mid; mid=$(shade_shown); sh_ "input motionevent UP $(($1 + 10 * $3)) $(($2 + 10 * $4))"; sleep 1; echo "${mid:-0}"; }

s=$(sh_ "dumpsys power | sed -n s/.*mWakefulness=//p | head -1")
[ "$s" = Awake ] || { echo "the screen is $s - not woken (rule); nothing done"; exit 3; }
if sh_ "dumpsys window | grep -m1 mCurrentFocus" | grep -qi "PowosLock"; then
  wh=$(sh_ "wm size" | sed -nE 's/.*(Override|Physical) size: ([0-9]+)x([0-9]+).*/\2 \3/p' | tail -1)
  sh_ "input swipe $((${wh% *} / 2)) $((${wh#* } * 9 / 10)) $((${wh% *} / 2)) $((${wh#* } / 4)) 300"; sleep 1.5
fi
sh_ "am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; sleep 1.5; chk home
[ "$(q '!!document.querySelector(".pages")')" = true ] || { fail "home's page isn't up"; exit 1; }
D=$(q '(()=>{const e=document.querySelector(".dock-pages, .dock");if(!e)return "";const r=e.getBoundingClientRect(),d=devicePixelRatio;return Math.round((r.x+r.width*0.25)*d)+" "+Math.round((r.y+r.height*0.35)*d)+" "+Math.round(r.width*d)})()')
W=$(sh_ "wm size" | sed -nE 's/.*(Override|Physical) size: ([0-9]+)x([0-9]+).*/\2/p' | tail -1)

step "1. diagonal drags along the dock's recent-apps strip: never the shade"
if [ -z "$D" ]; then fail "no dock on home"; else
  set -- $D; sh_ "logcat -c"
  for k in 1 2 3 4 5; do
    m=$(drag "$1" "$2" $(($3 / 40)) $(($3 / 56))); chk "dock drag $k"
    [ "$m" = 0 ] || fail "diagonal dock drag $k: the shade's window showed mid-drag"
    [ "$(shade_shown)" = 0 ] || { fail "diagonal dock drag $k left the shade open"; sh_ "input keyevent 4"; sleep 1; }
  done
  sh_ "logcat -d -v time | grep -E \"PowosShade|PowosGestures\" | tail -20" > "$OUT/dock.log"
fi

step "2. a widget's sideways scroller scrolls, home's page stays"
# Read-only: the scroller is found again by its index among the tiles' elements (nothing is written into the page).
ALL='[...document.querySelectorAll(".page:not(.away) .home-tile *")]'
SC="(()=>{const v=(r)=>r.left>=0&&r.right<=innerWidth&&r.top>=0&&r.bottom<=innerHeight;const all=$ALL;for(let i=0;i<all.length;i++){const e=all[i],s=getComputedStyle(e);if(!/auto|scroll/.test(s.overflowX)||e.scrollWidth<=e.clientWidth+8)continue;const r=e.getBoundingClientRect();if(r.width<80||!v(r))continue;const d=devicePixelRatio;return Math.round((r.x+r.width*0.8)*d)+' '+Math.round((r.y+r.height/2)*d)+' '+Math.round(r.width*d)+' '+i}return ''})()"
P=$(q "$SC")
if [ -z "$P" ]; then echo "no widget with a sideways scroller on the page on screen: step skipped" | tee -a "$OUT/log.txt"; else
  set -- $P
  pg0=$(q '(()=>{const t=document.querySelector(".page-track");return t?Math.round(t.getBoundingClientRect().left):0})()')
  l0=$(q "${ALL}[$4]?.scrollLeft|0")
  drag "$1" "$2" -$(($3 / 18)) 1 >/dev/null; chk scroller
  l1=$(q "${ALL}[$4]?.scrollLeft|0")
  pg1=$(q '(()=>{const t=document.querySelector(".page-track");return t?Math.round(t.getBoundingClientRect().left):0})()')
  echo "scrollLeft $l0 -> $l1, track $pg0 -> $pg1" | tee -a "$OUT/log.txt"
  [ "${l1:-0}" -gt "${l0:-0}" ] || fail "a sideways drag on the widget's scroller didn't scroll it"
  [ "$pg1" = "$pg0" ] || fail "a sideways drag on the widget's scroller turned home's page"
  drag $(($1 - $3 / 2)) "$2" $(($3 / 18)) 1 >/dev/null
fi

step "3. a straight pull down on home's body still opens the shade"
H=$(sh_ "wm size" | sed -nE 's/.*(Override|Physical) size: ([0-9]+)x([0-9]+).*/\3/p' | tail -1)
m=$(drag $((W / 2)) $((H * 30 / 100)) 1 $((H * 4 / 100))); chk pull
[ "$m" != 0 ] || fail "a straight pull down on home didn't show the shade's window"
sh_ "input swipe $((W / 2)) $((H * 80 / 100)) $((W / 2)) $((H * 15 / 100)) 250"; sleep 1.2
[ "$(shade_shown)" = 0 ] || sh_ "input keyevent 4"

[ "$FAILS" = 0 ] && echo "PASS: scroll ownership on home ($OUT)" || { echo "FAIL: $FAILS step(s) ($OUT)"; exit 1; }
