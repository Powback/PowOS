#!/usr/bin/env python3
"""dirty.py ROOT_PID INTERVAL_S DURATION_S: pages an app dirties per interval, via soft-dirty tracking.
Each sample: write 4 to /proc/<pid>/clear_refs for every process in ROOT_PID's tree (re-discovered each sample, so
new content processes count), sleep INTERVAL, then read /proc/<pid>/pagemap over every writable mapping and count
entries that are present-or-swapped (bits 63/62) and soft-dirty (bit 55). Rate = dirty bytes / (read - clear) per
process, summed. Prints one JSON line: per-sample MB/s, mean/p50/p95/max, the tree's RSS, the scan cost.
Caveats: a THP written once reports all 512 of its 4 KiB entries dirty; clearing soft-dirty write-protects every page,
so the app pays one minor fault per first write per interval (the measurement perturbs it slightly); GPU memory
(DMA-BUFs, VRAM) is not process memory and is not counted."""
import json, os, sys, time
import numpy as np
root, iv, dur = int(sys.argv[1]), float(sys.argv[2]), float(sys.argv[3])
PAGE = os.sysconf('SC_PAGE_SIZE')
def tree(r):
    kids = {}
    for d in os.listdir('/proc'):
        if d.isdigit():
            try:
                f = open(f'/proc/{d}/stat').read(); ppid = int(f[f.rindex(')') + 2:].split()[1])
                kids.setdefault(ppid, []).append(int(d))
            except OSError: pass
    out, st = [], [r]
    while st:
        p = st.pop(); out.append(p); st += kids.get(p, [])
    return out
def rss(pids):
    s = 0
    for p in pids:
        try: s += int(open(f'/proc/{p}/statm').read().split()[1]) * PAGE
        except OSError: pass
    return s
def count(pid):
    n = 0
    with open(f'/proc/{pid}/maps') as m, open(f'/proc/{pid}/pagemap', 'rb', buffering=0) as pm:
        for l in m:
            a = l.split()
            if a[1][1] != 'w' or (len(a) > 5 and a[5] == '[vsyscall]'): continue
            lo, hi = (int(x, 16) for x in a[0].split('-'))
            off, cnt = lo // PAGE * 8, (hi - lo) // PAGE
            while cnt:
                k = min(cnt, 1 << 18)
                b = os.pread(pm.fileno(), k * 8, off)
                e = np.frombuffer(b, dtype=np.uint64)
                n += int(np.count_nonzero(((e >> 55) & 1).astype(bool) & ((e >> 62) & 3).astype(bool)))
                off += k * 8; cnt -= k
    return n
rates, scans = [], []
end = time.time() + dur
while time.time() < end:
    pids = tree(root); tc = {}
    for p in pids:
        try:
            with open(f'/proc/{p}/clear_refs', 'w') as f: f.write('4')
            tc[p] = time.monotonic()
        except OSError: pass
    time.sleep(iv)
    s0 = time.monotonic(); tot = 0.0
    for p, t in tc.items():
        try:
            n = count(p); tot += n * PAGE / (time.monotonic() - t)
        except OSError: pass
    scans.append(time.monotonic() - s0); rates.append(tot / 1e6)
r = sorted(rates)
q = lambda x: round(r[min(len(r) - 1, int(round(x * (len(r) - 1))))], 2)
print(json.dumps({'interval_s': iv, 'samples': len(r), 'mean_MBps': round(sum(r) / len(r), 2), 'p50_MBps': q(.5),
                  'p95_MBps': q(.95), 'max_MBps': round(r[-1], 2), 'rss_MB': round(rss(tree(root)) / 1e6),
                  'procs': len(tree(root)), 'scan_ms_mean': round(1000 * sum(scans) / len(scans), 1)}))
