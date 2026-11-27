#!/usr/bin/env python3
"""test-ps5-cli.py - `powos ps5` (lib/apps/powos-ps5, docs/PS-REMOTE.md) without a PS5 or the network.

- find: a stand-in PS5 on 127.0.0.1:9302 answers a SRCH like the real one (chiaki lib/src/discovery.c: "200 Ok" awake,
  "620 Server Standby" in rest mode); `find --host 127.0.0.1 --json` reports its name, type and state.
- the reply parser on both states; garbage is ignored.
- the pin (lib/apps/upstream/chiaki-ng.json) has what the CLI and the docs name; `powos` dispatches ps5 and lists it in
  its help; the launcher's "PS5" entry runs `powos ps5 open` and the image installs it.

Usage:  python3 test/tier1/test-ps5-cli.py
"""
import importlib.machinery
import importlib.util
import json
import os
import socket
import subprocess
import sys
import threading

ROOT = os.path.realpath(os.path.join(os.path.dirname(__file__), "..", ".."))
CLI = os.path.join(ROOT, "lib", "apps", "powos-ps5")
FAIL = 0


def check(cond, msg):
    global FAIL
    print(f"  {'ok  ' if cond else 'FAIL'} - {msg}")
    FAIL += 0 if cond else 1


loader = importlib.machinery.SourceFileLoader("powos_ps5", CLI)
spec = importlib.util.spec_from_loader("powos_ps5", loader)
ps5 = importlib.util.module_from_spec(spec)
loader.exec_module(ps5)

awake = b"HTTP/1.1 200 Ok\nhost-id:ABCDEF012345\nhost-type:PS5\nhost-name:Living Room\nhost-request-port:997\ndevice-discovery-protocol-version:00030010\nsystem-version:09500000\n"
rest = b"HTTP/1.1 620 Server Standby\nhost-id:ABCDEF012345\nhost-type:PS5\nhost-name:Living Room\n"
r = ps5.parse_reply(awake, "192.168.50.20")
check(r and r["name"] == "Living Room" and r["type"] == "PS5" and r["state"] == "awake", "parse: awake PS5")
check(ps5.parse_reply(rest, "x")["state"] == "rest mode", "parse: 620 = rest mode")
check(ps5.parse_reply(b"hello", "x") is None, "parse: not a reply -> None")

# A stand-in PS5 on loopback port 9302 (skipped when the port is taken).
srv = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
try:
    srv.bind(("127.0.0.1", ps5.PS5_PORT))
except OSError:
    srv = None
    print("  skip - find: 127.0.0.1:9302 is taken")
if srv:
    got = []

    def answer():
        srv.settimeout(5)
        try:
            data, addr = srv.recvfrom(2048)
            got.append(data)
            srv.sendto(rest, addr)
        except OSError:
            pass

    t = threading.Thread(target=answer, daemon=True)
    t.start()
    out = subprocess.run([sys.executable, CLI, "find", "--host", "127.0.0.1", "--json"], capture_output=True, text=True, timeout=20)
    t.join(5)
    check(got and got[0].startswith(b"SRCH * HTTP/1.1\ndevice-discovery-protocol-version:00030010"), "find: sends the PS5 SRCH")
    hosts = json.loads(out.stdout or "[]")
    check(out.returncode == 0 and hosts and hosts[0]["state"] == "rest mode" and hosts[0]["address"] == "127.0.0.1",
          f"find --host: the stand-in in rest mode ({out.stdout.strip()[:120]})")
    srv.close()

pin = json.load(open(os.path.join(ROOT, "lib", "apps", "upstream", "chiaki-ng.json")))
check(pin["desktop"]["flatpak"] == "io.github.streetpea.Chiaki4deck" and pin["android"]["applicationId"] == "dev.powos.chiaki" and pin["verified"],
      "pin: flatpak id, Android package, verified version")
g = subprocess.run([sys.executable, CLI, "guide"], capture_output=True, text=True)
check(g.returncode == 0 and "Link Device" in g.stdout and "8-digit" in g.stdout, "guide: the PS5's Link Device PIN step")
bad = subprocess.run([sys.executable, CLI, "nope"], capture_output=True, text=True)
check(bad.returncode == 2, "unknown command exits 2")

powos = open(os.path.join(ROOT, "bin", "powos")).read()
check('"$POWOS_LIB/apps/powos-ps5"' in powos and "  ps5 [" in powos, "powos: dispatches ps5 and lists it in help")
desk = open(os.path.join(ROOT, "desktop", "apps", "powos-ps5.desktop")).read()
check("Name=PS5" in desk and "Exec=powos ps5 open" in desk, "desktop entry: PS5 -> powos ps5 open")
check("desktop/apps/powos-ps5.desktop" in open(os.path.join(ROOT, "Containerfile")).read(), "Containerfile installs the entry")

print("FAIL" if FAIL else "PASS")
sys.exit(1 if FAIL else 0)
