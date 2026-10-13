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
make -C "$AAD" build PROJECT=powos
echo "published: http://android.pow/apk/powos.apk (version code $(cat "$AAD/output/powos.ver"))"
