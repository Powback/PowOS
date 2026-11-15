#!/usr/bin/env python3
"""Device-free lifecycle and installer failure regressions (no Docker daemon used)."""
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
FAKE = r'''#!/usr/bin/env python3
import json, os, pathlib, sys, time
p = pathlib.Path(os.environ['CASE'])
a = sys.argv[1:]
with (p/'calls').open('a') as f: f.write(json.dumps(a)+'\n')
if a[0] == 'inspect': print('true')
elif a[0] == 'create':
    (p/'owned').write_text(a[a.index('--name')+1])
    print('container-id')
    sys.exit(int(os.environ.get('CREATE_RC', '0')))
elif a[0] == 'start':
    (p/'started').touch()
    (p/'client-pid').write_text(str(os.getpid()))
    if os.environ.get('HANG'):
        while True: time.sleep(.05)
    sys.exit(int(os.environ.get('TRANSFER_RC', '0')))
elif a[0] == 'rm':
    assert a[-1] == (p/'owned').read_text()
    (p/'removed').touch()
    sys.exit(int(os.environ.get('CLEANUP_RC', '0')))
else: sys.exit(99)
'''


class Transfer(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.p = Path(self.tmp.name).resolve()
        (self.p/'docker').write_text(FAKE)
        (self.p/'docker').chmod(0o755)
        (self.p/'state').write_text(f'{int(time.time())} ok\n')
        self.env = dict(os.environ, CASE=str(self.p), PATH=f'{self.p}:'+os.environ['PATH'],
                        HOME=str(self.p), PHONE_SERIAL='192.168.50.2:5555',
                        POWOS_ADB_STATE_FILE=str(self.p/'state'), POWOS_ADB_TRANSFER_TIMEOUT_S='3')
        self.cmd = ['bash', str(ROOT/'tools/phone/adb.sh'), 'push', str(self.p/'state'), '/remote']

    def tearDown(self):
        self.tmp.cleanup()

    def ready(self):
        for _ in range(100):
            if (self.p/'started').exists(): return
            time.sleep(.05)
        self.fail('transfer never started')

    def check_cleanup(self):
        self.assertTrue((self.p/'removed').exists())
        calls = [json.loads(x) for x in (self.p/'calls').read_text().splitlines()]
        create = next(x for x in calls if x[0] == 'create')
        self.assertIn('/usr/bin/timeout', create)
        self.assertIn('--kill-after=5', create)
        self.assertEqual([x for x in calls if x[0] == 'rm'], [['rm', '-f', (self.p/'owned').read_text()]])

    def test_success_and_original_failure(self):
        for rc in (0, 42):
            r = subprocess.run(self.cmd, env=dict(self.env, TRANSFER_RC=str(rc), CLEANUP_RC='1'), capture_output=True)
            self.assertEqual(r.returncode, rc, r.stderr)
        self.assertTrue((self.p/'removed').exists())

    def test_timeout(self):
        r = subprocess.run(self.cmd, env=dict(self.env, HANG='1', POWOS_ADB_TRANSFER_TIMEOUT_S='1'), capture_output=True, timeout=10)
        self.assertEqual(r.returncode, 124, r.stderr)
        self.check_cleanup()

    def test_cancellation(self):
        for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            (self.p/'started').unlink(missing_ok=True)
            p = subprocess.Popen(self.cmd, env=dict(self.env, HANG='1'), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            self.ready()
            p.send_signal(sig)
            p.communicate(timeout=10)
            self.assertEqual(p.returncode, 128+sig)
        self.assertTrue((self.p/'removed').exists())

    def test_queue_kills_client_first(self):
        p = subprocess.Popen(self.cmd, env=dict(self.env, HANG='1'), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.ready()
        os.kill(int((self.p/'client-pid').read_text()), signal.SIGTERM)
        p.communicate(timeout=10)
        self.assertEqual(p.returncode, 143)
        self.check_cleanup()

    def test_parent_disappears(self):
        # Parent is killed without signalling its child; supervisor must notice reparenting.
        code = 'import subprocess,sys,time; p=subprocess.Popen(sys.argv[1:]); time.sleep(30)'
        p = subprocess.Popen(['python3', '-c', code] + self.cmd, env=dict(self.env, HANG='1'), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.ready()
        p.kill()
        p.communicate(timeout=10)
        self.check_cleanup()

    def test_create_failure(self):
        r = subprocess.run(self.cmd, env=dict(self.env, CREATE_RC='45'), capture_output=True)
        self.assertEqual(r.returncode, 45)
        self.assertFalse((self.p/'started').exists())
        self.check_cleanup()


class Installer(unittest.TestCase):
    def test_failures_stop_later_phases_without_errexit(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp)
            (p/'adb.sh').write_text('#!/bin/bash\nexit "${PUSH_RC:-0}"\n')
            (p/'adb.sh').chmod(0o755)
            script = '''
T=$CASE; OUT=$CASE
source "$SCRIPT"
kwin_installed() { echo 6.7.5-3.79; }
_kw_rs() { case "$1" in vercmp*) echo 1;; *) echo install >> "$CASE/actions"; return 46;; esac; }
_kw_sh() { echo move >> "$CASE/actions"; return "${MOVE_RC:-0}"; }
kwin_install 6.7.5-3.80
echo restart >> "$CASE/actions"
'''
            for push, move, expected, actions in [(42, 0, 42, ''), (0, 43, 43, 'move\n'), (0, 0, 46, 'move\ninstall\n')]:
                (p/'actions').write_text('')
                env = dict(os.environ, CASE=tmp, SCRIPT=str(ROOT/'tools/phone/verify/kwin-up.sh'),
                           KWIN_PKG='/fake/kwin-6.7.5-3.80-aarch64.pkg.tar.xz', PUSH_RC=str(push), MOVE_RC=str(move))
                r = subprocess.run(['bash', '-c', script], env=env, capture_output=True, text=True)
                self.assertEqual(r.returncode, expected, r.stdout+r.stderr)
                self.assertEqual((p/'actions').read_text(), actions)
                self.assertIn('kwin transfer: start', r.stdout)
                self.assertIn('FAIL kwin', r.stdout)


if __name__ == '__main__':
    unittest.main()
