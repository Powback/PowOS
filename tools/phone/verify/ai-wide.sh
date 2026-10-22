#!/bin/bash
# ai-wide.sh [OUT] (board ai-page-two-pane-wide-layout): PowOS AI's page on the INNER screen is two panes. Forces the
# inner screen (cmd device_state state 3, as unfolded-checks.sh), dismisses the keyguard / swipes the lock face (no PIN),
# home, the page swipe to the AI page, then reads the layout over CDP (read only) and screencaps it.
# PASS = .ai-screen.wide, the conversation (.ai-talk) left of the side pane (.ai-side), the pill under the conversation,
# both panes their own scroll (overflow-y auto). Restores: swipe back, home, `cmd device_state state reset`.
# Exit 0 pass, 1 fail, 3 a real touch / screen not awake (re-queued), 5 can't run. Injected input only.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"; ROOT=$(cd "$T/../.." && pwd)
OUT=${1:-$HOME/.cache/powos-verify/ai-wide-$(date +%m%d-%H%M)}; mkdir -p "$OUT"
L=$HOME/.cache/powos-verify.lock
TASK=ai-page-two-pane-wide-layout
sh_() { "$A" shell "su -c '$*'" 2>/dev/null | tr -d '\r'; }
irq() { sh_ "awk '/touch-0/{s+=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9} END{print s}' /proc/interrupts"; }
restore() { sh_ "am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null; cmd device_state state reset"; echo "restored"; }
. "$here/window-lock.sh"; window_lock ai-wide.sh 120
trap 'restore; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"' EXIT
I0=$(irq)
chk() { [ "$(irq)" = "$I0" ] || { echo "STOP: a real touch at $1 - restoring"; exit 3; }; }
s=$(sh_ "dumpsys power | sed -n s/.*mWakefulness=//p | head -1")
[ "$s" = Awake ] || { echo "the screen is $s - not woken (rule); nothing done"; exit 3; }
sh_ "cmd device_state state 3"; sleep 3; chk unfold
WH=$(sh_ "wm size" | sed -nE 's/.*(Override|Physical) size: ([0-9]+)x([0-9]+).*/\2 \3/p' | tail -1)
W=${WH% *}; H=${WH#* }; echo "on: ${W}x${H}"
[ "${W:-0}" -gt 2000 ] || { echo "FAIL: display 0 is ${W}x${H}, not the inner screen"; exit 1; }
kg() { sh_ "dumpsys window policy | grep -m1 -E \"mIsShowing=\""; }
if kg | grep -q true; then
  sh_ "wm dismiss-keyguard"; sleep 1.5
  kg | grep -q true && { sh_ "input swipe $((W / 2)) $((H * 9 / 10)) $((W / 2)) $((H / 4)) 300"; sleep 1.5; }
  kg | grep -q true && { echo "the keyguard didn't go (a PIN?) - stopping"; exit 5; }
fi
sh_ "dumpsys window | grep -m1 mCurrentFocus" | grep -qi PowosLock && { sh_ "input swipe $((W / 2)) $((H * 9 / 10)) $((W / 2)) $((H / 4)) 300"; sleep 1.5; }
chk lock
sh_ "am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; sleep 1.5; chk home
sh_ "input swipe $((W * 3 / 10)) $((H / 2)) $((W * 9 / 10)) $((H / 2)) 350"; sleep 1.5; chk ai
probe='JSON.stringify((()=>{const s=document.querySelector(".ai-screen"),q=(c)=>{const e=s&&s.querySelector(c);if(!e)return null;const r=e.getBoundingClientRect();return {l:Math.round(r.left),t:Math.round(r.top),r:Math.round(r.right),b:Math.round(r.bottom),o:getComputedStyle(e).overflowY}};return {w:innerWidth,shown:!!s&&s.classList.contains("shown"),wide:!!s&&s.classList.contains("wide"),talk:q(".ai-talk"),side:q(".ai-side"),pill:q(".ai-compose")}})())'
p=$("$T/cdp.sh" eval home "$probe" 2>&1 | tr -d '\\' | tail -1)
"$T/shot.sh" "$OUT/ai-wide-unfolded.png" >/dev/null 2>&1
sh_ "input swipe $((W * 9 / 10)) $((H / 2)) $((W * 15 / 100)) $((H / 2)) 300"; sleep 1
echo "ai-wide: $p"
restore; trap - EXIT; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"
[ -f "$OUT/ai-wide-unfolded.png" ] && "$T/review-image.sh" "$OUT/ai-wide-unfolded.png" >/dev/null &&
  python3 "$ROOT/lib/ai/agents/powos-agents-cli" task set "$TASK" --image /home/powos/design-qa/ai-wide-unfolded.png >/dev/null 2>&1
python3 - "$p" <<'PY'
import json, sys
try: p = json.loads(sys.argv[1].strip('"'))
except Exception: print("FAIL: no layout read over CDP:", sys.argv[1][:200]); sys.exit(1)
t, s, c = p.get("talk"), p.get("side"), p.get("pill")
bad = [m for ok, m in [
  (p.get("shown"), "the AI page isn't on screen"), (p.get("wide"), f"not wide at {p.get('w')} px"),
  (t and s and t["r"] <= s["l"], "the conversation isn't left of the side pane"),
  (t and c and c["t"] >= t["b"] - 2 and abs(c["l"] - t["l"]) < 4, "the pill isn't under the conversation"),
  (t and s and t["o"] == "auto" and s["o"] == "auto", "the panes don't scroll on their own")] if not ok]
print("FAIL: " + "; ".join(bad) if bad else f"PASS: two panes at {p['w']} px, the pill under the conversation, each pane scrolls")
sys.exit(1 if bad else 0)
PY
