#!/bin/bash
# bf-ask.sh: a launch of APP Steam holds waiting on the user (console_log's newest GameAction of APP), else "ask none".
# ABZU 11-07: ActionID 3 waited on SynchronizingCloud "syncfailed" from 15:44 and swallowed four verify launches.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd); S=$ROOT/tools/phone/verify/bf-ask.sh
pass=0 fail=0
ok() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $1: got '$2', want '$3'"; fi; }
H=$(mktemp -d); trap 'rm -rf "$H"' EXIT; mkdir -p "$H/.local/share/Steam/logs"; C=$H/.local/share/Steam/logs/console_log.txt
old=$(date -d '-10 min' '+%F %T'); now=$(date '+%F %T')
ga() { echo "[$1] GameAction [AppID $2, ActionID $3] : LaunchApp $4"; }
run() { HOME=$H APP=384190 sh "$S"; }
{ ga "$old" 384190 3 'changed task to SynchronizingCloud with ""'; ga "$old" 384190 3 'waiting for user response to SynchronizingCloud "syncfailed"'
  echo "[$now] ExecuteSteamURL: \"steam://rungameid/384190\""; } > "$C"
ok "pending cloud ask" "$(run)" "ask 3 ${old#* } SynchronizingCloud \"syncfailed\""
ga "$old" 274190 9 'waiting for user response to ShowInterstitials ""' >> "$C"
ok "another game's line doesn't count" "$(run)" "ask 3 ${old#* } SynchronizingCloud \"syncfailed\""
ga "$old" 384190 4 'changed task to Completed with ""' >> "$C"
ok "a later action completed" "$(run)" "ask none"
ga "$now" 384190 5 'waiting for user response to CreatingProcess ""' >> "$C"
ok "a fresh wait (auto-continued in the same second)" "$(run)" "ask none"
: > "$C"; ok "empty log" "$(run)" "ask none"
echo "Results: $pass passed, $fail failed"
[ $fail = 0 ]
