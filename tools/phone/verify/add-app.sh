#!/bin/bash
# lanes: emu phone
# add-app.sh [OUT]: edit mode's "+ app" on the phone, on the screen that's on (folded or unfolded):
#   1. edit mode by a long press on a bare spot of the page;
#   2. "+ app" opens the drawer's list (A-Z) in a picker; typing an app's name narrows it to matches;
#   3. a tap on that app puts it on the page in view (a .home-tile for it appears) and the picker stays open;
#   4. the test app is removed again (home.remove of only that key) and edit mode left: the user's layout as it was.
# The test app is one not on home already (not a tile, not in a folder's minis), so nothing of the user's moves.
# Injected input + CDP probes in a free window; Home after. Exit 1 + "FAIL:" lines on a failed step, 3 on a real
# touch (restored). Headless: shell/dev/gate.mjs add-app-* (incl. the first free cell and a reload).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"
OUT=${1:-$HOME/.cache/powos-verify/add-app-$(date +%m%d-%H%M)}; mkdir -p "$OUT"
L=$HOME/.cache/powos-verify.lock
sh_() { "$A" shell "su -c '$*'" 2>/dev/null | tr -d '\r'; }
irq() { sh_ "awk '/touch-0/{s+=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9} END{print s}' /proc/interrupts"; }
q() { "$T/cdp.sh" eval home "$1" 2>/dev/null | tail -1 | tr -d '"\\\r'; }
ADDED=""
# The test tile goes again whatever happened (only its own key), then Back out of the picker and edit mode.
unplace() {
  [ -n "$ADDED" ] || return 0
  echo "== remove the test tile $ADDED"
  q "(()=>{window.PowosHost.postMessage(JSON.stringify([910771,'home.remove',JSON.stringify(['$ADDED'])]));return 1})()" >/dev/null
  sleep 1; ADDED=""
}
restore() { unplace; echo "== restore"; sh_ "input keyevent 4; input keyevent 4; input keyevent 4; am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; }
. "$here/window-lock.sh"; window_lock add-app 120 "${MAX_WAIT:-10800}"
trap 'restore; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"' EXIT
I0=$(irq); FAILS=0
chk() { [ "$(irq)" = "$I0" ] || { echo "STOP: a real touch at $1 - restoring"; exit 3; }; }
step() { echo "== $*" | tee -a "$OUT/log.txt"; }
fail() { echo "FAIL: $*" | tee -a "$OUT/log.txt"; FAILS=$((FAILS + 1)); }
# The centre of the first element matching a selector, in device px "x y".
at() { q "(()=>{const e=document.querySelector('$1');if(!e)return '';const r=e.getBoundingClientRect(),d=devicePixelRatio;return Math.round((r.x+r.width/2)*d)+' '+Math.round((r.y+r.height/2)*d)})()"; }

s=$(sh_ "dumpsys power | sed -n s/.*mWakefulness=//p | head -1")
[ "$s" = Awake ] || { echo "the screen is $s - not woken (rule); nothing done"; exit 3; }
if sh_ "dumpsys window | grep -m1 mCurrentFocus" | grep -qi "PowosLock"; then
  wh=$(sh_ "wm size" | sed -nE 's/.*(Override|Physical) size: ([0-9]+)x([0-9]+).*/\2 \3/p' | tail -1)
  sh_ "input swipe $((${wh% *} / 2)) $((${wh#* } * 9 / 10)) $((${wh% *} / 2)) $((${wh#* } / 4)) 300"; sleep 1.5
fi
sh_ "am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; sleep 1.5; chk home

BARE='(()=>{const pg=[...document.querySelectorAll(".page")].find(p=>{const r=p.getBoundingClientRect();return r.left>=-2&&r.left<innerWidth/2});if(!pg)return "";const r=pg.getBoundingClientRect(),tiles=[...pg.querySelectorAll(".home-tile")].map(t=>t.getBoundingClientRect());const bare=(x,y)=>{const e=document.elementFromPoint(x,y);return !!e&&e.matches(".page, .page-track, .pages")&&!tiles.some(t=>x>t.left-12&&x<t.right+12&&y>t.top-12&&y<t.bottom+12)};const d=devicePixelRatio;for(let y=r.bottom-60;y>r.top+60;y-=24)for(let x=r.left+40;x<r.right-40;x+=24)if(bare(x,y))return Math.round(x*d)+" "+Math.round(y*d);return ""})()'

step "edit mode: a long press on a bare spot"
p=$(q "$BARE"); [ -n "$p" ] || { fail "no bare spot to long-press"; exit 1; }
sh_ "input swipe $p $p 900"; sleep 1.5; chk edit
[ "$(q '!!document.querySelector(".home.editing")')" = true ] || { fail "a long press at $p isn't edit mode"; exit 1; }

step '"+ app": the drawer list in a picker'
p=$(q '(()=>{const b=[...document.querySelectorAll(".edit-sheet .edit-act")].find(b=>b.textContent.trim()==="+ app");if(!b)return "";const r=b.getBoundingClientRect(),d=devicePixelRatio;return Math.round((r.x+r.width/2)*d)+" "+Math.round((r.y+r.height/2)*d)})()')
[ -n "$p" ] || { fail 'no "+ app" in the edit bar (old shell?)'; exit 1; }
sh_ "input tap $p"; sleep 1.2; chk "+ app"
ALL=$(q 'document.querySelectorAll(".app-picker .grid.az .app").length')
echo "picker: $ALL apps A-Z" | tee -a "$OUT/log.txt"
[ "${ALL:-0}" -ge 5 ] 2>/dev/null || { fail "the picker shows ${ALL:-no} apps"; exit 1; }
"$T/shot.sh" "$OUT/picker.png" 2>&1 | tee -a "$OUT/log.txt"

# The test app: one word, letters only, not a home tile, not in a folder (its key nowhere under .pages).
PICK=$(q '(()=>{const home=(k)=>k.replace(/^a:/,"app:").replace(/^l:/,"linux:");const c=[...document.querySelectorAll(".app-picker .grid.az .app")].find(e=>{const k=e.dataset.key,l=e.textContent.trim();return /^[A-Za-z]{4,}$/.test(l)&&!document.querySelector(`.pages [data-key="${home(k)}"], .pages [data-key="${k}"], .dock [data-key="${k}"]`)});return c?c.dataset.key+" "+c.textContent.trim():""})()')
[ -n "$PICK" ] || { fail "no app free to add as a test"; exit 1; }
KEY=${PICK%% *}; NAME=${PICK#* }; echo "test app: $NAME ($KEY)" | tee -a "$OUT/log.txt"

step "search: typing \"$NAME\" narrows the list"
p=$(at ".app-picker textarea"); sh_ "input tap $p"; sleep 0.8; sh_ "input text $NAME"; sleep 1; chk search
r=$(q "(()=>{const f=[...document.querySelectorAll('.app-picker .drawer-list.results .app')];const has=f.some(e=>e.dataset.key==='$KEY');return f.length&&f.length<$ALL&&has?'ok '+f.length:'shows '+f.length+' of $ALL, '+(has?'with':'without')+' it'})()")
echo "search: $r" | tee -a "$OUT/log.txt"; case "$r" in ok*) ;; *) fail "search: $r" ;; esac
# The keyboard stays up, as for the user: the picker sits above it (--inset-keyboard). The 01:04 FAIL tapped the
# result where the keyboard was (the picker under it): the tap typed an "s", "Besieges" found nothing.
kb=$(q 'getComputedStyle(document.documentElement).getPropertyValue("--inset-keyboard").trim()')
echo "keyboard: $(sh_ "dumpsys input_method | grep -m1 -oE 'mInputShown=[a-z]+'") inset $kb" | tee -a "$OUT/log.txt"

step "a tap on $NAME puts it on the page in view"
HK=$(echo "$KEY" | sed -e 's/^a:/app:/' -e 's/^l:/linux:/')
p=$(at ".app-picker .drawer-list [data-key=\"$KEY\"]"); [ -n "$p" ] || { fail "$NAME isn't in the results to tap"; exit 1; }
r=$(q "(()=>{const e=document.querySelector('.app-picker .drawer-list [data-key=\"$KEY\"]').getBoundingClientRect(),k=parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--inset-keyboard'))||0;return e.bottom<=innerHeight-k?'clear':'under the keyboard ('+Math.round(e.bottom)+' > '+Math.round(innerHeight-k)+')'})()")
[ "$r" = clear ] || { fail "$NAME's result is $r"; exit 1; }
sh_ "input tap $p"; ADDED=$HK; sleep 1.5; chk pick
r=$(q "(()=>{const t=document.querySelector('.home-tile[data-key=\"$HK\"]');if(!t)return 'no tile for it on home';if(!document.querySelector('.app-picker'))return 'the picker closed';const r=t.getBoundingClientRect();return r.right>0&&r.left<innerWidth?'ok on screen':'its tile is off screen (another page)'})()")
echo "placed: $r" | tee -a "$OUT/log.txt"; case "$r" in ok*) ;; *) fail "the pick: $r" ;; esac
p=$(at ".app-picker .sheet-done"); [ -n "$p" ] && { sh_ "input tap $p"; sleep 1; chk done; }
"$T/shot.sh" "$OUT/placed.png" 2>&1 | tee -a "$OUT/log.txt"

unplace
[ "$(q "!!document.querySelector('.home-tile[data-key=\"$HK\"]')")" = false ] || fail "the test tile $HK is still on home"
restore; trap - EXIT; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"
echo "artefacts: $OUT"
[ "$FAILS" = 0 ] && echo "PASS: + app opens, search filters, a pick lands on the page in view (test tile removed)" || { echo "FAIL: $FAILS step(s)"; exit 1; }
