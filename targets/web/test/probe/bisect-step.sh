#!/bin/bash
# One bisect step: guest PCs in <lo>-<hi> never compiled to Wasm (patch 0004), then the probe in the browser.
# Prints "CRASH" if systemd's unit loading still dies, "OK" if all runs exit 0.
# Usage: targets/web/test/probe/bisect-step.sh 0xLO-0xHI [out-dir]
set -euo pipefail
W=$(cd "$(dirname "$0")/../.." && pwd)
RANGE=$1
OUT=${2:-$(mktemp -d)}
mkdir -p "$OUT"
QEMU_WASM_NOCOMPILE=$RANGE "$W/build-qemu.sh" > "$OUT/build.log" 2>&1
"$W/assemble.sh" > /dev/null 2>&1
"$W/test/probe/run-browser.sh" "$OUT/probe" > "$OUT/probe.log" 2>&1 || true
sum=$(tr -d '\r' < "$OUT/probe/serial.txt" | grep -o 'probe summary: .*' | tail -1)
case "$sum" in
  *"killed=0"*) echo "$RANGE OK ($sum)" ;;
  "")           echo "$RANGE UNKNOWN (no summary: timed out?)" ;;
  *)            echo "$RANGE CRASH ($sum)" ;;
esac
