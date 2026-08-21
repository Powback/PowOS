#!/usr/bin/env python3
"""Screenshots and window focus.

Screenshots are evidence, never assertions. A PNG in the report is how a human
confirms the harness was looking at the right thing; a test that "passes"
because pixels changed is a test that will pass on a crash dialog too. Every
pass/fail in this harness comes from the state channel or a log marker — images
are attached alongside.

Focus is a different matter and can be load-bearing. Games read input two ways:
through evdev (SDL, InControl, most engines under Proton) which does not care
about window focus, or through the display server (X11/Wayland keyboard and
pointer) which absolutely does. Virtual *gamepads* are evdev, so they land in an
unfocused window; virtual *keyboards and mice* generally do not. That is the
main reason this harness drives games with pads.
"""
from __future__ import annotations

import os
import shutil
import subprocess


def _has(binary):
    return shutil.which(binary) is not None


def session_kind():
    if os.environ.get("WAYLAND_DISPLAY"):
        return "wayland"
    if os.environ.get("DISPLAY"):
        return "x11"
    return "headless"


def find_window(title_substring):
    """(id, title) of the first window whose title contains the substring."""
    if _has("wmctrl"):
        try:
            out = subprocess.run(["wmctrl", "-l"], capture_output=True, text=True,
                                 timeout=10).stdout
            for line in out.splitlines():
                parts = line.split(None, 3)
                if len(parts) == 4 and title_substring.lower() in parts[3].lower():
                    return parts[0], parts[3]
        except Exception:
            pass
    if _has("xdotool"):
        try:
            out = subprocess.run(["xdotool", "search", "--name", title_substring],
                                 capture_output=True, text=True, timeout=10).stdout
            ids = [l for l in out.splitlines() if l.strip()]
            if ids:
                return ids[0], title_substring
        except Exception:
            pass
    return None, None


def focus(title_substring, log=print):
    """Best-effort raise+focus. Returns True if we believe it worked.

    On Wayland this is not guaranteed: a compositor may refuse activation
    requests from a process the user did not interact with. KWin honours
    wmctrl for XWayland clients, which covers Proton games (they are X11
    clients under XWayland), but a native Wayland game may simply ignore it.
    Pads work regardless — this exists for the cases that need a focused
    window, and it reports honestly when it cannot.
    """
    wid, title = find_window(title_substring)
    if not wid:
        log(f"[e2e] no window matching '{title_substring}' to focus")
        return False
    if _has("wmctrl"):
        try:
            subprocess.run(["wmctrl", "-i", "-a", wid], timeout=10)
            log(f"[e2e] focused window {wid} ({title})")
            return True
        except Exception:
            pass
    if _has("xdotool"):
        try:
            subprocess.run(["xdotool", "windowactivate", wid], timeout=10)
            return True
        except Exception:
            pass
    return False


def capture(path, window_title=None, log=print):
    """Grab a screenshot to `path`. Returns the path, or None.

    Tries, in order: a window-scoped X grab (sharpest, no desktop around it),
    a full-screen X grab, then the compositor's own tool.
    """
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)

    if window_title and _has("import") and os.environ.get("DISPLAY"):
        wid, _ = find_window(window_title)
        if wid:
            try:
                r = subprocess.run(["import", "-window", wid, path],
                                   capture_output=True, timeout=30)
                if r.returncode == 0 and os.path.exists(path):
                    return path
            except Exception:
                pass

    if _has("import") and os.environ.get("DISPLAY"):
        try:
            r = subprocess.run(["import", "-window", "root", path],
                               capture_output=True, timeout=30)
            if r.returncode == 0 and os.path.exists(path):
                return path
        except Exception:
            pass

    for tool, argv in (("grim", ["grim", path]),
                       ("spectacle", ["spectacle", "-b", "-n", "-o", path]),
                       ("scrot", ["scrot", "-o", path])):
        if _has(tool):
            try:
                subprocess.run(argv, capture_output=True, timeout=30)
                if os.path.exists(path):
                    return path
            except Exception:
                pass

    log(f"[e2e] could not capture a screenshot to {path} "
        f"(session={session_kind()}; install imagemagick or grim)")
    return None
