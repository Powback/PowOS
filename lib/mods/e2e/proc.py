#!/usr/bin/env python3
"""Launching, finding and stopping the game under test.

Two rules here are scar tissue, not style:

1. **Never SIGKILL a game client.** The Proton/nvidia stack leaks GPU and host
   memory when a process dies without unwinding — a killed client costs RAM
   that only a reboot returns. Everything below sends SIGTERM and waits.
   SIGKILL exists only as a last resort after a long grace period, and is
   reported when it happens.

2. **Never match your own process.** `pgrep -f "<pattern>"` matches the shell
   that is running it, so `kill $(pgrep -f ...)` kills the caller. This module
   scans /proc directly and excludes our own pid, our ancestors, and anything
   whose comm is a shell or an interpreter — a process-finder must not be able
   to return the process doing the finding.
"""
from __future__ import annotations

import os
import signal
import subprocess
import time

SHELL_COMMS = {"bash", "sh", "dash", "zsh", "python3", "python", "pgrep",
               "sed", "grep", "awk", "tmux", "tmux: server"}


def _read(path):
    try:
        with open(path, "rb") as f:
            return f.read()
    except OSError:
        return b""


def _ancestors(pid=None):
    """Our own pid and every parent, so we can never target them."""
    out = set()
    pid = pid or os.getpid()
    for _ in range(64):
        out.add(pid)
        stat = _read(f"/proc/{pid}/stat").decode("utf-8", "replace")
        # comm can contain spaces and parens; the ppid is the field after the
        # last ')'.
        close = stat.rfind(")")
        if close < 0:
            break
        fields = stat[close + 2:].split()
        if len(fields) < 2:
            break
        try:
            pid = int(fields[1])
        except ValueError:
            break
        if pid <= 1:
            break
    return out


def find(pattern, exclude_self=True):
    """Pids whose cmdline contains `pattern`, excluding this process tree.

    The exclusion is what makes this safe to feed to `stop()`.
    """
    safe = _ancestors() if exclude_self else set()
    hits = []
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        pid = int(entry)
        if pid in safe:
            continue
        cmdline = _read(f"/proc/{pid}/cmdline").replace(b"\0", b" ").decode(
            "utf-8", "replace")
        if not cmdline or pattern not in cmdline:
            continue
        comm = _read(f"/proc/{pid}/comm").decode("utf-8", "replace").strip()
        if comm in SHELL_COMMS:
            continue
        hits.append(pid)
    return sorted(hits)


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except (ProcessLookupError, PermissionError) as ex:
        return isinstance(ex, PermissionError)
    except OSError:
        return False


def wait_for_process(pattern, timeout=90, interval=1.0):
    """Block until a process matching `pattern` exists. Returns its pid or None."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        hits = find(pattern)
        if hits:
            return hits[0]
        time.sleep(interval)
    return None


def stop(pattern, grace=30, poll=1.0, hard_after=None, log=print):
    """SIGTERM everything matching `pattern`, then wait for it to be gone.

    Returns a dict describing what happened. `hard_after` (seconds) opts into a
    final SIGKILL; leave it None for game clients — a stuck client is a bug to
    report, not to paper over with a kill that leaks a gigabyte.
    """
    pids = find(pattern)
    if not pids:
        return {"matched": 0, "terminated": [], "survivors": [], "sigkilled": []}

    log(f"[e2e] SIGTERM {len(pids)} process(es) matching '{pattern}': {pids}")
    for pid in pids:
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError:
            pass

    deadline = time.time() + grace
    while time.time() < deadline:
        remaining = [p for p in pids if alive(p)]
        if not remaining:
            return {"matched": len(pids), "terminated": pids,
                    "survivors": [], "sigkilled": []}
        time.sleep(poll)

    survivors = [p for p in pids if alive(p)]
    killed = []
    if survivors and hard_after is not None:
        log(f"[e2e] WARNING: {survivors} ignored SIGTERM for {grace}s; SIGKILL "
            f"(this leaks GPU memory on Proton/nvidia — investigate)")
        for pid in survivors:
            try:
                os.kill(pid, signal.SIGKILL)
                killed.append(pid)
            except OSError:
                pass
    elif survivors:
        log(f"[e2e] WARNING: {survivors} still alive after {grace}s of SIGTERM. "
            f"NOT sending SIGKILL (Proton/nvidia RAM leak). Close it by hand.")
    return {"matched": len(pids), "terminated": [p for p in pids if p not in survivors],
            "survivors": survivors, "sigkilled": killed}


# ── Steam ─────────────────────────────────────────────────────────────────────

def steam_running():
    return bool(find("ubuntu12_32/steam"))


def ensure_steam(timeout=90, log=print):
    """Start Steam if it is not up. A Steam game cannot launch without it."""
    if steam_running():
        return True
    log("[e2e] Steam is not running — starting it (silent)…")
    try:
        subprocess.Popen(["steam", "-silent"],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True)
    except FileNotFoundError:
        log("[e2e] `steam` is not on PATH")
        return False
    deadline = time.time() + timeout
    while time.time() < deadline:
        if steam_running():
            time.sleep(5)      # the client needs a moment before -applaunch works
            return True
        time.sleep(2)
    return False


def steam_launch(appid, log=print):
    """`steam -applaunch <appid>`.

    This is the launch path that satisfies Steamworks DRM and uses the user's
    own Proton version and launch options — which is what makes a test
    reproduce what the user actually runs. Launching the exe directly skips
    all of that and tests a configuration nobody plays.
    """
    log(f"[e2e] steam -applaunch {appid}")
    subprocess.Popen(["steam", "-applaunch", str(appid)],
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     start_new_session=True)
