#!/bin/bash
# lanes: emu phone
# nav-strip.sh <cover|inner> [OUT] (board home-black-strip-at-bottom-under-dock-wallpaper): home's wallpaper reaches
# the bottom edge, under the gesture-nav handle - no black rows there (the decor's navigationBarBackground, black by
# Theme.Material's default, sat over the page until ShellActivity made the bars transparent).
# Forces the screen (cmd device_state state 0 = cover/folded, 3 = inner/unfolded), swipes the lock face if up, goes
# home, screencaps (shot.sh), then the pixel check: in each of the bottom 8 rows, >= 70% of pixels near-black (max
# channel < 16) while the row 120 px up is not = a dark strip = FAIL. Also reads the decor's bar views (dumpsys
# activity top): a VISIBLE navigationBarBackground/statusBarBackground with non-zero height is printed.
# Exit 0 pass, 1 fail, 3 a real touch / screen not awake (re-queued), 5 can't run. Injected input only.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"; ROOT=$(cd "$T/../.." && pwd)
SCR=${1:-}; case $SCR in cover) ST=0 ;; inner) ST=3 ;; *) echo "usage: nav-strip.sh <cover|inner> [OUT]"; exit 5 ;; esac
OUT=${2:-$HOME/.cache/powos-verify/nav-strip-$(date +%m%d-%H%M)}; mkdir -p "$OUT"
IMG=nav-strip-$SCR.png
L=$HOME/.cache/powos-verify.lock
TASK=${TASK:-home-wallpaper-edge-to-edge-no-black-strip-under}
sh_() { "$A" shell "su -c '$*'" 2>/dev/null | tr -d '\r'; }
irq() { sh_ "awk '/touch-0/{s+=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9} END{print s}' /proc/interrupts"; }
restore() { sh_ "am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null; cmd device_state state reset"; echo "restored"; }
. "$here/window-lock.sh"; window_lock nav-strip.sh 120
trap 'restore; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"' EXIT
I0=$(irq)
chk() { [ "$(irq)" = "$I0" ] || { echo "STOP: a real touch at $1 - restoring"; exit 3; }; }
s=$(sh_ "dumpsys power | sed -n s/.*mWakefulness=//p | head -1")
[ "$s" = Awake ] || { echo "the screen is $s - not woken (rule); nothing done"; exit 3; }
sh_ "cmd device_state state $ST"; sleep 3; chk fold
# The ON display's size (cover folded, inner unfolded).
WH=$(sh_ "dumpsys display | grep -E \"DisplayDeviceInfo.*state ON\" | head -1" | sed -nE 's/.* ([0-9]+) x ([0-9]+),.*/\1 \2/p')
W=${WH% *}; H=${WH#* }; echo "on: ${W}x${H} ($SCR)"
[ -n "$W" ] && [ "$W" -gt 0 ] 2>/dev/null || { echo "ENV: can't read the ON display's size"; exit 5; }
kg() { sh_ "dumpsys window policy | grep -m1 -E \"mIsShowing=\""; }
if kg | grep -q true; then
  sh_ "wm dismiss-keyguard"; sleep 1.5
  kg | grep -q true && { sh_ "input swipe $((W / 2)) $((H * 9 / 10)) $((W / 2)) $((H / 4)) 300"; sleep 1.5; }
  kg | grep -q true && { echo "ENV: the keyguard didn't go (a PIN?) - stopping"; exit 5; }
fi
sh_ "dumpsys window | grep -m1 mCurrentFocus" | grep -qi PowosLock && { sh_ "input swipe $((W / 2)) $((H * 9 / 10)) $((W / 2)) $((H / 4)) 300"; sleep 1.5; }
chk lock
sh_ "am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; sleep 2; chk home
# Home must be what's in front: a cover capture once showed Magisk (an app left open folded) and "passed".
front() { sh_ "dumpsys window | grep -m1 mCurrentFocus"; }
front | grep -q HomeShell || { sh_ "input keyevent KEYCODE_HOME"; sleep 2; chk home; }
f=$(front); echo "front: ${f##*u0 }"
case $f in *HomeShell*) ;; *) echo "FAIL: home isn't in front on the $SCR screen - nothing checked"; exit 1 ;; esac
bars=$(sh_ "dumpsys activity top" | awk '/ACTIVITY com.powos.app\/andro.marchy.HomeShell/{f=1} f&&/BarBackground/{print; n++} n==2{exit}' | sed -E 's/.*\{[0-9a-f]+ ([A-Z.]+) .* ([0-9]+,[0-9]+-[0-9]+,[0-9]+) .*id\/([a-zA-Z]+).*/\3 \1 \2/')
echo "decor bars: $(echo "$bars" | tr '\n' ';')"
"$T/shot.sh" "$OUT/$IMG" >/dev/null 2>&1 || { echo "FAIL: no screencap of the $SCR screen"; exit 1; }
restore; trap - EXIT; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"
"$T/review-image.sh" "$OUT/$IMG" >/dev/null &&
  python3 "$ROOT/lib/ai/agents/powos-agents-cli" task set "$TASK" --image "/home/powos/design-qa/$IMG" >/dev/null 2>&1
# Uncompressed BMP via sips (no PIL on the Mac): rows bottom-up, 32 bpp BGRA.
sips -s format bmp "$OUT/$IMG" --out "$OUT/${IMG%.png}.bmp" >/dev/null 2>&1 || { echo "FAIL: sips couldn't read $IMG"; exit 1; }
python3 - "$OUT/${IMG%.png}.bmp" "$SCR" <<'PY'
import struct, sys
b = open(sys.argv[1], "rb").read()
off, = struct.unpack_from("<I", b, 10); w, h = struct.unpack_from("<ii", b, 18); bpp, = struct.unpack_from("<H", b, 28)
bp = bpp // 8; stride = (w * bp + 3) & ~3; up = h < 0; h = abs(h)
def row(y):  # y from the top
    i = y if up else h - 1 - y
    r = b[off + i * stride: off + i * stride + w * bp]
    return [max(r[x:x + 3]) for x in range(0, w * bp, bp * 2)]
def dark(y):
    r = row(y); return sum(1 for v in r if v < 16) / len(r)
ref = dark(h - 120)
bottom = [round(dark(y), 2) for y in range(h - 8, h)]
strip = ref < 0.7 and all(d >= 0.7 for d in bottom)
print(f"{sys.argv[2]} {w}x{h}: bottom 8 rows dark fraction {bottom}, row h-120 {ref:.2f}")
print(f"FAIL: a dark strip at the bottom edge of home ({sys.argv[2]})" if strip else
      f"PASS: home's wallpaper reaches the bottom edge ({sys.argv[2]}, no dark rows under the nav handle)")
sys.exit(1 if strip else 0)
PY
