#!/usr/bin/env python3
"""PowOS Manager — a persistent streaming agent session you can leave running.

This is the backend the desktop widget will front (Phase 2); today it drives a
clean terminal REPL. It owns ONE long-lived `claude` process in bidirectional
stream-json mode, so the conversation persists across turns and:

  * per-directory memory  — the session id is stored keyed by cwd and resumed,
    so `manager` in ~/Projects/Foo continues Foo's thread, Bar's in Bar.
  * live inbox delivery    — mail arriving in the manager's comms inbox is
    injected into the session as a user turn automatically; the manager never
    has to poll or call wait_for_message.

Two writers feed the session (you at the keyboard, and the inbox watcher); a
single sender serializes them and only sends between turns, so nothing
interleaves mid-response. Output events are parsed and rendered as panels — the
same shape the widget will consume as JSON later.

The `claude` command is overridable via MANAGER_CLAUDE_CMD (used by the tests to
substitute a hermetic stub that speaks the same stream-json protocol).
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
    def __init__(self, args):
        self.args = args
        self.cwd = os.getcwd()
        self.store = SessionStore(args.session_store)
        self.session_id = self.store.load(self.cwd)
        self.pending = queue.Queue()      # (source, text) awaiting send
        self.busy = threading.Event()     # set while a turn is in flight
        self.stop = threading.Event()
        self.proc = None
        self._comms_root = os.environ.get("COMMS_ROOT", "")
        self._agent_id = args.agent_id

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
            stderr=self._log, text=True, bufsize=1, env=env)
        where = os.path.basename(self.cwd) or "/"
        resumed = f"resumed {self.session_id[:8]}" if self.session_id else "new session"
        print(DIM(f"● PowOS Manager — {where} ({resumed}). "
                  f"Type to talk; Ctrl-D or /exit to quit.\n"))

    # -- the three loops -----------------------------------------------------

    def _send_event(self, text):
        ev = {"type": "user", "message": {"role": "user",
              "content": [{"type": "text", "text": text}]}}
        try:
            self.proc.stdin.write(json.dumps(ev) + "\n")
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
                print(MAGENTA(f"\n✉  {text}"))
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
        """Parse the event stream and render it; clear busy on each result."""
        for line in self.proc.stdout:
            if self.stop.is_set():
                break
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                continue
            self._render(ev)
        self.stop.set()

    # -- rendering (the shape the widget will consume too) -------------------

    def _render(self, ev):
        t = ev.get("type")
        if t == "system" and ev.get("subtype") == "init":
            sid = ev.get("session_id")
            if sid:
                self.session_id = sid
                self.store.save(self.cwd, sid)
        elif t == "assistant":
            for b in ev["message"].get("content", []):
                if b.get("type") == "text" and b.get("text", "").strip():
                    print(BOLD(CYAN("\nmanager")) + DIM(" ▸ ") + b["text"].strip())
                elif b.get("type") == "tool_use":
                    self._render_tool_use(b)
        elif t == "user":
            for b in ev["message"].get("content", []):
                if b.get("type") == "tool_result":
                    self._render_tool_result(b)
        elif t == "result":
            self.busy.clear()
            if ev.get("session_id"):
                self.session_id = ev["session_id"]
                self.store.save(self.cwd, ev["session_id"])
            cost = ev.get("total_cost_usd")
            if cost and _TTY:
                print(DIM(f"  · turn done (${cost:.4f})"))

    def _render_tool_use(self, b):
        name = b.get("name", "?")
        inp = b.get("input", {}) or {}
        hint = (inp.get("command") or inp.get("file_path") or inp.get("path")
                or inp.get("pattern") or inp.get("to") or inp.get("message") or "")
        hint = str(hint).replace("\n", " ")
        if len(hint) > 100:
            hint = hint[:100] + "…"
        print(YELLOW(f"\n  ⚙ {name}") + (DIM(f"  {hint}") if hint else ""))

    def _render_tool_result(self, b):
        content = b.get("content", "")
        if isinstance(content, list):
            content = " ".join(c.get("text", "") for c in content
                               if isinstance(c, dict))
        content = str(content).strip().replace("\n", " ")
        if not content:
            return
        if len(content) > 160:
            content = content[:160] + "…"
        tag = DIM("  ↳ ") + (GREEN("ok") if not b.get("is_error") else _c("31", "err"))
        print(tag + DIM(f"  {content}"))

    # -- terminal frontend ---------------------------------------------------

    def repl(self):
        threading.Thread(target=self.reader_loop, daemon=True).start()
        threading.Thread(target=self.sender_loop, daemon=True).start()
        threading.Thread(target=self.inbox_loop, daemon=True).start()
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
        print(DIM("\n● Manager stopped. Session saved — `powos ai manager` resumes it."))


def main():
    ap = argparse.ArgumentParser(prog="powos-manager")
    ap.add_argument("--agent-id", default="manager")
    ap.add_argument("--system-prompt-file")
    ap.add_argument("--mcp-config-file")
    ap.add_argument("--session-store", required=True)
    # Live output: line-buffer so a pipe/widget consumer sees each event as it
    # renders (a block-buffered pipe would swallow everything until exit).
    try:
        sys.stdout.reconfigure(line_buffering=True)
    except Exception:
        pass
    m = Manager(ap.parse_args())
    m.start()
    m.repl()


if __name__ == "__main__":
    main()
