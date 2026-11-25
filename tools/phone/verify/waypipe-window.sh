#!/bin/bash
# lanes: phone
# needs: kwin home
# waypipe-window.sh [APPS...]: a Linux window of .58 on the OnePlus's KWin over waypipe (board task
# remote-linux-window-from-58-on-the-oneplus-via-w; docs/research/native-window-remoting.md §8.6, results §8.7).
# Default APPS: kate dolphin firefox. Per app:
#   .58  the measurement image (tools/research/remoting, Compose project rmm, profile phone: a job in nomad.slice, no
#        tc) runs bin/phone-serve: socat on .58's TCP 15100 -> waypipe server -> the app (Kate/Dolphin lossless `gpu`
#        mode, Firefox `video` = the ARGB-patched build with --video=h264). Never gpu-195.
#   phone in the chroot as the session user: `waypipe --debug -s /tmp/wpw/wp.sock client` on KWin's wayland-0, plus
#        `socat TCP:192.168.50.58:15100 UNIX-CONNECT:/tmp/wpw/wp.sock` (unit waypipe: our packages, pkgs/waypipe +
#        pkgs/socat). The window must come up as a NATIVE CHILD SURFACE OF A WEB WINDOW (docs/WEB_WINDOWS.md S6: a new
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
WW_DEADLINE=${WWC_DEADLINE_S:-560}
ROOT=$(cd "$T/../.." && pwd)
DC="$ROOT/tools/research/remoting/dc"
H58=${WP_HOST:-192.168.50.58} PORT=${WP_PORT:-15100}
APPS=${*:-kate dolphin firefox}
mode_of() { case $1 in firefox) echo video ;; *) echo gpu ;; esac; }
rs() { local f; f=$(mktemp "${TMPDIR:-/tmp}/wprs.XXXXXX"); printf '%s\n' "$1" > "$f"; "$T/root.sh" "$f" 2>/dev/null | tr -d '\r'; rm -f "$f"; }
dc() { "$DC" --profile phone "$@"; }
# The phone side as the session user (ww_us: powos-run.sh, the session's environment), KWin's socket named.
PENV='export XDG_RUNTIME_DIR=/run/powos-app WAYLAND_DISPLAY=wayland-0'
phone_stop() { ww_us "pkill -f 'waypipe --debug -s /tmp/wpw/' ; pkill -f 'UNIX-CONNECT:/tmp/wpw/'; sleep 0.3; pgrep -af 'waypipe|socat' | grep /tmp/wpw || true" >/dev/null; }
wwc_extra() { phone_stop; dc exec -T phone phone-stop >/dev/null 2>&1; dc rm -sf phone >/dev/null 2>&1
  local left; left=$(ww_us "pgrep -af 'waypipe|socat' | grep /tmp/wpw" ); [ -z "$left" ] || say "left on the phone: $left"
  say "cleaned: .58 container $(docker --context "${POW_JOB_CONTEXT:-pow58}" ps -q --filter name=rmm-phone | awk 'NF{f=1} END{exit !f}' && echo STILL UP || echo removed), phone waypipe/socat ended"; }
# ss_sample: the waypipe TCP connection on the phone - "bytes_acked bytes_received retrans_total".
ss_sample() { rs "ss -tin dst $H58 | tr -s ' \t' '\n' | awk -F: '/^bytes_acked:/{a=\$2} /^bytes_received:/{r=\$2} /^retrans:/{split(\$2,x,\"/\"); t=x[2]} END{print a+0, r+0, t+0}'" | tail -1; }
rssi() { sh_ "cmd wifi status" | grep -oE 'RSSI: -?[0-9]+|Link speed: [0-9]+' | tr '\n' ' '; }
now() { sh_ "date +%s.%N" | cut -c1-14; }
keyboard_up() { [ "$(sh_ "dumpsys input_method" | grep -m1 -oE "mInputShown=(true|false)")" = mInputShown=true ]; }

pre=$(rs 'pacman -Q waypipe socat 2>&1 | tr "\n" " "')
case $pre in *"waypipe 0.11.3"*socat*) say "phone: $pre" ;; *) echo "SKIP: waypipe/socat not deployed on the phone yet ($pre) - stays queued"; exit 3 ;; esac
docker --context "${POW_JOB_CONTEXT:-pow58}" image inspect localhost/rmm/remoting:latest >/dev/null 2>&1 ||
  { say "building the measurement image on .58 (tools/research/remoting)"; dc build phone >/dev/null 2>&1 || { echo "SKIP: the .58 image didn't build"; exit 5; }; }
wwc_start
dc up -d phone >/dev/null 2>&1 || bad "the .58 container didn't start (rmm phone)"
WPV=$(dc exec -T phone sh -c 'waypipe --version; waypipe-argbvideo --version' 2>/dev/null | tr '\n' ' ')
say ".58: $WPV; phone $(rssi)"
OK=0
for app in $APPS; do
  [ "$NF" = 0 ] || break
  mode=$(mode_of "$app"); N="$OUT/$app"; mkdir -p "$N"
  say "== $app ($mode)"
  dc exec -T -d -u u phone phone-serve "$app" "$mode" "$PORT" >/dev/null 2>&1
  sleep 1
  before=$(wwids l:)
  ww_us "$PENV; rm -rf /tmp/wpw; mkdir -p /tmp/wpw
setsid -f waypipe --debug -s /tmp/wpw/wp.sock client > /tmp/wpw/client.log 2>&1 < /dev/null
for i in \$(seq 50); do [ -S /tmp/wpw/wp.sock ] && break; sleep 0.1; done
setsid -f socat TCP:$H58:$PORT,nodelay UNIX-CONNECT:/tmp/wpw/wp.sock > /tmp/wpw/socat.log 2>&1 < /dev/null
sleep 1; pgrep -af 'waypipe --debug|UNIX-CONNECT:/tmp/wpw' | head -3" | tee -a "$N/phone-start.txt" >/dev/null
  ss0=$(ss_sample)
  st=$(dc exec -T phone cat /tmp/run/serve.state 2>/dev/null)
  say "$app: .58 serve state ${st:-?}, phone tcp $ss0"
  case $st in connected|started) ;; *) bad "$app: the phone's socat never reached $H58:$PORT (serve state ${st:-?}; $(ww_us 'cat /tmp/wpw/socat.log' | tail -1))"; break ;; esac
  W=$(wwnew 60 "$before" l:)
  W=$(echo "$W" | head -1)
  if [ -z "$W" ]; then
    bad "$app: no new Linux web window within 60 s ($(ww_us 'grep -m3 -E "Wrn|ERR" /tmp/wpw/client.log'))"
    "$T/shot.sh" "$N/no-window.png" >/dev/null 2>&1; break
  fi
  MINE_W="$MINE_W $W"
  key=$(wwhost "$W" key); state=$(wwhost "$W" state)
  for _ in $(seq 20); do [ "$(wwel "$W" "e=>e.querySelector('.webwindow-body.live')?'live':'placeholder'")" = live ] && break; sleep 1; done
  live=$(wwel "$W" "e=>e.querySelector('.webwindow-body.live')?'live':'placeholder'")
  bar=$(wwbar "$W"); body=$(wwbody "$W")
  say "$app: web window $W key=$key state=$state body=$live title-bar=$bar body-rect=${body:-none}"
  [ "$live" = live ] && [ "$bar" = true ] && [ -n "$body" ] ||
    bad "$app: window $W is not a live native child surface of a web window (body $live, title bar $bar)"
  sleep 4
  "$T/shot.sh" "$N/window.png" >/dev/null 2>&1 && say "$app: screenshot $N/window.png"
  # Phases: samples on the phone's clock (the client log's), bytes from ss before/after each.
  PH="{}" SS="{\"start\": \"$ss0\""
  for _ in $(seq 10); do keyboard_up && break; sleep 1; done
  kb=$(keyboard_up && echo yes || echo no); say "$app: Android keyboard for its text field: $kb"
  t0=$(now); s0=$(ss_sample); sleep 10; t1=$(now); s1=$(ss_sample)
  PH="\"idle\": [$t0, $t1]"; SS="$SS, \"idle0\": \"$s0\", \"idle1\": \"$s1\""
  if [ "$kb" = yes ]; then
    letters=$(python3 -c 'import random; r=random.Random(1); print(" ".join("KEYCODE_"+r.choice("ABCDEFGHIJKLMNOPQRSTUVWXYZ") for _ in range(60)))')
    t0=$(now); s0=$(ss_sample)
    sh_ "echo \$(( \$(date +%s) + 30 )) > /data/local/tmp/powos-selfinput; input keyevent --delay 200 $letters"
    t1=$(now); s1=$(ss_sample)
    PH="$PH, \"typing\": [$t0, $t1]"; SS="$SS, \"typing0\": \"$s0\", \"typing1\": \"$s1\""
    sleep 1.5
    t0=$(now); s0=$(ss_sample)
    if [ "$app" = firefox ]; then sh_ "input keyevent KEYCODE_F8"; sleep 10
    else sh_ "echo \$(( \$(date +%s) + 12 )) > /data/local/tmp/powos-selfinput; input keyevent --duration 8000 KEYCODE_DPAD_DOWN"; fi
    t1=$(now); s1=$(ss_sample)
    [ "$app" = firefox ] && sh_ "input keyevent KEYCODE_F9"
    PH="$PH, \"scroll\": [$t0, $t1]"; SS="$SS, \"scroll0\": \"$s0\", \"scroll1\": \"$s1\""
    "$T/shot.sh" "$N/after-input.png" >/dev/null 2>&1
    sh_ "input keyevent KEYCODE_BACK" >/dev/null   # the keyboard down
  else
    say "$app: no keyboard (no focused text field) - window, idle bytes and buffer path only"
  fi
  ssE=$(ss_sample); R=$(rssi)
  SS="$SS, \"end\": \"$ssE\"}"
  # Close: the web window's own close (KWin quit) first, then the transport on both ends.
  ww_close "$W"; MINE_W=${MINE_W% $W}
  sleep 1; dc exec -T phone phone-stop >/dev/null 2>&1; phone_stop
  ww_us "gzip -c /tmp/wpw/client.log" > "$N/client.log.gz" 2>/dev/null
  dc exec -T phone sh -c 'cat /tmp/run/app.log' > "$N/server.log" 2>/dev/null
  gunzip -f "$N/client.log.gz" 2>/dev/null
  python3 - "$N/net.json" "{$PH}" "$SS" "$R" <<'PY'
import json, re, sys
out, ph, ss, r = sys.argv[1], json.loads(sys.argv[2]), json.loads(sys.argv[3]), sys.argv[4]
f = lambda s: dict(zip(("bytes_acked", "bytes_received", "retrans_total"), map(int, s.split()))) if s.strip() else {}
m = re.search(r"RSSI: (-?\d+)", r); l = re.search(r"Link speed: (\d+)", r)
json.dump({"phases": ph, "ss": {k: f(v) for k, v in ss.items()}, "rssi": int(m.group(1)) if m else None,
           "link": int(l.group(1)) if l else None}, open(out, "w"))
PY
  res=$(python3 "$T/verify/waypipe-window.py" "$N/client.log" "$N/net.json" "$app" "$mode" 2>&1 | tail -1)
  printf '%s\n' "$res" >> "$OUT/results.jsonl"
  say "$app: $res"
  say "BAR $app: $(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("bar","?"))' "$res" 2>/dev/null)"
  OK=$((OK + 1))
done
[ "$OK" -gt 0 ] || bad "no app measured"
wwc_end "$OK app(s) as live web windows over waypipe from .58 - $OUT/results.jsonl"
