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

# Steam's own window closed: Steam quits (below) - a dry run names it and ends nothing, marks nothing.
out=$(POWOS_APP_QUIT_DRY=1 "$QUIT" "$steam" 2>&1)
check "dry run on Steam's pid: quits Steam" 'echo "$out" | grep -q "quitting Steam" && alive $steam && alive $game'
check "dry run leaves no user-closed mark" '[[ ! -e $T/.local/state/powos/user-closed/steam ]]'

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

# An app whose parent never waits (11-13: every "ending" since 10-31 logged "still there" after the KILL): ended, it
# is a zombie until that parent reaps it - "ended", not "still there", and the check's process test agrees.
(exec -a holder bash -c '(exec -a kate sleep 300) & exec sleep 300') &
holder=$!; pids+=("$holder")
for _ in $(seq 50); do zk=$(pgrep -P "$holder" | head -1); [[ -n "$zk" ]] && break; sleep 0.1; done
out=$("$QUIT" "${zk:-0}" 2>&1)
check "an app left a zombie by its parent counts as ended" 'echo "$out" | grep -q "ended on TERM" && ! echo "$out" | grep -q "still there"'
check "the zombie is still listed (the case is real)" '[[ -d /proc/${zk:-0} ]] && grep -q "^State:.*Z" /proc/${zk:-0}/status'

# ---- Steam quit (the user, 11-26: "steam is always running even when i try to stop it from the switcher") ----------
# Steam's window closed only put it in its tray; its card's close must quit it, its games too, and nothing in PowOS may
# start it again until the user does. Stubs: `steam -shutdown` (a client that obeys it, or one that ignores it), and
# `powos game <id> stop` that ends that game's chain.
cat > "$T/bin/powos" <<EOF
#!/bin/bash
echo "\$*" >> "$T/powos.calls"
if [[ "\$1 \$3" == "game stop" ]]; then  # the game's chain: the reaper and its children
  for r in \$(pgrep -f "SteamLaunch AppId=\$2 -- $T/"); do pkill -TERM -P "\$r"; kill -TERM "\$r"; done
fi
exit 0
EOF
cat > "$T/bin/steam" <<EOF
#!/bin/bash
echo "\$*" >> "$T/steam.calls"
[[ "\$*" == -shutdown && ! -e "$T/steam-ignores" ]] && kill -TERM "\$(cat "$T/.steam/steam.pid")"
exit 0
EOF
chmod +x "$T/bin/powos" "$T/bin/steam"
mkdir -p "$T/.steam"
MARK=$T/.local/state/powos/user-closed/steam
unmark() { [[ -e "$MARK" ]] && unlink "$MARK"; return 0; }
# fake_steam <appid>: Steam's client (argv0 steam) > {steamwebhelper, reaper SteamLaunch AppId=<id> -- > game}; sets
# $client $helper $sgame and steam.pid.
fake_steam() {
  # (The AppId as an argument: the client's own command line must not name the game's launch.)
  (exec -a steam bash -c '
    (exec -a steamwebhelper sleep 300) &
    bash -c "(exec -a Game.exe sleep 300) & wait" reaper SteamLaunch "AppId=$1" -- "$2/_v2-entry-point" &
    trap "exit 0" TERM; while :; do sleep 0.1; done' steam "$1" "$T") &
  client=$!; pids+=("$client"); helper= sgame=
  for _ in $(seq 50); do
    helper=$(pgrep -P "$client" -f '^steamwebhelper' | head -1); sgame=$(pgrep -f '^Game.exe' | head -1)
    [[ -n "$helper" && -n "$sgame" ]] && break; sleep 0.1
  done
  pids+=("$helper" "$sgame"); echo "$client" > "$T/.steam/steam.pid"
}

# 1. Its card closed (KWin hands over the window's pid: steamwebhelper's), Steam obeys -shutdown.
fake_steam 111
out=$("$QUIT" "$helper" 2>&1)
sleep 0.3
check "steamwebhelper's pid quits Steam" 'echo "$out" | grep -q "quitting Steam"'
check "its running game closed through powos game stop" 'grep -qx "game 111 stop" "$T/powos.calls" && ! alive $sgame'
check "Steam asked steam -shutdown via its wrapper" 'grep -qx -- "-shutdown" "$T/steam.calls"'
check "Steam's client ended" '! alive $client'
check "user-closed mark written" '[[ -s $MARK ]]'
check "its helper ended" '! alive ${helper:-0}'
unmark; : > "$T/steam.calls"

# 2. Steam ignores -shutdown (it stays in its tray): TERM after the wait.
touch "$T/steam-ignores"
fake_steam 222
out=$(POWOS_STEAM_QUIT_WAIT=1 "$QUIT" "$client" 2>&1)
sleep 0.3
check "a Steam ignoring -shutdown is TERMed after the wait" 'echo "$out" | grep -q "still runs 1 s after -shutdown" && ! alive $client && ! alive ${helper:-0}'
check "mark written again" '[[ -s $MARK ]]'
check "the test's own shell (same process group) stays" 'alive $$'
unlink "$T/steam-ignores"

# 3. The app menu's close: --steam, Steam not running - the mark is still written, nothing else to do.
unmark; echo 999999 > "$T/.steam/steam.pid"
out=$("$QUIT" --steam 2>&1)
check "--steam with no Steam running: marked, done" '[[ -s $MARK ]] && echo "$out" | grep -q "Steam isn.t running"'

# 4. Nothing starts it again while marked: /usr/bin/steam refuses a background start (-silent, no link) and a user's
# start clears the mark; powos-steam-resident doesn't start it.
W="$SCRIPT_DIR/../../targets/android/pkgs/steam/steam"
gate=$(sed -n '/^UC=/,/^esac/p' "$W")
check "the wrapper has the user-closed gate" '[[ -n "$gate" ]]'
uc() { sh -c "$gate"'
echo started' steam "$@" 2>&1; }
check "marked: steam -silent refused" '[[ "$(uc -silent)" == *"background start"*"refused"* && "$(uc -silent)" != *started* && -e $MARK ]]'
check "marked: steam -shutdown passes, mark kept" '[[ "$(uc -shutdown)" == started && -e $MARK ]]'
check "a game link (-silent steam://rungameid) is the user's: clears it" '[[ "$(uc -silent steam://rungameid/1)" == started && ! -e $MARK ]]'
date > "$MARK"
check "a plain start (a tap on Steam) clears it" '[[ "$(uc)" == started && ! -e $MARK ]]'
check "unmarked: steam -silent starts" '[[ "$(uc -silent)" == started ]]'
date > "$MARK"; : > "$T/steam.calls"
POWOS_STEAM_RESIDENT_DELAY=0 sh "$SCRIPT_DIR/../../targets/android/pkgs/steam/powos-steam-resident"
check "powos-steam-resident starts no Steam while marked" '[[ ! -s $T/steam.calls ]] && grep -q "closed by the user" "$T/powos-steam-resident.log"'

echo "== $PASS passed, $FAIL failed =="
[[ $FAIL == 0 ]]
