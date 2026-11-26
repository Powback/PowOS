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
# The staged app from the build-inputs cache (tools/agents/build-inputs-cache.sh), keyed by everything apps/build.sh
# reads: the app folder's tracked files (git's blob ids), apps/build.sh, the shared UI blocks, the SpacetimeDB pin, the
# Rust lint. A fresh worktree built all ~10 apps from scratch here (~6 min, 11-25) for the same bytes every checkout of
# those sources gets. Only a clean source is cached either way: uncommitted or untracked changes in any of those -> "".
# PREP_APPS_NO_CACHE=1 builds anyway.
BIC=$ROOT/tools/agents/build-inputs-cache.sh
SHARED_INPUTS=(apps/build.sh shell/ui/shared targets/android/pkgs/spacetimedb-bin/PKGBUILD tools/lint/rust-complexity.sh)
app_key() {
  local d=$1
  [ -z "${PREP_APPS_NO_CACHE:-}" ] && [ -x "$BIC" ] || return 0
  git -C "$d" rev-parse --git-dir >/dev/null 2>&1 || return 0
  [ -z "$(git -C "$d" status --porcelain -- . 2>/dev/null)" ] || return 0
  [ -z "$(git -C "$ROOT" status --porcelain -- "${SHARED_INPUTS[@]}" 2>/dev/null)" ] || return 0
  { git -C "$d" ls-files -s -- .; git -C "$ROOT" ls-files -s -- "${SHARED_INPUTS[@]}"; } | shasum -a 256 | cut -c1-32
}
# Builds the line's app and stages it by its id; fails (the build's tail on stderr) when it doesn't build complete.
stage_app() {
  local d id log key t
  d=$(app_dir "$1"); log=$(mktemp)
  [ -f "$d/powos-app.json" ] || { echo "prep-app: $1: no powos-app.json at $d" >&2; return 1; }
  id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$d/powos-app.json")
  key=$(app_key "$d")
  if [ -n "$key" ]; then
    t=$(mktemp -d)
    # Extracted from a tar (new files): nothing written later can reach the cached blob through a hardlink.
    if "$BIC" get "bundled-apps/$id/$key.tar" "$t/a.tar" >/dev/null 2>&1 && tar -xf "$t/a.tar" -C "$STAGE/apps" &&
       [ -f "$STAGE/apps/$id/powos-app.json" ]; then
      rm -rf "$t" "$log"; echo "prep-app: $id from the build-inputs cache"; return 0
    fi
    rm -rf "$t" "$STAGE/apps/$id"
  fi
  "$ROOT/apps/build.sh" "$d" > "$log" 2>&1 || { tail -20 "$log" >&2; rm -f "$log"; return 1; }
  rm -f "$log"
  [ ! -d "$d/ui" ] || [ -d "$d/out/ui" ] || { echo "prep-app: $1: no out/ui" >&2; return 1; }
  [ ! -f "$d/module/Cargo.toml" ] || [ -f "$d/out/module.wasm" ] || { echo "prep-app: $1: no out/module.wasm" >&2; return 1; }
  mkdir -p "$STAGE/apps/$id"
  cp "$d/powos-app.json" "$STAGE/apps/$id/"
  [ ! -d "$d/out/ui" ] || cp -R "$d/out/ui" "$STAGE/apps/$id/ui"
  [ ! -f "$d/out/module.wasm" ] || cp "$d/out/module.wasm" "$STAGE/apps/$id/"
  # Into the cache for the next checkout of the same sources (best-effort).
  if [ -n "$key" ]; then
    t=$(mktemp -d)
    COPYFILE_DISABLE=1 tar -cf "$t/a.tar" -C "$STAGE/apps" "$id" && "$BIC" put "$t/a.tar" "bundled-apps/$id/$key.tar" >/dev/null || true
    rm -rf "$t"
  fi
}
if [ "${POWOS_SKIP_APPS:-}" != 1 ]; then
  rm -rf "$STAGE" && mkdir -p "$STAGE/apps"
  cp "$ROOT/lib/apps/powos-noroot-services" "$ROOT/lib/apps/powos-account-sync" "$STAGE/"
  for a in $(sed 's/#.*//' "$ROOT/apps/bundled.list"); do
    stage_app "$a" || { echo "prep-app: refusing - apps/build.sh $a failed (above): the APK would ship without it" >&2; exit 6; }
  done
fi
# The APK's shell stamp (assets/shell/shell-build.txt via build.gradle.kts copyShell): "<commit time> <commit>", which
# the app compares with the shipped layer's (shell/push.sh: files/shell-layer.txt) to serve the NEWER shell (ShellSource).
git -C "$ROOT" log -1 --format='%ct %H' HEAD > "$HERE/app/app/shell-build.txt"
