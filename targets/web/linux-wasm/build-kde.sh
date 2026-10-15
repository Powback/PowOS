#!/bin/bash
# Runs inside the Linux/Wasm build container (build.sh build-kde:<name>): a KDE Frameworks module for PowOS on
# Linux/Wasm, static, against the Qt from build-qt.sh, into the same prefix (/ws/install/qt-wasm32_nommu).
# extra-cmake-modules is CMake files only. Sources: out/linux-wasm/dl/<name>-$KF_VERSION.tar.xz, sha256-checked.
set -euo pipefail
name=$1
KF_VERSION=6.31.0
declare -A SHA256=(
  [extra-cmake-modules]=8f74af329e4c918358bfe54316f8cf4d530c28444595a3e2fb15075f72877f17
  [kirigami]=811a8a150e636216269c0346e62470997fa282113a39e32b2d332bd5969926f0
)
# Per-module CMake options. No D-Bus yet (libdbus/dbus-daemon aren't built for Wasm): modules where it's optional
# build without it.
declare -A MODULE_ARGS=(
  [kirigami]="-DUSE_DBUS=OFF"
)
PREFIX=/ws/install/qt-wasm32_nommu
TARBALL=/out/dl/$name-$KF_VERSION.tar.xz
SRC=/ws/src/$name-$KF_VERSION
B=/ws/build/kde-$name
JOBS=${JOBS:-12}
export REAL_LLVM=/ws/install/llvm/bin

if [ ! -f "$SRC/CMakeLists.txt" ]; then
  [ -n "${SHA256[$name]:-}" ] || { echo "no sha256 for $name" >&2; exit 1; }
  echo "${SHA256[$name]}  $TARBALL" | sha256sum -c -
  rm -rf "$SRC" && mkdir -p "$SRC"
  tar -xJf "$TARBALL" -C "$SRC" --strip-components=1
fi
# HACK: no translations - compiling a module's poqm/ catalogs needs Qt Linguist's lrelease on the host (qttools),
# not built yet; KDE modules skip them when the directory is absent, so apps run in English. Real fix: build
# qttools' linguist tools in build-qt.sh host-module and drop this.
rm -rf "$SRC/poqm" "$SRC/po"
[ "${QT_INCREMENTAL:-}" = 1 ] || rm -rf "$B"
mkdir -p "$B"
# Static, no tests/docs; no RPATHs (static Wasm programs have none - see build-qt.sh). QML modules go where Qt's
# own are (KDE defaults to lib/qml): a static program's qt_import_qml_plugins only finds plugins Qt's scanner sees.
$PREFIX/bin/qt-cmake -G Ninja -S "$SRC" -B "$B" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$PREFIX \
  -DCMAKE_PREFIX_PATH=$PREFIX -DQT_HOST_PATH=/ws/install/qt-host -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF \
  -DBUILD_QCH=OFF -DBUILD_DOC=OFF -DKDE_INSTALL_QMLDIR=qml -DCMAKE_SKIP_RPATH=ON -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON ${MODULE_ARGS[$name]:-} ${KDE_ARGS:-}
cmake --build "$B" -j "$JOBS"
cmake --install "$B"
