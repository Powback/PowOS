#!/usr/bin/env python3
"""Splits a disk image into what the browser streams on demand.

    chunk-disk.py DISK OUTDIR [INDEX MANIFEST]

OUTDIR/chunks/<hh>/<hash>   one 256 KiB block of the disk, zlib-compressed, named by the BLAKE2b-128 of its
                            uncompressed bytes: identical blocks are stored (and fetched, and cached) once, and a
                            chunk never changes, so the browser and HTTP caches keep it forever.
OUTDIR/index.bin            16 bytes per block, in disk order: the block's hash, or all zeros for a block of zeros
                            (never stored or fetched - most of a sparse disk).
OUTDIR/manifest.json        disk size, block size, and the stats.
INDEX MANIFEST              other paths for those two, e.g. a snapshot's state (OUTDIR/snapshots/<id>/state.index +
                            state.json, read by qemu/migration/chunked-state.c): its chunks join the same OUTDIR/chunks.

QEMU's chunked block driver (targets/web/qemu/block/chunked.c) reads index.bin once, then fetches a block the first time the guest reads it.
"""
import hashlib
import json
import os
import sys
from concurrent.futures import ProcessPoolExecutor

import zlib

BLOCK = 256 * 1024
ZERO = bytes(BLOCK)
HASH_BYTES = 16


def work(args):
    path, start, count, outdir = args
    out = []
    stored = 0
    with open(path, "rb") as f:
        f.seek(start * BLOCK)
        for _ in range(count):
            data = f.read(BLOCK)
            if not data:
                break
            data = data.ljust(BLOCK, b"\0")
            if data == ZERO:
                out.append(bytes(HASH_BYTES))
                continue
            h = hashlib.blake2b(data, digest_size=HASH_BYTES).digest()
            hx = h.hex()
            dest = os.path.join(outdir, "chunks", hx[:2], hx)
            if not os.path.exists(dest):
                tmp = dest + f".{os.getpid()}.tmp"
                with open(tmp, "wb") as o:
                    o.write(zlib.compress(data, 9))
                os.replace(tmp, dest)
                stored += 1
            out.append(h)
    return start, out, stored


def main():
    disk, outdir = sys.argv[1], sys.argv[2]
    index_path = sys.argv[3] if len(sys.argv) > 3 else os.path.join(outdir, "index.bin")
    manifest_path = sys.argv[4] if len(sys.argv) > 4 else os.path.join(outdir, "manifest.json")
    size = os.path.getsize(disk)
    blocks = (size + BLOCK - 1) // BLOCK
    for i in range(256):
        os.makedirs(os.path.join(outdir, "chunks", f"{i:02x}"), exist_ok=True)
    per = 1024
    jobs = [(disk, s, min(per, blocks - s), outdir) for s in range(0, blocks, per)]
    index = [None] * len(jobs)
    stored = 0
    with ProcessPoolExecutor() as pool:
        for n, (start, hashes, s) in enumerate(pool.map(work, jobs)):
            index[start // per] = b"".join(hashes)
            stored += s
            if n % 20 == 0:
                print(f"chunk-disk: {start * BLOCK / 1e9:.1f} / {size / 1e9:.1f} GB", flush=True)
    idx = b"".join(index)
    with open(index_path, "wb") as f:
        f.write(idx)
    zero = sum(1 for i in range(blocks) if idx[i * HASH_BYTES:(i + 1) * HASH_BYTES] == bytes(HASH_BYTES))
    chunk_bytes = sum(e.stat().st_size for d in os.scandir(os.path.join(outdir, "chunks")) for e in os.scandir(d))
    manifest = {
        "size": size,
        "blockSize": BLOCK,
        "hashBytes": HASH_BYTES,
        "blocks": blocks,
        "zeroBlocks": zero,
        "uniqueChunks": sum(1 for d in os.scandir(os.path.join(outdir, "chunks")) for _ in os.scandir(d)),
        "chunkBytes": chunk_bytes,
    }
    with open(manifest_path, "w") as f:
        json.dump(manifest, f, indent=1)
    print(f"chunk-disk: {blocks} blocks, {zero} zero, {manifest['uniqueChunks']} chunks, "
          f"{chunk_bytes / 1e9:.2f} GB compressed (newly stored this run: {stored})")


if __name__ == "__main__":
    main()
