#!/bin/bash
# lanes: phone
# needs: kwin
# kwin-restart-windows.sh [OUT]: an app restart and a KWin restart each bring every open Linux window back as a web
# window (board task "A hung game crashes KWin and kills ALL Linux-app rendering (no ww-linux layers)"). Kate and
# Dolphin opened through home's launch path, each live (its app's frames), with its powos-ww-<id>-linux layer in
# SurfaceFlinger and Dolphin's body not a flat fill (screencap of its body rect, window-render.py stats); then
#   app:  `am force-stop com.powos.app` + home again (what an APK install or a crash does - the daemon goes with the
#         app, every window task goes back to KWin's desktop): both windows back as web windows within $BACK_S s,
#         live, with their layers, Dolphin drawing (kwin 0060: the new app's "export-new 1" sweeps them out again);
#   kwin: kwin_wayland SIGKILLed (what happened at 19:33:50 on 11-06; kwin_wayland_wrapper starts a new one): Kate
#         and Dolphin (Qt Wayland clients reconnect) back as web windows of the new KWin within $BACK_S s, the same.
# Always restores: the Kate/Dolphin this started killed, home, `cmd device_state state reset`.
# Exit: 0 passed; 1 FAIL; 3 a real touch / not now (re-queued); 5 can't run.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"
OUT=${1:-$HOME/.cache/powos-verify/kwin-restart-windows-$(date +%m%d-%H%M)}; mkdir -p "$OUT"
L=$HOME/.cache/powos-verify.lock
HYPR=/data/powos/root/run/powos-app/hyprland.log
BACK_S=${BACK_S:-20}
PY="python3 -I $here/window-render.py"
sh_() { "$A" shell "su -c '$*'" 2>/dev/null | tr -d '\r'; }
us() { printf '%s\n' "$1" > "$OUT/u.sh"; "$T/user.sh" "$OUT/u.sh" 2>/dev/null | grep -v "file pushed" | tr -d '\r'; }
irq() { sh_ "awk '/touch-0/{s+=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9} END{print s}' /proc/interrupts"; }
MINE=""
restore() {
  for a in $MINE; do us "pkill -x $a; true" >/dev/null; done
  sh_ "am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null; cmd device_state state reset"
  sh_ "tail -n +$((H0 + 1)) $HYPR" > "$OUT/kwin.log" 2>/dev/null
  echo "restored"
}
. "$here/window-lock.sh"
window_lock kwin-restart-windows.sh
H0=$(sh_ "wc -l < $HYPR"); H0=${H0:-0}
trap 'restore; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"' EXIT
I0=$(irq)
chk() { [ "$(irq)" = "$I0" ] || { echo "STOP: a real touch at $1 - restoring"; exit 3; }; }
fail() { echo "FAIL: $*" | tee -a "$OUT/log.txt"; "$T/shot.sh" "$OUT/fail.png" >/dev/null 2>&1; exit 1; }
pass() { echo "PASS: $*" | tee -a "$OUT/log.txt"; }
log() { echo "$*" | tee -a "$OUT/log.txt"; }
. "$here/ww-lib.sh"
. "$here/kwin-up.sh"
plaunch() { ev "importShim('./state.ts').then(m=>m.launch('$1')).then(()=>'ok',e=>'ERR '+e)"; }
kwin_pid() { sh_ "chroot /data/powos/root pgrep -x kwin_wayland | head -1"; }
# layer <w-id>: its powos-ww-<id>-linux layer is in SurfaceFlinger's list.
layer() { sh_ "dumpsys SurfaceFlinger --list" | grep -c "powos-ww-${1#w}-linux"; }
is_live() { [ "$(wwel "$1" "e=>e.querySelector('.webwindow-body.live')?'live':'placeholder'")" = live ]; }
# drawn <w-id> <name>: its body on screen is the app's picture, not a flat fill (window-render.sh's content rule).
drawn() {
  local r st dom col
  r=$(wwbody "$1"); [ -n "$r" ] || { echo "no body rect on screen"; return 1; }
  "$A" exec-out "screencap | gzip -1" > "$OUT/$2.raw.gz" 2>/dev/null && [ -s "$OUT/$2.raw.gz" ] || { echo "screencap failed"; return 1; }
  # shellcheck disable=SC2086
  st=$($PY stats "$OUT/$2.raw.gz" $r 2>&1); $PY png "$OUT/$2.raw.gz" "$OUT/$2.png" $r "$OUT/$2-body.png" >/dev/null 2>&1
  dom=$(echo "$st" | sed -n 's/.*dominant=\([0-9.]*\).*/\1/p'); col=$(echo "$st" | sed -n 's/.*colours=\([0-9]*\).*/\1/p')
  echo "$st (body $r)"
  awk -v d="${dom:-1}" -v c="${col:-0}" 'BEGIN { exit !(d < 0.97 && c >= 4) }'
}
# back <key> <round>: the newest web window of <key> - live, its layer, (Dolphin) drawn - within BACK_S s. Prints its id.
back() {
  local key=$1 round=$2 t0 id="" i why=""
  t0=$(date +%s)
  for i in $(seq 1 "$BACK_S"); do
    id=$(wwids "$key"); id=${id##* }
    if [ -n "$id" ] && is_live "$id" && [ "$(layer "$id")" -ge 1 ]; then break; fi
    why="window ${id:-none}, $( [ -n "$id" ] && is_live "$id" && echo live || echo 'not live'), layer $( [ -n "$id" ] && layer "$id" || echo 0)"
    id=""; sleep 1
  done
  [ -n "$id" ] || fail "$round: $key not back as a live web window with its ww-linux layer in $BACK_S s ($why)"
  log "$round: $key back as $id ($(( $(date +%s) - t0 )) s), live, layer powos-ww-${id#w}-linux"
  if [ "$key" = l:org.kde.dolphin ]; then
    local d; d=$(drawn "$id" "$round-dolphin") || fail "$round: Dolphin's window $id is live but draws nothing: $d"
    log "$round: Dolphin draws: $d"
  fi
  echo "$id" > "$OUT/$round-${key#l:}.id"
}

s=$(sh_ "dumpsys power | sed -n s/.*mWakefulness=//p | head -1")
[ "$s" = Awake ] || { echo "the screen is $s - not woken (rule); nothing done"; exit 3; }
[ -z "$(sh_ "chroot /data/powos/root pgrep -f steam_app_ | head -1")" ] || { echo "a game runs: not now"; exit 3; }
kwin_up "${KWIN_MIN:-6.7.5-3.68}"
K0=$(kwin_pid); [ -n "$K0" ] || { echo "ENV: no kwin_wayland runs"; exit 5; }
log "KWin pid $K0, hyprland.log at line $H0"
sh_ "am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; sleep 2; chk home
[ "$(hcall webwindows.list "[]" "l=>'ok'")" = ok ] || { echo "ENV: home has no web windows here (folded, off): not now"; exit 3; }

for app in kate dolphin; do
  [ -n "$(us "pgrep -x $app | head -1")" ] && { echo "the user's $app runs: not now"; exit 3; }
done
for app in kate dolphin; do
  before=$(wwids l:)
  [ "$(plaunch l:org.kde.$app)" = ok ] || fail "home's launch of $app failed"
  MINE="$MINE $app"
  id=$(wwnew 30 "$before" l:); id=${id%% *}
  [ -n "$id" ] || fail "$app opened no web window in 30 s"
  back "l:org.kde.$app" "open"
done
chk opened

# Round 1: the app restarts (its daemon, every window task with it); KWin stays.
sh_ "am force-stop com.powos.app"; sleep 1
sh_ "am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"
for app in kate dolphin; do back "l:org.kde.$app" app; done
K=$(kwin_pid); [ "$K" = "$K0" ] || log "(KWin is pid ${K:-none} now, was $K0, after the app restart)"
pass "app restart: Kate and Dolphin back as live web windows with their ww-linux layers, Dolphin drawing"
chk "app round"

# Round 2: KWin dies (SIGKILL, as on 11-06 19:33:50); its wrapper starts a new one, the Qt clients reconnect.
K0=$(kwin_pid)
sh_ "chroot /data/powos/root pkill -KILL -x kwin_wayland"
for _ in $(seq 1 20); do K=$(kwin_pid); [ -n "$K" ] && [ "$K" != "$K0" ] && break; sleep 1; done
[ -n "$K" ] && [ "$K" != "$K0" ] || fail "no new kwin_wayland 20 s after killing $K0"
log "KWin $K0 killed, new KWin $K"
for app in kate dolphin; do back "l:org.kde.$app" kwin; done
pass "KWin restart: Kate and Dolphin back as live web windows with their ww-linux layers, Dolphin drawing"
