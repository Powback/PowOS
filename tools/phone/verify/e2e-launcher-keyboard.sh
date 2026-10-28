#!/bin/bash
# lanes: phone
# The user's bug, as they do it (2026-10-28 "the keyboard gets dismissed when I try to use it", "still closes when I
# type the search bar in open mode"): unfolded, the drawer opened by a real swipe, a real tap on its search bar, then
# letters typed one at a time through Android's keyboard path (input text, the IME's commit). After the tap and after
# every letter: the keyboard (mInputShown), the focused element and the query, plus the page's blur/focus trace
# (blur() callers' stacks), so a FAIL names what closed it. Nothing persistent changes; the drawer is closed at the end.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/e2e-lib.sh"
e2e_args "$@"
e2e_init launcher-keyboard
e2e_setup inner

BAR='document.querySelector(".home > .bar textarea, .home > .bar input")'
ev '(()=>{if(window.__kbTrace)return "had";const t=(window.__kbTrace=[]),n=()=>Math.round(performance.now()),
  d=(e)=>e?(e.tagName+"."+String(e.className).split(" ")[0]):"none";
  const b=HTMLElement.prototype.blur;HTMLElement.prototype.blur=function(){t.push(n()+" blur() on "+d(this)+" "+(new Error().stack||"").split("\n").slice(2,5).join(" <- ").replace(/\s+/g," "));return b.call(this)};
  document.addEventListener("focusout",(e)=>t.push(n()+" focusout "+d(e.target)+" to="+d(e.relatedTarget)),true);
  document.addEventListener("focusin",(e)=>t.push(n()+" focusin "+d(e.target)),true);
  addEventListener("blur",()=>t.push(n()+" window blur"));return "on"})()' >/dev/null
state() { ev "JSON.stringify({open:!!document.querySelector('.home.open'),focus:document.activeElement===$BAR,q:($BAR||{}).value})"; }

step drawer "a swipe up from empty space on the unfolded home opens the drawer"
p=$(freept "" 0 0 .54); set -- ${p:-}
if [ $# -ge 2 ]; then swipe "$1" "$2" "$1" $(($2 - H * 30 / 100)) 250 "up (the drawer)"; sleep 1.2; chk drawer; fi
# The swipe isn't what this check is about: a missed one is retried once lower down, then opened by code (noted).
if [ "$(isopen)" != true ]; then
  swipe $((W * 3 / 4)) $((H * 70 / 100)) $((W * 3 / 4)) $((H * 35 / 100)) 250 "up again (the drawer)"; sleep 1.2; chk drawer
fi
if [ "$(isopen)" != true ]; then
  ev 'importShim("./state.ts").then(s=>{s.openPanel("apps");return "ok"})' >/dev/null; sleep 1.2
  note "the swipe didn't open the drawer; opened by code (openPanel) so the keyboard steps still run"
fi
[ "$(isopen)" = true ] && pass "drawer open" || { fail "the drawer didn't open ($p)"; e2e_finish; exit 1; }

step tap "a tap on the drawer's search bar raises the keyboard"
p=$(pt "$BAR"); case $p in none|off|"") fail "no search bar on screen ($p)"; e2e_finish; exit 1 ;; esac
set -- $p; tap "$1" "$2" "the search bar"; sleep 1.2; chk "search tap"
k=$(ime); s=$(state)
[ "$k" = mInputShown=true ] && [[ $s == *'"focus":true'* ]] && pass "$k $s" || fail "after the tap: $k $s"

step typing "typing p-o-w-o-s one letter at a time: the keyboard stays up and the search keeps focus"
bad=""
for c in p o w o s; do
  sh_ "input text $c"; sleep 0.7; chk "typing $c"
  k=$(ime); s=$(state); log "after '$c': $k $s"
  [ "$k" = mInputShown=true ] && [[ $s == *'"focus":true'* ]] || { bad="after '$c': $k $s"; break; }
done
sleep 1.5; k=$(ime); s=$(state); log "1.5 s later: $k $s"
[ -z "$bad" ] && { [ "$k" = mInputShown=true ] && [[ $s == *'"focus":true'* ]] || bad="1.5 s after the last letter: $k $s"; }
trace=$(ev 'JSON.stringify((window.__kbTrace||[]).slice(-12))')
[ -z "$bad" ] && pass "keyboard up and focused through 5 letters ($s)" || fail "keyboard dismissed $bad; page trace: $trace"

# What the user does: finger taps ON the keyboard's keys (a touch in the IME's own window), not `input text`.
step keys "five real taps on the keyboard's middle letter row: the keyboard stays up and the search keeps focus"
kb=$(wframe "InputMethod"); set -- $kb
if [ $# -ge 4 ] && [ "$4" -gt "$2" ]; then
  # Who gets a touch over the keys: the input dispatcher's window list (touchable regions, flags) before and after.
  sh_ "dumpsys input" > "$OUT/input-before.txt"; sh_ "dumpsys window windows" > "$OUT/windows-before.txt"
  sh_ "logcat -c"
  bad=""; y=$(($2 + ($4 - $2) * 55 / 100))
  for f in 20 35 50 65 80; do
    x=$(($1 + ($3 - $1) * f / 100)); tap "$x" "$y" "a key on the keyboard"; sleep 0.7; chk "key tap"
    k=$(ime); s=$(state); log "after key tap at $x,$y: $k $s"
    [ "$k" = mInputShown=true ] && [[ $s == *'"focus":true'* ]] || { bad="after the key tap at $x,$y: $k $s"; break; }
  done
  sh_ "dumpsys input" > "$OUT/input-after.txt"; sh_ "logcat -d -v time" > "$OUT/logcat-keys.txt"
  note "input dispatcher dumps and logcat: $OUT (input-before/after, windows-before, logcat-keys)"
  trace=$(ev 'JSON.stringify((window.__kbTrace||[]).slice(-12))')
  [ -z "$bad" ] && pass "keyboard up and focused through 5 key taps ($s)" || fail "keyboard dismissed $bad; page trace: $trace"
else
  fail "no keyboard window to tap (InputMethod frame: ${kb:-none})"
fi

back; back
e2e_finish
