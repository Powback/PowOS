#!/bin/bash
# lanes: phone
# needs: kwin
# kwin-hung-client.sh [OUT]: a hung Linux client never takes KWin or the other Linux windows down (board task "A hung
# game crashes KWin and kills ALL Linux-app rendering"). For each of an X11 (Xwayland, as Broforce) and a Wayland
# KWrite: opened from the session as a web window, frozen (SIGSTOP: answers no ping, commits no frame), then closed
# KWin's way (a KWin script's closeWindow: WM_DELETE / xdg close + _NET_WM_PING / xdg ping) so KWin's "Not Responding"
# prompt (kwin_killer_helper) comes up - what a hung game's close does. While it hangs:
#   - KWin is the same process (pid unchanged, no "kwin_wayland process ... finished" from kwin_wayland_wrapper),
#   - Kate opened through home's launch path is a NEW web window that goes live (its app's frames, not the
#     placeholder) and has its powos-ww-<id>-linux layer in SurfaceFlinger (the user's symptom: no ww-linux layers);
# then the hung client killed: its window goes, the prompt goes with it within 15 s (it stayed 5 h on 2026-11-06),
# KWin still the same process.
# Always restores: KWrite/Kate this started killed, any prompt this caused ended, home (this check does not change the fold override).
# Exit: 0 passed; 1 FAIL; 3 a real touch / no free window / not now (re-queued); 5 can't run.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"
OUT=${1:-$HOME/.cache/powos-verify/kwin-hung-client-$(date +%m%d-%H%M)}; mkdir -p "$OUT"
HYPR=/data/powos/root/run/powos-app/hyprland.log
# Bound the entire local transport tree, not just adb's remote command. Killing
# only the wrapper leaves docker/adb holding the output pipe open indefinitely.
CALL_S=10
DEADLINE=$((SECONDS + 230))
bounded() {
  local budget=$CALL_S left=$((DEADLINE - SECONDS))
  [ "$left" -gt 0 ] || { echo "ERR deadline" >&2; return 124; }
  [ "$left" -ge "$budget" ] || budget=$left
  python3 -c 'import os, signal, subprocess, sys
p = subprocess.Popen(sys.argv[2:], start_new_session=True)
try:
    rc = p.wait(timeout=int(sys.argv[1]))
except subprocess.TimeoutExpired:
    os.killpg(p.pid, signal.SIGKILL)
    p.wait()
    print("ERR transport deadline: " + sys.argv[2], file=sys.stderr)
    rc = 124
sys.exit(rc)' "$budget" "$@"
}
sh_() { bounded "$A" shell "su -c '$*'" </dev/null | tr -d '\r'; }
us() { printf '%s\n' "$1" > "$OUT/u.sh"; bounded "$T/user.sh" "$OUT/u.sh" | grep -v "file pushed" | tr -d '\r'; }
# $1 in the Plasma session's own environment (plasmashell's: WAYLAND_DISPLAY, DISPLAY, XAUTHORITY) - linux-float.sh.
ses() { us "P=\$(pgrep -x plasmashell | head -1); while IFS= read -r -d '' kv; do export \"\$kv\"; done < /proc/\$P/environ; $1"; }
irq() { sh_ "awk '\''/touch-0/{s+=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9} END{print s}'\'' /proc/interrupts"; }
KATE_MINE=0 SETUP=0 H0=0
restore() {
  [ "$SETUP" = 1 ] || return 0
  SETUP=0
  DEADLINE=$((SECONDS + 35))
  us "pkill -CONT -x kwrite; pkill -KILL -x kwrite; [ $KATE_MINE = 1 ] && pkill -x kate; pkill -f 'kwin_killer_helper.*kwrite'; true" >/dev/null
  sh_ "am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"
  [ -n "${LOGPID:-}" ] && kill "$LOGPID" 2>/dev/null
  sh_ "tail -n +$((H0 + 1)) $HYPR" > "$OUT/kwin.log" 2>/dev/null
  echo "restored"
}
. "$here/window-lock.sh"
window_lock kwin-hung-client.sh
DEADLINE=$((SECONDS + 230))
trap 'rc=$?; restore; wl_release; exit "$rc"' EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
chk() { [ "$SECONDS" -lt "$DEADLINE" ] || fail "check deadline at $1"; [ "$(irq)" = "$I0" ] || { echo "STOP: a real touch at $1 - restoring"; exit 3; }; }
fail() { echo "FAIL: $*" | tee -a "$OUT/log.txt"; bounded "$T/shot.sh" "$OUT/fail.png" >/dev/null 2>&1; exit 1; }
pass() { echo "PASS: $*" | tee -a "$OUT/log.txt"; }
log() { echo "$*" | tee -a "$OUT/log.txt"; }
. "$here/ww-lib.sh"
WW_DEADLINE=$DEADLINE
export CDP_TIMEOUT_S=8 CDP_ADB_TIMEOUT_S=8
ev() { bounded "$T/cdp.sh" eval "${2:-home}" "$1" | tr -d '\r' | tail -1 | python3 -c "$UNQ"; }
plaunch() { ev "importShim('./state.ts').then(m=>m.launch('$1')).then(()=>'ok',e=>'ERR '+e)"; }
# user.sh enters powos-run.sh's session namespace and Linux PATH; a raw Android
# chroot inherits Android's PATH and cannot resolve pgrep. Only pgrep rc=1 means
# absent; command/transport errors must not become an ENV skip (or a KWin crash).
kwin_pid() {
  local answer
  answer=$(us 'p=$(pgrep -x kwin_wayland); rc=$?; case $rc in 0) printf "%s\n" "$p" ;; 1) echo none ;; *) exit "$rc" ;; esac') || return 1
  answer=${answer%%$'\n'*}
  [[ "$answer" = none || "$answer" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$answer"
}
killers() { us "pgrep -f 'kwin_killer_helper.*kwrite' | tr '\n' ' '"; }
# live <w-id> <s>: the window's body shows its app's frames (not the placeholder) within s seconds.
live() { local i lv=""; for i in $(seq 1 "$2"); do lv=$(wwel "$1" "e=>e.querySelector('.webwindow-body.live')?'live':'placeholder'"); [ "$lv" = live ] && return 0; sleep 1; done; return 1; }
# layer <w-id>: its powos-ww-<id>-linux layer is in SurfaceFlinger's list.
layer() { sh_ "dumpsys SurfaceFlinger --list" | grep -c "powos-ww-${1#w}-linux"; }
# close_kwin: KWin's own close of every KWrite window (closeWindow: WM_DELETE/xdg close, then the ping).
close_kwin() {
  us "cat > /tmp/khc.js <<'EOF'
for (const w of workspace.windowList()) { if (w.resourceClass == 'kwrite' || w.resourceClass == 'org.kde.kwrite') { w.closeWindow(); } }
EOF
qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.unloadScript khc >/dev/null 2>&1
qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.loadScript /tmp/khc.js khc >/dev/null
qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.start >/dev/null 2>&1; sleep 1
qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.unloadScript khc >/dev/null 2>&1; true" >/dev/null
}

s=$(sh_ "dumpsys power | sed -n s/.*mWakefulness=//p | head -1")
[ "$s" = Awake ] || { echo "the screen is ${s:-unknown (wakefulness query failed)} - not woken (rule); nothing done"; exit 3; }
. "$(dirname "$0")/game-lib.sh"; game_gate   # the queue's test (Steam's reaper): `steam_app_` missed Broforce
K0=$(kwin_pid) || { echo "FAIL: could not query kwin_wayland through the Linux session"; exit 1; }
[ "$K0" != none ] || { echo "ENV: no kwin_wayland runs"; exit 5; }
# No cleanup is armed before these read-only preconditions succeed.
existing=$(us "pgrep -x kwrite; echo checked")
[ "$existing" = checked ] || { echo "KWrite already runs or could not be checked: not now"; exit 3; }
I0=$(irq); [[ "$I0" =~ ^[0-9]+$ ]] || { echo "touch counter unavailable: not now"; exit 3; }
H0=$(sh_ "wc -l < $HYPR"); [[ "$H0" =~ ^[0-9]+$ ]] || { echo "KWin log unavailable: not now"; exit 3; }
SETUP=1
log "KWin pid $K0, hyprland.log at line $H0"
sh_ "am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; sleep 2; chk home

for plat in xcb wayland; do
  log "== $plat KWrite, hung"
  before=$(wwids l:)
  ses "QT_QPA_PLATFORM=$plat setsid kwrite >/tmp/khc-kwrite.log 2>&1 < /dev/null &" >/dev/null
  KW=$(wwnew 30 "$before" l:); KW=${KW%% *}
  [ -n "$KW" ] || fail "$plat KWrite opened no web window in 30 s"
  live "$KW" 15 || fail "$plat KWrite's window $KW never went live"
  P=$(us "pgrep -x kwrite | head -1"); [ -n "$P" ] || fail "no kwrite process"
  us "kill -STOP $P" >/dev/null; log "KWrite $P ($plat, window $KW) stopped"
  sleep 1; close_kwin; log "KWin asked to close it (closeWindow: delete + ping)"
  # KWin's ping times out in killPingTimeout (5 s): the prompt's process starts then.
  for _ in $(seq 1 12); do [ -n "$(killers)" ] && break; sleep 1; done
  KP=$(killers); log "kill prompt: ${KP:-none}"
  [ -n "$KP" ] || log "(no prompt came up - KWin's ping may be off; the rest still holds)"
  chk hung
  # The rest of Linux keeps rendering: a new Kate window goes live with its layer, while KWrite hangs.
  before=$(wwids l:)
  kate_before=$(us "pgrep -x kate; echo checked")
  case $kate_before in checked) KATE_MINE=1 ;; *checked) ;; *) fail "could not check existing Kate processes" ;; esac
  [ "$(plaunch l:org.kde.kate)" = ok ] || fail "home's launch of Kate failed"
  KT=$(wwnew 30 "$before" l:); KT=${KT%% *}
  [ -n "$KT" ] || fail "with $plat KWrite hung, Kate opened no web window in 30 s"
  live "$KT" 15 || fail "with $plat KWrite hung, Kate's window $KT never went live"
  [ "$(layer "$KT")" -ge 1 ] || fail "with $plat KWrite hung, Kate's window $KT has no powos-ww-${KT#w}-linux layer"
  pass "with $plat KWrite hung (prompt ${KP:-none}), Kate's window $KT is live with its ww-linux layer"
  K=$(kwin_pid) || fail "could not query kwin_wayland through the Linux session"; [ "$K" = "$K0" ] || fail "KWin is pid ${K:-none} now, was $K0 (died with $plat KWrite hung)"
  # The hung client killed: its window goes, the prompt with it.
  us "kill -KILL $P" >/dev/null
  for _ in $(seq 1 15); do [ -z "$(killers)" ] && [ "$(wwhost "$KW" gone)" = true ] && break; sleep 1; done
  [ -z "$(killers)" ] || fail "the kill prompt $(killers) stayed 15 s after $plat KWrite died"
  [ "$(wwhost "$KW" gone)" = true ] || fail "$plat KWrite's window $KW stayed after it died"
  K=$(kwin_pid) || fail "could not query kwin_wayland through the Linux session"; [ "$K" = "$K0" ] || fail "KWin is pid ${K:-none} now, was $K0"
  pass "$plat KWrite killed: its window and prompt gone, KWin still pid $K0"
  hcall webwindows.close "[${KT#w}]" "v=>String(v)" >/dev/null; sleep 2
  chk "$plat done"
done
n=$(sh_ "tail -n +$((H0 + 1)) $HYPR | grep -c \"kwin_wayland process .* finished\"")
[ "${n:-0}" = 0 ] || fail "kwin_wayland_wrapper logged $n KWin exit(s) during the check"
pass "KWin pid $K0 throughout, no KWin exit logged, Linux windows rendered while a client hung"
