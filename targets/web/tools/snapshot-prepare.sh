#!/bin/sh
# Runs as root inside the snapshot machine (build-snapshot.sh: gzip+base64 on its kernel command line, started by systemd's
# run generator): brings PowOS to its desktop, lets it settle, frees what a resumed machine doesn't need, and
# signals tools/snapshot.py, which then saves the running machine.
echo POWOS-SNAPSHOT-START > /dev/console

# Units the browser machine masks (machine.json's systemd.mask= list, put here by build-snapshot.sh as MASK so the
# kernel command line stays under its 2048 bytes): masked before graphical.target starts them.
[ -n "${MASK:-}" ] && systemctl mask --runtime $MASK
# No swap in the browser machine (the zram units are in that list): swapped-out pages cost a decompression and the
# kernel's reclaim on every touch, which under browser emulation stalls the whole desktop for minutes. 1.5 GB holds
# the desktop (~0.6 GB used) without it.
swapoff -a

# The desktop: SDDM logs powos into Plasma; wait for its shell, then for the first-login work to settle.
timeout 1800 systemctl start graphical.target
systemctl is-active -q sddm.service || timeout 600 systemctl start sddm.service
# Give up as soon as SDDM is gone rather than waiting out the clock (a missing display manager once cost 30 min here).
for i in $(seq 1800); do
  pgrep -x plasmashell > /dev/null && break
  systemctl is-active -q sddm.service || break
  # SDDM showing its greeter means the autologin session already failed.
  pgrep -f sddm-greeter > /dev/null && break
  sleep 1
done
if ! pgrep -x plasmashell > /dev/null; then
  # No desktop, no snapshot: saving this machine would ship a text console as "PowOS".
  # Diagnostics BEFORE the marker: snapshot.py stops the machine the moment it sees the marker.
  { pacman -Q sddm plasma-workspace kwin; ls /usr/lib/systemd/system/sddm* /usr/share/wayland-sessions/
    systemctl get-default; systemctl is-enabled sddm.service; systemctl status sddm.service --no-pager -n 30
    journalctl -b -u sddm.service --no-pager -n 40
    grep -r . /etc/sddm.conf /etc/sddm.conf.d 2>/dev/null
    journalctl -b _UID=$(id -u powos) --no-pager | grep -v -E 'pam_|dbus-daemon' | tail -60; } > /dev/console 2>&1
  sleep 2
  echo "POWOS-SNAPSHOT-FAILED: no plasmashell after ${i}s" > /dev/console
  exit 1
fi
echo "POWOS-SNAPSHOT plasmashell up after ${i}s" > /dev/console
# Settled = Plasma's splash (ksplashqml) has exited: it closes exactly when the session's startup phases are done and
# the desktop has been drawn. Then 30 s more for late widgets. Emulated, a fixed wait saved an undrawn desktop (black
# canvas), and "wait for idle CPU" never ends: the PowOS widgets keep an emulated CPU busy.
# It has to be seen first: right after plasmashell starts the splash may not be up yet (that once ended this wait at
# once and saved a desktop with wallpaper but no panel).
for n in $(seq 60); do pgrep -x ksplashqml > /dev/null && break; sleep 5; done
for m in $(seq 180); do pgrep -x ksplashqml > /dev/null || break; sleep 10; done
sleep 60
echo "POWOS-SNAPSHOT settled after $((n * 5 + m * 10 + 60))s" > /dev/console
systemctl list-jobs > /dev/console

# Free what the resumed machine doesn't need: with init_on_free=1 (web/machine.json) freed pages are zeros, which
# the migration stream stores as a few bytes each.
swapoff -a
sync
echo 3 > /proc/sys/vm/drop_caches
echo 1 > /proc/sys/vm/compact_memory
free -m > /dev/console
ps -eo rss,comm --sort=-rss | head -25 > /dev/console
# Heartbeat on the serial console, carried into the resumed machine: guest uptime every 5 s ("HB <seconds>") and, every
# 30 s, the top processes ("TOP ...": what an emulated CPU is spent on). Against
# wall time it is the browser emulator's speed (test/alive.mjs). Its own unit, so it outlives this script; no forks
# but sleep.
systemd-run --unit=powos-heartbeat sh -c 'n=0; while sleep 5; do read u _ < /proc/uptime; echo "HB $u"; n=$((n+1)); [ $((n % 6)) = 0 ] && top -b -n1 -w 100 | sed -n "1,3p;7,13p" | sed "s/^/TOP /"; done > /dev/ttyAMA0'
echo "POWOS-SNAPSHOT-$((6*7))" > /dev/console
