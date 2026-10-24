#!/usr/bin/env python3
"""tools/agents/efficiency.py: how efficiently the PowOS agents worked - tokens per commit, context per call, where
the calls went. Reads Claude Code transcripts (each model call counted once, by message id).

  tools/agents/efficiency.py [--since 2026-10-22T00:00] [--hours N] [--root DIR] [--repo DIR] [--json]

Targets (handbook, Efficiency): avg context per call < 200k, waiting/polling < 5% of tokens, coordination (board,
messages, git sync) < 10%, process/tooling commits < 25%, wall-clock per agent task <= 5 min (the user: "aim for
max 5 min per agent per task" - same budget `.claude/hooks/agent-notices.py` reminds agents about live). The
self-optimize loop runs this and fixes the worst miss.
"""
import argparse, collections, datetime as dt, glob, json, os, re, subprocess, sys

CATS = [  # first match wins; Bash commands only
    ('wait/poll', r'idle\.sh|--wait|\bsleep \d|until |seq \d+\); do|tasks/\w+\.output|get-state'),
    ('edit', r"cat > |sed -i|perl -pi|python3 - <<|open\([^)]*'w'|git apply"),
    ('git commit/push', r'git (commit|push)'),
    ('git sync', r'git (fetch|rebase|pull|status|stash|merge)'),
    ('gate/test', r'gate\.sh|lint|tsc|vitest|bun test|run-all'),
    ('ship', r'ship-apk|push\.sh'),
    ('phone look', r'adb|cdp\.sh|shot\.sh|root\.sh|user\.sh'),
    ('board/comms', r'powos (agents|comms)'),
    ('read', r'^\s*(cd \S+ *(&&|;) *)?(cat|sed -n|grep|rg|head|tail|ls|find|wc|git (log|show|diff))'),
]
TOOL_CAT = {'Edit': 'edit', 'Write': 'edit', 'Read': 'read', 'Grep': 'read', 'Glob': 'read',
            'SendMessage': 'board/comms', 'SubagentHandback': 'board/comms'}
OVERHEAD = {'wait/poll', 'board/comms', 'git sync', 'git commit/push'}


def cat_of(tool):
    if tool['name'] != 'Bash':
        return TOOL_CAT.get(tool['name'], 'other')
    cmd = tool.get('input', {}).get('command', '')
    return next((n for n, p in CATS if re.search(p, cmd, re.M)), 'bash other')


def scan(path, since):
    calls = {}  # message id -> [context tokens, category, output tokens]
    lo = hi = None  # first/last in-window timestamp seen (any event type) - this call's wall-clock span
    for line in open(path, errors='replace'):
        try:
            e = json.loads(line)
        except ValueError:
            continue
        ts = e.get('timestamp') or ''
        if ts and ts >= since:
            lo = ts if lo is None or ts < lo else lo
            hi = ts if hi is None or ts > hi else hi
        if e.get('type') != 'assistant' or ts < since:
            continue
        m = e.get('message') or {}
        u = m.get('usage') or {}
        ctx = u.get('input_tokens', 0) + u.get('cache_read_input_tokens', 0) + u.get('cache_creation_input_tokens', 0)
        c = calls.setdefault(m.get('id'), [ctx, None, u.get('output_tokens', 0)])
        for x in m.get('content') or []:
            if isinstance(x, dict) and x.get('type') == 'tool_use' and c[1] is None:
                c[1] = cat_of(x)
    minutes = _span_minutes(lo, hi)
    return calls, minutes


def _span_minutes(lo, hi):
    """Wall-clock minutes between two ISO timestamps (the transcript's first and last in-window entries) -
    0 when either is missing or unparseable, never a crash on a malformed timestamp."""
    if not lo or not hi:
        return 0.0
    try:
        def parse(t):
            return dt.datetime.fromisoformat(t[:-1] + '+00:00' if t.endswith('Z') else t)
        return max(0.0, (parse(hi) - parse(lo)).total_seconds() / 60.0)
    except Exception:
        return 0.0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--since'); ap.add_argument('--hours', type=float, default=24)
    ap.add_argument('--root', default=os.path.expanduser('~/.claude/projects'))
    ap.add_argument('--repo', default=os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
    ap.add_argument('--branch', default='origin/worktree-powos-multiplatform'); ap.add_argument('--json', action='store_true')
    a = ap.parse_args()
    since = a.since or (dt.datetime.now(dt.timezone.utc) - dt.timedelta(hours=a.hours)).strftime('%Y-%m-%dT%H:%M')
    files = [f for f in glob.glob(a.root + '/*PowOS*/**/*.jsonl', recursive=True) if os.path.getmtime(f) > 0]
    agents, minutes, cats, n = {}, {}, collections.Counter(), collections.Counter()
    for f in files:
        calls, mins = scan(f, since)
        if not calls:
            continue
        name = os.path.basename(f)[:-6].replace('agent-', '')
        agents[name] = calls
        minutes[name] = mins
        for ctx, c, _ in calls.values():
            cats[c or 'final text'] += ctx; n[c or 'final text'] += 1
    tot = sum(cats.values()) or 1
    ncalls = sum(n.values()) or 1
    log = subprocess.run(['git', '-C', a.repo, 'log', a.branch, '--since', since, '--format=%s'],
                         capture_output=True, text=True).stdout.splitlines()
    proc = [s for s in log if re.search(r'handbook|tools/phone|gate|lint|baseline|ship-apk|push\.sh|idle|lock|board', s, re.I)]
    out = {
        'since': since, 'agents': len(agents), 'calls': ncalls, 'Mtok': round(tot / 1e6),
        'avg_ctx_k': round(tot / ncalls / 1e3), 'commits': len(log),
        'Mtok_per_commit': round(tot / 1e6 / max(len(log), 1), 1),
        'process_commits_pct': round(100 * len(proc) / max(len(log), 1)),
        'overhead_pct': round(100 * sum(cats[k] for k in OVERHEAD) / tot),
        'wait_pct': round(100 * cats['wait/poll'] / tot),
        'by_category': {k: {'calls': n[k], 'pct': round(100 * v / tot, 1)} for k, v in cats.most_common()},
        # restarts_needed/over_budget: calls past 150k context (AGENT-HANDBOOK.md, Efficiency: hand back by 120k,
        # never resume an agent past 150k) - how many times this agent should have handed off instead of ploughing
        # on, and whether it happened at all this window (over_budget is what gates a resume: never SendMessage an
        # agent with over_budget true - start fresh from its last report instead).
        # minutes/over_time: wall-clock span (first to last transcript entry this window) against the 5-min
        # per-task budget (the user: "aim for max 5 min per agent per task") - a separate axis from context: a
        # cheap task can still run long in real time (waiting, re-reading, back-and-forth).
        'by_agent': sorted(({'agent': k, 'calls': len(v), 'avg_ctx_k': round(sum(c[0] for c in v.values()) / len(v) / 1e3),
                             'Mtok': round(sum(c[0] for c in v.values()) / 1e6),
                             'minutes': round(minutes.get(k, 0.0), 1),
                             'over_time': minutes.get(k, 0.0) > 5,
                             'restarts_needed': sum(1 for c in v.values() if c[0] > 150_000),
                             'over_budget': any(c[0] > 150_000 for c in v.values())} for k, v in agents.items()),
                           key=lambda r: -r['Mtok']),
    }
    misses = []
    if out['avg_ctx_k'] > 200: misses.append(f"avg context {out['avg_ctx_k']}k > 200k: agents live too long (one task per agent run)")
    if out['wait_pct'] > 5: misses.append(f"waiting/polling {out['wait_pct']}% > 5%: queue phone checks (verify/queue.sh), no poll loops")
    if out['overhead_pct'] > 15: misses.append(f"coordination {out['overhead_pct']}% > 15%: fewer messages, rebase only to push")
    if out['process_commits_pct'] > 25: misses.append(f"process/tooling commits {out['process_commits_pct']}% > 25%: tooling only when something broke")
    over = [r['agent'] for r in out['by_agent'] if r['over_budget']]
    if over: misses.append(f"{len(over)} agent(s) passed the 150k hard budget this window: {', '.join(over[:5])}"
                            f"{' ...' if len(over) > 5 else ''} - never resume them (SendMessage), start fresh from their hand-back notes")
    over_t = [r['agent'] for r in out['by_agent'] if r['over_time']]
    if over_t: misses.append(f"{len(over_t)} agent(s) ran past the 5-min per-task budget this window: {', '.join(over_t[:5])}"
                              f"{' ...' if len(over_t) > 5 else ''} - land what works now and hand back, don't keep going")
    out['misses'] = misses
    if a.json:
        json.dump(out, sys.stdout, indent=1); print(); return
    print(f"since {since}: {out['agents']} transcripts, {out['calls']} calls, {out['Mtok']} Mtok, avg context {out['avg_ctx_k']}k, "
          f"{out['commits']} commits ({out['Mtok_per_commit']} Mtok each, {out['process_commits_pct']}% process)")
    for k, v in out['by_category'].items(): print(f"  {k:16} {v['calls']:5} calls {v['pct']:5.1f}%")
    print("top agents by tokens:")
    for r in out['by_agent'][:8]:
        extra = f"  restarts_needed={r['restarts_needed']} OVER_BUDGET" if r['over_budget'] else ''
        extra += '  OVER_TIME' if r['over_time'] else ''
        print(f"  {r['agent'][:36]:36} {r['calls']:5} calls avg {r['avg_ctx_k']:4}k  {r['Mtok']} Mtok  {r['minutes']}min{extra}")
    print("misses:" if misses else "all targets met"); [print('  - ' + m) for m in misses]


if __name__ == '__main__':
    main()
