#!/bin/bash
# Targeted design renders (dev/shots.mjs) of this shell's working tree, in the gate's headless Chromium:
#   shell/dev/shot.sh OUTDIR 'REGEX' [SHELL_DIR] [WALLPAPER]
# REGEX picks scenes by name (the SCENES list at the top of shots.mjs); OUTDIR gets <scene>-<folded|unfolded>.png and
# report.json (each text's contrast against the rendered pixels). Env: SHOTS_SCALE (2 for readable crops), SHOTS_PROBE
# ('<js>' evaluated in each page, printed), SHOTS_THEME, SHOTS_GLASS (native|page), SHOTS_DEBUG. A whole sweep with
# the gate first: shell/dev/gate.sh --tree --shots DIR --wallpaper FILE. Before|after sheet: dev/sheet.mjs.
# OUTDIR and WALLPAPER must be under $HOME (Colima mounts only the home folder).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
out=$1; only=$2; S=${3:-$here/..}; wp=${4:-}
mkdir -p "$out"; out=$(cd "$out" && pwd); S=$(cd "$S" && pwd)
m=(-v "$S:/shell:ro" -v "$here/shots.mjs:/usr/src/app/shots.mjs:ro" -v "$out:/out")
[ -n "$wp" ] && m+=(-v "$(cd "$(dirname "$wp")" && pwd)/$(basename "$wp"):/wallpaper.jpg:ro")
exec docker run --rm --platform linux/arm64 --shm-size 512m "${m[@]}" -e SHOTS_ONLY="$only" \
  -e SHOTS_GLASS="${SHOTS_GLASS:-native}" -e SHOTS_DEBUG="${SHOTS_DEBUG:-}" -e SHOTS_PROBE="${SHOTS_PROBE:-}" \
  ${SHOTS_SCALE:+-e SHOTS_SCALE=$SHOTS_SCALE} ${SHOTS_THEME:+-e SHOTS_THEME=$SHOTS_THEME} \
  -w /usr/src/app --entrypoint node "${GATE_IMAGE:-zenika/alpine-chrome:with-puppeteer}" shots.mjs
