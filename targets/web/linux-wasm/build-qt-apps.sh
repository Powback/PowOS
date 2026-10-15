#!/bin/bash
# Builds PowOS's Qt programs for Linux/Wasm (linux-wasm/qt-apps/<name>/, CMake projects) against the static Qt from
# build.sh build-qt, with the shared toolchain (qt-toolchain.sh) -> out/linux-wasm/apps/<name> (on the disk at
# /powos/apps after build-disk.sh). Run them with QT_QPA_PLATFORM=linuxfb QT_QPA_FONTDIR=/powos/fonts (see
# initramfs/etc/profile).   [KEEP_NAMES=1] build-qt-apps.sh [name...]
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$HERE/out/linux-wasm/apps"
"$HERE/linux-wasm/ws.sh" '
  set -e
  export REAL_LLVM=/ws/install/llvm/bin
  bash /web/linux-wasm/qt-toolchain.sh > /tmp/toolchain.cmake
  for dir in '"${*:-/web/linux-wasm/qt-apps/*}"'; do
    case $dir in /*) ;; *) dir=/web/linux-wasm/qt-apps/$dir ;; esac
    n=$(basename "$dir")
    B=/ws/build/qt-apps/$n
    rm -rf "$B" && mkdir -p /ws/build/qt-apps
    cmake -G Ninja -S "$dir" -B "$B" -DCMAKE_BUILD_TYPE=Release -DCMAKE_TOOLCHAIN_FILE=/tmp/toolchain.cmake \
      -DQT_HOST_PATH=/ws/install/qt-host -DCMAKE_PREFIX_PATH=/ws/install/qt-wasm32_nommu > "$B.log" 2>&1 \
      && cmake --build "$B" >> "$B.log" 2>&1 \
      || { grep -E "error|Error|undefined" "$B.log" | head -30; exit 1; }
    # The name section (function names, for stack traces) is most of the file; keep it in $B/$n for debugging.
    # Only that section: dylink.0 is what the runtime relocates the program with.
    if [ "'"${KEEP_NAMES:-}"'" = 1 ]; then cp "$B/$n" /out/apps/$n   # KEEP_NAMES=1: symbolized crash stacks
    else $REAL_LLVM/llvm-objcopy --remove-section=name "$B/$n" /out/apps/$n; fi
    ls -la /out/apps/$n
  done'
