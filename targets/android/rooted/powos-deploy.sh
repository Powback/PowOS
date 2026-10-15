#!/system/bin/sh
# Installs the rooted-mode scripts pushed to /data/local/tmp by `rooted.sh deploy` (run as root on the phone).
#   /data/powos/powos-start.sh + /data/adb/service.d/powos.sh   mounts + sshd, at every boot
#   /data/powos/powos-session.sh                                the desktop session the PowOS app starts (rooted mode)
#   /data/powos/root/usr/bin/powos-rooted-session               its part inside PowOS
# Plus: patches/andromarchy/0004 for an already installed rootfs (the no-root sudo shim runs commands directly when
# it is real root), and the flag the PowOS app checks for rooted mode (persist.powos.root=1, Magisk's resetprop -p).
set -e
T=/data/local/tmp
R=/data/powos/root
install -m 755 $T/powos-start.sh /data/powos/powos-start.sh
mkdir -p /data/adb/service.d
install -m 755 $T/powos-start.sh /data/adb/service.d/powos.sh
install -m 755 $T/powos-session.sh /data/powos/powos-session.sh
install -m 755 $T/powos-rooted-session $R/usr/bin/powos-rooted-session
rm -f $T/powos-start.sh $T/powos-session.sh $T/powos-rooted-session

# The user: powos, as on every PowOS (password powos, sudo through wheel). Its uid is the PowOS app's Android uid:
# the app's run dir (display socket, phone state) is then the user's own, as XDG_RUNTIME_DIR should be. Re-run
# after reinstalling the app (new Android uid). Arch Linux ARM's default user alarm goes, as in the VM build.
U=$(stat -c %u /data/data/com.powos.app)
chroot $R /usr/bin/env -i PATH=/usr/bin:/usr/sbin /bin/bash -s "$U" <<'EOF'
u=$1
id alarm >/dev/null 2>&1 && userdel -r alarm 2>/dev/null
sed -i "/^android:x:$u:/d" /etc/passwd            # the no-root engine's name for the app uid (session/first-boot.sh)
getent group powos >/dev/null || groupadd -g "$u" powos
[ "$(getent group powos | cut -d: -f3)" = "$u" ] || groupmod -g "$u" powos
if ! id powos >/dev/null 2>&1; then
  useradd -m -u "$u" -g powos -s /bin/bash powos && echo powos:powos | chpasswd
elif [ "$(id -u powos)" != "$u" ]; then
  usermod -u "$u" powos
fi
usermod -aG wheel,video,audio,input powos
echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/10-wheel && chmod 440 /etc/sudoers.d/10-wheel
echo "user powos uid $u"
EOF

# The no-root engine's sudo shim (fakeroot) first on PATH would shadow the real sudo: rooted mode has real root.
# Moved aside, not deleted; the no-root app's own rootfs keeps it.
S=$R/usr/local/bin/sudo
[ -f $S ] && mv $S $S.noroot-engine && echo "sudo: real sudo (shim moved to $S.noroot-engine)"
resetprop -p persist.powos.root 1
echo "deployed (persist.powos.root=$(getprop persist.powos.root))"
