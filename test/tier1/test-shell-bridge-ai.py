#!/usr/bin/env python3
"""Every PowOS AI call the mock bridge has, the real (Android) bridge has too (shell/bridge.ts, `ai: {...}` twice).

The ai calls are optional in types.ts (`stop?()`, `unqueue?()`: older hosts lack them), so a call missing from the real
bridge type-checks, works in the gate (mock) and silently does nothing on the phone: 11-24 the chat's stop button
turned back to send on the phone, but `powos.ai.stop` was undefined there and the turn ran on (75dbc8b0).
"""
import os
import re
import sys
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BRIDGE = os.path.join(REPO, "shell", "bridge.ts")


def ai_keys(src, start):
    """The method names of the `    ai: {` object found at or after [start], and where it ends."""
    i = src.index("    ai: {", start) + len("    ai: {")
    depth, j = 1, i
    while depth:
        c = src[j]
        if c in "{([":
            depth += 1
        elif c in "})]":
            depth -= 1
        j += 1
    return set(re.findall(r"^      (\w+)(?::|\s*\(|<)", src[i:j - 1], re.M)), j


class BridgeAiParity(unittest.TestCase):
    def test_mock_ai_calls_exist_on_the_real_bridge(self):
        src = open(BRIDGE, encoding="utf-8").read()
        real, end = ai_keys(src, 0)
        mock, _ = ai_keys(src, end)
        self.assertGreater(len(real), 5, "couldn't find the real bridge's ai calls")
        self.assertGreater(len(mock), 5, "couldn't find the mock bridge's ai calls")
        self.assertEqual(sorted(mock - real), [], "ai calls the mock has but the phone's bridge doesn't (add a call(...))")


if __name__ == "__main__":
    sys.exit(unittest.main())
