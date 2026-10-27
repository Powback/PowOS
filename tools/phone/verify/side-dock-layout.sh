#!/bin/bash
# lanes: phone
# Check both side docks folded/unfolded, real dock swipes, and full-width launcher/search. Restore the setting.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/e2e-lib.sh"
OUT=$HOME/.cache/powos-verify/side-dock-$(date +%m%d-%H%M%S)
mkdir -p "$OUT"
. "$here/window-lock.sh"
window_lock side-dock-layout 120
export CDP_TIMEOUT_S=20
I0=$(irq)
[ "$(sh_ "dumpsys power | sed -n s/.*mWakefulness=//p | head -1")" = Awake ] || exit 3
old=$(ev 'importShim("./state.ts").then(s=>s.dockPlacement.value)')
case "$old" in bottom|left|right) ;; *) echo "FAIL: cannot read dock setting"; exit 1 ;; esac
oldpage=$(hpage)
[[ "$oldpage" =~ ^-?[0-9]+$ ]] || { echo "FAIL: cannot read home page"; exit 1; }
restore() {
  ev "importShim('./state.ts').then(s=>{s.drawer.value=0;s.dockPlacement.value='$old';s.page.value=$oldpage;return 'restored'})" >/dev/null
  sh_ 'input keyevent BACK; cmd device_state state reset' >/dev/null
  [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"
}
trap restore EXIT
close_shade() {
  ev '(window.__powosHost.emit("shade.settle", {open:false}), "closed")' shade >/dev/null
  sleep 1
}
shade_open() {
  ev 'importShim("./ui/gesture.ts").then(s=>String(s.notifShown()>0.01))' shade
}
for state in 0 3; do
  close_shade
  ev 'importShim("./state.ts").then(s=>{s.drawer.value=0;return "closed"})' >/dev/null
  sh_ "cmd device_state state $state; am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"
  sleep 3
  for side in left right; do
    close_shade
    chk setting
    ev "importShim('./state.ts').then(s=>{s.drawer.value=0;s.dockPlacement.value='$side';s.page.value=0;return 'set'})" >/dev/null
    sleep 1
    read -r x y end <<<"$(ev '(()=>{const r=document.querySelector(".home > .dock").getBoundingClientRect(),d=devicePixelRatio;return [r.x+r.width/2,r.bottom-45,r.top+45].map(n=>Math.round(n*d)).join(" ")})()')"
    echo "dock $state $side: swipe $x,$y -> $x,$end"
    [[ "$x $y $end" =~ ^[0-9]+\ [0-9]+\ [0-9]+$ ]] && [ "$y" -gt "$end" ] || { echo "FAIL: invalid dock swipe geometry"; exit 1; }
    sh_ "input swipe $x $y $x $end 400"
    sleep 1
    chk dock-swipe
    opened=$(ev 'importShim("./state.ts").then(s=>String(s.drawer.value!==0||s.notif.value))')
    native=$(shade_open)
    [ "$native" = false ] || { echo "FAIL: $state $side dock swipe opened native shade ($native)"; exit 1; }
    [ "$opened" = false ] || { echo "FAIL: $state $side dock swipe opened launcher or shade ($opened)"; exit 1; }
    "$T/shot.sh" "$OUT/home-$state-$side.png" >/dev/null || exit 1
    ev 'importShim("./state.ts").then(s=>{s.drawer.value=1;return "open"})' >/dev/null
    sleep 1
    verdict=$(ev '(()=>{const c=document.querySelector(".launcher-clip").getBoundingClientRect(),b=document.querySelector(".home > .bar").getBoundingClientRect();return c.left<20&&c.right>innerWidth-20&&b.top>=0&&b.bottom<=innerHeight+1&&b.bottom>innerHeight-60?"ok":JSON.stringify({clip:c.toJSON(),bar:b.toJSON(),size:[innerWidth,innerHeight]})})()')
    [ "$verdict" = ok ] || { echo "FAIL: $state $side launcher: $verdict"; exit 1; }
    "$T/shot.sh" "$OUT/launcher-$state-$side.png" >/dev/null || exit 1
    echo "PASS: $state $side dock swipe isolated; launcher/search fully visible"
  done
done
echo "Visual evidence: $OUT"
