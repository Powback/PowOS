#!/usr/bin/env python3
"""
Tests for targets/android/pkgs/steam/user_settings.py follow_screen(): Proton's display mode emulation off in a game's
prefix ("EmulateModeset"="N" in user.reg's [Software\\Wine\\X11 Driver]), so Wine's monitor follows KWin's output on a
fold/rotate instead of keeping the launch size (Besiege 346010 withdrew its window off-screen, game-resize 11-18).

Covers: no section -> appended; section without the key -> key inserted after #time; the user's own value (any case)
kept; idempotent; other sections byte-identical; file mode kept; no user.reg -> nothing written; Proton's own import
(module name user_settings, STEAM_COMPAT_DATA_PATH) applies it.
"""

import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
PKG = REPO / "targets/android/pkgs/steam"

spec = importlib.util.spec_from_file_location("powos_us", PKG / "user_settings.py")
us = importlib.util.module_from_spec(spec)
spec.loader.exec_module(us)

HEAD = (b"WINE REGISTRY Version 2\n;; All keys relative to \\\\User\\\\S-1-5-21-0-0-0-1000\n\n#arch=win64\n\n"
        b"[Software\\\\Free Lives\\\\Broforce] 1794356019\n#time=1dd77aeb2b43aae\n\"a\"=dword:00000001\n")
X11 = b"[Software\\\\Wine\\\\X11 Driver] 1794356019\n#time=1dd77aeb2b43aae\n\"Decorated\"=\"N\"\n"
TAIL = b"\n[Software\\\\Wine\\\\X11 Driver\\\\Other] 1794356019\n#time=1\n\"EmulateModeset\"=\"Y\"\n"


class FollowScreen(unittest.TestCase):
    def setUp(self):
        self.t = Path(tempfile.mkdtemp())
        self.reg = self.t / "user.reg"

    def section(self, s):
        i = s.index(b"[Software\\\\Wine\\\\X11 Driver]")
        j = s.find(b"\n[", i + 1)
        return s[i:] if j < 0 else s[i:j]

    def test_no_section_appended(self):
        self.reg.write_bytes(HEAD)
        self.assertEqual(us.follow_screen(str(self.reg)), "set")
        s = self.reg.read_bytes()
        self.assertTrue(s.startswith(HEAD.rstrip(b"\n")))
        self.assertIn(b'"EmulateModeset"="N"', self.section(s))
        self.assertTrue(s.endswith(b"\n"))

    def test_section_without_key(self):
        self.reg.write_bytes(HEAD + b"\n" + X11 + TAIL)
        self.assertEqual(us.follow_screen(str(self.reg)), "set")
        s = self.reg.read_bytes()
        sec = self.section(s)
        self.assertEqual(sec.split(b"\n")[:4], [b"[Software\\\\Wine\\\\X11 Driver] 1794356019", b"#time=1dd77aeb2b43aae",
                                               b'"EmulateModeset"="N"', b'"Decorated"="N"'])
        self.assertTrue(s.startswith(HEAD))
        self.assertTrue(s.endswith(TAIL), "a sub-key's own value is a different section")

    def test_user_value_kept(self):
        for v in (b'"EmulateModeset"="Y"', b'"emulatemodeset"="y"'):
            orig = HEAD + b"\n" + X11.replace(b'"Decorated"', v + b'\n"Decorated"') + TAIL
            self.reg.write_bytes(orig)
            self.assertTrue(us.follow_screen(str(self.reg)).startswith("kept"))
            self.assertEqual(self.reg.read_bytes(), orig)

    def test_idempotent_and_mode(self):
        self.reg.write_bytes(HEAD + b"\n" + X11)
        os.chmod(self.reg, 0o640)
        us.follow_screen(str(self.reg))
        once = self.reg.read_bytes()
        self.assertTrue(us.follow_screen(str(self.reg)).startswith("kept"))
        self.assertEqual(self.reg.read_bytes(), once)
        self.assertEqual(once.count(b"EmulateModeset"), 1)
        self.assertEqual(os.stat(self.reg).st_mode & 0o777, 0o640)
        self.assertFalse(list(self.t.glob("*.powos-tmp")))

    def test_no_user_reg(self):
        self.assertEqual(us.follow_screen(str(self.reg)), "no user.reg")
        self.assertFalse(self.reg.exists())

    def test_protons_import_applies_it(self):
        data = self.t / "compatdata/346010"
        (data / "pfx").mkdir(parents=True)
        (data / "pfx/user.reg").write_bytes(HEAD)
        code = ("import importlib.util,sys; s=importlib.util.spec_from_file_location('user_settings', sys.argv[1]);"
                "m=importlib.util.module_from_spec(s); s.loader.exec_module(m)")
        env = dict(os.environ, STEAM_COMPAT_DATA_PATH=str(data), HOME=str(self.t))
        subprocess.run([sys.executable, "-c", code, str(PKG / "user_settings.py"), "waitforexitandrun"], env=env,
                       check=True)
        self.assertIn(b'"EmulateModeset"="N"', (data / "pfx/user.reg").read_bytes())


if __name__ == "__main__":
    unittest.main()
