#!/usr/bin/env python3
"""Do two kernels lay out their types identically? Compares `pahole -F btf vmlinux` dumps (every named
struct/union/enum with member offsets, sizes and holes) of a baseline kernel and a new one.

Vendor modules are compiled against the baseline's headers, so any type both kernels have must be
byte-for-byte the same in the new one - symbol CRCs (kmi-check.py) only catch what genksyms sees, this
catches the rest. Types only the new kernel has are fine (nothing old can reference them).

    layout-diff.py base.pahole new.pahole [allowed type ...]     exit 1 if a shared, non-allowed type differs
"""
import re, sys


def load(path):
    types, cur = {}, None
    for line in open(path, errors='replace'):
        m = re.match(r'^(struct|union|enum) (\w+) \{', line)
        if m:
            cur = f'{m.group(1)} {m.group(2)}'
            types[cur] = []
        if cur:
            types[cur].append(line.rstrip('\n'))
            if line.startswith('}'):
                cur = None
    return {k: '\n'.join(v) for k, v in types.items()}


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    a, b = load(sys.argv[1]), load(sys.argv[2])
    allowed = set(sys.argv[3:])
    shared = a.keys() & b.keys()
    changed = sorted(k for k in shared if a[k] != b[k])
    bad = [k for k in changed if k not in allowed]
    print(f'{len(a)} baseline types, {len(b)} new types, {len(shared)} shared')
    print('only in baseline:', ', '.join(sorted(a.keys() - b.keys())) or '-')
    print('only in new:', ', '.join(sorted(b.keys() - a.keys())) or '-')
    for k in changed:
        print(('ALLOWED ' if k in allowed else 'CHANGED ') + k)
        if k not in allowed:
            x, y = a[k].splitlines(), b[k].splitlines()
            for i in range(max(len(x), len(y))):
                l, r = (x[i] if i < len(x) else ''), (y[i] if i < len(y) else '')
                if l != r:
                    print('   -', l.strip())
                    print('   +', r.strip())
    print('OK - every shared type has the same layout' if not bad else f'FAIL - {len(bad)} shared types differ')
    sys.exit(1 if bad else 0)


main()
