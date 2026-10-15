#!/usr/bin/env python3
"""Deletes chunks nothing references any more (old disk builds, deleted snapshots).

    gc-chunks.py DISKDIR [--delete]      (default: dry run - prints what would go)

Referenced = in DISKDIR/index.bin, or in any DISKDIR/snapshots/<id>/ {disk.index, state.index} (16-byte hashes per
block) or overlay.bin (records: u64 block index + 16-byte hash). Chunks are content-addressed and shared, so only
unreferenced ones are safe to remove - run it after a publish, not during a build that is writing chunks."""
import os, sys

disk = sys.argv[1]
delete = '--delete' in sys.argv
HB = 16
keep = set()


def add_index(path):
    raw = open(path, 'rb').read()
    for i in range(0, len(raw), HB):
        keep.add(raw[i:i + HB].hex())


add_index(os.path.join(disk, 'index.bin'))
snaps = os.path.join(disk, 'snapshots')
for sid in os.listdir(snaps) if os.path.isdir(snaps) else []:
    d = os.path.join(snaps, sid)
    for f in ('disk.index', 'state.index'):
        if os.path.exists(os.path.join(d, f)):
            add_index(os.path.join(d, f))
    ov = os.path.join(d, 'overlay.bin')
    if os.path.exists(ov):
        raw = open(ov, 'rb').read()
        for i in range(0, len(raw) - len(raw) % (8 + HB), 8 + HB):
            keep.add(raw[i + 8:i + 8 + HB].hex())
keep.discard('00' * HB)

gone = n = size = 0
for sub in os.scandir(os.path.join(disk, 'chunks')):
    for e in os.scandir(sub.path):
        n += 1
        if e.name.split('.')[0] not in keep:
            gone += 1
            size += e.stat().st_size
            if delete:
                os.unlink(e.path)
print(f"gc-chunks: {n} chunks, {len(keep)} referenced, {gone} unreferenced ({size / 1e9:.2f} GB)"
      + (" deleted" if delete else " - dry run, --delete to remove"))
