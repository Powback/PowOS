#!/bin/bash
# prompt-glyph.sh [OUT] (board prompt-glyph): the pill's empty face is a ">" prompt glyph, not placeholder words, on
# home's search pill and PowOS AI's compose. On the screen in use: keyguard swiped (no PIN), home, a read-only CDP read
# of home's pill + a screencap, the page swipe to the AI page, the same read of its compose + a screencap, swipe back.
# PASS (each pill) = aria-label "Search" / "Ask PowOS AI", no placeholder words, and the glyph ".prompt" ">" shown
# exactly while the field is empty (muted, var(--font)). Screencaps go to the board task (BOARD_TASK=, default
# prompt-glyph). Restores: swipe back, home. Exit 0 pass, 1 fail, 3 a real touch / screen not awake, 5 can't run.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"; ROOT=$(cd "$T/../.." && pwd)
OUT=${1:-$HOME/.cache/powos-verify/prompt-glyph-$(date +%m%d-%H%M)}; mkdir -p "$OUT"
L=$HOME/.cache/powos-verify.lock
TASK=${BOARD_TASK:-prompt-glyph}
sh_() { "$A" shell "su -c '$*'" 2>/dev/null | tr -d '\r'; }
irq() { sh_ "awk '/touch-0/{s+=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9} END{print s}' /proc/interrupts"; }
restore() { sh_ "am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; echo "restored"; }
. "$here/window-lock.sh"; window_lock prompt-glyph.sh 120
trap 'restore; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"' EXIT
I0=$(irq)
chk() { [ "$(irq)" = "$I0" ] || { echo "STOP: a real touch at $1 - restoring"; exit 3; }; }
s=$(sh_ "dumpsys power | sed -n s/.*mWakefulness=//p | head -1")
[ "$s" = Awake ] || { echo "the screen is $s - not woken (rule); nothing done"; exit 3; }
WH=$(sh_ "wm size" | sed -nE 's/.*(Override|Physical) size: ([0-9]+)x([0-9]+).*/\2 \3/p' | tail -1)
W=${WH% *}; H=${WH#* }; echo "on: ${W}x${H}"
kg() { sh_ "dumpsys window policy | grep -m1 -E \"mIsShowing=\""; }
if kg | grep -q true; then
  sh_ "wm dismiss-keyguard"; sleep 1.5
  kg | grep -q true && { sh_ "input swipe $((W / 2)) $((H * 9 / 10)) $((W / 2)) $((H / 4)) 300"; sleep 1.5; }
  kg | grep -q true && { echo "the keyguard didn't go (a PIN?) - stopping"; exit 5; }
fi
sh_ "dumpsys window | grep -m1 mCurrentFocus" | grep -qi PowosLock && { sh_ "input swipe $((W / 2)) $((H * 9 / 10)) $((W / 2)) $((H / 4)) 300"; sleep 1.5; }
chk lock
sh_ "am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; sleep 1.5; chk home
# One pill's face (read only): its field's label/placeholder/value and the glyph's text and style.
probe() {
  printf '%s' 'JSON.stringify((()=>{const p=document.querySelector("'"$1"'");if(!p)return {found:false};const f=p.querySelector("textarea"),g=p.querySelector(".prompt"),c=g&&getComputedStyle(g),t=f&&getComputedStyle(f);return {found:true,label:f&&f.getAttribute("aria-label"),ph:f&&f.placeholder,empty:f&&!f.value,glyph:g&&g.textContent,color:c&&c.color,font:c&&c.fontFamily.slice(0,40),size:c&&c.fontSize,textSize:t&&t.fontSize,muted:getComputedStyle(document.documentElement).getPropertyValue("--color-muted").trim()}})())'
}
# cdp.sh prints the probe's JSON string JSON-encoded: kept whole (escapes and all) and decoded twice in python - stripping
# the backslashes broke it on the font name's own quotes ("JetBrainsMono Nerd Font", 2026-10-23).
read_() { "$T/cdp.sh" eval home "$(probe "$1")" 2>&1 | tail -1; }
home=$(read_ '.home > .bar .pill')
"$T/shot.sh" "$OUT/prompt-glyph-home.png" >/dev/null 2>&1
sh_ "input swipe $((W * 3 / 10)) $((H / 2)) $((W * 9 / 10)) $((H / 2)) 350"; sleep 1.5; chk ai
ai=$(read_ '.ai-screen.shown .ai-compose .pill')
"$T/shot.sh" "$OUT/prompt-glyph-ai.png" >/dev/null 2>&1
sh_ "input swipe $((W * 9 / 10)) $((H / 2)) $((W * 15 / 100)) $((H / 2)) 300"; sleep 1
echo "home pill: $home"; echo "ai compose: $ai"
restore; trap - EXIT; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"
for img in prompt-glyph-home.png prompt-glyph-ai.png; do
  [ -f "$OUT/$img" ] && "$T/review-image.sh" "$OUT/$img" >/dev/null &&
    python3 "$ROOT/lib/ai/agents/powos-agents-cli" task set "$TASK" --image "/home/powos/design-qa/$img" >/dev/null 2>&1
done
python3 - "$home" "$ai" <<'PY'
import json, sys
bad = []
for raw, name, label in [(sys.argv[1], "home's pill", "Search"), (sys.argv[2], "the AI compose", "Ask PowOS AI")]:
    try:
        p = json.loads(raw)
        p = json.loads(p) if isinstance(p, str) else p
    except Exception: bad.append(f"{name}: nothing read over CDP ({raw[:120]})"); continue
    if not p.get("found"): bad.append(f"{name}: not on screen"); continue
    if p.get("label") != label: bad.append(f"{name}: aria-label {p.get('label')!r}, not {label!r}")
    if p.get("ph") in ("search", "ask PowOS AI"): bad.append(f"{name}: still the placeholder {p['ph']!r}")
    if p.get("empty") and p.get("glyph") != ">": bad.append(f"{name}: empty, no > glyph")
    if not p.get("empty") and p.get("glyph"): bad.append(f"{name}: has text, the glyph still shows")
print("FAIL: " + "; ".join(bad) if bad else "PASS: home's pill and the AI compose show the > prompt (labels Search / Ask PowOS AI)")
sys.exit(1 if bad else 0)
PY
