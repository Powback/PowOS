import re, sys, os
FN = re.compile(r'^\s*(?:function\s+)?([A-Za-z_][A-Za-z0-9_:]*)\s*\(\)\s*\{')
DEC = [re.compile(p) for p in [
    r'(?:^|[\s;(])if\s', r'(?:^|[\s;(])elif\s', r'(?:^|[\s;(])while\s',
    r'(?:^|[\s;(])until\s', r'(?:^|[\s;(])for\s', r'&&', r'\|\|', r';;\s*$',
]]
# Heredoc bodies are DATA, not shell. Without this, `for`/`if` inside a
# `python3 - <<'PY'` payload counted as shell branching: mods_adopt_cmd measured
# 53 when its real shell complexity is 8, and that inflated number was written
# into docs as the third-worst function in the repo. 47 Python payloads and 19
# other heredocs across 29 files were affected.
HEREDOC = re.compile(r'<<-?\s*[\'"]?([A-Za-z_][A-Za-z0-9_]*)[\'"]?')

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
    heredoc = None
    for i, raw in enumerate(lines, 1):
        # Inside a heredoc body nothing is shell; only the terminator matters.
        if heredoc is not None:
            if raw.strip() == heredoc:
                heredoc = None
            continue
        l = strip(raw)
        m_h = HEREDOC.search(l)
        if m_h:
            heredoc = m_h.group(1)
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

# ── report / check ────────────────────────────────────────────────
# --check enforces a RATCHET, not a fixed ceiling:
#   * a function in the budget may not exceed its recorded value
#   * anything else may not exceed NEW_CAP
# So existing debt is frozen rather than demanded away, and new debt fails.
BUDGET = os.path.join(os.path.dirname(os.path.abspath(__file__)), "complexity-budget.txt")
NEW_CAP = 15

def load_budget():
    b = {}
    try:
        for line in open(BUDGET, encoding="utf-8"):
            line = line.split("#")[0].strip()
            if not line: continue
            fn, cc = line.rsplit(None, 1)
            b[fn.strip()] = int(cc)
    except OSError:
        pass
    return b

if "--check" in sys.argv:
    budget, fails, drifted = load_budget(), [], []
    for f, n, c, ln in rows:
        key = "%s:%s" % (f, n)
        if key in budget:
            if c > budget[key]:
                fails.append("  %-46s CC %d > budgeted %d" % (key, c, budget[key]))
            elif c < budget[key]:
                drifted.append("  %-46s CC %d (budget %d - lower it)" % (key, c, budget[key]))
        elif c > NEW_CAP:
            fails.append("  %-46s CC %d > %d (new code)" % (key, c, NEW_CAP))
    for d in drifted: print(d)
    if fails:
        print("\ncomplexity: FAIL")
        print("\n".join(fails))
        print("\nRaise a budget entry only with a reason. See docs/complexity.md.")
        sys.exit(1)
    print("complexity: ok (%d functions, cap %d for new code)" % (len(rows), NEW_CAP))
    sys.exit(0)

if "--budget" in sys.argv:
    for f, n, c, ln in sorted(rows, key=lambda r: (r[0], r[1])):
        if c > NEW_CAP:
            print("%s:%s %d" % (f, n, c))
    sys.exit(0)

print("  %-34s %-32s %4s %5s" % ("FILE","FUNCTION","CC","LINES"))
for f,n,c,ln in rows[:16]:
    print("  %-34s %-32s %4d %5d" % (f,n,c,ln))
print("\n  functions measured: %d   CC>15: %d   CC>25: %d"
      % (len(rows), sum(1 for r in rows if r[2]>15), sum(1 for r in rows if r[2]>25)))
