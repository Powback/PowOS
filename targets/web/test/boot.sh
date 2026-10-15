#!/bin/bash
# Runs test/boot.mjs (PowOS Web boots to a login prompt; SCRIPT=input.mjs: input reaches the desktop) in Playwright's Chromium container, on the traefik
# network so it reaches https://powos-web.pow through Traefik like a LAN browser does.
#
# Usage: targets/web/test/boot.sh [out-dir]   (default: a temp dir; serial.txt, console.log, screen.png)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:-$(mktemp -d)}
mkdir -p "$OUT"
docker run --rm --network traefik --ipc=host -v "$HERE:/test:ro" -v "$OUT:/out" -e TIMEOUT="${TIMEOUT:-1800}" -e WAIT_FOR="${WAIT_FOR:-}" -e URL="${URL:-}" -e PRESS_ENTER="${PRESS_ENTER:-}" -e DESKTOP="${DESKTOP:-}" -e SCRIPT="${SCRIPT:-boot.mjs}" -e LOGIN="${LOGIN:-}" -e LOGIN_AT="${LOGIN_AT:-}" -e SECS="${SECS:-}" -e SAMPLES="${SAMPLES:-}" -e WAIT="${WAIT:-}" -e LOOP="${LOOP:-}" -e NOTYPE="${NOTYPE:-}" \
  -w /tmp mcr.microsoft.com/playwright:v1.56.0-noble bash -c '
    npm init -y >/dev/null && npm i -s playwright@1.56.0 >/dev/null && cp /test/*.mjs . && node "$SCRIPT"'
echo "artifacts: $OUT"
