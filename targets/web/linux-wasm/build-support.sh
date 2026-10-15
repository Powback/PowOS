#!/bin/bash
# Runs inside the Linux/Wasm build container (build.sh build-support): libpowos-wasm-support.a (support/*.c - symbols
# C++ programs need that musl and our libc++abi lack), installed next to libc++ so -lpowos-wasm-support finds it.
set -euo pipefail
export REAL_LLVM=/ws/install/llvm/bin
CC=/linux-wasm/tools/fake-llvm/clang
D=/ws/install/libcxx-wasm32_nommu/lib
B=/ws/build/powos-wasm-support
rm -rf "$B" && mkdir -p "$B"
for src in /powos-lw/support/*.c; do
  $CC --target=wasm-linux-musl -march=wasm32 --sysroot=/ws/install/musl-wasm32_nommu \
    -isystem /ws/install/busybox-kernel-headers-wasm32_nommu -D__USE_TIME_BITS64 -fPIC -O2 \
    -c -o "$B/$(basename "${src%.c}").o" "$src"
done
rm -f "$D/libpowos-wasm-support.a"
$REAL_LLVM/llvm-ar rcs "$D/libpowos-wasm-support.a" "$B"/*.o
ls -la "$D/libpowos-wasm-support.a"
