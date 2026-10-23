#!/usr/bin/env python3
"""appcap_store.py - the encrypted-at-rest local token store for app-api.

Runs LOCALLY on PowOS (the phone's own Linux side and desktop PowOS); no Mac and
no cloud is ever in the loop. Tokens are the sessions the user's own app already
holds — we store them, we never create them. Values are encrypted at rest and
NEVER printed, logged, or returned to a human-facing command.

Crypto (offline, deps present on every PowOS: openssl + Python stdlib):
  - a 32-byte master key in a 0600 keyfile under the state dir (on the phone this
    file is itself wrapped by Android Keystore — see the doc; here it is 0600).
  - per-entry: encrypt-then-MAC. AES-256-CBC (openssl, PBKDF2 200k, random salt,
    key derived from the keyfile passphrase — the raw key never touches argv, the
    plaintext never touches disk: it is piped through stdin) + HMAC-SHA256 over
    the ciphertext with an independent subkey (HKDF from the master). Decrypt
    verifies the MAC first (constant-time) and refuses on mismatch.
  (Production note in the doc: libsodium/age or the `cryptography` AEAD + Keystore
  is the hardened path; this openssl construction is sound encrypt-then-MAC and
  keeps the prototype dependency-light and offline.)

Handles: an entry is addressed as `<app>:<id>` and referenced from an appcap
spec only as the handle `secret:<...>` / `store:<app>:<id>` — never the value.

CLI (never prints a secret value):
  appcap_store.py set   <app:id> [--meta k=v ...]     # reads value from stdin
  appcap_store.py has   <app:id>
  appcap_store.py list                                # handles + meta only
  appcap_store.py rm    <app:id>
  appcap_store.py migrate --from-json FILE            # import plaintext source,
                                                      #   encrypt, never print
Programmatic (what the runtime uses): get_secret(handle) -> bytes (in-process).
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import subprocess
import sys

STATE = os.environ.get("POWOS_APPAPI_STATE") or os.path.expanduser("~/.local/state/powos/app-api")
KEYFILE = os.path.join(STATE, "store.key")
DBFILE = os.path.join(STATE, "tokens.enc.json")
ITER = "200000"


def _ensure_dir():
    os.makedirs(STATE, mode=0o700, exist_ok=True)


def _master() -> bytes:
    _ensure_dir()
    if not os.path.exists(KEYFILE):
        fd = os.open(KEYFILE, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            os.write(fd, os.urandom(32))
        finally:
            os.close(fd)
    with open(KEYFILE, "rb") as f:
        return f.read()


def _mac_key(master: bytes) -> bytes:
    # HKDF-expand (one block) with an info label, pure stdlib.
    return hmac.new(master, b"appcap-store-mac\x01", hashlib.sha256).digest()


def _openssl(args: list[str], data: bytes) -> bytes:
    p = subprocess.run(["openssl", *args], input=data, stdout=subprocess.PIPE,
                       stderr=subprocess.PIPE)
    if p.returncode != 0:
        raise RuntimeError("openssl failed (crypto error)")  # never echo stderr (may contain data)
    return p.stdout


def _enc(master: bytes, plaintext: bytes) -> dict:
    ct = _openssl(["enc", "-aes-256-cbc", "-pbkdf2", "-iter", ITER, "-salt",
                   "-pass", f"file:{KEYFILE}"], plaintext)
    mac = hmac.new(_mac_key(master), ct, hashlib.sha256).digest()
    return {"ct": base64.b64encode(ct).decode(), "mac": base64.b64encode(mac).decode()}


def _dec(master: bytes, entry: dict) -> bytes:
    ct = base64.b64decode(entry["ct"])
    want = base64.b64decode(entry["mac"])
    got = hmac.new(_mac_key(master), ct, hashlib.sha256).digest()
    if not hmac.compare_digest(want, got):
        raise RuntimeError("MAC mismatch: store entry tampered or wrong key")
    return _openssl(["enc", "-d", "-aes-256-cbc", "-pbkdf2", "-iter", ITER,
                     "-pass", f"file:{KEYFILE}"], ct)


def _load_db() -> dict:
    if not os.path.exists(DBFILE):
        return {"v": 1, "entries": {}}
    with open(DBFILE, encoding="utf-8") as f:
        return json.load(f)


def _save_db(db: dict):
    _ensure_dir()
    tmp = DBFILE + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(db, f, indent=2)
    os.replace(tmp, DBFILE)


def _norm(handle: str) -> str:
    """Accept 'secret:x', 'store:app:id', or 'app:id' -> canonical 'app:id'."""
    if handle.startswith("secret:"):
        return handle[len("secret:"):]
    if handle.startswith("store:"):
        return handle[len("store:"):]
    return handle


# ---- public API (used by the runtime, in-process; never prints) ----
def set_secret(handle: str, value: bytes, meta: dict | None = None):
    master = _master()
    db = _load_db()
    db["entries"][_norm(handle)] = {**_enc(master, value), "meta": meta or {}}
    _save_db(db)


def get_secret(handle: str) -> bytes:
    master = _master()
    e = _load_db()["entries"].get(_norm(handle))
    if not e:
        raise KeyError(f"no such handle: {handle}")
    return _dec(master, e)


def has(handle: str) -> bool:
    return _norm(handle) in _load_db()["entries"]


def meta(handle: str) -> dict:
    e = _load_db()["entries"].get(_norm(handle))
    return (e or {}).get("meta", {})


def _main(argv: list[str]) -> int:
    if not argv:
        print("usage: appcap_store.py {set|has|list|rm|migrate} …", file=sys.stderr)
        return 2
    cmd, rest = argv[0], argv[1:]
    if cmd == "set":
        handle = rest[0]
        m = {}
        for a in rest[1:]:
            if a.startswith("--meta.") and "=" in a:
                k, v = a[len("--meta."):].split("=", 1)
                m[k] = v
        data = sys.stdin.buffer.read()  # value from stdin only, never argv
        if not data:
            print("refusing to store empty value (read from stdin)", file=sys.stderr)
            return 1
        set_secret(handle, data, m)
        print(f"stored {_norm(handle)} ({len(data)} bytes, encrypted; value not shown)", file=sys.stderr)
        return 0
    if cmd == "has":
        ok = has(rest[0])
        print("yes" if ok else "no")
        return 0 if ok else 1
    if cmd == "list":
        db = _load_db()
        for h, e in sorted(db["entries"].items()):
            print(f"{h}\t{json.dumps(e.get('meta', {}))}\t[value encrypted, not shown]")
        return 0
    if cmd == "rm":
        db = _load_db()
        if db["entries"].pop(_norm(rest[0]), None) is not None:
            _save_db(db)
            print(f"removed {_norm(rest[0])}", file=sys.stderr)
        return 0
    if cmd == "migrate":
        # --from-json FILE : {"app:id": {"value": "...", "meta": {...}}, ...}
        src = None
        for i, a in enumerate(rest):
            if a == "--from-json":
                src = rest[i + 1]
        if not src:
            print("migrate needs --from-json FILE", file=sys.stderr)
            return 2
        with open(src, encoding="utf-8") as f:
            data = json.load(f)
        n = 0
        for handle, rec in data.items():
            val = rec["value"]
            set_secret(handle, val.encode() if isinstance(val, str) else val, rec.get("meta"))
            n += 1
        print(f"migrated {n} token(s) into the encrypted store (values never printed)", file=sys.stderr)
        return 0
    print(f"unknown command: {cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(_main(sys.argv[1:]))
