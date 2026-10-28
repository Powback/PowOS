#!/usr/bin/env python3
"""test-composer.py - `powos compose` (lib/apps/powos-compose, docs/COMPOSER.md), headless: words -> manifest ->
the rules -> an app folder, and the safety path the composed widget runs through (App API's runtime + service).

What it holds to:
  - a widget is made only of widget-safe READ blocks: a write (set_room), a spend, a read that isn't widget-safe, a
    switched-off action, a missing input and a dangling reference are all refused, with their rule;
  - "which Hue rooms are on" composes list_rooms + list_grouped_lights (joined on the room), opens Lights on a tap;
  - PowOS AI's manifest is used when it passes the rules, and the word match takes over when it doesn't;
  - the folder is an ordinary PowOS app: its own database, net = 127.0.0.1 only, one island, the composition in its
    manifest (what powos-registry keeps), the shared module copied, its prebuilt wasm only when the stamp matches;
  - the widget's code calls App API as consumer "widget" and nothing else;
  - the runtime refuses a widget's write, a send with an unfilled {bridge_ip} and a pinned host without a pin, and
    hands a read's JSON back parsed; the service passes consumer "widget" through, takes app/action from the query,
    and a newer package's actions reach the user's spec copy with its toggles kept.
Nothing here talks to a Hue bridge: the one real send goes to a local HTTP server this test runs.

Usage:  python3 test/tier1/test-composer.py
"""
import http.server
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
COMPOSE = os.path.join(ROOT, "lib", "apps", "powos-compose")
APPAPI = os.path.join(ROOT, "tools", "app-api")
EXAMPLES = os.path.join(APPAPI, "examples")


def load(path, name):
    loader = SourceFileLoader(name, path)
    m = module_from_spec(spec_from_loader(name, loader))
    loader.exec_module(m)
    return m


class Env:
    """A private App API state + specs dir for one test (no ~/.local/state is read or written)."""

    def __init__(self):
        self.root = tempfile.mkdtemp(prefix="compose-test-")
        self.state = os.path.join(self.root, "state")
        os.makedirs(self.state)
        self.env = {**os.environ, "POWOS_APPAPI_STATE": self.state, "POWOS_COMPOSE_AI": "off",
                    "POWOS_COMPOSE_SPECS": EXAMPLES}

    def run(self, *argv, env=None):
        return subprocess.run([sys.executable, COMPOSE, *argv], capture_output=True, text=True,
                              env={**self.env, **(env or {})}, timeout=120)

    def done(self):
        shutil.rmtree(self.root, ignore_errors=True)


class ComposerRules(unittest.TestCase):
    def setUp(self):
        self.e = Env()
        os.environ.update({k: v for k, v in self.e.env.items() if k.startswith("POWOS_")})
        self.c = load(COMPOSE, "powos_compose_t")

    def tearDown(self):
        self.e.done()

    def test_blocks_are_widget_safe_reads(self):
        r = self.e.run("blocks", "--json")
        self.assertEqual(r.returncode, 0, r.stderr)
        got = {(b["app"], b["action"]) for b in json.loads(r.stdout)["blocks"]}
        self.assertIn(("hue", "list_rooms"), got)
        self.assertIn(("hue", "list_grouped_lights"), got)
        self.assertNotIn(("hue", "set_room"), got)
        self.assertNotIn(("hue", "open_lights_page"), got)  # a read, but not widget-safe

    def test_hue_words_compose_rooms_with_their_state(self):
        m = self.c.match("show which Hue rooms are on", {})
        self.assertEqual([(u["app"], u["action"]) for u in m["uses"]], [("hue", "list_rooms"), ("hue", "list_grouped_lights")])
        self.assertEqual(m["show"]["rows"]["label"], "metadata.name")
        self.assertEqual(m["show"]["join"][0]["key"], "owner.rid")
        self.assertEqual(m["open"], "local.lights")
        self.assertEqual(m["id"], "local.hue-rooms")
        self.assertEqual(self.c.check(m), [])

    def test_unknown_words_refuse(self):
        r = self.e.run("widget", "quantum flux capacitor", "--no-install", "--dir", os.path.join(self.e.root, "x"))
        self.assertEqual(r.returncode, 1)
        self.assertIn("no building block matches", r.stderr)

    def manifest(self, **over):
        m = self.c.match("hue rooms", {})
        m.update(over)
        return m

    def rules(self, m):
        return " ".join(self.c.check(m))

    def test_a_widget_never_writes(self):
        m = self.manifest()
        m["uses"][0]["action"] = "set_room"
        m["uses"][0]["args"] = {"group_id": "x"}
        self.assertIn("[C4]", self.rules(m))
        m["uses"][0]["action"] = "recall_scene"
        m["uses"][0]["args"] = {"scene_id": "x"}
        self.assertIn("[C4]", self.rules(m))
        m["uses"][0]["action"] = "open_lights_page"  # read, not widget-safe
        self.assertIn("not widget-safe", self.rules(m))

    def test_android_widget_block(self):
        card = {"spec": "powos.compose/v1", "kind": "widget", "id": "local.steps", "name": "Steps",
                "uses": [{"as": "w", "block": "android", "source": "widget", "provider": "com.example.steps/.Counter#0", "appWidgetId": 12}],
                "show": {"template": "native-card", "title": "Steps", "from": "w"}}
        self.assertEqual(self.c.check(card), [])
        bad = json.loads(json.dumps(card))
        bad["uses"][0]["source"] = "screen"
        self.assertIn("[C3]", self.rules(bad))
        bad = json.loads(json.dumps(card))
        bad["uses"][0]["provider"] = "not a component"
        self.assertIn("provider", self.rules(bad))
        bad = json.loads(json.dumps(card))
        bad["show"]["template"] = "status-list"
        bad["show"]["rows"] = {"from": "w", "label": "x"}
        self.assertIn("[C2]", self.rules(bad))

    def test_spend_and_switched_off_refused(self):
        d = os.path.join(self.e.root, "specs")
        os.makedirs(d)
        shop = {"spec": "powos.appcap/v1", "app": "shop", "name": "Shop", "enabled": True,
                "base": {"kind": "internet", "url": "https://shop.example"}, "auth": {"tokens": {}},
                "actions": {
                    "order": {"summary": "Order the basket.", "safety": "spend", "origin": "official", "confirm": True,
                              "confirm_template": "Pay {total}?", "endpoint": {"method": "POST", "path": "/order"}},
                    "basket": {"summary": "Read the basket.", "safety": "read", "origin": "official", "widget": True,
                               "enabled": False, "endpoint": {"method": "GET", "path": "/basket"}}}}
        with open(os.path.join(d, "shop.appcap.json"), "w") as f:
            json.dump(shop, f)
        os.environ["POWOS_COMPOSE_SPECS"] = d
        m = {"spec": "powos.compose/v1", "kind": "widget", "id": "local.shop", "name": "Shop",
             "uses": [{"as": "o", "block": "appcap", "app": "shop", "action": "order"},
                      {"as": "b", "block": "appcap", "app": "shop", "action": "basket"}],
             "show": {"template": "status-list", "title": "Shop", "rows": {"from": "o", "label": "=x"}}}
        got = self.rules(m)
        self.assertIn("is spend", got)
        self.assertIn("switched off in App API [C3]", got)

    def test_inputs_refs_kind(self):
        m = self.c.match("weather temperature", {"lat": 59.9, "lon": 10.7})
        self.assertEqual(self.c.check(m), [])
        self.assertEqual(m["uses"][0]["args"], {"lat": 59.9, "lon": 10.7})
        del m["uses"][0]["args"]
        self.assertIn("needs lat, lon", self.rules(m))
        m = self.manifest()
        m["show"]["rows"]["from"] = "nope"
        self.assertIn("[C6]", self.rules(m))
        m = self.manifest()
        m["uses"][1]["as"] = m["uses"][0]["as"]
        self.assertIn("unique [C6]", self.rules(m))
        self.assertIn("[C1]", self.rules(self.manifest(kind="app")))
        self.assertIn("[C2]", self.rules(self.manifest(id="org.evil/../x")))
        self.assertIn("only appcap blocks", self.rules(self.manifest(uses=[{"as": "x", "block": "stdb", "db": "local-lights"}])))


class ComposerAI(unittest.TestCase):
    def setUp(self):
        self.e = Env()

    def tearDown(self):
        self.e.done()

    def fake_ai(self, manifest):
        p = os.path.join(self.e.root, "ai.sh")
        with open(p, "w") as f:
            f.write("#!/bin/sh\ncat <<'EOF'\nHere you go:\n" + json.dumps(manifest) + "\nEOF\n")
        os.chmod(p, 0o755)
        return p

    def compose(self, ai):
        d = os.path.join(self.e.root, "app")
        r = self.e.run("widget", "hue rooms", "--no-install", "--json", "--dir", d, env={"POWOS_COMPOSE_AI": ai})
        self.assertEqual(r.returncode, 0, r.stderr)
        return json.loads(r.stdout)["composition"], r.stderr

    def test_ai_manifest_used_when_it_passes(self):
        good = json.loads(self.e.run("widget", "hue rooms", "--no-install", "--json", "--no-ai",
                                     "--dir", os.path.join(self.e.root, "m")).stdout)["composition"]
        good.update({"name": "Rooms by AI", "id": "local.rooms-by-ai"})
        good.pop("open")
        m, _ = self.compose(self.fake_ai(good))
        self.assertEqual((m["by"], m["id"]), ("ai", "local.rooms-by-ai"))
        self.assertEqual(m["open"], "local.lights")  # the block's own app, filled in when the AI left it out

    def test_ai_write_refused_falls_back(self):
        bad = {"spec": "powos.compose/v1", "kind": "widget", "id": "local.lights-off", "name": "Off",
               "uses": [{"as": "r", "block": "appcap", "app": "hue", "action": "set_room", "args": {"group_id": "1", "on": False}}],
               "show": {"template": "status-list", "title": "Off", "rows": {"from": "r", "label": "=x"}}}
        m, log = self.compose(self.fake_ai(bad))
        self.assertEqual(m["by"], "matcher")
        self.assertIn("broke the rules", log)
        self.assertNotIn("set_room", json.dumps(m["uses"]))


class ComposerFolder(unittest.TestCase):
    def setUp(self):
        self.e = Env()

    def tearDown(self):
        self.e.done()

    def fake_composed(self, stamp_ok):
        """A composed-module dir like the device's (module source + a 'prebuilt' wasm + its stamp + bindings)."""
        d = os.path.join(self.e.root, "composed")
        shutil.copytree(os.path.join(ROOT, "apps", "composed", "module"), os.path.join(d, "module"),
                        ignore=shutil.ignore_patterns("target"))
        with open(os.path.join(d, "module.wasm"), "wb") as f:
            f.write(b"\0asm-fake")
        pa = load(os.path.join(ROOT, "lib", "apps", "powos-app"), "powos_app_t")
        sha = pa.tree_hash(os.path.join(d, "module"), skip={"target", "Cargo.lock"}) if stamp_ok else "0" * 64
        with open(os.path.join(d, ".module.sha"), "w") as f:
            f.write(sha + "\n")
        os.makedirs(os.path.join(d, "bindings"))
        with open(os.path.join(d, "bindings", "index.ts"), "w") as f:
            f.write("export const DbConnection = null;\n")
        return d

    def make(self, stamp_ok=True):
        d = os.path.join(self.e.root, "hue-rooms")
        r = self.e.run("widget", "which hue rooms are on", "--no-install", "--dir", d,
                       env={"POWOS_COMPOSED_DIR": self.fake_composed(stamp_ok)})
        self.assertEqual(r.returncode, 0, r.stderr)
        return d

    def test_an_ordinary_app_with_its_own_database(self):
        d = self.make()
        with open(os.path.join(d, "powos-app.json")) as f:
            m = json.load(f)
        self.assertEqual(m["id"], "local.hue-rooms")
        self.assertEqual(m["module"]["database"], "local-hue-rooms")
        self.assertEqual(m["net"], ["127.0.0.1"])
        self.assertEqual([(w["kind"], w["entry"]) for w in m["widgets"]], [("island", "widgets/main.js")])
        self.assertEqual(m["composition"]["uses"][0]["action"], "list_rooms")
        for rel in ("ui/composition.json", "ui/lib/compose.ts", "ui/lib/app.ts", "ui/widgets/main.tsx", "ui/icon.svg",
                    "module/src/lib.rs", "module/Cargo.toml", "out/module.wasm", "out/.module.sha", "ui/bindings/index.ts"):
            self.assertTrue(os.path.isfile(os.path.join(d, rel)), rel)
        with open(os.path.join(d, "ui", "lib", "app.ts")) as f:
            self.assertIn('DATABASE = "local-hue-rooms"', f.read())

    def test_stale_prebuilt_module_is_not_copied(self):
        d = self.make(stamp_ok=False)
        self.assertFalse(os.path.exists(os.path.join(d, "out", "module.wasm")))
        self.assertTrue(os.path.isfile(os.path.join(d, "module", "src", "lib.rs")))

    def test_rebuild_keeps_folder_refuses_a_stranger(self):
        d = self.make()
        r = self.e.run("build", d)
        self.assertEqual(r.returncode, 0, r.stderr)
        other = os.path.join(self.e.root, "someone")
        os.makedirs(other)
        open(os.path.join(other, "notes.txt"), "w").close()
        r = self.e.run("widget", "hue rooms", "--no-install", "--dir", other)
        self.assertEqual(r.returncode, 1)
        self.assertIn("isn't a composed app", r.stderr)

    def test_widget_code_calls_app_api_as_a_widget_only(self):
        d = self.make()
        with open(os.path.join(d, "ui", "lib", "compose.ts")) as f:
            src = f.read()
        self.assertIn('consumer: "widget"', src)
        self.assertEqual(src.count("host.net.fetch("), 1)
        self.assertIn('API = "http://127.0.0.1:3411"', src)
        with open(os.path.join(d, "ui", "widgets", "main.tsx")) as f:
            w = f.read()
        self.assertNotIn("fetch(", w)
        self.assertNotIn("useReducer", w)


class Hue(http.server.BaseHTTPRequestHandler):
    hits = []

    def do_GET(self):
        Hue.hits.append(("GET", self.path))
        body = json.dumps({"data": [{"id": "r1", "metadata": {"name": "Living room"}}]}).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.end_headers()
        self.wfile.write(body)

    def do_PUT(self):
        Hue.hits.append(("PUT", self.path))
        self.send_response(200)
        self.end_headers()

    def log_message(self, *_a):
        pass


class Runtime(unittest.TestCase):
    """App API's call path, as the composed widget reaches it."""

    @classmethod
    def setUpClass(cls):
        cls.srv = http.server.HTTPServer(("127.0.0.1", 0), Hue)
        threading.Thread(target=cls.srv.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.srv.shutdown()
        cls.srv.server_close()

    def setUp(self):
        self.e = Env()
        Hue.hits.clear()
        with open(os.path.join(EXAMPLES, "hue.appcap.json")) as f:
            self.hue = json.load(f)

    def tearDown(self):
        self.e.done()

    def spec(self, **base):
        s = json.loads(json.dumps(self.hue))
        s["base"].update(base)
        p = os.path.join(self.e.root, "hue.appcap.json")
        with open(p, "w") as f:
            json.dump(s, f)
        return p

    def run_(self, spec, action, *extra):
        return subprocess.run([sys.executable, os.path.join(APPAPI, "appcap_run.py"), spec, action, "--json", *extra],
                              capture_output=True, text=True, env=self.e.env, timeout=60)

    def link(self, **v):
        os.makedirs(os.path.join(self.e.state, "state"), exist_ok=True)
        with open(os.path.join(self.e.state, "state", "hue.json"), "w") as f:
            json.dump(v, f)

    def test_widget_write_refused_nothing_sent(self):
        p = self.spec(url=f"http://127.0.0.1:{self.srv.server_port}/clip/v2", tls="standard")
        r = self.run_(p, "set_room", "--consumer", "widget", "--arg", "group_id=g1", "--arg", "on=false", "--send")
        self.assertEqual(r.returncode, 3)
        self.assertIn("a widget may only call read actions", r.stderr)
        self.assertEqual(Hue.hits, [])

    def test_unfilled_placeholder_and_missing_pin_refuse(self):
        p = self.spec()
        r = self.run_(p, "list_rooms", "--consumer", "widget", "--send")
        self.assertEqual(r.returncode, 3)
        self.assertIn("needs bridge_ip", r.stderr)
        self.link(bridge_ip="127.0.0.1")
        r = self.run_(p, "list_rooms", "--consumer", "widget", "--send")
        self.assertEqual(r.returncode, 3)
        self.assertIn("no pinned certificate", r.stderr)
        r = self.run_(p, "list_rooms")  # a dry run shows the linked address
        self.assertIn("GET https://127.0.0.1/clip/v2/resource/room", r.stdout)

    def test_read_comes_back_parsed(self):
        p = self.spec(url="http://{bridge_ip}/clip/v2", tls="standard")
        self.link(bridge_ip=f"127.0.0.1:{self.srv.server_port}")
        subprocess.run([sys.executable, os.path.join(APPAPI, "appcap_store.py"), "set", "hue:key"], input=b"k",
                       env=self.e.env, check=True, capture_output=True)
        with open(p) as f:
            s = json.load(f)
        s["auth"]["tokens"]["bridge"]["store"] = "secret:hue:key"
        with open(p, "w") as f:
            json.dump(s, f)
        r = self.run_(p, "list_rooms", "--consumer", "widget", "--send")
        self.assertEqual(r.returncode, 0, r.stderr)
        out = json.loads(r.stdout)
        self.assertEqual(out["response"]["data"][0]["metadata"]["name"], "Living room")
        self.assertEqual(Hue.hits, [("GET", "/clip/v2/resource/room")])

    def test_service_widget_consumer_query_and_merge(self):
        os.environ["POWOS_APPAPI_STATE"] = self.e.state
        sys.path.insert(0, APPAPI)
        try:
            serve = load(os.path.join(APPAPI, "appcap_serve.py"), "appcap_serve_t")
        finally:
            sys.path.remove(APPAPI)
        serve.STATE, serve.SPECS = self.e.state, os.path.join(self.e.state, "specs")
        os.makedirs(serve.SPECS)
        old = json.loads(json.dumps(self.hue))
        del old["actions"]["list_grouped_lights"]
        old["actions"]["set_room"]["enabled"] = False
        old["actions"]["list_rooms"].pop("view")
        with open(os.path.join(serve.SPECS, "hue.appcap.json"), "w") as f:
            json.dump(old, f)
        serve.seed()
        with open(os.path.join(serve.SPECS, "hue.appcap.json")) as f:
            now = json.load(f)
        self.assertIn("list_grouped_lights", now["actions"])
        self.assertIn("view", now["actions"]["list_rooms"])
        self.assertIs(now["actions"]["set_room"]["enabled"], False)  # the user's toggle kept
        now["actions"]["set_room"]["enabled"] = True
        with open(os.path.join(serve.SPECS, "hue.appcap.json"), "w") as f:
            json.dump(now, f)
        r = serve.call({"app": "hue", "action": "set_room"}, {"args": {"group_id": "g"}, "consumer": "widget"})
        self.assertIn("a widget may only call read actions", r.get("refused", ""))
        r = serve.call({"app": "hue", "action": "list_rooms"}, {"send": True, "consumer": "widget"})
        self.assertIn("needs bridge_ip", r.get("refused", ""))
        with self.assertRaises(ValueError):
            serve.call({}, {"app": "hue", "action": "list_rooms", "consumer": "root"})
        self.assertEqual(Hue.hits, [])


class CreationProgress(unittest.TestCase):
    """The placeholder-widget telemetry (docs/AGENT-HANDBOOK.md, "live creation"): a provisional id, and best-effort
    registry calls that never block or break a composition when there's nothing to report to."""

    def setUp(self):
        self.c = load(COMPOSE, "powos_compose_creation_t")

    def test_creation_id_is_slugged_and_unique(self):
        a, b = self.c.creation_id_of("show which Hue rooms are on"), self.c.creation_id_of("show which Hue rooms are on")
        for cid in (a, b):
            self.assertRegex(cid, r"^widget:[a-z0-9-]+-[0-9a-f]{6}$")
        self.assertNotEqual(a, b)  # two compositions of the same words don't collide

    def test_registry_call_failure_never_raises(self):
        self.c.powos_app = lambda: (_ for _ in ()).throw(RuntimeError("no stdb here"))
        self.c._registry_ready = False
        self.c._creation("creation_begin", "widget:x-000000", "a widget", ["one"])  # must not raise


if __name__ == "__main__":
    unittest.main(verbosity=1)
