#!/bin/bash
# Builds tcg-check (static aarch64) natively in an arm64 container, prints its NATIVE checksums (the expected
# values), and packs it as the /init of a tiny initramfs for booting under QEMU.
# Output: targets/web/out/tcg-check/{tcg-check, initramfs.img, expected.txt}
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$HERE/../../out/tcg-check
mkdir -p "$OUT"
docker run --rm --platform linux/arm64 -v "$HERE:/src:ro" -v "$OUT:/out" debian:trixie bash -c '
  set -euo pipefail
  apt-get update -qq && apt-get install -y -qq gcc libc6-dev cpio >/dev/null
  gcc -O2 -static -march=armv8.2-a+crypto+crc -o /out/tcg-check /src/tcg-check.c -lm -latomic
  /out/tcg-check > /out/expected.txt
  rm -rf /tmp/i && mkdir -p /tmp/i/dev && cp /out/tcg-check /tmp/i/init
  (cd /tmp/i && find . | cpio -o -H newc --quiet) | gzip -9 > /out/initramfs.img'
cat "$OUT/expected.txt"
