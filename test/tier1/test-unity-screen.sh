#!/bin/bash
# test-unity-screen.sh - Tier-1 tests for targets/android/steam/unity-screen (a Unity game's Steam launch option): the
# Unity player arguments it appends. G2: a borderless WINDOWED player (-screen-fullscreen 0 -popupwindow) at the
# container's size, so KWin's resize of the window on a rotate/fold re-renders the game live (windowed Unity's render
# size = its client area); POWOS_UNITY_SCREEN=fullscreen keeps the old full-screen launch; no size -> unchanged.
# With Xvfb + libX11 present (not in the tier-1 image) it also reads a real root _POWOS_SCREEN_SIZE end to end.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
US="$SCRIPT_DIR/../../targets/android/steam/unity-screen"
PASS=0; FAIL=0
ok()  { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL - $1${2:+ ($2)}"; FAIL=$((FAIL+1)); }
echo "== test-unity-screen.sh =="

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
# The game: prints its argv, one per line.
printf '#!/bin/sh\nfor a in "$@"; do echo "$a"; done\n' > "$T/game"; chmod +x "$T/game"
# A python3 that answers the size query the way the libX11 snippet does (the container 2268x2440).
printf '#!/bin/sh\necho "${FAKE_SIZE-2268 2440}"\n' > "$T/bin/python3"; chmod +x "$T/bin/python3"

args() { tr '\n' ' ' < "$T/out" | sed 's/ $//'; }

PATH="$T/bin:$PATH" DISPLAY=:9 sh "$US" "$T/game" -logFile x > "$T/out" 2> "$T/err"
[ "$(args)" = "-logFile x -screen-fullscreen 0 -popupwindow -screen-width 2268 -screen-height 2440" ] \
  && ok "default: borderless window at the container size (follows its task live)" || bad "default args" "$(args)"
grep -q "borderless window 2268x2440" "$T/err" && ok "says the mode and size" || bad "stderr" "$(cat "$T/err")"

PATH="$T/bin:$PATH" DISPLAY=:9 FAKE_SIZE="2440 2268" sh "$US" "$T/game" > "$T/out" 2>/dev/null
[ "$(args)" = "-screen-fullscreen 0 -popupwindow -screen-width 2440 -screen-height 2268" ] \
  && ok "landscape size passes through" || bad "landscape args" "$(args)"

PATH="$T/bin:$PATH" DISPLAY=:9 POWOS_UNITY_SCREEN=fullscreen sh "$US" "$T/game" > "$T/out" 2>/dev/null
[ "$(args)" = "-screen-fullscreen 1 -screen-width 2268 -screen-height 2440" ] \
  && ok "POWOS_UNITY_SCREEN=fullscreen: the old full-screen launch" || bad "fullscreen args" "$(args)"

PATH="$T/bin:$PATH" DISPLAY=:9 FAKE_SIZE="" sh "$US" "$T/game" -a > "$T/out" 2>/dev/null
[ "$(args)" = "-a" ] && ok "no size: starts unchanged" || bad "no-size args" "$(args)"

# The Steam overlay: dropped from the game's LD_PRELOAD (the rest kept) unless POWOS_STEAM_OVERLAY=1.
printf '#!/bin/sh\necho "$LD_PRELOAD|${ENABLE_VK_LAYER_VALVE_steam_overlay_1:-}"\n' > "$T/env"; chmod +x "$T/env"
OV="/home/u/.steam/ubuntu12_32/gameoverlayrenderer.so:/home/u/.steam/ubuntu12_64/gameoverlayrenderer.so"
env -u DISPLAY LD_PRELOAD="/x/libfoo.so:$OV" ENABLE_VK_LAYER_VALVE_steam_overlay_1=1 sh "$US" "$T/env" > "$T/out" 2> "$T/err"
[ "$(cat "$T/out")" = "/x/libfoo.so|" ] && ok "overlay dropped from LD_PRELOAD, its Vulkan layer off" || bad "overlay strip" "$(cat "$T/out")"
grep -q "Steam overlay off" "$T/err" && ok "says the overlay is off" || bad "overlay stderr" "$(cat "$T/err")"
env -u DISPLAY LD_PRELOAD="$OV" POWOS_STEAM_OVERLAY=1 ENABLE_VK_LAYER_VALVE_steam_overlay_1=1 sh "$US" "$T/env" > "$T/out" 2>/dev/null
[ "$(cat "$T/out")" = "$OV|1" ] && ok "POWOS_STEAM_OVERLAY=1 keeps it" || bad "overlay kept" "$(cat "$T/out")"

env -u DISPLAY PATH="$T/bin:$PATH" sh "$US" "$T/game" -a > "$T/out" 2>/dev/null
[ "$(args)" = "-a" ] && ok "no DISPLAY: starts unchanged" || bad "no-display args" "$(args)"

# Unreal: an Engine/Binaries folder beside the exe (ABZU) or the exe under <Project>/Binaries/Win64 -> -windowed -ResX/-ResY.
mkdir -p "$T/ue/Engine/Binaries" "$T/ue2/Proj/Binaries/Win64" "$T/un/G_Data"
cp "$T/game" "$T/ue/AbzuGame.exe"; cp "$T/game" "$T/ue2/Proj/Binaries/Win64/Proj-Win64-Shipping.exe"; cp "$T/game" "$T/un/G.exe"
PATH="$T/bin:$PATH" DISPLAY=:9 sh "$US" "$T/ue/AbzuGame.exe" > "$T/out" 2> "$T/err"
[ "$(args)" = "-windowed -ResX=2268 -ResY=2440" ] && ok "Unreal (Engine/ at the root): -windowed -ResX/-ResY" || bad "unreal args" "$(args)"
grep -q "Unreal window 2268x2440" "$T/err" && ok "says Unreal" || bad "unreal stderr" "$(cat "$T/err")"
PATH="$T/bin:$PATH" DISPLAY=:9 sh "$US" "$T/ue2/Proj/Binaries/Win64/Proj-Win64-Shipping.exe" > "$T/out" 2>/dev/null
[ "$(args)" = "-windowed -ResX=2268 -ResY=2440" ] && ok "Unreal (exe under Binaries/Win64)" || bad "unreal2 args" "$(args)"
PATH="$T/bin:$PATH" DISPLAY=:9 sh "$US" "$T/un/G.exe" > "$T/out" 2>/dev/null
[ "$(args)" = "-screen-fullscreen 0 -popupwindow -screen-width 2268 -screen-height 2440" ] && ok "a Unity exe: Unity arguments" || bad "unity exe args" "$(args)"

# End to end with a real X server: the root's _POWOS_SCREEN_SIZE (kwin 0051) wins over the root size.
if command -v Xvfb >/dev/null && command -v xprop >/dev/null && command -v python3 >/dev/null; then
  Xvfb :93 -screen 0 1116x2358x24 -noreset >/dev/null 2>&1 & XP=$!
  for _ in $(seq 50); do DISPLAY=:93 xprop -root >/dev/null 2>&1 && break; sleep 0.1; done
  DISPLAY=:93 xprop -root -f _POWOS_SCREEN_SIZE 32c -set _POWOS_SCREEN_SIZE "2268, 2440"
  DISPLAY=:93 sh "$US" "$T/game" > "$T/out" 2>/dev/null
  [ "$(args)" = "-screen-fullscreen 0 -popupwindow -screen-width 2268 -screen-height 2440" ] \
    && ok "Xvfb: root _POWOS_SCREEN_SIZE 2268x2440 over the 1116x2358 root" || bad "Xvfb args" "$(args)"
  kill "$XP" 2>/dev/null; wait "$XP" 2>/dev/null
else
  echo "  skip - Xvfb end-to-end (no Xvfb/xprop here)"
fi

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
