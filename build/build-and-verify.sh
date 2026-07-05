#!/bin/bash
# build/build-and-verify.sh — local dev build + tier-2 QEMU boot verification.
#
# Builds a PowOS image (live or the lean installer variant), runs
# bootc-image-builder to a raw disk image, optionally delivers it, then boots it
# under QEMU via test/qemu/boot-verify.sh to confirm it actually boots to the
# expected state. This is the "build it AND prove it boots before trusting it on
# hardware" loop — the manual gate the boot-loop incident taught us to keep
# (CI has no KVM; see CLAUDE.md "boot-path" note).
#
# Designed to run on a nested-podman host — e.g. a privileged container with
# /dev/kvm (Docker Desktop / WSL2) or a KVM Linux box. It forces podman's NATIVE
# kernel overlay (fuse-overlayfs is catastrophically slow for these builds); put
# podman storage on a native-fs volume when running nested.
#
# Usage:
#   build/build-and-verify.sh [--installer] [--deliver DIR] [--no-verify]
#                             [--tag NAME] [--vga std|virtio]
#
#   --installer   Build the LEAN INSTALLER variant (POWOS_INSTALLER=1): no
#                 ramboot, boots straight to the wizard. Default: live image.
#   --deliver DIR Copy the resulting raw (sparse) into DIR after building.
#   --no-verify   Build + deliver only; skip the QEMU boot check.
#   --tag NAME    Image tag (default localhost/powos[-installer]:latest).
#   --vga MODE    QEMU VGA for verify (std for text/installer, virtio for KDE).
set -uo pipefail
STAGE() { echo; echo "==================== $* ===================="; }

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VARIANT="live" ; DELIVER="" ; VERIFY=1 ; TAG="" ; VGA=""
while [ $# -gt 0 ]; do
    case "$1" in
        --installer) VARIANT="installer"; shift ;;
        --deliver)   DELIVER="$2"; shift 2 ;;
        --no-verify) VERIFY=0; shift ;;
        --tag)       TAG="$2"; shift 2 ;;
        --vga)       VGA="$2"; shift 2 ;;
        -h|--help)   grep '^#' "$0" | cut -c3-; exit 0 ;;
        *) echo "build-and-verify: unknown option: $1" >&2; exit 2 ;;
    esac
done

if [ "$VARIANT" = "installer" ]; then
    BUILD_ARGS=(--build-arg POWOS_INSTALLER=1)
    TAG="${TAG:-localhost/powos-installer:latest}"
    RAW_OUT="powos-installer.raw"
    VGA="${VGA:-std}"
    # Installer must reach multi-user + the wizard, and must NOT engage ramboot.
    V_EXPECT="Reached target multi-user|powos-install-wizard|powos.install"
    V_FORBID="Kernel panic|Failed to mount /sysroot|ramboot-setup|rd.powos.ramboot=1 .*overlay"
else
    BUILD_ARGS=()
    TAG="${TAG:-localhost/powos:latest}"
    RAW_OUT="powos.raw"
    VGA="${VGA:-virtio}"
    V_EXPECT="Reached target graphical|plasmalogin|Started .*Login"
    V_FORBID="Kernel panic|Failed to mount /sysroot|emergency mode"
fi

STAGE "Force native kernel overlay (fuse-overlayfs is too slow for image builds)"
mkdir -p /etc/containers
cat > /etc/containers/storage.conf <<EOF
[storage]
driver = "overlay"
graphroot = "/var/lib/containers/storage"
runroot = "/run/containers/storage"
[storage.options.overlay]
mountopt = "nodev,metacopy=on"
EOF

STAGE "Build image ($VARIANT → $TAG)"
cd "$REPO"
git config --global --add safe.directory "$REPO" 2>/dev/null || true
echo "HEAD: $(git log --oneline -1 2>/dev/null)"
[ -f build/vendor-bazzite.sh ] && { bash build/vendor-bazzite.sh 2>&1 | tail -2 || echo "(vendor warn)"; }
podman build "${BUILD_ARGS[@]}" -f Containerfile -t "$TAG" . || { echo "FATAL: build"; exit 2; }

STAGE "bootc-image-builder → raw"
mkdir -p "$REPO/build/output"
podman run --rm --privileged -v "$REPO/build/output:/output" \
    -v /var/lib/containers/storage:/var/lib/containers/storage \
    quay.io/centos-bootc/bootc-image-builder:latest \
    --type raw --rootfs btrfs --local "$TAG" || { echo "FATAL: bib"; exit 3; }
RAW="$(find "$REPO/build/output" -name '*.raw' | head -1)"
[ -f "$RAW" ] || { echo "FATAL: no raw produced"; exit 4; }
echo "raw: $RAW ($(du -h "$RAW" | cut -f1))"

if [ -n "$DELIVER" ]; then
    STAGE "Deliver → $DELIVER/$RAW_OUT"
    mkdir -p "$DELIVER"
    cp --sparse=always "$RAW" "$DELIVER/$RAW_OUT"; sync
    sha256sum "$DELIVER/$RAW_OUT" | tee "$DELIVER/$RAW_OUT.sha256"
fi

if [ "$VERIFY" -eq 1 ]; then
    STAGE "QEMU boot verify ($VARIANT)"
    bash "$REPO/test/qemu/boot-verify.sh" --raw "$RAW" --vga "$VGA" \
        --expect "$V_EXPECT" --forbid "$V_FORBID" --timeout 360 \
        --shots "$REPO/build/output/boot-shots" \
        --serial "$REPO/build/output/boot-serial.log"
    RC=$?
    STAGE "RESULT"
    [ $RC -eq 0 ] && echo "PASS — $VARIANT image boots to the expected state." \
                  || echo "FAIL — see build/output/boot-serial.log + boot-shots/."
    exit $RC
fi
echo "Built (verify skipped)."
