#!/bin/bash
# Themed icons slice 2 (board theme-recolor-icons) on the phone: asks the ship service for origin's tip if the
# phone still serves an old ui/icontint.ts (waits up to 3 min), then READ-ONLY: the served module has the
# "hue" mode, the user's current setting, how many icons are recoloured copies, and a screencap.
set -u
cd "$(dirname "$0")/../../.." || exit 1
probe='fetch("ui/icontint.ts").then(r=>r.text()).then(t=>JSON.stringify({hue:t.includes("toPalette"),
  tint:localStorage.getItem("powos.icons.tint"),blobs:document.querySelectorAll("img[src^=\"blob:\"]").length}))'
out=$(tools/phone/cdp.sh eval home "$probe" 2>&1)
if ! grep -q 'hue.\{0,3\}:true' <<<"$out"; then
  # Only the ship service pushes (push.sh refuses checks since c93b8bc): ask it for origin's tip, wait for it served.
  tools/phone/ship.sh request --silent --note "icon-hues check: phone serves an older icontint.ts" >/dev/null 2>&1
  for _ in $(seq 18); do sleep 10; out=$(tools/phone/cdp.sh eval home "$probe" 2>&1); grep -q 'hue.\{0,3\}:true' <<<"$out" && break; done
fi
shot=$HOME/.cache/icons2/device-home.png
mkdir -p "$(dirname "$shot")"
tools/phone/shot.sh "$shot" >/dev/null 2>&1 || shot="(no screencap)"
echo "icon-hues: $(tr -d '\n' <<<"$out" | tail -c 200) shot=$shot"
grep -q 'hue.\{0,3\}:true' <<<"$out"
