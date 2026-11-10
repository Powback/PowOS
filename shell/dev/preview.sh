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
# f411: --init, the run label and the in-container cap (dev/gate-containers.sh); under a gate, the gate's label and pid.
. "$SHELL_DIR/dev/gate-containers.sh"
[ "$GATE_PARENT_PID" != $$ ] || gc_reap
t0=$(date +%s)
mkdir -p "$out" "${XDG_CACHE_HOME:-$HOME/.cache}/powos-preview"
# Under $HOME: Colima's VM mounts the home folder only.
work=$(mktemp -d "${XDG_CACHE_HOME:-$HOME/.cache}/powos-preview/run.XXXXXX")
trap '[ "$GATE_PARENT_PID" != $$ ] || gc_kill; rm -rf "$work"' EXIT
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

# The OWL CLI, built once per source version (by content: a rebase touches every file's time) and shared across
# checkouts through the build-inputs cache (dev/owl-jar.sh, friction f402). A build that fails keeps the jar there
# is and says why (owl-jar.sh prints Gradle's error) and what that means for the widgets.
jar=$REPO/targets/android/app/owl/build/cli/owl.jar
rc=0; "$SHELL_DIR/dev/owl-jar.sh" "$REPO" --build >/dev/null || rc=$?
case $rc in
  0) ;;
  3) echo "     owl.jar: didn't build (reason above) - using an OLDER compiler: a widget using OWL it doesn't know FAILs as 'didn't evaluate'" ;;
  *) echo "preview: owl.jar didn't build" >&2; exit 2 ;;
esac
owl_trees() {
  docker run --rm "${gc_flags[@]}" -v "$work:$work" -v "$jar:/owl.jar:ro" --entrypoint java "$JVM_IMAGE" -jar /owl.jar trees --batch "$work/batch.json" ||
    echo "     owl trees: some widgets didn't evaluate (their errors are in the report)"
}
docker image inspect "$IMAGE" >/dev/null 2>&1 || docker pull -q "$IMAGE" >/dev/null
# The browser image's arch, as this Mac runs it. Set here, not as $(case ...) inside the docker line: macOS bash 3.2
# can't parse a case pattern's ")" inside $( ) - that failed every widget sweep run under /bin/bash (11-09 ships).
case $(uname -m) in x86_64 | amd64) platform=linux/amd64 ;; *) platform=linux/arm64 ;; esac
browser() { # PASS
  local mounts=(-v "$S:/shell:ro" -v "$work:/work" -v "$out:/out" -v "$SHELL_DIR/dev/preview/preview.mjs:/usr/src/app/preview.mjs:ro" -v "$work/apps:/apps:ro")
  # shell/fonts/nerd_symbols.ttf links out of the shell (../../targets/android/.../res/font): where it points, so OWL's
  # icons draw as on the phone instead of as empty boxes the fit checks can't see.
  mounts+=(-v "$REPO/targets/android/app/app/src/main/res/font:/targets/android/app/app/src/main/res/font:ro")
  # The preview's own page and baseline, from here: the shell checked (the installed APK's, say) may not carry them.
  mounts+=(-v "$SHELL_DIR/dev/preview:/shell/dev/preview:ro")
  [ -n "$wallpaper" ] && mounts+=(-v "$(cd "$(dirname "$wallpaper")" && pwd)/$(basename "$wallpaper"):/wallpaper.jpg:ro")
  local envs=(-e PASS="$1" -e HOST_WORK="$work" -e PREVIEW_THEMES="$themes" \
    -e PREVIEW_LIVE="$live" -e PREVIEW_FAST="$fast" ${only:+-e PREVIEW_ONLY="$only"} ${PREVIEW_EMPTY:+-e PREVIEW_EMPTY="$PREVIEW_EMPTY"} \
    ${PREVIEW_JOBS:+-e PREVIEW_JOBS="$PREVIEW_JOBS"} ${PREVIEW_DEBUG:+-e PREVIEW_DEBUG=1} ${PREVIEW_DEBUG_KEY:+-e PREVIEW_DEBUG_KEY="$PREVIEW_DEBUG_KEY"} ${PREVIEW_BASELINE:+-e PREVIEW_BASELINE="$PREVIEW_BASELINE"})
  if [ -n "$JOB_ON" ]; then browser_job "$1" "${envs[@]}"; return; fi
  docker run --rm "${gc_flags[@]}" --platform "$platform" --shm-size 1g ${GATE_CPU_SHARES:+--cpu-shares "$GATE_CPU_SHARES"} "${mounts[@]}" "${envs[@]}" \
    -w /usr/src/app --entrypoint timeout "$IMAGE" "${gc_cap[@]}" node preview.mjs
}
# The browser passes run as the gate job (tools/jobs/compose.yml via tools/jobs/job.sh - the one remote route, as
# dev/gate.sh's scenes): the shell, preview.mjs, the apps and the fonts baked into an image on the Docker context
# POW_JOB_CONTEXT names (default pow58: .58; not answering within 5 s -> the hub, said so), one container kept up for
# the three passes. The OWL trees between them stay here (the JVM image is the Mac's): /work goes in before each pass
# and comes back after it, with /out. HOST_WORK stays this $work, the path the local JVM container sees.
# A job that can't start, or PREVIEW_LOCAL=1: the local container above.
. "$SHELL_DIR/../tools/jobs/job.sh"
JOB_ON="" job_cid="" jc=$work.job
trap 'exit 130' INT TERM HUP ALRM
trap '[ "$GATE_PARENT_PID" != $$ ] || gc_kill; job_cleanup; rm -rf "$work" "$jc"' EXIT
if [ -z "${PREVIEW_LOCAL:-}" ]; then
  job_init preview
  # Its own image tag: the gate's scene image of this checkout differs, and job_build drops a tag's previous image.
  JOB_TAG=$JOB_TAG-preview
  mkdir -p "$jc/shell" "$jc/app" "$jc/apps" "$jc/fonts" "$jc/in"
  (cd "$S" && COPYFILE_DISABLE=1 tar --exclude ./node_modules -cf - .) | tar -xf - -C "$jc/shell"
  # The preview's own page and baseline, from here (as the local mounts: the shell checked may not carry them).
  rm -rf "$jc/shell/dev/preview" && mkdir -p "$jc/shell/dev" && cp -R "$SHELL_DIR/dev/preview" "$jc/shell/dev/preview"
  cp "$SHELL_DIR/dev/preview/preview.mjs" "$jc/app/"
  cp -R "$work/apps/." "$jc/apps/"
  # shell/fonts/nerd_symbols.ttf links to /targets/.../res/font, which the gate image points at /fonts.
  cp -L "$REPO"/targets/android/app/app/src/main/res/font/* "$jc/fonts/" 2>/dev/null || true
  [ -z "$wallpaper" ] || cp "$wallpaper" "$jc/in/wallpaper.jpg"
  if job_build gate "$jc" && job_cid=$(job_dc run -d --no-deps --entrypoint sleep gate 86400 < /dev/null 2>/dev/null | tail -1) &&
    [ -n "$job_cid" ] && job_docker exec -u root "$job_cid" sh -c 'mkdir -p /work /out && chown chrome /work /out'; then
    JOB_ON=1; echo "     browser passes on $JOB_CTX (gate job)"
  else echo "     the gate job didn't start on $JOB_CTX - browser passes run locally"; job_cleanup; fi
fi
browser_job() { # PASS ENVS...
  local rc=0; shift
  # In: this $work (the trees the last pass asked for). Out: /work and /out after the pass.
  job_docker exec -u root "$job_cid" find /work -mindepth 1 -delete || return 2
  (cd "$work" && COPYFILE_DISABLE=1 tar -cf - .) | job_docker exec -i -u root "$job_cid" sh -c 'tar -xf - -C /work && chown -R chrome /work' || return 2
  job_docker exec -u chrome -w /usr/src/app "$@" "$job_cid" timeout "${gc_cap[@]}" node preview.mjs < /dev/null || rc=$?
  { job_docker exec "$job_cid" tar -cf - -C /work . | tar -xf - -C "$work"; } &&
    { job_docker exec "$job_cid" tar -cf - -C /out . | tar -xf - -C "$out"; } || return 2
  return $rc
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
