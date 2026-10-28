"""POST /compose/android: an app's own Android widget as a PowOS native-card widget (docs/COMPOSER.md, "android" block).

App API's "Make a widget" on an app that ships a home widget: this writes the composition (one android block, the
native-card template), runs the composer's own check / build / install (`powos compose`, so the rules live in one
place) and the widget lands in home's edit sheet, "PowOS apps". It reads the phone's widget through the island's bridge
at run time - nothing is read or sent here, and nothing is written to the app.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import tempfile

STATE = os.environ.get("POWOS_APPAPI_STATE") or os.path.expanduser("~/.local/state/powos/app-api")
PROVIDER = re.compile(r"^[A-Za-z0-9_.]+/[A-Za-z0-9_.$]+(#\d+)?$")
HERE = os.path.dirname(os.path.realpath(__file__))


def powos_compose() -> list[str]:
    """The composer: `powos compose` on the device, else this checkout's lib/apps/powos-compose."""
    exe = shutil.which("powos")
    if exe:
        return [exe, "compose"]
    return [os.path.join(HERE, "..", "..", "lib", "apps", "powos-compose")]


def run(*argv: str) -> str:
    r = subprocess.run([*powos_compose(), *argv], capture_output=True, text=True, timeout=300, stdin=subprocess.DEVNULL)
    if r.returncode:
        raise ValueError((r.stderr or r.stdout).strip()[-300:] or f"powos compose exited {r.returncode}")
    return r.stdout.strip()


def manifest(provider: str, label: str, open_app: str | None) -> dict:
    slug = re.sub(r"-+", "-", re.sub(r"[^a-z0-9]+", "-", label.lower())).strip("-")[:30] or "widget"
    m = {"spec": "powos.compose/v1", "kind": "widget", "id": f"local.{slug}-card", "name": label, "by": "app-api",
         "words": f"{label}, the app's own widget in PowOS's style",
         "uses": [{"as": "widget", "block": "android", "source": "widget", "provider": provider, "name": label}],
         "show": {"template": "native-card", "title": label, "from": "widget", "empty": "Nothing to show"},
         "widget": {"size": "4x2", "minSize": "2x1"}}
    if open_app:
        m["open"] = open_app
    return m


def compose_android(_q, b):
    provider, label = str(b.get("provider", "")), str(b.get("label", "")).strip()[:40]
    if not PROVIDER.match(provider) or not label:
        raise ValueError("provider (package/class) and label needed")
    m = manifest(provider, label, None)
    d = tempfile.mkdtemp(prefix="app-api-compose-")
    try:
        path = os.path.join(d, "composition.json")
        with open(path, "w", encoding="utf-8") as f:
            json.dump(m, f)
        run("check", path)
        folder = os.path.join(STATE, "composed", m["id"])
        run("build", path, "--dir", folder)
        run("install", folder, "--note", f"New widget: {label} (native card)")
    finally:
        shutil.rmtree(d, ignore_errors=True)
    return {"ok": True, "id": m["id"], "name": label}


ROUTES = {("POST", "/compose/android"): compose_android}
