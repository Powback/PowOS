#!/bin/bash
# lanes: phone
# lock-notif-expand.sh (board lock-screen-can-t-tap-to-expand-collapse-notific; the user, 11-24: a tap on a lock-face
# notification didn't expand it). Read-only over CDP on the lock page (LockFace keeps it warm after the first lock since
# the app started): the face runs the shade's cards (notifications.tsx Card/Stack, locked) - each card has the
# tap-to-expand state (aria-expanded), groups are the shade's .notif-stack, a card keeps the face's swipe
# (touch-action none unless the list scrolls), and no card carries an action/open button (opening needs the unlock).
# No taps, no wake, nothing on screen changes: the tap -> expand -> fold path itself is the gate's lock-expand-* scenes
# (a real CDP finger). SKIP: no lock page yet, or no notifications on it.
set -u
cd "$(dirname "$0")/../../.." || exit 1
if ! tools/phone/cdp.sh pages 2>/dev/null | grep -q '^lock '; then
  echo "SKIP: no lock page yet (LockFace makes it on the first lock since the app started) - gate lock-expand-* judge it"; exit 0
fi
js='JSON.stringify((()=>{const n=document.querySelector(".lock-notes"),c=[...document.querySelectorAll(".lock-notes .notif")];
return {list:!!n&&!!n.querySelector(":scope > .notif-items"),cards:c.length,
expandable:c.filter(e=>e.hasAttribute("aria-expanded")).length,
groups:document.querySelectorAll(".lock-notes .notif-stack").length,
buttons:document.querySelectorAll(".lock-notes .notif-buttons, .lock-notes [aria-label=open]").length,
touch:c.map(e=>getComputedStyle(e).touchAction).filter((t,i,a)=>a.indexOf(t)===i),
scrolls:!!n&&n.hasAttribute("data-scrolls"),old:document.querySelectorAll(".lock-note-main").length}})())'
raw=$(tools/phone/cdp.sh eval lock "$js" 2>&1 | tail -1)
echo "lock page: $raw"
python3 - "$raw" <<'PY'
import json, sys
s = sys.argv[1]
try:
    f = json.loads(s)
    if isinstance(f, str): f = json.loads(f)
except Exception:
    print("FAIL: no answer from the lock page: " + s[:200]); sys.exit(1)
if f["old"] or not f["list"]:
    print("FAIL: the lock page still runs the old flat cards (no shade cards) - not shipped yet?"); sys.exit(1)
if f["cards"] == 0:
    print("SKIP: no notifications on the lock face - cards not judged"); sys.exit(0)
bad = []
if f["expandable"] != f["cards"]: bad.append(f"{f['cards'] - f['expandable']} of {f['cards']} cards have no expand state")
if f["buttons"]: bad.append(f"{f['buttons']} action/open buttons on the locked face (opening must need the unlock)")
if not f["scrolls"] and f["touch"] != ["none"]: bad.append(f"cards' touch-action {f['touch']} (want none: the face's swipe)")
if bad: print("FAIL: " + "; ".join(bad)); sys.exit(1)
print(f"PASS: {f['cards']} shade cards on the lock face, all tap-to-expand, {f['groups']} group(s), no action buttons, touch {f['touch']}")
PY
