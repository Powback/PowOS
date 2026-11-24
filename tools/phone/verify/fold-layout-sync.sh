#!/bin/bash
# lanes: phone
# fold-layout-sync.sh [OUT]: ONE home layout on both screens (shell/hosts/reflow.ts + flowsync.ts; the user 11-24:
# "changed the home layout unfolded, it isn't reflected folded"), on the phone:
#   1. the host's layout and the stores home.wide / home.flow / home.stacks are saved first (base64 JSON in OUT);
#   2. read only: the migration ran (home.flow), every home item has a wide cell in the half of its host page, and
#      neither screen has two tiles on one cell;
#   3. one widget on the screen on now is resized by a row through home's own bridge (as the grid's resize does);
#      once the other screen is laid out again, it has the new size there too (the wide cell, or the host's cell);
#   4. the other screen forced (cmd device_state; always reset) and shot, home's layout read there: the widget's size;
#   5. restore EXACTLY: every item placed back at its saved cell/page through the host, the three stores written back
#      as they were (removed when they didn't exist), home reloaded; then compared with the saved ones (FAIL "not
#      restored" on any difference).
# CDP (the page's own modules) + one device-state switch in a free window; no touch is injected. Headless twin:
# shell/dev/gate.mjs fold-sync-unfolded / fold-sync-folded.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"
OUT=${1:-$HOME/.cache/powos-verify/fold-layout-sync-$(date +%m%d-%H%M)}; mkdir -p "$OUT"
L=$HOME/.cache/powos-verify.lock
SD=/data/data/com.powos.app/files/shell-data
sh_() { "$A" shell "su -c '$*'" 2>/dev/null | tr -d '\r'; }
q() { "$T/cdp.sh" eval home "$1" 2>/dev/null | tail -1 | tr -d '"\\\r'; }
# A host call from the page (its own resolve chained, only our id taken), answered as base64 JSON (q strips quotes).
HC='const hc=(m,a)=>new Promise((ok,no)=>{const h=window.__powosHost,id=920000+Math.floor(Math.random()*9999),r=h.resolve,j=h.reject;const done=()=>{h.resolve=r;h.reject=j};h.resolve=(i,v)=>i===id?(done(),ok(v)):r(i,v);h.reject=(i,e)=>i===id?(done(),no(e)):j(i,e);PowosHost.postMessage(JSON.stringify([id,m,JSON.stringify(a)]))});const b64=(v)=>btoa(unescape(encodeURIComponent(JSON.stringify(v))));'
STORES='["home.wide","home.flow","home.stacks"]'
snap() { q "(async()=>{$HC const h=await hc('home.get',[]);const s={};for(const k of $STORES)s[k]=await hc('store.get',[k]);return b64({items:h.items.map(i=>[i.key,i.cell,i.page]).sort((x,y)=>x[0]<y[0]?-1:1),stores:s})})()"; }
SAVED=""; TOUCHED=0; FORCED=0
restore_layout() {
  [ -n "$SAVED" ] && [ "$TOUCHED" = 1 ] || return 0
  echo "== restore the layout"
  q "(async()=>{$HC const s=JSON.parse(decodeURIComponent(escape(atob('$SAVED'))));for(const [k,c,p] of s.items)if(c)await hc('home.place',[k,c,p]);for(const [k,v] of Object.entries(s.stores))if(v!=null)await hc('store.set',[k,v]);return 'ok'})()" >/dev/null
  # A store that didn't exist before goes again (the page's own copy is re-read by the reload below).
  for k in home.wide home.flow home.stacks; do
    [ "$(echo "$SAVED" | base64 -d | python3 -c "import json,sys;print(json.load(sys.stdin)['stores']['$k'] is None)")" = True ] && sh_ "rm -f $SD/$k.json"
  done
  q 'location.reload(),1' >/dev/null; sleep 5
  TOUCHED=0
}
unforce() { [ "$FORCED" = 1 ] && { "$A" shell cmd device_state state reset >/dev/null 2>&1; FORCED=0; sleep 3; }; return 0; }
restore() { unforce; restore_layout; sh_ "am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; }
. "$here/window-lock.sh"; window_lock fold-layout-sync 120 "${MAX_WAIT:-10800}"
trap 'restore; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"' EXIT
FAILS=0
step() { echo "== $*" | tee -a "$OUT/log.txt"; }
fail() { echo "FAIL: $*" | tee -a "$OUT/log.txt"; FAILS=$((FAILS + 1)); }

s=$(sh_ "dumpsys power | sed -n s/.*mWakefulness=//p | head -1")
[ "$s" = Awake ] || { echo "the screen is $s - not woken (rule); nothing done"; exit 3; }
sh_ "am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; sleep 1.5
[ "$(q '!!document.querySelector(".pages")')" = true ] || { fail "home's page isn't up"; exit 1; }
[ "$(q 'importShim("./hosts/flowsync.ts").then(()=>true,()=>false)')" = true ] || { fail "the phone's shell has no hosts/flowsync.ts (not shipped yet)"; exit 1; }

step "save the layout"
SAVED=$(snap); [ -n "$SAVED" ] || { fail "couldn't read the layout (home.get)"; exit 1; }
echo "$SAVED" > "$OUT/before.b64"

step "one layout: migrated, every item on both screens, in its page's half, no overlaps"
CHECK='(async()=>{'"$HC"'const R=await importShim("./hosts/reflow.ts");const h=await hc("home.get",[]);const w=await hc("store.get",["home.wide"])||{};const f=await hc("store.get",["home.flow"]);const pairs=R.pairsOf(h.pages);const bad=[];if(!f)bad.push("no home.flow (not migrated)");const fold=[],wide=[];for(const i of h.items){if(!i.cell)continue;fold.push({key:i.key,page:i.page,cell:i.cell});const c=w[i.key],wp=pairs.findIndex(p=>p.includes(i.page));if(!c||c.hp!==i.page){bad.push(i.key+": no wide cell");continue}wide.push({key:i.key,page:wp+1,cell:c});const half=pairs[wp].indexOf(i.page);if(R.halfOf(c,h.columns)!==half&&pairs[wp].length>1)bad.push(i.key+": wide half "+R.halfOf(c,h.columns)+", host page "+i.page)}const st=await hc("store.get",["home.stacks"]);const inStack=new Set(Object.values((st&&st.stacks)||{}).flatMap(s=>s.keys));const ov=(xs)=>R.overlaps(xs.filter(x=>!inStack.has(x.key))).map(p=>p.join(" + "));bad.push(...ov(fold).map(x=>"folded overlap: "+x),...ov(wide).map(x=>"wide overlap: "+x));return b64({bad,items:fold.length,pins:f&&f.pins})})()'
r=$(q "$CHECK"); echo "$r" | base64 -d > "$OUT/consistency.json" 2>/dev/null
python3 -c "import json;d=json.load(open('$OUT/consistency.json'));print('items',d['items'],'pins',d['pins']);[print('  ',b) for b in d['bad']]" 2>&1 | tee -a "$OUT/log.txt"
python3 -c "import json,sys;sys.exit(1 if json.load(open('$OUT/consistency.json'))['bad'] else 0)" 2>/dev/null || fail "the two screens' layouts disagree (consistency.json)"

screen=$(q 'innerWidth>=700?"wide":"folded"'); echo "on now: $screen" | tee -a "$OUT/log.txt"
"$T/shot.sh" "$OUT/before-$screen.png" 2>&1 | tail -1

step "resize one widget on the $screen screen by a row"
PICK='(async()=>{const S=await importShim("./state.ts");const pg=S.pages.value[S.page.value];const t=S.home.value.items.filter(i=>i.resizable&&i.cell&&!i.stack&&i.page===pg&&i.key!=="panel:search"&&i.cell.h>i.minSize[1]);const i=t[0];return i?i.key+"|"+i.page+"|"+JSON.stringify(i.cell):""})()'
p=$(q "$PICK"); [ -n "$p" ] || { fail "no widget on the page on screen that can lose a row"; exit 1; }
KEY=${p%%|*}; rest=${p#*|}; PAGE=${rest%%|*}; CELL=${rest#*|}
echo "widget $KEY on page $PAGE at $CELL" | tee -a "$OUT/log.txt"
TOUCHED=1
r=$(q "(async()=>{const B=(await importShim('./bridge.ts')).powos;const F=await importShim('./hosts/flowsync.ts');const c=$CELL;await B.home.place('$KEY',{...c,h:c.h-1},$PAGE);await F.flowSettled();return 'ok'})()")
[ "$r" = ok ] || { fail "the resize didn't go through ($r)"; exit 1; }
WANT_H=$(python3 -c "import json;print(json.loads('$CELL')['h']-1)")
OTHER=$(q "(async()=>{$HC const h=await hc('home.get',[]);const w=await hc('store.get',['home.wide'])||{};const i=h.items.find(i=>i.key==='$KEY');return '$screen'==='wide'?(i&&i.cell?i.cell.h:-1):(w['$KEY']?w['$KEY'].h:-1)})()")
echo "other screen's height for it: $OTHER (want $WANT_H)" | tee -a "$OUT/log.txt"
[ "$OTHER" = "$WANT_H" ] || fail "resized on the $screen screen, the other screen still has height $OTHER"

step "the other screen, forced: shown there at the new size"
now=$("$A" shell cmd device_state print-state | tr -d '\r'); [ "$screen" = wide ] && to=0 || to=3
"$A" shell cmd device_state state $to >/dev/null; FORCED=1; sleep 5
shown=$(q "(async()=>{const S=await importShim('./state.ts');const i=S.home.value.items.find(i=>i.key==='$KEY');return (innerWidth>=700?'wide':'folded')+' '+(i&&i.cell?i.cell.h:-1)})()")
echo "device state $now -> $to; home shows: $shown" | tee -a "$OUT/log.txt"
[ "${shown#* }" = "$WANT_H" ] || fail "on the other screen home shows height ${shown#* } for $KEY, want $WANT_H"
"$T/shot.sh" "$OUT/after-${shown%% *}.png" 2>&1 | tail -1
unforce

restore_layout
step "restored exactly?"
NOW=$(snap); echo "$NOW" > "$OUT/after.b64"
python3 - "$OUT/before.b64" "$OUT/after.b64" <<'EOF' | tee -a "$OUT/log.txt"
import base64, json, sys
a, b = (json.loads(base64.b64decode(open(p).read().strip())) for p in sys.argv[1:3])
diff = [k for k in ("items",) if a[k] != b[k]] + [k for k in a["stores"] if a["stores"][k] != b["stores"][k]]
print("restored: same" if not diff else "restored: DIFFERS in " + ", ".join(diff))
EOF
grep -q "restored: same" "$OUT/log.txt" || fail "the layout wasn't restored exactly (before.b64 / after.b64 in $OUT)"
restore; trap - EXIT; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"
echo "artefacts: $OUT"
[ "$FAILS" = 0 ] && echo "PASS: one layout on both screens (migrated, consistent); a resize on the $screen screen shows on the other; layout restored exactly" || { echo "FAIL: $FAILS step(s)"; exit 1; }
