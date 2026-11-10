#!/usr/bin/env python3
"""Tier-1: powos-noroot-services sets up the Agents view's reporter without root (unit agentsd, no-root path) - the
claude hooks into the image's Claude settings once, keeping the file's other settings, and powos-agentsd started."""
import importlib.machinery
import importlib.util
import json
import os
import shutil
import sys
import tempfile
import time
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
AGENTS = os.path.join(ROOT, "lib", "ai", "agents")


def load():
    loader = importlib.machinery.SourceFileLoader("noroot", os.path.join(ROOT, "lib", "apps", "powos-noroot-services"))
    spec = importlib.util.spec_from_loader("noroot", loader)
    m = importlib.util.module_from_spec(spec)
    loader.exec_module(m)
    return m


class NoRootAgents(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        lib = os.path.join(self.tmp, "agents")
        os.makedirs(lib)
        for f in ("install-hooks.py", "claude-hooks.json"):
            shutil.copy(os.path.join(AGENTS, f), lib)
        # A stand-in daemon: records that it ran, and with which host.
        with open(os.path.join(lib, "powos-agentsd"), "w") as f:
            f.write(f"import os\nopen({os.path.join(self.tmp, 'ran')!r}, 'w').write(os.environ.get('POWOS_AGENTS_HOST', ''))\n")
        self.home = os.path.join(self.tmp, "home")
        os.makedirs(os.path.join(self.home, ".claude"))
        with open(os.path.join(self.home, ".claude", "settings.json"), "w") as f:
            json.dump({"model": "opus"}, f)
        os.environ.update(POWOS_AGENTS_LIB=lib, POWOS_LOGS=os.path.join(self.tmp, "log"), HOME=self.home)
        self.m = load()

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def ran(self):
        for _ in range(100):
            if os.path.exists(os.path.join(self.tmp, "ran")):
                return open(os.path.join(self.tmp, "ran")).read()
            time.sleep(0.05)
        return None

    def test_hooks_installed_once_and_daemon_started(self):
        out = self.m.agents()
        self.assertEqual(out, ["agents hooks: installed", "agentsd: started"])
        self.assertEqual(self.ran(), "phone")
        s = json.load(open(os.path.join(self.home, ".claude", "settings.json")))
        self.assertEqual(s["model"], "opus")
        cmds = json.dumps(s["hooks"])
        self.assertIn("POWOS_AGENTS_HOST=phone", cmds)
        before = open(os.path.join(self.home, ".claude", "settings.json")).read()
        self.assertEqual(self.m.agents(), ["agentsd: started"])  # hooks there: the file is left alone
        self.assertEqual(open(os.path.join(self.home, ".claude", "settings.json")).read(), before)

    def test_image_without_the_reporter(self):
        os.remove(os.path.join(os.environ["POWOS_AGENTS_LIB"], "powos-agentsd"))
        self.assertEqual(self.m.agents(), ["agentsd: not in this image"])


if __name__ == "__main__":
    sys.exit(0 if unittest.main(exit=False).result.wasSuccessful() else 1)
