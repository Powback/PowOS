#!/bin/bash
# The running bar under app icons (board "running indicator on app icons") on the phone: Calculator opened through
# home's own launch call (apps.launch over CDP, no touch) gets its cells marked by the "apps.running" event (cells
# .app[data-run], from the host's apps.running: Android tasks, powos-sleep-gui's running/apps.json), their bar is the
# accent with no animation, powos-sleep-gui's file is there, a screencap; then Calculator is stopped and its mark
# must go. Calculator is stopped FIRST (a run that found it open only re-read the start-up map and passed without an
# event, 2026-10-23); a FAIL says which link broke: the host's own map (apps.running call: no task read = listener)
# or only the page's cells (event not reaching the page). Unfolded the launch floats (freeform): the mode is printed.
# Always restores: Calculator stopped, home. Exit 3: no free window.
set -u
cd "$(dirname "$0")/../../.." || exit 1
PKG=com.oneplus.calculator
sh_() { tools/phone/adb.sh shell "su -c '$*'" 2>/dev/null | tr -d '\r'; }
# cdp.sh prints the result as a JSON string: drop the escaping so plain greps match.
ev() { tools/phone/cdp.sh eval home "$1" 2>&1 | tr -d '\n\r' | sed 's/\\"/"/g; s/^"//; s/"$//'; }
# A call on home's bridge as the page makes it (float-desktops.sh hcall).
hcall() {
  ev "new Promise(ok=>{const h=window.__powosHost,P=window.PowosHost;if(!h||!P||!P.postMessage)return ok('ERR no bridge');const r=h.resolve,j=h.reject,id=910400+Math.floor(Math.random()*9000);const done=v=>{h.resolve=r;h.reject=j;ok(v)};h.resolve=(i,v)=>i===id?done(v):r(i,v);h.reject=(i,m)=>i===id?done('ERR '+m):j(i,m);setTimeout(()=>done('ERR no answer'),8000);P.postMessage(JSON.stringify([id,'$1',JSON.stringify($2)]))}).then(v=>typeof v==='string'&&v.startsWith('ERR')?v:($3)(v))" | tail -c 200
}
calcrun() { ev "[...document.querySelectorAll('.app[data-key^=\"a:$PKG/\"]')].map(e=>e.dataset.run||'-').join(',')"; }
. tools/phone/verify/window-lock.sh
window_lock running-dot.sh 120
restore() { sh_ "am force-stop $PKG"; sh_ "am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; }
trap 'restore; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$HOME/.cache/powos-verify.lock"' EXIT
s=$(sh_ "dumpsys power | sed -n s/.*mWakefulness=//p | head -1")
[ "$s" = Awake ] || { echo "the screen is $s - not woken (rule); nothing done"; exit 3; }
sh_ "am force-stop $PKG"
t=0; while grep -q running <<<"$(calcrun)" && [ $t -lt 10 ]; do sleep 0.5; t=$((t + 1)); done
grep -q running <<<"$(calcrun)" && { echo "FAIL running-dot: Calculator stopped before the launch, its mark stays"; exit 1; }
key=$(hcall apps.list "[]" "l=>(l.find(a=>/^a:$PKG\\//.test(a.key))||{}).key||'ERR not in the list'")
case $key in a:$PKG/*) ;; *) echo "FAIL running-dot: Calculator's key: $key"; exit 1 ;; esac
# The main log rotates in seconds (256 KiB, OplusTouch spam): a `logcat -d` after the fact found nothing. Capture the
# tags from the launch on, on the phone, bounded (timeout); hiddenapi denials log under the app's process name.
sh_ "rm -f /data/local/tmp/rd-log.txt; (timeout 40 logcat -T 1 -v time -s PowosWindowFrames PowosFreeform PowosRunning com.powos.app:W </dev/null >/data/local/tmp/rd-log.txt 2>&1 &)"
r=$(hcall apps.launch "['$key']" "()=>'ok'"); [ "$r" = ok ] || { echo "FAIL running-dot: apps.launch: $r"; exit 1; }
t=0; until grep -q running <<<"$(calcrun)" || [ $t -ge 20 ]; do sleep 0.5; t=$((t + 1)); done
mode=$(sh_ "dumpsys activity activities" | grep -E "Task\\{.*$PKG" | grep -o "mode=[a-z-]*" | head -1)
host=$(hcall apps.running "[]" "m=>Object.keys(m).filter(k=>k.includes('$PKG')).join(',')||'none'")
echo "running-dot: Calculator launched ($mode), its cells: $(calcrun) after $((t * 5 / 10)) s; host map: $host"
probe='(()=>{const c=[...document.querySelectorAll(".app[data-run]")];const i=c[0]?.querySelector(".app-icon");
const s=i&&getComputedStyle(i,"::after");return JSON.stringify({marked:c.length,
keys:[...new Set(c.map(e=>e.dataset.key+"="+e.dataset.run))].slice(0,12),bar:s?s.backgroundColor+" "+s.width+"x"+s.height:null,
accent:getComputedStyle(document.documentElement).getPropertyValue("--color-accent").trim(),
anims:c.reduce((n,e)=>n+e.getAnimations({subtree:true}).length,0)})})()'
out=$(ev "$probe")
linux=$(tools/phone/adb.sh shell su -c "'cat /data/data/com.powos.app/files/run/running/apps.json 2>/dev/null || echo none'" 2>&1 | tr -d '\r\n' | tail -c 300)
shot=$HOME/.cache/running-dot/device-home.png
mkdir -p "$(dirname "$shot")"
tools/phone/shot.sh "$shot" >/dev/null 2>&1 || shot="(no screencap)"
echo "running-dot: dom $(tail -c 400 <<<"$out") linux $linux shot=$shot"
if ! grep -q running <<<"$(calcrun)"; then
  case $host in *$PKG*) why="the host's map has it: the apps.running event didn't reach the page" ;;
  *) why="the host's map lacks it: no task read after the launch (logcat PowosRunning: listener on? tasks: ...)" ;; esac
  echo "FAIL running-dot: Calculator open ($mode), its cells not marked running - $why"
  sh_ "tail -30 /data/local/tmp/rd-log.txt"; exit 1
fi
if ! grep -q '"marked":[1-9]' <<<"$out"; then echo "FAIL running-dot: no app icon marked running (APK without apps.running, or no task)"; exit 1; fi
if ! grep -q '"anims":0' <<<"$out"; then echo "FAIL running-dot: marked cells animate at rest"; exit 1; fi
{
  sh_ "am force-stop $PKG"
  t=0; while grep -q running <<<"$(calcrun)" && [ $t -lt 20 ]; do sleep 0.5; t=$((t + 1)); done
  grep -q running <<<"$(calcrun)" && { echo "FAIL running-dot: Calculator stopped, its mark stays ($(calcrun))"; exit 1; }
  echo "running-dot: Calculator stopped, its mark went after $((t * 5 / 10)) s"
}
echo "PASS running-dot: $(grep -o '"marked":[0-9]*' <<<"$out"), linux file: ${linux:0:120}"
