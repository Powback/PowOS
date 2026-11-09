#!/usr/bin/env python3
"""gh#13: what a fresh phone WITHOUT root needs to make and install a PowOS app is there on day one.
- SpacetimeDB (the spacetimedb package: server + `spacetime` CLI) lands in the BASE image, not a pack, by the real
  targets/android/rootfs-packs.conf through split-rootfs.py's own assign() - and so do its dependencies;
- the app registry (powos-registry) ships in the APK (apps/bundled.list), so powos-noroot-services publishes it on the
  first start (it publishes each bundled <database>.wasm) and `powos app install` registers there;
- the APK build accepts a module-only bundled app (targets/android/build-app.sh: out/ui only where ui/ is).
  python3 test/tier1/test-noroot-app-base.py     exit 0 = all pass"""

import importlib.util
import json
import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CONF = ROOT / 'targets/android/rootfs-packs.conf'


def split():
    spec = importlib.util.spec_from_file_location('split_rootfs', ROOT / 'targets/android/tools/split-rootfs.py')
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class NoRootAppBase(unittest.TestCase):
    def test_spacetimedb_and_its_deps_in_the_base(self):
        s = split()
        rs = s.rules(str(CONF))
        # A db shaped like Arch's: spacetimedb needs glibc/openssl, which brave (apps pack) also pulls.
        db = {'bash': ([], []), 'glibc': ([], []), 'openssl': (['glibc'], []),
              'spacetimedb': (['glibc', 'openssl'], []), 'brave-origin-bin': (['openssl'], []),
              'mariadb': (['openssl'], []), 'kate': ([], [])}
        home = s.assign(rs, db)
        self.assertEqual(home['spacetimedb'], 'base')
        self.assertEqual(home['openssl'], 'base')
        self.assertEqual(home['brave-origin-bin'], 'apps')
        self.assertEqual(home['kate'], 'apps')

    def test_no_pack_names_spacetimedb(self):
        # A package a pack names leaves the base even when a root depends on it (rootfs-packs.conf header).
        for k, name, how, ws in split().rules(str(CONF)):
            if k == 'pack' and how == 'pkg':
                self.assertNotIn('spacetimedb', ws, f'pack {name} names spacetimedb')

    def test_registry_bundled_with_its_database(self):
        apps = [l.split('#', 1)[0].strip() for l in (ROOT / 'apps/bundled.list').read_text().splitlines()]
        self.assertIn('registry', apps)
        m = json.loads((ROOT / 'apps/registry/powos-app.json').read_text())
        self.assertEqual(m['module']['database'], 'powos-registry')
        # powos-app's ensure_registry looks for exactly that database.
        self.assertIn('REGISTRY = "powos-registry"', (ROOT / 'lib/apps/powos-app').read_text())

    def test_build_app_accepts_a_module_only_app(self):
        text = (ROOT / 'targets/android/build-app.sh').read_text()
        self.assertTrue(re.search(r'\[ ! -d "\$ROOT/apps/\$a/ui" \] \|\| \[ -d "\$ROOT/apps/\$a/out/ui" \]', text),
                        'build-app.sh must require out/ui only for an app with a ui/')


if __name__ == '__main__':
    sys.exit(0 if unittest.main(exit=False).result.wasSuccessful() else 1)
