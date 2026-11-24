#!/bin/bash
# lanes: emu phone
# home-stack.sh [OUT]: widget stacks on the phone (shell/ui/stacks.tsx; the user 11-23 "stack widgets and swipe between
# them like pages like samsung"), on the screen that's on:
#   1. the host's layout and the stores home.stacks / home.wide are saved first (base64 JSON in OUT);
#   2. edit mode by a long press on a bare spot; widget A held and dragged onto widget B = one stack tile, 2 dots;
#   3. out of edit mode, a sideways swipe on the stack: the widget on top changes, home's page doesn't;
#   4. a long press on the stack -> "edit stack" -> "unstack all": no stack left;
#   5. restore EXACTLY: every item placed back at its saved cell/page through the host, both stores written back as
#      they were (removed when they didn't exist), home reloaded so its wide cells are re-read; then the layout and the
#      stores are compared with the saved ones (a difference = FAIL "not restored").
# Injected input + CDP in a free window; Home after. Exit 1 + "FAIL:" on a failed step, 3 on a real touch (restored).
# Headless twin: shell/dev/gate.mjs home-stack-folded/-unfolded.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"
OUT=${1:-$HOME/.cache/powos-verify/home-stack-$(date +%m%d-%H%M)}; mkdir -p "$OUT"
L=$HOME/.cache/powos-verify.lock
SD=/data/data/com.powos.app/files/shell-data
sh_() { "$A" shell "su -c '$*'" 2>/dev/null | tr -d '\r'; }
irq() { sh_ "awk '\''/touch-0/{s+=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9} END{print s}'\'' /proc/interrupts"; }
q() { "$T/cdp.sh" eval home "$1" 2>/dev/null | tail -1 | tr -d '"\\\r'; }
# A host call from the page (its own resolve chained, only our id taken), answered as base64 JSON (q strips quotes).
HC='const hc=(m,a)=>new Promise((ok,no)=>{const h=window.__powosHost,id=910000+Math.floor(Math.random()*9999),r=h.resolve,j=h.reject;const done=()=>{h.resolve=r;h.reject=j};h.resolve=(i,v)=>i===id?(done(),ok(v)):r(i,v);h.reject=(i,e)=>i===id?(done(),no(e)):j(i,e);PowosHost.postMessage(JSON.stringify([id,m,JSON.stringify(a)]))});const b64=(v)=>btoa(unescape(encodeURIComponent(JSON.stringify(v))));'
snap() { q "(async()=>{$HC const h=await hc('home.get',[]);return b64({items:h.items.map(i=>[i.key,i.cell,i.page]).sort((x,y)=>x[0]<y[0]?-1:1),stacks:await hc('store.get',['home.stacks']),wide:await hc('store.get',['home.wide'])})})()"; }
SAVED=""; TOUCHED=0
restore_layout() {
  [ -n "$SAVED" ] && [ "$TOUCHED" = 1 ] || return 0
  echo "== restore the layout"
  q "(async()=>{$HC const s=JSON.parse(decodeURIComponent(escape(atob('$SAVED'))));for(const [k,c,p] of s.items)if(c)await hc('home.place',[k,c,p]);if(s.stacks!=null)await hc('store.set',['home.stacks',s.stacks]);if(s.wide!=null)await hc('store.set',['home.wide',s.wide]);return 'ok'})()" >/dev/null
  # A store that didn't exist before goes again (the page's own copy then re-read by the reload below).
  [ "$(echo "$SAVED" | base64 -d | python3 -c 'import json,sys;print(json.load(sys.stdin)["stacks"] is None)')" = True ] && sh_ "rm -f $SD/home.stacks.json"
  [ "$(echo "$SAVED" | base64 -d | python3 -c 'import json,sys;print(json.load(sys.stdin)["wide"] is None)')" = True ] && sh_ "rm -f $SD/home.wide.json"
  q 'location.reload(),1' >/dev/null; sleep 4
  TOUCHED=0
}
restore() { sh_ "input keyevent 4; input keyevent 4; input keyevent 4"; restore_layout; echo "== home"; sh_ "am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; }
. "$here/window-lock.sh"; window_lock home-stack 120 "${MAX_WAIT:-10800}"
trap 'restore; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"' EXIT
I0=$(irq); FAILS=0
chk() { [ "$(irq)" = "$I0" ] || { echo "STOP: a real touch at $1 - restoring"; exit 3; }; }
step() { echo "== $*" | tee -a "$OUT/log.txt"; }
fail() { echo "FAIL: $*" | tee -a "$OUT/log.txt"; FAILS=$((FAILS + 1)); }
px() { q "(()=>{const e=document.querySelector('$1');if(!e)return '';const r=e.getBoundingClientRect(),d=devicePixelRatio;return Math.round((r.x+r.width*${2:-0.5})*d)+' '+Math.round((r.y+r.height*${3:-0.5})*d)})()"; }
btn() { q "(()=>{const b=[...document.querySelectorAll('$1')].find(b=>b.textContent.trim()==='$2');if(!b)return '';const r=b.getBoundingClientRect(),d=devicePixelRatio;return Math.round((r.x+r.width/2)*d)+' '+Math.round((r.y+r.height/2)*d)})()"; }

s=$(sh_ "dumpsys power | sed -n s/.*mWakefulness=//p | head -1")
[ "$s" = Awake ] || { echo "the screen is $s - not woken (rule); nothing done"; exit 3; }
if sh_ "dumpsys window | grep -m1 mCurrentFocus" | grep -qi "PowosLock"; then
  wh=$(sh_ "wm size" | sed -nE 's/.*(Override|Physical) size: ([0-9]+)x([0-9]+).*/\2 \3/p' | tail -1)
  sh_ "input swipe $((${wh% *} / 2)) $((${wh#* } * 9 / 10)) $((${wh% *} / 2)) $((${wh#* } / 4)) 300"; sleep 1.5
fi
sh_ "am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; sleep 1.5; chk home
[ "$(q '!!document.querySelector(".pages")')" = true ] || { fail "home's page isn't up"; exit 1; }

step "save the layout"
SAVED=$(snap); [ -n "$SAVED" ] || { fail "couldn't read the layout (home.get)"; exit 1; }
echo "$SAVED" > "$OUT/before.b64"

# Two plain widgets (not stacked, not the search bar) on the page on screen, wholly visible: A (carried) and B.
PAIR=$(q '(()=>{const v=(t)=>{const r=t.getBoundingClientRect();return r.left>=0&&r.right<=innerWidth&&r.top>=0&&r.bottom<=innerHeight};const t=[...document.querySelectorAll(".home-tile:is(.widget,.appwidget,.panel):not(.stacked)")].filter(e=>v(e)&&!e.querySelector(".search-face, .bar-pill")&&e.dataset.key!=="panel:search");return t.length>=2?t[0].dataset.key+" "+t[1].dataset.key:""})()')
[ -n "$PAIR" ] || { fail "no two plain widgets on the page on screen to stack"; exit 1; }
KA=${PAIR%% *}; KB=${PAIR#* }; echo "A=$KA B=$KB" | tee -a "$OUT/log.txt"

BARE='(()=>{const pg=[...document.querySelectorAll(".page")].find(p=>{const r=p.getBoundingClientRect();return r.left>=-2&&r.left<innerWidth/2});if(!pg)return "";const r=pg.getBoundingClientRect(),tiles=[...pg.querySelectorAll(".home-tile")].map(t=>t.getBoundingClientRect());const bare=(x,y)=>{const e=document.elementFromPoint(x,y);return !!e&&e.matches(".page, .page-track, .pages")&&!tiles.some(t=>x>t.left-12&&x<t.right+12&&y>t.top-12&&y<t.bottom+12)};const d=devicePixelRatio;for(let y=r.bottom-60;y>r.top+60;y-=24)for(let x=r.left+40;x<r.right-40;x+=24)if(bare(x,y))return Math.round(x*d)+" "+Math.round(y*d);return ""})()'
step "edit mode, then A held and dragged onto B"
p=$(q "$BARE"); [ -n "$p" ] || { fail "no bare spot to long-press"; exit 1; }
sh_ "input swipe $p $p 900"; sleep 1.5; chk edit
[ "$(q '!!document.querySelector(".home.editing")')" = true ] || { fail "a long press at $p isn't edit mode"; exit 1; }
a=$(px ".home-tile[data-key=\"$KA\"]" 0.5 0.3); b=$(px ".home-tile[data-key=\"$KB\"]")
TOUCHED=1
sh_ "input motionevent DOWN ${a% *} ${a#* }"; sleep 0.8
for k in 1 2 3 4 5 6 7 8; do
  sh_ "input motionevent MOVE $(( ${a% *} + (${b% *} - ${a% *}) * k / 8 )) $(( ${a#* } + (${b#* } - ${a#* }) * k / 8 ))"
done
sleep 0.4; sh_ "input motionevent UP ${b% *} ${b#* }"; sleep 1.5; chk drop
r=$(q '(()=>{const s=document.querySelectorAll(".home-tile.stacked");if(s.length!==1)return "stacks on home: "+s.length;return "ok dots "+s[0].querySelectorAll(".stack-dots i").length})()')
echo "stack: $r" | tee -a "$OUT/log.txt"; [ "$r" = "ok dots 2" ] || { fail "A onto B: $r"; exit 1; }
"$T/shot.sh" "$OUT/stacked-edit.png" 2>&1 | tail -1

step "out of edit mode: a swipe on the stack shows the other widget, home's page stays"
sh_ "input keyevent 4"; sleep 1.2
[ "$(q '!!document.querySelector(".stack-strip[data-swipe]")')" = true ] || fail "the stack can't swipe out of edit mode"
T0=$(q 'document.querySelector(".stack-page.top")?.dataset.member||""'); P0=$(q 'document.querySelector(".page-track")?.style.transform||""')
f=$(px ".stack-strip" 0.85 0.5); t=$(px ".stack-strip" 0.1 0.5)
[ "$T0" = "$KA" ] && dir=1 || dir=0
[ "$dir" = 1 ] && sh_ "input swipe $f $t 220" || sh_ "input swipe $t $f 220"
sleep 1; chk swipe
T1=$(q 'document.querySelector(".stack-page.top")?.dataset.member||""'); P1=$(q 'document.querySelector(".page-track")?.style.transform||""')
echo "top: $T0 -> $T1; track: '$P0' -> '$P1'" | tee -a "$OUT/log.txt"
[ -n "$T1" ] && [ "$T1" != "$T0" ] || fail "the swipe didn't change the widget on top ($T0 -> $T1)"
[ "$P0" = "$P1" ] || fail "home's page moved with the stack's swipe ($P0 -> $P1)"
"$T/shot.sh" "$OUT/swiped.png" 2>&1 | tail -1

step "edit stack -> unstack all"
p=$(px ".home-tile.stacked"); sh_ "input swipe $p $p 900"; sleep 1.2; chk hold
p=$(btn ".tile-actions button" "edit stack"); [ -n "$p" ] || { fail "no 'edit stack' in the stack's actions"; exit 1; }
sh_ "input tap $p"; sleep 1; chk edit-stack
"$T/shot.sh" "$OUT/edit-stack.png" 2>&1 | tail -1
p=$(btn ".stack-sheet-acts button" "unstack all"); [ -n "$p" ] || { fail "no 'unstack all' in the sheet"; exit 1; }
sh_ "input tap $p"; sleep 1.5; chk unstack
[ "$(q '!!document.querySelector(".stack-strip")')" = false ] || fail "unstack all left a stack"

restore_layout
step "restored exactly?"
NOW=$(snap); echo "$NOW" > "$OUT/after.b64"
python3 - "$OUT/before.b64" "$OUT/after.b64" <<'EOF' | tee -a "$OUT/log.txt"
import base64, json, sys
a, b = (json.loads(base64.b64decode(open(p).read().strip())) for p in sys.argv[1:3])
diff = [k for k in ("items", "stacks", "wide") if a[k] != b[k]]
print("restored: same" if not diff else "restored: DIFFERS in " + ", ".join(diff))
EOF
grep -q "restored: same" "$OUT/log.txt" || fail "the layout wasn't restored exactly (before.b64 / after.b64 in $OUT)"
restore; trap - EXIT; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"
echo "artefacts: $OUT"
[ "$FAILS" = 0 ] && echo "PASS: A onto B = a stack (2 dots), a swipe changes the top widget (home's page still), unstack all, layout restored exactly" || { echo "FAIL: $FAILS step(s)"; exit 1; }
