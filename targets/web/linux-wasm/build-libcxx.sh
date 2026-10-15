#!/bin/bash
# Runs inside the Linux/Wasm build container (build.sh build-libcxx): libc++ + libc++abi for wasm32 NOMMU Linux/musl,
# static, from the same LLVM tree and compiler wrapper as everything else -> /ws/install/libcxx-wasm32_nommu.
# Exceptions off for now (Wasm exception handling is its own step); threads on (musl pthreads run on clone()).
set -euo pipefail
export REAL_LLVM=/ws/install/llvm/bin
CC=/linux-wasm/tools/fake-llvm/clang
FLAGS="--target=wasm-linux-musl -march=wasm32 -fPIC --sysroot=/ws/install/musl-wasm32_nommu -isystem /ws/install/busybox-kernel-headers-wasm32_nommu -D__USE_TIME_BITS64"
B=/ws/build/libcxx-wasm32_nommu
rm -rf "$B"
cmake -G Ninja -S /ws/src/llvm/runtimes -B "$B" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_SYSTEM_NAME=Linux \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CC" \
  -DCMAKE_AR="$REAL_LLVM/llvm-ar" -DCMAKE_RANLIB="$REAL_LLVM/llvm-ranlib" -DCMAKE_NM="$REAL_LLVM/llvm-nm" \
  -DCMAKE_C_FLAGS="$FLAGS" -DCMAKE_CXX_FLAGS="$FLAGS" \
  -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
  -DCMAKE_INSTALL_PREFIX=/ws/install/libcxx-wasm32_nommu \
  -DLLVM_ENABLE_RUNTIMES="libcxx;libcxxabi" \
  -DLIBCXX_ENABLE_SHARED=OFF -DLIBCXXABI_ENABLE_SHARED=OFF \
  -DLIBCXX_ENABLE_EXCEPTIONS=OFF -DLIBCXXABI_ENABLE_EXCEPTIONS=OFF \
  -DLIBCXX_HAS_MUSL_LIBC=ON \
  -DLIBCXX_CXX_ABI=libcxxabi \
  -DLIBCXXABI_USE_LLVM_UNWINDER=OFF \
  -DLIBCXX_INCLUDE_TESTS=OFF -DLIBCXX_INCLUDE_BENCHMARKS=OFF -DLIBCXXABI_INCLUDE_TESTS=OFF \
  -DLIBCXX_ENABLE_THREADS=ON -DLIBCXXABI_ENABLE_THREADS=ON
cmake --build "$B" -j "${JOBS:-12}"
cmake --install "$B"
ls -la /ws/install/libcxx-wasm32_nommu/lib
