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

S=$R/usr/local/bin/sudo
if [ -f $S ] && ! grep -q 'PowOS rooted mode' $S; then
  awk '{print} /# already fake root$/ {
    print "# PowOS rooted mode (patches/andromarchy/0004): real root in a real chroot - nothing to fake."
    print "[ \"$(id -u)\" = 0 ] && [ -z \"${FAKECHROOT_BASE:-}\" ] && exec \"$@\""
  }' $S > $S.new && chmod 755 $S.new && mv $S.new $S
  echo "sudo shim: rooted-mode passthrough added"
fi
resetprop -p persist.powos.root 1
echo "deployed (persist.powos.root=$(getprop persist.powos.root))"
