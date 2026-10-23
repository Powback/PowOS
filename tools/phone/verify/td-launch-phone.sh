#!/bin/bash
# td-launch-phone.sh <variant>...: (in the PowOS session as powos; td-launch.sh pushes and runs it) one Teardown
# (1167630) cold launch per variant, with every log on: Steam's stdout/stderr (pressure-vessel, Proton, Wine) to a
# file, PROTON_LOG=1 (~/steam-1167630.log), timed by stage from 4 Hz process samples (tap -> reaper -> pv-adverb ->
# wineserver -> teardown.exe -> its X window -> its first new frame). Variants = the Proton Teardown runs on (Steam's
# CompatToolMapping, set in config.vdf with Steam off):
#   arm64  "Proton Experimental (ARM64)": Wine itself native, x86 code through FEX's arm64ec/wow64 DLLs, DXVK/VKD3D native
#          on PowOS's own Turnip (pressure-vessel imports the host driver)
#   x86    "Proton Experimental" x86 under Valve's FEX compat tool (Broforce's path): Wine, DXVK/VKD3D and Turnip all x86
# The mapping found at the start is put back at the end unless KEEP=<variant> (then that one stays). Logs go to
# /tmp/td-logs/<variant>/ (td-launch.sh pulls them). "STAGES <variant> ..." lines, RESULT last.
set -uo pipefail
APP=1167630 GAME=Teardown WIN_NAME=Teardown
. /var/tmp/powos-bf-lib.sh
S=$HOME/.local/share/Steam CFG=$S/config/config.vdf L=/tmp/td-logs
LAUNCH_S=${LAUNCH_S:-600}  # a first arm64 launch also downloads Steam Linux Runtime 4.0 (arm64)
declare -A TOOL=([arm64]=proton-experimental-arm64 [x86]=proton_experimental)
declare -A PDIR=([arm64]="Proton Experimental (ARM64)" [x86]="Proton - Experimental")
first() { [ -n "${seen[$1]:-}" ] || seen[$1]=$2; }
mapping() { python3 - "$CFG" "$APP" "${1:-}" <<'PY'
import re, sys
p, app, new = sys.argv[1:4]
s = open(p).read()
i = s.index('"CompatToolMapping"')
m = re.compile(r'("%s"\s*\{\s*"name"\s*")([^"]*)(")' % app).search(s, i)
if not new:
    print(m.group(2) if m else ""); sys.exit()
if m:
    s = s[:m.start(2)] + new + s[m.end(2):]
else:  # no entry yet: one like Steam's own
    j = s.index("{", i) + 1
    s = s[:j] + '\n\t\t\t\t\t"%s"\n\t\t\t\t\t{\n\t\t\t\t\t\t"name"\t\t"%s"\n\t\t\t\t\t\t"config"\t\t""\n\t\t\t\t\t\t"priority"\t\t"250"\n\t\t\t\t\t}' % (app, new) + s[j:]
open(p + ".td", "w").write(s)
PY
  [ -z "${1:-}" ] || mv -f "$CFG.td" "$CFG"; }
steam_off() { pill "Teardown check: closing Steam"; APP=$APP bash /var/tmp/powos-bf-stop.sh --steam | head -1
  for _ in $(seq 20); do [ -d "/proc/$(steam_pid)" ] || break; sleep 0.5; done; }
# The logging settings go in ~/.config/powos/proton-settings.json, which PowOS's own user_settings.py (pkgs/steam: the
# install-script evaluator skip) reads - never over or instead of that file (it removed it, 2026-10-23).
logs_off() { rm -f ~/.config/powos/proton-settings.json; }
restore() { logs_off; [ -n "${ORIG:-}" ] && [ "$(mapping)" != "$ORIG" ] && { steam_off; mapping "$ORIG"; echo "mapping put back: $ORIG"; }; ORIG=; }
ON_CLOSE=restore
run() {  # run <variant> <n>
  local v=$1 t0 now_ r x k=-1 gl d=$L/$1 p
  declare -gA seen=()
  [ -n "${TOOL[$v]:-}" ] || { fail "variant-$v" "unknown variant (arm64 | x86)"; return; }
  rm -rf "$d"; mkdir -p "$d"
  steam_off; mapping "${TOOL[$v]}"
  p="$S/steamapps/common/${PDIR[$v]}"
  [ -x "$p/proton" ] || { fail "start-$v" "$p has no proton (not installed)"; return; }
  mkdir -p ~/.config/powos
  printf '{"PROTON_LOG": "1", "PROTON_LOG_DIR": "%s", "WINEDEBUG": "+loaddll,+seh,err+all,warn+module", "DXVK_LOG_LEVEL": "info", "VKD3D_DEBUG": "warn", "VKD3D_SHADER_DEBUG": "fixme"}\n' "$d" > ~/.config/powos/proton-settings.json
  [ -f "$p/user_settings.py" ] || echo "   note: $p has no PowOS user_settings.py - the log settings won't apply there" 
  echo "== $v #$2: mapping $(mapping), $(cat "$p/version"), FEX $(head -1 "$S/steamapps/common/FEX-Emu/VERSIONS.txt" 2>/dev/null)"
  gl=$(wc -l < "$S/logs/gameprocess_log.txt" 2>/dev/null || echo 0)
  powos sleep never steam >/dev/null 2>&1
  mine=1; pill "Teardown $v #$2: tap"; t0=$(now)
  ( cd "$HOME" && exec setsid steam steam://rungameid/$APP > "$d/steam.out" 2>&1 < /dev/null ) &
  for _ in $(seq $((LAUNCH_S * 4))); do
    now_=$(ms "$t0" "$(now)")
    r=$(reaper); [ -n "$r" ] && first reaper "$now_"
    # Ended = Steam's own word only (a cold Steam first runs the install script evaluator through the same chain).
    [ -z "$r" ] && [ -n "${seen[reaper]:-}" ] && tail -n +$((gl + 1)) "$S/logs/gameprocess_log.txt" | grep -q "Remove $APP from running list" \
      && { seen[ended]=$now_; break; }
    pgrep -f pv-adverb >/dev/null && first container "$now_"
    pgrep -f wineserver >/dev/null && first wineserver "$now_"
    [ -n "${seen[wineserver]:-}" ] && pgrep -f 'teardown.exe' | while read -r x; do ! grep -qa 'proton\|reaper\|python\|pressure-vessel\|steam-launch-wrapper' "/proc/$x/cmdline" && echo y; done | grep -q y && first exe "$now_"
    W=$(gamewin); [ -n "$W" ] && [ "$(mapped "$W")" = IsViewable ] && { first window "$now_"; break; }
    [ ${#seen[@]} != $k ] && k=${#seen[@]} && pill "Teardown $v: $(for s in reaper container wineserver exe; do [ -n "${seen[$s]:-}" ] && last=$s; done; echo "${last:-Steam}")"
    touched; sleep 0.25
  done
  if [ -n "${seen[window]:-}" ]; then
    x=$(first_change "$W" 30 10); [ "$x" != none ] && seen[frame]=$(ms "$t0" "$x")
    pill "Teardown $v: running 30 s"; sleep 30; touched
    ffmpeg -nostdin -loglevel error -f x11grab -window_id "$W" -i "$DISPLAY" -frames:v 1 -y "$d/window.png" 2>/dev/null
    echo "   window $W $(xwininfo -id "$W" | awk '/Width|Height/ {printf "%s ", $2}'), alive: $(pgrep -fc teardown.exe) teardown.exe"
  elif [ -n "${seen[ended]:-}" ]; then fail "start-$v" "the launch chain ended ${seen[ended]} ms after the tap, no window"
  else fail "start-$v" "no window in $LAUNCH_S s:$(for s in reaper container wineserver exe; do printf ' %s=%s' $s "${seen[$s]:--}"; done)"; fi
  echo "STAGES $v #$2 (ms from the tap): reaper ${seen[reaper]:--} pv ${seen[container]:--} wineserver ${seen[wineserver]:--} exe ${seen[exe]:--} window ${seen[window]:--} frame ${seen[frame]:--} ended ${seen[ended]:--}"
  RES_="$RES_ $v window ${seen[window]:--} frame ${seen[frame]:--};"
  # Evidence, before the close kills anything: what Steam, pressure-vessel, Proton and Wine said.
  tail -n +$((gl + 1)) "$S/logs/gameprocess_log.txt" > "$d/gameprocess.txt"
  tail -n 400 "$S/logs/console_log.txt" > "$d/console.txt"; tail -n 60 "$S/logs/compat_log.txt" > "$d/compat.txt"
  ls -t /tmp/fex-compat-tool-*.log 2>/dev/null | head -3 | xargs -r cp -t "$d/" 2>/dev/null
  ls -lt --time-style=+%T "$S/steamapps/compatdata/$APP/fex-emu/Telemetry" 2>/dev/null | head -12 > "$d/fex-telemetry.txt"
  echo "   --- Steam stdout (pressure-vessel / Proton / Wine), the lines that matter:"
  grep -a -i -E 'error|fail|abort|crash|segv|signal|unhandled|not found|cannot|unable|err:|vkd3d|dxvk|vulkan|D3D12|pressure-vessel|pv-|proton|wine' "$d/steam.out" \
    | grep -v -E 'SlowJSMethodCall|steamwebhelper|cef_|chromium' | tail -40 | cut -c1-240 | sed 's/^/   | /'
  for x in "$d"/steam-$APP.log; do [ -f "$x" ] || continue
    echo "   --- $(basename "$x") ($(wc -l < "$x") lines): err/crash lines"
    grep -a -E 'err:|Unhandled|EXCEPTION|page fault|wine: |fixme:vkd3d|vkd3d|dxvk|D3D12|Vulkan|exited|Exited' "$x" | grep -v -E 'Loaded L"|loaddll' | sort | uniq -c | sort -rn | head -30 | cut -c1-240 | sed 's/^/   | /'
    echo "   --- last 25 lines:"; tail -25 "$x" | cut -c1-240 | sed 's/^/   | /'
  done
  [ -f "$d/steam-$APP.log" ] || echo "   no PROTON_LOG file: Proton's script never ran"
  sleep 3
}
RES_=""; ORIG=$(mapping)
echo "== $(date +%T) Teardown launch check, $(pacman -Q steam), mapping at start: ${ORIG:-none}"
[ $# -gt 0 ] || set -- arm64 x86
n=0
for v in "$@"; do n=$((n + 1)); run "$v" "$n"; done
[ -n "${KEEP:-}" ] && [ -n "${TOOL[$KEEP]:-}" ] && { steam_off; mapping "${TOOL[$KEEP]}"; ORIG=; echo "mapping kept: ${TOOL[$KEEP]}"; }
close_mine
echo "RESULT td-launch: ${FAILS:+FAIL$FAILS - }$RES_"
[ -z "$FAILS" ]
