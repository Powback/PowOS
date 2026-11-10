# game-lib.sh - the one test for "a game runs on the phone", sourced by queue.sh and every check that must not run
# beside a game (window-bench, kwin-*, linux-*, steam-*, ww-popups, plasma-modes).
# Why one: checks looked for `steam_app_` (window-bench, kwin-restart-windows, kwin-hung-client) or counted
# 'SteamLaunch AppId=' in the session, and window-bench p2 (11-10 06:28) ran its gestures beside Broforce: fps 30-44
# judged as window FAILs. The queue's own test (Steam's reaper: `reaper SteamLaunch AppId=<id>`) saw it.
#   game_up       the Steam app id of the game running now; "none" when adb answered and none runs; "" when adb failed
#   game_gate     exit 3 "a game runs (app <id>): not now" when one runs (or adb can't say); returns otherwise
# adb: $phone/adb.sh when the caller sets phone (queue.sh), else tools/phone/adb.sh next to this file.
_game_lib_adb=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/adb.sh
game_up() { local o a=${phone:+$phone/adb.sh}
  o=$(perl -e 'alarm shift; exec @ARGV' 10 "${a:-$_game_lib_adb}" shell "pgrep -af '[r]eaper SteamLaunch AppId='; echo adb-ok" 2>/dev/null | tr -d '\r')
  case $o in *adb-ok*) ;; *) return 0 ;; esac
  o=$(sed -n 's/.*AppId=\([0-9][0-9]*\).*/\1/p' <<<"$o" | head -1); echo "${o:-none}"; }
game_gate() { local g; g=$(game_up)
  case $g in none) return 0 ;; '') echo "${GAME_GATE_PREFIX:-}the phone didn't say whether a game runs: not now"; exit 3 ;; esac
  echo "${GAME_GATE_PREFIX:-}a game runs (Steam app $g): not now"; exit 3; }
