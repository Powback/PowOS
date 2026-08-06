#!/usr/bin/env python3
# vu-cdp.py — minimal Chrome DevTools Protocol client for VU's WebUI.
#
# VU's WebUI is Coherent Gameface/CEF (Chromium). Launched with -dwebui it opens
# a CDP endpoint (default http://localhost:8884). This lets `powos ai` read the
# client console / Lua-facing WebUI errors, evaluate JS, click UI elements, and
# screenshot the overlay — the AI's eyes+hands for mod UIs (MapEditor's editor is
# a WebUI), soldier-select, etc.
#
# Stdlib only (socket/urllib/base64/hashlib/struct) — no pip, matching vu-rcon.py.
#
# Usage:
#   vu-cdp.py targets [host:port]
#   vu-cdp.py eval    [host:port] <javascript>
#   vu-cdp.py console [host:port] [seconds]         # stream console + exceptions
#   vu-cdp.py click   [host:port] <css-selector>
#   vu-cdp.py screenshot [host:port] <out.png>
#   vu-cdp.py title   [host:port]

import base64
import json
import os
import socket
import struct
import sys
import time
import urllib.request

DEFAULT = "localhost:8884"


def _split(hostport, default_port):
    host, _, port = hostport.partition(":")
    return host or "localhost", int(port) if port else default_port


def http_targets(hostport):
    host, port = _split(hostport, 8884)
    with urllib.request.urlopen("http://%s:%d/json" % (host, port), timeout=5) as r:
        return json.load(r)


def pick_page(hostport):
    """Return the webSocketDebuggerUrl of the first inspectable page."""
    targets = http_targets(hostport)
    pages = [t for t in targets if t.get("type") == "page" and t.get("webSocketDebuggerUrl")]
    chosen = (pages or [t for t in targets if t.get("webSocketDebuggerUrl")])
    if not chosen:
        raise IOError("no inspectable CDP target at %s (is the client up with -dwebui?)" % hostport)
    return chosen[0]["webSocketDebuggerUrl"]


class WS:
    def __init__(self, url):
        assert url.startswith("ws://"), url
        rest = url[5:]
        hostport, _, path = rest.partition("/")
        host, port = _split(hostport, 80)
        self.sock = socket.create_connection((host, port), timeout=10)
        key = base64.b64encode(os.urandom(16)).decode()
        req = ("GET /%s HTTP/1.1\r\nHost: %s:%d\r\nUpgrade: websocket\r\n"
               "Connection: Upgrade\r\nSec-WebSocket-Key: %s\r\n"
               "Sec-WebSocket-Version: 13\r\n\r\n" % (path, host, port, key))
        self.sock.sendall(req.encode())
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise IOError("CDP handshake failed")
            buf += chunk
        if b" 101 " not in buf.split(b"\r\n", 1)[0]:
            raise IOError("CDP did not upgrade: %r" % buf.split(b"\r\n", 1)[0])

    def send(self, obj):
        payload = json.dumps(obj).encode("utf-8")
        header = bytearray([0x81])
        n = len(payload)
        mask = os.urandom(4)
        if n < 126:
            header.append(0x80 | n)
        elif n < 65536:
            header.append(0x80 | 126)
            header += struct.pack(">H", n)
        else:
            header.append(0x80 | 127)
            header += struct.pack(">Q", n)
        header += mask
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self.sock.sendall(bytes(header) + masked)

    def _rd(self, n):
        b = b""
        while len(b) < n:
            c = self.sock.recv(n - len(b))
            if not c:
                raise IOError("CDP socket closed")
            b += c
        return b

    def recv(self):
        while True:
            h = self._rd(2)
            op = h[0] & 0x0F
            ln = h[1] & 0x7F
            if ln == 126:
                ln = struct.unpack(">H", self._rd(2))[0]
            elif ln == 127:
                ln = struct.unpack(">Q", self._rd(8))[0]
            data = self._rd(ln) if ln else b""
            if op == 0x8:
                raise IOError("CDP closed by peer")
            if op in (0x0, 0x1, 0x2):
                return data.decode("utf-8", "replace")
            # ping/pong → ignore

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


class CDP:
    def __init__(self, hostport):
        self.ws = WS(pick_page(hostport))
        self.id = 0

    def call(self, method, params=None, timeout=15):
        self.id += 1
        mid = self.id
        self.ws.send({"id": mid, "method": method, "params": params or {}})
        self.ws.sock.settimeout(timeout)
        while True:
            msg = json.loads(self.ws.recv())
            if msg.get("id") == mid:
                if "error" in msg:
                    raise IOError("CDP %s: %s" % (method, msg["error"].get("message")))
                return msg.get("result", {})
            # events dropped here

    def evaluate(self, js, await_promise=True):
        r = self.call("Runtime.evaluate", {
            "expression": js, "returnByValue": True,
            "awaitPromise": await_promise, "allowUnsafeEvalBlocklist": True,
        })
        if r.get("exceptionDetails"):
            ex = r["exceptionDetails"]
            return "EXCEPTION: " + (ex.get("exception", {}).get("description") or ex.get("text", "?"))
        return r.get("result", {}).get("value")

    def close(self):
        self.ws.close()


def cmd_targets(hostport):
    for t in http_targets(hostport):
        print("%-8s %-30s %s" % (t.get("type", "?"), (t.get("title") or "")[:30], t.get("url", "")))
    return 0


def cmd_eval(hostport, js):
    c = CDP(hostport)
    try:
        v = c.evaluate(js)
        print(v if isinstance(v, str) else json.dumps(v))
    finally:
        c.close()
    return 0


def cmd_title(hostport):
    return cmd_eval(hostport, "document.title + ' | ' + location.href")


def cmd_click(hostport, selector):
    c = CDP(hostport)
    try:
        js = ("(()=>{const e=document.querySelector(%s);"
              "if(!e)return 'NOT FOUND: '+%s;e.click();return 'clicked '+(e.textContent||e.id||%s).trim().slice(0,40);})()"
              % (json.dumps(selector), json.dumps(selector), json.dumps(selector)))
        print(c.evaluate(js))
    finally:
        c.close()
    return 0


def cmd_console(hostport, seconds):
    c = CDP(hostport)
    try:
        c.call("Runtime.enable")
        c.call("Log.enable")
        print("[cdp] streaming console for %ss (Ctrl-C to stop)…" % seconds)
        c.ws.sock.settimeout(1.0)
        elapsed = 0
        while elapsed < seconds:
            try:
                msg = json.loads(c.ws.recv())
            except socket.timeout:
                elapsed += 1
                continue
            m = msg.get("method")
            p = msg.get("params", {})
            if m == "Runtime.consoleAPICalled":
                args = " ".join(str(a.get("value", a.get("description", ""))) for a in p.get("args", []))
                print("[console.%s] %s" % (p.get("type", "log"), args))
            elif m == "Runtime.exceptionThrown":
                d = p.get("exceptionDetails", {})
                print("[EXCEPTION] %s" % (d.get("exception", {}).get("description") or d.get("text")))
            elif m == "Log.entryAdded":
                e = p.get("entry", {})
                print("[log.%s] %s" % (e.get("level"), e.get("text")))
    except KeyboardInterrupt:
        pass
    finally:
        c.close()
    return 0


def cmd_screenshot(hostport, outpath):
    c = CDP(hostport)
    try:
        c.call("Page.enable")
        r = c.call("Page.captureScreenshot", {"format": "png"}, timeout=20)
        data = base64.b64decode(r["data"])
        with open(outpath, "wb") as f:
            f.write(data)
        print("wrote %s (%d bytes)" % (outpath, len(data)))
    finally:
        c.close()
    return 0


USAGE = (
    "usage: vu-cdp.py [--addr host:port] <mode> [args]\n"
    "  modes: targets | title | eval <js> | click <css> | console [secs] | screenshot <out.png>\n"
    "  --addr defaults to $VU_CDP_ADDR or localhost:8884\n"
)


def main(argv):
    argv = argv[1:]
    hp = os.environ.get("VU_CDP_ADDR", DEFAULT)
    if argv and argv[0] == "--addr":
        hp = argv[1]; argv = argv[2:]
    if not argv:
        print(USAGE)
        return 2
    mode = argv[0]
    rest = argv[1:]
    try:
        if mode == "targets":
            return cmd_targets(hp)
        if mode == "title":
            return cmd_title(hp)
        if mode == "eval":
            return cmd_eval(hp, rest[0])
        if mode == "click":
            return cmd_click(hp, rest[0])
        if mode == "console":
            return cmd_console(hp, int(rest[0]) if rest else 30)
        if mode == "screenshot":
            return cmd_screenshot(hp, rest[0] if rest else "webui.png")
    except (OSError, IOError) as e:
        print("vu-cdp: %s" % e, file=sys.stderr)
        return 1
    except IndexError:
        print("vu-cdp: missing argument", file=sys.stderr)
        return 2
    print("vu-cdp: unknown mode %r" % mode, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
