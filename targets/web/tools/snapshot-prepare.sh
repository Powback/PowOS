#!/bin/sh
# Runs as root inside the snapshot machine (build-snapshot.sh: handed in through QEMU's fw_cfg, started by systemd's
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

# The desktop: SDDM logs powos into Plasma; wait for its shell, then for the first-login work to settle.
timeout 1800 systemctl start graphical.target
for i in $(seq 1800); do pgrep -x plasmashell > /dev/null && break; sleep 1; done
pgrep -x plasmashell > /dev/null && echo "POWOS-SNAPSHOT plasmashell up after ${i}s" > /dev/console
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
