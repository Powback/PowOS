#!/usr/bin/env python3
"""test-powos-dispatch.py - every `powos <subcommand>` runs a file that exists, and the phone's deploy installs it.

bin/powos dispatches subcommands to "$POWOS_LIB/<path>" (/usr/lib/powos on a host, lib/ in the repo). A subcommand
whose file is in the repo but never installed fails only on the device (2026-11-01: `powos terms list` on the phone:
"can't open file '/usr/lib/powos/apps/powos-terms'", so the AI page showed only the phone's own terminals).

Checks: (1) every $POWOS_LIB/<path> bin/powos names exists under lib/ (the repo's install layout); (2) every
$POWOS_LIB/apps/<file> it runs is installed into /usr/lib/powos/apps by targets/android/rooted/powos-deploy.sh and
claimed by a unit in units/phone/. --phone also runs the check on the phone, read-only (tools/phone/root.sh).

Usage:  python3 test/tier1/test-powos-dispatch.py [--phone]
"""
import glob
import json
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.realpath(os.path.join(os.path.dirname(__file__), "..", ".."))
FAILS = []


def check(cond, msg):
    print(f"  {'ok  ' if cond else 'FAIL'} - {msg}")
    if not cond:
        FAILS.append(msg)


def targets():
    with open(os.path.join(ROOT, "bin/powos")) as f:
        text = f.read()
    return sorted(set(re.findall(r"\$POWOS_LIB/([A-Za-z0-9_./-]+)", text)))


def deploy_installs():
    """The names powos-deploy.sh installs into $L (/usr/lib/powos/apps): `install ... $L/<f>`, with its for-loops."""
    with open(os.path.join(ROOT, "targets/android/rooted/powos-deploy.sh")) as f:
        lines = f.read().splitlines()
    names = set()
    for line in lines:
        m = re.search(r"for f in ([^;]+);.*install [^;]*\$L/\$f", line)
        if m:
            names.update(m.group(1).split())
        names.update(re.findall(r"install [^;]*\$L/([A-Za-z0-9_.-]+)", line))
    return names


def unit_files():
    files = set()
    for p in glob.glob(os.path.join(ROOT, "units/phone/*.json")):
        with open(p) as f:
            files.update(json.load(f).get("files", []))
    return files


def main():
    ts = targets()
    for t in ts:
        path = os.path.normpath(os.path.join(ROOT, "lib", t))
        check(os.path.exists(path), f"$POWOS_LIB/{t} exists in the repo ({os.path.relpath(path, ROOT)})")
    installed, claimed = deploy_installs(), unit_files()
    apps = [t.split("/", 1)[1] for t in ts if t.startswith("apps/") and "/" not in t.split("/", 1)[1]]
    for a in apps:
        check(a in installed, f"powos-deploy.sh installs /usr/lib/powos/apps/{a}")
        check(f"/usr/lib/powos/apps/{a}" in claimed, f"a units/phone manifest claims /usr/lib/powos/apps/{a}")
    if "--phone" in sys.argv:
        script = "rc=0; for f in " + " ".join(apps) + "; do [ -f /usr/lib/powos/apps/$f ] || { echo \"missing $f\"; rc=1; }; done; exit $rc\n"
        with tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False) as f:
            f.write(script)
        try:
            r = subprocess.run([os.path.join(ROOT, "tools/phone/root.sh"), f.name], capture_output=True, text=True)
        finally:
            os.unlink(f.name)
        missing = [l for l in r.stdout.splitlines() if l.startswith("missing ")]
        check(r.returncode == 0, "the phone has every powos apps file" + (f" ({', '.join(missing)})" if missing else ""))
    print(f"\n== Results: {len(FAILS)} failed ==")
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
