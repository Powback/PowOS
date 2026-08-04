#!/usr/bin/env python3
"""PowOS Manager — a persistent streaming agent session you can leave running.

Backend for the desktop widget (Phase 2) and a clean terminal REPL today. It
owns ONE `claude` process in bidirectional stream-json mode, so a conversation
persists across turns and:

  * per-directory memory  — the session id is stored keyed by cwd and resumed,
    so `manager` in ~/Projects/Foo continues Foo's thread, Bar's in Bar. The
    widget maps its project sidebar onto this: picking a project = its thread.
  * live inbox delivery    — mail arriving in the manager's comms inbox is
    injected as a user turn automatically; the manager never polls.

Everything the session produces is turned into ONE normalized event stream
(assistant / tool_use / tool_result / turn_done / inbox / user / session). A
pluggable sink consumes it:

  * terminal sink  — pretty panels for the REPL (default, interactive).
  * jsonl sink     — one JSON object per line on stdout (--json-events), which
    the widget parses into chat bubbles and tool panels.

Frontends: `repl()` (interactive, two writers = you + the inbox watcher,
serialized) and `once(text)` (one turn against the per-dir session, for the
widget). The `claude` command is overridable via MANAGER_CLAUDE_CMD (the tests
substitute a hermetic stub speaking the same protocol).
"""

import argparse
import json
import os
import queue
import subprocess
import sys
import threading
import time

# ---- ANSI (skip when not a tty or NO_COLOR) --------------------------------
_TTY = sys.stdout.isatty() and not os.environ.get("NO_COLOR")
def _c(code, s):
    return f"\033[{code}m{s}\033[0m" if _TTY else s
DIM = lambda s: _c("2", s)
BOLD = lambda s: _c("1", s)
CYAN = lambda s: _c("36", s)
GREEN = lambda s: _c("32", s)
YELLOW = lambda s: _c("33", s)
MAGENTA = lambda s: _c("35", s)
RED = lambda s: _c("31", s)


def encode_cwd(path):
    """claude-style path key: /a/b -> -a-b (filesystem-safe, collision-free)."""
    return path.replace("/", "-").strip("-") or "root"


class SessionStore:
    """Maps a working directory to the last claude session id for the manager."""

    def __init__(self, store_dir):
        self.dir = os.path.join(store_dir, "sessions")
        os.makedirs(self.dir, exist_ok=True)

    def _path(self, cwd):
        return os.path.join(self.dir, encode_cwd(cwd) + ".session")

    def load(self, cwd):
        try:
            with open(self._path(cwd)) as f:
                return f.read().strip() or None
        except OSError:
            return None

    def save(self, cwd, session_id):
        if not session_id:
            return
        tmp = self._path(cwd) + ".tmp"
        with open(tmp, "w") as f:
            f.write(session_id)
        os.replace(tmp, self._path(cwd))


class Manager:
    def __init__(self, args, sink=None, enable_inbox=True):
        self.args = args
        self.cwd = os.path.abspath(args.cwd) if getattr(args, "cwd", None) else os.getcwd()
        self.store = SessionStore(args.session_store)
        self.session_id = self.store.load(self.cwd)
        self.pending = queue.Queue()      # (source, text) awaiting send
        self.busy = threading.Event()     # set while a turn is in flight
        self.stop = threading.Event()
        self.proc = None
        self.turns_done = 0
        self.enable_inbox = enable_inbox
        self.sink = sink or self._term_sink
        self._comms_root = os.environ.get("COMMS_ROOT", "")
        self._agent_id = args.agent_id
        self._log = None

    # -- process launch ------------------------------------------------------

    def _build_cmd(self):
        cmd = os.environ.get("MANAGER_CLAUDE_CMD", "claude").split()
        cmd += ["-p", "--input-format", "stream-json",
                "--output-format", "stream-json", "--verbose"]
        if os.environ.get("POWOS_MANAGER_SAFE") != "1":
            # The manager acts on the user's own machine; in stream mode there is
            # no TTY to answer permission prompts. POWOS_MANAGER_SAFE=1 opts out.
            cmd += ["--dangerously-skip-permissions"]
        if self.args.system_prompt_file:
            with open(self.args.system_prompt_file) as f:
                cmd += ["--append-system-prompt", f.read()]
        if self.args.mcp_config_file:
            cmd += ["--mcp-config", self.args.mcp_config_file]
        if self.session_id:
            cmd += ["--resume", self.session_id]
        return cmd

    def start(self):
        cmd = self._build_cmd()
        env = dict(os.environ, COMMS_AGENT_ID=self._agent_id)
        # Keep claude's stderr in a log so a failed session is diagnosable
        # (silent DEVNULL once cost me an afternoon), not lost.
        log_path = os.path.join(self.args.session_store, "manager.log")
        self._log = open(log_path, "a")
        self.proc = subprocess.Popen(
            cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=self._log, text=True, bufsize=1, env=env,
            cwd=self.cwd)

    # -- normalized event stream + sinks -------------------------------------

    def _emit(self, ev):
        """Send one normalized event to the active sink."""
        try:
            self.sink(ev)
        except Exception:
            pass

    def _term_sink(self, ev):
        k = ev.get("kind")
        if k == "assistant":
            print(BOLD(CYAN("\nmanager")) + DIM(" ▸ ") + ev["text"].strip())
        elif k == "tool_use":
            hint = ev.get("hint", "")
            print(YELLOW(f"\n  ⚙ {ev['name']}") + (DIM(f"  {hint}") if hint else ""))
        elif k == "tool_result":
            tag = DIM("  ↳ ") + (GREEN("ok") if ev.get("ok") else RED("err"))
            print(tag + DIM(f"  {ev.get('text','')}"))
        elif k == "inbox":
            print(MAGENTA(f"\n✉  {ev['text']}"))
        elif k == "turn_done":
            cost = ev.get("cost")
            if cost and _TTY:
                print(DIM(f"  · turn done (${cost:.4f})"))
        # 'user' and 'session' are silent in the terminal (you typed it / meta)

    def _json_sink(self, ev):
        sys.stdout.write(json.dumps(ev) + "\n")
        sys.stdout.flush()

    # -- the loops -----------------------------------------------------------

    def _send_event(self, text):
        msg = {"type": "user", "message": {"role": "user",
               "content": [{"type": "text", "text": text}]}}
        try:
            self.proc.stdin.write(json.dumps(msg) + "\n")
            self.proc.stdin.flush()
            self.busy.set()
        except (BrokenPipeError, ValueError):
            self.stop.set()

    def sender_loop(self):
        """Serialize the two writers: send the next queued turn only when idle."""
        while not self.stop.is_set():
            if self.busy.is_set():
                time.sleep(0.05)
                continue
            try:
                source, text = self.pending.get(timeout=0.2)
            except queue.Empty:
                continue
            if source == "inbox":
                self._emit({"kind": "inbox", "text": text})
            else:
                self._emit({"kind": "user", "text": text})
            self._send_event(text)

    def inbox_loop(self):
        """Watch the manager's comms inbox; queue arrivals as user turns."""
        if not self._comms_root or not self._agent_id:
            return
        inbox = os.path.join(self._comms_root, "agents", self._agent_id, "inbox")
        while not self.stop.is_set():
            try:
                files = sorted(f for f in os.listdir(inbox)
                               if f.endswith(".json")) if os.path.isdir(inbox) else []
            except OSError:
                files = []
            for name in files:
                path = os.path.join(inbox, name)
                try:
                    with open(path) as f:
                        m = json.load(f)
                    os.remove(path)
                except (OSError, json.JSONDecodeError):
                    continue
                frm = m.get("from", "?")
                pri = m.get("priority", "normal")
                body = m.get("body", "")
                res = f"\nResult: {m['result']}" if m.get("result") else ""
                self.pending.put(("inbox",
                    f"[inbox message from agent '{frm}' ({pri})]: {body}{res}\n\n"
                    f"Handle this: fold it into what you tell me, and act or "
                    f"delegate if needed."))
            time.sleep(1.0)

    def reader_loop(self):
        """Parse the raw event stream into normalized events; clear busy on result."""
        for line in self.proc.stdout:
            if self.stop.is_set():
                break
            line = line.strip()
            if not line:
                continue
            try:
                raw = json.loads(line)
            except json.JSONDecodeError:
                continue
            self._parse_raw(raw)
        self.stop.set()

    def _parse_raw(self, ev):
        t = ev.get("type")
        if t == "system" and ev.get("subtype") == "init":
            sid = ev.get("session_id")
            if sid:
                self.session_id = sid
                self.store.save(self.cwd, sid)
                self._emit({"kind": "session", "id": sid})
        elif t == "assistant":
            for b in ev["message"].get("content", []):
                if b.get("type") == "text" and b.get("text", "").strip():
                    self._emit({"kind": "assistant", "text": b["text"].strip()})
                elif b.get("type") == "tool_use":
                    self._emit({"kind": "tool_use", "name": b.get("name", "?"),
                                "hint": self._tool_hint(b.get("input", {}) or {})})
        elif t == "user":
            for b in ev["message"].get("content", []):
                if b.get("type") == "tool_result":
                    self._emit({"kind": "tool_result",
                                "ok": not b.get("is_error"),
                                "text": self._result_text(b.get("content", ""))})
        elif t == "result":
            self.busy.clear()
            self.turns_done += 1
            if ev.get("session_id"):
                self.session_id = ev["session_id"]
                self.store.save(self.cwd, ev["session_id"])
            self._emit({"kind": "turn_done", "cost": ev.get("total_cost_usd")})

    @staticmethod
    def _tool_hint(inp):
        hint = (inp.get("command") or inp.get("file_path") or inp.get("path")
                or inp.get("pattern") or inp.get("to") or inp.get("message") or "")
        hint = str(hint).replace("\n", " ")
        return hint[:120] + "…" if len(hint) > 120 else hint

    @staticmethod
    def _result_text(content):
        if isinstance(content, list):
            content = " ".join(c.get("text", "") for c in content
                               if isinstance(c, dict))
        content = str(content).strip().replace("\n", " ")
        return content[:160] + "…" if len(content) > 160 else content

    # -- frontends -----------------------------------------------------------

    def _spawn_workers(self):
        threading.Thread(target=self.reader_loop, daemon=True).start()
        threading.Thread(target=self.sender_loop, daemon=True).start()
        if self.enable_inbox:
            threading.Thread(target=self.inbox_loop, daemon=True).start()

    def once(self, text, timeout=300):
        """Run a single turn against the per-dir session, then exit. Widget path."""
        self.enable_inbox = False
        self.start()
        self._spawn_workers()
        self.pending.put(("user", text))
        t0 = time.time()
        while self.turns_done < 1 and not self.stop.is_set():
            if time.time() - t0 > timeout:
                break
            time.sleep(0.05)
        self.shutdown()

    def repl(self):
        self.start()
        where = os.path.basename(self.cwd) or "/"
        resumed = f"resumed {self.session_id[:8]}" if self.session_id else "new session"
        print(DIM(f"● PowOS Manager — {where} ({resumed}). "
                  f"Type to talk; Ctrl-D or /exit to quit.\n"))
        self._spawn_workers()
        try:
            while not self.stop.is_set():
                try:
                    line = input(BOLD("\nyou ▸ ") if _TTY else "")
                except EOFError:
                    break
                if line.strip() in ("/exit", "/quit"):
                    break
                if not line.strip():
                    continue
                self.pending.put(("user", line))
        except KeyboardInterrupt:
            pass
        finally:
            self.drain()
            self.shutdown()
            print(DIM("\n● Manager stopped. Session saved — `powos ai manager` resumes it."))

    def drain(self, timeout=120):
        """Let queued/in-flight turns finish before tearing the session down."""
        t0 = time.time()
        while time.time() - t0 < timeout:
            if self.pending.empty() and not self.busy.is_set():
                return
            if self.stop.is_set():
                return
            time.sleep(0.1)

    def shutdown(self):
        self.stop.set()
        try:
            if self.proc and self.proc.stdin:
                self.proc.stdin.close()
        except Exception:
            pass
        if self.proc:
            try:
                self.proc.wait(timeout=10)
            except Exception:
                self.proc.kill()
        if self._log:
            try:
                self._log.close()
            except Exception:
                pass


# Known agent roster — shown in the widget sidebar even before an inbox exists.
KNOWN_AGENTS = ["manager", "assistant", "health", "coder", "devops",
                "containerizer", "creator", "modder"]


def list_json(args):
    """Sidebar data for the widget: projects (with per-dir session state) and
    agents (with inbox depth). One clean JSON object — no ANSI to parse."""
    store = SessionStore(args.session_store)
    base = os.environ.get("POWOS_PROJECTS_DIR") or os.path.expanduser("~/Projects")
    projects = []
    if os.path.isdir(base):
        for name in sorted(os.listdir(base)):
            p = os.path.join(base, name)
            if os.path.isdir(p) and not name.startswith("."):
                projects.append({"name": name, "path": p,
                                 "hasSession": bool(store.load(p))})
    # Merge the known roster with whatever inboxes actually exist.
    root = os.environ.get("COMMS_ROOT", "")
    adir = os.path.join(root, "agents") if root else ""
    depth = {}
    if adir and os.path.isdir(adir):
        for name in os.listdir(adir):
            inbox = os.path.join(adir, name, "inbox")
            if os.path.isdir(inbox):
                depth[name] = len([f for f in os.listdir(inbox)
                                   if f.endswith(".json")])
    names = list(dict.fromkeys(KNOWN_AGENTS + sorted(depth)))
    agents = [{"name": n, "pending": depth.get(n, 0)} for n in names]
    print(json.dumps({"projects": projects, "agents": agents,
                      "projectsBase": base}))


def main():
    ap = argparse.ArgumentParser(prog="powos-manager")
    ap.add_argument("--agent-id", default="manager")
    ap.add_argument("--system-prompt-file")
    ap.add_argument("--mcp-config-file")
    ap.add_argument("--session-store", required=True)
    ap.add_argument("--cwd", help="Directory whose session to resume (per-dir memory).")
    ap.add_argument("--once", metavar="TEXT",
                    help="Send one turn against the per-dir session, then exit.")
    ap.add_argument("--once-stdin", action="store_true",
                    help="Like --once, but read the turn text from stdin "
                         "(lets the widget avoid shell-quoting the message).")
    ap.add_argument("--json-events", action="store_true",
                    help="Emit one normalized JSON event per line (for the widget).")
    ap.add_argument("--list-json", action="store_true",
                    help="Emit sidebar data (projects + agents) as JSON and exit.")
    args = ap.parse_args()

    if args.list_json:
        list_json(args)
        return
    # Live output: line-buffer so a pipe/widget consumer sees each event as it
    # renders (a block-buffered pipe would swallow everything until exit).
    try:
        sys.stdout.reconfigure(line_buffering=True)
    except Exception:
        pass
    m = Manager(args)
    if args.json_events:
        m.sink = m._json_sink
    if args.once_stdin:
        m.once(sys.stdin.read().strip())
    elif args.once is not None:
        m.once(args.once)
    else:
        m.repl()


if __name__ == "__main__":
    main()
