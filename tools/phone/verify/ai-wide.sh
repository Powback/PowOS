#!/bin/bash
# ai-wide.sh [--panel] [OUT] (board ai-page-two-pane-wide-layout): PowOS AI on the INNER screen is two panes - its
# page (default) or, --panel, its pull-up panel on home (a swipe up from home's left half; the same AiView). Forces the
# inner screen (cmd device_state state 3, as unfolded-checks.sh), dismisses the keyguard / swipes the lock face (no PIN),
# home, the page swipe to the AI page, then reads the layout over CDP (read only) and screencaps it.
# PASS = .ai-screen.wide / .ai-panel.wide, the side pane (.ai-side) left of the conversation (.ai-talk), the pill under it,
# both panes their own scroll (overflow-y auto), the conversation unfolded and at the newest. BOARD_TASK= names the
# task its screencap goes to. Restores: swipe back, home, `cmd device_state state reset`.
# Exit 0 pass, 1 fail, 3 a real touch / screen not awake (re-queued), 5 can't run. Injected input only.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"; ROOT=$(cd "$T/../.." && pwd)
MODE=page; [ "${1:-}" = --panel ] && { MODE=panel; shift; }
OUT=${1:-$HOME/.cache/powos-verify/ai-wide-$MODE-$(date +%m%d-%H%M)}; mkdir -p "$OUT"
IMG=ai-wide-$MODE-unfolded.png
L=$HOME/.cache/powos-verify.lock
TASK=${BOARD_TASK:-ai-page-two-pane-wide-layout}
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
if [ $MODE = panel ]; then
  sh_ "input swipe $((W / 4)) $((H * 72 / 100)) $((W / 4)) $((H * 28 / 100)) 220"; sleep 1.5; chk ai
  SEL='.home.open .ai-panel'
else
  sh_ "input swipe $((W * 3 / 10)) $((H / 2)) $((W * 9 / 10)) $((H / 2)) 350"; sleep 1.5; chk ai
  SEL='.ai-screen.shown'
fi
probe='JSON.stringify((()=>{const s=document.querySelector("'"$SEL"'"),q=(c)=>{const e=s&&s.querySelector(c);if(!e)return null;const r=e.getBoundingClientRect();return {l:Math.round(r.left),t:Math.round(r.top),r:Math.round(r.right),b:Math.round(r.bottom),o:getComputedStyle(e).overflowY}};return {w:innerWidth,shown:!!s,wide:!!s&&s.classList.contains("wide"),talk:q(".ai-talk"),side:q(".ai-side"),pill:q(".ai-compose"),hist:(()=>{const t=s&&s.querySelector(".ai-talk");return t&&{fold:!!t.querySelector(".ai-fold"),asks:t.querySelectorAll(".ai-history-list .msg.user").length,bare:[...t.querySelectorAll(".msg")].filter((m)=>{const c=m.closest(".tile"),k=c&&getComputedStyle(c);return !k||(k.backgroundImage==="none"&&/^(transparent|rgba\(0, 0, 0, 0\))$/.test(k.backgroundColor))}).length,st:Math.round(t.scrollTop),sh:t.scrollHeight,ch:t.clientHeight}})()}})())'
p=$("$T/cdp.sh" eval home "$probe" 2>&1 | tr -d '\\' | tail -1)
"$T/shot.sh" "$OUT/$IMG" >/dev/null 2>&1
[ $MODE = page ] && { sh_ "input swipe $((W * 9 / 10)) $((H / 2)) $((W * 15 / 100)) $((H / 2)) 300"; sleep 1; }
echo "ai-wide $MODE: $p"
restore; trap - EXIT; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"
[ -f "$OUT/$IMG" ] && "$T/review-image.sh" "$OUT/$IMG" >/dev/null &&
  python3 "$ROOT/lib/ai/agents/powos-agents-cli" task set "$TASK" --image "/home/powos/design-qa/$IMG" >/dev/null 2>&1
python3 - "$p" "$MODE" <<'PY'
import json, sys
try: p = json.loads(sys.argv[1].strip('"'))
except Exception: print("FAIL: no layout read over CDP:", sys.argv[1][:200]); sys.exit(1)
t, s, c, h = p.get("talk"), p.get("side"), p.get("pill"), p.get("hist")
bad = [m for ok, m in [
  (p.get("shown"), f"the AI {sys.argv[2]} isn't on screen"), (p.get("wide"), f"not wide at {p.get('w')} px"),
  (t and s and s["r"] <= t["l"], "the side pane isn't left of the conversation"),
  (t and c and c["t"] >= t["b"] - 2 and abs(c["l"] - t["l"]) < 4, "the pill isn't under the conversation"),
  (t and s and t["o"] == "auto" and s["o"] == "auto", "the panes don't scroll on their own"),
  # The whole conversation, no "earlier" fold; it opens at the newest (column-reverse: scrollTop 0 is the bottom).
  (h and not h["fold"], "the conversation is folded ('earlier')"),
  # Every message on a frosted surface (2026-10-23: the history's sat bare on the wallpaper, unreadable over a bright one).
  (h and not h.get("bare"), f"{h and h.get('bare')} messages have no frost surface behind them"),
  (h and (abs(h["st"]) < 4 or h["sh"] <= h["ch"]), f"the conversation isn't at the newest: {h}")] if not ok]
print("FAIL: " + "; ".join(bad) if bad else f"PASS: the {sys.argv[2]}: two panes at {p['w']} px, the pill under the conversation, each pane scrolls, the whole conversation at the newest ({h and h['asks']} earlier asks drawn)")
sys.exit(1 if bad else 0)
PY
