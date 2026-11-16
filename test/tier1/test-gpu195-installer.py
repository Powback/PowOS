#!/usr/bin/env python3
"""Device-free installer ownership regression; all host commands are sandboxed."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
INSTALLER = ROOT / 'hosts/gpu-195/install.sh'


class InstallerOwnership(unittest.TestCase):
    def run_install(self, no_build=False, missing=False):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            bindir = home / 'bin'
            bindir.mkdir()
            log = home / 'commands'
            quadlets = home / '.config/containers/systemd'
            pool = home / '.config/llm-pool'
            voice = home / '.config/voiceagent'
            for directory in (quadlets, pool, voice, home / 'Projects/VoiceAgent/.git'):
                directory.mkdir(parents=True, exist_ok=True)
            protected = [quadlets / 'llm-pool.container', pool / 'config.yaml',
                         pool / 'flash-next.json', pool / 'user-runtime-data']
            for path in protected:
                path.write_text('owner-managed sentinel\n')
            (voice / 'secrets.env').write_text('LITELLM_API_KEY=test-only\n')
            if missing:
                protected[0].unlink()
            # The installer never reaches real host commands. mkdir only logs its
            # /var/lib requests; HOME directories needed by install already exist.
            for command in ('mkdir', 'podman', 'systemctl', 'loginctl', 'python3'):
                script = bindir / command
                script.write_text('#!/bin/bash\nprintf "%s\\n" "' + command +
                                  ' $*" >> "$TEST_LOG"\n' +
                                  ('echo Linger=yes\n' if command == 'loginctl' else ''))
                script.chmod(0o755)
            env = dict(os.environ, HOME=str(home), USER='test', TEST_LOG=str(log),
                       VOICEAGENT_DIR=str(home / 'Projects/VoiceAgent'),
                       PATH=str(bindir) + ':/usr/bin:/bin')
            result = subprocess.run(['/bin/bash', str(INSTALLER)] +
                                    (['--no-build'] if no_build else []),
                                    env=env, capture_output=True, text=True)
            commands = log.read_text() if log.exists() else ''
            if missing:
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('local-llm-stack/hosts/gpu-195/install-llm-pool.sh', result.stderr)
                self.assertEqual(commands, '')
                self.assertEqual(sorted(p.name for p in quadlets.iterdir()), [])
                protected = protected[1:]
            else:
                self.assertEqual(result.returncode, 0, result.stderr)
                for name in ('voice.network', 'voice-stt.container', 'voice-tts.container',
                             'voice-llm.container', 'stt-batch.container',
                             'voice-llm-gateway.container', 'voice-agent.container',
                             'voice-web.container'):
                    self.assertEqual((quadlets / name).read_bytes(),
                                     (ROOT / 'hosts/gpu-195/quadlets' / name).read_bytes())
                self.assertEqual((voice / 'voiceagent.env').read_bytes(),
                                 (ROOT / 'hosts/gpu-195/voiceagent.env').read_bytes())
                self.assertIn('restart voice-agent.service voice-web.service', commands)
                self.assertIn('start voice-stt.service voice-tts.service voice-llm.service stt-batch.service voice-llm-gateway.service', commands)
                self.assertIn('voice-agent.json', commands)
                builds = [line for line in commands.splitlines() if line.startswith('podman build')]
                self.assertEqual(len(builds), 0 if no_build else 4)
                for line in builds:
                    self.assertIn('localhost/voice', line)
            self.assertNotIn('llm-pool', commands)
            self.assertNotIn('/models/strata', commands)
            for path in protected:
                self.assertEqual(path.read_text(), 'owner-managed sentinel\n')
            self.assertEqual((voice / 'secrets.env').read_text(), 'LITELLM_API_KEY=test-only\n')

    def test_default(self):
        self.run_install()

    def test_no_build(self):
        self.run_install(no_build=True)

    def test_missing_prerequisite_fails_before_mutation(self):
        self.run_install(missing=True)

    def test_gateway_does_not_start_external_pool(self):
        text = (ROOT / 'hosts/gpu-195/quadlets/voice-llm-gateway.container').read_text()
        for line in text.splitlines():
            if line.startswith(('Wants=', 'Requires=', 'BindsTo=', 'PartOf=')):
                self.assertNotIn('llm-pool', line)
        self.assertIn('llm-pool.service', text)


if __name__ == '__main__':
    unittest.main()
