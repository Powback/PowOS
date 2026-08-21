#!/usr/bin/env python3
"""State channels — how the harness reads live game state.

This is the part that separates a real end-to-end test from a smoke test. With
launch and input alone a harness can only assert "it did not crash" and "a
button was pressed"; it cannot assert that the button did anything. Every
assertion worth writing needs to read what the game currently believes.

No engine offers this by default, so each game exposes it some way of its own
and this module normalises them behind one interface:

    channel.ready()                 -> bool     is the channel answering
    channel.state()                 -> dict     current game state
    channel.command(name, **args)   -> dict     drive the game directly
    channel.describe()              -> str      for the report

Adapters
--------
`http-json`  The game (or a mod inside it) serves JSON on a loopback port.
             Recommended for anything you can put code inside: cheapest to
             implement, easiest to assert on, and it works through Wine —
             a Windows build under Proton listening on 127.0.0.1 is reachable
             from Linux tooling because Wine's sockets are the host's.

`cdp`        Chrome DevTools Protocol, for games whose UI is a browser engine
             (Venice Unleashed's Coherent Gameface WebUI). Shells out to
             powos' vu-cdp.py and evaluates JS.

`file`       The game writes a JSON snapshot to disk and the harness reads it.
             The fallback for a game you cannot open a socket in. Poll-only,
             no commands, but it survives anything a socket cannot.

`none`       No channel. The harness degrades to log + process assertions and
             says so loudly in the report, because assertions written against
             a `none` channel are not measuring the game.
"""
from __future__ import annotations

import json
import os
import subprocess
import time
import urllib.error
import urllib.request


class ChannelError(RuntimeError):
    pass


class Channel:
    kind = "none"

    def ready(self) -> bool:
        return False

    def state(self) -> dict:
        raise ChannelError("this game has no state channel")

    def command(self, name, **args) -> dict:
        raise ChannelError("this game's state channel cannot issue commands")

    def describe(self) -> str:
        return self.kind

    def wait_ready(self, timeout=120, interval=1.0, on_wait=None):
        """Block until the channel answers. Returns True/False, never raises."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.ready():
                return True
            if on_wait:
                on_wait(int(deadline - time.time()))
            time.sleep(interval)
        return False

    def wait_for(self, predicate, timeout=30, interval=0.5):
        """Poll state() until `predicate(state)` is true. Returns (ok, last_state)."""
        deadline = time.time() + timeout
        last = None
        while time.time() < deadline:
            try:
                last = self.state()
                if predicate(last):
                    return True, last
            except Exception:
                pass
            time.sleep(interval)
        return False, last


class HttpJsonChannel(Channel):
    kind = "http-json"

    def __init__(self, base_url, state_path="/state", command_path="/cmd",
                 timeout=5):
        self.base = base_url.rstrip("/")
        self.state_path = state_path
        self.command_path = command_path
        self.timeout = timeout

    def _get(self, path, params=None):
        url = self.base + path
        if params:
            from urllib.parse import urlencode
            url += "?" + urlencode(params)
        try:
            with urllib.request.urlopen(url, timeout=self.timeout) as r:
                body = r.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as ex:
            body = ex.read().decode("utf-8", "replace")
            try:
                return json.loads(body)
            except Exception:
                raise ChannelError(f"HTTP {ex.code} from {url}: {body[:200]}")
        except Exception as ex:
            raise ChannelError(f"{type(ex).__name__} talking to {url}: {ex}")
        try:
            return json.loads(body)
        except Exception:
            raise ChannelError(f"non-JSON from {url}: {body[:200]}")

    def ready(self):
        try:
            return isinstance(self._get(self.state_path), dict)
        except Exception:
            return False

    def state(self):
        return self._get(self.state_path)

    def command(self, name, **args):
        params = dict(args)
        params["do"] = name
        return self._get(self.command_path, params)

    def describe(self):
        return f"http-json {self.base}{self.state_path}"


class CdpChannel(Channel):
    """Chrome DevTools Protocol, via powos' vu-cdp.py."""
    kind = "cdp"

    def __init__(self, addr="localhost:8884", target=None, state_js=None,
                 cdp_py=None):
        self.addr = addr
        self.target = target
        self.state_js = state_js
        self.cdp_py = cdp_py or os.environ.get(
            "VU_CDP_PY",
            os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                         "vu-cdp.py"))

    def _run(self, *argv, timeout=30):
        cmd = ["python3", self.cdp_py, "--addr", self.addr]
        if self.target:
            cmd += ["--target", self.target]
        cmd += list(argv)
        try:
            p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        except subprocess.TimeoutExpired:
            raise ChannelError(f"cdp {argv[0]} timed out")
        return p

    def ready(self):
        try:
            return self._run("targets", timeout=15).returncode == 0
        except Exception:
            return False

    def eval(self, js, timeout=30):
        """Evaluate JS that RETURNS a JSON string; the last JSON line wins."""
        p = self._run("eval", js, timeout=timeout)
        for line in reversed((p.stdout or "").strip().splitlines()):
            line = line.strip()
            if not line:
                continue
            try:
                return json.loads(line)
            except Exception:
                return {"__raw": line}
        raise ChannelError((p.stderr or "no output").strip())

    def state(self):
        if not self.state_js:
            raise ChannelError("cdp channel has no state_js configured")
        return self.eval(self.state_js)

    def describe(self):
        return f"cdp {self.addr}" + (f" target~{self.target}" if self.target else "")


class FileChannel(Channel):
    """The game writes JSON to a path; we read it. Poll-only, no commands."""
    kind = "file"

    def __init__(self, path, max_age=10.0):
        self.path = path
        self.max_age = max_age

    def ready(self):
        try:
            return self.state() is not None
        except Exception:
            return False

    def state(self):
        if not os.path.exists(self.path):
            raise ChannelError(f"no snapshot at {self.path}")
        age = time.time() - os.path.getmtime(self.path)
        if self.max_age and age > self.max_age:
            raise ChannelError(
                f"snapshot at {self.path} is {age:.0f}s stale — the game is not "
                "writing it (crashed, or the debug flag is off)")
        with open(self.path, "r", encoding="utf-8", errors="replace") as f:
            return json.load(f)

    def describe(self):
        return f"file {self.path}"


def build(spec: dict) -> Channel:
    """Construct a channel from a games.d declaration."""
    kind = (spec.get("kind") or "none").lower()
    if kind in ("none", ""):
        return Channel()
    if kind == "http-json":
        url = spec.get("url")
        if not url:
            raise ChannelError("http-json channel needs a url")
        return HttpJsonChannel(url, spec.get("state_path", "/state"),
                               spec.get("command_path", "/cmd"))
    if kind == "cdp":
        return CdpChannel(spec.get("addr", "localhost:8884"),
                          spec.get("target"), spec.get("state_js"))
    if kind == "file":
        path = spec.get("path")
        if not path:
            raise ChannelError("file channel needs a path")
        return FileChannel(path)
    raise ChannelError(f"unknown state channel kind '{kind}'")


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser(description="Poke a game's state channel")
    ap.add_argument("--kind", default="http-json")
    ap.add_argument("--url")
    ap.add_argument("--path")
    ap.add_argument("--addr", default="localhost:8884")
    ap.add_argument("--wait", type=int, default=0)
    a = ap.parse_args()
    ch = build({"kind": a.kind, "url": a.url, "path": a.path, "addr": a.addr})
    if a.wait and not ch.wait_ready(a.wait):
        print(f"channel not ready after {a.wait}s: {ch.describe()}")
        raise SystemExit(1)
    print(json.dumps(ch.state(), indent=2))
