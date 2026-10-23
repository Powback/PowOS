#!/bin/bash
# bf-coldstart-phone.sh <variant>...: (in the PowOS session as powos; bf-coldstart.sh pushes and runs it) a Broforce
# launch through the drawer's path, timed by stage from 4 Hz process samples: tap -> Steam's web UI -> the install
# script evaluator (iscript: its own reaper `Install=1` + Proton `run iscriptevaluator.exe`, start-end; skipped when
# nothing changed since its last good run, pkgs/steam/user_settings.py) -> the game's launch (reaper) ->
# pressure-vessel (pv-adverb) -> wineserver -> the game's exe -> its X window -> its first drawn frame (first_frame).
# The evaluator's own pressure-vessel / wineserver don't count as the game's. Variants:
#   cold      nothing running (bf-stop.sh --steam first): Steam's own start included
#   steam     Steam left running (out of sight, so frozen by unified sleep), only the game closed
#   fexcache  as steam, with FEX's code cache on for the game (FEX_ENABLECODECACHINGWIP=1 through PowOS's Proton
#             user_settings.py: ~/.config/powos/proton-settings.json, removed after; a Proton without ours: its own
#             user_settings.py, removed after) and FEXOfflineCompiler process-all between two such runs; lists the files FEX wrote
# Also per run: Steam's state at the tap, shader cache sizes before/after. "STAGES <variant> ..." lines, RESULT last.
set -uo pipefail
. /var/tmp/powos-bf-lib.sh
S=$HOME/.local/share/Steam P="$S/steamapps/common/Proton - Experimental" F=$S/steamapps/common/FEX-Emu
CD=$S/steamapps/compatdata/$APP
sizes() { echo "steam shadercache $(du -sk "$S/steamapps/shadercache/$APP" 2>/dev/null | cut -f1) KB, mesa $(du -sk ~/.cache/mesa_shader_cache 2>/dev/null | cut -f1) KB, fex $(du -sk "$CD/fex-emu" ~/.local/share/fex-emu 2>/dev/null | awk '{s+=$1} END{print s}') KB"; }
first() { [ -n "${seen[$1]:-}" ] || seen[$1]=$2; }
close_game() { echo "   close: $(powos game $APP stop 2>&1 | tail -1 | sed "s/\x1b\[[0-9;]*m//g")"; }
ours() { head -1 "$P/user_settings.py" 2>/dev/null | grep -q 'PowOS user_settings'; }  # pkgs/steam/user_settings.py
fexcache_on() {
  if ours; then mkdir -p ~/.config/powos && printf '{"FEX_ENABLECODECACHINGWIP": "1"}\n' > ~/.config/powos/proton-settings.json
  else printf 'user_settings = {"FEX_ENABLECODECACHINGWIP": "1"}\n' > "$P/user_settings.py"; fi; }
fexcache_off() { rm -f ~/.config/powos/proton-settings.json; ours || rm -f "$P/user_settings.py"; }
ON_CLOSE=fexcache_off
run() {  # run <variant> <n>
  local v=$1 t0 now_ st r=0 x k=-1
  declare -gA seen=()
  case $v in
    cold) pill "cold start timing: closing Steam"; bash /var/tmp/powos-bf-stop.sh --steam | head -1 ;;
    *) close_game; [ "$(cat /proc/"$(steam_pid)"/comm 2>/dev/null)" = steam ] || { pill "starting Steam (for the warm runs)"; setsid -f steam -silent >/dev/null 2>&1 </dev/null; sleep 60; }
       pill "waiting for Steam to sleep (out of sight)"; for _ in $(seq 60); do [ -n "$(cg)" ] && break; touched; sleep 1; done ;;
  esac
  [ $v = fexcache ] && fexcache_on
  st="steam $([ -d "/proc/$(steam_pid)" ] && { [ -n "$(cg)" ] && echo frozen || echo awake; } || echo off), wineserver $(pgrep -c wineserver)"
  echo "== $v #$2: at the tap: $st; $(sizes)"
  gl=$(wc -l < "$S/logs/gameprocess_log.txt" 2>/dev/null || echo 0)
  mine=1; pill "cold start timing: $v #$2 - tap"; t0=$(now)
  ( open_task 400 "steam_app_$APP" > "$T/open.status" ) &
  for _ in $(seq 1600); do  # 400 s
    now_=$(ms "$t0" "$(now)")
    [ -n "$(pgrep -f 'steamwebhelper' | head -1)" ] && first steam "$now_"
    if [ -n "$(iscript_reapers)" ]; then first iscript "$now_"; elif [ -n "${seen[iscript]:-}" ]; then first iscript_end "$now_"; fi
    r=$(reaper); [ -n "$r" ] && first reaper "$now_"
    # The launch died: say so, don't wait 400 s. Only Steam's own word counts ("Remove <appid> from running list" in
    # gameprocess_log since the tap): a cold Steam first runs the game's install script evaluator through the same
    # reaper/Proton chain (console_log "Running install script evaluator", 15-40 s) and its end isn't the game's - taken
    # for a death, the check closed the real launch a second later (2026-10-23: "exit code -1" = this check's kill).
    [ -z "$r" ] && [ -n "${seen[reaper]:-}" ] && tail -n +$((gl + 1)) "$S/logs/gameprocess_log.txt" | grep -q "Remove $APP from running list" \
      && { seen[ended]=$now_; break; }
    [ -n "$r" ] && [ -z "$(iscript_reapers)" ] && pgrep -f pv-adverb >/dev/null && first container "$now_"
    [ -n "$r" ] && [ -z "$(iscript_reapers)" ] && pgrep -f wineserver >/dev/null && first wineserver "$now_"
    [ -n "${seen[wineserver]:-}" ] && pgrep -f 'Broforce_beta.exe' | while read -r x; do grep -qa 'wine.*preloader\|^.*FEX' "/proc/$x/cmdline" && ! grep -qa 'proton\|reaper\|python\|pressure-vessel' "/proc/$x/cmdline" && echo y; done | grep -q y && first exe "$now_"
    W=$(gamewin); [ -n "$W" ] && [ "$(mapped "$W")" = IsViewable ] && { first window "$now_"; break; }
    [ ${#seen[@]} != $k ] && k=${#seen[@]} && case " ${!seen[*]} " in
      *" exe "*) pill "cold start timing: $v - game starting" ;; *" wineserver "*) pill "cold start timing: $v - wine" ;;
      *" container "*) pill "cold start timing: $v - pressure-vessel" ;; *" reaper "*) pill "cold start timing: $v - launching" ;;
      *" iscript "*) pill "cold start timing: $v - install script" ;; *) pill "cold start timing: $v - Steam" ;; esac
    touched; sleep 0.25
  done
  if [ -n "${seen[window]:-}" ]; then
    pill "cold start timing: $v - first frame"
    x=$(first_frame 90); [ "$x" != none ] && seen[frame]=$(ms "$t0" "$x")
  elif [ -n "${seen[ended]:-}" ]; then fail "start-$v" "the launch chain ended ${seen[ended]} ms after the tap, no window; Steam: $(grep -a 'Game process removed\|exit code' "$S/logs/gameprocess_log.txt" | tail -2 | cut -c1-120 | tr '\n' '|')"
  else fail "start-$v" "no window in 400 s:$(for k in steam reaper container wineserver exe; do printf '%s=%s ' $k "${seen[$k]:--}"; done)"; fi
  echo "STAGES $v #$2 (ms from the tap): steam-ui ${seen[steam]:--} iscript ${seen[iscript]:--}-${seen[iscript_end]:--} reaper ${seen[reaper]:--} pv ${seen[container]:--} wineserver ${seen[wineserver]:--} exe ${seen[exe]:--} window ${seen[window]:--} frame ${seen[frame]:--}; open-task: $(cat "$T/open.status" 2>/dev/null)"
  echo "   after: $(sizes); evaluator: $(tail -1 "$CD/powos-iscript.log" 2>/dev/null | cut -c1-160)"
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
