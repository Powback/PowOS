#!/bin/bash
# Patches a stock init_boot.img with Magisk ON THE PHONE over adb (Magisk's own boot_patch.sh, as the Magisk app
# would run it) - no taps in the app, nothing flashed. The result is the one temporary write of the bring-up:
# `fastboot flash init_boot_<slot>` it, back up with root (phone.sh backup), then flash the stock image back.
#   tools/magisk-patch.sh <Magisk-vX.apk> <stock init_boot.img> <out patched.img>
set -euo pipefail
apk=$1 img=$2 out=$3
W=/data/local/tmp/powos-magisk
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
# The patch script and the arm64 tools inside the APK, under the names boot_patch.sh expects.
unzip -q -o "$apk" 'assets/*' 'lib/arm64-v8a/*' -d "$T"
mkdir -p "$T/w"
cp "$T"/assets/boot_patch.sh "$T"/assets/util_functions.sh "$T"/assets/stub.apk "$T/w/"
for f in "$T"/lib/arm64-v8a/lib*.so; do
  n=$(basename "$f" .so); cp "$f" "$T/w/${n#lib}"
done
adb shell "rm -rf $W && mkdir -p $W"
adb push -q "$T"/w/. "$W/"
adb push -q "$img" "$W/stock.img"
adb shell "cd $W && chmod 755 * && sh boot_patch.sh $W/stock.img" 2>&1 | tail -15
adb pull -q "$W/new-boot.img" "$out"
adb shell "rm -rf $W"
ls -la "$out"
