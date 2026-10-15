#!/system/bin/sh
# PowOS on a rooted Android phone (OnePlus Open): runs PowOS's Linux system (Arch Linux ARM + KDE + the PowOS
# layer, /data/powos/root) alongside Android on the same kernel. Run as root - by Magisk at every boot
# (/data/adb/service.d/powos.sh, a copy of this file) or by hand (rooted.sh start). Safe to run again.
#
# It gives PowOS the real system: /dev (GPU = /dev/kgsl-3d0, input, dma-heaps), /proc, /sys, private /tmp and
# /run, the phone's storage at /mnt/sdcard, DNS. Then starts PowOS's SSH server on port 2222.
# Nothing outside /data/powos is changed; to remove PowOS: stop the phone's use of it, delete /data/powos and
# /data/adb/service.d/powos.sh.
R=/data/powos/root
LOG=/data/powos/start.log
exec >> "$LOG" 2>&1
echo "--- $(date) powos-start"

[ -x "$R/usr/bin/bash" ] || { echo "no PowOS system in $R"; exit 1; }

# Mounts go into the global mount namespace (pid 1's), so every root shell and app sees the same PowOS.
m() { nsenter -t 1 -m -- "$@"; }
mounted() { m grep -q " $1 " /proc/mounts; }
bind() { mounted "$2" || { mkdir -p "$2" && m mount --rbind "$1" "$2" && echo "bind $1 -> $2"; }; }

bind /dev "$R/dev"
bind /proc "$R/proc"
bind /sys "$R/sys"
mounted "$R/tmp" || m mount -t tmpfs -o mode=1777 tmpfs "$R/tmp"
mounted "$R/run" || m mount -t tmpfs -o mode=755 tmpfs "$R/run"
mounted "$R/dev/shm" || { mkdir -p "$R/dev/shm"; m mount -t tmpfs -o mode=1777 tmpfs "$R/dev/shm"; }
# What systemd-tmpfiles makes on a booted PowOS: without /tmp/.X11-unix KWin can't open the X11 socket, so no
# Xwayland, ksmserver (X11) aborts and Plasma never starts plasmashell.
for d in .X11-unix .ICE-unix .XIM-unix .font-unix; do m mkdir -p "$R/tmp/$d" && m chmod 1777 "$R/tmp/$d"; done
bind /storage/emulated/0 "$R/mnt/sdcard"

# DNS: Android keeps no resolv.conf; PowOS asks Android's resolver (netd) via the first DNS server it knows,
# else the LAN's Pi-hole.
dns=$(getprop net.dns1); [ -n "$dns" ] || dns=192.168.50.100
printf 'nameserver %s\nnameserver 1.1.1.1\n' "$dns" > "$R/etc/resolv.conf"

# SSH into PowOS (port 2222: Android may use 22). Keys are generated on first start.
chroot "$R" /usr/bin/env -i PATH=/usr/bin:/usr/sbin HOME=/root /bin/sh -c '
  [ -f /etc/ssh/ssh_host_ed25519_key ] || ssh-keygen -A
  pgrep -x sshd >/dev/null || /usr/bin/sshd -p 2222
' && echo "sshd on 2222"
echo "PowOS up"
