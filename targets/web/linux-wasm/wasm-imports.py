#!/usr/bin/env python3
"""Lists a Wasm module's imports (module, field, kind) - e.g. to see which symbols a Linux/Wasm program left to the
loader (GOT.mem / GOT.func imports the runtime can't satisfy).   wasm-imports.py file.wasm [module-filter]"""
import sys

data = open(sys.argv[1], 'rb').read()
want = sys.argv[2] if len(sys.argv) > 2 else None


def leb(b, i):
    r = s = 0
    while True:
        x = b[i]; i += 1
        r |= (x & 0x7f) << s; s += 7
        if x < 0x80:
            return r, i


i = 8
kinds = {0: 'func', 1: 'table', 2: 'memory', 3: 'global', 4: 'tag'}
while i < len(data):
    sid = data[i]; i += 1
    size, i = leb(data, i)
    end = i + size
    if sid == 2:
        n, j = leb(data, i)
        for _ in range(n):
            ml, j = leb(data, j); mod = data[j:j + ml].decode(); j += ml
            fl, j = leb(data, j); field = data[j:j + fl].decode(); j += fl
            kind = data[j]; j += 1
            if kind == 0:
                _, j = leb(data, j)
            elif kind == 1:
                j += 1; fl2, j = leb(data, j); _, j = leb(data, j)
                if fl2 & 1: _, j = leb(data, j)
            elif kind == 2:
                fl2, j = leb(data, j); _, j = leb(data, j)
                if fl2 & 1: _, j = leb(data, j)
            elif kind == 3:
                j += 2
            elif kind == 4:
                j += 1; _, j = leb(data, j)
            if not want or want in mod:
                print(f'{mod}\t{field}\t{kinds.get(kind, kind)}')
        break
    i = end
