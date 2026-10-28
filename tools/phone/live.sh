#!/bin/bash
# tools/phone/live.sh: a manual live test on the phone with a screenshot after every action, so a fix is judged on what
# the screen showed, not on page state alone (2026-10-28: a launcher check "passed" by setting the query from code
# while the user's keyboard still closed on every real key tap).
#   tools/phone/live.sh [--name NAME] ACTION...      each ACTION one argument:
#     "tap X Y"          a real tap (screen px)              "el <css selector>"   a real tap on home's element
#     "swipe X1 Y1 X2 Y2 [MS]"                              "key <fraction-x> <fraction-y>"  a real tap ON the keyboard,
#     "text abc"         Android's text input (no touch)        at that fraction of the IME window's frame
#     "keyevent N"       a key event (4 back, 3 home)       "wait S"              seconds
#     "unfold" / "fold"  device state (reset at the end)    "js <expr>"           a CDP eval on home, its answer logged
# Out: ~/.cache/powos-verify/live-NAME-<time>/NN-<action>.png + log.txt (keyboard shown, focused element after each).
# The phone must be idle: run it through the queue (`tools/phone/verify/queue.sh add <task> tools/phone/live.sh ...`)
# or with --now only when the user said to go now. Nothing persistent is changed by the tool itself.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); A=$here/adb.sh
NAME=live; NOW=0
while [ $# -gt 0 ]; do case $1 in --name) NAME=$2; shift 2 ;; --now) NOW=1; shift ;; *) break ;; esac; done
[ "$NOW" = 1 ] || [ "${LOCK_HELD:-0}" = 1 ] || { echo "live.sh: run it through tools/phone/verify/queue.sh add, or --now when the user said so"; exit 3; }
OUT=$HOME/.cache/powos-verify/live-$NAME-$(date +%m%d-%H%M%S); mkdir -p "$OUT"
sh_() { "$A" shell "su -c '$*'" </dev/null 2>/dev/null | tr -d '\r'; }
ev() { "$here/cdp.sh" eval home "$1" 2>/dev/null | tr -d '\r' | tail -1; }
log() { echo "$*" | tee -a "$OUT/log.txt"; }
FOLD=0; trap '[ $FOLD = 1 ] && sh_ "cmd device_state state reset"' EXIT
n=0
for a in "$@"; do
  n=$((n + 1)); set -- $a; verb=$1; shift
  case $verb in
    tap) sh_ "input tap $1 $2" ;;
    swipe) sh_ "input swipe $1 $2 $3 $4 ${5:-250}" ;;
    text) sh_ "input text $*" ;;
    keyevent) sh_ "input keyevent $1" ;;
    wait) sleep "$1" ;;
    unfold) sh_ "cmd device_state state 3"; FOLD=1; sleep 2 ;;
    fold) sh_ "cmd device_state state 0"; FOLD=1; sleep 2 ;;
    js) log "   js: $(ev "${a#js }")" ;;
    el) p=$(ev "(()=>{const e=document.querySelector('${a#el }');if(!e)return 'none';const r=e.getBoundingClientRect(),d=devicePixelRatio;return Math.round((r.x+r.width/2)*d)+' '+Math.round((r.y+r.height/2)*d)})()" | tr -d '"')
        [ "$p" = none ] && log "   no element ${a#el }" || sh_ "input tap $p" ;;
    key) f=$(sh_ "dumpsys window windows" | awk '/^ *Window #/{w=(index($0,"InputMethod}")>0)} w' | grep -m1 -oE ' frame=\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]' | tr -c '0-9\n' ' ')
         set -- $f; [ $# -ge 4 ] && sh_ "input tap $(awk -v a="$1" -v b="$3" -v f="${a#key }" 'BEGIN{split(f,q," ");print int(a+(b-a)*q[1])}') $(awk -v a="$2" -v b="$4" -v f="${a#key }" 'BEGIN{split(f,q," ");print int(a+(b-a)*q[2])}')" || log "   no keyboard on screen" ;;
    *) log "   unknown action: $a"; continue ;;
  esac
  sleep 0.7
  slug=$(printf '%02d-%s' "$n" "$(echo "$a" | tr -c 'A-Za-z0-9.' '-' | cut -c1-40)")
  "$here/shot.sh" "$OUT/$slug.png" >/dev/null 2>&1 || log "   (no screenshot)"
  log "$slug: $(sh_ "dumpsys input_method | grep -m1 -oE mInputShown=[a-z]+") focus=$(ev '(document.activeElement&&document.activeElement.tagName+"."+String(document.activeElement.className).split(" ")[0])||"none"' | tr -d '"')"
done
echo "out: $OUT"
