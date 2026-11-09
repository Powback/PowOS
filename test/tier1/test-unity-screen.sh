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
# A python3 that answers the size query the way the libX11 snippet does (the container 2268x2440); the render-scale
# snippet (STEPS in its code) runs on the real python3.
RP=$(command -v python3)
printf '#!/bin/sh\ncase "$2" in *STEPS*) exec %s "$@" ;; esac\necho "${FAKE_SIZE-2268 2440}"\n' "$RP" > "$T/bin/python3"; chmod +x "$T/bin/python3"
export XDG_DATA_HOME="$T/data" HOME="$T/home"; mkdir -p "$T/data/powos" "$T/home"

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

# Render scale (abz-has-low-fps): steam-compat.json "scale" per appid; the record in render-scale/<appid>.json.
st() { printf '%s' "$1" > "$T/data/powos/steam-compat.json"; }
rec() { python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(r.get(sys.argv[2]))' "$T/data/powos/render-scale/$1.json" "$2"; }
st '{"apps": {"274190": {"scale": 70}}}'
PATH="$T/bin:$PATH" DISPLAY=:9 SteamAppId=274190 sh "$US" "$T/game" > "$T/out" 2> "$T/err"
[ "$(args)" = "-screen-fullscreen 1 -screen-width 1586 -screen-height 1708" ] \
  && ok "Unity at 70 %: a full-screen player at 1586x1708, stretched" || bad "unity 70 args" "$(args)" 
grep -q "render scale 70 set" "$T/err" && [ "$(rec 274190 scale)" = 70 ] && ok "says it and records 70" || bad "unity 70 log" "$(cat "$T/err")"
st '{"apps": {}}'
PATH="$T/bin:$PATH" DISPLAY=:9 SteamAppId=274190 sh "$US" "$T/game" > "$T/out" 2> "$T/err"
[ "$(args)" = "-screen-fullscreen 0 -popupwindow -screen-width 2268 -screen-height 2440" ] \
  && ok "Unity, auto, nothing measured: 100 % (the live borderless window)" || bad "unity auto args" "$(args)"
PATH="$T/bin:$PATH" DISPLAY=:9 SteamAppId=274190 POWOS_RENDER_SCALE=off sh "$US" "$T/game" > "$T/out" 2> "$T/err"
! grep -q "render scale" "$T/err" && ok "POWOS_RENDER_SCALE=off: not looked at" || bad "off" "$(cat "$T/err")"

# Unreal: ABZU's own ResolutionScale enum in the prefix's GameUserSettings.ini; auto on 5.5 MP, nothing measured = 70
# -> SCALE_75; then 100 puts the user's value back; a game without that key gets sg.ResolutionQuality.
CD="$T/compat/384190"; INI="$CD/pfx/drive_c/users/steamuser/AppData/Local/AbzuGame/Saved/Config/WindowsNoEditor/GameUserSettings.ini"
mkdir -p "$(dirname "$INI")"
printf '[/Script/AbzuGame.AbzuGameUserSettings]\r\nResolutionScale=SCALE_100\r\nVSync=ON\r\n' > "$INI"
PATH="$T/bin:$PATH" DISPLAY=:9 SteamAppId=384190 STEAM_COMPAT_DATA_PATH="$CD" sh "$US" "$T/ue/AbzuGame.exe" > "$T/out" 2> "$T/err"
[ "$(args)" = "-windowed -ResX=2268 -ResY=2440" ] && grep -q "^ResolutionScale=SCALE_75" "$INI" && grep -q "^VSync=ON" "$INI" \
  && ok "Unreal auto (nothing measured, 5.5 MP): the game's own ResolutionScale=SCALE_75, window still full size" \
  || bad "abzu auto" "$(args) / $(cat "$INI") / $(cat "$T/err")"
grep -q "auto: Unreal at 5.5 MP" "$T/err" && ok "says why (auto, Unreal, MP)" || bad "abzu why" "$(cat "$T/err")"
st '{"apps": {"384190": {"scale": 50}}}'
PATH="$T/bin:$PATH" DISPLAY=:9 SteamAppId=384190 STEAM_COMPAT_DATA_PATH="$CD" sh "$US" "$T/ue/AbzuGame.exe" > /dev/null 2>&1
grep -q "^ResolutionScale=SCALE_50" "$INI" && ok "set 50: SCALE_50" || bad "abzu 50" "$(cat "$INI")"
st '{"apps": {"384190": {"scale": 100}}}'
PATH="$T/bin:$PATH" DISPLAY=:9 SteamAppId=384190 STEAM_COMPAT_DATA_PATH="$CD" sh "$US" "$T/ue/AbzuGame.exe" > /dev/null 2>&1
grep -q "^ResolutionScale=SCALE_100" "$INI" && ok "100: the value before ours (SCALE_100) put back" || bad "abzu restore" "$(cat "$INI")"
sed -i.b 's/SCALE_100/SCALE_125/' "$INI"
PATH="$T/bin:$PATH" DISPLAY=:9 SteamAppId=384190 STEAM_COMPAT_DATA_PATH="$CD" sh "$US" "$T/ue/AbzuGame.exe" > /dev/null 2>&1
grep -q "^ResolutionScale=SCALE_125" "$INI" && ok "100: a value we never wrote (in-game choice) stays" || bad "abzu user value" "$(cat "$INI")"
st '{"apps": {"384190": {"fps": [{"fps": 19.6, "scale": 100}, {"fps": 27.3, "scale": 50}, {"fps": 40, "scale": 70}]}}}'
PATH="$T/bin:$PATH" DISPLAY=:9 SteamAppId=384190 STEAM_COMPAT_DATA_PATH="$CD" sh "$US" "$T/ue/AbzuGame.exe" > /dev/null 2> "$T/err"
grep -q "render scale 35 auto: 27 fps at 50%, under 120" "$T/err" && grep -q "^ResolutionScale=SCALE_25" "$INI" \
  && ok "auto, none held 120: one step under 50 (35 -> ABZU's SCALE_25)" || bad "auto under 50" "$(cat "$T/err")"
st '{"apps": {"384190": {"fps": [{"fps": 19.6, "scale": 100}, {"fps": 27.3, "scale": 50}, {"fps": 36, "scale": 35}]}}}'
PATH="$T/bin:$PATH" DISPLAY=:9 SteamAppId=384190 STEAM_COMPAT_DATA_PATH="$CD" sh "$US" "$T/ue/AbzuGame.exe" > /dev/null 2> "$T/err"
grep -q "render scale 35 auto: 36 fps at 35%, the lowest step" "$T/err" && ok "auto, none held 120: the lowest step (35)" || bad "auto lowest" "$(cat "$T/err")"
st '{"apps": {"384190": {"fps": [{"fps": 30, "scale": 100}, {"fps": 31, "scale": 70}]}}}'
PATH="$T/bin:$PATH" DISPLAY=:9 SteamAppId=384190 STEAM_COMPAT_DATA_PATH="$CD" sh "$US" "$T/ue/AbzuGame.exe" > /dev/null 2> "$T/err"
grep -q "render scale 100 auto: .*not GPU-bound" "$T/err" && ok "auto: lowering bought < 10 % -> back to 100 (CPU-bound)" || bad "auto cpu-bound" "$(cat "$T/err")"
st '{"apps": {"384190": {"fps": [{"fps": 121, "scale": 70}]}}}'
PATH="$T/bin:$PATH" DISPLAY=:9 SteamAppId=384190 STEAM_COMPAT_DATA_PATH="$CD" sh "$US" "$T/ue/AbzuGame.exe" > /dev/null 2> "$T/err"
grep -q "render scale 70 auto: 121 fps at 70%" "$T/err" && ok "auto: 70 held 120 -> stays 70" || bad "auto held" "$(cat "$T/err")"
st '{"apps": {"384190": {"target": 55, "fps": [{"fps": 62, "scale": 70}]}}}'
PATH="$T/bin:$PATH" DISPLAY=:9 SteamAppId=384190 STEAM_COMPAT_DATA_PATH="$CD" sh "$US" "$T/ue/AbzuGame.exe" > /dev/null 2> "$T/err"
grep -q "render scale 70 auto: 62 fps at 70%" "$T/err" && ok "auto: a per-game target (55) held -> stays 70" || bad "auto target" "$(cat "$T/err")"
st '{"apps": {"384190": {"fps": [{"fps": 30, "scale": 100}]}}}'
PATH="$T/bin:$PATH" DISPLAY=:9 SteamAppId=384190 STEAM_COMPAT_DATA_PATH="$CD" sh "$US" "$T/ue/AbzuGame.exe" > /dev/null 2> "$T/err"
grep -q "render scale 85 auto: 30 fps at 100%, under 120" "$T/err" && ok "auto: 100 under 120 -> one step down (85)" || bad "auto step" "$(cat "$T/err")"
# A check holding the game's settings (bf-lib gus_set's .powos-gus-bak): unity-screen writes nothing, marks it held.
st '{"apps": {"384190": {"scale": 50}}}'; sed -i.b 's/^ResolutionScale=.*/ResolutionScale=SCALE_75/' "$INI"; : > "$INI.powos-gus-bak"
PATH="$T/bin:$PATH" DISPLAY=:9 SteamAppId=384190 STEAM_COMPAT_DATA_PATH="$CD" sh "$US" "$T/ue/AbzuGame.exe" > /dev/null 2> "$T/err"
grep -q "^ResolutionScale=SCALE_75" "$INI" && grep -q "a check holds" "$T/err" && [ "$(rec 384190 held)" = True ] \
  && ok "a check's .powos-gus-bak: its ResolutionScale left as the check set it, record held" || bad "gus hold" "$(cat "$INI") / $(cat "$T/err")"
rm -f "$INI.powos-gus-bak"
CD2="$T/compat/9"; INI2="$CD2/pfx/drive_c/users/steamuser/AppData/Local/Proj/Saved/Config/WindowsNoEditor/GameUserSettings.ini"
mkdir -p "$(dirname "$INI2")"; printf '[ScalabilityGroups]\nsg.ShadowQuality=3\n' > "$INI2"
st '{"apps": {"9": {"scale": 70}}}'
PATH="$T/bin:$PATH" DISPLAY=:9 SteamAppId=9 STEAM_COMPAT_DATA_PATH="$CD2" sh "$US" "$T/ue2/Proj/Binaries/Win64/Proj-Win64-Shipping.exe" > /dev/null 2>&1
grep -q "^sg.ResolutionQuality=70" "$INI2" && grep -q "^sg.ShadowQuality=3" "$INI2" && ok "a plain UE game: [ScalabilityGroups] sg.ResolutionQuality=70" || bad "ue sg" "$(cat "$INI2")"
st '{"apps": {"9": {"scale": 100}}}'
PATH="$T/bin:$PATH" DISPLAY=:9 SteamAppId=9 STEAM_COMPAT_DATA_PATH="$CD2" sh "$US" "$T/ue2/Proj/Binaries/Win64/Proj-Win64-Shipping.exe" > /dev/null 2>&1
grep -q "^sg.ResolutionQuality=100" "$INI2" && ok "100 again: sg.ResolutionQuality back to the engine's 100" || bad "ue sg restore" "$(cat "$INI2")"
st '{"apps": {"8": {"scale": 70}}}'
PATH="$T/bin:$PATH" DISPLAY=:9 SteamAppId=8 STEAM_COMPAT_DATA_PATH="$T/compat/8" sh "$US" "$T/ue2/Proj/Binaries/Win64/Proj-Win64-Shipping.exe" > "$T/out" 2> "$T/err"
[ "$(args)" = "-windowed -ResX=2268 -ResY=2440" ] && grep -q "70% not applied: no GameUserSettings.ini yet" "$T/err" && [ "$(rec 8 applied)" = False ] \
  && ok "no ini yet: says so, starts at full size" || bad "ue no ini" "$(args) / $(cat "$T/err")"

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
