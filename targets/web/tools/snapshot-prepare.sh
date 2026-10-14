#!/bin/sh
# Runs as root inside the snapshot machine (build-snapshot.sh: gzip+base64 on its kernel command line, started by systemd's
# run generator): brings PowOS to its desktop, lets it settle, frees what a resumed machine doesn't need, and
# signals tools/snapshot.py, which then saves the running machine.
echo POWOS-SNAPSHOT-START > /dev/console

# HACK: bridge until the rootfs is rebuilt - install-powos-android.sh (POWOS_TARGET=vm) now writes both of these
# at install time. Written here they land in the snapshot's disk overlay, so the resumed machine has them too.
if [ ! -f /etc/sddm.conf.d/10-powos-vm-autologin.conf ]; then
  mkdir -p /etc/sddm.conf.d
  session=$(ls /usr/share/wayland-sessions/ | grep '^plasma' | head -1)
  printf '[Autologin]\nUser=powos\nSession=%s\n' "${session%.desktop}" > /etc/sddm.conf.d/10-powos-vm-autologin.conf
fi
grep -q '^KWIN_COMPOSE=' /etc/environment || echo 'KWIN_COMPOSE=Q' >> /etc/environment
systemctl is-enabled -q sddm.service || systemctl enable sddm.service

# Units the browser machine masks (machine.json's systemd.mask= list, put here by build-snapshot.sh as MASK so the
# kernel command line stays under its 2048 bytes): masked before graphical.target starts them.
[ -n "${MASK:-}" ] && systemctl mask --runtime $MASK

# The desktop: SDDM logs powos into Plasma; wait for its shell, then for the first-login work to settle.
timeout 1800 systemctl start graphical.target
systemctl is-active -q sddm.service || timeout 600 systemctl start sddm.service
# Give up as soon as SDDM is gone rather than waiting out the clock (a missing display manager once cost 30 min here).
for i in $(seq 1800); do
  pgrep -x plasmashell > /dev/null && break
  systemctl is-active -q sddm.service || break
  sleep 1
done
if ! pgrep -x plasmashell > /dev/null; then
  # No desktop, no snapshot: saving this machine would ship a text console as "PowOS".
  { echo "POWOS-SNAPSHOT-FAILED: no plasmashell after ${i}s"; systemctl status sddm.service --no-pager -n 30
    journalctl -b -u sddm.service --no-pager -n 40; } > /dev/console 2>&1
  exit 1
fi
echo "POWOS-SNAPSHOT plasmashell up after ${i}s" > /dev/console
sleep 90
systemctl list-jobs > /dev/console

# Free what the resumed machine doesn't need: with init_on_free=1 (web/machine.json) freed pages are zeros, which
# the migration stream stores as a few bytes each.
sync
echo 3 > /proc/sys/vm/drop_caches
echo 1 > /proc/sys/vm/compact_memory
free -m > /dev/console
ps -eo rss,comm --sort=-rss | head -25 > /dev/console
echo "POWOS-SNAPSHOT-$((6*7))" > /dev/console
