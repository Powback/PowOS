#!/bin/bash
# lanes: phone
# game-aot.sh <appid> on|off|status: (Mac side; queue it so it runs between checks, never during one:
# queue.sh add <board-task> tools/phone/verify/game-aot.sh 274190 on) switches a game's prebuilt Mono AOT images
# (lib/game.sh _game_aot, 436db942: hard-links from ~/.local/share/powos/mono-aot/<appid>/, manifest installed.tsv;
# off removes only those) through `powos game <appid> aot <verb>` as the powos user. For the AOT A/B in
# docs/research/broforce-engine-init.md: aot on, bf-coldstart.sh steam x3, aot off, bf-coldstart.sh steam x3.
# Exit 0 PASS (prints the command's output), 1 FAIL.
set -u
cd "$(dirname "$0")/../../.." || exit 1
id=${1:-}; verb=${2:-}
case $id in ''|*[!0-9]*) echo "usage: game-aot.sh <appid> on|off|status"; exit 2 ;; esac
case $verb in on|off|status) ;; *) echo "usage: game-aot.sh <appid> on|off|status"; exit 2 ;; esac
out=$(tools/phone/adb.sh shell "su -c 'sh /data/powos/powos-run.sh \"powos game $id aot $verb\"'" 2>&1 | tr -d '\r'); rc=$?
echo "$out" | tail -8
if [ $rc -eq 0 ]; then echo "PASS: powos game $id aot $verb"; else echo "FAIL: powos game $id aot $verb (rc $rc)"; exit 1; fi
