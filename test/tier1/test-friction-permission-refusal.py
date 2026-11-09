#!/usr/bin/env python3
"""test-friction-permission-refusal.py: friction logging for permission refusals records commands, not descriptions.

Test that permission refusal friction entries log the actual command (first ~160 chars with secrets redacted)
instead of the tool description, and that repeats are grouped by command shape (first two words + cwd root).
"""

import json
import os
import sys
import unittest
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
AGENTSD = os.path.join(ROOT, "lib", "ai", "agents", "powos-agentsd")


def load(name, path):
    loader = SourceFileLoader(name, path)
    m = module_from_spec(spec_from_loader(name, loader))
    loader.exec_module(m)
    return m


agentsd = load("powos_agentsd", AGENTSD)


class TestFrictionPermissionRefusal(unittest.TestCase):
    """Test _refusal_hint and _cmd_shape functions."""

    def test_refusal_hint_bash_with_secret(self):
        """Bash command with secret should be redacted."""
        inp = {
            "command": "curl -H 'Authorization: Bearer sk-1234567890abcdef1234567890abcdef' https://api.example.com",
            "cwd": os.path.expanduser("~/pw/perm-log"),
            "description": "Call API",
        }
        hint = agentsd._refusal_hint("Bash", inp)
        # Should redact the secret
        self.assertNotIn("sk-1234567890", hint)
        self.assertIn("…", hint)
        # Should include cwd root
        self.assertIn("perm-log", hint)

    def test_refusal_hint_bash_no_secret(self):
        """Bash command without secret should be clean."""
        inp = {
            "command": "cd /Users/macback/pw/perm-log && git status",
            "cwd": os.path.expanduser("~/pw/perm-log"),
        }
        hint = agentsd._refusal_hint("Bash", inp)
        # Should contain the command
        self.assertIn("git", hint)
        # Should include cwd root
        self.assertIn("perm-log", hint)

    def test_refusal_hint_file_tool(self):
        """File tool should show the file path."""
        inp = {"file_path": "/Users/macback/pw/perm-log/lib/ai/agents/powos-agentsd"}
        hint = agentsd._refusal_hint("Read", inp)
        # Should contain the file name
        self.assertIn("powos-agentsd", hint)

    def test_refusal_hint_bash_var_tmp(self):
        """Bash with /var/tmp cwd should show /var/tmp."""
        inp = {
            "command": "ls -la /var/tmp/test",
            "cwd": "/var/tmp/something",
        }
        hint = agentsd._refusal_hint("Bash", inp)
        self.assertIn("/var/tmp", hint)

    def test_cmd_shape_simple(self):
        """Command shape should extract first two words + cwd."""
        hint1 = "curl -H Authorization:Bearer… @ perm-log"
        shape1 = agentsd._cmd_shape(hint1)
        # Should contain "curl" and the cwd with @
        self.assertIn("curl", shape1)
        self.assertIn("perm-log", shape1)
        self.assertIn("@", shape1)

    def test_cmd_shape_normalization(self):
        """Command shape should normalize numbers."""
        hint1 = "find /var/tmp/test123 -name file456"
        hint2 = "find /var/tmp/test999 -name file888"
        shape1 = agentsd._cmd_shape(hint1)
        shape2 = agentsd._cmd_shape(hint2)
        # Both should normalize numbers to #
        self.assertEqual(shape1, shape2)

    def test_cmd_shape_grouping(self):
        """Similar commands should group together."""
        hint1 = "git commit -m 'test message' @ perm-log"
        hint2 = "git commit -m 'other message' @ perm-log"
        shape1 = agentsd._cmd_shape(hint1)
        shape2 = agentsd._cmd_shape(hint2)
        # Both should have the same shape (git commit ... @ perm-log)
        self.assertEqual(shape1, shape2)


if __name__ == "__main__":
    unittest.main()
