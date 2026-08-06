#!/usr/bin/env python3
# vu-rcon.py — Frostbite/BF3 RCON client for Venice Unleashed, plus a
# dependency-free "watch the mods dir and hot-reload" dev loop.
#
# VU speaks the vanilla BF3 PC Server Remote Administration Protocol: a binary
# TCP protocol (default port 47200) whose packets are arrays of length-prefixed
# words. Auth is a salted hash: request `login.hashed`, the server returns a
# hex salt, you reply with MD5(salt_bytes + password) uppercased.
#
# This is intentionally a single stdlib file (socket/struct/hashlib/os/time) so
# it ships with PowOS and runs anywhere python3 does — no pip, no inotify-tools.
#
# Usage:
#   vu-rcon.py send  <host> <port> <password> <word> [word ...]
#   vu-rcon.py watch <host> <port> <password> <dir> <logfile|-> [reload-command...]
#
# `watch` polls file mtimes under <dir> (only .lua/.json/.txt), debounced, and
# sends <reload-command> (default modList.ReloadExtensions) on any change,
# reconnecting if the server bounces. If <logfile> is a path (not "-") it also
# tails it, interleaving server output so a reload's errors surface inline.

import hashlib
import os
import re
import socket
import struct
import sys
import time

# Strip ANSI/terminal control sequences — the server log is a PTY recording, so
# it carries colour codes and cursor moves we don't want in a plain-text feed.
_ANSI = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b[()][B0]|[\r\x07]")

USAGE = (
    "usage:\n"
    "  vu-rcon.py send  <host> <port> <password> <word> [word ...]\n"
    "  vu-rcon.py watch <host> <port> <password> <dir> <logfile|-> [reload-command...]\n"
)

RESPONSE_BIT = 0x40000000
SERVER_BIT = 0x80000000


def _encode(words, seq):
    """Client request: origin=client(0), response=0, sequence=seq."""
    payload = b""
    for w in words:
        wb = w.encode("utf-8")
        payload += struct.pack("<I", len(wb)) + wb + b"\x00"
    total = 12 + len(payload)
    return struct.pack("<III", seq & 0x3FFFFFFF, total, len(words)) + payload


def _recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise IOError("RCON connection closed by server")
        buf += chunk
    return buf


def _recv_packet(sock):
    seq, total, nwords = struct.unpack("<III", _recv_exact(sock, 12))
    body = _recv_exact(sock, total - 12)
    words, off = [], 0
    for _ in range(nwords):
        (wlen,) = struct.unpack("<I", body[off:off + 4])
        off += 4
        words.append(body[off:off + wlen].decode("utf-8", "replace"))
        off += wlen + 1  # skip trailing NUL
    return seq, words


class Rcon:
    def __init__(self, host, port, password, timeout=6):
        self.sock = socket.create_connection((host, int(port)), timeout=timeout)
        self.sock.settimeout(timeout)
        self.password = password
        self.seq = 0

    def _cmd(self, *words):
        seq = self.seq
        self.seq += 1
        self.sock.sendall(_encode(list(words), seq))
        # Skip any server-initiated events (origin bit set, not a response);
        # return the first packet flagged as a response.
        while True:
            rseq, rwords = _recv_packet(self.sock)
            if rseq & RESPONSE_BIT:
                return rwords

    def login(self):
        r = self._cmd("login.hashed")
        if not r or r[0] != "OK":
            raise IOError("salt request rejected: %r" % (r,))
        salt = bytes.fromhex(r[1])
        digest = hashlib.md5(salt + self.password.encode("utf-8")).hexdigest().upper()
        r = self._cmd("login.hashed", digest)
        if not r or r[0] != "OK":
            raise IOError("login failed (wrong admin.password?): %r" % (r,))
        return self

    def command(self, *words):
        return self._cmd(*words)

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


def _fmt(words):
    if not words:
        return "(no reply)"
    head, rest = words[0], words[1:]
    if head == "OK":
        return "OK" + (" " + " ".join(rest) if rest else "")
    return "ERROR: " + " ".join(words)


def _snapshot(root, exts=(".lua", ".json", ".txt")):
    state = {}
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in (".git", "node_modules")]
        for fn in filenames:
            if fn.endswith(exts):
                p = os.path.join(dirpath, fn)
                try:
                    state[p] = os.stat(p).st_mtime_ns
                except OSError:
                    pass
    return state


def do_send(host, port, password, words):
    r = Rcon(host, port, password).login()
    try:
        print(_fmt(r.command(*words)))
    finally:
        r.close()
    return 0


class LogTail:
    """Follow a growing logfile, surviving truncation/rotation. Starts at EOF so
    only output produced *after* the dev loop starts is shown."""

    ERR = ("error", "exception", "traceback", "failed", "nil value",
           "stack traceback", "attempt to")

    def __init__(self, path):
        self.path = path if path and path != "-" else None
        self.f = None
        self.inode = None

    def _open(self, at_end=True):
        try:
            f = open(self.path, "r", errors="replace")
            self.inode = os.fstat(f.fileno()).st_ino
            if at_end:
                f.seek(0, os.SEEK_END)
            self.f = f
        except OSError:
            self.f = None

    def poll(self):
        if not self.path:
            return []
        if self.f is None:
            self._open()
            return []
        out = []
        try:
            st = os.stat(self.path)
            if st.st_ino != self.inode or st.st_size < self.f.tell():
                self.f.close()
                self._open(at_end=False)  # rotated/truncated: read from top
            for line in self.f:
                out.append(line.rstrip("\n"))
        except OSError:
            self.f = None
        return out

    def emit(self):
        for raw in self.poll():
            line = _ANSI.sub("", raw).strip()
            if not line:
                continue
            mark = "  !" if any(k in line.lower() for k in self.ERR) else "   "
            print("[srv]%s %s" % (mark, line))


def do_watch(host, port, password, watchdir, logfile, reload_words):
    watchdir = os.path.abspath(watchdir)
    if not os.path.isdir(watchdir):
        print("vu-rcon: not a directory: %s" % watchdir, file=sys.stderr)
        return 1
    tail = LogTail(logfile)

    def connect():
        while True:
            try:
                r = Rcon(host, port, password).login()
                print("[vu-dev] connected to %s:%s — watching %s" % (host, port, watchdir))
                print("[vu-dev] save any .lua/.json to hot-reload (%s); Ctrl-C to stop"
                      % " ".join(reload_words))
                return r
            except (OSError, IOError) as e:
                print("[vu-dev] server not reachable (%s) — retrying in 3s…" % e)
                tail.emit()
                time.sleep(3)

    r = connect()
    last = _snapshot(watchdir)
    try:
        while True:
            time.sleep(0.5)
            tail.emit()  # stream server output as it happens
            now = _snapshot(watchdir)
            if now == last:
                continue
            changed = [p for p in now if last.get(p) != now.get(p)]
            rel = os.path.relpath(sorted(changed)[0], watchdir) if changed else "?"
            last = now
            stamp = time.strftime("%H:%M:%S")
            extra = "" if len(changed) <= 1 else " (+%d more)" % (len(changed) - 1)
            print("[vu-dev] %s  change: %s%s → reloading…" % (stamp, rel, extra))
            try:
                print("[vu-dev]   %s" % _fmt(r.command(*reload_words)))
            except (OSError, IOError) as e:
                print("[vu-dev]   reload send failed (%s) — reconnecting…" % e)
                r.close()
                r = connect()
                last = _snapshot(watchdir)
            time.sleep(0.4)  # let the reload produce log output, then surface it
            tail.emit()
    except KeyboardInterrupt:
        print("\n[vu-dev] stopped.")
        return 0
    finally:
        r.close()


def main(argv):
    if len(argv) < 2:
        print(USAGE)
        return 2
    mode = argv[1]
    try:
        if mode == "send":
            host, port, password = argv[2], argv[3], argv[4]
            return do_send(host, port, password, argv[5:])
        if mode == "watch":
            host, port, password, watchdir, logfile = argv[2:7]
            reload_words = argv[7:] or ["modList.ReloadExtensions"]
            return do_watch(host, port, password, watchdir, logfile, reload_words)
    except (OSError, IOError) as e:
        print("vu-rcon: %s" % e, file=sys.stderr)
        return 1
    except IndexError:
        print("vu-rcon: missing arguments\n" + USAGE, file=sys.stderr)
        return 2
    print("vu-rcon: unknown mode %r" % mode, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
