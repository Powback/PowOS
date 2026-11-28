#!/bin/bash
# lanes: phone
# ai-stop.sh [OUT] (board ai-chat-send-button-becomes-a-stop-button-while): the pill's send is a stop button while
# PowOS AI answers, and its tap really ends the turn. Home, the swipe to the AI page, then over CDP: a long ask typed
# into the page's field (the one bar, role "ai") and submitted -> within 3 s `.send.stop` shows ("stop answering");
# once the turn has run ~6 s, stop is clicked -> send again within 1 s, the turn over (the page's .ai-state no longer
# busy) within 15 s, a "stopped" line on the page, and no `manager.py ... --once` left running in PowOS (claude and its
# children stopped with it). Phone only: the emulator has no PowOS session to answer. Restores home.
# Exit 0 pass, 1 fail, 3 a real touch / screen not awake / the chat busy with something else (re-queued), 5 can't run.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"
OUT=${1:-$HOME/.cache/powos-verify/ai-stop-$(date +%m%d-%H%M)}; mkdir -p "$OUT"
L=$HOME/.cache/powos-verify.lock
MSG="stop-button check from a test script, please ignore: write a 1500-word essay about folding phones (it will be stopped)"
. "$here/base.sh"  # sh_ and the shared check helpers (tools/phone/verify/base.sh)
irq() { sh_ "awk '/touch-0/{s+=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9} END{print s}' /proc/interrupts"; }
home() { sh_ "am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; sleep 1.5; }
ev() { "$T/cdp.sh" eval home "$1" 2>&1 | tail -1 | tr -d '"'; }
. "$here/window-lock.sh"; window_lock ai-stop.sh 90
trap 'home; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"' EXIT
I0=$(irq)
chk() { [ "$(irq)" = "$I0" ] || { echo "STOP: a real touch at $1 - restoring"; exit 3; }; }
s=$(sh_ "dumpsys power | sed -n s/.*mWakefulness=//p | head -1")
[ "$s" = Awake ] || { echo "the screen is $s - not woken (rule); nothing done"; exit 3; }
WH=$(sh_ "wm size" | sed -nE 's/.*(Override|Physical) size: ([0-9]+)x([0-9]+).*/\2 \3/p' | tail -1)
W=${WH% *}; H=${WH#* }
up() { sh_ "input swipe $((W / 2)) $((H * 9 / 10)) $((W / 2)) $((H / 4)) 300"; sleep 1.5; }
sh_ "dumpsys window policy | grep -m1 -E \"mIsShowing=\"" | grep -q true && { sh_ "wm dismiss-keyguard"; sleep 1.5; }
sh_ "dumpsys window policy | grep -m1 -E \"mIsShowing=\"" | grep -q true && up
sh_ "dumpsys window | grep -m1 mCurrentFocus" | grep -qi PowosLock && up
chk lock
home; chk home
# The AI page: its header (.ai-screen.shown) and the one bar in its "ai" role.
# busy/idle: the page's own chat state (the host's PowosAiChat.busy, as ai.changed brings it) - 11-24 a header class
# (.ai-state.busy) that this page no longer draws read "idle" all along, and "the turn ended" meant nothing.
st='importShim("./state.ts").then(S=>(document.querySelector(".ai-screen.shown")&&document.querySelector("form.bar[data-role=ai] textarea")?"page":"no")+" "+(S.chat.value.busy?"busy":"idle"))'
for i in 1 2 3 4 5 6; do s=$(ev 'document.querySelector("form.bar textarea")?"up":"no"'); [ "$s" = up ] && break; sleep 2; done
# Where home is (page, drawer, edit mode, the AI page's tab): said when the swipes don't get there.
where='(async()=>{const S=await importShim("./state.ts");return JSON.stringify({page:S.page.value,drawer:S.drawer.value,editing:S.editing?.value,ai:S.aiScreen?.value,roles:[...document.querySelectorAll("form.bar")].map(f=>f.dataset.role||"-")})})()'
# The swipe right, once per page left of where home is (HOME doesn't always bring its first page back; 11-24 the run
# saw "no idle" after two swipes - home not on its first page, or the swipe on a widget that keeps it). The stop
# button is the check, not the page swipe (ai-tab-head.sh / the gate's home-swipes check that): still not there after
# four, the page is put up over CDP (state.ts page -1, as bar-same-rect.sh), its state logged.
for i in 1 2 3 4; do
  sh_ "input swipe $((W * 3 / 10)) $((H / 2)) $((W * 9 / 10)) $((H / 2)) 350"; sleep 1.5; chk page
  s=$(ev "$st"); case $s in page*) break;; esac
done
case $s in
  page*) ;;
  *) echo "the swipes didn't reach the AI page ($s): $(ev "$where") - putting it up over CDP"
     "$T/shot.sh" "$OUT/ai-stop-noswipe.png" >/dev/null 2>&1
     ev 'importShim("./state.ts").then(S=>{S.drawer.value=0;S.page.value=-1;return "set"})' >/dev/null; sleep 1.5
     s=$(ev "$st") ;;
esac
case $s in page*) ;; *) echo "FAIL: the AI page's field isn't showing: $s $(ev "$where")"; exit 1;; esac
# Another turn under way (an agent's mail): not ours to stop - wait a minute, else try later.
for i in $(seq 1 30); do case $(ev "$st") in *idle) break;; esac; sleep 2; done
case $(ev "$st") in *idle) ;; *) echo "the chat is busy with another turn - re-queued"; exit 3;; esac
chk before-send
ev '(()=>{const f=document.querySelector("form.bar[data-role=ai]");const t=f.querySelector("textarea");t.focus();t.value='"\"$MSG\""';t.dispatchEvent(new InputEvent("input",{bubbles:true,inputType:"insertText"}));f.requestSubmit();t.blur();return "sent"})()'
t0=$(date +%s)
shown=no
for i in $(seq 1 12); do
  [ "$(ev 'document.querySelector("form.bar[data-role=ai] .send.stop")?.getAttribute("aria-label")||"none"')" = "stop answering" ] && { shown=yes; break; }
  sleep 0.25
done
echo "stop shown after the send: $shown ($(( $(date +%s) - t0 )) s)"
[ $shown = yes ] || { "$T/shot.sh" "$OUT/ai-stop-nostop.png" >/dev/null 2>&1; echo "verify FAIL: no stop button after a send (an APK before ai.stop?)"; exit 1; }
sleep 6; chk mid-answer
"$T/shot.sh" "$OUT/ai-stop-answering.png" >/dev/null 2>&1
# THIS check's turn: the broker pid in turn.pid now (manager.py once(), written at its start) and its whole process
# tree (claude, its MCP servers and tool commands) - 11-24 a bare count of `manager.py --once` couldn't tell our turn
# from another one (an agent's mail answered right after).
PIDF=/data/powos/root/home/powos/.local/state/powos/ai/manager/turn.pid
tpid=$(sh_ "cat $PIDF 2>/dev/null")
tree() { sh_ "ps -A -o pid,ppid" | awk -v r="$1" '$1 ~ /^[0-9]+$/ {p[$1]=$2} END{for(k in p){x=k; while(x!="" && x!=r && x!=1 && x!=0) x=p[x]; if(x==r) print k}}' | sort -n | tr '\n' ' '; }
case $tpid in ''|*[!0-9]*) echo "verify FAIL: no turn.pid while the turn runs (the manager before --stop?): '$tpid'"; exit 1;; esac
pids=$(tree "$tpid")
echo "our turn: broker $tpid, its tree: $pids; page: $(ev "$st")"
case $(ev "$st") in *busy) ;; *) echo "verify FAIL: the page says the chat is idle while our turn runs"; exit 1;; esac
ev 'document.querySelector("form.bar[data-role=ai] .send.stop").click(),"tapped"'
t1=$(date +%s)
sleep 1
back=$(ev 'document.querySelector("form.bar[data-role=ai] .send.stop")?"stop":"send"')
echo "1 s after the tap the button is: $back"
gone=no
for i in $(seq 1 30); do
  left=$(sh_ "for p in $pids; do [ -d /proc/\$p ] && echo \$p; done" | tr '\n' ' ')
  [ -z "${left// /}" ] && { gone=yes; break; }
  sleep 0.5
done
echo "our turn's processes gone: $gone ($(( $(date +%s) - t1 )) s after the tap)${left:+, left: $left}"
[ $gone = yes ] || sh_ "for p in $left; do cat /proc/\$p/cmdline | tr '\\0' ' ' | cut -c1-160; echo; done"
ended=no
for i in $(seq 1 20); do case $(ev "$st") in *idle) ended=yes; break;; esac; sleep 0.5; done
echo "the page's chat idle: $ended"
sleep 1
# The item our ask started: the last one after our message must be the quiet "stopped" (our MSG itself says "stopped").
said=$(ev '(()=>{const n=[...document.querySelectorAll(".ai-screen .msg")].map(m=>m.textContent.trim());const i=n.findLastIndex(t=>t.startsWith("stop-button check from a test script"));return i<0?"(our message not found)":n.slice(i+1).join(" | ")})()')
echo "after our message: $said"
"$T/shot.sh" "$OUT/ai-stop-after.png" >/dev/null 2>&1
chk after
ok=1
[ "$back" = send ] || { echo "the button stayed stop after the tap"; ok=0; }
[ $gone = yes ] || { echo "our turn's processes still run 15 s after stop"; ok=0; }
[ $ended = yes ] || { echo "the chat stayed busy after stop"; ok=0; }
case $said in *stopped) ;; *) echo "no quiet \"stopped\" after our message"; ok=0;; esac
case $said in *"didn't answer"*) echo "an error line instead of a quiet stopped"; ok=0;; esac
[ $ok = 1 ] && echo "verify PASS: stop showed on send, its tap ended our turn (broker $tpid + its tree) in $(( $(date +%s) - t1 )) s, stopped shown, send back" \
  || echo "verify FAIL: stop didn't end our turn cleanly (shots in $OUT)"
[ $ok = 1 ]
