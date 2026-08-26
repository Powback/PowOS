import re, sys, os
FN = re.compile(r'^\s*(?:function\s+)?([A-Za-z_][A-Za-z0-9_:]*)\s*\(\)\s*\{')
DEC = [re.compile(p) for p in [
    r'(?:^|[\s;(])if\s', r'(?:^|[\s;(])elif\s', r'(?:^|[\s;(])while\s',
    r'(?:^|[\s;(])until\s', r'(?:^|[\s;(])for\s', r'&&', r'\|\|', r';;\s*$',
]]
def strip(l):
    out, q = [], None
    for ch in l:
        if q:
            out.append(ch)
            if ch == q: q = None
        elif ch in "'\"": q = ch; out.append(ch)
        elif ch == '#' and (not out or out[-1] in ' \t'): break
        else: out.append(ch)
    return ''.join(out)
rows=[]
for path in sys.argv[1:]:
    try: lines = open(path, encoding='utf-8', errors='replace').read().split('\n')
    except OSError: continue
    fn, depth, cc, start = None, 0, 0, 0
    for i, raw in enumerate(lines, 1):
        l = strip(raw)
        if fn is None:
            m = FN.match(l)
            if m:
                fn, cc, start = m.group(1), 1, i
                depth = l.count('{') - l.count('}')
                for d in DEC: cc += len(d.findall(l[l.index('{')+1:]))
                if depth <= 0:
                    rows.append((os.path.basename(path), fn, cc, i-start+1)); fn=None
            continue
        for d in DEC: cc += len(d.findall(l))
        depth += l.count('{') - l.count('}')
        if depth <= 0:
            rows.append((os.path.basename(path), fn, cc, i-start+1)); fn=None
rows.sort(key=lambda r: -r[2])
print("  %-34s %-32s %4s %5s" % ("FILE","FUNCTION","CC","LINES"))
for f,n,c,ln in rows[:16]:
    print("  %-34s %-32s %4d %5d" % (f,n,c,ln))
print("\n  functions measured: %d   CC>15: %d   CC>25: %d"
      % (len(rows), sum(1 for r in rows if r[2]>15), sum(1 for r in rows if r[2]>25)))
