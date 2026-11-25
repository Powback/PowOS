#!/usr/bin/env python3
"""powos-supervisor load_new: a service manifest added while the supervisor runs (a deploy) is picked up at the next
rescan / SIGUSR1 - 11-25: powos-account-sync was installed by a deploy and never started until a reboot. Loaded ones
aren't loaded twice (by path or id); a bad manifest is skipped and logged once."""
import importlib.machinery
import importlib.util
import json
import os
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
d = tempfile.mkdtemp()
os.environ["POWOS_SERVICES"] = d
loader = importlib.machinery.SourceFileLoader("sup", os.path.join(REPO, "lib/apps/powos-supervisor"))
spec = importlib.util.spec_from_loader("sup", loader)
m = importlib.util.module_from_spec(spec)
loader.exec_module(m)
logged = []
m.log = logged.append


def man(name, i):
    json.dump({"id": i, "backend": {"exec": ["/bin/true"]}}, open(os.path.join(d, name), "w"))


fails = 0


def check(c, what):
    global fails
    print(("ok   " if c else "FAIL ") + what)
    fails += not c


man("a.json", "a")
services = []
check([s.id for s in m.load_new(services)] == ["a"], "boot: the manifests there")
man("b.json", "b")
open(os.path.join(d, "bad.json"), "w").write("{")
check([s.id for s in m.load_new(services)] == ["b"], "a manifest added later is loaded at the next rescan")
check(m.load_new(services) == [] and [s.id for s in services] == ["a", "b"], "nothing loaded twice")
man("a2.json", "a")
check(m.load_new(services) == [], "a second manifest with a running id is not a second service")
check(sum("bad manifest" in x for x in logged) == 1, f"a bad manifest is logged once ({logged})")
sys.exit(1 if fails else 0)
