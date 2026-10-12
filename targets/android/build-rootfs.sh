#!/bin/bash
# Builds the PowOS Android rootfs (Arch Linux ARM + Andromarchy's no-root engine + KDE Plasma + the PowOS
# layer) as powos-rootfs.tar.gz, natively on an aarch64 Docker host (Apple Silicon Colima: no qemu).
#
# Usage: targets/android/build-rootfs.sh [path/to/kwin-*.pkg.tar.zst]
#   Output: targets/android/out/powos-rootfs.tar.gz (+ .sha256). Default kwin package:
#   targets/android/out/pkgs/kwin-*.pkg.tar.* (build it with targets/android/build-pkgs.sh).
#
# Install on a phone running the stock Andromarchy app (offline install path of its InstallActivity):
#   adb push out/powos-rootfs.tar.gz /sdcard/Android/data/andro.marchy/files/lotfix-rootfs.tar.gz
# HACK: the lotfix-rootfs.tar.gz name is Andromarchy's; their app looks for exactly that file.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
OUT=$HERE/out
W=$OUT/work
mkdir -p "$OUT" "$W"

# Pinned inputs. Bump deliberately: our patch and the KWin port target these.
ANDROMARCHY_URL=https://github.com/lotfibennour/andromarchy
ANDROMARCHY_REF=220754d390f743aa5a8227e689402de1a6eb0281
IMAGE=menci/archlinuxarm:latest   # build host userland only; the rootfs itself is the ALARM tarball

KWIN_PKG=${1:-$(ls "$OUT"/pkgs/kwin-*.pkg.tar.* 2>/dev/null | head -1)}
[ -f "${KWIN_PKG:-}" ] || { echo "no kwin package: run targets/android/build-pkgs.sh first" >&2; exit 1; }

"$HERE/check-layer-drift.sh"

# 1. Andromarchy at the pinned commit, with our build patch.
rm -rf "$W/andromarchy"
git clone -q "$ANDROMARCHY_URL" "$W/andromarchy"
git -C "$W/andromarchy" checkout -q "$ANDROMARCHY_REF"
for p in "$HERE"/patches/andromarchy/*.patch; do patch -d "$W/andromarchy" -p1 < "$p"; done

# 2. The PowOS layer, laid out at its destinations (layer.list '+' lines).
S=$W/powos
rm -rf "$S" && mkdir -p "$S/layer" "$S/pkgs"
rm -rf "$W/snapshot" && mkdir -p "$W/snapshot"
git -C "$REPO" archive HEAD | tar -x -C "$W/snapshot"   # same as CI's .snapshot/: the committed tree
while read -r mark src dst _; do
  [ "$mark" = + ] || continue
  from=$REPO/$src
  [ "$src" = .snapshot/ ] && from=$W/snapshot/
  mkdir -p "$S/layer/$(dirname "$dst")"
  if [ -d "$from" ]; then mkdir -p "$S/layer/$dst" && cp -a "$from". "$S/layer/$dst"
  else cp -a "$from" "$S/layer/$dst"; fi
done < <(grep -E '^[+-] ' "$HERE/layer.list")
cp "$KWIN_PKG" "$S/pkgs/"
cp -a "$HERE/session" "$HERE/shims" "$S/"
install -m 755 "$HERE/install-powos-android.sh" "$S/"

# 3. Build inside a privileged aarch64 container (chroot + mounts need it), on a Docker volume:
#    a bind-mounted macOS directory can't hold Linux ownership, device nodes or hard links.
# Resource caps keep the build from starving the services running on the same Colima VM.
# The Docker disk is shared with the live PowStation services: a full disk breaks them (this build
# once filled it to 100%). Refuse to start without room for the ~15-20 GB working tree plus margin.
NEED_GB=25
free_gb=$(docker run --rm "$IMAGE" df -BG --output=avail /etc/hostname | tail -1 | tr -dc '0-9')
if [ "${free_gb:-0}" -lt "$NEED_GB" ]; then
  echo "only ${free_gb} GB free on the Docker disk; need ${NEED_GB} GB (shared with live services)" >&2
  exit 1
fi
docker volume create powos-android-rootfs >/dev/null
# The working tree is deleted afterwards (success or not): it is only scratch space, and leaving
# ~15-20 GB behind on the shared disk is how it filled up.
trap 'docker volume rm -f powos-android-rootfs >/dev/null 2>&1 || true' EXIT
docker run --rm --privileged --platform linux/arm64 --cpus 8 --memory 16g \
  -v powos-android-rootfs:/work -v "$W:/in:ro" -v "$OUT:/out" -v "$HERE/rootfs-in-container.sh:/rootfs-in-container.sh:ro" \
  "$IMAGE" bash /rootfs-in-container.sh
echo "built: $OUT/powos-rootfs.tar.gz"
