#!/bin/bash
# lanes: phone
# widgets-nonroot.sh (board widgets-etc-don-t-work-in-powos-on-a-non-rooted; the user: "Widgets etc. don't work in
# PowOS on a non-rooted device"): on the UNROOTED razr (PHONE_SERIAL, default the razr's Mac-adb TLS serial), read only
# over CDP: every home widget tile on screen shows something real - text, or a live terminal/canvas face - not a
# "needs root"/error face, and no reading is nonsense (a percentage over 100, a 0 MHz clock). Run from the Mac.
set -u
cd "$(dirname "$0")/../../.." || exit 5
ADB=${ADB:-$HOME/Library/Android/sdk/platform-tools/adb}
export PHONE_SERIAL=${PHONE_SERIAL:-$("$ADB" devices | awk '/^192\.168\.50\.203:/{print $1; exit}')}
[ -n "$PHONE_SERIAL" ] || { echo "SKIP: ENV: the razr isn't on the Mac's adb"; exit 5; }
js='JSON.stringify([...document.querySelectorAll(".home-tile")].filter(e=>e.getBoundingClientRect().height>0).map(e=>({t:(e.innerText||"").replace(/\s+/g," ").trim().slice(0,120),live:!!e.querySelector(".xterm-screen,canvas,video,img")})))'
out=$(perl -e 'alarm 60; exec @ARGV' tools/phone/cdp.sh eval home "$js" 2>&1 | tr -d '\\' | tail -1)
echo "widgets-nonroot ($PHONE_SERIAL): $out"
python3 - "$out" <<'PY'
import sys,json,re
m=re.search(r"\[.*\]",sys.argv[1])
if not m: print("SKIP: ENV: no CDP answer from home"); sys.exit(5)
tiles=json.loads(m[0]); f=[]
if not tiles: print("FAIL: no widget tile on home"); sys.exit(1)
for i,t in enumerate(tiles,1):
    s=t["t"].lower()
    if not s and not t["live"]: f.append(f"tile {i} is empty")
    if re.search(r"needs root|not rooted|requires root|unavailable|error",s): f.append(f"tile {i} says: {t['t'][:60]}")
    for p in re.findall(r"(\d+)%",s):
        if int(p)>100: f.append(f"tile {i} reads {p}% ({t['t'][:50]})")
    if re.search(r"\b0 mhz\b",s): f.append(f"tile {i} reads 0 MHz ({t['t'][:50]})")
if f: print("FAIL: "+"; ".join(f)); sys.exit(1)
print(f"PASS: {len(tiles)} widget tiles render real content unrooted")
PY
