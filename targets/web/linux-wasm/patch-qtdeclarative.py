#!/usr/bin/env python3
"""PowOS patch over qtdeclarative for Linux/Wasm (idempotent; build-qt.sh applies it).

The QML/JS engine's heap (QV4::MemoryManager) gets memory from WTF's OSAllocator in the "reserve, then commit" style:
mmap a large PROT_NONE region, later mprotect parts of it writable (commit) and madvise/mprotect them away again
(decommit). A NOMMU kernel can't do any of that - the PROT_NONE reservation is not usable memory - so the first
write into a "committed" chunk ran off into the void ("memory access out of bounds" in OSAllocator::commit).

On NOMMU an anonymous mmap is real, zeroed, contiguous memory right away, so: reserve = allocate it writable, commit
= nothing, decommit = zero it (QV4 relies on decommitted memory reading back as zeros, as after MADV_DONTNEED).

    patch-qtdeclarative.py <qtdeclarative source dir>"""
import os, sys

p = os.path.join(sys.argv[1], 'src/3rdparty/masm/wtf/OSAllocatorPosix.cpp')
s = open(p).read()
if 'PowOS: NOMMU' in s:
    print('qtdeclarative: OSAllocator already patched')
    sys.exit(0)

def patch(func_head, branch):
    global s
    i = s.index(func_head)
    j = s.index('#if OS(QNX)', i)
    s = s[:j] + '#if defined(__wasm__) /* PowOS: NOMMU (patch-qtdeclarative.py) */\n' + branch + '#elif OS(QNX)' + s[j + len('#if OS(QNX)'):]

patch('void* OSAllocator::reserveUncommitted(', '''    UNUSED_PARAM(usage);
    UNUSED_PARAM(writable);
    UNUSED_PARAM(executable);
    void* result = mmap(0, bytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (result == MAP_FAILED)
        CRASH();
''')
patch('void OSAllocator::commit(', '''    UNUSED_PARAM(address);
    UNUSED_PARAM(bytes);
    UNUSED_PARAM(writable);
    UNUSED_PARAM(executable);
''')
patch('void OSAllocator::decommit(', '''    memset(address, 0, bytes);
''')
open(p, 'w').write(s)
print('qtdeclarative: OSAllocator reserve/commit for NOMMU')
