#!/bin/bash
# lanes: phone
# bf-driver.sh (Mac; queued) start Broforce cold, wait for its window, run bf-driver-phone.sh (root, read-only) while
# it is up, close it and put Steam + the front activity back. PASS = the game maps OUR Turnip (the package's inode),
# FAIL = another one (FEX RootFS's x86_64 Turnip, emulated). Exit 3 on a touch.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); W=$here/..; A=$W/adb.sh
OUT=$HOME/.cache/powos-verify/bfd-$(date +%F_%H%M); mkdir -p "$OUT"
BF_ADB=$A . "$here/bf-lib.sh"
irq() { "$A" shell "awk '/touch-0/{s+=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9} END{print s}' /proc/interrupts" | tr -d '\r'; }
asuser() { local n=$1; shift
  "$A" shell "su -c 'cp /data/local/tmp/powos-$n /data/powos/root/var/tmp/powos-$n; chmod 644 /data/powos/root/var/tmp/powos-$n; sh /data/powos/powos-run.sh \"sh /var/tmp/powos-$n $*\"'" 2>&1 | grep -v sysvipc | tr -d '\r'; }
for f in bf-game.sh bf-start.sh bf-stop.sh bf-window.sh; do "$A" push "$here/$f" /data/local/tmp/powos-$f >/dev/null; done
case $(asuser bf-game.sh state | tail -1) in game=awake|game=frozen) echo "the user's Broforce is up - skip"; exit 3 ;; esac
front=$("$A" shell "dumpsys activity activities | grep -m1 topResumedActivity" | sed -nE 's#.* ([a-zA-Z0-9_.]+/[a-zA-Z0-9_.$]+) .*#\1#p')
steam_before=$("$A" shell "pgrep -f 'steam -cef'" | tr -d '\r')
restore() { pill "closing the game, putting Steam back"; asuser bf-stop.sh >/dev/null
  [ -n "$steam_before" ] && "$A" shell "su -c 'sh /data/powos/powos-run.sh \"cd /home/powos; setsid -f steam -silent </dev/null >/dev/null 2>&1\"'" >/dev/null 2>&1
  [ -n "$front" ] && "$A" shell "am start -n $front >/dev/null 2>&1"; }
i0=$(irq)
pill "bf-driver: launching Broforce"; asuser bf-start.sh >/dev/null
win=""; for i in $(seq "${BF_WIN_TRIES:-48}"); do sleep 5; [ "$(irq)" != "$i0" ] && { echo "touch - abort"; restore; exit 3; }
  win=$(asuser bf-window.sh | tail -1); case $win in win=[0-9]*) break ;; esac; done
case $win in win=[0-9]*) ;; *) echo "FAIL: no game window in 4 min - the maps/env of what runs:"
  perl -e 'alarm 120; exec @ARGV' "$W/root.sh" "$here/bf-driver-phone.sh" 2>&1 | grep -v pushed | tee "$OUT/driver.txt"; restore; exit 1 ;; esac
echo "window after $((i * 5)) s: $win"; sleep 15
pill "bf-driver: reading the game's mapped Vulkan driver"
perl -e 'alarm 120; exec @ARGV' "$W/root.sh" "$here/bf-driver-phone.sh" 2>&1 | grep -v pushed | tee "$OUT/driver.txt"
restore
grep -q '^   map .*vulkan_freedreno' "$OUT/driver.txt" || { echo "FAIL: no Vulkan driver mapping seen ($OUT/driver.txt)"; exit 1; }
v=$(grep -m1 '^== verdict:' "$OUT/driver.txt"); ahb=$(grep -m1 'AHB bus errors' "$OUT/driver.txt" | sed 's/.*: //')
case $v in "== verdict: OURS "*) echo "PASS: ${v#== verdict: }; AHB/20 s $ahb ($OUT/driver.txt)" ;;
  *) echo "FAIL: ${v#== verdict: }; AHB/20 s $ahb ($OUT/driver.txt)"; exit 1 ;; esac
