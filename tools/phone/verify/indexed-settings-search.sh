#!/bin/bash
# lanes: phone
# Detailed OEM settings on the rooted OnePlus; navigation only, no setting values changed.
set -euo pipefail
cd "$(dirname "$0")/../../.."
. tools/phone/verify/e2e-lib.sh
. tools/phone/verify/window-lock.sh
window_lock indexed-settings-search 120
export CDP_TIMEOUT_S=90
OUT=$HOME/.cache/powos-verify/indexed-settings-search-$(date +%m%d-%H%M%S)
mkdir -p "$OUT"
top=$(sh_ 'dumpsys activity activities | grep -m1 topResumedActivity')
top_task=$(sed -nE 's/.* t([0-9]+)\}.*/\1/p' <<<"$top")
case "$top" in *HomeShell*|*HomeDesktop*|*PowosLock*|"") top_task= ;; esac
restore() {
  sh_ 'am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null' >/dev/null || true
  ev 'importShim("./state.ts").then(s=>{s.closeDrawer();s.query.value="";return "restored"})' >/dev/null || true
  [ -z "$top_task" ] || hcall tasks.open "[$top_task]" "()=>\"ok\"" >/dev/null || true
  [ "${LOCK_HELD:-0}" = 1 ] || rmdir "$L" 2>/dev/null || true
}
trap restore EXIT
sh_ 'am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null' >/dev/null
r=$(ev '(async()=>{const s=await importShim("./state.ts"),q=await importShim("./search.ts");s.goHome();s.drawer.value=1;s.query.value="glass edges";for(let i=0;i<50;i++){const hit=q.searchResults.value.find(r=>r.id==="settings:style:glass edges");if(hit){q.openSearchResult(hit);break}await new Promise(r=>setTimeout(r,100))}for(let i=0;i<50;i++){const e=document.querySelector("[data-search-highlight]");if(e?.dataset.setting==="glass edges"){const r=e.getBoundingClientRect(),b=e.closest(".scr-body").getBoundingClientRect();return r.top>=b.top&&r.bottom<=b.bottom?"highlighted":"offscreen"}await new Promise(r=>setTimeout(r,100))}return "missing highlight"})()')
[ "$r" = highlighted ] || { echo "FAIL: PowOS setting $r"; exit 1; }
tools/phone/shot.sh "$OUT/powos-highlight.png" >/dev/null
ev 'importShim("./screens.ts").then(p=>{p.closeScreens();return "closed"})' >/dev/null
r=$(ev '(async()=>{const {powos}=await importShim("./bridge.ts"),s=await importShim("./state.ts"),q=await importShim("./search.ts");s.goHome();s.drawer.value=1;s.query.value="refresh rate";for(let i=0;i<350;i++){const hit=q.searchResults.value.find(r=>r.id.startsWith("android-settings:indexed:")&&r.label==="Screen refresh rate");if(hit){const pages=await powos.qs.destinations();return JSON.stringify({count:pages.filter(p=>p.id.startsWith("indexed:")).length,found:true})}await new Promise(r=>setTimeout(r,200))}return "missing"})()')
echo "index: $r"
python3 -c 'import json,sys; r=json.loads(sys.argv[1]); assert r["found"] and r["count"]>100,r' "$r"
r=$(ev '(async()=>{const s=await importShim("./state.ts"),q=await importShim("./search.ts");for(const text of ["font size","auto rotate","gesture navigation"]){s.query.value=text;let found=false;for(let i=0;i<40;i++){if(q.searchResults.value.some(r=>r.id.startsWith("android-settings:indexed:"))){found=true;break}await new Promise(r=>setTimeout(r,100))}if(!found)return "missing "+text}s.query.value="refresh rate";for(let i=0;i<40;i++){if([...document.querySelectorAll("[data-search-result]")].some(e=>e.textContent.includes("Screen refresh rate")))return "found";await new Promise(r=>setTimeout(r,100))}return "missing refresh UI"})()')
[ "$r" = found ] || { echo "FAIL: $r"; exit 1; }
tools/phone/shot.sh "$OUT/refresh-search.png" >/dev/null
ev '(async()=>{const q=await importShim("./search.ts");const hit=q.searchResults.value.find(r=>r.id.startsWith("android-settings:indexed:")&&r.label==="Screen refresh rate");[...document.querySelectorAll("[data-search-result]")].find(e=>e.dataset.searchResult===hit.id).click();return "clicked"})()' >/dev/null
sleep 2
sh_ 'uiautomator dump /sdcard/powos-settings-search.xml >/dev/null' >/dev/null
r=$(sh_ 'cat /sdcard/powos-settings-search.xml')
[[ "$r" == *'Screen refresh rate'* ]] || { echo 'FAIL: refresh-rate page not shown'; exit 1; }
[[ "$r" == *'Auto-select'* || "$r" == *'High'* || "$r" == *'Standard'* ]] || { echo 'FAIL: detailed refresh-rate choices not shown'; exit 1; }
tools/phone/shot.sh "$OUT/refresh-page.png" >/dev/null
sh_ 'am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null' >/dev/null
record_pid=
if [ "${RECORD_NATIVE:-0}" = 1 ]; then
  "$T/adb.sh" shell screenrecord --size 720x1280 --time-limit 8 --bit-rate 3000000 /sdcard/powos-settings-highlight.mp4 </dev/null >"$OUT/record.log" 2>&1 &
  record_pid=$!
  sleep 0.4
fi
r=$(ev '(async()=>{const s=await importShim("./state.ts"),q=await importShim("./search.ts");s.goHome();s.drawer.value=1;s.query.value="auto rotate";for(let i=0;i<50;i++){const hit=q.searchResults.value.find(r=>r.id.startsWith("android-settings:indexed:com.android.settings:")&&r.label==="Auto-rotate");if(hit){q.openSearchResult(hit);return "opened"}await new Promise(r=>setTimeout(r,100))}return "missing"})()')
[ "$r" = opened ] || { echo 'FAIL: Auto-rotate result missing'; exit 1; }
sleep 0.8
tools/phone/shot.sh "$OUT/auto-rotate-highlight.png" >/dev/null
sh_ 'uiautomator dump /sdcard/powos-settings-search.xml >/dev/null' >/dev/null
r=$(sh_ 'cat /sdcard/powos-settings-search.xml')
[[ "$r" == *'Auto-rotate'* ]] || { echo 'FAIL: Auto-rotate not visible after direct link'; exit 1; }
if [ -n "$record_pid" ]; then
  wait "$record_pid" || { cat "$OUT/record.log"; exit 1; }
  "$T/adb.sh" pull /sdcard/powos-settings-highlight.mp4 "$OUT/native-highlight.mp4" >/dev/null
  sh_ 'rm /sdcard/powos-settings-highlight.mp4' >/dev/null
fi
sh_ 'rm /sdcard/powos-settings-search.xml' >/dev/null
echo "PASS: indexed OEM settings, keyword searches and exact refresh-rate page; screenshots $OUT"
