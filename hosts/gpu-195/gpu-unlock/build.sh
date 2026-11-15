#!/bin/bash
# Build on x86_64 with prepared target headers. No deployment or kernel transition.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
PROFILE=ampere
if [[ $# -gt 0 && $1 != --* ]]; then PROFILE=$1; shift; fi
KVER=
KDIR=
while [[ $# -gt 0 ]]; do
    case "$1" in
        --kernel|--kdir)
            [[ $# -ge 2 && -n $2 && $2 != --* ]] || { echo "Missing value for $1" >&2; exit 1; }
            if [[ $1 == --kernel ]]; then KVER=$2; else KDIR=$2; fi
            shift 2 ;;
        *) echo "Usage: $0 [ampere|ada] [--kernel RELEASE] [--kdir HEADER_TREE]" >&2; exit 1 ;;
    esac
done
KVER=${KVER:-$(uname -r)}
# The release is used in paths and RPM macros; reject traversal and macro syntax.
[[ $KVER =~ ^[a-zA-Z0-9][a-zA-Z0-9._+-]*$ ]] || { echo 'Invalid kernel release.' >&2; exit 1; }
KDIR=${KDIR:-/usr/src/kernels/$KVER}
[[ $KDIR == /* ]] || KDIR="$PWD/$KDIR"
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
WORK="$CACHE/$PROFILE/kernels/$KVER"
[[ $(uname -m) == x86_64 && -d "$KDIR" ]] || {
    echo 'Build on x86_64 with the selected kernel-devel tree already installed.' >&2; exit 1;
}
# Check before fetching sources, generating assets or compiling anything.
HEADER_KVER=$(make -s --no-print-directory -C "$KDIR" kernelrelease)
[[ $HEADER_KVER == "$KVER" ]] || {
    printf 'Header kernelrelease mismatch: selected %s, headers report %s\n' "$KVER" "$HEADER_KVER" >&2
    exit 1
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
make -C "$SRC/kernel/gpu_unlock" KDIR="$KDIR" -j4
test "$(modinfo -F vermagic "$SRC/kernel/gpu_unlock/gpu_unlock.ko" | cut -d' ' -f1)" = "$KVER"
make -C "$SRC" assets INPUTS="$CACHE/inputs" ASSETS="$WORK/assets-$REV"
make -C "$SRC" "$TEST_TARGET" ASSETS="$WORK/assets-$REV"
# A fresh payload prevents a different profile's firmware/module leaking into the RPM.
PAYLOAD=$(mktemp -d "$WORK/payload-$KVER.XXXXXX")
trap 'rm -rf "$PAYLOAD"' EXIT
mkdir -p "$PAYLOAD/usr/lib/modules/$KVER/extra"
install -m644 "$SRC/kernel/gpu_unlock/gpu_unlock.ko" "$PAYLOAD/usr/lib/modules/$KVER/extra/"
make -C "$SRC" DESTDIR="$PAYLOAD" ASSETS="$WORK/assets-$REV" install-firmware install-dracut install-licenses
# Bazzite force-loads NVIDIA too: append would run the unlock after it binds.
cat > "$PAYLOAD/usr/lib/dracut/dracut.conf.d/gpu-unlock.conf" <<'EOF'
force_drivers=" gpu_unlock ${force_drivers:-} "
EOF
mkdir -p "$PAYLOAD/usr/lib/modprobe.d"
echo 'softdep nvidia pre: gpu_unlock' > "$PAYLOAD/usr/lib/modprobe.d/gpu-unlock.conf"
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
