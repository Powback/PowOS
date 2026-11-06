#!/usr/bin/env python3
"""powos-padd's report rate: every change goes out at once, the timer only repeats the last state as a 30 Hz
keepalive - 250 Hz only while the Deck motion fields (gyro/accel) are live. 11-06 live play (Broforce, the overlay's
sticks moving all the time): the old rule (250 Hz for a second after any change) kept powos-padd at 7.5 % of a core
and Steam's CSteamController at 8.7 % reading identical reports."""
from importlib.machinery import SourceFileLoader
from pathlib import Path
import importlib.util
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
loader = SourceFileLoader("padd", str(ROOT / "targets/android/session/powos-padd"))
spec = importlib.util.spec_from_loader("padd", loader)
padd = importlib.util.module_from_spec(spec)
loader.exec_module(padd)


def pad(state, changed_ago):
    p = object.__new__(padd.DeckPad)
    p.state, p.changed, p.opened = tuple(state) + (0,) * (17 - len(state)), time.monotonic() - changed_ago, True
    p.sent = []
    p.send = lambda: p.sent.append(p.state)
    p.last_sent = time.monotonic()
    return p


class Rate(unittest.TestCase):
    def test_sticks_moving_keepalive_only(self):
        p = pad((0, 12000, -3000, 0, 0, 0, 0), 0.0)
        self.assertAlmostEqual(p.interval(), 1 / padd.IDLE_HZ)

    def test_gyro_live_full_rate(self):
        s = [0] * 17
        s[12] = 900  # gyro yaw
        self.assertAlmostEqual(pad(s, 0.0).interval(), 1 / padd.REPORT_HZ)
        self.assertAlmostEqual(pad(s, 2.0).interval(), 1 / padd.IDLE_HZ)

    def test_change_sent_at_once(self):
        p = pad((0,), 5.0)
        p.apply((1, 0, 0, 0, 0, 0, 0))
        self.assertEqual(len(p.sent), 1)
        self.assertEqual(p.sent[0][0], 1)

    def test_closed_no_timer(self):
        p = pad((0,), 0.0)
        p.opened = False
        self.assertIsNone(p.interval())


if __name__ == "__main__":
    unittest.main()
