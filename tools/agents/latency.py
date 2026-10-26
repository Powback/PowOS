#!/usr/bin/env python3
"""tools/agents/latency.py: request -> on-phone time, per user request, split into stages. The #1 metric (the user,
2026-10-23: "it takes wayyyyyy too long per request still"; target: a small UI request on the phone in < 10 min).

  tools/agents/latency.py [--since 2026-10-22T18:00] [--hours N] [--json] [--md]

Per request (the manager's [high]/[urgent] mail in ~/.cache/powos-coder-mail.log, local time):
  lag    request -> agent start   the first agent prompt (Claude Code subagent transcript) that quotes the request
  code   agent start -> commit    its first commit that changes the phone (shell/ or the APK), as it landed on origin
  ship   commit -> on phone       the first shell push ("pushed <file>") covering that commit's shell files after it,
                                  or the first APK install (ship-apk) started after it - a Kotlin commit needs the APK;
                                  the ship service's done logs count as either
  check  on phone -> check pass   the first PASS in the verify runner's log of a board task the agent queued
A stage with no event yet is open (counted to now, marked '>'); a request no agent prompt matched is listed as such.
Matching is by words: a request's distinctive words found in an agent's prompt. The self-optimize loop runs this and
attacks the stage with the biggest median.
"""
import argparse, collections, datetime as dt, glob, json, os, re, statistics, subprocess, sys

HOME = os.path.expanduser('~')
MAIL = HOME + '/.cache/powos-coder-mail.log'
SHIPQ = HOME + '/.cache/powos-ship-queue'
VERQ = HOME + '/.cache/powos-verify-queue'
TRANSCRIPTS = HOME + '/.claude/projects'
BRANCH = 'origin/worktree-powos-multiplatform'
STOP = set('about after again agent agents already always before being below between board check could every first '
           'from have into isn\'t just later makes might more must never other phone right shell should since still '
           'their them then there these they thing this those through under until user user\'s users what when where '
           'which while with without would your the and for that not are but its it\'s now one two only does doesn\'t '
           'don\'t make shows show same'.split())


def words(s):
    return {w for w in re.findall(r"[a-z][a-z0-9'-]{4,}", s.lower()) if w not in STOP}


def local(ts):  # transcript timestamps are UTC ('...Z'); everything else here is local time
    return dt.datetime.fromisoformat(ts.replace('Z', '+00:00')).astimezone().replace(tzinfo=None)


def requests(since):
    out, cur = [], None
    for line in open(MAIL, errors='replace'):
        m = re.match(r'^• \[(\w+)\] from (\S+) \(\w+\) at (\S+)', line)
        if m:
            cur = None
            if m.group(1) in ('high', 'urgent') and m.group(2) == 'manager':
                t = dt.datetime.fromisoformat(m.group(3))
                if t >= since:
                    cur = {'at': t, 'prio': m.group(1), 'body': ''}
                    out.append(cur)
        elif cur is not None:
            cur['body'] += line
    return out


def text_of(c):
    if isinstance(c, str):
        return c
    return ' '.join(x.get('text', '') for x in c if isinstance(x, dict))


def scan_transcript(path, since):
    """-> (segments [(time, prompt)], bash [(start, end, cmd, result)]) of one transcript after `since`."""
    segs, uses, bash = [], {}, []
    for line in open(path, errors='replace'):
        try:
            e = json.loads(line)
        except ValueError:
            continue
        ts = e.get('timestamp')
        if not ts:
            continue
        t = local(ts)
        if t < since:
            continue
        att = e.get('attachment') or {}
        if e.get('type') == 'attachment' and att.get('type') == 'queued_command' and isinstance(att.get('prompt'), str):
            segs.append((t, att['prompt']))   # a SendMessage to a running agent
        c = (e.get('message') or {}).get('content')
        if e.get('type') == 'user' and isinstance(c, str) and not c.startswith('<'):
            segs.append((t, c))
        if not isinstance(c, list):
            continue
        for x in c:
            if not isinstance(x, dict):
                continue
            if x.get('type') == 'text' and e.get('type') == 'user' and not x.get('text', '').startswith('<'):
                segs.append((t, x['text']))
            elif x.get('type') == 'tool_use' and x.get('name') == 'Bash':
                uses[x['id']] = (t, x.get('input', {}).get('command', ''))
            elif x.get('type') == 'tool_result' and x.get('tool_use_id') in uses:
                st, cmd = uses.pop(x['tool_use_id'])
                bash.append((st, t, cmd, text_of(x.get('content') or '')))
    return segs, bash


def git(*a):
    return subprocess.run(['git', *a], capture_output=True, text=True).stdout


def commits(repo, since):
    out = []
    log = git('-C', repo, 'log', BRANCH, '--since', since.isoformat(), '--format=%x00%H %ct %s', '--name-only')
    for chunk in log.split('\0')[1:]:
        head, *files = chunk.strip().split('\n')
        sha, ct, subj = head.split(' ', 2)
        files = [f for f in files if f]
        sh = [f[6:] for f in files if f.startswith('shell/') and not re.match(r'shell/(dev|test)/', f)]
        apk = any(f.startswith('targets/android/app') and not f.endswith('version.properties') for f in files)
        out.append({'sha': sha, 'at': dt.datetime.fromtimestamp(int(ct)), 'subj': subj, 'shell': sh, 'apk': apk})
    return out


def ship_events(bashes, repo):
    """Shell pushes [(time, {files})] and APK installs [(start, end)] - agents' own runs + the ship service's logs."""
    pushes, apks = [], []
    for st, en, cmd, res in bashes:
        if 'push.sh' in cmd or 'ship-apk' in cmd:
            f = set(re.findall(r'^pushed (\S+)', res, re.M))
            if f:
                pushes.append((en, f))
        if 'ship-apk' in cmd and re.search(r'versionCode=\d+', res):
            apks.append((st, en))
    for log in glob.glob(SHIPQ + '/done/*.log'):
        m = re.match(r'(\d{8}-\d{6})-', os.path.basename(log))
        if not m:
            continue
        st, en, res = dt.datetime.strptime(m.group(1), '%Y%m%d-%H%M%S'), dt.datetime.fromtimestamp(os.path.getmtime(log)), open(log, errors='replace').read()
        f = set(re.findall(r'^pushed (\S+)', res, re.M))
        if f:
            pushes.append((en, f))
        if re.search(r'versionCode=\d+', res):
            apks.append((st, en))
    return sorted(pushes), sorted(apks)


def on_phone(c, pushes, apks):
    a = next((en for st, en in apks if st >= c['at']), None)
    if c['apk']:
        return a
    p = next((t for t, f in pushes if t >= c['at'] and set(c['shell']) & f), None)
    return min([x for x in (a, p) if x], default=None)


def check_passes():
    """board task -> [PASS times] from the verify runner's log (HH:MM:SS, dated by the job id's queue time)."""
    task_of = {}
    for j in glob.glob(VERQ + '/*.job') + glob.glob(VERQ + '/done/*.job'):
        m = re.search(r'^task=(.*)$', open(j, errors='replace').read(), re.M)
        if m:
            task_of[os.path.basename(j)[:-4]] = m.group(1)
    out = collections.defaultdict(list)
    for line in open(VERQ + '/runner.log', errors='replace') if os.path.exists(VERQ + '/runner.log') else []:
        m = re.match(r'(\d\d:\d\d:\d\d) ((\d{8})-(\d{6})-\S+): PASS', line)
        if not m:
            continue
        q = dt.datetime.strptime(m.group(3) + m.group(4), '%Y%m%d%H%M%S')
        t = dt.datetime.combine(q.date(), dt.time.fromisoformat(m.group(1)))
        if t < q:
            t += dt.timedelta(days=1)
        out[task_of.get(m.group(2), m.group(2).split('-', 3)[-1])].append(t)
    return out


def mins(a, b):
    return None if a is None or b is None else round((b - a).total_seconds() / 60, 1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--since'); ap.add_argument('--hours', type=float, default=12)
    ap.add_argument('--repo', default=os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
    ap.add_argument('--json', action='store_true'); ap.add_argument('--md', action='store_true')
    a = ap.parse_args()
    now = dt.datetime.now()
    since = dt.datetime.fromisoformat(a.since) if a.since else now - dt.timedelta(hours=a.hours)
    git('-C', a.repo, 'fetch', '-q', 'origin', BRANCH.split('/', 1)[1])
    reqs, cs = requests(since), commits(a.repo, since)
    agents, allbash = [], []
    for f in glob.glob(TRANSCRIPTS + '/*PowOS*/**/*.jsonl', recursive=True):
        if os.path.getmtime(f) < since.timestamp():
            continue
        segs, bash = scan_transcript(f, since)
        allbash += bash
        if '/subagents/' in f:
            agents.append({'id': os.path.basename(f)[6:-6], 'segs': segs, 'bash': bash})
    pushes, apks = ship_events(allbash, a.repo)
    passes = check_passes()
    rows = []
    for r in reqs:
        rw = words(r['body'])
        best = None
        for ag in agents:
            for i, (t, p) in enumerate(ag['segs']):
                if not (r['at'] - dt.timedelta(minutes=1) <= t <= r['at'] + dt.timedelta(hours=6)) or not rw:
                    continue
                s = len(rw & words(p)) / len(rw)
                end = now   # its first commit after the ask, even if more asks came in meanwhile
                if s >= 0.4 and (best is None or t < best[0]):
                    best = (t, ag, end, s)
        row = {'at': r['at'], 'prio': r['prio'], 'ask': ' '.join(r['body'].split())[:90]}
        rows.append(row)
        if not best:
            continue
        start, ag, end, s = best
        row.update(agent=ag['id'][:8], start=start, match=round(s, 2))
        cmds = ' '.join(c for st, en, c, _ in ag['bash'] if start <= st <= end)
        mine = [c for c in cs if c['subj'][:50] in cmds and c['at'] >= start - dt.timedelta(minutes=1)]
        phone = [c for c in mine if c['shell'] or c['apk']]
        if not phone:
            row['commits'] = [c['subj'] for c in mine][:2]
            continue
        c = min(phone, key=lambda c: c['at'])
        row.update(commit=c['at'], subj=c['subj'], kind='apk' if c['apk'] else 'shell', live=on_phone(c, pushes, apks))
        tasks = set(re.findall(r'queue\.sh add (?:--close )?([a-z0-9][a-z0-9-]+)', cmds))
        if row['live']:
            row['check'] = min((t for k in tasks for t in passes.get(k, []) if t >= row['live']), default=None)
        row['tasks'] = sorted(tasks)
    stages = [('lag', 'at', 'start'), ('code', 'start', 'commit'), ('ship', 'commit', 'live'), ('check', 'live', 'check')]
    for row in rows:
        for n, x, y in stages:
            if row.get(x) is None or not row.get('start'):
                continue
            v = mins(row[x], row.get(y))
            # Open stage (no event yet): counted to now, so a stuck ship shows as the wait it is.
            if v is None and (n != 'check' or row.get('tasks')):
                row[n], row[n + '_open'] = mins(row[x], now), True
            elif v is not None:
                row[n] = v
        if row.get('live'):
            row['total'] = mins(row['at'], row['live'])
    med = {}
    for n in [s[0] for s in stages] + ['total']:
        # done: stages that ended; with_open: + the open ones counted to now (a lower bound - a stuck ship is a wait)
        v = [r[n] for r in rows if r.get(n) is not None and not r.get(n + '_open')]
        w = [r[n] for r in rows if r.get(n) is not None]
        med[n] = {'median': round(statistics.median(v), 1) if v else None, 'n': len(v),
                  'with_open': round(statistics.median(w), 1) if w else None, 'open': len(w) - len(v)}
    biggest = max((n for n, *_ in stages if med[n]['median'] is not None), key=lambda n: med[n]['median'], default=None)
    out = {'since': since.isoformat(timespec='minutes'), 'now': now.isoformat(timespec='minutes'), 'requests': len(rows),
           'matched': sum(1 for r in rows if r.get('start')), 'medians': med, 'biggest': biggest, 'rows': rows}
    if a.json:
        json.dump(out, sys.stdout, indent=1, default=str); print(); return
    fmt = lambda r, n: '' if r.get(n) is None else ('>' if r.get(n + '_open') else '') + f"{r[n]:g}"
    hm = lambda t: t.strftime('%H:%M') if t else '-'
    if a.md:
        print(f"| asked | ask | agent start | first phone commit | kind | on phone | lag | code | ship | check | to phone |")
        print('|---|---|---|---|---|---|---|---|---|---|---|')
        for r in rows:
            print(f"| {hm(r['at'])} {r['prio']} | {r['ask'][:70].replace('|', '/')} | {hm(r.get('start'))} | "
                  f"{(r.get('subj') or ('no phone commit' if r.get('start') else 'no agent matched'))[:50].replace('|', '/')} | "
                  f"{r.get('kind', '')} | {hm(r.get('live'))} | {fmt(r, 'lag')} | {fmt(r, 'code')} | {fmt(r, 'ship')} | "
                  f"{fmt(r, 'check')} | {fmt(r, 'total')} |")
        print()
    print(f"since {out['since']}: {out['requests']} requests, {out['matched']} matched to an agent")
    for n, v in med.items():
        print(f"  {n:6} median {v['median']} min (n={v['n']})" + (f", {v['with_open']} with {v['open']} open" if v['open'] else ''))
    print(f"biggest stage: {biggest}")


if __name__ == '__main__':
    main()
