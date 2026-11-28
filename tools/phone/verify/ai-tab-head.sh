#!/bin/bash
# lanes: emu phone
# ai-tab-head.sh [cover|inner] [OUT] (board ai-page-agents-progress-devices-tabs-cut-off-at): on the PowOS AI page, each
# bottom tab (Agents, Progress, Devices) opens its screen with ONE header - back, the tab's name, a glance - under the
# status bar, whole, and the tab strip whole on screen (the headless twin: shell/dev/ai-tab-head-check.js, gate
# ai-tab-head-*). Screen: cover (default, cmd device_state state 0) or inner (3). Dismisses the keyguard / swipes the
# lock face (no PIN), home, the page swipe to the AI page, then per tab: reads the tab's rect over CDP (read only), taps
# it (injected), reads the layout, screencaps. BOARD_TASK= names the task its screencaps go to. Restores: the Chat
# tab, swipe back, home, `cmd device_state state reset`.
# Exit 0 pass, 1 fail, 3 a real touch / screen not awake (re-queued), 5 can't run. Injected input only.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"; ROOT=$(cd "$T/../.." && pwd)
SCREEN=cover; case "${1:-}" in cover | inner) SCREEN=$1; shift ;; esac
OUT=${1:-$HOME/.cache/powos-verify/ai-tab-head-$SCREEN-$(date +%m%d-%H%M)}; mkdir -p "$OUT"
L=$HOME/.cache/powos-verify.lock
TASK=${BOARD_TASK:-ai-page-agents-progress-devices-tabs-cut-off-at}
. "$here/base.sh"  # sh_ and the shared check helpers (tools/phone/verify/base.sh)
irq() { sh_ "awk '/touch-0/{s+=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9} END{print s}' /proc/interrupts"; }
cdp() { "$T/cdp.sh" eval home "$1" 2>&1 | tr -d '\\' | tail -1 | sed 's/^"//; s/"$//'; }
restore() { sh_ "am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null; cmd device_state state reset"; echo "restored"; }
. "$here/window-lock.sh"; window_lock ai-tab-head.sh 150
trap 'restore; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"' EXIT
I0=$(irq)
chk() { [ "$(irq)" = "$I0" ] || { echo "STOP: a real touch at $1 - restoring"; exit 3; }; }
s=$(sh_ "dumpsys power | sed -n s/.*mWakefulness=//p | head -1")
[ "$s" = Awake ] || { echo "the screen is $s - not woken (rule); nothing done"; exit 3; }
[ "$SCREEN" = inner ] && sh_ "cmd device_state state 3" || sh_ "cmd device_state state 0"
sleep 3; chk fold
WH=$(sh_ "wm size" | sed -nE 's/.*(Override|Physical) size: ([0-9]+)x([0-9]+).*/\2 \3/p' | tail -1)
W=${WH% *}; H=${WH#* }; echo "on: ${W}x${H} ($SCREEN)"
kg() { sh_ "dumpsys window policy | grep -m1 -E \"mIsShowing=\""; }
if kg | grep -q true; then
  sh_ "wm dismiss-keyguard"; sleep 1.5
  kg | grep -q true && { sh_ "input swipe $((W / 2)) $((H * 9 / 10)) $((W / 2)) $((H / 4)) 300"; sleep 1.5; }
  kg | grep -q true && { echo "ENV: the keyguard didn't go (a PIN?) - stopping"; exit 5; }
fi
sh_ "dumpsys window | grep -m1 mCurrentFocus" | grep -qi PowosLock && { sh_ "input swipe $((W / 2)) $((H * 9 / 10)) $((W / 2)) $((H / 4)) 300"; sleep 1.5; }
chk lock
sh_ "am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; sleep 1.5; chk home
sh_ "input swipe $((W * 3 / 10)) $((H / 2)) $((W * 9 / 10)) $((H / 2)) 350"; sleep 1.5; chk ai
# The tab named $1's centre in screen pixels (x y, its JSON quotes dropped: kept, `input tap "x y"` got one argument and
# never tapped - the 11-24 emulator FAIL, Chat still open on all three tabs), from the live page (read only).
seg() { cdp 'JSON.stringify((()=>{const b=[...document.querySelectorAll(".ai-screen.shown .ai-seg")].find((e)=>e.textContent.trim().startsWith("'"$1"'"));if(!b)return "";const r=b.getBoundingClientRect();return Math.round((r.left+r.width/2)*devicePixelRatio)+" "+Math.round((r.top+r.height/2)*devicePixelRatio)})())' | tr -d '"'; }
# The open screen's header and the tab strip against the status bar.
probe='JSON.stringify((()=>{const s=document.querySelector(".ai-screen.shown"),R=(e)=>{if(!e)return null;const r=e.getBoundingClientRect();return {t:Math.round(r.top*10)/10,b:Math.round(r.bottom*10)/10,h:Math.round(r.height)}};const hs=s?[...s.querySelectorAll(".ag-top")].filter((h)=>h.getBoundingClientRect().height>0):[];const h=hs[0];return {shown:!!s,inset:parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--inset-top"))||0,ih:innerHeight,n:hs.length,title:h?.querySelector(".ai-title")?.textContent.trim()??"",head:R(h),back:R(h?.querySelector(".session-back")),segs:R(s?.querySelector(".ai-segs"))}})())'
res=()
for tab in Agents Progress Devices; do
  xy=$(seg $tab)
  [ -n "$xy" ] || { res+=("$tab {\"shown\":false}"); continue; }
  sh_ "input tap $xy"; sleep 1.2; chk "$tab tab"
  res+=("$tab $(cdp "$probe")")
  "$T/shot.sh" "$OUT/ai-tab-head-$SCREEN-$(echo "$tab" | tr A-Z a-z).png" >/dev/null 2>&1
done
xy=$(seg Chat); [ -n "$xy" ] && { sh_ "input tap $xy"; sleep 0.8; }
sh_ "input swipe $((W * 9 / 10)) $((H / 2)) $((W * 15 / 100)) $((H / 2)) 300"; sleep 1
restore; trap - EXIT; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"
for f in "$OUT"/ai-tab-head-$SCREEN-*.png; do
  [ -f "$f" ] && "$T/review-image.sh" "$f" >/dev/null &&
    python3 "$ROOT/lib/ai/agents/powos-agents-cli" task set "$TASK" --image "/home/powos/design-qa/$(basename "$f")" >/dev/null 2>&1
done
printf '%s\n' "${res[@]}"
# The judge reads one "<tab> <json>" line per tab. Held in a quoted heredoc so the Python needs no shell escapes.
judge=$(cat <<'PY'
import json, sys
bad = []
for line in sys.stdin:
    tab, _, raw = line.strip().partition(" ")
    try: p = json.loads(raw)
    except Exception: bad.append(f"{tab}: no layout read over CDP ({raw[:120]})"); continue
    if not p.get("shown"): bad.append(f"{tab}: the AI page or its tab is not on screen"); continue
    i, h, b, s = p["inset"], p["head"], p["back"], p["segs"]
    if p["n"] != 1: bad.append(f"{tab}: {p['n']} headers, want 1"); continue
    if p["title"] != tab: bad.append(f"{tab}: the header says {p['title']!r}")
    if h["t"] < i - 0.5 or (b and b["t"] < i - 0.5): bad.append(f"{tab}: the header (top {h['t']}) is under the status bar ({i})")
    if not s or s["t"] < i - 0.5 or s["b"] > p["ih"] + 0.5: bad.append(f"{tab}: the tab strip is cut off ({s} in {p['ih']})")
print("FAIL: " + "; ".join(bad) if bad else "PASS: Agents, Progress and Devices each open under one header below the status bar, the tab strip whole")
sys.exit(1 if bad else 0)
PY
)
printf '%s\n' "${res[@]}" | python3 -c "$judge"
