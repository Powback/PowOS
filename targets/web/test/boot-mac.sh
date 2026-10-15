#!/bin/bash
# Runs a test/*.mjs in the installed Google Chrome, natively on the Mac (real CPU, real threads) instead of headless
# Chromium inside the Docker VM - to tell PowOS Web's speed from the test harness's.
#   SCRIPT=alive.mjs LOGIN=1 targets/web/test/boot-mac.sh [out-dir]
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:-$(mktemp -d)}
NODE_DIR=${POWOS_TEST_NODE_DIR:-$HERE/../out/test-node}   # playwright only; the browser is the installed Chrome
mkdir -p "$OUT" "$NODE_DIR"
[ -d "$NODE_DIR/node_modules/playwright" ] || (cd "$NODE_DIR" && npm init -y > /dev/null && PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm i -s playwright@1.56.0 > /dev/null)
cp "$HERE"/*.mjs "$NODE_DIR/"
cd "$NODE_DIR"
CHANNEL=chrome RESOLVE=${RESOLVE:-192.168.50.100} OUT="$OUT" node "${SCRIPT:-boot.mjs}"
echo "artifacts: $OUT"
