#!/usr/bin/env python3
"""The emu lane's clean-recents step (tools/emu/clean-recents.sh) refuses anything that isn't the emulator - a phone
serial is never even asked, an emulator serial whose device lacks the qemu property gets no remove - and on the
emulator removes every task but PowOS's own. window-lock.sh's release_pkgs removes only the tasks its claim created."""
import os
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
PHONE = (ROOT / 'test/tier1/fixtures/switcher-empty/recents-phone.txt').read_text()
STUB = '''#!/bin/bash
echo "$*" >> "$STUB_LOG"
case "$*" in *getprop*) echo "$STUB_QEMU" ;; *"dumpsys activity recents"*) cat "$STUB_RECENTS" ;; esac
'''


class CleanRecents(unittest.TestCase):
    def run_clean(self, serial, qemu):
        with tempfile.TemporaryDirectory() as d:
            stub = pathlib.Path(d, 'adb'); stub.write_text(STUB); stub.chmod(0o755)
            log = pathlib.Path(d, 'log'); log.write_text('')
            rec = pathlib.Path(d, 'rec'); rec.write_text(PHONE)
            env = dict(os.environ, ADB=str(stub), SERIAL=serial, STUB_LOG=str(log), STUB_QEMU=qemu, STUB_RECENTS=str(rec))
            p = subprocess.run(['bash', str(ROOT / 'tools/emu/clean-recents.sh')], env=env, capture_output=True, text=True, timeout=30)
            return p, log.read_text().splitlines()

    def test_refuses_phone_serials_untouched(self):
        for serial in ('adb-ZY22MQL54Q-XpSn2g._adb-tls-connect._tcp', '10.13.13.7:5555', 'ZY22MQL54Q', 'emulator-5584x', ''):
            p, calls = self.run_clean(serial, '1')
            self.assertNotEqual(p.returncode, 0, serial)
            self.assertEqual(calls, [], serial)

    def test_refuses_emulator_serial_without_qemu(self):
        p, calls = self.run_clean('emulator-5584', '')
        self.assertEqual(p.returncode, 2)
        self.assertIn('refused', p.stderr)
        self.assertFalse([c for c in calls if 'remove' in c or 'dumpsys' in c], calls)

    def test_emulator_removes_all_but_powos(self):
        p, calls = self.run_clean('emulator-5584', '1')
        self.assertEqual(p.returncode, 0, p.stderr)
        removed = sorted(c.split()[-1] for c in calls if 'am stack remove' in c)
        self.assertEqual(removed, sorted(['3414', '3202', '1774']))   # not 3523 (lock), 3510 (home), 2 (FallbackHome)


class ReleasePkgs(unittest.TestCase):
    def test_removes_only_tasks_its_claim_created(self):
        before = PHONE
        after = PHONE.replace('  Visible recent tasks', '  * Recent #6: Task{abc #15 type=standard A=10100:com.oneplus.calculator}\n'
                              '    mActivityComponent=com.oneplus.calculator/.Calculator\n    Activities=[]\n  Visible recent tasks')
        with tempfile.TemporaryDirectory() as d:
            b = pathlib.Path(d, 'b'); b.write_text(before)
            a = pathlib.Path(d, 'a'); a.write_text(after)
            log = pathlib.Path(d, 'log'); log.write_text('')
            script = f'''sh_() {{ echo "$*" >> {log}; case "$*" in "dumpsys activity recents") cat "$CUR" ;; esac; }}
. {ROOT}/tools/phone/verify/window-lock.sh
CUR={b}; claim_pkg com.oneplus.calculator; claim_pkg com.termux 2>/dev/null
CUR={a}; release_pkgs'''
            subprocess.run(['bash', '-c', script], check=False, timeout=30)
            calls = log.read_text().splitlines()
        self.assertIn('am stack remove 15', calls)
        self.assertNotIn('am stack remove 3414', calls)   # Termux's task was there before the claim: never ours
        self.assertEqual([c for c in calls if 'stack remove' in c], ['am stack remove 15'])


if __name__ == '__main__':
    unittest.main()
