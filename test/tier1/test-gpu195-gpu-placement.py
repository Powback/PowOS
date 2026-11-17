#!/usr/bin/env python3
"""Device-free checks: gpu-195 voice units name their GPU by CDI UUID, units match quadlets, gateway borrower logic."""
import ast
import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
QUADLETS = ROOT / 'hosts/gpu-195/quadlets'
UNITS = ROOT / 'units/gpu-195'
GPU0 = 'GPU-589a4c17-7c2d-78bc-1188-2aadb37ba2b4'  # PCI 01:00.0, monitor/games, CDI "0" = /dev/nvidia1
GPU1 = 'GPU-1a118f88-9cb5-2316-ddda-1ea80ff0af37'  # PCI 02:00.0, CDI "1" = /dev/nvidia0
EXPECTED = {'voice-stt': GPU1, 'voice-tts': GPU1, 'stt-batch': GPU1, 'voice-llm': GPU0}


def devices(name):
    return re.findall(r'^AddDevice=nvidia\.com/gpu=(\S+)$', (QUADLETS / f'{name}.container').read_text(), re.M)


class Placement(unittest.TestCase):
    def test_voice_units_pinned_by_uuid(self):
        for name, uuid in EXPECTED.items():
            self.assertEqual(devices(name), [uuid], name)

    def test_one_device_per_voice_container(self):
        # One injected device means CUDA index 0 inside is that card; the services use the default device.
        for name in EXPECTED:
            text = (QUADLETS / f'{name}.container').read_text()
            self.assertNotIn('CUDA_VISIBLE_DEVICES', text, name)
            self.assertNotRegex(text, r'WHISPER__DEVICE_INDEX=[1-9]', name)

    def test_unit_manifests_match_quadlets(self):
        for name, uuid in EXPECTED.items():
            self.assertEqual(json.loads((UNITS / f'{name}.json').read_text())['gpu'], f'nvidia.com/gpu={uuid}', name)

    def test_descriptions_name_the_card(self):
        for name in ('voice-stt', 'voice-tts'):
            desc = re.search(r'^Description=(.*)$', (QUADLETS / f'{name}.container').read_text(), re.M).group(1)
            self.assertIn('GPU1', desc)
            self.assertNotIn('GPU0', desc)

    def test_no_index_names_left(self):
        for path in QUADLETS.glob('*.container'):
            if path.stem == 'llm-pool':
                continue
            for dev in re.findall(r'^AddDevice=nvidia\.com/gpu=(\S+)$', path.read_text(), re.M):
                self.assertTrue(dev.startswith('GPU-'), f'{path.name}: {dev}')


class GatewayBorrowers(unittest.TestCase):
    def load(self):
        src = (ROOT / 'hosts/gpu-195/voice-llm-gateway/gateway.py').read_text()
        tree = ast.parse(src)
        fn = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == 'running_borrowers')
        scope = {'WAKE_BORROWERS': frozenset({'flash-next', 'swift-27b', 'nanbeige-33b'})}
        exec(compile(ast.Module([fn], []), 'gateway', 'exec'), scope)
        return scope['running_borrowers'], src

    def test_running_borrowers(self):
        running_borrowers, _ = self.load()
        self.assertEqual(running_borrowers([{'model': 'general'}, {'model': 'embed'}]), [])
        self.assertEqual(running_borrowers([{'model': 'swift-27b'}, {'model': 'embed'}]), ['swift-27b'])
        self.assertEqual(running_borrowers([{'model': 'flash-next'}, {}]), ['flash-next'])

    def test_default_and_quadlet_lists_agree(self):
        _, src = self.load()
        default = re.search(r'"VOICE_WAKE_BORROWERS", "([^"]+)"', src).group(1)
        quadlet = re.search(r'^Environment=VOICE_WAKE_BORROWERS=(\S+)$',
                            (QUADLETS / 'voice-llm-gateway.container').read_text(), re.M).group(1)
        self.assertEqual(set(default.split(',')), set(quadlet.split(',')))
        self.assertEqual(set(quadlet.split(',')), {'flash-next', 'swift-27b', 'nanbeige-33b'})

    def test_wake_waits_on_borrowers(self):
        _, src = self.load()
        self.assertIn('await free_gpu0_wake_room()', src)
        self.assertNotIn('free_dual_gpu_flash_next', src)


if __name__ == '__main__':
    unittest.main()
