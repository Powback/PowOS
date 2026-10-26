#!/usr/bin/env python3
"""Offline checks for next-boot-only activation and benchmark validation."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'hosts/gpu-195/gpu-unlock' / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


control = load('gpu_unlock_control', 'control.py')
bench = load('gpu_unlock_bench', 'bench.py')


class ToggleTests(unittest.TestCase):
    def test_replace_old_single_gpu_target(self):
        self.assertEqual(control.karg_changes('quiet gpu_unlock.targets=0000:02:00.0 root=UUID=x', True), [
            '--delete-if-present=gpu_unlock.targets=0000:02:00.0', '--append=gpu_unlock.targets=all'])
        self.assertEqual(control.karg_changes('quiet gpu_unlock.targets=all', True), [])

    def test_disable_clears_every_target(self):
        self.assertEqual(control.karg_changes('quiet gpu_unlock.targets=all gpu_unlock.targets=0000:01:00.0', False), [
            '--delete-if-present=gpu_unlock.targets=all', '--delete-if-present=gpu_unlock.targets=0000:01:00.0'])

    def test_failed_image_verification_never_sets_targets(self):
        with tempfile.NamedTemporaryFile(suffix='.rpm') as rpm:
            def read(*args):
                if args[:2] == ('rpm', '-qp'):
                    return 'powos-gpu-unlock' if '--qf' in args else 'kernel-core-uname-r = ' + control.os.uname().release
                if args == ('mokutil', '--sb-state'):
                    return 'SecureBoot disabled'
                if args == ('rpm-ostree', 'status', '--json'):
                    return json.dumps({'deployments': [{'booted': True}]})
                raise AssertionError(args)
            with patch.object(control.sys, 'argv', ['control.py', 'enable', '--rpm', rpm.name]), \
                    patch.object(control.os, 'geteuid', return_value=0), \
                    patch.object(control, 'run', side_effect=read), \
                    patch.object(control, 'change') as changes, \
                    patch.object(control, 'check_image', side_effect=RuntimeError('missing firmware')):
                with self.assertRaisesRegex(RuntimeError, 'missing firmware'):
                    control.main()
                self.assertEqual([c.args[:2] for c in changes.call_args_list], [
                    ('rpm-ostree', 'install'), ('rpm-ostree', 'initramfs')])

    def test_missing_firmware_rejected(self):
        deployment = {'osname': 'default', 'checksum': 'abc', 'serial': 0}
        with patch.object(control, 'run', side_effect=['gpu_unlock.ko', 'gpu-unlock/missing.bin']):
            with self.assertRaisesRegex(RuntimeError, 'missing firmware'):
                control.check_image(deployment, 'test-kernel')


class BenchmarkTests(unittest.TestCase):
    def reports(self):
        before = dict.fromkeys(['schema', 'kernel', 'torch', 'cuda', 'uuid', 'driver', 'n', 'samples', 'warmups', 'seed'], 'same')
        before.update(boot_id='boot-1', results={m: {'correct': True, 'output_sha256': 'hash', 'tflops': 50.0} for m in ['fp16', 'bf16', 'tf32']})
        after = json.loads(json.dumps(before))
        after['boot_id'] = 'boot-2'
        return before, after

    def test_different_card_rejected(self):
        before, after = self.reports()
        after['uuid'] = 'different'
        with self.assertRaisesRegex(ValueError, 'uuid'):
            bench.compare(before, after)

    def test_same_boot_rejected(self):
        before, after = self.reports()
        after['boot_id'] = before['boot_id']
        with self.assertRaisesRegex(ValueError, 'same boot'):
            bench.compare(before, after)

    def test_fast_but_wrong_output_rejected(self):
        before, after = self.reports()
        after['results']['fp16'].update(output_sha256='wrong', tflops=100)
        with self.assertRaisesRegex(ValueError, 'fingerprint'):
            bench.compare(before, after)


if __name__ == '__main__':
    unittest.main()
