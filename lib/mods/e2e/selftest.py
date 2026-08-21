#!/usr/bin/env python3
"""Tests for the harness itself.

A test rig that is wrong reports the game as wrong, which is worse than no rig
at all: it sends you debugging code that works. These cover the parts that
failed silently in practice rather than the parts that are obvious.

    python3 selftest.py
"""
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import logs          # noqa: E402
import proc          # noqa: E402
import report        # noqa: E402
import run           # noqa: E402
import state         # noqa: E402

FAILS = []


def check(ok, name, detail=""):
    print(("PASS " if ok else "FAIL ") + name + (f"  {detail}" if detail and not ok else ""))
    if not ok:
        FAILS.append(name)


def ini(body):
    fd, path = tempfile.mkstemp(suffix=".cfg")
    with os.fdopen(fd, "w") as f:
        f.write(body)
    return path


def test_ini_sections():
    """The bug that cost a full game launch: a sectioned key appended at EOF.

    BepInEx scopes settings to their section, so `DebugServer = true` written
    after the last section is read as a setting of that section and the real
    one keeps its default — the feature stays off and nothing says why.
    """
    rev = run.Reversible(tempfile.mkdtemp())

    path = ini("[General]\nFoo = 1\n\n[Debug]\nDebugServer = false\n")
    rev.set_ini(path, "DebugServer", "true", "Debug")
    body = open(path).read()
    check("[Debug]\nDebugServer = true" in body,
          "existing key in the named section is replaced in place", body)

    path = ini("[General]\nFoo = 1\n")
    rev.set_ini(path, "DebugServer", "true", "Debug")
    body = open(path).read()
    check(body.rstrip().endswith("[Debug]\nDebugServer = true"),
          "missing section is created rather than appended blind", body)

    path = ini("[General]\nFoo = 1\n\n[Camera]\nZoom = 2\n")
    rev.set_ini(path, "Bar", "9", "General")
    body = open(path).read()
    general = body.split("[Camera]")[0]
    check("Bar = 9" in general,
          "new key is inserted inside its section, not after the file", body)

    path = ini("[General]\nFoo = 1\n")
    rev.set_ini(path, "Foo", "7")
    check("Foo = 7" in open(path).read(), "sectionless set still works")

    # Restoration is what makes the debug channel safe to switch on. The
    # baseline is the file as it was before the harness touched it — not before
    # the most recent edit, or a run that sets a key twice would restore its own
    # first edit and leave the channel enabled.
    rev2 = run.Reversible(tempfile.mkdtemp())
    path = ini("[Debug]\nDebugServer = false\n")
    pristine = open(path).read()
    rev2.set_ini(path, "DebugServer", "true", "Debug")
    rev2.set_ini(path, "DebugServerPort", "27600", "Debug")
    during = open(path).read()
    check("DebugServer = true" in during and "27600" in during,
          "both edits applied during the run")
    rev2.restore()
    check(open(path).read() == pristine,
          "restore() returns the file to its pre-run state, not its last edit")


def test_log_truncation():
    """A launcher that truncates its log on each run must not blind the watcher.

    BepInEx rewrites LogOutput.log from scratch every launch. Remembering the
    old file's size and seeking there lands past the end of the new, shorter
    file, so the load marker sitting in its first ten lines reads as absent —
    which looks exactly like the mod failing to load.
    """
    fd, path = tempfile.mkstemp()
    os.write(fd, b"x" * 5000 + b"\nold line\n")
    os.close(fd)
    lf = logs.LogFile(path).mark()
    check(lf.find("MARKER") == [], "marker genuinely absent before the rewrite")
    with open(path, "w") as f:
        f.write("fresh run\nMARKER HERE\n")
    check(lf.find("MARKER HERE") == ["MARKER HERE"],
          "marker is found after the log is truncated and rewritten")
    with open(path, "a") as f:
        f.write("later line\n")
    check(lf.find("later line") == ["later line"], "appends after a rewrite still read")
    os.unlink(path)


def test_proc_excludes_self():
    """`pgrep -f X` matches the shell running it; this must never do that."""
    me = os.getpid()
    hits = proc.find("selftest.py")
    check(me not in hits, "find() never returns our own pid", str(hits))
    check(all(h != os.getppid() for h in hits),
          "find() never returns our parent", str(hits))


def test_verdicts():
    """A run that observed nothing is not a pass."""
    r = report.Results("g")
    r.record("a", report.SKIP, "")
    check(r.verdict == "not-run", "all-skipped is not-run, not pass", r.verdict)

    r = report.Results("g")
    r.record("a", report.PASS, "")
    r.record("b", report.SKIP, "")
    check(r.verdict == "pass", "a real pass with a skip is a pass", r.verdict)

    r = report.Results("g")
    r.record("a", report.PASS, "")
    r.record("b", report.FAIL, "")
    check(r.verdict == "fail", "any failure fails the run", r.verdict)

    r = report.Results("g")
    r.record("a", report.FAIL, "")
    r.record("b", report.ERROR, "")
    check(r.verdict == "error",
          "an errored case outranks a failure (the harness is suspect)", r.verdict)


def test_channel_failures_are_loud():
    """A dead channel must raise, never return a plausible-looking empty dict."""
    ch = state.HttpJsonChannel("http://127.0.0.1:1")   # nothing listens on port 1
    check(ch.ready() is False, "unreachable http channel is not ready")
    try:
        ch.state()
        check(False, "unreachable http channel raises")
    except state.ChannelError:
        check(True, "unreachable http channel raises")

    ch = state.FileChannel("/nonexistent/nope.json")
    try:
        ch.state()
        check(False, "missing snapshot file raises")
    except state.ChannelError:
        check(True, "missing snapshot file raises")

    # A stale snapshot is the dangerous case: the file parses fine and every
    # assertion reads a frozen world from a game that died minutes ago.
    fd, path = tempfile.mkstemp(suffix=".json")
    with os.fdopen(fd, "w") as f:
        f.write('{"ok": true}')
    os.utime(path, (0, 0))
    try:
        state.FileChannel(path, max_age=5).state()
        check(False, "a stale snapshot is rejected, not served as live state")
    except state.ChannelError:
        check(True, "a stale snapshot is rejected, not served as live state")
    check(state.FileChannel(path, max_age=0).state() == {"ok": True},
          "max_age=0 disables the staleness check")
    os.unlink(path)


def test_conf_round_trip():
    """games.d confs are bash; arrays and single-quoted placeholders must survive."""
    path = ini('''GAME_NAME="X"
GAME_APPID=1
E2E_PADS=2
E2E_LOG_FILES=('${GAME_DIR}/a.log' "/tmp/b.log")
''')
    conf = run.load_conf(path)
    check(conf.get("GAME_NAME") == "X", "scalar read")
    check(conf.get("E2E_LOG_FILES") == ["${GAME_DIR}/a.log", "/tmp/b.log"],
          "array read, placeholder unexpanded", str(conf.get("E2E_LOG_FILES")))
    conf["GAME_DIR"] = "/games/x"
    check(run.expand(conf["E2E_LOG_FILES"][0], conf) == "/games/x/a.log",
          "placeholder expands against resolved paths")
    os.unlink(path)


if __name__ == "__main__":
    for fn in (test_ini_sections, test_log_truncation, test_proc_excludes_self, test_verdicts,
               test_channel_failures_are_loud, test_conf_round_trip):
        fn()
    print()
    print("ALL PASS" if not FAILS else f"{len(FAILS)} FAILURES: {FAILS}")
    sys.exit(1 if FAILS else 0)
