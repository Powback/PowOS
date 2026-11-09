#!/usr/bin/env python3
"""The phone agent's `layout` action (lib/devices/powos-deviced AndroidBackend): the PowOS app's exported home + dock
(shell-data/layout-export.json, read through su) handed back as data; advertised as a cap; anything that isn't a v1
export (missing, garbage) is a refusal, never a crash or an empty layout."""
import importlib.machinery
import importlib.util
import json
import os
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
work = tempfile.mkdtemp()
os.environ["POWOS_DEVICED_DIR"] = os.path.join(work, "target")
os.environ["POWOS_DEVICED_CONFIG"] = os.path.join(work, "deviced.json")
loader = importlib.machinery.SourceFileLoader("deviced", os.path.join(REPO, "lib/devices/powos-deviced"))
spec = importlib.util.spec_from_loader("deviced", loader)
d = importlib.util.module_from_spec(spec)
loader.exec_module(d)
fails = 0


def check(ok, what):
    global fails
    print(("  ok   - " if ok else "  FAIL - ") + what)
    fails += 0 if ok else 1


class Phone(d.AndroidBackend):
    out = (0, "")
    LAYOUT = os.path.join(work, "nope.json")  # not readable directly: the su path

    def sh(self, *cmd):
        self.cmd = cmd
        return self.out


p = Phone()
check("layout" in p.caps() and "layout" in d.ACTIONS, "layout is a phone cap and an action")
exp = {"v": 1, "at": 1, "dock": ["a:org.mozilla.firefox/.App"], "home": {"pages": [1], "items": []}}
p.out = (0, json.dumps(exp))
check(p.act("layout", {}) == exp, "the export comes back as data")
check(p.cmd[:2] == ("su", "-c") and p.LAYOUT in p.cmd[2] and d.AndroidBackend.LAYOUT.endswith("files/shell-data/layout-export.json"), "read through su from the app's shell-data")
for bad, why in (((1, "Permission denied"), "unreadable"), ((0, "{nope"), "garbage"), ((0, '{"v": 2}'), "another version")):
    p.out = bad
    try:
        p.act("layout", {})
        check(False, f"{why}: refused")
    except d.ActionError as e:
        check(e.code == "failed", f"{why}: refused ({e})")
print("deviced-layout:", "FAIL" if fails else "PASS")
sys.exit(1 if fails else 0)
