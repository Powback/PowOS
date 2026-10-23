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

echo; echo "== Results: $PASS passed, $FAIL failed =="
[ $FAIL = 0 ]
