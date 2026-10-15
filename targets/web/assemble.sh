#!/bin/bash
# Assembles the site served by compose.yaml: out/site/
#   qemu-system-aarch64.{js,wasm,worker.js}   (build-qemu.sh)
#   load-{kernel,initramfs}.{js,data}        PowOS's kernel + initramfs (build-rootfs.sh), packed by Emscripten's
#                                            file_packager: preloaded, boot needs them whole
#   index.html args.js                       (web/)
# The disk (out/disk, build-rootfs.sh) is served next to it at /disk, streamed, never packed.
#
# Usage: targets/web/assemble.sh
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SITE=$HERE/out/site
mkdir -p "$SITE"
cp "$HERE"/out/qemu/qemu-system-aarch64.js "$HERE"/out/qemu/qemu-system-aarch64.wasm \
  "$HERE"/out/qemu/qemu-system-aarch64.worker.js "$SITE/"
cp "$HERE"/web/* "$SITE/"
rm -f "$SITE/load-state.data" "$SITE/load-state.data.gz" "$SITE/load-state.js" "$SITE/snapshot.json"   # only a current snapshot is offered
# The snapshot to publish: the newest COMPLETE one (build-snapshot.sh makes a new out/disk/snapshots/<id>/ per run,
# so a build in progress or a failed one is never picked, and never disturbs the one being served).
D=$HERE/out/disk
mkdir -p "$D/snapshots"
if [ -f "$D/snapshot/vm.state" ]; then   # the old single-directory layout: adopt it as a dated snapshot
  mv "$D/snapshot" "$D/snapshots/$(date -r "$D/snapshot/vm.state" +%Y%m%d-%H%M%S)"
fi
SNAP=$(ls -d "$D"/snapshots/*/ 2>/dev/null | sort | while read -r d; do [ -f "$d/vm.state" ] && [ -f "$d/overlay.bin" ] && basename "$d"; done | tail -1 || true)
# Older complete snapshots beyond the newest three go (their overlay chunks stay: chunks are shared, by content).
ls -d "$D"/snapshots/*/ 2>/dev/null | sort | while read -r d; do [ -f "$d/vm.state" ] && echo "$d"; done | awk '{a[NR] = $0} END {for (i = 1; i <= NR - 3; i++) print a[i]}' | xargs rm -rf || true
docker run --rm -v "$HERE/out:/out" -e SNAP="$SNAP" powos-web-qemu-build bash -c '
  set -euo pipefail
  rm -rf /tmp/pack && mkdir -p /tmp/pack/pack-kernel /tmp/pack/pack-initramfs
  cp /out/disk/Image.gz /tmp/pack/pack-kernel/
  cp /out/disk/initramfs.img /tmp/pack/pack-initramfs/
  # Test initramfses, when built (?boot=<name>, args.js): test/tcg-check, test/probe.
  for t in tcg-check probe; do
    [ -f /out/$t/initramfs.img ] || continue
    mkdir -p /tmp/pack/pack-$t && cp /out/$t/initramfs.img /tmp/pack/pack-$t/
    python3 /emsdk/upstream/emscripten/tools/file_packager.py /out/site/load-$t.data \
      --preload /tmp/pack/pack-$t@/pack-$t > /out/site/load-$t.js
  done
  # The snapshot to resume (build-snapshot.sh), when made.
  for f in kernel initramfs; do
    python3 /emsdk/upstream/emscripten/tools/file_packager.py /out/site/load-$f.data \
      --preload /tmp/pack/pack-$f@/pack-$f > /out/site/load-$f.js
  done'
# Precompressed once (nginx gzip_static serves file.gz): gzip -9 here instead of nginx compressing hundreds of MB
# per visitor at its fast level. The page's progress counts decompressed bytes, as the browser hands them over.
for f in "$SITE"/*.wasm "$SITE"/*.data; do
  [ -f "$f.gz" ] && [ "$f.gz" -nt "$f" ] || gzip -9 -k -f "$f"
done
# Which snapshot the packed state belongs to: the page reads its disk overlay from snapshots/<id>/ (args.js).
# The snapshot's machine state is streamed, not packed: chunked like the disk, into the same chunks/ (zero blocks never
# stored or fetched, unchanged chunks shared between snapshots), indexed per snapshot. QEMU reads it on demand
# (-incoming file:chunked:..., qemu/migration/chunked-state.c), so no copy of it sits in the wasm heap.
if [ -n "$SNAP" ]; then
  S=$D/snapshots/$SNAP
  [ -f "$S/state.index" ] || python3 "$HERE/tools/chunk-disk.py" "$S/vm.state" "$D" "$S/state.index" "$S/state.json" | tail -1
  printf '{"id": "%s"}\n' "$SNAP" > "$SITE/snapshot.json"
  echo "snapshot: $SNAP"
fi
# What the page downloads before QEMU starts, with real sizes: its progress bar (index.html).
python3 - "$SITE" <<'PY'
import json, os, sys
site = sys.argv[1]
names = ["qemu-system-aarch64.wasm", "qemu-system-aarch64.js", "qemu-system-aarch64.worker.js"] + \
        sorted(f for f in os.listdir(site) if f.startswith("load-") and f.endswith(".data"))
json.dump({n: os.path.getsize(os.path.join(site, n)) for n in names}, open(os.path.join(site, "files.json"), "w"), indent=1)
PY
ls -la "$SITE"
