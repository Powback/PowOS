#!/bin/bash
# lanes: phone
# needs: home
# term-feel.sh (board the-shell-s-terminal-renders-like-powterm-font-s; 7897328a ShellTermViews): the shell's terminal
# as PowTerm's. On a FRESH tmux session of its own (never a live one), opened view-only on home (openSession):
#   renderer - PowTerm's com.termux.view.TerminalView is up over the page (not xterm.js);
#   scroll   - a slow drag moves the text (>= MIN_ROWS of the terminal's pixel rows change) and it stays put 1.5 s later
#              (the session's frames must not snap it back to the bottom);
#   fling    - after a fast flick the text is still moving once the finger is up (two shots after the lift differ);
#   size     - a pinch step (the view's "term.pinch", emitted as its ScaleGestureDetector does: `input` has no second
#              finger) redraws it at the next text size; the opposite step puts the user's size back.
# Shots in $OUT for review. Exit 0 PASS, 1 FAIL, 3 touched, 5 SKIP.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); . "$here/e2e-lib.sh"; S=powos-verify-term; MIN_ROWS=${MIN_ROWS:-0.2}
OUT=$HOME/.cache/powos-verify/term-feel-$(date +%m%d-%H%M); mkdir -p "$OUT"
. "$here/window-lock.sh"; window_lock term-feel 120; e2e_touchwatch >/dev/null 2>&1; I0=$(irq)
trap 'ev "importShim(\"./state.ts\").then(m=>(m.closeSession(),\"ok\"))" >/dev/null; us "tmux kill-session -t $S" >/dev/null; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"' EXIT
us "tmux kill-session -t $S 2>/dev/null; tmux new -d -s $S \"seq -f 'powos verify line %g' 3000; exec sleep 900\" && echo ok" | grep -q ok || { echo "SKIP: ENV: no tmux session"; exit 5; }
vis() { CDP_TIMEOUT_S=15 ev "document.visibilityState"; }
hf=$("$here/../home-front.sh") || { echo "SKIP: ENV: home's page isn't visible even after going home ($hf)"; exit 5; }
ev "importShim('./state.ts').then(m=>(m.openSession('$S',null),'ok'))" >/dev/null; sleep 4
read -r x y w h <<<"$(ev "(()=>{const d=devicePixelRatio,r=[...document.querySelectorAll('.term-holder')].map(e=>e.getBoundingClientRect()).filter(r=>r.width>99&&r.height>99).sort((a,b)=>b.width*b.height-a.width*a.height)[0];return r?[r.left,r.top,r.width,r.height].map(v=>Math.round(v*d)).join(' '):'none'})()")"
[[ "${h:-}" =~ ^[0-9]+$ ]] || { echo "FAIL: the session view shows no terminal (${x:-none})"; exit 1; }
# PowTerm's view is placed from the page's frame loop (terminal.tsx placeNative): with home not in front the page is
# hidden, no frame runs and no view is ever made - that's the run, not the code (job 20261109-162404-36737). Only
# HomeShell's own hierarchy counts: PowTerm the app has a TerminalView of its own, which is not this.
homeview() { sh_ 'dumpsys activity top' | awk '/^ *ACTIVITY /{f=(index($0,"com.powos.app/andro.marchy.HomeShell")>0)} f' | grep -qE 'com\.termux\.view\.TerminalView\{[0-9a-f]+ V'; }
for i in 1 2 3 4 5 6; do homeview && break; sleep 1; done
if ! homeview; then
  v=$(vis); [ "$v" = visible ] || { echo "SKIP: ENV: home left the front during the run (page $v) - no frame places PowTerm's view"; exit 5; }
  [ "$(ev "String(!!document.querySelector('.term-holder .xterm-screen'))")" = true ] && { echo "FAIL: the page draws the shell's terminal with xterm - no PowTerm TerminalView (term.view missing or refused)"; exit 1; }
  echo "FAIL: no PowTerm TerminalView in HomeShell and no xterm either - the terminal draws nothing"; exit 1
fi
shot() { "$T/shot.sh" "$OUT/$1.png" >/dev/null && sips -s format bmp "$OUT/$1.png" --out "$OUT/$1.bmp" >/dev/null 2>&1; }
moved() { python3 -c 'import sys,struct
def L(p):
    d=open(p,"rb").read(); o,=struct.unpack_from("<I",d,10); W,H=struct.unpack_from("<ii",d,18); b=struct.unpack_from("<H",d,28)[0]//8; return d,o,W,H,b
def R(l,r,x,w):
    d,o,W,H,b=l; s=(W*b+3)//4*4; i=o+((H-1-r) if H>0 else r)*s+x*b; return d[i:i+w*b]
a,b=L(sys.argv[1]),L(sys.argv[2]); x,y,w,h=map(int,sys.argv[3:]); print(round(sum(R(a,r,x,w)!=R(b,r,x,w) for r in range(y,y+h))/h,3))' "$OUT/$1.bmp" "$OUT/$2.bmp" "$x" "$y" "$w" "$h"; }
big() { awk -v v="$1" -v m="$MIN_ROWS" 'BEGIN{exit !(v>=m)}'; }
cx=$((x + w / 2)); f=
shot base || { echo "SKIP: no screenshot"; exit 5; }
sh_ "$(self_input_for 10)input swipe $cx $((y + h * 3 / 10)) $cx $((y + h * 8 / 10)) 700"; sleep 1.5; shot drag
d1=$(moved base drag); big "$d1" || f="$f a drag moved $d1 of its rows (< $MIN_ROWS);"
sh_ "$(self_input_for 10)input swipe $cx $((y + h / 4)) $cx $((y + h * 17 / 20)) 60"; shot lift; sleep 1.2; shot after
d2=$(moved lift after); awk -v v="$d2" 'BEGIN{exit !(v>0.05)}' || f="$f no fling: the text stopped with the finger ($d2 of rows moved after the lift);"
sleep 2; shot pre; hemit term.pinch '{id:"",dir:1}'; shot p1; d3=$(moved pre p1); s=-1
big "$d3" || { hemit term.pinch '{id:"",dir:-1}'; shot p1; d3=$(moved pre p1); s=1; }   # at the top size: step down
hemit term.pinch "{id:\"\",dir:$s}"; big "$d3" || f="$f a pinch step didn't redraw the text ($d3 of rows);"
[ "$(irq)" = "$I0" ] || { echo "the user touched the phone - again later"; exit 3; }
echo "term-feel: rect $x,$y ${w}x$h; drag $d1, after-lift $d2, pinch $d3 of rows changed (shots $OUT)"
[ -n "$f" ] && { echo "FAIL:$f"; exit 1; }
echo "PASS: PowTerm's TerminalView draws the shell's terminal; it drags, flings on after the lift and pinch-resizes"
