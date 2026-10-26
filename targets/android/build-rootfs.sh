#!/bin/bash
# Builds the PowOS Android rootfs (Arch Linux ARM + Andromarchy's no-root engine + KDE Plasma + the PowOS
# layer) as powos-rootfs.tar.gz, natively on an aarch64 Docker host (Apple Silicon Colima: no qemu).
#
# Usage: targets/android/build-rootfs.sh [path/to/kwin-*.pkg.tar.zst]
#   Output: targets/android/out/powos-rootfs.tar.gz (+ .sha256, also pinned into the app when published). Default kwin package:
#   targets/android/out/pkgs/kwin-*.pkg.tar.* (build it with targets/android/build-pkgs.sh).
#
# Install on a phone running the stock Andromarchy app (offline install path of its InstallActivity):
#   adb push out/powos-rootfs.tar.gz /sdcard/Android/data/andro.marchy/files/lotfix-rootfs.tar.gz
# HACK: the lotfix-rootfs.tar.gz name is Andromarchy's; their app looks for exactly that file.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$HERE/out
W=$OUT/work
mkdir -p "$OUT" "$W"

# Pinned inputs. Bump deliberately: our patch and the KWin port target these.
ANDROMARCHY_URL=https://github.com/lotfibennour/andromarchy
ANDROMARCHY_REF=220754d390f743aa5a8227e689402de1a6eb0281
IMAGE=menci/archlinuxarm:latest   # build host userland only; the rootfs itself is the ALARM tarball

KWIN_PKG=${1:-$("$HERE/tools/newest-pkgs.sh" "$OUT/pkgs" kwin)}
[ -f "${KWIN_PKG:-}" ] || { echo "no kwin package: run targets/android/build-pkgs.sh first" >&2; exit 1; }
# Xwayland too (patches/andromarchy/0005: build-inside.sh installs it from our package instead of compiling it).
[ -n "$("$HERE/tools/newest-pkgs.sh" "$OUT/pkgs" xwayland-kgsl)" ] ||
  { echo "no xwayland-kgsl package: run targets/android/build-pkgs.sh xwayland-kgsl first" >&2; exit 1; }

# 1. Andromarchy at the pinned commit, with our build patch.
rm -rf "$W/andromarchy"
git clone -q "$ANDROMARCHY_URL" "$W/andromarchy"
git -C "$W/andromarchy" checkout -q "$ANDROMARCHY_REF"
for p in "$HERE"/patches/andromarchy/*.patch; do patch -d "$W/andromarchy" -p1 < "$p"; done

# 2. What PowOS is: the published PowOS Deck image's manifest (a few MB; see
#    .github/workflows/phone-manifest.yml). POWOS_MANIFEST picks another one (e.g. a commit's deck-<digest>).
S=$W/powos
rm -rf "$S" && mkdir -p "$S/pkgs"
"$HERE/tools/fetch-manifest.sh" "$S/manifest" "${POWOS_MANIFEST:-ghcr.io/powback/powos-phone:deck}"
cp $("$HERE/tools/newest-pkgs.sh" "$OUT/pkgs") "$S/pkgs/"   # ours: kwin, fex-emu, recipes.list builds (newest of each)
cp -a "$HERE/session" "$HERE/shims" "$HERE/play" "$HERE/phone-rules.conf" "$HERE/tools/resolve-packages.py" "$HERE/tools/phone-parity.py" "$S/"
install -m 755 "$HERE/install-powos-android.sh" "$S/"
# The PowOS desktop widgets from this checkout (install-powos-android.sh puts them over the image content's).
cp -a "$HERE/../../desktop/plasmoid" "$S/plasmoids"
# The downloaded manifest supplies distro packages; ship this checkout's committed PowOS CLI and libraries.
mkdir -p "$S/current"
git -C "$HERE/../.." archive HEAD bin lib | tar -x -C "$S/current"
git -C "$HERE/../.." rev-parse HEAD > "$S/current/revision"

# 3. Build inside a privileged aarch64 container (chroot + mounts need it), on a Docker volume:
#    a bind-mounted macOS directory can't hold Linux ownership, device nodes or hard links.
# Resource caps keep the build from starving the services running on the same Colima VM.
# The Docker disk is shared with the live PowStation services: a full disk breaks them (this build
# once filled it to 100%). Refuse to start without room for the ~15-20 GB working tree plus margin.
# POWOS_SCRATCH=image (or automatically when the Docker disk is short): the working tree goes in a sparse ext4
# image on the output directory's disk (the Mac's, via VirtioFS), loop-mounted in the container, so the build
# never touches the shared Docker disk beyond the package cache. ext4, not the macOS folder itself: the tree
# needs Linux ownership, device nodes and case-sensitive names.
NEED_GB=25
free_gb=$(docker run --rm "$IMAGE" df -BG --output=avail /etc/hostname | tail -1 | tr -dc '0-9')
SCRATCH=${POWOS_SCRATCH:-volume}
if [ "$SCRATCH" = volume ] && [ "${free_gb:-0}" -lt "$NEED_GB" ]; then
  echo "only ${free_gb} GB free on the Docker disk (shared with live services): working tree goes in a disk image" >&2
  SCRATCH=image
fi
# The volume/image name carries the worktree, so two checkouts building at once never share a working tree.
TAG=$(printf %s "$HERE" | cksum | cut -d' ' -f1)
if [ "$SCRATCH" = image ]; then
  IMG=$W/rootfs-scratch.img
  rm -f "$IMG" && truncate -s 40G "$IMG"
  trap 'rm -f "$IMG"' EXIT
  work=(-v "$W:/scratch")
  inner='mkfs.ext4 -q /scratch/rootfs-scratch.img && mkdir -p /work && mount -o loop /scratch/rootfs-scratch.img /work && bash /rootfs-in-container.sh; rc=$?; umount -l /work; exit $rc'
else
  VOL=powos-android-rootfs-$TAG
  docker volume create "$VOL" >/dev/null
  # The working tree is deleted afterwards (success or not): it is only scratch space, and leaving
  # ~15-20 GB behind on the shared disk is how it filled up.
  trap 'docker volume rm -f "$VOL" >/dev/null 2>&1 || true' EXIT
  work=(-v "$VOL:/work")
  inner='bash /rootfs-in-container.sh'
fi
# powos-android-cache is the opposite of scratch: kept between builds (Arch base tarball, pacman
# packages, Mesa/fakeroot sources) so dev rebuilds don't re-download ~3 GB. A few GB; never pruned here.
docker run --rm --privileged --platform linux/arm64 --cpus 8 --memory 16g \
  "${work[@]}" -v powos-android-cache:/cache -v "$W:/in:ro" -v "$OUT:/out" -v "$HERE/rootfs-in-container.sh:/rootfs-in-container.sh:ro" \
  "$IMAGE" bash -c "$inner"
echo "built: $OUT/powos-rootfs.tar.gz"

# Serve it to the PowOS app (engine InstallActivity.ROOTFS_URL = http://android.pow/apk/powos-rootfs.tar.gz):
# android-app-dev's web server serves its output/ there. A hard link, not a copy (same disk, ~2 GB).
PUBLISH=${POWOS_PUBLISH_DIR:-$HOME/Projects/android-app-dev/output}
if [ -d "$PUBLISH" ]; then
  ln -f "$OUT/powos-rootfs.tar.gz" "$PUBLISH/powos-rootfs.tar.gz" && echo "published: http://android.pow/apk/powos-rootfs.tar.gz"
  # The app refuses a rootfs whose sha256 isn't the one pinned in its assets (InstallActivity.PIN_ASSET): pin what
  # was just published, so the next build-app.sh ships the matching pin. Commit the pin with the rebuild; until the new
  # APK is out, first installs with the old APK refuse this tarball (by design: the pin is what makes it trusted).
  PIN=$HERE/app/engine/src/main/assets/powos-rootfs.sha256
  cut -d' ' -f1 "$OUT/powos-rootfs.tar.gz.sha256" > "$PIN"
  echo "pinned: $(cat "$PIN") in ${PIN#$HERE/} - rebuild the app (build-app.sh) and commit the pin"
fi
