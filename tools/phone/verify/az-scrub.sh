#!/bin/bash
# lanes: emu phone
# A-Z scrub highlight (board "A-Z scrub highlights the letter's apps", drawer.tsx highlight) on the phone, in a free
# window (run by queue.sh with LOCK_HELD=1): goes home, opens the drawer with a swipe, holds an injected finger on the A-Z bar at M,
# reads which cells are lit / how dim the rest are, screencaps, lifts the finger, checks everything eased back, then
# Back closes the drawer. Nothing persistent changes.
set -u
cd "$(dirname "$0")/../../.." || exit 1
p=tools/phone
[ -n "${LOCK_HELD:-}" ] || { echo "az-scrub: run it through tools/phone/verify/queue.sh add"; exit 3; }
# Home first (a free window: the user isn't on the phone), then Back closes a switcher left over home - as bf-pacing.sh.
# 11-11 21:01: an app in front made this exit 3 every window ("home isn't in front").
$p/adb.sh shell "input keyevent 3; sleep 1; input keyevent 4" >/dev/null 2>&1; sleep 1
fg=$($p/adb.sh shell "dumpsys activity activities | grep -m1 topResumedActivity")
[[ "$fg" == *HomeShell* ]] || { echo "az-scrub: home isn't in front"; exit 3; }
$p/cdp.sh eval home 'fetch("ui/drawer.tsx").then(r=>r.text()).then(t=>t.includes("data-lit"))' | grep -q true ||
  { echo "FAIL az-scrub: the phone serves a drawer.tsx without the highlight"; exit 1; }
# AZ_LIST=1: the experimental list mode (Settings > style > experimental, drawer.azList; 14b92ebb): the letter's apps
# as a centred card of whole names over the grid. The setting is read first, switched on for this run, and put back
# on exit, so nothing persistent changes here either.
# Centred = in .az-list's content box (its right padding keeps the A-Z bar clear - shell.css), not the screen's middle
# (11-11 21:16: the card sat left of the screen's centre by design and read as a FAIL).
LIST=${AZ_LIST:-0}
if [ "$LIST" = 1 ]; then
  AZ0=$($p/cdp.sh eval home 'importShim("./ui/drawer.tsx").then((m) => JSON.stringify(m.azList.value))' | sed 's/^"//; s/"$//; s/\\"/"/g')
  case $AZ0 in '"'*'"') ;; *) echo "FAIL az-scrub: drawer.azList unreadable ($AZ0)"; exit 1 ;; esac
  trap '$p/cdp.sh eval home "importShim(\"./ui/drawer.tsx\").then((m) => { m.azList.value = $AZ0; return \"ok\"; })" >/dev/null' EXIT
  $p/cdp.sh eval home 'importShim("./ui/drawer.tsx").then((m) => { m.azList.value = "on"; return m.azList.value; })' | grep -q on ||
    { echo "FAIL az-scrub: couldn't switch drawer.azList on"; exit 1; }
fi
read -r W H < <($p/cdp.sh eval home 'Math.round(innerWidth*devicePixelRatio)+" "+Math.round(innerHeight*devicePixelRatio)' | tr -d '"')
$p/adb.sh shell input swipe $((W * 3 / 4)) $((H * 85 / 100)) $((W * 3 / 4)) $((H * 30 / 100)) 300
sleep 1
read -r X Y < <($p/cdp.sh eval home '(() => { const m = [...document.querySelectorAll(".letter-bar span")].find((s) => s.textContent === "M"); if (!m) return "0 0"; const r = m.getBoundingClientRect(), d = devicePixelRatio; return Math.round((r.x + r.width / 2) * d) + " " + Math.round((r.y + r.height / 2) * d); })()' | tr -d '"')
[ "${X:-0}" -gt 0 ] || { $p/adb.sh shell input keyevent 4; echo "FAIL az-scrub: no A-Z bar after opening the drawer"; exit 1; }
probe='JSON.stringify({scrub: !!document.querySelector(".az[data-scrub]"), lit: [...document.querySelectorAll(".az [data-lit] .app-label")].map((e) => e.textContent), dim: getComputedStyle(document.querySelector(".az .app:not([data-lit])") || document.body).opacity})'
[ "$LIST" = 1 ] && probe='JSON.stringify((() => { const l = document.querySelector(".az-list:not(.leaving)"), c = l && l.querySelector(".az-list-card"), r = c && c.getBoundingClientRect(), n = [...document.querySelectorAll(".az-list:not(.leaving) .az-list-name")]; return { list: !!l, names: n.map((e) => e.textContent), allM: n.length > 0 && n.every((e) => (e.textContent || "").trim().toUpperCase().startsWith("M")), cut: n.filter((e) => e.scrollWidth > e.clientWidth + 1).length, centred: !!r && (() => { const b = l.getBoundingClientRect(), cs = getComputedStyle(l), pl = parseFloat(cs.paddingLeft), pr = parseFloat(cs.paddingRight); return Math.abs(r.x + r.width / 2 - (b.x + pl + (b.width - pl - pr) / 2)) <= 4; })() }; })())'
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
if [ "$LIST" = 1 ]; then
  if grep -q '"list":true' <<<"$held" && grep -q '"allM":true' <<<"$held" && grep -q '"cut":0' <<<"$held" &&
    grep -q '"centred":true' <<<"$held" && grep -q '"list":false' <<<"$after"; then
    echo "PASS az-scrub list: the M apps as a centred list, every name whole, gone on release"
  else
    echo "FAIL az-scrub list: held=$held after=$after"
  fi
elif grep -q '"scrub":true' <<<"$held" && grep -q '"lit":\["' <<<"$held" && grep -q '"dim":"0.4"' <<<"$held" &&
  grep -q '"scrub":false' <<<"$after"; then
  echo "PASS az-scrub: the letter's apps lit, the rest at 0.4, cleared on release"
else
  echo "FAIL az-scrub: held=$held after=$after"
fi
