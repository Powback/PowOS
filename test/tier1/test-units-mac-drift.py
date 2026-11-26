#!/usr/bin/env python3
"""test-units-mac-drift.py - on the Mac, an installed unit that is stopped is never drift (lib/apps/powos-units).

The Mac's deploy scripts install what units/mac/*.json declares (a LaunchAgent/Daemon plist, a script copy) without
registering it in ~/.config/powos/units.d. Until 11-26 the Mac's check only read that registry, so every PowOS agent
that was installed but stopped between runs or not loaded showed up as drift (its plist "unregistered", its idle
helper processes unclaimed) - the user's "why so many drifts?". The check now reads units/mac too; a registered copy
still wins. Off the Mac the repo's manifests are not read (each host's registry is the truth there).

Usage:  python3 test/tier1/test-units-mac-drift.py
"""
import json
import os
import sys
import tempfile
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader

ROOT = os.path.realpath(os.path.join(os.path.dirname(__file__), "..", ".."))
FAIL = 0


def check(cond, msg):
    global FAIL
    print(f"  {'ok  ' if cond else 'FAIL'} - {msg}")
    FAIL += 0 if cond else 1


os.environ.pop("POWOS_UNITS_DIR", None)
loader = SourceFileLoader("powos_units", os.path.join(ROOT, "lib", "apps", "powos-units"))
m = module_from_spec(spec_from_loader("powos_units", loader))
loader.exec_module(m)

tmp = tempfile.mkdtemp()
reg, repo = os.path.join(tmp, "units.d"), os.path.join(tmp, "units")
os.makedirs(reg)
os.makedirs(os.path.join(repo, "mac"))
plist = os.path.join(tmp, "LaunchAgents", "com.powos.sweep.plist")
stray = os.path.join(tmp, "LaunchAgents", "com.example.stray.plist")
os.makedirs(os.path.dirname(plist))
for p in (plist, stray):
    open(p, "w").close()
with open(os.path.join(repo, "mac", "sweep-mac.json"), "w") as f:
    json.dump({"id": "sweep-mac", "name": "Sweep", "kind": "service", "owner": "system:test", "host": "mac",
               "purpose": "a timer agent, stopped between runs", "files": [plist],
               "processes": [{"match": "sweep-agent-never-running-xyz"}], "unbounded": "test"}, f)

# The host's state, fixed: no packages, the two plists watched, no processes, no docker.
m.UNITS_DIR, m.USER_DIR, m.REPO_UNITS = reg, reg, repo
m.user_dirs = lambda: []
m.package_manager = lambda: None
m.installed_packages = lambda pm: {}
m.package_files = lambda pm: set()
m.watched_paths = lambda host: [plist, stray]
m.proc_table = lambda: {}
m.docker_containers = lambda: []

m.HOST = "mac"
d = m.drift()
files = [f["path"] for f in d["files"]]
check(plist not in files, "an installed, stopped Mac agent (units/mac) is not drift")
check(stray in files, "a file no unit claims is still drift")
row = next((r for r in m.snapshot(sample=False) if r["id"] == "sweep-mac"), None)
check(row is not None and row["status"] == "stopped", f"the agent is listed as a stopped unit ({row and row['status']})")

# A registered copy wins over the repo's.
with open(os.path.join(reg, "sweep-mac.json"), "w") as f:
    json.dump({"id": "sweep-mac", "name": "Sweep (registered)", "kind": "service", "owner": "system:test",
               "host": "mac", "purpose": "registered", "files": [plist], "unbounded": "test"}, f)
names = [u["name"] for u in m.load() if u["id"] == "sweep-mac"]
check(names == ["Sweep (registered)"], f"the registered manifest wins over units/mac ({names})")

# Off the Mac the repo's manifests are not this host's registry.
os.remove(os.path.join(reg, "sweep-mac.json"))
m.HOST = "phone"
check(not any(u["id"] == "sweep-mac" for u in m.load()), "off the Mac, units/mac is not read")

print("PASS" if not FAIL else f"{FAIL} FAILED")
sys.exit(1 if FAIL else 0)
