#!/usr/bin/env python3
"""PowOS patch over kcoreaddons for Linux/Wasm (idempotent; build-kde.sh applies it).

kcoreaddons REQUIREs libmount (util-linux) on Linux, but the code only uses it behind HAVE_LIB_MOUNT (filesystem
type detection, KFileSystemType). In the browser the filesystems are the streamed EROFS disk, tmpfs and procfs - not
worth porting util-linux for - so it is optional here and that code falls back to statfs.

    patch-kcoreaddons.py <kcoreaddons source dir>"""
import os, sys

p = os.path.join(sys.argv[1], 'CMakeLists.txt')
s = open(p).read()
old = '    find_package(LibMount REQUIRED)\n'
if 'PowOS' not in s:
    assert old in s, 'kcoreaddons CMakeLists.txt changed upstream: re-check patch-kcoreaddons.py'
    s = s.replace(old, '    find_package(LibMount) # PowOS: optional (patch-kcoreaddons.py)\n', 1)
    open(p, 'w').write(s)
print('kcoreaddons: libmount optional')
