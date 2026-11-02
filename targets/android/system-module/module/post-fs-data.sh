#!/system/bin/sh
# The boot watchdog. Counts boots that started; service.sh clears the count once Android has finished booting. Two
# that never got there and the module turns itself off (Magisk skips a module with a `disable` file), so a bad PowOS
# system build can't keep the phone from booting. Also: Magisk safe mode, or `magisk --remove-modules` over adb.
MODDIR=${0%/*}
COUNT=$MODDIR/boot-attempts
n=$(cat "$COUNT" 2>/dev/null || echo 0)
if [ "$n" -ge 2 ]; then
    touch "$MODDIR/disable"
    echo 0 > "$COUNT"
    log -t powos-system "two boots didn't finish: module disabled"
    exit 0
fi
echo $((n + 1)) > "$COUNT"
# The split screen divider menu's orientation item, for every app (split-orientation.sh): before Magisk's mount.
sh "$MODDIR/split-orientation.sh" build
# Android's package cache (/data/system/package_cache/<fingerprint hash>/<dir or apk name>-<flags>-<path hash>) is
# trusted over a replaced system APK: after the 11-02 module update the phone kept the old PowOS priv-app (version
# 29872953) through a reboot, so the update's privileged permissions (WATCH_APPOPS) were never granted - an updated
# system app gets only the privileged permissions its system copy requests. So whenever the module's APKs (the
# priv-app and the overlays, all named PowOS*) change, their cache entries go before system_server starts and the
# next scan parses them again. The stamp lives outside the module dir: a module update replaces that dir.
STAMP=/data/adb/powos-system-apks.sha
sum=$(find "$MODDIR/system" -name '*.apk' -type f 2>/dev/null | sort | xargs -r sha256sum 2>/dev/null | sha256sum | cut -d' ' -f1)
if [ "$sum" != "$(cat "$STAMP" 2>/dev/null)" ]; then
    rm -f /data/system/package_cache/*/PowOS-*
    echo "$sum" > "$STAMP"
    log -t powos-system "module APKs changed: package cache entries cleared"
fi
