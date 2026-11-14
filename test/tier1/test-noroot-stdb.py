#!/usr/bin/env python3
"""Tier-1: SpacetimeDB on a no-root phone (razr ISSUES 11-14).
- Under the no-root engine (FAKECHROOT_BASE) its data lives in the run dir (XDG_RUNTIME_DIR, excluded from fakechroot's
  path rewrite: its raw renameat calls work there), and what an earlier start left in /var/lib/powos/stdb or the
  on-device hack's run/stdb-data moves there once, never over data. Rooted phones and desktops keep the manifest's dir.
- powos-noroot-services makes the device owner's CLI identity (cli.toml) BEFORE it publishes anything, once - the
  registry's owner is then the CLI's, so `powos app install` isn't refused.
- `powos app install` names the registry's real error, not the empty first line of `spacetime call failed:`."""
import importlib.machinery
import importlib.util
import io
import json
import os
import shutil
import sys
import tempfile
import unittest
from contextlib import redirect_stdout

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MANIFEST = json.load(open(os.path.join(ROOT, "lib", "apps", "services", "spacetimedb.json")))


def load(path, name):
    loader = importlib.machinery.SourceFileLoader(name, path)
    m = importlib.util.module_from_spec(importlib.util.spec_from_loader(name, loader))
    loader.exec_module(m)
    return m


def noroot_services():
    return load(os.path.join(ROOT, "lib", "apps", "powos-noroot-services"), "noroot_t")


def put(path, text="x"):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.env = dict(os.environ)
        self.run = os.path.join(self.tmp, "files", "run")
        os.makedirs(self.run)
        self.old = os.path.join(self.tmp, "rootfs", "var", "lib", "powos", "stdb")
        self.m = json.loads(json.dumps(MANIFEST))
        self.m["backend"]["data"] = self.old
        for k in ("FAKECHROOT_BASE", "XDG_RUNTIME_DIR"):
            os.environ.pop(k, None)

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self.env)
        shutil.rmtree(self.tmp)

    def engine(self):
        os.environ.update(FAKECHROOT_BASE=os.path.join(self.tmp, "rootfs"), XDG_RUNTIME_DIR=self.run)


class DataDir(Base):
    def test_rooted_and_desktop_keep_the_manifest_dir(self):
        s = noroot_services()
        os.environ["XDG_RUNTIME_DIR"] = self.run  # a desktop session has one too: not a reason to move
        self.assertEqual(s.data_dir(self.m), self.old)
        exe = s.command(self.m, s.data_dir(self.m)) or [x.replace("${data}", self.old) for x in self.m["backend"]["exec"]]
        self.assertEqual(exe[exe.index("--data-dir") + 1], f"{self.old}/data")

    def test_noroot_data_in_the_run_dir(self):
        self.engine()
        s = noroot_services()
        d = s.data_dir(self.m)
        self.assertEqual(d, os.path.join(self.run, "stdb"))
        exe = [x.replace("${data}", d) for x in self.m["backend"]["exec"]]
        self.assertEqual(exe[exe.index("--data-dir") + 1], f"{self.run}/stdb/data")
        self.assertEqual(exe[exe.index("--jwt-priv-key-path") + 1], f"{self.run}/stdb/keys/id_ecdsa")

    def test_other_services_keep_theirs(self):
        self.engine()
        m = {"id": "app-api", "backend": {"data": "/var/lib/x", "exec": []}}
        self.assertEqual(noroot_services().data_dir(m), "/var/lib/x")

    def test_migrates_old_data_and_the_hack_dir_once(self):
        self.engine()
        put(f"{self.old}/keys/id_ecdsa", "KEY")
        os.makedirs(f"{self.old}/data")  # the server never ran: empty
        put(f"{self.old}/bundled/powos-registry.sha", "abc")
        put(f"{self.run}/stdb-data/config.toml", "CFG")  # the 11-14 on-device hack's data
        s = noroot_services()
        new = s.data_dir(self.m)
        s.migrate(self.m, new)
        self.assertEqual(open(f"{new}/keys/id_ecdsa").read(), "KEY")
        self.assertEqual(open(f"{new}/data/config.toml").read(), "CFG")
        self.assertEqual(open(f"{new}/bundled/powos-registry.sha").read(), "abc")
        self.assertFalse(os.path.exists(self.old))  # emptied: gone (powos-agents-cli: "no /var/lib/powos/stdb")
        self.assertFalse(os.path.exists(f"{self.run}/stdb-data"))
        self.assertEqual(s.migrate(self.m, new), [])  # once

    def test_never_over_data(self):
        self.engine()
        s = noroot_services()
        new = s.data_dir(self.m)
        put(f"{new}/data/config.toml", "NEW")
        put(f"{self.old}/data/config.toml", "OLD")
        out = s.migrate(self.m, new)
        self.assertEqual(open(f"{new}/data/config.toml").read(), "NEW")
        self.assertEqual(open(f"{self.old}/data/config.toml").read(), "OLD")
        self.assertTrue(any("kept" in x for x in out), out)

    def test_hacked_image_manifest_gets_the_migrated_dir(self):
        self.engine()
        s = noroot_services()
        m = json.loads(json.dumps(self.m))
        ex = m["backend"]["exec"]
        ex[ex.index("--data-dir") + 1] = os.path.join(self.run, "stdb-data")
        new = s.data_dir(m)
        exe = s.command(m, new) or []
        if exe:
            self.assertEqual(exe[exe.index("--data-dir") + 1], f"{new}/data")
        else:  # no spacetimedb-standalone on this host: check the mapping itself
            run = os.environ["XDG_RUNTIME_DIR"]
            legacy = {os.path.join(run, a): os.path.join(new, b) for a, b in s.NOROOT_LEGACY[m["id"]].items()}
            self.assertEqual(legacy[os.path.join(self.run, "stdb-data")], f"{new}/data")


FAKE_SPACETIME = r"""#!/bin/sh
# Records each call and whether an identity existed when it ran; `login` writes one, like the real CLI.
t=$HOME/.config/spacetime/cli.toml
has=no; grep -q spacetimedb_token "$t" 2>/dev/null && has=yes
echo "$1 $2 identity=$has" >> "$LOG"
case "$1" in
  login) mkdir -p "$(dirname "$t")"; echo 'spacetimedb_token = "owner-token"' >> "$t";;
  publish) [ $has = yes ] || { mkdir -p "$(dirname "$t")"; echo 'spacetimedb_token = "anonymous"' >> "$t"; };;
esac
exit 0
"""


class Identity(Base):
    def setUp(self):
        super().setUp()
        self.engine()
        bin_ = os.path.join(self.tmp, "bin")
        put(os.path.join(bin_, "spacetime"), FAKE_SPACETIME)
        os.chmod(os.path.join(bin_, "spacetime"), 0o755)
        self.home = os.path.join(self.tmp, "home")
        os.makedirs(self.home)
        self.log = os.path.join(self.tmp, "calls")
        os.environ.update(PATH=f"{bin_}:{os.environ['PATH']}", HOME=self.home, LOG=self.log,
                          POWOS_SERVICES=os.path.join(self.tmp, "services"))
        put(os.path.join(self.tmp, "services", "spacetimedb.json"), json.dumps(self.m))
        self.bundled = os.path.join(self.tmp, "bundled")
        put(os.path.join(self.bundled, "powos-registry.wasm"), "wasm1")
        put(os.path.join(self.bundled, "powos-counter.wasm"), "wasm2")
        self.s = noroot_services()
        self.s.listening = lambda *a, **k: True
        self.s.exists = lambda db: True

    def calls(self):
        return open(self.log).read().splitlines() if os.path.exists(self.log) else []

    def test_identity_made_before_the_first_publish(self):
        out = self.s.publish(self.bundled)
        self.assertEqual(out, ["powos-counter: published", "powos-registry: published"])
        c = self.calls()
        self.assertEqual(c[0], "server add identity=no")
        self.assertEqual(c[1], "login --server-issued-login identity=no")
        pubs = [x for x in c if x.startswith("publish")]
        self.assertEqual(len(pubs), 2)
        self.assertTrue(all(x.endswith("identity=yes") for x in pubs), c)
        self.assertNotIn("anonymous", open(os.path.join(self.home, ".config", "spacetime", "cli.toml")).read())
        # The stamps go with the data (the run dir), not back to /var/lib/powos/stdb.
        self.assertTrue(os.path.exists(os.path.join(self.run, "stdb", "bundled", "powos-registry.sha")))
        self.assertFalse(os.path.exists(self.old))

    def test_once(self):
        self.s.publish(self.bundled)
        os.remove(self.log)
        self.s.publish(self.bundled)
        self.assertEqual([x for x in self.calls() if x.startswith(("login", "server"))], [])

    def test_kept_identity_is_not_replaced(self):
        put(os.path.join(self.home, ".config", "spacetime", "cli.toml"), 'spacetimedb_token = "mine"\n')
        self.s.publish(self.bundled)
        self.assertEqual([x for x in self.calls() if x.startswith(("login", "server"))], [])
        self.assertEqual(open(os.path.join(self.home, ".config", "spacetime", "cli.toml")).read(), 'spacetimedb_token = "mine"\n')

    def test_no_identity_no_publish(self):
        put(os.path.join(self.tmp, "bin", "spacetime"), FAKE_SPACETIME.replace(
            "login) mkdir", "login) echo 'Error: server down' >&2; exit 1; mkdir"))
        out = self.s.publish(self.bundled)
        self.assertEqual(len(out), 1)
        self.assertIn("not publishing", out[0])
        self.assertIn("server down", out[0])
        self.assertEqual([x for x in self.calls() if x.startswith("publish")], [])


class RegistryError(unittest.TestCase):
    def test_install_names_the_real_error(self):
        pa = load(os.path.join(ROOT, "lib", "apps", "powos-app"), "powos_app_noroot_t")
        if not hasattr(pa, "register_row"):
            self.skipTest("no register_row")

        def refused(text):
            raise pa.Fail("spacetime call failed:\nError: Response text: only the device owner installs apps\n")
        pa.register = refused
        pa.shutil.which = lambda _: "/usr/bin/spacetime"
        buf = io.StringIO()
        with redirect_stdout(buf):
            self.assertFalse(pa.register_row("{}", optional=True))
        self.assertIn("only the device owner installs apps", buf.getvalue())
        self.assertNotIn("(spacetime call failed:)", buf.getvalue())

    def test_caused_by_chain(self):
        pa = load(os.path.join(ROOT, "lib", "apps", "powos-app"), "powos_app_noroot_t2")
        e = pa.Fail("spacetime call failed:\nError: call failed\n\nCaused by:\n    0: HTTP 530\n    1: only the device owner installs apps")
        self.assertEqual(pa.reason(e), "only the device owner installs apps")


if __name__ == "__main__":
    sys.exit(0 if unittest.main(exit=False).result.wasSuccessful() else 1)
