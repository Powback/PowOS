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
