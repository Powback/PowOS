#!/usr/bin/env python3
"""Device-free camera guard/ownership and shell setup regressions."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
VERIFY = ROOT / 'tools/phone/verify'
spec = importlib.util.spec_from_file_location('ownership', VERIFY / 'camera-ownership.py')
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)
HOME = 'RootTask id=1 bounds=[0,0][100,100] displayId=0\n  taskId=10: dev.omalauncher/.Home bounds=[0,0][100,100] visible=true\n'
CAM = 'RootTask id=22 bounds=[0,0][100,100] displayId=4\n  taskId=20: com.oplus.camera/.Camera bounds=[0,0][100,100] visible=true\n'


# Sanitized, shortened shape of the saved 1115-0558 media.camera dump: global
# snapshot completes, then events, then provider metadata which may time out.
CLIENTS = '''
== Service global info: ==

Number of camera devices: 8
Number of normal camera devices: 6
Number of public camera devices visible to API1: 3
    Device 0 maps to "0"
Active Camera Clients:
[]
Allowed user IDs: 0

== Camera service events log (most recent at top): ==
  11-15 05:52:12 : ADD device 0, reason: (Device added)

== Camera Provider HAL device static information: ==
  android.sensor.info.activeArraySize: [0 0 100 100]
'''
TIMEOUT = "*** SERVICE 'media.camera' DUMP TIMEOUT (5000ms) EXPIRED ***\n"


class Ownership(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.d = Path(self.tmp.name)
        for k, text in dict(tasks=HOME, activities='ACTIVITY MANAGER ACTIVITIES',
                            recents='ACTIVITY MANAGER RECENT TASKS', windows='WINDOW MANAGER WINDOWS',
                            clients=CLIENTS, process='ABSENT').items():
            (self.d / (k + '.txt')).write_text(text)

    def test_absent_recognized(self):
        policy.guard(self.d)

    def test_preexisting_hidden_task_recent_window_client_and_cached_process(self):
        for key, value in [('tasks', HOME + CAM.replace('visible=true', 'visible=false')),
                           ('activities', 'ACTIVITY MANAGER ACTIVITIES com.oplus.camera'),
                           ('recents', 'ACTIVITY MANAGER RECENT TASKS com.oplus.camera'),
                           ('windows', 'WINDOW MANAGER WINDOWS com.oplus.camera'),
                           ('clients', CLIENTS.replace('\n[]\n', '\n[other.app]\n')), ('process', '1234')]:
            with self.subTest(key=key):
                p = self.d / (key + '.txt')
                old = p.read_text()
                p.write_text(value)
                with self.assertRaises(ValueError):
                    policy.guard(self.d)
                p.write_text(old)

    def test_unknown_empty_and_reported_probe_errors(self):
        for key in ['tasks', 'activities', 'recents', 'windows', 'clients', 'process']:
            p = self.d / (key + '.txt')
            old = p.read_text()
            for value in ['', 'Permission Denial', 'DUMP TIMEOUT', 'unexpected format']:
                with self.subTest(key=key, value=value):
                    p.write_text(value)
                    with self.assertRaises(ValueError):
                        policy.guard(self.d)
            p.write_text(old)

    def test_completed_clients_accept_late_metadata_timeout_not_cached_pid(self):
        path = self.d / 'clients.txt'
        path.write_text(CLIENTS + TIMEOUT)
        policy.guard(self.d)
        self.assertTrue(path.read_text().endswith(TIMEOUT))
        (self.d / 'process.txt').write_text('1234')
        with self.assertRaisesRegex(ValueError, 'may be cached'):
            policy.guard(self.d)

    def test_initial_clients_fail_closed_at_section_boundary(self):
        event = '== Camera service events log (most recent at top): =='
        invalid = [
            CLIENTS.replace('Active Camera Clients:', TIMEOUT + 'Active Camera Clients:'),
            CLIENTS.replace('Allowed user IDs: 0', 'Allowed user IDs: 0\n' + TIMEOUT),
            CLIENTS.replace('\n[]\n', '\n[other.app]\n') + 'Active Camera Clients:\n[]\n',
            CLIENTS.replace('Active Camera Clients:\n[]\n', '') + 'Active Camera Clients:\n[]\n',
            CLIENTS.replace('== Service global info: ==\n', ''),
            CLIENTS.replace(event, '== Other section: =='),
            CLIENTS.split(event)[0],
            CLIENTS.replace('Allowed user IDs: 0\n', ''),
            CLIENTS.replace('Active Camera Clients:', 'Active Camera Clients:\nActive Camera Clients:'),
            CLIENTS.replace('\n[]\n', '\n[\n'),
            CLIENTS.replace('\n[]\n', '\n[] extra\n'),
        ]
        for warning in ['Permission Denial', 'ERROR: failed', 'Camera service deadlock',
                        'No camera HAL available', 'WARNING: incomplete snapshot']:
            invalid.append(CLIENTS.replace('Number of camera devices:', warning + '\nNumber of camera devices:'))
        for text in invalid:
            with self.subTest(text=text):
                (self.d / 'clients.txt').write_text(text)
                with self.assertRaises(ValueError):
                    policy.guard(self.d)

    def test_new_exact_task_and_exclusive_root_cleanup(self):
        after = self.d / 'after'
        after.write_text(HOME + CAM)
        self.assertEqual(policy.owned(self.d, after), '20')
        policy.cleanup(self.d, after, '20')
        for task in ['10', '999', '20;kill']:
            with self.assertRaises(ValueError):
                policy.cleanup(self.d, after, task)
        after.write_text(HOME + CAM + '  taskId=21: other.app/.Main visible=true\n')
        with self.assertRaises(ValueError):
            policy.cleanup(self.d, after, '20')
        after.write_text(HOME + CAM.replace('id=22', 'id=1'))
        with self.assertRaises(ValueError):
            policy.cleanup(self.d, after, '20')

    def test_no_ownership_for_old_missing_or_ambiguous_camera(self):
        after = self.d / 'after'
        for text in [HOME, HOME + CAM + CAM.replace('id=22', 'id=23').replace('taskId=20', 'taskId=21')]:
            after.write_text(text)
            with self.assertRaises(ValueError):
                policy.owned(self.d, after)
        (self.d / 'tasks.txt').write_text(HOME + CAM)
        after.write_text(HOME + CAM)
        with self.assertRaises(ValueError):
            policy.owned(self.d, after)

    def test_probe_failure_and_guard_skip_precede_any_mutation(self):
        source = (VERIFY / 'inner-rotation-back.sh').read_text()
        # Run the real setup/helpers with device transport replaced by a function;
        # never source device libraries or reach adb/home/fold.
        block = source[source.index('CAMTASK=""'):source.index('r0=$(rot)')]
        for failed in [True, False]:
            script = '''
set -uo pipefail
OUT=$1; T=$2; A=never-device; SECONDS=0
say() { echo "$*"; }
wwc_skip() { say "$*"; exit 3; }
wwc_start() { echo UNSAFE_SETUP; exit 99; }
perl() { echo 'Permission Denial'; return ''' + ('1' if failed else '0') + '''; }
''' + block
            r = subprocess.run(['bash', '-c', script, '_', str(self.d), str(VERIFY.parent)],
                               capture_output=True, text=True, timeout=5)
            self.assertEqual(r.returncode, 3, r.stderr)
            self.assertNotIn('UNSAFE_SETUP', r.stdout)
            self.assertTrue((self.d / 'before-setup/tasks.txt.rc').exists())

    def test_shell_cleanup_only_removes_owned_exclusive_new_root(self):
        source = (VERIFY / 'inner-rotation-back.sh').read_text()
        helper = source[source.index('wwc_extra()'):source.index('# Before wwc_start')]
        # The policy reads prelaunch from OUT; use this fixture directory as it.
        out = self.d / 'out'
        out.mkdir()
        (out / 'prelaunch').symlink_to(self.d, target_is_directory=True)
        current = self.d / 'current'
        for text, task, expected in [(HOME + CAM, '20', 'REMOVE am stack remove 22'),
                                     (HOME + CAM, '10', ''), (HOME, '', ''),
                                     (HOME + CAM + '  taskId=21: other.app/.Main visible=true\n', '20', '')]:
            current.write_text(text)
            script = '''
set -uo pipefail
OUT=$1; POLICY=$2; CAMTASK=$3; CURRENT=$4; STARTED=1
say() { echo "$*"; }
probe() { local file=$1; shift
  if [ "$*" = 'timeout 5 am stack list' ]; then cp "$CURRENT" "$file";
  else echo "REMOVE $*"; fi; }
''' + helper + '\nwwc_extra\nwwc_extra\n'
            r = subprocess.run(['bash', '-c', script, '_', str(out),
                                str(VERIFY / 'camera-ownership.py'), task, str(current)],
                               capture_output=True, text=True, timeout=5)
            self.assertEqual(r.returncode, 0, r.stderr)
            removes = [line for line in r.stdout.splitlines() if line.startswith('REMOVE')]
            self.assertEqual(removes, [expected] if expected else [])

    def test_safety_and_rotation_contract(self):
        s = (VERIFY / 'inner-rotation-back.sh').read_text()
        self.assertNotIn('force-stop', s)
        self.assertNotIn('pkill', s)
        self.assertNotIn('# screen: inner', s)
        self.assertNotIn('# needs: home', s)
        self.assertIn('app.s task $CAMTASK moved onto display', s)
        self.assertNotIn('CAMTASK=$(sed', s)
        self.assertIn('am stack remove $root', s)
        self.assertIn('seq 1 16', s)
        self.assertIn('[ "$r" = "$r0" ] || bad', s)
        self.assertIn('NOT EXERCISED', s)
        self.assertIn('alarm 12', s)
        self.assertLess(s.index('camera_snapshot "$OUT/before-setup"'), s.index('\nwwc_start\n'))


if __name__ == '__main__':
    unittest.main()
