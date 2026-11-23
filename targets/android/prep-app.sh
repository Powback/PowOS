#!/bin/bash
# The PowOS APK's inputs that aren't in git, staged into a checkout before Gradle runs - one place for every APK build:
# build-app.sh (ships) and tools/emu/emu.sh (the emulator lane's warm build, PUBLISH=0). The emulator lane called the
# warm builder without them and every build failed at CMake ("Run sources/powstream/build-android.sh before native/APK
# builds", 11-23, f524): a build path that skips a staging step must not exist, so both run this.
#   prep-app.sh [ROOT]   ROOT: the checkout (default: this script's); its own pins and apps are used
# Exit 6: an app of apps/bundled.list didn't build. POWOS_SKIP_APPS=1 for a deliberate local experiment (the APK then
# ships whatever bundled-apps/ holds).
set -euo pipefail
ROOT=$(cd "${1:-$(dirname "$0")/../..}" && pwd)
HERE=$ROOT/targets/android
# The pinned PowStream Android client (engine/powstream-native, gitignored; CMakeLists.txt refuses without it).
bash "$ROOT/sources/powstream/build-android.sh"
# The PowOS apps the APK ships (apps/bundled.list), built now from this commit, so the APK carries their UIs and modules
# at its own version - a phone without root has no `powos app install` (docs/research/nonroot-parity.md #2). Each is
# staged with the no-root services' starter in app/app/bundled-apps/ (gitignored), the one folder
# app/build.gradle.kts copyApps packs as assets/apps/<app id>/{powos-app.json, ui/, module.wasm}: inside the Gradle
# project, so the warm builder's /work mirror (tools/warm-builder.sh copies app/ and shell/ only) has them too - it
# read apps/*/out from the repo before, which /work hasn't, and every APK from it shipped no app and no starter (razr
# 11-10: no island, no service). A line of bundled.list is an app of apps/ or another repo's app folder (~/Projects/
# lights). apps/build.sh's caches make an unchanged app quick.
STAGE=$HERE/app/app/bundled-apps
# An app's folder from its bundled.list line: a name under apps/, else a path (~ = $HOME).
app_dir() { case $1 in */*) echo "${1/#\~/$HOME}" ;; *) echo "$ROOT/apps/$1" ;; esac; }
# Builds the line's app and stages it by its id; fails (the build's tail on stderr) when it doesn't build complete.
stage_app() {
  local d id log
  d=$(app_dir "$1"); log=$(mktemp)
  [ -f "$d/powos-app.json" ] || { echo "prep-app: $1: no powos-app.json at $d" >&2; return 1; }
  "$ROOT/apps/build.sh" "$d" > "$log" 2>&1 || { tail -20 "$log" >&2; rm -f "$log"; return 1; }
  rm -f "$log"
  [ ! -d "$d/ui" ] || [ -d "$d/out/ui" ] || { echo "prep-app: $1: no out/ui" >&2; return 1; }
  [ ! -f "$d/module/Cargo.toml" ] || [ -f "$d/out/module.wasm" ] || { echo "prep-app: $1: no out/module.wasm" >&2; return 1; }
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
    stage_app "$a" || { echo "prep-app: refusing - apps/build.sh $a failed (above): the APK would ship without it" >&2; exit 6; }
  done
fi
# The APK's shell stamp (assets/shell/shell-build.txt via build.gradle.kts copyShell): "<commit time> <commit>", which
# the app compares with the shipped layer's (shell/push.sh: files/shell-layer.txt) to serve the NEWER shell (ShellSource).
git -C "$ROOT" log -1 --format='%ct %H' HEAD > "$HERE/app/app/shell-build.txt"
