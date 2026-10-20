#!/system/bin/sh
# `powos units` on the phone's Android side (lib/apps/powos-units, POWOS_UNITS_HOST=phone-android): Magisk's modules,
# /data/powos, /data/adb's boot scripts, /data/local/tmp and what root runs outside PowOS. PowOS's own python, run
# from Android's side through PowOS's dynamic loader (as powos-start.sh starts the system tier): no chroot, so it
# sees Android's /data. Installed by powos-deploy.sh as /data/powos/powos-units.sh.
#   sh /data/powos/powos-units.sh list|show|check|remove|enforce ...   (powos units --help)
R=/data/powos/root
export PYTHONHOME=$R/usr POWOS_UNITS_HOST=phone-android
exec "$R/usr/lib/ld-linux-aarch64.so.1" --library-path "$R/usr/lib" "$R/usr/bin/python3" \
  "$R/usr/lib/powos/apps/powos-units" "$@"
