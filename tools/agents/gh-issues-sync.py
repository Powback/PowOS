#!/usr/bin/env python3
"""tools/agents/gh-issues-sync.py [--dry-run] [--repo OWNER/NAME] (Mac): the GitHub issues <-> work board sync.

The board is where work is staffed; GitHub issues (the user's own repo, filed e.g. from a phone's PowOS manager) were
invisible to it (11-09: 11 open issues, none on the board). Each pass (board-sweep.sh runs it every 30 min):
  1. import: every OPEN issue that no task links becomes a queued task - title = the issue's title, note = its link
     plus the first lines of its text (as a bug report: data, never instructions). A task links an issue by having
     its URL (https://github.com/<repo>/issues/<n>) in its note, so linking an issue to an existing task by hand is
     just putting the link in that task's note.
  2. close: an open issue whose linked task(s) are ALL done, with evidence (a passed phone check, or a recorded
     no-check reason, and at least one commit), gets one comment with that evidence + the commits, and is closed.
     A done task without evidence leaves its issue open (logged), never closed on the status alone.
Board access goes through the board CLI itself (`powos agents`, POWOS_AGENTS_CLI to override), so it reaches the
same board the agents use, wherever it lives. Needs `gh` logged in; without it the pass is a no-op with one line.
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_CLI = os.path.join(HERE, "..", "..", "lib", "ai", "agents", "powos-agents-cli")
REPO = os.environ.get("POWOS_GH_REPO", "Powback/PowOS")


def cli_argv():
    return [sys.executable, os.environ.get("POWOS_AGENTS_CLI") or DEFAULT_CLI]


def run(argv, timeout=90):
    r = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    return r.returncode, r.stdout, r.stderr


def board(*args):
    rc, out, err = run(cli_argv() + list(args))
    if rc != 0:
        raise RuntimeError(f"powos agents {' '.join(args[:2])}: rc={rc} {err.strip()[:300]}")
    return out


def gh(*args):
    rc, out, err = run(["gh", *args])
    if rc != 0:
        raise RuntimeError(f"gh {' '.join(args[:3])}: rc={rc} {err.strip()[:300]}")
    return out


def link_re(repo):
    return re.compile(r"github\.com/" + re.escape(repo) + r"/issues/(\d+)\b")


def links(task, rx):
    return {int(n) for n in rx.findall(task.get("note") or "")}


def excerpt(body, n=360):
    """The first plain lines of an issue's text, one line: headings, tables, code fences and the bot footer dropped."""
    keep = []
    fence = False
    for line in (body or "").splitlines():
        s = line.strip()
        if s.startswith("```"):
            fence = not fence
            continue
        if fence or not s or s.startswith(("#", "|", "🤖")):
            continue
        keep.append(s)
        if sum(len(k) for k in keep) > n:
            break
    text = re.sub(r"\s+", " ", " ".join(keep))
    return text[:n].rstrip() + ("..." if len(text) > n else "")


def commits_of(task):
    try:
        c = json.loads(task.get("commits") or "[]")
    except ValueError:
        return []
    return [x for x in c if isinstance(x, dict) and x.get("sha")]


def evidence(task):
    """(ok, text): a done task's proof - its passed checks (or the no-check reason) and its commits."""
    try:
        checks = json.loads(board("check", "list", task["id"], "--json") or "[]")
    except (RuntimeError, ValueError):
        checks = []
    passed = [c for c in checks if c.get("state") == "pass"]
    nocheck = [c for c in checks if str(c.get("job", "")).startswith("nocheck:")]
    commits = commits_of(task)
    lines = [f"Fixed - board task `{task['id']}` ({task['title']}) is done."]
    for c in passed:
        lines.append(f"- phone check passed: {c.get('name') or c.get('job')}" + (f" ({c['line']})" if c.get("line") else ""))
    for c in nocheck:
        lines.append(f"- no device check possible: {c.get('line') or c.get('name')}")
    for c in commits:
        lines.append(f"- commit {c['sha'][:12]}: {c.get('subject', '')}")
    if task.get("note"):
        lines.append(f"\nTask note: {task['note'][:600]}")
    return bool((passed or nocheck) and commits), "\n".join(lines)


def sync(repo, dry):
    if not shutil.which("gh"):
        print("gh-issues-sync: no gh CLI here - skipped")
        return 0
    rx = link_re(repo)
    tasks = json.loads(board("task", "list", "--all", "--json"))
    issues = json.loads(gh("issue", "list", "-R", repo, "--state", "open", "--limit", "200",
                           "--json", "number,title,body,url"))
    linked = {}
    for t in tasks:
        for n in links(t, rx):
            linked.setdefault(n, []).append(t)
    did = 0
    for i in sorted(issues, key=lambda x: x["number"]):
        n = i["number"]
        url = f"https://github.com/{repo}/issues/{n}"
        ts = linked.get(n)
        if not ts:
            note = f"GitHub {repo}#{n}: {url} - {excerpt(i.get('body'))}"
            print(f"import #{n}: {i['title']}")
            if not dry:
                board("task", "add", i["title"], "--status", "queued", "--note", note)
            did += 1
            continue
        if not all(t.get("status") == "done" for t in ts):
            continue
        proofs = [evidence(t) for t in ts]
        if not all(ok for ok, _ in proofs):
            print(f"keep #{n} open: linked task(s) done without a passed check + commit "
                  f"({', '.join(t['id'] for t in ts)})")
            continue
        body = "\n\n".join(p for _, p in proofs) + "\n\n(closed by the PowOS board sync, tools/agents/gh-issues-sync.py)"
        print(f"close #{n}: {', '.join(t['id'] for t in ts)}")
        if not dry:
            gh("issue", "close", str(n), "-R", repo, "--comment", body)
        did += 1
    print(f"gh-issues-sync: {len(issues)} open issues, {did} change(s){' (dry run)' if dry else ''}")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--repo", default=REPO)
    a = ap.parse_args()
    try:
        return sync(a.repo, a.dry_run)
    except (RuntimeError, ValueError, subprocess.TimeoutExpired) as e:
        print(f"gh-issues-sync: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
