#!/bin/bash
# Sketch's page in headless Chromium against a mock database (page.html: the module's reducers in JS): strokes saved as
# vector data, a rotation redraws the whole drawing fitted (never cropped), undo/redo/clear, a restart redraws it, the
# infinite canvas (two-finger pan, pinch zoom around its centre with limits, culling, no frames at rest, fit all, double
# tap to 100%, the view saved per drawing across rotation and restart, the strokes untouched by it), an
# older raster drawing is adopted with its picture kept. Builds the UI first (shell/dev/preview/build-app-ui.sh).
#   apps/sketch/test/rotate.sh
set -euo pipefail
T=$(cd "$(dirname "$0")" && pwd); A=$(cd "$T/.." && pwd); R=$(cd "$A/../.." && pwd)
"$R/shell/dev/preview/build-app-ui.sh" "$A" >/dev/null
docker run --rm --platform linux/arm64 --shm-size 512m -v "$R/shell:/shell:ro" -v "$A/out/ui:/appui:ro" -v "$T:/t:ro" \
  -v "$T/rotate.mjs:/usr/src/app/rotate.mjs:ro" -w /usr/src/app --entrypoint node zenika/alpine-chrome:with-puppeteer rotate.mjs
