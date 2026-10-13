#!/usr/bin/env bash
# Runs in the guest, for scripts/store-previews.sh: demo data for the store widgets that
# otherwise only say how to set them up. `gh` answers like a signed-in account, Home
# Assistant's states are files that curl reads, `curl` answers Cursor's dashboard, and
# the Tesla tile reads its own fixture, go-limit reads an OpenCode database, `python3` answers
# google-calendar's feed script, and two sleeping `claude` processes stand in for claude-top's
# Claude Code instances. With "off", puts everything back.
set -u
demo=/tmp/store-previews-demo
ha=~/.config/omarchy-proot/home-assistant
cursor=~/.config/cursor/auth.json
tesla=~/.config/omarchy-tesla/fixture.json
opencode=~/.local/share/opencode/opencode.db
history=~/.claude/history.jsonl

# Moves a real file aside before the demo writes its own; "off" puts it back.
aside() { [ -f "$1" ] && [ ! -f "$1.before-demo" ] && mv "$1" "$1.before-demo"; mkdir -p "${1%/*}"; }

if [ "${1:-}" = off ]; then
  for p in $(cat "$demo/claude.pids" 2>/dev/null); do kill "$p" 2>/dev/null; rm -f ~/.claude/sessions/"$p".json; done
  rm -rf "$demo" /usr/local/bin/gh /usr/local/bin/curl /usr/local/bin/python3 /usr/local/bin/pgrep
  for f in "$ha" "$cursor" "$tesla" "$opencode" "$history"; do
    [ -f "$f.before-demo" ] && mv "$f.before-demo" "$f" || rm -f "$f"
  done
  exit 0
fi

mkdir -p "$demo/api/states" /usr/local/bin
cat > /usr/local/bin/gh <<'EOF'
#!/bin/sh
case "$*" in
  auth*) exit 0 ;;
  api*) echo 4 ;;
  *review-requested*) echo 2 ;;
  search*) cat <<'JSON'
[{"title":"Add previews for every widget","url":"https://github.com/","repository":{"name":"omarchy-widgets"},"updatedAt":"2026-10-07T09:00:00Z"},
 {"title":"Store: categories, search and a detail page","url":"https://github.com/","repository":{"name":"omarchy-widgets"},"updatedAt":"2026-10-06T09:00:00Z"},
 {"title":"Fix wrapping of long command lines","url":"https://github.com/","repository":{"name":"omarchy-proot"},"updatedAt":"2026-10-05T09:00:00Z"},
 {"title":"Bump the checker to owl 2","url":"https://github.com/","repository":{"name":"omarchy-widgets"},"updatedAt":"2026-10-04T09:00:00Z"}]
JSON
    ;;
esac
EOF
chmod +x /usr/local/bin/gh

state() { printf '{"entity_id":"%s","state":"%s","attributes":{"friendly_name":"%s","unit_of_measurement":"%s"}}' "$1" "$2" "$3" "${4:-}" > "$demo/api/states/$1"; }
state light.living_room on "Living room"
state light.kitchen off "Kitchen"
state sensor.indoor 21.5 "Indoor" "°C"
state sensor.power 342 "Power use" "W"
state lock.front_door locked "Front door"
state switch.coffee_machine on "Coffee machine"
aside "$ha"
printf 'file://%s\ndemo\nlight.living_room\nlight.kitchen\nsensor.indoor\nsensor.power\nlock.front_door\nswitch.coffee_machine\n' "$demo" > "$ha"

# Cursor's Pro+ plan, from the cursor-plan author's own picture. Everything else goes to curl.
aside "$cursor"
echo '{"accessToken":"demo"}' > "$cursor"
cat > /usr/local/bin/curl <<'EOF'
#!/bin/sh
case "$*" in
  *DashboardService/GetCurrentPeriodUsage*) echo '{"billingCycleEnd":"1792627200000","planUsage":{"totalPercentUsed":77,"apiPercentUsed":96,"includedSpend":7000,"limit":7000}}' ;;
  *DashboardService/GetPlanInfo*) echo '{"planInfo":{"planName":"Pro+","price":"$60/mo"}}' ;;
  *) exec /usr/bin/curl "$@" ;;
esac
EOF
chmod +x /usr/local/bin/curl

# The made-up car from the tesla README: Bluebird, parked at 54% with an 80% charge limit.
aside "$tesla"
cat > "$tesla" <<'JSON'
{"name":"Bluebird","vin":"5YJ3E1EA0PF000001","car_type":"model 3","state":"online","shift":"P","driving":false,
 "speed_unit":"mph","battery":54,"charge_limit":80,"charging":"Disconnected","range":168,"range_unit":"mi",
 "odometer":12840,"locked":true,"sentry":false,"climate_on":false,"inside_temp":72,"outside_temp":64,"temp_unit":"°F",
 "tyres":{"min":41,"max":42},"tyre_fl":42,"tyre_fr":42,"tyre_rl":41,"tyre_rr":41,"tyre_unit":"psi",
 "software":"2026.32.6","open":[],"vehicles":[{"vin":"5YJ3E1EA0PF000001","name":"Bluebird"}]}
JSON

# A day of OpenCode Go on GLM-5.3-Flash, like the go-limit author's picture: quiet until a few
# hours ago, then bursts, about $1.50 in the 5-hour window.
aside "$opencode"
now=$(date +%s)
sqlite3 "$opencode" "
  create table message (id integer primary key, time_created integer, data text);
  with recursive n(i) as (select 0 union all select i + 1 from n where i < 39)
  insert into message (time_created, data)
  select ($now - (i * 37 % 41) * 900 - 60) * 1000,
    json_object('providerID', 'opencode-go', 'role', 'assistant', 'modelID', 'glm-5.3-flash',
      'tokens', json_object('input', 150000 + i * 3000, 'output', 15000, 'reasoning', 4000,
        'cache', json_object('read', 900000, 'write', 0)))
  from n"

# Two calendars of made-up events over the next few days, in place of the Google feeds the
# calendar's saved state points at (scripts/store-previews.sh seeds that state).
cat > "$demo/gcal.py" <<'PY'
import json, time
from datetime import datetime, timedelta
now = time.time()
day = datetime.now().replace(hour=0, minute=0, second=0, microsecond=0)
def at(days, h, m=0): return int((day + timedelta(days=days, hours=h, minutes=m)).timestamp())
def soon(hours): return int(now // 1800 * 1800 + hours * 3600)
timed = [
    ("Call with Mom", "", 0, soon(1), 30), ("Standup", "", 1, at(1, 9, 30), 15),
    ("Lunch with Sam", "Café Lindt", 0, at(1, 12, 30), 60), ("Design review", "", 1, at(1, 16), 60),
    ("Dentist", "Dr. Weber", 0, at(2, 8, 30), 45), ("1:1 with Alex", "", 1, at(2, 14), 30),
    ("Sprint planning", "", 1, at(3, 10), 90), ("Climbing", "Boulderhalle", 0, at(3, 19), 120),
]
events = [{"t": t, "l": l, "c": c, "d": datetime.fromtimestamp(s).date().isoformat(), "s": s, "e": s + mins * 60, "a": False}
          for t, l, c, s, mins in timed]
events.append({"t": "Mia's birthday", "l": "", "c": 0, "d": (day + timedelta(days=1)).date().isoformat(), "a": True, "s": 0, "e": 0, "n": 1})
events.sort(key=lambda x: (x["d"], x["s"]))
print(json.dumps({"events": events, "errors": {}, "names": {"0": "Personal", "1": "Work"}}, ensure_ascii=False))
PY
cat > /usr/local/bin/python3 <<'EOF'
#!/bin/sh
case "$*" in
  *owl-gcal*) exec /usr/bin/python3 /tmp/store-previews-demo/gcal.py ;;
  *) exec /usr/bin/python3 "$@" ;;
esac
EOF
chmod +x /usr/local/bin/python3

# Claude Code instances for claude-top: processes named claude (python, so the memory is
# real), one busy on and off, with the session files and prompts Claude Code would keep.
# Every proot kills what it runs when it exits, this script's too, so `pgrep` starts them
# from the widget's own command, the first time it looks for claude.
aside "$history"
cat > "$demo/claude.sh" <<'EOF'
demo=/tmp/store-previews-demo
mkdir -p "$demo/bin" ~/.claude/sessions ~/Projects/omarchy-widgets ~/Projects/website
ln -sf /usr/bin/python3 "$demo/bin/claude"
ms=$(( $(date +%s) * 1000 ))
claude() {
  local cwd=$1 sid=$2 status=$3 mb=$4 busy=$5 prompt=$6 ago=$7
  (cd "$cwd" && exec setsid "$demo/bin/claude" -c "
import time
x = bytearray($mb << 20)
for i in range(0, len(x), 4096): x[i] = 1
while True:
    t = time.time() + $busy
    while time.time() < t: pass
    time.sleep(1 - $busy)" </dev/null >/dev/null 2>&1) &
  local pid=$!
  echo "$pid" >> "$demo/claude.pids"
  printf '{"sessionId":"%s","name":"%s","status":"%s","cwd":"%s","version":"2.4.1","statusUpdatedAt":%s,"startedAt":%s}\n' \
    "$sid" "${cwd##*/}" "$status" "$cwd" $(( ms - 40000 )) $(( ms - ago * 60000 )) > ~/.claude/sessions/"$pid".json
  printf '{"display":"%s","sessionId":"%s"}\n' "$prompt" "$sid" >> ~/.claude/history.jsonl
}
claude ~/Projects/omarchy-widgets demo-widgets busy 410 0.3 "render the themed previews for the new widgets" 52
claude ~/Projects/website demo-website idle 280 0 "fix the header on small screens" 140
sleep 0.5
EOF
cat > /usr/local/bin/pgrep <<'EOF'
#!/bin/sh
if [ "$*" = "-x claude" ] && [ -f /tmp/store-previews-demo/claude.sh ] && [ ! -f /tmp/store-previews-demo/claude.pids ]; then
  bash /tmp/store-previews-demo/claude.sh
fi
exec /usr/bin/pgrep "$@"
EOF
chmod +x /usr/local/bin/pgrep
