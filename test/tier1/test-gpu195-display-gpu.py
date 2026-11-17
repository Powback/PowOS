#!/usr/bin/env python3
"""Device-free test of hosts/gpu-195/display-gpu/install.sh: the display-GPU derivation, dry-run only (writes nothing).

A fake sysfs (DRM connectors -> PCI devices) and stub ip/nvidia-smi stand in for gpu-195; HOME is a temp dir."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
INSTALLER = ROOT / 'hosts/gpu-195/display-gpu/install.sh'
SMI = ('00000000:01:00.0, GPU-589a4c17-7c2d-78bc-1188-2aadb37ba2b4\n'
       '00000000:02:00.0, GPU-1a118f88-9cb5-2316-ddda-1ea80ff0af37\n')


class DisplayGpu(unittest.TestCase):
    def run_it(self, connected, ip='192.168.50.195', mode='--dry-run'):
        with tempfile.TemporaryDirectory() as tmp:
            t = Path(tmp)
            sysfs, home, bindir = t / 'sys', t / 'home', t / 'bin'
            for d in (home, bindir):
                d.mkdir()
            # gpu-195's real layout: card0 = 02:00.0, card1 = 01:00.0 (the monitor, HDMI-A-3).
            cards = {'card0': ('0000:02:00.0', ['DP-1', 'HDMI-A-1']), 'card1': ('0000:01:00.0', ['DP-4', 'HDMI-A-3'])}
            for card, (pci, conns) in cards.items():
                dev = sysfs / 'devices' / pci
                dev.mkdir(parents=True)
                drm = sysfs / 'class/drm'
                drm.mkdir(parents=True, exist_ok=True)
                (drm / card).mkdir()
                (drm / card / 'device').symlink_to(dev)
                for c in conns:
                    (drm / f'{card}-{c}').mkdir()
                    (drm / f'{card}-{c}' / 'status').write_text(
                        'connected\n' if f'{card}-{c}' in connected else 'disconnected\n')
            (bindir / 'ip').write_text(f'#!/bin/sh\necho "2: enp0s31f6    inet {ip}/24 brd x"\n')
            (bindir / 'nvidia-smi').write_text('#!/bin/sh\nprintf "%s" "$SMI_OUT"\n')
            for b in bindir.iterdir():
                b.chmod(0o755)
            env = dict(os.environ, HOME=str(home), POWOS_SYSFS=str(sysfs), POWOS_IP=str(bindir / 'ip'),
                       NVIDIA_SMI=str(bindir / 'nvidia-smi'), SMI_OUT=SMI, POWOS_UNITS_DIR=str(t / 'units'))
            r = subprocess.run(['bash', str(INSTALLER), mode], env=env, capture_output=True, text=True)
            self.assertEqual(list(home.rglob('*')), [], 'dry-run wrote under HOME')
            self.assertFalse((t / 'units').exists(), 'dry-run registered a unit')
            return r

    def test_monitor_on_gpu0_picks_its_uuid(self):
        r = self.run_it({'card1-HDMI-A-3'})
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('DXVK_FILTER_DEVICE_UUID=589a4c177c2d78bc11882aadb37ba2b4\n', r.stdout)
        self.assertIn('0000:01:00.0', r.stdout)

    def test_monitor_on_gpu1_follows_it(self):
        r = self.run_it({'card0-DP-1'})
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('DXVK_FILTER_DEVICE_UUID=1a118f889cb52316ddda1ea80ff0af37\n', r.stdout)

    def test_two_monitors_same_gpu_is_fine(self):
        r = self.run_it({'card1-HDMI-A-3', 'card1-DP-4'})
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_displays_on_both_gpus_is_ambiguous(self):
        r = self.run_it({'card1-HDMI-A-3', 'card0-DP-1'})
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('ambiguous', r.stderr)

    def test_no_display_fails(self):
        r = self.run_it(set())
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('no connected display', r.stderr)

    def test_other_hosts_refused(self):
        r = self.run_it({'card1-HDMI-A-3'}, ip='192.168.50.58')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('gpu-195 only', r.stderr)


if __name__ == '__main__':
    unittest.main()
