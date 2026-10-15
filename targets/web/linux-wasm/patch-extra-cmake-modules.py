#!/usr/bin/env python3
"""PowOS patch over extra-cmake-modules for Linux/Wasm (idempotent; build-kde.sh applies it).

KDECompilerSettings adds -Wl,--enable-new-dtags (an ELF DT_RUNPATH flag) on every Unix; wasm-ld has no such option
("unknown argument: --enable-new-dtags") and Wasm programs here are static, with no runpath at all.

    patch-extra-cmake-modules.py <ecm source dir>"""
import os, sys

p = os.path.join(sys.argv[1], 'kde-modules/KDECompilerSettings.cmake')
s = open(p).read()
old = 'if (UNIX AND NOT APPLE AND NOT CYGWIN)\n    # Enable adding DT_RUNPATH'
if 'PowOS' not in s:
    assert old in s, 'KDECompilerSettings.cmake changed upstream: re-check patch-extra-cmake-modules.py'
    s = s.replace(old, '# PowOS: not for Wasm (static, no ELF runpath; patch-extra-cmake-modules.py)\n'
                  'if (UNIX AND NOT APPLE AND NOT CYGWIN AND NOT CMAKE_SYSTEM_PROCESSOR STREQUAL "wasm32")\n'
                  '    # Enable adding DT_RUNPATH', 1)
    open(p, 'w').write(s)
print('ecm: no --enable-new-dtags on wasm32')
