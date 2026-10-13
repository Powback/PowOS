#!/bin/bash
# Builds the Windows test programs (cpubench, d3d11tri, d3d9tri) for x86_64, i686 and aarch64 with llvm-mingw,
# in an aarch64 container (no host installs). Output: targets/android/out/wintest/<arch>/*.exe
# The phone test (tools/device-test.sh) pushes these; the lab (tools/lab.sh) runs them under each Proton path.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$(cd "$HERE/../.." && pwd)/out/wintest
LLVM_MINGW=${LLVM_MINGW:-20261006}
mkdir -p "$OUT"
docker run --rm --platform linux/arm64 --cpus 4 --memory 4g -v "$HERE:/src:ro" -v "$OUT:/out" \
  -v powos-android-llvm-mingw:/tc -e V="$LLVM_MINGW" menci/archlinuxarm:latest bash -c '
  set -euo pipefail
  tc=/tc/llvm-mingw-$V-ucrt-ubuntu-22.04-aarch64
  [ -x $tc/bin/clang ] || curl -fsSL "https://github.com/mstorsjo/llvm-mingw/releases/download/$V/llvm-mingw-$V-ucrt-ubuntu-22.04-aarch64.tar.xz" | tar -xJ -C /tc
  for a in x86_64 i686 aarch64; do
    mkdir -p /out/$a
    $tc/bin/$a-w64-mingw32-clang -O2 -o /out/$a/cpubench.exe /src/cpubench.c
    $tc/bin/$a-w64-mingw32-clang -O2 -o /out/$a/d3d11tri.exe /src/d3d11tri.c -ld3d11 -ld3dcompiler
    $tc/bin/$a-w64-mingw32-clang -O2 -o /out/$a/d3d9tri.exe /src/d3d9tri.c -ld3d9
  done
  ls -la /out/*'
