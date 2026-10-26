#!/bin/bash
# lanes: phone
# plasma-transparent.sh [OUT]: Plasma's desktop (the Linux desktop app) is TRANSPARENT over the real PowOS wallpaper
# (board task "Plasma transparent again", 2026-10-23). Guards against the regression of cb40fa50, where
# org.powos.transparent drew its own copy of the wallpaper: a second crystal at another scale and offset (KWin at
# scale 2.25), black over the top, instead of the wallpaper and frost behind the app. Steps:
#   1. the installed org.powos.transparent draws nothing (no Image/FolderListModel in its main.qml), and plasmashell
#      runs it (started after the QML was installed; if not, it is restarted here, inside the free window);
#   2. a screenshot of PowOS home (the web home: its wallpaper region), then Plasma's desktop opened the drawer's way
#      (apps.launch l:org.powos.plasma), its screenshot and KWin's own capture (spectacle, with alpha);
#   3. KWin's frame: a good share of the desktop is at alpha 0 (transparent: no picture of its own);
#   4. where KWin's frame is transparent and home shows lit wallpaper, the Plasma screenshot's pixels are home's
#      (same wallpaper, same place; both shots box-downscaled 8x so frost/blur and small UI don't count), and not black.
#      Home's own UI is no reference (2026-10-24: the 0.117 "black" of the 10-23 FAIL was home's widgets and status bar
#      text - lit - over the wallpaper's black sky; the desktop showed the wallpaper right): cells under anything home's
#      page paints (its rects, read-only over CDP) and the status bar band are left out, and so are cells where the live
#      (video) wallpaper changed between the home shots before and after (OxygenOS's plays a clip on unlock/fold);
#   5. SurfaceFlinger composes the wallpaper directly under the desktop's surface, and that surface is translucent:
#      nothing between them could show black.
# WARNING (f92, 2026-10-24): the reference shot for this check (and any check comparing against a screenshot) must
# never include pixels the check's OWN UI draws (home's widgets, status bar) or pixels a LIVE source can change on
# its own (the video wallpaper plays unprompted) - either one fails the comparison for reasons that have nothing to
# do with transparency. Step 4 is where that's excluded; touch it only to exclude MORE, never less.
# Always restores: the web home. Exit: 0 passed; 1 FAIL; 3 a real touch / not awake (re-queued).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"
OUT=${1:-$HOME/.cache/powos-verify/plasma-transparent-$(date +%m%d-%H%M)}; mkdir -p "$OUT"
L=$HOME/.cache/powos-verify.lock
KEY=l:org.powos.plasma
QML=/usr/share/plasma/wallpapers/org.powos.transparent/contents/ui/main.qml
PT=/data/powos/root/tmp   # the chroot's /tmp, seen from Android
sh_() { "$A" shell "su -c '$*'" 2>/dev/null | tr -d '\r'; }
# As the session user (its bus): a script file run by tools/phone/user.sh. Never sudo through it.
us_() { printf '%s\n' "$1" > "$OUT/us.sh"; "$T/user.sh" "$OUT/us.sh" 2>/dev/null | grep -av -e "locale" -e "Qt depends" -e "If this causes" -e "for more information" -e "pushed"; }
irq() { sh_ "awk '/touch-0/{s+=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9} END{print s}' /proc/interrupts"; }
restore() { sh_ "am start -n com.powos.app/andro.marchy.HomeShell >/dev/null"; sh_ "rm -f $PT/pt-home.png $PT/pt-home2.png $PT/pt-desk.png $PT/pt-kwin.png $PT/pt-ui.txt"; echo "restored"; }
# A file in the chroot (root-only dirs) to OUT on the Mac: the shots stay as evidence.
pull() { sh_ "cp $PT/$1 /data/local/tmp/pt-pull && chmod 644 /data/local/tmp/pt-pull"; "$A" pull /data/local/tmp/pt-pull "$OUT/$1" >/dev/null 2>&1; sh_ "rm -f /data/local/tmp/pt-pull"; }
# Everything home's page paints (backgrounds, text, images, glass) in screen pixels, "l,t,r,b" each: no wallpaper there.
UIJS='(()=>{const d=devicePixelRatio,r=[];for(const e of document.querySelectorAll("body *")){const s=getComputedStyle(e);if(s.visibility!=="visible"||+s.opacity===0)continue;const b=e.getBoundingClientRect();if(b.width<2||b.height<2||b.bottom<0||b.top>innerHeight)continue;const bg=s.backgroundColor,txt=[...e.childNodes].some(n=>n.nodeType===3&&n.textContent.trim());if((bg&&bg!=="transparent"&&!/, *0\)$/.test(bg))||s.backgroundImage!=="none"||(s.backdropFilter&&s.backdropFilter!=="none")||/^(IMG|svg|CANVAS|VIDEO)$/.test(e.tagName)||txt)r.push([b.left,b.top,b.right,b.bottom].map(v=>Math.round(v*d)).join(","))}return r.join(" ")})()'
fail() { echo "FAIL: $*" | tee -a "$OUT/log.txt"; "$T/shot.sh" "$OUT/fail.png" >/dev/null 2>&1; exit 1; }
pass() { echo "PASS: $*" | tee -a "$OUT/log.txt"; }

# 1. needs no window.
n=$(us_ "grep -c -E 'Image *\{|FolderListModel' $QML")
[ "${n:-x}" = 0 ] || fail "org.powos.transparent draws a picture of its own again ($n Image/FolderListModel in $QML): Plasma's desktop must stay transparent"
pass "org.powos.transparent draws nothing"

. "$here/window-lock.sh"
window_lock plasma-transparent.sh 120
trap 'restore; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"' EXIT
I0=$(irq)
chk() { [ "$(irq)" = "$I0" ] || { echo "STOP: a real touch at $1 - restoring"; exit 3; }; }
hcall() {
  "$T/cdp.sh" eval home "new Promise(ok=>{const h=window.__powosHost,P=window.PowosHost;if(!h||!P||!P.postMessage)return ok('ERR no bridge');const r=h.resolve,j=h.reject,id=910400+Math.floor(Math.random()*9000);const done=v=>{h.resolve=r;h.reject=j;ok(v)};h.resolve=(i,v)=>i===id?done(v):r(i,v);h.reject=(i,m)=>i===id?done('ERR '+m):j(i,m);setTimeout(()=>done('ERR no answer'),8000);P.postMessage(JSON.stringify([id,'$1',JSON.stringify($2)]))}).then(v=>typeof v==='string'&&v.startsWith('ERR')?v:($3)(v))" 2>&1 | tr -d '"\r' | tail -1
}
s=$(sh_ "dumpsys power | sed -n s/.*mWakefulness=//p | head -1")
[ "$s" = Awake ] || { echo "the screen is $s - not woken (rule)"; exit 3; }

r=$(us_ "q=\$(stat -c %Y $QML); p=\$(stat -c %Y /proc/\$(pgrep -x plasmashell | head -1)); echo \$q \$p")
q=${r% *}; p=${r#* }
if ! { [ -n "$q" ] && [ -n "$p" ] && [ "$p" -ge "$q" ]; }; then
  echo "plasmashell (started $p) runs an older org.powos.transparent ($q): restarting it" | tee -a "$OUT/log.txt"
  us_ "setsid -f plasmashell --replace >/dev/null 2>&1 </dev/null; sleep 8; pgrep -x plasmashell >/dev/null && echo up" | grep -q up \
    || fail "plasmashell didn't come back after --replace"
fi
pass "plasmashell runs the installed org.powos.transparent"

DESK='andro\.marchy\.(MainActivity|HomeDesktop)'
sh_ "am start -W -n com.powos.app/andro.marchy.HomeShell >/dev/null"; sleep 3; chk webhome
"$T/shot.sh" "$PT/pt-home.png" --phone >/dev/null 2>&1 || fail "no screenshot of home"
"$T/cdp.sh" eval home "$UIJS" 2>/dev/null | tr -d '"\r' | tail -1 > "$OUT/pt-ui.txt"
grep -q ',' "$OUT/pt-ui.txt" || fail "no rects of home's UI over CDP (cdp.sh eval home): $(head -c 200 "$OUT/pt-ui.txt")"
"$A" push "$OUT/pt-ui.txt" /data/local/tmp/pt-ui.txt >/dev/null 2>&1; sh_ "mv /data/local/tmp/pt-ui.txt $PT/pt-ui.txt; chmod 644 $PT/pt-ui.txt"
r=$(hcall apps.launch "['$KEY']" "()=>'ok'"); [ "$r" = ok ] || fail "apps.launch: $r"
sleep 6; chk launch   # thawed, and a session start's ksplash faded
f=$(sh_ "dumpsys window | grep -m1 mCurrentFocus")
grep -qE "$DESK" <<<"$f" || fail "Plasma's desktop isn't in front: $f"
"$T/shot.sh" "$PT/pt-desk.png" --phone >/dev/null 2>&1 || fail "no screenshot of Plasma's desktop"
sh_ "dumpsys SurfaceFlinger" > "$OUT/sf.txt"
# KWin's frame now (the desktop in front), then home again: a second reference for the live wallpaper's frame.
us_ "rm -f /tmp/pt-kwin.png; timeout 30 spectacle -b -n -f -o /tmp/pt-kwin.png >/dev/null 2>&1; chmod 644 /tmp/pt-kwin.png" >/dev/null
sh_ "am start -W -n com.powos.app/andro.marchy.HomeShell >/dev/null"; sleep 3
"$T/shot.sh" "$PT/pt-home2.png" --phone >/dev/null 2>&1 || fail "no second screenshot of home"
sh_ "chmod 644 $PT/pt-home.png $PT/pt-home2.png $PT/pt-desk.png"
chk shots

# 3-5. measured inside PowOS (python3 + PIL there).
m=$(us_ "python3 - <<'PY'
from PIL import Image
home = Image.open('/tmp/pt-home.png').convert('RGB')
home2 = Image.open('/tmp/pt-home2.png').convert('RGB')
desk = Image.open('/tmp/pt-desk.png').convert('RGB')
kwin = Image.open('/tmp/pt-kwin.png').convert('RGBA').resize(desk.size, Image.NEAREST)
if home.size != desk.size or home2.size != desk.size: print('ERR sizes home %s %s desk %s (folded/unfolded between shots)' % (home.size, home2.size, desk.size)); raise SystemExit
s = (max(1, desk.size[0] // 8), max(1, desk.size[1] // 8))
h8, g8, d8 = home.resize(s, Image.BOX), home2.resize(s, Image.BOX), desk.resize(s, Image.BOX)
alpha = kwin.split()[3].resize(s, Image.BOX)   # a cell counts as transparent only when all of it is
# Home's UI (cells under anything its page paints, one cell of margin) and the status bar band: no wallpaper there.
W, H = s; skip = set(); bar = max(1, desk.size[1] * 4 // 100 // 8)
for r in open('/tmp/pt-ui.txt').read().split():
    l, t, rr, b = [int(v) // 8 for v in r.split(',')]
    for y in range(max(0, t - 1), min(H, b + 2)):
        for x in range(max(0, l - 1), min(W, rr + 2)): skip.add((x, y))
n = clear = lit = same = black = ui = moving = 0
for y in range(0, H, max(1, H // 64)):
    for x in range(0, W, max(1, W // 64)):
        n += 1
        if alpha.getpixel((x, y)) > 0: continue
        clear += 1
        if (x, y) in skip or y < bar: ui += 1; continue
        hr, hg, hb = h8.getpixel((x, y)); gr, gg, gb = g8.getpixel((x, y)); dr, dg, db = d8.getpixel((x, y))
        if abs(hr - gr) + abs(hg - gg) + abs(hb - gb) >= 60: moving += 1; continue   # the live wallpaper moved here
        if hr + hg + hb < 120: continue   # home's wallpaper is dark here: a black frame would match it too
        lit += 1
        if abs(hr - dr) + abs(hg - dg) + abs(hb - db) < 90: same += 1
        if dr + dg + db < 40: black += 1
print('clear=%.3f lit=%d same=%.3f black=%.3f ui=%d moving=%d' % (clear / n, lit, same / max(lit, 1), black / max(lit, 1), ui, moving))
PY" | tail -1)
pull pt-desk.png; pull pt-home.png; pull pt-home2.png; pull pt-kwin.png
echo "measure: $m" | tee -a "$OUT/log.txt"
case "$m" in ERR*) fail "$m" ;; esac
v() { sed -n "s/.*$1=\([0-9.]*\).*/\1/p" <<<"$m"; }
clear=$(v clear); lit=$(v lit); same=$(v same); black=$(v black)
[ -n "$clear" ] || fail "nothing to measure (KWin capture or shots missing: $m)"
awk "BEGIN{exit !($clear >= 0.15)}" || fail "Plasma's desktop is opaque in KWin's frame: only $clear of it at alpha 0 (it draws a wallpaper of its own)"
pass "KWin's frame of the desktop: $clear of it transparent"
[ "${lit:-0}" -ge 20 ] || fail "too few lit wallpaper cells behind the transparent desktop to compare ($lit)"
awk "BEGIN{exit !($black <= 0.10)}" || fail "$black of the transparent desktop is black where home's wallpaper is lit"
awk "BEGIN{exit !($same >= 0.60)}" || fail "the desktop shows another picture than home's wallpaper: only $same of $lit lit cells match home's (a second copy, another scale/offset)"
pass "Plasma's desktop shows home's own wallpaper behind it: $same of $lit lit cells match, $black black"
sf=$(awk '/Composition list \(bottom to top\)/{p=1} p&&/^  Layer \[/{print}' "$OUT/sf.txt" | head -2)
sed -n 1p <<<"$sf" | grep -q Wallpaper && sed -n 2p <<<"$sf" | grep -qE 'SurfaceView\[com\.powos\.app/andro\.marchy\.(MainActivity|HomeDesktop)' \
  || fail "SurfaceFlinger has something between the wallpaper and the desktop's surface: $(tr '\n' '|' <<<"$sf")"
awk '/SurfaceView\[com\.powos\.app\/andro\.marchy\.(MainActivity|HomeDesktop)\]/{p=1} p&&/isOpaque=/{print; exit}' "$OUT/sf.txt" | grep -q 'isOpaque=false' \
  || fail "the desktop's surface is opaque in SurfaceFlinger: Android draws black where Plasma is transparent"
pass "SurfaceFlinger: the wallpaper directly under the desktop's translucent surface"
chk end
pass "Plasma's desktop is transparent over the PowOS wallpaper ($OUT)"
