#!/usr/bin/env python3
"""adb unauthorized on the phone must never become a reconnect storm (11-08: the "Allow USB debugging?" dialog spam).

A fake docker/adb reports the phone `unauthorized`: tools/phone/adb.sh makes no connect on first sight, at most one per
backoff window after that, exits 69 "phone offline: adb unauthorized" (and --vpn-state too), notifies the user once,
and picks up an Allow at once. powos-vadb's keepalive backs off the same way. docs/REMOTE-POWOS.md, adb authorization.
"""
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]

DOCKER = r'''#!/bin/sh
d=$(dirname "$0")
case "$1" in
 inspect) echo true ;;
 exec)
   case "$*" in
     *wireguard*) exit 0 ;;
     *disconnect*connect*) echo CONNECT >> "$d/calls" ;;
     *get-state*) s=$(cat "$d/state"); [ "$s" = device ] && { echo device; exit 0; }
                  echo "error: device $s" >&2; exit 1 ;;
     *" shell "*) echo RAN >> "$d/calls"; echo ran ;;
     *) echo "unexpected: $*" >&2; exit 99 ;;
   esac ;;
 *) exit 99 ;;
esac
'''

# The keepalive runs inside powos-vadb with adb on PATH.
ADB = r'''#!/bin/sh
d=$(dirname "$0")
for a in "$@"; do case "$a" in
  connect) echo CONNECT >> "$d/calls"; exit 0 ;;
  disconnect|start-server) exit 0 ;;
  get-state) s=$(cat "$d/state"); [ "$s" = device ] && { echo device; exit 0; }; echo "error: device $s" >&2; exit 1 ;;
esac; done
'''


class UnauthorizedTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.d = Path(self.temp.name)
        for name, body in (('docker', DOCKER), ('adb', ADB),
                           ('notify', '#!/bin/sh\necho "$*" >> "$(dirname "$0")/notified"\n')):
            (self.d / name).write_text(body)
            (self.d / name).chmod(0o755)
        (self.d / 'state').write_text('unauthorized\n')
        self.marker = self.d / 'adbstate.unauth'
        self.env = dict(os.environ, PATH=f'{self.d}:' + os.environ['PATH'], POWOS_DEVICE='phone',
                        POWOS_ADB_STATE_FILE=str(self.d / 'adbstate'), POWOS_ADB_NOTIFY=str(self.d / 'notify'))

    def adb(self, *args):
        return subprocess.run(['bash', str(ROOT / 'tools/phone/adb.sh'), *args], env=self.env,
                              capture_output=True, text=True, timeout=10)

    def count(self, what):
        f = self.d / 'calls'
        return f.read_text().split().count(what) if f.exists() else 0

    def notified(self):
        for _ in range(50):  # the notify is backgrounded
            if (self.d / 'notified').exists():
                break
            time.sleep(0.05)
        time.sleep(0.2)
        f = self.d / 'notified'
        return f.read_text().splitlines() if f.exists() else []

    def test_backs_off_and_notifies_once(self):
        r = self.adb('shell', 'true')
        self.assertEqual(r.returncode, 69, r.stderr)
        self.assertIn('phone offline: adb unauthorized', r.stderr)
        self.assertEqual(self.count('CONNECT'), 0, 'no reconnect on first sight: the dialog already up is enough')
        for _ in range(15):  # a runner's tight loop
            self.assertEqual(self.adb('shell', 'true').returncode, 69)
        self.assertEqual(self.count('CONNECT'), 0)
        self.assertEqual(self.count('RAN'), 0)
        v = self.adb('--vpn-state')
        self.assertEqual(v.returncode, 69)
        self.assertIn('adb=unauthorized', v.stdout)
        n = self.notified()
        self.assertEqual(len(n), 1, n)
        self.assertIn('Always allow', n[0])

    def test_one_reconnect_per_window(self):
        self.adb('shell', 'true')
        at, first = self.marker.read_text().split()
        self.marker.write_text(f'{int(at) - 601} {first}\n')  # the window ran out
        self.assertEqual(self.adb('--vpn-state').returncode, 0, 'out of the window: the runner may try again')
        for _ in range(5):
            self.assertEqual(self.adb('shell', 'true').returncode, 69)
        self.assertEqual(self.count('CONNECT'), 1)
        self.assertEqual(len(self.notified()), 1, 'same episode: no second notice')

    def test_allow_ends_the_backoff(self):
        self.adb('shell', 'true')
        (self.d / 'state').write_text('device\n')
        self.assertEqual(self.adb('--vpn-state').returncode, 0)
        self.assertFalse(self.marker.exists())
        r = self.adb('shell', 'true')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.count('RAN'), 1)
        self.assertEqual(self.count('CONNECT'), 0)

    def test_offline_still_reconnects_once_per_call(self):
        (self.d / 'state').write_text('offline\n')
        self.assertEqual(self.adb('shell', 'true').returncode, 69)
        self.assertEqual(self.count('CONNECT'), 1, 'a stale (not unauthorized) link keeps its one reconnect')
        self.assertFalse(self.marker.exists())

    def keepalive(self, seconds):
        env = dict(self.env, ANDROID_SERIAL='10.13.13.7:5555', VADB_POLL_S='0.1')
        p = subprocess.Popen(['sh', str(ROOT / 'targets/android/vadb/vadb-keepalive.sh')], env=env,
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        time.sleep(seconds)
        p.kill()
        return p.communicate()[0]

    def test_keepalive_backs_off(self):
        out = self.keepalive(1.5)
        self.assertEqual(self.count('CONNECT'), 0, out)
        self.assertEqual(out.count('unauthorized'), 1, out)
        (self.d / 'state').write_text('offline\n')
        self.keepalive(0.6)
        self.assertGreater(self.count('CONNECT'), 1, 'a dropped (not unauthorized) link is still reconnected')


if __name__ == '__main__':
    unittest.main()
