#!/usr/bin/env python3
"""test-appcap-add.py - App API's "+ add app" (tools/app-api/appcap_add.py): one normalize() for every source, drafts
kept apart from your apps, only ever previewed, and the "drafted" origin's promotion rule (S3).

What it holds to:
  - normalize: the whole app off, reads on, writes off and unpromoted, origin "drafted" (a claimed "official" too),
    spend confirmed with a template, widgets only on reads, auth only as store:<app>:session / secret:<app> - an
    inline token, a URL's user:password and a secret-named query/body value never survive;
  - appcap_validate: an enabled drafted write needs promoted:true; off or promoted it is valid;
  - the routes: an imported OpenAPI sample is a draft in drafts/, not in /apps; /call draft:true is a dry run past
    the allowlist and never sends; "Add to my apps" moves it into specs/ with the app off; switching a drafted write
    on promotes it; discard removes it; an old specs/<app>.draft.appcap.json is moved to drafts/;
  - appcap_run --draft: a dry run of a disabled app's write; --send with it is refused;
  - the installed-app sources: a PowOS app's page + its own database's public tables/reducers; an Android app's links.

Usage:  python3 test/tier1/test-appcap-add.py
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
import urllib.error
import urllib.request
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
APPAPI = os.path.join(ROOT, "tools", "app-api")
TOKEN = "sk-live-Zq81-never-in-a-draft"


def wjson(path, obj):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(obj, f)


def rjson(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def load(path, name):
    loader = SourceFileLoader(name, path)
    m = module_from_spec(spec_from_loader(name, loader))
    loader.exec_module(m)
    return m


def fresh(state):
    """The app-api modules loaded again against [state] (their STATE is read at import)."""
    os.environ["POWOS_APPAPI_STATE"] = state
    sys.path.insert(0, APPAPI)
    try:
        for m in ("appcap_store", "appcap_validate", "appcap_run", "appcap_link", "appcap_files", "appcap_flows",
                  "appcap_render", "appcap_add", "openapi2appcap"):
            sys.modules.pop(m, None)
        return load(os.path.join(APPAPI, "appcap_serve.py"), "appcap_serve_add_t")
    finally:
        sys.path.remove(APPAPI)


SPEC = {
    "app": "Shop App", "name": "Shop", "enabled": True,
    "base": {"kind": "internet", "url": "https://user:hunter2@api.shop.example/v1?api_key=" + TOKEN},
    "auth": {"tokens": {"session": {"store": TOKEN, "type": "bearer"}, "other": {"store": "secret:someone-else", "type": "weird"}}},
    "actions": {
        "list_items": {"summary": "Items.", "safety": "read", "origin": "official", "widget": True,
                       "endpoint": {"method": "GET", "path": "/items?token=" + TOKEN, "auth": "session"}},
        "add_to_cart": {"summary": "Add.", "safety": "reversible-write", "origin": "official", "enabled": True,
                        "promoted": True, "widget": True, "undo": "remove_from_cart",
                        "endpoint": {"method": "POST", "path": "/cart", "body": {"item": "{item}", "password": TOKEN}}},
        "checkout": {"summary": "Pay.", "safety": "spend", "origin": "official", "enabled": True,
                     "endpoint": {"method": "POST", "path": "/checkout"}},
    },
}


class Normalize(unittest.TestCase):
    def setUp(self):
        self.state = tempfile.mkdtemp(prefix="add-norm-")
        self.serve = fresh(self.state)
        self.add = sys.modules["appcap_add"]

    def tearDown(self):
        shutil.rmtree(self.state, ignore_errors=True)

    def test_safe_by_construction(self):
        d = self.add.normalize(json.loads(json.dumps(SPEC)), "describe")
        self.assertEqual(d["app"], "shop-app")
        self.assertIs(d["enabled"], False)
        a = d["actions"]
        self.assertTrue(a["list_items"]["enabled"])
        self.assertTrue(a["list_items"]["widget"])
        for w in ("add_to_cart", "checkout"):
            self.assertIs(a[w]["enabled"], False, w)
            self.assertIs(a[w]["promoted"], False, w)
            self.assertNotIn("widget", a[w])
        self.assertEqual({x["origin"] for x in a.values()}, {"drafted"})
        self.assertTrue(a["checkout"]["confirm"])
        self.assertTrue(a["checkout"]["confirm_template"])
        self.assertNotIn("undo", a["add_to_cart"])  # names no action of the draft

    def test_no_credential_survives(self):
        d = self.add.normalize(json.loads(json.dumps(SPEC)), "appcap")
        text = json.dumps(d)
        self.assertNotIn(TOKEN, text)
        self.assertNotIn("hunter2", text)
        toks = d["auth"]["tokens"]
        self.assertEqual(toks["session"]["store"], "store:shop-app:session")
        self.assertEqual(toks["other"]["store"], "store:shop-app:session")  # another app's handle isn't kept
        self.assertEqual(toks["other"]["type"], "bearer")
        self.assertEqual(d["actions"]["add_to_cart"]["endpoint"]["body"]["password"], "{password}")
        self.assertIn("token={token}", d["actions"]["list_items"]["endpoint"]["path"])

    def test_capture_keeps_captured(self):
        d = self.add.normalize(json.loads(json.dumps(SPEC)), "capture", "shop")
        self.assertEqual({x["origin"] for x in d["actions"].values()}, {"captured"})

    def test_app_level_origin_and_auth(self):
        """normalize() sets the app-level origin/auth.handle (schema/appcap.schema.json) the detail page reads
        instead of deriving them client-side: origin matches every action's; auth.handle is the one handle shared
        by every action that needs one, 'mixed' when they differ, absent when none do."""
        d = self.add.normalize(json.loads(json.dumps(SPEC)), "describe")
        self.assertEqual(d["origin"], "drafted")
        self.assertEqual({x["origin"] for x in d["actions"].values()}, {d["origin"]})
        self.assertEqual(d["auth"]["handle"], "store:shop-app:session")  # list_items is the only action using auth
        d2 = self.add.normalize({"actions": {
            "a": {"safety": "read", "endpoint": {"method": "GET", "path": "/a", "auth": "x"}},
            "b": {"safety": "read", "endpoint": {"method": "GET", "path": "/b", "auth": "y"}},
        }, "auth": {"tokens": {"x": {"store": "secret:two-app"}, "y": {"store": "store:two-app:session"}}}},
            "describe", "two-app")
        self.assertEqual(d2["auth"]["handle"], "mixed")
        d3 = self.add.normalize({"actions": {"a": {"safety": "read", "endpoint": {"method": "GET", "path": "/a"}}}},
                                 "describe", "no-auth-app")
        self.assertNotIn("handle", d3["auth"])  # nothing here needs auth

    def test_refused(self):
        with self.assertRaises(ValueError):
            self.add.normalize({"actions": {}}, "appcap", "x-app")
        with self.assertRaises(ValueError):
            self.add.normalize({"actions": {"a": {"safety": "yolo", "endpoint": {"method": "GET"}}}}, "appcap", "x-app")
        with self.assertRaises(ValueError):
            self.add.normalize({"actions": {"a": {"endpoint": {"method": "GET"}}}}, "appcap", "9")
        with self.assertRaises(ValueError):
            self.add.normalize(SPEC, "nowhere")
        with self.assertRaises(ValueError):
            self.add.fetch("https://me:pw@example.com/openapi.json")
        with self.assertRaises(ValueError):
            self.add.fetch("https://example.com/openapi.json?access_token=abc")
        with self.assertRaises(ValueError):
            self.add.fetch("file:///etc/passwd")

    def test_unsaid_safety_follows_the_method(self):
        d = self.add.normalize({"actions": {"g": {"endpoint": {"method": "GET", "path": "/"}},
                                            "p": {"endpoint": {"method": "POST", "path": "/"}}}}, "describe", "two")
        self.assertEqual(d["actions"]["g"]["safety"], "read")
        self.assertEqual(d["actions"]["p"]["safety"], "reversible-write")
        self.assertIs(d["actions"]["p"]["enabled"], False)


class DraftedOrigin(unittest.TestCase):
    def check(self, **act):
        state = tempfile.mkdtemp(prefix="add-s3-")
        try:
            fresh(state)
            v = sys.modules["appcap_validate"]
            p = os.path.join(state, "s.json")
            a = {"summary": "x", "safety": "reversible-write", "origin": "drafted", "endpoint": {"method": "POST", "path": "/"}}
            a.update(act)
            wjson(p, {"spec": "powos.appcap/v1", "app": "s3-app", "name": "s", "auth": {"tokens": {}}, "actions": {"w": a}})
            return [e for e in v.validate(p, False) if "WARN" not in e]
        finally:
            shutil.rmtree(state, ignore_errors=True)

    def test_enabled_unpromoted_write_refused(self):
        errs = self.check(enabled=True, promoted=False)
        self.assertTrue(any("[S3]" in e for e in errs), errs)

    def test_off_or_promoted_is_valid(self):
        self.assertEqual(self.check(enabled=False), [])
        self.assertEqual(self.check(enabled=True, promoted=True), [])
        self.assertEqual(self.check(safety="read", enabled=True), [])


class Routes(unittest.TestCase):
    def setUp(self):
        self.state = tempfile.mkdtemp(prefix="add-routes-")
        self.serve = fresh(self.state)
        self.add = sys.modules["appcap_add"]
        self.serve.seed()
        self.httpd = http.server.HTTPServer(("127.0.0.1", 0), self.serve.Handler)
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.api = f"http://127.0.0.1:{self.httpd.server_port}"

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        shutil.rmtree(self.state, ignore_errors=True)

    def req(self, path, body=None):
        data = json.dumps(body).encode() if body is not None else None
        r = urllib.request.Request(self.api + path, data=data, method="POST" if data else "GET",
                                   headers={"content-type": "application/json"})
        try:
            with urllib.request.urlopen(r, timeout=30) as resp:
                return resp.status, json.loads(resp.read())
        except urllib.error.HTTPError as e:
            with e:
                return e.code, json.loads(e.read())

    def apps(self):
        return {a["app"]: a for a in self.req("/apps")[1]["apps"]}

    def test_sample_import_review_discard(self):
        code, d = self.req("/draft/import", {"sample": "open-meteo"})
        self.assertEqual(code, 200, d)
        app = d["app"]
        self.assertTrue(os.path.exists(os.path.join(self.state, "drafts", f"{app}.appcap.json")))
        self.assertNotIn(app, self.apps())
        self.assertIn(app, [x["app"] for x in self.req("/drafts")[1]["drafts"]])
        code, one = self.req(f"/draft?app={app}")
        self.assertEqual(code, 200)
        self.assertIs(one["enabled"], False)
        aid = next(iter(one["actions"]))
        code, r = self.req("/call", {"app": app, "action": aid, "args": {}, "draft": True})
        self.assertEqual(code, 200, r)
        self.assertTrue(r["preview"]["dry_run"], r)
        self.assertTrue(r["preview"]["draft"])
        self.assertIn("GET https://api.open-meteo.com", r["preview"]["request"])
        self.assertIn("refused", self.req("/call", {"app": app, "action": aid, "draft": True, "send": True})[1])
        self.assertEqual(self.req("/call", {"app": app, "action": aid})[0], 404)  # not one of your apps
        self.assertEqual(self.req("/draft/discard", {"app": app}), (200, {"discarded": app}))
        self.assertEqual(self.req("/drafts")[1]["drafts"], [])
        self.assertEqual(self.req("/draft/discard", {"app": app})[0], 404)

    def test_import_write_failure_answers_instead_of_hanging(self):
        """A draft write that can't land (here: the destination is already a directory, not a file - e.g. left
        over from an older tool) is an OSError appcap_add.put() doesn't raise as ValueError/LookupError. Before
        the fix, handle_one didn't catch OSError: the connection just dropped with no response - which looks,
        from the UI, exactly like "the sample made no draft" (no JSON error to catch and show). It must come
        back as a clean error instead, and leave no half-written draft behind."""
        os.makedirs(os.path.join(self.state, "drafts", "open-meteo-demo-capture.appcap.json"))
        code, d = self.req("/draft/import", {"sample": "open-meteo"})
        self.assertEqual(code, 500, d)
        self.assertIn("error", d)
        self.assertEqual(self.req("/drafts")[1]["drafts"], [])

    def test_add_then_switch_on_promotes(self):
        code, d = self.req("/draft/import", {"doc": json.dumps(SPEC)})
        self.assertEqual(code, 200, d)
        self.assertEqual(self.req("/draft/add", {"app": "shop-app"}), (200, {"added": "shop-app"}))
        a = self.apps()["shop-app"]
        self.assertIs(a["enabled"], False)
        self.assertIs(a["actions"]["add_to_cart"]["enabled"], False)
        self.assertEqual(self.req("/drafts")[1]["drafts"], [])
        code, s = self.req("/enable", {"app": "shop-app", "action": "add_to_cart", "enabled": True})
        self.assertEqual(code, 200, s)
        spec = rjson(os.path.join(self.state, "specs", "shop-app.appcap.json"))
        self.assertIs(spec["actions"]["add_to_cart"]["promoted"], True)
        self.assertIs(spec["actions"]["checkout"]["promoted"], False)
        # A second draft of the same id can't overwrite the app.
        self.req("/draft/import", {"doc": json.dumps(SPEC)})
        code, r = self.req("/draft/add", {"app": "shop-app"})
        self.assertEqual(code, 400, r)

    def test_old_draft_in_specs_moves(self):
        os.makedirs(os.path.join(self.state, "specs"), exist_ok=True)
        p = os.path.join(self.state, "specs", "shop.draft.appcap.json")
        wjson(p, SPEC | {"app": "shop"})
        self.add.migrate()
        self.assertFalse(os.path.exists(p))
        self.assertEqual([x["app"] for x in self.add.drafts()], ["shop"])
        self.assertNotIn("shop", self.apps())

    def test_android_links(self):
        code, d = self.req("/draft/installed", {"kind": "android", "pkg": "com.example.shop", "label": "Example Shop",
                                                "links": [{"uri": "https://shop.example.com/item/.*", "activity": ".Item"},
                                                          {"uri": "exshop://cart"}, {"uri": "not a uri"}]})
        self.assertEqual(code, 200, d)
        acts = self.req(f"/draft?app={d['app']}")[1]["actions"]
        self.assertEqual(set(acts), {"open", "open_shop_example_com_item", "open_cart"})
        self.assertTrue(all(a["safety"] == "read" and a["enabled"] for a in acts.values()))
        self.assertEqual(acts["open"]["endpoint"], "open android-app://com.example.shop")
        self.assertEqual(self.req("/draft/installed", {"kind": "android", "pkg": "../x"})[0], 400)

    def test_android_widgets(self):
        gm = {"provider": "com.example.mail.widget.MailWidgetProvider", "label": "Inbox", "minWidth": 250, "minHeight": 110,
              "minResizeWidth": 150, "targetCellWidth": 4, "targetCellHeight": 2, "resize": ["horizontal", "vertical"],
              "categories": ["home_screen"], "updatePeriodMs": 86400000, "preview": "image", "configure": "com.example.mail.Setup"}
        code, d = self.req("/draft/installed", {"kind": "android", "pkg": "com.example.mail", "label": "Example Mail",
                                                "links": [], "widgets": [gm, {"provider": "bad name!"}, "x"]})
        self.assertEqual(code, 200, d)
        dr = self.req(f"/draft?app={d['app']}")[1]
        self.assertEqual(dr["widgets"], [gm])
        a = dr["actions"]["widget_inbox"]
        self.assertTrue(a["safety"] == "read" and a["widget"])
        self.assertIn("4x2 cells", a["summary"])
        self.assertIn("needs set-up", a["summary"])
        self.assertEqual(self.req("/draft/installed", {"kind": "android", "pkg": "com.example.none", "label": "None"})[1]["actions"], 1)

    def test_trackers_filter_by_app(self):
        code, d = self.req("/draft/import", {"sample": "open-meteo"})
        self.assertEqual(code, 200, d)
        app = d["app"]
        # Both /trackers (no filter) and /trackers?app=<id> should work.
        code, all_trackers = self.req("/trackers")
        self.assertEqual(code, 200)
        code, app_trackers = self.req(f"/trackers?app={app}")
        self.assertEqual(code, 200)
        # When filtered by app, result only contains that app (or is empty).
        self.assertTrue(all(a["app"] == app for a in app_trackers["apps"]))

    def test_powos_app(self):
        apps = tempfile.mkdtemp(prefix="add-apps-")
        try:
            os.makedirs(os.path.join(apps, "local.notes", "current"))
            wjson(os.path.join(apps, "local.notes", "current", "powos-app.json"),
                  {"id": "local.notes", "name": "Notes", "module": {"database": "local-notes"}})
            self.add.POWOS_APPS = apps
            self.add.STDB = "http://127.0.0.1:9"  # nothing listens: the page alone
            self.assertEqual(self.req("/installed")[1]["powos"], [{"id": "local.notes", "name": "Notes", "database": "local-notes"}])
            code, d = self.req("/draft/installed", {"id": "local.notes"})
            self.assertEqual(code, 200, d)
            acts = self.req(f"/draft?app={d['app']}")[1]["actions"]
            self.assertEqual(acts["open"]["endpoint"], "open app://local.notes")
        finally:
            shutil.rmtree(apps, ignore_errors=True)
        schema = {"tables": [{"name": "note", "table_access": {"Public": []}}, {"name": "secret", "table_access": {"Private": []}}],
                  "reducers": [{"name": "add_note", "params": {"elements": [{"name": {"some": "text"}, "algebraic_type": {"String": []}},
                                                                           {"name": {"some": "pin"}, "algebraic_type": {"Bool": []}}]},
                                "lifecycle": {"none": []}},
                               {"name": "init", "params": {"elements": []}, "lifecycle": {"some": {"Init": []}}}]}
        acts = self.add._stdb_actions("local-notes", schema)
        self.assertEqual(set(acts), {"list_note", "add_note"})
        self.assertEqual(acts["list_note"]["endpoint"]["body"], "SELECT * FROM note")
        self.assertTrue(acts["list_note"]["endpoint"]["path"].startswith("/v1/database/local-notes/"))
        self.assertEqual(acts["add_note"]["inputs"]["properties"], {"text": {"type": "string"}, "pin": {"type": "boolean"}})
        d = self.add.normalize({"actions": acts}, "powos", "local-notes")
        self.assertIs(d["actions"]["add_note"]["enabled"], False)


class RunDraft(unittest.TestCase):
    def test_dry_run_past_the_allowlist_never_sends(self):
        state = tempfile.mkdtemp(prefix="add-run-")
        try:
            fresh(state)
            add = sys.modules["appcap_add"]
            d = add.put(json.loads(json.dumps(SPEC)), "describe")
            path = add.draft_path(d["app"])
            run = [sys.executable, os.path.join(APPAPI, "appcap_run.py"), path, "add_to_cart", "--arg", "item=1", "--json"]
            env = dict(os.environ, POWOS_APPAPI_STATE=state)
            p = subprocess.run(run, capture_output=True, text=True, env=env)
            self.assertEqual(p.returncode, 3, "a disabled app's write isn't previewed without --draft")
            p = subprocess.run(run + ["--draft"], capture_output=True, text=True, env=env)
            self.assertEqual(p.returncode, 0, p.stderr)
            out = json.loads(p.stdout)["preview"]
            self.assertTrue(out["dry_run"] and out["draft"])
            self.assertNotIn(TOKEN, p.stdout + p.stderr)
            p = subprocess.run(run + ["--draft", "--send"], capture_output=True, text=True, env=env)
            self.assertEqual(p.returncode, 3)
            self.assertIn("only previewed", p.stderr)
        finally:
            shutil.rmtree(state, ignore_errors=True)


if __name__ == "__main__":
    unittest.main(verbosity=2)
