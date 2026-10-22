#!/usr/bin/env python3
"""The complexity baselines only shrink - across history, not just against HEAD.

For every commit that changed shell/dev/complexity-baseline*.json, each file/rule count must be <= its parent's;
for targets/android/app/config/detekt-baseline.xml, no id may appear that its parent didn't have.
A commit may raise them only if its message says "[baseline-reset]" and why (a deliberate, visible reset - e.g. code
committed before the lint existed). Prints each violation; exit 1 if any.

  python3 shell/dev/complexity-history.py [REPO_ROOT]
"""
import json, re, subprocess, sys

root = sys.argv[1] if len(sys.argv) > 1 else "."
FILES = ["shell/dev/complexity-baseline.json", "shell/dev/complexity-baseline-apps.json"]


def git(*a):
    return subprocess.run(["git", "-C", root, *a], capture_output=True, text=True)


def load(rev, path):
    r = git("show", f"{rev}:{path}")
    return json.loads(r.stdout) if r.returncode == 0 and r.stdout.strip() else None


bad = 0
for path in FILES:
    for sha in git("log", "--format=%H", "--", path).stdout.split():
        if "[baseline-reset]" in git("log", "-1", "--format=%B", sha).stdout:
            continue
        new, old = load(sha, path), load(f"{sha}^", path)
        if new is None or old is None:  # added (the first baseline) or removed
            continue
        for f, rules in new.items():
            for r, v in rules.items():
                was, now = old.get(f, {}).get(r, {}).get("count", 0), v["count"]
                if now > was:
                    print(f"{sha[:8]} {path}: {f} {r}: {was} -> {now} (raised without [baseline-reset])")
                    bad += 1
KT = "targets/android/app/config/detekt-baseline.xml"
ids = lambda text: set(re.findall(r"<ID>(.*?)</ID>", text or ""))
for sha in git("log", "--format=%H", "--", KT).stdout.split():
    if "[baseline-reset]" in git("log", "-1", "--format=%B", sha).stdout:
        continue
    old = git("show", f"{sha}^:{KT}")
    if old.returncode != 0:
        continue  # the first baseline
    for i in sorted(ids(git("show", f"{sha}:{KT}").stdout) - ids(old.stdout)):
        print(f"{sha[:8]} {KT}: added {i} (without [baseline-reset])")
        bad += 1
sys.exit(1 if bad else 0)
