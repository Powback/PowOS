#!/bin/bash
# lib-install.sh <lib path>...: (Mac side; queue it: queue.sh add <board-task> tools/phone/verify/lib-install.sh
# apps/powos-sleep-gui game.sh) puts single files of lib/ (this checkout's) on the phone the way powos-deploy.sh does:
# lib/<path> -> PowOS's /usr/lib/powos/<path>, mode kept, the old file kept as /var/cache/powos/lib-<name>.<time>.bak
# (rollback: copy it back). The full deploy (rooted.sh deploy) does the same and more; this is for one fix without it.
# powos-sleep-gui among them: restarted in the session as powos (TERM thaws all it froze; the new one learns the
# windows from KWin and freezes what is still out of sight after its idle time again). Prints "<path>: installed".
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); A="$here/../adb.sh"; R="$here/../root.sh"; L=$(cd "$here/../../../lib" && pwd)
[ $# -gt 0 ] || { echo "usage: lib-install.sh <path under lib/>..."; exit 2; }
rc=0 gui=
for f in "$@"; do
  [ -f "$L/$f" ] || { echo "FAIL install: no lib/$f"; rc=1; continue; }
  b=powos-lib-$(echo "$f" | tr / _)
  "$A" push "$L/$f" "/data/local/tmp/$b" >/dev/null || { echo "FAIL install: can't push $f"; rc=1; continue; }
  s=$(mktemp); cat > "$s" <<SH
set -e
d=/usr/lib/powos/$f t=\$(date +%Y%m%d-%H%M%S)
mkdir -p /var/cache/powos
[ -f "\$d" ] && cp -p "\$d" "/var/cache/powos/lib-$(basename "$f").\$t.bak"
install -m 755 /data/local/tmp/$b "\$d.new" 2>/dev/null || cp /data/local/tmp/$b "\$d.new"
[ -f "\$d" ] && chmod --reference="\$d" "\$d.new"
mv -f "\$d.new" "\$d"
echo "$f: installed (old: /var/cache/powos/lib-$(basename "$f").\$t.bak)"
SH
  # root.sh runs inside PowOS's chroot: /data/local/tmp is Android's - copy it in first.
  "$A" shell "su -c 'mkdir -p /data/powos/root/data/local/tmp && mv /data/local/tmp/$b /data/powos/root/data/local/tmp/$b'" >/dev/null
  out=$("$R" "$s" 2>&1); rm -f "$s"
  echo "$out" | tail -2
  echo "$out" | grep -q ": installed" || { echo "FAIL install: $f"; rc=1; continue; }
  case $f in apps/powos-sleep-gui) gui=1 ;; esac
done
if [ -n "$gui" ]; then
  s=$(mktemp); cat > "$s" <<'SH'
export XDG_RUNTIME_DIR=/run/powos-app DISPLAY=:0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/powos-app/bus
pkill -TERM -f 'bin/powos-sleep-gui$'; for _ in $(seq 20); do pgrep -f 'bin/powos-sleep-gui$' >/dev/null || break; sleep 0.5; done
setsid -f powos-sleep-gui >> /run/powos-app/powos-sleep-gui.log 2>&1 < /dev/null
sleep 4; pgrep -f 'bin/powos-sleep-gui$' >/dev/null && echo "powos-sleep-gui restarted: $(grep ' up: ' /run/powos-app/powos-sleep-gui.log | tail -1 | cut -c1-140)" || echo "FAIL restart: powos-sleep-gui not running"
SH
  "$here/../user.sh" "$s" 2>&1 | grep -v 'pushed' | tail -2; rm -f "$s"
fi
exit $rc
