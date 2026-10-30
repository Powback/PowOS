#!/bin/bash
# test-app-quit.sh - Tier-1 tests for powos-app-quit (targets/android/session/powos-app-quit): the second half of a
# switcher swipe. KWin closed the swiped window ("quit") and its process still runs 3 s later; the script ends the app.
#
# The game case is the one that matters: a Proton game's window pid (AbzuGame-Win64-Shipping.exe) is a SIBLING of its
# wineserver / winedevice.exe / launcher exe under pressure-vessel, all under Steam's reaper `SteamLaunch AppId=<id> --`
# (the phone, ABZU 2026-10-30). Ending the window pid's own tree left the game's chain running. A fake chain of the same
# shape is built from real processes here: Steam (protected) > reaper > {game exe, wineserver}.
#
# Usage:  bash test/tier1/test-app-quit.sh   (Linux: needs /proc; skipped elsewhere)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUIT="$SCRIPT_DIR/../../targets/android/session/powos-app-quit"

PASS=0; FAIL=0
ok()   { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL - $1${2:+ ($2)}"; FAIL=$((FAIL+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1" "$2"; fi; }
alive(){ [[ -d /proc/$1 ]] && ! grep -q '^State:.*Z' "/proc/$1/status" 2>/dev/null; }

echo "== test-app-quit.sh =="
[[ -f "$QUIT" ]] || { echo "FATAL: powos-app-quit not found"; exit 1; }
[[ -r /proc/self/stat ]] || { echo "  skip - no /proc (not Linux)"; exit 0; }

T=$(mktemp -d)
export XDG_RUNTIME_DIR=$T HOME=$T
mkdir -p "$T/bin"
# `powos game <id> stop` that fails and ends nothing (an appid it can't resolve, a timeout): the script must still end
# the game itself.
cat > "$T/bin/powos" <<EOF
#!/bin/bash
echo "\$*" >> "$T/powos.calls"
echo "No installed Steam game called \$2" >&2
exit 1
EOF
chmod +x "$T/bin/powos"
export PATH="$T/bin:$PATH"
pids=()
cleanup() { kill -KILL "${pids[@]}" 2>/dev/null; pkill -KILL -f "$T/" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT

# Steam's client (argv0 steam: protected) > reaper (SteamLaunch AppId=384190 --) > game exe + wineserver.
(exec -a steam bash -c "
  bash -c '(exec -a AbzuGame-Win64-Shipping.exe sleep 300) & (exec -a wineserver sleep 300) & wait' \
    reaper SteamLaunch AppId=384190 -- $T/_v2-entry-point --verb=waitforexit &
  sleep 300 & wait") &
steam=$!; pids+=("$steam")
game= wserver= reaper=
for _ in $(seq 50); do
  game=$(pgrep -f '^AbzuGame-Win64-Shipping.exe' | head -1)
  wserver=$(pgrep -f '^wineserver 300' | head -1)
  reaper=$(pgrep -f '^bash -c .*reaper SteamLaunch AppId=384190' | head -1)
  [[ -n "$game" && -n "$wserver" && -n "$reaper" ]] && break
  sleep 0.1
done
[[ -n "$game" && -n "$wserver" && -n "$reaper" ]] || { echo "FATAL: fake game chain didn't start"; exit 1; }
pids+=("$game" "$wserver" "$reaper")

# Dry run: names the game, ends nothing.
out=$(POWOS_APP_QUIT_DRY=1 "$QUIT" "$game" 2>&1)
check "dry run sees Steam game 384190" 'echo "$out" | grep -q "Steam game 384190"'
check "dry run ends nothing" 'alive $game && alive $wserver && alive $reaper'

# Steam's own window closed: Steam is refused as a whole.
out=$("$QUIT" "$steam" 2>&1)
check "Steam's pid is protected" 'echo "$out" | grep -q "protected" && alive $steam && alive $game'

# The swipe: game window pid handed over, `powos game stop` fails - the whole launch chain still goes, Steam stays.
out=$("$QUIT" "$game" 2>&1)
check "asks powos game 384190 stop first" 'grep -qx "game 384190 stop" "$T/powos.calls"'
check "ends the chain from the reaper" 'echo "$out" | grep -q "ending its launch chain from $reaper:"'
sleep 0.3
check "game exe ended" '! alive $game'
check "its sibling wineserver ended" '! alive $wserver'
check "the reaper ended" '! alive $reaper'
check "Steam's client stays" 'alive $steam'
check "logged to XDG_RUNTIME_DIR" 'grep -q "powos-app-quit $game:" "$T/powos-app-quit.log"'

# Any other app: the process and its descendants.
(exec -a dolphin bash -c 'sleep 300 & wait') &
app=$!; pids+=("$app")
for _ in $(seq 50); do kid=$(pgrep -P "$app" | head -1); [[ -n "$kid" ]] && break; sleep 0.1; done
out=$("$QUIT" "$app" 2>&1)
sleep 0.3
check "a plain app and its child end" '! alive $app && ! alive ${kid:-0}'
check "a plain app never calls powos game" '[[ $(wc -l < "$T/powos.calls") == 1 ]]'

echo "== $PASS passed, $FAIL failed =="
[[ $FAIL == 0 ]]
