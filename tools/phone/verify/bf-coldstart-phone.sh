#!/bin/bash
# bf-coldstart-phone.sh <variant>...: (in the PowOS session as powos; bf-coldstart.sh pushes and runs it) a Broforce
# launch through the drawer's path, timed by stage from 4 Hz process samples: tap -> Steam's launch (reaper) ->
# pressure-vessel (pv-adverb) -> wineserver -> the game's exe -> its X window -> its first new frame. Variants:
#   cold      nothing running (bf-stop.sh first): Steam's own start included
#   steam     Steam left running (out of sight, so frozen by unified sleep), only the game closed
#   fexcache  as steam, with FEX's code cache on for the game (Proton user_settings.py: FEX_ENABLECODECACHINGWIP=1,
#             removed after) and FEXOfflineCompiler process-all between two such runs; lists the files FEX wrote
# Also per run: Steam's state at the tap, shader cache sizes before/after. "STAGES <variant> ..." lines, RESULT last.
set -uo pipefail
. /var/tmp/powos-bf-lib.sh
S=$HOME/.local/share/Steam P="$S/steamapps/common/Proton - Experimental" F=$S/steamapps/common/FEX-Emu
CD=$S/steamapps/compatdata/$APP
sizes() { echo "steam shadercache $(du -sk "$S/steamapps/shadercache/$APP" 2>/dev/null | cut -f1) KB, mesa $(du -sk ~/.cache/mesa_shader_cache 2>/dev/null | cut -f1) KB, fex $(du -sk "$CD/fex-emu" ~/.local/share/fex-emu 2>/dev/null | awk '{s+=$1} END{print s}') KB"; }
first() { [ -n "${seen[$1]:-}" ] || seen[$1]=$2; }
close_game() { local p; for p in $(reapers); do kill $(tree "$p") 2>/dev/null; done; sleep 3; for p in $(reapers); do kill -9 $(tree "$p") 2>/dev/null; done; pkill -f wineserver; sleep 2; }
fexcache_off() { rm -f "$P/user_settings.py"; }
ON_CLOSE=fexcache_off
run() {  # run <variant> <n>
  local v=$1 t0 now_ st r=0 x k=-1
  declare -gA seen=()
  case $v in
    cold) pill "cold start timing: closing Steam"; bash /var/tmp/powos-bf-stop.sh >/dev/null 2>&1 ;;
    *) close_game; [ "$(cat /proc/"$(steam_pid)"/comm 2>/dev/null)" = steam ] || { pill "starting Steam (for the warm runs)"; setsid -f steam -silent >/dev/null 2>&1 </dev/null; sleep 60; }
       pill "waiting for Steam to sleep (out of sight)"; for _ in $(seq 60); do [ -n "$(cg)" ] && break; touched; sleep 1; done ;;
  esac
  [ $v = fexcache ] && printf 'user_settings = {"FEX_ENABLECODECACHINGWIP": "1"}\n' > "$P/user_settings.py"
  st="steam $([ -d "/proc/$(steam_pid)" ] && { [ -n "$(cg)" ] && echo frozen || echo awake; } || echo off), wineserver $(pgrep -c wineserver)"
  echo "== $v #$2: at the tap: $st; $(sizes)"
  mine=1; pill "cold start timing: $v #$2 - tap"; t0=$(now)
  ( open_task 400 "steam_app_$APP" > "$T/open.status" ) &
  for _ in $(seq 1600); do  # 400 s
    now_=$(ms "$t0" "$(now)")
    [ -n "$(pgrep -f 'steamwebhelper' | head -1)" ] && first steam "$now_"
    r=$(reaper); [ -n "$r" ] && first reaper "$now_"
    pgrep -f pv-adverb >/dev/null && first container "$now_"
    pgrep -f wineserver >/dev/null && first wineserver "$now_"
    [ -n "${seen[wineserver]:-}" ] && pgrep -f 'Broforce_beta.exe' | while read -r x; do grep -qa 'wine.*preloader\|^.*FEX' "/proc/$x/cmdline" && ! grep -qa 'proton\|reaper\|python\|pressure-vessel' "/proc/$x/cmdline" && echo y; done | grep -q y && first exe "$now_"
    W=$(gamewin); [ -n "$W" ] && [ "$(mapped "$W")" = IsViewable ] && { first window "$now_"; break; }
    [ ${#seen[@]} != $k ] && k=${#seen[@]} && case $k in 0|1|2) pill "cold start timing: $v - Steam" ;; 3) pill "cold start timing: $v - pressure-vessel" ;; 4) pill "cold start timing: $v - wine" ;; 5) pill "cold start timing: $v - game starting" ;; esac
    touched; sleep 0.25
  done
  if [ -n "${seen[window]:-}" ]; then
    x=$(first_change "$W" 20 10); [ "$x" != none ] && seen[frame]=$(ms "$t0" "$x")
  else fail "start-$v" "no window in 400 s: $(for k in steam reaper container wineserver exe; do printf '%s=%s ' $k "${seen[$k]:--}"; done)"; fi
  echo "STAGES $v #$2 (ms from the tap): steam-ui ${seen[steam]:--} reaper ${seen[reaper]:--} pv ${seen[container]:--} wineserver ${seen[wineserver]:--} exe ${seen[exe]:--} window ${seen[window]:--} frame ${seen[frame]:--}; open-task: $(cat "$T/open.status" 2>/dev/null)"
  echo "   after: $(sizes)"
  RES_="$RES_ $v#$2 window ${seen[window]:--} frame ${seen[frame]:--};"
  [ $v = fexcache ] && { echo "   FEX wrote: $(find "$CD/fex-emu" ~/.local/share/fex-emu ~/.cache -newer /tmp/bf-cold-mark -type f 2>/dev/null | grep -vi telemetry | head -8 | tr '\n' ' ')"; fexcache_off; }
  sleep 5
}
touch /tmp/bf-cold-mark; RES_=""
echo "== $(date +%T) $(pacman -Q steam), FEX $(head -1 "$F/VERSIONS.txt" 2>/dev/null)"
powos sleep never --remove steam >/dev/null 2>&1
n=0
[ $# -gt 0 ] || set -- cold steam fexcache fexcache
for v in "$@"; do
  n=$((n + 1)); run "$v" "$n"
  if [ "$v" = fexcache ]; then
    pill "FEX: compiling the code cache"
    close_game; ( cd "$CD" && FEX_PORTABLE=1 FEX_APP_CONFIG_LOCATION="$CD/fex-emu/" timeout 300 "$F/usr/bin/FEXOfflineCompiler" process-all 2>&1 | tail -3 )
  fi
done
close_mine; rm -f /tmp/bf-cold-mark
echo "RESULT bf-coldstart: ${FAILS:+FAIL$FAILS - }$RES_"
[ -z "$FAILS" ]
