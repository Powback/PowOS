#!/bin/bash
# Runs inside the Linux/Wasm build container (build.sh build-qt-host / build-qt): Qt (qtbase) for PowOS on Linux/Wasm.
#   host:   Qt's build tools (moc, rcc, uic, ...) for the build machine -> /ws/install/qt-host
#   target: qtbase for wasm32 NOMMU musl, static, drawing with linuxfb on /dev/fb0 (wasmfb: the page's canvas) and
#           reading /dev/input (wasminput) through the evdev plugins -> /ws/install/qt-wasm32_nommu
# Source: out/linux-wasm/dl/qtbase-everywhere-src-$QT_VERSION.tar.xz (sha256-checked download, see QT_SHA256).
set -euo pipefail
stage=$1
QT_VERSION=6.12.0
QT_SHA256=a951bd163c7b80fc6b8c88d7668fb56abf91c152373e13c10666763238131307
TARBALL=/out/dl/qtbase-everywhere-src-$QT_VERSION.tar.xz
SRC=/ws/src/qtbase-$QT_VERSION
JOBS=${JOBS:-12}
# The fake-llvm clang wrapper runs the real tools from here (also needed at build time, not just configure).
export REAL_LLVM=/ws/install/llvm/bin

if [ ! -f "$SRC/CMakeLists.txt" ]; then
  echo "$QT_SHA256  $TARBALL" | sha256sum -c -
  rm -rf "$SRC" && mkdir -p "$SRC"
  tar -xJf "$TARBALL" -C "$SRC" --strip-components=1
fi

case $stage in
  host)
    B=/ws/build/qt-host
    rm -rf "$B" && mkdir -p "$B"
    cmake -G Ninja -S "$SRC" -B "$B" \
      -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/ws/install/qt-host \
      -DQT_BUILD_EXAMPLES=OFF -DQT_BUILD_TESTS=OFF \
      -DFEATURE_gui=ON -DFEATURE_widgets=ON -DINPUT_opengl=no -DFEATURE_opengl=OFF -DFEATURE_xcb=OFF -DFEATURE_wayland=OFF \
      -DFEATURE_dbus=OFF -DFEATURE_icu=OFF -DFEATURE_glib=OFF -DFEATURE_sql=OFF -DFEATURE_network=ON \
      -DFEATURE_printsupport=OFF -DFEATURE_testlib=OFF -DINPUT_openssl=no
    cmake --build "$B" -j "$JOBS"
    cmake --install "$B"
    ls /ws/install/qt-host/libexec ;;
  target)
    B=/ws/build/qt-wasm32_nommu
    rm -rf "$B" && mkdir -p "$B"
    bash /powos-lw/qt-toolchain.sh > "$B/toolchain.cmake"
    # Off: everything that needs fork (process), dlopen (library: plugins are linked in statically), GL/Vulkan
    # (no GPU), D-Bus, ICU, fontconfig; libinput/xkbcommon/udev/mtdev (the evdev plugins read wasminput directly).
    # Bundled freetype/harfbuzz/png/zlib/pcre2. Exceptions off like the libc++ we link (build-libcxx.sh).
    cmake -G Ninja -S "$SRC" -B "$B" \
      -DCMAKE_TOOLCHAIN_FILE="$B/toolchain.cmake" -DQT_HOST_PATH=/ws/install/qt-host \
      -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/ws/install/qt-wasm32_nommu \
      -DBUILD_SHARED_LIBS=OFF -DQT_BUILD_EXAMPLES=OFF -DQT_BUILD_TESTS=OFF -DQT_BUILD_BENCHMARKS=OFF \
      -DFEATURE_linuxfb=ON -DFEATURE_evdev=ON -DFEATURE_thread=ON \
      -DFEATURE_libinput=OFF -DFEATURE_tslib=OFF -DFEATURE_xkbcommon=OFF -DFEATURE_libudev=OFF -DFEATURE_mtdev=OFF \
      -DINPUT_opengl=no -DFEATURE_opengl=OFF -DFEATURE_vulkan=OFF -DFEATURE_egl=OFF -DFEATURE_eglfs=OFF -DFEATURE_kms=OFF \
      -DFEATURE_xcb=OFF -DFEATURE_wayland=OFF -DFEATURE_vnc=OFF \
      -DFEATURE_dbus=OFF -DFEATURE_glib=OFF -DFEATURE_icu=OFF -DFEATURE_fontconfig=OFF -DFEATURE_journald=OFF \
      -DFEATURE_freetype=ON -DFEATURE_system_freetype=OFF -DFEATURE_harfbuzz=ON -DFEATURE_system_harfbuzz=OFF \
      -DFEATURE_png=ON -DFEATURE_system_png=OFF -DFEATURE_jpeg=OFF -DFEATURE_system_zlib=OFF -DFEATURE_system_pcre2=OFF \
      -DFEATURE_process=OFF -DFEATURE_library=OFF -DFEATURE_sharedmemory=OFF -DFEATURE_systemsemaphore=OFF \
      -DFEATURE_backtrace=OFF -DFEATURE_exceptions=OFF \
      -DFEATURE_network=OFF -DFEATURE_sql=OFF -DFEATURE_printsupport=OFF -DFEATURE_testlib=OFF -DFEATURE_concurrent=OFF \
      -DINPUT_openssl=no
    cmake --build "$B" -j "$JOBS"
    cmake --install "$B"
    ls /ws/install/qt-wasm32_nommu/lib ;;
  *) echo "usage: build-qt.sh host|target" >&2; exit 1 ;;
esac
