#!/bin/bash
# lanes: phone
# bf-recents.sh [recents|float]: (Mac side; queue it: queue.sh add <board-task> [env APP=<appid>] bf-recents.sh <what>)
# a Steam game (APP, default 274190 Broforce) the user started is a real task of the phone, in every PowOS mode it runs in:
#   recents  board "Linux apps/games (Broforce) show in the recents list": started through powos-open-task (the drawer's
#            path), its task (PowosWindowActivity) is in home's own recents list (the bridge's tasks.list, what the
#            switcher shows) labelled with the game's name - while it runs in front AND after HOME (the task backgrounded:
#            a full-screen Unity/Wine game that loses focus minimizes itself, and a task KWin closed then, or never
#            exported because the window was minimized, is the missing card).
#   float    board "Games in floating windows render (not black)": unfolded (device_state 3), the game started, HOME,
#            then reopened from its recents card (tasks.open, the card's tap: unfolded every task comes back floating) -
#            its task is freeform, and it DRAWS there: Xwayland's copy of the game window changes (bf-lib xframes count:
#            the game renders) AND SurfaceFlinger presents new buffers on the task's layer (KWin's export reaches
#            Android). Never a screenshot's darkness: Broforce's dark scenes read as "black" (f281).
# Phases on the phone: bf-return-phone.sh launch / close (bf-lib.sh steps). What it started is closed after; a game the
# user had left frozen is used and frozen again; one running awake = SKIP (exit 3); a real touch: exit 3 (re-queued).
# The PowOS mode it ran in (shell / plasma / together: KWin's desktopShown) is printed - queue it once per mode.
# Artefacts ~/.cache/powos-verify/bf-recents-<what>-<date>/run.txt.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"; APP=${APP:-274190}; WHAT=${1:-recents}
case $APP in *[!0-9]*|"") echo "FAIL setup: APP must be a Steam app id ($APP)"; exit 2 ;; esac
case $WHAT in recents|float) ;; *) echo "FAIL setup: bf-recents.sh recents|float ($WHAT)"; exit 2 ;; esac
OUT=${OUT:-$HOME/.cache/powos-verify/bf-recents-$WHAT-$(date +%F_%H%M)}; mkdir -p "$OUT"; R=$OUT/run.txt
GAME=${GAME:-Broforce}
log() { echo "$*" | tee -a "$R"; }
fail() { log "FAIL $1: $2"; }
sh_() { "$A" shell "su -c '$*'" 2>/dev/null | tr -d '\r'; }
irq() { sh_ "awk '/touch-0/{s+=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9} END{print s}' /proc/interrupts"; }
top() { sh_ "dumpsys activity activities | grep -m1 topResumedActivity"; }
# A call on home's bridge exactly as the page makes it (linux-float.sh's / float-windows.sh's hcall).
hcall() {
  "$T/cdp.sh" eval home "new Promise(ok=>{const h=window.__powosHost,P=window.PowosHost;if(!h||!P||!P.postMessage)return ok('ERR no bridge');const r=h.resolve,j=h.reject,id=910300+Math.floor(Math.random()*9000);const done=v=>{h.resolve=r;h.reject=j;ok(v)};h.resolve=(i,v)=>i===id?done(v):r(i,v);h.reject=(i,m)=>i===id?done('ERR '+m):j(i,m);setTimeout(()=>done('ERR no answer'),8000);P.postMessage(JSON.stringify([id,'$1',JSON.stringify($2)]))}).then(v=>typeof v==='string'&&v.startsWith('ERR')?v:($3)(v))" 2>&1 | tr -d '"\r' | tail -1
}
# card <task>: the recents list's entry for the task, "label|key", or "none"
card() { hcall tasks.list "[]" "l=>{const t=l.find(x=>x.id===$1);return t?t.label+'|'+t.key:'none ('+l.length+' cards: '+l.map(x=>x.id+':'+x.label).join(', ')+')'}"; }
mode() { sh_ "dumpsys activity activities" | grep -m1 -E "Task\{[^ ]* #$1 " | grep -oE "mode=[a-z-]+"; }
glog() { sh_ "grep -aE \"window task|full-screen window|as a task|desktop shown|stays on the desktop\" /data/powos/root/run/powos-app/hyprland.log | tail -${1:-8}"; }

ot=$(cd "$here/../../../targets/android/session" && pwd)/powos-open-task
"$A" push "$ot" /data/local/tmp/powos-open-task >/dev/null || { echo "FAIL setup: can't push $ot"; exit 1; }
for f in bf-return-phone.sh bf-lib.sh bf-stop.sh bf-xframes.py; do "$A" push "$here/$f" /data/local/tmp/powos-$f >/dev/null || { echo "FAIL setup: can't push $f"; exit 1; }; done
sh_ "install -m 755 /data/local/tmp/powos-open-task /data/powos/root/usr/local/bin/powos-open-task && cp /data/local/tmp/powos-bf-return-phone.sh /data/local/tmp/powos-bf-lib.sh /data/local/tmp/powos-bf-stop.sh /data/local/tmp/powos-bf-xframes.py /data/powos/root/var/tmp/ && chmod 644 /data/powos/root/var/tmp/powos-bf-*" >/dev/null
ph() { "$A" shell "su -c 'sh /data/powos/powos-run.sh \"APP=$APP bash /var/tmp/powos-bf-return-phone.sh $1\"'" 2>&1 | grep -v sysvipc | sed -l $'s/\r$//' | tee -a "$R"; }
xchanges() { ph "frames $1" | sed -n "s/^changes=//p" | tail -1; }  # distinct samples of the game's X window in <s> s
# presents <s>: the most new buffers SurfaceFlinger presented in <s> s on any PowosWindowActivity layer (the floating
# game's task is the one drawing; layer names carry no task id, and Steam's window task idles)
presents() {
  sh_ "cd /data/local/tmp; dumpsys SurfaceFlinger --list | grep PowosWindowActivity | grep -vE \"ActivityRecord|InputSink|Gesture\" | sed -E \"s/^RequestedLayerState.//; s/ parentId=.*//; s/ z=.*//\" | head -6 > powos-bfr-l; [ -s powos-bfr-l ] || { echo none; exit; }; n=0; while read -r L; do dumpsys SurfaceFlinger --latency \"\$L\" | awk \"NF==3&&\\\$3>0&&\\\$3<9e18{print \\\$3}\" > powos-bfr-\$n.a; n=\$((n+1)); done < powos-bfr-l; sleep $1; n=0; m=0; while read -r L; do c=\$(dumpsys SurfaceFlinger --latency \"\$L\" | awk \"NF==3&&\\\$3>0&&\\\$3<9e18{print \\\$3}\" | grep -cvxFf powos-bfr-\$n.a); [ \$c -gt \$m ] && m=\$c; n=\$((n+1)); done < powos-bfr-l; rm -f powos-bfr-*; echo \$m"
}
front=$(top | sed -nE 's#.* ([a-zA-Z0-9_.]+/[a-zA-Z0-9_.$]+) .*#\1#p'); log "front before: ${front:-?}"
closed=0
finish() {
  [ $closed = 1 ] && return; closed=1
  ph close >/dev/null
  [ "$WHAT" = float ] && sh_ "cmd device_state state reset"
  [ -n "$front" ] && sh_ "am start -n $front >/dev/null 2>&1"
  sh_ "rm -f /data/local/tmp/powos-open-task /data/local/tmp/powos-bf-*.sh /data/local/tmp/powos-bf-xframes.py /data/powos/root/var/tmp/powos-bf-return-phone.sh /data/powos/root/var/tmp/powos-bf-lib.sh /data/powos/root/var/tmp/powos-bf-stop.sh /data/powos/root/var/tmp/powos-bf-xframes.py /data/powos/root/tmp/bf-return.env" >/dev/null
}
result() { log "RESULT bf-recents $WHAT: $(grep -q '^FAIL' "$R" && echo "FAIL$(grep '^FAIL' "$R" | sed -E 's/^FAIL ([^:]*):.*/ \1/' | tr -d '\n')" || echo PASS) - artefacts $R"; }
trap 'log "stopped from outside $(date +%T)"; finish; exit 3' HUP TERM INT
i0=$(irq); touched() { [ "$(irq)" != "$i0" ] && { log "user input $(date +%T) - stopping"; finish; exit 3; }; }
shown=$(glog 40 | grep -oE "desktop shown: [a-z]+|stays on the desktop" | tail -1)
log "mode: KWin ${shown:-no desktop-shown line} (plasma = the game stays in the Plasma app's task by design, kwin 0031)"

if [ "$WHAT" = float ]; then
  sh_ "cmd device_state state 3"; sleep 3
  W=$(sh_ "wm size" | sed -nE 's/.*(Override|Physical) size: ([0-9]+)x.*/\2/p' | tail -1)
  [ "${W:-0}" -gt 2000 ] || { fail unfold "display 0 is ${W:-?} wide, not the unfolded inner screen"; finish; result; exit 1; }
fi
ph launch
grep -q '^SKIP\|^user input' "$R" && { finish; exit 3; }
grep -q '^FAIL launch' "$R" && { finish; result; exit 1; }
touched
TID=$(top | grep -oE ' t[0-9]+' | tr -dc '0-9')
case $(top) in *PowosWindowActivity*) log "game task $TID in front" ;; *) fail launch-front "the game's task isn't in front ($(top))"; TID= ;; esac
log "KWin: $(glog 6 | tr '\n' '|')"

if [ "$WHAT" = recents ]; then
  if [ -n "$TID" ]; then
    c=$(card "$TID"); log "recents card of task $TID (in front): $c"
    case $c in *"$GAME"*) ;; *) fail recents-front "no '$GAME' card for task $TID while it runs: $c" ;; esac
  fi
  sh_ "am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null 2>&1"; sleep 4; touched
  log "KWin after HOME: $(glog 4 | tr '\n' '|')"
  if [ -n "$TID" ]; then
    c=$(card "$TID"); log "recents card of task $TID (after HOME): $c"
    case $c in *"$GAME"*) ;; *) fail recents-home "the '$GAME' card is gone once the game is in the background: $c (dumpsys: $(sh_ "dumpsys activity recents | grep -c PowosWindowActivity") window tasks)" ;; esac
  fi
else
  if [ -n "$TID" ]; then
    sh_ "am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null 2>&1"; sleep 3; touched
    o=$(hcall tasks.open "[$TID]" "v=>String(v)"); sleep 4; touched
    m=$(mode "$TID"); log "reopened from its card ($o): task $TID $m, front $(top)"
    [ "$m" = mode=freeform ] || fail float "task $TID is $m after its card's tap on the unfolded home, not a floating window"
    x=$(xchanges 5); p=$(presents 5)
    log "drawing in the window: X window changes in 5 s: $x; SurfaceFlinger presents on the task's layer in 5 s: $p"
    case $x in ''|none|*[!0-9]*|0|1) fail float-xframes "the game's X window didn't change in 5 s ($x): the game itself stopped drawing" ;; esac
    case $p in ''|none|*[!0-9]*|0|1|2) fail float-presents "the task's layer got ${p:-no} new buffers in 5 s while the game draws ($x samples): KWin's export doesn't reach the floating task (black)" ;; esac
    log "KWin: $(glog 4 | tr '\n' '|')"
  fi
fi
finish
result
grep -q '^FAIL' "$R" && exit 1
exit 0
