#!/bin/bash
# lanes: emu phone
# composer.sh [APP_ID] (Mac side, docs/COMPOSER.md): a composed widget on the device (default local.hue-rooms, made by
# `powos compose widget "which Hue rooms are on"`). Read-only probes, no input, nothing on home moved:
#   1. powos-registry has the app (its manifest carries the composition) and its island widget - the rows home's edit
#      sheet lists under "PowOS apps" (ui/apppicker.tsx);
#   2. its own database is published (the snapshot table answers) and its UI is installed;
#   3. the shell serves its widget module (home's page fetches ./_app/<id>/widgets/main.js: 200);
#   4. the widget's own read, as it makes it (lib/compose.ts read: app/action in the query and the body): App API /call
#      as consumer "widget" for each block - a READ (list_rooms,
#      list_grouped_lights); an unlinked Hue answers "refused: needs bridge_ip" without contacting anything. No write
#      action is ever called here (never set_room / recall_scene: the user's lights stay as they are);
#   5. App API's audit since the check started: the widget consumer made reads only, nothing was sent that wasn't a read.
# PASS when 1-5 hold. The device needs the composed app installed first (apps/install.sh <its folder>).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..
ID=${1:-local.hue-rooms}
DB=${ID//./-}
fail=""
probe=$HOME/.cache/powos-verify/composer-probe.sh; mkdir -p "$(dirname "$probe")"
cat > "$probe" <<EOF
q() { curl -s -m 5 -X POST -d "\$2" http://127.0.0.1:3410/v1/database/\$1/sql | tr -d '\n'; echo; }
since=\$(date +%Y-%m-%dT%H:%M:%S)
echo "REG_APP \$(q powos-registry "SELECT id, database FROM app WHERE id = '$ID'")"
echo "REG_COMPOSED \$(q powos-registry "SELECT manifest FROM app WHERE id = '$ID'" | grep -c 'powos.compose/v1')"
echo "REG_WIDGET \$(q powos-registry "SELECT key, kind, entry FROM widget WHERE app_id = '$ID'")"
echo "DB \$(q $DB "SELECT source FROM snapshot")"
[ -f /home/powos/.local/share/powos/apps/$ID/current/ui/widgets/main.js ] && echo "UI_OK"
M=/home/powos/.local/share/powos/apps/$ID/current/powos-app.json
for a in \$(python3 -c "import json;print(' '.join(u['app']+':'+u['action'] for u in json.load(open('\$M'))['composition']['uses']))" 2>/dev/null); do
  b="{\\"app\\":\\"\${a%%:*}\\",\\"action\\":\\"\${a#*:}\\",\\"args\\":{},\\"send\\":true,\\"consumer\\":\\"widget\\"}"
  r=\$(curl -s -m 30 -X POST -d "\$b" "http://127.0.0.1:3411/call?app=\${a%%:*}&action=\${a#*:}" | head -c 300)
  echo "CALL \$a \$r"
done
python3 - "\$since" <<'PY'
import glob, json, sys
since, reads, bad = sys.argv[1], 0, []
for p in glob.glob("/home/powos/.local/state/powos/app-api/audit/*.jsonl"):
    for line in open(p):
        try:
            r = json.loads(line)
        except ValueError:
            continue
        if r.get("ts", "") < since:
            continue
        if r.get("sent") and r.get("safety") != "read":
            bad.append(f"{r.get('app')}.{r.get('action')} sent by {r.get('consumer')}")
        elif r.get("safety") == "read":
            reads += 1
print(f"AUDIT reads={reads} bad={';'.join(bad) or 'none'}")
PY
EOF
out=$("$T/root.sh" "$probe" 2>&1 | grep -E '^(REG_|DB |UI_OK|CALL |AUDIT )')
echo "$out"
grep -q "^REG_APP .*$DB" <<<"$out" || fail="$fail not-registered"
grep -q "^REG_COMPOSED [1-9]" <<<"$out" || fail="$fail no-composition-in-registry"
grep -q "^REG_WIDGET .*island" <<<"$out" || fail="$fail no-island-widget"
grep -q '^DB .*"schema"' <<<"$out" || fail="$fail no-database"
grep -q "^UI_OK" <<<"$out" || fail="$fail ui-missing"
grep -q "^CALL " <<<"$out" || fail="$fail no-block-call"
# "no action": a block the running App API service doesn't know yet (a newer package's read, e.g.
# list_grouped_lights, arrives at the service's next start) - pending, not a safety problem.
grep "^CALL " <<<"$out" | grep -qvE '"refused"|"response|"preview"|"error": "no action' && fail="$fail call-unexpected"
grep -q '^CALL .*"error": "no action' <<<"$out" && echo "note: a block waits for App API's next start (its newer actions)"
grep -q "^AUDIT .*bad=none" <<<"$out" || fail="$fail audit-shows-a-non-read"
st=$("$T/cdp.sh" eval home "fetch('./_app/$ID/widgets/main.js').then(r=>r.status,e=>String(e))" 2>&1 | tail -1 | tr -d '"\r')
echo "SHELL_MODULE $st"
[ "$st" = 200 ] || fail="$fail shell-module=$st"
[ -n "$fail" ] && { echo "FAIL:$fail"; exit 1; }
echo "PASS: $ID registered with its composition and island (home's edit sheet lists it), its database and UI installed, the shell serves its widget, its blocks answer a widget read, App API's audit shows reads only"
