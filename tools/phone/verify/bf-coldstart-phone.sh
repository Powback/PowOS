#!/bin/bash
# bf-coldstart-phone.sh <variant>...: (in the PowOS session as powos; bf-coldstart.sh pushes and runs it) a Steam game's
# (APP, default Broforce) launch through the drawer's path, timed by stage from 4 Hz process samples: tap -> Steam's web UI -> the install
# script evaluator (iscript: its own reaper `Install=1` + Proton `run iscriptevaluator.exe`, start-end; skipped when
# nothing changed since its last good run, pkgs/steam/user_settings.py) -> the game's launch (reaper) ->
# pressure-vessel (pv-adverb) -> wineserver -> the game's exe -> its X window -> its first drawn frame (first_frame).
# The evaluator's own pressure-vessel / wineserver don't count as the game's. Variants:
#   cold      nothing running (bf-stop.sh --steam first): Steam's own start included
#   steam     Steam left running (out of sight, so frozen by unified sleep), only the game closed
#   fexcache  as steam, with FEX's code cache on for the game (FEX_ENABLECODECACHINGWIP=1 through PowOS's Proton
#             user_settings.py: ~/.config/powos/proton-settings.json, removed after; a Proton without ours: its own
#             user_settings.py, removed after) and FEXOfflineCompiler process-all between two such runs; lists the files FEX wrote
# Setup tokens, applied with Steam closed (bf-cfg.py, backups next to the files) before the runs that follow them:
#   cfg:x86 | cfg:arm64 | cfg:native   compat tool: Proton Experimental (x86 Wine under FEX) | Proton Experimental
#             (ARM64: Wine native, only the game's code through FEX) | none = the game's native Linux build (Steam swaps
#             the depot at the next launch: stage "update")
#   opt:vk | opt:gl | opt:base         launch options: unity-screen + -force-vulkan | + -force-glcore | as installed
#   env:K=V   K=V in the environment of the Steam this check starts (all it launches inherits it), e.g.
#             env:PRESSURE_VESSEL_GENERATE_LOCALES=0
#   keep      leave the last setup in place at the end (default: the compat tool + launch options as they were)
# Also per run: Steam's state at the tap, shader cache sizes before/after, the Unity renderer (Player.log).
# "STAGES <variant> ..." lines, RESULT last.
set -uo pipefail
# Any Steam game: APP=<appid> (bf-coldstart.sh app:<id>); GAME / WIN_NAME (its window's title) default to the name in
# its appmanifest (bf-coldstart.sh win:<title> when the window is called something else).
if [ -n "${APP:-}" ] && [ -z "${GAME:-}" ]; then
  GAME=$(sed -n 's/^[[:space:]]*"name"[[:space:]]*"\(.*\)"$/\1/p' "$HOME/.local/share/Steam/steamapps/appmanifest_$APP.acf" 2>/dev/null | head -1)
  export GAME=${GAME:-$APP} WIN_NAME=${WIN_NAME:-$GAME}
fi
. /var/tmp/powos-bf-lib.sh
# Not ready: the game isn't fully installed yet, or Steam is still downloading something (a test set queued right after
# its downloads, steam-install.sh). Exit 3 = the queue tries again in a later window: a launch timed during a
# download measures Steam's network + disk, and the setup's Steam stop would cut the download off.
not_ready() { local f fl busy=""
  fl=$(steam_field "$APP" StateFlags); [ "${fl:-0}" = 4 ] || { echo "not ready: $GAME ($APP) not installed yet (StateFlags ${fl:--}) - again next window"; return 0; }
  for f in "$HOME"/.local/share/Steam/steamapps/appmanifest_*.acf; do
    fl=$(sed -nE 's/^\s*"StateFlags"\s*"([0-9]+)"/\1/p' "$f" | head -1)
    [ $(( ${fl:-0} & (256 | 1024 | 1048576) )) = 0 ] || busy="$busy $(basename "$f" .acf | sed 's/appmanifest_//')"; done
  [ -z "$busy" ] || { echo "not ready: Steam is downloading ($busy ) - again next window"; return 0; }
  return 1; }
not_ready && { rm -rf "$T"; exit 3; }
S=$HOME/.local/share/Steam P="$S/steamapps/common/Proton - Experimental" F=$S/steamapps/common/FEX-Emu
CD=$S/steamapps/compatdata/$APP
# The game's install dir: its own process is the one that runs a file from there (Wine's preloader / the native player).
IDIR=$(sed -n 's/^[[:space:]]*"installdir"[[:space:]]*"\(.*\)"$/\1/p' "$S/steamapps/appmanifest_$APP.acf" 2>/dev/null | head -1)
sizes() { echo "steam shadercache $(du -sk "$S/steamapps/shadercache/$APP" 2>/dev/null | cut -f1) KB, mesa $(du -sk ~/.cache/mesa_shader_cache 2>/dev/null | cut -f1) KB, fex $(du -sk "$CD/fex-emu" ~/.local/share/fex-emu 2>/dev/null | awk '{s+=$1} END{print s}') KB"; }
first() { [ -n "${seen[$1]:-}" ] || seen[$1]=$2; }
close_game() { echo "   close: $(powos game $APP stop 2>&1 | tail -1 | sed "s/\x1b\[[0-9;]*m//g")"; }
ours() { head -1 "$P/user_settings.py" 2>/dev/null | grep -q 'PowOS user_settings'; }  # pkgs/steam/user_settings.py
fexcache_on() {
  if ours; then mkdir -p ~/.config/powos && printf '{"FEX_ENABLECODECACHINGWIP": "1"}\n' > ~/.config/powos/proton-settings.json
  else printf 'user_settings = {"FEX_ENABLECODECACHINGWIP": "1"}\n' > "$P/user_settings.py"; fi; }
fexcache_off() { rm -f ~/.config/powos/proton-settings.json; ours || rm -f "$P/user_settings.py"; }
# Setup (cfg:/opt:/env:/keep tokens) through the steam package's powos-steam-compat (the copy bf-coldstart.sh pushed:
# the phone's may be older). ORIG = the game's compat mode + launch options before this check, put back at the end.
CFG="python3 /var/tmp/powos-steam-compat" ORIG_MODE="" ORIG_OPTS="" KEEP=0 CHANGED=0
base_opts() { local o; o=$($CFG get $APP | sed -n 's/.* opts=//p'); o=${o%% -force-*}; echo "$o"; }
plus_opts() { local b; b=$(base_opts); [ "$b" = - ] && b="%command%"; echo "$b $1"; }
setup() {  # setup <token>
  [ -n "$ORIG_MODE" ] || { ORIG_MODE=$($CFG mode $APP); ORIG_OPTS=$($CFG get $APP | sed -n 's/.* opts=//p'); }
  case $1 in env:*=*) export "${1#env:}"; echo "== setup $1: exported for the Steam this check starts"; return 0 ;; esac
  pill "setup $1: closing Steam"; bash /var/tmp/powos-bf-stop.sh --steam | head -1
  case $1 in
    cfg:x86 | cfg:arm64 | cfg:native) $CFG set $APP "${1#cfg:}" ;;
    cfg:auto) $CFG set $APP auto ;;
    opt:vk) $CFG opts $APP "$(plus_opts -force-vulkan)" ;; opt:gl) $CFG opts $APP "$(plus_opts -force-glcore)" ;;
    opt:base) $CFG opts $APP "$(base_opts)" ;;
    *) fail setup "unknown setup token $1"; return 1 ;;
  esac
  CHANGED=1; echo "== setup $1: $($CFG get $APP), mode $($CFG mode $APP)"
}
restore() {
  [ $CHANGED = 1 ] && [ $KEEP = 0 ] || return 0
  CHANGED=0; bash /var/tmp/powos-bf-stop.sh --steam >/dev/null 2>&1
  $CFG set $APP "$ORIG_MODE" >/dev/null && $CFG opts $APP "$ORIG_OPTS" >/dev/null && echo "== restored: $($CFG get $APP), mode $($CFG mode $APP)"
}
# The renderer the game reported: the newest Unity Player.log / output_log.txt written since this check began (Proton's
# prefix or the native build's ~/.config/unity3d).
renderer() { local l; l=$(find "$CD/pfx/drive_c/users" "$HOME/.config/unity3d" \( -name Player.log -o -name output_log.txt \) -newer /tmp/bf-cold-mark 2>/dev/null | head -1)
  [ -n "$l" ] && grep -a -m3 -i 'renderer:\|GfxDevice:\|Direct3D\|OpenGL\|Vulkan' "$l" | tr -d '\r' | cut -c1-90 | tr '\n' '|' || echo "no new Unity log"; }
ON_CLOSE="fexcache_off; restore"
# game_exe <reaper>: the game's own program runs under the launch - a process whose command line runs a file from
# common/<installdir>/ (Unix or Wine's Windows spelling), run by FEX or Wine, that isn't one of the chain's wrappers.
game_exe() { local x c; for x in $(tree "$1"); do c=$(tr '\0' ' ' < "/proc/$x/cmdline" 2>/dev/null) || continue
    case $c in *"common/$IDIR/"* | *"common\\$IDIR\\"*) ;; *) continue ;; esac
    case $(readlink "/proc/$x/exe") in *FEX* | *wine*) ;; *) continue ;; esac  # emulated (FEX) or in Wine (ARM64 Proton)
    printf '%s' "$c" | grep -q 'proton\|reaper\|python\|pressure-vessel\|steam-launch-wrapper\|unity-screen\|entry-point\|steam-runtime\|steam\.exe\|SteamLaunch' && continue
    return 0; done; return 1; }
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
  # 400 s cold (Steam's start, maybe a depot download); 150 s warm (~35 s expected): past that it is Steam's
  # freeze/thaw hanging the launch (INVALID below), and the check stays inside its 300 s budget to say so.
  for _ in $(seq $([ $v = cold ] && echo 1600 || echo 600)); do
    now_=$(ms "$t0" "$(now)")
    [ -n "$(pgrep -f 'steamwebhelper' | head -1)" ] && first steam "$now_"
    # A depot swap (cfg:native / back): Steam downloads before the launch.
    if [ -d "$S/steamapps/downloading/$APP" ]; then first update "$now_"; elif [ -n "${seen[update]:-}" ]; then first update_end "$now_"; fi
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
    # The game's own process (Wine's preloader / the native player, under FEX), not the chain's wrappers. The native
    # build has no wineserver: the exe counts from the game's reaper on.
    [ -n "$r" ] && [ -z "$(iscript_reapers)" ] && game_exe "$r" && first exe "$now_"
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
  else fail "start-$v" "no window in $([ $v = cold ] && echo 400 || echo 150) s:$(for k in steam reaper container wineserver exe; do printf '%s=%s ' $k "${seen[$k]:--}"; done)"; fi
  echo "STAGES $v #$2 (ms from the tap): steam-ui ${seen[steam]:--} update ${seen[update]:--}-${seen[update_end]:--} iscript ${seen[iscript]:--}-${seen[iscript_end]:--} reaper ${seen[reaper]:--} pv ${seen[container]:--} wineserver ${seen[wineserver]:--} exe ${seen[exe]:--} window ${seen[window]:--} frame ${seen[frame]:--}; open-task: $(cat "$T/open.status" 2>/dev/null)"
  echo "   tool: $($CFG get $APP); renderer: $(renderer)"
  echo "   after: $(sizes); evaluator: $(tail -1 "$CD/powos-iscript.log" 2>/dev/null | cut -c1-160)"
  RES_="$RES_ $v#$2 window ${seen[window]:--} frame ${seen[frame]:--};"
  # The per-game compat policy learns from it (powos-steam-compat record): a window = a working launch of this tool;
  # a chain that ended without one = a failed one. Not when Steam downloaded first (the time isn't the tool's).
  # A warm run (Steam left running) without a window says nothing about the tool while Steam's freeze/thaw can hang
  # a launch (2026-10-23 02:53: a frozen Steam never thawed for the launch, no window in 394 s; 02:58: never frozen):
  # INVALID, not a failed way - re-queue it once unified sleep's fix is in. Only a cold run's failure counts.
  if [ -z "${seen[window]:-}" ] && [ $v != cold ]; then
    echo "INVALID $v #$2: no window on a warm Steam (at the tap: $st; Steam's cgroup now '$(cg)') - Steam freeze/thaw, not the tool; not recorded"
  elif [ -z "${seen[update]:-}" ]; then
    if [ -n "${seen[window]:-}" ]; then echo "   policy: $($CFG record $APP "${seen[window]}" $([ $v = cold ] && echo --cold))"
    elif [ -n "${seen[ended]:-}" ]; then echo "   policy: $($CFG record $APP fail)"; fi
  fi
  [ $v = fexcache ] && { echo "   FEX wrote: $(find "$CD/fex-emu" ~/.local/share/fex-emu ~/.cache -newer /tmp/bf-cold-mark -type f 2>/dev/null | grep -vi telemetry | head -8 | tr '\n' ' ')"; fexcache_off; }
  sleep 5
}
touch /tmp/bf-cold-mark; RES_=""
echo "== $(date +%T) $(pacman -Q steam), FEX $(head -1 "$F/VERSIONS.txt" 2>/dev/null)"
powos sleep never --remove steam >/dev/null 2>&1
n=0
[ $# -gt 0 ] || set -- cold steam fexcache fexcache
for v in "$@"; do
  case $v in keep) KEEP=1; continue ;; cfg:* | opt:* | env:*) setup "$v" || break; continue ;; esac
  n=$((n + 1)); run "$v" "$n"
  if [ "$v" = fexcache ]; then
    pill "FEX: compiling the code cache"
    close_game; ( cd "$CD" && FEX_PORTABLE=1 FEX_APP_CONFIG_LOCATION="$CD/fex-emu/" timeout 300 "$F/usr/bin/FEXOfflineCompiler" process-all 2>&1 | tail -3 )
  fi
done
close_mine; restore; rm -f /tmp/bf-cold-mark
echo "RESULT bf-coldstart: ${FAILS:+FAIL$FAILS - }$RES_"
[ -z "$FAILS" ]
