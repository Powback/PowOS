#!/usr/bin/env python3
"""A message is never cut off: a ~10 KB body full of what breaks text handling (emoji and ZWJ sequences, CJK,
combining marks, quotes, backslashes, `$`, CR/LF, tabs, a leading "-") goes through every path an agent's message
takes, and comes out byte for byte:

  * `powos comms send` (argv, stdin "-", after "--") -> `watch` / `inbox` (--json exact; the text form indented,
    every line) - also under a hostile locale (ASCII / latin-1 stdio), which once crashed the watcher AFTER it had
    drained the inbox: the message lost;
  * the MCP tools over their real stdio JSON-RPC (send_message, read_inbox, wait_for_message, escalate, notify_user);
  * the manager: --once-inbox and the live injection, checked on the text the model receives (a stub `claude` records
    its stream-json input) and on the --json-events `inbox` event the phone's chat shows;
  * the phone boundary: the agent-mail/ file the PowOS app turns into a notification (AgentMail.kt reads "text"), and
    the Agents view's feed (comms' queue record -> powos-agentsd -> messages.json).

What the app does with the text past that file (the notification's preview and capped expanded body, the tap opening
the stored mail whole) is Kotlin, outside tier 1; the JSON it reads is checked here.

Hermetic: tmp COMMS_ROOT / run dir / agents queue, a stub claude, no network, no phone.
"""

import glob
import json
import os
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
SERVER = os.path.join(REPO, "lib", "ai", "comms", "comms-mcp.py")
COMMS_SH = os.path.join(REPO, "lib", "ai", "comms", "comms.sh")
BROKER = os.path.join(REPO, "lib", "ai", "manager", "manager.py")
AGENTSD = os.path.join(REPO, "lib", "ai", "agents", "powos-agentsd")


def make_body(size=10 * 1024):
    """~[size] bytes of UTF-8 that breaks naive text handling. No NUL (argv can't carry one) and no secret-shaped
    strings (the Agents view scrubs those on purpose)."""
    pieces = [
        "- starts like an option\n",
        "emoji 🎉🚀 ZWJ 👩‍👩‍👧‍👦 flag 🇨🇭 skin 👍🏽 keycap 1️⃣\n",
        "CJK 中文汉字 日本語のテキスト 한국어 텍스트\n",
        "combining: e\u0301 a\u0308 n\u0303 Z\u0337\u0335\u0321 \u1100\u1161\u11a8 \u0915\u094d\u0937\n",
        "quotes ' \" ` ‘curly’ “double” «guillemets»\n",
        "backslashes \\ \\\\ \\n \\t \\u00e9 C:\\path\\to\\file\n",
        "dollars $HOME ${PATH} $(id) `id` $1 $$ $? %s %d {0} {{x}}\n",
        "tab\there, CRLF line\r\n",
        "trailing spaces   \n",
        "json-ish {\"a\": [1, \"b\"]} </script> <b>html</b> &amp;\n",
        "\n",
    ]
    out, i = [], 0
    while len("".join(out).encode()) < size:
        out.append(f"[{i:04d}] " + pieces[i % len(pieces)])
        i += 1
    return "".join(out) + "the end, no newline after it ✓"


BODY = make_body()


def unindent(text):
    """The CLI's / read_inbox's text form back to the body: every line carries four spaces."""
    lines = text.split("\n")
    assert all(line.startswith("    ") for line in lines), "a body line without its indent"
    return "\n".join(line[4:] for line in lines)


def body_block(fmt_text, header_id):
    """The indented body after the message header that carries [header_id], up to the next header or the end."""
    lines = fmt_text.split("\n")
    start = next(i for i, line in enumerate(lines) if f"[id {header_id}]" in line) + 1
    end = start
    while end < len(lines) and lines[end].startswith("    ") and not lines[end].startswith("    result: "):
        end += 1
    return "\n".join(lines[start:end])


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="comms-fulltext-")
        self.root = os.path.join(self.tmp, "comms")
        self.run_dir = os.path.join(self.tmp, "run")
        self.queue = os.path.join(self.tmp, "agents-q")
        os.makedirs(self.run_dir)
        os.makedirs(self.queue)
        self.env = dict(os.environ, COMMS_ROOT=self.root, POWOS_PLATFORM="phone", XDG_RUNTIME_DIR=self.run_dir,
                        POWOS_AGENTS_QUEUE=self.queue, NO_COLOR="1")
        for k in ("COMMS_AGENT_ID", "COMMS_PARENT_ID", "COMMS_CAN_NOTIFY"):
            self.env.pop(k, None)
        self.assertGreater(len(BODY.encode()), 10 * 1024)

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)

    def cli(self, *args, stdin=None, env=None):
        p = subprocess.run([sys.executable, SERVER, *args], input=stdin.encode() if stdin is not None else None,
                           capture_output=True, env=env or self.env, timeout=60)
        self.assertEqual(p.returncode, 0, p.stderr.decode(errors="replace"))
        return p.stdout.decode()

    def inbox_json(self, agent, *extra, env=None):
        out = self.cli("inbox", "--agent", agent, "--json", *extra, env=env)
        return [json.loads(line) for line in out.splitlines() if line.strip()]


class CliTests(Base):
    HOSTILE = {"PYTHONIOENCODING": "ascii", "LC_ALL": "C", "LANG": "C"}

    def test_send_argv_watch_json(self):
        self.cli("send", "coder", BODY)
        out = self.cli("watch", "--agent", "coder", "--timeout", "5", "--json")
        msgs = [json.loads(line) for line in out.splitlines()]
        self.assertEqual(len(msgs), 1)
        self.assertEqual(msgs[0]["body"].encode(), BODY.encode())

    def test_send_watch_text_every_line(self):
        self.cli("send", "coder", BODY)
        out = self.cli("watch", "--agent", "coder", "--timeout", "5")
        header, _, rest = out.partition("\n")
        self.assertIn("from user (message)", header)
        self.assertEqual(unindent(rest.rstrip("\n")).encode(), BODY.encode())

    def test_send_stdin_and_double_dash(self):
        self.cli("send", "coder", "-", stdin=BODY + "\n")   # the newline echo adds is dropped, nothing else
        self.cli("send", "coder", "--", BODY)                 # starts with "-": still the message (the app's reply)
        got = self.inbox_json("coder")
        self.assertEqual([m["body"].encode() for m in got], [BODY.encode(), BODY.encode()])

    def test_via_comms_sh(self):
        """`powos comms ...` is comms.sh's cmd_comms: its pass-through keeps the body whole too."""
        subprocess.run(["bash", "-c", 'source "$1"; shift; cmd_comms "$@"', "x", COMMS_SH, "send", "coder", BODY],
                       env=self.env, check=True, capture_output=True, timeout=60)
        p = subprocess.run(["bash", "-c", 'source "$1"; cmd_comms inbox --agent coder --json', "x", COMMS_SH],
                           env=self.env, check=True, capture_output=True, timeout=60)
        self.assertEqual(json.loads(p.stdout.decode())["body"].encode(), BODY.encode())

    def test_hostile_locale_watch_and_inbox(self):
        """An ASCII-only locale: no UnicodeEncodeError (which used to come after the drain - the message gone)."""
        env = dict(self.env, **self.HOSTILE)
        self.cli("send", "coder", BODY, env=env)
        self.cli("send", "coder", "-", stdin=BODY, env=env)
        out = self.cli("watch", "--agent", "coder", "--timeout", "5", env=env)
        ids = [line.split("[id ")[1].rstrip("]") for line in out.splitlines() if line.startswith("• ")]
        self.assertEqual(len(ids), 2)
        for mid in ids:
            self.assertEqual(unindent(body_block(out, mid)).encode(), BODY.encode())
        self.cli("send", "coder", BODY, env=env)
        self.assertEqual(self.inbox_json("coder", env=env)[0]["body"].encode(), BODY.encode())

    def test_peek_keeps_it_whole(self):
        self.cli("send", "coder", BODY)
        self.assertEqual(self.inbox_json("coder", "--peek")[0]["body"], BODY)
        self.assertEqual(self.inbox_json("coder")[0]["body"], BODY)


class McpTests(Base):
    """The tools over the real stdio transport, the client sending raw UTF-8 (as claude does)."""

    def server(self, agent, can_notify="1", parent="manager", encoding="latin-1"):
        env = dict(self.env, COMMS_AGENT_ID=agent, COMMS_CAN_NOTIFY=can_notify, COMMS_PARENT_ID=parent,
                   PYTHONIOENCODING=encoding, LC_ALL="C", LANG="C")
        return subprocess.Popen([sys.executable, SERVER], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, env=env)

    def calls(self, agent, calls, **kw):
        """Each (tool, arguments) as tools/call over one session; the result texts."""
        p = self.server(agent, **kw)
        reqs = [{"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {"protocolVersion": "2024-11-05"}}]
        reqs += [{"jsonrpc": "2.0", "id": i + 1, "method": "tools/call", "params": {"name": n, "arguments": a}}
                 for i, (n, a) in enumerate(calls)]
        data = "".join(json.dumps(r, ensure_ascii=False) + "\n" for r in reqs).encode("utf-8")
        out, _ = p.communicate(data, timeout=60)
        resps = {r["id"]: r for r in (json.loads(line) for line in out.decode("utf-8").splitlines() if line.strip())}
        texts = []
        for i in range(1, len(calls) + 1):
            res = resps[i]["result"]
            self.assertFalse(res.get("isError"), res)
            texts.append(res["content"][0]["text"])
        return texts

    def only_id(self, agent):
        files = glob.glob(os.path.join(self.root, "agents", agent, "inbox", "*.json"))
        self.assertEqual(len(files), 1)
        with open(files[0]) as f:
            return json.load(f)["id"]

    def test_send_message_read_inbox(self):
        self.calls("coder", [("send_message", {"to": "devops", "message": BODY})])
        mid = self.only_id("devops")
        (text,) = self.calls("devops", [("read_inbox", {})])
        self.assertEqual(unindent(body_block(text, mid)).encode(), BODY.encode())

    def test_wait_for_message(self):
        self.calls("coder", [("send_message", {"to": "devops", "message": BODY})])
        mid = self.only_id("devops")
        (text,) = self.calls("devops", [("wait_for_message", {"timeout_seconds": 5})])
        self.assertEqual(unindent(body_block(text, mid)).encode(), BODY.encode())

    def test_escalate_with_result(self):
        self.calls("worker", [("escalate", {"message": BODY, "result": BODY})], parent="manager", can_notify="0")
        mid = self.only_id("manager")
        got = self.inbox_json("manager", "--peek")[0]
        self.assertEqual((got["body"], got["result"]), (BODY, BODY))
        (text,) = self.calls("manager", [("read_inbox", {})], parent="user")
        lines = text.split("\n")
        r = next(i for i, line in enumerate(lines) if line.startswith("    result: "))
        result = "\n".join(["    " + lines[r][len("    result: "):]] + lines[r + 1:])
        self.assertEqual(unindent(body_block(text, mid)), BODY)
        self.assertEqual(unindent(result), BODY)

    def test_notify_user_to_the_phone(self):
        self.calls("manager", [("notify_user", {"message": BODY, "priority": "high"})], parent="user")
        mail = PhoneTests.agent_mail(self, self.run_dir)
        self.assertEqual(len(mail), 1)
        self.assertEqual(mail[0]["text"].encode(), BODY.encode())
        self.assertEqual(self.inbox_json("user")[0]["body"].encode(), BODY.encode())


STUB = textwrap.dedent("""
    import sys, json, os
    rec = os.environ['STUB_RECORD']
    sid = 'stub-full-0001'
    out = open(sys.stdout.fileno(), 'w', encoding='utf-8', closefd=False)
    def emit(o):
        out.write(json.dumps(o) + '\\n'); out.flush()
    emit({'type': 'system', 'subtype': 'init', 'session_id': sid})
    for raw in open(sys.stdin.fileno(), 'rb', closefd=False):
        if not raw.strip():
            continue
        ev = json.loads(raw.decode('utf-8'))
        text = ''.join(b.get('text', '') for b in ev['message']['content'] if b.get('type') == 'text')
        with open(rec, 'a', encoding='utf-8') as f:
            f.write(json.dumps(text) + '\\n')
        emit({'type': 'assistant', 'message': {'content': [{'type': 'text', 'text': 'got it'}]}})
        emit({'type': 'result', 'subtype': 'success', 'session_id': sid, 'total_cost_usd': 0.0})
""")


class ManagerTests(Base):
    def setUp(self):
        super().setUp()
        self.stub = os.path.join(self.tmp, "stub.py")
        with open(self.stub, "w") as f:
            f.write(STUB)
        self.record = os.path.join(self.tmp, "model-input.jsonl")
        self.menv = dict(self.env, MANAGER_CLAUDE_CMD=f"{sys.executable} {self.stub}", STUB_RECORD=self.record,
                         POWOS_MANAGER_SAFE="1", POWOS_AGENTS="0", PYTHONIOENCODING="ascii", LC_ALL="C", LANG="C")

    def turns(self):
        with open(self.record, encoding="utf-8") as f:
            return [json.loads(line) for line in f if line.strip()]

    @staticmethod
    def expected(frm, body):
        return (f"[inbox message from agent '{frm}' (normal)]: {body}\n\n"
                "Handle this: fold it into what you tell me, and act or delegate if needed.")

    def test_once_inbox_model_text_and_event(self):
        self.cli("send", "manager", BODY, "--from", "coder")
        self.cli("send", "manager", "-", "--from", "devops", stdin=BODY)
        p = subprocess.run([sys.executable, BROKER, "--agent-id", "manager", "--session-store",
                            os.path.join(self.tmp, "store"), "--once-inbox", "--json-events"],
                           capture_output=True, env=self.menv, cwd=self.tmp, timeout=60)
        self.assertEqual(p.returncode, 0, p.stderr.decode(errors="replace"))
        want = self.expected("coder", BODY) + "\n\n" + self.expected("devops", BODY)
        (turn,) = self.turns()
        self.assertEqual(turn.encode(), want.encode(), "the text the model receives")
        events = [json.loads(line) for line in p.stdout.decode().splitlines() if line.strip()]
        inbox = [e for e in events if e["kind"] == "inbox"]
        self.assertEqual([e["text"].encode() for e in inbox], [want.encode()], "the event the phone's chat shows")
        self.assertEqual(os.listdir(os.path.join(self.root, "agents", "manager", "inbox")), [])

    def test_live_injection(self):
        p = subprocess.Popen([sys.executable, BROKER, "--agent-id", "manager", "--session-store",
                              os.path.join(self.tmp, "store"), "--json-events"],
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                             env=self.menv, cwd=self.tmp)
        try:
            self.cli("send", "manager", BODY, "--from", "coder")
            deadline = time.time() + 20
            while time.time() < deadline and not (os.path.exists(self.record) and self.turns()):
                time.sleep(0.1)
        finally:
            out, _ = p.communicate(b"", timeout=60)
        self.assertEqual([t.encode() for t in self.turns()], [self.expected("coder", BODY).encode()])
        # The REPL's own lines (its banner) aren't events.
        inbox = [e for e in (json.loads(line) for line in out.decode().splitlines() if line.startswith("{"))
                 if e.get("kind") == "inbox"]
        self.assertEqual([e["text"] for e in inbox], [self.expected("coder", BODY)])


class SilentTests(Base):
    """notify --silent (deploys the user can't see): nobody told - no inbox, no agent-mail, no feed - only the quiet log."""

    def test_silent_notify_only_logs(self):
        out = self.cli("notify", "-", "--from", "deploy", "--silent", "--priority", "low", "--batch", "deploy",
                       stdin="shell push (silent): ui/gesture.ts\n")
        self.assertIn("quietly", out)
        self.assertEqual(self.inbox_json("user", "--peek"), [])
        self.assertEqual(PhoneTests.agent_mail(self, self.run_dir), [])
        self.assertEqual(glob.glob(os.path.join(self.queue, "*.ev")), [])
        log = self.cli("quiet")
        self.assertIn("deploy: shell push (silent): ui/gesture.ts", log)

    def test_deploy_note_silent(self):
        """deploy-note.sh --silent asks comms for --silent (a stand-in adb records the phone command)."""
        bindir = os.path.join(self.tmp, "bin")
        os.makedirs(bindir)
        rec = os.path.join(self.tmp, "adb.log")
        with open(os.path.join(bindir, "adb"), "w") as f:
            f.write(f'#!/bin/sh\nprintf "%s\\n" "$*" >> {rec}\n')
        os.chmod(os.path.join(bindir, "adb"), 0o755)
        script = os.path.join(REPO, "targets", "android", "tools", "deploy-note.sh")
        env = dict(self.env, PATH=bindir + os.pathsep + os.environ["PATH"], ADB="adb")
        subprocess.run(["bash", script, "--silent", "gesture.ts refactor"], env=env, check=True, timeout=30)
        subprocess.run(["bash", script, "Switcher follows your finger"], env=env, check=True, timeout=30)
        self.assertNotEqual(subprocess.run(["bash", script], env=env, capture_output=True).returncode, 0)
        with open(rec) as f:
            calls = f.read().splitlines()
        self.assertIn("--silent", calls[0])
        self.assertNotIn("--silent", calls[1])


class PhoneTests(Base):
    """The phone's side of the boundary: what the app reads (agent-mail/) and the Agents view's feed."""

    @staticmethod
    def agent_mail(case, run_dir):
        """The files AgentMail.kt posts as notifications (it reads "text", "from", "id", "priority")."""
        out = []
        for path in sorted(glob.glob(os.path.join(run_dir, "agent-mail", "*.json"))):
            with open(path, "rb") as f:
                m = json.loads(f.read().decode("utf-8"))   # File.readText(): UTF-8
            if m.get("op") != "read":
                out.append(m)
        return out

    def test_notify_cli_stdin(self):
        self.cli("notify", "-", "--from", "health", "--priority", "urgent", stdin=BODY + "\n")
        mail = self.agent_mail(self, self.run_dir)
        self.assertEqual([(m["from"], m["priority"], m["text"].encode()) for m in mail],
                         [("health", "urgent", BODY.encode())])
        user = self.inbox_json("user", "--peek")[0]
        self.assertEqual(user["id"], mail[0]["id"], "the tap opens the stored mail by this id")
        self.assertEqual(user["body"], BODY)

    def test_agents_feed_whole(self):
        self.cli("send", "manager", BODY, "--from", "coder")
        evs = glob.glob(os.path.join(self.queue, "*.ev"))
        self.assertEqual(len(evs), 1)
        with open(evs[0], encoding="utf-8") as f:
            self.assertEqual(json.load(f)["body"], BODY, "comms' record for the feed")
        spool = os.path.join(self.tmp, "spool")
        subprocess.run([sys.executable, AGENTSD, "--once"], check=True, timeout=60,
                       env=dict(self.env, POWOS_AGENTS_DIR=spool, POWOS_AGENTS_HOST="phone", POWOS_AGENTS_STDB="0"))
        with open(os.path.join(spool, "messages.json"), encoding="utf-8") as f:
            msgs = json.load(f)["messages"]
        self.assertEqual([m["body"].encode() for m in msgs], [BODY.encode()], "the feed's row (tap: the whole body)")


if __name__ == "__main__":
    unittest.main(verbosity=2)
