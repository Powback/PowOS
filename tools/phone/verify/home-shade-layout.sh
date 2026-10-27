#!/bin/bash
# lanes: phone
# Capture the user's folded/unfolded home and shade, with native layout and status-bar bounds.
# No layout writes. Reset the display override and close the shade on exit.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/e2e-lib.sh"
OUT=$HOME/.cache/powos-verify/home-shade-$(date +%m%d-%H%M)
mkdir -p "$OUT"
. "$here/window-lock.sh"
window_lock home-shade-layout 120
I0=$(irq)
restore() {
  sh_ 'input keyevent BACK; cmd device_state state reset' >/dev/null
  [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"
}
trap restore EXIT
export CDP_TIMEOUT_S=20
BOXES='JSON.stringify({size:[innerWidth,innerHeight],items:[...document.querySelectorAll(".page:not(.away) .home-tile")].map(e=>({key:e.dataset.key,text:e.textContent.slice(0,100),box:e.getBoundingClientRect().toJSON()}))})'
BAR='JSON.stringify([...document.querySelectorAll(".status-chrome button")].map(e=>({text:e.textContent,box:e.getBoundingClientRect().toJSON()})))'
for state in 0 3; do
  sh_ "cmd device_state state $state; am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"
  sleep 3
  chk display
  hcall home.get '[]' 'v=>JSON.stringify(v)' > "$OUT/home-$state.json"
  ev "$BOXES" > "$OUT/tiles-$state.json"
  ev "$BAR" statusbar > "$OUT/status-home-$state.json"
  "$T/shot.sh" "$OUT/home-$state.png" >/dev/null || exit 1
  hcall shade.open '[]' '()=>"opened"' >/dev/null
  sleep 1
  chk shade
  ev "$BAR" statusbar > "$OUT/status-shade-$state.json"
  ev 'JSON.stringify([...document.querySelectorAll(".notif-bar,.cc-clock")].map(e=>({text:e.textContent,box:e.getBoundingClientRect().toJSON()})))' shade > "$OUT/shade-head-$state.json"
  "$T/shot.sh" "$OUT/shade-$state.png" >/dev/null || exit 1
  sh_ 'dumpsys window windows' > "$OUT/windows-$state.txt"
  sh_ 'input keyevent BACK'
done
echo "Captured home/shade layouts for visual review: $OUT"
