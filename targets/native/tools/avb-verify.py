#!/usr/bin/env python3
"""Checks partition images against the hashes in an Android vbmeta image (AVB hash descriptors).

A vbmeta that is byte-identical to the phone's own (e.g. backup/<serial>/vbmeta_b.img) carries the OEM's hash of
every boot-chain image it covers (boot, init_boot, vendor_boot, dtbo, ...). An image whose digest matches is the
exact image the OEM built - so a stock image from a third-party mirror can be proven genuine before flashing it.

    avb-verify.py <vbmeta.img> <partition>=<image> ...
    e.g. avb-verify.py vbmeta.img init_boot=stock/init_boot.img boot=stock/boot.img
Exit status 1 when any image doesn't match (or its partition has no hash descriptor)."""
import hashlib, struct, sys


def descriptors(vbmeta):
    d = open(vbmeta, 'rb').read()
    if d[:4] != b'AVB0':
        sys.exit(f'{vbmeta}: not a vbmeta image')
    auth_size, = struct.unpack_from('>Q', d, 12)
    desc_off, desc_size = struct.unpack_from('>QQ', d, 96)
    p = 256 + auth_size + desc_off
    end = p + desc_size
    out = {}
    while p < end:
        tag, n = struct.unpack_from('>QQ', d, p)
        body = p + 16
        if tag == 2:  # hash descriptor
            image_size, = struct.unpack_from('>Q', d, body)
            algo = d[body + 8:body + 40].rstrip(b'\0').decode()
            name_len, salt_len, digest_len = struct.unpack_from('>III', d, body + 40)
            q = body + 116
            name = d[q:q + name_len].decode()
            salt = d[q + name_len:q + name_len + salt_len]
            digest = d[q + name_len + salt_len:q + name_len + salt_len + digest_len]
            out[name] = (image_size, algo, salt, digest)
        p = body + n
    return out


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    descs = descriptors(sys.argv[1])
    bad = 0
    for arg in sys.argv[2:]:
        part, path = arg.split('=', 1)
        if part not in descs:
            print(f'{part}: no hash descriptor in this vbmeta (have: {", ".join(sorted(descs))})')
            bad += 1
            continue
        size, algo, salt, want = descs[part]
        h = hashlib.new(algo)
        h.update(salt)
        with open(path, 'rb') as f:
            h.update(f.read(size))
        ok = h.digest() == want
        bad += not ok
        print(f'{part}: {"OK - matches the vbmeta hash" if ok else "MISMATCH"} ({algo}, {size} bytes of {path})')
    sys.exit(1 if bad else 0)


main()
