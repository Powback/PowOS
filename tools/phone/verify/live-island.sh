#!/bin/bash
# lanes: phone
# live-island.sh (board live-activities-around-the-camera-ring; shell ui/chrome.tsx LiveIsland, host
# system/LiveActivities.kt): the status bar's live pill round the camera. Read-only - nothing is started on the phone
# (a timer would ring later, media would play aloud): it compares what is live NOW in the shade (dumpsys notification:
# an ongoing chronometer / progress notification, a playing media session) with the status bar page's chrome state
# ("live") and the drawn pill (CDP, statusbar): something live -> a pill hugging the camera's hole (4 px round it,
# top/bottom), inside the screen, naming the app; nothing live -> no pill.
# Exit 0 PASS, 1 FAIL, 3 no free window, 5 SKIP (nothing live on the phone to show).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A=$T/adb.sh
OUT=${OUT:-$HOME/.cache/powos-verify/live-island-$(date +%m%d-%H%M%S)}; mkdir -p "$OUT"
sh_() { "$A" shell "$*" 2>/dev/null | tr -d '\r'; }
. "$here/window-lock.sh"
window_lock live-island.sh 60
# Ground truth: the shade's ongoing chronometer / progress notifications and the playing sessions (package names).
sh_ "dumpsys notification --noredact" > "$OUT/notification.txt"
sh_ "dumpsys media_session" > "$OUT/media_session.txt"
truth=$(python3 - "$OUT/notification.txt" "$OUT/media_session.txt" <<'PY'
import re, sys
text = open(sys.argv[1], errors="replace").read()
live = set()
for rec in re.split(r"\n\s*NotificationRecord\(", text)[1:]:
    pkg = re.search(r"pkg=(\S+)", rec)
    flags = re.search(r"flags=0x([0-9a-f]+)", rec)
    if not pkg or not flags: continue
    ongoing = int(flags.group(1), 16) & (0x2 | 0x40) and not int(flags.group(1), 16) & 0x200
    chrono = re.search(r"android\.showChronometer=(?:Boolean )?\(?true", rec)
    pmax = re.search(r"android\.progressMax=(?:Integer )?\(?(\d+)", rec)
    pind = re.search(r"android\.progressIndeterminate=(?:Boolean )?\(?true", rec)
    if ongoing and (chrono or (pmax and int(pmax.group(1)) > 0) or pind): live.add(pkg.group(1))
ms = open(sys.argv[2], errors="replace").read()
for m in re.finditer(r"package=(\S+)[\s\S]{0,1500}?state=PlaybackState \{state=(\d+)", ms):
    if m.group(2) == "3": live.add(m.group(1))
print(" ".join(sorted(live)))
PY
)
echo "live in the shade now: ${truth:-nothing}"
PILL_JS='importShim("./bridge.ts").then(b=>b.powos.chrome.state()).then(s=>new Promise(res=>setTimeout(()=>{const p=document.querySelector(".live-island");let r=null;if(p){for(const a of p.getAnimations())if(a.effect.getComputedTiming().endTime!==Infinity)a.finish();const b=p.getBoundingClientRect();r={x:b.x,y:b.y,w:b.width,h:b.height,label:p.getAttribute("aria-label")}}res(JSON.stringify({live:(s.live||[]).map(l=>({kind:l.kind,app:l.app,title:l.title})),camera:s.camera||null,iw:innerWidth,pill:r}))},400)))'
got=$("$T/cdp.sh" eval statusbar "$PILL_JS" 2>&1 | tail -1 | sed 's/^"//; s/"$//; s/\\"/"/g')
"$T/shot.sh" "$OUT/statusbar.png" >/dev/null 2>&1 || true
echo "status bar: $got"
verdict=$(GOT="$got" TRUTH="$truth" python3 - <<'PY'
import json, os
try: g = json.loads(os.environ["GOT"])
except Exception: print("FAIL the status bar page didn't answer: " + os.environ["GOT"][:200]); raise SystemExit
truth, live, cam, pill = os.environ["TRUTH"].split(), g["live"], g["camera"], g["pill"]
why = []
if truth and not live: why.append("live in the shade (%s) but the bar's state has none" % " ".join(truth))
if live and cam and not pill: why.append("state has %d live but no pill is drawn" % len(live))
if not live and pill: why.append("a pill with nothing live")
if pill and cam:
    if abs(pill["y"] - (cam["y"] - 4)) > 1 or abs(pill["h"] - (cam["height"] + 8)) > 1: why.append("pill %.1f+%.1f not 4px round the hole %.1f+%.1f" % (pill["y"], pill["h"], cam["y"], cam["height"]))
    if pill["x"] > cam["x"] - 3 or pill["x"] + pill["w"] < cam["x"] + cam["width"] + 3: why.append("pill doesn't go round the hole")
    if pill["x"] < 0 or pill["x"] + pill["w"] > g["iw"] + 0.5: why.append("pill off the screen")
    if live[0]["app"] not in (pill["label"] or ""): why.append("pill label %r doesn't name %s" % (pill["label"], live[0]["app"]))
if why: print("FAIL " + "; ".join(why))
elif not truth and not live: print("SKIP nothing live on the phone now (no timer, progress or playing media)")
else: print("OK %d live (%s), pill %s" % (len(live), ", ".join(l["kind"] + ":" + l["app"] for l in live), "drawn" if pill else "none (no camera hole on this screen)"))
PY
)
echo "$verdict"; echo "out: $OUT"
case $verdict in OK*) exit 0 ;; SKIP*) exit 5 ;; *) exit 1 ;; esac
