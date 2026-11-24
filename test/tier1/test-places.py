#!/usr/bin/env python3
"""Dolphin's Places panel: lib/devices/powos-places writes the PowOS places into user-places.xbel.

Pinned: the user's own bookmarks stay byte-for-byte (also one the user moved between ours); a second run changes
nothing (no write); a device that doesn't answer is written hidden and "(offline)", never as a live entry; a device or
storage that is gone loses its entry; a missing file stays missing (KDE writes its defaults only into a new file);
this device is left out of the fleet; the phone's folders are the launcher's Quick launch list (FilePlaces.kt).
"""
import importlib.machinery
import importlib.util
import json
import os
import re
import sys
import tempfile
from xml.dom import minidom

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC = os.path.join(REPO, "lib/devices/powos-places")
KT = os.path.join(REPO, "targets/android/app/app/src/main/kotlin/dev/omalauncher/shell/FilePlaces.kt")

work = tempfile.mkdtemp()
phone = os.path.join(work, "emulated0")
for d in ("Android", "Download", "DCIM/Camera", "Music"):
    os.makedirs(os.path.join(phone, d))
media = os.path.join(work, "storage")
os.makedirs(os.path.join(media, "1A2B-3C4D"))
os.makedirs(os.path.join(media, "self"))
owner = os.path.join(work, "owner.conf")
xbel = os.path.join(work, "user-places.xbel")
os.environ.update(POWOS_PHONE_STORAGE=phone, POWOS_STORAGE_DIRS=media, POWOS_OWNER_CONF=owner,
                  POWOS_PLACES_XBEL=xbel, POWOS_PLACES_CACHE=os.path.join(work, "cache"))
with open(owner, "w") as f:
    f.write("POWOS_STT_URL=http://stt.pow\nPOWOS_FILE_PLACES=" + json.dumps([
        {"name": "Mac", "url": "sftp://owner@hub.test/Users/owner", "kind": "desktop"},
        {"name": "GPU server", "url": "sftp://gpu.test/srv", "kind": "server"},
        {"name": "NAS CDN", "url": "nfs://nas.test/volume1/cdn", "kind": "nas"},
        {"name": "bad", "url": "/mnt/nas/cdn"}]) + "\n")

loader = importlib.machinery.SourceFileLoader("places", SRC)
spec = importlib.util.spec_from_loader("places", loader)
P = importlib.util.module_from_spec(spec)
loader.exec_module(P)

fails = 0


def check(cond, msg):
    global fails
    print(("  ok   - " if cond else "  FAIL - ") + msg)
    fails += 0 if cond else 1


class FakeDeviced:
    """The realm client: this phone enrolled, the registry with itself, a rooted phone, a desktop, a revoked one."""
    devices = [
        {"id": "me", "name": "This phone", "kind": "phone", "agent": "https://10.0.0.5:3416"},
        {"id": "razr-1", "name": "razr fold", "kind": "phone", "agent": "https://10.0.0.18:3416"},
        {"id": "desk-1", "name": "Desk", "kind": "desktop", "agent": "https://10.0.0.30:3416"},
        {"id": "old", "name": "Old", "kind": "phone", "agent": "https://10.0.0.40:3416", "revoked": "2026-11-01"},
    ]
    calls = 0

    load_json = staticmethod(lambda p, d: json.load(open(p)) if os.path.exists(p) else d)

    @staticmethod
    def save_json(p, data):
        os.makedirs(os.path.dirname(p), exist_ok=True)
        json.dump(data, open(p, "w"))

    @staticmethod
    def enrollment_path():
        p = os.path.join(work, "enrollment.json")
        if not os.path.exists(p):
            json.dump({"realm": "http://realm.test", "device_token": "t", "device": {"id": "me"}}, open(p, "w"))
        return p

    @classmethod
    def realm_call(cls, realm, path, body=None, token=None):
        cls.calls += 1
        return 200, {"devices": cls.devices}


up = {("hub.test", 22), ("nas.test", 2049), ("10.0.0.18", 2222), ("10.0.0.30", 22)}


def probe(pairs):
    return {hp: hp in up for hp in pairs}


USER = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE xbel>
<xbel xmlns:bookmark="http://www.freedesktop.org/standards/desktop-bookmarks" xmlns:kdepriv="http://www.kde.org/kdepriv" xmlns:mime="http://www.freedesktop.org/standards/shared-mime-info">
 <info>
  <metadata owner="http://www.kde.org">
   <kde_places_version>4</kde_places_version>
   <GroupState-Places-IsHidden>false</GroupState-Places-IsHidden>
  </metadata>
 </info>
 <bookmark href="file:///home/powos">
  <title>Home</title>
  <info>
   <metadata owner="http://freedesktop.org">
    <bookmark:icon name="user-home"/>
   </metadata>
   <metadata owner="http://www.kde.org">
    <ID>1700000000/0</ID>
    <isSystemItem>true</isSystemItem>
   </metadata>
  </info>
 </bookmark>
 <bookmark href="sftp://me@box.example/projects">
  <title>My box &amp; stuff</title>
  <info>
   <metadata owner="http://freedesktop.org">
    <bookmark:icon name="folder-network"/>
   </metadata>
   <metadata owner="http://www.kde.org">
    <ID>1700000000/7</ID>
    <IsHidden>false</IsHidden>
   </metadata>
  </info>
 </bookmark>
</xbel>
"""
user_marks = re.findall(r" <bookmark .*?</bookmark>", USER, re.S)


def by_title(text):
    doc = minidom.parseString(text)
    out = {}
    for b in doc.getElementsByTagName("bookmark"):
        t = b.getElementsByTagName("title")[0].firstChild.data
        hidden = [h.firstChild.data for h in b.getElementsByTagName("IsHidden")]
        icon = [i.getAttribute("name") for i in b.getElementsByTagName("bookmark:icon")]
        out[t] = {"href": b.getAttribute("href"), "hidden": hidden[0] if hidden else None, "icon": icon[0] if icon else None,
                  "ours": P.ours(b)}
    return out


print("== Dolphin places (powos-places) ==")

# The phone's folders are the launcher's.
kt = re.findall(r'Place\("(\w+)", "([^"]+)", "primary:([^"]+)"\)', open(KT).read())
check([(i, l, r) for i, l, r, _ in P.PHONE_FOLDERS] == kt,
      f"PHONE_FOLDERS = FilePlaces.kt's Quick launch folders ({len(kt)})")

# A missing file stays missing.
places = P.gather(FakeDeviced, refresh_registry=True, probe=probe)
check(not P.apply(places, xbel) and not os.path.exists(xbel), "no user-places.xbel yet: left for KDE to create")

with open(xbel, "w") as f:
    f.write(USER)
check(P.apply(places, xbel), "first apply writes")
text = open(xbel).read()
t = by_title(text)
check(all(m in text for m in user_marks), "the user's bookmarks are byte-for-byte as they were")
check(text.startswith('<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE xbel>\n'), "header and doctype kept")
check("<kde_places_version>4</kde_places_version>" in text, "KDE's own file metadata kept")
check(t["Phone"]["href"] == "file://" + phone and t["Phone"]["icon"] == "smartphone", "the phone's storage root")
check(t["Downloads"]["href"].endswith("/Download") and t["Camera"]["href"].endswith("/DCIM/Camera")
      and "Music" in t and "Documents" not in t and "Pictures" not in t, "only the Quick launch folders that exist")
check(t["Removable storage (1A2B-3C4D)"]["icon"] == "drive-removable-media" and not any("self" in k for k in t),
      "removable storage by its volume uuid")
check(t["Mac"]["href"] == "sftp://owner@hub.test/Users/owner" and t["Mac"]["hidden"] == "false"
      and t["Mac"]["icon"] == "computer", "owner host online: visible, its friendly name and icon")
check(t["NAS CDN"]["href"].startswith("nfs://") and t["NAS CDN"]["hidden"] == "false", "the NAS share over nfs://")
check("GPU server" not in t and t["GPU server (offline)"]["hidden"] == "true", "an offline host is hidden, marked offline")
check("bad" not in t and not any(k.startswith("bad") for k in t), "a non-KIO owner entry (a mount path) is refused")
check(t["razr fold"]["href"] == "sftp://powos@10.0.0.18:2222/mnt/sdcard" and t["razr fold"]["icon"] == "smartphone",
      "a rooted phone in the realm: sftp to its sshd, its storage")
check(t["Desk"]["href"] == "sftp://10.0.0.30:22/" and t["Desk"]["hidden"] == "false", "a desktop in the realm")
check("This phone" not in t and not any("Old" in k for k in t), "this device and revoked ones left out")
check(t["Home"]["ours"] is False and t["My box & stuff"]["ours"] is False and t["Phone"]["ours"], "only ours are tagged")

dup = USER.replace("file:///home/powos", "file://" + phone + "/Music")
check("Music" not in by_title(P.render(dup, places)), "a folder the user already has a place for isn't added twice")

# Idempotent.
check(not P.apply(P.gather(FakeDeviced, probe=probe), xbel) and open(xbel).read() == text,
      "a second run changes nothing (no write)")
calls = FakeDeviced.calls
P.gather(FakeDeviced, probe=probe)
check(FakeDeviced.calls == calls, "the registry comes from the cache between refreshes")

# The user moves their bookmark between ours; a device goes offline, the SD card goes.
doc = minidom.parseString(text)
root = doc.documentElement
marks = [n for n in root.childNodes if n.nodeType == n.ELEMENT_NODE and n.tagName == "bookmark"]
mine = [m for m in marks if P.ours(m)]
box = [m for m in marks if "box.example" in m.getAttribute("href")][0]
root.removeChild(box)
root.insertBefore(box, mine[3])
moved = text[:text.index("<xbel")] + root.toxml() + "\n"
with open(xbel, "w") as f:
    f.write(moved)
up.discard(("10.0.0.30", 22))
os.rmdir(os.path.join(media, "1A2B-3C4D"))
check(P.apply(P.gather(FakeDeviced, probe=probe), xbel), "a change is written")
text2 = open(xbel).read()
t2 = by_title(text2)
check(t2["Desk (offline)"]["hidden"] == "true" and "Desk" not in t2, "the desktop went offline: hidden, not a dead entry")
check(not any(k.startswith("Removable") for k in t2), "the removed SD card's entry is gone")
check(all(m in text2 for m in user_marks), "the user's bookmarks still byte-for-byte")
order = [b.getAttribute("href") for b in minidom.parseString(text2).getElementsByTagName("bookmark")]
check(order.index("sftp://me@box.example/projects") > order.index("file://" + phone), "the user's order is kept")
check(not P.apply(P.gather(FakeDeviced, probe=probe), xbel), "and again idempotent")

# Not enrolled, no phone storage (a computer): our entries all go, the user's stay.
os.environ["POWOS_PHONE_STORAGE"] = os.path.join(work, "none")
open(owner, "w").close()
check(P.apply(P.gather(None, probe=probe), xbel), "nothing of ours to show: removed")
text3 = open(xbel).read()
check(not any(v["ours"] for v in by_title(text3).values()) and all(m in text3 for m in user_marks),
      "only the user's bookmarks left, unchanged")

print(f"\n== Results: {'all passed' if not fails else f'{fails} failed'} ==")
sys.exit(1 if fails else 0)
