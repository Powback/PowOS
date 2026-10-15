#!/usr/bin/env python3
"""Will the phone's own kernel modules load on our kernel? Compares the symbol CRCs our kernel exports
(out/gki/Module.symvers, build-gki-kernel.sh) with the CRCs every module expects (its __versions section).

With MODVERSIONS the kernel refuses a module whose expected CRC for a symbol differs from the kernel's ("disagrees
about version of symbol") - so a mismatch here means that driver (display, GPU, touch, Wi-Fi...) would not load.
Symbols a module expects that the kernel doesn't export at all are fine if another module provides them; those are
listed separately.

    kmi-check.py out/gki/Module.symvers <dir with .ko files>...   (e.g. backup/<serial>/vendor_dlkm extracted)
Exit status 1 when any CRC disagrees."""
import os, struct, sys


def symvers(path):
    crcs = {}
    for line in open(path):
        f = line.rstrip('\n').split('\t')
        if len(f) >= 2:
            crcs[f[1]] = int(f[0], 16)
    return crcs


def versions(ko):
    """(crc, name) pairs from an ELF64 little-endian module's __versions section (u64 crc + 56-byte name)."""
    d = open(ko, 'rb').read()
    if d[:4] != b'\x7fELF' or d[4] != 2 or d[5] != 1:
        return []
    shoff, = struct.unpack_from('<Q', d, 0x28)
    shentsize, shnum, shstrndx = struct.unpack_from('<HHH', d, 0x3a)
    sh = [struct.unpack_from('<IIQQQQIIQQ', d, shoff + i * shentsize) for i in range(shnum)]
    strtab = sh[shstrndx]
    out = []
    for s in sh:
        name = d[strtab[4] + s[0]:].split(b'\0', 1)[0]
        if name == b'__versions':
            off, size = s[4], s[5]
            for i in range(off, off + size, 64):
                crc, = struct.unpack_from('<Q', d, i)
                out.append((crc, d[i + 8:i + 64].split(b'\0', 1)[0].decode()))
    return out


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    kernel = symvers(sys.argv[1])
    bad, missing, checked = {}, set(), 0
    for root in sys.argv[2:]:
        for dirpath, _, files in os.walk(root):
            for f in files:
                if not f.endswith('.ko'):
                    continue
                checked += 1
                for crc, sym in versions(os.path.join(dirpath, f)):
                    if sym not in kernel:
                        missing.add(sym)
                    elif kernel[sym] != crc & 0xffffffff:
                        bad.setdefault(f, []).append(sym)
    print(f'{checked} modules checked against {len(kernel)} kernel symbols')
    for mod, syms in sorted(bad.items()):
        print(f'MISMATCH {mod}: {", ".join(sorted(syms)[:8])}{" ..." if len(syms) > 8 else ""}')
    print(f'{len(missing)} expected symbols not exported by the kernel (fine if another module provides them)')
    print('OK - the modules accept this kernel' if not bad else f'FAIL - {len(bad)} modules would refuse to load')
    sys.exit(1 if bad else 0)


main()
