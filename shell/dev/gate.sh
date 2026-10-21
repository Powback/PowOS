#!/bin/bash
# The pre-push gate: what shell/push.sh (and apps/install.sh, for a PowOS app's UI) runs before anything reaches the
# phone. A pushed shell file that doesn't load leaves its pages without JS (2026-10-20: an in-progress apps/pages.ts
# with an import cycle - home and the lock face dead, the shade's window over everything), and nobody is told: so it
# never gets there.
#
#   shell/dev/gate.sh [--tree | --dir DIR] [--overrides DIR] [--app APPDIR] [file...]
#
# The shell it checks is the one the phone will run after the push: the committed shell (git HEAD: what an APK is
# built from - build-app.sh refuses a dirty tree), the phone's current overrides over it (--overrides: push.sh pulls
# them), and the files being pushed, from the working tree, over that. Other agents' uncommitted edits elsewhere in
# shell/ are not part of it, as they aren't part of the phone. --tree: the working tree as it is instead; --dir: DIR
# as it is (nothing composed).
#   1. tsc --noEmit over that shell (the folder's own tsconfig and node_modules); the style lint (dev/lint-style.sh:
#      a raw colour, a line or a shadow outside theme.css's tokens fails, dev/style-allow.txt the exceptions);
#   2. every page of it (home, lock, shade, assist, aod, recents: each mode app.tsx renders) booted in a headless
#      Chromium against the mock bridge, served as the phone's WebView serves it (shell/dev/gate.mjs): any uncaught
#      error, failed module load, missing export or import-cycle error, or no ready (window.__powosAlive) in READY_MS
#      (default 8000) fails it. Then the idle check: settled, a page draws nothing - no requestAnimationFrame, no layer
#      paint, no endless animation for IDLE_MS (default 2000; IDLE_MS=0 skips it).
#   --app APPDIR (apps/<app>): also every page/widget entry of that app's built UI (out/ui), imported as the shell does.
#   --shots DIR [--wallpaper FILE]: after the pages boot, every surface rendered at the phone's two screens into DIR
#      (dev/shots.mjs: PNGs + report.json with each text's measured contrast) - design QA's renders, never a pass/fail.
#      SHOTS_THEME / SHOTS_ONLY pass through.
# Exit 0: pass. 1: failed (the reasons on stdout). 2: couldn't run (no docker...). Time: ~5-10 s, the image cached.
# GATE_IMAGE overrides the Chromium image. Docker's build cache and images are never pruned here.
set -euo pipefail
SHELL_DIR=$(cd "$(dirname "$0")/.." && pwd)
IMAGE=${GATE_IMAGE:-zenika/alpine-chrome:with-puppeteer}
base=head dir="" overrides="" app="" shots="" wallpaper="" files=()
while [ $# -gt 0 ]; do
  case "$1" in
    --tree) base=tree; shift ;;
    --dir) base=dir; dir=$(cd "$2" && pwd); shift 2 ;;
    --overrides) overrides=$2; shift 2 ;;
    --app) app=$(cd "$2" && pwd); shift 2 ;;
    --shots) mkdir -p "$2"; shots=$(cd "$2" && pwd); shift 2 ;;
    --wallpaper) wallpaper=$(cd "$(dirname "$2")" && pwd)/$(basename "$2"); shift 2 ;;
    -h|--help) sed -n '2,27p' "$0"; exit 0 ;;
    *) files+=("$1"); shift ;;
  esac
done
command -v docker >/dev/null || { echo "gate: no docker" >&2; exit 2; }
t0=$(date +%s)
# Under $HOME, not $TMPDIR: Colima's VM mounts the home folder only (a /var/folders path is empty in the container).
mkdir -p "${XDG_CACHE_HOME:-$HOME/.cache}/powos-gate"
work=$(mktemp -d "${XDG_CACHE_HOME:-$HOME/.cache}/powos-gate/run.XXXXXX")
trap 'rm -rf "$work"' EXIT
S=$work/shell
case $base in
  dir) S=$dir ;;
  tree) mkdir -p "$S" && (cd "$SHELL_DIR" && tar --exclude ./node_modules -cf - .) | tar -xf - -C "$S" ;;
  head)
    top=$(git -C "$SHELL_DIR" rev-parse --show-toplevel)
    rel=${SHELL_DIR#"$top"/}
    git -C "$top" archive HEAD "$rel" | tar -xf - -C "$work"
    [ "$rel" = shell ] || mv "$work/$rel" "$S"
    ;;
esac
if [ "$base" != dir ]; then
  # The phone's overrides, then the pushed files: what the phone serves after the push (ShellHost.open).
  [ -n "$overrides" ] && [ -d "$overrides" ] && (cd "$overrides" && tar -cf - .) | tar -xf - -C "$S"
  for f in ${files[@]+"${files[@]}"}; do
    [ -f "$SHELL_DIR/$f" ] || { echo "gate: no such shell file: $f" >&2; exit 2; }
    mkdir -p "$S/$(dirname "$f")" && cp "$SHELL_DIR/$f" "$S/$f"
  done
  ln -sfn "$SHELL_DIR/node_modules" "$S/node_modules"
fi
fail=0
# 1. Types.
if [ "${GATE_SHELL_PAGES:-1}" = 0 ]; then
  : # an app's UI alone (apps/install.sh): the shell isn't what changed
elif [ -x "$SHELL_DIR/node_modules/.bin/tsc" ]; then
  if out=$(cd "$S" && "$SHELL_DIR/node_modules/.bin/tsc" --noEmit -p . 2>&1); then echo "ok   tsc"
  else echo "$out" | grep -v '^ ' | head -40 | sed 's/^/FAIL tsc: /'; fail=1; fi
else
  echo "     tsc: skipped (no shell/node_modules - npm ci in shell/)"
fi
# 1b. The design language's style lint (docs/DESIGN-LANGUAGE.md): no raw colours, lines or shadows outside the tokens.
if out=$("$SHELL_DIR/dev/lint-style.sh" "$S" 2>&1); then echo "$out"; else echo "$out" | head -30; fail=1; fi
# 2. The pages, booted.
docker image inspect "$IMAGE" >/dev/null 2>&1 || docker pull -q "$IMAGE" >/dev/null
mounts=(-v "$S:/shell:ro" -v "$SHELL_DIR/dev/gate.mjs:/usr/src/app/gate.mjs:ro")
# node_modules is a link out of the composed folder: the browser half needs none of it.
if [ -n "$app" ]; then
  id=$(sed -n 's/^ *"id": *"\([^"]*\)".*/\1/p' "$app/powos-app.json" | head -1)
  [ -d "$app/out/ui" ] || { echo "FAIL app: $app/out/ui isn't built (apps/build.sh)"; exit 1; }
  mounts+=(-v "$app/powos-app.json:/apps/$id/powos-app.json:ro" -v "$app/out/ui:/apps/$id/ui:ro")
fi
set +e
docker run --rm --platform linux/arm64 --shm-size 512m "${mounts[@]}" -e READY_MS="${READY_MS:-8000}" \
  ${GATE_SHELL_PAGES:+-e SHELL_PAGES="$GATE_SHELL_PAGES"} ${IDLE_MS:+-e IDLE_MS="$IDLE_MS"} ${IDLE_WAIT_MS:+-e IDLE_WAIT_MS="$IDLE_WAIT_MS"} \
  -w /usr/src/app --entrypoint node "$IMAGE" gate.mjs
rc=$?
set -e
[ $rc -eq 0 ] || fail=1
# 3. Design QA's renders (not a check: they're looked at).
if [ -n "$shots" ]; then
  smounts=(-v "$S:/shell:ro" -v "$SHELL_DIR/dev/shots.mjs:/usr/src/app/shots.mjs:ro" -v "$shots:/out")
  [ -n "$wallpaper" ] && smounts+=(-v "$wallpaper:/wallpaper.jpg:ro")
  docker run --rm --platform linux/arm64 --shm-size 512m "${smounts[@]}" ${SHOTS_THEME:+-e SHOTS_THEME="$SHOTS_THEME"} \
    ${SHOTS_ONLY:+-e SHOTS_ONLY="$SHOTS_ONLY"} ${SHOTS_SCALE:+-e SHOTS_SCALE="$SHOTS_SCALE"} -w /usr/src/app --entrypoint node "$IMAGE" shots.mjs ||
    echo "     shots: the render run failed"
fi
[ $rc -le 1 ] || echo "FAIL gate: the browser run itself failed (exit $rc)"
echo "gate: $([ $fail = 0 ] && echo pass || echo FAIL) in $(($(date +%s) - t0)) s ($base$([ -n "$overrides" ] && echo " + phone overrides")$([ ${#files[@]} -gt 0 ] && echo " + ${#files[@]} pushed file(s)"))"
exit $fail
