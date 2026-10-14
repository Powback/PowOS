#!/bin/bash
# Builds QEMU for the browser (qemu-wasm: QEMU with a TCG backend that emits WebAssembly, aarch64 guests (PowOS's Arch Linux ARM build, as on the phone)) with
# its own Dockerfile (Emscripten + glib/zlib/pixman/libffi for wasm). Output: targets/web/out/qemu/
#   qemu-system-aarch64.{js,wasm,worker.js}
#
# Usage: targets/web/build-qemu.sh
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$HERE/third_party/qemu-wasm
OUT=$HERE/out/qemu
mkdir -p "$OUT"
IMAGE=powos-web-qemu-build
# HACK: zlib.net serves only the newest release at its top level; 1.3.1 moved to /fossils/ (and only as .tar.gz),
# so qemu-wasm's Dockerfile URL returns an HTML page. Real fix: upstream the fossils URL to qemu-wasm.
sed -e 's|https://zlib.net/zlib-$ZLIB_VERSION.tar.xz \| tar xJC|https://zlib.net/fossils/zlib-$ZLIB_VERSION.tar.gz \| tar xzC|' \
  "$SRC/Dockerfile" | docker build -t "$IMAGE" -

# The flags are qemu-wasm's README build for aarch64-softmmu (xterm-pty serves the serial console for now).
EXTRA_CFLAGS="-O3 -g -Wno-error=unused-command-line-argument -matomics -mbulk-memory -DNDEBUG -DG_DISABLE_ASSERT \
-D_GNU_SOURCE -sASYNCIFY=1 -pthread -sPROXY_TO_PTHREAD=1 -sFORCE_FILESYSTEM -sALLOW_TABLE_GROWTH -sTOTAL_MEMORY=2300MB \
-sWASM_BIGINT -sMALLOC=mimalloc --js-library=/build/node_modules/xterm-pty/emscripten-pty.js -sEXPORT_ES6=1 \
-sASYNCIFY_IMPORTS=ffi_call_js"
# Our additions (targets/web/qemu/: the on-demand chunked disk, block/chunked.c) are laid over a copy of the
# pinned source in a volume, which QEMU builds out of tree (keeps build/ off the macOS bind mount, and
# incremental across runs: cp -a keeps mtimes, so unchanged files aren't rebuilt).
docker run --rm --cpus 8 --memory 12g -v "$SRC:/qemu-pinned:ro" -v "$HERE/qemu:/powos:ro" \
  -v "$HERE/patches/qemu:/patches:ro" -v powos-web-qemu-build:/vol -v "$OUT:/out" \
  -e EXTRA_CFLAGS="$EXTRA_CFLAGS" "$IMAGE" bash -c '
    set -euo pipefail
    mkdir -p /vol/src /vol/build
    cp -a -u /qemu-pinned/. /vol/src/
    cp -a /powos/. /vol/src/
    # Patches go on once: the copy persists in the volume (one that reverses cleanly is already applied).
    for p in /patches/*.patch; do
      patch -d /vol/src -p1 -R -f -s --dry-run < "$p" >/dev/null 2>&1 && continue
      patch -d /vol/src -p1 -f -s < "$p"
    done
    cd /vol/build
    [ -f build.ninja ] || emconfigure /vol/src/configure --static --target-list=aarch64-softmmu --cpu=wasm32 \
      --cross-prefix= --without-default-features --enable-system --with-coroutine=fiber --enable-virtfs \
      --extra-cflags="$EXTRA_CFLAGS" --extra-cxxflags="$EXTRA_CFLAGS" \
      --extra-ldflags="-sEXPORTED_RUNTIME_METHODS=getTempRet0,setTempRet0,addFunction,removeFunction,TTY,FS"
    emmake make -j"$(nproc)" qemu-system-aarch64
    cp qemu-system-aarch64* /out/ 2>/dev/null || cp qemu-system-aarch64.* /out/
    ls -la /out'
