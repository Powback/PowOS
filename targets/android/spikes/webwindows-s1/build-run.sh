#!/bin/bash
# Builds P1.java to a dex jar in the android-builder image and runs the S1 permission probe on the phone (nothing shown,
# nothing launched; every display's output is a 1x1 ImageReader). Results: docs/WEB_WINDOWS.md "S1-S3 (built)".
set -euo pipefail
cd "$(dirname "$0")"
ADB=../../../../tools/phone/adb.sh
docker run --rm -v "$PWD:/w" -w /w android-app-dev-android-builder sh -c '
  rm -rf build && mkdir -p build/classes build/j &&
  javac -source 17 -target 17 -cp /opt/android-sdk/platforms/android-36/android.jar -d build/classes P1.java &&
  /opt/android-sdk/build-tools/35.0.0/d8 --min-api 34 --output build/j build/classes/*.class --lib /opt/android-sdk/platforms/android-36/android.jar &&
  cd build/j && jar cf ../p1.jar classes.dex'
chmod 444 build/p1.jar   # ART refuses a writable dex
$ADB push build/p1.jar /data/local/tmp/p1.jar >/dev/null
# PowOS = uid 10359, Chrome = 10194 on the test phone (dumpsys package <pkg> | grep appId=).
$ADB shell 'chmod 444 /data/local/tmp/p1.jar; R="CLASSPATH=/data/local/tmp/p1.jar app_process /system/bin P1"
T=com.android.chrome/org.chromium.chrome.browser.ChromeTabbedActivity
for f in 0x109 0x509 0x909 0x1109; do su 10359 -c "$R make com.powos.app $f 10" 2>&1 | grep P1; done
for who in "10359 com.powos.app 0x109" "2000 com.android.shell 0x509"; do set -- $who
  su $1 -c "$R make $2 $3 5000" > /data/local/tmp/p1.out 2>&1 &
  sleep 2; ID=$(grep -m1 "^VD " /data/local/tmp/p1.out | cut -d" " -f2)
  su 10194 -c "$R allowed com.android.chrome $ID $T" 2>&1 | grep P1
  su 10359 -c "$R allowed com.powos.app $ID $T" 2>&1 | grep P1
  su 10359 -c "$R mirror com.powos.app $ID" 2>&1 | grep P1
  wait; grep P1 /data/local/tmp/p1.out
done
rm -f /data/local/tmp/p1.out /data/local/tmp/p1.jar'
