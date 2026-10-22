#!/bin/bash
# The running bar under app icons (board "running indicator on app icons") on the phone, READ-ONLY: the home page has
# marked cells (.app[data-run], from the host's apps.running: Android tasks, powos-sleep-gui's running/apps.json),
# their bar is the accent with no animation, powos-sleep-gui's file is there, and a screencap.
set -u
cd "$(dirname "$0")/../../.." || exit 1
probe='(()=>{const c=[...document.querySelectorAll(".app[data-run]")];const i=c[0]?.querySelector(".app-icon");
const s=i&&getComputedStyle(i,"::after");return JSON.stringify({marked:c.length,
keys:[...new Set(c.map(e=>e.dataset.key+"="+e.dataset.run))].slice(0,12),bar:s?s.backgroundColor+" "+s.width+"x"+s.height:null,
accent:getComputedStyle(document.documentElement).getPropertyValue("--color-accent").trim(),
anims:c.reduce((n,e)=>n+e.getAnimations({subtree:true}).length,0)})})()'
out=$(tools/phone/cdp.sh eval home "$probe" 2>&1 | tr -d '\n')
linux=$(tools/phone/adb.sh shell su -c "'cat /data/data/com.powos.app/files/run/running/apps.json 2>/dev/null || echo none'" 2>&1 | tr -d '\r\n' | tail -c 300)
shot=$HOME/.cache/running-dot/device-home.png
mkdir -p "$(dirname "$shot")"
tools/phone/shot.sh "$shot" >/dev/null 2>&1 || shot="(no screencap)"
echo "running-dot: dom $(tail -c 400 <<<"$out") linux $linux shot=$shot"
if ! grep -q '"marked":[1-9]' <<<"$out"; then echo "FAIL running-dot: no app icon marked running (APK without apps.running, or no task)"; exit 1; fi
if ! grep -q '"anims":0' <<<"$out"; then echo "FAIL running-dot: marked cells animate at rest"; exit 1; fi
echo "PASS running-dot: $(grep -o '"marked":[0-9]*' <<<"$out"), linux file: ${linux:0:120}"
