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
#   3. a straight pull down on home's body still opens the shade (regression), swiped shut;
#   4. the app library's page (the user 11-24: "scrolling UP opens the notification center"): scrolled down by a drag up,
#      a drag down scrolls it back and the shade's window never shows.
# Injected input + read-only CDP in a free window; Home after. Exit 1 + "FAIL:" on a failed step, 3 on a real touch.
# Headless twin: shell/dev/gate.mjs home-scroll-own.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"
OUT=${1:-$HOME/.cache/powos-verify/scroll-own-$(date +%m%d-%H%M)}; mkdir -p "$OUT"
L=$HOME/.cache/powos-verify.lock
# Every device call capped (CAP s, default 40): a hung adb/CDP call fails the step instead of the whole check's budget.
cap() { perl -e 'alarm shift; exec @ARGV' "${CAP:-40}" "$@"; }
. "$(dirname "${BASH_SOURCE[0]}")/../su-quote.sh"  # su_q: a ' inside the command is safe
sh_() { cap "$A" shell "$(su_q "$*")" 2>/dev/null | tr -d '\r'; }
irq() { sh_ "awk '/touch-0/{s+=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9} END{print s}' /proc/interrupts"; }
q() { cap "$T/cdp.sh" eval home "$1" 2>/dev/null | tail -1 | tr -d '"\\\r'; }
shade_shown() { sh_ "dumpsys window windows | grep -E \"Window #.*PowOS shade\" -A20 | grep -c mViewVisibility=0x0"; }
. "$here/window-lock.sh"; window_lock scroll-own 120 "${MAX_WAIT:-10800}"
trap 'sh_ "am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"' EXIT
I0=$(irq); FAILS=0
chk() { [ "$(irq)" = "$I0" ] || { echo "STOP: a real touch at $1"; exit 3; }; }
fail() { echo "FAIL: $*" | tee -a "$OUT/log.txt"; FAILS=$((FAILS + 1)); }
# Home in front: brought back only when something else is (an `am start` HOME re-shows home, and for a few seconds after
# it - ~3-8 s on the emulator - the host doesn't take a pull on home's body yet: a false step-3 FAIL), then settled.
home_front() {
  sh_ "dumpsys window | grep -m1 mCurrentFocus" | grep -qE "ShellActivity|HomeShell" && { sleep 1; return; }
  sh_ "am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; sleep "${HOME_SETTLE_S:-8}"
}
# Each step has STEP_S (default 60) s: [late] says so and the step's remaining drags are skipped (FAIL, named).
STEP_S=${STEP_S:-60}; T0=$SECONDS
step() { echo "== $*" | tee -a "$OUT/log.txt"; T0=$SECONDS; SNAME=${*%%.*}; }
late() { [ $((SECONDS - T0)) -le "$STEP_S" ] && return 1; fail "step $SNAME over its ${STEP_S} s cap - rest of the step skipped"; return 0; }
pass() { echo "PASS step $SNAME: $*" | tee -a "$OUT/log.txt"; }
# drag <x0> <y0> <x1> <y1> [ms]: ONE adb call - a real-time `input swipe` (moves at the display's pace, so the host's
# 250 ms "moving down from the down" rule sees a real swipe; 12 adb calls of motionevents took seconds per move and
# made every pull a not-a-pull) with the shade window probed mid-swipe (at 60%); prints how many shade windows showed.
drag() { local ms=${5:-900}; local mid; mid=$(sh_ "input swipe $1 $2 $3 $4 $ms & sleep $(printf "%d.%03d" $((ms * 6 / 10000)) $((ms * 6 / 10 % 1000))); dumpsys window windows | grep -E \"Window #.*PowOS shade\" -A20 | grep -c mViewVisibility=0x0; wait"); sleep 1; echo "${mid:-0}" | tail -1; }

s=$(sh_ "dumpsys power | sed -n s/.*mWakefulness=//p | head -1")
[ "$s" = Awake ] || { echo "the screen is $s - not woken (rule); nothing done"; exit 3; }
if sh_ "dumpsys window | grep -m1 mCurrentFocus" | grep -qi "PowosLock"; then
  wh=$(sh_ "wm size" | sed -nE 's/.*(Override|Physical) size: ([0-9]+)x([0-9]+).*/\2 \3/p' | tail -1)
  sh_ "input swipe $((${wh% *} / 2)) $((${wh#* } * 9 / 10)) $((${wh% *} / 2)) $((${wh#* } / 4)) 300"; sleep 1.5
fi
home_front; chk home
[ "$(q '!!document.querySelector(".pages")')" = true ] || { fail "home's page isn't up"; exit 1; }
D=$(q '(()=>{const e=document.querySelector(".dock-pages, .dock");if(!e)return "";const r=e.getBoundingClientRect(),d=devicePixelRatio;return Math.round((r.x+r.width*0.25)*d)+" "+Math.round((r.y+r.height*0.35)*d)+" "+Math.round(r.width*d)})()')
W=$(sh_ "wm size" | sed -nE 's/.*(Override|Physical) size: ([0-9]+)x([0-9]+).*/\2/p' | tail -1)

step "1. diagonal drags along the dock's recent-apps strip: never the shade"
if [ -z "$D" ]; then echo "SKIP step 1: no dock on home (a dock button / search bar instead)" | tee -a "$OUT/log.txt"; else
  set -- $D; sh_ "logcat -c"; f0=$FAILS
  for k in 1 2 3 4 5; do
    late && break
    m=$(drag "$1" "$2" $(($1 + $3 / 4)) $(($2 + $3 / 6)) 500); chk "dock drag $k"
    [ "$m" = 0 ] || fail "diagonal dock drag $k: the shade's window showed mid-drag"
    [ "$(shade_shown)" = 0 ] || { fail "diagonal dock drag $k left the shade open"; sh_ "input keyevent 4"; sleep 1; }
  done
  sh_ "logcat -d -v time | grep -E \"PowosShade|PowosGestures\" | tail -20" > "$OUT/dock.log"
  [ "$FAILS" = "$f0" ] && pass "5 diagonal drags on the dock, the shade's window never showed"
fi

step "2. a widget's sideways scroller scrolls, home's page stays"
# Read-only: the scroller is found again by its index among the tiles' elements (nothing is written into the page).
ALL='[...document.querySelectorAll(".page:not(.away) .home-tile *")]'
SC="(()=>{const v=(r)=>r.left>=0&&r.right<=innerWidth&&r.top>=0&&r.bottom<=innerHeight;const all=$ALL;for(let i=0;i<all.length;i++){const e=all[i],s=getComputedStyle(e);if(!/auto|scroll/.test(s.overflowX)||e.scrollWidth<=e.clientWidth+8)continue;const r=e.getBoundingClientRect();if(r.width<80||!v(r))continue;const d=devicePixelRatio;return Math.round((r.x+r.width*0.8)*d)+' '+Math.round((r.y+r.height/2)*d)+' '+Math.round(r.width*d)+' '+i}return ''})()"
P=$(q "$SC")
if [ -z "$P" ]; then echo "SKIP step 2: no widget with a sideways scroller on the page on screen" | tee -a "$OUT/log.txt"; else
  set -- $P
  pg0=$(q '(()=>{const t=document.querySelector(".page-track");return t?Math.round(t.getBoundingClientRect().left):0})()')
  l0=$(q "${ALL}[$4]?.scrollLeft|0")
  f0=$FAILS
  drag "$1" "$2" $(($1 - $3 * 55 / 100)) $(($2 + 10)) 600 >/dev/null; chk scroller
  l1=$(q "${ALL}[$4]?.scrollLeft|0")
  pg1=$(q '(()=>{const t=document.querySelector(".page-track");return t?Math.round(t.getBoundingClientRect().left):0})()')
  echo "scrollLeft $l0 -> $l1, track $pg0 -> $pg1" | tee -a "$OUT/log.txt"
  [ "${l1:-0}" -gt "${l0:-0}" ] || fail "a sideways drag on the widget's scroller didn't scroll it"
  [ "$pg1" = "$pg0" ] || fail "a sideways drag on the widget's scroller turned home's page"
  [ "$FAILS" = "$f0" ] && pass "the widget's scroller scrolled ($l0 -> $l1), home's page stayed"
  drag $(($1 - $3 / 2)) "$2" $(($1 + $3 / 20)) "$2" 600 >/dev/null
fi

step "3. a straight pull down on home's body still opens the shade"
H=$(sh_ "wm size" | sed -nE 's/.*(Override|Physical) size: ([0-9]+)x([0-9]+).*/\3/p' | tail -1)
# On home (home_front), settled, then a pull from a bare spot.
home_front; sleep 1.5
m=$(drag $((W / 2)) $((H * 30 / 100)) $((W / 2 + 2)) $((H * 62 / 100)) 900); chk pull
open=$(shade_shown)
echo "shade windows shown mid-pull: $m, after the release: $open" | tee -a "$OUT/log.txt"
sh_ "logcat -d -v time | grep -E \"PowosShade\" | tail -12" > "$OUT/pull.log"
if [ "$m" != 0 ] || [ "$open" != 0 ]; then pass "a straight pull down on home opened the shade"; else fail "a straight pull down on home didn't show the shade's window (log: $OUT/pull.log)"; fi
# Shut by Back (a swipe up here, once the shade had gone, was home's own swipe up: the switcher).
sh_ "input keyevent 4"; sleep 1.5
[ "$(shade_shown)" = 0 ] || { sh_ "input keyevent 4"; sleep 1.5; }

step "4. the library scrolled down: a drag down scrolls it back, never the shade (both ways the list's)"
# The user, 11-24: "scrolling DOWN works, but scrolling UP opens the notification center" - a page-sized list was left
# out of the host's regions. Home's pages are swiped (input) to the library; its list is read only.
LIB='document.querySelector(".library-scroll")'
onlib() { q "(()=>{const e=$LIB;if(!e)return 0;const r=e.getBoundingClientRect();return r.left>-4&&r.left<innerWidth/4?1:0})()"; }
home_front
for k in 1 2 3 4 5 6 7 8; do { [ "$(onlib)" = 1 ] || late; } && break; sh_ "input swipe $((W * 85 / 100)) $((H * 50 / 100)) $((W * 15 / 100)) $((H * 50 / 100)) 300"; sleep 1.2; done
if [ "$(onlib)" != 1 ]; then echo "SKIP step 4: no library page reached" | tee -a "$OUT/log.txt"; else
  sh_ "logcat -c"
  t0=$(q "${LIB}.scrollTop|0")
  f0=$FAILS
  m1=$(drag $((W / 2)) $((H * 70 / 100)) $((W / 2 + 20)) $((H * 30 / 100)) 700); chk "library up"
  t1=$(q "${LIB}.scrollTop|0"); sleep 0.5
  m2=$(drag $((W / 2)) $((H * 35 / 100)) $((W / 2 + 20)) $((H * 65 / 100)) 700); chk "library down"
  t2=$(q "${LIB}.scrollTop|0")
  echo "library scrollTop $t0 -> $t1 (up) -> $t2 (down); shade mid-drag up=$m1 down=$m2" | tee -a "$OUT/log.txt"
  sh_ "logcat -d -v time | grep -E \"PowosShade|PowosGestures\" | tail -20" > "$OUT/library.log"
  if [ "${t1:-0}" -le "${t0:-0}" ]; then echo "the library didn't scroll (too short?): down step not judged" | tee -a "$OUT/log.txt"; else
    [ "$m2" = 0 ] || fail "a drag down on the scrolled library showed the shade's window"
    [ "${t2:-0}" -lt "${t1:-0}" ] || fail "a drag down on the scrolled library didn't scroll it back"
  fi
  [ "$m1" = 0 ] || fail "a drag up on the library showed the shade's window"
  [ "$(shade_shown)" = 0 ] || { fail "the library drags left the shade open"; sh_ "input keyevent 4"; sleep 1; }
  [ "$FAILS" = "$f0" ] && pass "the library's drags up and down were its own, the shade never showed"
fi

[ "$FAILS" = 0 ] && echo "PASS: scroll ownership on home ($OUT)" || { echo "FAIL: $FAILS step(s) ($OUT)"; exit 1; }
