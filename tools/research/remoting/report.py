#!/usr/bin/env python3
"""report.py: results/*.jsonl -> the Markdown tables in docs/research/native-window-remoting.md "Measurements".
Bar (doc §4 Phase 1b): key->commit <= 30 ms p50 and <= 60 ms p95; idle+typing <= 1 MB/s; scroll >= 60 fps with
p95 frame gap <= 33 ms at <= 30 MB/s; at 1% loss no stall > 100 ms beyond the app's own (local-mode) stalls."""
import json, os
here = os.path.dirname(os.path.abspath(__file__))
def load(n):
    p = os.path.join(here, 'results', n)
    return [json.loads(l) for l in open(p)] if os.path.exists(p) else []
mb = lambda b: '-' if b is None else f'{b / 1e6:.2f}'
kb = lambda b: '-' if b is None else f'{b / 1e3:.1f}'
NETS = {'none': 'wired (none)', '3,2,0': '3±2 ms', '3,2,1': '3±2 ms 1% loss', '8,4,0': '8±4 ms', '8,4,1': '8±4 ms 1% loss'}
wp = load('waypipe.jsonl')
if wp:
    local = {r['app']: r for r in wp if r['mode'] == 'local'}
    print('| app | mode | net (each way) | key→commit p50 / p95 / max ms | idle KB/s | typing KB/s | scroll fps | gap p95 / max ms | scroll MB/s avg / peak 1 s | stalls >100 ms (local) | retrans | bar |')
    print('|---|---|---|---|---|---|---|---|---|---|---|---|')
    order = lambda r: (['firefox', 'kate', 'dolphin'].index(r['app']), ['local', 'shm', 'gpu', 'video-stock', 'video'].index(r['mode']), list(NETS).index(r['net']))
    for r in sorted(wp, key=order):
        t, s, i = r['typing'], r['scroll'], r['idle']
        loc = local.get(r['app'], {}).get('scroll', {}).get('stalls_100ms', 0)
        up = lambda x: (x.get('up_Bps') or 0) + (x.get('down_Bps') or 0)
        ok = []
        if r['mode'] != 'local':
            ok.append(t['lat_p50'] <= 30 and t['lat_p95'] <= 60)
            ok.append(up(i) <= 1e6 and up(t) <= 1e6)
            ok.append(s['fps'] >= 60 and s['gap_p95'] <= 33 and s.get('up_Bps', 0) <= 30e6)
            ok.append(s['stalls_100ms'] + t['key_stalls_100ms'] <= loc)
        verdict = '-' if not ok else ('PASS' if all(ok) else 'FAIL: ' + ','.join(n for n, o in zip(['latency', 'idle/typing bytes', 'scroll', 'stalls'], ok) if not o))
        print(f"| {r['app']} | {r['mode']} | {NETS.get(r['net'], r['net'])} | {t['lat_p50']} / {t['lat_p95']} / {t['lat_max']} | "
              f"{kb(up(i)) if r['mode'] != 'local' else '-'} | {kb(up(t)) if r['mode'] != 'local' else '-'} | {s['fps']} | {s['gap_p95']} / {s['gap_max']} | "
              f"{mb(s.get('up_Bps')) + ' / ' + mb(s.get('peak1s_up_Bps')) if r['mode'] != 'local' else '-'} | "
              f"{s['stalls_100ms'] + t['key_stalls_100ms']} ({loc}) | {s.get('retrans', 0) + t.get('retrans', 0) + i.get('retrans', 0) if r['mode'] != 'local' else '-'} | {verdict} |")
dt = load('dirty.jsonl')
if dt:
    print('\n| app | state | 100 ms: mean / p95 / max MB/s | 1 s: mean / p95 / max MB/s | RSS MB | processes |')
    print('|---|---|---|---|---|---|')
    by = {}
    for r in dt: by.setdefault((r['app'], r['state']), {})[r['interval_s']] = r
    for (a, st), v in by.items():
        f = lambda r: f"{r['mean_MBps']} / {r['p95_MBps']} / {r['max_MBps']}" if r else '-'
        any_ = v.get(0.1) or v.get(1.0)
        print(f"| {a} | {st} | {f(v.get(0.1))} | {f(v.get(1.0))} | {any_['rss_MB']} | {any_['procs']} |")
cr = load('criu.jsonl')
if cr:
    print('\n| workload | RSS MB | pre-dumps | net (each way) | total ms | freeze ms (dump + send + restore) | bytes moved MB (pre-dumps + final) | restored + typed text kept |')
    print('|---|---|---|---|---|---|---|---|')
    for r in cr:
        f = r['final']; pre = '+'.join(mb(p['bytes']) for p in r['pre'])
        print(f"| {r['workload']} | {r['rss_kb'] / 1e3:.0f} | {r['iter']} | {NETS.get(r['net'], r['net'])} | {r.get('total_ms', '-')} | "
              f"{r.get('freeze_ms', '-')} ({f['dump_ms']} + {f['send_ms']} + {r.get('restore_ms', '-')}) | {mb(r['bytes_total'])} ({pre + ' + ' if pre else ''}{mb(f['bytes'])}) | "
              f"{'yes' if r.get('restore_rc') == 0 and r['restored_lines_with_typing'] > 0 else 'NO'} |")
