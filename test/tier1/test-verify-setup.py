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
                (t / "adb.sh").write_text('#!/bin/bash\ncase "$*" in *"dumpsys power"*) echo "$WAKE" ;; *"pgrep -x kwin_wayland"*) : ;; *) echo UNEXPECTED >&2; exit 99 ;; esac\n')
                (t / "adb.sh").chmod(0o755)
                r = subprocess.run(["bash", str(v / "kwin-hung-client.sh"), str(t / "out")],
                                   text=True, capture_output=True, timeout=8,
                                   env={**os.environ, "WAKE": wake})
                self.assertEqual(r.returncode, 5 if wake == "Awake" else 3, r.stderr)
                self.assertIn("released", r.stdout)
                self.assertNotIn("restored", r.stdout)
                self.assertNotIn("UNEXPECTED", r.stderr)

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
