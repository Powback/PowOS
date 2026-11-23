#!/bin/bash
# lanes: phone
# The launcher and PowOS AI fill the width with a side dock (board side-dock-on-the-right-launcher-and-ai-chat-aren; the
# user, 2026-11-23: "A launcher is not full width if the docking is on the right"), folded and unfolded, left and
# right: the launcher's window keeps clear of the dock only while the dock is shown beside it, otherwise no reserve on
# either side. Tried with state.ts dockTry (this page only, never stored), restored on exit; screencaps for review.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/e2e-lib.sh"
OUT=$HOME/.cache/powos-verify/side-dock-width-$(date +%m%d-%H%M%S)
mkdir -p "$OUT"
. "$here/window-lock.sh"
window_lock side-dock-width 120
export CDP_TIMEOUT_S=20
[ "$(sh_ "dumpsys power | sed -n s/.*mWakefulness=//p | head -1")" = Awake ] || exit 3
oldpage=$(hpage)
[[ "$oldpage" =~ ^-?[0-9]+$ ]] || { echo "FAIL: cannot read home page"; exit 1; }
restore() {
  ev "importShim('./state.ts').then(s=>{s.drawer.value=0;s.dockTry.value='';s.page.value=$oldpage;return 'restored'})" >/dev/null
  sh_ 'cmd device_state state reset' >/dev/null
  [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"
}
trap restore EXIT
# The probe for [side]: "ok" or what's wrong - the drawer clip's padding on the dock's side equals the dock's width
# while the dock is on screen and 0 once it has slid out; 0 on the other side; the content spans the clip's box.
probe() {
  ev "(()=>{const side='$1',other=side==='left'?'right':'left',f=[];const c=document.querySelector('.home .drawer-clip');if(!c)return 'no drawer-clip';const cs=getComputedStyle(c),pad={left:parseFloat(cs.paddingLeft),right:parseFloat(cs.paddingRight)};const d=document.querySelector('.home > .dock:not(.dock-tray)'),dr=d&&d.getBoundingClientRect();const shown=!!dr&&dr.width>0&&dr.right>1&&dr.left<innerWidth-1&&Number(getComputedStyle(d).opacity)>0.05;if(shown&&pad[side]<dr.width-1)f.push('dock shown '+Math.round(dr.width)+' but reserve '+Math.round(pad[side]));if(!shown&&pad[side]>1)f.push('dock gone but reserve '+Math.round(pad[side]));if(pad[other]>1)f.push('reserve '+Math.round(pad[other])+' on '+other);const i=c.firstElementChild,r=i&&i.getBoundingClientRect(),w=c.getBoundingClientRect().width-pad.left-pad.right;if(r&&r.width<w-2)f.push('content '+Math.round(r.width)+' of '+Math.round(w));return f.length?f.join('; '):'ok w='+innerWidth+' dock '+(shown?'shown':'gone')})()"
}
fails=0
for state in 0 3; do
  ev 'importShim("./state.ts").then(s=>{s.drawer.value=0;return "closed"})' >/dev/null
  sh_ "cmd device_state state $state; am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"
  sleep 3
  ev 'importShim("./state.ts").then(s=>{s.goHome();return "home"})' >/dev/null
  for side in left right; do
    for kind in apps ai; do
      chk setting
      open=$([ "$kind" = ai ] && echo "s.openPanel('ai')" || echo "s.drawer.value=1")
      ev "importShim('./state.ts').then(s=>{s.drawer.value=0;s.dockTry.value='$side';setTimeout(()=>{if(s.dockTry.value==='$side')s.dockTry.value=''},240000);s.page.value=0;setTimeout(()=>{$open},400);return 'set'})" >/dev/null
      sleep 2
      v=$(probe "$side")
      "$T/shot.sh" "$OUT/launcher-$state-$side-$kind.png" >/dev/null || true
      ev 'importShim("./state.ts").then(s=>{s.drawer.value=0;return "closed"})' >/dev/null
      if [[ "$v" == ok* ]]; then echo "PASS: state $state $side $kind ($v)"; else echo "FAIL: state $state $side $kind: $v"; fails=$((fails + 1)); fi
    done
  done
done
echo "Visual evidence: $OUT"
[ "$fails" = 0 ]
