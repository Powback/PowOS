#!/usr/bin/env python3
"""A theme.get() answer (the phone home's ThemeColors, JSON on stdin, as cdp.sh prints it) -> its name on the first
line, then Omarchy colors.toml lines (mode, and every named color as #rrggbb): phone.sh theme writes them out."""
import json
import re
import sys

raw = sys.stdin.read().strip().splitlines()[-1]
t = json.loads(raw)
if isinstance(t, str):
    t = json.loads(t)


def hexed(v):
    m = re.match(r"rgba?\(\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)", v)
    return "#%02x%02x%02x" % tuple(int(float(x)) for x in m.groups()) if m else v


print(t.get("name") or "phone")
print('mode = "%s"' % ("light" if t.get("light") else "dark"))
for k, v in t.get("colors", {}).items():
    if re.fullmatch(r"[A-Za-z0-9_]+", k) and isinstance(v, str):
        print('%s = "%s"' % (k, hexed(v)))
