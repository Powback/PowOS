#!/usr/bin/env python3
"""Device-free build orchestration regressions; no compiler/network/container calls."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / 'hosts/gpu-195/gpu-unlock'
CURRENT = '7.2.9-current.x86_64'
TARGET = '7.3.0-candidate.x86_64'

# Every external operation capable of downloading/building is a command stub.
STUB = r'''#!/usr/bin/env python3
import json, os, pathlib, shutil, sys
name = pathlib.Path(sys.argv[0]).name
a = sys.argv[1:]
with open(os.environ['CALLS'], 'a') as f:
    f.write(json.dumps([name] + a) + '\n')
if name == 'uname':
    print(os.environ['CURRENT'] if a == ['-r'] else 'x86_64')
elif name == 'make':
    if 'kernelrelease' in a:
        print(os.environ['HEADER_RELEASE'])
    elif any(x.startswith('KDIR=') for x in a):
        p = pathlib.Path(a[a.index('-C') + 1]) / 'gpu_unlock.ko'
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text('stub module')
    elif 'install-dracut' in a:
        dest = pathlib.Path(next(x[8:] for x in a if x.startswith('DESTDIR=')))
        (dest / 'usr/lib/dracut/dracut.conf.d').mkdir(parents=True)
    if os.environ.get('FAIL_MAKE') in a:
        sys.exit(1)
elif name == 'modinfo':
    print(os.environ.get('VERMAGIC', os.environ['HEADER_RELEASE']) + ' SMP')
elif name == 'git':
    if a[0] == 'clone':
        (pathlib.Path(a[-1]) / '.git').mkdir(parents=True)
elif name == 'tar':
    if '-xf' in a:
        dest = pathlib.Path(a[a.index('-C') + 1])
        (dest / 'VERSION').write_text(os.environ['VERSION'])
elif name == 'install':
    # Portable equivalent of GNU install's -D used by the production script.
    src, dest = map(pathlib.Path, a[-2:])
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy(src, dest)
elif name == 'podman' and a[0] == 'run':
    dest = pathlib.Path(a[a.index('-v') + 1].removesuffix(':/build'))
    defines = [a[i+1] for i, x in enumerate(a) if x == '--define']
    values = dict(x.split(' ', 1) for x in defines)
    spec = (dest / 'SPECS/gpu-unlock.spec').read_text()
    assert 'Requires: kernel-core-uname-r = %{kver}' in spec
    rpm = dest / 'RPMS/x86_64' / ('powos-gpu-unlock-%s-%s.x86_64.rpm' % (values['unlock_version'], values['unlock_release']))
    rpm.parent.mkdir(parents=True, exist_ok=True)
    rpm.write_text(values['kver'])
elif name == 'sha256sum':
    assert pathlib.Path(a[0]).is_file()
'''


class BuildTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.here = self.base / 'hosts/gpu-195/gpu-unlock'
        shutil.copytree(BUILD, self.here)
        unit = self.base / 'units/gpu-195'
        unit.mkdir(parents=True)
        shutil.copy(ROOT / 'units/gpu-195/gpu-unlock.json', unit)
        self.headers = self.base / 'headers'
        (self.headers / CURRENT).mkdir(parents=True)
        (self.headers / TARGET).mkdir()
        # Only relocate the system header directory into the fixture; production
        # argument parsing, release checks, cache layout and commands run intact.
        script = self.here / 'build.sh'
        script.write_text(script.read_text().replace('/usr/src/kernels/', str(self.headers) + '/'))
        self.bin = self.base / 'bin'
        self.bin.mkdir()
        for name in ('uname', 'make', 'modinfo', 'git', 'tar', 'install', 'podman', 'sha256sum'):
            path = self.bin / name
            path.write_text(STUB)
            path.chmod(0o755)
        self.cache = self.base / 'cache'
        self.log = self.base / 'calls'
        self.env = dict(os.environ, PATH=str(self.bin) + ':' + os.environ['PATH'],
                        GPU_UNLOCK_CACHE=str(self.cache), CALLS=str(self.log),
                        CURRENT=CURRENT, HEADER_RELEASE=CURRENT, VERSION='1.0.0')

    def run_build(self, *args, release=CURRENT, **env):
        return subprocess.run(['bash', str(self.here / 'build.sh'), *args],
                              env=dict(self.env, HEADER_RELEASE=release, **env),
                              text=True, capture_output=True)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def rpm(self, kernel, profile='ampere', version='1.0.0-4'):
        return self.cache / profile / 'kernels' / kernel / 'rpmbuild/RPMS/x86_64' / ('powos-gpu-unlock-' + version + '.x86_64.rpm')

    def test_default_and_isolation(self):
        result = self.run_build()
        self.assertEqual(result.returncode, 0, result.stderr)
        current = self.rpm(CURRENT)
        self.assertEqual(current.read_text(), CURRENT)
        before = current.stat().st_mtime_ns
        custom = self.base / 'custom headers'
        custom.mkdir()
        result = self.run_build('--kernel', TARGET, '--kdir', str(custom), release=TARGET)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.rpm(TARGET).read_text(), TARGET)
        self.assertEqual(current.stat().st_mtime_ns, before)
        calls = self.calls()
        for kernel, headers in ((CURRENT, self.headers / CURRENT), (TARGET, custom)):
            self.assertTrue(any('KDIR=' + str(headers) in c for c in calls))
            self.assertTrue(any('kver ' + kernel in c for c in calls))
        for c in calls:
            if c[0] == 'make' and 'assets' in c:
                self.assertTrue(any('/kernels/' in x for x in c if x.startswith('ASSETS=')))
        self.assertTrue(any('test' in c for c in calls))

    def test_mismatch_before_sources_or_build(self):
        result = self.run_build('--kernel', TARGET, '--kdir', str(self.headers / TARGET))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Header kernelrelease mismatch', result.stderr)
        self.assertFalse(self.cache.exists())
        self.assertTrue(all(c[0] == 'uname' or 'kernelrelease' in c for c in self.calls()))

    def test_vermagic_still_required(self):
        result = self.run_build(VERMAGIC=TARGET)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(c[0] == 'podman' for c in self.calls()))

    def test_ada_profile_and_target_default_headers(self):
        result = self.run_build('ada', '--kernel', TARGET, release=TARGET, VERSION='1.1.1')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(any('test-full' in c for c in self.calls()))
        self.assertEqual(self.rpm(TARGET, 'ada', '1.1.1-3').read_text(), TARGET)

    def test_asset_and_upstream_test_failures_block_packaging(self):
        for stage in ('assets', 'test'):
            with self.subTest(stage=stage):
                self.log.write_text('')
                result = self.run_build(FAIL_MAKE=stage)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(any(c[0] == 'podman' for c in self.calls()))

    def test_bad_profile_or_target_rejected(self):
        for args in [('blackwell',), ('--kernel', '../bad'), ('--kernel',), ('--unknown',)]:
            with self.subTest(args=args):
                self.assertNotEqual(self.run_build(*args).returncode, 0)
                self.assertFalse(self.cache.exists())


if __name__ == '__main__':
    unittest.main()
