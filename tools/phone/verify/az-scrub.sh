#!/bin/bash
# lanes: emu phone
# The launcher's A-Z scrub (ui/launcherview.ts; the user, 11-23: "show the recent apps by default and then if you use
# the sorter thing it shifts to show all apps filtered to the letter you are using") on the phone, in a free window (run
# by queue.sh with LOCK_HELD=1): goes home, opens the drawer with a swipe - it must show its sections (Recent first) -,
# holds an injected finger on the A-Z bar at M (every shown app starts with M), screencaps, lifts the finger (still M,
# under its chip), taps the chip (sections again), then taps the bar's bottom "All" (every app under letter headings,
# under an "All" chip; the user, 11-23: "the launcher sorter should have an option to show all on the top and bottom of the
# sorter"; the top one must be there too), taps its chip (sections again), then Back closes the drawer. Nothing
# persistent changes.
# Touch (11-24): every gesture goes through tools/phone/verify/base.sh - the scrub is ONE on-device shell (DOWN on A,
# MOVEs down the bar to M, the finger resting on M, UP; `drag` in the background so the page is probed mid-hold), its
# points from the bar's live rect by drawer.tsx LetterBar's own pick() maths. Before, each motionevent was its own
# `adb shell` (11-23 19:35 on f785d92e: opened/held/after all "view: sections, letter: null" - the hold never picked M,
# while 03:02 on the same build PASSed); the same per-call timing broke scroll-own.sh and home-stack.sh.
set -u
here=$(cd "$(dirname "$0")" && pwd)
. "$here/base.sh"  # sh_, tap, swipe, drag, shot (tools/phone/verify/base.sh)
cd "$(dirname "$0")/../../.." || exit 1
p=tools/phone
[ -n "${LOCK_HELD:-}" ] || { echo "az-scrub: run it through tools/phone/verify/queue.sh add"; exit 3; }
# Home first (a free window: the user isn't on the phone), then Back closes a switcher left over home - as bf-pacing.sh.
# 11-11 21:01: an app in front made this exit 3 every window ("home isn't in front").
$p/adb.sh shell "input keyevent 3; sleep 1; input keyevent 4" >/dev/null 2>&1; sleep 1
fg=$($p/adb.sh shell "dumpsys activity activities | grep -m1 topResumedActivity")
[[ "$fg" == *HomeShell* ]] || { echo "az-scrub: home isn't in front"; exit 3; }
$p/cdp.sh eval home 'fetch("ui/drawer.tsx").then(r=>r.text()).then(t=>t.includes("launcherLetter"))' | grep -q true ||
  { echo "FAIL az-scrub: the phone serves a drawer.tsx without the launcher's sections"; exit 1; }
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
swipe $((W * 3 / 4)) $((H * 85 / 100)) $((W * 3 / 4)) $((H * 30 / 100)) 300 >/dev/null
sleep 1
# A's and M's slot centres on the bar, device px: pick() takes floor((y - top) / height * letters) - the slot centre is
# the one y that's furthest from both neighbours. x = the bar's middle. Read after the drawer settled (a 2nd read
# 300 ms later must match, else the bar was still moving).
BAR='(() => { const b = document.querySelector(".drawer-page .letter-bar"); if (!b) return "0 0 0 0 none"; const s = [...b.querySelectorAll(":scope > span")].map((e) => e.textContent), r = b.getBoundingClientRect(), d = devicePixelRatio, n = s.length, a = s.indexOf("A"), m = s.indexOf("M"); if (a < 0 || m < 0 || !r.height) return "0 0 0 0 none"; const y = (i) => Math.round((r.top + ((i + 0.5) * r.height) / n) * d), x = Math.round((r.left + r.width / 2) * d); return [x, y(a), x, y(m), `bar=${Math.round(r.left)},${Math.round(r.top)},${Math.round(r.width)}x${Math.round(r.height)}@${d}/${n}`].join(" "); })()'
pos=""; for i in 1 2 3 4 5 6; do
  p2=$(cdp_val "$BAR"); [ "$p2" = "$pos" ] && break; pos=$p2; sleep 0.3
done
read -r AX0 AY0 X Y BARINFO <<<"$pos"
vb_int "${X:-}" && [ "${X:-0}" -gt 0 ] || { sh_ "input keyevent 4"; echo "FAIL az-scrub: no A-Z bar after opening the drawer ($pos)"; exit 1; }
probe='JSON.stringify((() => { const p = document.querySelector(".drawer-page .drawer-list"), v = p && p.querySelector("[data-view]"), ends = [...document.querySelectorAll(".drawer-page .letter-bar span")].map((s) => s.textContent), heads = [...(p ? p.querySelectorAll("[data-view=all] [data-group] > .heading") : [])].length, n = [...(p ? p.querySelectorAll("[data-view=letter] .grid.az .app-label") : [])].map((e) => (e.textContent || "").trim()); return { view: v ? v.dataset.view : null, letter: v ? v.dataset.letter || null : null, names: n, allM: n.length > 0 && n.every((t) => t.toUpperCase().startsWith("M")), recent: !!(p && p.querySelector("[data-section=recent] .app")), allEnds: ends[0] === "All" && ends.at(-1) === "All", heads, chip: !!document.querySelector(".drawer-page .launcher-chip") }; })())'
opened=$($p/cdp.sh eval home "$probe" | tr -d '\\')
[ "$LIST" = 1 ] && probe='JSON.stringify((() => { const l = document.querySelector(".az-list:not(.leaving)"), c = l && l.querySelector(".az-list-card"), r = c && c.getBoundingClientRect(), n = [...document.querySelectorAll(".az-list:not(.leaving) .az-list-name")]; return { list: !!l, names: n.map((e) => e.textContent), allM: n.length > 0 && n.every((e) => (e.textContent || "").trim().toUpperCase().startsWith("M")), cut: n.filter((e) => e.scrollWidth > e.clientWidth + 1).length, centred: !!r && (() => { const b = l.getBoundingClientRect(), cs = getComputedStyle(l), pl = parseFloat(cs.paddingLeft), pr = parseFloat(cs.paddingRight); return Math.abs(r.x + r.width / 2 - (b.x + pl + (b.width - pl - pr) / 2)) <= 4; })() }; })())'
# The scrub: DOWN on A, 8 MOVEs to M over 320 ms, the finger resting on M 3 s, UP - one on-device shell in the
# background; the page is polled while it rests (adb's start-up can take ~1 s under load, so up to ~2.4 s).
touch="scrub $AX0,$AY0 -> $X,$Y (8 moves/320 ms, rest 3000 ms) $BARINFO"
echo "az-scrub: touch $touch"
drag "$AX0" "$AY0" "$X" "$Y" 0 320 8 3000 >/dev/null & dp=$!
sleep 0.8
for i in 1 2 3 4 5 6 7 8; do
  held=$($p/cdp.sh eval home "$probe" | tr -d '\\')
  grep -qE '"view":"letter"|"list":true' <<<"$held" && break; sleep 0.2
done
shot=$HOME/.cache/az-scrub/device-scrub.png
mkdir -p "$(dirname "$shot")"
$p/shot.sh "$shot" >/dev/null 2>&1 || shot="(no screencap)"
wait "$dp" 2>/dev/null
sleep 0.5
after=$($p/cdp.sh eval home "$probe" | tr -d '\\')
back='(none)' alls='(none)' allback='(none)'
if [ "$LIST" != 1 ]; then
  read -r CX CY < <($p/cdp.sh eval home '(() => { const c = document.querySelector(".launcher-chip"); if (!c) return "0 0"; const r = c.getBoundingClientRect(), d = devicePixelRatio; return Math.round((r.x + r.width / 2) * d) + " " + Math.round((r.y + r.height / 2) * d); })()' | tr -d '"')
  [ "${CX:-0}" -gt 0 ] && touch="$touch; chip $CX,$CY" && tap "$CX" "$CY" && sleep 0.5
  back=$($p/cdp.sh eval home "$probe" | tr -d '\\')
  # The bar's bottom "All": tapped (DOWN+UP at it), every app under its letter headings, kept, under its chip.
  read -r AX AY < <($p/cdp.sh eval home '(() => { const a = [...document.querySelectorAll(".drawer-page .letter-bar span.all")].at(-1); if (!a) return "0 0"; const r = a.getBoundingClientRect(), d = devicePixelRatio; return Math.round((r.x + r.width / 2) * d) + " " + Math.round((r.y + r.height / 2) * d); })()' | tr -d '"')
  if [ "${AX:-0}" -gt 0 ]; then
    touch="$touch; All $AX,$AY"
    tap "$AX" "$AY" && sleep 0.5
    alls=$($p/cdp.sh eval home "$probe" | tr -d '\\')
    read -r CX CY < <($p/cdp.sh eval home '(() => { const c = document.querySelector(".drawer-page .launcher-chip"); if (!c) return "0 0"; const r = c.getBoundingClientRect(), d = devicePixelRatio; return Math.round((r.x + r.width / 2) * d) + " " + Math.round((r.y + r.height / 2) * d); })()' | tr -d '"')
    [ "${CX:-0}" -gt 0 ] && touch="$touch; chip $CX,$CY" && tap "$CX" "$CY" && sleep 0.5
    allback=$($p/cdp.sh eval home "$probe" | tr -d '\\')
  fi
fi
# A FAIL line carries the touch path and the screencap taken while the finger rested on M ($shot).
sh_ "input keyevent 4"
echo "az-scrub: opened=$opened held=$held after=$after back=$back all=$alls allback=$allback shot=$shot"
if [ "$LIST" = 1 ]; then
  if grep -q '"list":true' <<<"$held" && grep -q '"allM":true' <<<"$held" && grep -q '"cut":0' <<<"$held" &&
    grep -q '"centred":true' <<<"$held" && grep -q '"list":false' <<<"$after"; then
    echo "PASS az-scrub list: the M apps as a centred list, every name whole, gone on release"
  else
    echo "FAIL az-scrub list: held=$held after=$after touch=[$touch] shot=$shot"
  fi
elif grep -qE '"view":"(sections|all)"' <<<"$opened" && grep -q '"view":"letter"' <<<"$held" && grep -q '"allM":true' <<<"$held" &&
  grep -q '"view":"letter"' <<<"$after" && grep -q '"allM":true' <<<"$after" && grep -qE '"view":"(sections|all)"' <<<"$back" &&
  grep -q '"allEnds":true' <<<"$opened" && grep -q '"view":"all"' <<<"$alls" && grep -q '"chip":true' <<<"$alls" &&
  ! grep -q '"heads":0' <<<"$alls" && grep -qE '"view":"(sections|all)"' <<<"$allback" && grep -q '"chip":false' <<<"$allback"; then
  echo "PASS az-scrub: opens on its sections, M shows only the M apps, kept on release, the chip goes back; All at both ends shows every app under headings, its chip goes back"
else
  echo "FAIL az-scrub: opened=$opened held=$held after=$after back=$back all=$alls allback=$allback touch=[$touch] shot=$shot"
fi
