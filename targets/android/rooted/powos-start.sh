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

# PowOS's root as a mount of its own that allows setuid: Android mounts /data nosuid, which stops sudo for the user
# powos. --rbind keeps what is already mounted inside (a rerun while PowOS runs).
mounted "$R" || { m mount --rbind "$R" "$R" && m mount -o remount,bind,suid "$R" && echo "setuid allowed in $R"; }
bind /dev "$R/dev"
bind /proc "$R/proc"
bind /sys "$R/sys"
mounted "$R/tmp" || m mount -t tmpfs -o mode=1777 tmpfs "$R/tmp"
mounted "$R/run" || m mount -t tmpfs -o mode=755 tmpfs "$R/run"
mounted "$R/dev/shm" || { mkdir -p "$R/dev/shm"; m mount -t tmpfs -o mode=1777 tmpfs "$R/dev/shm"; }
# What systemd-tmpfiles makes on a booted PowOS: without /tmp/.X11-unix KWin can't open the X11 socket, so no
# Xwayland, ksmserver (X11) aborts and Plasma never starts plasmashell.
for d in .X11-unix .ICE-unix .XIM-unix .font-unix; do m mkdir -p "$R/tmp/$d" && m chmod 1777 "$R/tmp/$d"; done
# The phone's storage: only once Android has unlocked it. At boot /storage/emulated/0 is still an empty tmpfs
# placeholder; bound then, PowOS kept seeing that (and every later start stacked another). A stale placeholder bind is
# replaced; at boot the bind waits in the background.
sdcard() {
  [ -d /storage/emulated/0/Android ] || return 1
  while m grep -q " $R/mnt/sdcard tmpfs " /proc/mounts; do m umount -l "$R/mnt/sdcard" || break; done
  bind /storage/emulated/0 "$R/mnt/sdcard"
}
sdcard || (for _ in $(seq 360); do sleep 5; sdcard && break; done) &

# x86 programs (Steam, Proton games) run through FEX: register PowOS's binfmt rules with the kernel (Android's
# kernel has BINFMT_MISC built in, unmounted). Flag F: the kernel opens /usr/bin/FEX at registration, from inside
# PowOS's root, so the rule works from any mount namespace; Android itself never executes x86 ELFs.
BM="$R/proc/sys/fs/binfmt_misc"
[ -e "$BM/register" ] || m mount -t binfmt_misc binfmt_misc "$BM"
for f in "$R"/usr/lib/binfmt.d/FEX-*.conf; do
  [ -e "$f" ] || continue
  n=$(cut -d: -f2 "$f")
  [ -e "$BM/$n" ] || m chroot "$R" /usr/bin/env PATH=/usr/bin /bin/sh -c "cat /usr/lib/binfmt.d/${f##*/} > /proc/sys/fs/binfmt_misc/register" && echo "binfmt $n"
done

# DNS: Android keeps no resolv.conf; PowOS asks Android's resolver (netd) via the first DNS server it knows,
# else the LAN's Pi-hole.
dns=$(getprop net.dns1); [ -n "$dns" ] || dns=192.168.50.100
printf 'nameserver %s\nnameserver 1.1.1.1\n' "$dns" > "$R/etc/resolv.conf"

# SSH into PowOS (port 2222: Android may use 22). Keys are generated on first start.
chroot "$R" /usr/bin/env -i PATH=/usr/bin:/usr/sbin HOME=/root /bin/sh -c '
  [ -f /etc/ssh/ssh_host_ed25519_key ] || ssh-keygen -A
  pgrep -x sshd >/dev/null || /usr/bin/sshd -p 2222
' && echo "sshd on 2222"

# PowOS's local services' ports (SpacetimeDB 3410), for the PowOS app's uid only: Android's loopback is shared by
# every app on the phone, and the PowOS user powos IS the app's uid - so the app's WebViews, the desktop session,
# agents and root pass, every other Android app gets a reset (docs/POWOS-APPS-FEASIBILITY.md section 3). The uid
# comes from Android's package list each time (it changes if the app is reinstalled). A changed rule set is built as
# a new chain and swapped in, never flushed in place (that would leave the port open in between).
POWOS_PORTS="3410"
lock_ports() {
  u=$(awk '$1 == "com.powos.app" {print $2}' /data/system/packages.list)
  [ -n "$u" ] || { echo "port lock: com.powos.app not in packages.list"; return 1; }
  want="-A powos-local -m owner --uid-owner $u -j RETURN
-A powos-local -m owner --uid-owner 0 -j RETURN
-A powos-local -p tcp -j REJECT --reject-with tcp-reset"
  have=$(iptables -w -S powos-local 2>/dev/null | grep '^-A')
  if [ "$have" != "$want" ]; then
    iptables -w -N powos-local-new 2>/dev/null || iptables -w -F powos-local-new
    printf '%s\n' "$want" | sed 's/^-A powos-local /-A powos-local-new /' | while read -r rule; do iptables -w $rule; done
    for p in $POWOS_PORTS; do iptables -w -I OUTPUT 1 -o lo -p tcp --dport "$p" -j powos-local-new; done
    for p in $POWOS_PORTS; do while iptables -w -D OUTPUT -o lo -p tcp --dport "$p" -j powos-local 2>/dev/null; do :; done; done
    iptables -w -F powos-local 2>/dev/null && iptables -w -X powos-local
    iptables -w -E powos-local-new powos-local
    echo "port lock: $POWOS_PORTS for uid $u (and root)"
  fi
  for p in $POWOS_PORTS; do
    iptables -w -C OUTPUT -o lo -p tcp --dport "$p" -j powos-local 2>/dev/null || iptables -w -I OUTPUT 1 -o lo -p tcp --dport "$p" -j powos-local
  done
}

# PowOS's system tier: services that live as long as the phone, not the desktop session (which restarts with every
# app update and kills its whole process group). Its own persistent mount namespace with PowOS as its root - the same
# pivot_root as powos-session.sh - made once per boot, running the supervisor (lib/apps/powos-supervisor: SpacetimeDB
# and other manifests under /usr/lib/powos/apps/services, budgets, idle unload). Never without the port lock above.
# Off: touch /data/powos/system-tier.off (rooted.sh system off); its state: rooted.sh system status.
system_tier() {
  # (the real file: /usr/bin/powos-supervisor is a link that only resolves inside PowOS)
  [ -x "$R/usr/lib/powos/apps/powos-supervisor" ] || return 0
  [ -e /data/powos/system-tier.off ] && { echo "system tier: off (/data/powos/system-tier.off)"; return 0; }
  pid=$(cat "$R/run/powos-system/supervisor.pid" 2>/dev/null)
  [ -n "$pid" ] && grep -q powos-supervisor "/proc/$pid/cmdline" 2>/dev/null && return 0
  lock_ports || { echo "system tier: not started (no port lock)"; return 1; }
  export L="$R/usr/lib/ld-linux-aarch64.so.1 --library-path $R/usr/lib" R
  setsid nsenter -t 1 -m -- unshare -m sh -c '
    $L $R/usr/bin/mount --make-rprivate / && $L $R/usr/bin/mount --rbind $R $R && cd $R && mkdir -p .oldroot &&
      $L $R/usr/bin/pivot_root . .oldroot || exit 1
    exec /usr/bin/env -i PATH=/usr/bin:/usr/sbin LANG=C.UTF-8 /bin/sh -c "umount -l /.oldroot; exec /usr/bin/powos-supervisor"
  ' > /dev/null 2>&1 < /dev/null &
  for _ in $(seq 50); do
    pid=$(cat "$R/run/powos-system/supervisor.pid" 2>/dev/null)
    [ -n "$pid" ] && [ -d "/proc/$pid" ] && { echo "system tier: supervisor pid $pid"; return 0; }
    sleep 0.1
  done
  echo "system tier: the supervisor didn't come up (/data/powos/root/var/log/powos/supervisor.log)"
}
system_tier
echo "PowOS up"
