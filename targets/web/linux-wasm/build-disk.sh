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
  apt-get update -qq && apt-get install -y -qq erofs-utils bzip2 > /dev/null
  rm -rf /tmp/root && mkdir -p /tmp/root
  for d in bin lib config desktop docs; do [ -d /repo/$d ] && cp -a /repo/$d /tmp/root/; done
  cp /repo/README.md /repo/CLAUDE.md /tmp/root/ 2>/dev/null || true
  # PowOS programs built for Linux/Wasm (build-apps.sh), at /powos/apps.
  mkdir -p /tmp/root/apps
  for f in /out/apps/*; do case $f in *.txt|*"*") ;; *) cp "$f" /tmp/root/apps/ ;; esac; done
  # Fonts for Qt (bundled FreeType, no fontconfig: QT_QPA_FONTDIR=/powos/fonts). DejaVu, sha256-checked download.
  if [ -f /out/dl/dejavu-fonts-ttf-2.37.tar.bz2 ]; then
    echo "fa9ca4d13871dd122f61258a80d01751d603b4d3ee14095d65453b4e846e17d7  /out/dl/dejavu-fonts-ttf-2.37.tar.bz2" | sha256sum -c - > /dev/null
    mkdir -p /tmp/root/fonts
    tar -xjf /out/dl/dejavu-fonts-ttf-2.37.tar.bz2 -C /tmp/root/fonts --strip-components=2 \
      dejavu-fonts-ttf-2.37/ttf/DejaVuSans.ttf dejavu-fonts-ttf-2.37/ttf/DejaVuSans-Bold.ttf \
      dejavu-fonts-ttf-2.37/ttf/DejaVuSansMono.ttf
    tar -xjf /out/dl/dejavu-fonts-ttf-2.37.tar.bz2 -O dejavu-fonts-ttf-2.37/LICENSE > /tmp/root/fonts/LICENSE-DejaVu
  fi
  # Uncompressed: EROFS decompression uses vmap(), which a NOMMU kernel does not have (BUG at mm/nommu.c, panic).
  # The page streams only the blocks that are read anyway.
  mkfs.erofs /out/powos.erofs /tmp/root > /dev/null
  ls -la /out/powos.erofs'
