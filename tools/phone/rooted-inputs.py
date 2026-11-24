#!/usr/bin/env python3
"""rooted-inputs.py - the repo paths `targets/android/rooted/rooted.sh deploy` puts on the phone, derived from the
deploy itself (ship.sh's rooted_inputs diffs exactly these, so a change to any of them starts a rooted deploy).

Why derived: ship.sh kept a hand list, and it fell behind what the deploy installs - lib/devices (fixed efcf8483) and
most of lib/apps (11-24: the Steam stall fix a27864d4 in lib/apps/powos-sleep-gui would never have shipped).

How: every `adb push` in rooted.sh's `deploy)` block is resolved to its repo source ($HERE, loop lists, simple
assignments; generated files through GENERATED below). A pushed FILE counts as is. A pushed DIRECTORY counts only for
what targets/android/rooted/powos-deploy.sh installs from its staged copy (`$T/<dest>/<path>`, aliases like
A=$T/powos-apps, `for f in ...` lists expanded): lib/apps/powos-noroot-services (the APK's) is staged with lib/apps but
never installed, so it doesn't start a rooted deploy. The two deploy scripts themselves always count.

A push this can't resolve is an error (exit 1), never a silent gap: add the variable to GENERATED.

Usage:  rooted-inputs.py [--rev REV] [--files]
  --rev REV   read the scripts and the tree at commit REV (default/empty: the working tree)
  --files     print the concrete files covered (for the tier-1 test) instead of git pathspecs
"""
import fnmatch
import os
import posixpath
import re
import shlex
import subprocess
import sys

ROOT = os.path.realpath(os.path.join(os.path.dirname(__file__), "..", ".."))
ROOTED = "targets/android/rooted"
SCRIPTS = [f"{ROOTED}/rooted.sh", f"{ROOTED}/powos-deploy.sh"]
# Pushed variables holding a file rooted.sh generates or picks at deploy time -> the repo paths it comes from.
GENERATED = {
    "stdb": ["targets/android/pkgs"],     # out/pkgs packages, built by ship.sh's "pkgs" step from these PKGBUILDs
    "xwl": ["targets/android/pkgs"],
    "kw": ["targets/android/pkgs"],
    "sbx_tgz": ["lib/ai/sandbox"],        # sandbox_bundle (node_modules excluded by ship.sh)
    "gc": ["tools/phone/owner.json"],     # the ship gate's url
    "oc": ["tools/phone/owner.json", "lib/devices/powos-deviced"],  # owner.conf, rendered by owner-apply
    "gs": [],                             # the ship gate's secret (~/.config, not the repo)
    "src_tar": [],                        # git archive HEAD: seeds /var/lib/powos/src only when absent
}
# Build outputs a push reads -> their sources.
OUT = {"apps/composed/out": "apps/composed/module", "apps/registry/out": "apps/registry/module",
       "targets/android/out/pkgs": "targets/android/pkgs"}
# Commands that take a staged path wholesale: `cp -r $A/composed ...` installs all of what was pushed under it.
COPY = ("cp", "install", "tar", "mv", "rsync")


class Tree:
    def __init__(self, rev):
        self.rev = rev
        if rev:
            out = subprocess.run(["git", "-C", ROOT, "ls-tree", "-r", "--name-only", rev], check=True,
                                 capture_output=True, text=True).stdout
            self.files = out.split()
        else:
            self.files = []
            for d, dirs, fs in os.walk(ROOT):
                dirs[:] = [x for x in dirs if x not in (".git", "node_modules", "out")]
                rel = os.path.relpath(d, ROOT)
                self.files += [f if rel == "." else f"{rel}/{f}" for f in fs]
        self.fileset = set(self.files)

    def read(self, path):
        if self.rev:
            return subprocess.run(["git", "-C", ROOT, "show", f"{self.rev}:{path}"], check=True,
                                  capture_output=True, text=True).stdout
        with open(os.path.join(ROOT, path)) as f:
            return f.read()

    def match(self, spec):
        """Files a git pathspec (prefix or fnmatch glob) covers."""
        if any(c in spec for c in "*?["):
            return [f for f in self.files if fnmatch.fnmatchcase(f, spec)]
        return [f for f in self.files if f == spec or f.startswith(spec + "/")]

    def is_dir(self, path):
        return path not in self.fileset and any(f.startswith(path + "/") for f in self.files)


def joined(text):
    """Lines with backslash continuations joined, comments dropped."""
    out, cur = [], ""
    for line in text.split("\n"):
        s = line.rstrip()
        if s.lstrip().startswith("#"):
            s = ""
        if s.endswith("\\"):
            cur += s[:-1] + " "
            continue
        out.append(cur + s)
        cur = ""
    return out


FOR = re.compile(r"\bfor (\w+) in ([^;]*?); do\b")


def deploy_block(lines):
    start = next(i for i, l in enumerate(lines) if re.match(r"^deploy\)", l))
    end = next((i for i in range(start + 1, len(lines)) if re.match(r"^[a-z][a-z0-9|-]*\)\s*$", lines[i])), len(lines))
    return lines[start:end]


def pushes(tree):
    """[(source repo path or None, dest under /data/local/tmp)] for every push in rooted.sh deploy."""
    lines = joined(tree.read(f"{ROOTED}/rooted.sh"))
    block = deploy_block(lines)
    assign, loops, res, errors = {}, {}, [], []
    for line in block:
        for m in re.finditer(r"(?:^|[\s;(])(\w+)=\"?(\$HERE/[^\"\s;)]*)", line):
            assign[m.group(1)] = m.group(2)
        for m in FOR.finditer(line):
            loops[m.group(1)] = m.group(2).split()
        for seg in re.split(r"&&|\|\||;", line):
            m = re.search(r"\badb push\b(.*)", seg)
            if not m:
                continue
            args = [a for a in shlex.split(m.group(1)) if not a.startswith("-")]
            args = [a for a in args if not re.match(r"^\d*>", a)]
            *srcs, dest = args
            for src in srcs:
                res += [(s, dest) for s in resolve(src, assign, loops, errors)]
    return res, errors


def resolve(src, assign, loops, errors):
    """A push source -> repo paths ([] for a generated file with no repo source)."""
    m = re.match(r"^\$\{?(\w+)\}?(/.*)?$", src)
    if m and m.group(1) != "HERE":
        var, rest = m.group(1), m.group(2) or ""
        if var in assign:
            return resolve(assign[var] + rest, assign, loops, errors)
        if var in GENERATED:
            return ["=" + g for g in GENERATED[var]]   # "=": counts whole, never narrowed
        errors.append(f"rooted.sh deploy pushes {src}: unknown source (add it to GENERATED in tools/phone/rooted-inputs.py)")
        return []
    if not src.startswith("$HERE"):
        errors.append(f"rooted.sh deploy pushes {src}: not under $HERE")
        return []
    paths = [src]
    for var, vals in loops.items():
        if f"${var}" in src:
            paths = [p.replace(f"${var}", v) for p in paths for v in vals]
    out = []
    for p in paths:
        if "$" in p.replace("$HERE", ""):
            errors.append(f"rooted.sh deploy pushes {src}: unresolved variable")
            continue
        p = posixpath.normpath(p.replace("$HERE", ROOTED))
        for o, s in OUT.items():
            if p == o or p.startswith(o + "/"):
                p = "=" + s   # a build output: its sources count whole
        out.append(p)
    return out


def installed(tree, staged):
    """Paths under /data/local/tmp/<staged> that powos-deploy.sh installs (relative), or ['.'] when it copies the whole
    staged path (`cp -a $T/<staged>/.`, `for f in $T/<staged>/*`, or a copy of it or of a parent: `cp -r $A/composed`)."""
    loops, rels, alias = {}, set(), {}
    for line in joined(tree.read(f"{ROOTED}/powos-deploy.sh")):
        # Aliases of staged paths (A=$T/powos-apps), as of this line: a variable is reassigned later (A, U).
        for m in re.finditer(r"(?:^|[\s;])(\w+)=(\S*)", line):
            t = re.match(r"^\$T/([\w./-]+)$", m.group(2))
            alias.pop(m.group(1), None)
            if t:
                alias[m.group(1)] = t.group(1)
        for var, path in alias.items():
            line = re.sub(r"\$\{?" + var + r"\b\}?", f"$T/{path}", line)
        for m in FOR.finditer(line):
            loops[m.group(1)] = m.group(2).split()
        for seg in re.split(r"&&|\|\||;|\bthen\b|\bdo\b", line):
            words = seg.split()
            copy = bool(words) and words[0] in COPY
            for m in re.finditer(r"\$T/([^\s\"';)]+)", seg):
                refs = [m.group(1)]
                for var, vals in loops.items():
                    if any(f"${var}" in r for r in refs):
                        refs = [r.replace(f"${var}", v) for r in refs for v in vals]
                for r in refs:
                    r = r.rstrip("/")
                    if copy and (r == staged or staged.startswith(r + "/")):
                        rels.add(".")
                    elif r.startswith(staged + "/"):
                        rel = r[len(staged) + 1:]
                        rels.add("." if rel in (".", "*") else rel)
    return sorted(rels)


def inputs(rev=""):
    tree = Tree(rev)
    res, errors = pushes(tree)
    specs = set(SCRIPTS)
    for src, dest in res:
        if not dest.startswith("/data/local/tmp/"):
            errors.append(f"rooted.sh deploy pushes {src} to {dest}: not under /data/local/tmp")
            continue
        staged = dest[len("/data/local/tmp/"):]
        if src.startswith("="):
            specs.add(src[1:])
            continue
        if not tree.is_dir(src) or "*" in src:
            specs.add(src)
            continue
        if staged.endswith("/") or not staged:
            staged += posixpath.basename(src)
        rels = installed(tree, staged.rstrip("/"))
        if "." in rels:
            specs.add(src)
            continue
        for r in rels:
            spec = f"{src}/{r}"
            if tree.match(spec):
                specs.add(spec)
    return sorted(specs), errors, tree


def main():
    args = sys.argv[1:]
    rev = ""
    if "--rev" in args:
        rev = args[args.index("--rev") + 1]
    specs, errors, tree = inputs(rev)
    for e in errors:
        print(f"rooted-inputs: {e}", file=sys.stderr)
    if errors:
        return 1
    if "--files" in args:
        print("\n".join(sorted({f for s in specs for f in tree.match(s)})))
    else:
        print("\n".join(specs))
    return 0


if __name__ == "__main__":
    sys.exit(main())
