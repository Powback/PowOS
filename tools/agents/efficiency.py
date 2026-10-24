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

READ_TOOLS = {'Read', 'Grep', 'Glob'}
EDIT_TOOLS = {'Edit', 'Write'}


def parse_ts(ts):
    """A transcript event's `timestamp` field (ISO 8601, usually Z-suffixed) -> aware datetime, or None.
    Shared by efficiency.py and retro.py so "model time" and "tool time" mean the same thing in both."""
    if not ts:
        return None
    try:
        if ts.endswith('Z'):
            ts = ts[:-1] + '+00:00'
        return dt.datetime.fromisoformat(ts)
    except Exception:
        return None

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
        # The transcript JSONL's per-call usage field (undocumented upstream - see docs/AGENT-HANDBOOK.md, Retro):
        # message.usage.{input_tokens,cache_read_input_tokens,cache_creation_input_tokens,output_tokens} on every
        # type:"assistant" line. This is the one place that reads it; don't re-derive it elsewhere.
        u = m.get('usage') or {}
        ctx = u.get('input_tokens', 0) + u.get('cache_read_input_tokens', 0) + u.get('cache_creation_input_tokens', 0)
        c = calls.setdefault(m.get('id'), [ctx, None, u.get('output_tokens', 0)])
        for x in m.get('content') or []:
            if isinstance(x, dict) and x.get('type') == 'tool_use' and c[1] is None:
                c[1] = cat_of(x)
    minutes = _span_minutes(lo, hi)
    return calls, minutes


def call_timings(path, since=''):
    """Where the wall-clock actually went, one transcript at a time (the user, 2026-10-24: model time 661h
    vs tool time 131h across the fleet - measured by walking tool_use/tool_result timestamps in order, not
    by assuming either side is free). Two numbers, same pass:
      model time  - the gap between a tool_result landing and the NEXT tool_use being issued (the model
                     "thinking": reading the result, deciding, writing the next call). Charged once per
                     assistant turn (a turn can hold several parallel tool_use blocks; they share one gap).
      tool time   - the gap between a tool_use being issued and ITS OWN tool_result landing (the tool
                     actually running). Charged per call, so two tools issued in parallel both get the
                     turn's wall-clock span even though they overlapped - an overestimate for the sum, but
                     the right number for "how long did a slow command actually take" per call.
    Also: calls in-window, reads/searches (Read/Grep/Glob or a `read`-category Bash) before the first
    Edit/Write, and how many distinct files got read 3+ times (both already shown to matter in retro.py's
    per-agent digest; this gives efficiency.py the same two numbers so they can be compared across agents).
    Never raises on a malformed line; a missing/unparseable timestamp just skips that gap."""
    pending = {}            # tool_use id -> issued_ts
    last_result_ts = None    # ts of the most recent tool_result seen, in file order
    model_s = tool_s = 0.0
    calls = 0
    first_edit_seen = False
    reads_before_edit = 0
    reads_per_file = collections.Counter()
    for line in open(path, errors='replace'):
        try:
            e = json.loads(line)
        except ValueError:
            continue
        raw_ts = e.get('timestamp') or ''
        if since and raw_ts < since:
            continue
        ts = parse_ts(raw_ts)
        etype = e.get('type')
        m = e.get('message') or {}
        if etype == 'assistant':
            content = m.get('content') or []
            tool_uses = [x for x in content if isinstance(x, dict) and x.get('type') == 'tool_use']
            if tool_uses and ts is not None and last_result_ts is not None:
                model_s += max(0.0, (ts - last_result_ts).total_seconds())
            for x in tool_uses:
                calls += 1
                name = x.get('name')
                if ts is not None:
                    pending[x.get('id')] = ts
                if not first_edit_seen:
                    if name in EDIT_TOOLS:
                        first_edit_seen = True
                    elif name in READ_TOOLS or (name == 'Bash' and cat_of(x) == 'read'):
                        reads_before_edit += 1
                if name == 'Read':
                    fp = (x.get('input') or {}).get('file_path', '')
                    if fp:
                        reads_per_file[fp] += 1
        elif etype == 'user' and ts is not None:
            content = m.get('content')
            if isinstance(content, list):
                for x in content:
                    if isinstance(x, dict) and x.get('type') == 'tool_result':
                        issued = pending.pop(x.get('tool_use_id'), None)
                        if issued is not None:
                            tool_s += max(0.0, (ts - issued).total_seconds())
                last_result_ts = ts
    return {
        'calls': calls,
        'model_time_s': round(model_s),
        'tool_time_s': round(tool_s),
        'sec_per_call': round(tool_s / calls, 1) if calls else 0.0,
        'reads_before_first_edit': reads_before_edit,
        'files_read_3plus': sum(1 for n in reads_per_file.values() if n >= 3),
    }


def _span_minutes(lo, hi):
    """Wall-clock minutes between two ISO timestamps (the transcript's first and last in-window entries) -
    0 when either is missing or unparseable, never a crash on a malformed timestamp."""
    a, b = parse_ts(lo), parse_ts(hi)
    if a is None or b is None:
        return 0.0
    return max(0.0, (b - a).total_seconds() / 60.0)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--since'); ap.add_argument('--hours', type=float, default=24)
    ap.add_argument('--root', default=os.path.expanduser('~/.claude/projects'))
    ap.add_argument('--repo', default=os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
    ap.add_argument('--branch', default='origin/worktree-powos-multiplatform'); ap.add_argument('--json', action='store_true')
    a = ap.parse_args()
    since = a.since or (dt.datetime.now(dt.timezone.utc) - dt.timedelta(hours=a.hours)).strftime('%Y-%m-%dT%H:%M')
    files = [f for f in glob.glob(a.root + '/*PowOS*/**/*.jsonl', recursive=True) if os.path.getmtime(f) > 0]
    agents, minutes, timings, cats, n = {}, {}, {}, collections.Counter(), collections.Counter()
    for f in files:
        calls, mins = scan(f, since)
        if not calls:
            continue
        name = os.path.basename(f)[:-6].replace('agent-', '')
        agents[name] = calls
        minutes[name] = mins
        timings[name] = call_timings(f, since)
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
        # model_s/tool_s/sec_per_call/reads_before_edit/files_reread: call_timings() above - model time is
        # the model "thinking" between a tool_result and the next tool_use, tool time is tool_use -> its
        # own tool_result (how long the tool itself took). Lets a per-agent row show e.g. "mostly waiting
        # on a slow tool" vs "mostly re-reading/deciding" instead of only a token count.
        'by_agent': sorted(({'agent': k, 'calls': len(v), 'avg_ctx_k': round(sum(c[0] for c in v.values()) / len(v) / 1e3),
                             'Mtok': round(sum(c[0] for c in v.values()) / 1e6),
                             'minutes': round(minutes.get(k, 0.0), 1),
                             'over_time': minutes.get(k, 0.0) > 5,
                             'restarts_needed': sum(1 for c in v.values() if c[0] > 150_000),
                             'over_budget': any(c[0] > 150_000 for c in v.values()),
                             'model_s': timings.get(k, {}).get('model_time_s', 0),
                             'tool_s': timings.get(k, {}).get('tool_time_s', 0),
                             'sec_per_call': timings.get(k, {}).get('sec_per_call', 0.0),
                             'reads_before_edit': timings.get(k, {}).get('reads_before_first_edit', 0),
                             'files_reread': timings.get(k, {}).get('files_read_3plus', 0),
                             } for k, v in agents.items()),
                           key=lambda r: -r['Mtok']),
    }
    model_s_tot = sum(t['model_time_s'] for t in timings.values())
    tool_s_tot = sum(t['tool_time_s'] for t in timings.values())
    out['model_time_h'] = round(model_s_tot / 3600, 1)
    out['tool_time_h'] = round(tool_s_tot / 3600, 1)
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
    print(f"model time {out['model_time_h']}h (thinking between a tool_result and the next tool_use) vs "
          f"tool time {out['tool_time_h']}h (tool_use -> its own tool_result)")
    for k, v in out['by_category'].items(): print(f"  {k:16} {v['calls']:5} calls {v['pct']:5.1f}%")
    print("top agents by tokens:")
    for r in out['by_agent'][:8]:
        extra = f"  restarts_needed={r['restarts_needed']} OVER_BUDGET" if r['over_budget'] else ''
        extra += '  OVER_TIME' if r['over_time'] else ''
        print(f"  {r['agent'][:36]:36} {r['calls']:5} calls avg {r['avg_ctx_k']:4}k  {r['Mtok']} Mtok  {r['minutes']}min{extra}")
        print(f"    {r['model_s']}s model / {r['tool_s']}s tool ({r['sec_per_call']}s/call tool), "
              f"{r['reads_before_edit']} reads before first edit, {r['files_reread']} file(s) read 3+ times")
    print("misses:" if misses else "all targets met"); [print('  - ' + m) for m in misses]


if __name__ == '__main__':
    main()
