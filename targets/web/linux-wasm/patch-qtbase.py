#!/usr/bin/env python3
"""PowOS patch over qtbase for Linux/Wasm (idempotent; build-qt.sh applies it).

QProcess: Qt starts child processes with fork() on musl - it avoids vfork() there because musl's sigaction() locks a
mutex for SIGABRT, which a vfork child could deadlock on. A NOMMU kernel has no fork() at all: the only way to start a
process is vfork semantics (clone(CLONE_VM | CLONE_VFORK), which forkfd's system_vforkfd uses). KDE runs processes
through QProcess everywhere, so on Wasm use vfork.

    patch-qtbase.py <qtbase source dir>"""
import os, sys

p = os.path.join(sys.argv[1], 'src/corelib/io/qprocess_unix.cpp')
s = open(p).read()
old = 'inline bool globalUsingVfork() noexcept\n{\n'
if 'PowOS' not in s:
    assert old in s, 'qprocess_unix.cpp changed upstream: re-check patch-qtbase.py'
    s = s.replace(old, old + '''#if defined(__wasm__)
    // PowOS: NOMMU has no fork() - vfork semantics are the only way to start a process (patch-qtbase.py).
    // HACK: musl's sigaction() can still lock a mutex for SIGABRT in the child; real fix: a vfork-safe sigaction
    // in our musl (or Qt resetting SIGABRT through the raw syscall).
    return true;
#endif
''', 1)
    open(p, 'w').write(s)
print('qtbase: QProcess uses vfork on Wasm')
