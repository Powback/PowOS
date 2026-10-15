#!/bin/bash
# Builds PowOS's own Linux/Wasm programs (linux-wasm/apps/*.c, *.cpp) with the Linux/Wasm toolchain (build.sh) the
# way upstream builds BusyBox: clang via the fake-llvm wrapper, musl sysroot, -fPIC + a shared-library link (NOMMU
# Wasm), musl + compiler-rt linked in explicitly. C++ links the static libc++/libc++abi from build.sh build-libcxx.
# -D__USE_TIME_BITS64: musl has 64-bit time_t, and with it the kernel uapi headers use the 16-byte wasm32 input_event
# (32-bit __sec/__usec) the kernel writes - without it programs read 24-byte events and misparse them.
# -pie (not upstream's -shared; same dylink.0 relocatable module, --import-table added by hand since the wrapper only
# adds it for -shared): a shared library must let other modules override its symbols, so wasm-ld routes default-
# visibility symbols through GOT.mem/GOT.func imports and IMPORTS every weak definition it also exports - all of
# C++'s inline/template code and operator new ("_Znwm: function import requires a callable"). A program is the only
# module, so as a PIE nothing is preemptible and its imports are the same handful the C programs need.
# Output: out/linux-wasm/apps/<name> (+ <name>.link.txt: the link line and the module's sections, for debugging).
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$HERE/out/linux-wasm/apps"
"$HERE/linux-wasm/ws.sh" '
  set -e
  export REAL_LLVM=/ws/install/llvm/bin
  CC=/linux-wasm/tools/fake-llvm/clang
  COMMON="--target=wasm-linux-musl -march=wasm32 --sysroot=/ws/install/musl-wasm32_nommu
    -isystem /ws/install/busybox-kernel-headers-wasm32_nommu -D__USE_TIME_BITS64 -fPIC -O2 -Wl,-pie -Wl,--import-table"
  CXX=/ws/install/libcxx-wasm32_nommu
  for src in /web/linux-wasm/apps/*.c /web/linux-wasm/apps/*.cpp; do
    [ -f "$src" ] || continue
    n=$(basename "${src%.*}")
    case $src in
      *.c)   $CC $COMMON -o /tmp/$n "$src" -lc --rtlib=compiler-rt -v > /tmp/$n.log 2>&1 ;;
      *.cpp) $CC $COMMON -x c++ -std=c++20 -fno-exceptions -nostdinc++ -isystem $CXX/include/c++/v1 \
               -o /tmp/$n "$src" -L$CXX/lib -lc++ -lc++abi -lpowos-wasm-support -lc --rtlib=compiler-rt -v > /tmp/$n.log 2>&1 ;;
    esac || { grep -E "error|undefined" /tmp/$n.log | head -20; exit 1; }
    { grep -E "wasm-ld" /tmp/$n.log | tail -1; $REAL_LLVM/llvm-objdump -h /tmp/$n; } > /out/apps/$n.link.txt 2>&1
    cp /tmp/$n /out/apps/$n
    ls -la /out/apps/$n
  done'
