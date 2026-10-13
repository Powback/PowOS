#!/usr/bin/env python3
"""PowOS manifest (top-level RPMs) + phone-rules.conf + Arch's package list -> what the phone installs.

Usage: resolve-packages.py <leaves.tsv> <phone-rules.conf> <available.txt> <install.txt> <report.txt>
  available.txt: Arch package names one per line (pacman -Slq).
Writes the Arch packages to install, and a report of every RPM's fate (installed as / skipped / provided /
bundled / MISSING: no Arch package), MISSING first.
"""
import fnmatch
import re
import sys

leaves_f, rules_f, avail_f, install_f, report_f = sys.argv[1:6]
available = {l.strip() for l in open(avail_f) if l.strip()}

skips, skiparch, renames, rewrites, provides, bundles = [], {}, {}, [], [], set()
for raw in open(rules_f):
    line = raw.split("#", 1)[0].strip() if not raw.lstrip().startswith("#") else ""
    if not line:
        continue
    kind, rest = line.split(None, 1)
    if kind == "skip":
        # globs until the first token that is not a name/glob followed by the reason: globs are the tokens
        # before the reason; we treat every token containing no space as a glob and keep the line as reason.
        # "skip <glob> [<glob>...]   <reason>": the globs are the leading name-like tokens, up to the
        # first run of two or more spaces (the column gap) or the first token that isn't name-like.
        parts = re.split(r"\s{2,}", rest, maxsplit=1)
        head, reason = parts[0], parts[1] if len(parts) > 1 else ""
        globs = [t for t in head.split() if re.fullmatch(r"[A-Za-z0-9_.+*?\[\]-]+", t)]
        skips.append((globs, reason.strip() or head))
    elif kind == "skiparch":
        a, _, reason = rest.partition(" ")
        skiparch[a] = reason.strip()
    elif kind == "rename":
        toks = rest.split()
        renames[toks[0]] = toks[1:]
    elif kind == "rewrite":
        pat, repl = rest.split(None, 1)
        rewrites.append((re.compile(pat), repl.strip()))
    elif kind == "provide":
        toks = rest.split()
        provides.append((toks[0], " ".join(toks[1:])))
    elif kind == "bundle":
        bundles.add(rest.split()[0])

install, report = [], []
for line in open(leaves_f):
    if not line.strip():
        continue
    name, arch = (line.rstrip("\n").split("\t") + [""])[:2]
    if arch in skiparch:
        report.append(("skip", name, f"arch {arch}: {skiparch[arch]}")); continue
    if name in bundles:
        report.append(("bundle", name, "files taken from the image")); continue
    hit = next((reason for glob, reason in provides if fnmatch.fnmatch(name, glob)), None)
    if hit is not None:
        report.append(("provide", name, hit)); continue
    hit = next((reason for globs, reason in skips if any(fnmatch.fnmatch(name, g) for g in globs)), None)
    if hit is not None:
        report.append(("skip", name, hit)); continue
    if name in renames:
        targets = renames[name]
    else:
        targets = [name]
        for rx, repl in rewrites:
            alt = rx.sub(repl, name)
            if alt != name and alt in available and name not in available:
                targets = [alt]
                break
    missing = [t for t in targets if t not in available]
    if missing:
        report.append(("MISSING", name, "no Arch Linux ARM package: " + " ".join(missing)))
    install += [t for t in targets if t in available]
    if not missing:
        report.append(("install", name, " ".join(targets)))

with open(install_f, "w") as f:
    f.write("\n".join(sorted(set(install))) + "\n")
order = {"MISSING": 0, "install": 1, "bundle": 2, "provide": 3, "skip": 4}
with open(report_f, "w") as f:
    counts = {}
    for k, *_ in report:
        counts[k] = counts.get(k, 0) + 1
    f.write("# " + ", ".join(f"{k}: {v}" for k, v in sorted(counts.items(), key=lambda kv: order[kv[0]])) + "\n")
    for kind, name, why in sorted(report, key=lambda r: (order[r[0]], r[1])):
        f.write(f"{kind:8} {name:40} {why}\n")
print(open(report_f).readline().strip())
