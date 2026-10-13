#!/bin/bash
# Read the published PowOS image, the single source of truth for what the phone gets: no hand-kept lists.
# The image is x86_64 and ~20 GB unpacked, so it is never pulled into Docker (the disk is shared with live
# services): its layers are streamed with crane and only the requested paths are kept.
#
# Usage: tools/powos-image.sh digest  [ref]           print the pinned digest (default ref: ghcr.io/powback/powos:deck)
#        tools/powos-image.sh extract <ref@digest> <outdir> <tar-path-pattern...>
#        tools/powos-image.sh packages <outdir>        list NAME ARCH of every RPM in an extracted rpm database
set -euo pipefail
CRANE=gcr.io/go-containerregistry/crane:debug
cmd=${1:?usage}; shift
case $cmd in
  digest)
    ref=${1:-ghcr.io/powback/powos:deck}
    d=$(docker run --rm "$CRANE" digest "$ref")
    echo "${ref%%:*}@$d" ;;
  extract)
    ref=$1 out=$2; shift 2
    mkdir -p "$out"
    # crane export flattens the image (whiteouts applied) to a tar stream; GNU tar (crane's image only has
    # busybox tar, without --wildcards) keeps only the patterns.
    docker run --rm "$CRANE" export "$ref" - \
      | docker run --rm -i --platform linux/arm64 -v "$out:/out" menci/archlinuxarm:latest \
          tar -x -C /out --wildcards --no-same-owner "$@" ;;
  packages)
    out=$1
    db=$(cd "$out" && ls -d usr/lib/sysimage/rpm usr/share/rpm 2>/dev/null | head -1)
    [ -n "$db" ] || { echo "no rpm database under $out" >&2; exit 1; }
    docker run --rm --platform linux/arm64 -v "$out:/img:ro" menci/archlinuxarm:latest bash -c "
      sed -i '/^\[options\]/a DisableSandbox' /etc/pacman.conf
      pacman -Sy --noconfirm --needed rpm-tools >/dev/null 2>&1
      rpm --dbpath /img/$db -qa --qf '%{NAME} %{ARCH}\n' | sort -u" ;;
  *) echo "unknown command $cmd" >&2; exit 1 ;;
esac
