#!/bin/bash
# The disk Linux/Wasm streams on demand (kernel/wasm_blk.c): PowOS's own files (CLI, libraries, configs, docs) as a
# compressed read-only EROFS image -> out/linux-wasm/powos.erofs, mounted at /powos by initramfs/init.
# Only what the page reads is downloaded (HTTP Range requests, runtime/linux-worker.js).
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
REPO=$(cd "$HERE/../.." && pwd)
OUT=$HERE/out/linux-wasm
mkdir -p "$OUT"
docker run --rm -v "$REPO:/repo:ro" -v "$OUT:/out" debian:trixie bash -euc '
  apt-get update -qq && apt-get install -y -qq erofs-utils > /dev/null
  rm -rf /tmp/root && mkdir -p /tmp/root
  for d in bin lib config desktop docs; do [ -d /repo/$d ] && cp -a /repo/$d /tmp/root/; done
  cp /repo/README.md /repo/CLAUDE.md /tmp/root/ 2>/dev/null || true
  # Uncompressed: EROFS decompression uses vmap(), which a NOMMU kernel does not have (BUG at mm/nommu.c, panic).
  # The page streams only the blocks that are read anyway.
  mkfs.erofs /out/powos.erofs /tmp/root > /dev/null
  ls -la /out/powos.erofs'
