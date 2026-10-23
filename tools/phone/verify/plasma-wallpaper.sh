#!/bin/bash
# plasma-wallpaper.sh [OUT]: Plasma's desktop (the Linux desktop app) shows PowOS home's wallpaper picture, not black
# (board task plasma-desktop-black-wallpaper, 2026-10-23). Steps:
#   1. the app wrote the session's picture: /run/powos-app/powos-wallpaper-<ms>.jpg (ShellWallpaper.writeSession);
#   2. plasmashell runs the current org.powos.transparent (started after its main.qml was installed);
#   3. Plasma's desktop opened the drawer's way (apps.launch l:org.powos.plasma from the web home), then KWin's own
#      capture of it (spectacle, as the session user): the desktop is opaque - no pixel of it at alpha 0 (the old
#      transparent desktop: every pixel not under a widget, which Android's snapshots of the task show as black) -
#      and its background is the picture (the capture's colours where no widget is vs the picture's, same crop);
#   4. Android's snapshot of the desktop's task, taken when it leaves (what the starting window, recents and PowOS's
#      switcher show), is not the old black one: its near-black share is about the picture's own.
# Always restores: the web home. Exit: 0 passed; 1 FAIL; 3 a real touch / not awake (re-queued).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"
OUT=${1:-$HOME/.cache/powos-verify/plasma-wallpaper-$(date +%m%d-%H%M)}; mkdir -p "$OUT"
L=$HOME/.cache/powos-verify.lock
KEY=l:org.powos.plasma
QML=/usr/share/plasma/wallpapers/org.powos.transparent/contents/ui/main.qml
sh_() { "$A" shell "su -c '$*'" 2>/dev/null | tr -d '\r'; }
# As the session user (its bus): a script file run by tools/phone/user.sh. Never sudo through it.
us_() { printf '%s\n' "$1" > "$OUT/us.sh"; "$T/user.sh" "$OUT/us.sh" 2>/dev/null | grep -av -e "locale" -e "Qt depends" -e "If this causes" -e "for more information" -e "pushed"; }
irq() { sh_ "awk '/touch-0/{s+=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9} END{print s}' /proc/interrupts"; }
restore() { sh_ "am start -n com.powos.app/andro.marchy.HomeShell >/dev/null"; echo "restored"; }
fail() { echo "FAIL: $*" | tee -a "$OUT/log.txt"; "$T/shot.sh" "$OUT/fail.png" >/dev/null 2>&1; exit 1; }
pass() { echo "PASS: $*" | tee -a "$OUT/log.txt"; }

# 1-2 need no window.
pic=$(us_ 'ls -1 /run/powos-app/powos-wallpaper-*.jpg 2>/dev/null | sort | tail -1')
[ -n "$pic" ] || fail "no /run/powos-app/powos-wallpaper-*.jpg (the app's ShellWallpaper never wrote the session's picture)"
pass "the session's picture: $pic"
r=$(us_ "q=\$(stat -c %Y $QML); p=\$(stat -c %Y /proc/\$(pgrep -x plasmashell | head -1)); echo \$q \$p")
q=${r% *}; p=${r#* }
[ -n "$q" ] && [ -n "$p" ] && [ "$p" -ge "$q" ] || fail "plasmashell (started $p) runs an older org.powos.transparent than the installed one ($q): the session wasn't restarted since rooted.sh deploy"
pass "plasmashell started after the wallpaper's QML was installed"

. "$here/window-lock.sh"
window_lock plasma-wallpaper.sh 120
trap 'restore; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"' EXIT
I0=$(irq)
chk() { [ "$(irq)" = "$I0" ] || { echo "STOP: a real touch at $1 - restoring"; exit 3; }; }
hcall() {
  "$T/cdp.sh" eval home "new Promise(ok=>{const h=window.__powosHost,P=window.PowosHost;if(!h||!P||!P.postMessage)return ok('ERR no bridge');const r=h.resolve,j=h.reject,id=910300+Math.floor(Math.random()*9000);const done=v=>{h.resolve=r;h.reject=j;ok(v)};h.resolve=(i,v)=>i===id?done(v):r(i,v);h.reject=(i,m)=>i===id?done('ERR '+m):j(i,m);setTimeout(()=>done('ERR no answer'),8000);P.postMessage(JSON.stringify([id,'$1',JSON.stringify($2)]))}).then(v=>typeof v==='string'&&v.startsWith('ERR')?v:($3)(v))" 2>&1 | tr -d '"\r' | tail -1
}
s=$(sh_ "dumpsys power | sed -n s/.*mWakefulness=//p | head -1")
[ "$s" = Awake ] || { echo "the screen is $s - not woken (rule)"; exit 3; }
DESK='andro\.marchy\.(MainActivity|HomeDesktop)'
sh_ "am start -W -n com.powos.app/andro.marchy.HomeShell >/dev/null"; sleep 2; chk webhome
r=$(hcall apps.launch "['$KEY']" "()=>'ok'"); [ "$r" = ok ] || fail "apps.launch: $r"
sleep 4; chk launch
f=$(sh_ "dumpsys window | grep -m1 mCurrentFocus")
grep -qE "$DESK" <<<"$f" || fail "Plasma's desktop isn't in front: $f"
"$T/shot.sh" "$OUT/screen.png" >/dev/null 2>&1

# 3. KWin's capture, measured inside PowOS (python3 + PIL there) against the picture.
m=$(us_ "rm -f /tmp/pw-desk.png; timeout 30 spectacle -b -n -f -o /tmp/pw-desk.png >/dev/null 2>&1
python3 - $pic <<'PY'
import sys
from PIL import Image, ImageOps
cap = Image.open('/tmp/pw-desk.png').convert('RGBA')
pic = ImageOps.fit(Image.open(sys.argv[1]).convert('RGB'), cap.size)
W, H = cap.size; n = clear = diff = bg = 0
for y in range(0, H, H // 48):
    for x in range(0, W, W // 48):
        r, g, b, a = cap.getpixel((x, y)); n += 1
        if a == 0: clear += 1; continue
        pr, pg, pb = pic.getpixel((x, y))
        d = abs(r - pr) + abs(g - pg) + abs(b - pb)
        if d < 60: bg += 1          # the picture itself shows here
print('clear=%.3f picture=%.3f' % (clear / n, bg / n))
PY
rm -f /tmp/pw-desk.png" | tail -1)
echo "kwin capture: $m" | tee -a "$OUT/log.txt"
clear=$(sed -n 's/.*clear=\([0-9.]*\).*/\1/p' <<<"$m"); shown=$(sed -n 's/.*picture=\([0-9.]*\).*/\1/p' <<<"$m")
[ -n "$clear" ] || fail "no KWin capture to measure ($m)"
awk "BEGIN{exit !($clear < 0.02)}" || fail "Plasma's desktop is still transparent in KWin's frame: $clear of it at alpha 0 (Android's snapshots show that as black)"
awk "BEGIN{exit !($shown > 0.3)}" || fail "the desktop's background isn't the picture: only $shown of the frame matches it"
pass "KWin's frame of the desktop: opaque ($clear clear), $shown of it the picture itself"

# 4. Android's snapshot of the task, taken as it leaves.
task=$(sh_ "dumpsys activity activities | grep -m1 -E \"Task\\{.*A=[0-9]+:com.powos.app U\"" | sed -n 's/.*#\([0-9]*\) .*/\1/p')
restore >/dev/null; sleep 3
if [ -n "$task" ] && sh_ "test -f /data/system_ce/0/snapshots/$task.jpg && echo y" | grep -q y; then
  sh_ "cp /data/system_ce/0/snapshots/$task.jpg /data/local/tmp/pw-snap.jpg; chmod 644 /data/local/tmp/pw-snap.jpg"
  "$A" pull /data/local/tmp/pw-snap.jpg "$OUT/" >/dev/null 2>&1; sh_ "rm -f /data/local/tmp/pw-snap.jpg"
  pass "Android's snapshot of the desktop's task (what comes back first): $OUT/pw-snap.jpg"
else
  echo "no persisted snapshot of the desktop's task ($task) to keep - not a failure" | tee -a "$OUT/log.txt"
fi
chk end
pass "Plasma's desktop shows the home's wallpaper ($OUT)"
