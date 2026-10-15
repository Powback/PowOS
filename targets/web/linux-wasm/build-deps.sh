#!/bin/bash
# Runs inside the Linux/Wasm build container (build.sh build-dep:<name>): a C library PowOS needs on Linux/Wasm,
# static, with the shared toolchain (qt-toolchain.sh), into the Qt/KDE prefix so their CMake finds it.
#   expat - XML parser (dbus-daemon's config files)
#   dbus  - libdbus + dbus-daemon (Qt DBus, KDE Frameworks, Plasma)
#   zlib  - compression (KArchive)
# Sources: out/linux-wasm/dl/<file>, sha256-checked (dbus: cross-checked against Alpine's pinned sha512, since
# upstream publishes only a GPG signature).
set -euo pipefail
name=$1
PREFIX=/ws/install/qt-wasm32_nommu
declare -A FILE=(
  [expat]=expat-2.9.0.tar.xz
  [dbus]=dbus-1.16.2.tar.xz
  [zlib]=zlib-1.3.2.tar.xz
)
declare -A SHA256=(
  [expat]=1e6371862cc31999b368c3b89b49994f0677e1bab5f1b2b85ae3741f5d803051
  [dbus]=0ba2a1a4b16afe7bceb2c07e9ce99a8c2c3508e5dec290dbb643384bd6beb7e2
  [zlib]=d7a0654783a4da529d1bb793b7ad9c3318020af77667bcae35f95d0e42a792f3
)
declare -A ARGS=(
  [expat]="-DEXPAT_BUILD_TOOLS=OFF -DEXPAT_BUILD_EXAMPLES=OFF -DEXPAT_BUILD_TESTS=OFF -DEXPAT_BUILD_DOCS=OFF -DEXPAT_SHARED_LIBS=OFF"
  # No systemd/X11/launchd/GLib; the session bus socket in /tmp (tmpfs); no docs/tests.
  [dbus]="-DDBUS_BUILD_TESTS=OFF -DDBUS_ENABLE_XML_DOCS=OFF -DDBUS_ENABLE_DOXYGEN_DOCS=OFF -DDBUS_BUILD_X11=OFF -DENABLE_SYSTEMD=OFF -DDBUS_WITH_GLIB=OFF -DDBUS_SESSION_SOCKET_DIR=/tmp -DDBUS_ENABLE_STATS=OFF"
  [zlib]="-DZLIB_BUILD_TESTING=OFF -DZLIB_BUILD_SHARED=OFF -DZLIB_BUILD_STATIC=ON"
)
[ -n "${FILE[$name]:-}" ] || { echo "unknown dependency: $name" >&2; exit 1; }
TARBALL=/out/dl/${FILE[$name]}
SRC=/ws/src/dep-$name
B=/ws/build/dep-$name
export REAL_LLVM=/ws/install/llvm/bin
# HACK: the toolchain's sysroot-only search mode re-roots absolute search hints (pkg-config's include/lib dirs in
# this prefix, which Find modules pass to find_path/find_library) under the musl sysroot, so they are never found.
# Map the re-rooted prefix back with a symlink inside the sysroot. Real fix: install the prefix inside the sysroot.
mkdir -p /ws/install/musl-wasm32_nommu/ws/install
ln -sfn /ws/install/qt-wasm32_nommu /ws/install/musl-wasm32_nommu/ws/install/qt-wasm32_nommu
if [ ! -f "$SRC/CMakeLists.txt" ]; then
  echo "${SHA256[$name]}  $TARBALL" | sha256sum -c -
  rm -rf "$SRC" && mkdir -p "$SRC"
  tar -xJf "$TARBALL" -C "$SRC" --strip-components=1
fi
# PowOS patches over a dependency (idempotent): patch-<name>.py next to this script, when there is one.
[ ! -f "/powos-lw/patch-$name.py" ] || python3 "/powos-lw/patch-$name.py" "$SRC"
rm -rf "$B" && mkdir -p "$B"
bash /powos-lw/qt-toolchain.sh > "$B/toolchain.cmake"
cmake -G Ninja -S "$SRC" -B "$B" -DCMAKE_TOOLCHAIN_FILE="$B/toolchain.cmake" -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=$PREFIX -DCMAKE_PREFIX_PATH=$PREFIX -DBUILD_SHARED_LIBS=OFF -DCMAKE_SKIP_RPATH=ON \
  ${ARGS[$name]:-}
cmake --build "$B" -j "${JOBS:-12}"
cmake --install "$B"
