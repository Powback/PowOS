#!/system/bin/sh
# Android finished booting with the module in place: the watchdog's count starts again (post-fs-data.sh).
MODDIR=${0%/*}
# The containers kernel's nftables modules, when the module carries them (load-kernel-modules.sh).
[ -f "$MODDIR/load-kernel-modules.sh" ] && sh "$MODDIR/load-kernel-modules.sh" &
until [ "$(getprop sys.boot_completed)" = 1 ]; do sleep 2; done
echo 0 > "$MODDIR/boot-attempts"
