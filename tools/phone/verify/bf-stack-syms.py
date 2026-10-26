#!/usr/bin/env python3
# bf-stack-syms.py: the body of bf-lib.sh's hang_stack() helper (its gdb-output symbolizer), split out to keep
# that shell function under the length budget (test-complexity.sh). Invoked as
# `python3 /var/tmp/powos-bf-stack-syms.py <pid> <tid> <gdb output file>` - same argv positions as the old
# `python3 - "$x" "$tid" "$T/gdb.$tid" <<PY`, since argv[0] (script path) takes the place of the old "-".
import re, struct, sys
pid, tid, out = sys.argv[1], sys.argv[2], open(sys.argv[3], errors="replace").read()
print("stack: thread %s (%s), host frames:" % (tid, open("/proc/%s/task/%s/comm" % (pid, tid)).read().strip()))
for l in out.splitlines():
    if l.startswith("#"): print("stack:   " + re.sub(r"\s+", " ", l)[:200])
    elif re.match(r"\s*(=>)?\s*0x[0-9a-f]+.*:\t", l): print("stack:   asm " + re.sub(r"\s+", " ", l)[:120])
maps = []
for l in open("/proc/%s/maps" % pid):
    f = l.split()
    a, b = (int(v, 16) for v in f[0].split("-"))
    maps.append((a, b, f[1], int(f[2], 16), f[5] if len(f) > 5 else ""))
def where(v):
    for a, b, perm, off, path in maps:
        if a <= v < b: return path, v - a + off, perm
    return None, 0, ""
syms = {}
def sym(path, foff):
    if path not in syms:
        s = []
        try:
            d = open(path, "rb").read()
            if d[:4] == b"\x7fELF" and d[4] == 2:
                phoff, shoff = struct.unpack_from("<QQ", d, 32); phn, shn = struct.unpack_from("<H", d, 56)[0], struct.unpack_from("<H", d, 60)[0]
                loads = [struct.unpack_from("<IIQQQQ", d, phoff + 56 * i) for i in range(phn)]
                sh = [struct.unpack_from("<IIQQQQIIQQ", d, shoff + 64 * i) for i in range(shn)]
                for t in sh:
                    if t[1] in (2, 11):  # SYMTAB / DYNSYM
                        st = sh[t[6]]
                        for j in range(t[5] // 24):
                            nm, info, _, _, val, sz = struct.unpack_from("<IBBHQQ", d, t[4] + 24 * j)
                            if info & 15 == 2 and val:
                                e = d.index(b"\0", st[4] + nm); s.append((val, sz, d[st[4] + nm:e].decode(errors="replace")))
                s.sort(); syms[path] = (s, [(l[2], l[3], l[5]) for l in loads if l[0] == 1])
            else: syms[path] = ([], [])
        except Exception: syms[path] = ([], [])
    s, loads = syms[path]
    va = next((foff - o + v for o, v, fs in loads if o <= foff < o + fs), None)
    if va is None or not s: return ""
    best = None
    for val, sz, nm in s:
        if val > va: break
        best = (val, nm)
    return " %s+%#x" % (best[1], va - best[0]) if best else ""
def name(v):
    path, foff, perm = where(v)
    return "%#x %s+%#x%s" % (v, path.rsplit("/", 1)[-1], foff, sym(path, foff)) if path and path.startswith("/") and "x" in perm else None
m = re.search(r"\$\d+ = (0x[0-9a-f]+)\n\$\d+ = (0x[0-9a-f]+)", out)
pc = int(m.group(1), 16) if m else 0
print("stack: host pc %s" % (name(pc) or "%#x (JIT code / anonymous)" % pc))
try:
    x28 = int(m.group(2), 16); mem = open("/proc/%s/mem" % pid, "rb")
    mem.seek(x28); q = struct.unpack("<17Q", mem.read(136))
    rip = q[0]
    def region(v):
        for a, b, perm, off, path in maps:
            if a <= v < b: return "%s %s %dK" % (path or "anon", perm, (b - a) // 1024)
        return "unmapped"
    print("stack: guest rip %s [%s]; regs %s" % (name(rip) or "%#x" % rip, region(rip), " ".join("%#x" % v for v in q[1:])))
    # Which greg is the stack pointer depends on FEX's CPUState layout: scan from every greg that points into rw
    # anonymous memory (a stack), 8 KB up, for values inside file-backed executable mappings (return addresses).
    seen, n = set(), 0
    for v in q[1:]:
        p, _, perm = where(v)
        if not perm.startswith("rw") or p.startswith("/"): continue
        try:
            mem.seek(v & ~7); st = struct.unpack("<1024Q", mem.read(8192))
        except Exception: continue
        for w in st:
            r = name(w)
            if r and w not in seen:
                seen.add(w); print("stack:   guest ret? " + r); n += 1
            if n >= 20: break
        if n >= 20: break
except Exception as e:
    print("stack: no guest state at x28 (%s) - not in JIT code" % e)
