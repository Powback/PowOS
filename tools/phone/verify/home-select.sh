#!/bin/bash
# home-select.sh [OUT]: edit mode's selection rectangle and home's app library on the phone, on the screen that's on
# (folded or unfolded), without changing the user's layout: picking tiles is transient (no tile moves, no folder is
# made - those are gated headless: shell/dev/gate.mjs home-select-*, home-folder-*, library-*).
#   1. edit mode by a long press on a bare spot of the page (its element is the page itself);
#   2. a swipe down from a bare spot across a tile draws the rectangle: the tiles it crossed are marked (.chosen), no
#      rectangle stays after the finger lifts; a tap on empty space lets go of them; Back leaves edit mode;
#   3. swiped left to the last page: the app library is on screen with its search field and folders.
# Read-only CDP probes + injected input in a free window; Home after. Exit 1 + "FAIL:" lines on a failed step, 3 on a
# real touch (restored).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"
OUT=${1:-$HOME/.cache/powos-verify/home-select-$(date +%m%d-%H%M)}; mkdir -p "$OUT"
L=$HOME/.cache/powos-verify.lock
sh_() { "$A" shell "su -c '$*'" 2>/dev/null | tr -d '\r'; }
irq() { sh_ "awk '/touch-0/{s+=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9} END{print s}' /proc/interrupts"; }
restore() { echo "== restore"; sh_ "input keyevent 4; input keyevent 4; am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; }
. "$here/window-lock.sh"; window_lock home-select 120 "${MAX_WAIT:-10800}"
trap 'restore; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"' EXIT
I0=$(irq); FAILS=0
chk() { [ "$(irq)" = "$I0" ] || { echo "STOP: a real touch at $1 - restoring"; exit 3; }; }
step() { echo "== $*" | tee -a "$OUT/log.txt"; }
fail() { echo "FAIL: $*" | tee -a "$OUT/log.txt"; FAILS=$((FAILS + 1)); }
q() { "$T/cdp.sh" eval home "$1" 2>/dev/null | tail -1 | tr -d '"\\\r'; }

s=$(sh_ "dumpsys power | sed -n s/.*mWakefulness=//p | head -1")
[ "$s" = Awake ] || { echo "the screen is $s - not woken (rule); nothing done"; exit 3; }
if sh_ "dumpsys window | grep -m1 mCurrentFocus" | grep -qi "PowosLock"; then
  wh=$(sh_ "wm size" | sed -nE 's/.*(Override|Physical) size: ([0-9]+)x([0-9]+).*/\2 \3/p' | tail -1)
  sh_ "input swipe $((${wh% *} / 2)) $((${wh#* } * 9 / 10)) $((${wh% *} / 2)) $((${wh#* } / 4)) 300"; sleep 1.5
fi
sh_ "am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; sleep 1.5; chk home

# A bare spot of the page on screen (device px "x y"), and one a tile's height above a tile below it (for the swipe).
BARE='(()=>{const pg=[...document.querySelectorAll(".page")].find(p=>{const r=p.getBoundingClientRect();return r.left>=-2&&r.left<innerWidth/2});if(!pg)return "";const r=pg.getBoundingClientRect(),tiles=[...pg.querySelectorAll(".home-tile")].map(t=>t.getBoundingClientRect());const bare=(x,y)=>{const e=document.elementFromPoint(x,y);return !!e&&e.matches(".page, .page-track, .pages")&&!tiles.some(t=>x>t.left-12&&x<t.right+12&&y>t.top-12&&y<t.bottom+12)};const d=devicePixelRatio,P=(x,y)=>Math.round(x*d)+" "+Math.round(y*d);for(const t of tiles)for(const y of [t.top-30,t.top-60]){const x=t.left+t.width/2;if(y>r.top+20&&bare(x,y))return P(x,y)+" "+P(x,t.top+t.height/2)}for(let y=r.bottom-60;y>r.top+60;y-=24)for(let x=r.left+40;x<r.right-40;x+=24)if(bare(x,y))return P(x,y);return ""})()'

step "edit mode: a long press on a bare spot"
at=$(q "$BARE"); [ -n "$at" ] || { fail "no bare spot to long-press"; exit 1; }
set -- $at
sh_ "input swipe $1 $2 $1 $2 900"; sleep 1.5; chk edit
[ "$(q '!!document.querySelector(".home.editing")')" = true ] || fail "a long press on a bare spot (at $1 $2) isn't edit mode"

step "the selection rectangle: a swipe down from a bare spot across a tile"
at=$(q "$BARE"); set -- $at
if [ $# -ge 4 ]; then
  sh_ "input swipe $1 $2 $3 $4 700"; sleep 1; chk marquee
  r=$(q '(()=>{const n=document.querySelectorAll(".home-tile.chosen").length;if(document.querySelector(".pages .marquee"))return "the rectangle stays after the finger lifts";return n?"ok "+n:"no tile picked"})()')
  echo "marquee: $r" | tee -a "$OUT/log.txt"; case "$r" in ok*) ;; *) fail "the selection rectangle: $r" ;; esac
  "$T/shot.sh" "$OUT/chosen.png" 2>&1 | tee -a "$OUT/log.txt"
  at=$(q "$BARE"); set -- $at; [ $# -ge 2 ] && { sh_ "input tap $1 $2"; sleep 0.8; chk unpick; }
  [ "$(q 'document.querySelectorAll(".home-tile.chosen").length')" = 0 ] || fail "a tap on empty space didn't let go of the picked tiles"
else fail "no bare spot above a tile to swipe from"; fi
sh_ "input keyevent 4"; sleep 1; chk back
[ "$(q '!!document.querySelector(".home.editing")')" = false ] || fail "Back didn't leave edit mode"

step "the app library: the last page"
wh=$(sh_ "wm size" | sed -nE 's/.*(Override|Physical) size: ([0-9]+)x([0-9]+).*/\2 \3/p' | tail -1); W=${wh% *}; H=${wh#* }
for _ in 1 2 3 4 5 6; do
  [ "$(q '(()=>{const l=document.querySelector(".page.library");return !!l&&Math.abs(l.getBoundingClientRect().left)<4})()')" = true ] && break
  sh_ "input swipe $((W * 8 / 10)) $((H * 45 / 100)) $((W * 2 / 10)) $((H * 45 / 100)) 220"; sleep 1; chk "swipe"
done
r=$(q '(()=>{const l=document.querySelector(".page.library");if(!l||Math.abs(l.getBoundingClientRect().left)>=4)return "not on screen after the last page";const v=(e)=>!!e&&e.getClientRects().length>0;if(!v(l.querySelector(".lib-search")))return "no search field";const n=l.querySelectorAll(".lib-card").length,a=l.querySelectorAll(".lib-card .app").length;return n?"ok "+n+" folders, "+a+" icons":"no folders"})()')
echo "library: $r" | tee -a "$OUT/log.txt"; case "$r" in ok*) ;; *) fail "the app library: $r" ;; esac
"$T/shot.sh" "$OUT/library.png" 2>&1 | tee -a "$OUT/log.txt"

restore; trap - EXIT; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"
echo "artefacts: $OUT"
[ "$FAILS" = 0 ] && echo "PASS: selection rectangle + app library" || { echo "FAIL: $FAILS step(s)"; exit 1; }
