#!/usr/bin/env bash
# image-build.sh — bake sources/kde/patches/<app>/ into the OS image.
#
# Runs in a throwaway Containerfile stage FROM THE SAME base image, so the
# rebuilt bits match the shipped app's exact version and ABI. For each app
# with patches: clone the release tag matching the INSTALLED rpm, apply the
# patches, build, and stage artifacts into $OUT for the final image's
# `COPY --from=kde-builder`.
#
# Per-app build.conf (next to the patches) keeps CI fast by building only
# named cmake targets and shipping only named artifacts:
#   BUILD_TARGETS="org.kde.plasma.taskmanager"
#   SHIP_ARTIFACTS="bin/plasma/applets/org.kde.plasma.taskmanager.so:/usr/lib64/qt6/plugins/plasma/applets/"
# (artifact path is relative to the cmake build dir → destination dir in the
# image; multiple space-separated pairs allowed)
# Without build.conf: full build + `cmake --install` DESTDIR (slow, complete).
#
# A patch that no longer applies or builds FAILS THE IMAGE BUILD — loud on
# purpose: base updates that break a patch must be seen, not silently dropped.
set -euo pipefail

KDE_DIR="${1:?usage: image-build.sh <sources/kde dir> <out dir>}"
OUT="${2:?usage: image-build.sh <sources/kde dir> <out dir>}"
mkdir -p "$OUT"

shopt -s nullglob
appdirs=("$KDE_DIR"/patches/*/)
if [[ ${#appdirs[@]} -eq 0 ]]; then
    echo "kde-image-build: no patches under $KDE_DIR/patches — nothing to bake"
    exit 0
fi

# Category map for invent.kde.org URLs (same source of truth as `dev fork`).
# shellcheck disable=SC1091
source "$KDE_DIR/dev.conf"

dnf5 -y install --setopt=install_weak_deps=False \
    'dnf5-command(builddep)' git-core gcc-c++ cmake ninja-build

for appdir in "${appdirs[@]}"; do
    app="$(basename "$appdir")"
    patches=("$appdir"*.patch)
    if [[ ${#patches[@]} -eq 0 ]]; then
        echo "kde-image-build: $app has no .patch files, skipping"
        continue
    fi

    if ! ver="$(rpm -q --qf '%{VERSION}' "$app")"; then
        echo "ERROR: '$app' (from patches/$app) is not installed in the base image" >&2
        exit 1
    fi
    category="${KDE_APP_CATEGORIES[$app]:-system}"
    url="${KDE_INVENT_URL:-https://invent.kde.org}/$category/$app.git"

    echo "── $app $ver — ${#patches[@]} patch(es), $url ──"
    # Source repos are defined-but-disabled on Fedora; builddep usually
    # auto-enables them, fall back to explicit enable if not.
    dnf5 -y builddep "$app" || dnf5 -y builddep --enablerepo='*source*' "$app"

    src="/tmp/kde-build/$app"
    rm -rf "$src"
    git clone --depth 1 --branch "v$ver" "$url" "$src"
    for p in "${patches[@]}"; do
        echo "kde-image-build: applying $(basename "$p")"
        git -C "$src" apply --verbose "$p"
    done

    BUILD_TARGETS="" SHIP_ARTIFACTS=""
    if [[ -f "$appdir/build.conf" ]]; then
        # shellcheck disable=SC1090
        source "$appdir/build.conf"
    fi

    cmake -S "$src" -B "$src/build" -G Ninja \
        -DCMAKE_INSTALL_PREFIX=/usr \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_TESTING=OFF

    if [[ -n "$BUILD_TARGETS" && -n "$SHIP_ARTIFACTS" ]]; then
        # shellcheck disable=SC2086
        cmake --build "$src/build" --target $BUILD_TARGETS -j"$(nproc)"
        for pair in $SHIP_ARTIFACTS; do
            rel="${pair%%:*}"
            dest="$OUT${pair##*:}"
            mkdir -p "$dest"
            cp -v "$src/build/$rel" "$dest/"
        done
    else
        echo "kde-image-build: no build.conf for $app — full build + install (slow)"
        cmake --build "$src/build" -j"$(nproc)"
        DESTDIR="$OUT" cmake --install "$src/build"
    fi
    rm -rf "$src"
done

echo "kde-image-build: done — staged artifacts:"
find "$OUT" -type f
