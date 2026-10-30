#!/bin/bash
# Builds s0.jar (dex) in the android-builder image: javac 17 against android-36, then d8.
set -euo pipefail
cd "$(dirname "$0")"
docker run --rm -v "$PWD:/w" -w /w android-app-dev-android-builder sh -c '
  rm -rf build/classes build/j && mkdir -p build/classes &&
  javac -source 17 -target 17 -cp /opt/android-sdk/platforms/android-36/android.jar -d build/classes S0.java &&
  /opt/android-sdk/build-tools/35.0.0/d8 --min-api 34 --output build build/classes/*.class --lib /opt/android-sdk/platforms/android-36/android.jar &&
  cd build && mv classes.dex classes.dex.tmp && mkdir -p j && mv classes.dex.tmp j/classes.dex && cd j && jar cf ../s0.jar classes.dex'
ls -la build/s0.jar
