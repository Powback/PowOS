#!/bin/bash
# lanes: emu phone
# board-state.sh [TITLE] (board board-shows-real-agent-state-working-only-if-an; queue: queue.sh add --close <task>
# board-state.sh): the AI page's in-progress rows say working / queued / awaiting check / stalled, a lit dot only on
# "working" ones (the states: working / awaiting check / no check / stalled, agents.ts boardState), and the row titled TITLE (default: this task's, queued for this check) says "awaiting check".
# Home, the page swipe to the AI page, reads the rows over CDP (read only), screencaps, swipes back.
# Exit 0 pass, 1 fail, 3 a real touch / screen not awake (re-queued), 5 can't run. Injected input only.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"
TITLE=${1:-Board shows real agent state}
OUT=$HOME/.cache/powos-verify/board-state-$(date +%m%d-%H%M); mkdir -p "$OUT"
L=$HOME/.cache/powos-verify.lock
sh_() { "$A" shell "su -c '$*'" 2>/dev/null | tr -d '\r'; }
irq() { sh_ "awk '/touch-0/{s+=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9} END{print s}' /proc/interrupts"; }
restore() { sh_ "am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; }
. "$here/window-lock.sh"; window_lock board-state.sh 60
trap 'restore; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"' EXIT
I0=$(irq)
chk() { [ "$(irq)" = "$I0" ] || { echo "STOP: a real touch at $1 - restoring"; exit 3; }; }
[ "$(sh_ "dumpsys power | sed -n s/.*mWakefulness=//p | head -1")" = Awake ] || { echo "screen not awake - nothing done"; exit 3; }
sh_ "dumpsys window policy | grep -m1 -E \"mIsShowing=\"" | grep -q true && { echo "keyguard showing - nothing done"; exit 3; }
WH=$(sh_ "wm size" | sed -nE 's/.*(Override|Physical) size: ([0-9]+)x([0-9]+).*/\2 \3/p' | tail -1); W=${WH% *}; H=${WH#* }
sh_ "am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; sleep 1.5; chk home
sh_ "input swipe $((W * 3 / 10)) $((H / 2)) $((W * 9 / 10)) $((H / 2)) 350"; sleep 4; chk ai
probe='JSON.stringify([...document.querySelectorAll(".ai-item.working")].map(e=>({t:e.querySelector(".ai-item-title")?.textContent||"",f:e.querySelector(".ai-item-facts")?.textContent||"",on:!!e.querySelector(".ai-dot.on")})))'
p=$("$T/cdp.sh" eval home "$probe" 2>&1 | tr -d '\\' | tail -1)
"$T/shot.sh" "$OUT/board-state.png" >/dev/null 2>&1
sh_ "input swipe $((W * 9 / 10)) $((H / 2)) $((W * 15 / 100)) $((H / 2)) 300"; sleep 1
python3 - "$p" "$TITLE" <<'PY'
import json, sys
raw, title = sys.argv[1], sys.argv[2]
try:
    rows = json.loads(raw.strip('"'))
except ValueError:
    print(f"FAIL board-state: no rows read ({raw[:200]})"); sys.exit(1)
states = ("working", "awaiting check", "no check", "stalled")
bad = [r for r in rows if not r["f"].startswith(states) or r["on"] != r["f"].startswith("working ")]
mine = [r for r in rows if r["t"].startswith(title)]
count = {s: sum(r["f"].startswith(s) for r in rows) for s in states}
print(f"board-state: {len(rows)} in progress {count}")
if not rows: print("FAIL board-state: no in-progress rows on the page"); sys.exit(1)
if bad: print(f"FAIL board-state: rows without a state or with a dot that disagrees: {bad[:3]}"); sys.exit(1)
if not mine or not mine[0]["f"].startswith("awaiting check"):
    print(f"FAIL board-state: '{title}' row: {mine[:1]}"); sys.exit(1)
print(f"PASS board-state: every row has its live state, '{title}' awaiting check")
PY
