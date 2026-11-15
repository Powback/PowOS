#!/usr/bin/env python3
"""Device-free watchdog regression tests; all system commands are shell doubles."""
import itertools
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = (ROOT / "bin/greeter-watchdog").read_text()
DOUBLES = r'''
systemctl() {
  case "$1" in
    is-active) return "$SERVICE_RC" ;;
    show) printf '%s\n' '2026-11-15 00:00:00 UTC' ;;
    restart) printf '%s\n' RESTART ;;
    *) return 99 ;;
  esac
}
loginctl() {
  case "$1" in
    list-sessions) printf '%s\n' "$SESSIONS"; return "$LIST_RC" ;;
    show-session)
      if [ "$2" = g ]; then
        printf '%s\n' 'Type=wayland' 'Class=greeter' 'State=active'
      else
        printf '%s\n' "$TEST_INFO"
        return "$SHOW_RC"
      fi ;;
    *) return 99 ;;
  esac
}
journalctl() {
  local i=0
  while [ "$i" -lt "$ERRORS" ]; do
    echo 'greeter: not a function'
    i=$((i + 1))
  done
}
logger() { :; }
date() { echo 1000; }
'''


class WatchdogTests(unittest.TestCase):
    def run_watchdog(self, expected=False, last=None, **values):
        env = dict(os.environ, SERVICE_RC="0", LIST_RC="0", SHOW_RC="0",
                   SESSIONS="g 100 greeter\nu 1000 user", ERRORS="3",
                   INFO="Type=wayland\nClass=user\nState=active")
        env.update(values)
        env["TEST_INFO"] = env.pop("INFO")
        with tempfile.TemporaryDirectory(prefix="greeter-watchdog-test-") as tmp:
            stamp = Path(tmp) / "last"
            if last is not None:
                stamp.write_text(str(last))
            env["TEST_STAMP"] = str(stamp)
            # Only redirect the private cooldown file; run the actual script body.
            script = SCRIPT.replace("STAMP=/run/greeter-watchdog.last",
                                    'STAMP="$TEST_STAMP"')
            result = subprocess.run(["bash", "-c", DOUBLES + script], env=env,
                                    capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stderr, "")
            self.assertEqual(result.stdout, "RESTART\n" if expected else "")
            self.assertEqual(stamp.read_text() if stamp.exists() else None,
                             "1000\n" if expected else
                             (str(last) if last is not None else None))

    def test_active_desktops_all_property_orders(self):
        for desktop in ("wayland", "x11"):
            for props in itertools.permutations(("Class=user", "State=active",
                                                 "Type=" + desktop)):
                with self.subTest(properties=props):
                    self.run_watchdog(INFO="\n".join(props))

    def test_greeter_recovery_threshold_and_cooldown(self):
        self.run_watchdog(expected=True, SESSIONS="g 100 greeter")
        self.run_watchdog(SESSIONS="g 100 greeter", ERRORS="2")
        self.run_watchdog(SESSIONS="g 100 greeter", last=701)
        self.run_watchdog(expected=True, SESSIONS="g 100 greeter", last=700)
        self.run_watchdog(SESSIONS="g 100 greeter", SERVICE_RC="1")

    def test_query_failures(self):
        self.run_watchdog(SESSIONS="", LIST_RC="1")
        self.run_watchdog(SESSIONS="g 100 greeter", LIST_RC="1")
        self.run_watchdog(SHOW_RC="1")
        self.run_watchdog(SHOW_RC="1", INFO="")

    def test_unknown_or_incomplete_properties(self):
        for info in ("", "Class=user\nState=active", "Class=user\nType=x11",
                     "Type=wayland\nState=active",
                     "Class=unknown\nState=active\nType=wayland",
                     "Class=user\nState=unknown\nType=x11",
                     "Class=user\nState=active\nType=unknown",
                     "Class=greeter\nState=active\nType=",
                     "Class=greeter\nClass=user\nState=active\nType=x11"):
            with self.subTest(info=info):
                self.run_watchdog(INFO=info)


if __name__ == "__main__":
    unittest.main()
