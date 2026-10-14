#!/bin/bash
# Runs test/boot.mjs (PowOS Web boots to a login prompt) in Playwright's Chromium container, on the traefik
# network so it reaches https://powos-web.pow through Traefik like a LAN browser does.
#
# Usage: targets/web/test/boot.sh [out-dir]   (default: a temp dir; serial.txt, console.log, screen.png)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:-$(mktemp -d)}
mkdir -p "$OUT"
docker run --rm --network traefik --ipc=host -v "$HERE:/test:ro" -v "$OUT:/out" -e TIMEOUT="${TIMEOUT:-1800}" \
  -w /tmp mcr.microsoft.com/playwright:v1.56.0-noble bash -c '
    npm init -y >/dev/null && npm i -s playwright@1.56.0 >/dev/null && cp /test/boot.mjs . && node boot.mjs'
echo "artifacts: $OUT"
