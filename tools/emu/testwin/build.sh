#!/bin/bash
# tools/emu/testwin/build.sh: builds the emulator's test window client (AndroidManifest.xml + src/) with the SDK in
# the android-builder image (javac, d8, aapt2, apksigner; its own throwaway signing key under ~/.cache/powos-emu) and
# prints the APK's path. Rebuilt only when a source is newer than the APK.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
out=$HOME/.cache/powos-emu/testwin; apk=$out/testwin.apk; mkdir -p "$out"
if [ -f "$apk" ] && [ -z "$(find "$here" -newer "$apk" -type f)" ]; then echo "$apk"; exit 0; fi
docker run --rm -v "$here:/src:ro" -v "$out:/out" --entrypoint bash android-app-dev-android-builder:latest -c '
  set -euo pipefail; B=/opt/android-sdk/build-tools/35.0.0; J=/opt/android-sdk/platforms/android-36/android.jar
  rm -rf /tmp/t && mkdir -p /tmp/t/classes /tmp/t/dex
  javac -source 8 -target 8 -nowarn -bootclasspath "$J" -d /tmp/t/classes $(find /src/src -name "*.java") 2>&1 | grep -v "^warning" || true
  "$B/d8" --release --min-api 30 --lib "$J" --output /tmp/t/dex $(find /tmp/t/classes -name "*.class")
  "$B/aapt2" link -o /tmp/t/base.apk -I "$J" --manifest /src/AndroidManifest.xml
  (cd /tmp/t/dex && zip -q /tmp/t/base.apk classes.dex)
  "$B/zipalign" -f 4 /tmp/t/base.apk /tmp/t/aligned.apk
  [ -f /out/key.jks ] || keytool -genkeypair -keystore /out/key.jks -storepass testwin -keypass testwin -alias t -keyalg RSA -keysize 2048 -validity 36500 -dname "CN=PowOS emulator test window" >/dev/null 2>&1
  "$B/apksigner" sign --ks /out/key.jks --ks-pass pass:testwin --out /out/testwin.apk /tmp/t/aligned.apk' >&2
echo "$apk"
