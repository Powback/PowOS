#!/usr/bin/env python3
"""rm-analyze.py: (comp container) turn one run's raw logs into one JSON line.
Inputs in /tmp/run: sway.log (WAYLAND_DEBUG=server, libwayland's HH:MM:SS.us UTC stamps), phases.json (rm-drive.py),
net.txt (netsample.py of the app container, copied in; absent for MODE=local).
  key latency = sway sends wl_keyboard.key(pressed) to the app's connection -> first wl_surface.commit that carries
                damage, on any surface of that connection (compositor-side "screen" = the commit arriving; the
                compositor's own repaint, <= 1 output frame, is not included)
  fps         = damaged commits per second on the busiest surface in the phase; gaps between them; a stall = a gap
                > 100 ms during scroll, or a key whose damage took > 100 ms
  bytes/s     = tcp_info bytes_acked (app->comp) and bytes_received (comp->app) of the waypipe link"""
import json, re, sys, datetime, statistics, collections
meta = dict(a.split('=', 1) for a in sys.argv[1:])
ph = json.load(open('/tmp/run/phases.json'))
day0 = datetime.datetime.fromtimestamp(ph['idle'][0] / 1000, datetime.timezone.utc).replace(hour=0, minute=0, second=0, microsecond=0).timestamp() * 1000
line = re.compile(r'^\[(\d\d):(\d\d):(\d\d)\.(\d+)\]\s+(->\s+)?([\w]+)#(\d+)\.(\w+)\((.*)\)\s*$')
keys, commits = [], collections.defaultdict(list)
pending = set()
kb_ids = set()
for l in open('/tmp/run/sway.log', errors='replace'):
    m = line.match(l)
    if not m: continue
    h, mi, s, us, ev, iface, oid, msg, args = m.groups()
    t = day0 + ((int(h) * 60 + int(mi)) * 60 + int(s)) * 1000 + int(us) / 1000
    if iface == 'wl_keyboard' and msg == 'key' and ev:
        a = [x.strip() for x in args.split(',')]
        if a[-1] == '1' and (not keys or t - keys[-1] > 1): keys.append(t)  # apps bind wl_keyboard twice
    elif iface == 'wl_surface':
        if msg in ('damage', 'damage_buffer'): pending.add(oid)
        elif msg == 'commit' and oid in pending:
            commits[oid].append(t); pending.discard(oid)
allc = sorted(t for v in commits.values() for t in v)
def pct(v, p):
    if not v: return None
    v = sorted(v); return round(v[min(len(v) - 1, int(round(p / 100 * (len(v) - 1))))], 1)
net = []
try:
    for l in open('/tmp/run/net.txt'):
        p = l.split()
        if len(p) == 4: net.append(tuple(int(x) for x in p))
except FileNotFoundError: pass
def bytes_in(a, b):
    s = [n for n in net if a <= n[0] <= b]
    if len(s) < 2: return None
    dt = (s[-1][0] - s[0][0]) / 1000
    up = (s[-1][1] - s[0][1]) / dt; dn = (s[-1][2] - s[0][2]) / dt
    peak = 0
    for i in range(len(s)):
        j = next((k for k in range(i, len(s)) if s[k][0] - s[i][0] >= 1000), None)
        if j is None: break
        peak = max(peak, (s[j][1] - s[i][1]) / ((s[j][0] - s[i][0]) / 1000))
    return {'up_Bps': round(up), 'down_Bps': round(dn), 'peak1s_up_Bps': round(peak), 'retrans': s[-1][3] - s[0][3]}
out = dict(meta)
for name, (a, b) in ph.items():
    r = {'dur_s': round((b - a) / 1000, 2)}
    busiest = max(commits, key=lambda k: sum(a <= t <= b for t in commits[k]), default=None)
    fr = [t for t in commits.get(busiest, []) if a <= t <= b]
    r['fps'] = round(len(fr) / ((b - a) / 1000), 1)
    if name == 'scroll':
        # gaps from the first frame after the scroll starts to the scroll end
        gaps = [y - x for x, y in zip(fr, fr[1:])]
        r.update(gap_p50=pct(gaps, 50), gap_p95=pct(gaps, 95), gap_max=round(max(gaps), 1) if gaps else None,
                 stalls_100ms=sum(g > 100 for g in gaps), first_frame_ms=round(fr[0] - a, 1) if fr else None)
    if name == 'typing':
        lat = []
        for k in [k for k in keys if a <= k <= b + 300][1:]:  # [0] = rm-drive's Shift_L tap
            nxt = next((t for t in allc if t >= k), None)
            lat.append(nxt - k if nxt is not None and nxt - k < 2000 else 2000)
        r.update(keys=len(lat), lat_p50=pct(lat, 50), lat_p95=pct(lat, 95), lat_max=round(max(lat), 1) if lat else None,
                 key_stalls_100ms=sum(x > 100 for x in lat))
    bi = bytes_in(a, b)
    if bi: r.update(bi)
    out[name] = r
print(json.dumps(out))
