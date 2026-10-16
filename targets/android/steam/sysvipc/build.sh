#!/bin/bash
# Builds sysvipc-emu (i686 + x86-64, see README.md) with upstream's build-sysvipc.sh in a disposable arm64
# Ubuntu 24.04 container. Output: targets/android/out/sysvipc/ (sysvipc-emu.tar.gz + .sha256 + build-info.txt).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$HERE/../../out/sysvipc
rm -rf "$OUT" && mkdir -p "$(dirname "$OUT")"
docker run --rm --platform linux/arm64 -v "$HERE:/src:ro" -v "$(dirname "$OUT"):/outdir" ubuntu:24.04 bash -euo pipefail -c '
  mkdir -p /work && cp /src/sysvipc-emu.c /src/sysv-test.c /src/build-sysvipc.sh /work/
  bash /work/build-sysvipc.sh
  cp -r /work/out /outdir/sysvipc'
# The steam package (pkgs/steam) ships it: its PKGBUILD takes the tarball as a local source (gitignored there).
cp "$OUT/sysvipc-emu.tar.gz" "$HERE/../../pkgs/steam/sysvipc-emu.tar.gz"
ls -la "$OUT"
