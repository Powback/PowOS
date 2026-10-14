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

# The flags are container2wasm's aarch64 build of qemu-wasm (reference/container2wasm/Dockerfile:899), which
# ships arm64 guests: qemu-wasm's README flags plus -fno-inline-functions (aarch64 only there) and emmalloc
# instead of mimalloc. With the README's flags systemd crashed (SEGV) in the initrd although every instruction
# group of test/tcg-check matched the real CPU. xterm-pty serves the serial console for now.
EXTRA_CFLAGS="-O3 -fno-inline-functions -g -Wno-error=unused-command-line-argument -matomics -mbulk-memory -DNDEBUG \
-DG_DISABLE_ASSERT -D_GNU_SOURCE -sASYNCIFY=1 -pthread -sPROXY_TO_PTHREAD=1 -sFORCE_FILESYSTEM -sALLOW_TABLE_GROWTH \
-sTOTAL_MEMORY=2300MB -sWASM_BIGINT -sMALLOC=emmalloc --js-library=/build/node_modules/xterm-pty/emscripten-pty.js \
-sEXPORT_ES6=1 -sASYNCIFY_IMPORTS=ffi_call_js"
# Our additions (targets/web/qemu/: the on-demand chunked disk, block/chunked.c) are laid over a copy of the
# pinned source in a volume, which QEMU builds out of tree (keeps build/ off the macOS bind mount, and
# incremental across runs: cp -a keeps mtimes, so unchanged files aren't rebuilt).
docker run --rm --cpus 8 --memory 12g -v "$SRC:/qemu-pinned:ro" -v "$HERE/qemu:/powos:ro" \
  -v "$HERE/patches/qemu:/patches:ro" -v powos-web-qemu-build:/vol -v "$OUT:/out" \
  -e EXTRA_CFLAGS="$EXTRA_CFLAGS" -e INSTANTIATE_NUM="${QEMU_WASM_INSTANTIATE_NUM:-1500}" -e NOCOMPILE="${QEMU_WASM_NOCOMPILE:-}" -e SKIP_PATCHES="${QEMU_WASM_SKIP_PATCHES:-}" "$IMAGE" bash -c '
    set -euo pipefail
    mkdir -p /vol/src /vol/build
    # The source is rebuilt from the pinned tree every time, then our files and ALL patches go on fresh: what is
    # compiled is exactly what git has (a changed patch can never meet an older version of itself). cp -a keeps
    # the pinned mtimes, so only the files patches touch are recompiled.
    cp -a /qemu-pinned/. /vol/src/
    cp -a /powos/. /vol/src/
    # QEMU_WASM_SKIP_PATCHES (e.g. "0005"): leave patches out, to prove a test catches what they fix.
    for p in /patches/*.patch; do
      n=$(basename "$p" | cut -c1-4)
      case " $SKIP_PATCHES " in *" $n "*) echo "skipping patch $n"; continue ;; esac
      patch -d /vol/src -p1 -s --no-backup-if-mismatch < "$p" || { echo "patch failed: $p" >&2; exit 1; }
    done
    # TCI-to-Wasm threshold (patch 0002) and a guest-PC range never compiled to Wasm (patch 0004, bisecting).
    # Rewritten only when it changes: switching rebuilds a few files.
    cfg="#define INSTANTIATE_NUM $INSTANTIATE_NUM"
    if [ -n "$NOCOMPILE" ]; then
      cfg="$cfg
#define WASM_NOCOMPILE_LO ${NOCOMPILE%-*}ull
#define WASM_NOCOMPILE_HI ${NOCOMPILE#*-}ull"
    fi
    [ "$(cat /vol/src/tcg/wasm32-config.h 2>/dev/null)" = "$cfg" ] || echo "$cfg" > /vol/src/tcg/wasm32-config.h
    cd /vol/build
    # Changed flags need a fresh configure (configure bakes them into build.ninja): start the build dir over.
    if [ "$(cat .powos-flags 2>/dev/null)" != "$EXTRA_CFLAGS" ]; then rm -rf /vol/build/* /vol/build/.[!.]*; fi
    printf %s "$EXTRA_CFLAGS" > .powos-flags
    [ -f build.ninja ] || emconfigure /vol/src/configure --static --target-list=aarch64-softmmu --cpu=wasm32 \
      --cross-prefix= --without-default-features --enable-system --with-coroutine=fiber --enable-virtfs \
      --extra-cflags="$EXTRA_CFLAGS" --extra-cxxflags="$EXTRA_CFLAGS" \
      --extra-ldflags="-sEXPORTED_RUNTIME_METHODS=getTempRet0,setTempRet0,addFunction,removeFunction,TTY,FS"
    emmake make -j"$(nproc)" qemu-system-aarch64
    # The JS loader is linked as plain "qemu-system-aarch64" (no extension); the page imports it as .js.
    cp qemu-system-aarch64 /out/qemu-system-aarch64.js
    cp qemu-system-aarch64.wasm qemu-system-aarch64.worker.js /out/
    ls -la /out'
