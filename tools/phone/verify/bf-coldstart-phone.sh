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
#   fetch     untimed: a launch kept until Steam downloaded what the setup needs (a depot swap), then closed
# Setup tokens, applied with Steam closed (bf-cfg.py, backups next to the files) before the runs that follow them:
#   cfg:x86 | cfg:arm64 | cfg:native   compat tool: Proton Experimental (x86 Wine under FEX) | Proton Experimental
#             (ARM64: Wine native, only the game's code through FEX) | none = the game's native Linux build (Steam swaps
#             the depot at the next launch: stage "update")
#   opt:vk | opt:gl | opt:base         launch options: unity-screen + -force-vulkan | + -force-glcore | as installed
#   env:K=V   K=V in the environment of the Steam this check starts (all it launches inherits it), e.g.
#             env:PRESSURE_VESSEL_GENERATE_LOCALES=0
#   keep      leave the last setup in place at the end (default: the compat tool + launch options as they were)
#   via:steam the runs that follow launch the way Steam's own Library does (`steam steam://rungameid/<id>` into Steam,
#             no powos-open-task): only KWin's own export can show the game then (2026-10-24: Broforce ran unseen)
#             via:drawer back to the default
# Every run asserts the game's window became an Android task (KWin's "window task N live ... for <title>" in
# hyprland.log, FAIL export-<variant> otherwise, with the window's X state) and asks the Mac side for a screenshot
# ("SHOT <name>", bf-coldstart.sh takes it with shot.sh).
# Also per run: Steam's state at the tap, shader cache sizes before/after, the Unity renderer (Player.log).
# "STAGES <variant> ..." lines, RESULT last.
set -uo pipefail
# Any Steam game: APP=<appid> (bf-coldstart.sh app:<id>); GAME / WIN_NAME (its window's title) default to the name in
# its appmanifest (bf-coldstart.sh win:<title> when the window is called something else).
[ -n "${WIN_B64:-}" ] && { WIN_NAME=$(printf %s "$WIN_B64" | base64 -d); export WIN_NAME; }
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
    cfg:x86 | cfg:arm64) $CFG set $APP "${1#cfg:}"; pfx_use "${1#cfg:}" ;;
    cfg:native) $CFG set $APP native ;;
    cfg:auto) $CFG set $APP auto ;;
    opt:vk) $CFG opts $APP "$(plus_opts -force-vulkan)" ;; opt:gl) $CFG opts $APP "$(plus_opts -force-glcore)" ;;
    opt:base) $CFG opts $APP "$(base_opts)" ;;
    *) fail setup "unknown setup token $1"; return 1 ;;
  esac
  CHANGED=1; echo "== setup $1: $($CFG get $APP), mode $($CFG mode $APP)"
}
# One Proton prefix per Wine architecture (as td-launch-phone.sh): a prefix ARM64 Proton set up breaks x86 Proton (its
# VC++ runtime DLLs: c000007b, Teardown 2026-10-23 06:04). cfg:x86 / cfg:arm64 swap compatdata/<id> with
# compatdata/<id>.powos-<family> (Steam is off in setup); the family found at the start comes back with the tool
# at the end (not with keep: tool and prefix stay together; powos-family records which prefix is in place).
CD0=$S/steamapps/compatdata/$APP PFX0=
pfx_fam() { cat "$CD0/powos-family" 2>/dev/null || { case $($CFG get $APP) in *arm64*) echo arm64 ;; *) echo x86 ;; esac; }; }
pfx_use() {
  local cur; cur=$(pfx_fam); [ -n "$PFX0" ] || PFX0=$cur; [ "$cur" = "$1" ] && return 0
  [ -d "$CD0" ] && { rm -rf "$CD0.powos-$cur.old"; [ -e "$CD0.powos-$cur" ] && mv "$CD0.powos-$cur" "$CD0.powos-$cur.old"; echo "$cur" > "$CD0/powos-family"; mv "$CD0" "$CD0.powos-$cur"; }
  if [ -d "$CD0.powos-$1" ]; then mv "$CD0.powos-$1" "$CD0"; else mkdir -p "$CD0"; fi
  echo "$1" > "$CD0/powos-family"; echo "   prefix: $1 (the $cur one kept as compatdata/$APP.powos-$cur)"
}
pfx_back() { [ -n "$PFX0" ] || return 0; bash /var/tmp/powos-bf-stop.sh --steam >/dev/null 2>&1; pfx_use "$PFX0"; PFX0=; }
restore() {
  [ $CHANGED = 1 ] && [ $KEEP = 0 ] || return 0  # keep: the tool AND its prefix stay (they belong together)
  pfx_back
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
HYPR=/run/powos-app/hyprland.log
# exported <variant> <hyprland.log line at the tap> <X window>: the game's window is an Android task (KWin's word: its
# task went live, a PowosWindowActivity drew it) within 20 s of the window, else FAIL export-<variant> + its X state.
exported() {
  local t line=""
  for t in $(seq 80); do
    # awk, not tail | grep -m1: grep's early exit SIGPIPEs tail and pipefail calls the match a miss
    line=$(awk -v n="$(($2 + 1))" -v k="live, " -v w="for \"$WIN_NAME" 'NR >= n && index($0, k) && index($0, w) {print; exit}' "$HYPR" 2>/dev/null)
    [ -n "$line" ] && break
    touched; sleep 0.25
  done
  if [ -n "$line" ]; then
    echo "   exported: ${line#*kwin_backend_anland: }"
    echo "SHOT ${1}-$(date +%H%M%S)"; sleep 6   # the Mac side's screenshot of the game on screen
  else
    fail "export-$1" "the game's window is no Android task 20 s after it showed (nothing on the phone shows it)"
  fi
  echo "   KWin: $(tail -n +"$(($2 + 1))" "$HYPR" 2>/dev/null | grep -a -E 'has its surface|full-screen window|opened as a task|window task [0-9]+ live|new windows as tasks' | sed 's/kwin_backend_anland: //' | tail -6 | cut -c1-160 | tr '\n' '|')"
  echo "   X: $(xwininfo -id "$3" 2>/dev/null | awk '/Map State|Override Redirect|Width|Height/ {$1=$1; printf "%s; ", $0}')$(xprop -id "$3" _NET_WM_STATE _NET_WM_WINDOW_TYPE WM_TRANSIENT_FOR 2>/dev/null | tr '\n' ' ')"
}
# cs_ready_steam <variant>: get Steam into the state the variant needs before the tap (closed for cold, left
# running and asleep for the warm variants). Split out of run() to keep it under the length budget
# (test-complexity.sh) - same steps, same messages.
cs_ready_steam() {
  case $1 in
    cold) pill "cold start timing: closing Steam"; bash /var/tmp/powos-bf-stop.sh --steam | head -1 ;;
    *) close_game; [ "$(cat /proc/"$(steam_pid)"/comm 2>/dev/null)" = steam ] || { pill "starting Steam (for the warm runs)"; setsid -f steam -silent >/dev/null 2>&1 </dev/null; sleep 60; }
       # A -silent Steam has no window, so unified sleep never freezes it (seen 2026-10-23: resident Steam awake 20 min
       # after its start); a Steam the user had on screen is frozen 15 s after it went out of sight. 25 s at most.
       pill "waiting for Steam to sleep (out of sight)"; for _ in $(seq 25); do [ -n "$(cg)" ] && break; touched; sleep 1; done ;;
  esac
}
# cs_poll_launch: poll the launch's process tree / windows / logs for stage timestamps (into the global `seen`
# array) until a window shows, the chain ends, or the budget runs out. Split out of run() to keep it under the
# length budget (test-complexity.sh) - reads/writes run()'s locals (v, t0, gl, cl, cb, up) by bash's normal
# dynamic scoping (a function sees its caller's locals), same as the rest of this file's helpers do with `seen`.
# cs_poll_diag: every 30 s of cs_poll_launch's loop (i % 120 == 119, at 4 Hz), what the launch is doing (a run the
# budget kills still says where it stood - 2026-10-23 05:13: the native build's exe at 41 s, then nothing for 4
# min): the newest processes under the launch, the game's own process (state, wchan, CPU s), its windows. Split
# out of cs_poll_launch to keep it under the length budget (test-complexity.sh) - reads/writes cs_poll_launch's
# locals (now_, r, i) by bash's normal dynamic scoping, same as the rest of this file's helpers do with `seen`.
cs_poll_diag() {
  local xw
  x=$(for q in $(tree "$r"); do tr '\0' ' ' < /proc/$q/cmdline 2>/dev/null | grep -qF "common/$IDIR/" && echo $q; done | tail -1)
  echo "   at ${now_} ms: $(tail -n 3 "$T/timeline" 2>/dev/null | cut -f3 | cut -c1-60 | tr '\n' '|') game ${x:-none}$([ -n "$x" ] && awk '{printf " state %s cpu %.1fs", $3, ($14+$15)/100}' /proc/$x/stat 2>/dev/null) wchan $(cat /proc/${x:-0}/wchan 2>/dev/null); X windows of it: $(xwininfo -root -tree 2>/dev/null | grep -c "$WIN_NAME")"
  [ -n "$x" ] && [ -n "${seen[exe]:-}" ] && echo "     $(hang_diag "$x")"
  # A first launch's install script past 60 s (ABZU 2026-10-23 08:16: still in the evaluator at 272 s, tabtip.exe
  # up = something showed a dialog): every process under the evaluator (state, CPU s) and the X windows' names.
  # No launch chain 60 s after the tap (Desk Job 08:21: nothing for 284 s, no download seen): Steam's windows (a
  # dialog waiting for an answer: launch-option picker, EULA, cloud conflict...) and its console since the tap.
  if [ -z "$r" ] && [ -z "$(iscript_reapers)" ] && [ "$now_" -gt 60000 ]; then
    echo "     no launch yet - X windows: $(xwininfo -root -tree 2>/dev/null | sed -nE 's/^ +0x[0-9a-f]+ "([^"]+)".* ([0-9]+x[0-9]+)\+.*/\1 \2/p' | sort | uniq -c | sort -rn | head -12 | awk '{$1=$1; print}' | tr '\n' '|')"
    echo "     console_log: $(tail -n +$((cl + 1)) "$S/logs/console_log.txt" 2>/dev/null | grep -v '^\s*$' | tail -6 | cut -c1-150 | tr '\n' '|')"
    # f89: "no launch yet" used to print only SlowJSMethodCall noise (the periodic timeline, below) - never the
    # one line that actually says why: Steam waiting on the user (a EULA/launch-option/cloud-save dialog) or
    # offline/logging in. Both read straight from Steam's own logs, no guessing.
    echo "     waiting for user response: $(tail -n +$((cl + 1)) "$S/logs/console_log.txt" 2>/dev/null | grep -i 'waiting for user response' | tail -3 | cut -c1-150 | tr '\n' '|')"
    echo "     connection: $(tail -2 "$S/logs/connection_log.txt" 2>/dev/null | cut -c1-150 | tr '\n' '|')"
    # A Steam dialog up (ABZU 09:45: "Steam Dialog" 700x480 the whole time, no launch): its picture, once, for the
    # Mac side to pull (bf-coldstart.sh copies /tmp/bf-cold-dialog into the artefacts).
    # (not `xwininfo | grep -q`: grep -q closes the pipe early, xwininfo dies of SIGPIPE, pipefail says no match)
    xw=$(xwininfo -root -tree 2>/dev/null)
    if [ -z "${dialog_grabbed:-}" ] && [[ $xw == *'"Steam Dialog"'* ]]; then
      dialog_grabbed=1; rm -rf /tmp/bf-cold-dialog; xframes grab "Steam Dialog" 1 /tmp/bf-cold-dialog >/dev/null 2>&1
      echo "     Steam Dialog grabbed: $(ls /tmp/bf-cold-dialog 2>/dev/null | tr '\n' ' ')"; fi
    echo "     downloading: $(ls "$S/steamapps/downloading" 2>/dev/null | tr '\n' ' ') content_log: $(tail -2 "$S/logs/content_log.txt" 2>/dev/null | cut -c1-150 | tr '\n' '|')"
  fi
  if [ -n "$(iscript_reapers)" ] && [ "$now_" -gt 60000 ]; then
    echo "     install script: $(for q in $(for e in $(iscript_reapers); do tree "$e"; done); do c=$(tr '\0' ' ' < /proc/$q/cmdline 2>/dev/null) || continue
      case $c in *reaper*|*steam-launch-wrapper*|*pressure-vessel*|*pv-adverb*|*_v2-entry-point*) continue ;; esac
      printf '%s[%s %ss] ' "$(printf '%s' "$c" | sed -E 's|^[^ ]*[\\/]([^\\/ ]+)|\1|' | cut -c1-80)" "$(awk '{print $3}' /proc/$q/stat 2>/dev/null)" "$(awk '{printf "%.0f", ($14+$15)/100}' /proc/$q/stat 2>/dev/null)"; done | cut -c1-1400)"
    echo "     X windows: $(xwininfo -root -tree 2>/dev/null | sed -nE 's/^ +0x[0-9a-f]+ "([^"]+)".* ([0-9]+x[0-9]+)\+.*/\1 \2/p' | sort | uniq -c | sort -rn | head -12 | awk '{$1=$1; print}' | tr '\n' '|')"
  fi
}
cs_poll_launch() {
  local now_ r=0 x k=-1 stacks=0
  # 400 s cold (Steam's start, maybe a depot download); 150 s warm (~35 s expected): past that it is Steam's
  # freeze/thaw hanging the launch (INVALID below), and the check stays inside its 300 s budget to say so.
  for _ in $(seq $([ $v = cold ] && echo 1600 || echo 600)); do
    now_=$(ms "$t0" "$(now)"); i=$((i + 1))
    # The queue kills a job at 300 s: stop waiting at COLD_WAIT_MS (265 s) so a launch that never shows a window still
    # gets its HANG lines, STAGES and the restore below (2026-10-23 08:08: killed mid-wait, none of them printed).
    [ $v = cold ] && [ "$now_" -gt "${COLD_WAIT_MS:-265000}" ] && break
    # A running Steam logs the URL at once (ExecCommandLine): stage "handoff" = when it did. A new client's "Client
    # version" = Steam was restarted for the launch (what pkgrel 24-27 did; the hand-off works since pkgrel 28's
    # sysvipc fix): FAIL restart below. Nothing in 20 s = the hand-off was lost (bf-lib handoff_detail says where).
    if [ "$up" = 1 ]; then
      case $(tail -c +$((cb + 1)) "$S/logs/console_log.txt" 2>/dev/null) in
        *"Client version"*) first restart "$now_"; up= ;;
        *"rungameid/$APP"*) first handoff_ms "$now_"; up= ;;
        *) if [ $i = 80 ]; then seen[handoff]=lost; echo "   handoff lost: $(handoff_diag)"; handoff_detail | sed 's/^/   /'; break; fi ;;
      esac
    fi
    [ -n "$(pgrep -f 'steamwebhelper' | head -1)" ] && first steam "$now_"
    # A depot swap (cfg:native / back): Steam downloads before the launch.
    if [ -d "$S/steamapps/downloading/$APP" ]; then first update "$now_"; elif [ -n "${seen[update]:-}" ]; then first update_end "$now_"; fi
    if [ -n "$(iscript_reapers)" ]; then first iscript "$now_"; elif [ -n "${seen[iscript]:-}" ]; then first iscript_end "$now_"; fi
    r=$(reaper); [ -n "$r" ] && first reaper "$now_"
    # Every new process under the launch's reapers (the evaluator's too), once, with its time: where the seconds go
    # between the stages (2026-10-23 cold: the evaluator's chain showed nothing for 21 s before pressure-vessel's ldconfig).
    ps -e -o pid=,ppid=,args= 2>/dev/null | awk -v r=" $(pgrep -f "SteamLaunch AppId=$APP( |\$)" | tr '\n' ' ') " -v t="$now_" '
      {pp[$1] = $2; a = $0; sub(/^ *[0-9]+ +[0-9]+ +/, "", a); args[$1] = a}
      END {for (p in pp) {q = p; for (i = 0; i < 40 && q > 1; i++) {if (index(r, " " q " ")) {print p "\t" t "\t" substr(args[p], 1, 110); break}; q = pp[q]}}}' \
      >> "$T/timeline"
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
    [ $((i % 120)) = 119 ] && cs_poll_diag
    # The exe up 45 s / 90 s and still no window: where its busiest thread is (two samples: a loop or progress).
    if [ -n "${seen[exe]:-}" ] && [ $stacks -lt 2 ] && [ $((now_ - ${seen[exe]})) -gt $((45000 * (stacks + 1))) ]; then
      x=$(for q in $(tree "$r"); do tr '\0' ' ' < /proc/$q/cmdline 2>/dev/null | grep -qF "common/$IDIR/" && echo $q; done | tail -1)
      stacks=$((stacks + 1)); [ -n "$x" ] && { echo "   at ${now_} ms, exe up $((now_ - ${seen[exe]})) ms, no window:"; hang_stack "$x" | sed 's/^/     /'; }
    fi
    [ ${#seen[@]} != $k ] && k=${#seen[@]} && case " ${!seen[*]} " in
      *" exe "*) pill "cold start timing: $v - game starting" ;; *" wineserver "*) pill "cold start timing: $v - wine" ;;
      *" container "*) pill "cold start timing: $v - pressure-vessel" ;; *" reaper "*) pill "cold start timing: $v - launching" ;;
      *" iscript "*) pill "cold start timing: $v - install script" ;; *) pill "cold start timing: $v - Steam" ;; esac
    touched; sleep 0.25
  done
}
# cs_no_window_evidence: a launch that started but showed no window - where its process stands, Steam's stdout,
# and (f89) whether it's stuck waiting on a Steam dialog rather than actually hung. Split out of run() to keep it
# under the length budget (test-complexity.sh) - reads run()'s locals (v is unused here, IDIR/cl/S/T are globals).
cs_no_window_evidence() {
  # Started but no window: where its process stands, before the close kills it (native Broforce 2026-10-23: exe at
  # 41 s, then nothing for 4 min and no Player.log).
  for q in $(tree "$(reaper)"); do tr '\0' ' ' < /proc/$q/cmdline 2>/dev/null | grep -qF "common/$IDIR/" && echo $q; done | tail -2 \
    | while read -r q; do echo "   HANG $(hang_diag "$q")"; done
  # Steam's stdout (open-task started it) carries the game's own stdout/stderr too: the player's / FEX's last words.
  for f in $(find /tmp -maxdepth 1 -name 'fex-game-*.log' -newer /tmp/bf-cold-mark 2>/dev/null | head -2); do echo "   FEX log $f ($(wc -l < "$f") lines), last:"; tail -15 "$f" | cut -c1-200 | sed 's/^/   | /'; done
  echo "   game output (Steam's stdout, last lines):"; grep -a -v -E 'LD_PRELOAD|^\s*$|steamwebhelper|cef_|chromium|SlowJSMethodCall' "$T/open.out" 2>/dev/null \
    | tail -25 | cut -c1-200 | sed 's/^/   | /'
  # f89: Steam's own stdout is mostly SlowJSMethodCall noise (the grep above drops it, but a launch waiting on a
  # Steam dialog can leave nothing else there) - print the actual "waiting for user response" lines and the
  # connection state too, or a launch stuck on a Steam prompt reads exactly like a dropped forward.
  echo "   console_log (waiting for user response, since the tap): $(tail -n +$((cl + 1)) "$S/logs/console_log.txt" 2>/dev/null | grep -i 'waiting for user response' | tail -6 | cut -c1-150 | tr '\n' '|')"
  echo "   connection_log (latest state): $(tail -3 "$S/logs/connection_log.txt" 2>/dev/null | cut -c1-150 | tr '\n' '|')"
}
run() {  # run <variant> <n>
  local v=$1 t0 st
  declare -gA seen=()
  cs_ready_steam "$v"
  [ $v = fexcache ] && fexcache_on
  st="steam $([ -d "/proc/$(steam_pid)" ] && { [ -n "$(cg)" ] && echo frozen || echo awake; } || echo off), wineserver $(pgrep -c wineserver)"
  echo "== $v #$2: at the tap: $st; $(sizes)"
  gl=$(wc -l < "$S/logs/gameprocess_log.txt" 2>/dev/null || echo 0) cl=$(wc -l < "$S/logs/console_log.txt" 2>/dev/null || echo 0) i=0
  local cb; cb=$(stat -c %s "$S/logs/console_log.txt" 2>/dev/null || echo 0)
  local up=; [ $v != cold ] && [ -d "/proc/$(steam_pid)" ] && up=1
  mine=1; pill "cold start timing: $v #$2 - tap"; t0=$(now)
  local hl; hl=$(wc -l < "$HYPR" 2>/dev/null || echo 0)
  if [ "${VIA:-drawer}" = steam ]; then
    ( setsid -f steam "steam://rungameid/$APP" >"$T/open.out" 2>&1 </dev/null; echo "none (Steam's own launch, the Library's path)" > "$T/open.status" ) &
  else
    ( open_task 400 "steam_app_$APP" > "$T/open.status" ) &
  fi
  cs_poll_launch
  if [ -n "${seen[restart]:-}" ]; then fail "restart-$v" "the running Steam was restarted for the launch (a new client ${seen[restart]} ms after the tap) instead of taking it"
  fi
  if [ -n "${seen[window]:-}" ]; then
    exported "$v" "$hl" "$W"
    pill "cold start timing: $v - first frame"
    x=$(first_frame 90); [ "$x" != none ] && seen[frame]=$(ms "$t0" "$x")
  elif [ -n "${seen[handoff]:-}" ]; then fail "handoff-$v" "the running Steam didn't log the launch's URL in 20 s (handoff lines above)"
  elif [ -n "${seen[ended]:-}" ]; then fail "start-$v" "the launch chain ended ${seen[ended]} ms after the tap, no window; Steam: $(grep -a 'Game process removed\|exit code' "$S/logs/gameprocess_log.txt" | tail -2 | cut -c1-120 | tr '\n' '|')"
  else
    cs_no_window_evidence
    fail "start-$v" "no window in $([ $v = cold ] && echo $((${COLD_WAIT_MS:-265000} / 1000)) || echo 150) s:$(for k in steam reaper container wineserver exe; do printf '%s=%s ' $k "${seen[$k]:--}"; done)"; fi
  local hv=${seen[handoff_ms]:-${seen[restart]:+restart@${seen[restart]}}}
  echo "STAGES $v #$2 (ms from the tap):$([ $v != cold ] && echo " handoff ${hv:--}") steam-ui ${seen[steam]:--} update ${seen[update]:--}-${seen[update_end]:--} iscript ${seen[iscript]:--}-${seen[iscript_end]:--} reaper ${seen[reaper]:--} pv ${seen[container]:--} wineserver ${seen[wineserver]:--} exe ${seen[exe]:--} window ${seen[window]:--} frame ${seen[frame]:--}; open-task: $(cat "$T/open.status" 2>/dev/null)"
  echo "   timeline (ms from the tap, first sight of each process under the launch; 4 Hz):"
  sort -t$'\t' -k2,2n "$T/timeline" 2>/dev/null | awk -F'\t' '!p[$1]++ && !a[$3]++ {printf "%6s %s\n", $2, $3}' \
    | sed -E 's|/home/powos/.local/share/Steam/|~S/|g' | head -45 | sed 's/^/     /'
  rm -f "$T/timeline"
  echo "   tool: $($CFG get $APP); renderer: $(renderer)"
  echo "   after: $(sizes); evaluator: $(tail -1 "$CD/powos-iscript.log" 2>/dev/null | cut -c1-160)"
  RES_="$RES_ $v#$2 window ${seen[window]:--} frame ${seen[frame]:--};"
  # The per-game compat policy learns from it (powos-steam-compat record): a window = a working launch of this tool;
  # a chain that ended without one = a failed one. Not when Steam downloaded first (the time isn't the tool's).
  # A warm run (Steam left running) without a window says nothing about the tool while Steam's freeze/thaw can hang
  # a launch (2026-10-23 02:53: a frozen Steam never thawed for the launch, no window in 394 s; 02:58: never frozen):
  # INVALID, not a failed way - re-queue it once unified sleep's fix is in. Only a cold run's failure counts.
  if [ -z "${seen[window]:-}" ] && [ $v != cold ]; then
    echo "INVALID $v #$2: no window on a warm Steam (at the tap: $st; Steam's cgroup now '$(cg)'$([ -n "${seen[handoff]:-}" ] && echo "; Steam never took the URL")) - Steam's hand-off, not the tool; not recorded"
  elif [ -z "${seen[update]:-}" ]; then
    if [ -n "${seen[window]:-}" ]; then echo "   policy: $($CFG record $APP "${seen[window]}" $([ $v = cold ] && echo --cold))"
    elif [ -n "${seen[ended]:-}" ]; then echo "   policy: $($CFG record $APP fail)"; fi
  fi
  [ $v = fexcache ] && { echo "   FEX wrote: $(find "$CD/fex-emu" ~/.local/share/fex-emu ~/.cache -newer /tmp/bf-cold-mark -type f 2>/dev/null | grep -vi telemetry | head -8 | tr '\n' ' ')"; fexcache_off; }
  sleep 5
}
# fetch: what the setup needs from Steam's servers (a depot swap after cfg:native/back, a runtime), untimed: a launch,
# kept until Steam's download is done (steamapps/downloading/<id> came and went) or a window shows, then closed. A
# timed run after it measures the launch only (2026-10-23 05:03: cfg:native cold spent its 300 s on the depot).
fetch() {
  local i seen_dl=
  pill "fetching what $GAME needs (untimed)"; bash /var/tmp/powos-bf-stop.sh --steam | head -1
  mine=1; ( open_task 270 "steam_app_$APP" > "$T/open.status" ) &
  for i in $(seq 260); do
    [ -d "$S/steamapps/downloading/$APP" ] && seen_dl=1
    [ -n "$seen_dl" ] && [ ! -d "$S/steamapps/downloading/$APP" ] && break
    W=$(gamewin); [ -n "$W" ] && [ "$(mapped "$W")" = IsViewable ] && break
    touched; sleep 1
  done
  echo "FETCH: $([ -n "$seen_dl" ] && echo "downloaded" || echo "nothing to download"), ${i} s; $(grep -a "$APP" "$S/logs/content_log.txt" | tail -1 | cut -c1-120)"
  close_game
}
touch /tmp/bf-cold-mark; RES_=""
echo "== $(date +%T) $(pacman -Q steam), FEX $(head -1 "$F/VERSIONS.txt" 2>/dev/null)"
powos sleep never --remove steam >/dev/null 2>&1
n=0
[ $# -gt 0 ] || set -- cold steam fexcache fexcache
for v in "$@"; do
  case $v in keep) KEEP=1; continue ;; fetch) fetch; continue ;; via:*) VIA=${v#via:}; echo "== launch via $VIA"; continue ;; cfg:* | opt:* | env:*) setup "$v" || break; continue ;; esac
  n=$((n + 1)); run "$v" "$n"
  if [ "$v" = fexcache ]; then
    pill "FEX: compiling the code cache"
    close_game; ( cd "$CD" && FEX_PORTABLE=1 FEX_APP_CONFIG_LOCATION="$CD/fex-emu/" timeout 300 "$F/usr/bin/FEXOfflineCompiler" process-all 2>&1 | tail -3 )
  fi
done
close_mine; restore; rm -f /tmp/bf-cold-mark
echo "RESULT bf-coldstart: ${FAILS:+FAIL$FAILS - }$RES_"
[ -z "$FAILS" ]
