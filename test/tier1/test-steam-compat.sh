#!/bin/bash
# test-steam-compat.sh - Tier-1 tests for targets/android/pkgs/steam/powos-steam-compat (the per-game compat policy:
# native Linux build / ARM64 Proton / x86 Proton, measured launches, config.vdf edits) on a fake Steam tree.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PSC="$SCRIPT_DIR/../../targets/android/pkgs/steam/powos-steam-compat"
PASS=0; FAIL=0
ok()  { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL - $1${2:+ ($2)}"; FAIL=$((FAIL+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1" "$2"; fi; }
echo "== test-steam-compat.sh =="
command -v python3 >/dev/null || { echo "skip: no python3"; exit 0; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
St=$T/Steam
mkdir -p "$St/config" "$St/steamapps/common/Proton Experimental (ARM64)" "$St/steamapps/compatdata/100/pfx/drive_c/users"
echo save > "$St/steamapps/compatdata/100/pfx/drive_c/users/save.dat"
touch "$St/steamapps/common/Proton Experimental (ARM64)/proton"
# An ARM64 Proton is found by what it is (a proton script + Wine's aarch64-windows DLLs), not by its name.
mkdir -p "$St/steamapps/common/Proton Experimental (ARM64)/files/lib/wine/aarch64-windows"
cat > "$St/config/config.vdf" <<'V'
"InstallConfigStore"
{
	"Software"
	{
		"Valve"
		{
			"Steam"
			{
				"CompatToolMapping"
				{
					"100"
					{
						"name"		"proton_experimental"
						"config"		""
						"priority"		"250"
					}
				}
			}
		}
	}
}
V
cp "$St/config/config.vdf" "$T/orig.vdf"
for a in 100:OldGame 200:NewGame "4185400:Steam Linux Runtime 4.0"; do
  printf '"AppState"\n{\n\t"appid"\t\t"%s"\n\t"name"\t\t"%s"\n}\n' "${a%%:*}" "${a#*:}" > "$St/steamapps/appmanifest_${a%%:*}.acf"
done
C() { HOME=$T POWOS_STEAM_DIR=$St POWOS_STEAM_COMPAT_STATE=$T/state.json python3 "$PSC" "$@"; }

out=$(C apply --dry-run)
check "dry run names the new game"                 'grep -q "would set 200 NewGame: native -> arm64" <<<"$out"'
check "dry run writes nothing"                     'cmp -s "$T/orig.vdf" "$St/config/config.vdf"'
check "a played Proton game is kept"               '[ "$(C mode 100)" = kept:x86 ]'
check "Steam runtimes aren't games"                '! C status | grep -q 4185400'
C apply >/dev/null
check "new game -> ARM64 Proton (no Linux build)"  '[ "$(C get 200)" = "tool=proton-experimental-arm64 opts=-" ]'
check "kept game untouched"                        '[ "$(C get 100)" = "tool=proton_experimental opts=-" ]'
C record 200 fail >/dev/null; C apply >/dev/null
check "a failed tool -> the next one (x86)"        '[ "$(C get 200)" = "tool=proton_experimental opts=-" ]'
C record 200 31000 >/dev/null
check "measured launch is shown"                   'C status 200 | grep -q "x86 31000"'
C set 100 auto >/dev/null
check "auto on a kept game applies the policy"     '[ "$(C get 100)" = "tool=proton-experimental-arm64 opts=-" ]'
CD="$St/steamapps/compatdata"
check "x86 -> arm64 puts the x86 prefix aside"     '[ -f "$CD/100.powos-x86/pfx/drive_c/users/save.dat" ] && [ ! -e "$CD/100/pfx" ] && [ "$(cat "$CD/100/powos-family")" = arm64 ]'
C record 100 40000 >/dev/null; C record 100 20000 --tool x86 >/dev/null; C apply >/dev/null
check "the fastest measured tool wins"             '[ "$(C get 100)" = "tool=proton_experimental opts=-" ]'
check "back to x86 brings its prefix (saves) back" '[ -f "$CD/100/pfx/drive_c/users/save.dat" ] && [ -d "$CD/100.powos-arm64" ] && [ "$(cat "$CD/100/powos-family")" = x86 ]'
C set 100 kept:x86 >/dev/null
check "mode round-trips through set"               '[ "$(C mode 100)" = kept:x86 ]'
C set 200 native >/dev/null
check "native pin removes the mapping"             '[ "$(C get 200)" = "tool=- opts=-" ] && [ "$(C mode 200)" = pinned:native ]'
C set 200 x86 >/dev/null; C set 100 kept:x86 >/dev/null
check "config.vdf otherwise byte-identical"        'cmp -s <(grep -v "\"200\"" "$T/orig.vdf") <(grep -v "\"200\"" "$St/config/config.vdf") || diff <(sed "/\"200\"/,/}/d" "$St/config/config.vdf") "$T/orig.vdf" >/dev/null'
check "backups kept"                               'ls "$St/config/" | grep -q powos-bak'
# PowOS's ARM64 launch gate (compatibilitytools.d/powos-proton-arm64): "arm64" maps to it once it and Valve's runtime are there.
mkdir -p "$St/compatibilitytools.d/powos-proton-arm64" "$St/steamapps/common/SteamLinuxRuntime_4-arm64"
touch "$St/compatibilitytools.d/powos-proton-arm64/powos-entry"
C set 200 arm64 >/dev/null
check "arm64 without the runtime -> Valve's tool"  '[ "$(C get 200)" = "tool=proton-experimental-arm64 opts=-" ]'
touch "$St/steamapps/common/SteamLinuxRuntime_4-arm64/_v2-entry-point"; C apply >/dev/null
check "arm64 with the gate installed -> the gate"  '[ "$(C get 200)" = "tool=powos-proton-arm64 opts=-" ] && [ "$(C mode 200)" = pinned:arm64 ]'
check "the gate counts as the arm64 prefix family" '[ "$(cat "$CD/200/powos-family" 2>/dev/null || echo arm64)" = arm64 ]'
rm -rf "$St/compatibilitytools.d/powos-proton-arm64"; C apply >/dev/null
check "gate gone -> back to Valve's ARM64 tool"    '[ "$(C get 200)" = "tool=proton-experimental-arm64 opts=-" ]'
# Version-proof: Valve renames its ARM64 Proton / ships a newer runtime - still found by capability, not by name.
mkdir -p "$St/compatibilitytools.d/powos-proton-arm64"; touch "$St/compatibilitytools.d/powos-proton-arm64/powos-entry"
mv "$St/steamapps/common/Proton Experimental (ARM64)" "$St/steamapps/common/Proton 12.0 (ARM64)"
mv "$St/steamapps/common/SteamLinuxRuntime_4-arm64" "$St/steamapps/common/SteamLinuxRuntime_5-arm64"; C apply >/dev/null
check "renamed ARM64 Proton + runtime 5 -> still the gate" '[ "$(C get 200)" = "tool=powos-proton-arm64 opts=-" ]'
mkdir -p "$St/steamapps/common/Proton 12.0 (x86)"; touch "$St/steamapps/common/Proton 12.0 (x86)/proton"
rm -rf "$St/steamapps/common/Proton 12.0 (ARM64)"; C apply >/dev/null
check "only an x86 Proton -> not the gate"         '[ "$(C get 200)" = "tool=proton-experimental-arm64 opts=-" ]'
mkdir -p "$St/steamapps/common/Proton Experimental (ARM64)/files/lib/wine/aarch64-windows"
touch "$St/steamapps/common/Proton Experimental (ARM64)/proton"
mv "$St/steamapps/common/SteamLinuxRuntime_5-arm64" "$St/steamapps/common/SteamLinuxRuntime_4-arm64"
rm -rf "$St/compatibilitytools.d/powos-proton-arm64" "$St/steamapps/common/Proton 12.0 (x86)"; C apply >/dev/null

# Screen size: a Unity / Unreal game gets the unity-screen wrapper in front of %command% at apply (user options kept).
mkdir -p "$St/userdata/1/config" "$T/.local/share/powos" "$St/steamapps/common/UGame/UGame_Data" "$St/steamapps/common/RGame/RGame_Data" \
  "$St/steamapps/common/EGame/Engine/Binaries" "$St/steamapps/common/PGame/PGame_Data" "$St/steamapps/common/SGame"
touch "$St/steamapps/common/UGame/UnityPlayer.dll" "$St/steamapps/common/RGame/RGame_Data/globalgamemanagers" \
  "$St/steamapps/common/PGame/UnityPlayer.dll" "$St/steamapps/common/SGame/sgame.exe"
W=$T/.local/share/powos/unity-screen; printf '#!/bin/sh\nexec "$@"\n' > "$W"
for a in 300:UGame 301:RGame 302:EGame 303:PGame 304:SGame; do
  printf '"AppState"\n{\n\t"appid"\t\t"%s"\n\t"name"\t\t"%s"\n\t"installdir"\t\t"%s"\n}\n' "${a%%:*}" "${a#*:}" "${a#*:}" > "$St/steamapps/appmanifest_${a%%:*}.acf"
done
cat > "$St/userdata/1/config/localconfig.vdf" <<'V'
"UserLocalConfigStore"
{
	"Software"
	{
		"Valve"
		{
			"Steam"
			{
				"apps"
				{
					"301"
					{
						"LaunchOptions"		"SteamDeck=1 %command%"
					}
					"303"
					{
						"LaunchOptions"		"-dx11"
					}
				}
			}
		}
	}
}
V
out=$(C apply --dry-run)
check "dry run names the Unity game"               'echo "$out" | grep -q "would set 300 (unity)"'
check "dry run writes nothing"                      '[ "$(C get 300)" = "tool=proton-experimental-arm64 opts=-" ] || [ "$(C get 300 | cut -d" " -f2)" = "opts=-" ]'
C apply >/dev/null
check "Unity game: wrapper + %command%"             '[ "$(C get 300 | sed "s/.* opts=//")" = "$W %command%" ]'
check "user env prefix kept around it"              '[ "$(C get 301 | sed "s/.* opts=//")" = "SteamDeck=1 $W %command%" ]'
check "Unreal game gets it too"                     '[ "$(C get 302 | sed "s/.* opts=//")" = "$W %command%" ]'
check "plain user args go after %command%"          '[ "$(C get 303 | sed "s/.* opts=//")" = "$W %command% -dx11" ]'
check "other engines untouched"                     '[ "$(C get 304 | sed "s/.* opts=//")" = "-" ]'
cp "$St/userdata/1/config/localconfig.vdf" "$T/lc1"; C apply >/dev/null
check "apply again changes nothing"                 'cmp -s "$St/userdata/1/config/localconfig.vdf" "$T/lc1"'
C screen 301 off >/dev/null
check "screen off: wrapper out, user's options back" '[ "$(C get 301 | sed "s/.* opts=//")" = "SteamDeck=1 %command%" ]'
C apply >/dev/null
check "screen off stays off at the next apply"      '[ "$(C get 301 | sed "s/.* opts=//")" = "SteamDeck=1 %command%" ]'
C screen 300 off >/dev/null
check "screen off on a bare wrapper -> no options"   '[ "$(C get 300 | sed "s/.* opts=//")" = "-" ]'
C screen 300 auto >/dev/null
check "screen auto puts it back"                    '[ "$(C get 300 | sed "s/.* opts=//")" = "$W %command%" ]'
rm "$W"; C screen 303 off >/dev/null; C screen 303 auto >/dev/null
check "no wrapper on disk: not added"               '[ "$(C get 303 | sed "s/.* opts=//")" = "%command% -dx11" ]'

# Render scale (abz-has-low-fps): the setting unity-screen reads, the widget's JSON, fps records, watch-fps.
C scale 302 70 >/dev/null
check "scale 302 70 stored"                          '[ "$(C scale 302)" = 70 ]'
check "scale 302 7 refused"                          '! C scale 302 7 2>/dev/null'
mkdir -p "$T/render-scale"; echo '{"scale": 70, "why": "set", "engine": "unreal", "applied": true}' > "$T/render-scale/302.json"
check "scales: the Unreal game, setting + applied"    'C scales | python3 -c "import json,sys; d=json.load(sys.stdin)[\"302\"]; sys.exit(not (d[\"setting\"]==\"70\" and d[\"scale\"]==70 and d[\"engine\"]==\"unreal\"))"'
check "scales: no other engine"                       '! C scales | grep -q "\"304\""'
C fps 302 27.3 >/dev/null
check "fps tagged with the applied scale"            'python3 -c "import json; f=json.load(open(\"$T/state.json\"))[\"apps\"][\"302\"][\"fps\"][-1]; exit(not (f[\"fps\"]==27.3 and f[\"scale\"]==70))"'
C scale 302 auto >/dev/null
check "scale auto clears the setting"                '[ "$(C scale 302)" = auto ]'
LOGF=$T/session.log; : > "$LOGF"
sleep 600 & GP=$!; exec -a "reaper SteamLaunch AppId=302 -- x" sleep 600 & RP=$!
( sleep 0.5; for f in 31.0 33.2 32.0 30.8 34.0; do
    echo "kwin_backend_anland: window task 9 frames: last 5 s 160 commits, 160 drawn ($f fps); commit -> drawn median 1 ms" >> "$LOGF"
    echo "kwin_backend_anland: window task 4 frames: last 5 s 5 commits, 5 drawn (1.0 fps); commit -> drawn median 1 ms" >> "$LOGF"; sleep 0.2; done ) &
POWOS_SESSION_LOG=$LOGF POWOS_WATCH_FPS=0.1,2.5 C watch-fps 302 >/dev/null 2>&1; wait $! 2>/dev/null
check "watch-fps: the busiest task's median, recorded"  'python3 -c "import json; f=json.load(open(\"$T/state.json\"))[\"apps\"][\"302\"][\"fps\"][-1]; exit(not (f[\"fps\"]==32.0))"'
kill $RP $GP 2>/dev/null; wait $RP $GP 2>/dev/null
n=$(python3 -c "import json; print(len(json.load(open('$T/state.json'))['apps']['302']['fps']))")
POWOS_SESSION_LOG=$LOGF POWOS_WATCH_FPS=0,0.5 C watch-fps 302 >/dev/null 2>&1
check "watch-fps: game closed -> nothing recorded"   '[ "$(python3 -c "import json; print(len(json.load(open(\"$T/state.json\"))[\"apps\"][\"302\"][\"fps\"]))")" = "$n" ]'

echo; echo "== Results: $PASS passed, $FAIL failed =="
[ $FAIL = 0 ]
