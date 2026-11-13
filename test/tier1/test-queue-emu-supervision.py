#!/usr/bin/env python3
"""Device-free lifecycle regression: isolated HOME/cache/queue, no launchctl or adb."""
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
VERIFY = ROOT / 'tools/phone/verify'


class EmulatorSupervision(unittest.TestCase):
    def test_service_contract(self):
        with (VERIFY / 'com.powos.verify-emu-runner.plist').open('rb') as f:
            p = plistlib.load(f)
        self.assertEqual(p['ProgramArguments'][-1], 'run-emu')
        self.assertTrue(p['RunAtLoad'])
        self.assertEqual(p['KeepAlive'], {'SuccessfulExit': False})
        self.assertGreaterEqual(p['ThrottleInterval'], 10)
        self.assertNotIn('StartInterval', p)
        self.assertNotIn('WatchPaths', p)

    def test_enqueue_only_kicks_emulator_agent(self):
        source = (VERIFY / 'queue.sh').read_text()
        start = source.index('    # Separate launchd supervision:')
        end = source.index('\n  elif [ -z "${QUEUE_NO_RUN:-}" ]; then', start)
        # Await the isolated fallback child before inspecting its redirected log.
        block = source[start:end].rsplit('\n    )', 1)[0] + '\n      wait\n    )'
        with tempfile.TemporaryDirectory(prefix='queue-emu-kick-') as temp:
            env = dict(os.environ, HOME=temp, QUEUE_DIR=temp, QUEUE_NO_TREE='1')
            env.pop('QUEUE_EMU_AGENT', None)
            script = '''
E=$HOME; QUEUE_AGENT=phone-test-agent
alive_runner() { return 1; }
agent_kick() { printf '%s %s\\n' "$LABEL" "$QUEUE_AGENT"; }
nohup() { echo fallback; }
'''
            result = subprocess.run(['bash', '-c', script + block], env=env,
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), '')
            self.assertEqual((Path(temp) / 'runner.log').read_text().strip(), 'fallback')
            env['QUEUE_EMU_AGENT'] = 'isolated-emu-test-agent'
            result = subprocess.run(['bash', '-c', script + block], env=env,
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(),
                             'isolated-emu-test-agent isolated-emu-test-agent')

    def test_timeout_preserves_job_and_foreign_lock_then_idle_exits(self):
        with tempfile.TemporaryDirectory(prefix='queue-emu-supervision-') as temp:
            t = Path(temp)
            q = t / 'queue'
            e = q / 'emu'
            e.mkdir(parents=True)
            job = e / 'old.job'
            job.write_text('task=old\ntries=0\ncmd=(false)\n')
            original = job.read_bytes()
            lock = t / '.cache/powos-emu.lock'
            lock.mkdir(parents=True)
            # This Python process is alive, but never the bash runner's owner PID.
            (lock / 'pid').write_text(str(os.getpid()) + '\n')
            (lock / 'label').write_text('foreign-owner\n')
            env = dict(os.environ, HOME=temp, XDG_CACHE_HOME=str(t / '.cache'),
                       QUEUE_DIR=str(q), QUEUE_NO_TREE='1')
            script = '''
REPO=$1; here=$2; E=$QUEUE_DIR/emu; Q=$QUEUE_DIR; phone=$3
QUEUE_COPY=$(mktemp -d "$HOME/copy.XXXXXX")
printf '%s' "$QUEUE_COPY" > "$HOME/copy-path"
alive_runner() { return 1; }
# Exercise all 240 bounded iterations immediately, without waiting four minutes.
# No emulator/adb command may be reached while the foreign lock is held.
sleep() { printf '. ' >> "$HOME/waits"; }
# Avoid hundreds of macOS process launches while preserving real directory/PID
# contention semantics. All other paths use the actual filesystem commands.
mkdir() {
  if [ "$#" = 1 ] && [ "$1" = "$HOME/.cache/powos-emu.lock" ] && [ -d "$1" ]; then return 1; fi
  command mkdir "$@"
}
cat() {
  if [ "$#" = 1 ] && [ "$1" = "$HOME/.cache/powos-emu.lock/pid" ]; then
    local pid; IFS= read -r pid < "$1" || return 1; printf '%s\\n' "$pid"
  else command cat "$@"; fi
}
. "$here/queue-emu.sh"
'''
            args = ['bash', '-c', script, '_', str(ROOT), str(VERIFY), str(t / 'no-phone')]
            # Model launchd's restart after a failed attempt, with the same durable job.
            for attempt in range(2):
                result = subprocess.run(args, env=env, capture_output=True, text=True, timeout=120)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn('could not acquire emulator lock', result.stdout)
                self.assertEqual(len((t / 'waits').read_text().split()), 240 * (attempt + 1))
                self.assertEqual(job.read_bytes(), original)
                self.assertEqual((lock / 'pid').read_text(), str(os.getpid()) + '\n')
                self.assertEqual((lock / 'label').read_text(), 'foreign-owner\n')
                self.assertFalse((e / 'runner.lock').exists())
                self.assertFalse(Path((t / 'copy-path').read_text()).exists())
            # The competing owner releases its own lock; the next supervised attempt
            # must really acquire it, execute the durable job, drain it and release it.
            (lock / 'pid').unlink()
            (lock / 'label').unlink()
            lock.rmdir()
            fake = t / 'checkout/tools/phone/verify'
            fake.mkdir(parents=True)
            (fake / 'queue-emu.sh').write_bytes((VERIFY / 'queue-emu.sh').read_bytes())
            emu = fake.parents[1] / 'emu/emu.sh'
            emu.parent.mkdir()
            emu.write_text('''#!/bin/bash
[ -d "$HOME/.cache/powos-emu.lock" ] || exit 91
printf '%s\\n' "$1" >> "$HOME/emu-calls"
''')
            emu.chmod(0o755)
            for name in ('adb.sh', 'user.sh'):
                stub = fake.parent / name
                stub.write_text('#!/bin/bash\nexit 0\n')
                stub.chmod(0o755)
            job.write_text('''task=old
tries=0
cmd=(bash -c 'test "$(cat "$HOME/.cache/powos-emu.lock/pid")" = "$PPID" && echo PASS')
''')
            success_script = script.replace('alive_runner() { return 1; }',
                                            'alive_runner() { return 1; }; verify_tree() { return 0; }; ET=unused')
            result = subprocess.run(['bash', '-c', success_script, '_', str(ROOT),
                                     str(fake), str(fake.parent)], env=env,
                                    capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertEqual((t / 'emu-calls').read_text().splitlines(), ['start', 'wake'])
            self.assertFalse(job.exists())
            self.assertTrue((q / 'done/old.job').exists())
            self.assertIn('PASS: PASS', (q / 'done/old.log').read_text())
            self.assertFalse(lock.exists())
            self.assertFalse((e / 'runner.lock').exists())
            self.assertFalse(Path((t / 'copy-path').read_text()).exists())
            # Drained queue: supervisor invocation succeeds without touching the emulator.
            result = subprocess.run(['bash', str(VERIFY / 'queue.sh'), 'run-emu'],
                                    env=env, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse((e / 'runner.lock').exists())
            self.assertFalse(lock.exists())
            self.assertEqual((t / 'emu-calls').read_text().splitlines(), ['start', 'wake'])


if __name__ == '__main__':
    unittest.main()
