#!/system/bin/sh
# Android finished booting with the module in place: the watchdog's count starts again (post-fs-data.sh).
MODDIR=${0%/*}
until [ "$(getprop sys.boot_completed)" = 1 ]; do sleep 2; done
echo 0 > "$MODDIR/boot-attempts"
