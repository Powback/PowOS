#!/usr/bin/env python3
"""test-openapi2appcap-safety.py - an OpenAPI draft never leaves a delete or a credential-taking action usable.

Petstore (no-root S25, 11-23): DELETE /pet/{petId} was "reversible-write" (a delete can't be undone) and
GET /user/login?username&password an ENABLED read - against "never enter credentials" (APP-API-CAPTURE.md §0.2).
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tools", "app-api"))
import openapi2appcap  # noqa: E402

DOC = {
    "openapi": "3.0.0", "servers": [{"url": "https://api.example.com/v1"}],
    "paths": {
        "/pet/{petId}": {"get": {"operationId": "getPet", "parameters": [{"name": "petId", "in": "path"}]},
                         "delete": {"operationId": "deletePet", "parameters": [{"name": "petId", "in": "path"}]}},
        "/pet": {"put": {"operationId": "updatePet"}},
        "/user/login": {"get": {"operationId": "loginUser", "parameters": [
            {"name": "username", "in": "query"}, {"name": "password", "in": "query"}]}},
        "/search": {"get": {"operationId": "search", "parameters": [{"name": "api_key", "in": "query"}]}},
        "/checkout": {"post": {"operationId": "checkout"}},
    },
}


class Safety(unittest.TestCase):
    def setUp(self):
        self.a = openapi2appcap.convert(DOC, "pets")["actions"]

    def test_plain_read_is_on(self):
        self.assertEqual((self.a["getPet"]["safety"], self.a["getPet"]["enabled"]), ("read", True))

    def test_delete_is_gated(self):
        d = self.a["deletePet"]
        self.assertEqual(d["safety"], "spend")
        self.assertFalse(d["enabled"])
        self.assertTrue(d["confirm"])

    def test_credential_read_is_never_on(self):
        for aid in ("loginUser", "search"):
            x = self.a[aid]
            self.assertEqual(x["safety"], "spend", aid)
            self.assertFalse(x["enabled"], aid)
            self.assertFalse(x["widget"], aid)
            self.assertIn("credential", x["confirm_template"], aid)

    def test_other_writes_unchanged(self):
        self.assertEqual((self.a["updatePet"]["safety"], self.a["updatePet"]["enabled"]), ("reversible-write", False))
        self.assertEqual(self.a["checkout"]["safety"], "spend")


if __name__ == "__main__":
    unittest.main()
