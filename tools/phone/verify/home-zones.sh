#!/bin/bash
# lanes: phone
# One swipe-up gesture for home and over apps: from the bottom strip on HOME's main page the left corner opens
# PowOS AI's pull-up panel, the right corner the drawer's (the same "PowOS pull-up panel" window and PowosCornerPull
# path as over an app), the centre the switcher. And a fast SHORT flick up in the centre commits the switcher
# (distance OR speed OR hold decides; only short and slow aborts), a short slow one does not.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
installed=$(cat "$HOME/.cache/powos-installed-commit" 2>/dev/null)
if [ -z "$installed" ] || ! git -C "$here" diff --quiet "$installed" HEAD -- ":(top)targets/android/app"; then
  echo "SKIP: the gesture APK has not been installed yet"; exit 3
fi
. "$here/e2e-lib.sh"
. "$here/window-lock.sh"
OUT=$HOME/.cache/powos-verify/home-zones-$(date +%m%d-%H%M%S); mkdir -p "$OUT"
window_lock home-zones 120
export CDP_TIMEOUT_S=20
oldpage=$(hpage)
[[ "$oldpage" =~ ^-?[0-9]+$ ]] || exit 1
restore() { sh_ 'input keyevent BACK' >/dev/null; sh_ 'input keyevent BACK' >/dev/null
  ev "importShim('./state.ts').then(s=>{s.page.value=$oldpage;return 'restored'})" >/dev/null
  [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"; }
trap restore EXIT
home() { sh_ 'am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null'; sleep 2
  ev 'importShim("./state.ts").then(s=>{s.goHome();s.page.value=0;return "main"})' >/dev/null; sleep 1; }
read -r W H <<<"$(ev '[innerWidth,innerHeight].map(n=>Math.round(n*devicePixelRatio)).join(" ")')"
y=$((H-3))
# swipe <x> <up px> <ms>, then what the native gesture logged
swipe() { sh_ 'logcat -c'; sh_ "input swipe $1 $y $1 $((y-$2)) $3"; sleep 2.5
  sh_ 'logcat -d -v time' | grep -E 'PowosCornerPull|PowosNavGesture|PowosGestures' | tail -8 > "$OUT/$4.log"; }
panel() { sh_ 'dumpsys window windows' | grep -E 'Window #.*PowOS pull-up panel' -A20 | grep -c 'mViewVisibility=0x0'; }
fail() { "$T/shot.sh" "$OUT/$1.png" >/dev/null 2>&1; echo "FAIL: $2 (log $OUT/$1.log)"; exit 1; }
switcher_open() { [ "$(ev 'document.querySelector(".recents")?.classList.contains("open") || false')" = true ]; }

for z in "left:$((W/10)):ai" "right:$((W*9/10)):apps"; do
  IFS=: read -r name x kind <<<"$z"
  home; swipe "$x" $((H/3)) 300 "zone-$name"
  grep -q "corner pull: $kind" "$OUT/zone-$name.log" || fail "zone-$name" "home $name corner swipe did not open the $kind pull-up panel (as over an app)"
  sh_ 'input keyevent BACK'; sleep 1
done
home; swipe $((W/2)) $((H/3)) 300 centre
switcher_open || fail centre "home centre swipe did not open the switcher"
sh_ 'input keyevent BACK'; sleep 1
# Early release: fast and short (~28 dp) commits; short and slow (~24 dp, 500 ms) does not.
home; swipe $((W/2)) 70 60 flick
switcher_open || fail flick "a fast short flick up did not commit the switcher"
sh_ 'input keyevent BACK'; sleep 1
home; swipe $((W/2)) 60 500 slow
switcher_open && fail slow "a short slow release opened the switcher (should abort)"
# Swipe up closes the open launcher: from its foot (above the nav strip), the panel follows and shuts.
home; ev 'importShim("./state.ts").then(s=>{s.drawer.value=1;return "open"})' >/dev/null; sleep 1.5
sh_ "input swipe $((W/2)) $((H*85/100)) $((W/2)) $((H*40/100)) 250"; sleep 1.5
[ "$(ev 'importShim("./state.ts").then(s=>s.drawer.value)')" = 0 ] || fail close-up "swipe up from the open launcher's foot did not close it"
echo "PASS: home corners open AI/apps panels, centre the switcher, a fast short flick commits, a short slow one aborts, swipe up closes the launcher"
