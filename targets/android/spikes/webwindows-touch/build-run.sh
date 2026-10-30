#!/bin/bash
# Builds T1.java (a trusted VD as shell, optionally with a uinput touchscreen associated to it) and prints each
# variant's display configuration touch field: bare "-touch", SUPPORTS_TOUCH alone "-touch", SUPPORTS_TOUCH + the
# associated device "finger" (2026-10-30). Nothing shown, nothing launched. Used by WebWindowsHost.Touch's note.
set -euo pipefail
cd "$(dirname "$0")"
ADB=../../../../tools/phone/adb.sh
docker run --rm -v "$PWD:/w" -w /w android-app-dev-android-builder sh -c '
  rm -rf build && mkdir -p build/classes build/j &&
  javac -source 17 -target 17 -cp /opt/android-sdk/platforms/android-36/android.jar -d build/classes T1.java &&
  /opt/android-sdk/build-tools/35.0.0/d8 --min-api 34 --output build/j build/classes/*.class --lib /opt/android-sdk/platforms/android-36/android.jar &&
  cd build/j && jar cf ../t1.jar classes.dex'
chmod 444 build/t1.jar
$ADB push build/t1.jar /data/local/tmp/t1.jar >/dev/null
$ADB push t1.json /data/local/tmp/t1.json >/dev/null
$ADB shell 'su -c '"'"'R="CLASSPATH=/data/local/tmp/t1.jar app_process /system/bin T1"
run() { su -g 2000 -G 3011 2000 -c "$R $1 4000 $2" > /data/local/tmp/t1.out 2>&1 & sleep 2.5
  ID=$(grep -m1 "^T1 VD" /data/local/tmp/t1.out | cut -d" " -f3)
  echo "flags $1 ${2:+uinput} display $ID: $(dumpsys window displays | grep -A4 "Display: mDisplayId=$ID " | grep -oE " (finger|-touch)( |$)")"; wait; }
run 0x509; run 0x549; run 0x549 /data/local/tmp/t1.json
rm -f /data/local/tmp/t1.out /data/local/tmp/t1.jar /data/local/tmp/t1.json'"'"
