#!/usr/bin/env python3
"""test-appcap-link.py - a pairing handed over by the app that holds it (tools/app-api/appcap_link.py, docs/COMPOSER.md
section 6), headless against a fake Hue bridge (HTTPS, self-signed, CN = its id) on loopback.

What it holds to:
  - the key comes only in the x-powos-secret header (a body "_secret" is ignored) and is never returned, logged or
    written in the clear: it lands in the encrypted store as secret:hue;
  - nothing is kept unless the bridge's certificate is the pin the app sent (or, without a pin, names the bridge id the
    app paired with) and the key reads the bridge (GET /resource/bridge - a read);
  - a public address, a wrong key, a wrong pin and a wrong bridge id are refused, nothing stored;
  - once linked, the composed widget's reads (list_rooms, list_grouped_lights as consumer widget) reach the pinned
    bridge and come back parsed; a widget's write is still refused. The bridge sees GETs only.

Usage:  python3 test/tier1/test-appcap-link.py
"""
import hashlib
import http.server
import json
import os
import shutil
import ssl
import subprocess
import sys
import tempfile
import threading
import unittest
import urllib.request
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
APPAPI = os.path.join(ROOT, "tools", "app-api")
BRIDGE_ID = "001788fffe0abcde"
KEY = "test-key-Zq81"


class Bridge(http.server.BaseHTTPRequestHandler):
    hits = []

    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        Bridge.hits.append(("GET", self.path))
        if self.headers.get("hue-application-key") != KEY:
            return self._send(403, {"errors": [{"description": "unauthorized user"}]})
        data = {"/clip/v2/resource/bridge": [{"id": "b", "bridge_id": BRIDGE_ID}],
                "/clip/v2/resource/room": [{"id": "r1", "metadata": {"name": "Living room"}}],
                "/clip/v2/resource/grouped_light": [{"id": "g1", "owner": {"rid": "r1", "rtype": "room"}, "on": {"on": True},
                                                     "dimming": {"brightness": 60.0}}]}.get(self.path)
        self._send(200 if data is not None else 404, {"errors": [], "data": data or []})

    def do_PUT(self):
        Bridge.hits.append(("PUT", self.path))
        self._send(200, {})

    def log_message(self, *_a):
        pass


class Quiet(http.server.HTTPServer):
    def handle_error(self, *_a):  # a TLS peek (the pin check) closes without a request: not an error here
        pass


def load(path, name):
    loader = SourceFileLoader(name, path)
    m = module_from_spec(spec_from_loader(name, loader))
    loader.exec_module(m)
    return m


class Link(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="link-test-")
        key, crt = os.path.join(cls.tmp, "b.key"), os.path.join(cls.tmp, "b.crt")
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", crt,
                        "-days", "2", "-subj", f"/CN={BRIDGE_ID}"], check=True, capture_output=True)
        cls.srv = Quiet(("127.0.0.1", 0), Bridge)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(crt, key)
        cls.srv.socket = ctx.wrap_socket(cls.srv.socket, server_side=True)
        threading.Thread(target=cls.srv.serve_forever, daemon=True).start()
        with open(crt) as f:
            cls.pin = hashlib.sha256(ssl.PEM_cert_to_DER_cert(f.read())).hexdigest()
        cls.addr = f"127.0.0.1:{cls.srv.server_port}"

    @classmethod
    def tearDownClass(cls):
        cls.srv.shutdown()
        cls.srv.server_close()
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def setUp(self):
        Bridge.hits.clear()
        self.state = tempfile.mkdtemp(prefix="link-state-")
        os.environ["POWOS_APPAPI_STATE"] = self.state
        os.environ["POWOS_APPAPI_LINK_LOOPBACK"] = "1"
        sys.path.insert(0, APPAPI)
        try:
            for m in ("appcap_store", "appcap_validate", "appcap_run", "appcap_link", "appcap_files", "appcap_flows", "appcap_render"):
                sys.modules.pop(m, None)
            self.serve = load(os.path.join(APPAPI, "appcap_serve.py"), "appcap_serve_link_t")
        finally:
            sys.path.remove(APPAPI)
        self.serve.seed()
        self.httpd = http.server.HTTPServer(("127.0.0.1", 0), self.serve.Handler)
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.api = f"http://127.0.0.1:{self.httpd.server_port}"

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        shutil.rmtree(self.state, ignore_errors=True)

    def post(self, body, secret=KEY):
        h = {"content-type": "application/json", **({"x-powos-secret": secret} if secret is not None else {})}
        req = urllib.request.Request(f"{self.api}/link", data=json.dumps(body).encode(), headers=h, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                return r.status, json.loads(r.read())
        except urllib.error.HTTPError as e:
            with e:
                return e.code, json.loads(e.read())

    def status(self):
        with urllib.request.urlopen(f"{self.api}/link?app=hue", timeout=10) as r:
            return json.loads(r.read())

    def body(self, **over):
        b = {"app": "hue", "from": "local.lights", "state": {"bridge_ip": self.addr, "bridge_id": BRIDGE_ID}, "pin": self.pin}
        b.update(over)
        return b

    def no_key_anywhere(self):
        for root, _, files in os.walk(self.state):
            for f in files:
                with open(os.path.join(root, f), "rb") as fh:
                    self.assertNotIn(KEY.encode(), fh.read(), f)

    def test_link_then_widget_reads(self):
        code, r = self.post(self.body())
        self.assertEqual(code, 200, r)
        self.assertTrue(r["linked"], r)
        self.assertNotIn(KEY, json.dumps(r))
        st = self.status()
        self.assertEqual((st["linked"], st["bridge_ip"], st["pinned"], st["by"]), (True, self.addr, True, "local.lights"))
        self.no_key_anywhere()
        spec = os.path.join(self.state, "specs", "hue.appcap.json")
        for action in ("list_rooms", "list_grouped_lights"):
            p = subprocess.run([sys.executable, os.path.join(APPAPI, "appcap_run.py"), spec, action, "--consumer", "widget",
                                "--send", "--json"], capture_output=True, text=True, env=os.environ, timeout=60)
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertIn("data", json.loads(p.stdout)["response"])
            self.assertNotIn(KEY, p.stdout + p.stderr)
        p = subprocess.run([sys.executable, os.path.join(APPAPI, "appcap_run.py"), spec, "set_room", "--consumer", "widget",
                            "--arg", "group_id=g1", "--arg", "on=false", "--send"], capture_output=True, text=True,
                           env=os.environ, timeout=60)
        self.assertEqual(p.returncode, 3)
        self.assertEqual({m for m, _ in Bridge.hits}, {"GET"})
        self.no_key_anywhere()

    def test_refusals_store_nothing(self):
        cases = [
            (self.body(), "nope"),                                                    # the key doesn't read the bridge
            (self.body(pin="0" * 64), KEY),                                           # not the pinned certificate
            (self.body(pin=None, state={"bridge_ip": self.addr, "bridge_id": "001788fffe999999"}), KEY),  # other bridge
        ]
        for body, secret in cases:
            code, r = self.post({k: v for k, v in body.items() if v is not None}, secret)
            self.assertEqual(code, 200, r)
            self.assertFalse(r["linked"], r)
            self.assertFalse(self.status()["linked"])
        code, r = self.post(self.body(state={"bridge_ip": "8.8.8.8"}))
        self.assertEqual(code, 400)
        code, r = self.post({**self.body(), "_secret": KEY}, secret=None)  # a key in the body is ignored
        self.assertEqual(code, 400)
        self.assertIn("x-powos-secret", r["error"])
        self.assertFalse(self.status()["linked"])
        self.assertEqual({m for m, _ in Bridge.hits}, {"GET"})
        self.no_key_anywhere()

    def test_no_pin_export_binds_to_bridge_id(self):
        b = self.body()
        del b["pin"]
        code, r = self.post(b)
        self.assertEqual(code, 200, r)
        self.assertTrue(r["linked"], r)
        with open(os.path.join(self.state, "state", "hue.json")) as f:
            self.assertEqual(json.load(f)["tls_pin_sha256"], self.pin)


if __name__ == "__main__":
    unittest.main(verbosity=1)
