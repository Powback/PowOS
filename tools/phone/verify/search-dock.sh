#!/bin/bash
# search-dock.sh [OUT]: the user's own move with the search bar (2026-10-23, the 4th and 5th reports), on the screen
# that's on: edit mode -> long-press the search bar's tile -> drag it onto the dock -> let go -> Back. Then:
#   - it's in the foot: folded under the dock (search.belowDock "1"), unfolded in the bar's middle; not on the grid;
#   - the pull-up launcher has it: a swipe up from the pill opens the drawer with the pill on screen;
#   - after the app restarts (force-stop, Home) it is still there.
# It CHANGES the layout as the user asked (the search bar to the foot); nothing else moves. Exit 1 + "FAIL:" lines on
# a failed step, 3 on a real touch.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"
OUT=${1:-$HOME/.cache/powos-verify/search-dock-$(date +%m%d-%H%M)}; mkdir -p "$OUT"
L=$HOME/.cache/powos-verify.lock
sh_() { "$A" shell "su -c '$*'" 2>/dev/null | tr -d '\r'; }
irq() { sh_ "awk '/touch-0/{s+=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9} END{print s}' /proc/interrupts"; }
home() { sh_ "am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; }
. "$here/window-lock.sh"; window_lock search-dock 120 "${MAX_WAIT:-10800}"
trap 'sh_ "input keyevent 4"; home; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"' EXIT
I0=$(irq); FAILS=0
chk() { [ "$(irq)" = "$I0" ] || { echo "STOP: a real touch at $1"; exit 3; }; }
step() { echo "== $*" | tee -a "$OUT/log.txt"; }
fail() { echo "FAIL: $*" | tee -a "$OUT/log.txt"; FAILS=$((FAILS + 1)); }
q() { "$T/cdp.sh" eval home "$1" 2>/dev/null | tail -1 | tr -d '"\\\r'; }
# An element's centre in device px ("x y"), [f] of its width from the left (default the middle).
at() { q "(()=>{const e=document.querySelector('$1');if(!e)return '';const r=e.getBoundingClientRect(),d=devicePixelRatio;return Math.round((r.left+r.width*${2:-0.5})*d)+' '+Math.round((r.top+r.height/2)*d)})()"; }

s=$(sh_ "dumpsys power | sed -n s/.*mWakefulness=//p | head -1")
[ "$s" = Awake ] || { echo "the screen is $s - not woken (rule); nothing done"; exit 3; }
home; sleep 1.5; chk home
# Not shipped yet (the ship service ships origin's tip when it's quiet): back on the queue, nothing touched.
has=$(q '(async()=>(await (await fetch("./ui/searchwidget.tsx")).text()).includes("putBackInBar"))()')
[ "$has" = true ] || { echo "the phone doesn't serve the search fix yet (searchwidget.tsx) - not run"; exit 3; }
WIDE=$(q '!!document.querySelector(".home.wide")'); WANT=$([ "$WIDE" = true ] && echo "" || echo 1)
echo "wide=$WIDE" | tee -a "$OUT/log.txt"

step "edit mode: a long press on a bare spot of the page"
bare=$(q '(()=>{const pg=[...document.querySelectorAll(".page")].find(p=>{const r=p.getBoundingClientRect();return r.left>=-2&&r.left<innerWidth/2});if(!pg)return "";const r=pg.getBoundingClientRect(),d=devicePixelRatio;for(let y=r.bottom-30;y>r.top+40;y-=20)for(let x=r.left+30;x<r.right-30;x+=20){const e=document.elementFromPoint(x,y);if(e&&e.matches(".page, .page-track, .pages"))return Math.round(x*d)+" "+Math.round(y*d)}return ""})()')
[ -n "$bare" ] || { fail "no bare spot to long-press for edit mode"; exit 1; }
set -- $bare; sh_ "input swipe $1 $2 $1 $2 900"; sleep 1.5; chk edit
[ "$(q '!!document.querySelector(".home.editing")')" = true ] || { fail "no edit mode"; exit 1; }
tile=$(at '.home-tile[data-key="panel:search"]' 0.3); dock=$(at ".home > .dock:not(.dock-tray)")
[ "$WIDE" = true ] && dock=$(at ".home > .edit-sheet")
[ -n "$tile" ] && [ -n "$dock" ] || { fail "edit mode: no search tile ($tile) or dock ($dock)"; exit 1; }
"$T/shot.sh" "$OUT/edit.png" 2>&1 | tee -a "$OUT/log.txt"

step "long-press the search bar and drag it onto the dock ($tile -> $dock)"
set -- $tile $dock
sh_ "input motionevent DOWN $1 $2"; sleep 0.9
for k in 1 2 3 4 5 6 7 8; do sh_ "input motionevent MOVE $(( $1 + ($3 - $1) * k / 8 )) $(( $2 + ($4 - $2) * k / 8 ))"; sleep 0.08; done
sleep 0.4; sh_ "input motionevent UP $3 $4"; sleep 1.2; chk drop
sh_ "input keyevent 4"; sleep 1.2; chk done
check_foot() {
  r=$(q "(()=>{const S=document.querySelector('.home');if(!S)return 'no home';if(document.querySelector('.home-tile[data-key=\"panel:search\"]'))return 'still on the grid';const b=document.querySelector('.home > .bar');if(!b||+getComputedStyle(b).opacity<0.9)return 'no pill in the foot';return 'ok below='+S.classList.contains('pill-below')})()")
  echo "$1: $r" | tee -a "$OUT/log.txt"
  case "$r" in "ok below=$([ "$WANT" = 1 ] && echo true || echo false)") ;; *) fail "$1: $r (want under the dock: ${WANT:-no})" ;; esac
}
check_foot "after the drop"
"$T/shot.sh" "$OUT/dropped.png" 2>&1 | tee -a "$OUT/log.txt"

step "the pull-up launcher from the pill"
p=$(at ".home > .bar .bar-pill" 0.8); set -- $p
sh_ "input swipe $1 $2 $1 $(( $2 - 700 )) 250"; sleep 1.2; chk pull
r=$(q '(()=>{if(!document.querySelector(".home.open"))return "the drawer did not open";const b=document.querySelector(".home > .bar"),p=b&&b.querySelector(".bar-pill").getBoundingClientRect();return p&&p.width&&+getComputedStyle(b).opacity>0.9?"ok":"no pill over the open drawer"})()')
echo "pull-up: $r" | tee -a "$OUT/log.txt"; [ "$r" = ok ] || fail "pull-up: $r"
"$T/shot.sh" "$OUT/drawer.png" 2>&1 | tee -a "$OUT/log.txt"
sh_ "input keyevent 4"; sleep 1

step "after a restart of the app"
sh_ "am force-stop com.powos.app"; sleep 1; home; sleep 8; chk restart
check_foot "after the restart"
"$T/shot.sh" "$OUT/after-restart.png" 2>&1 | tee -a "$OUT/log.txt"

trap - EXIT; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"
echo "artefacts: $OUT"
[ "$FAILS" = 0 ] && echo "PASS: search bar dragged onto the dock stays in the foot, launcher works, survives a restart" || { echo "FAIL: $FAILS step(s)"; exit 1; }
