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
# The PowOS apps the APK ships (apps/bundled.list), built now from this commit, so the APK carries their UIs and modules
# at its own version - a phone without root has no `powos app install` (docs/research/nonroot-parity.md #2). Each is
# staged with the no-root services' starter in app/app/bundled-apps/ (gitignored), the one folder
# app/build.gradle.kts copyApps packs as assets/apps/<app id>/{powos-app.json, ui/, module.wasm}: inside the Gradle
# project, so the warm builder's /work mirror (tools/warm-builder.sh copies app/ and shell/ only) has them too - it
# read apps/*/out from the repo before, which /work hasn't, and every APK from it shipped no app and no starter (razr
# 11-10: no island, no service). A line of bundled.list is an app of apps/ or another repo's app folder (~/Projects/
# lights). apps/build.sh's caches make an unchanged app quick. POWOS_SKIP_APPS=1 for a deliberate local experiment
# (the APK then ships whatever bundled-apps/ holds).
STAGE=$HERE/app/app/bundled-apps
# An app's folder from its bundled.list line: a name under apps/, else a path (~ = $HOME).
app_dir() { case $1 in */*) echo "${1/#\~/$HOME}" ;; *) echo "$ROOT/apps/$1" ;; esac; }
# Builds the line's app and stages it by its id; fails (the build's tail on stderr) when it doesn't build complete.
stage_app() {
  local d id log
  d=$(app_dir "$1"); log=$(mktemp)
  [ -f "$d/powos-app.json" ] || { echo "build-app: $1: no powos-app.json at $d" >&2; return 1; }
  "$ROOT/apps/build.sh" "$d" > "$log" 2>&1 || { tail -20 "$log" >&2; rm -f "$log"; return 1; }
  rm -f "$log"
  [ ! -d "$d/ui" ] || [ -d "$d/out/ui" ] || { echo "build-app: $1: no out/ui" >&2; return 1; }
  [ ! -f "$d/module/Cargo.toml" ] || [ -f "$d/out/module.wasm" ] || { echo "build-app: $1: no out/module.wasm" >&2; return 1; }
  id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$d/powos-app.json")
  mkdir -p "$STAGE/apps/$id"
  cp "$d/powos-app.json" "$STAGE/apps/$id/"
  [ ! -d "$d/out/ui" ] || cp -R "$d/out/ui" "$STAGE/apps/$id/ui"
  [ ! -f "$d/out/module.wasm" ] || cp "$d/out/module.wasm" "$STAGE/apps/$id/"
}
if [ "${POWOS_SKIP_APPS:-}" != 1 ]; then
  rm -rf "$STAGE" && mkdir -p "$STAGE/apps"
  cp "$ROOT/lib/apps/powos-noroot-services" "$STAGE/"
  for a in $(sed 's/#.*//' "$ROOT/apps/bundled.list"); do
    stage_app "$a" || { echo "build-app: refusing - apps/build.sh $a failed (above): the APK would ship without it" >&2; exit 6; }
  done
fi
AAD=${ANDROID_APP_DEV:-$HOME/Projects/android-app-dev}
# android-app-dev's builder mounts only ~/Projects (as /Projects): a checkout elsewhere (~/pw) can't build there.
case "$HERE/" in "$HOME/Projects/"*) ;; *)
  echo "build-app: refusing - $HERE is outside ~/Projects, the only dir the APK builder mounts; build from a checkout under ~/Projects" >&2; exit 5 ;; esac
want=/Projects${HERE#$HOME/Projects}/app
link=$AAD/projects/powos
[ "$(readlink "$link" 2>/dev/null)" = "$want" ] || { rm -f "$link"; ln -s "$want" "$link"; }
# The APK's shell stamp (assets/shell/shell-build.txt via build.gradle.kts copyShell): "<commit time> <commit>", which
# the app compares with the shipped layer's (shell/push.sh: files/shell-layer.txt) to serve the NEWER shell (ShellSource).
git -C "$ROOT" log -1 --format='%ct %H' HEAD > "$HERE/app/app/shell-build.txt"
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
# Every staged app and the starter in the APK: a builder that couldn't see them shipped none, silently (11-10).
if [ "${POWOS_SKIP_APPS:-}" != 1 ]; then
  have=$(unzip -l "$AAD/output/powos.apk" 'assets/apps/*/powos-app.json' 'assets/powos-noroot-services' 2>/dev/null || true)
  for want in powos-noroot-services $(cd "$STAGE/apps" && printf 'apps/%s/powos-app.json ' *); do
    case $have in *"assets/$want"*) ;; *) echo "build-app: the APK lacks assets/$want (app/app/bundled-apps not packed)" >&2; exit 7 ;; esac
  done
fi
echo "published: http://android.pow/apk/powos.apk (version code $(cat "$AAD/output/powos.ver"))"
# The same commit's shell bundle and PowOS code (powos-core) for the phones that pull their updates (no adb: the S25,
# the razr - docs/PHONE-UPDATES.md). Only from origin's history; a failure only warns: the APK stands.
"$HERE/publish-shell.sh" "$AAD/output" || echo "build-app: publish-shell failed - the pull phones keep their shell" >&2
"$HERE/build-powos-core.sh" --publish || echo "build-app: powos-core not published - the pull phones keep their code" >&2
