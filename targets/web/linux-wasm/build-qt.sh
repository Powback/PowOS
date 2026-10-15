#!/bin/bash
# Runs inside the Linux/Wasm build container (build.sh build-qt-host / build-qt): Qt (qtbase) for PowOS on Linux/Wasm.
#   host:   Qt's build tools (moc, rcc, uic, ...) for the build machine -> /ws/install/qt-host
#   target: qtbase for wasm32 NOMMU musl, static, drawing with linuxfb on /dev/fb0 (wasmfb: the page's canvas) and
#           reading /dev/input (wasminput) through the evdev plugins -> /ws/install/qt-wasm32_nommu
#   host-module M / target-module M: another Qt module (qtshadertools, qtdeclarative, ...) for host / target, built
#           against the Qt above (target: through its qt-cmake, which chain-loads our toolchain).
# Sources: out/linux-wasm/dl/<module>-everywhere-src-$QT_VERSION.tar.xz, sha256-checked against SHA256 below.
set -euo pipefail
stage=$1
module=${2:-qtbase}
QT_VERSION=6.12.0
declare -A SHA256=(
  [qtbase]=a951bd163c7b80fc6b8c88d7668fb56abf91c152373e13c10666763238131307
  [qtshadertools]=c7d84f436e1aaef39fdcadebf2bd71bdf24dc69497e13f2e0198873cbbfea2ab
  [qtdeclarative]=311f3a2603e1973bb59baef9dfa740a376de713157d4782ee043681e889c9260
  [qtsvg]=e4ab39534ec97987b1b9b60ef7f4d3253d5912a69f8c713a01753174a4029331
)
TARBALL=/out/dl/$module-everywhere-src-$QT_VERSION.tar.xz
SRC=/ws/src/$module-$QT_VERSION
JOBS=${JOBS:-12}
# The fake-llvm clang wrapper runs the real tools from here (also needed at build time, not just configure).
export REAL_LLVM=/ws/install/llvm/bin

if [ ! -f "$SRC/CMakeLists.txt" ]; then
  [ -n "${SHA256[$module]:-}" ] || { echo "no sha256 for $module" >&2; exit 1; }
  echo "${SHA256[$module]}  $TARBALL" | sha256sum -c -
  rm -rf "$SRC" && mkdir -p "$SRC"
  tar -xJf "$TARBALL" -C "$SRC" --strip-components=1
fi
# PowOS patches over Qt modules (idempotent).
[ "$module" != qtdeclarative ] || python3 /powos-lw/patch-qtdeclarative.py "$SRC"

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
    [ "${QT_INCREMENTAL:-}" = 1 ] || rm -rf "$B"   # QT_INCREMENTAL=1: reconfigure + rebuild only what changed
    mkdir -p "$B"
    bash /powos-lw/qt-toolchain.sh > "$B/toolchain.cmake"
    # Off: everything that needs fork (process), dlopen (library: plugins are linked in statically), GL/Vulkan
    # (no GPU), D-Bus, ICU, fontconfig. Qt Concurrent + Network on: Kirigami needs them; libinput/xkbcommon/udev/mtdev (the evdev plugins read wasminput directly).
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
      -DFEATURE_network=ON -DFEATURE_sql=OFF -DFEATURE_printsupport=OFF -DFEATURE_testlib=OFF -DFEATURE_concurrent=ON \
      -DINPUT_openssl=no
    cmake --build "$B" -j "$JOBS"
    cmake --install "$B"
    ls /ws/install/qt-wasm32_nommu/lib ;;
  host-module)
    B=/ws/build/qt-host-$module
    rm -rf "$B" && mkdir -p "$B"
    cmake -G Ninja -S "$SRC" -B "$B" -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH=/ws/install/qt-host \
      -DCMAKE_INSTALL_PREFIX=/ws/install/qt-host -DQT_BUILD_EXAMPLES=OFF -DQT_BUILD_TESTS=OFF
    cmake --build "$B" -j "$JOBS"
    cmake --install "$B" ;;
  target-module)
    # No RPATHs: static Wasm programs have none, and CMake refuses to rewrite them in non-ELF binaries at install.
    B=/ws/build/qt-wasm32_nommu-$module
    # QT_INCREMENTAL=1: keep the build tree (a patched file rebuilds in minutes, not a full module build).
    [ "${QT_INCREMENTAL:-}" = 1 ] || rm -rf "$B"
    mkdir -p "$B"
    /ws/install/qt-wasm32_nommu/bin/qt-cmake -G Ninja -S "$SRC" -B "$B" -DCMAKE_BUILD_TYPE=Release \
      -DQT_HOST_PATH=/ws/install/qt-host -DQT_BUILD_EXAMPLES=OFF -DQT_BUILD_TESTS=OFF \
      -DCMAKE_SKIP_RPATH=ON -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON ${QT_MODULE_ARGS:-}
    cmake --build "$B" -j "$JOBS"
    cmake --install "$B" ;;
  *) echo "usage: build-qt.sh host|target|host-module M|target-module M" >&2; exit 1 ;;
esac
