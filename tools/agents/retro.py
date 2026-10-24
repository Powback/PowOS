#!/usr/bin/env python3
"""tools/agents/retro.py: the friction one agent transcript hit, digested so the fix is cheap and automatic.

  tools/agents/retro.py <agent-id | transcript path> [--json]
  tools/agents/retro.py --since 4h --all [--json]     # digest across every agent finished in the window,
                                                       # ranked by tokens wasted

An agent-id is the subagent transcript's filename minus "agent-"/".jsonl" (same id efficiency.py prints in
by_agent). Transcripts live under ~/.claude/projects/*PowOS*/**/*.jsonl (efficiency.py's glob) - most under
<project>/<session>/subagents/agent-<id>.jsonl. Reuses efficiency.py's CATS/cat_of so a category means the
same thing in both tools.

Prints a <=60-line digest: permission refusals, tool errors grouped by cause, retries/loops, information
hunts (read/grep/find runs before the first edit, files re-read 3+ times), waits/long sleeps, checks that
misled it (FAIL then "not a real failure"), and friction it logged (+ whether fixed, best-effort against
the board). Each item gets a suggested fix target. Never prints a raw token/secret - see `redact()`.
"""
import argparse, collections, datetime as dt, glob, json, os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import efficiency as eff  # CATS, cat_of, TOOL_CAT - one categorization, shared with efficiency.py

ROOT = os.path.expanduser('~/.claude/projects')
MAX_LINES = 60

SECRET_RE = re.compile(
    r'sk-ant-[A-Za-z0-9_-]{16,}|AIza[A-Za-z0-9_-]{20,}|eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}'
    r'|Bearer\s+[A-Za-z0-9._-]{12,}|ghp_[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}')
PERM_RE = re.compile(r'Permission for this (?:action|command) was denied|denied by (?:the Claude Code auto mode '
                     r'classifier|a built-in Claude Code safety check|the user)')
MISLED_RE = re.compile(r'not a real (?:failure|fail|bug|regression)|false positive|false alarm|'
                       r"flaky,? not(?: a)? real|turns out (?:it|that)(?: was)?n?'?t? (?:a )?(?:real )?(?:fail|broken)")
SLEEP_RE = re.compile(r'\bsleep\s+(\d+)\b')
FRICTION_ADD_RE = re.compile(r'\bfriction add\b')


def redact(s):
    return SECRET_RE.sub('[REDACTED]', s or '')


def text_of(content):
    """A tool_result's `content` field, as one redacted string (it's either a string or a list of blocks)."""
    if isinstance(content, str):
        return redact(content)
    if isinstance(content, list):
        parts = [b.get('text', '') for b in content if isinstance(b, dict) and b.get('type') == 'text']
        return redact('\n'.join(parts))
    return ''


def short_cmd(tool):
    if tool['name'] == 'Bash':
        return redact((tool.get('input') or {}).get('command', ''))[:160]
    inp = tool.get('input') or {}
    key = inp.get('file_path') or inp.get('path') or inp.get('pattern') or inp.get('url') or ''
    return f"{tool['name']} {redact(str(key))[:140]}".strip()


def norm_cmd(tool):
    """Collapse a command to compare retries - strip quoted/hex/numeric noise."""
    s = short_cmd(tool)
    return re.sub(r'[0-9a-f]{6,}|\d+', '#', s)


def load(path):
    """One pass over the transcript: tool_use calls (in order) joined to their tool_result, plus raw text
    events for the misled-check scan. Returns (calls, raw_texts) - calls is a list of dicts."""
    pending = {}  # tool_use id -> call dict (name, input, msg_id, ctx)
    calls = []
    raw_texts = []
    msg_ctx = {}
    with open(path, errors='replace') as f:
        for line in f:
            try:
                e = json.loads(line)
            except ValueError:
                continue
            etype = e.get('type')
            m = e.get('message') or {}
            if etype == 'assistant':
                u = m.get('usage') or {}
                ctx = u.get('input_tokens', 0) + u.get('cache_read_input_tokens', 0) + u.get('cache_creation_input_tokens', 0)
                mid = m.get('id')
                msg_ctx[mid] = ctx
                for x in m.get('content') or []:
                    if not isinstance(x, dict):
                        continue
                    if x.get('type') == 'text':
                        raw_texts.append(redact(x.get('text', ''))[:4000])
                    elif x.get('type') == 'tool_use':
                        c = {'id': x.get('id'), 'name': x.get('name'), 'input': x.get('input') or {},
                             'msg_id': mid, 'ctx': ctx, 'is_error': None, 'result': ''}
                        pending[x.get('id')] = c
                        calls.append(c)
            elif etype == 'user':
                content = m.get('content')
                if isinstance(content, list):
                    for x in content:
                        if isinstance(x, dict) and x.get('type') == 'tool_result':
                            c = pending.get(x.get('tool_use_id'))
                            if c is not None:
                                c['is_error'] = bool(x.get('is_error'))
                                c['result'] = text_of(x.get('content'))
    for c in calls:  # ctx already set per message id
        c['ctx'] = msg_ctx.get(c['msg_id'], c['ctx'])
    return calls, raw_texts


def cause_of(result):
    """A short, grouped cause for a non-permission error."""
    r = result.strip().splitlines()[0] if result.strip() else '(no output)'
    for pat, name in [
        (r'[Nn]o such file or directory', 'no such file or directory'),
        (r'command not found', 'command not found'),
        (r'[Pp]ermission denied', 'permission denied (os)'),
        (r'[Cc]onflict', 'merge/rebase conflict'),
        (r'[Tt]imed? ?out', 'timeout'),
        (r'[Rr]efused', 'refused by script'),
        (r'is not a git', 'not a git repo'),
        (r'[Ee]xit code (\d+)', 'non-zero exit'),
    ]:
        if re.search(pat, r):
            return name
    return r[:80]


def suggest(kind, detail=''):
    d = detail.lower()
    if kind == 'permission':
        return 'skill: fewer-permission-prompts (allowlist), or update-config if it should just be allowed'
    if kind == 'error':
        if 'git' in d or 'rebase' in d or 'conflict' in d:
            return 'handbook: Shared checkouts / Git sync section'
        if 'no such file' in d or 'not found' in d:
            return 'script/doc: path drifted - fix the script or the doc that named it'
        return 'script: make the command fail with a clearer message, or add to its --help'
    if kind == 'retry':
        return 'script: make the command idempotent, or document why it needs a retry'
    if kind == 'info-hunt':
        return 'skill or handbook "Where things live": add the line so the next agent does not re-hunt'
    if kind == 'wait':
        return 'handbook: Efficiency section (land.sh/queue.sh instead of polling)'
    if kind == 'misled':
        return 'gate/check script: fix the FAIL message so it says this up front'
    if kind == 'friction-open':
        return 'staff as a friction cluster fix (powos friction fix once landed)'
    return '--help: the command should explain this itself'


def friction_logged(calls):
    """Bash calls that logged friction (powos friction add / tools/agents/friction add)."""
    out = []
    for c in calls:
        if c['name'] != 'Bash':
            continue
        cmd = (c.get('input') or {}).get('command', '')
        if FRICTION_ADD_RE.search(cmd):
            m = re.search(r'"([^"]{3,160})"', cmd)
            out.append(m.group(1) if m else redact(cmd)[:120])
    return out


def board_fixed_status(titles, timeout=3):
    """Best-effort: ask the board which of these titles are already fixed. Never fails the digest."""
    if not titles:
        return {}
    cli = os.path.join(HERE, '..', '..', 'lib', 'ai', 'agents', 'powos-agents-cli')
    try:
        out = subprocess.run(['python3', cli, 'friction', 'list', '--all', '--json'],
                              capture_output=True, text=True, timeout=timeout)
        if out.returncode != 0:
            return {}
        rows = json.loads(out.stdout)
    except Exception:
        return {}
    status = {}
    for t in titles:
        key = t.strip()[:160]
        row = next((r for r in rows if r.get('title', '').strip()[:160] == key), None)
        status[t] = (row or {}).get('status', 'unknown (not logged)')
    return status


def analyze(path, since=''):
    calls, raw_texts = load(path)
    for c in calls:
        c['cat'] = eff.cat_of(c)

    permissions = collections.Counter()
    perm_examples = {}
    errors = collections.Counter()
    err_examples = {}
    cmd_seen = collections.Counter()
    cmd_example = {}
    reads_per_file = collections.Counter()
    waits = []
    long_sleeps = []
    first_edit_idx = next((i for i, c in enumerate(calls) if c['cat'] == 'edit'), len(calls))
    hunt_before_edit = sum(1 for c in calls[:first_edit_idx] if c['cat'] == 'read')

    wasted_tokens = 0
    for c in calls:
        if c['name'] == 'Bash':  # "retries" means the same command, not every repeated tool (SendMessage etc.)
            key = norm_cmd(c)
            cmd_seen[key] += 1
            cmd_example.setdefault(key, short_cmd(c))
        if c['name'] == 'Read':
            fp = (c.get('input') or {}).get('file_path', '')
            if fp:
                reads_per_file[fp] += 1
        if c['cat'] == 'wait/poll':
            waits.append(c)
            wasted_tokens += c['ctx']
            m = SLEEP_RE.search((c.get('input') or {}).get('command', ''))
            if m and int(m.group(1)) >= 60:
                long_sleeps.append(c)
        if c['is_error']:
            if PERM_RE.search(c['result']):
                permissions[short_cmd(c)] += 1
                perm_examples.setdefault(short_cmd(c), c['result'][:200])
                wasted_tokens += c['ctx']
            else:
                cause = cause_of(c['result'])
                errors[cause] += 1
                err_examples.setdefault(cause, short_cmd(c))
                wasted_tokens += c['ctx']

    retries = [(cmd_example[k], n) for k, n in cmd_seen.items() if n >= 2 and k.strip()]
    retries.sort(key=lambda x: -x[1])
    retry_keys = {k for k, n in cmd_seen.items() if n >= 2}
    wasted_tokens += sum(c['ctx'] for c in calls if c['name'] == 'Bash' and norm_cmd(c) in retry_keys)

    reread_files = [(f, n) for f, n in reads_per_file.items() if n >= 3]
    reread_files.sort(key=lambda x: -x[1])

    misled = []
    joined = '\n'.join(raw_texts)
    if MISLED_RE.search(joined):
        for m in MISLED_RE.finditer(joined):
            snippet = joined[max(0, m.start() - 60):m.end() + 20].replace('\n', ' ')
            misled.append(snippet.strip())

    fr_titles = friction_logged(calls)
    fr_status = board_fixed_status(fr_titles)

    tot_ctx = sum(c['ctx'] for c in {c['msg_id']: c for c in calls}.values()) or 0
    return {
        'path': path, 'calls': len(calls), 'ctx_tokens': tot_ctx, 'wasted_tokens': wasted_tokens,
        'permissions': permissions.most_common(8), 'perm_examples': perm_examples,
        'errors': errors.most_common(8), 'err_examples': err_examples,
        'retries': retries[:8],
        'hunt_before_edit': hunt_before_edit, 'first_edit_idx': first_edit_idx,
        'reread_files': reread_files[:8],
        'waits': len(waits), 'long_sleeps': [short_cmd(c) for c in long_sleeps],
        'misled': misled[:5],
        'friction': [{'title': t, 'status': fr_status.get(t, 'unknown')} for t in fr_titles],
    }


def render(d, lines_budget=MAX_LINES):
    out = [f"retro: {os.path.basename(d['path'])} - {d['calls']} calls, {d['ctx_tokens']//1000}k context, "
           f"~{d['wasted_tokens']//1000}k wasted on friction"]
    if d['permissions']:
        out.append("permission refusals:")
        for cmd, n in d['permissions']:
            out.append(f"  x{n}  {cmd}  -> {suggest('permission')}")
    if d['errors']:
        out.append("tool errors by cause:")
        for cause, n in d['errors']:
            out.append(f"  x{n}  {cause}  (e.g. {d['err_examples'][cause]})  -> {suggest('error', cause)}")
    if d['retries']:
        out.append("retries (same command 2+ times):")
        for cmd, n in d['retries']:
            out.append(f"  x{n}  {cmd}  -> {suggest('retry')}")
    if d['hunt_before_edit'] >= 5:
        out.append(f"information hunt: {d['hunt_before_edit']} read/grep/find calls before the first edit "
                    f"(of {d['first_edit_idx']} calls)  -> {suggest('info-hunt')}")
    if d['reread_files']:
        out.append("files read 3+ times:")
        for f, n in d['reread_files']:
            out.append(f"  x{n}  {f}  -> {suggest('info-hunt')}")
    if d['waits']:
        out.append(f"waits/polls: {d['waits']} call(s)" + (f", long sleeps: {', '.join(d['long_sleeps'][:3])}" if d['long_sleeps'] else '')
                    + f"  -> {suggest('wait')}")
    if d['misled']:
        out.append("checks that misled it (FAIL, then \"not a real failure\"):")
        for s in d['misled']:
            out.append(f"  ...{s}...  -> {suggest('misled')}")
    if d['friction']:
        out.append("friction it logged:")
        for f in d['friction']:
            tag = suggest('friction-open') if f['status'] not in ('fixed',) else 'fixed'
            out.append(f"  [{f['status']}] {f['title'][:90]}  -> {tag}")
    if len(out) == 1:
        out.append("no friction found - clean run")
    return out[:lines_budget]


def find_transcript(ref):
    if os.path.isfile(ref):
        return ref
    cands = [c for c in glob.glob(os.path.join(ROOT, '*PowOS*', '**', '*.jsonl'), recursive=True)
              if os.path.basename(c)[:-6].replace('agent-', '') == ref]
    if not cands:
        cands = [c for c in glob.glob(os.path.join(ROOT, '*PowOS*', '**', f'*{ref}*.jsonl'), recursive=True)]
    if not cands:
        raise SystemExit(f"retro.py: no transcript found for {ref!r} under {ROOT}")
    cands.sort(key=os.path.getmtime, reverse=True)
    return cands[0]


def since_all(since_arg):
    since = (dt.datetime.now(dt.timezone.utc) - parse_dur(since_arg)).strftime('%Y-%m-%dT%H:%M') if since_arg else \
        (dt.datetime.now(dt.timezone.utc) - dt.timedelta(hours=4)).strftime('%Y-%m-%dT%H:%M')
    files = glob.glob(os.path.join(ROOT, '*PowOS*', '**', '*.jsonl'), recursive=True)
    digests = []
    for f in files:
        if os.path.getmtime(f) < dt.datetime.strptime(since, '%Y-%m-%dT%H:%M').timestamp():
            continue
        try:
            d = analyze(f, since)
        except Exception:
            continue
        if d['calls']:
            digests.append(d)
    digests.sort(key=lambda d: -d['wasted_tokens'])
    return digests, since


def parse_dur(s):
    m = re.match(r'(\d+)\s*([hHdDmM])$', s.strip())
    if not m:
        raise SystemExit(f"retro.py: bad --since {s!r} (use e.g. 4h, 2d, 30m)")
    n, u = int(m.group(1)), m.group(2).lower()
    return dt.timedelta(hours=n) if u == 'h' else dt.timedelta(days=n) if u == 'd' else dt.timedelta(minutes=n)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('ref', nargs='?')
    ap.add_argument('--since')
    ap.add_argument('--all', action='store_true')
    ap.add_argument('--json', action='store_true')
    a = ap.parse_args()

    if a.all:
        digests, since = since_all(a.since)
        if a.json:
            json.dump({'since': since, 'agents': digests}, sys.stdout, indent=1); print(); return
        lines = [f"retro --since {a.since or '4h'}: {len(digests)} agent(s), ranked by tokens wasted on friction"]
        for d in digests[:12]:
            lines.append(f"-- {os.path.basename(d['path'])}: ~{d['wasted_tokens']//1000}k wasted")
            lines += ['   ' + l for l in render(d, 6)[1:]]
        for l in lines[:MAX_LINES]:
            print(l)
        return

    if not a.ref:
        ap.error('give an agent-id or transcript path, or --since/--all')
    path = find_transcript(a.ref)
    d = analyze(path, a.since or '')
    if a.json:
        json.dump(d, sys.stdout, indent=1); print(); return
    for l in render(d):
        print(l)


if __name__ == '__main__':
    main()
