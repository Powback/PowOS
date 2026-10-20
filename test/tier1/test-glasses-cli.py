#!/usr/bin/env python3
"""test-glasses-cli.py - `powos glasses` (lib/apps/powos-glasses) against a stand-in for the PowOS app.

The app side (glasses/Glasses.kt) watches <run>/glasses/cmd/ for whole JSON files and answers in status.json's "last";
here a thread plays the app: it takes each command, checks it, deletes it and writes the answer, as the app does. Also:
status reads the app's file, the CLI exits 2 without an app, and `powos help` / `powos glasses help` document it.

Usage:  python3 test/tier1/test-glasses-cli.py
"""
import json
import os
import subprocess
import sys
import tempfile
import threading
import time

ROOT = os.path.realpath(os.path.join(os.path.dirname(__file__), "..", ".."))
CLI = os.path.join(ROOT, "lib", "apps", "powos-glasses")
PASS = FAIL = 0


def ok(msg):
    global PASS
    PASS += 1
    print(f"  ok   - {msg}")


def bad(msg):
    global FAIL
    FAIL += 1
    print(f"  FAIL - {msg}")


def check(name, cond, detail=""):
    ok(name) if cond else bad(f"{name} {detail}")


STATE = {
    "available": True,
    "enabled": True,
    "paired": {"model": "G2", "pairId": "G2_84"},
    "wanted": True,
    "phase": "ready",
    "left": {"address": "AA:BB:CC:DD:EE:01", "name": "Even G2_84_L_8AF0B1", "phase": "ready"},
    "right": {"address": "AA:BB:CC:DD:EE:02", "name": "Even G2_84_R_8AF0B2", "phase": "authenticating"},
    "worn": None,
    "shown": True,
    "battery": {},
    "mic": False,
    "error": None,
    "canvas": {"width": 576, "height": 288, "bits": 4},
    "image": {"verified": False, "usable": False},
    "options": {"g2Raster": False},
}


def run(args, env, stdin=None):
    p = subprocess.run([sys.executable, CLI, *args], env=env, capture_output=True, text=True, input=stdin, timeout=20)
    return p.returncode, p.stdout, p.stderr


def fake_app(run_dir, seen, stop, answer_ok=lambda c: True):
    """The app's command loop: whole files in cmd/, deleted once read, the outcome in status.json's "last"."""
    cmd = os.path.join(run_dir, "cmd")
    while not stop.is_set():
        for name in sorted(os.listdir(cmd)):
            if name.startswith(".") or not name.endswith(".json"):
                continue
            path = os.path.join(cmd, name)
            with open(path) as f:
                c = json.load(f)
            os.remove(path)
            seen.append(c)
            st = dict(STATE, last={"id": name[:-5], "op": c.get("op"), "ok": answer_ok(c)})
            tmp = os.path.join(run_dir, ".status.json.tmp")
            with open(tmp, "w") as f:
                json.dump(st, f)
            os.rename(tmp, os.path.join(run_dir, "status.json"))
        time.sleep(0.02)


def main():
    print("== powos glasses (lib/apps/powos-glasses) ==")
    tmp = tempfile.mkdtemp()
    run_dir = os.path.join(tmp, "glasses")
    env = dict(os.environ, POWOS_GLASSES_DIR=run_dir, POWOS_GLASSES_WAIT="3")

    # No app: exit 2, saying why.
    code, _, err = run(["status"], env)
    check("without the app's status file: exit 2", code == 2, f"(got {code})")
    check("... and it says where it looked", "status.json" in err, f"({err.strip()})")

    os.makedirs(os.path.join(run_dir, "cmd"))
    with open(os.path.join(run_dir, "status.json"), "w") as f:
        json.dump(STATE, f)

    code, out, _ = run([], env)
    check("bare = status", code == 0 and "G2 G2_84: connected" in out, f"({out!r})")
    check("status lists both arms", "left" in out and "right" in out and "authenticating" in out)
    check("status says how the display is fed", "sent as text" in out)
    code, out, _ = run(["status", "--json"], env)
    check("status --json is the app's state", code == 0 and json.loads(out)["paired"]["model"] == "G2")

    seen, stop = [], threading.Event()
    t = threading.Thread(target=fake_app, args=(run_dir, seen, stop), daemon=True)
    t.start()
    try:
        code, _, err = run(["show", "hello", "glasses", "--seconds", "12"], env)
        check("show: done (exit 0)", code == 0, f"(got {code}: {err.strip()})")
        check("show: one command, op show, the text, the seconds", seen[-1:] == [{"op": "show", "text": "hello glasses", "seconds": 12}], f"({seen})")
        code, _, _ = run(["show"], env, stdin="from stdin\n")
        check("show reads stdin when given no text", code == 0 and seen[-1]["text"] == "from stdin", f"({seen[-1:]})")
        for verb in ("clear", "connect", "disconnect"):
            code, _, _ = run([verb], env)
            check(f"{verb}: done", code == 0 and seen[-1] == {"op": verb})
        code, _, _ = run(["mic", "on"], env)
        check("mic on", code == 0 and seen[-1] == {"op": "mic", "on": True})
        code, _, _ = run(["mic", "maybe"], env)
        check("mic needs on|off (exit 1)", code == 1)
        check("no stray files left in cmd/", os.listdir(os.path.join(run_dir, "cmd")) == [])
    finally:
        stop.set()
        t.join()

    # The app says no: exit 1.
    seen2, stop2 = [], threading.Event()
    t = threading.Thread(target=fake_app, args=(run_dir, seen2, stop2, lambda c: False), daemon=True)
    t.start()
    try:
        code, _, err = run(["clear"], env)
        check("the app refusing: exit 1, with the state", code == 1 and "not done" in err, f"({code} {err.strip()})")
    finally:
        stop2.set()
        t.join()

    # Nobody answering: exit 2 after the wait.
    env_fast = dict(env, POWOS_GLASSES_WAIT="0.3")
    code, _, err = run(["clear"], env_fast)
    check("no answer: exit 2", code == 2 and "didn't answer" in err, f"({code} {err.strip()})")

    # Documented: its own help, and powos help's lines; bin/powos dispatches it.
    code, out, _ = run(["help"], env)
    check("powos glasses help lists every verb", code == 0 and all(v in out for v in ("status", "show", "clear", "connect", "disconnect", "mic")))
    with open(os.path.join(ROOT, "bin", "powos")) as f:
        src = f.read()
    check("bin/powos dispatches `glasses` to lib/apps/powos-glasses", 'glasses)' in src and "apps/powos-glasses" in src)
    check("powos help documents glasses", "  glasses [status]" in src and "glasses show|clear|connect|disconnect|mic" in src)

    print(f"\n== Results: {PASS} passed, {FAIL} failed ==")
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
