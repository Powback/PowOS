#!/bin/bash
# lanes: phone
# needs: kwin
# steam-input.sh [OUT] (board tapping-steam-shows-its-window-resident-steam-ru; Mac side, queue it after linux-float.sh
# has put the newest kwin on): input inside Linux windows on the unfolded home, kwin 0020 (touch target = a shown
# window taking input there; a window that resized itself is sized back to its task). Recorded (OUT/steam.mp4, kate.mp4):
#   show:    a real tap on the dock's Steam cell (else home's launch call) -> Steam's X window viewable, its task in front.
#   size:    Steam's X window is its task's size (X px = task px: Xwayland's scale is the output's), +-4 px.
#   library: a real tap on LIBRARY (X window point 427,103) changes the URL row; logs which X window X itself put the
#            touch's pointer on (xdotool getmouselocation), and KWin's "touch at ... to" lines.
#   scroll:  a real swipe up in the library's content changes the content (it scrolled).
#   kate:    a real tap in Kate's window + `input text` change it (steam-tap.sh's kate phase).
# Steam is left shown; Kate closed; home; `cmd device_state state reset`. Exit: 0 pass; 1 FAIL; 3 a real touch / not
# now; 5 can't run.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"
OUT=${1:-$HOME/.cache/powos-verify/steam-input-$(date +%m%d-%H%M)}; mkdir -p "$OUT"
L=$HOME/.cache/powos-verify.lock
sh_() { "$A" shell "su -c '$*'" 2>/dev/null | tr -d '\r'; }
us() { printf '%s\n' "$1" > "$OUT/u.sh"; "$T/user.sh" "$OUT/u.sh" 2>/dev/null | grep -v "file pushed" | tr -d '\r'; }
irq() { sh_ "awk '/touch-0/{s+=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9} END{print s}' /proc/interrupts"; }
X='export DISPLAY=:0 XAUTHORITY=$(pgrep -a Xwayland | grep -o -- "-auth [^ ]*" | head -1 | cut -d" " -f2)'
REC=""; KATE=0; RC=0; KL0=0
recstop() { [ -n "$REC" ] || return 0; sh_ "pkill -INT screenrecord"; sleep 2
  sh_ "chmod 644 /data/local/tmp/steam-input-$REC.mp4"
  "$A" pull "/data/local/tmp/steam-input-$REC.mp4" "$OUT/$REC.mp4" >/dev/null 2>&1; sh_ "rm -f /data/local/tmp/steam-input-$REC.mp4"; REC=""; }
rec() { recstop; REC=$1; "$A" shell "su -c 'screenrecord --time-limit 170 --bit-rate 6000000 /data/local/tmp/steam-input-$1.mp4 >/dev/null 2>&1 &'" >/dev/null 2>&1; sleep 1; }
restore() {
  recstop
  [ $KATE = 1 ] && us "pkill -x kate; true"
  sh_ "am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null; cmd device_state state reset"
  us "tail -n +$((KL0 + 1)) /run/powos-app/hyprland.log | grep -a kwin_backend_anland" > "$OUT/kwin.txt"
  echo "restored; recordings: $(ls "$OUT"/*.mp4 2>/dev/null | tr '\n' ' ')"
}
. "$here/window-lock.sh"
. "$here/kwin-up.sh"
window_lock steam-input.sh 120
trap 'restore; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"' EXIT
I0=$(irq)
chk() { [ "$(irq)" = "$I0" ] || { echo "STOP: a real touch at $1 - restoring"; exit 3; }; }
fail() { echo "FAIL $*" | tee -a "$OUT/log.txt"; "$T/shot.sh" "$OUT/fail-$(date +%H%M%S).png" >/dev/null 2>&1; RC=1; }
pass() { echo "PASS $*" | tee -a "$OUT/log.txt"; }
log() { echo "$*" | tee -a "$OUT/log.txt"; }
page() { "$T/cdp.sh" eval home "$1" 2>&1 | tr -d '"\r' | tail -1; }
hcall() {
  "$T/cdp.sh" eval home "new Promise(ok=>{const h=window.__powosHost,P=window.PowosHost;if(!h||!P||!P.postMessage)return ok('ERR no bridge');const r=h.resolve,j=h.reject,id=910800+Math.floor(Math.random()*9000);const done=v=>{h.resolve=r;h.reject=j;ok(v)};h.resolve=(i,v)=>i===id?done(v):r(i,v);h.reject=(i,m)=>i===id?done('ERR '+m):j(i,m);setTimeout(()=>done('ERR no answer'),8000);P.postMessage(JSON.stringify([id,'$1',$2]))}).then(v=>($3)(v))" 2>&1 | tr -d '"\r' | tail -1
}
tasks() { sh_ "am stack list | grep PowosWindowActivity" | grep -oE 'taskId=[0-9]+' | tr -dc '0-9\n' | sort -n; }
tbounds() { sh_ "am stack list | grep -E \"taskId=$1[^0-9]\"" | grep -oE 'bounds=\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]' | head -1 | tr -c '0-9\n' ' '; }
focus() { sh_ "dumpsys window | grep -m1 mCurrentFocus"; }
steamwin() { us "$X; xwininfo -root -tree 2>/dev/null | awk '/\"Steam\": \\(\"steamwebhelper\" \"steam\"\\)/{print \$1}' | while read -r w; do xwininfo -id \$w 2>/dev/null | awk -v w=\$w '/Map State/{m=\$3} /Width:/{x=\$2} /Height:/{y=\$2} END{if(m==\"IsViewable\"&&x>=400&&y>=300)print w, x, y}'; done | head -1" | tail -1; }
# A crop of Steam's X window, hashed (x11grab: what Steam drew, not what the task shows): $1 = w:h:x:y.
grab() { us "$X; ffmpeg -loglevel error -f x11grab -window_id $SW -i :0 -frames:v 1 -vf crop=$1,format=gray -f rawvideo - 2>/dev/null | md5sum | cut -c1-12" | tail -1; }
# Which X window X itself has the pointer over (a touch moves the emulated pointer there): its id, name, geometry.
xunder() { us "$X; eval \$(xdotool getmouselocation --shell 2>/dev/null); echo \"pointer \$X,\$Y window \$WINDOW: \$(xwininfo -id \$WINDOW 2>/dev/null | sed -n 's/^xwininfo: Window id: //p') \$(xwininfo -id \$WINDOW 2>/dev/null | awk '/Width:/{w=\$2} /Height:/{h=\$2} /Map State/{m=\$3} END{print w\"x\"h, m}')\"" | tail -1; }
bright() {  # mean brightness of "L T R B" on the ON display (steam-tap.sh's)
  sh_ "screencap -d ${DID:-0} /data/powos/root/var/tmp/steam-input.raw" >/dev/null
  printf '%s\n' "python3 - /var/tmp/steam-input.raw $1 $2 $3 $4 <<'PY' 2>/dev/null || echo 0
import struct, sys
f = sys.argv[1]; l, t, r, b = map(int, sys.argv[2:6]); d = open(f, 'rb').read(); w, h = struct.unpack('<II', d[:8])
off = len(d) - w * h * 4; s = n = 0
for y in range(max(t, 0), min(b, h), 8):
    row = off + y * w * 4
    for x in range(max(l, 0), min(r, w), 8):
        p = row + x * 4; s += d[p] + d[p + 1] + d[p + 2]; n += 3
print(s // max(n, 1))
PY
rm -f /var/tmp/steam-input.raw" > "$OUT/r.sh"; "$T/root.sh" "$OUT/r.sh" 2>/dev/null | grep -v "file pushed" | tr -d '\r' | tail -1
}

s=$(sh_ "dumpsys power | sed -n s/.*mWakefulness=//p | head -1")
[ "$s" = Awake ] || { echo "the screen is $s - not woken (rule); nothing done"; exit 3; }
[ "$(us "pgrep -fc 'SteamLaunch AppId='" | tail -1)" = 0 ] || { echo "a game runs under Steam (the user's): not now"; exit 3; }
sh_ "cmd device_state state 3"; sleep 3; chk unfold
WH=$(sh_ "wm size" | sed -nE 's/.*(Override|Physical) size: ([0-9]+)x([0-9]+).*/\2 \3/p' | tail -1); W=${WH% *}; H=${WH#* }
[ "${W:-0}" -gt 2000 ] || { echo "display is ${W:-?}x${H:-?}, not the unfolded inner screen"; exit 5; }
if sh_ "dumpsys window policy | grep -m1 mIsShowing=" | grep -q true; then
  sh_ "wm dismiss-keyguard"; sleep 1.5
  sh_ "dumpsys window policy | grep -m1 mIsShowing=" | grep -q true && { sh_ "input swipe $((W / 2)) $((H * 9 / 10)) $((W / 2)) $((H / 4)) 300"; sleep 1.5; }
fi
sh_ "am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; sleep 2; chk home
DID=$(sh_ "dumpsys display" | sed -nE 's/.*uniqueId="local:([0-9]+)".* state ON,.*/\1/p' | head -1)
KL0=$(us "grep -a -c . /run/powos-app/hyprland.log" | tail -1); KL0=${KL0:-0}
# The newest built KWin, running (kwin-up.sh): a check on an older or stale KWin proves nothing (this one ran on 3.25
# as "kwin 3.26", 2026-10-23). KWIN_MIN: 0022 (X11 windows take taps), 0023 (sessions), 0024.
kwin_up "${KWIN_MIN:-6.7.5-3.28}"
log "kwin: $(us 'pacman -Q kwin' | tail -1), session kwin started $(us 'ps -o lstart= -C kwin_wayland | head -1' | tail -1)"

# show
rec steam; before=$(tasks)
xy=$(page "(()=>{const e=document.querySelector('.home .dock .app[data-key=\"l:steam\"]');if(!e)return 'none';const r=e.getBoundingClientRect(),d=devicePixelRatio;return Math.round((r.left+r.width/2)*d)+' '+Math.round((r.top+r.height/2)*d)})()")
if [[ $xy =~ ^[0-9]+\ [0-9]+$ ]]; then log "show: a tap on the dock's Steam cell at $xy"; sh_ "input tap $xy"
else log "show: no Steam cell in the dock ($xy) - home's launch call"; hcall apps.launch "['l:steam']" "()=>'ok'" >/dev/null; fi
chk "steam tap"
w=""; tk=""; f=""; end=$((SECONDS + 150))
while [ $SECONDS -lt $end ]; do
  w=$(steamwin); [ -n "$w" ] && tk=$( { comm -13 <(echo "$before") <(tasks); tasks; } | grep . | head -1) && f=$(focus)
  [ -n "$w" ] && [ -n "$tk" ] && [[ $f == *PowosWindowActivity* ]] && break
  sleep 2
done
chk show
[ -n "$w" ] && [[ $f == *PowosWindowActivity* ]] || { fail "show: no Steam window in front (window '${w:-none}', focus $f)"; exit 1; }
SW=${w%% *}; read -r _ XW XH <<<"$w"
sleep 4; w=$(steamwin); read -r _ XW XH <<<"$w"
read -r l t r b <<<"$(tbounds "$tk")"; TW=$((r - l)); TH=$((b - t))
"$T/shot.sh" "$OUT/steam.png" >/dev/null 2>&1
log "show: Steam X window $SW ${XW}x$XH, task $tk bounds $l $t $r $b (${TW}x$TH), brightness $(bright "$l" "$t" "$r" "$b")"
pass "show: a tap on Steam shows its window"

# size
if [ $(( XW > TW ? XW - TW : TW - XW )) -le 4 ] && [ $(( XH > TH ? XH - TH : TH - XH )) -le 4 ]; then
  pass "size: Steam's X window ${XW}x$XH is its task's size ${TW}x$TH"
else
  fail "size: Steam's X window ${XW}x$XH, its task ${TW}x$TH (min size: $(us "$X; xprop -id $SW WM_NORMAL_HINTS | grep -i minimum" | tail -1 | sed 's/^[[:space:]]*//'))"
fi

# library: Steam's tab row, URL row (crop 900x50+100+140 of its X window, steam-tap.sh's)
u0=$(grab 900:50:100:140); sleep 2; u1=$(grab 900:50:100:140); log "library: URL row $u0 / $u1 (still)"
log "library: tap $((l + 427)),$((t + 103))"; sh_ "input tap $((l + 427)) $((t + 103))"; sleep 0.3
log "library: X under the touch: $(xunder)"; sleep 3; chk "library tap"
u2=$(grab 900:50:100:140)
[ "$u2" != "$u1" ] && pass "library: a tap on LIBRARY switched Steam's tab (URL row changed)" \
                   || fail "library: a tap on LIBRARY changed nothing in Steam's window"

# scroll: a swipe up in the middle of its content (below the tab row)
CW=$(( XW < TW ? XW : TW )); CH=$(( XH < TH ? XH : TH )); cw=$((CW * 6 / 10)); ch=$((CH * 4 / 10))
c0=$(grab "$cw:$ch:$((CW / 5)):$((CH * 4 / 10))"); sleep 1; c1=$(grab "$cw:$ch:$((CW / 5)):$((CH * 4 / 10))")
log "scroll: content $c0 / $c1 (still); swipe $((l + CW / 2)),$((t + CH * 8 / 10)) -> $((l + CW / 2)),$((t + CH * 4 / 10))"
sh_ "input swipe $((l + CW / 2)) $((t + CH * 8 / 10)) $((l + CW / 2)) $((t + CH * 4 / 10)) 500"; sleep 2.5; chk scroll
c2=$(grab "$cw:$ch:$((CW / 5)):$((CH * 4 / 10))"); "$T/shot.sh" "$OUT/scrolled.png" >/dev/null 2>&1
[ "$c2" != "$c1" ] && pass "scroll: a swipe in the library scrolled it (content changed)" \
                   || fail "scroll: a swipe in the library changed nothing"
recstop

# kate
sh_ "am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; sleep 2
rec kate; before=$(tasks); KATE=1
hcall apps.launch "['l:org.kde.kate']" "()=>'ok'" >/dev/null
KT=""; for _ in $(seq 30); do sleep 1; KT=$(comm -13 <(echo "$before") <(tasks) | tail -1); [ -n "$KT" ] && break; done; chk kate
if [ -z "$KT" ]; then fail "kate: no window task in 30 s"
else
  sleep 4; read -r kl kt kr kb <<<"$(tbounds "$KT")"
  k0=$(bright "$kl" "$kt" "$kr" "$kb")
  sh_ "input tap $(( (kl + kr) / 2 )) $(( (kt + kb) / 2 ))"; sleep 1.5
  sh_ "input text powostaptest"; sleep 2; chk "kate tap"
  k1=$(bright "$kl" "$kt" "$kr" "$kb"); "$T/shot.sh" "$OUT/kate.png" >/dev/null 2>&1
  cap=$(hcall windows.list "[]" "l=>String((l.find(w=>w.id===$KT)||{}).title||(l.find(w=>w.id===$KT)||{}).label||'-')")
  log "kate: task $KT bounds $kl $kt $kr $kb, brightness $k0 -> $k1, title '$cap'"
  [[ $cap == *"*"* || $cap == *odified* || $k0 != "$k1" ]] && pass "kate: a tap + keys reached Kate" || fail "kate: the tap + keys changed nothing in Kate"
fi
recstop
exit $RC
