#!/usr/bin/env python3
"""test-minecraft.py - powos-minecraft (targets/android/pkgs/powos-minecraft): the server's .mrpack -> a Prism instance.

Hermetic: a temp HOME, a local HTTP server serving a made-up .mrpack and its one downloadable mod, no Prism needed.
Checks the contract the client/server parity depends on:
  - a first sync puts every client-side file in place (downloads sha1-checked, overrides + client-overrides, a
    server-only file skipped), writes Prism's instance.cfg / mmc-pack.json (Minecraft + loader from the index) and
    servers.dat with the pack's server
  - an unchanged pack re-syncs with no file touched (the ETag fast path)
  - a pack update replaces what the pack changed, removes what it dropped, keeps a config the user edited when the
    pack didn't change it, and leaves a mod the user added themselves alone
  - a download whose sha1 doesn't match is refused (the instance keeps its old files)
  - an unreachable server falls back to the cached pack

Usage:  python3 test/tier1/test-minecraft.py
"""
import hashlib
import http.server
import io
import json
import os
import subprocess
import sys
import tempfile
import threading
import zipfile

ROOT = os.path.realpath(os.path.join(os.path.dirname(__file__), "..", ".."))
TOOL = os.path.join(ROOT, "targets/android/pkgs/powos-minecraft/powos-minecraft")
PASS = FAIL = 0


def ok(cond, msg):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"  ok   - {msg}")
    else:
        FAIL += 1
        print(f"  FAIL - {msg}")


tmp = tempfile.mkdtemp(prefix="powos-mc-test-")
www = os.path.join(tmp, "www")
os.makedirs(www)
served = {}


class H(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k):
        super().__init__(*a, directory=www, **k)

    def log_message(self, *a):
        pass

    def end_headers(self):
        p = os.path.join(www, self.path.lstrip("/"))
        if os.path.isfile(p):
            self.send_header("ETag", '"' + hashlib.sha1(open(p, "rb").read()).hexdigest() + '"')
        super().end_headers()

    def do_GET(self):
        served[self.path] = served.get(self.path, 0) + 1
        p = os.path.join(www, self.path.lstrip("/"))
        etag = '"' + hashlib.sha1(open(p, "rb").read()).hexdigest() + '"' if os.path.isfile(p) else None
        if etag and self.headers.get("If-None-Match") == etag:
            self.send_response(304)
            self.end_headers()
            return
        super().do_GET()


srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{srv.server_port}"


def mod(name, body):
    open(os.path.join(www, name), "wb").write(body)
    return {"path": f"mods/{name}", "hashes": {"sha1": hashlib.sha1(body).hexdigest(),
                                                "sha512": hashlib.sha512(body).hexdigest()},
            "downloads": [f"{BASE}/{name}"], "fileSize": len(body)}


def mrpack(files, overrides, client_overrides=None, loader="21.1.248"):
    b = io.BytesIO()
    with zipfile.ZipFile(b, "w") as z:
        z.writestr("modrinth.index.json", json.dumps({
            "formatVersion": 1, "game": "minecraft", "versionId": "1", "name": "Test pack", "files": files,
            "dependencies": {"minecraft": "1.21.1", "neoforge": loader}}))
        for p, data in overrides.items():
            z.writestr("overrides/" + p, data)
        for p, data in (client_overrides or {}).items():
            z.writestr("client-overrides/" + p, data)
    open(os.path.join(www, "pack.mrpack"), "wb").write(b.getvalue())


home = os.path.join(tmp, "home")
os.makedirs(os.path.join(home, ".config/powos/minecraft"))
json.dump({"test": {"name": "Test pack", "mrpack": f"{BASE}/pack.mrpack", "server": "10.0.0.1:25565",
                    "serverName": "Test server", "default": True, "memory": 4096}},
          open(os.path.join(home, ".config/powos/minecraft/packs.json"), "w"))
env = {**os.environ, "HOME": home, "XDG_CACHE_HOME": os.path.join(home, ".cache"),
       "XDG_DATA_HOME": os.path.join(home, ".local/share")}
env.pop("DISPLAY", None)
env.pop("WAYLAND_DISPLAY", None)
inst = os.path.join(home, ".local/share/PrismLauncher/instances/test")
game = os.path.join(inst, "minecraft")


def run(*args):
    r = subprocess.run([sys.executable, TOOL, *args], env=env, capture_output=True, text=True, timeout=60)
    return r.returncode, r.stdout + r.stderr


def cfg():
    out = {}
    for line in open(os.path.join(inst, "instance.cfg")):
        if "=" in line:
            k, v = line.rstrip("\n").split("=", 1)
            out[k] = v
    return out


print("== first sync")
a = mod("a-1.0.jar", b"mod a 1.0")
b_ = mod("b-1.0.jar", b"mod b 1.0")
server_only = {**mod("srv-1.0.jar", b"server only"), "env": {"client": "unsupported", "server": "required"}}
mrpack([a, b_, server_only], {"config/x.toml": "x = 1\n", "config/y.toml": "y = 1\n", "mods/cf-1.0.jar": "cf mod"},
       {"options.txt": "fullscreen:true\n"})
rc, out = run("sync", "--quiet")
ok(rc == 0, f"sync exits 0 ({out.strip().splitlines()[-1] if out.strip() else ''})")
ok(all(os.path.exists(os.path.join(game, p)) for p in
       ("mods/a-1.0.jar", "mods/b-1.0.jar", "mods/cf-1.0.jar", "config/x.toml", "options.txt")),
   "downloaded mods, overrides and client-overrides are in the instance")
ok(not os.path.exists(os.path.join(game, "mods/srv-1.0.jar")), "a server-only file (env.client unsupported) is skipped")
mp = json.load(open(os.path.join(inst, "mmc-pack.json")))
ok([(c["uid"], c["version"]) for c in mp["components"]] == [("net.minecraft", "1.21.1"), ("net.neoforged", "21.1.248")],
   "mmc-pack.json = Minecraft + the pack's loader")
c = cfg()
ok(c.get("JoinServerOnLaunchAddress") == "10.0.0.1:25565" and c.get("JoinServerOnLaunch") == "true",
   "instance.cfg joins the pack's server")
ok(c.get("MaxMemAlloc") == "4096" and c.get("InstanceType") == "OneSix", "instance.cfg: the pack's heap, a Prism instance")
ok("sync test --quiet" in c.get("PreLaunchCommand", ""), "instance.cfg: the tool is Prism's pre-launch command")
sd = open(os.path.join(game, "servers.dat"), "rb").read()
ok(sd.startswith(b"\x0a\x00\x00\x09\x00\x07servers") and b"10.0.0.1:25565" in sd and b"Test server" in sd,
   "servers.dat (NBT) lists the pack's server")

print("== unchanged pack")
n = served.get("/a-1.0.jar", 0)
open(os.path.join(game, "config/x.toml"), "w").write("x = 1  # the user's edit\n")
rc, out = run("sync", "--quiet")
ok(rc == 0 and "0 file(s) changed" in out, "an unchanged pack changes nothing")
ok(served.get("/a-1.0.jar", 0) == n, "no mod downloaded again")

print("== pack update")
open(os.path.join(game, "mods/mine.jar"), "w").write("the user's own mod")
a2 = mod("a-2.0.jar", b"mod a 2.0")
mrpack([a2], {"config/x.toml": "x = 1\n", "config/y.toml": "y = 2\n", "mods/cf-1.0.jar": "cf mod"},
       {"options.txt": "fullscreen:true\n"}, loader="21.1.250")
rc, out = run("sync", "--quiet")
ok(rc == 0, "sync of the new pack exits 0")
ok(os.path.exists(os.path.join(game, "mods/a-2.0.jar")) and not os.path.exists(os.path.join(game, "mods/a-1.0.jar")),
   "an updated mod replaces the old one")
ok(not os.path.exists(os.path.join(game, "mods/b-1.0.jar")), "a mod the pack dropped is removed")
ok(open(os.path.join(game, "config/y.toml")).read() == "y = 2\n", "a config the pack changed is updated")
ok("the user's edit" in open(os.path.join(game, "config/x.toml")).read(), "a config only the user changed stays theirs")
ok(os.path.exists(os.path.join(game, "mods/mine.jar")), "a mod the user added is left alone")
mp = json.load(open(os.path.join(inst, "mmc-pack.json")))
ok(("net.neoforged", "21.1.250") in [(c["uid"], c["version"]) for c in mp["components"]], "the loader follows the pack")
rc, out = run("status")
ok(rc == 0 and "mine.jar" in out, "status names the mod that isn't the pack's")

print("== bad download")
bad = mod("c-1.0.jar", b"mod c")
bad["hashes"]["sha1"] = "0" * 40
bad["hashes"].pop("sha512")
mrpack([a2, bad], {"config/x.toml": "x = 1\n"})
rc, out = run("sync", "--quiet")
ok(rc != 0 and "hash mismatch" in out, "a download with the wrong sha1 is refused")
ok(not os.path.exists(os.path.join(game, "mods/c-1.0.jar")) and os.path.exists(os.path.join(game, "mods/a-2.0.jar")),
   "the instance keeps its files after a refused update")

print("== offline")
mrpack([a2], {"config/x.toml": "x = 1\n", "config/y.toml": "y = 2\n", "mods/cf-1.0.jar": "cf mod"},
       {"options.txt": "fullscreen:true\n"}, loader="21.1.250")
rc, _ = run("sync", "--quiet")
srv.shutdown()
srv.server_close()
rc, out = run("sync", "--quiet")
ok(rc == 0 and "cached pack" in out, "an unreachable server: the cached pack is used")

print(f"\n== Results: {PASS} passed, {FAIL} failed ==")
sys.exit(1 if FAIL else 0)
