#!/bin/bash
# lanes: phone
# plasma-notify.sh [OUT]: Plasma's notifications in PowOS's shade and the clipboard both ways (board task "Plasma as
# app + backend for the web launcher", slice 3; docs/DESKTOP-WEB-SHELL.md). Steps:
#   1. the session runs powos-plasma-bridge (started as its autostart would, if the session predates the deploy),
#      idle at rest; the installed APK has PlasmaBridge;
#   2. `notify-send -w` in the session -> the notification is in the shade's list (home's notifications.list: the
#      Linux app's name, an icon, grouped as a Linux app, not as PowOS's own);
#   3. dismissed as the shade does it (notifications.dismiss) -> gone from Android's list, and Plasma closed it
#      (notify-send -w returns only on NotificationClosed);
#   4. clipboard: Klipper's setClipboardContents -> home's clipboard.read has it; home's clipboard.write -> Klipper's
#      getClipboardContents has it. The user's clip is put back afterwards (never printed).
# Always restores: home, the clip. Exit: 0 passed; 1 FAIL; 3 a real touch / not awake / APK not in yet (re-queued).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"
OUT=${1:-$HOME/.cache/powos-verify/plasma-notify-$(date +%m%d-%H%M)}; mkdir -p "$OUT"
L=$HOME/.cache/powos-verify.lock
N=$(date +%s)$RANDOM
sh_() { "$A" shell "su -c '$*'" 2>/dev/null | tr -d '\r'; }
# A script run as the session user (its bus), through user.sh. Never sudo in it.
ux() { printf '%s\n' "$1" >"$OUT/u.sh"; "$T/user.sh" "$OUT/u.sh" 2>/dev/null | tr -d '\r'; }
irq() { sh_ "awk '/touch-0/{s+=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9} END{print s}' /proc/interrupts"; }
hcall() {
  "$T/cdp.sh" eval home "new Promise(ok=>{const h=window.__powosHost,P=window.PowosHost;if(!h||!P||!P.postMessage)return ok('ERR no bridge');const r=h.resolve,j=h.reject,id=910400+Math.floor(Math.random()*9000);const done=v=>{h.resolve=r;h.reject=j;ok(v)};h.resolve=(i,v)=>i===id?done(v):r(i,v);h.reject=(i,m)=>i===id?done('ERR '+m):j(i,m);setTimeout(()=>done('ERR no answer'),8000);P.postMessage(JSON.stringify([id,'$1',JSON.stringify($2)]))}).then(v=>typeof v==='string'&&v.startsWith('ERR')?v:($3)(v))" 2>&1 | tr -d '"\r' | tail -1
}
CLIP0=; CLIP_SAVED=0
restore() {
  # The user's clip as it was (read URI-encoded, so quotes survive the trip): back on Android, and so in Klipper too.
  [ "$CLIP_SAVED" = 1 ] && [ -n "$CLIP0" ] &&
    hcall clipboard.write "[decodeURIComponent('$CLIP0')]" "()=>'ok'" >/dev/null
  ux "pkill -f 'notify-send -p -w -a PowOS check'; rm -f /tmp/pn-$N.out" >/dev/null
  sh_ "am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; echo "restored"
}
. "$here/window-lock.sh"
window_lock plasma-notify.sh 120
trap 'restore; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"' EXIT
I0=$(irq)
chk() { [ "$(irq)" = "$I0" ] || { echo "STOP: a real touch at $1 - restoring"; exit 3; }; }
fail() { echo "FAIL: $*" | tee -a "$OUT/log.txt"; "$T/shot.sh" "$OUT/fail.png" >/dev/null 2>&1; exit 1; }
pass() { echo "PASS: $*" | tee -a "$OUT/log.txt"; }

# 1. The APK side, the bridge, and that it sleeps.
# PlasmaBridge makes its channel when the app starts.
sh_ "dumpsys notification" | grep -q "mId=.plasma-v1" || { echo "the installed APK has no PlasmaBridge yet (no plasma-v1 channel) - re-queued"; exit 3; }
pid() { sh_ "pgrep -f -d, \"^python3 /usr/local/bin/powos-plasma-bridge\""; }
pids=$(pid)
if [ -z "$pids" ]; then
  ux "setsid -f powos-plasma-bridge </dev/null >/tmp/powos-plasma-bridge.log 2>&1" >/dev/null; sleep 3; pids=$(pid)
  [ -n "$pids" ] || fail "powos-plasma-bridge doesn't start: $(ux 'tail -5 /tmp/powos-plasma-bridge.log')"
  echo "started powos-plasma-bridge (the session predates its deploy)"
fi
t() { sh_ "for p in ${pids//,/ }; do awk '{s+=\$14+\$15} END{print s}' /proc/\$p/stat; done" | awk '{s+=$1} END{print s}'; }
t0=$(t); sleep 5; t1=$(t)
[ $((t1 - t0)) -le 1 ] || fail "powos-plasma-bridge used $((t1 - t0)) ticks in 5 s at rest"
pass "bridge running ($pids), $((t1 - t0)) ticks in 5 s"

s=$(sh_ "dumpsys power | sed -n s/.*mWakefulness=//p | head -1")
[ "$s" = Awake ] || { echo "the screen is $s - not woken (rule); nothing sent"; exit 3; }
sh_ "am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; sleep 2; chk home

# 2. A Plasma notification -> the shade's list.
TITLE="Plasma check $N"
ux "setsid -f sh -c 'notify-send -p -w -a \"PowOS check\" \"$TITLE\" \"from the Plasma session\" >/tmp/pn-$N.out 2>&1; echo closed >>/tmp/pn-$N.out' </dev/null >/dev/null 2>&1" >/dev/null
sleep 3; chk notify
pid_n=$(ux "head -1 /tmp/pn-$N.out")
[ -n "$pid_n" ] || fail "notify-send printed no id"
item=$(hcall notifications.list "[]" "l=>{const n=(l.items||[]).find(i=>i.title==='$TITLE');return n?[n.app,n.pkg,n.icon?'icon':'noicon',n.key].join('|'):'ERR not in the shade: '+(l.items||[]).map(i=>i.title).join(',')}")
case "$item" in ERR*) fail "Plasma notification $pid_n: $item" ;; esac
IFS='|' read -r app pkg ic key <<<"$item"
[ "$app" = "PowOS check" ] || fail "the shade names it '$app', not the Linux app"
[ "$pkg" != com.powos.app ] || fail "grouped as PowOS's own (pkg $pkg)"
[ "$ic" = icon ] || fail "no icon"
sh_ "dumpsys notification --noredact" | grep -q "tag=plasma.*id=$pid_n\|id=$pid_n.*tag=plasma" || echo "note: dumpsys shows no tag=plasma id=$pid_n line (format?)"
"$T/shot.sh" "$OUT/posted.png" >/dev/null 2>&1
pass "Plasma notification $pid_n is in the shade as '$app' ($pkg, with an icon)"

# 3. Dismissed in the shade -> gone here and closed in Plasma.
r=$(hcall notifications.dismiss "['$key']" "()=>'ok'"); [ "$r" = ok ] || fail "notifications.dismiss: $r"
sleep 3; chk dismiss
left=$(hcall notifications.list "[]" "l=>(l.items||[]).some(i=>i.title==='$TITLE')?'still':'gone'")
[ "$left" = gone ] || fail "still in the shade after the dismiss"
ux "cat /tmp/pn-$N.out" | grep -q '^closed$' || fail "Plasma didn't close it (notify-send -w still waiting)"
pass "dismissed: gone from the shade, and Plasma closed $pid_n"

# 4. The clipboard, both ways (the user's clip kept and put back).
CLIP0=$(hcall clipboard.read "[]" "v=>v==null?'':encodeURIComponent(String(v)).replace(/'/g,'%27')"); case "$CLIP0" in ERR*) fail "clipboard.read: $CLIP0" ;; esac; CLIP_SAVED=1
ux "qdbus6 org.kde.klipper /klipper setClipboardContents powos-clip-$N-linux 2>/dev/null" >/dev/null
sleep 2; chk clip1
got=$(hcall clipboard.read "[]" "v=>String(v)")
[ "$got" = "powos-clip-$N-linux" ] || fail "Linux -> Android: Android's clip is not the Klipper text"
pass "clipboard Linux -> Android"
r=$(hcall clipboard.write "['powos-clip-$N-android']" "()=>'ok'"); [ "$r" = ok ] || fail "clipboard.write: $r"
sleep 2; chk clip2
got=$(ux "qdbus6 org.kde.klipper /klipper getClipboardContents 2>/dev/null")
[ "$got" = "powos-clip-$N-android" ] || fail "Android -> Linux: Klipper has something else"
pass "clipboard Android -> Linux"
