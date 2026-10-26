#!/bin/bash
# Run on the target host. Only writes the build cache and uses a rootless builder.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REV=af28cbbfd3d922a659227ecfb7369adfd924cf03
CACHE=${GPU_UNLOCK_CACHE:-$HOME/.cache/powos-gpu-unlock}
KVER=$(uname -r)
[[ $(uname -m) == x86_64 && -d /usr/src/kernels/$KVER ]] || {
    echo 'Build on the x86_64 target with its matching kernel-devel installed.' >&2; exit 1;
}
mkdir -p "$CACHE"
if [[ ! -d "$CACHE/upstream/.git" ]]; then
    git clone https://github.com/Zagitta/gpu-unlock.git "$CACHE/upstream"
fi
git -C "$CACHE/upstream" cat-file -e "$REV^{commit}" || git -C "$CACHE/upstream" fetch origin "$REV"
SRC="$CACHE/build-$REV-$KVER"
mkdir -p "$SRC"
git -C "$CACHE/upstream" archive "$REV" | tar -xf - -C "$SRC"
make -C "$SRC/kernel/gpu_unlock" KDIR="/usr/src/kernels/$KVER" -j4
test "$(modinfo -F vermagic "$SRC/kernel/gpu_unlock/gpu_unlock.ko" | cut -d' ' -f1)" = "$KVER"
make -C "$SRC" assets INPUTS="$CACHE/inputs" ASSETS="$CACHE/assets"
make -C "$SRC" test ASSETS="$CACHE/assets"
PAYLOAD="$CACHE/payload-$KVER"
mkdir -p "$PAYLOAD/usr/lib/modules/$KVER/extra"
install -m644 "$SRC/kernel/gpu_unlock/gpu_unlock.ko" "$PAYLOAD/usr/lib/modules/$KVER/extra/"
make -C "$SRC" DESTDIR="$PAYLOAD" ASSETS="$CACHE/assets" install-firmware install-dracut install-licenses
mkdir -p "$PAYLOAD/usr/share/powos/gpu-unlock"
printf '%s\n' "$REV" > "$PAYLOAD/usr/share/powos/gpu-unlock/upstream-revision"
printf '%s\n' "$KVER" > "$PAYLOAD/usr/share/powos/gpu-unlock/kernel"
install -Dm755 "$HERE/control.py" "$PAYLOAD/usr/bin/powos-gpu-unlock"
install -Dm644 "$HERE/../../../units/gpu-195/gpu-unlock.json" "$PAYLOAD/etc/powos/units.d/gpu-unlock.json"
mkdir -p "$CACHE/rpmbuild/SOURCES" "$CACHE/rpmbuild/SPECS"
tar -czf "$CACHE/rpmbuild/SOURCES/payload.tar.gz" -C "$PAYLOAD" usr etc
cp "$HERE/gpu-unlock.spec" "$CACHE/rpmbuild/SPECS/"
podman build -t localhost/powos-gpu-unlock-builder:1 "$HERE"
podman run --rm --userns=keep-id --security-opt label=disable \
    -v "$CACHE/rpmbuild:/build" localhost/powos-gpu-unlock-builder:1 \
    rpmbuild -bb --define '_topdir /build' --define "kver $KVER" /build/SPECS/gpu-unlock.spec
find "$CACHE/rpmbuild/RPMS" -name '*.rpm' -exec sha256sum {} \;
echo 'Built only. No packages installed, no boot settings changed, no reboot.'
