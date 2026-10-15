#!/usr/bin/env python3
"""PowOS patch over dbus for Linux/Wasm (idempotent; build-deps.sh applies it): a static libdbus-1.

dbus's CMake build hard-codes the client library as SHARED (and BUILD_SHARED_LIBS ON at the top), and on Linux adds
a GNU ld version script; a Wasm program here links everything statically and wasm-ld has no version scripts
("unknown argument: --version-script"). The daemon and tools already use a static internal library.

    patch-dbus.py <dbus source dir>"""
import os, sys

src = sys.argv[1]
p = os.path.join(src, 'dbus/CMakeLists.txt')
s = open(p).read()
if 'PowOS: static' not in s:
    old_lib = 'add_library(dbus-1 SHARED\n'
    old_vs = 'if("${CMAKE_SYSTEM_NAME}" STREQUAL "Linux")\n    set(SOVERSION ${DBUS_LIBRARY_MAJOR})'
    assert old_lib in s and old_vs in s, 'dbus/CMakeLists.txt changed upstream: re-check patch-dbus.py'
    s = s.replace(old_lib, '# PowOS: static (patch-dbus.py)\nadd_library(dbus-1 STATIC\n', 1)
    s = s.replace(old_vs, 'if("${CMAKE_SYSTEM_NAME}" STREQUAL "Linux" AND NOT CMAKE_SYSTEM_PROCESSOR STREQUAL "wasm32")\n'
                  '    set(SOVERSION ${DBUS_LIBRARY_MAJOR})', 1)
    open(p, 'w').write(s)

p = os.path.join(src, 'CMakeLists.txt')
s = open(p).read()
old = 'set(BUILD_SHARED_LIBS ON)\n'
if old in s:
    s = s.replace(old, 'set(BUILD_SHARED_LIBS OFF) # PowOS: static (patch-dbus.py)\n', 1)
    open(p, 'w').write(s)
print('dbus: static libdbus-1')
