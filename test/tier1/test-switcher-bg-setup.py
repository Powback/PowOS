#!/usr/bin/env python3
"""Run the actual fixture setup against command responses, never against a device."""
import pathlib
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SOURCE = (ROOT / 'tools/phone/verify/switcher-bg.sh').read_text()
SETUP = SOURCE.split('# Start a real terminal session', 1)[1].split('sh_ "am start -W -a android.intent.action.MAIN', 1)[0]
SETUP = '# Start a real terminal session' + SETUP


class Setup(unittest.TestCase):
    def run_setup(self, scenario):
        # Function state lives in a file because sh_ is normally called through command substitution.
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            root = pathlib.Path(d)
            (root / 'cdp.sh').write_text('#!/bin/bash\necho "remove-owned $*" >> "$CALLS"\ntouch "$STATE/removed"\n')
            (root / 'cdp.sh').chmod(0o755)
            script = '''
set -u
T=$1; STATE=$1; CALLS=$1/calls; export STATE CALLS
scenario=$2; STARTED=
sleep() { :; }
sh_() {
 echo "$*" >> "$CALLS"
 case "$*" in
 'dumpsys activity recents')
   if [ "$scenario" = existing-task ] || { [ -f "$STATE/launched" ] && [ ! -f "$STATE/removed" ]; }; then
     printf '  * Recent #0: Task{abc #42 type=standard}\n    realActivity=com.termux/.app.TermuxActivity\n'
   fi ;;
 'pidof com.termux')
   if [ "$scenario" = existing-service ] || [ -f "$STATE/launched" ]; then echo 123; fi ;;
 'cmd package resolve-activity --brief com.termux') echo 'com.termux/.app.TermuxActivity' ;;
 'am start -W -n com.termux/.app.TermuxActivity') touch "$STATE/launched"; echo 'Status: ok' ;;
 *) echo "Unexpected: $*" >&2; exit 9 ;;
 esac
}
''' + SETUP + '\nprintf "owned=%s\\n" "$STARTED"\n'
            result = subprocess.run(['bash', '-c', script, 'test', d, scenario], capture_output=True, text=True)
            return result, (root / 'calls').read_text()

    def test_rotation_spacing_uses_existing_restoration_frame(self):
        source = (ROOT / 'tools/phone/verify/rotate-repro.sh').read_text()
        self.assertIn('--home-icons) HOME_ICONS=1', source)
        self.assertIn('for r in 1 2 3 0', source)
        self.assertIn('shell_check home dock-search-check.js homeIconsClearNow', source)
        self.assertIn('rot_restore; (exit $rc); e2e_abort', source)
        self.assertIn('chk "$name rotation $r"', source)
        # Source the library in a subshell: its variables cannot overwrite e2e's state/restore paths.
        self.assertIn('icons=$(SHELL_CHECK_LIB=1 .', source)

    def test_existing_task_untouched(self):
        r, calls = self.run_setup('existing-task')
        self.assertEqual(r.returncode, 5, r.stderr)
        self.assertNotIn('am start', calls)
        self.assertNotIn('remove-owned', calls)

    def test_existing_service_reused(self):
        r, calls = self.run_setup('existing-service')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('owned=\n', r.stdout)
        self.assertNotIn('am start', calls)
        self.assertNotIn('remove-owned', calls)

    def test_new_session_supported_launcher_and_only_owned_task(self):
        r, calls = self.run_setup('fresh')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('owned=1', r.stdout)
        self.assertIn('am start -W -n com.termux/.app.TermuxActivity', calls)
        self.assertIn('powos.tasks.remove(42)', calls)
        self.assertNotIn('start-foreground-service', calls)


if __name__ == '__main__':
    unittest.main()
