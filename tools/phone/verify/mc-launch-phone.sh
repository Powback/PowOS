#!/bin/bash
# mc-launch-phone.sh [variant]...: (in the PowOS session as powos; mc-launch.sh pushes and runs it) Minecraft launches
# of the PowStation pack through its real path - powos-open-task (the drawer's) -> powos-minecraft launch (pack sync)
# -> Prism Launcher -> Java -> NeoForge -> title screen - each in a TEST Prism root (~/.cache/powos-verify/mc-root:
# an offline test profile, no server join; the user's own Prism dir, account and instance untouched).
# Variants = the game's GL setup (the phone's Mesa): base (freedreno GL 4.3 on KGSL), zink (GL 4.6 on Turnip),
# glthread / zink-glthread (+ mesa_glthread). Per variant: STAGES (ms from the tap: prism, java, window = NeoForge's
# early window, title = ModernFix's "Game took"), fps on the title screen (Gallium HUD dump, 1 s samples), the game's
# RSS / GC heap, a frame of its window; then the game is closed. A Minecraft the user runs: skipped (exit 3).
# Logs: /tmp/mc-logs/<variant>/ (mc-launch.sh pulls them).
set -uo pipefail
APP=0 . /var/tmp/powos-bf-lib.sh
R=$HOME/.cache/powos-verify/mc-root
OUT=/tmp/mc-logs; rm -rf "$OUT"; mkdir -p "$OUT"
LAUNCH_S=${LAUNCH_S:-240}   # tap -> title screen, at most (first run: Prism downloads Minecraft + NeoForge's install)
FPS_S=${FPS_S:-20}
PACK=${PACK:-create121}
variants=("$@"); [ ${#variants[@]} -gt 0 ] || variants=(base)
GAME_DIR=$R/instances/$PACK/minecraft

# The test profile: Prism launches with an offline account in this root only (the user signs in with Microsoft in
# their own Prism dir; this one never joins a server).
mkdir -p "$R"
[ -f "$R/accounts.json" ] || cat > "$R/accounts.json" <<'JSON'
{"formatVersion": 3, "accounts": [{"type": "Offline", "active": true,
  "ygg": {"token": "0", "extra": {"userName": "PowOSTest", "clientToken": "00000000000000000000000000000000"}, "iat": 0},
  "profile": {"id": "6f4c8b0e5e0a4b7f9b0c1d2e3f405162", "name": "PowOSTest", "capes": [], "skin": {"id": "", "url": "", "variant": ""}},
  "entitlement": {"ownsMinecraft": true, "canPlayMinecraft": true}}]}
JSON

game_java() {  # the java of a Minecraft instance: $1 = its game dir (or "other" = any not under $R)
  local p c
  for p in $(pgrep -f 'java .*(net.neoforged|cpw.mods|org.prismlauncher|EntryPoint)'); do
    c=$(readlink "/proc/$p/cwd" 2>/dev/null) || continue
    if [ "$1" = other ]; then case $c in "$R"/*) ;; *) echo "$p"; return ;; esac
    elif [ "$c" = "$1" ]; then echo "$p"; return; fi
  done; }
u=$(game_java other); [ -n "$u" ] && { echo "Minecraft is running (pid $u, not this check's): skipped"; exit 3; }

stop_game() {
  local j; j=$(game_java "$GAME_DIR")
  [ -n "$j" ] && { kill -TERM "$j"; for _ in $(seq 20); do kill -0 "$j" 2>/dev/null || break; sleep 0.5; done; kill -KILL "$j" 2>/dev/null; }
  pkill -TERM -f "prismlauncher --dir $R" 2>/dev/null; sleep 1; pkill -KILL -f "prismlauncher --dir $R" 2>/dev/null; mine=0
}
ON_CLOSE=stop_game
close_mine() { [ $mine = 1 ] && { pill "closing Minecraft (this check started it)"; stop_game; }; rm -f /tmp/powos-verify-step; }

for v in "${variants[@]}"; do
  D=$OUT/$v; mkdir -p "$D/hud"
  {
    case $v in
      base) ;;
      zink) echo "MESA_LOADER_DRIVER_OVERRIDE=zink"; echo "GALLIUM_DRIVER=zink" ;;
      glthread) echo "mesa_glthread=true" ;;
      zink-glthread) echo "MESA_LOADER_DRIVER_OVERRIDE=zink"; echo "GALLIUM_DRIVER=zink"; echo "mesa_glthread=true" ;;
      *) echo "FAIL $v: unknown variant" >&2; continue ;;
    esac
    echo "GALLIUM_HUD=fps"; echo "GALLIUM_HUD_PERIOD=1"; echo "GALLIUM_HUD_DUMP_DIR=$D/hud"
    echo "JAVA_TOOL_OPTIONS=-Xlog:gc:file=$D/gc.log"
  } > "$D/env"
  export POWOS_MINECRAFT_ENV=$D/env
  echo "== $v: $(grep -v -e GALLIUM_HUD -e JAVA_TOOL "$D/env" | tr '\n' ' ')"
  pill "Minecraft $v: syncing the pack"
  s0=$(now)
  powos-minecraft sync "$PACK" --root "$R" --no-join --quiet 2> "$D/sync.log"; rc=$?
  echo "sync $(ms "$s0" "$(now)") ms: $(tail -1 "$D/sync.log")"
  [ $rc = 0 ] || { fail "$v" "sync failed: $(tail -3 "$D/sync.log" | tr '\n' ' ')"; continue; }
  rm -f "$GAME_DIR/logs/latest.log"
  pill "Minecraft $v: launching"
  t0=$(now); mine=1
  setsid powos-open-task --app-id dev.powos.minecraft -- powos-minecraft launch "$PACK" --root "$R" --no-join \
    > "$D/launch.log" 2>&1 < /dev/null &
  tp="" tj="" tw="" tt="" jp="" win=""
  while [ "$(ms "$t0" "$(now)")" -lt $((LAUNCH_S * 1000)) ]; do
    touched
    [ -z "$tp" ] && pgrep -f "prismlauncher --dir $R" >/dev/null && tp=$(ms "$t0" "$(now)")
    [ -z "$jp" ] && jp=$(game_java "$GAME_DIR") && [ -n "$jp" ] && { tj=$(ms "$t0" "$(now)"); pill "Minecraft $v: Java up, loading mods"; }
    if [ -n "$jp" ] && [ -z "$tw" ]; then
      win=$(xdotool search --onlyvisible --pid "$jp" 2>/dev/null | head -1)
      [ -n "$win" ] && tw=$(ms "$t0" "$(now)")
    fi
    if [ -n "$jp" ] && grep -q "Game took .* seconds to start" "$GAME_DIR/logs/latest.log" 2>/dev/null; then
      tt=$(ms "$t0" "$(now)"); break
    fi
    if [ -n "$jp" ] && ! kill -0 "$jp" 2>/dev/null; then fail "$v" "the game exited during the load"; break; fi
    [ -z "$jp" ] && [ -n "$tp" ] && ! pgrep -f "prismlauncher --dir $R" >/dev/null && { fail "$v" "Prism exited before the game started"; break; }
    sleep 0.5
  done
  echo "STAGES $v prism ${tp:--} java ${tj:--} window ${tw:--} title ${tt:--} (ms from the tap)"
  grep -h "Game took" "$GAME_DIR/logs/latest.log" 2>/dev/null | tail -1
  [ -n "$tt" ] || fail "$v" "no title screen in ${LAUNCH_S} s"
  if [ -n "$tt" ]; then
    pill "Minecraft $v: title screen, measuring fps"
    sleep 5; : > "$D/rss"
    for _ in $(seq "$FPS_S"); do touched; awk '/VmRSS/{print $2}' "/proc/$jp/status" >> "$D/rss" 2>/dev/null; sleep 1; done
    name=$(xdotool getwindowname "$win" 2>/dev/null)
    [ -n "$name" ] && xframes grab "$name" 1 "$D" >/dev/null 2>&1
    xwininfo -id "$win" 2>/dev/null | grep -E "Width|Height|Map State" | tr -s ' ' | tr '\n' ' ' > "$D/window"; echo >> "$D/window"
    echo "window $win \"$name\" $(cat "$D/window")"
    hud=$(ls "$D"/hud/* 2>/dev/null | head -1)
    if [ -n "$hud" ]; then
      tail -n "$FPS_S" "$hud" | awk -v v="$v" '{x=$NF+0; s+=x; n++; if(min==""||x<min)min=x; if(x>max)max=x} END{if(n) printf "FPS %s title: avg %.1f min %.1f max %.1f (%d s)\n", v, s/n, min, max, n; else print "FPS " v " title: none"}'
    else echo "FPS $v title: no HUD dump"; fi
    awk -v v="$v" '{s+=$1;n++; if($1>m)m=$1} END{if(n) printf "MEM %s rss avg %d MB max %d MB\n", v, s/n/1024, m/1024}' "$D/rss"
    grep -E "Pause (Young|Full)" "$D/gc.log" 2>/dev/null | tail -1 | sed "s/^/GC $v last: /"
    grep -c "Pause Full" "$D/gc.log" 2>/dev/null | sed "s/^/GC $v full pauses: /"
  fi
  cp "$GAME_DIR/logs/latest.log" "$D/latest.log" 2>/dev/null
  ls -t "$GAME_DIR"/crash-reports/* 2>/dev/null | head -1 | xargs -r -I{} cp {} "$D/crash.txt"
  cp "$R/logs/PrismLauncher-0.log" "$D/prism.log" 2>/dev/null
  pill "Minecraft $v: closing"
  stop_game
done
chmod -R a+rX "$OUT"
echo "RESULT ${FAILS:+FAIL$FAILS}${FAILS:-ok}"
