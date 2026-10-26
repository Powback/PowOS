#!/bin/bash
# lanes: emu phone
# A-Z scrub highlight (board "A-Z scrub highlights the letter's apps", drawer.tsx highlight) on the phone, in a free
# window (run by queue.sh with LOCK_HELD=1): opens the drawer with a swipe, holds an injected finger on the A-Z bar at M,
# reads which cells are lit / how dim the rest are, screencaps, lifts the finger, checks everything eased back, then
# Back closes the drawer. Nothing persistent changes.
set -u
cd "$(dirname "$0")/../../.." || exit 1
p=tools/phone
[ -n "${LOCK_HELD:-}" ] || { echo "az-scrub: run it through tools/phone/verify/queue.sh add"; exit 3; }
fg=$($p/adb.sh shell "dumpsys activity activities | grep -m1 topResumedActivity")
[[ "$fg" == *HomeShell* ]] || { echo "az-scrub: home isn't in front"; exit 3; }
$p/cdp.sh eval home 'fetch("ui/drawer.tsx").then(r=>r.text()).then(t=>t.includes("data-lit"))' | grep -q true ||
  { echo "FAIL az-scrub: the phone serves a drawer.tsx without the highlight"; exit 1; }
read -r W H < <($p/cdp.sh eval home 'Math.round(innerWidth*devicePixelRatio)+" "+Math.round(innerHeight*devicePixelRatio)' | tr -d '"')
$p/adb.sh shell input swipe $((W * 3 / 4)) $((H * 85 / 100)) $((W * 3 / 4)) $((H * 30 / 100)) 300
sleep 1
read -r X Y < <($p/cdp.sh eval home '(() => { const m = [...document.querySelectorAll(".letter-bar span")].find((s) => s.textContent === "M"); if (!m) return "0 0"; const r = m.getBoundingClientRect(), d = devicePixelRatio; return Math.round((r.x + r.width / 2) * d) + " " + Math.round((r.y + r.height / 2) * d); })()' | tr -d '"')
[ "${X:-0}" -gt 0 ] || { $p/adb.sh shell input keyevent 4; echo "FAIL az-scrub: no A-Z bar after opening the drawer"; exit 1; }
probe='JSON.stringify({scrub: !!document.querySelector(".az[data-scrub]"), lit: [...document.querySelectorAll(".az [data-lit] .app-label")].map((e) => e.textContent), dim: getComputedStyle(document.querySelector(".az .app:not([data-lit])") || document.body).opacity})'
$p/adb.sh shell input motionevent DOWN "$X" "$Y"
sleep 0.5
held=$($p/cdp.sh eval home "$probe" | tr -d '\\')
shot=$HOME/.cache/az-scrub/device-scrub.png
mkdir -p "$(dirname "$shot")"
$p/shot.sh "$shot" >/dev/null 2>&1 || shot="(no screencap)"
$p/adb.sh shell input motionevent UP "$X" "$Y"
sleep 0.5
after=$($p/cdp.sh eval home "$probe" | tr -d '\\')
$p/adb.sh shell input keyevent 4
echo "az-scrub: held=$held after=$after shot=$shot"
if grep -q '"scrub":true' <<<"$held" && grep -q '"lit":\["' <<<"$held" && grep -q '"dim":"0.4"' <<<"$held" &&
  grep -q '"scrub":false' <<<"$after"; then
  echo "PASS az-scrub: the letter's apps lit, the rest at 0.4, cleared on release"
else
  echo "FAIL az-scrub: held=$held after=$after"
fi
