#!/bin/bash
# lanes: emu phone
# fetch widget logo after a restart (board fetch-widget-broken-logo-white-box): READ-ONLY on home - the served owl.tsx
# has the fix (canvas contain: size, MAX_CANVAS, Image onError), the fetch tile's logo canvas stays inside its box
# (it grew into a 28 px bar down the tile at dpr 2.76), no OWL tile shows a broken image, plus a screencap of home.
set -u
cd "$(dirname "$0")/../../.." || exit 1
probe='fetch("ui/owl.tsx").then(r=>r.text()).then(t=>{
  const tile=[...document.querySelectorAll(".tile.widget-face")].find(e=>/@/.test(e.querySelector(".owl")?.textContent||""));
  const c=tile?.querySelector("canvas"), b=c?.parentElement?.getBoundingClientRect(), r=c?.getBoundingClientRect();
  const broken=[...document.querySelectorAll(".widget-face img")].filter(i=>i.complete&&!i.naturalWidth&&getComputedStyle(i).visibility!=="hidden").length;
  return JSON.stringify({fix:t.includes("MAX_CANVAS")&&t.includes("onError"),tile:!!tile,
    canvas:r?[Math.round(r.width),Math.round(r.height),c.width,c.height]:null,box:b?[Math.round(b.width),Math.round(b.height)]:null,
    inside:!!(r&&b&&r.height<=b.height+1&&r.width<=b.width+1),broken,dpr:devicePixelRatio,w:innerWidth})})'
out=$(tools/phone/cdp.sh eval home "$probe" 2>&1 | tr -d '\n\\')
shot=$HOME/.cache/powos-verify-shots/fetch-logo-home.png
mkdir -p "$(dirname "$shot")"
tools/phone/shot.sh "$shot" >/dev/null 2>&1 || shot="(no screencap)"
echo "fetch-logo: $(tail -c 300 <<<"$out") shot=$shot"
grep -q '"fix":true' <<<"$out" && grep -q '"inside":true' <<<"$out" && grep -q '"broken":0' <<<"$out"
