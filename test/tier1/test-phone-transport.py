#!/usr/bin/env python3
"""Transport failures must not look like a busy phone or poison the state cache."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class TransportTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        docker = self.directory / 'docker'
        docker.write_text('''#!/bin/sh
case "$1" in
 inspect) echo "$MOCK_RUNNING" ;;
 exec)
   case "$*" in
     *get-state*) echo offline; exit 1 ;;
     *disconnect*) exit 0 ;;
     *wireguard*) exit 0 ;;
     *) echo unexpected-command >&2; exit 99 ;;
   esac ;;
 *) exit 99 ;;
esac
''')
        docker.chmod(0o755)
        self.env = dict(os.environ, PATH=f'{self.directory}:' + os.environ['PATH'],
                        POWOS_DEVICE='phone', MOCK_RUNNING='false',
                        POWOS_ADB_STATE_FILE=str(self.directory / 'state'))

    def run_script(self, name, *args):
        return subprocess.run(['bash', str(ROOT / 'tools/phone' / name), *args],
                              env=self.env, capture_output=True, text=True, timeout=5)

    def test_stopped_container_fails_even_with_cached_device(self):
        import time
        (self.directory / 'state').write_text(f'{int(time.time())} ok\n')
        result = self.run_script('adb.sh', 'shell', 'true')
        self.assertEqual(result.returncode, 70, result.stderr)
        self.assertIn('transport unavailable', result.stderr)

    def test_idle_wait_returns_transport_error_immediately(self):
        result = self.run_script('idle.sh', '--wait', '60', '240')
        self.assertEqual(result.returncode, 70, result.stderr)
        self.assertEqual(result.stdout.strip(), 'transport-error')

    def test_failed_reconnect_does_not_cache_success(self):
        self.env['MOCK_RUNNING'] = 'true'
        result = self.run_script('adb.sh', 'shell', 'true')
        self.assertEqual(result.returncode, 69, result.stderr)
        self.assertFalse((self.directory / 'state').exists())


if __name__ == '__main__':
    unittest.main()
