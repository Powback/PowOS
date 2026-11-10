#!/bin/bash
# lanes: phone
# widgets-nonroot.sh (board widgets-etc-don-t-work-in-powos-on-a-non-rooted; the user: "Widgets etc. don't work in
# PowOS on a non-rooted device"): on the UNROOTED razr (PHONE_SERIAL, default the razr's Mac-adb TLS serial), read only
# over CDP: every home widget tile on screen shows something real - text, or a live terminal/canvas face - not a
# "needs root"/error face, and no reading is nonsense (a percentage over 100, a 0 MHz clock). Run from the Mac.
set -u
cd "$(dirname "$0")/../../.." || exit 5
ADB=${ADB:-$HOME/Library/Android/sdk/platform-tools/adb}
# The razr on the Mac's own adb (wireless debugging, paired with the Mac only - powos-vadb can't reach it): its mdns
# serial, as nonroot-ports.sh (11-10: the old default matched only 192.168.50.203:, the razr was at .18 under its mdns
# name, so this SKIPped and the board task sat at 3/4 without a check). CDP goes through the Mac's adb too (cdp.sh
# CDP_MAC_ADB).
export PHONE_SERIAL=${PHONE_SERIAL:-$("$ADB" devices | awk '/^(adb-ZY22MQL54Q[^ \t]*|192\.168\.50\.203:[0-9]+)[ \t]+device$/{print $1; exit}')}
[ -n "$PHONE_SERIAL" ] || { echo "SKIP: ENV: the razr isn't on the Mac's adb (adb mdns services)"; exit 5; }
export CDP_MAC_ADB=${CDP_MAC_ADB:-$ADB}
js='JSON.stringify([...document.querySelectorAll(".home-tile")].filter(e=>e.getBoundingClientRect().height>0).map(e=>({t:(e.innerText||"").replace(/\s+/g," ").trim().slice(0,120),live:!!e.querySelector(".xterm-screen,canvas,video,img")})))'
out=$(perl -e 'alarm 60; exec @ARGV' tools/phone/cdp.sh eval home "$js" 2>&1 | tr -d '\\' | tail -1)
echo "widgets-nonroot ($PHONE_SERIAL): $out"
# No answer: say what's in front (the home's WebView exists only while PowOS's home is up; 11-10 the razr's user was in
# Motorola's own wallpaper/style panel, so the PowOS process ran without a page to read).
case "$out" in *'['*) ;; *) echo "widgets-nonroot: in front: $("$ADB" -s "$PHONE_SERIAL" shell dumpsys activity activities 2>/dev/null | awk '/ResumedActivity/{for (i = 1; i <= NF; i++) if ($i ~ /\//) { print $i; exit }}')" ;; esac
python3 - "$out" <<'PY'
import sys,json,re
m=re.search(r"\[.*\]",sys.argv[1])
if not m: print("SKIP: ENV: no CDP answer from home ("+sys.argv[1][-160:]+")"); sys.exit(5)
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
