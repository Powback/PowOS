#!/bin/bash
# Boots tcg-check (build.sh) as /init on native QEMU (build-qemu-native.sh) with the browser's machine, and
# compares its checksums with the real CPU's (out/tcg-check/expected.txt).
set -euo pipefail
W=$(cd "$(dirname "$0")/../.." && pwd)
got=$(docker run --rm -v "$W/out/disk:/disk:ro" -v "$W/out/tcg-check:/t:ro" -v "$W/out/qemu-native:/q:ro" \
  powos-web-qemu-native timeout 300 /q/qemu-system-aarch64 -nographic -M virt -cpu neoverse-n1 -m 1024M -accel tcg \
  -nic none -kernel /disk/Image -initrd /t/initramfs.img -append 'console=ttyAMA0 rdinit=/init quiet' 2>&1 \
  | tr -d '\r' | grep -E '^[a-z/]+ +[0-9a-f]{16}$' || true)
echo "$got"
if diff <(grep -E '^[a-z/]+ +[0-9a-f]{16}$' "$W/out/tcg-check/expected.txt") <(echo "$got"); then
  echo "native QEMU: every group matches the real CPU"
else
  echo "native QEMU: MISMATCH (lines above: < real CPU, > QEMU)"
  exit 1
fi
