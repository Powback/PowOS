#!/bin/bash
# lanes: emu phone
# chat-polish.sh [OUT] (board agent-mail-in-chat-as-tidy-folded-cards): the pill's gap above the keyboard on the AI page
# and in the AI pull-up panel (home's bar folded, the panel's own pill when wide), and agents' mail folded to one line.
# On the screen the phone is on. Home, the page swipe to the AI page, a tap on its pill (the keyboard comes up), reads the
# layout over CDP (read only), screencap, Back; then home, the pull-up panel (a swipe up on home's left half), the same.
# PASS = the pill's bottom 8..16 CSS px above the keyboard in both, every folded .mail card at most 44 px tall.
# Restores: Back (keyboard), home. Exit 0 pass, 1 fail, 3 a real touch / screen not awake (re-queued), 5 can't run.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"; ROOT=$(cd "$T/../.." && pwd)
OUT=${1:-$HOME/.cache/powos-verify/chat-polish-$(date +%m%d-%H%M)}; mkdir -p "$OUT"
L=$HOME/.cache/powos-verify.lock
TASK=agent-mail-in-chat-as-tidy-folded-cards
sh_() { "$A" shell "su -c '$*'" 2>/dev/null | tr -d '\r'; }
irq() { sh_ "awk '/touch-0/{s+=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9} END{print s}' /proc/interrupts"; }
home() { sh_ "am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; sleep 1.5; }
restore() { sh_ "input keyevent 4"; sleep 0.5; home; echo "restored"; }
. "$here/window-lock.sh"; window_lock chat-polish.sh 120
trap 'restore; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"' EXIT
I0=$(irq)
chk() { [ "$(irq)" = "$I0" ] || { echo "STOP: a real touch at $1 - restoring"; exit 3; }; }
s=$(sh_ "dumpsys power | sed -n s/.*mWakefulness=//p | head -1")
[ "$s" = Awake ] || { echo "the screen is $s - not woken (rule); nothing done"; exit 3; }
sh_ "dumpsys window policy | grep -m1 -E \"mIsShowing=\"" | grep -q true && { echo "locked - stopping"; exit 5; }
WH=$(sh_ "wm size" | sed -nE 's/.*(Override|Physical) size: ([0-9]+)x([0-9]+).*/\2 \3/p' | tail -1)
W=${WH% *}; H=${WH#* }; echo "on: ${W}x${H}"
# The visible pill under SEL: the scope's own .ai-compose, else home's bar pill. Its rect, the keyboard inset, the mail.
probe() {
  "$T/cdp.sh" eval home 'JSON.stringify((()=>{const s=document.querySelector("'"$1"'");if(!s)return {shown:false};const h=s.closest(".home");const p=s.querySelector(".ai-compose")||(h&&h.querySelector(":scope > .bar .bar-pill"));const r=p&&p.getBoundingClientRect();const kb=parseFloat(document.documentElement.style.getPropertyValue("--inset-keyboard"))||0;return {shown:true,w:innerWidth,h:innerHeight,kb:kb,pill:r?{x:Math.round(r.left+r.width/2),y:Math.round(r.top+r.height/2),b:Math.round(r.bottom)}:null,mail:[...s.querySelectorAll(".mail:not(.open)")].map(m=>Math.round(m.getBoundingClientRect().height))}})())' 2>&1 | tr -d '\\' | tail -1
}
tap_pill() { # $1 = probe JSON: tap the pill's centre (CSS px -> device px)
  python3 -c 'import json,sys;p=json.loads(sys.argv[1].strip("\""));d=int(sys.argv[2])/p["w"];print(round(p["pill"]["x"]*d),round(p["pill"]["y"]*d))' "$1" "$W" 2>/dev/null
}
measure() { # $1 name, $2 selector -> echoes the probe with the keyboard up
  local before xy after
  before=$(probe "$2"); xy=$(tap_pill "$before")
  [ -n "$xy" ] || { echo "$before"; return; }
  sh_ "input tap $xy"; sleep 2; chk "$1"
  after=$(probe "$2"); "$T/shot.sh" "$OUT/chat-polish-$1.png" >/dev/null 2>&1
  sh_ "input keyevent 4"; sleep 1
  echo "$after"
}
home; chk home
sh_ "input swipe $((W * 3 / 10)) $((H / 2)) $((W * 9 / 10)) $((H / 2)) 350"; sleep 1.5; chk page
P1=$(measure page ".ai-screen.shown")
sh_ "input swipe $((W * 9 / 10)) $((H / 2)) $((W * 15 / 100)) $((H / 2)) 300"; sleep 1
home; chk home2
sh_ "input swipe $((W / 4)) $((H * 72 / 100)) $((W / 4)) $((H * 28 / 100)) 220"; sleep 1.5; chk panel
P2=$(measure panel ".home.open .ai-panel")
echo "page: $P1"; echo "panel: $P2"
restore; trap - EXIT; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"
for f in "$OUT"/chat-polish-*.png; do
  [ -f "$f" ] && "$T/review-image.sh" "$f" >/dev/null &&
    python3 "$ROOT/lib/ai/agents/powos-agents-cli" task set "$TASK" --image "/home/powos/design-qa/$(basename "$f")" >/dev/null 2>&1
done
python3 - "$P1" "$P2" <<'PY'
import json, sys
bad, ok = [], []
for name, raw in zip(("AI page", "panel"), sys.argv[1:]):
    try: p = json.loads(raw.strip('"'))
    except Exception: bad.append(f"{name}: no layout read over CDP ({raw[:120]})"); continue
    if not p.get("shown") or not p.get("pill"): bad.append(f"{name}: not on screen / no pill"); continue
    if p["kb"] <= 0: bad.append(f"{name}: the keyboard didn't come up"); continue
    gap = (p["h"] - p["kb"]) - p["pill"]["b"]
    (ok if 8 <= gap <= 16 else bad).append(f"{name}: pill {gap} px above the keyboard")
    tall = [h for h in p["mail"] if h > 44]
    if tall: bad.append(f"{name}: folded mail cards {tall} px tall")
    elif p["mail"]: ok.append(f"{name}: {len(p['mail'])} folded mail cards one line")
print(("FAIL: " + "; ".join(bad)) if bad else "PASS: " + "; ".join(ok))
sys.exit(1 if bad else 0)
PY
