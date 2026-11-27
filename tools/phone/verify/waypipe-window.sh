#!/bin/bash
# lanes: phone
# needs: kwin home
# waypipe-window.sh [APPS...]: a Linux window of .58 on the OnePlus's KWin over waypipe (board task
# remote-linux-window-from-58-on-the-oneplus-via-w; docs/research/native-window-remoting.md §8.6, results §8.7).
# Default APPS: kate dolphin firefox. Per app:
#   .58  the measurement image (tools/research/remoting, Compose project rmm, profile phone: a job in nomad.slice, no
#        tc) runs bin/phone-serve: socat on .58's TCP 15100 -> waypipe server -> the app (Kate/Dolphin lossless `gpu`
#        mode, Firefox `video` = the ARGB-patched build with --video=h264). Never gpu-195.
#   phone in the chroot as the session user: `powos-remote-app --log /tmp/wpw/client.log 192.168.50.58:15100 <app id>`
#        - PowOS's own launch path for a remote app (targets/android/session/powos-remote-app): powos-open-task around
#        `waypipe --debug client` on KWin's wayland-0 + socat from the TCP connection, so KWin is asked to SHOW the
#        window like a launched local app's (unit waypipe: pkgs/waypipe + pkgs/socat). 11-26 00:12 the bare client got
#        Kate's toplevel to KWin, but nothing showed it: folded ("export-new 0") it stayed on KWin's hidden desktop. The window must come up as a NATIVE CHILD SURFACE OF A WEB WINDOW (docs/WEB_WINDOWS.md S6: a new
#        "l:" entry in home's webwindows.list, floating, its .webwindow element with the PowOS title bar and a LIVE body
#        - KWin's buffers on the consumer, not the placeholder); screenshot.
#   input through the phone's own path (no touch): KWin shows the Android keyboard for a focused text field (Kate's
#        editor, Firefox's textarea), and `input keyevent` keys go home's SystemIME -> KWin -> the remote app: 60
#        letters 200 ms apart, then a 10 s scroll (Kate/Dolphin: DOWN held 8 s; Firefox: F8 = page.js's 10 s scroll).
#        Dolphin has no text field (no keyboard): window, screenshot, idle bytes only.
#   logs key->commit p50/p95 from the client's --debug stamps (waypipe 0.11 is not libwayland: WAYLAND_DEBUG does nothing,
#        --debug is its twin), scroll fps / frame gaps, bytes per phase (ss -ti of the TCP connection), Wi-Fi RSSI, TCP
#        retransmits, and whether KWin got DMA-BUFs or shm (§7 Q3) - waypipe-window.py; one JSON line per app in
#        $OUT/results.jsonl, the verdict against §8.2's bar on a "BAR" line.
# Always cleans up: the web windows it opened closed, waypipe/socat ended on the phone (only its own, /tmp/wpw), the
# .58 container removed (rmm phone: `dc --profile phone rm -sf phone`). Nothing stays running on either end.
# Exit (queue.sh): 0 every app's window was a live web window and measured (the bar verdicts are data, on BAR lines);
#   1 FAIL (no window / not a web window / nothing measured); 3 not now (busy, a touch, waypipe not deployed yet).
#   queue.sh add remote-linux-window-from-58-on-the-oneplus-via-w tools/phone/verify/waypipe-window.sh
set -uo pipefail
NAME=waypipe-window; . "$(dirname "$0")/wwc-lib.sh"
# The steps' deadline inside the queue's budget (480 s for this job): 80 s before it, so wwc_clean (its own 40 s) and the
# verdict land before the queue's kill. It was 560 s - past the 480 s budget, so it never fired: 11-25 19:48 the run sat
# 418 s after "kate: .58 serve state started" and the queue killed it with no line saying where.
WW_DEADLINE=${WWC_DEADLINE_S:-$(( ${QUEUE_BUDGET_S:-480} - 80 ))}
# result <text>: a number as it is taken - a "RESULT: " line queue.sh puts on the board task with the verdict, so a
# timeout or a later FAIL never loses what was measured (perf-scenarios.sh result(), 37295929).
result() { say "RESULT: $*"; }
# Per-phase caps (wall clock): every step that waits on the phone, .58 or the page is bounded on its own, and a step
# that runs out says which one and what it saw - never the budget's bare "FAIL timeout".
# cap <s> <cmd...>: the command, TERMed with its children after <s> s; rc 124 then. The killer's output goes nowhere
# (a $(cap ...) caller would otherwise wait for its sleep).
_kids() { local c; for c in $(pgrep -P "$1" 2>/dev/null); do _kids "$c"; done; kill -TERM "$1" 2>/dev/null; }
cap() { local s=$1 p w rc; shift; "$@" & p=$!
  ( sleep "$s"; kill -0 "$p" 2>/dev/null && { _kids "$p"; : > "${TMPDIR:-/tmp}/wpcap.$p"; } ) >/dev/null 2>&1 </dev/null & w=$!
  wait "$p"; rc=$?; pkill -P "$w" 2>/dev/null; kill "$w" 2>/dev/null
  [ -f "${TMPDIR:-/tmp}/wpcap.$p" ] && { rm -f "${TMPDIR:-/tmp}/wpcap.$p"; return 124; }; return $rc; }
# phase <name>: the step being run, its start (elapsed seconds) kept for its RESULT line.
PHASE=setup PH0=$SECONDS
phase() { PHASE=$1 PH0=$SECONDS; }
took() { echo $((SECONDS - PH0)); }
# front: what's in front on the phone and whether home's page answers - said when a page wait runs out (a remote window
# opened as its own task in front hides home, and every page call then waits out its timeout).
front() { echo "front=$(cap 10 sh_ "dumpsys activity activities | grep -m1 topResumedActivity" | sed -nE 's#.*/[a-zA-Z0-9_.]*\.([A-Za-z0-9_$]+) .*#\1#p') home=$(CDP_TIMEOUT_S=5 cap 10 wwc_vis | head -c 20)"; }
# wait_new <cap_s> <before>: a new "l:" web window within cap_s s of wall clock (wwnew counted tries, each up to 4 page
# calls of CDP_TIMEOUT_S: 60 tries could be an hour against a page that stopped answering).
wait_new() { local end=$((SECONDS + $1)) n=""
  while [ "$SECONDS" -lt "$end" ]; do
    n=$(WW_DEADLINE=$end CDP_TIMEOUT_S=5 cap 15 wwids l: | tr ' ' '\n' | grep -vxF -f <(printf '%s\n' $2 _) | head -1)
    [ -n "$n" ] && break; sleep 1; done; echo "$n"; }
ROOT=$(cd "$T/../.." && pwd)
DC="$ROOT/tools/research/remoting/dc"
H58=${WP_HOST:-192.168.50.58} PORT=${WP_PORT:-15100}
APPS=${*:-kate dolphin firefox}
mode_of() { case $1 in firefox) echo video ;; *) echo gpu ;; esac; }
appid_of() { case $1 in firefox) echo firefox ;; *) echo "org.kde.$1" ;; esac; }
rs() { local f; f=$(mktemp "${TMPDIR:-/tmp}/wprs.XXXXXX"); printf '%s\n' "$1" > "$f"; "$T/root.sh" "$f" 2>/dev/null | tr -d '\r'; rm -f "$f"; }
dc() { "$DC" --profile phone "$@"; }
# The phone side as the session user (ww_us: powos-run.sh, the session's environment), KWin's socket named.
PENV='export XDG_RUNTIME_DIR=/run/powos-app WAYLAND_DISPLAY=wayland-0'
# Only this check's own powos-remote-app (its --log /tmp/wpw/), its socat and waypipe client first (bash runs its trap
# only once the foreground socat is gone), never a remote app the user started.
phone_stop() { ww_us "for p in \$(pgrep -f 'powos-remote-app --connect --log /tmp/wpw/'); do pkill -P \$p; kill \$p; done; pkill -f 'powos-open-task --app-id [^ ]* -- [^ ]*powos-remote-app --connect --log /tmp/wpw/'; sleep 0.3; true" >/dev/null; }
wwc_extra() { phone_stop; dc exec -T phone phone-stop >/dev/null 2>&1; dc rm -sf phone >/dev/null 2>&1
  local left; left=$(ww_us "pgrep -af 'waypipe|socat' | grep /tmp/wpw" ); [ -z "$left" ] || say "left on the phone: $left"
  say "cleaned: .58 container $(docker --context "${POW_JOB_CONTEXT:-pow58}" ps -q --filter name=rmm-phone | awk 'NF{f=1} END{exit !f}' && echo STILL UP || echo removed), phone waypipe/socat ended"; }
# ss_sample: the waypipe TCP connection on the phone - "bytes_acked bytes_received retrans_total".
ss_sample() { rs "ss -tin dst $H58 | tr -s ' \t' '\n' | awk -F: '/^bytes_acked:/{a=\$2} /^bytes_received:/{r=\$2} /^retrans:/{split(\$2,x,\"/\"); t=x[2]} END{print a+0, r+0, t+0}'" | tail -1; }
rssi() { sh_ "cmd wifi status" | grep -oE 'RSSI: -?[0-9]+|Link speed: [0-9]+' | tr '\n' ' '; }
now() { sh_ "date +%s.%N" | cut -c1-14; }
keyboard_up() { [ "$(sh_ "dumpsys input_method" | grep -m1 -oE "mInputShown=(true|false)")" = mInputShown=true ]; }

phase packages
pre=$(cap 30 rs 'pacman -Q waypipe socat 2>&1 | tr "\n" " "')
case $pre in *"waypipe 0.11.3"*socat*) say "phone: $pre" ;; *) echo "SKIP: waypipe/socat not deployed on the phone yet ($pre) - stays queued"; exit 3 ;; esac
[ -n "$(cap 30 rs 'command -v powos-remote-app')" ] || { echo "SKIP: powos-remote-app not deployed on the phone yet - stays queued"; exit 3; }
docker --context "${POW_JOB_CONTEXT:-pow58}" image inspect localhost/rmm/remoting:latest >/dev/null 2>&1 ||
  { say "building the measurement image on .58 (tools/research/remoting)"; dc build phone >/dev/null 2>&1 || { echo "SKIP: the .58 image didn't build"; exit 5; }; }
phase home; wwc_start
# Web windows need the unfolded home (AppWindows.floating: display 0's smaller side): ww_ready answers folded too, so
# 11-26 00:12 ran on the cover screen. Unfolded here, put back by wwc_clean (wwc-lib.sh reads UNFOLDED).
# shellcheck disable=SC2034
[ "$(cap 10 sh_ 'cmd device_state print-state' | tr -dc 0-9)" = 0 ] && { fold 3; UNFOLDED=1; sleep 2; say "unfolded (device_state 3)"; }
result "setup: packages + home $(took) s"
phase .58-up
cap 60 dc up -d phone >/dev/null 2>&1 || bad "the .58 container didn't start (rmm phone) in $(took) s"
WPV=$(cap 20 dc exec -T phone sh -c 'waypipe --version; waypipe-argbvideo --version' 2>/dev/null | tr '\n' ' ')
R0=$(cap 10 rssi)
say ".58: $WPV; phone $R0"; result ".58 up $(took) s; phone wifi $(echo "$R0" | grep -oE 'RSSI: -?[0-9]+|Link speed: [0-9]+' | head -2 | tr '\n' ' ')"
OK=0
for app in $APPS; do
  [ "$NF" = 0 ] || break
  mode=$(mode_of "$app"); N="$OUT/$app"; mkdir -p "$N"
  # An app needs ~150 s (connect 30 + window 60 + live 25 + idle/typing/scroll ~35 + close/logs); one that can't fit
  # before the steps' deadline isn't started - the apps measured keep their results.
  [ $((WW_DEADLINE - SECONDS)) -ge 150 ] || { result "$app: not run - $((WW_DEADLINE - SECONDS)) s left before the deadline, it needs ~150 s"; continue; }
  # powos-open-task brings back an existing window of the app id: the user's own local Kate would be raised instead.
  ww_running "$app" && { result "$app: not run - the phone's own $app runs (its window would be raised, not .58's)"; continue; }
  say "== $app ($mode)"
  phase "$app: .58 serve"
  cap 20 dc exec -T -d -u u phone phone-serve "$app" "$mode" "$PORT" >/dev/null 2>&1 || say "$app: phone-serve start rc $? after $(took) s"
  sleep 1
  before=$(WW_DEADLINE=$((SECONDS + 20)) CDP_TIMEOUT_S=10 cap 25 wwids l:)
  phase "$app: phone connect"
  cap 30 ww_us "$PENV; rm -rf /tmp/wpw; mkdir -p /tmp/wpw
setsid -f powos-remote-app --log /tmp/wpw/client.log $H58:$PORT $(appid_of "$app") > /tmp/wpw/open.log 2>&1 < /dev/null
sleep 2; pgrep -af 'powos-remote-app|waypipe --debug|socat TCP' | head -5" | tee -a "$N/phone-start.txt" >/dev/null
  ss0=$(cap 15 ss_sample)
  st=$(cap 15 dc exec -T phone cat /tmp/run/serve.state 2>/dev/null)
  say "$app: .58 serve state ${st:-?}, phone tcp $ss0"
  result "$app: connected in $(took) s, serve state ${st:-?}, phone tcp acked/received/retrans ${ss0:-?}"
  case $st in connected|started) ;; *) bad "$app: the phone's socat never reached $H58:$PORT (serve state ${st:-?}; $(ww_us 'tail -1 /tmp/wpw/open.log'))"; break ;; esac
  phase "$app: window"
  W=$(wait_new 60 "$before")
  if [ -z "$W" ]; then
    ssW=$(cap 15 ss_sample)
    bad "$app: no new Linux web window within $(took) s ($(front); phone tcp ${ssW:-?}; open-task: $(cap 15 ww_us 'tail -3 /tmp/wpw/open.log' | tr '\n' ' '); toplevel: $(cap 15 ww_us 'grep -m1 -oE "set_app_id\([^)]*\)" /tmp/wpw/client.log'))"
    result "$app: no window after $(took) s; phone tcp ${ssW:-?}"
    cap 30 "$T/shot.sh" "$N/no-window.png" >/dev/null 2>&1; break
  fi
  result "$app: web window $W after $(took) s"
  MINE_W="$MINE_W $W"
  phase "$app: live body"
  # The page reads, bounded by wall clock: 25 s for the window's body to go live (it was 20 tries of up to 20 s each).
  end=$((SECONDS + 25)); live=""
  while [ "$SECONDS" -lt "$end" ]; do
    live=$(WW_DEADLINE=$end CDP_TIMEOUT_S=5 cap 8 wwel "$W" "e=>e.querySelector('.webwindow-body.live')?'live':'placeholder'")
    [ "$live" = live ] && break; sleep 1; done
  key=$(CDP_TIMEOUT_S=5 cap 25 wwhost "$W" key); state=$(CDP_TIMEOUT_S=5 cap 25 wwhost "$W" state)
  bar=$(CDP_TIMEOUT_S=5 cap 10 wwbar "$W"); body=$(CDP_TIMEOUT_S=5 cap 10 wwbody "$W")
  [ "$live" = live ] || say "$app: body ${live:-no answer} after $(took) s ($(front))"
  result "$app: body ${live:-no answer} after $(took) s, title bar ${bar:-?}"
  say "$app: web window $W key=$key state=$state body=$live title-bar=$bar body-rect=${body:-none}"
  [ "$live" = live ] && [ "$bar" = true ] && [ -n "$body" ] ||
    bad "$app: window $W is not a live native child surface of a web window (body $live, title bar $bar)"
  sleep 4
  cap 30 "$T/shot.sh" "$N/window.png" >/dev/null 2>&1 && say "$app: screenshot $N/window.png"
  phase "$app: input"
  # Phases: samples on the phone's clock (the client log's), bytes from ss before/after each.
  PH="{}" SS="{\"start\": \"$ss0\""
  end=$((SECONDS + 12)); while [ "$SECONDS" -lt "$end" ]; do cap 8 keyboard_up && break; sleep 1; done
  kb=$(cap 8 keyboard_up && echo yes || echo no); say "$app: Android keyboard for its text field: $kb"
  t0=$(cap 10 now); s0=$(cap 15 ss_sample); sleep 10; t1=$(cap 10 now); s1=$(cap 15 ss_sample)
  PH="\"idle\": [$t0, $t1]"; SS="$SS, \"idle0\": \"$s0\", \"idle1\": \"$s1\""
  result "$app: idle 10 s, phone tcp ${s0:-?} -> ${s1:-?}; keyboard $kb"
  if [ "$kb" = yes ]; then
    letters=$(python3 -c 'import random; r=random.Random(1); print(" ".join("KEYCODE_"+r.choice("ABCDEFGHIJKLMNOPQRSTUVWXYZ") for _ in range(60)))')
    t0=$(cap 10 now); s0=$(cap 15 ss_sample)
    cap 40 sh_ "echo \$(( \$(date +%s) + 30 )) > /data/local/tmp/powos-selfinput; input keyevent --delay 200 $letters"
    t1=$(cap 10 now); s1=$(cap 15 ss_sample)
    PH="$PH, \"typing\": [$t0, $t1]"; SS="$SS, \"typing0\": \"$s0\", \"typing1\": \"$s1\""
    sleep 1.5
    t0=$(cap 10 now); s0=$(cap 15 ss_sample)
    if [ "$app" = firefox ]; then sh_ "input keyevent KEYCODE_F8"; sleep 10
    else sh_ "echo \$(( \$(date +%s) + 12 )) > /data/local/tmp/powos-selfinput; input keyevent --duration 8000 KEYCODE_DPAD_DOWN"; fi
    t1=$(cap 10 now); s1=$(cap 15 ss_sample)
    [ "$app" = firefox ] && sh_ "input keyevent KEYCODE_F9"
    PH="$PH, \"scroll\": [$t0, $t1]"; SS="$SS, \"scroll0\": \"$s0\", \"scroll1\": \"$s1\""
    cap 30 "$T/shot.sh" "$N/after-input.png" >/dev/null 2>&1
    sh_ "input keyevent KEYCODE_BACK" >/dev/null   # the keyboard down
  else
    say "$app: no keyboard (no focused text field) - window, idle bytes and buffer path only"
  fi
  ssE=$(cap 15 ss_sample); R=$(cap 10 rssi)
  SS="$SS, \"end\": \"$ssE\"}"
  # Close: the web window's own close (KWin quit) first, then the transport on both ends.
  phase "$app: close"
  CDP_TIMEOUT_S=10 cap 30 ww_close "$W"; MINE_W=${MINE_W% $W}
  sleep 1; cap 20 dc exec -T phone phone-stop >/dev/null 2>&1; cap 20 phone_stop
  cap 30 ww_us "gzip -c /tmp/wpw/client.log" > "$N/client.log.gz" 2>/dev/null
  cap 30 dc exec -T phone sh -c 'cat /tmp/run/app.log' > "$N/server.log" 2>/dev/null
  gunzip -f "$N/client.log.gz" 2>/dev/null
  python3 - "$N/net.json" "{$PH}" "$SS" "$R" <<'PY'
import json, re, sys
out, ph, ss, r = sys.argv[1], json.loads(sys.argv[2]), json.loads(sys.argv[3]), sys.argv[4]
f = lambda s: dict(zip(("bytes_acked", "bytes_received", "retrans_total"), map(int, s.split()))) if s.strip() else {}
m = re.search(r"RSSI: (-?\d+)", r); l = re.search(r"Link speed: (\d+)", r)
json.dump({"phases": ph, "ss": {k: f(v) for k, v in ss.items()}, "rssi": int(m.group(1)) if m else None,
           "link": int(l.group(1)) if l else None}, open(out, "w"))
PY
  res=$(cap 30 python3 "$T/verify/waypipe-window.py" "$N/client.log" "$N/net.json" "$app" "$mode" 2>&1 | tail -1)
  printf '%s\n' "$res" >> "$OUT/results.jsonl"
  say "$app: $res"
  result "$app: $(printf %s "$res" | cut -c1-200)"
  say "BAR $app: $(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("bar","?"))' "$res" 2>/dev/null)"
  OK=$((OK + 1))
done
[ "$OK" -gt 0 ] || bad "no app measured"
wwc_end "$OK app(s) as live web windows over waypipe from .58 - $OUT/results.jsonl"
