#!/usr/bin/env python3
"""Evaluate JS in powos-shell's panel page over DevTools (QTWEBENGINE_REMOTE_DEBUGGING=9222), standard library only:
the nested bench (dev/nested.sh) has no node or websocket module.

    cdp-eval.py 'document.querySelectorAll(".panel-task").length'
    cdp-eval.py 'document.querySelector(".panel-task:not(.active)").click()'

    cdp-eval.py --shot out.png      the page as Chromium drew it, transparent where it is (no compositor: KWin's blur
                                    and the wallpaper aren't in it - dev/phone.sh page lays it over the wallpaper)

Awaits a promise result; prints the value as JSON. PORT env: the DevTools port (9222). MODE env: the page whose
?mode= it is (any powos: page if unset). Read-only checks on a page someone may be looking at.
"""
import base64
import json
import os
import socket
import struct
import sys
import urllib.request

port = int(os.environ.get("PORT", "9222"))
pages = json.load(urllib.request.urlopen(f"http://127.0.0.1:{port}/json"))
mode = os.environ.get("MODE")
page = next(p for p in pages if p.get("type") == "page" and p["url"].startswith("powos://") and (not mode or f"mode={mode}" in p["url"]))
path = page["webSocketDebuggerUrl"].split(str(port), 1)[1]

sock = socket.create_connection(("127.0.0.1", port))
key = base64.b64encode(os.urandom(16)).decode()
sock.sendall(
    f"GET {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
    f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n".encode()
)
buf = b""
while b"\r\n\r\n" not in buf:
    buf += sock.recv(4096)
rest = buf.split(b"\r\n\r\n", 1)[1]


def send(obj):
    data = json.dumps(obj).encode()
    mask = os.urandom(4)
    n = len(data)
    head = bytes([0x81]) + (bytes([0x80 | n]) if n < 126 else bytes([0x80 | 126]) + struct.pack(">H", n) if n < 65536
                            else bytes([0x80 | 127]) + struct.pack(">Q", n))
    sock.sendall(head + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))


def read_exact(n):
    global rest
    while len(rest) < n:
        rest += sock.recv(65536)
    out, rest = rest[:n], rest[n:]
    return out


def recv():
    b1, b2 = read_exact(2)
    n = b2 & 0x7F
    if n == 126:
        n = struct.unpack(">H", read_exact(2))[0]
    elif n == 127:
        n = struct.unpack(">Q", read_exact(8))[0]
    return json.loads(read_exact(n))


if sys.argv[1] == "--shot":
    # Transparent where the page is (the wallpaper's place - a screenshot paints it white otherwise), for this
    # capture only: the default background is put back right after.
    send({"id": 1, "method": "Emulation.setDefaultBackgroundColorOverride", "params": {"color": {"r": 0, "g": 0, "b": 0, "a": 0}}})
    # captureBeyondViewport: a frame drawn for the capture itself - a frozen session (no frame callbacks from KWin)
    # draws none of its own, and the override's repaint never reached the screen's frame.
    send({"id": 2, "method": "Page.captureScreenshot", "params": {"format": "png", "captureBeyondViewport": True}})
    send({"id": 3, "method": "Emulation.setDefaultBackgroundColorOverride", "params": {}})
    pending = {2, 3}  # the screenshot answers after the reset: wait for both
    while pending:
        msg = recv()
        if msg.get("id") == 2:
            open(sys.argv[2], "wb").write(base64.b64decode(msg["result"]["data"]))
            print(sys.argv[2])
        pending.discard(msg.get("id"))
    sys.exit(0)

send({"id": 1, "method": "Runtime.evaluate",
      "params": {"expression": sys.argv[1], "awaitPromise": True, "returnByValue": True}})
while True:
    msg = recv()
    if msg.get("id") == 1:
        res = msg["result"]
        if "exceptionDetails" in res:
            print(json.dumps(res["exceptionDetails"].get("exception", res["exceptionDetails"])), file=sys.stderr)
            sys.exit(1)
        print(json.dumps(res["result"].get("value")))
        break
