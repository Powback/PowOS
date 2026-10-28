#!/bin/bash
# test-self-ship.sh - `powos self push --ship`: the phone client (lib/self.sh) against the REAL tools/phone/ship-gate.py
# on localhost, with ship.sh stubbed (no queue, no launchd, no network beyond 127.0.0.1).
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
command -v python3 >/dev/null && command -v curl >/dev/null || { echo "skip: needs python3 + curl"; exit 0; }
PASS=0; FAIL=0
ok()  { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL - $1 ${2:-}"; FAIL=$((FAIL+1)); }
W=$(mktemp -d); GP=
trap '[ -n "$GP" ] && kill $GP 2>/dev/null; rm -rf "$W"' EXIT
perr() { echo "ERR $*"; }; pok() { echo "OK $*"; }; plog() { echo "LOG $*"; }
source "$REPO/lib/self.sh" 2>/dev/null || true
type self_ship_request >/dev/null 2>&1 || { bad "self_ship_request defined"; exit 1; }

# a repo whose HEAD the stub ship.sh will accept or refuse
git init -q "$W/src" && git -C "$W/src" -c user.email=t@t -c user.name=t commit -q --allow-empty -m x
SHA=$(git -C "$W/src" rev-parse HEAD)
cat > "$W/ship.sh" <<STUB
#!/bin/bash
echo "\$*" >> $W/ship.args
[ -e $W/refuse ] && { echo "ship.sh request: REFUSED - not on origin" >&2; exit 3; }
echo "ship requested (abc): ... [id 20261028-120000-1]"
STUB
SECRET=0123456789abcdef0123456789abcdef; echo "$SECRET" > "$W/secret"; chmod 600 "$W/secret"
PORT=$((20000 + RANDOM % 20000))
SHIP_SH="$W/ship.sh" SHIP_GATE_SECRET_FILE="$W/secret" SHIP_GATE_PORT=$PORT SHIP_GATE_BIND=127.0.0.1 python3 "$REPO/tools/phone/ship-gate.py" 2>"$W/gate.log" & GP=$!
for _ in $(seq 30); do curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.2; done
export POWOS_SHIP_GATE_URL="http://127.0.0.1:$PORT" POWOS_SHIP_GATE_SECRET_FILE="$W/secret" POWOS_SHIP_GATE_CONF=/nonexistent

out=$(self_ship_request "$W/src" 'fix "quotes" in agents' T-7 2>&1); rc=$?
[ $rc = 0 ] && grep -q "id 20261028-120000-1" <<<"$out" && ok "queued: prints the request id" || bad "queued" "$out"
grep -q -- "--sha $SHA --note fix \"quotes\" in agents \[task T-7\] --who phone:" "$W/ship.args" && ok "gate passes sha, note (+task), who to ship.sh request" || bad "ship.sh args" "$(cat "$W/ship.args")"
grep -q "$SECRET" <<<"$out$(cat "$W/gate.log")" && bad "secret leaked in output/log" || ok "secret never printed or logged"

: > "$W/ship.args"; touch "$W/refuse"
out=$(self_ship_request "$W/src" "n" 2>&1); rc=$?
[ $rc != 0 ] && grep -q "not on origin" <<<"$out" && ok "sha not on origin -> clear refusal, non-zero" || bad "refusal" "$out"
rm "$W/refuse"

: > "$W/ship.args"; echo "wrong-secret-wrong-secret" > "$W/secret2"
out=$(POWOS_SHIP_GATE_SECRET_FILE="$W/secret2" self_ship_request "$W/src" "n" 2>&1); rc=$?
[ $rc != 0 ] && grep -q "rejected the secret" <<<"$out" && ok "bad secret -> 401 message" || bad "401" "$out"
[ ! -s "$W/ship.args" ] && ok "bad secret never reaches ship.sh" || bad "401 reached ship.sh"

out=$(POWOS_SHIP_GATE_URL="http://127.0.0.1:1" self_ship_request "$W/src" "n" 2>&1); rc=$?
[ $rc != 0 ] && grep -q "unreachable" <<<"$out" && ok "endpoint down -> says unreachable, push untouched" || bad "unreachable" "$out"

out=$(POWOS_SHIP_GATE_SECRET_FILE="$W/none" self_ship_request "$W/src" "n" 2>&1)
grep -q "no ship secret" <<<"$out" && ok "no secret file -> says what to provision" || bad "no secret" "$out"

code=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $SECRET" -d '{"sha":"zz","note":"n","from":"p"}' "$POWOS_SHIP_GATE_URL/request")
[ "$code" = 400 ] && ok "bad sha -> 400" || bad "400" "$code"

# provisioning: ship-deploy.sh gate-install makes the secret (temp HOME, launchctl/plutil/openssl-free stubs), idempotently, never printing it
H=$W/home; mkdir -p "$H/bin" "$H/pw/ship-runner/tools/phone"; touch "$H/pw/ship-runner/.git" "$H/pw/ship-runner/tools/phone/ship-gate.py"
for c in launchctl plutil sleep; do printf '#!/bin/sh\nexit 0\n' > "$H/bin/$c"; chmod +x "$H/bin/$c"; done
gi() { HOME="$H" POWOS_RUN_ROOT="$H/pw" PATH="$H/bin:$PATH" bash "$REPO/tools/phone/ship-deploy.sh" gate-install 2>&1; }
o1=$(gi); GS=$H/.config/powos/ship-gate.secret
[ -s "$GS" ] && [ "$(stat -f %Lp "$GS" 2>/dev/null || stat -c %a "$GS")" = 600 ] && ok "gate-install makes the secret, mode 600" || bad "secret made" "$o1"
S1=$(cat "$GS"); o2=$(gi)
[ "$S1" = "$(cat "$GS")" ] && ok "second gate-install keeps the same secret" || bad "idempotent"
grep -qF "$S1" <<<"$o1$o2" && bad "provisioned secret printed" || ok "provisioned secret never printed"
grep -q "ship-gate.secret" "$REPO/targets/android/rooted/powos-deploy.sh" && grep -q "cmp -s" "$REPO/targets/android/rooted/powos-deploy.sh" \
  && ! grep -n "ship-gate.secret" "$REPO/targets/android/rooted/rooted.sh" | grep -q "asu\|echo.*\$(cat" && ok "phone deploy installs by file compare, no secret on a command line" || bad "phone deploy shape"

echo "self-ship: $PASS passed, $FAIL failed"; [ $FAIL = 0 ]
