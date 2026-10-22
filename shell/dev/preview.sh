#!/bin/bash
# The widget preview: every widget - the shell's panels, the OWL widgets, PowOS apps' islands - at every size it allows
# (minSize to 4x4) on the cover screen's cells and the inner screen's, in two themes, against mock data (and live http
# with --live), as one contact-sheet PNG per widget, with the fit checks run on every tile:
#   clipped text, a row cut in half, content that leaves more than 12% of a side of the tile empty, a tile that
#   scrolls, a hard border; and a widget's screen (its onTap's screen()) on both screens: its content across the
#   screen, no hard border, its backdrop not showing what's behind.
# Any of these fails it (exit 1), each listed with the tile's size. `powos app preview` runs this; so does the gate
# (gate.sh --widgets).
#
#   shell/dev/preview.sh [--dir SHELL] [--out DIR] [--only REGEX] [--live] [--themes "gruvbox nord"]
#                        [--owl FILE|DIR]... [--app APPDIR]... [--wallpaper FILE] [--no-defaults] [--fast]
#
# --dir: the shell to render (default: this one, as it is on disk). --owl: OWL widgets beyond (or instead of, by file
# name) the app's own (targets/android/app/.../assets/widgets, examples/ too). --app: a PowOS app's folder
# (powos-app.json + out/ui/, built) - the repo's apps/* with a built UI are always included unless --no-defaults.
# Mock data: shell/dev/preview/data/<widget id>.json (an OWL widget's sources by name - {"seq": [...]} feeds several
# updates, so history() fills - or an app's {rows, net}). Out: DIR/<widget id>.png, DIR/report.json
# (default ~/.cache/powos-preview/out), DIR/baseline.json (the problems found, as dev/preview/baseline.json lists the
# known ones: those are reported, not failed - PREVIEW_BASELINE=0 fails them too). --fast: the gate's run - checks
# only, one theme, no sheets.
#
# The OWL engine runs off the phone: `owl trees` (targets/android/app/owl, the language's own JVM CLI - built here
# into owl/build/cli/owl.jar on first use, in the Android builder image) evaluates each widget at each size; the page
# draws those trees with the shell's own renderer (ui/owl.tsx), in the gate's headless Chromium.
set -euo pipefail
SHELL_DIR=$(cd "$(dirname "$0")/.." && pwd)
REPO=$(cd "$SHELL_DIR/.." && pwd)
IMAGE=${GATE_IMAGE:-zenika/alpine-chrome:with-puppeteer}
JVM_IMAGE=${PREVIEW_JVM_IMAGE:-android-app-dev-android-builder:latest}
GRADLE_VOLUME=${PREVIEW_GRADLE_VOLUME:-powos-android-gradle}
dir="" out="${XDG_CACHE_HOME:-$HOME/.cache}/powos-preview/out" only="" live=0 themes="gruvbox nord" wallpaper="" defaults=1 fast=0
owls=() apps=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) dir=$(cd "$2" && pwd); shift 2 ;;
    --out) mkdir -p "$2"; out=$(cd "$2" && pwd); shift 2 ;;
    --only) only=$2; shift 2 ;;
    --live) live=1; shift ;;
    --themes) themes=$2; shift 2 ;;
    --owl) owls+=("$2"); shift 2 ;;
    --app) apps+=("$(cd "$2" && pwd)"); shift 2 ;;
    --wallpaper) wallpaper=$2; shift 2 ;;
    --no-defaults) defaults=0; shift ;;
    --fast) fast=1; shift ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "preview: unknown argument $1" >&2; exit 2 ;;
  esac
done
command -v docker >/dev/null || { echo "preview: no docker" >&2; exit 2; }
t0=$(date +%s)
mkdir -p "$out" "${XDG_CACHE_HOME:-$HOME/.cache}/powos-preview"
# Under $HOME: Colima's VM mounts the home folder only.
work=$(mktemp -d "${XDG_CACHE_HOME:-$HOME/.cache}/powos-preview/run.XXXXXX")
trap 'rm -rf "$work"' EXIT
S=${dir:-$SHELL_DIR}
mkdir -p "$work/owl" "$work/apps" "$work/data" "$work/themes" "$work/trees"
cp "$SHELL_DIR"/dev/preview/themes/*.toml "$work/themes/"
cp "$SHELL_DIR"/dev/preview/data/*.json "$work/data/" 2>/dev/null || true
assets=$REPO/targets/android/app/app/src/main/assets/widgets
if [ $defaults = 1 ]; then
  cp "$assets"/*.owl "$work/owl/" 2>/dev/null || true
  cp "$assets"/examples/*.owl "$work/owl/" 2>/dev/null || true
fi
for o in ${owls[@]+"${owls[@]}"}; do
  if [ -d "$o" ]; then cp "$o"/*.owl "$work/owl/"; else cp "$o" "$work/owl/"; fi
done
add_app() { # an app folder: its manifest and its built UI, under its id
  local d=$1 id ui
  id=$(sed -n 's/^ *"id": *"\([^"]*\)".*/\1/p' "$d/powos-app.json" | head -1)
  [ -n "$id" ] || return 0
  ui=$d/out/ui
  [ -d "$ui" ] || { echo "     app $id: no built UI ($ui) - skipped (apps/build.sh)"; return 0; }
  mkdir -p "$work/apps/$id"
  cp "$d/powos-app.json" "$work/apps/$id/"
  cp -R "$ui" "$work/apps/$id/ui"
}
if [ $defaults = 1 ]; then
  for d in "$REPO"/apps/*/; do [ -f "$d/powos-app.json" ] && add_app "${d%/}"; done
fi
for d in ${apps[@]+"${apps[@]}"}; do add_app "$d"; done

# The OWL CLI, built once and again when its sources change (by content: a rebase touches every file's time). A build
# that can't run now (the Gradle cache is the APK builds' - locked while one runs) keeps the jar there is, and says so.
jar=$REPO/targets/android/app/owl/build/cli/owl.jar
src_hash=$(find "$REPO/targets/android/app/owl/src" -name '*.kt' -print0 | sort -z | xargs -0 shasum | shasum | cut -c1-16)
if [ ! -f "$jar" ] || [ "$(cat "$jar.src" 2>/dev/null)" != "$src_hash" ]; then
  echo "     owl.jar: building (targets/android/app/owl)"
  if docker run --rm -v "$GRADLE_VOLUME:/root/.gradle" -v "$REPO:$REPO" -w "$REPO/targets/android/app" --entrypoint bash "$JVM_IMAGE" \
    -c './gradlew -q --offline --configure-on-demand :owl:owlJar' >/dev/null 2>&1; then
    echo "$src_hash" > "$jar.src"
  elif [ -f "$jar" ]; then
    echo "     owl.jar: couldn't build now (the Gradle cache busy?) - using the one built before"
  else
    echo "preview: owl.jar didn't build" >&2; exit 2
  fi
fi
owl_trees() {
  docker run --rm -v "$work:$work" -v "$jar:/owl.jar:ro" --entrypoint java "$JVM_IMAGE" -jar /owl.jar trees --batch "$work/batch.json" ||
    echo "     owl trees: some widgets didn't evaluate (their errors are in the report)"
}
docker image inspect "$IMAGE" >/dev/null 2>&1 || docker pull -q "$IMAGE" >/dev/null
browser() { # PASS
  local mounts=(-v "$S:/shell:ro" -v "$work:/work" -v "$out:/out" -v "$SHELL_DIR/dev/preview/preview.mjs:/usr/src/app/preview.mjs:ro" -v "$work/apps:/apps:ro")
  # shell/fonts/nerd_symbols.ttf links out of the shell (../../targets/android/.../res/font): where it points, so OWL's
  # icons draw as on the phone instead of as empty boxes the fit checks can't see.
  mounts+=(-v "$REPO/targets/android/app/app/src/main/res/font:/targets/android/app/app/src/main/res/font:ro")
  # The preview's own page and baseline, from here: the shell checked (the installed APK's, say) may not carry them.
  mounts+=(-v "$SHELL_DIR/dev/preview:/shell/dev/preview:ro")
  [ -n "$wallpaper" ] && mounts+=(-v "$(cd "$(dirname "$wallpaper")" && pwd)/$(basename "$wallpaper"):/wallpaper.jpg:ro")
  docker run --rm --platform linux/arm64 --shm-size 1g ${GATE_CPU_SHARES:+--cpu-shares "$GATE_CPU_SHARES"} "${mounts[@]}" -e PASS="$1" -e HOST_WORK="$work" -e PREVIEW_THEMES="$themes" \
    -e PREVIEW_LIVE="$live" -e PREVIEW_FAST="$fast" ${only:+-e PREVIEW_ONLY="$only"} ${PREVIEW_EMPTY:+-e PREVIEW_EMPTY="$PREVIEW_EMPTY"} \
    ${PREVIEW_JOBS:+-e PREVIEW_JOBS="$PREVIEW_JOBS"} ${PREVIEW_DEBUG:+-e PREVIEW_DEBUG=1} ${PREVIEW_DEBUG_KEY:+-e PREVIEW_DEBUG_KEY="$PREVIEW_DEBUG_KEY"} ${PREVIEW_BASELINE:+-e PREVIEW_BASELINE="$PREVIEW_BASELINE"} \
    -w /usr/src/app --entrypoint node "$IMAGE" preview.mjs
}
step() { echo "     $1: $(($(date +%s) - t0)) s"; }
browser plan; step plan
owl_trees; step trees
browser measure; step measure
owl_trees; step trees
set +e
browser render
rc=$?
set -e
echo "preview: $([ $rc = 0 ] && echo "every widget fits" || echo FAIL) in $(($(date +%s) - t0)) s - contact sheets in $out"
exit $rc
