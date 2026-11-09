#!/bin/bash
# lanes: phone
# game-present-rate.sh: (Mac side; queue it: queue.sh add <board-task> game-present-rate.sh) a running game never stops
# presenting frames (board "Game render stalls: engine keeps running but window stops presenting frames"). In one free
# window: the game (APP, default 274190 Broforce) started the user's way (bf-return-phone.sh launch: powos-open-task,
# a Broforce the user left frozen is used and frozen again, one running awake = SKIP), then for SECS (60) s
# game-present-rate-phone.sh samples SurfaceFlinger's new presents on the game's layers about every second while this
# drives the transitions that stalled it: the switcher opened (KEYCODE_APP_SWITCH) and closed again by the game's card
# (tasks.open, the card's tap), then a fold-style resize (cmd device_state 0 = cover, then 3 = unfolded; reset after).
# FAIL stall: any span of >= 2 s with 0 presents while the game's launch chain is alive and the game is in front (its
# window task, or home showing its web window). Each stall names its stage from KWin's lines of the run (kwin.txt):
# "0 commits" = upstream (the game / Xwayland stopped presenting to the surface), commits but SF 0 = KWin's draw or the
# Android consumer. What it started is closed (bf-stop.sh via bf-return-phone.sh close). A touch: exit 3.
# Artefacts ~/.cache/powos-verify/game-present-rate-<date>/ (run.txt, samples, kwin.txt). Budget <= 300 s.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"; APP=${APP:-274190}; SECS=${SECS:-60}
case $APP$SECS in *[!0-9]*) echo "FAIL setup: APP / SECS are numbers ($APP $SECS)"; exit 2 ;; esac
OUT=${OUT:-$HOME/.cache/powos-verify/game-present-rate-$(date +%F_%H%M)}; mkdir -p "$OUT"; R=$OUT/run.txt
log() { echo "$(date +%T) $*" | tee -a "$R"; }
sh_() { "$A" shell "su -c '$*'" 2>/dev/null | tr -d '\r'; }
irq() { sh_ "awk '/touch-0/{s+=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9} END{print s}' /proc/interrupts"; }
top() { sh_ "dumpsys activity activities | grep -m1 topResumedActivity"; }
# A call on home's bridge exactly as the page makes it (bf-recents.sh's hcall).
hcall() {
  "$T/cdp.sh" eval home "new Promise(ok=>{const h=window.__powosHost,P=window.PowosHost;if(!h||!P||!P.postMessage)return ok('ERR no bridge');const r=h.resolve,j=h.reject,id=910400+Math.floor(Math.random()*9000);const done=v=>{h.resolve=r;h.reject=j;ok(v)};h.resolve=(i,v)=>i===id?done(v):r(i,v);h.reject=(i,m)=>i===id?done('ERR '+m):j(i,m);setTimeout(()=>done('ERR no answer'),8000);P.postMessage(JSON.stringify([id,'$1',JSON.stringify($2)]))}).then(v=>String(v))" 2>&1 | tr -d '"\r' | tail -1
}
ot=$(cd "$here/../../../targets/android/session" && pwd)/powos-open-task
"$A" push "$ot" /data/local/tmp/powos-open-task >/dev/null || { echo "ENV: can't push $ot"; exit 5; }
for f in bf-return-phone.sh bf-lib.sh bf-stop.sh bf-xframes.py game-present-rate-phone.sh; do
  "$A" push "$here/$f" /data/local/tmp/powos-$f >/dev/null || { echo "ENV: can't push $f"; exit 5; }; done
sh_ "install -m 755 /data/local/tmp/powos-open-task /data/powos/root/usr/local/bin/powos-open-task && cp /data/local/tmp/powos-bf-return-phone.sh /data/local/tmp/powos-bf-lib.sh /data/local/tmp/powos-bf-stop.sh /data/local/tmp/powos-bf-xframes.py /data/powos/root/var/tmp/ && chmod 644 /data/powos/root/var/tmp/powos-bf-*" >/dev/null
ph() { "$A" shell "su -c 'sh /data/powos/powos-run.sh \"APP=$APP bash /var/tmp/powos-bf-return-phone.sh $1\"'" 2>&1 | grep -v sysvipc | sed -l $'s/\r$//' | tee -a "$R"; }
PD=/data/local/tmp/powos-gpr
closed=0 SP=
finish() {
  [ $closed = 1 ] && return; closed=1
  [ -n "$SP" ] && kill "$SP" 2>/dev/null
  sh_ "cmd device_state state reset"
  ph close >/dev/null
  sh_ "rm -f /data/local/tmp/powos-open-task /data/local/tmp/powos-bf-*.sh /data/local/tmp/powos-bf-xframes.py /data/local/tmp/powos-game-present-rate-phone.sh /data/powos/root/var/tmp/powos-bf-return-phone.sh /data/powos/root/var/tmp/powos-bf-lib.sh /data/powos/root/var/tmp/powos-bf-stop.sh /data/powos/root/var/tmp/powos-bf-xframes.py /data/powos/root/tmp/bf-return.env" >/dev/null
}
trap 'log "stopped from outside"; finish; exit 3' HUP TERM INT
i0=$(irq); touched() { [ "$(irq)" != "$i0" ] && { log "user input - stopping"; finish; exit 3; }; }

ph launch
grep -q '^SKIP\|^user input' "$R" && { finish; exit 3; }
grep -q '^FAIL launch' "$R" && { finish; log "RESULT game-present-rate: FAIL launch - artefacts $R"; exit 1; }
touched
TID=$(top | grep -oE ' t[0-9]+' | tr -dc '0-9')
case $(top) in *PowosWindowActivity*) log "game task $TID in front" ;; *) log "game not in its own task in front ($(top)): sampling its web window" ;; esac
sleep 5   # past the window going full screen
sh_ "rm -rf $PD; sh /data/local/tmp/powos-game-present-rate-phone.sh $SECS $APP $PD" & SP=$!
t0=$(date +%s)
at() { local w=$(( t0 + $1 - $(date +%s) )); [ $w -gt 0 ] && sleep $w; touched; }
at 10; log "switcher open"; sh_ "input keyevent KEYCODE_APP_SWITCH"
at 16; log "switcher closed by the game's card: $([ -n "$TID" ] && hcall tasks.open "[$TID]" || sh_ "input keyevent KEYCODE_BACK")"
# rebase: the touch-IRQ baseline taken again 3 s after this check's own fold - the other panel's power-up moves its
# counter with no finger (game-resize.sh's rebase; idle.sh's watcher skips it by the mOverrideState change).
rebase() { sleep 3; i0=$(irq); }
at 26; log "fold: cover (device_state 0)"; sh_ "cmd device_state state 0"; rebase
at 40; log "unfold (device_state 3)"; sh_ "cmd device_state state 3"; rebase
wait "$SP"; SP=
sh_ "cat $PD/samples" > "$OUT/samples"; sh_ "cat $PD/kwin.txt" > "$OUT/kwin.txt"; sh_ "rm -rf $PD"
finish
# Verdict: spans (>= 2 s) of consecutive alive+front samples with 0 presents; the KWin frame lines of the run say whether
# the surface still got commits then (KWin's lines carry no time: the stage is per run, listed with the counts).
# A sample's presents cover the time since the previous sample, so a 0-run's span starts at the sample before it.
st=$(awk '{a=$2=="alive=1"; f=$3=="front=1"; split($4,p,"="); if (a && f && p[2]==0) { if (s=="") s=(lt==""?$1:lt); e=$1 }
  else { if (s!="" && e-s >= 2000) printf "%.1f-%.1fs ", (s-T0)/1000, (e-T0)/1000; s="" } lt=$1 }
  END { if (s!="" && e-s >= 2000) printf "%.1f-%.1fs ", (s-T0)/1000, (e-T0)/1000 }' T0=0 "$OUT/samples")
n=$(wc -l < "$OUT/samples" | tr -d ' ')
log "samples $n: presents per sample $(awk '{split($4,p,"="); printf "%s%s", (NR>1?" ":""), ($2=="alive=1"?"":"x") ($3=="front=1"?"":"b") p[2]}' "$OUT/samples") (x = game gone, b = not in front)"
log "KWin (run): $(grep -cE 'frames: last 5 s 0 commits' "$OUT/kwin.txt") frame lines with 0 commits, $(grep -cE 'frames: last 5 s [1-9]' "$OUT/kwin.txt") with commits; Xwayland BUGs $(grep -c 'BUG' "$OUT/kwin.txt"), import failures $(grep -c 'failed to import' "$OUT/kwin.txt")"
[ "$n" -ge $((SECS / 2)) ] || { log "RESULT game-present-rate: FAIL samples - only $n samples in $SECS s - artefacts $R"; exit 1; }
if [ -n "$st" ]; then
  log "RESULT game-present-rate: FAIL stall - 0 presents for >= 2 s while the game ran in front at ${st}- artefacts $R"; exit 1
fi
log "RESULT game-present-rate: PASS - presents every 2 s through switcher + fold - artefacts $R"
