#!/bin/bash
# tools/phone/verify/window-scroll.sh: a scroll inside a floating window is the app's - never home's shade pull or
# drawer (the user, 2026-10-23: "scrolling inside a window opens the notifications or the launcher"). For Calculator,
# Kate (a Linux window) and Chrome: quick swipes (as a finger flicks) down near the window's top edge, down and up in its
# middle, up near its bottom edge - fresh, after a bar move and after a grip resize - and after each: PowOS's shade, the
# pull-up panel and home's drawer still shut. At each spot a DOWN first: which windows InputDispatcher gave the finger
# (the app's, or home's under it). Chrome the user had open is only scrolled (its place and size stay theirs).
#   queue.sh add --close <task> tools/phone/verify/window-scroll.sh [--apps "calc kate chrome"]
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
APPS="calc kate chrome"; ARGS=()
while [ $# -gt 0 ]; do case $1 in --apps) APPS=$2; shift 2 ;; *) ARGS+=("$1"); shift ;; esac; done
. "$here/e2e-lib.sh"
e2e_args ${ARGS[@]+"${ARGS[@]}"}; LAST=2
E2E_APPS='com.oneplus.calculator|PowosWindowActivity|com.android.chrome'; E2E_LINUX='kate'
e2e_init scroll
e2e_setup inner

wvis() { sh_ "dumpsys window windows" | awk -v p="$1}" '/^ *Window #/{f=(index($0,p)>0)} f' | grep -m1 -oE "isVisible=[a-z]+" | cut -d= -f2; }
touched() { sh_ "dumpsys input" | sed -n '/TouchStatesByDisplay/,/CursorStatesByDisplay/p' | grep -oE "name='[^']*'|pilferingPointerIds=[^,]*" | sed -E "s/name='[0-9a-f]+ ?/'/" | tr '\n' ' ' | cut -c1-400; }
# shut <what>: shade, pull-up panel and drawer all shut; anything open is closed again (and FAILs).
shut() { local s p d; s=$(wvis "PowOS shade"); p=$(wvis "PowOS pull-up panel"); d=$(isopen)
  if [ "$s" = true ] || [ "$p" = true ] || [ "$d" = true ]; then fail "$1: shade=$s pull-up=$p drawer=$d - home took the scroll"
    back 1; [ "$(isopen)" = true ] && hemit system.home null; sh_ "cmd statusbar collapse"; sleep 0.8
  else pass "$1: shade, pull-up panel and drawer stayed shut"; fi; }
# flick <x> <y> <dy> <what>: who gets a finger there (a DOWN, the touch state, an UP), then a quick swipe dy px.
flick() { mdown "$1" "$2" "$4 (probe)" || return; local t; t=$(touched); mup "$1" "$2"; sleep 0.3
  case $t in *"$PAT"*) note "$4: the finger goes to $t" ;; *) fail "$4: the finger does NOT go to the app's window: $t" ;; esac
  swipe "$1" "$2" "$1" $(($2 + $3)) 120 "$4" || return; sleep 1.2; chk "$4"; shut "$4"; }
# scrolls <task> <stage>: the four flicks inside the window.
scrolls() { local b; b=$(tbounds "$1"); [ -n "$b" ] || { fail "[$2] no bounds for task $1"; return; }; set -- $b "$2"
  local x=$((($1 + $3) / 2)) h=$(($4 - $2)) d=$(dp 220)
  [ $d -gt $((h * 2 / 3)) ] && d=$((h * 2 / 3))
  flick $x $(($2 + $(dp 24))) $d "[$5] down near the top edge"
  flick $x $(($2 + h / 2 - d / 2)) $d "[$5] down in the middle"
  flick $x $(($2 + h / 2 + d / 2)) $((-d)) "[$5] up in the middle"
  flick $x $(($4 - $(dp 24))) $((-d)) "[$5] up near the bottom edge"
  step "$5" "[$5] after the scrolls"; }
movebar() { local p x y dx=$(dp 120) dy=$(dp 60); p=$(barpt "$1"); [ -n "$p" ] || { fail "no bar for task $1"; return; }; set -- $p; x=$1; y=$2
  [ $((x + dx)) -gt $((W - $(dp 80))) ] && dx=$((-dx))
  mdown $x $y "the bar" && { mpath $x $y $((x + dx)) $((y + dy)) 10; mup $((x + dx)) $((y + dy)); sleep 1.5; chk move; }; }
grip() { local g x y s=1; g=$(wframe "PowOS window grip $1}"); [ -n "$g" ] || { fail "no grip for task $1"; return; }; set -- $g
  x=$((($1 + $3) / 2)); y=$((($2 + $4) / 2)); { [ $x -gt $((W - $(dp 200))) ] || [ $y -gt $((H - $(dp 260))) ]; } && s=-1
  mdown $x $y "the grip" && { mpath $x $y $((x + s * $(dp 140))) $((y + s * $(dp 90))) 10; mup $((x + s * $(dp 140))) $((y + s * $(dp 90))); sleep 2; chk resize; }; }

for app in $APPS; do
  case $app in
    calc) KEY=a:com.oneplus.calculator/; WKEY=com.oneplus.calculator; PAT=calculator ;;
    kate) KEY=l:org.kde.kate; WKEY=l:org.kde.kate; PAT=PowosWindowActivity ;;
    chrome) KEY=a:com.android.chrome/; WKEY=com.android.chrome; PAT=chrome ;;
    *) fail "unknown app $app"; continue ;;
  esac
  mine=1; grep -qE "$WKEY" <<<"$TASKS0" && mine=0; [ $app = kate ] && grep -qx kate <<<"$LIN0" && mine=0
  k=$(hcall apps.list "[]" "l=>(l.find(a=>a.key.startsWith('$KEY'))||{}).key||'none'")
  [ "$k" != none ] || { fail "$app isn't installed ($k)"; continue; }
  hcall apps.launch "['$k']" "()=>'ok'" >/dev/null; CT=$(waitwin "$WKEY" 40); sleep 2; chk "$app"
  [ "$CT" != none ] && [ -n "$CT" ] || { fail "no $app window"; continue; }
  step "$app" "$app in a window (task $CT $(tbounds "$CT"), the journey's own: $mine)"
  scrolls "$CT" "$app fresh"
  if [ $mine = 1 ]; then movebar "$CT"; scrolls "$CT" "$app moved"; grip "$CT"; scrolls "$CT" "$app resized"
  else note "$app was open already (the user's): scrolled only, not moved or resized"; fi
  [ $mine = 1 ] && [ $app != kate ] && { sh_ "am stack remove $CT"; sleep 1; }
done
e2e_finish
