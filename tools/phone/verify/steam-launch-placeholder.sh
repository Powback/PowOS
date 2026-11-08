#!/bin/bash
# lanes: phone
# steam-launch-placeholder.sh [appid] (Mac side; queue it: queue.sh add steam-launch-placeholder steam-launch-placeholder.sh):
# SL1 (the user 11-07: "if steam is launching a game why arent we seeing the splashscreen app placeholder window thing
# we made?"). A game started as Steam's own UI starts it (`steam -applaunch` in the session, no PowOS launch path) must
# show home's launch placeholder (webwindows.tsx steamLaunches: a pending window with steam set and Steam's phase)
# within PLACEHOLDER_MS (default 3000) of the call, then the game's window takes it (a host id, the same element) and
# draws (live) within WINDOW_S (default 150). Needs the unfolded inner screen (web windows). FOLDED=1 (queue with
# --screen cover; the check folds to it itself - device_state 0 - and resets after): the cover screen, where the game's window is an Android task - its full-screen launch window
# (SteamLaunchTasks -> LaunchWindows, logcat "its launch window") within PLACEHOLDER_MS, then the game's window
# becomes THAT task ("launch window: now window"), no second task ("full screen (the app's own)"). The game (APP, default
# Broforce 274190) is closed after (powos game <appid> stop: the game only, Steam stays); one running already is the
# user's - SKIP (exit 3).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A=$T/adb.sh
# shellcheck source=ww-lib.sh
. "$here/ww-lib.sh"
APP=${1:-${APP:-274190}}; PLACEHOLDER_MS=${PLACEHOLDER_MS:-3000}; WINDOW_S=${WINDOW_S:-150}
OUT=${OUT:-$HOME/.cache/powos-verify/steam-launch-placeholder-$(date +%F_%H%M)}; mkdir -p "$OUT"
session() { "$A" shell "su -c 'sh /data/powos/powos-run.sh \"$1\"'" | tr -d '\r'; }
WIN="importShim('./ui/webwindows.tsx').then(m=>{const w=m.webWins.value.find(w=>w.steam);return w?[w.id,!!w.pending,!!w.live,w.phase||'',w.failed||''].join('|'):'none'})"
"$A" push "$here/steam-launch-placeholder-phone.sh" /data/local/tmp/powos-slp.sh >/dev/null || { echo "FAIL setup: can't push the phone side"; exit 1; }
"$A" shell "su -c 'cp /data/local/tmp/powos-slp.sh /data/powos/root/var/tmp/powos-slp.sh && chmod 755 /data/powos/root/var/tmp/powos-slp.sh'" >/dev/null
if [ "${FOLDED:-0}" = 1 ]; then
  # The cover screen made here (device_state 0, as game-present-rate.sh's fold), reset at the end: --screen cover is
  # only the pill's hint - 11-08 02:40 the job ran on the open inner screen, where the launch is home's web window, and
  # failed "no-launch-task window-never-took-the-task" with Steam's launch fine (Completed in 2 s).
  "$A" shell cmd device_state state 0 >/dev/null 2>&1
  trap '"$A" shell cmd device_state state reset >/dev/null 2>&1' EXIT
  sleep 3
  "$A" logcat -c >/dev/null 2>&1
  logs() { "$A" logcat -d -s SteamLaunchTasks:I LaunchWindows:I PowosWindow:I WindowTasks:I 2>/dev/null | tr -d '\r'; }
else
  [ "$(ev "$WIN")" = none ] || { echo "SKIP a Steam launch's window is up already: $(ev "$WIN")"; exit 3; }
fi
t0=$(python3 -c 'import time;print(time.time())')
session "bash /var/tmp/powos-slp.sh $APP" | tee "$OUT/run.txt"
grep -q "^SKIP" "$OUT/run.txt" && exit 3
grep -q "^ANNOUNCE" "$OUT/run.txt" || { echo "RESULT FAIL announce"; exit 1; }
since() { python3 -c "import time;print(int((time.time()-$t0)*1000))"; }
if [ "${FOLDED:-0}" = 1 ]; then
  seen=""; fails=""
  while [ "$(since)" -lt $((PLACEHOLDER_MS + 15000)) ]; do logs | grep -q "($APP): its launch window" && { seen=$(since); break; }; sleep 0.5; done
  echo "launch task: ${seen:-never} ms after the call" | tee -a "$OUT/run.txt"
  [ -n "$seen" ] || fails="$fails no-launch-task"
  [ -n "$seen" ] && [ "$seen" -gt "$PLACEHOLDER_MS" ] && fails="$fails slow-launch-task"
  end=$(( $(date +%s) + WINDOW_S ))
  while [ "$(date +%s)" -lt "$end" ]; do logs | grep -q "launch window: now window\|launch of .* failed" && break; sleep 2; done
  logs | grep "its launch window\|launch window: now window\|launch of .* failed\|full screen (the app's own)" | tail -6 | tee -a "$OUT/run.txt"
  logs | grep -q "launch window: now window" || fails="$fails window-never-took-the-task"
  logs | grep -q "full screen (the app's own)" && fails="$fails second-task"
  session "timeout 20 powos game $APP stop 2>&1 | tail -1" | tee -a "$OUT/run.txt"
  [ -z "$fails" ] && { echo "RESULT PASS folded launch task ${seen} ms"; exit 0; }
  echo "RESULT FAIL$fails"; exit 1
fi
seen="" ; w=none
while [ "$(since)" -lt $((PLACEHOLDER_MS + 15000)) ]; do w=$(ev "$WIN"); case $w in none|"") ;; *) seen=$(since); break ;; esac; sleep 0.3; done
echo "placeholder: ${seen:-never} ms after the call ($w)" | tee -a "$OUT/run.txt"
fails=""
[ -n "$seen" ] || fails="$fails no-placeholder"
[ -n "$seen" ] && [ "$seen" -gt "$PLACEHOLDER_MS" ] && fails="$fails slow-placeholder"
case $w in -*'|true|'*) ;; none) ;; *) fails="$fails not-a-placeholder($w)" ;; esac
end=$(( $(date +%s) + WINDOW_S )); last=$w
while [ "$(date +%s)" -lt "$end" ]; do
  w=$(ev "$WIN"); [ "$w" != "$last" ] && { echo "  $(since) ms: $w" | tee -a "$OUT/run.txt"; last=$w; }
  case $w in [0-9]*'|false|true|'*) break ;; *'|'*'|'*'|'*'|'?*) break ;; esac
  sleep 1
done
case $w in [0-9]*'|false|true|'*) echo "window: the game's window took it and drew at $(since) ms" | tee -a "$OUT/run.txt" ;; *) fails="$fails window($w)" ;; esac
session "timeout 20 powos game $APP stop 2>&1 | tail -1" | tee -a "$OUT/run.txt"
echo "artefacts: $OUT/run.txt"
[ -z "$fails" ] && { echo "RESULT PASS placeholder ${seen} ms"; exit 0; }
echo "RESULT FAIL$fails"; exit 1
