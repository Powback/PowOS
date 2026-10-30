#!/usr/bin/env python3
"""test-terms-cli.py - `powos terms` (lib/apps/powos-terms): every linked host's tmux sessions, opened view-first.

A stand-in `tmux` and `ssh` on PATH play this host's and the linked host's tmux: list parses both, marks agents,
serves a linked host from its cache and refreshes it in the background, keeps the last list when the link is down;
attach is a read-only client unless --write, over the link for another host; bad names are refused; `powos help`
names it.

Usage:  python3 test/tier1/test-terms-cli.py
"""
import json
import os
import subprocess
import sys
import tempfile
import time

ROOT = os.path.realpath(os.path.join(os.path.dirname(__file__), "..", ".."))
CLI = os.path.join(ROOT, "lib", "apps", "powos-terms")
PASS = FAIL = 0


def ok(msg):
    global PASS
    PASS += 1
    print(f"  ok   - {msg}")


def bad(msg):
    global FAIL
    FAIL += 1
    print(f"  FAIL - {msg}")


def check(msg, cond):
    ok(msg) if cond else bad(msg)


T = tempfile.mkdtemp()
BIN = os.path.join(T, "bin")
os.makedirs(BIN)
LOG = os.path.join(T, "calls")
LOCAL = "main\t1\t1700000000\t1\t✳ Fix the bar\t/home/powos/x\tclaude\nscratch\t2\t1700000100\t0\thost\t/home/powos\tbash\n"
REMOTE = "7\t1\t1700000200\t0\t⠂ Port it\t/Users/m/p\tclaude\n"


def stub(name, body):
    p = os.path.join(BIN, name)
    with open(p, "w") as f:
        f.write("#!/bin/sh\n" + body)
    os.chmod(p, 0o755)


# tmux: list-sessions prints LOCAL; attach is logged. ssh: logged; a remote list prints REMOTE unless SSH_DOWN.
stub("tmux", f'echo "tmux $*" >> {LOG}\ncase "$1" in list-sessions) printf "{LOCAL.encode("unicode_escape").decode()}";; esac\n')
stub("ssh", f'echo "ssh $*" >> {LOG}\n[ -n "$SSH_DOWN" ] && {{ echo "connect refused" >&2; exit 255; }}\n'
     f'case "$*" in *list-sessions*) printf "{REMOTE.encode("unicode_escape").decode()}";; esac\n')

ENV = dict(os.environ, PATH=BIN + ":" + os.environ["PATH"], POWOS_TERMS_HOST="phone",
           POWOS_TERMS_HOSTS="mac=me@10.0.0.9", POWOS_TERMS_CACHE=os.path.join(T, "cache"))


def run(*args, **env):
    return subprocess.run([sys.executable, CLI, *args], capture_output=True, text=True, env=dict(ENV, **env), timeout=30)


def calls():
    try:
        with open(LOG) as f:
            return f.read()
    except OSError:
        return ""


print("== list --wait ==")
r = run("list", "--json", "--wait")
d = json.loads(r.stdout)
hosts = {h["host"]: h for h in d["hosts"]}
check("this host and the linked one", list(hosts) == ["phone", "mac"])
ph = {s["name"]: s for s in hosts["phone"]["sessions"]}
check("local sessions parsed (name, windows, activity)", ph["scratch"]["windows"] == 2 and ph["main"]["activity"] == 1700000000)
check("claude marked agent, bash not", ph["main"]["agent"] and not ph["scratch"]["agent"])
mac = hosts["mac"]["sessions"]
check("mac sessions over ssh, tagged mac", len(mac) == 1 and mac[0]["host"] == "mac" and mac[0]["agent"])
check("ssh is BatchMode (never prompts)", "BatchMode=yes" in calls() and "me@10.0.0.9" in calls())

print("== list from cache, link down ==")
r = run("list", "--json", SSH_DOWN="1")
d = json.loads(r.stdout)
check("cached mac list served at once", len(d["hosts"][1]["sessions"]) == 1)
time.sleep(0.2)
r = run("list", "--json", "--wait", SSH_DOWN="1")
m = json.loads(r.stdout)["hosts"][1]
check("unreachable: error, last list kept", not m["ok"] and "unreachable" in m["error"] and len(m["sessions"]) == 1)

print("== attach ==")
open(LOG, "w").close()
run("attach", "phone", "main")
check("local view-only is a read-only client", "tmux attach -r -t main" in calls())
open(LOG, "w").close()
run("attach", "phone", "main", "--write")
check("--write is a read-write client", "tmux attach -t main" in calls() and "-r" not in calls())
open(LOG, "w").close()
run("attach", "mac", "7")
c = calls()
check("mac over ssh -t, read-only", c.startswith("ssh ") and " -t " in c and "tmux attach -r -t 7" in c)
r = run("attach", "mac", "x;rm -rf /")
check("bad session name refused", r.returncode == 2 and "bad session name" in r.stderr)
r = run("attach", "nowhere", "7")
check("unknown host refused", r.returncode == 2 and "no link" in r.stderr)

print("== help ==")
r = subprocess.run(["bash", os.path.join(ROOT, "bin", "powos"), "help"], capture_output=True, text=True, timeout=60)
check("powos help names terms", "terms [list|attach]" in r.stdout + r.stderr)
check("powos terms help", "view-only" in run("help").stdout)

print(f"\n{PASS} passed, {FAIL} failed")
sys.exit(1 if FAIL else 0)
