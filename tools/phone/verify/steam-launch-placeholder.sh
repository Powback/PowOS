#!/bin/bash
# lanes: phone
# steam-launch-placeholder.sh [appid] (Mac side; queue it: queue.sh add steam-launch-placeholder steam-launch-placeholder.sh):
# SL1 (the user 11-07: "if steam is launching a game why arent we seeing the splashscreen app placeholder window thing
# we made?"). A game started as Steam's own UI starts it (`steam -applaunch` in the session, no PowOS launch path) must
# show home's launch placeholder (webwindows.tsx steamLaunches: a pending window with steam set and Steam's phase)
# within PLACEHOLDER_MS (default 3000) of the call, then the game's window takes it (a host id, the same element) and
# draws (live) within WINDOW_S (default 150). Forces the inner screen (device_state 3, reset after: web windows). FOLDED=1 (queue with
# --screen cover; the check folds to it itself - device_state 0 - and resets after): the cover screen, where the game's window is an Android task - its full-screen launch window
# (SteamLaunchTasks -> LaunchWindows, logcat "its launch window") within PLACEHOLDER_MS, then the game's window
# becomes THAT task ("launch window: now window"), no second task ("full screen (the app's own)"). The game (APP, default
# Broforce 274190) is closed after (powos game <appid> stop: the game only, Steam stays); one running already is the
# user's - SKIP (exit 3). Unfolded, the game's window may also open as its own full-screen task (WindowTasks "open ...:
# full screen", the placeholder handed over): the host's log says so while home's page is behind it and can't answer.
# After the game, home's page must answer again within 15 s (else FAIL home-frozen-after-game: the user's way back).
# Steam asking about APP (a cloud conflict, a launch option; "LaunchApp waiting for user response") before or during
# the launch: SKIP with its question - never answered here.
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
# A page eval gives up in 20 s, not cdp.ts's 120 s: home's page is paused under a game's full screen (GQ1,
# WebWindows.quietCheck) or behind the game's own task, and the 11-08 runs spent their budget on 120 s waits.
export CDP_TIMEOUT_S=${CDP_TIMEOUT_S:-20}
logs() { "$A" logcat -d -s SteamLaunchTasks:I LaunchWindows:I PowosWindow:I WindowTasks:I PowosWebWindows:I 2>/dev/null | tr -d '\r'; }
# Steam asking about APP (the phone side's ask: "LaunchApp waiting for user response to <what>"), else empty.
steam_ask() { session "bash /var/tmp/powos-slp.sh $APP ask" | sed -n 's/^ASK //p' | grep -v '^none$'; }
if [ "${FOLDED:-0}" = 1 ]; then
  # The cover screen made here (device_state 0, as game-present-rate.sh's fold), reset at the end: --screen cover is
  # only the pill's hint - 11-08 02:40 the job ran on the open inner screen, where the launch is home's web window, and
  # failed "no-launch-task window-never-took-the-task" with Steam's launch fine (Completed in 2 s).
  "$A" shell cmd device_state state 0 >/dev/null 2>&1
  trap '"$A" shell cmd device_state state reset >/dev/null 2>&1' EXIT
  sleep 3
else
  # The inner screen made here too (device_state 3, as ai-wide.sh / unfolded-checks.sh), reset at the end: the 11-09
  # 22:06 and 11-10 03:40 runs found the phone CLOSED on the desk (surface 1116x2484), where the launch's placeholder
  # is rightly the game's own launch task (SteamLaunchTasks "its launch window" at 0.4 s) and home's page has none -
  # FAIL no-placeholder from the check's screen, not the product.
  "$A" shell cmd device_state state 3 >/dev/null 2>&1
  trap '"$A" shell cmd device_state state reset >/dev/null 2>&1' EXIT
  sleep 4
  WH=$("$A" shell wm size | tr -d '\r' | sed -nE 's/.*(Override|Physical) size: ([0-9]+)x([0-9]+).*/\2/p' | tail -1)
  [ "${WH:-0}" -gt 2000 ] || { echo "SKIP display 0 is ${WH:-?} wide, not the inner screen (the unfold didn't take)"; exit 3; }
  [ "$(ev "$WIN")" = none ] || { echo "SKIP a Steam launch's window is up already: $(ev "$WIN")"; exit 3; }
fi
"$A" logcat -c >/dev/null 2>&1
# The placeholder's time is taken ON the page (PW_JS: webWins watched every 25 ms from before the call, its Date.now()
# when the window appears) against the phone's own clock at the call (the phone side's "CALL <epoch ms>"). Polled from
# the Mac it included each poll's CDP round trip over adb (~1.5-3 s, one slow eval more): 11-10 07:07 "7066 ms" FAIL
# slow-placeholder where the earlier runs measured 1675-2655 ms the same way. The Mac-side poll below stays the fallback.
PW_JS="new Promise(ok=>importShim('./ui/webwindows.tsx').then(m=>{const t=Date.now();window.__slpWatch=t;const f=()=>{const w=m.webWins.value.find(w=>w.steam);if(w)return ok(Date.now()+'|'+[w.id,!!w.pending,!!w.live,w.phase||''].join('|'));if(window.__slpWatch!==t||Date.now()-t>$((PLACEHOLDER_MS + 20000)))return ok('none');setTimeout(f,25)};f()},e=>ok('ERR '+e)))"
pw=""
if [ "${FOLDED:-0}" != 1 ]; then
  rm -f "$OUT/page-watch.txt"; ( CDP_TIMEOUT_S=$((PLACEHOLDER_MS / 1000 + 30)) ev "$PW_JS" > "$OUT/page-watch.txt" ) & pw=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ "$(ev '!!window.__slpWatch')" = true ] && break; sleep 0.5; done
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
  q=$(steam_ask)
  session "timeout 35 powos game $APP stop 2>&1 | tail -1" | tee -a "$OUT/run.txt"
  [ -z "$fails" ] && { echo "RESULT PASS folded launch task ${seen} ms"; exit 0; }
  logs > "$OUT/logcat.txt"; echo "artefacts: $OUT (logcat.txt: the launch's window tags)"
  [ -n "$q" ] && { echo "SKIP Steam asked about $APP during the launch: $q (left unanswered)$fails"; exit 3; }
  echo "RESULT FAIL$fails"; exit 1
fi
seen="" ; w=none
while [ "$(since)" -lt $((PLACEHOLDER_MS + 15000)) ]; do w=$(ev "$WIN"); case $w in none|"") ;; *) seen=$(since); break ;; esac; sleep 0.3; done
echo "placeholder (polled from the Mac, CDP round trips included): ${seen:-never} ms after the call ($w)" | tee -a "$OUT/run.txt"
# The page's own time ([PW_JS]): the verdict when it has one.
call=$(sed -n 's/^CALL \([0-9]*\).*/\1/p' "$OUT/run.txt" | head -1)
# Its answer is due once the Mac poll saw the window (10 s at most for the eval's own hop); else it's stopped.
[ -n "$pw" ] && { [ -n "$seen" ] && for _ in $(seq 1 20); do kill -0 "$pw" 2>/dev/null || break; sleep 0.5; done; kill "$pw" 2>/dev/null; }
pg=$(cat "$OUT/page-watch.txt" 2>/dev/null); at=${pg%%|*}
if [ -n "$call" ] && [ "${at:-x}" -gt 0 ] 2>/dev/null; then
  seen=$((at - call)); [ "$seen" -ge 0 ] || seen=0
  echo "placeholder: ${seen} ms after the call, on the page (${pg#*|})" | tee -a "$OUT/run.txt"
else echo "placeholder: no page-side time (${pg:-no answer}${call:-, no CALL line}) - the Mac poll's counts" | tee -a "$OUT/run.txt"; fi
fails=""
[ -n "$seen" ] || fails="$fails no-placeholder"
[ -n "$seen" ] && [ "$seen" -gt "$PLACEHOLDER_MS" ] && fails="$fails slow-placeholder"
case $w in -*'|true|'*) ;; none) ;; *) fails="$fails not-a-placeholder($w)" ;; esac
# The game's window takes the placeholder (a host id, live) - or opens as its own task (WindowTasks "open <id>
# (<app>): full screen ...": the launch is the task's, the placeholder goes - SteamLaunchTasks.taskOpened), after which
# home's page is behind the game and may not answer: the host's log says how it went, not the page.
# Its app id names APP when KWin's window says steam_app_<appid>; else the only full-screen task opened since the
# logcat was cleared at the call (nothing else launches meanwhile: the user is idle for a queue job).
task_opened() { local o; o=$(logs | grep -E "WindowTasks.*: open [0-9]+ \(.*\): (full screen|floating|in its launch window)")
  grep -E "$APP" <<<"$o" | tail -1 | grep . || grep "full screen (the app's own)" <<<"$o" | tail -1; }
end=$(( $(date +%s) + WINDOW_S )); last=$w; how=""; asked=0
while [ "$(date +%s)" -lt "$end" ]; do
  w=$(ev "$WIN"); [ "$w" != "$last" ] && { echo "  $(since) ms: $w" | tee -a "$OUT/run.txt"; last=$w; }
  case $w in [0-9]*'|false|true|'*) how=web; break ;; *'|'*'|'*'|'*'|'?*) break ;; esac
  case $w in none|""|cdp:*) t=$(task_opened); [ -n "$t" ] && { how=task; echo "  $(since) ms: its own task: ${t##*WindowTasks}" | tee -a "$OUT/run.txt"; break; } ;; esac
  # Steam asking for 20 s+ (a cloud conflict, a launch option): its question, not a placeholder fault - SKIP below.
  case $w in *'|Steam is asking something|'*) asked=$((asked + 1)) ;; *) asked=0 ;; esac
  [ "$asked" -ge 20 ] && q=$(steam_ask) && [ -n "$q" ] && break
  sleep 1
done
case $how in
  web) echo "window: the game's window took it and drew at $(since) ms" | tee -a "$OUT/run.txt" ;;
  task) echo "window: the game's window opened as its own task at $(since) ms (the placeholder handed over)" | tee -a "$OUT/run.txt" ;;
  *) fails="$fails window($w)" ;;
esac
q=${q:-$(steam_ask)}
session "timeout 35 powos game $APP stop 2>&1 | tail -1" | tee -a "$OUT/run.txt"
# Home after the game (the user's way back): its page answers again within 15 s - one that doesn't is home frozen.
back=""; for _ in $(seq 1 15); do [ "$(CDP_TIMEOUT_S=5 ev '1+1')" = 2 ] && { back=$(since); break; }; sleep 1; done
echo "home's page after the game: ${back:+answers at $back ms}${back:-NO ANSWER in 15 s}" | tee -a "$OUT/run.txt"
[ -n "$back" ] || fails="$fails home-frozen-after-game"
logs > "$OUT/logcat.txt"
echo "artefacts: $OUT (run.txt, logcat.txt)"
[ -z "$fails" ] && { echo "RESULT PASS placeholder ${seen} ms, ${how} window"; exit 0; }
[ -n "$q" ] && [ -n "$back" ] && { echo "SKIP Steam asked about $APP during the launch: $q (left unanswered)$fails"; exit 3; }
echo "RESULT FAIL$fails"; exit 1
