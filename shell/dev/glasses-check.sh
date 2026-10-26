#!/bin/bash
# The glasses' screen page driven against the mock (shell/dev/glasses-check.mjs), in the gate's headless Chromium
# image: what it sends the glasses in text and image mode. The working tree's shell, as it is.
set -euo pipefail
SHELL_DIR=$(cd "$(dirname "$0")/.." && pwd)
IMAGE=${GATE_IMAGE:-zenika/alpine-chrome:with-puppeteer}
docker run --rm --platform linux/arm64 --shm-size 512m -v "$SHELL_DIR:/shell:ro" \
  -v "$SHELL_DIR/dev/glasses-check.mjs:/usr/src/app/glasses-check.mjs:ro" -w /usr/src/app --entrypoint node "$IMAGE" glasses-check.mjs
