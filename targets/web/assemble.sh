#!/bin/bash
# Assembles the site served by compose.yaml: out/site/
#   qemu-system-aarch64.{js,wasm,worker.js}   (build-qemu.sh)
#   load-{kernel,initramfs}.{js,data}        PowOS's kernel + initramfs (build-rootfs.sh), packed by Emscripten's
#                                            file_packager: preloaded, boot needs them whole
#   index.html args.js                       (web/)
# The disk (out/disk, build-rootfs.sh) is served next to it at /disk, streamed, never packed.
#
# Usage: targets/web/assemble.sh
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SITE=$HERE/out/site
mkdir -p "$SITE"
cp "$HERE"/out/qemu/qemu-system-aarch64.js "$HERE"/out/qemu/qemu-system-aarch64.wasm \
  "$HERE"/out/qemu/qemu-system-aarch64.worker.js "$SITE/"
cp "$HERE"/web/* "$SITE/"
docker run --rm -v "$HERE/out:/out" powos-web-qemu-build bash -c '
  set -euo pipefail
  rm -rf /tmp/pack && mkdir -p /tmp/pack/pack-kernel /tmp/pack/pack-initramfs
  cp /out/disk/Image /tmp/pack/pack-kernel/
  cp /out/disk/initramfs.img /tmp/pack/pack-initramfs/
  # Test initramfses, when built (?boot=<name>, args.js): test/tcg-check, test/probe.
  for t in tcg-check probe; do
    [ -f /out/$t/initramfs.img ] || continue
    mkdir -p /tmp/pack/pack-$t && cp /out/$t/initramfs.img /tmp/pack/pack-$t/
    python3 /emsdk/upstream/emscripten/tools/file_packager.py /out/site/load-$t.data \
      --preload /tmp/pack/pack-$t@/pack-$t > /out/site/load-$t.js
  done
  for f in kernel initramfs; do
    python3 /emsdk/upstream/emscripten/tools/file_packager.py /out/site/load-$f.data \
      --preload /tmp/pack/pack-$f@/pack-$f > /out/site/load-$f.js
  done'
ls -la "$SITE"
