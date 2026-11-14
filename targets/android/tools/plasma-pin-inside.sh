#!/bin/bash
# plasma-pin-inside.sh <outdir> - plasma-pin.sh's step inside the build-base rootfs: every installed package at KWin's
# Plasma version ($VER) except ours ($OURS, from out/pkgs) repackaged into <outdir> as the powos-plasma repo.
# Refuses (exit 1) a rootfs whose kscreenlocker isn't at $VER: that is not the rootfs KWin is built on, and the pin
# would come out empty - repo-add then failed on its own glob ("File '*.pkg.tar.*' not found", 11-14: the main
# checkout's out/powos-rootfs.tar.gz was an old full build with Plasma 6.8.1, not the 6.7.5 build base).
# PLASMA_PIN_DB (default /var/lib/pacman/local) and PLASMA_PIN_LIST=1 (print the pin, build nothing) are for tests.
set -euo pipefail
out=${1:?usage: plasma-pin-inside.sh <outdir>}
DB=${PLASMA_PIN_DB:-/var/lib/pacman/local}
: "${VER:?VER (kwin pkgver)}"
installed=$(for d in "$DB"/*/desc; do
  awk '/^%NAME%/{getline; n=$0} /^%VERSION%/{getline; v=$0} END{print n, v}' "$d"
done | awk '{v=$2; sub(/^[0-9]+:/, "", v); sub(/-[^-]*$/, "", v); print $1, v}')
sl=$(awk '$1 == "kscreenlocker" {print $2}' <<<"$installed")
[ "$sl" = "$VER" ] || {
  echo "plasma-pin: this rootfs has kscreenlocker ${sl:-(none)}, kwin is Plasma $VER: not the build base KWin links" >&2
  exit 1; }
pin=$(awk -v ver="$VER" -v ours=" ${OURS:-} " '$2 == ver && index(ours, " " $1 " ") == 0 {print $1}' <<<"$installed")
[ -n "$pin" ] || { echo "plasma-pin: no package at Plasma $VER to pin" >&2; exit 1; }
if [ "${PLASMA_PIN_LIST:-0}" = 1 ]; then echo "$pin"; exit 0; fi
cd "$out"
python3 -I /tools/repack-installed.py "$out" $pin >/dev/null
repo-add -q powos-plasma.db.tar.gz *.pkg.tar.*
echo "$pin" | tr "\n" " " > pinned.txt
