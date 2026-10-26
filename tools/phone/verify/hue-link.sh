#!/bin/bash
# lanes: emu phone
# hue-link.sh (Mac side, docs/COMPOSER.md section 6): Lights' Hue pairing handed to App API, and a composed widget's
# reads of the real bridge through it. Read-only: no input, nothing on home moved, and only READ actions are called
# (list_rooms, list_grouped_lights as consumer "widget") - never set_room / recall_scene: the lights stay as they are.
#   1. App API's service has /link (it runs appcap_link.py: started after the 2026-10-23 deploy - else it needs a
#      restart of the app-api service / the system tier, which this never does);
#   2. GET /link?app=hue: linked by local.lights, pinned (Lights hands it over once its widget or page has read the
#      bridge after that start);
#   3. both reads answer 200 with rows (room count, grouped-light count); App API's audit since the start shows reads only.
# Exit 1 + FAIL lines otherwise. Never prints the key (it never leaves App API's store; /link doesn't return it).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..
probe=$HOME/.cache/powos-verify/hue-link-probe.sh; mkdir -p "$(dirname "$probe")"
cat > "$probe" <<'EOF'
since=$(date +%Y-%m-%dT%H:%M:%S)
echo "LINK $(curl -s -m 5 'http://127.0.0.1:3411/link?app=hue' | head -c 300)"
for a in list_rooms list_grouped_lights; do
  curl -s -m 30 -X POST -d "{\"app\":\"hue\",\"action\":\"$a\",\"args\":{},\"send\":true,\"consumer\":\"widget\"}" \
    "http://127.0.0.1:3411/call?app=hue&action=$a" |
    python3 -c "import json,sys; j=json.load(sys.stdin); r=j.get('response') or {}; print('READ $a', j.get('refused') or j.get('error') or 'status=%s rows=%d' % ((j.get('preview') or {}).get('status'), len(r.get('data') or [])))"
done
python3 - "$since" <<'PY'
import glob, json, sys
bad = []
for p in glob.glob("/home/powos/.local/state/powos/app-api/audit/*.jsonl"):
    for line in open(p):
        try:
            r = json.loads(line)
        except ValueError:
            continue
        if r.get("ts", "") >= sys.argv[1] and r.get("sent") and r.get("safety") not in ("read", None):
            bad.append(f"{r.get('app')}.{r.get('action')}")
print("AUDIT bad=" + (";".join(bad) or "none"))
PY
EOF
out=$("$T/root.sh" "$probe" 2>&1 | grep -E '^(LINK|READ|AUDIT) ')
echo "$out"
fail=""
grep -q '^LINK .*no such route' <<<"$out" && { echo "FAIL: App API runs without /link - restart the app-api service (or the system tier) first"; exit 1; }
grep -q '^LINK .*"linked": true' <<<"$out" || fail="$fail not-linked(open Lights once after App API's restart)"
grep -q '^READ list_rooms status=200 rows=[1-9]' <<<"$out" || fail="$fail list_rooms"
grep -q '^READ list_grouped_lights status=200 rows=[1-9]' <<<"$out" || fail="$fail list_grouped_lights"
grep -q '^AUDIT bad=none' <<<"$out" || fail="$fail audit-shows-a-write"
[ -n "$fail" ] && { echo "FAIL:$fail"; exit 1; }
echo "PASS: Hue linked into App API by Lights (pinned); list_rooms and list_grouped_lights read the real bridge as a widget; reads only"
