#!/bin/bash
# test-game-mono-aot.sh - Tier-1: `powos game <appid> aot on|off|status` (lib/game.sh _game_aot).
#
# Mono AOT images (<assembly>.dll.dll, built off the phone by tools/games/mono-aot.sh) are placed beside the game's
# assemblies only by `aot on`, which records each one in installed.tsv; `off` removes exactly those. Never a game
# file: an existing file of that name is left alone, and an image whose assembly changed (game update = new GUID,
# Mono would ignore it) is not placed. docs/research/broforce-engine-init.md lever 2.
#
# Usage:  bash test/tier1/test-game-mono-aot.sh
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR/../.."
PASS=0; FAIL=0
ok()   { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL - $1${2:+ ($2)}"; FAIL=$((FAIL+1)); }
eq()   { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }
sha()  { sha256sum < "$1" | cut -d' ' -f1; }

echo "== test-game-mono-aot.sh =="
export POWOS_LIB="$REPO_ROOT/lib"
source "$REPO_ROOT/lib/game.sh" >/dev/null 2>&1
declare -f _game_aot >/dev/null || { echo "FATAL: _game_aot missing"; exit 1; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export XDG_DATA_HOME=$T/share POWOS_MONO_AOT_DIR=$T/aot
lib=$XDG_DATA_HOME/Steam/steamapps; g=$lib/common/Broforce; M=Broforce_beta_Data/Managed
mkdir -p "$g/$M"
printf '"AppState"\n{\n\t"appid"\t\t"274190"\n\t"installdir"\t\t"Broforce"\n}\n' > "$lib/appmanifest_274190.acf"
for a in Assembly-CSharp mscorlib UnityEngine.CoreModule Rewired_Core; do echo "il $a" > "$g/$M/$a.dll"; done
echo "the game's own file" > "$g/$M/Rewired_Core.dll.dll"   # a file of an image's name the game ships: never ours
st=$POWOS_MONO_AOT_DIR/274190; mkdir -p "$st/images/$M"
: > "$st/images.tsv"
for a in Assembly-CSharp mscorlib UnityEngine.CoreModule Rewired_Core; do
  echo "aot $a" > "$st/images/$M/$a.dll.dll"
  printf '%s\t%s\t%s\n' "$M/$a.dll.dll" "$(sha "$g/$M/$a.dll")" "GUID-$a" >> "$st/images.tsv"
done
echo "il mscorlib v2" > "$g/$M/mscorlib.dll"               # a game update after the build: stale
printf '%s\t%s\t%s\n' "../../escape.dll" x y >> "$st/images.tsv"  # a path out of the game dir is never followed
before=$(cd "$g" && find . -type f ! -name '*.dll.dll' -exec sha256sum {} + | sort; sha "$M/Rewired_Core.dll.dll")

eq "resolves the game dir from the appmanifest" "$(_game_steam_dir 274190)" "$g"
case $(_game_aot 274190 status 2>&1) in *"aot off (4 images built"*|*"aot off (5 images built"*) ok "status before: off, built";; *) bad "status before" "$(_game_aot 274190 status 2>&1)";; esac

out=$(_game_aot 274190 on 2>&1); rc=$?
eq "on: exit 0" "$rc" 0
case $out in *"2 of 4 images placed"*"1 stale"*"1 not placed"*) ok "on: says placed/stale/not placed";; *) bad "on: says placed/stale/not placed" "$out";; esac
[[ -f "$g/$M/Assembly-CSharp.dll.dll" && -f "$g/$M/UnityEngine.CoreModule.dll.dll" ]] && ok "on: images placed beside their assemblies" || bad "on: images placed"
[[ ! -e "$g/$M/mscorlib.dll.dll" ]] && ok "on: stale image (assembly changed) not placed" || bad "on: stale image not placed"
eq "on: the game's own same-named file untouched" "$(cat "$g/$M/Rewired_Core.dll.dll")" "the game's own file"
[[ ! -e "$T/escape.dll" && ! -e "$lib/escape.dll" ]] && ok "on: no path outside the game dir" || bad "on: no path outside the game dir"
eq "on: manifest lists exactly the placed images" "$(cut -f1 "$st/installed.tsv" | sort | tr '\n' ' ')" "$M/Assembly-CSharp.dll.dll $M/UnityEngine.CoreModule.dll.dll "
case $(_game_aot 274190 status 2>&1) in *"aot on: 2 images"*) ok "status: on, 2";; *) bad "status: on" "$(_game_aot 274190 status 2>&1)";; esac

out2=$(_game_aot 274190 on 2>&1); rc=$?
eq "on twice: exit 0, same result" "$rc/$(wc -l < "$st/installed.tsv" | tr -d ' ')" "0/2"

echo "changed by hand" > "$g/$M/UnityEngine.CoreModule.dll.dll"   # someone replaced a placed image: not ours anymore
out=$(_game_aot 274190 off 2>&1); rc=$?
eq "off: exit 0" "$rc" 0
[[ ! -e "$g/$M/Assembly-CSharp.dll.dll" ]] && ok "off: placed image removed" || bad "off: placed image removed"
eq "off: a placed image changed since is kept" "$(cat "$g/$M/UnityEngine.CoreModule.dll.dll" 2>/dev/null)" "changed by hand"
rm -f "$g/$M/UnityEngine.CoreModule.dll.dll"
after=$(cd "$g" && find . -type f ! -name '*.dll.dll' -exec sha256sum {} + | sort; sha "$M/Rewired_Core.dll.dll")
eq "off: every game file as before" "$after" "$before"
[[ ! -e "$st/installed.tsv" ]] && ok "off: manifest gone" || bad "off: manifest gone"
[[ -f "$st/images/$M/Assembly-CSharp.dll.dll" ]] && ok "off: the store keeps the built images" || bad "off: store keeps images"
eq "off again: no-op, exit 0" "$(_game_aot 274190 off >/dev/null 2>&1; echo $?)" 0

rm -f "$st/images.tsv"
eq "on without a build: exit 1" "$(_game_aot 274190 on >/dev/null 2>&1; echo $?)" 1
eq "unknown game: exit 1" "$(_game_aot 999 status >/dev/null 2>&1; echo $?)" 1

echo "results: $PASS passed, $FAIL failed"
[[ $FAIL == 0 ]]
