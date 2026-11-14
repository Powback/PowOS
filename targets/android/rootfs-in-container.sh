#!/bin/bash
# Container half of build-rootfs.sh. Adapted from Andromarchy's build/build-rootfs.sh @ 220754d (steps 2-5),
# minus its x86 parts (apt, qemu-user binfmt) and the prebuilt Hyprland tarball. /in = staged inputs (ro),
# /work = Docker volume for the rootfs, /out = output directory.
set -euo pipefail
ALARM_URL=http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz
MESA_URL=https://github.com/lfdevs/mesa-for-android-container/releases/download/mesa-26.3.0-devel-20260824/mesa-for-android-container_26.3.0-devel-20260824_archlinux_arm64.tar
FAKEROOT_URL=https://deb.debian.org/debian/pool/main/f/fakeroot/fakeroot_1.37.1.1.orig.tar.gz
# Mesa source pin (lfdevs dev/adreno-main = Mesa main + KGSL/termux-va), as a commit archive: branches there get
# rewritten. The SAME commit as pkgs/vulkan-freedreno-kgsl's _commit (Gallium freedreno matches Turnip); its
# PKGBUILD header says how to move it. Was ef25369b (2026-10-04, test/add-va-bridge) until 11-04.
MESA_SRC_COMMIT=eb3e7fd4f009cab04b1482aad4843c0bde28a786  # 2026-10-29, Mesa 27.0.0-devel
MESA_SRC_URL=https://github.com/lfdevs/mesa-for-android-container/archive/$MESA_SRC_COMMIT.tar.gz
R=/work/rootfs
A=/in/andromarchy

# HACK: same pacman-sandbox workaround as the build container (Landlock not permitted in Docker).
grep -q '^DisableSandbox' /etc/pacman.conf || sed -i '/^\[options\]/a DisableSandbox' /etc/pacman.conf
# -Syu, never -Sy <pkg>: Arch supports no partial upgrade. 11-14: Arch Linux ARM moved to OpenSSL 4, and -Sy pulled the
# new curl + openssl 4 into an image whose pacman/cryptsetup/libldap still need libcrypto.so.3: "could not satisfy
# dependencies", every rootfs build failed here.
pacman -Syu --noconfirm --needed libarchive curl >/dev/null

# Fresh Arch Linux ARM base every build: a half-built rootfs from an interrupted run is not reusable.
# The tarball itself (~790 MB) is kept on the persistent cache volume, re-fetched only when newer.
mkdir -p /cache/dl
curl -fL -o /cache/dl/alarm.tar.gz -z /cache/dl/alarm.tar.gz "$ALARM_URL"
rm -rf "$R" && mkdir -p "$R"
bsdtar -xpf /cache/dl/alarm.tar.gz -C "$R"

# European mirrors first, the geo-IP balancer last. The balancer alone sent this build (Switzerland) to
# a US mirror that stalled mid-transaction ("Operation too slow") and failed the whole build; pacman
# falls through the Server list per file, so several entries make one slow mirror survivable.
cat > "$R/etc/pacman.d/mirrorlist" <<'EOF'
Server = http://de3.mirror.archlinuxarm.org/$arch/$repo
Server = http://de.mirror.archlinuxarm.org/$arch/$repo
Server = http://de4.mirror.archlinuxarm.org/$arch/$repo
Server = http://fr.mirror.archlinuxarm.org/$arch/$repo
Server = http://dk.mirror.archlinuxarm.org/$arch/$repo
Server = http://hu.mirror.archlinuxarm.org/$arch/$repo
Server = http://mirror.archlinuxarm.org/$arch/$repo
EOF

# Inputs the chroot needs (layout build-inside.sh expects in /tmp/lotfix).
mkdir -p "$R/tmp/lotfix"
cp -r "$A/patches" "$A/native" "$R/tmp/lotfix/"
cp -r /in/powos "$R/tmp/lotfix/powos"
mkdir -p /cache/dl /cache/pkg
curl -fsSL -o /cache/dl/mesa.tar -z /cache/dl/mesa.tar "$MESA_URL" && cp /cache/dl/mesa.tar "$R/tmp/lotfix/mesa.tar"
curl -fsSL -o /cache/dl/fakeroot.tar.gz -z /cache/dl/fakeroot.tar.gz "$FAKEROOT_URL" && cp /cache/dl/fakeroot.tar.gz "$R/tmp/lotfix/fakeroot.tar.gz"
# Cached under the commit's name: immutable, fetched once per pin (a fixed name kept serving the old pin).
[ -s /cache/dl/mesa-src-$MESA_SRC_COMMIT.tar.gz ] || curl -fsSL -o /cache/dl/mesa-src-$MESA_SRC_COMMIT.tar.gz "$MESA_SRC_URL"
cp /cache/dl/mesa-src-$MESA_SRC_COMMIT.tar.gz "$R/tmp/lotfix/mesa-src.tar.gz"
cp "$A/build/build-inside.sh" "$R/tmp/lotfix/build-inside.sh"

# pacman's package cache lives on the persistent cache volume (/cache/pkg), so rebuilds reuse the
# ~2-3 GB of packages instead of re-downloading them from flaky mirrors. Unmounted (first) before
# the image's own cache is emptied below, so packing never wipes it.
cleanup() { for m in var/cache/pacman/pkg dev/pts dev proc sys; do umount -l "$R/$m" 2>/dev/null || true; done; }
trap 'rc=$?; cleanup; exit $rc' EXIT
mkdir -p "$R/var/cache/pacman/pkg" && mount --bind /cache/pkg "$R/var/cache/pacman/pkg"
mount -t proc proc "$R/proc"
mount --rbind /sys "$R/sys" && mount --make-rslave "$R/sys"
mount --rbind /dev "$R/dev" && mount --make-rslave "$R/dev"
rm -f "$R/etc/resolv.conf" && cp -L /etc/resolv.conf "$R/etc/resolv.conf"

chroot "$R" /bin/bash /tmp/lotfix/build-inside.sh

# Host-side fixups, then pack. Hard links become plain files: Android's SELinux forbids creating them.
bash "$A/native/relativize-symlinks.sh" "$R" 2>/dev/null || true
cleanup; trap - EXIT
rm -rf "$R/tmp/lotfix" "$R/var/cache/pacman/pkg/"* "$R/etc/resolv.conf"
# /out is $POWOS_IMAGES on the NAS (build-rootfs.sh, tools/data-root.sh). Written beside and renamed over: the image
# may be hard-linked as the published copy, and writing it in place would change that one mid-build.
tar --numeric-owner --hard-dereference -C "$R" -I 'gzip -6' -cf /out/.powos-rootfs.tar.gz.new .
(cd /out && sha256sum .powos-rootfs.tar.gz.new | sed 's/\.powos-rootfs\.tar\.gz\.new$/powos-rootfs.tar.gz/' > .powos-rootfs.tar.gz.sha256.new &&
  mv -f .powos-rootfs.tar.gz.new powos-rootfs.tar.gz && mv -f .powos-rootfs.tar.gz.sha256.new powos-rootfs.tar.gz.sha256 &&
  cat powos-rootfs.tar.gz.sha256)
