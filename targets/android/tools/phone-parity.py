#!/usr/bin/env python3
"""PowOS phone parity: what the PowOS image offers a user (manifest index.tsv: commands, apps, autostart
entries, enabled system and user units) checked against this phone, gaps grouped by the PowOS package they
come from, next to what the phone mapping did with that package (phone-report.txt).

Usage: phone-parity.py <index.tsv> [phone-report.txt] [--root DIR] [--all]
Exit status 1 when anything is missing, so builds and CI can gate on it.
"""
import os
import sys

args = [a for a in sys.argv[1:] if not a.startswith("--")]
root = "/"
if "--root" in sys.argv:
    root = sys.argv[sys.argv.index("--root") + 1]
    args = [a for a in args if a != root]
index_path = args[0]
report_path = args[1] if len(args) > 1 else "/usr/share/powos/phone-report.txt"

# How each top-level RPM was mapped (install / skip / provide / bundle / MISSING / FAILED), for context.
mapping = {}
if os.path.exists(report_path):
    for line in open(report_path):
        parts = line.split(None, 2)
        if len(parts) >= 2 and not line.startswith("#"):
            mapping[parts[1].split("\\t")[0].split("\t")[0]] = (parts[0], parts[2].strip() if len(parts) > 2 else "")

# Enabled units only do anything when something runs them. On the phone that is Andromarchy's systemctl
# (docker-systemctl-replacement), started by the session; ask it which units are active. Elsewhere (--root on a
# host) only presence is checked.
import subprocess

def active_units(user):
    if root != "/":
        return None
    names = [l.split("\t")[1] for l in open(index_path) if l.startswith("user-unit\t" if user else "unit\t")]
    if not names:
        return set()
    cmd = ["systemctl"] + (["--user"] if user else []) + ["is-active"] + names
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=120).stdout.split()
    except (OSError, subprocess.TimeoutExpired):
        return set()
    return {n for n, state in zip(names, out) if state == "active"}

active = {"unit": active_units(False), "user-unit": active_units(True)}


def present(kind, name):
    r = lambda *p: os.path.lexists(os.path.join(root, *p))
    if kind == "bin":
        return r("usr/bin", name) or r("usr/sbin", name) or r("usr/local/bin", name)
    if kind == "app":
        return r("usr/share/applications", name) or r("var/lib/flatpak/exports/share/applications", name) \
            or r("root/.local/share/flatpak/exports/share/applications", name)
    if kind == "autostart":
        return r("etc/xdg/autostart", name)
    if kind == "unit":
        return r("usr/lib/systemd/system", name) or r("etc/systemd/system", name)
    if kind == "user-unit":
        return r("usr/lib/systemd/user", name) or r("etc/systemd/user", name)
    return False


gaps = {}       # owner -> [(kind, name, why)]
totals = {}     # kind -> [have, want]
for line in open(index_path):
    kind, name, owner = line.rstrip("\n").split("\t")
    t = totals.setdefault(kind, [0, 0])
    t[1] += 1
    ok = present(kind, name)
    why = "missing"
    if ok and kind in ("unit", "user-unit") and active[kind] is not None and name not in active[kind] \
            and not name.endswith((".target", ".path", ".socket")):
        ok, why = False, "unit file present, not active"
    if ok:
        t[0] += 1
    else:
        gaps.setdefault(owner, []).append((kind, name, why))

print("PowOS phone parity (what the PowOS image offers vs this phone)")
for kind, (have, want) in sorted(totals.items()):
    print(f"  {kind:10} {have:5} / {want:<5} {'OK' if have == want else f'{want - have} gaps'}")
print()
for owner in sorted(gaps, key=lambda o: (-len(gaps[o]), o)):
    m = mapping.get(owner)
    how = f"  [{m[0]}: {m[1]}]" if m else ("  [PowOS's own files]" if owner == "image" else "  [dependency of a top-level package]")
    print(f"{owner} ({len(gaps[owner])}){how}")
    items = gaps[owner] if "--all" in sys.argv else gaps[owner][:8]
    for kind, name, why in items:
        print(f"    {kind:9} {name}" + ("" if why == "missing" else f"  ({why})"))
    if len(items) < len(gaps[owner]):
        print(f"    ... {len(gaps[owner]) - len(items)} more (--all)")
sys.exit(1 if gaps else 0)
