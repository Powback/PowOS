#!/bin/bash
# lanes: phone
# account-sync.sh (board: Apps follow the account: Hue pairing and app config on every device; queue: queue.sh add
# <task> tools/phone/verify/account-sync.sh): on the phone, after a rooted.sh deploy + the new Lights installed
# (apps/install.sh ~/Projects/lights install) - read only, no touch:
#  1. powos-account-sync runs there and its last round was ok, with local.lights|home_bridge and |pref "ok";
#  2. the account (the realm, asked with the phone's own enrollment token, inside the phone) holds Lights' rows and
#     the secret "hue" - the OnePlus's key went up (the migration);
#  3. Lights' home_bridge row exists in local-lights (the old bridge row migrated).
# Then the S25 (non-root, its APK from the same ship) needs no pairing: the user opens Lights there.
# Exit 0 pass, 1 fail, 5 can't run (no phone).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..
out=$("$T/user.sh" /dev/stdin <<'SH' 2>&1
set -u
S=/usr/lib/powos/apps/powos-account-sync
[ -x "$S" ] || { echo "NOAGENT"; exit 0; }
pgrep -f 'powos-account-sync run' >/dev/null && echo "RUNNING" || echo "NOTRUNNING"
python3 "$S" status 2>&1 | sed 's/^/STATUS /'
E=$HOME/.local/state/powos/deviced/enrollment.json
python3 - "$E" <<'PY'
import json, sys, urllib.request
e = json.load(open(sys.argv[1]))
def get(p):
    r = urllib.request.Request(e["realm"].rstrip("/") + p, headers={"Authorization": "Bearer " + e["device_token"]})
    return json.load(urllib.request.urlopen(r, timeout=10))
print("SECRETS", json.dumps(get("/v1/account/secrets?app=local.lights")["names"]))
rows = get("/v1/account/rows?since=0&limit=500")["rows"]
print("ROWS", json.dumps(sorted({r["table"] for r in rows if r["app"] == "local.lights" and not r["deleted"]})))
PY
curl -s -X POST -d "SELECT * FROM home_bridge" http://127.0.0.1:3410/v1/database/local-lights/sql | head -c 400 | sed 's/^/HOME /'
SH
) || { echo "SKIP account-sync: phone not reachable ($out)"; exit 5; }
echo "$out" | sed 's/^/  /'
fail() { echo "FAIL account-sync: $1"; exit 1; }
grep -q NOAGENT <<<"$out" && fail "powos-account-sync isn't installed (rooted.sh deploy)"
grep -q '^RUNNING' <<<"$out" || fail "the agent isn't running (supervisor)"
grep -q 'STATUS last round .*: ok' <<<"$out" || fail "its last round wasn't ok"
grep -q 'STATUS   local.lights|home_bridge: ok' <<<"$out" || fail "Lights' home_bridge doesn't sync (new Lights installed?)"
grep -q 'SECRETS .*"hue"' <<<"$out" || fail "the account has no Hue key yet (open Lights once on this phone)"
grep -q 'ROWS .*"home_bridge"' <<<"$out" || fail "the account has no Lights bridge row"
grep -q 'HOME .*"rows":\[\[0' <<<"$out" || fail "no home_bridge row in local-lights here"
echo "PASS account-sync: agent ok, Lights' bridge + rooms and the Hue key are in the account"
