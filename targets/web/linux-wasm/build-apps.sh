#!/bin/bash
# Builds PowOS's own Linux/Wasm programs (linux-wasm/apps/*.c) with the Linux/Wasm toolchain (build.sh) the way
# upstream builds BusyBox: clang via the fake-llvm wrapper, musl sysroot, -fPIC + a shared-library link (NOMMU Wasm).
# -D__USE_TIME_BITS64: musl has 64-bit time_t, and with it the kernel uapi headers use the 16-byte wasm32 input_event
# (32-bit __sec/__usec) the kernel writes - without it programs read 24-byte events and misparse them.
# Output: out/linux-wasm/apps/<name> (+ <name>.link.txt: the link line and the module's sections, for debugging).
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$HERE/out/linux-wasm/apps"
"$HERE/linux-wasm/ws.sh" '
  set -e
  export REAL_LLVM=/ws/install/llvm/bin
  for src in /web/linux-wasm/apps/*.c; do
    n=$(basename "$src" .c)
    /linux-wasm/tools/fake-llvm/clang --target=wasm-linux-musl -march=wasm32 \
      --sysroot=/ws/install/musl-wasm32_nommu -isystem /ws/install/busybox-kernel-headers-wasm32_nommu \
      -D__USE_TIME_BITS64 -fPIC -O2 -Wl,-shared -o /tmp/$n "$src" -lc --rtlib=compiler-rt -v > /tmp/$n.log 2>&1 || { cat /tmp/$n.log; exit 1; }
    { grep -E "wasm-ld" /tmp/$n.log | tail -1; $REAL_LLVM/llvm-objdump -h /tmp/$n; } > /out/apps/$n.link.txt 2>&1
    cp /tmp/$n /out/apps/$n
    ls -la /out/apps/$n
  done'
