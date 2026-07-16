#!/usr/bin/env python3
"""Minimal QMP (QEMU Machine Protocol) client for tier-2 boot tests.

Commands:
    qmp.py <socket> screendump <output.ppm>    Take a VGA framebuffer screenshot
    qmp.py <socket> sendkey <key1> [key2 ...]  Type keys sequentially (100ms delay)
    qmp.py <socket> quit                       Graceful VM shutdown
    qmp.py check-blank <ppm-file>              Exit 0 = has content, 1 = blank, 2 = error
"""
import json
import socket
import sys
import time


def _recv_line(s):
    buf = b""
    while b"\n" not in buf:
        chunk = s.recv(4096)
        if not chunk:
            raise ConnectionError("QMP socket closed unexpectedly")
        buf += chunk
    return buf


def _recv_response(s):
    """Read until we get a return/error response, skipping async events."""
    while True:
        line = _recv_line(s)
        for part in line.decode().strip().split("\n"):
            part = part.strip()
            if not part:
                continue
            obj = json.loads(part)
            if "return" in obj or "error" in obj:
                return obj


def qmp_connect(sock_path):
    """Connect and complete QMP capability negotiation."""
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(10)
    s.connect(sock_path)
    _recv_line(s)  # greeting
    s.sendall(json.dumps({"execute": "qmp_capabilities"}).encode() + b"\n")
    resp = _recv_response(s)
    if "error" in resp:
        raise RuntimeError(f"QMP capability negotiation failed: {resp}")
    return s


def qmp_command(s, cmd, **kwargs):
    msg = {"execute": cmd}
    if kwargs:
        msg["arguments"] = kwargs
    s.sendall(json.dumps(msg).encode() + b"\n")
    return _recv_response(s)


def cmd_screendump(sock_path, output_file):
    s = qmp_connect(sock_path)
    resp = qmp_command(s, "screendump", filename=output_file)
    s.close()
    if "error" in resp:
        print(f"screendump error: {resp['error']}", file=sys.stderr)
        return 1
    return 0


def cmd_sendkey(sock_path, keys):
    s = qmp_connect(sock_path)
    for key in keys:
        resp = qmp_command(s, "send-key",
                           keys=[{"type": "qcode", "data": key}])
        if "error" in resp:
            print(f"sendkey error for '{key}': {resp['error']}", file=sys.stderr)
        time.sleep(0.1)
    s.close()
    return 0


def cmd_quit(sock_path):
    try:
        s = qmp_connect(sock_path)
        qmp_command(s, "quit")
        s.close()
    except (ConnectionError, OSError):
        pass  # VM may have already exited
    return 0


def cmd_check_blank(ppm_path, threshold=8):
    """Analyze a PPM screenshot for content.

    Returns 0 if the screen has visible content (not blank),
    1 if it appears blank (solid color), 2 on error.
    """
    try:
        with open(ppm_path, "rb") as f:
            data = f.read()
    except (FileNotFoundError, PermissionError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 2

    # Parse PPM P6 header: magic, width height, maxval (3 newline-terminated lines)
    idx = 0
    try:
        for _ in range(3):
            idx = data.index(b"\n", idx) + 1
    except ValueError:
        print("error: invalid PPM format", file=sys.stderr)
        return 2

    sample = data[idx:idx + 16384]
    if len(sample) < 64:
        print("error: insufficient pixel data", file=sys.stderr)
        return 2

    unique = len(set(sample))
    if unique <= threshold:
        print(f"blank ({unique} unique values)")
        return 1
    else:
        print(f"content ({unique} unique values)")
        return 0


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)

    # Standalone subcommand: check-blank <file>
    if sys.argv[1] == "check-blank":
        sys.exit(cmd_check_blank(sys.argv[2]))

    sock_path = sys.argv[1]
    command = sys.argv[2]

    if command == "screendump":
        if len(sys.argv) < 4:
            print("Usage: qmp.py <socket> screendump <output.ppm>", file=sys.stderr)
            sys.exit(1)
        sys.exit(cmd_screendump(sock_path, sys.argv[3]))
    elif command == "sendkey":
        if len(sys.argv) < 4:
            print("Usage: qmp.py <socket> sendkey <key1> [key2 ...]", file=sys.stderr)
            sys.exit(1)
        sys.exit(cmd_sendkey(sock_path, sys.argv[3:]))
    elif command == "quit":
        sys.exit(cmd_quit(sock_path))
    else:
        print(f"Unknown command: {command}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
