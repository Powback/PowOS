#!/usr/bin/env python3
"""Tests for targets/android/tools/split-rootfs.py with the real rootfs-packs.conf: a tiny rootfs with a pacman
database splits into the base (the roots' dependency closure, keeps, pacman.conf NoExtract, /etc/powos/packs) and the
packs (gaming with its own dependencies, apps/dev by package and as the rest, languages by path and package), docs
dropped, checksums written, and --plan agreeing; and play/powos-pack treats a rootfs without /etc/powos/packs (the
full, rooted one) as having every pack."""

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

# name: (depends, files)
PKGS = {
    'bash': (['readline', 'sh'], ['usr/bin/bash', 'usr/share/locale/de/LC_MESSAGES/bash.mo', 'usr/share/doc/bash/README']),
    'readline': ([], ['usr/lib/libreadline.so']),
    'plasma-workspace': (['libgtkish>=1'], ['usr/bin/plasmashell']),
    'libgtkish': ([], ['usr/lib/libgtkish.so']),
    'box64': (['libsteamonly'], ['usr/bin/box64']),
    'libsteamonly': (['readline'], ['usr/lib/libsteamonly.so']),
    'brave-origin-bin': ([], ['opt/brave/brave']),
    'kate': (['readline'], ['usr/bin/kate', 'usr/share/locale/de/LC_MESSAGES/kate.mo']),
    'gcc': ([], ['usr/bin/gcc']),
    'noto-fonts-cjk': ([], ['usr/share/fonts/noto-cjk/a.ttc']),
}
UNOWNED = {
    'etc/pacman.conf': b'[options]\nNoExtract = usr/bin/bwrap\n',
    'usr/bin/powos-steam': b'#!/bin/bash',
    'usr/share/fex-emu/RootFS/x/lib.so': b'x86',
    'usr/share/gamescope-session-plus/bootstrap_steam.tar.gz': b'steam',
    'usr/share/homebrew.tar.zst': b'brew',
    'usr/share/locale/en_GB/LC_MESSAGES/x.mo': b'en',
    'usr/share/locale/locale.alias': b'alias',
    'usr/lib/locale/de_DE.utf8/LC_TIME': b'de',
    'usr/lib/locale/C.utf8/LC_TIME': b'c',
}


def build(path):
    files = dict(UNOWNED)
    for name, (deps, owned) in PKGS.items():
        d = f'var/lib/pacman/local/{name}-1.0-1/'
        files[d + 'desc'] = f'%NAME%\n{name}\n\n%VERSION%\n1.0-1\n\n%DEPENDS%\n' .encode() + '\n'.join(deps).encode() + b'\n\n'
        if name == 'bash':
            files[d + 'desc'] += b'%PROVIDES%\nsh\n\n'
        files[d + 'files'] = ('%FILES%\nusr/\n' + '\n'.join(owned) + '\n').encode()
        for f in owned:
            files[f] = name.encode() * 10
    with tarfile.open(path, 'w:gz', format=tarfile.GNU_FORMAT) as t:
        for d in ('./', './usr/', './usr/share/fex-emu/'):
            m = tarfile.TarInfo(d); m.type = tarfile.DIRTYPE; m.mode = 0o755; t.addfile(m)
        for n, data in files.items():
            m = tarfile.TarInfo('./' + n); m.size = len(data); m.mode = 0o644; t.addfile(m, io.BytesIO(data))
    return files


class SplitTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp()
        full = os.path.join(cls.tmp, 'full.tar.gz')
        cls.files = build(full)
        cls.out = os.path.join(cls.tmp, 'out')
        r = subprocess.run([sys.executable, '-I', str(TOOL), full, str(CONF), cls.out], capture_output=True, text=True)
        assert r.returncode == 0, r.stderr + r.stdout

    def members(self, name):
        with tarfile.open(os.path.join(self.out, name)) as t:
            return {m.name.removeprefix('./'): (t.extractfile(m).read() if m.isfile() else None) for m in t}

    def files_of(self, name):
        return {n for n, d in self.members(name).items() if d is not None}

    def test_base(self):
        base = self.members('powos-rootfs-base.tar.gz')
        for keep in ('usr/bin/bash', 'usr/lib/libreadline.so', 'usr/bin/plasmashell', 'usr/lib/libgtkish.so',
                     'usr/bin/powos-steam', 'usr/share/locale/en_GB/LC_MESSAGES/x.mo', 'usr/share/locale/locale.alias',
                     'usr/lib/locale/C.utf8/LC_TIME', 'usr/share/fex-emu'):
            self.assertIn(keep, base)
        for gone in ('usr/bin/box64', 'usr/share/fex-emu/RootFS/x/lib.so', 'usr/share/doc/bash/README', 'opt/brave/brave',
                     'usr/bin/kate', 'usr/bin/gcc', 'usr/share/locale/de/LC_MESSAGES/bash.mo', 'usr/share/homebrew.tar.zst'):
            self.assertNotIn(gone, base)
        conf = base['etc/pacman.conf'].decode()
        self.assertIn('usr/share/doc/*', conf)
        self.assertIn('NoExtract = usr/bin/bwrap', conf)
        packs = dict(l.split('\t')[:2] for l in base['etc/powos/packs'].decode().splitlines())
        self.assertEqual(set(packs), {'gaming', 'apps', 'dev', 'languages'})
        self.assertEqual(int(packs['gaming']), os.path.getsize(os.path.join(self.out, 'powos-pack-gaming.tar.gz')))

    def test_packs(self):
        self.assertEqual(self.files_of('powos-pack-gaming.tar.gz'),
                         {'usr/bin/box64', 'usr/lib/libsteamonly.so', 'usr/share/fex-emu/RootFS/x/lib.so',
                          'usr/share/gamescope-session-plus/bootstrap_steam.tar.gz'})
        # kate as the rest: its own translation goes with it, not to languages.
        self.assertEqual(self.files_of('powos-pack-apps.tar.gz'),
                         {'opt/brave/brave', 'usr/bin/kate', 'usr/share/locale/de/LC_MESSAGES/kate.mo', 'usr/share/homebrew.tar.zst'})
        self.assertEqual(self.files_of('powos-pack-dev.tar.gz'), {'usr/bin/gcc'})
        self.assertEqual(self.files_of('powos-pack-languages.tar.gz'),
                         {'usr/share/locale/de/LC_MESSAGES/bash.mo', 'usr/lib/locale/de_DE.utf8/LC_TIME', 'usr/share/fonts/noto-cjk/a.ttc'})
        for f in ('powos-rootfs-base', 'powos-pack-gaming', 'powos-pack-apps', 'powos-pack-dev', 'powos-pack-languages'):
            sha = Path(self.out, f + '.tar.gz.sha256').read_text().split()[0]
            self.assertRegex(sha, '^[0-9a-f]{64}$')

    def test_plan_matches(self):
        listing = os.path.join(self.tmp, 'full.lst')
        with open(listing, 'w') as f:
            for n, d in self.files.items():
                f.write(f'-rw-r--r--  0 0 0 {len(d)} Nov  3 23:00 ./{n}\n')
        db = os.path.join(self.tmp, 'db')
        for n, d in self.files.items():
            if n.startswith('var/lib/pacman/local/'):
                p = Path(db, *n.split('/')[4:]); p.parent.mkdir(parents=True, exist_ok=True); p.write_bytes(d)
        r = subprocess.run([sys.executable, '-I', str(TOOL), '--plan', listing, db, str(CONF)], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertRegex(r.stdout, r'(?m)^gaming\t')

    def test_powos_pack_full_rootfs(self):
        # No /etc/powos/packs on a full rootfs (rooted): every pack counts as installed. (The test host has none.)
        if os.path.exists('/etc/powos/packs'):
            self.skipTest('host has /etc/powos/packs')
        r = subprocess.run(['bash', str(ROOT / 'targets/android/play/powos-pack'), 'status', 'gaming'],
                           capture_output=True, text=True)
        self.assertEqual((r.returncode, r.stdout.strip()), (0, 'installed'))


if __name__ == '__main__':
    unittest.main()
