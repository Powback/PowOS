#!/bin/bash
# Boots tcg-check under qemu-wasm in headless Chromium (test/boot.sh, ?boot=tcg-check) and compares its
# checksums with the real CPU's (out/tcg-check/expected.txt). Needs build.sh, build-qemu.sh, assemble.sh and the
# powos-web container up.
set -euo pipefail
W=$(cd "$(dirname "$0")/../.." && pwd)
OUT=${1:-$(mktemp -d)}
URL='https://powos-web.pow/?boot=tcg-check' WAIT_FOR='tcg-check done' TIMEOUT="${TIMEOUT:-1200}" \
  "$W/test/boot.sh" "$OUT" || true
got=$(tr -d '\r' < "$OUT/serial.txt" | grep -E '^[a-z/]+ +[0-9a-f]{16}$' || true)
echo "$got"
if diff <(grep -E '^[a-z/]+ +[0-9a-f]{16}$' "$W/out/tcg-check/expected.txt") <(echo "$got"); then
  echo "qemu-wasm: every group matches the real CPU"
else
  echo "qemu-wasm: MISMATCH (lines above: < real CPU, > qemu-wasm; a missing group = crashed/hung there)"
  exit 1
fi
