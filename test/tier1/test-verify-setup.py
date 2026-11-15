#!/usr/bin/env python3
"""Device-free regressions for verification prerequisites, cleanup and dock discovery."""
import os
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
VERIFY = ROOT / "tools/phone/verify"
HUNG = (VERIFY / "kwin-hung-client.sh").read_text()
DESKTOP = (VERIFY / "e2e-desktop.sh").read_text()


def function(source, name, next_marker):
    return source[source.index(name + "() {"):source.index(next_marker, source.index(name + "() {"))]


def shell(code, env=None):
    return subprocess.run(["bash", "-c", code], text=True, capture_output=True,
                          timeout=8, env={**os.environ, **(env or {})})


class VerifySetup(unittest.TestCase):
    def test_preconditions_never_restore(self):
        for wake in ("", "Asleep", "Awake"):
            with self.subTest(wake=wake), tempfile.TemporaryDirectory() as tmp:
                t = pathlib.Path(tmp)
                v = t / "verify"
                v.mkdir()
                (v / "kwin-hung-client.sh").write_text(HUNG)
                (v / "window-lock.sh").write_text("window_lock() { :; }; wl_release() { echo released; }\n")
                (v / "ww-lib.sh").write_text("")
                (v / "game-lib.sh").write_text("game_gate() { :; }\n")
                (t / "adb.sh").write_text('#!/bin/bash\ncase "$*" in *"dumpsys power"*) echo "$WAKE" ;; *"pgrep -u powos -x kwin_wayland"*) echo none ;; *) echo UNEXPECTED >&2; exit 99 ;; esac\n')
                (t / "adb.sh").chmod(0o755)
                (t / "user.sh").write_text("#!/bin/bash\necho none\n")
                (t / "user.sh").chmod(0o755)
                r = subprocess.run(["bash", str(v / "kwin-hung-client.sh"), str(t / "out")],
                                   text=True, capture_output=True, timeout=8,
                                   env={**os.environ, "WAKE": wake})
                self.assertEqual(r.returncode, 5 if wake == "Awake" else 3, r.stderr)
                self.assertIn("released", r.stdout)
                self.assertNotIn("restored", r.stdout)
                self.assertNotIn("UNEXPECTED", r.stderr)

    def test_kwin_query_distinguishes_absence_and_failure(self):
        query = function(HUNG, "linux_pids", 'killers() {')
        for rc, output, expected_rc, expected in ((0, "42\n43", 0, "42"),
                                                  (1, "", 0, "none"),
                                                  (127, "", 1, ""),
                                                  (2, "", 1, "")):
            with self.subTest(rc=rc):
                r = shell('set -o pipefail\n'
                          'chroot() { [ "$*" = "/data/powos/root /usr/bin/pgrep -u powos -x kwin_wayland" ] || exit 99; printf "%s" "$OUTPUT"; return "$RC"; }; export -f chroot\n'
                          'us() { echo WRONG-TRANSPORT; return 99; }; sh_() { bash -c "$1"; }\n' + query + '\nkwin_pid',
                          {"RC": str(rc), "OUTPUT": output})
                self.assertEqual(r.returncode, expected_rc, r.stderr)
                self.assertEqual(r.stdout.strip(), expected)
        for response in ('return 124', 'echo garbage', ':'):
            r = shell('sh_() { ' + response + '; }\n' + query + '\nkwin_pid')
            self.assertEqual(r.returncode, 1)
            self.assertNotIn("none", r.stdout)
        setup = HUNG[HUNG.index('K0=$(kwin_pid)'):HUNG.index('# No cleanup is armed')]
        r = shell('kwin_pid() { return 1; }\n' + setup)
        self.assertEqual(r.returncode, 1)
        self.assertIn("FAIL: could not query", r.stdout)
        self.assertNotIn("ENV:", r.stdout)

    def test_ownership_guards_use_authoritative_lookup(self):
        query = function(HUNG, "linux_pids", 'killers() {')
        kwrite_guard = HUNG[HUNG.index('existing=$(linux_pids'):HUNG.index('I0=$(irq)')]
        kate_guard = HUNG[HUNG.index('  kate_before=$(linux_pids'):HUNG.index('  [ "$(plaunch')]
        for app, guard in (("kwrite", kwrite_guard), ("kate", kate_guard)):
            for response, owns in (("echo none", True), ("echo 123", False), ("return 124", False)):
                with self.subTest(app=app, response=response):
                    # Session-user lookup lies about absence. It must never be used.
                    r = shell('us() { echo none; }; sh_() { ' + response + '; }\n'
                              'fail() { echo FAIL; exit 1; }; KATE_MINE=0\n' + query +
                              '\n' + guard + '\necho accepted:$KATE_MINE')
                    if app == "kwrite":
                        self.assertEqual("accepted:" in r.stdout, owns)
                    else:
                        self.assertEqual("accepted:1" in r.stdout, owns)
                        if response == "return 124":
                            self.assertEqual(r.returncode, 1)
                    self.assertNotIn("restored", r.stdout)

    def test_process_identity_states(self):
        fn = function(HUNG, "proc_state", "# Signal delivery")
        for record, expected in (("S 90", "live:S"), ("T 90", "live:T"),
                                 ("Z 90", "zombie"), ("absent", "absent"),
                                 ("S 91", "reused")):
            r = shell('proc_record() { echo "$RECORD"; }\n' + fn + '\nproc_state 10 90',
                      {"RECORD": record})
            self.assertEqual(r.stdout.strip(), expected)

    def test_retirement_samples_windows_even_with_live_helper(self):
        fn = function(HUNG, "retirement_sample", "retire_client() {")
        for state, gone, success in (("live:S", "true", False), ("zombie", "true", True),
                                     ("absent", "true", True), ("reused", "true", True),
                                     ("absent", "false", False), ("unknown", "true", False)):
            r = shell('P=1; PSTART=10; KW=w1; HELPERS="2:20"; PROMPT_WINDOWS=w2\n'
                      'proc_state() { [ "$1" = 1 ] && echo absent || echo "$STATE"; }\n'
                      'wwhost() { echo sampled-$1 >&2; echo "$GONE"; }\n'
                      'hcall() { echo [inventory]; }; remember_helpers() { :; }; log() { echo "$*"; }\n'
                      + fn + '\nretirement_sample', {"STATE": state, "GONE": gone})
            self.assertEqual(r.returncode == 0, success, r.stdout)
            self.assertIn("sampled-w1", r.stderr)
            self.assertIn("sampled-w2", r.stderr)
            self.assertIn('windows=[inventory]', r.stdout)

    def test_kill_failure_records_evidence_before_failure(self):
        fn = function(HUNG, "retire_client", "# live <w-id>")
        r = shell('P=1; PSTART=10\nkill_owned_client() { return 1; }\n'
                  'retirement_sample() { echo evidence; return 1; }\n'
                  'fail() { echo "FAIL $*"; exit 1; }\n' + fn + '\nretire_client')
        self.assertEqual(r.returncode, 1)
        self.assertTrue(r.stdout.startswith("evidence\nFAIL SIGKILL failed"))

    def test_reused_pid_never_signalled(self):
        fn = function(HUNG, "kill_owned_client", "retirement_sample() {")
        r = shell('P=1; PSTART=10\nproc_state() { echo reused; }\n'
                  'sh_() { echo SIGNAL; }; log() { echo "$*"; }\n' + fn + '\nkill_owned_client')
        self.assertEqual(r.returncode, 1)
        self.assertNotIn("SIGNAL", r.stdout)

    def test_helper_lookup_has_exact_client_argument(self):
        fn = function(HUNG, "killers", "remember_helpers() {")
        r = shell('P=123\nsh_() { echo "$1" >&2; echo none; }\n' + fn + '\nkillers')
        self.assertEqual(r.returncode, 0)
        self.assertIn("--pid 123( |$)", r.stderr)
        self.assertIn("(^|/)kwin_killer_helper ", r.stderr)
        self.assertEqual(r.stdout, "")

    def test_user_transport_silent_and_filtered_status(self):
        fn = function(HUNG, "us", "# $1 in the Plasma")
        for output, rc in (("", 0), ("file pushed\n", 0), ("", 7), ("file pushed\n", 124)):
            with tempfile.TemporaryDirectory() as tmp:
                r = shell('set -o pipefail\nT=unused\n'
                          'bounded() { printf "%s" "$OUTPUT"; return "$RC"; }\n'
                          + fn + '\nus "kill -STOP 123"',
                          {"OUT": tmp, "OUTPUT": output, "RC": str(rc)})
            self.assertEqual(r.returncode, rc)
            self.assertEqual(r.stdout, "")

    def test_stop_requires_original_stopped_identity(self):
        fn = function(HUNG, "confirm_stopped", "killers() {")
        for state, expected in (("live:T", 0), ("live:t", 0), ("reused", 1),
                                ("absent", 1), ("zombie", 1), ("live:S", 1)):
            r = shell('P=1; PSTART=2\nproc_state() { echo "$STATE"; }\n'
                      'log() { :; }; sleep() { SECONDS=$((SECONDS + 4)); }\n'
                      + fn + '\nconfirm_stopped', {"STATE": state})
            self.assertEqual(r.returncode, expected, state)

    def test_restore_only_after_setup_and_once(self):
        restore = function(HUNG, "restore", '. "$here/window-lock.sh"')
        with tempfile.TemporaryDirectory() as tmp:
            r = shell('set -u\nSETUP=0; KATE_MINE=0; H0=0; HYPR=x\n'
                      'us() { echo USER >&2; }; sh_() { echo SHELL >&2; }\n' + restore +
                      '\nrestore; echo before; SETUP=1; restore; restore', {"OUT": tmp})
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.count("restored"), 1)
        self.assertEqual(r.stderr.count("USER"), 1)
        self.assertNotIn("device_state", restore)

    def test_transport_tree_deadline(self):
        bounded = function(HUNG, "bounded", 'sh_() {')
        r = shell('CALL_S=1; DEADLINE=30\n' + bounded +
                  '\nbounded bash -c "sleep 30 & wait"; echo rc=$?')
        self.assertIn("rc=124", r.stdout)
        self.assertIn("ERR transport deadline", r.stderr)

    def test_cleanup_transport_timeout_preserves_failure(self):
        bounded = function(HUNG, "bounded", 'sh_() {')
        restore = function(HUNG, "restore", '. "$here/window-lock.sh"')
        with tempfile.TemporaryDirectory() as tmp:
            r = shell('CALL_S=1; DEADLINE=30; SETUP=1; KATE_MINE=0; H0=0; HYPR=x\n'
                      + bounded + restore +
                      '\nus() { bounded bash -c "sleep 30 & wait"; }; sh_() { :; }; wl_release() { echo released; }\n'
                      'trap \'rc=$?; restore; wl_release; exit "$rc"\' EXIT\nexit 1', {"OUT": tmp})
        self.assertEqual(r.returncode, 1)
        self.assertIn("released", r.stdout)
        self.assertIn("ERR transport deadline", r.stderr)

    def test_expired_budget_does_not_invoke_transport(self):
        bounded = function(HUNG, "bounded", 'sh_() {')
        r = shell('CALL_S=1; DEADLINE=0\n' + bounded + '\nbounded echo invoked; echo rc=$?')
        self.assertIn("rc=124", r.stdout)
        self.assertNotIn("invoked", r.stdout)

    def calculator(self, point, key="a:com.oneplus.calculator/Main", result="ok"):
        launch = function(DESKTOP, "calculator_open", '# put_away <window key>')
        return shell('CALC=com.oneplus.calculator\n'
                     'pt() { echo "$POINT"; }; dockel() { :; }; '
                     'dock_tap() { echo dock; }; fail() { echo "FAIL $*"; }; note() { echo "$*"; }\n'
                     'ev() { case "$*" in document.visibilityState) echo visible ;; *m.apps.value*) echo "$KEY" ;; *m.launch*) echo "$RESULT" ;; esac; }\n'
                     + launch + '\ncalculator_open', {"POINT": point, "KEY": key, "RESULT": result})

    def test_pinned_uses_real_dock(self):
        r = self.calculator("10 20")
        self.assertEqual(r.returncode, 0)
        self.assertEqual(r.stdout.strip(), "dock")

    def test_unpinned_discovers_and_launches(self):
        r = self.calculator("none")
        self.assertEqual(r.returncode, 0)
        self.assertIn("without changing the dock", r.stdout)
        self.assertNotIn("FAIL", r.stdout)
        # Initial launch changes only; actual minimise/restore still use real taps.
        body = function(DESKTOP, "part2_minimise", "part2_pages()")
        self.assertEqual(body.count('dock_tap "a:$CALC/" Calculator'), 2)

    def test_missing_app_and_failed_launch_are_failures(self):
        for key, result in (("none", "ok"), ("a:com.oneplus.calculator/Main", "ERR failed")):
            r = self.calculator("none", key, result)
            self.assertEqual(r.returncode, 1)
            self.assertIn("FAIL", r.stdout)


if __name__ == "__main__":
    unittest.main()
