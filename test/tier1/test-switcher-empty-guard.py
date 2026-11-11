#!/usr/bin/env python3
"""switcher-empty.sh's refuse-on-user-tasks guard: with any user task (live or backgrounded) or an unreadable task
dump it SKIPs (exit 5) having sent the device nothing but the read - no install, start, key, stop or uninstall."""
import os
import pathlib
import runpy
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
FIX = ROOT / 'test/tier1/fixtures/switcher-empty'
SCRIPT = ROOT / 'tools/phone/verify/switcher-empty.sh'
STUB = '''#!/bin/bash
echo "$*" >> "$STUB_LOG"
case "$*" in "shell dumpsys activity recents") cat "$STUB_RECENTS" ;; esac
'''


class Guard(unittest.TestCase):
    def run_script(self, recents):
        with tempfile.TemporaryDirectory() as d:
            stub = pathlib.Path(d, 'adb.sh'); stub.write_text(STUB); stub.chmod(0o755)
            log = pathlib.Path(d, 'log'); log.write_text('')
            rec = pathlib.Path(d, 'recents'); rec.write_text(recents)
            env = dict(os.environ, ADB_SH=str(stub), STUB_LOG=str(log), STUB_RECENTS=str(rec), LOCK_HELD='1',
                       OUT=str(pathlib.Path(d, 'out')), POWOS_DEVICE='emu', HOME=d)
            p = subprocess.run(['bash', str(SCRIPT)], env=env, capture_output=True, text=True, timeout=60)
            return p, log.read_text().splitlines()

    def test_user_tasks_refused_untouched(self):
        p, calls = self.run_script((FIX / 'recents-phone.txt').read_text())
        self.assertEqual(p.returncode, 5, p.stdout + p.stderr)
        self.assertIn('SKIP: pre-existing user tasks', p.stdout)
        self.assertIn('com.termux', p.stdout)
        self.assertEqual(calls, ['shell dumpsys activity recents'])

    def test_unreadable_dump_refused_untouched(self):
        p, calls = self.run_script('error: device offline\n')
        self.assertEqual(p.returncode, 5, p.stdout + p.stderr)
        self.assertIn("SKIP: can't read the device's tasks", p.stdout)
        self.assertEqual(calls, ['shell dumpsys activity recents'])

    def test_empty_device_passes_guard(self):
        m = runpy.run_path(str(ROOT / 'tools/phone/verify/user-tasks.py'))
        self.assertEqual(m['user_tasks']((FIX / 'recents-empty.txt').read_text()), [])
        # A backgrounded task (no activities) still counts, and a spoofed powos-ish package does not pass as ours.
        bg = '  * Recent #0: Task{a #9 type=standard A=1:com.x}\n    mActivityComponent=com.x/.Main\n    Activities=[]\n'
        self.assertEqual(m['user_tasks'](bg), ['#9 com.x/.Main'])
        spoof = bg.replace('com.x/.Main', 'com.powos.apps/.Main')
        self.assertEqual(len(m['user_tasks'](spoof)), 1)

    def test_guard_precedes_every_device_change(self):
        src = SCRIPT.read_text()
        guard = src.index('user-tasks.py')
        for change in ('install -r', 'am start', 'KEYCODE_APP_SWITCH', 'force-stop', 'uninstall'):
            self.assertLess(guard, src.index(change), change)


if __name__ == '__main__':
    unittest.main()
