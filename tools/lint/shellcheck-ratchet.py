#!/usr/bin/env python3
"""shellcheck over EVERY tracked shell script, as a ratchet (like build/complexity-budget.txt).

CI's old step linted bin/, lib/, build/ and sources/ only (142 of ~870 scripts) and at error level only. This lints
every tracked *.sh plus every extensionless tracked file with a sh/bash shebang, at warning level (errors + warnings).
The old debt is frozen per file and per code in tools/lint/shellcheck-baseline.txt ("<file> <SCxxxx> <count>"):

  - a finding whose (file, code) count is above the baseline fails (a new finding, or a file that got worse);
  - an entry above its current count fails until pruned (--prune), so the baseline follows every fix down;
  - an entry above the same entry at the reference commit fails (the baseline only goes down). The reference is the
    merge base with origin/main, or HEAD^ when HEAD is on it (CI on main). A commit whose message says
    "[baseline-reset]" and why may raise it deliberately (a rename, a pinned shellcheck upgrade).

The shellcheck is pinned (SC_VERSION): CI and the tier-1 image (Ubuntu 24.04) ship it, the Mac has none, so the
koalaman/shellcheck-alpine image of that version runs it there through docker with the repo mounted at its own path. Another
version reports different findings, so it is never used silently. $SHELLCHECK overrides the command.

  tools/lint/shellcheck-ratchet.py [--root DIR] [--check] [FILE...]   # default: every shell file
  tools/lint/shellcheck-ratchet.py --prune     # lower entries to the current counts (never raises one)
  tools/lint/shellcheck-ratchet.py --report    # print the current counts per code and per file, no verdict
  tools/lint/shellcheck-ratchet.py --write     # regenerate the whole baseline (needs [baseline-reset] if it rises)

Exit 0 ok, 1 a finding / a stale or raised entry, 2 skipped (GATE_LINT=0) or no usable shellcheck.
"""
import os
import re
import shlex
import shutil
import subprocess
import sys
from collections import Counter
from concurrent.futures import ThreadPoolExecutor

SC_VERSION = "0.9.0"
BASELINE = "tools/lint/shellcheck-baseline.txt"
SHEBANG = re.compile(rb"^#!\s*\S*?(?:/env\s+(?:-\S+\s+)*)?\S*?\b(?:ba|da|k|mk)?sh\b")
# Lint fixtures: shell that is bad ON PURPOSE (tools/agents/shell-pitfalls.py's test cases; changed-lints.sh skips them
# for the pitfalls lint too). Linting them only counted deliberate findings, and every new fixture tripped CI.
LINT_FIXTURES = ("test/tier1/fixtures/shell-pitfalls/",)
FINDING = re.compile(r"^(.+?):(\d+):(\d+): (error|warning): (.*) \[(SC\d+)\]$")


def git(root, *a):
    return subprocess.run(["git", "-C", root, *a], capture_output=True, text=True)


def shell_files(root):
    """Every tracked *.sh, plus extensionless tracked files whose first line is a sh/bash shebang."""
    out = []
    for f in git(root, "ls-files", "-z").stdout.split("\0"):
        p = os.path.join(root, f)
        if not f or not os.path.isfile(p) or os.path.islink(p) or f.startswith(LINT_FIXTURES):
            continue
        base = os.path.basename(f)
        if f.endswith(".sh"):
            out.append(f)
        elif "." not in base:
            with open(p, "rb") as fh:
                if SHEBANG.match(fh.readline(200)):
                    out.append(f)
    return sorted(out)


def shellcheck_cmd(root):
    """(command, batched): batched commands take a list of files and check them ONE AT A TIME themselves."""
    env = os.environ.get("SHELLCHECK")
    if env:
        return shlex.split(env), False
    sc = shutil.which("shellcheck")
    if sc:
        v = subprocess.run([sc, "--version"], capture_output=True, text=True).stdout
        if re.search(r"^version: " + re.escape(SC_VERSION) + r"$", v, re.M):
            return [sc], False
    docker = shutil.which("docker")
    if docker and subprocess.run([docker, "version"], capture_output=True).returncode == 0:
        return [docker, "run", "--rm", "-v", f"{root}:{root}", "-w", root, f"koalaman/shellcheck-alpine:v{SC_VERSION}",
                "sh", "-c", 'for f; do [ -f "$f" ] || { echo "$f: not visible in the container" >&2; exit 3; }; '
                'shellcheck -S warning -f gcc "$f"; done; exit 0', "sh"], True
    return None, False


def run_shellcheck(root, cmd, batched, files):
    """All (file, code) findings at warning level.

    Every file is its own shellcheck run: given several files at once, shellcheck uses the others to resolve `source`
    lines, so a file's findings would depend on which files share its run (test-sync.sh: 1 SC2034 in the full list,
    3 alone) and a pre-push run of the changed files would disagree with CI's full run.
    """
    batches = [files[i:i + 40] for i in range(0, len(files), 40)] if batched else [[f] for f in files]
    args = [] if batched else ["-S", "warning", "-f", "gcc"]

    def one(batch):
        r = subprocess.run(cmd + args + batch, cwd=root, capture_output=True, text=True)
        # A path docker could not mount (outside the VM's shared folders) is an empty dir there: exit 3, never 0 findings.
        if r.returncode not in (0, 1):
            raise RuntimeError(f"shellcheck rc {r.returncode}: {(r.stderr or r.stdout).strip()[:300]}")
        return [m.groups() for m in map(FINDING.match, r.stdout.splitlines()) if m]

    found = Counter()
    lines = {}
    with ThreadPoolExecutor(max_workers=4 if batched else (os.cpu_count() or 4)) as ex:
        for res in ex.map(one, batches):
            for f, ln, _col, sev, msg, code in res:
                found[(f, code)] += 1
                lines.setdefault((f, code), []).append(f"{f}:{ln}: {sev}: {msg} [{code}]")
    return found, lines


def load_baseline(text):
    b = {}
    for ln in (text or "").splitlines():
        ln = ln.strip()
        if not ln or ln.startswith("#"):
            continue
        f, code, n = ln.rsplit(None, 2)
        b[(f, code)] = int(n)
    return b


HEADER = ("# shellcheck warning-level findings per file and code - a RATCHET (tools/lint/shellcheck-ratchet.py).\n"
          "# It only goes down: fix a finding, then --prune. A new finding is fixed (or given a\n"
          "# '# shellcheck disable=SCxxxx  # why' directive), never added here.\n")


def save_baseline(root, b):
    with open(os.path.join(root, BASELINE), "w") as fh:
        fh.write(HEADER)
        for (f, code), n in sorted(b.items()):
            if n > 0:
                fh.write(f"{f} {code} {n}\n")


def ref_baseline(root):
    """The baseline at the reference commit, or None (no git history / first commit of the file)."""
    ref = os.environ.get("SHELLCHECK_BASELINE_REF")
    if not ref:
        head = git(root, "rev-parse", "HEAD").stdout.strip()
        mb = git(root, "merge-base", "HEAD", "origin/main").stdout.strip()
        ref = mb if mb and mb != head else "HEAD^"
    r = git(root, "show", f"{ref}:{BASELINE}")
    if r.returncode != 0:
        return None
    msgs = git(root, "log", "--format=%B", f"{ref}..HEAD").stdout
    msgs += os.environ.get("SHELLCHECK_COMMIT_MSG", "")
    if "[baseline-reset]" in msgs:
        return None
    return load_baseline(r.stdout)


def main(argv):
    root = os.getcwd()
    mode, files = "check", []
    it = iter(argv)
    for a in it:
        if a == "--root":
            root = next(it)
        elif a in ("--check", "--prune", "--report", "--write"):
            mode = a[2:]
        else:
            files.append(a)
    root = os.path.abspath(git(root, "rev-parse", "--show-toplevel").stdout.strip() or root)
    if os.environ.get("GATE_LINT", "1") == "0":
        print("     shellcheck: skipped (GATE_LINT=0)")
        return 2
    cmd, batched = shellcheck_cmd(root)
    if not cmd:
        print(f"FAIL shellcheck: no shellcheck {SC_VERSION} and no docker for koalaman/shellcheck-alpine:v{SC_VERSION} "
              "(GATE_LINT=0 skips it explicitly)")
        return 2
    every = shell_files(root)
    if files:
        known = set(every)
        files = sorted({os.path.relpath(os.path.abspath(f), root) for f in files} & known)
    else:
        files = every
    try:
        found, lines = run_shellcheck(root, cmd, batched, files) if files else (Counter(), {})
    except RuntimeError as e:
        print(f"FAIL shellcheck: {e}")
        return 1
    bpath = os.path.join(root, BASELINE)
    base = load_baseline(open(bpath).read()) if os.path.exists(bpath) else {}
    scope = set(files)

    if mode == "report":
        by_code = Counter()
        by_file = Counter()
        for (f, code), n in found.items():
            by_code[code] += n
            by_file[f] += n
        print(f"{sum(found.values())} findings in {len(by_file)} of {len(files)} files")
        for code, n in by_code.most_common():
            print(f"  {code} {n}")
        for f, n in by_file.most_common(30):
            print(f"  {n:5d} {f}")
        return 0
    if mode == "write":
        save_baseline(root, {k: v for k, v in base.items() if k[0] not in scope} | dict(found))
        print(f"wrote {BASELINE}: {sum(found.values())} findings, {len(found)} entries")
        return 0
    if mode == "prune":
        new = {k: (min(v, found.get(k, 0)) if k[0] in scope else v) for k, v in base.items()}
        new = {k: v for k, v in new.items() if k[0] in every}   # a removed or renamed file's entries go too
        save_baseline(root, new)
        print(f"pruned {BASELINE}: {sum(base.values())} -> {sum(v for v in new.values())}")
        return 0

    fail = 0
    for k, n in sorted(found.items()):
        was = base.get(k, 0)
        if n > was:
            what = "new finding" if was == 0 else f"{n} > baseline {was}"
            print(f"FAIL shellcheck: {k[0]} {k[1]}: {what}")
            for ln in lines[k][:5]:
                print(f"       {ln}")
            fail = 1
    for k, n in sorted(base.items()):
        if k[0] in scope or k[0] not in every:
            now = found.get(k, 0) if k[0] in every else 0
            if now < n:
                print(f"FAIL shellcheck: {k[0]} {k[1]}: paid off ({n} -> {now}) - "
                      "tools/lint/shellcheck-ratchet.py --prune and commit the baseline")
                fail = 1
    ref = ref_baseline(root)
    if ref is not None:
        for k, n in sorted(base.items()):
            if n > ref.get(k, 0):
                print(f"FAIL shellcheck: the baseline rose: {k[0]} {k[1]} {ref.get(k, 0)} -> {n} "
                      "(fix the finding; a deliberate raise needs [baseline-reset] in the commit message)")
                fail = 1
    if not fail:
        print(f"ok   shellcheck: {len(files)} files, {sum(found.values())} findings, none above the baseline")
    return fail


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
