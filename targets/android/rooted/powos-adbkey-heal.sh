#!/system/bin/sh
# PowOS: restore the Mac's adb key at boot if the phone dropped it (fixes the 11-08 lockout).
# Waits for /data, then runs the guarded heal (append-only, that one key only).
until [ -d /data/misc/adb ] && [ -f /data/powos/adb-key-heal.sh ]; do sleep 2; done
sleep 8
sh /data/powos/adb-key-heal.sh
