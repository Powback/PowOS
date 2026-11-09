#!/bin/bash
# Builds the PowOS LSPosed module for OnePlus's launcher (targets/android/oplus-hook, see its README.md) with
# android-app-dev's build system, as build-app.sh does for the PowOS app. Output: android-app-dev
# output/powos-oplus-hook.apk (+ published at http://android.pow/apk/powos-oplus-hook.apk).
#
# Usage: targets/android/build-oplus-hook.sh
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
AAD=${ANDROID_APP_DEV:-$HOME/Projects/android-app-dev}
# android-app-dev's builder mounts only ~/Projects (as /Projects): from a checkout elsewhere (~/pw) the project link
# would point nowhere (and repointing it breaks the next build from ~/Projects). Same guard as build-app.sh.
case "$HERE/" in "$HOME/Projects/"*) ;; *)
  echo "build-oplus-hook: refusing - $HERE is outside ~/Projects, the only dir the APK builder mounts" >&2; exit 5 ;; esac
want=/Projects${HERE#$HOME/Projects}/oplus-hook
link=$AAD/projects/powos-oplus-hook
[ "$(readlink "$link" 2>/dev/null)" = "$want" ] || { rm -f "$link"; ln -s "$want" "$link"; }
stamp=$(mktemp)
make -C "$AAD" build PROJECT=powos-oplus-hook
# HACK: android-app-dev's `make build` exits 0 when Gradle fails (see build-app.sh).
if [ ! "$AAD/output/powos-oplus-hook.apk" -nt "$stamp" ]; then
  rm -f "$stamp"
  echo "build-oplus-hook: no new APK - the build failed (see the Gradle errors above)" >&2
  exit 1
fi
rm -f "$stamp"
echo "built: $AAD/output/powos-oplus-hook.apk"
