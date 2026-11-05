#!/bin/bash
# build.sh <outdir>: (Mac) libdstest.so (NDK clang, Mac SDK) + dstest.dex (javac + d8 in the android builder image,
# android-36 android.jar) for tools/phone/verify/direct-scanout.sh.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
OUTD=${1:?outdir}; mkdir -p "$OUTD"; OUTD=$(cd "$OUTD" && pwd)
NDK=${NDK:-$(ls -d "$HOME"/Library/Android/sdk/ndk/28.* 2>/dev/null | tail -1)}
CC=$NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin/aarch64-linux-android35-clang
[ -x "$CC" ] || { echo "ENV: no NDK clang at $CC"; exit 5; }
"$CC" -shared -fPIC -O2 -Wall -o "$OUTD/libdstest.so" "$here/dstest.c" -landroid -lnativewindow -ldl
cp "$here/DsTest.java" "$OUTD/"
# The image has the JDK + build-tools; the source goes in through a bind mount of the out dir (under $HOME, shared).
docker run --rm -v "$OUTD:/w" -w /w --entrypoint bash android-app-dev-android-builder:latest -c '
  set -e; J=/opt/android-sdk/platforms/android-36/android.jar
  mkdir -p cls && javac -source 11 -target 11 -cp $J -d cls DsTest.java 2>&1 | grep -v "^warning\|bootstrap" || true
  /opt/android-sdk/build-tools/35.0.0/d8 --min-api 34 --lib $J --output . cls/DsTest.class
  mv classes.dex dstest.dex; rm -rf cls'
ls -l "$OUTD/libdstest.so" "$OUTD/dstest.dex"
