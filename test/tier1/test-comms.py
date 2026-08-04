#!/usr/bin/env python3
"""Tier-1 tests for the PowOS inter-agent comms mailbox (lib/ai/comms).

Hermetic: every test runs against a throwaway COMMS_ROOT tmpdir and drives the
server either in-process (imported) or over its real stdio JSON-RPC transport
and CLI. No network, no daemon, no real /var.
"""

import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
SERVER = os.path.join(REPO, "lib", "ai", "comms", "comms-mcp.py")


def load_server(root, agent_id="", parent="user", can_notify="1"):
    """Import comms-mcp.py as a fresh module bound to a given identity/root."""
    import importlib.util
    os.environ["COMMS_ROOT"] = root
    os.environ["COMMS_AGENT_ID"] = agent_id
    os.environ["COMMS_PARENT_ID"] = parent
    os.environ["COMMS_CAN_NOTIFY"] = can_notify
    spec = importlib.util.spec_from_file_location(f"comms_{agent_id}_{id(root)}", SERVER)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class StoreTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.root = os.path.join(self.tmp, "comms")

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_deliver_and_read_roundtrip(self):
        coder = load_server(self.root, "coder")
        coder.tool_send_message({"to": "devops", "message": "hi", "priority": "high"})
        devops = load_server(self.root, "devops")
        out = devops.tool_read_inbox({})
        self.assertIn("hi", out)
        self.assertIn("from coder", out)
        self.assertIn("high", out)

    def test_read_drains_by_default(self):
        load_server(self.root, "coder").tool_send_message({"to": "devops", "message": "x"})
        devops = load_server(self.root, "devops")
        devops.tool_read_inbox({})              # drains
        again = devops.tool_read_inbox({})       # now empty
        self.assertIn("0 message", again)

    def test_peek_does_not_drain(self):
        load_server(self.root, "coder").tool_send_message({"to": "devops", "message": "x"})
        devops = load_server(self.root, "devops")
        peeked = devops.tool_read_inbox({"peek": True})
        self.assertIn("Peeked", peeked)
        # still there after a peek
        self.assertIn("1 message", devops.tool_read_inbox({"peek": True}))

    def test_fifo_order(self):
        c = load_server(self.root, "coder")
        for i in range(3):
            c.tool_send_message({"to": "devops", "message": f"m{i}"})
            time.sleep(0.002)  # keep timestamp prefixes distinct
        out = load_server(self.root, "devops").tool_read_inbox({})
        self.assertLess(out.index("m0"), out.index("m1"))
        self.assertLess(out.index("m1"), out.index("m2"))

    def test_escalate_routes_to_parent(self):
        worker = load_server(self.root, "worker", parent="devops")
        worker.tool_escalate({"message": "done", "result": "fixed bug"})
        out = load_server(self.root, "devops").tool_read_inbox({})
        self.assertIn("done", out)
        self.assertIn("fixed bug", out)

    def test_notify_forbidden_agent_forwards_to_parent(self):
        # A restricted agent's notify_user must NOT reach 'user'; it escalates.
        w = load_server(self.root, "worker", parent="devops", can_notify="0")
        msg = w.tool_notify_user({"message": "ping"})
        self.assertIn("forwarded", msg.lower())
        self.assertEqual(len(w._read_pending("user", drain=False)), 0)
        self.assertEqual(len(w._read_pending("devops", drain=False)), 1)

    def test_list_agents_reports_depth(self):
        c = load_server(self.root, "coder")
        c.tool_send_message({"to": "devops", "message": "a"})
        c.tool_send_message({"to": "devops", "message": "b"})
        out = load_server(self.root, "coder").tool_list_agents({})
        self.assertIn("devops", out)
        self.assertIn("2 pending", out)

    def test_unsafe_agent_name_rejected(self):
        c = load_server(self.root, "coder")
        with self.assertRaises(ValueError):
            c.tool_send_message({"to": "../../etc/passwd", "message": "x"})

    def test_read_inbox_without_identity_refuses(self):
        anon = load_server(self.root, "")  # no COMMS_AGENT_ID
        with self.assertRaises(ValueError):
            anon.tool_read_inbox({})

    def test_wait_returns_immediately_when_mail_present(self):
        load_server(self.root, "coder").tool_send_message({"to": "devops", "message": "x"})
        devops = load_server(self.root, "devops")
        t0 = time.time()
        out = devops.tool_wait_for_message({"timeout_seconds": 5})
        self.assertIn("x", out)
        self.assertLess(time.time() - t0, 1.0)

    def test_wait_wakes_on_late_delivery(self):
        devops = load_server(self.root, "devops")
        sender = load_server(self.root, "coder")

        def deliver_soon():
            time.sleep(0.4)
            sender.tool_send_message({"to": "devops", "message": "late"})

        threading.Thread(target=deliver_soon, daemon=True).start()
        t0 = time.time()
        out = devops.tool_wait_for_message({"timeout_seconds": 5})
        elapsed = time.time() - t0
        self.assertIn("late", out)
        self.assertGreater(elapsed, 0.3)   # it really waited
        self.assertLess(elapsed, 3.0)      # and woke well before timeout

    def test_wait_times_out_cleanly(self):
        devops = load_server(self.root, "devops")
        out = devops.tool_wait_for_message({"timeout_seconds": 1})
        self.assertIn("No message arrived", out)


class StdioProtocolTests(unittest.TestCase):
    """Exercise the real newline-delimited JSON-RPC transport."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.root = os.path.join(self.tmp, "comms")

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _drive(self, agent_id, requests):
        env = dict(os.environ, COMMS_ROOT=self.root, COMMS_AGENT_ID=agent_id)
        payload = "".join(json.dumps(r) + "\n" for r in requests)
        p = subprocess.run([sys.executable, SERVER], input=payload,
                           capture_output=True, text=True, env=env, timeout=30)
        out = []
        for line in p.stdout.splitlines():
            line = line.strip()
            if line:
                out.append(json.loads(line))
        return out

    def test_initialize_and_tools_list(self):
        resp = self._drive("devops", [
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
        ])
        init = next(r for r in resp if r.get("id") == 1)
        self.assertEqual(init["result"]["serverInfo"]["name"], "powos-comms")
        tools = next(r for r in resp if r.get("id") == 2)
        names = {t["name"] for t in tools["result"]["tools"]}
        self.assertEqual(names, {
            "send_message", "notify_user", "escalate",
            "read_inbox", "wait_for_message", "list_agents",
        })

    def test_notification_gets_no_response(self):
        # A JSON-RPC notification (no id) must not produce a response line.
        resp = self._drive("devops", [
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            {"jsonrpc": "2.0", "id": 2, "method": "ping"},
        ])
        ids = [r.get("id") for r in resp]
        self.assertIn(1, ids)
        self.assertIn(2, ids)
        self.assertNotIn(None, ids)  # the notification produced nothing

    def test_tools_call_over_stdio(self):
        # coder sends, devops reads — both over the wire.
        self._drive("coder", [
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
             "params": {"name": "send_message",
                        "arguments": {"to": "devops", "message": "wire-ok"}}},
        ])
        resp = self._drive("devops", [
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
             "params": {"name": "read_inbox", "arguments": {}}},
        ])
        call = next(r for r in resp if r.get("id") == 2)
        self.assertIn("wire-ok", call["result"]["content"][0]["text"])

    def test_unknown_tool_is_tool_error_not_crash(self):
        resp = self._drive("devops", [
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
             "params": {"name": "nope", "arguments": {}}},
        ])
        call = next(r for r in resp if r.get("id") == 2)
        self.assertIn("error", call)  # JSON-RPC error for an unknown tool name


class CliTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.root = os.path.join(self.tmp, "comms")

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _cli(self, *args, agent=""):
        env = dict(os.environ, COMMS_ROOT=self.root, COMMS_AGENT_ID=agent)
        return subprocess.run([sys.executable, SERVER, *args],
                             capture_output=True, text=True, env=env, timeout=30)

    def test_send_and_inbox(self):
        self.assertEqual(self._cli("send", "devops", "hello", "world").returncode, 0)
        out = self._cli("inbox", "--agent", "devops").stdout
        self.assertIn("hello world", out)
        self.assertIn("from user", out)  # a human at the CLI acts as 'user'

    def test_agents_listing(self):
        self._cli("send", "coder", "x")
        self.assertIn("coder", self._cli("agents").stdout)

    def test_from_override(self):
        self._cli("send", "devops", "msg", "--from", "health")
        self.assertIn("from health", self._cli("inbox", "--agent", "devops").stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
