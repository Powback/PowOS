#!/usr/bin/env bash
# image-build.sh - the Containerfile's powos-shell-builder stage: the build deps, then build.sh into OUT, for the
# final image's `COPY --from=powos-shell-builder`. Runs FROM the same base image, so powos-shell links the exact
# Qt / KF6 / libtaskmanager the image ships. A build failure fails the image build (loud on purpose, as kde's).
#
#   image-build.sh <sources/powos-shell dir> <shell/ dir> <out dir>
set -euo pipefail
SRC="${1:?usage: image-build.sh <sources/powos-shell> <shell/> <out>}"
WEB="${2:?usage: image-build.sh <sources/powos-shell> <shell/> <out>}"
OUT="${3:?usage: image-build.sh <sources/powos-shell> <shell/> <out>}"
# shellcheck source=source.conf
source "$SRC/source.conf"
# `--setopt=*.exclude=`: Bazzite excludes Fedora's mesa-* (it ships its own), which can leave a -devel package's
# GL/EGL requirement with no provider (sources/kde/image-build.sh has the story). Safe here: this stage is thrown
# away, only OUT reaches the image.
# shellcheck disable=SC2086
dnf5 -y install --setopt=install_weak_deps=False --setopt='*.exclude=' $BUILD_DEPS
mkdir -p "$OUT"
POWOS_SHELL_WEB="$WEB" POWOS_SHELL_BUILD_DIR=/tmp/powos-shell-build bash "$SRC/build.sh" "$OUT"
