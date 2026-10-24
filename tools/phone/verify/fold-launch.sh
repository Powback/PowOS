#!/bin/bash
# lanes: phone
# tools/phone/verify/fold-launch.sh [app:<steam id>]: a game launched FOLDED, then unfolded and folded again with it
# running - the user's "ui is in a really bad state after launching some games" (2026-10-23 23:49). Queue it:
#   queue.sh add <board-task> fold-launch.sh app:557340
# In one free window (the verify lock only then), the hinge forced with `cmd device_state state 0|3` (always reset):
#   1 folded, home: the game started through the drawer's path (powos-open-task, as bf-coldstart) - its window task
#     must be full screen on the cover (not freeform, bounds inside 1116x2484)
#   2 unfolded: Plasma's desktop (HomeDesktop) must not come up over the web home; Home -> the web home in front
#   3 folded again: no freeform task left anywhere (a window keeps its inner-screen bounds off the cover's edge
#     otherwise), home's page at the cover's width, its switcher layer closed
#   4 the switcher (KEYCODE_APP_SWITCH) on the cover: every card inside the screen; Home closes it again
# Screenshots + task dumps per step and two screenrecords (unfold, refold) in $OUT. Closes the game it started (never
# one the user started: then exit 3, a later window). FAIL lines; exit 1 on any, 3 = no window / the user's game.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); P=$(cd "$here/.." && pwd); A=$P/adb.sh
APP=557340
for a in "$@"; do case $a in app:[0-9]*) APP=${a#app:} ;; *) echo "FAIL setup: unknown argument '$a'"; exit 2 ;; esac; done
OUT=${OUT:-$HOME/.cache/powos-verify/fold-launch-$(date +%F_%H%M%S)}; mkdir -p "$OUT"
COVER=4630946316123810436 INNER=4630946704981769859
cleanup() { [ -n "${started:-}" ] && { echo "closing $APP"; user "timeout 20 powos game $APP stop 2>&1 | tail -1"; }; }
WL_TRAP='cleanup; "$A" shell cmd device_state state reset >/dev/null 2>&1; echo "device state reset: $("$A" shell cmd device_state print-state | tr -d "\r")"'
. "$here/window-lock.sh"
window_lock fold-launch.sh 120
# Under the runner (LOCK_HELD=1) window_lock sets no trap: the game closed and the hinge reset all the same.
trap 'rm -rf "${WL_LOCK:-/nonexistent}"; '"$WL_TRAP" EXIT
FAILS=0
fail() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }
user() { "$A" shell "su -c \"sh /data/powos/powos-run.sh '$1'\"" 2>&1 | tr -d '\r'; }
# Tasks as "id mode bounds visible component", one per line (am stack list: a RootTask's config line carries its mode).
tasks() { "$A" shell am stack list | tr -d '\r' | awk '/^RootTask/{m=""} /mWindowingMode=/{match($0,/mWindowingMode=[a-z-]*/); m=substr($0,RSTART+15,RLENGTH-15)}
  /^ +taskId=/{id=$1; sub("taskId=","",id); sub(":","",id); match($0,/bounds=\[[^ ]*/); b=substr($0,RSTART+7,RLENGTH-7); match($0,/visible=[a-z]*/); v=substr($0,RSTART+8,RLENGTH-8); print id, m, b, v, $2}'; }
focus() { "$A" shell "dumpsys window | grep -m1 mCurrentFocus" | tr -d '\r' | sed 's/.*mCurrentFocus=//'; }
snap() {  # snap <name>: tasks, focus, a screenshot of the ON screen
  tasks > "$OUT/$1-tasks.txt"; focus > "$OUT/$1-focus.txt"
  "$P/shot.sh" "$OUT/$1.png" >/dev/null 2>&1 || echo "  (no screenshot for $1)"
  echo "-- $1: focus $(cat "$OUT/$1-focus.txt")"; sed 's/^/   /' "$OUT/$1-tasks.txt"; }
page() { "$P/cdp.sh" eval home "$1" 2>/dev/null | tail -1 | tr -d '\\"'; }
reaper() { user "pgrep -f AppId=$APP | head -1"; }

# The user's own game running: never touched.
[ -n "$(reaper)" ] && { echo "game $APP is running (the user's): not touched - a later window"; exit 3; }
"$A" shell cmd device_state state 0; sleep 4
"$A" shell input keyevent 3; sleep 2
before=$(tasks | awk '{print $1}' | sort -n | tail -1)
echo "1) folded: starting $APP through the drawer's path"
user "POWOS_NO_LAUNCH_RECORD=1 setsid -f timeout 400 powos-open-task --app-id steam_app_$APP -- steam steam://rungameid/$APP >/tmp/fold-launch-open.out 2>&1 </dev/null"
started=1
win=""
for _ in $(seq 80); do  # up to ~240 s for the game's window task
  win=$(tasks | awk -v b="$before" '$1 > b && $5 ~ /PowosWindowActivity/ && $4 == "true" {print $1; exit}')
  [ -n "$win" ] && break; sleep 3
done
[ -z "$win" ] && { fail "no window task for $APP in 240 s ($(user 'tail -1 /tmp/fold-launch-open.out'))"; exit 1; }
sleep 3; snap 1-folded-launch
read -r _ mode bounds vis _ < <(grep "^$win " "$OUT/1-folded-launch-tasks.txt")
[ "$mode" = freeform ] && fail "1 launched folded, task $win is freeform at $bounds"
[ "$bounds" = "[0,0][1116,2484]" ] || fail "1 launched folded, task $win is at $bounds, not the cover's [0,0][1116,2484]"

echo "2) unfolded with the game running"
"$A" shell "screenrecord --display-id $INNER --time-limit 14 /data/local/tmp/fold-launch-unfold.mp4" >/dev/null 2>&1 &
rec=$!; sleep 1
"$A" shell cmd device_state state 3; sleep 6; snap 2-unfolded
grep -q HomeDesktop "$OUT/2-unfolded-focus.txt" && fail "2 unfolded: Plasma's desktop (HomeDesktop) came up over the web home"
"$A" shell input keyevent 3; sleep 3; snap 2-unfolded-home
grep -q HomeShell "$OUT/2-unfolded-home-focus.txt" || fail "2 Home unfolded: focus is $(cat "$OUT/2-unfolded-home-focus.txt"), not the web home"
wait $rec
echo "   page: $(page 'JSON.stringify({w:innerWidth,layer:document.querySelector(".recents")?.className})')"

echo "3) folded again"
"$A" shell "screenrecord --display-id $COVER --time-limit 20 /data/local/tmp/fold-launch-fold.mp4" >/dev/null 2>&1 &
rec=$!; sleep 1
"$A" shell cmd device_state state 0; sleep 6; snap 3-folded
awk '$2 == "freeform"' "$OUT/3-folded-tasks.txt" | while read -r id _ b _ c; do echo "FAIL: 3 folded: task $id ($c) is still freeform at $b"; done | tee "$OUT/3-freeform.txt"
[ -s "$OUT/3-freeform.txt" ] && FAILS=$((FAILS + 1))
st=$(page 'JSON.stringify({w:innerWidth,layer:document.querySelector(".recents")?.className.trim(),expand:!!document.querySelector(".recents-expand")})')
echo "   page: $st"
case $st in *'w:404'*) ;; *) fail "3 folded: home's page isn't at the cover's width: $st" ;; esac
case $st in *'layer:recents closed'*) ;; *) fail "3 folded: home's switcher layer isn't closed: $st" ;; esac

echo "4) the switcher on the cover"
"$A" shell input keyevent 187; sleep 3; "$P/shot.sh" "$OUT/4-switcher.png" >/dev/null 2>&1
cards=$(page 'JSON.stringify([...document.querySelectorAll(".recents .task")].map(e=>{const r=e.getBoundingClientRect();return [Math.round(r.left),Math.round(r.top),Math.round(r.right),Math.round(r.bottom)]}))')
echo "   cards: $cards"
out=$(page '[...document.querySelectorAll(".recents .task-row .task")].filter(e=>{const r=e.getBoundingClientRect();return r.width>0&&(r.top<-1||r.bottom>innerHeight+1||r.width>innerWidth)}).length')
[ "${out:-0}" != 0 ] && fail "4 switcher folded: $out card(s) outside the cover screen"
"$A" shell input keyevent 3; sleep 3; snap 4-home
st=$(page 'document.querySelector(".recents")?.className.trim()')
case $st in "recents closed"*) ;; *) fail "4 Home after the switcher: the layer is '$st', not closed (stuck)" ;; esac
grep -q HomeShell "$OUT/4-home-focus.txt" || fail "4 Home folded: focus is $(cat "$OUT/4-home-focus.txt")"
wait $rec
for f in unfold fold; do "$A" pull /data/local/tmp/fold-launch-$f.mp4 "$OUT/" >/dev/null 2>&1; "$A" shell rm -f /data/local/tmp/fold-launch-$f.mp4; done
"$A" shell "logcat -d -v time | grep -E 'PowosFoldedWindows|FoldWatcher|HomeScreen|WindowTasks|PowosWindowFrames'" | tr -d '\r' | tail -60 > "$OUT/logcat.txt"
echo "artefacts: $OUT"
[ "$FAILS" = 0 ] && echo "PASS: game launched folded is full screen; unfold keeps the web home; refold leaves no freeform task, home and its switcher fit the cover" || { echo "FAIL: $FAILS step(s) failed (fold-launch)"; exit 1; }
