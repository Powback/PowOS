#!/bin/bash
# Themed icons slice 2 (board theme-recolor-icons) on the phone: ships ui/icontint.ts + ui/screens.tsx if the phone
# still serves the old copy (push.sh refused while the phone was offline), then READ-ONLY: the served module has the
# "hue" mode, the user's current setting, how many icons are recoloured copies, and a screencap.
set -u
cd "$(dirname "$0")/../../.." || exit 1
probe='fetch("ui/icontint.ts").then(r=>r.text()).then(t=>JSON.stringify({hue:t.includes("toPalette"),
  tint:localStorage.getItem("powos.icons.tint"),blobs:document.querySelectorAll("img[src^=\"blob:\"]").length}))'
out=$(tools/phone/cdp.sh eval home "$probe" 2>&1)
if ! grep -q 'hue.\{0,3\}:true' <<<"$out"; then
  READY_MS=90000 shell/push.sh --note "Settings > style > icons: new 'theme hues' option recolours app icons into the theme's palette" \
    shell/ui/icontint.ts shell/ui/screens.tsx || { echo "icon-hues: push failed"; exit 1; }
  sleep 20
  out=$(tools/phone/cdp.sh eval home "$probe" 2>&1)
fi
shot=$HOME/.cache/icons2/device-home.png
mkdir -p "$(dirname "$shot")"
tools/phone/shot.sh "$shot" >/dev/null 2>&1 || shot="(no screencap)"
echo "icon-hues: $(tr -d '\n' <<<"$out" | tail -c 200) shot=$shot"
grep -q 'hue.\{0,3\}:true' <<<"$out"
