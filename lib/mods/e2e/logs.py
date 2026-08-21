#!/usr/bin/env python3
"""Log assertions — the weak channel, and why it stays the weak one.

A log line proves the code that writes it ran. That makes logs excellent for
"did the mod load" and poor for everything else: they cannot answer where a
player is, whether health went down, or what the game currently believes.

They also lie about *when*. Game and loader logs are block-buffered — typically
4KB — so the tail does not reach disk while the process runs. A harness tailing
a log can sit watching nothing for a minute while the event it is waiting for
happened long ago and is sitting in the writer's buffer. Anything time-sensitive
must come from the state channel; a log watcher waiting on a marker needs a
timeout generous enough to cover a block that has not flushed, and must never be
the only evidence for a timing claim.
"""
from __future__ import annotations

import os
import re
import time


class LogFile:
    def __init__(self, path, name=None):
        self.path = os.path.expanduser(path)
        self.name = name or os.path.basename(self.path)
        self._start_size = 0

    def exists(self):
        return os.path.isfile(self.path)

    def mark(self):
        """Remember the current end of file, so later reads see only new lines.

        Preferred over truncating: the game may hold the file open, and a
        truncated-out-from-under-it log can strand the writer's offset and
        leave a multi-megabyte hole of NULs.
        """
        self._start_size = os.path.getsize(self.path) if self.exists() else 0
        return self

    def text(self, since_mark=True):
        """Everything written since mark() — or everything, if it was rotated.

        A launcher that truncates its log on every run (BepInEx does) leaves the
        file SHORTER than the offset we remembered. Seeking to that offset then
        lands past the end and reads nothing at all, so a marker that is sitting
        in plain sight in the first ten lines is reported as never appearing.
        A file smaller than the mark is a new file; read it whole.
        """
        if not self.exists():
            return ""
        size = os.path.getsize(self.path)
        offset = self._start_size if since_mark else 0
        if offset and size < offset:
            offset = 0
            self._start_size = 0
        with open(self.path, "r", encoding="utf-8", errors="replace") as f:
            if offset:
                f.seek(offset)
            return f.read()

    def lines(self, since_mark=True):
        return self.text(since_mark).splitlines()

    def find(self, pattern, since_mark=True, regex=False):
        """Matching lines, newest last."""
        hay = self.lines(since_mark)
        if regex:
            rx = re.compile(pattern)
            return [l for l in hay if rx.search(l)]
        return [l for l in hay if pattern in l]

    def wait_for(self, pattern, timeout=120, interval=1.0, regex=False,
                 since_mark=True):
        """Block until a line matches. Returns the line, or None on timeout."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            hits = self.find(pattern, since_mark, regex)
            if hits:
                return hits[-1]
            time.sleep(interval)
        return None

    def tail(self, n=40, since_mark=False):
        return "\n".join(self.lines(since_mark)[-n:])


class LogSet:
    """Several logs treated as one, so a marker can live in any of them."""

    def __init__(self, files):
        self.files = [f if isinstance(f, LogFile) else LogFile(f) for f in files]

    def mark(self):
        for f in self.files:
            f.mark()
        return self

    def find(self, pattern, regex=False, since_mark=True):
        out = []
        for f in self.files:
            out += [(f.name, l) for l in f.find(pattern, since_mark, regex)]
        return out

    def wait_for(self, pattern, timeout=120, interval=1.0, regex=False):
        deadline = time.time() + timeout
        while time.time() < deadline:
            hits = self.find(pattern, regex)
            if hits:
                return hits[-1]
            time.sleep(interval)
        return None

    def present(self):
        return [f for f in self.files if f.exists()]
