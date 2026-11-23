#!/bin/bash
# lanes: phone
# The side dock's alignment (shell/ui/dockalign.ts), folded and unfolded, left and right, top and bottom: bottom keeps
# every pinned app at the column's foot on screen with the recents above it (they scroll, the pinned don't); top keeps
# the pinned group at the column's top. Tried with state.ts dockTry/dockAlignTry (this page only, never stored: the
# user's own placement and alignment are never written), restored on exit; screencaps of each case for review.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/e2e-lib.sh"
OUT=$HOME/.cache/powos-verify/side-dock-align-$(date +%m%d-%H%M%S)
mkdir -p "$OUT"
. "$here/window-lock.sh"
window_lock side-dock-align 120
export CDP_TIMEOUT_S=20
[ "$(sh_ "dumpsys power | sed -n s/.*mWakefulness=//p | head -1")" = Awake ] || exit 3
oldpage=$(hpage)
[[ "$oldpage" =~ ^-?[0-9]+$ ]] || { echo "FAIL: cannot read home page"; exit 1; }
restore() {
  ev "importShim('./state.ts').then(s=>{s.drawer.value=0;s.dockTry.value='';s.dockAlignTry.value='';s.page.value=$oldpage;return 'restored'})" >/dev/null
  sh_ 'cmd device_state state reset' >/dev/null
  [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"
}
trap restore EXIT
# The probe: "ok" or what's wrong, for [align] - pinned cells inside the column and the screen; bottom: pinned at the
# column's foot, recents above it; top: pinned at the column's top, recents under it.
probe() {
  ev "(()=>{const a='$1',f=[],col=document.querySelector('.home > .dock .dock-pages')?.getBoundingClientRect(),pe=document.querySelector('.home > .dock .dock-page:not(.dock-recent)'),re=document.querySelector('.home > .dock .dock-recent');if(!col||!pe)return 'no side column or pinned apps';const p=pe.getBoundingClientRect();for(const c of pe.querySelectorAll(':scope > .app')){const r=c.getBoundingClientRect();if(r.top<col.top-1||r.bottom>col.bottom+1||r.bottom>innerHeight)f.push('pinned off column '+Math.round(r.top)+'..'+Math.round(r.bottom))}const end=document.querySelector('.home').classList.contains('dock-end');if(end!==(a==='bottom'))f.push('dock-end '+end);const r=re?.getBoundingClientRect();if(a==='bottom'){if(p.bottom<col.bottom-2)f.push('pinned not at foot '+Math.round(p.bottom)+' vs '+Math.round(col.bottom));if(r&&r.height&&r.bottom>p.top+1)f.push('recents not above pinned')}else{if(p.top>col.top+2)f.push('pinned not at top');if(r&&r.height&&r.top<p.bottom)f.push('recents not under pinned')}return f.length?f.join('; '):'ok'})()"
}
fails=0
for state in 0 3; do
  ev 'importShim("./state.ts").then(s=>{s.drawer.value=0;return "closed"})' >/dev/null
  sh_ "cmd device_state state $state; am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"
  sleep 3
  ev 'importShim("./state.ts").then(s=>{s.goHome();return "home"})' >/dev/null
  for side in left right; do
    for align in top bottom; do
      chk setting
      ev "importShim('./state.ts').then(s=>{s.drawer.value=0;s.dockTry.value='$side';s.dockAlignTry.value='$align';setTimeout(()=>{if(s.dockTry.value==='$side')s.dockTry.value='';s.dockAlignTry.value=''},240000);s.page.value=0;return 'set'})" >/dev/null
      sleep 2
      v=$(probe "$align")
      "$T/shot.sh" "$OUT/home-$state-$side-$align.png" >/dev/null || true
      if [ "$v" = ok ]; then echo "PASS: state $state $side $align"; else echo "FAIL: state $state $side $align: $v"; fails=$((fails + 1)); fi
    done
  done
done
echo "Visual evidence: $OUT"
[ "$fails" = 0 ]
