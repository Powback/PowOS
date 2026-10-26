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
# The APK ships shell/ and the app sources as they are on disk. In a checkout several agents share, that is other
# agents' half-done work too (2026-10-20: an in-progress shell/apps/pages.ts in APK 29874211 left home and the lock
# face without JS). So build only committed code: refuse while either has uncommitted or untracked changes.
# POWOS_BUILD_DIRTY=1 overrides it, for a deliberate local experiment.
ROOT=$(git -C "$HERE" rev-parse --show-toplevel)
dirty=$(git -C "$ROOT" status --porcelain -- shell targets/android/app | grep -v 'app/version.properties$' || true)
if [ -n "$dirty" ] && [ "${POWOS_BUILD_DIRTY:-}" != 1 ]; then
  echo "build-app: refusing - uncommitted changes would ship in the APK (commit them, or POWOS_BUILD_DIRTY=1):" >&2
  echo "$dirty" | sed 's/^/  /' >&2
  exit 3
fi
# The complexity lint (targets/android/lint-complexity.sh: per function cyclomatic/cognitive 10, depth 3, 60 lines,
# 4 params; old debt in app/config/detekt-baseline.xml, which only shrinks): a function over it doesn't ship.
# POWOS_SKIP_COMPLEXITY=1 for a deliberate local experiment; exit 2 (no docker/image/jar) only warns.
if [ "${POWOS_SKIP_COMPLEXITY:-}" != 1 ]; then
  cx=0; "$HERE/lint-complexity.sh" || cx=$?
  if [ "$cx" = 1 ]; then echo "build-app: refusing - the complexity lint failed (above)" >&2; exit 4; fi
fi
AAD=${ANDROID_APP_DEV:-$HOME/Projects/android-app-dev}
# android-app-dev's builder mounts only ~/Projects (as /Projects): a checkout elsewhere (~/pw) can't build there.
case "$HERE/" in "$HOME/Projects/"*) ;; *)
  echo "build-app: refusing - $HERE is outside ~/Projects, the only dir the APK builder mounts; build from a checkout under ~/Projects" >&2; exit 5 ;; esac
want=/Projects${HERE#$HOME/Projects}/app
link=$AAD/projects/powos
[ "$(readlink "$link" 2>/dev/null)" = "$want" ] || { rm -f "$link"; ln -s "$want" "$link"; }
stamp=$(mktemp)
# The warm builder (tools/warm-builder.sh, unit gradle-warm-mac: a long-lived Gradle daemon - no cold JVM, Gradle and
# Kotlin daemon per APK) when it starts and answers; android-app-dev's cold `make build` otherwise, or with
# POWOS_COLD_BUILD=1. Both publish output/powos.apk + .ver + .pkg the same way.
if [ "${POWOS_COLD_BUILD:-}" != 1 ] && "$HERE/tools/warm-builder.sh" start >/dev/null 2>&1; then
  echo "build-app: warm builder"
  "$HERE/tools/warm-builder.sh" build "$want" || { echo "build-app: the warm build failed - building cold" >&2; make -C "$AAD" build PROJECT=powos; }
else
  echo "build-app: cold build (android-app-dev make build)"
  make -C "$AAD" build PROJECT=powos
fi
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
