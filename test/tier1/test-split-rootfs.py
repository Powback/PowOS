#!/usr/bin/env python3
"""Tests for targets/android/tools/split-rootfs.py with the real rootfs-packs.conf: a tiny rootfs with a pacman
database splits into the base (keeps, pacman.conf NoExtract, /etc/powos/packs) and the gaming/languages packs
(by path and by package), with docs dropped and checksums written; and play/powos-pack treats a rootfs without
/etc/powos/packs (the full, rooted one) as having every pack."""

import io
import os
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TOOL = ROOT / 'targets/android/tools/split-rootfs.py'
CONF = ROOT / 'targets/android/rootfs-packs.conf'

FILES = {
    'etc/pacman.conf': b'[options]\nNoExtract = usr/bin/bwrap\n',
    'usr/bin/bash': b'bash',
    'usr/bin/powos-steam': b'#!/bin/bash',
    'usr/bin/box64': b'box64' * 100,
    'usr/share/fex-emu/RootFS/x/lib.so': b'x86',
    'usr/share/gamescope-session-plus/bootstrap_steam.tar.gz': b'steam',
    'usr/share/doc/bash/README': b'docs',
    'usr/share/man/man1/bash.1': b'man',
    'usr/share/locale/de/LC_MESSAGES/bash.mo': b'de',
    'usr/share/locale/en_GB/LC_MESSAGES/bash.mo': b'en',
    'usr/share/locale/locale.alias': b'alias',
    'usr/lib/locale/de_DE.utf8/LC_TIME': b'de',
    'usr/lib/locale/C.utf8/LC_TIME': b'c',
    'var/lib/pacman/local/box64-1.0-1/files': b'%FILES%\nusr/\nusr/bin/\nusr/bin/box64\n',
    'var/lib/pacman/local/bash-5-1/files': b'%FILES%\nusr/bin/bash\n',
}


def build(path):
    with tarfile.open(path, 'w:gz', format=tarfile.GNU_FORMAT) as t:
        for d in ('./', './usr/', './usr/share/fex-emu/'):
            m = tarfile.TarInfo(d); m.type = tarfile.DIRTYPE; m.mode = 0o755; t.addfile(m)
        for n, data in FILES.items():
            m = tarfile.TarInfo('./' + n); m.size = len(data); m.mode = 0o644; t.addfile(m, io.BytesIO(data))


class SplitTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp()
        full = os.path.join(cls.tmp, 'full.tar.gz')
        build(full)
        cls.out = os.path.join(cls.tmp, 'out')
        r = subprocess.run([sys.executable, '-I', str(TOOL), full, str(CONF), cls.out], capture_output=True, text=True)
        assert r.returncode == 0, r.stderr + r.stdout

    def members(self, name):
        with tarfile.open(os.path.join(self.out, name)) as t:
            return {m.name.removeprefix('./'): (t.extractfile(m).read() if m.isfile() else None) for m in t}

    def test_base(self):
        base = self.members('powos-rootfs-base.tar.gz')
        for keep in ('usr/bin/bash', 'usr/bin/powos-steam', 'usr/share/locale/en_GB/LC_MESSAGES/bash.mo',
                     'usr/share/locale/locale.alias', 'usr/lib/locale/C.utf8/LC_TIME', 'usr/share/fex-emu'):
            self.assertIn(keep, base)
        for gone in ('usr/bin/box64', 'usr/share/fex-emu/RootFS/x/lib.so', 'usr/share/doc/bash/README',
                     'usr/share/man/man1/bash.1', 'usr/share/locale/de/LC_MESSAGES/bash.mo'):
            self.assertNotIn(gone, base)
        conf = base['etc/pacman.conf'].decode()
        self.assertIn('NoExtract = usr/share/doc/*', conf)
        self.assertIn('NoExtract = usr/bin/bwrap', conf)
        packs = dict(l.split('\t')[:2] for l in base['etc/powos/packs'].decode().splitlines())
        self.assertEqual(set(packs), {'gaming', 'languages'})
        self.assertEqual(int(packs['gaming']), os.path.getsize(os.path.join(self.out, 'powos-pack-gaming.tar.gz')))

    def test_packs(self):
        self.assertEqual(set(self.members('powos-pack-gaming.tar.gz')),
                         {'usr/bin/box64', 'usr/share/fex-emu/RootFS/x/lib.so',
                          'usr/share/gamescope-session-plus/bootstrap_steam.tar.gz'})
        self.assertEqual(set(self.members('powos-pack-languages.tar.gz')),
                         {'usr/share/locale/de/LC_MESSAGES/bash.mo', 'usr/lib/locale/de_DE.utf8/LC_TIME'})
        for f in ('powos-rootfs-base', 'powos-pack-gaming', 'powos-pack-languages'):
            sha = Path(self.out, f + '.tar.gz.sha256').read_text().split()[0]
            self.assertRegex(sha, '^[0-9a-f]{64}$')

    def test_powos_pack_full_rootfs(self):
        # No /etc/powos/packs on a full rootfs (rooted): every pack counts as installed. (The test host has none.)
        if os.path.exists('/etc/powos/packs'):
            self.skipTest('host has /etc/powos/packs')
        r = subprocess.run(['bash', str(ROOT / 'targets/android/play/powos-pack'), 'status', 'gaming'],
                           capture_output=True, text=True)
        self.assertEqual((r.returncode, r.stdout.strip()), (0, 'installed'))


if __name__ == '__main__':
    unittest.main()
