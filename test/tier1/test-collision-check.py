#!/usr/bin/env python3
"""
Tests for bin/pow-collision-check — the podman prestart hook that refuses to
start a container whose Traefik Host(`…`) label already resolves to a
DIFFERENT host on the LAN.

The whole reason this file exists: the hook shipped a regression where a
multi-homed host (LAN + full-tunnel VPN) flagged EVERY routed container as a
collision, because self-identity came from a single routing probe that returns
the VPN address, never the LAN IP the `.pow` record points at. That bug was
invisible — nothing exercised the collision decision. These tests inject fake
IPs and a fake resolver so the decision runs with zero real DNS, zero
multi-homing, zero podman, and the regression can never come back silently.

Covers:
- hosts_from_labels(): pulls every Host(`…`) out of router .rule labels,
  handles `||` compound rules, ignores non-router labels, dedups + sorts
- self_ips(): enumerated interface IPs plus the OPTIONAL POW_HOST_IP
  supplement (comma-separated, malformed entries dropped)
- main() end-to-end via injected read_labels/self_ips/resolve + stdin:
    * no id / no labels / no Host label            -> exit 0 (nothing to do)
    * host resolves to one of OUR ips (LAN or VPN) -> exit 0  <-- the regression
    * host resolves to a FOREIGN ip                -> exit 1  (real collision)
    * POW_COLLISION_CHECK_BYPASS=1                 -> exit 0  (even if foreign)
    * host is NXDOMAIN (resolve -> "")             -> exit 0  (unknown != taken)
    * self_ips empty (can't tell who we are)       -> exit 0  (fail open)
"""

import importlib.util
import io
import unittest
from importlib.machinery import SourceFileLoader
from contextlib import redirect_stderr
from pathlib import Path
from unittest.mock import patch

# ── Load bin/pow-collision-check (hyphen in name prevents normal import) ──────
_REPO_ROOT = Path(__file__).parent.parent.parent
_HOOK_PATH = _REPO_ROOT / "bin" / "pow-collision-check"
if not _HOOK_PATH.exists():
    _HOOK_PATH = Path("/usr/bin/pow-collision-check")

# The hook has no .py suffix, so an explicit source loader is required —
# spec_from_file_location alone can't infer one from the extension.
_loader = SourceFileLoader("pow_collision_check", str(_HOOK_PATH))
_spec = importlib.util.spec_from_loader("pow_collision_check", _loader)
cc = importlib.util.module_from_spec(_spec)
_loader.exec_module(cc)


def _router(name, host):
    return {f"traefik.http.routers.{name}.rule": f"Host(`{host}`)"}


class TestHostsFromLabels(unittest.TestCase):
    def test_single_host(self):
        self.assertEqual(cc.hosts_from_labels(_router("app", "app.pow")), ["app.pow"])

    def test_no_traefik_labels(self):
        self.assertEqual(cc.hosts_from_labels({"com.example.foo": "bar"}), [])

    def test_enable_label_is_not_a_rule(self):
        # A stray Host() outside a *.rule label must not be picked up.
        self.assertEqual(cc.hosts_from_labels({"traefik.enable": "true"}), [])

    def test_compound_rule_yields_all_hosts(self):
        labels = {"traefik.http.routers.r.rule": "Host(`a.pow`) || Host(`b.pow`)"}
        self.assertEqual(cc.hosts_from_labels(labels), ["a.pow", "b.pow"])

    def test_multiple_routers_dedup_and_sorted(self):
        labels = {}
        labels.update(_router("z", "z.pow"))
        labels.update(_router("a", "a.pow"))
        labels.update(_router("dup", "a.pow"))  # same host, second router
        self.assertEqual(cc.hosts_from_labels(labels), ["a.pow", "z.pow"])

    def test_rule_without_host_matcher(self):
        # PathPrefix-only rules reference no hostname.
        labels = {"traefik.http.routers.r.rule": "PathPrefix(`/api`)"}
        self.assertEqual(cc.hosts_from_labels(labels), [])


class TestSelfIps(unittest.TestCase):
    def test_enumerated_interfaces(self):
        with patch.object(cc, "local_ipv4s", return_value={"192.168.50.58", "10.13.13.3"}):
            self.assertEqual(cc.self_ips({}), {"192.168.50.58", "10.13.13.3"})

    def test_pow_host_ip_supplements(self):
        with patch.object(cc, "local_ipv4s", return_value={"192.168.50.58"}):
            got = cc.self_ips({"POW_HOST_IP": "203.0.113.7"})
        self.assertEqual(got, {"192.168.50.58", "203.0.113.7"})

    def test_pow_host_ip_comma_list_and_malformed_dropped(self):
        with patch.object(cc, "local_ipv4s", return_value={"192.168.50.58"}):
            got = cc.self_ips({"POW_HOST_IP": "203.0.113.7, not-an-ip , 198.51.100.2"})
        self.assertEqual(got, {"192.168.50.58", "203.0.113.7", "198.51.100.2"})


class TestMain(unittest.TestCase):
    """Drive main() with injected identity + resolver + stdin; assert exit code."""

    def _run(self, *, state=None, labels=None, my_ips=None, dns=None, conf=None):
        state = {"id": "abc123def456"} if state is None else state
        labels = labels if labels is not None else {}
        my_ips = my_ips if my_ips is not None else {"192.168.50.58"}
        dns = dns or {}
        conf = conf or {}

        stdin = io.StringIO(cc.json.dumps(state))
        with patch.object(cc, "read_labels", return_value=labels), \
             patch.object(cc, "load_pow_conf", return_value=conf), \
             patch.object(cc, "self_ips", return_value=set(my_ips)), \
             patch.object(cc, "resolve", side_effect=lambda h, station: dns.get(h, "")), \
             patch.object(cc, "dbg"), \
             patch.object(cc.sys, "stdin", stdin), \
             redirect_stderr(io.StringIO()):
            return cc.main()

    def test_no_id_is_noop(self):
        self.assertEqual(self._run(state={}), 0)

    def test_no_labels_is_noop(self):
        self.assertEqual(self._run(labels={}), 0)

    def test_labels_without_host_is_noop(self):
        self.assertEqual(self._run(labels={"traefik.enable": "true"}), 0)

    def test_host_on_one_of_our_ips_is_not_a_collision(self):
        # THE REGRESSION: we are multi-homed (LAN + VPN); the record points at
        # our LAN IP. A single-probe self-IP would be the VPN addr and wrongly
        # flag this. Enumerated identity includes the LAN IP -> exit 0.
        rc = self._run(
            labels=_router("app", "app.pow"),
            my_ips={"192.168.50.58", "10.13.13.3"},
            dns={"app.pow": "192.168.50.58"},
        )
        self.assertEqual(rc, 0)

    def test_host_on_foreign_ip_is_a_collision(self):
        rc = self._run(
            labels=_router("app", "app.pow"),
            my_ips={"192.168.50.58"},
            dns={"app.pow": "192.168.50.99"},  # another host owns it
        )
        self.assertEqual(rc, 1)

    def test_bypass_flag_skips_even_a_real_collision(self):
        rc = self._run(
            labels=_router("app", "app.pow"),
            my_ips={"192.168.50.58"},
            dns={"app.pow": "192.168.50.99"},
            conf={"POW_COLLISION_CHECK_BYPASS": "1"},
        )
        self.assertEqual(rc, 0)

    def test_nxdomain_is_not_a_collision(self):
        # Unresolvable host: unknown, not "taken by someone else".
        rc = self._run(
            labels=_router("app", "app.pow"),
            my_ips={"192.168.50.58"},
            dns={},  # resolve() -> ""
        )
        self.assertEqual(rc, 0)

    def test_unknown_self_ips_fails_open(self):
        # If we can't determine our own addresses, refuse to guess a collision.
        rc = self._run(
            labels=_router("app", "app.pow"),
            my_ips=set(),
            dns={"app.pow": "192.168.50.99"},
        )
        self.assertEqual(rc, 0)

    def test_one_foreign_among_several_ours_still_collides(self):
        labels = {}
        labels.update(_router("a", "a.pow"))   # ours
        labels.update(_router("b", "b.pow"))   # foreign
        rc = self._run(
            labels=labels,
            my_ips={"192.168.50.58"},
            dns={"a.pow": "192.168.50.58", "b.pow": "192.168.50.99"},
        )
        self.assertEqual(rc, 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
