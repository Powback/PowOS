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
                    if '--provides' in args:
                        return 'powos-gpu-unlock-profile-ampere'
                    return 'powos-gpu-unlock' if '--qf' in args else 'kernel-core-uname-r = ' + control.os.uname().release
                if args == ('mokutil', '--sb-state'):
                    return 'SecureBoot disabled'
                if args == ('rpm-ostree', 'status', '--json'):
                    return json.dumps({'deployments': [{'booted': True}]})
                raise AssertionError(args)
            with patch.object(control.sys, 'argv', ['control.py', 'enable', '--rpm', rpm.name]), \
                    patch.object(control.os, 'geteuid', return_value=0), \
                    patch.object(control, 'gpu_devices', return_value={'0000:01:00.0': '0x2204'}), \
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

    def test_nvidia_forced_before_unlock_rejected(self):
        deployment = {'osname': 'default', 'checksum': 'abc', 'serial': 0}
        for commandline in ['rd.driver.pre=nvidia rd.driver.pre=gpu_unlock',
                            'rd.driver.pre=nvidia_drm,gpu_unlock']:
            with patch.object(control, 'run', side_effect=['gpu_unlock.ko', '', commandline]):
                with self.assertRaisesRegex(RuntimeError, 'before gpu_unlock'):
                    control.check_image(deployment, 'test-kernel')

    def test_unlock_forced_before_nvidia_accepted(self):
        deployment = {'osname': 'default', 'checksum': 'abc', 'serial': 0}
        with patch.object(control, 'run', side_effect=[
                'gpu_unlock.ko', '', 'rd.driver.pre=gpu_unlock rd.driver.pre=nvidia']):
            control.check_image(deployment, 'test-kernel')

    def test_4090_requires_ada_profile(self):
        devices = {'0000:01:00.0': '0x2684'}
        with self.assertRaisesRegex(ValueError, 'unsupported'):
            control.validate_selection('ampere', 'all', devices)
        self.assertEqual(control.validate_selection('ada', 'all', devices), ('all', ['0000:01:00.0']))

    def test_5090_rejected_but_explicit_4090_on_mixed_host_allowed(self):
        devices = {'0000:01:00.0': '0x2684', '0000:02:00.0': '0x2b85'}
        with self.assertRaisesRegex(ValueError, 'Blackwell'):
            control.validate_selection('ada', 'all', devices)
        self.assertEqual(control.validate_selection('ada', '0000:01:00.0', devices)[1], ['0000:01:00.0'])

    def test_both_3090s_remain_selected(self):
        devices = {'0000:01:00.0': '0x2204', '0000:02:00.0': '0x2204'}
        self.assertEqual(len(control.validate_selection('ampere', 'all', devices)[1]), 2)

    def test_experimental_ada_ids_rejected(self):
        for device in ['0x2685', '0x2757', '0x2705']:
            with self.assertRaisesRegex(ValueError, 'unsupported'):
                control.validate_selection('ada', 'all', {'0000:01:00.0': device})

    def test_invalid_pci_selection_rejected(self):
        for selection in ['all,0000:01:00.0', '01:00.0', '0000:01:00.0,0000:01:00.0', '0000:09:00.0']:
            with self.assertRaises(ValueError):
                control.validate_selection('ada', selection, {'0000:01:00.0': '0x2684'})

    def test_explicit_targets_replace_all(self):
        self.assertEqual(control.karg_changes('quiet gpu_unlock.targets=all', True, '0000:01:00.0'), [
            '--delete-if-present=gpu_unlock.targets=all', '--append=gpu_unlock.targets=0000:01:00.0'])

    def test_staged_wrong_profile_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            metadata = Path(tmp) / 'usr/share/powos/gpu-unlock'
            metadata.mkdir(parents=True)
            (metadata / 'profile').write_text('ampere')
            (metadata / 'upstream-revision').write_text(control.PROFILES['ampere']['revision'])
            with patch.object(control, 'deployment_root', return_value=Path(tmp)):
                with self.assertRaisesRegex(RuntimeError, 'differs'):
                    control.check_profile({}, 'ada')

    def test_enable_without_rpm_reuses_deployed_package(self):
        with tempfile.TemporaryDirectory() as tmp:
            metadata = Path(tmp) / 'usr/share/powos/gpu-unlock'
            metadata.mkdir(parents=True)
            for key, value in {'profile': 'ampere', 'kernel': control.os.uname().release,
                               'upstream-revision': control.PROFILES['ampere']['revision']}.items():
                (metadata / key).write_text(value)
            state = {'kargs': 'quiet'}
            def read(*args):
                if args == ('rpm-ostree', 'status', '--json'):
                    return json.dumps({'deployments': [{'booted': True}]})
                if args == ('mokutil', '--sb-state'):
                    return 'SecureBoot disabled'
                if args == ('rpm-ostree', 'kargs'):
                    return state['kargs']
                raise AssertionError(args)
            def mutate(*args):
                if args[:2] == ('rpm-ostree', 'kargs'):
                    state['kargs'] = 'quiet gpu_unlock.targets=all'
            with patch.object(control.sys, 'argv', ['control.py', 'enable']), \
                    patch.object(control.os, 'geteuid', return_value=0), \
                    patch.object(control, 'deployment_root', return_value=Path(tmp)), \
                    patch.object(control, 'gpu_devices', return_value={'0000:01:00.0': '0x2204'}), \
                    patch.object(control, 'run', side_effect=read), \
                    patch.object(control, 'change', side_effect=mutate) as changes, \
                    patch.object(control, 'check_image'):
                control.main()
            self.assertEqual([c.args[:2] for c in changes.call_args_list], [
                ('rpm-ostree', 'initramfs'), ('rpm-ostree', 'kargs')])


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
