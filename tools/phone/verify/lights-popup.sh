#!/bin/bash
# lights-popup.sh [OUT] (board lights-popup-shows-all-rooms): a held press on the Lights island's room name opens its
# detail sheet (shell/ui/widgetsheet.tsx) with EVERY room: one row per room with its brightness slider,
# the last row on screen or scrollable to (the sheet never runs under home's foot). On the screen the phone is on.
# Home's first page, the room name's spot read over CDP (read only), a held press (900 ms, not on a slider or toggle:
# no light is switched), the sheet read over CDP, a screencap, Back. Restores: Back, home.
# Exit 0 pass, 1 FAIL, 3 a real touch / screen not awake (re-queued), 5 can't run (no Lights island on page 1).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"
OUT=${1:-$HOME/.cache/powos-verify/lights-$(date +%m%d-%H%M)}; mkdir -p "$OUT"
L=$HOME/.cache/powos-verify.lock
sh_() { "$A" shell "su -c '$*'" 2>/dev/null | tr -d '\r'; }
irq() { sh_ "awk '/touch-0/{s+=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9} END{print s}' /proc/interrupts"; }
restore() { sh_ "input keyevent 4; am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; echo "restored"; }
. "$here/window-lock.sh"; window_lock lights-popup.sh 120
trap 'restore; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"' EXIT
I0=$(irq)
chk() { [ "$(irq)" = "$I0" ] || { echo "STOP: a real touch at $1 - restoring"; exit 3; }; }
[ "$(sh_ "dumpsys power | sed -n s/.*mWakefulness=//p | head -1")" = Awake ] || { echo "screen not awake - nothing done"; exit 3; }
sh_ "dumpsys window policy | grep -m1 -E \"mIsShowing=\"" | grep -q true && { echo "keyguard showing - nothing done"; exit 3; }
sh_ "cmd statusbar collapse; am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; sleep 1.5; chk home
"$T/cdp.sh" eval home "(window.__powosHost.emit('system.home', null), 'ok')" >/dev/null 2>&1; sleep 1.2
# The Lights island's room name on the page on screen, device px (the leaf whose text says room, not a control).
pos=$("$T/cdp.sh" eval home 'JSON.stringify((()=>{const e=[...document.querySelectorAll(".island-face *")].find(n=>n.children.length==0&&/room/i.test(n.textContent)&&!n.closest("input,button,[role=switch],[role=slider]"));if(!e)return [0,0];const r=e.getBoundingClientRect();if(r.y<0||r.y>innerHeight||r.x<0||r.x>innerWidth)return [0,0];return [Math.round((r.x+Math.min(r.width,60)/2)*devicePixelRatio),Math.round((r.y+r.height/2)*devicePixelRatio)]})())' 2>/dev/null | tr -dc '0-9,' | tr ',' ' ')
echo "lights room name at: ${pos:-none}" | tee -a "$OUT/log.txt"
set -- ${pos:-0 0}; X=$1; Y=${2:-0}
[ "$X" -gt 0 ] && [ "$Y" -gt 0 ] || { echo "no Lights island on the page on screen - can't run"; exit 5; }
chk press; sh_ "input swipe $X $Y $X $Y 900"; sleep 1.5; chk sheet
r=$("$T/cdp.sh" eval home 'JSON.stringify((()=>{const s=document.querySelector(".wsheet");if(!s)return {open:false};const b=s.querySelector(".wsheet-body")||s,sr=s.getBoundingClientRect();const sl=[...b.querySelectorAll("input[type=range]")];const rows=sl.map(x=>{let r=x;while(r.parentElement&&r.parentElement!==b&&!/[A-Za-z]/.test(r.parentElement.textContent.replace(x.textContent,"")))r=r.parentElement;return (r.parentElement||r).textContent.trim().slice(0,24)});const last=sl[sl.length-1];const lb=last?last.getBoundingClientRect().bottom:0;return {open:true,title:(s.querySelector(".wsheet-title")||{}).textContent||"",rows:sl.length,names:rows,lastOn:lb<=sr.bottom+1&&lb<=innerHeight,scroll:b.scrollHeight>b.clientHeight+1&&getComputedStyle(b).overflowY!=="visible",sheetBottom:Math.round(sr.bottom),vh:innerHeight}})())' 2>&1 | tr -d '\r' | tail -1)
echo "sheet: $r" | tee -a "$OUT/log.txt"
"$T/shot.sh" "$OUT/lights-popup.png" >/dev/null 2>&1
python3 - "$r" <<'PY'
import json, sys
raw = sys.argv[1]
try:
    d = json.loads(json.loads(raw))
except Exception:
    print(f"FAIL: unreadable sheet probe: {raw[:200]}"); sys.exit(1)
if not d.get("open"):
    print("FAIL: the held press opened no detail sheet"); sys.exit(1)
rows = d["rows"]
if rows < 2:
    print(f"FAIL: the sheet shows {rows} room brightness slider(s)"); sys.exit(1)
if not (d["lastOn"] or d["scroll"]):
    print("FAIL: the last room is cut off and the sheet doesn't scroll"); sys.exit(1)
print(f"PASS: Lights sheet '{d['title']}': {rows} rooms with brightness sliders, last row reachable")
PY
