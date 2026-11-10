#!/bin/bash
# lanes: phone
# needs: kwin home
# ww-clamp.sh: no window lands out of reach (board task a-window-can-land-out-of-bounds-off-the-right-ed, a0f5bff9 WC1:
# clampPlace against the work area, not the screen). On the unfolded home, with Kate (or Dolphin) opened through home's
# launch path, its bar must stay reachable - at least a third of the frame's width (or the work area's) of the bar
# inside webwindows.tsx's workArea(), its top on screen and above the work area's bottom:
#   open      as it opened
#   drag      its bar dragged by the left end to the bottom-right corner of the screen (past the right dock)
#   fold      after a fold and unfold (cmd device_state 0 then 3: the work area changed twice)
# Opens only an app the user isn't running; closes it after. Exit 0 PASS, 1 FAIL, 3 not now.
set -uo pipefail
NAME=ww-clamp; . "$(dirname "$0")/wwc-lib.sh"
reach() { ev "importShim('./ui/webwindows.tsx').then(m=>{const e=document.querySelector('.webwindow[data-wwid=\"${1#w}\"]'),t=e&&e.querySelector('.webwindow-title');if(!t)return 'none';const a=m.workArea(),r=e.getBoundingClientRect(),b=t.getBoundingClientRect(),inn=Math.min(b.right,a.right)-Math.max(b.left,a.left),need=Math.min(r.width/3,a.right-a.left)-4,f=v=>v.map(Math.round).join(' ');return (inn>=need&&b.top>=-1&&b.bottom<=a.bottom+2?'ok':'out')+' bar '+f([b.left,b.top,b.right,b.bottom])+' ('+Math.round(inn)+' of '+Math.round(need)+' css px in) work area '+f([a.left,a.top,a.right,a.bottom])})"; }
judge() { local v; v=$(reach "$WID"); say "$1: $v"; case $v in ok*) return ;; esac
  if [ "$1:$v" = fold:none ]; then say "fold: $WID isn't on home after the unfold (not the clamp's case)"; else bad "$1: $WID's bar out of reach: $v"; fi; }
wwc_start
a=$(wwc_pick kate dolphin) || wwc_skip "Kate and Dolphin both run (the user's)"
wwc_open "$a" || wwc_end
sleep 1; judge open
grab=$(wwel "$WID" "e=>{const b=e.querySelector('.webwindow-title').getBoundingClientRect(),d=devicePixelRatio;return Math.round((b.left+24)*d)+' '+Math.round((b.top+b.height/2)*d)}")
read -r gx gy <<<"$grab"; read -r sw sh <<<"$(ev "Math.round(innerWidth*devicePixelRatio)+' '+Math.round(innerHeight*devicePixelRatio)")"
[ -n "${gx:-}" ] && [ -n "${sw:-}" ] || { bad "drag: no bar point ($grab) or screen size"; wwc_end; }
say "drag: $WID's bar from $gx,$gy to $((sw - 8)),$((sh - 8))"
sh_ "input swipe $gx $gy $((sw - 8)) $((sh - 8)) 900"; sleep 1.5; judge drag
fold 0; sleep 4; fold 3; sleep 4; judge fold
UNFOLDED=1   # fold reset after (the hinge's own state again)
wwc_end "$a's bar reachable after open, a drag past the bottom-right corner, a fold + unfold"
