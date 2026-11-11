#!/bin/bash
# lanes: phone
# tools/phone/verify/window-render.sh: does a PowOS web window (ui/webwindows.tsx + WebWindows.kt: a virtual display
# mirrored into a hole in home's page) SHOW its app and TAKE its touches - on the glass, not in a headless gate?
# Why (2026-10-31): web windows shipped as empty frames twice in one night with every headless gate green. This is the
# device check the ship service runs after a ship that touches window files (tools/phone/ship.sh window_gate).
#   tools/phone/verify/window-render.sh        exit 0 PASS, 1 FAIL, 2 SKIP (user active / folded / phone not free)
#   tools/phone/verify/window-render.sh --hidden   exit 0 PASS, 1 FAIL (timeout included), never a skip: the ship gate's
#                                                  run - the host path on a display nobody sees (see hidden() below)
#   tools/phone/verify/window-render.sh --hidden --hold S   the same, its display kept up S s after content+tap pass
#                                                  (ship.sh runs render_watch across it; see hold below)
#   --hidden exit 2 = NOT JUDGED: the phone isn't Awake (asleep()) - at the start, before a judged step (content, tap,
#                                                  resize, each hold sample) or when one fails. The hidden display goes
#                                                  dark with the screen (10-31 889b6cb5, a4dcb83b), so nothing can be
#                                                  judged; ship.sh window_gate keeps the ship's requests and retries.
#                                                  Also when the Linux step fails while the user touched the phone (f384),
#                                                  and when the user's page's window list changed during the check (the
#                                                  user opened/closed a window, 11-03).
#                                                  Exception (11-02, the ship service deadlocked all night on a dozing
#                                                  phone): when the USER hasn't touched it for WR_WAKE_IDLE_S (600) s
#                                                  (idle.sh's touch IRQ idle, not the screen state) the check wakes the
#                                                  screen as ship-guard.sh's boot check does (KEYCODE_WAKEUP + dismiss
#                                                  the swipe lock), keeps it on with a wake key before each judged step,
#                                                  and puts it back to sleep at the end - unless a real touch came in
#                                                  meanwhile (then it's the user's: left on, no more wake keys). No
#                                                  setting is changed. WR_WAKE_IDLE_S=0 turns the wake off.
# What it does, touching nothing of the user's:
#   1. waits (idle.sh --wait, AWAKE_ONLY) for the screen on and no touch for WR_IDLE_S (30) s, the keyguard down and the
#      phone unfolded (web windows only exist there), up to WR_WAIT_S (900) s; else "SKIP: user active" (or folded),
#      exit 2. Holds the verify lock (an install waits for it); a real finger during the run (touch IRQs move) ends it:
#      its own window closed, exit 2.
#   2. opens TEST_APP (Calculator) as a web window through the page's own path (webwindows.tsx openWindow - what the
#      dock's launch -> openWebWindow runs unfolded) on home's current page. Refused (SKIP) when that app already has a
#      window or a task: that could be the user's.
#   3. reads the window's body rect from the page (.webwindow-body getBoundingClientRect x devicePixelRatio, inset 6 px).
#   4. content, from `screencap` (raw, every 2nd px of the body rect; window-render.py):
#        differs  >= 35% of the body's pixels differ from the same rect shot BEFORE the window opened (home's page and
#                 wallpaper there): an empty hole shows exactly that, so it can't pass;
#        not flat the most common colour (4 bits/channel) covers < 97% and >= 0.3% of neighbouring pixels are edges: a
#                 solid fill (an unmirrored layer, the placeholder's surface) can't pass;
#        live     the page marked it live ("webwindows.live": the host saw the app's first frame) within 15 s.
#   5. a tap through the real body path: pointerdown/up dispatched ON .webwindow-body, so Body's own handler sends it
#      (powos.webwindows.input -> WebWindows.forward -> the helper's injector, 1162412c) - on Calculator's "7" key
#      (WR_TAP "fx fy" of the body). The app got it when its pixels changed for good (the 7 in its display): the body
#      1.5 s after the tap vs just before differs by >= 0.1% and by more than 3x the noise of two shots without a tap.
#      The helper's "log touch ... : ok" lines are reported beside it (the injection, not the reception).
#   6. closes only its own window (webwindows.close <its id> - the host removes the task it made), and checks it's gone.
# PASS = 4 and 5 all hold. Shots (PNG, whole screen + the body crop) and log.txt in WR_OUT/<stamp>/.
set -uo pipefail
# WR_TOOLS: tools/phone to use (the ship service runs a copy of this script beside its checkout, which it resets).
here=$(cd "$(dirname "$0")" && pwd); T=${WR_TOOLS:-$here/..}; A="$T/adb.sh"
APP=${TEST_APP:-com.oneplus.calculator}
OUT=${WR_OUT:-$HOME/.cache/powos-window-render}/$(date +%Y%m%d-%H%M%S); mkdir -p "$OUT"
PY="python3 -I $here/window-render.py"
L=$HOME/.cache/powos-verify.lock
log() { echo "$*" | tee -a "$OUT/log.txt"; }
# >>> fifo-bounds (test/tier1/test-window-render-fifo.sh runs these two)
# mt SECS CMD...: CMD bounded to SECS s, in a process group of its own: on the deadline (or a TERM/INT to mt) the whole
# group gets TERM, then KILL 2 s later - a docker exec/adb child left alive keeps its pipe open and the reader (tr)
# waiting. rc 124 on the deadline. 11-11 14:50: an unbounded adb call in the check's cleanup held the ship service 2.5 h.
mt() { perl -e 'my $t = shift; my $p = fork(); defined $p or exit 127;
  if (!$p) { setpgrp(0, 0); exec @ARGV; exit 127 }
  setpgrp($p, $p); my $end = sub { kill "TERM", -$p;
    for (1 .. 20) { last unless kill 0, -$p; select undef, undef, undef, 0.1 } kill "KILL", -$p; waitpid($p, 0); exit $_[0] };
  $SIG{ALRM} = sub { $end->(124) }; $SIG{TERM} = sub { $end->(143) }; $SIG{INT} = sub { $end->(130) };
  alarm $t; waitpid($p, 0); exit($? & 127 ? 128 + ($? & 127) : $? >> 8)' "$@"; }
# fifo_put_cmd DIR MSG: the phone-side sh for one line to the helper's stdin fifo DIR/in that can never block: skipped
# ("gone") when the helper (DIR/helper: app_process's pid) has exited, and the fifo opened read-write (1<>), which never
# waits for a reader as `> fifo` does. 11-11 14:50: `echo release 145 > .../in` after the helper (and its holder) had
# exited blocked forever - the ship service's device window check, and every ship behind it, stuck for 2.5 h.
fifo_put_cmd() { echo "p=\$(cat $1/helper 2>/dev/null); if [ -p $1/in ] && [ -n \"\$p\" ] && kill -0 \$p 2>/dev/null; then echo $2 1<>$1/in && echo sent; else echo gone; fi"; }
# <<< fifo-bounds
# sh_ CMD: one root shell command on the phone, bounded to SH_T (60) s (hclean: 15 s per call).
sh_() { mt "${SH_T:-60}" "$A" shell "su -c '$*'" </dev/null 2>/dev/null | tr -d '\r'; }
# asleep: true when the phone's power state isn't Awake (Dozing/Asleep/Dreaming); WAKE is that state. Read-only
# (dumpsys power) - it never wakes the screen. Unreadable (no answer) counts as awake: the step is judged as before.
asleep() { WAKE=$(mt "${SH_T:-60}" "$A" shell "dumpsys power | grep -m1 mWakefulness=" </dev/null 2>/dev/null | tr -d '\r ' | cut -d= -f2); [ -n "$WAKE" ] && [ "$WAKE" != Awake ] && return 0
  # Locked counts as asleep: the test display is in the default display group since 63cdfdb9, so it follows the
  # keyguard and draws no app (11-01 04:18: 16 colours, flat, the phone woken by keys but still on its swipe lock).
  mt "${SH_T:-60}" "$A" shell "dumpsys window | grep -m1 isKeyguardShowing" </dev/null 2>/dev/null | grep -q "isKeyguardShowing=true" && { WAKE=locked; return 0; }; return 1; }
UNQ='import json,sys
s=sys.stdin.read().strip()
try:
    v=json.loads(s)
except Exception:
    v=s
print(v if isinstance(v,str) else json.dumps(v))'
ev() { CDP_TIMEOUT_S=${CDP_TIMEOUT_S:-20} "$T/cdp.sh" eval home "$1" 2>/dev/null | tr -d '\r' | tail -1 | python3 -c "$UNQ"; }
WW='Promise.all([importShim("./state.ts"),importShim("./ui/webwindows.tsx")])'
irq() { sh_ "awk '\''/touch-0/{for(i=2;i<=NF;i++) if(\$i ~ /^[0-9]+\$/) s+=\$i; else break} END{print s}'\'' /proc/interrupts"; }
ID= LOCKED= P0=
cleanup() {
  if [ -n "$ID" ]; then
    # Only our window: by its id, through the host (it removes the task it launched there).
    ev "new Promise(ok=>{const h=window.__powosHost,P=window.PowosHost;if(!h||!P)return ok('no bridge');const r=h.resolve,j=h.reject,id=931700+Math.floor(Math.random()*900);const done=v=>{h.resolve=r;h.reject=j;ok(String(v))};h.resolve=(i,v)=>i===id?done(v):r(i,v);h.reject=(i,m)=>i===id?done('ERR '+m):j(i,m);setTimeout(()=>done('no answer'),8000);P.postMessage(JSON.stringify([id,'webwindows.close',JSON.stringify([$ID])]))})" >/dev/null
    gone=
    for _ in 1 2 3 4 5 6; do
      [ "$(ev "$WW.then(([s,m])=>String(m.webWins.value.some(w=>w.id===$ID)))")" = false ] && { gone=1; break; }; sleep 1
    done
    [ -n "$gone" ] && log "closed window $ID" || log "WARNING: window $ID still in the page's list after close"
    ID=
  fi
  [ -n "${P0:-}" ] && { ev "importShim('./state.ts').then(s=>{s.page.value=$P0;return 'ok'})" >/dev/null; log "home back on page $P0"; P0=; }
  [ -n "$LOCKED" ] && [ "$(cut -d' ' -f1 "$L/who" 2>/dev/null)" = window-render ] && rm -rf "$L"; LOCKED=
}
trap 'cleanup' EXIT
trap 'cleanup; exit 143' TERM INT
skip() { log "SKIP: $*"; log "window-render: SKIP ($*) - $OUT"; exit 2; }
verdict() {
  # A FAIL keeps the window path's own record: the ring log WebWindows/WebWindowLaunch/FreeformTasks append to
  # (shell/WindowLog.kt: files/window-log.1.txt then window-log.txt, ~1 h+) and logcat's window tags as they are now.
  if [ "$1" = FAIL ]; then
    "$A" exec-out "su -c 'cat /data/data/com.powos.app/files/window-log.1.txt /data/data/com.powos.app/files/window-log.txt 2>/dev/null'" > "$OUT/window-log.txt" 2>/dev/null
    sh_ "logcat -d -v time -s PowosWebWindows:V PowosFreeform:V" > "$OUT/logcat-windows.txt"
    log "window path log: $OUT/window-log.txt ($(wc -l < "$OUT/window-log.txt" | tr -d ' ') lines; empty = an APK before WindowLog), logcat: $OUT/logcat-windows.txt"
  fi
  log "window-render: $1 - shots: $OUT";ls "$OUT"/*.png 2>/dev/null | sed 's/^/  /' | tee -a "$OUT/log.txt"; }
touched() { [ "$(irq)" = "$I0" ] || skip "user active (a real touch during the check at $1; its window closed)"; }
shot() {   # shot NAME: raw screencap gzipped on the phone -> $OUT/NAME.raw.gz
  "$A" exec-out "screencap ${DISP:+-d $DISP} | gzip -1" > "$OUT/$1.raw.gz" 2>/dev/null && [ -s "$OUT/$1.raw.gz" ] || { log "screencap $1 failed"; return 1; }
}

# --hidden: the ship gate's check (tools/phone/ship.sh window_gate), run on EVERY window-touching ship whatever the user
# is doing - nothing on their screen, no wait, no skip. The host path of a web window without the page's half: the
# APK's own WebWindowsHost (the shell-uid display maker WebWindows.kt runs: `create` -> a trusted virtual display, its
# touchscreen) is started here from adb, Calculator launched on that display (the root `am start --display` launch()
# falls back to), and the display is never mirrored (no element, no hole, no mirror under home). Checked:
#   task     Calculator's task is on that display (`am stack list`);
#   content  `screencap -d <that display>` is the app, not a flat fill (dominant colour < 97%, edges >= 0.3%), within 15 s;
#   tap      `input -d <that display> tap` on its "7" (found by id in `uiautomator dump --windows`, any layout/width)
#            changes its formula's text (the accessibility dump before vs after); the keystroke is then deleted again.
#   linux    a Linux app (WR_LINUX_APP, foot) through the host's KWin -> web-window consumer path into an offscreen
#            ImageReader, never offered to the page (webwindows.selftestLinux, LinuxSelftest.kt; see linux_step).
# Then its task removed (`am stack remove`; a Calculator task the user had before is moved back to display 0, never
# removed), the display released and the helper ended (its stdin closed: it releases what's left and exits; a holder
# that keeps stdin open ends by itself after WR_HOLD_S (default WR_TIMEOUT_S + 60, plus the hold: never before the
# check's own deadline), so a killed check leaves nothing either; every write to its stdin is fput's, never blocking). Exit 0 PASS, 1 FAIL;
# the whole run is bounded by WR_TIMEOUT_S (210: the Linux step adds up to ~50 s; plus the hold): a timeout is a FAIL. Shots in WR_OUT/<stamp>/.
# --hold S (HOLD): after content+tap pass, the PASS line is logged at once (ship.sh window_gate waits for it, then runs
# its passive render_watch) and the display stays up S s with Calculator on it: every ~5 s its content is measured again
# and logged to the phone's logcat (tag PowosWrHidden: "hold display D ..." - the helper's display geometry first),
# so render_watch sees a live window across its watch. Gone flat or its task gone during the hold: FAIL (exit 1, a
# "window-render: FAIL" line after the PASS one). The display is the adb-started helper's, never in WebWindows.kt's
# window list: the app's watchdog (RenderWatch) doesn't count it, and it gets no `w.f` lines (never mirrored).
# windows_same WL0 WL1: the user's page's window list (count:ids) before and after a hidden check. Changed = the USER
# opened/closed a window meanwhile (11-03 241478a42: '2:-2,2' -> '1:2' while they closed one; the check's display is
# the helper's, never in that list) - user activity, not a broken window: NOT JUDGED (exit 2, ship.sh retries), as a
# dozing phone, never a FAIL.
windows_same() {
  [ "$1" = "$2" ] && return 0
  log "the user's page's window list changed during the check ('${1:-unreadable}' -> '${2:-unreadable}') - the user's own action, not judged"
  hclean; log "window-render: NOT JUDGED (the user changed their windows) - $OUT"; exit 2
}
HOLD=0
hidden() {
  local tag=wrh$$ dir=/data/local/tmp/powos-wr-hidden-$$ W=${WR_W:-1080} H=${WR_H:-1500} dpi D= S= comp t0 pre task= st dom edg d1 noise fx fy wd
  t0=$(date +%s)
  # hnj STEP: the phone isn't Awake - nothing on the hidden display can be judged (exit 2, cleaned up as a FAIL is).
  hnj() { log "$1: the phone is $WAKE - not judged"; hclean; log "window-render: NOT JUDGED (the phone is $WAKE) - $OUT"; exit 2; }
  # wake_if_idle: the phone asleep and the user idle >= WR_WAKE_IDLE_S (600) s -> wake it (WOKE=1, WI0 = the touch IRQ
  # count then). A user touch < WR_WAKE_IDLE_S s ago, or no idle reading: never woken (the check stays NOT JUDGED).
  WOKE= WI0=
  wake_if_idle() {
    local need=${WR_WAKE_IDLE_S:-600} i
    [ "$need" -gt 0 ] 2>/dev/null && asleep || return 0
    i=$("$T/idle.sh" 2>/dev/null | sed -n 's/^idle=\([0-9]*\) .*/\1/p')
    if [ -z "$i" ] || [ "$i" -lt "$need" ]; then log "start: the phone is $WAKE, the user touched it ${i:-?} s ago (< $need s) - not woken"; return 0; fi
    # The wake's own panel resume moves the touch IRQs (no finger): the baseline is read once it has settled, and the
    # wake is marked as the tools' own for idle.sh's watcher (powos-selfinput) - else the wake read as the user (11-07).
    "$A" shell 'echo $(( $(date +%s) + 8 )) > /data/local/tmp/powos-selfinput; input keyevent KEYCODE_WAKEUP; sleep 1; wm dismiss-keyguard' </dev/null >/dev/null 2>&1
    WOKE=1; sleep 1; WI0=$(irq)
    log "start: woke the $WAKE screen for the check (the user idle $i s); it sleeps again after"
  }
  # keep_awake: the screen this check woke stays on (a wake key resets the screen timeout); a real touch since -> it's
  # the user's phone again: no more keys, and it isn't put to sleep at the end.
  keep_awake() {
    [ -n "$WOKE" ] || return 0
    [ "$(irq)" = "$WI0" ] || { WOKE=; log "the user touched the phone - it stays on, no more wake keys"; return 0; }
    "$A" shell 'echo $(( $(date +%s) + 8 )) > /data/local/tmp/powos-selfinput; input keyevent KEYCODE_WAKEUP; wm dismiss-keyguard' </dev/null >/dev/null 2>&1
  }
  awake_or_nj() { keep_awake; asleep && hnj "$1"; return 0; }
  # A failed step on a phone that fell asleep is not a window fault (10-31 a4dcb83b: the tap "changed nothing", Dozing).
  # A phone that left adb (VPN dropped, out of range) is not a window verdict (11-11 17:25: 93d0ab881 mailed WINDOWS
  # BROKEN for "no phone (adb get-state)"): NOT JUDGED, ship.sh keeps the request and retries.
  no_phone() { "$A" get-state >/dev/null 2>&1 && return 1; log "$1: no phone (adb get-state) - not judged"; hclean; log "window-render: NOT JUDGED (no phone: adb unreachable) - $OUT"; exit 2; }
  hfail() { no_phone "FAIL ($*)"; asleep && hnj "FAIL ($*) while asleep"; log "FAIL: $*"; hclean; log "window-render: FAIL (hidden: $*) - $OUT"; exit 1; }
  # fput MSG: one line to the helper's stdin, never blocking (fifo_put_cmd); prints sent or gone.
  fput() { sh_ "$(fifo_put_cmd "$dir" "$*")"; }
  # hclean: bounded as a whole - every phone call SH_T=15 s, and the run KILLed after WR_CLEAN_S (90) s whatever hangs
  # (the check's watchdog is gone by now: it is what called us, or we stopped it). A hung cleanup is a FAIL, never a
  # ship service waiting forever.
  hclean() {
    [ -n "${HCLEANED:-}" ] && return; HCLEANED=1
    local SH_T=15 cwd
    [ -n "${wd:-}" ] && kill "$wd" 2>/dev/null
    ( sleep "${WR_CLEAN_S:-90}"; echo "FAIL: cleanup hung > ${WR_CLEAN_S:-90} s - killed" >> "$OUT/log.txt"; echo "window-render: FAIL (hidden: cleanup hung > ${WR_CLEAN_S:-90} s) - $OUT"; kill -KILL $$ ) & cwd=$!
    if [ -n "$D" ]; then
      local t
      for t in $(tasks_on "$D"); do
        case " $pre " in
          *" $t "*) log "task $t was there before the check (the user's): moved back to display 0: $(sh_ "am display move-stack $t 0" | head -1)" ;;
          *) sh_ "am stack remove $t" >/dev/null; log "task $t removed" ;;
        esac
      done
      log "release display $D: $(fput "release $D")"
    fi
    sh_ "kill \$(cat $dir/holder 2>/dev/null) 2>/dev/null; sleep 0.5; cat $dir/out 2>/dev/null; rm -rf $dir" | sed 's/^/  helper: /' >> "$OUT/log.txt"
    if [ -n "$D" ]; then
      local left
      for _ in 1 2 3 4; do left=$(tasks_on "$D"); [ -z "$left" ] && break; sleep 1; done
      if [ -z "$left" ]; then log "display $D released, no task left on it"; else log "WARNING: tasks still on display $D: $left"; fi
    fi
    if [ -n "$WOKE" ] && [ "$(irq)" = "$WI0" ]; then
      mt 15 "$A" shell 'echo $(( $(date +%s) + 8 )) > /data/local/tmp/powos-selfinput; input keyevent KEYCODE_SLEEP' </dev/null >/dev/null 2>&1; log "the screen this check woke: back to sleep"
    fi; WOKE=
    kill "$cwd" 2>/dev/null
  }
  # tasks_on DISPLAY: the task ids on a display; app_tasks: every task of $APP (any display).
  tasks_on() { sh_ "am stack list" | awk -v d="$1" '/^RootTask id=/{on=($0 ~ ("displayId=" d " "))} on && /^ *taskId=/{sub(/^ *taskId=/,"");sub(/:.*/,"");print}' | sort -u | paste -sd' ' -; }
  app_tasks() { sh_ "am stack list" | awk -v p="$APP/" '/^ *taskId=/ && index($0, " " p){x=$0;sub(/^ *taskId=/,"",x);sub(/:.*/,"",x);print x}' | sort -u | paste -sd' ' -; }
  # hb METHOD 'JS args array': one bridge call of home's page (as the page's own PowosHost calls), its answer as text.
  hb() { ev "new Promise(ok=>{const h=window.__powosHost,P=window.PowosHost;if(!h||!P)return ok('no bridge');const r=h.resolve,j=h.reject,id=931700+Math.floor(Math.random()*900);const done=v=>{h.resolve=r;h.reject=j;ok(typeof v==='string'?v:JSON.stringify(v))};h.resolve=(i,v)=>i===id?done(v):r(i,v);h.reject=(i,m)=>i===id?done('ERR '+m):j(i,m);setTimeout(()=>done('no answer'),8000);P.postMessage(JSON.stringify([id,'$1',JSON.stringify($2)]))})"; }
  # jf JSON FIELD: one field of the selftest's JSON.
  jf() { echo "$1" | python3 -c "import json,sys
try: print(json.loads(sys.stdin.read()).get('$2',''))
except Exception: print('')"; }
  # linux_step: WR_LINUX_APP (foot: always in the PowOS chroot, starts in < 1 s) launched by the host
  # ("webwindows.selftestLinux", LinuxSelftest.kt): its next KWin window is never offered to the page - the consumer a
  # Linux web window uses (native_consumer.c, its own ConsumerLane) draws it into an offscreen ImageReader. Checked:
  # (a) a KWin window of it came (kwin id); (b) the consumer up and >= 2 frames with content (dominant < 99.5%, edges
  # >= 0.1%; the window is resized once after the first, so KWin draws a second); (c) the consumer's stop returned in
  # <= 1 s; (d) the window quit and KWin said closed; the page's window list unchanged (wl0/wl1 below). Not run (logged,
  # not a FAIL) where web windows don't take Linux windows (folded, the setting off): KWin would open a task on screen.
  # f384 (11-01 16:44/16:48): with the user on the phone, foot drew 8 flat frames (shell.css-only ship) and KWin's
  # "closed" came after the selftest's fixed 3 s close wait (terminal.tsx ship); 6 min earlier, idle, it passed. So:
  # KWin's close is WAITED for (kwinClosed is set on the selftest even after "done": WebWindows.linuxClosed), up to
  # WR_CLOSE_WAIT_S (12) s, and a Linux-step failure while the user touched the phone (touch IRQs moved during the
  # step: their load, not the window path) is NOT JUDGED (exit 2: ship.sh window_gate keeps the request and retries).
  lfail() { [ -n "${LI0:-}" ] && [ "$(irq)" != "$LI0" ] && { log "linux: FAIL ($*) while the user touched the phone - not judged"; hclean; log "window-render: NOT JUDGED (the user was using the phone) - $OUT"; exit 2; }; hfail "$@"; }
  linux_step() {
    local app=${WR_LINUX_APP:-foot} lr lj st
    awake_or_nj "linux"
    LI0=$(irq)
    lr=$(hb webwindows.selftestLinux "['$app']"); log "linux: webwindows.selftestLinux $app: ${lr:-no answer}"
    case $lr in
      started) ;;
      "web windows don't take"*) log "linux: not run ($lr)"; return 0 ;;
      *) hfail "linux: the host didn't start the selftest ($lr)" ;;
    esac
    for _ in $(seq 1 60); do
      sleep 1; lj=$(hb webwindows.selftestLinuxResult "[]"); st=$(jf "$lj" state); [ "$st" = done ] && break
    done
    log "linux: $lj"
    [ "$st" = done ] || lfail "linux: the selftest never finished (${lj:-no answer})"
    [ "$(jf "$lj" kwin)" -ge 0 ] 2>/dev/null || lfail "linux: no KWin window of $app came ($(jf "$lj" error))"
    log "linux: (a) KWin window $(jf "$lj" kwin) ($(jf "$lj" kwinApp)) taken offscreen, never offered to the page"
    [ "$(jf "$lj" upMs)" -ge 0 ] 2>/dev/null || lfail "linux: KWin window $(jf "$lj" kwin)'s consumer never came up ($(jf "$lj" error))"
    [ "$(jf "$lj" content)" -ge 2 ] 2>/dev/null || lfail "linux: KWin window $(jf "$lj" kwin)'s consumer delivered $(jf "$lj" content) frames with content of $(jf "$lj" frames) (want >= 2; best $(jf "$lj" best))"
    log "linux: (b) consumer up in $(jf "$lj" upMs) ms, $(jf "$lj" content) of $(jf "$lj" frames) frames with content ($(jf "$lj" best))"
    st=$(jf "$lj" stopMs); { [ "$st" -ge 0 ] && [ "$st" -le 1000 ]; } 2>/dev/null || lfail "linux: the consumer's stop took ${st} ms (want <= 1000; -1 = still blocked after 3 s)"
    LSTOP=$st; log "linux: (c) stop returned in $st ms"
    for _ in $(seq 1 "${WR_CLOSE_WAIT_S:-12}"); do [ "$(jf "$lj" kwinClosed)" = True ] && break; sleep 1; lj=$(hb webwindows.selftestLinuxResult "[]"); done
    [ "$(jf "$lj" kwinClosed)" = True ] || lfail "linux: KWin window $(jf "$lj" kwin) wasn't closed after the quit"
    log "linux: (d) KWin closed window $(jf "$lj" kwin)"
  }
  trap 'hclean' EXIT
  # A timeout while the phone sleeps is the sleep, not the windows (10-31 17:57, 1943e3e5: an adb su call hung with the
  # phone Dozing after passing the start check) - NOT JUDGED like every other asleep path.
  trap '"$A" get-state >/dev/null 2>&1 || { log "window-render: NOT JUDGED (no phone: adb unreachable; timed out) - $OUT"; hclean; exit 2; }; if asleep; then log "window-render: NOT JUDGED (the phone is $WAKE; timed out after ${WR_TIMEOUT_S:-210} s) - $OUT"; hclean; exit 2; fi; log "FAIL: timeout (${WR_TIMEOUT_S:-210} s)"; hclean; log "window-render: FAIL (hidden: timeout) - $OUT"; exit 1' TERM INT
  # The watchdog: kills whatever adb call hangs (bash runs the trap only once its foreground child is gone), then us.
  ( sleep $(( ${WR_TIMEOUT_S:-210} + HOLD )); pkill -P $$ 2>/dev/null; kill -TERM $$ 2>/dev/null ) & wd=$!

  no_phone "start"
  wake_if_idle
  awake_or_nj "start"
  dpi=$(sh_ "wm density" | sed -n 's/^Override density: //p'); [ -n "$dpi" ] || dpi=$(sh_ "wm density" | sed -n 's/^Physical density: //p')
  apk=$(sh_ "pm path com.powos.app" | sed -n '1s/^package://p'); [ -n "$apk" ] || hfail "PowOS isn't installed (pm path com.powos.app)"
  comp=$(sh_ "cmd package resolve-activity --brief -c android.intent.category.LAUNCHER $APP" | tail -1); case $comp in "$APP"/*) ;; *) hfail "no launcher activity for $APP ($comp)" ;; esac
  pre=" $(app_tasks) "
  # The user's page's windows (count + ids) before; the same after the check or FAIL - the check never opens,
  # closes or moves one of theirs.
  wlist() { ev "(()=>{const w=[...document.querySelectorAll('.webwindow')];return w.length+':'+w.map(e=>e.dataset.wwid||'?').join(',')})()"; }
  local wl0 wl1; wl0=$(wlist); log "the user's page's windows before: ${wl0:-unreadable}"
  log "hidden check: $comp on a ${W}x$H display at $dpi dpi from $apk (the user's $APP tasks before:${pre% })"
  # The helper (WebWindowsHost from the installed APK, as WebWindows.kt starts it: su 2000, group uhid), stdin a fifo a
  # holder keeps open for WR_HOLD_S; "selftest": own display group/focus/lock state (an older helper ignores it).
  cat > "$OUT/wrh.sh" <<EOF
mkdir -p $dir && mkfifo $dir/in && chmod 777 $dir $dir/in || exit 1
nohup sh -c 'exec sleep $(( ${WR_HOLD_S:-$(( ${WR_TIMEOUT_S:-210} + 60 ))} + HOLD )) > $dir/in' >/dev/null 2>&1 &
echo \$! > $dir/holder
nohup su -g 2000 -G 3011 2000 -c "echo \\\$\\\$ > $dir/helper; CLASSPATH='$apk' exec app_process /system/bin dev.omalauncher.shell.WebWindowsHost" < $dir/in > $dir/out 2>&1 &
for i in \$(seq 1 30); do grep -q '^hello' $dir/out && break; sleep 0.2; done
echo "create $tag $W $H $dpi selftest" 1<> $dir/in
for i in \$(seq 1 30); do grep -qE '^(display|error) $tag' $dir/out && break; sleep 0.2; done
cat $dir/out
EOF
  "$A" push "$OUT/wrh.sh" "$dir.sh" >/dev/null 2>&1 || hfail "can't push the helper script"
  r=$(sh_ "sh $dir.sh; rm -f $dir.sh")
  echo "$r" | sed 's/^/  helper: /' | tee -a "$OUT/log.txt"
  D=$(echo "$r" | sed -n "s/^display $tag \([0-9]*\).*/\1/p")
  [ -n "$D" ] || hfail "the host made no display: $(echo "$r" | grep -m1 "^error $tag" || echo "${r:-no answer from WebWindowsHost}")"
  S=$(sh_ "dumpsys SurfaceFlinger --display-id" | sed -n "s/^Display \([0-9]*\) (Virtual display): displayName=\"powos-ww-$tag\".*/\1/p")
  [ -n "$S" ] || hfail "display $D isn't in SurfaceFlinger's list (no powos-ww-$tag)"
  log "display $D (SurfaceFlinger $S), never mirrored"
  # A task of its own even if the user has Calculator open (NEW_TASK | MULTIPLE_TASK): theirs is never pulled over. And
  # the other way: a document task (NEW_DOCUMENT + its own data URI) no plain launch of the app matches - 11-01 ship
  # 2a849163, the phone folded: a launch of Calculator at 21:23:28 brought THIS task (2256) to display 0 mid-hold
  # (wm_task_moved [2256,2256,0]), display 98 went flat black (ff000000) and it read as a window fault.
  log "launch: $(sh_ "am start --display $D -f 0x18080000 -d powos-window-render://hidden/$tag -n $comp" | grep -v '^Starting' | head -2 | paste -sd' ' -)"
  # (a) its task on that display and its content drawn.
  for _ in $(seq 1 15); do task=$(tasks_on "$D"); [ -n "$task" ] && break; sleep 1; done
  [ -n "$task" ] || hfail "$APP's task never reached display $D"
  for t in $task; do case "$pre" in *" $t "*) log "WARNING: task $t was the user's (it moved to the check's display; it goes back after)" ;; esac; done
  log "task $task on display $D"
  awake_or_nj "content"
  for i in $(seq 1 15); do
    "$A" exec-out "su -c 'screencap -d $S | gzip -1'" > "$OUT/display.raw.gz" 2>/dev/null
    st=$($PY stats "$OUT/display.raw.gz" 0 0 "$W" "$H" 2>&1)
    dom=$(echo "$st" | sed -n 's/.*dominant=\([0-9.]*\).*/\1/p'); edg=$(echo "$st" | sed -n 's/.*edges=\([0-9.]*\).*/\1/p')
    [ -n "$dom" ] && awk "BEGIN{exit !($dom < 0.97 && $edg >= 0.003)}" && break; sleep 1
  done
  log "content ($i s): $st"
  [ -n "$dom" ] && [ -n "$edg" ] || hfail "no screencap of display $D ($st)"
  awk "BEGIN{exit !($dom < 0.97 && $edg >= 0.003)}" || hfail "display $D shows a flat fill, not the app (dominant $dom, edges $edg)"
  # Still there: home's adopt took this task to a web window of its own (window-log "app's task N moved onto display M")
  # before FreeformTasks counted only display 0's tasks - this display went black and the tap hit nothing.
  # Gone elsewhere, it's still the check's (a new task, never one of $pre): removed there - else a Calculator window
  # the check made stays on the user's screen (its web window closes with its task).
  stayed() { local now t to; now=$(tasks_on "$D"); case " $now " in *" ${task%% *} "*) return 0 ;; esac
    to=$(sh_ "am stack list" | awk -v t="taskId=${task%% *}:" '/^RootTask id=/{d=$0;sub(/.*displayId=/,"",d);sub(/ .*/,"",d)} index($0,t){print d;exit}')
    for t in $task; do case "$pre" in *" $t "*) ;; *) sh_ "am stack remove $t" >/dev/null; log "task $t removed where it went (display ${to:-?})" ;; esac; done
    hfail "$APP's task $task left display $D $1 (to display ${to:-?}: PowOS's adopt of a full-screen task on another display - fixed in FreeformTasks.onMainDisplay)"; }
  # (b) a tap on THAT display reaches the app, judged on the app's own text. The key is read from the app's real layout
  # (`uiautomator dump --windows`: every display's accessibility tree, this display's Calculator in it), its formula
  # text before vs after. 11-11 ea2933b3: a fixed tap (0.14,0.69 of the display) hit the scientific layout's "log" key
  # (the layout depends on the display width), the formula already held a long "log(log(..." of earlier checks, the
  # appended text was off-screen and a pixel diff of the number area read 0.0005 -> a false "WINDOWS BROKEN". Nothing
  # is cleared: the app's own formula (it may be the user's) gets one keystroke, undone with its delete key after.
  # window-render.py calc picks "7" ("+" after a long number: the digit limit) and gives its centre on this display.
  uidump() {   # uidump NAME: the accessibility dump of every display -> $OUT/NAME.xml (retried: the dump can miss idle)
    local i; for i in 1 2 3; do
      sh_ "uiautomator dump --windows $dir/ui.xml >/dev/null 2>&1 && cat $dir/ui.xml" > "$OUT/$1.xml"
      grep -q "</displays>" "$OUT/$1.xml" && return 0; sleep 1
    done; return 1; }
  local plan key kx ky dx dy jr
  sleep 1; stayed "after its content showed"; awake_or_nj "layout"
  uidump ui-pre || hfail "no accessibility dump of display $D (uiautomator dump --windows)"
  plan=$($PY calc "$OUT/ui-pre.xml" "$D" "$APP") || hfail "no key to tap in $APP's layout: $plan"
  read -r key kx ky dx dy <<< "$(echo "$plan" | head -1)"
  log "layout: $key at $kx,$ky, delete at $dx,$dy; formula before: $(echo "$plan" | sed -n 2p)"
  awake_or_nj "tap"; sh_ "input -d $D tap $kx $ky" >/dev/null; log "tap: input -d $D tap $kx $ky ($key)"
  sleep 1; "$A" exec-out "su -c 'screencap -d $S | gzip -1'" > "$OUT/tap.raw.gz" 2>/dev/null
  stayed "by the tap"
  for n in display tap; do $PY png "$OUT/$n.raw.gz" "$OUT/$n.png" 2>/dev/null && rm -f "$OUT/$n.raw.gz"; done
  uidump ui-tap || hfail "no accessibility dump of display $D after the tap"
  jr=$($PY calcjudge "$OUT/ui-pre.xml" "$OUT/ui-tap.xml" "$D" "$APP" changed) || hfail "the tap changed nothing in the app ($key: $jr)"
  log "tap: reached the app ($key: $jr)"
  # Undo the keystroke (the formula as it was; not judged - the tap's proof is above).
  if [ "$dx" != - ]; then
    awake_or_nj "undo"; sh_ "input -d $D tap $dx $dy" >/dev/null; sleep 1
    if uidump ui-undo && jr=$($PY calcjudge "$OUT/ui-pre.xml" "$OUT/ui-undo.xml" "$D" "$APP" same); then log "undo: delete tapped, formula as before"
    else log "WARNING: the delete tap didn't restore the formula (${jr:-no dump})"; fi
  fi
  # (c) a resize through the helper (as WebWindows.resizeContent sends it): dumpsys display shows the new size at the
  # SAME density (a window's density is fixed for its life, WindowDpi - 10-31 Chrome lost its desktop layout).
  vdinfo() { sh_ "dumpsys display" | grep -m1 "DisplayDeviceInfo{\"powos-ww-$tag\"" | sed -n 's/.*", \([0-9]*\) x \([0-9]*\),.* density \([0-9]*\),.*/\1 \2 \3/p'; }
  awake_or_nj "resize"; local g0 g1 W2 H2; g0=$(vdinfo); log "display $D before the resize: ${g0:-unreadable} (w h dpi)"
  [ -n "$g0" ] || hfail "dumpsys display has no powos-ww-$tag"
  set -- $g0; W2=$(( $1 * 3 / 4 )); H2=$(( $2 * 3 / 4 ))
  [ "$(fput "resize $D $W2 $H2 $3")" = sent ] || hfail "the helper is gone (resize not sent)"
  for _ in 1 2 3 4 5 6 7 8 9 10; do g1=$(vdinfo); [ "$g1" = "$W2 $H2 $3" ] && break; sleep 0.3; done
  log "display $D after 'resize $D $W2 $H2 $3': ${g1:-unreadable}"
  [ "$g1" = "$W2 $H2 $3" ] || hfail "display $D after the resize is '${g1:-unreadable}', not '$W2 $H2 $3' (size, density unchanged)"
  # (d) a Linux window through the host's KWin -> web-window consumer path, offscreen (linux_step below).
  linux_step
  wl1=$(wlist); log "the user's page's windows after: ${wl1:-unreadable}"
  windows_same "$wl0" "$wl1"
  if [ "$HOLD" -gt 0 ]; then
    log "window-render: PASS (hidden: task $task on display $D drew the app, the tap reached it; linux stopMs=${LSTOP:--1}; $(( $(date +%s) - t0 )) s; holding $HOLD s) - $OUT"
    # Into logcat: the helper's geometry line for this display, then the content every ~5 s (no quotes in the text).
    lc() { "$A" shell "log -t PowosWrHidden '$(echo "$*" | tr -d "'\"\\\\")'" </dev/null >/dev/null 2>&1; }
    lc "hold display $D start: $(echo "$r" | grep -m1 "^log display $D " | cut -c5-) task $task, $HOLD s"
    local h0 hs hd he
    h0=$(date +%s)
    while :; do
      sleep 5
      keep_awake; asleep && { lc "hold display $D: phone $WAKE - not judged"; hnj "hold $(( $(date +%s) - h0 )) s"; }
      # Its task first: one moved off the display (a launch elsewhere took it) leaves it flat black - say THAT, not "flat".
      [ -n "$(tasks_on "$D")" ] || { lc "hold display $D: task gone"; hfail "during the hold $APP's task left display $D (now: $(sh_ "am stack list" | grep -m1 -B1 "taskId=${task%% *}:" | sed -n 's/.*\(displayId=[0-9]*\).*/\1/p' | head -1))"; }
      "$A" exec-out "su -c 'screencap -d $S | gzip -1'" > "$OUT/hold.raw.gz" 2>/dev/null
      hs=$($PY stats "$OUT/hold.raw.gz" 0 0 "$W" "$H" 2>&1)
      hd=$(echo "$hs" | sed -n 's/.*dominant=\([0-9.]*\).*/\1/p'); he=$(echo "$hs" | sed -n 's/.*edges=\([0-9.]*\).*/\1/p')
      if [ -z "$hd" ] || ! awk "BEGIN{exit !($hd < 0.97 && $he >= 0.003)}"; then
        # The phone fell asleep: the test display (own group or not) goes dark with it - not a window fault (10-31 16:15,
        # 889b6cb5: "went flat" with mWakefulness=Dozing): NOT JUDGED (exit 2), never a FAIL.
        asleep && { lc "hold display $D: phone $WAKE - not judged"; hnj "hold $(( $(date +%s) - h0 )) s"; }
        lc "hold display $D FLAT: $hs"; hfail "during the hold display $D went flat ($hs)"
      fi
      [ -n "$(tasks_on "$D")" ] || { lc "hold display $D: task gone"; hfail "during the hold $APP's task left display $D"; }
      lc "hold display $D live $(( $(date +%s) - h0 )) s: $hs"; log "hold $(( $(date +%s) - h0 )) s: $hs"
      [ $(( $(date +%s) - h0 )) -ge "$HOLD" ] && break
    done
    rm -f "$OUT/hold.raw.gz"; lc "hold display $D end"
    hclean
    log "hold: display $D stayed drawn for $HOLD s"
    exit 0
  fi
  hclean
  log "window-render: PASS (hidden: task $task on display $D drew the app, the tap reached it; linux stopMs=${LSTOP:--1}; $(( $(date +%s) - t0 )) s) - $OUT"
  ls "$OUT"/*.png 2>/dev/null | sed 's/^/  /' | tee -a "$OUT/log.txt"
  exit 0
}
if [ "${1:-}" = --hidden ]; then
  [ "${2:-}" = --hold ] && { case ${3:-} in ''|*[!0-9]*) echo "--hold wants seconds" >&2; exit 1 ;; esac; HOLD=$3; }
  trap - EXIT TERM INT; hidden
fi

# 1. A free phone: screen on, no touch for WR_IDLE_S, no keyguard, unfolded.
deadline=$(( $(date +%s) + ${WR_WAIT_S:-900} ))
while :; do
  left=$(( deadline - $(date +%s) )); [ $left -gt 0 ] || skip "${why:-user active} for ${WR_WAIT_S:-900} s"
  i=$(AWAKE_ONLY=1 "$T/idle.sh" --wait "${WR_IDLE_S:-30}" "$left"); rc=$?
  case $rc in 70) skip "phone transport failed" ;; 0) ;; *) skip "user active ($i) for ${WR_WAIT_S:-900} s" ;; esac
  kg=$(sh_ "dumpsys window" | grep -m1 -o 'isKeyguardShowing=[a-z]*')
  fold=$(sh_ "dumpsys device_state" | grep -m1 mCommittedState | grep -o "name='[A-Z_]*'")
  if [ "$kg" != isKeyguardShowing=false ]; then why="locked ($kg)"
  elif [ "$fold" = "name='CLOSED'" ]; then why="folded - web windows exist only unfolded"
  elif [ -d "$L" ] && [ $(( $(date +%s) - $(stat -f %m "$L" 2>/dev/null || stat -c %Y "$L") )) -lt 600 ]; then why="verify lock held ($(cat "$L/who" 2>/dev/null))"
  elif mkdir "$L" 2>/dev/null || { rm -rf "$L" && mkdir "$L" 2>/dev/null; }; then
    echo "window-render pid $$ $(date +%H:%M:%S)" > "$L/who"; LOCKED=1; break
  else why="verify lock busy"; fi
  log "waiting: $why ($i)"; sleep 30
done
log "free: $i, $kg, $fold"
I0=$(irq)
dpr=$(ev 'String(devicePixelRatio)')
# The physical display home is on (two panels + every web window's virtual display: a bare screencap warns and picks
# "the first one found"): the one whose size is home's viewport in device px.
want=$(ev 'Math.round(innerWidth*devicePixelRatio)+"x"+Math.round(innerHeight*devicePixelRatio)'); DISP=
for d in $(sh_ "dumpsys SurfaceFlinger --display-id" | sed -n 's/^Display \([0-9]*\) (HWC display.*/\1/p'); do
  wh=$("$A" exec-out "screencap -d $d 2>/dev/null | head -c 8" 2>/dev/null | od -An -tu4 | awk '{print $1"x"$2}')
  awk -v a="$wh" -v b="$want" 'BEGIN{split(a,x,"x"); split(b,y,"x"); d1=x[1]-y[1]; d2=x[2]-y[2]; exit !(x[1] > 0 && d1*d1 <= 16 && d2*d2 <= 16)}' && { DISP=$d; break; }
done
[ -n "$DISP" ] || skip "no physical display is home's size ($want) - can't tell which to screencap"
log "display $DISP ($want)"
on=$(ev "$WW.then(async([s,m])=>String(await m.webWindowsOn()))")
[ "$on" = true ] || skip "web windows aren't on here (webWindowsOn: ${on:-no answer}) - unfolded with powos_web_windows=1?"
# Never the user's: no window of the app, no task of it (an open would pull that task into our window, a close end it).
had=$(ev "$WW.then(([s,m])=>String(m.webWins.value.filter(w=>w.key.startsWith('a:$APP/')).length))")
[ "$had" = 0 ] || skip "$APP already has a web window (${had:-?}) - not touching the user's"
tasks=$(sh_ "dumpsys activity activities" | grep -c "ActivityRecord{[^}]* $APP/")
[ "$tasks" = 0 ] || skip "$APP has a running task - could be the user's; not touching it"

# 2. Before: the screen as it is (home's page, the wallpaper) - the rect the window will cover is cut from it.
shot before || skip "no screencap"
touched "the first shot"
# Home must show one of its desktop pages (not PowOS AI's page -1 or the app library): the window opens on the page
# shown, as the dock's launch does. Another one: home goes to its first page for the check and back after it.
P0=$(ev "importShim('./state.ts').then(s=>{const p=s.page.value;if(p>=0&&p<s.pages.value.length)return 'ok';s.page.value=0;return String(p)})")
case "$P0" in ok) P0= ;; -[0-9]*|[0-9]*) log "home was on page $P0 (not a desktop page): to page 0 for the check, back after"; sleep 1.5 ;; *) skip "can't read home's page (${P0:-no answer})" ;; esac
r=$(ev "$WW.then(async([s,m])=>{const k=[...s.byKey.value.keys()].find(k=>k.startsWith('a:$APP/'));if(!k)return 'no app key';const id=await m.openWindow(k,s.byKey.value.get(k).label,s.pages.value[s.page.value]??1);return id==null?'not a window':'id '+id})")
case "$r" in "id "*) ID=${r#id }; log "opened $APP as web window $ID (webwindows.tsx openWindow)" ;; *) log "FAIL: the open didn't make a window: ${r:-no answer}"; verdict FAIL; exit 1 ;; esac

# 3. Live + the body's rect (device px).
live=
for _ in $(seq 1 15); do
  live=$(ev "$WW.then(([s,m])=>String(!!(m.webWins.value.find(w=>w.id===$ID)||{}).live))"); [ "$live" = true ] && break; sleep 1
done
sleep 1.5
rect=$(ev "(()=>{const b=document.querySelector('.webwindow[data-wwid=\"$ID\"] .webwindow-body');if(!b)return 'none';const r=b.getBoundingClientRect(),d=devicePixelRatio,i=6;return [r.left*d+i,r.top*d+i,r.right*d-i,r.bottom*d-i].map(Math.round).join(' ')+' '+b.className})()")
log "body: $rect (dpr $dpr), live=$live"
set -- $rect
[ $# -ge 4 ] && [ $(( $3 - $1 )) -gt 100 ] && [ $(( $4 - $2 )) -gt 100 ] || { log "FAIL: no body rect for window $ID ($rect)"; verdict FAIL; exit 1; }
R="$1 $2 $3 $4"
scr=$(ev 'Math.round(innerWidth*devicePixelRatio)+" "+Math.round(innerHeight*devicePixelRatio)'); set -- $R $scr
[ "$1" -ge 0 ] && [ "$2" -ge 0 ] && [ "$3" -le "${5:-0}" ] && [ "$4" -le "${6:-0}" ] || { log "FAIL: window $ID's body ($R) isn't on the screen (0 0 $scr): it opened where it can't be seen"; verdict FAIL; exit 1; }
touched "the open"

# 4. Content.
shot open || { verdict FAIL; exit 1; }
d0=$($PY diff "$OUT/before.raw.gz" "$OUT/open.raw.gz" $R)
st=$($PY stats "$OUT/open.raw.gz" $R)
dom=$(echo "$st" | sed -n 's/.*dominant=\([0-9.]*\).*/\1/p'); edg=$(echo "$st" | sed -n 's/.*edges=\([0-9.]*\).*/\1/p')
log "content: $d0 of the body differs from before the open; $st"

# 5. A tap on "7" through the body's own handler.
sleep 1; shot pre || { verdict FAIL; exit 1; }
noise=$($PY diff "$OUT/open.raw.gz" "$OUT/pre.raw.gz" $R)
set -- ${WR_TAP:-0.36 0.62}; fx=$1 fy=$2
since=$(sh_ "date +%m-%d\ %H:%M:%S.000")
touched "before the tap"
tr_=$(ev "(async()=>{const b=document.querySelector('.webwindow[data-wwid=\"$ID\"] .webwindow-body');if(!b)return 'no body';const r=b.getBoundingClientRect(),x=r.left+r.width*$fx,y=r.top+r.height*$fy;const o={bubbles:true,cancelable:true,composed:true,pointerId:931,pointerType:'touch',isPrimary:true,clientX:x,clientY:y,button:0};b.dispatchEvent(new PointerEvent('pointerdown',{...o,buttons:1}));await new Promise(f=>setTimeout(f,90));b.dispatchEvent(new PointerEvent('pointerup',{...o,buttons:0}));return 'tapped '+Math.round(x*devicePixelRatio)+','+Math.round(y*devicePixelRatio)})()")
log "tap ($fx,$fy of the body): $tr_"
sleep 1.5
shot tap || { verdict FAIL; exit 1; }
d1=$($PY diff "$OUT/pre.raw.gz" "$OUT/tap.raw.gz" $R)
tl=$(sh_ "logcat -d -v time -T \"$since\" -s PowosWebWindows:I" | grep -E "input: window $ID |log touch" | tail -4)
log "tap: $d1 of the body changed (noise without a tap: $noise)"; [ -n "$tl" ] && echo "$tl" | sed 's/^/  /' | tee -a "$OUT/log.txt"
touched "the tap"

# PNGs to look at (whole screen + the body crop).
for n in before open pre tap; do $PY png "$OUT/$n.raw.gz" "$OUT/$n.png" $R "$OUT/$n-body.png" && rm -f "$OUT/$n.raw.gz"; done

bad=
for v in "$d0" "$dom" "$edg" "$d1" "$noise"; do case $v in ""|*[!0-9.]*) log "FAIL: a measurement is missing (d0=$d0 dom=$dom edges=$edg tap=$d1 noise=$noise)"; verdict FAIL; exit 1 ;; esac; done
[ "$live" = true ] || bad="$bad; never live (no first frame from the app in 15 s)"
awk "BEGIN{exit !($d0 >= 0.35)}" || bad="$bad; the body looks like the page under it ($d0 differs, want >= 0.35): an empty hole"
awk "BEGIN{exit !($dom < 0.97 && $edg >= 0.003)}" || bad="$bad; the body is a flat fill (dominant $dom, edges $edg)"
awk "BEGIN{exit !($d1 >= 0.001 && $d1 > 3 * $noise)}" || bad="$bad; the tap changed nothing in the app ($d1 vs noise $noise)$(echo "$tl" | grep -q ': ok' && echo ' though the helper injected it ok')"
if [ -z "$bad" ]; then verdict PASS; exit 0; fi
log "FAIL:${bad#;}"; verdict FAIL; exit 1
