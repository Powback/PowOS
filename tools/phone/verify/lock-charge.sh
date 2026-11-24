#!/bin/bash
# lanes: phone
# lock-charge.sh (Mac side, board lock-charging-info; ask-1a209c7798a): the lock face's charging line against the
# phone's own battery facts. Read-only: one bridge read (system.battery, as the lock face asks it) from home's page over
# CDP, and `dumpsys battery` (no root). No taps, no settings, nothing on screen changes.
# PASS = the bridge's level matches dumpsys (+-1), its plugged state matches, and while charging it gives a speed class
# whose watts agree with dumpsys' Max charging current x voltage (system/Charging.kt's thresholds), plus the line the
# face would show. Not plugged in: SKIP (this check needs a charger in).
set -u
cd "$(dirname "$0")/../../.." || exit 1
read_js='new Promise((ok)=>{const H=window.__powosHost;const r=H.resolve;const id=987001;const t=setTimeout(()=>{H.resolve=r;ok("timeout")},5000);H.resolve=(i,v)=>{if(i===id){clearTimeout(t);H.resolve=r;ok(JSON.stringify(v))}else r(i,v)};window.PowosHost.postMessage(JSON.stringify([id,"system.battery","[]"]))})'
bridge=$(tools/phone/cdp.sh eval home "$read_js" 2>&1 | tail -1)
# cdp.sh prints the answer JSON-quoted: unquote once.
bridge=$(python3 -c 'import json,sys; s=sys.argv[1]; v=json.loads(s) if s.startswith("\"") else s; print(v)' "$bridge" 2>/dev/null || echo "$bridge")
dump=$(tools/phone/adb.sh shell dumpsys battery 2>&1)
echo "bridge: $bridge"
echo "dumpsys:"; echo "$dump" | grep -E 'powered|level|status|Max charging|voltage' | sed 's/^/  /'
python3 - "$bridge" "$dump" <<'PY'
import json, re, sys
raw, dump = sys.argv[1], sys.argv[2]
try:
    b = json.loads(raw)
except Exception:
    print(f"FAIL: no battery from the bridge ({raw[:120]})"); sys.exit(1)
def num(key):
    m = re.search(rf"^\s*{re.escape(key)}:\s*(-?\d+)", dump, re.M)
    return int(m.group(1)) if m else None
def flag(key):
    m = re.search(rf"^\s*{re.escape(key)}:\s*(true|false)", dump, re.M)
    return m and m.group(1) == "true"
level, status = num("level"), num("status")
plugged = flag("AC powered") or flag("USB powered") or flag("Wireless powered") or flag("Dock powered")
if "plugged" not in b:
    print("FAIL: the installed APK's bridge has no charging fields yet (older host)"); sys.exit(1)
if level is not None and b.get("level") is not None and abs(level - b["level"]) > 1:
    print(f"FAIL: level bridge {b['level']} vs dumpsys {level}"); sys.exit(1)
if not plugged:
    print("SKIP: not plugged in - plug a charger in and queue again"); sys.exit(0)
if b.get("plugged") is None:
    print("FAIL: dumpsys says powered, the bridge says on battery"); sys.exit(1)
ua, uv = num("Max charging current"), num("Max charging voltage")
words = {"superfast": "Super fast charging", "fast": "Fast charging", "slow": "Charging slowly", "normal": "Charging"}
if b.get("charging") and not b.get("full"):
    if b.get("speed") not in words:
        print(f"FAIL: charging but no speed class ({b.get('speed')})"); sys.exit(1)
    if ua and ua > 0:
        w = (ua / 1000) * ((uv if uv and uv > 0 else 5_000_000) / 1000) / 1e6
        want = "superfast" if w >= 20 else "fast" if w >= 7.5 else "slow" if w < 5 else "normal"
        if b["speed"] != want:
            print(f"FAIL: dumpsys charger {w:.1f} W -> {want}, bridge says {b['speed']}"); sys.exit(1)
t = b.get("fullInMs")
line = "Charged" if b.get("full") else "Charging paused" if b.get("held") else words.get(b.get("speed"), "Charging")
if t: line += f" · {-(-t // 60000)} min until full"
print(f"PASS: plugged {b['plugged']}, {b.get('watts')} W ({b.get('wattsFrom')}), speed {b.get('speed')}, "
      f"full in {'unknown (hidden)' if not t else str(round(t/60000)) + ' min'}; the face says \"{line}\"")
PY
