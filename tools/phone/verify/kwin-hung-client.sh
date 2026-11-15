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
# The session user's /proc hides live KWin despite its matching UID. Enumerate
# as root with an absolute Linux executable (Android's inherited PATH is wrong),
# scoped to powos's UID. Only rc=1 is absence; unknown visibility never grants
# ownership for cleanup. This intentionally does not change runtime permissions.
linux_pids() {
  local answer pid
  case $1 in kwin_wayland|kwrite|kate) ;; *) return 1 ;; esac
  answer=$(sh_ "p=\$(chroot /data/powos/root /usr/bin/pgrep -u powos -x $1); rc=\$?; case \$rc in 0) echo \"\$p\" ;; 1) echo none ;; *) exit \"\$rc\" ;; esac") || return 1
  [ -n "$answer" ] || return 1
  if [ "$answer" != none ]; then
    for pid in $answer; do [[ "$pid" =~ ^[0-9]+$ ]] || return 1; done
  fi
  printf '%s\n' "$answer"
}
kwin_pid() {
  local answer
  answer=$(linux_pids kwin_wayland) || return 1
  printf '%s\n' "${answer%%$'\n'*}"
}
# Root proc identity: state and starttime (not PID alone). A reused PID is not
# the original process, and must never be signalled on its behalf.
proc_record() {
  local stat fields
  [[ "$1" =~ ^[0-9]+$ ]] || return 1
  stat=$(sh_ "if [ -d /proc/$1 ]; then cat /proc/$1/stat; else echo absent; fi") || return 1
  [ "$stat" != absent ] || { echo absent; return; }
  fields=${stat##*) }; set -- $fields
  [ "$#" -ge 20 ] || return 1
  [[ "${20}" =~ ^[0-9]+$ ]] || return 1
  printf '%s %s\n' "$1" "${20}"
}
proc_state() { # PID original-starttime -> live:<state>, zombie, absent, reused
  local record state start
  record=$(proc_record "$1") || return 1
  [ "$record" != absent ] || { echo absent; return; }
  read -r state start <<< "$record"
  [ "$start" = "$2" ] || { echo reused; return; }
  case $state in Z|X) echo zombie ;; [A-Zt]) echo "live:$state" ;; *) return 1 ;; esac
}
killers() {
  # Match the helper executable AND an exact --pid argument, not a title or
  # another client's helper. Root visibility is required here as for KWrite.
  local answer
  answer=$(sh_ "p=\$(chroot /data/powos/root /usr/bin/pgrep -u powos -f \"(^|/)kwin_killer_helper .*--pid $P( |$)\"); rc=\$?; case \$rc in 0) echo \"\$p\" ;; 1) echo none ;; *) exit \"\$rc\" ;; esac") || return 1
  [ "$answer" != none ] || return 0
  [ -n "$answer" ] || return 1
  local pid
  for pid in $answer; do [[ "$pid" =~ ^[0-9]+$ ]] || return 1; done
  printf '%s\n' "$answer"
}
remember_helpers() {
  local ids id rec state start
  ids=$(killers) || return 1
  for id in $ids; do
    case " $HELPERS " in *" $id:"*) continue ;; esac
    rec=$(proc_record "$id") || return 1
    [ "$rec" != absent ] || continue
    read -r state start <<< "$rec"
    HELPERS="$HELPERS $id:$start"
  done
}
kill_owned_client() {
  local state
  state=$(proc_state "$P" "$PSTART") || return 1
  case $state in live:*) ;; *) log "refused SIGKILL: KWrite $P identity/state=$state"; return 1 ;; esac
  # Verify identity again in the same remote command as the signal.
  sh_ "s=\$(cat /proc/$P/stat) || exit 1; f=\${s##*) }; set -- \$f; [ \"\${20}\" = $PSTART ] || exit 1; kill -KILL $P"
}
retirement_sample() {
  local helper id start state
  CLIENT_STATE=$(proc_state "$P" "$PSTART") || CLIENT_STATE=unknown
  # Always sample the window, even if a process is still present.
  WINDOW_GONE=$(wwhost "$KW" gone)
  INVENTORY=$(hcall webwindows.list "[]" "v=>JSON.stringify(v)")
  HELPER_STATE=""; RETIRED=1
  case $INVENTORY in \[*\]) ;; *) RETIRED=0 ;; esac
  remember_helpers || { HELPER_STATE=query-error; RETIRED=0; }
  for helper in $HELPERS; do
    id=${helper%:*}; start=${helper#*:}
    state=$(proc_state "$id" "$start") || state=unknown
    HELPER_STATE="$HELPER_STATE $id:$state"
    case $state in absent|zombie|reused) ;; *) RETIRED=0 ;; esac
  done
  case $CLIENT_STATE in absent|zombie|reused) ;; *) RETIRED=0 ;; esac
  [ "$WINDOW_GONE" = true ] || RETIRED=0
  # Separate helper windows, when exported by the host, must disappear too.
  for id in $PROMPT_WINDOWS; do
    [ "$(wwhost "$id" gone)" = true ] || RETIRED=0
  done
  log "retirement: KWrite=$P:$CLIENT_STATE window=$KW gone=$WINDOW_GONE helpers=[$HELPER_STATE] windows=$INVENTORY"
  [ "$RETIRED" = 1 ]
}
retire_client() {
  local until
  if ! kill_owned_client; then
    retirement_sample || true
    fail "SIGKILL failed or KWrite identity changed ($P:$PSTART); retirement evidence captured"
  fi
  until=$((SECONDS + 15))
  while :; do
    retirement_sample && return 0
    [ "$SECONDS" -lt "$until" ] || break
    sleep 1
  done
  fail "retirement deadline: KWrite=$CLIENT_STATE windowGone=$WINDOW_GONE helpers=[$HELPER_STATE] (inventory captured before cleanup)"
}
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
K0=$(kwin_pid) || { echo "FAIL: could not query kwin_wayland through root Linux process lookup"; exit 1; }
[ "$K0" != none ] || { echo "ENV: no kwin_wayland runs"; exit 5; }
# No cleanup is armed before these read-only preconditions succeed.
existing=$(linux_pids kwrite) || { echo "could not check existing KWrite processes: not now"; exit 3; }
[ "$existing" = none ] || { echo "KWrite already runs or could not be checked: not now"; exit 3; }
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
  P=$(linux_pids kwrite) || fail "could not query KWrite processes"
  [[ "$P" =~ ^[0-9]+$ ]] || fail "expected exactly one kwrite process, got $P"
  rec=$(proc_record "$P") || fail "could not record KWrite identity"
  read -r state PSTART <<< "$rec"
  [[ "$PSTART" =~ ^[0-9]+$ ]] || fail "KWrite vanished before STOP"
  us "kill -STOP $P" >/dev/null || fail "could not stop KWrite $P"
  log "KWrite $P ($plat, window $KW) stopped"
  PROMPT_BEFORE=$(wwids l:kwin_killer_helper)
  sleep 1; close_kwin; log "KWin asked to close it (closeWindow: delete + ping)"
  # KWin's ping times out in killPingTimeout (5 s): the prompt's process starts then.
  for _ in $(seq 1 12); do [ -n "$(killers)" ] && break; sleep 1; done
  KP=$(killers) || fail "could not query owned kill prompt"
  HELPERS=""; remember_helpers || fail "could not record helper identity"
  PROMPT_WINDOWS=""
  prompt_now=$(wwids l:kwin_killer_helper)
  case $prompt_now in ERR*) fail "could not record prompt windows" ;; esac
  for id in $prompt_now; do
    case " $PROMPT_BEFORE " in *" $id "*) ;; *) PROMPT_WINDOWS="$PROMPT_WINDOWS $id" ;; esac
  done
  case $PROMPT_WINDOWS in ERR*) fail "could not record prompt windows" ;; esac
  log "kill prompt: ${KP:-none}, identities:$HELPERS"
  [ -n "$KP" ] || log "(no prompt came up - KWin's ping may be off; the rest still holds)"
  chk hung
  # The rest of Linux keeps rendering: a new Kate window goes live with its layer, while KWrite hangs.
  before=$(wwids l:)
  kate_before=$(linux_pids kate) || fail "could not check existing Kate processes"
  [ "$kate_before" != none ] || KATE_MINE=1
  [ "$(plaunch l:org.kde.kate)" = ok ] || fail "home's launch of Kate failed"
  KT=$(wwnew 30 "$before" l:); KT=${KT%% *}
  [ -n "$KT" ] || fail "with $plat KWrite hung, Kate opened no web window in 30 s"
  live "$KT" 15 || fail "with $plat KWrite hung, Kate's window $KT never went live"
  [ "$(layer "$KT")" -ge 1 ] || fail "with $plat KWrite hung, Kate's window $KT has no powos-ww-${KT#w}-linux layer"
  pass "with $plat KWrite hung (prompt ${KP:-none}), Kate's window $KT is live with its ww-linux layer"
  K=$(kwin_pid) || fail "could not query kwin_wayland through root Linux process lookup"; [ "$K" = "$K0" ] || fail "KWin is pid ${K:-none} now, was $K0 (died with $plat KWrite hung)"
  # The hung client killed: its window goes, the prompt with it.
  retire_client
  K=$(kwin_pid) || fail "could not query kwin_wayland through root Linux process lookup"; [ "$K" = "$K0" ] || fail "KWin is pid ${K:-none} now, was $K0"
  pass "$plat KWrite killed: its window and prompt gone, KWin still pid $K0"
  hcall webwindows.close "[${KT#w}]" "v=>String(v)" >/dev/null; sleep 2
  chk "$plat done"
done
n=$(sh_ "tail -n +$((H0 + 1)) $HYPR | grep -c \"kwin_wayland process .* finished\"")
[ "${n:-0}" = 0 ] || fail "kwin_wayland_wrapper logged $n KWin exit(s) during the check"
pass "KWin pid $K0 throughout, no KWin exit logged, Linux windows rendered while a client hung"
