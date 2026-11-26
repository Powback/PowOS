#!/bin/bash
# test-coordinator-relay.sh - the phone's "coordinator" mail relayed to the Mac (tools/agents/coordinator-relay.py,
# tools/agents/reply-phone.sh; unit units/mac/coordinator-relay-mac.json).
#
# The phone is a fake: a local comms spool (the real lib/ai/comms/comms-mcp.py store, COMMS_ROOT in a temp dir), a
# `powos` on PATH that runs it, RELAY_PHONE_RUN = bash, RELAY_PHONE_STATE = a file saying online/offline. Guards:
# every message relayed once (idempotent by id), marked read on the phone only after the Mac file has it, nothing
# touched while offline and all of it delivered on reconnect, other roles' mail untouched, replies reach the sender.
#
# Usage:  bash test/tier1/test-coordinator-relay.sh
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()  { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL - $1"; [ -n "${2:-}" ] && echo "    $2"; FAIL=$((FAIL+1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/spool"
export COMMS_ROOT=$T/spool COMMS_AGENT_ID='' POWOS_COMMS_START=0 POWOS_AI_AGENTS_DIR=$T/no-agents POWOS_AGENTS_QUEUE=$T/no-queue POWOS_PLATFORM=test
cat > "$T/bin/powos" <<EOF
#!/bin/bash
[ "\$1" = comms ] || exit 2; shift
echo "powos comms \$*" >> "$T/calls"
exec python3 "$ROOT/lib/ai/comms/comms-mcp.py" "\$@"
EOF
cat > "$T/state" <<'EOF'
#!/bin/bash
[ "$(cat "$(dirname "$0")/online")" = 1 ]
EOF
chmod +x "$T/bin/powos" "$T/state"
export PATH="$T/bin:$PATH"
export RELAY_PHONE_STATE="$T/state" RELAY_PHONE_RUN=bash RELAY_INBOX="$T/mac/inbox.jsonl"
RELAY="python3 $ROOT/tools/agents/coordinator-relay.py"
pending() { find "$T/spool/agents/$1/inbox" -name '*.json' 2>/dev/null | wc -l | tr -d ' '; }
lines() { [ -f "$1" ] && wc -l < "$1" | tr -d ' ' || echo 0; }
send() { powos comms send "$@" >/dev/null 2>&1; }

echo "== coordinator relay =="
echo 1 > "$T/online"
send coordinator 'Board: 3 stalled tasks, see `powos agents` $(not expanded)' --from manager --priority high
send coordinator "second note" --from manager
send manager "not for the coordinator" --from user
$RELAY run 2>/dev/null
[ "$(lines "$T/mac/inbox.jsonl")" = 2 ] && ok "two coordinator messages relayed" || bad "relayed lines: $(lines "$T/mac/inbox.jsonl")"
[ "$(pending coordinator)" = 0 ] && ok "marked read on the phone" || bad "still pending: $(pending coordinator)"
[ "$(pending manager)" = 1 ] && ok "other roles' mail untouched" || bad "manager inbox: $(pending manager)"
python3 - "$T/mac/inbox.jsonl" <<'EOF' && ok "record: id/from/priority/time/body exact" || bad "record fields"
import json, sys
r = [json.loads(l) for l in open(sys.argv[1])]
assert r[0]["from"] == "manager" and r[0]["priority"] == "high" and r[0]["time"] and len(r[0]["id"]) == 12
assert r[0]["body"] == 'Board: 3 stalled tasks, see `powos agents` $(not expanded)', r[0]["body"]
assert r[1]["body"] == "second note" and r[1]["priority"] == "normal"
EOF
grep -q '!! \[high\] manager -> coordinator' "$T/mac/inbox.log" && [ "$(lines "$T/mac/inbox.log")" = 2 ] \
  && ok "summary log: one line each, high flagged" || bad "log" "$(cat "$T/mac/inbox.log")"

# Idempotence: the read failed last time (crash between append and read) -> the same mail seen again is not duplicated.
send coordinator "third" --from manager
cp "$T/mac/inbox.jsonl" "$T/before"
python3 - "$T/spool" <<'EOF'
import glob, json, sys
f = sorted(glob.glob(sys.argv[1] + "/agents/coordinator/inbox/*.json"))[0]
m = json.load(open(f))
open(sys.argv[1] + "/../mac/inbox.jsonl", "a").write(json.dumps({"id": m["id"], "from": "manager", "body": "third"}) + "\n")
EOF
$RELAY run 2>/dev/null
[ "$(lines "$T/mac/inbox.jsonl")" = 3 ] && ok "already-relayed id not appended again" || bad "lines: $(lines "$T/mac/inbox.jsonl")"
[ "$(pending coordinator)" = 0 ] && ok "already-relayed id still marked read" || bad "pending: $(pending coordinator)"
$RELAY run 2>/dev/null
[ "$(lines "$T/mac/inbox.jsonl")" = 3 ] && ok "empty pass changes nothing" || bad "lines: $(lines "$T/mac/inbox.jsonl")"

# Offline: no phone command at all, mail kept; back online: delivered.
: > "$T/calls"; echo 0 > "$T/online"
send coordinator "queued while offline 1" --from manager
send coordinator "queued while offline 2" --from manager --priority urgent
: > "$T/calls"
$RELAY run 2>/dev/null
[ ! -s "$T/calls" ] && ok "offline: no phone command run" || bad "offline calls" "$(cat "$T/calls")"
[ "$(pending coordinator)" = 2 ] && [ "$(lines "$T/mac/inbox.jsonl")" = 3 ] && ok "offline: mail waits on the phone" \
  || bad "offline pending $(pending coordinator) lines $(lines "$T/mac/inbox.jsonl")"
echo 1 > "$T/online"
$RELAY run 2>/dev/null
[ "$(lines "$T/mac/inbox.jsonl")" = 5 ] && [ "$(pending coordinator)" = 0 ] && ok "reconnect: queued mail delivered" \
  || bad "reconnect pending $(pending coordinator) lines $(lines "$T/mac/inbox.jsonl")"

# The read happens only after the Mac file has it: an unwritable Mac file -> nothing marked read (root ignores the
# mode bits, so as root - the tier-1 container - this pair is skipped).
if [ "$(id -u)" != 0 ]; then
  send coordinator "mac disk full" --from manager
  chmod 444 "$T/mac/inbox.jsonl"
  $RELAY run >/dev/null 2>&1
  [ "$(pending coordinator)" = 1 ] && ok "Mac append failed: phone mail not marked read" || bad "pending $(pending coordinator)"
  chmod 644 "$T/mac/inbox.jsonl"
  $RELAY run 2>/dev/null
  [ "$(pending coordinator)" = 0 ] && [ "$(lines "$T/mac/inbox.jsonl")" = 6 ] && ok "next pass delivers it" || bad "after retry"

else ok "Mac append failed: skipped as root"; ok "next pass delivers it: skipped as root"
  send coordinator "mac disk full" --from manager; $RELAY run 2>/dev/null
fi

# Reply path.
id=$(python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).readline())["id"])' "$T/mac/inbox.jsonl")
bash "$ROOT/tools/agents/reply-phone.sh" "$id" 'on it: `x` $(y)' >/dev/null 2>&1
python3 - "$T/spool" "$id" <<'EOF' && ok "reply reaches the sender, body literal" || bad "reply" "$(cat "$T"/spool/agents/manager/inbox/*.json)"
import glob, json, sys
ms = [json.load(open(f)) for f in sorted(glob.glob(sys.argv[1] + "/agents/manager/inbox/*.json"))]
r = [m for m in ms if m["from"] == "coordinator"]
assert len(r) == 1 and r[0]["body"] == f"Re {sys.argv[2]}: on it: `x` $(y)" and r[0]["priority"] == "high", r
EOF
bash "$ROOT/tools/agents/reply-phone.sh" nosuchid hi >/dev/null 2>&1; [ $? = 2 ] && ok "reply to an unknown id refused" || bad "unknown id"
echo 0 > "$T/online"
bash "$ROOT/tools/agents/reply-phone.sh" "$id" hi >/dev/null 2>&1; [ $? = 69 ] && ok "reply while offline: 69, nothing sent" || bad "offline reply"

echo "== Results: $PASS passed, $FAIL failed =="
[ "$FAIL" = 0 ]
