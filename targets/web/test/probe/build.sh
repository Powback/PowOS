#!/bin/bash
# Builds the probe initramfs: PowOS's own initramfs (out/disk/initramfs.img) + test/probe/probe-init as
# /probe-init (boot with rdinit=/probe-init). Output: targets/web/out/probe/initramfs.img
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
W=$HERE/../..
OUT=$W/out/probe
mkdir -p "$OUT"
docker run --rm --platform linux/arm64 -v "$HERE:/src:ro" -v "$W/out/disk:/disk:ro" -v "$OUT:/out" debian:trixie bash -c '
  set -euo pipefail
  apt-get update -qq && apt-get install -y -qq gcc libc6-dev cpio zstd initramfs-tools-core >/dev/null 2>&1
  gcc -O2 -static -o /tmp/probe-init /src/probe-init.c
  # mkinitcpio images are an uncompressed early archive followed by the compressed main one: unmkinitramfs
  # takes both apart (early/, main/).
  rm -rf /tmp/x && unmkinitramfs /disk/initramfs.img /tmp/x
  if [ -d /tmp/x/main ]; then R=/tmp/r; rm -rf $R; mkdir $R; cp -a /tmp/x/early/. $R/ 2>/dev/null || true; cp -a /tmp/x/main/. $R/; else R=/tmp/x; fi
  cd $R
  install -m 755 /tmp/probe-init ./probe-init
  find . | cpio -o -H newc --quiet | zstd -q -10 > /out/initramfs.img
  ls -la /out/initramfs.img; ls -la ./usr/lib/systemd/systemd'
