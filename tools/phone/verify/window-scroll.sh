#!/bin/bash
# lanes: emu? phone
# tools/phone/verify/window-scroll.sh: a scroll inside a floating window is the app's - never home's shade pull or
# drawer (the user, 2026-10-23: "scrolling inside a window opens the notifications or the launcher"). For Calculator,
# Kate (a Linux window) and Chrome: quick swipes (as a finger flicks) down near the window's top edge, down and up in its
# middle, up near its bottom edge - fresh, after a bar move and after a grip resize - and after each: PowOS's shade, the
# pull-up panel and home's drawer still shut. Steam too (its window; resident Steam is never killed). At each spot a
# DOWN first: which windows InputDispatcher gave the finger (the app's, or home's under it). Each move and resize is
# undone after its scrolls: a window the user had open keeps its place and size.
#   queue.sh add --close <task> tools/phone/verify/window-scroll.sh [--apps "calc kate chrome steam"] [--android-only]
# --android-only (the emulator lane, no Kate/Steam): same as --apps "calc chrome"; --apps overrides it.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
APPS="calc kate chrome steam"; ARGS=(); APPS_SET=0; AO=0
while [ $# -gt 0 ]; do case $1 in --apps) APPS=$2; APPS_SET=1; shift 2 ;; --android-only) AO=1; shift ;; *) ARGS+=("$1"); shift ;; esac; done
[ $AO = 1 ] && [ $APPS_SET = 0 ] && APPS="calc chrome"
. "$here/e2e-lib.sh"
e2e_args ${ARGS[@]+"${ARGS[@]}"}; LAST=2
E2E_APPS="${TEST_APP:-com.oneplus.calculator}|PowosWindowActivity|com.android.chrome"; E2E_LINUX='kate'
e2e_init scroll
e2e_setup inner

wvis() { sh_ "dumpsys window windows" | awk -v p="$1}" '/^ *Window #/{f=(index($0,p)>0)} f' | grep -m1 -oE "isVisible=[a-z]+" | cut -d= -f2; }
touched() { sh_ "dumpsys input" | sed -n '/TouchStatesByDisplay/,/CursorStatesByDisplay/p' | grep -oE "name='[^']*'|pilferingPointerIds=[^,]*" | sed -E "s/name='[0-9a-f]+ ?/'/" | tr '\n' ' ' | cut -c1-400; }
# shut <what>: shade, pull-up panel and drawer all shut; anything open is closed again (and FAILs).
shut() { local s p d v; v=$(sh_ "dumpsys window windows" | awk '/^ *Window #/{f=(index($0,"PowOS shade}")>0)?"s":(index($0,"PowOS pull-up panel}")>0)?"p":""} f && /isVisible=/{print f, $0}' | grep -oE "^[sp]|isVisible=[a-z]+" | paste - - | tr '\t' ' ')
  s=$(awk '$1=="s"{sub("isVisible=","",$2); print $2; exit}' <<<"$v"); p=$(awk '$1=="p"{sub("isVisible=","",$2); print $2; exit}' <<<"$v"); d=$(isopen)
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
# movebar <task> <dx> <dy>: its bar dragged by (dx, dy) px.
movebar() { local p x y; p=$(barpt "$1"); [ -n "$p" ] || { fail "no bar for task $1"; return 1; }; set -- $p "$2" "$3"; x=$1; y=$2
  mdown $x $y "the bar" && { mpath $x $y $((x + $3)) $((y + $4)) 10; mup $((x + $3)) $((y + $4)); sleep 1.5; chk move; }; }
# grip <task> <dx> <dy>: its grip dragged by (dx, dy) px.
grip() { local g x y; g=$(wframe "PowOS window grip $1}"); [ -n "$g" ] || { fail "no grip for task $1"; return 1; }; set -- $g "$2" "$3"
  x=$((($1 + $3) / 2)); y=$((($2 + $4) / 2))
  mdown $x $y "the grip" && { mpath $x $y $((x + $5)) $((y + $6)) 10; mup $((x + $5)) $((y + $6)); sleep 2; chk resize; }; }
# Move and resize ways that fit the window where it is (inwards near a screen edge).
ways() { set -- $(tbounds "$1"); MX=$(dp 120); MY=$(dp 60); [ $(($3 + MX)) -gt $((W - $(dp 40))) ] && MX=$((-MX)); [ $(($4 + MY)) -gt $((H - $(dp 200))) ] && MY=$((-MY))
  RX=$(dp 140); RY=$(dp 90); [ $(($3 + RX)) -gt $((W - $(dp 40))) ] && RX=$((-RX)); [ $(($4 + RY)) -gt $((H - $(dp 220))) ] && RY=$((-RY)); }

for app in $APPS; do
  case $app in
    calc) KEY=a:${TEST_APP:-com.oneplus.calculator}/; WKEY=${TEST_APP:-com.oneplus.calculator}; PAT=${TEST_APP:-calculator} ;;
    kate) KEY=l:org.kde.kate; WKEY=l:org.kde.kate; PAT=PowosWindowActivity ;;
    chrome) KEY=a:com.android.chrome/; WKEY=com.android.chrome; PAT=chrome ;;
    steam) KEY=l:steam; WKEY=l:steam; PAT=PowosWindowActivity ;;
    *) fail "unknown app $app"; continue ;;
  esac
  mine=1; grep -qE "$WKEY" <<<"$TASKS0" && mine=0; [ $app = kate ] && grep -qx kate <<<"$LIN0" && mine=0
  [ $app = steam ] && [ "$(win l:steam id)" != none ] && mine=0
  k=$(hcall apps.list "[]" "l=>(l.find(a=>a.key.startsWith('$KEY'))||{}).key||'none'")
  [ "$k" != none ] || { fail "$app isn't installed ($k)"; continue; }
  hcall apps.launch "['$k']" "()=>'ok'" >/dev/null; CT=$(waitwin "$WKEY" 40); sleep 2; chk "$app"
  [ "$CT" != none ] && [ -n "$CT" ] || { fail "no $app window"; continue; }
  step "$app" "$app in a window (task $CT $(tbounds "$CT"), the journey's own: $mine)"
  B0=$(tbounds "$CT"); scrolls "$CT" "$app fresh"
  # Moved and resized - and back after (a window the user had open keeps its place and size).
  ways "$CT"; movebar "$CT" $MX $MY && { scrolls "$CT" "$app moved"; movebar "$CT" $((-MX)) $((-MY)); }
  ways "$CT"; grip "$CT" $RX $RY && { scrolls "$CT" "$app resized"; grip "$CT" $((-RX)) $((-RY)); }
  B1=$(tbounds "$CT"); [ "$B1" = "$B0" ] && note "$app back at $B0" || note "$app at $B1 (was $B0)"
  if [ $mine = 1 ]; then
    case $app in kate) ;; steam) p=$(closebtn "$CT"); [ -n "$p" ] && { set -- $p; tap $1 $2 "Steam's close button"; sleep 2; } ;; *) sh_ "am stack remove $CT"; sleep 1 ;; esac
  fi
done
e2e_finish
