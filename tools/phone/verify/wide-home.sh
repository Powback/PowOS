#!/bin/bash
# wide-home.sh [OUT]: unfolded home is ONE wide page with one bar (dock | search | recent apps), its tiles where the two
# side-by-side pages had them (the host's layout backed up first), and edit mode keeps the dock and shows the search bar
# as a tile on the grid - on the inner screen (forced: cmd device_state state 3) and on the cover (state 0).
# Read-only CDP probes; edit mode is entered by one long press on an empty spot and left with Back (nothing is moved).
# Exits 1 + "FAIL:" lines on a failed step, 3 on a real touch (restored); `cmd device_state state reset` always.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"
OUT=${1:-$HOME/.cache/powos-verify/wide-home-$(date +%m%d-%H%M)}; mkdir -p "$OUT"
L=$HOME/.cache/powos-verify.lock
sh_() { "$A" shell "su -c '$*'" 2>/dev/null | tr -d '\r'; }
irq() { sh_ "awk '/touch-0/{s+=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9} END{print s}' /proc/interrupts"; }
restore() { echo "== restore"; sh_ "input keyevent 4; am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null; cmd device_state state reset"; }
. "$here/window-lock.sh"; window_lock wide-home 120 "${MAX_WAIT:-10800}"
trap 'restore; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"' EXIT
I0=$(irq); FAILS=0
chk() { [ "$(irq)" = "$I0" ] || { echo "STOP: a real touch at $1 - restoring"; exit 3; }; }
step() { echo "== $*" | tee -a "$OUT/log.txt"; }
fail() { echo "FAIL: $*" | tee -a "$OUT/log.txt"; FAILS=$((FAILS + 1)); }
q() { "$T/cdp.sh" eval home "$1" 2>/dev/null | tail -1 | tr -d '"\\\r'; }
hcall() {
  "$T/cdp.sh" eval home "new Promise(ok=>{const h=window.__powosHost,P=window.PowosHost;if(!h||!P||!P.postMessage)return ok('ERR no bridge');const r=h.resolve,j=h.reject,id=910300+Math.floor(Math.random()*9000);const done=v=>{h.resolve=r;h.reject=j;ok(v)};h.resolve=(i,v)=>i===id?done(v):r(i,v);h.reject=(i,m)=>i===id?done('ERR '+m):j(i,m);setTimeout(()=>done('ERR no answer'),8000);P.postMessage(JSON.stringify([id,'$1',JSON.stringify($2)]))}).then(v=>JSON.stringify(v))" 2>&1 | tail -1
}

s=$(sh_ "dumpsys power | sed -n s/.*mWakefulness=//p | head -1")
[ "$s" = Awake ] || { echo "the screen is $s - not woken (rule); nothing done"; exit 3; }

unlock() {
  kg() { sh_ "dumpsys window policy | grep -m1 -E \"mIsShowing=\""; }
  if kg | grep -q true; then sh_ "wm dismiss-keyguard"; sleep 1.5; fi
  if sh_ "dumpsys window | grep -m1 mCurrentFocus" | grep -qi "PowosLock"; then
    local wh; wh=$(sh_ "wm size" | sed -nE 's/.*(Override|Physical) size: ([0-9]+)x([0-9]+).*/\2 \3/p' | tail -1)
    sh_ "input swipe $((${wh% *} / 2)) $((${wh#* } * 9 / 10)) $((${wh% *} / 2)) $((${wh#* } / 4)) 300"; sleep 1.5
  fi
}
home() {
  sh_ "am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; sleep 1.5
  for _ in 1 2; do [ "$(q '!!document.querySelector(".home.open, .home.editing")')" = true ] || break; sh_ "input keyevent 4"; sleep 1; done
}

# The one bar, left to right on one line (wide only).
bar() {
  local r; r=$(q '(()=>{const b=(s)=>document.querySelector(s)?.getBoundingClientRect();const d=b(".home.wide > .dock:not(.dock-tray) .app"),p=b(".home.wide .bar-pill"),t=b(".home.wide > .dock-tray .app");if(!document.querySelector(".home.wide"))return "not wide";if(!p)return "no pill";const m=(r)=>r.top+r.height/2;const bad=[];if(d&&!(d.right<=p.left))bad.push("dock not left of the pill");if(t&&!(p.right<=t.left))bad.push("recents not right of the pill");for(const r of [d,t])if(r&&Math.abs(m(r)-m(p))>4)bad.push("not one line");return bad.join("; ")||"ok"})()')
  echo "bar: $r" | tee -a "$OUT/log.txt"; [ "$r" = ok ] || fail "the wide bar: $r"
}

# Every host tile on the first two pages at its side-by-side place on the wide page (store home.wide), a backup kept.
migrated() {
  hcall home.get "[]" > "$OUT/host.json"; hcall store.get "['home.wide']" > "$OUT/wide.json"; hcall store.get "['home.wide.backup']" > "$OUT/backup.json"
  local r; r=$(python3 - "$OUT" <<'PY'

import json, sys, os
d = sys.argv[1]
def rd(n):
    v = json.loads(open(os.path.join(d, n)).read().strip() or "null")
    return json.loads(v) if isinstance(v, str) and not v.startswith("ERR") else (None if isinstance(v, str) else v)
host, wide, backup = rd("host.json"), rd("wide.json"), rd("backup.json")
if not backup or not backup.get("home", {}).get("items"): print("FAIL: no backup of the host layout (home.wide.backup)")
if not wide: print("FAIL: no wide cells (home.wide)"); sys.exit()
pages = sorted(host["pages"]); n = 0
for it in host["items"]:
    c = it.get("cell")
    if not c or it["page"] not in pages[:2]: continue
    w = wide.get(it["key"]); want = (c["x"] + pages.index(it["page"]) * (host["columns"] + 1), c["y"])
    if not w or (w["x"], w["y"]) != want: print(f"FAIL: {it['key']} at {w and (w['x'], w['y'])}, side by side it was {want}")
    n += 1
print(f"migration: {n} tiles checked, {len(host['items'])} items")
PY
)
  echo "$r" | tee -a "$OUT/log.txt"; echo "$r" | grep -q "^FAIL" && FAILS=$((FAILS + 1))
}

# Edit mode by a long press on an empty spot of the page: the search bar a tile on the grid, the dock in view.
edit() {
  local at; at=$(q '(()=>{const pg=[...document.querySelectorAll(".page")].find(p=>{const r=p.getBoundingClientRect();return r.left>=-2&&r.left<innerWidth/2});if(!pg)return "";const r=pg.getBoundingClientRect(),tiles=[...pg.querySelectorAll(".home-tile")].map(t=>t.getBoundingClientRect());for(let y=r.bottom-60;y>r.top+60;y-=24)for(let x=r.left+40;x<r.right-40;x+=24)if(!tiles.some(t=>x>t.left-12&&x<t.right+12&&y>t.top-12&&y<t.bottom+12))return Math.round(x*devicePixelRatio)+" "+Math.round(y*devicePixelRatio);return ""})()')
  [ -n "$at" ] || { fail "$1: no empty spot to long-press"; return; }
  sh_ "input swipe $at $at 900"; sleep 1.5; chk "edit-$1"
  local r; r=$(q '(()=>{const v=(e)=>!!e&&e.getClientRects().length>0&&getComputedStyle(e).visibility==="visible";if(!document.querySelector(".home.editing"))return "not in edit mode";const bad=[];if(!v(document.querySelector(".home-tile[data-key=\"panel:search\"] .bar-pill")))bad.push("no search bar tile on the grid");if(document.querySelector(".home > .dock")&&!v(document.querySelector(".home > .dock .app")))bad.push("the dock hidden");if(!v(document.querySelector(".edit-sheet")))bad.push("no edit sheet");return bad.join("; ")||"ok"})()')
  echo "edit $1: $r" | tee -a "$OUT/log.txt"; [ "$r" = ok ] || fail "edit mode ($1): $r"
  "$T/shot.sh" "$OUT/edit-$1.png" 2>&1 | tee -a "$OUT/log.txt"
  sh_ "input keyevent 4"; sleep 1
  [ "$(q '!!document.querySelector(".home.editing")')" = true ] && { home; }
}

for screen in inner cover; do
  st=3; [ $screen = cover ] && st=0
  step "$screen screen (device state $st)"; sh_ "cmd device_state state $st"; sleep 4; chk $screen
  unlock; chk "$screen-lock"; home; chk "$screen-home"
  "$T/shot.sh" "$OUT/home-$screen.png" 2>&1 | tee -a "$OUT/log.txt"
  if [ $screen = inner ]; then bar; migrated; fi
  edit $screen
done

restore; trap - EXIT; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"
echo "artefacts: $OUT"
[ "$FAILS" = 0 ] && echo "PASS: wide home + edit mode, inner and cover" || { echo "FAIL: $FAILS step(s)"; exit 1; }
