#!/usr/bin/env python3
"""appcap_link.py - a device the user already paired in its own PowOS app, linked into App API by that app.

The pairing isn't done twice (docs/COMPOSER.md section 6): the app that holds it hands it over through its own
interface - the Lights app, once paired, POSTs /link with the bridge's address, its id and the certificate pin its
host.net pinned, and the key as `${secret:hue}` in the x-powos-secret header: the PowOS app puts the value in on the
way out (ShellNet.kt), so neither the app's code nor this service's callers ever see it. Nothing reads the app's
tables or its private storage; App API only receives what the app chose to send.

  GET  /link?app=hue      {linked, bridge_ip, pinned, by, at} - never the key
  POST /link {app, from, state: {bridge_ip, bridge_id}, pin?}   + header x-powos-secret: the key
       Checked before anything is kept: the spec exists and takes a token; bridge_ip is a private address; the
       device's certificate is the pin the app sent (or, from a host.net without pin export, its subject is the
       bridge id the app paired with - then that certificate is pinned); the key works for a READ
       (GET /resource/bridge, nothing changes). Then the key goes into the encrypted store under the spec's handle
       (secret:hue), the address and pin into <state>/state/<app>.json, one audit line (no key).
"""
from __future__ import annotations

import hashlib
import http.client
import ipaddress
import json
import os
import re
import ssl
import socket
import tempfile
import time
import urllib.request

import appcap_run
import appcap_store

STATE = appcap_store.STATE
SPECS = os.path.join(STATE, "specs")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
ID = re.compile(r"^[0-9a-f]{12,32}$")
# The read that proves a key: the bridge's own resource (CLIP v2), nothing changes.
PROBE = "/clip/v2/resource/bridge"


def _spec(app: str) -> dict:
    p = os.path.join(SPECS, f"{os.path.basename(app)}.appcap.json")
    with open(p, encoding="utf-8") as f:
        return json.load(f)


def _state_path(app: str) -> str:
    return os.path.join(STATE, "state", f"{os.path.basename(app)}.json")


def _handle(spec: dict) -> tuple[str, dict]:
    toks = (spec.get("auth") or {}).get("tokens") or {}
    if len(toks) != 1:
        raise ValueError(f"{spec.get('app')}: link needs a spec with exactly one token")
    t = next(iter(toks.values()))
    return t["store"], t


def peer_cert(host: str, port: int = 443) -> bytes:
    """The device's certificate (DER), no CA asked: what a pin is taken of / compared with."""
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE  # a LAN device has no CA; the pin / its id is the check
    with socket.create_connection((host, port), timeout=8) as s, ctx.wrap_socket(s, server_hostname=host) as t:
        return t.getpeercert(binary_form=True)


def subject_cn(der: bytes) -> str:
    """The certificate's subject CN (a Hue bridge's is its id), read with the stdlib's own decoder."""
    with tempfile.NamedTemporaryFile("w", suffix=".pem", delete=False) as f:
        f.write(ssl.DER_cert_to_PEM_cert(der))
    try:
        d = ssl._ssl._test_decode_cert(f.name)  # noqa: SLF001 - the stdlib's decoder; no third-party x509 here
    finally:
        os.unlink(f.name)
    for rdn in d.get("subject", ()):
        for k, v in rdn:
            if k == "commonName":
                return v
    return ""


def status(q, _b):
    app = q.get("app", "")
    _spec(app)
    try:
        with open(_state_path(app), encoding="utf-8") as f:
            st = json.load(f)
    except (OSError, ValueError):
        st = {}
    handle, _ = _handle(_spec(app))
    return {"app": app, "linked": bool(st.get("bridge_ip")) and appcap_store.has(handle), "bridge_ip": st.get("bridge_ip", ""),
            "pinned": bool(st.get("tls_pin_sha256")), "by": st.get("linked_by", ""), "at": st.get("linked_at", "")}


def _checked_pin(host: str, port: int, pin: str, bridge_id: str) -> str:
    der = peer_cert(host, port)
    seen = hashlib.sha256(der).hexdigest()
    if pin:
        if seen != pin:
            raise PermissionError("the bridge's certificate isn't the one the app pinned")
        return seen
    # A host.net without pin export: the certificate must name the bridge the app paired with.
    if not bridge_id or subject_cn(der).lower() != bridge_id:
        raise PermissionError("the bridge's certificate doesn't name the bridge the app paired with")
    return seen


def _probe(spec: dict, ip: str, pin: str, tok: dict, key: str) -> int:
    url = (spec.get("base") or {}).get("url", "").replace("{bridge_ip}", ip)
    url = url[: url.index("/clip/v2")] + PROBE if "/clip/v2" in url else url
    req = urllib.request.Request(url, headers={tok.get("header", "authorization"): key}, method="GET")
    st, _ = appcap_run.pinned_open(req, pin, 1 << 16)
    return st


def link(_q, b):
    key = b.pop("_secret", "") or ""
    app, st = str(b.get("app", "")), b.get("state") or {}
    spec = _spec(app)
    handle, tok = _handle(spec)
    ip = str(st.get("bridge_ip", ""))
    host, _, port = ip.partition(":")
    try:
        addr = ipaddress.ip_address(host)
        port = int(port or 443)
    except ValueError:
        raise ValueError("state.bridge_ip: an IPv4 address[:port]") from None
    # Test hook: the tests' fake bridge listens on loopback; a real device is never there.
    loop_ok = os.environ.get("POWOS_APPAPI_LINK_LOOPBACK") == "1" and addr.is_loopback
    if not (addr.is_private and (not addr.is_loopback or loop_ok)):
        raise ValueError("state.bridge_ip: a private (LAN) address")
    bridge_id = str(st.get("bridge_id", "")).lower()
    if bridge_id and not ID.match(bridge_id):
        raise ValueError("state.bridge_id: hex")
    pin = str(b.get("pin") or "").lower().replace(":", "")
    if pin and not HEX64.match(pin):
        raise ValueError("pin: sha-256 hex")
    if not key or len(key) > 256 or not key.isprintable():
        raise ValueError("no key (header x-powos-secret, as ${secret:<name>})")
    try:
        pin = _checked_pin(host, port, pin, bridge_id)
        code = _probe(spec, ip, pin, tok, key)
    except (OSError, PermissionError, http.client.HTTPException) as e:
        appcap_run._audit(app, {"consumer": "link", "action": "link", "from": b.get("from", ""), "sent": False,
                                "refused": str(e)[:200]})
        return {"linked": False, "refused": str(e)[:200]}
    if code != 200:
        appcap_run._audit(app, {"consumer": "link", "action": "link", "from": b.get("from", ""), "sent": False,
                                "refused": f"the key didn't read the bridge (HTTP {code})"})
        return {"linked": False, "refused": f"the key didn't read the bridge (HTTP {code})"}
    appcap_store.set_secret(handle, key.encode(), {"linked_by": str(b.get("from", ""))[:64]})
    os.makedirs(os.path.dirname(_state_path(app)), mode=0o700, exist_ok=True)
    rec = {"bridge_ip": ip, "tls_pin_sha256": pin, "bridge_id": bridge_id, "linked_by": str(b.get("from", ""))[:64],
           "linked_at": time.strftime("%Y-%m-%dT%H:%M:%S")}
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(_state_path(app)), suffix=".tmp")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(rec, f, indent=2)
    os.replace(tmp, _state_path(app))
    appcap_run._audit(app, {"consumer": "link", "action": "link", "from": rec["linked_by"], "sent": True,
                            "status": code, "bridge_ip": ip})
    return {"linked": True, "bridge_ip": ip, "pinned": True, "by": rec["linked_by"]}


ROUTES = {("GET", "/link"): status, ("POST", "/link"): link}
