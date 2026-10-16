#!/bin/bash
# Builds the PowOS Android app (targets/android/app: Omalauncher fork + Andromarchy engine) with android-app-dev's
# build system, which is also the PowApps store: `make build PROJECT=powos` stamps the version
# (app/version.properties, read by app/build.gradle.kts), signs with the shared persistent debug key, and
# publishes output/powos.apk + powos.ver at http://android.pow/apk/ - phones install/update it from PowApps.
#
# android-app-dev/projects/powos is a symlink to this directory (/Projects is mounted into its builder), like
# projects/powpass.
#
# Usage: targets/android/build-app.sh
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
AAD=${ANDROID_APP_DEV:-$HOME/Projects/android-app-dev}
want=/Projects${HERE#$HOME/Projects}/app
link=$AAD/projects/powos
[ "$(readlink "$link" 2>/dev/null)" = "$want" ] || { rm -f "$link"; ln -s "$want" "$link"; }
stamp=$(mktemp)
make -C "$AAD" build PROJECT=powos
# HACK: android-app-dev's `make build` exits 0 when Gradle fails and leaves the previous output/powos.apk (seen
# 2026-10-16: compile errors, "published" the old version code). Real fix: propagate the builder's exit status in
# android-app-dev's Makefile. Until then: the APK must be newer than this run's start.
if [ ! "$AAD/output/powos.apk" -nt "$stamp" ]; then
  rm -f "$stamp"
  echo "build-app: no new APK - the build failed (see the Gradle errors above); output/powos.apk is the old one" >&2
  exit 1
fi
rm -f "$stamp"
echo "published: http://android.pow/apk/powos.apk (version code $(cat "$AAD/output/powos.ver"))"
