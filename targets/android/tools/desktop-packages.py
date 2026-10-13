#!/usr/bin/env python3
"""List every package the PowOS desktop image installs: `dnf5 ... install` arguments in
containers/Containerfile.base-common and Containerfile (flags, $vars, $(...) URL lookups dropped)."""
import re, sys
root = sys.argv[1]
pkgs = {}
for f in ("containers/Containerfile.base-common", "Containerfile"):
    text = open(f"{root}/{f}").read()
    # join continuation lines
    text = re.sub(r"\\\n", " ", text)
    for line in text.splitlines():
        for m in re.finditer(r"dnf5?\s+-y\s+(?:--\S+\s+)*install\b(.*?)(?:&&|$)", line):
            for tok in m.group(1).split():
                if tok.startswith(("-", "$", "'", '"')) or "(" in tok or ")" in tok or "/" in tok:
                    continue
                pkgs.setdefault(tok, f)
for p in sorted(pkgs):
    print(f"{p}\t{pkgs[p].split('/')[-1]}")
