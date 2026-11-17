#!/usr/bin/env python3
"""Device-free checks: gpu-195 voice units name their GPU by CDI UUID, units match quadlets, gateway GPU0 lease lock."""
import ast
import asyncio
import fcntl
import json
import logging
import os
import tempfile
import time
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


class GatewayLease(unittest.TestCase):
    """Real flock on a tmp lock: the gateway's wake waits for a GPU0 borrower and never preempts it."""

    def setUp(self):
        src = (ROOT / 'hosts/gpu-195/voice-llm-gateway/gateway.py').read_text()
        self.src = src
        tree = ast.parse(src)
        wanted = {'lease_holder', 'take_gpu0_wake_room', 'release_gpu0_wake_room'}
        fns = [n for n in tree.body if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)) and n.name in wanted]
        self.assertEqual({f.name for f in fns}, wanted)
        self.tmp = tempfile.TemporaryDirectory()
        self.lock = Path(self.tmp.name) / 'gpu0-wake-room.lock'
        self.lock.write_text('')
        self.scope = {'os': os, 'fcntl': fcntl, 'time': time, 'asyncio': asyncio, 'Path': Path,
                      'log': logging.getLogger('test'), 'GPU0_LEASE_LOCK': self.lock, 'GPU_DRAIN_TIMEOUT': 1}
        exec(compile(ast.Module(fns, []), 'gateway', 'exec'), self.scope)

    def tearDown(self):
        self.tmp.cleanup()

    def borrower(self):
        fd = os.open(self.lock, os.O_RDWR)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        os.pwrite(fd, b'{"holder": "swift-27b"}', 0)
        return fd

    def test_wake_waits_for_borrower_then_proceeds(self):
        fd = self.borrower()  # started, maybe not allocated yet: the lock alone blocks the wake

        async def scenario():
            asyncio.get_running_loop().call_later(0.3, os.close, fd)  # model unloads naturally
            return await self.scope['take_gpu0_wake_room']()
        held = asyncio.run(scenario())
        self.assertIsInstance(held, int)
        other = os.open(self.lock, os.O_RDWR)
        with self.assertRaises(BlockingIOError):  # a launcher can't borrow while voice wakes
            fcntl.flock(other, fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.scope['release_gpu0_wake_room'](held)
        fcntl.flock(other, fcntl.LOCK_EX | fcntl.LOCK_NB)
        os.close(other)

    def test_bounded_wait_names_holder_and_leaves_borrower(self):
        fd = self.borrower()
        with self.assertRaisesRegex(RuntimeError, 'swift-27b'):
            asyncio.run(self.scope['take_gpu0_wake_room']())
        with self.assertRaises(BlockingIOError):  # still held: the gateway did not interrupt the model
            probe = os.open(self.lock, os.O_RDWR)
            try:
                fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
            finally:
                os.close(probe)
        os.close(fd)

    def test_missing_lock_wakes_voice(self):
        self.lock.unlink()
        self.assertIsNone(asyncio.run(self.scope['take_gpu0_wake_room']()))
        self.assertFalse(self.lock.exists())

    def test_wake_order_and_wiring(self):
        body = self.src[self.src.index('async def wake_voice_if_needed'):]
        self.assertLess(body.index('write_state("waking")'), body.index('await take_gpu0_wake_room()'))
        self.assertIn('release_gpu0_wake_room(lease)', body)
        quadlet = (QUADLETS / 'voice-llm-gateway.container').read_text()
        self.assertIn('Volume=/var/lib/powos/gpu-lease:/gpu-lease\n', quadlet)
        self.assertIn('"/gpu-lease/gpu0-wake-room.lock"', self.src)
        self.assertIn('gpu0-wake-room.lock', (ROOT / 'hosts/gpu-195/install.sh').read_text())
        for name in ('voice-llm-gateway', 'llm-pool'):
            files = json.loads((UNITS / f'{name}.json').read_text())['files']
            self.assertIn('/var/lib/powos/gpu-lease/gpu0-wake-room.lock', files)


if __name__ == '__main__':
    unittest.main()
