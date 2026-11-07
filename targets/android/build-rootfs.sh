#!/bin/bash
# Builds the PowOS Android rootfs (Arch Linux ARM + Andromarchy's no-root engine + KDE Plasma + the PowOS
# layer) as powos-rootfs.tar.gz, natively on an aarch64 Docker host (Apple Silicon Colima: no qemu).
#
# Usage: targets/android/build-rootfs.sh [path/to/kwin-*.pkg.tar.zst]
#        POWOS_FROM_ROOTFS=<full powos-rootfs.tar.gz> targets/android/build-rootfs.sh
#   The second form skips the build: it re-splits an already built (and checked) full rootfs, e.g. the published one,
#   after a rootfs-packs.conf change, then publishes and pins like a build (~10 min instead of hours).
#   Output: $POWOS_IMAGES/powos-rootfs.tar.gz (+ .sha256, base + packs; also pinned into the app when published) - on the
#   NAS, /mnt/nas/cdn/powos/android/images/<checkout> by default (tools/data-root.sh). Default kwin package:
#   targets/android/out/pkgs/kwin-*.pkg.tar.* (build it with targets/android/build-pkgs.sh).
#
# Install on a phone running the stock Andromarchy app (offline install path of its InstallActivity):
#   adb push $POWOS_IMAGES/powos-rootfs.tar.gz /sdcard/Android/data/andro.marchy/files/lotfix-rootfs.tar.gz
# HACK: the lotfix-rootfs.tar.gz name is Andromarchy's; their app looks for exactly that file.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$HERE/out
W=$OUT/work
mkdir -p "$OUT" "$W"
. "$HERE/tools/data-root.sh"
# The images are write-once bulk (~13 GB per build): they go on the NAS, not the Mac disk (PowCDN).
mkdir -p "$POWOS_IMAGES" || { echo "build-rootfs: can't create $POWOS_IMAGES (NAS mounted? POWOS_DATA_ROOT)" >&2; exit 1; }

# Pinned inputs. Bump deliberately: our patch and the KWin port target these.
ANDROMARCHY_URL=https://github.com/lotfibennour/andromarchy
ANDROMARCHY_REF=220754d390f743aa5a8227e689402de1a6eb0281
IMAGE=menci/archlinuxarm:latest   # build host userland only; the rootfs itself is the ALARM tarball

# Step 1 inputs: our KWin + Xwayland packages, and Andromarchy at the pinned commit with our build patches.
fetch_inputs() {
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
}

# Step 2: stage what goes into the image ($S): the PowOS manifest, our packages and this checkout's PowOS layer.
stage_powos() {
# 2. What PowOS is: the published PowOS Deck image's manifest and content (see
#    .github/workflows/phone-manifest.yml). POWOS_MANIFEST picks another one (e.g. a commit's deck-<digest>).
S=$W/powos
rm -rf "$S" && mkdir -p "$S/pkgs"
if [ -n "${POWOS_MANIFEST_DIR:-}" ]; then
  # Reuse a completed fetch when retrying a build, without downloading the content archive again.
  for f in image.txt packages.tsv leaves.tsv content.list content.tar.zst; do
    [ -s "$POWOS_MANIFEST_DIR/$f" ] || { echo "missing manifest input: $POWOS_MANIFEST_DIR/$f" >&2; exit 1; }
  done
  cp -a "$POWOS_MANIFEST_DIR" "$S/manifest"
else
  "$HERE/tools/fetch-manifest.sh" "$S/manifest" "${POWOS_MANIFEST:-ghcr.io/powback/powos-phone:deck}"
fi
cp $("$HERE/tools/newest-pkgs.sh" "$OUT/pkgs") "$S/pkgs/"   # ours: kwin, fex-emu, recipes.list builds (newest of each)
# Plasma at our KWin's version, from the rootfs KWin builds on (tools/plasma-pin.sh: Arch Linux ARM moved Plasma past it).
"$HERE/tools/plasma-pin.sh" && cp -a "$OUT/plasma-pin" "$S/plasma-pin"
cp -a "$HERE/session" "$HERE/shims" "$HERE/play" "$HERE/phone-rules.conf" "$HERE/tools/resolve-packages.py" "$HERE/tools/phone-parity.py" "$S/"
install -m 755 "$HERE/install-powos-android.sh" "$S/"
# The PowOS desktop widgets from this checkout (install-powos-android.sh puts them over the image content's).
cp -a "$HERE/../../desktop/plasmoid" "$S/plasmoids"
# The downloaded manifest supplies distro packages; ship this checkout's committed PowOS CLI and libraries.
mkdir -p "$S/current"
# The whole tree, exactly as CI's .snapshot (git archive HEAD): install-powos-android.sh takes bin/ and lib/ from it
# and bakes it as the bundled source that `powos self` attaches to origin.
mkdir -p "$S/current/src"
git -C "$HERE/../.." archive HEAD | tar -x -C "$S/current/src"
git -C "$HERE/../.." rev-parse HEAD > "$S/current/revision"
}

# Step 3: the build itself, in a container on scratch space that never fills the shared Docker disk.
build_in_container() {
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
  "${work[@]}" -v powos-android-cache:/cache -v "$W:/in:ro" -v "$POWOS_IMAGES:/out" -v "$HERE/rootfs-in-container.sh:/rootfs-in-container.sh:ro" \
  "$IMAGE" bash -c "$inner"
echo "built: $POWOS_IMAGES/powos-rootfs.tar.gz"
}

# The full build (steps 1-3); POWOS_FROM_ROOTFS takes an existing full rootfs instead.
build_full() {
  fetch_inputs "$@"
  stage_powos
  build_in_container
}
if [ -n "${POWOS_FROM_ROOTFS:-}" ]; then
  [ -s "$POWOS_FROM_ROOTFS" ] && [ -s "$POWOS_FROM_ROOTFS.sha256" ] ||
    { echo "build-rootfs: POWOS_FROM_ROOTFS=$POWOS_FROM_ROOTFS: no such rootfs (with .sha256)" >&2; exit 1; }
  publish_file "$POWOS_FROM_ROOTFS" "$POWOS_IMAGES/powos-rootfs.tar.gz"
  publish_file "$POWOS_FROM_ROOTFS.sha256" "$POWOS_IMAGES/powos-rootfs.tar.gz.sha256"
  echo "re-splitting $POWOS_FROM_ROOTFS (no build)"
else
  build_full "$@"
fi
# KWin is ours at a pinned Plasma version (pkgs/kwin, IgnorePkg); the Plasma libraries it links come from today's Arch
# Linux ARM. When those move a minor version KWin can't start at all: the 11-04 rootfs had kscreenlocker/libplasma/
# plasma-workspace 6.8.1 under kwin 6.7.5 ("undefined symbol ScreenLocker::KSldApp::lock" - no desktop, no Linux app
# window on any phone that installs it). Refused here, before it is split, pinned or published.
tar -tzf "$POWOS_IMAGES/powos-rootfs.tar.gz" ./var/lib/pacman/local 2>/dev/null > "$W/rootfs-pacdb.lst" || tar -tzf "$POWOS_IMAGES/powos-rootfs.tar.gz" > "$W/rootfs-pacdb.lst"
plasma_ver() { sed -n "s#^\(\./\)\{0,1\}var/lib/pacman/local/$2-\([0-9][0-9]*\.[0-9][0-9]*\)\..*#\2#p" "$W/rootfs-pacdb.lst" | head -n 1; }
kw=$(plasma_ver "$POWOS_IMAGES/powos-rootfs.tar.gz" kwin)
for lib in kscreenlocker libplasma plasma-workspace kdecoration; do
  sl=$(plasma_ver "$POWOS_IMAGES/powos-rootfs.tar.gz" $lib)
  [ -n "$kw" ] && [ "$kw" = "$sl" ] || {
    echo "build-rootfs: kwin is Plasma ${kw:-?} but $lib is ${sl:-?}: KWin won't start in this rootfs." >&2
    echo "  tools/plasma-pin.sh pins Plasma to kwin's version (install-powos-android.sh), or move pkgs/kwin to ${sl:-theirs}." >&2
    exit 1; }
done
# The same rootfs split for phones without root (rootfs-packs.conf): a base image they download first and the packs
# the app adds on demand (gaming, languages). Read from the full tarball, so it never changes what rooted installs get.
python3 -I "$HERE/tools/split-rootfs.py" "$POWOS_IMAGES/powos-rootfs.tar.gz" "$HERE/rootfs-packs.conf" "$POWOS_IMAGES"

# Serve it to the PowOS app (engine InstallActivity.ROOTFS_URL = http://android.pow/apk/powos-rootfs.tar.gz):
# android-app-dev's web server serves the rootfs/base/pack names from $POWOS_PUBLISHED (its nginx.conf), the rest of
# /apk/ from its output/. Same NAS as the build, so publishing is a hard link (publish_file copies if it can't link).
PUBLISH=${POWOS_PUBLISH_DIR:-$POWOS_PUBLISHED}
[ -n "${POWOS_PUBLISH_DIR:-}" ] || mkdir -p "$PUBLISH"
if [ -d "$PUBLISH" ]; then
  publish_file "$POWOS_IMAGES/powos-rootfs.tar.gz" "$PUBLISH/powos-rootfs.tar.gz" && echo "published: http://android.pow/apk/powos-rootfs.tar.gz"
  # The app refuses a rootfs whose sha256 isn't the one pinned in its assets (InstallActivity.PIN_ASSET): pin what
  # was just published, so the next build-app.sh ships the matching pin. Commit the pin with the rebuild; until the new
  # APK is out, first installs with the old APK refuse this tarball (by design: the pin is what makes it trusted).
  PIN=$HERE/app/engine/src/main/assets/powos-rootfs.sha256
  cut -d' ' -f1 "$POWOS_IMAGES/powos-rootfs.tar.gz.sha256" > "$PIN"
  echo "pinned: $(cat "$PIN") in ${PIN#$HERE/} - rebuild the app (build-app.sh) and commit the pin"
  # Base + packs beside it, pinned the same way (InstallActivity uses the base once it and every pack are pinned).
  # Opt-in (POWOS_PUBLISH_PACKS=1) until the base is the approved first install for phones without root.
  if [ "${POWOS_PUBLISH_PACKS:-0}" = 1 ]; then
    for f in powos-rootfs-base $(cut -f1 "$POWOS_IMAGES/powos-packs.tsv" | grep -vx base | sed 's/^/powos-pack-/'); do
      publish_file "$POWOS_IMAGES/$f.tar.gz" "$PUBLISH/$f.tar.gz"
      cut -d' ' -f1 "$POWOS_IMAGES/$f.tar.gz.sha256" > "$HERE/app/engine/src/main/assets/$f.sha256"
      echo "published + pinned: http://android.pow/apk/$f.tar.gz"
    done
  fi
fi
