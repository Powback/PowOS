#!/usr/bin/env python3
"""Rebuilds a raw disk image from the streamed disk (chunk-disk.py's chunks + index.bin), optionally with a
snapshot's overlay (qemu/block/chunked.c save-overlay: records of u64 LE block index + hash) applied on top.
For debugging the exact disk the browser sees with a fast native QEMU (HVF/KVM) - see test/debug-native.sh.

    unchunk-disk.py DISKDIR OUT.raw [OVERLAY.bin]
Sparse output: blocks of zeros are never written."""
import os, struct, sys, zlib

disk, out = sys.argv[1], sys.argv[2]
overlay = sys.argv[3] if len(sys.argv) > 3 else None
BLOCK, HB = 256 * 1024, 16
index = open(os.path.join(disk, "index.bin"), "rb").read()
hashes = [index[i:i + HB] for i in range(0, len(index), HB)]
if overlay:
    raw = open(overlay, "rb").read()
    rec = 8 + HB
    for i in range(0, len(raw) - len(raw) % rec, rec):
        (blk,) = struct.unpack_from("<Q", raw, i)
        hashes[blk] = raw[i + 8:i + rec]
zero = bytes(HB)
with open(out, "wb") as f:
    f.truncate(len(hashes) * BLOCK)
    for n, h in enumerate(hashes):
        if h == zero:
            continue
        hx = h.hex()
        f.seek(n * BLOCK)
        f.write(zlib.decompress(open(os.path.join(disk, "chunks", hx[:2], hx), "rb").read()))
print(f"{out}: {len(hashes)} blocks, {sum(h != zero for h in hashes)} written")
