#!/bin/bash
# Run on the target host. Only writes the build cache and uses a rootless builder.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
PROFILE=${1:-ampere}
read -r REPOSITORY REV VERSION RELEASE TEST_TARGET < <(python3 - "$HERE/profiles.json" "$PROFILE" <<'PY'
import json, sys
profiles = json.load(open(sys.argv[1]))
if sys.argv[2] not in profiles:
    sys.exit('Profile must be ampere or ada; Blackwell/5090 is not supported.')
p = profiles[sys.argv[2]]
print(p['repository'], p['revision'], p['version'], p['release'], p['test_target'])
PY
)
CACHE=${GPU_UNLOCK_CACHE:-$HOME/.cache/powos-gpu-unlock}
WORK="$CACHE/$PROFILE"
KVER=$(uname -r)
[[ $(uname -m) == x86_64 && -d /usr/src/kernels/$KVER ]] || {
    echo 'Build on the x86_64 target with its matching kernel-devel installed.' >&2; exit 1;
}
mkdir -p "$WORK"
if [[ ! -d "$WORK/upstream/.git" ]]; then
    git clone "$REPOSITORY" "$WORK/upstream"
fi
git -C "$WORK/upstream" cat-file -e "$REV^{commit}" || git -C "$WORK/upstream" fetch "$REPOSITORY" "$REV"
SRC="$WORK/build-$REV-$KVER"
mkdir -p "$SRC"
git -C "$WORK/upstream" archive "$REV" | tar -xf - -C "$SRC"
test "$(cat "$SRC/VERSION")" = "$VERSION"
make -C "$SRC/kernel/gpu_unlock" KDIR="/usr/src/kernels/$KVER" -j4
test "$(modinfo -F vermagic "$SRC/kernel/gpu_unlock/gpu_unlock.ko" | cut -d' ' -f1)" = "$KVER"
make -C "$SRC" assets INPUTS="$CACHE/inputs" ASSETS="$WORK/assets-$REV"
make -C "$SRC" "$TEST_TARGET" ASSETS="$WORK/assets-$REV"
# A fresh payload prevents a different profile's firmware/module leaking into the RPM.
PAYLOAD=$(mktemp -d "$WORK/payload-$KVER.XXXXXX")
trap 'rm -rf "$PAYLOAD"' EXIT
mkdir -p "$PAYLOAD/usr/lib/modules/$KVER/extra"
install -m644 "$SRC/kernel/gpu_unlock/gpu_unlock.ko" "$PAYLOAD/usr/lib/modules/$KVER/extra/"
make -C "$SRC" DESTDIR="$PAYLOAD" ASSETS="$WORK/assets-$REV" install-firmware install-dracut install-licenses
mkdir -p "$PAYLOAD/usr/share/powos/gpu-unlock"
printf '%s\n' "$REV" > "$PAYLOAD/usr/share/powos/gpu-unlock/upstream-revision"
printf '%s\n' "$KVER" > "$PAYLOAD/usr/share/powos/gpu-unlock/kernel"
printf '%s\n' "$PROFILE" > "$PAYLOAD/usr/share/powos/gpu-unlock/profile"
install -m644 "$HERE/profiles.json" "$PAYLOAD/usr/share/powos/gpu-unlock/profiles.json"
install -Dm755 "$HERE/control.py" "$PAYLOAD/usr/bin/powos-gpu-unlock"
install -Dm644 "$HERE/../../../units/gpu-195/gpu-unlock.json" "$PAYLOAD/etc/powos/units.d/gpu-unlock.json"
mkdir -p "$WORK/rpmbuild/SOURCES" "$WORK/rpmbuild/SPECS"
tar -czf "$WORK/rpmbuild/SOURCES/payload.tar.gz" -C "$PAYLOAD" usr etc
cp "$HERE/gpu-unlock.spec" "$WORK/rpmbuild/SPECS/"
podman build -t localhost/powos-gpu-unlock-builder:1 "$HERE"
podman run --rm --userns=keep-id --security-opt label=disable \
    -v "$WORK/rpmbuild:/build" localhost/powos-gpu-unlock-builder:1 \
    rpmbuild -bb --define '_topdir /build' --define "kver $KVER" \
    --define "unlock_version $VERSION" --define "unlock_release $RELEASE" \
    --define "unlock_revision $REV" --define "unlock_profile $PROFILE" \
    --define "unlock_repository $REPOSITORY" /build/SPECS/gpu-unlock.spec
sha256sum "$WORK/rpmbuild/RPMS/x86_64/powos-gpu-unlock-$VERSION-$RELEASE.x86_64.rpm"
echo 'Built only. No packages installed, no boot settings changed, no reboot.'
