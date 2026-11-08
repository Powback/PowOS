#!/bin/bash
# test-game-stop-sync.sh - Tier-1: `powos game <id> stop` never kills a game while Steam syncs its cloud save.
#
# 11-08 ~03:20 (night-fails-2): a verify stop ended Broforce while Steam synced its cloud save; Steam was left asking a
# sync-conflict question that SKIPped every later game check. lib/game.sh now reads Steam's console_log/content_log
# (_game_steam_exit_state) and holds the KILL while a sync runs (_gsc_game_wait). Fixtures (test/tier1/fixtures/
# steam-exit/): sync (ExitApp SynchronizingCloud, not finished), synced (ExitApp Completed + state without Running),
# nocloud (process removed + state without Running, no sync), ask (ExitApp waiting for the user).
#
# Usage:  bash test/tier1/test-game-stop-sync.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR/../.."
FX="$SCRIPT_DIR/fixtures/steam-exit"

PASS=0; FAIL=0
ok()   { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL - $1${2:+ ($2)}"; FAIL=$((FAIL+1)); }
eq()   { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }

echo "== test-game-stop-sync.sh =="
export POWOS_LIB="$REPO_ROOT/lib"
source "$REPO_ROOT/lib/game.sh" >/dev/null 2>&1
declare -f _game_steam_exit_state >/dev/null || { echo "FATAL: _game_steam_exit_state missing"; exit 1; }

t() { date -d "2026-11-08 $1" +%s; }
STOP=$(t 03:20:00)  # the stop: just before Steam's "Game process removed" at 03:20:01

eq "sync in progress: sync"           "$(_game_steam_exit_state 274190 "$STOP" "$FX/sync")"    sync
eq "sync finished: done"              "$(_game_steam_exit_state 274190 "$STOP" "$FX/synced")"  done
eq "no cloud, exit logged: done"      "$(_game_steam_exit_state 274190 "$STOP" "$FX/nocloud")" done
eq "Steam asks about the sync: ask"   "$(_game_steam_exit_state 274190 "$STOP" "$FX/ask")"     "ask CloudSyncConflict \"\""
eq "another game's launch sync counts for it" "$(_game_steam_exit_state 384190 "$STOP" "$FX/nocloud")" sync
eq "an appid prefix is another game"  "$(_game_steam_exit_state 27419 "$STOP" "$FX/sync")" quiet
eq "nothing since the stop: quiet"    "$(_game_steam_exit_state 274190 "$(t 03:30:00)" "$FX/nocloud")" quiet
eq "a sync line >10 min old is stale" "$(_game_steam_exit_state 274190 "$(t 03:40:00)" "$FX/sync")" running
d=$(mktemp -d); head -4 "$FX/sync/console_log.txt" > "$d/console_log.txt"; cp "$FX/sync/content_log.txt" "$d/"
eq "still App Running: running"       "$(_game_steam_exit_state 274190 "$STOP" "$d")" running
printf '[2026-11-08 03:20:01] GameAction [AppID 274190, ActionID 13] : ExitApp changed task to SynchronizingCloud with ""\r\n' >> "$d/console_log.txt"
eq "CRLF log lines: sync"             "$(_game_steam_exit_state 274190 "$STOP" "$d")" sync
rm -rf "$d"

# _gsc_game_wait with a game that ignores TERM: held while Steam syncs, KILLed at 2 s otherwise.
game() { bash -c 'trap "" TERM; while :; do sleep 0.2; done' >/dev/null 2>&1 & p=$!; }  # a direct child: no $(...)
export POWOS_GAME_STOP_TICKS=30
game; out=$(POWOS_STEAM_LOGS="$FX/sync" _gsc_game_wait 274190 "$p" "$STOP")
eq "sync: the game is not killed (state|left)" "$out" "sync|$p "
if [[ -d /proc/$p ]]; then ok "sync: the game process still runs"; else bad "sync: the game process still runs"; fi
kill -KILL "$p" 2>/dev/null; wait "$p" 2>/dev/null
game; out=$(POWOS_STEAM_LOGS="$FX/nocloud" _gsc_game_wait 274190 "$p" "$STOP")
eq "no cloud: killed after 2 s, exit done" "$out" "done|"
sleep 0.2; if [[ -d /proc/$p ]] && ! grep -q '^State:.*Z' "/proc/$p/status" 2>/dev/null; then bad "no cloud: the game is gone"; else ok "no cloud: the game is gone"; fi
wait "$p" 2>/dev/null

# _game_steam_close: a sync still running = left to Steam, exit 4, Steam not touched.
_game_launch_pids() { echo "$GP"; }
d=$(mktemp -d); n=$(date '+%F %T'); sed "s/2026-11-08 03:20:01/$n/" "$FX/sync/console_log.txt" > "$d/console_log.txt"
cp "$FX/sync/content_log.txt" "$d/"  # the sync line stamped now: _game_steam_close reads from its own start
game; GP=$p; out=$(POWOS_STEAM_LOGS="$d" _game_steam_close 274190 1 2>&1); rc=$?; rm -rf "$d"
eq "close mid-sync: exit 4" "$rc" 4
case $out in *"left to Steam"*"Steam not shut down"*) ok "close mid-sync: says left to Steam";; *) bad "close mid-sync: says left to Steam" "$out";; esac
kill -KILL "$GP" 2>/dev/null; wait "$GP" 2>/dev/null

echo "test-game-stop-sync.sh: $PASS passed, $FAIL failed"
[[ $FAIL == 0 ]]
