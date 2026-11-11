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
 'am start -W -n com.termux/.app.TermuxActivity') touch "$STATE/launched"; if [ "$scenario" = hot ]; then printf 'Status: ok\nLaunchState: HOT\n'; else printf 'Status: ok\nLaunchState: COLD\n'; fi ;;
 *) echo "Unexpected: $*" >&2; exit 9 ;;
 esac
}
''' + SETUP + '\nprintf "owned=%s\\n" "$STARTED"\n'
            result = subprocess.run(['bash', '-c', script, 'test', d, scenario], capture_output=True, text=True)
            return result, (root / 'calls').read_text()

    def test_rotation_rejects_wrong_screen_in_both_orientations(self):
        source = (ROOT / 'tools/phone/verify/rotate-repro.sh').read_text()
        body = source.split('assert_home_screen() {', 1)[1].split('\n}\n', 1)[0]
        script = 'HOME_ICONS=1; QUEUE_SCREEN=$1; dims_test=$2; sh_() { echo "Physical size: $dims_test"; }; log() { :; }; assert_home_screen() {' + body + '\n}\nassert_home_screen'
        for screen, dims, rc in [('cover', '2268x2440', 3), ('cover', '2440x2268', 3),  # wrong screen: rc 3, the queue waits for it
                                  ('cover', '1116x2484', 0), ('cover', '2484x1116', 0),
                                  ('inner', '2268x2440', 0), ('inner', '2440x2268', 0),
                                  ('inner', '1116x2484', 3), ('', '1116x2484', 5),
                                  ('cover', 'garbage', 5), ('cover', '1000x1000', 5)]:
            with self.subTest(screen=screen, dims=dims):
                result = subprocess.run(['bash', '-c', script, 'test', screen, dims], capture_output=True, text=True)
                self.assertEqual(result.returncode, rc, result.stdout + result.stderr)
        queue = (ROOT / 'tools/phone/verify/queue.sh').read_text()
        self.assertIn('QUEUE_SCREEN="$screen"', queue)
        self.assertIn('assert_home_screen\ne2e_setup\nassert_home_screen', source)
        self.assertIn('chk "$name rotation $r"\n    assert_home_screen', source)

    def test_rotation_spacing_uses_existing_restoration_frame(self):
        source = (ROOT / 'tools/phone/verify/rotate-repro.sh').read_text()
        self.assertIn('--home-icons) HOME_ICONS=1', source)
        self.assertIn('for r in 1 2 3 0', source)
        self.assertIn('shell_check home dock-search-check.js homeIconsClearNow', source)
        self.assertIn('rot_restore; (exit $rc); e2e_abort', source)
        self.assertIn('chk "$name rotation $r"', source)
        # Source the library in a subshell: its variables cannot overwrite e2e's state/restore paths.
        self.assertIn('icons=$(SHELL_CHECK_LIB=1 .', source)

    def test_actual_oxygenos_task_records(self):
        parser = SOURCE.split('termux_task_ids() {', 1)[1].split('\n}\n', 1)[0]
        fixture = """  * Recent #1: Task{a202015 #3414 type=standard A=10362:com.termux}
    mActivityComponent=com.termux/.app.TermuxActivity
    taskId=3414 rootTaskId=3414
  * Recent #2: Task{dee6929 #3417 type=standard A=10359:.lock}
    mActivityComponent=com.powos.app/.lock
  Visible recent tasks (most recent first):
  * RecentTaskInfo #0:
    id=3414 userId=0 hasTask=true lastActiveTime=70920284
    realActivity={com.termux/com.termux.app.TermuxActivity}
  * RecentTaskInfo #1:
    id=3202 userId=0 hasTask=false
    realActivity={com.oplus.pscanvas/.Canvas}
"""
        r = subprocess.run(['bash', '-c', parser], input=fixture, capture_output=True, text=True, check=True)
        self.assertEqual(r.stdout.strip(), '3414')
        # Legacy Android format and multiple sessions must remain distinct, never the Recent # index.
        legacy = '* Recent #9: Task{abc #42 type=standard}\n realActivity=com.termux/.app.TermuxActivity\n* Recent #0: Task{def #55 type=standard}\n realActivity=com.termux/.app.TermuxActivity\n'
        r = subprocess.run(['bash', '-c', parser], input=legacy, capture_output=True, text=True, check=True)
        self.assertEqual(r.stdout.split(), ['42', '55'])

    def test_existing_task_untouched(self):
        r, calls = self.run_setup('existing-task')
        self.assertEqual(r.returncode, 5, r.stderr)
        self.assertNotIn('am start', calls)
        self.assertNotIn('remove-owned', calls)

    def test_hot_launch_never_claimed(self):
        r, calls = self.run_setup('hot')
        self.assertEqual(r.returncode, 5, r.stderr)
        self.assertNotIn('remove-owned', calls)
        self.assertIn('leaving Termux untouched', r.stdout)

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

    def run_open(self, states):
        """open_switcher against scripted page answers (one per poll); returns (rc, stdout, presses)."""
        body = SOURCE.split('open_switcher() {', 1)[1].split('\n}\n', 1)[0]
        script = ('P=0; I=0; F=$2; read -ra S <<<"$1"; sleep() { :; }\n'
                  'sh_() { [ "$*" = "input keyevent KEYCODE_APP_SWITCH" ] && P=$((P+1)) && echo $P > "$F"; }\n'
                  'sw_state() { echo "${S[$I]:-false/false}"; }\n'
                  'open_switcher() {' + body.replace('st=$(sw_state)', 'st=$(sw_state); I=$((I+1))') + '\n}\n'
                  'open_switcher')
        import tempfile
        with tempfile.NamedTemporaryFile('r') as f:
            r = subprocess.run(['bash', '-c', script, 'test', ' '.join(states), f.name], capture_output=True, text=True)
            return r.returncode, r.stdout, int(f.read().strip() or 0)

    def test_switcher_opened_on_first_press(self):
        self.assertEqual(self.run_open(['false/false', 'true/true'])[::2], (0, 1))

    def test_lost_press_pressed_again_never_toggled_back(self):
        rc, _, presses = self.run_open(['false/false'] * 6 + ['true/true'])
        self.assertEqual((rc, presses), (0, 2))

    def test_never_opened_fails_named(self):
        rc, out, presses = self.run_open([])
        self.assertEqual((rc, presses), (1, 3))
        self.assertIn('opened no switcher', out)

    def test_host_open_page_closed_is_reported_not_retoggled(self):
        rc, out, presses = self.run_open(['true/false'] * 6)
        self.assertEqual((rc, presses), (1, 1))
        self.assertIn('recents key is dead', out)

    def test_check_reads_page_only_after_open(self):
        self.assertLess(SOURCE.index('if ! why=$(open_switcher)'), SOURCE.index('switcherBackgroundNow Termux'))

if __name__ == '__main__':
    unittest.main()
