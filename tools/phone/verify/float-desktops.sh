#!/bin/bash
# lanes: emu phone
# float-desktops.sh [OUT]: floating windows live on home's pages, one desktop per page (shell ui/desktops.ts,
# WindowFrames.desktop; board task floating-windows-live-on-home-pages-one-desktop). Needs the INNER screen (folded,
# apps are full screen by design): forces it (cmd device_state state 3), swipes the lock face, home's first page.
# Then, never touching the home layout: Calculator opened through home's launch call lands on page 1 (in windows.list,
# stored in home.windows - missing there was the bug of 2026-10-23, its logcat is kept); a REAL swipe from an empty
# spot (read-only CDP finds one: no tile, outside the window) to page 2 hides it; swiping back shows it at the same
# bounds; its app opened while page 2 shows moves it to page 2; home's app killed and back, it's still page 2's. Always
# restores: Calculator stopped,
# home's first page, `cmd device_state state reset`. Both first swipes must slide the window with the page (slid). Exit: 0 passed; 1 FAIL: ...; 3 a real touch / no free window;
# 5 can't run (no screen size, a PIN, one home page only). Injected input only; a free window first, the lock then.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); T=$here/..; A="$T/adb.sh"
OUT=${1:-$HOME/.cache/powos-verify/desktops-$(date +%m%d-%H%M)}; mkdir -p "$OUT"
L=$HOME/.cache/powos-verify.lock
PKG=${TEST_APP:-com.oneplus.calculator}
sh_() { "$A" shell "su -c '$*'" 2>/dev/null | tr -d '\r'; }
irq() { sh_ "awk '/touch-0/{s+=\$2+\$3+\$4+\$5+\$6+\$7+\$8+\$9} END{print s}' /proc/interrupts"; }
# device_state_set <state>: set fold state; on emu, state 3 (inner) is a no-op, state 0 (cover) prints SKIP.
device_state_set() {
  case "${POWOS_DEVICE:-phone}" in
    emu) case $1 in 3|inner|unfolded) ;; 0|cover|folded) echo "SKIP emu has no cover screen" ;; *) ;; esac ;;
    *) sh_ "cmd device_state state $1" ;;
  esac
}
# device_state_reset: reset fold state to hinge; on emu, a no-op.
device_state_reset() {
  case "${POWOS_DEVICE:-phone}" in emu) ;; *) sh_ "cmd device_state state reset" ;; esac
}
restore() { [ "${TOUCHED:-0}" = 1 ] || return 0; release_pkgs; sh_ "am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; device_state_reset; echo "restored"; }
. "$here/window-lock.sh"
window_lock float-desktops.sh 120
trap 'restore; [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"' EXIT
I0=$(irq)
chk() { [ "$(irq)" = "$I0" ] || { echo "STOP: a real touch at $1 - restoring"; exit 3; }; }
fail() { echo "FAIL: $*" | tee -a "$OUT/log.txt"; "$T/shot.sh" "$OUT/fail.png" >/dev/null 2>&1; exit 1; }
pass() { echo "PASS: $*" | tee -a "$OUT/log.txt"; }
# fps_gate <step_name> <frame_count> <duration_ms> <min_fps>: check FPS threshold; on emu, print NOTE; on phone, PASS/FAIL.
fps_gate() {
  local step_name="$1" frame_count="$2" duration_ms="$3" min_fps="$4"
  local fps=$((frame_count * 1000 / duration_ms))
  case "${POWOS_DEVICE:-phone}" in
    emu) echo "NOTE emu: $frame_count frames in $duration_ms ms ($fps fps, fps gates apply on the phone only)" | tee -a "$OUT/log.txt" ;;
    *) [ "$fps" -ge "$min_fps" ] && pass "$step_name: slid with the page, $frame_count frames in $duration_ms ms ($fps fps)" || fail "$step_name: the slide lagged - $frame_count frames in $duration_ms ms ($fps fps, want >= $min_fps)" ;;
  esac
}
# A call on home's bridge as the page makes it (float-windows.sh hcall): $1 method, $2 JSON args, $3 JS fn of the answer.
hcall_once() {
  "$T/cdp.sh" eval home "new Promise(ok=>{const h=window.__powosHost,P=window.PowosHost;if(!h||!P||!P.postMessage)return ok('ERR no bridge');const r=h.resolve,j=h.reject,id=910300+Math.floor(Math.random()*9000);const done=v=>{h.resolve=r;h.reject=j;ok(v)};h.resolve=(i,v)=>i===id?done(v):r(i,v);h.reject=(i,m)=>i===id?done('ERR '+m):j(i,m);setTimeout(()=>done('ERR no answer'),8000);P.postMessage(JSON.stringify([id,'$1',JSON.stringify($2)]))}).then(v=>typeof v==='string'&&v.startsWith('ERR')?v:($3)(v))" 2>&1 | tr -d '"\r' | tail -1
}
# hcall with retries: an EMPTY answer is a failed adb/CDP hop before the call reached the page (cdp.sh's adb under
# set -e once exited silently: "Calculator's key from home's apps.list: ", 2026-10-23) - the call never ran, so it's
# made again (up to 4 tries, 2 s apart). An answer from the page (ok, ERR ...) is final.
hcall() { local v i; for i in 1 2 3 4; do v=$(hcall_once "$@"); case $v in ""|"cdp: adb"*|*"isn't running"*|"no page"*) echo "hcall $2: try $i: '${v}'" >&2; sleep 2 ;; *) echo "$v"; return ;; esac; done; echo "ERR no answer after 4 tries (${v:-empty})"; }
# A host event into home's page, as ShellBridge.emit sends it; the page on screen (0-based, -1 none).
hemit() { "$T/cdp.sh" eval home "(window.__powosHost.emit('$1', $2), 'ok')" >/dev/null 2>&1; sleep 1.2; }
# The page index on screen. Retried: right after home's app restarted, cdp.sh's answer can be another line (its pages
# list ending in "]": "after the restart on page 2: page ]", 07:21 2026-10-23, while the window showed - the read, not home).
onpage() { local v i; for i in 1 2 3 4; do
  v=$("$T/cdp.sh" eval home "[...document.querySelectorAll('.page-track > .page')].findIndex(p=>!p.classList.contains('away'))" 2>&1 | tr -d '"\r' | tail -1)
  case $v in -[0-9]*|[0-9]*) echo "$v"; return ;; esac; echo "onpage: try $i: '$v'" >&2; sleep 2; done; echo "?($v)"; }
npages() { "$T/cdp.sh" eval home "document.querySelectorAll('.page-track > .page').length" 2>&1 | tr -d '"\r' | tail -1; }
vis() { sh_ "am stack list | grep -m1 $PKG" | grep -oE 'visible=(true|false)'; }
away() { hcall windows.list "[]" "l=>(l.find(w=>w.pkg==='$PKG')||{away:'none'}).away"; }
# Context for a FAIL on a page check: home's page count (n, set at start / after the restart) and the last swipe's
# start,end px (LASTSWIPE, set by swipe()). Uses only values the script already holds - no extra CDP call.
ctx() { echo "home pages ${n:-?}, last swipe ${LASTSWIPE:-none}"; }

s=$(sh_ "dumpsys power | sed -n s/.*mWakefulness=//p | head -1")
[ "$s" = Awake ] || { echo "the screen is $s - not woken (rule); nothing done"; exit 3; }
[ "$(sh_ "settings get global enable_freeform_support")" = 1 ] || fail "enable_freeform_support isn't 1"
# The committed state flips to OPENED before display 0 is the inner screen: 3 s once wasn't enough (right after
# sketch-rotate, folded: OPENED, wm size still the cover's 1116x2484) - wait for the inner size, up to 15 s.
claim_pkg $PKG
device_state_set 3; sleep 2; chk unfold
# mCommittedState can take longer than 2 s to reach OPENED on the emulator's software renderer (2026-10-24: still
# CLOSED at 2 s there) - up to 10 s more, as wsize's loop below already allows for the screen size.
# Skip on emu (no device_state support); otherwise wait for OPENED state.
if [ "${POWOS_DEVICE:-phone}" != emu ]; then
  t=0; until sh_ "dumpsys device_state | grep -m1 mCommittedState" | grep -q OPENED; do
    [ $t -lt 10 ] || { echo "ENV: phone locked/folded - floating desktop not available (the inner screen didn't come on: device_state not OPENED)" | tee -a "$OUT/log.txt"; exit 5; }; sleep 1; t=$((t + 1))
  done
fi
wsize() { sh_ "wm size" | sed -nE 's/.*(Override|Physical) size: ([0-9]+)x([0-9]+).*/\2 \3/p' | tail -1; }
t=0; WH=$(wsize)
while [ "${WH%% *}" -le 2000 ] 2>/dev/null && [ $t -lt 13 ]; do sleep 1; t=$((t + 1)); WH=$(wsize); done
chk unfold
W=${WH% *}; H=${WH#* }; echo "on: ${W}x${H} ($((t + 2)) s after state 3)"
[ "${W:-0}" -gt 2000 ] || { echo "ENV: phone locked/folded - floating desktop not available (no unfolded screen size: $WH) - stopping before any input"; exit 5; }
kg() { sh_ "dumpsys window policy | grep -m1 -E \"mIsShowing=\""; }
if kg | grep -q true; then
  sh_ "wm dismiss-keyguard"; sleep 1.5
  kg | grep -q true && { sh_ "input swipe $((W / 2)) $((H * 9 / 10)) $((W / 2)) $((H / 4)) 300"; sleep 1.5; }
  kg | grep -q true && { echo "ENV: phone locked/folded - floating desktop not available (the keyguard didn't go, a PIN?) - stopping"; exit 5; }
fi
sh_ "dumpsys window | grep -m1 mCurrentFocus" | grep -qi "PowosLock" && { sh_ "input swipe $((W / 2)) $((H * 9 / 10)) $((W / 2)) $((H / 4)) 300"; sleep 1.5; }
chk lock
sh_ "am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; sleep 2; chk home
hemit system.home null
n=$(npages); echo "home pages: $n, on $(onpage)" | tee -a "$OUT/log.txt"
[ "${n:-0}" -ge 2 ] || { echo "ENV: home has one page - nothing to switch between; stopping"; exit 5; }
[ "$(onpage)" = 0 ] || fail "system.home didn't show page 1 ($(onpage))"

bounds() { sh_ "am stack list | grep -m1 $PKG" | grep -oE 'bounds=\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]' | head -1 | tr -c '0-9\n' ' ' | xargs; }
# A spot on the page on screen with nothing under it (no tile, app, bar, dock) and outside the window: read-only CDP,
# device px "x y" (a real swipe starts there, never on a widget). $2 the swipe's way (-1 leftwards), $3 its length: a
# spot with room for the whole swipe first. The 05:25 FAIL (2026-10-23) was the check's: the leftmost empty spot
# (x 227, left of the window) clamped a leftward swipe to 207 px - under home's quarter-width turn and its flick
# speed, so home rightly stayed on page 1.
freept() {
  "$T/cdp.sh" eval home "(()=>{const b='$1'.split(' ').map(Number),r=devicePixelRatio,d=$2,len=$3,W=innerWidth*r;let best=null,room=-1;for(let y=.15;y<=.92;y+=.03)for(let x=.04;x<=.96;x+=.02){const cx=innerWidth*x,cy=innerHeight*y,px=cx*r,py=cy*r;if(b.length===4&&px>=b[0]-60&&px<=b[2]+60&&py>=b[1]-120&&py<=b[3]+60)continue;const e=document.elementFromPoint(cx,cy);if(!e||!e.closest('.page-track'))continue;if(e.closest('.tile,.app,.panel,.widget,.island,.owl,button,a,input,.bar,.bottom-bar,.dock,[data-key]'))continue;if(px<60||px>W-60)continue;const m=d<0?px-20:W-20-px;if(m>=len)return Math.round(px)+' '+Math.round(py);if(m>room){room=m;best=Math.round(px)+' '+Math.round(py)}}return best||'none'})()" 2>&1 | tr -d '"\r' | tail -1
}
# A real horizontal swipe on home from an empty spot: $1 -1 = to the next page (finger leftwards), 1 = back.
swipe() {
  # The window's box is kept clear only while it shows: on page 2 it's hidden (its bounds still listed), and keeping
  # its box clear there left no spot with room for the swipe back (05:57: 570 px from x 1678).
  kg | grep -q true && { echo "ENV: phone locked mid-run (keyguard)" | tee -a "$OUT/log.txt"; exit 5; }
  local d=$((W * 30 / 100)) p b=;  # 30% (680 px of 2268): above the quarter-width turn (+40), and the scan covers the whole page width from the far edge in
  [ "$(vis)" = visible=true ] && b=$(bounds); p=$(freept "$b" "$1" "$d"); [ "$p" != none ] && [ -n "$p" ] || { echo "ENV: no empty spot on page $(($(onpage) + 1)) to swipe from - stopping"; exit 5; }
  local x=${p% *} y=${p#* }; local to=$((x + $1 * d))
  [ $to -lt 20 ] && to=20; [ $to -gt $((W - 20)) ] && to=$((W - 20))
  # Shorter than home turns a page for (a quarter of its width, no flick): the check's spot, not the product.
  [ $(( (to - x) * $1 )) -ge $((W / 4 + 40)) ] || { echo "ENV: only a $(( (to - x) * $1 )) px swipe fits from $x,$y - stopping (not a product FAIL)"; exit 5; }
  # A cancelled stream sometimes still turns the page on its last flick velocity. Require the real release too:
  # raising an incoming task used to make WebView cancel on focus loss, even though Android kept sending moves.
  "$T/cdp.sh" eval home '(()=>{window.__desktopSwipeEnd=null;if(!window.__desktopSwipeWatching){window.__desktopSwipeWatching=true;for(const t of ["touchend","touchcancel"])addEventListener(t,()=>{window.__desktopSwipeEnd=t},{capture:true,passive:true})}return true})()' >/dev/null
  LASTSWIPE="$x,$y -> $to,$y"; echo "swipe $LASTSWIPE" >>"$OUT/log.txt"
  # The flash probe (2026-10-24: "the windows of the previous page appear for a split second" on the new page): on the
  # device, a SurfaceFlinger composition list every ~0.4 s for 10 s from the swipe, each sample "<device uptime ms>
  # <layers of $PKG composited>". The uptime is /proc/uptime (CLOCK_BOOTTIME), the clock of the slide's end line
  # ("at <elapsedRealtime>", PageSlide.kt), so flash() splits the samples at the end without a wall-clock or a log
  # count (06:5x: the probe counted end lines in the log, saw 0 in all 150 samples, and ran past the logcat's timeout).
  # A sample after the end that still composites the window = the flash. The same samples' $PKG and title bar rows go
  # to fd-bar.txt (barcheck). The swipe runs in the same device call, right after the sampler starts: as a separate
  # call it came only once the sampler's 10 s were over (job 20261024-190606-57880: every sample 10-0.6 s before the
  # slide's end line - 56 before / 0 after, and 0 bar samples during the 332 ms swipe back).
  sh_ "rm -f /data/local/tmp/fd-flash.txt /data/local/tmp/fd-bar.txt; (read u0 r </proc/uptime; u0=\${u0%.*}; while :; do read u r </proc/uptime; [ \${u%.*} -ge \$((u0 + 10)) ] && break; d=\$(dumpsys SurfaceFlinger); h=\$(echo \"\$d\" | awk \"/HWC layers/{f=1} f&&/^\\\$/{f=0} f\"); v=\$(echo \"\$h\" | grep -c $PKG); echo \${u%.*}\${u#*.}0 \$v >>/data/local/tmp/fd-flash.txt; echo \"@ \${u%.*}\${u#*.}0\" >>/data/local/tmp/fd-bar.txt; bl=\$(echo \"\$d\" | grep -A22 \"Layer .*window bar ${id:-x}#\"); ba=\$(echo \"\$bl\" | grep -o -m1 \"alpha=[0-9.]*\"); bv=\$(echo \"\$bl\" | grep -o -m1 \"isVisible=[a-z]*\"); echo \"=A \${ba:-none} \${bv:-none}\" >>/data/local/tmp/fd-bar.txt; echo \"\$h\" | grep -A1 -e $PKG -e \"window bar ${id:-x}\" >>/data/local/tmp/fd-bar.txt; done </dev/null >/dev/null 2>&1 &); input swipe $x $y $to $y 250"; sleep 1.5
  local ended; ended=$("$T/cdp.sh" eval home 'window.__desktopSwipeEnd' | tr -d '\"\r' | tail -1)
  [ "$ended" = touchend ] || fail "swipe lost its touch stream ($ended): $LASTSWIPE"
  pass "swipe received its release"
}

# After a swipe that leaves the window behind: was it composited after the slide ended? $1 the step. The end time is
# the swipe's last PowosPageSlide end line ("at <ms>", device elapsedRealtime), the samples' clock is /proc/uptime,
# stamped in ms too (the same clock: CLOCK_BOOTTIME). Seen before the end but never after = no flash; no sample on either side = the probe can't tell.
flash() {
  sleep 9
  local f l end before after n; f=$(sh_ "cat /data/local/tmp/fd-flash.txt")
  l=$(sh_ "grep PowosPageSlide /data/local/tmp/fd-log.txt | grep -F \"end (\" | tail -1")
  end=$(echo "$l" | sed -n 's/.* at \([0-9]*\)$/\1/p')
  echo "flash probe $1: end at ${end:-?} ms; samples (uptime ms, layers): $(echo $f | tr '\n' ' ')" >>"$OUT/log.txt"
  if [ -z "$end" ]; then echo "NOTE $1: flash probe can't tell (the end line has no 'at' time: $l)" | tee -a "$OUT/log.txt"; return; fi
  before=$(echo "$f" | awk -v e="$end" '$1<e && $2>0' | wc -l | tr -d ' ')
  after=$(echo "$f" | awk -v e="$end" '$1>=e && $2>0' | wc -l | tr -d ' ')
  n=$(echo "$f" | awk -v e="$end" '$1>=e' | wc -l | tr -d ' ')
  if [ "$before" -eq 0 ] || [ "$n" -eq 0 ]; then echo "NOTE $1: flash probe can't tell ($before samples with the window before the end, $n after it)" | tee -a "$OUT/log.txt"
  elif [ "$after" -gt 0 ]; then fail "$1: the old page's window flashed - composited in $after of $n samples after the slide ended"
  else pass "$1: no flash - the window was composited in $before samples during the slide, 0 of $n after it ended"; fi
}
# The title bar slid with its window (WindowFrames.slideMove, in the leashes' transaction): from the same samples
# (fd-bar.txt: "@ <uptime ms>", then each composited $PKG / "PowOS window bar <task>" layer's name and row), the
# bar's HWC Disp Frame minus the window's, against the first sample with both, stays within 4 px through the slide (both
# clip alike at the screen's edge: the bar spans the window's width), split at the end line's "at" like flash(). $1 the
# step; $3 hidden|shown: the bar after the slide ended (gone with its window, or there with it).
barcheck() {
  local f r l k; f=$(sh_ "cat /data/local/tmp/fd-bar.txt"); printf '%s\n' "$f" >"$OUT/bar-$3.txt"
  l=$(sh_ "grep PowosPageSlide /data/local/tmp/fd-log.txt | grep -F \"end (\" | tail -1"); k=$(echo "$l" | sed -n 's/.* at \([0-9]*\)$/\1/p')
  [ -n "$k" ] || { echo "NOTE $1: bar probe can't tell (the end line has no 'at' time: $l)" | tee -a "$OUT/log.txt"; return 0; }
  r=$(printf '%s\n' "$f" | awk -v k="$k" -v id="window bar $id" '
    function df(l,  a, i, n) { n = split(l, a, "|"); for (i = 1; i <= n; i++) if (a[i] ~ /^ *-?[0-9]+ +-?[0-9]+ +-?[0-9]+ +-?[0-9]+ *$/) return a[i]; return "" }
    function flush(  i, d, m, dv, ds) {
      # The SF layer of the bar (alpha= / isVisible= from dumpsys SurfaceFlinger): alpha < 0.05 or not visible = hidden at the compositor.
      if (e < k && e >= e0 + 150 && B != "" && AV == 0) { B = ""; sup++ }
      if (T != "" && B != "") { split(T, t, " "); split(B, b, " "); if (!based) { for (i = 1; i <= 4; i++) base[i] = b[i] - t[i]; based = 1 }
        dv = 0; ds = 0
        for (i = 1; i <= 4; i++) { d = b[i] - t[i] - base[i]; if (d < 0) d = -d; if (i % 2 == 0) { if (d > ds) ds = d } else if (d > dv) dv = d }
        # The slide hides the bar (WindowFrames.HIDE_BAR_DURING_SLIDE): its first 150 ms are the fade-out (and the late layout of WM).
        # Later, a composited bar must be exactly with its window. Then 300 ms after the end it is back, in place.
        if (e < k && e >= e0 + 150) { if (ds > ws) ws = ds; if (dv > wv) wv = dv
          # Peak window speed along the slide axis (px per ms between samples) x 16.7 ms = one 60 Hz frame dx.
          if (n > 0 && e > pe) { v = t[2] - pt; if (v < 0) v = -v; v = v / (e - pe); if (v > pv) pv = v }
          pt = t[2]; pe = e; n++ }
        if (e >= k + 300) { lateN++; if (ds > lateS) lateS = ds; if (dv > lateV) lateV = dv } }
      if (e >= k) { after++; if (B != "") barAfter++; lastBar = (B != "") } }
    /^@ / { if (started) flush(); if (!started) e0 = $2; started = 1; e = $2; T = ""; B = ""; nm = ""; AV = 1; next }
    /^=A / { a = $2; v = $3; sub(/alpha=/, "", a); AV = 1
      if (a == "none") { AV = 0; if (e >= e0 + 150 && e < k) noL++ }
      else if (a + 0 < 0.05) { AV = 0; if (e >= e0 + 150 && e < k) loA++ }
      else if (v != "isVisible=true") { AV = 0; if (e >= e0 + 150 && e < k) loV++ }
      else if (e >= e0 + 150 && e < k) shn++
      next }
    /\|/ { if (nm ~ id) { if (B == "") B = df($0) } else if (T == "") T = df($0); nm = ""; next }
    /^--$/ { next }
    { nm = $0 }
    END { if (started) flush(); printf "%d %d %d %d %d %d %d %d %d %d %d %d %d %d\n", n, ws, after, barAfter, lastBar, wv, pv * 16.7 + 0.5, lateN, lateV, lateS, noL, loA, loV, shn }')
  set -- "$1" "$2" "$3" $r; echo "bar probe $1: samples $4, worst bar-window offset: slide axis $5 px (limit: one frame's dx of this slide, ${10:-0} px), vertical ${9:-0} px (limit 4), after the end $6 samples, bar in $7, last ${8:-?}; SF bar layer during the slide (after the fade-out): absent ${14:-0}, alpha<0.05 ${15:-0}, not visible ${16:-0}, shown ${17:-0} samples" | tee -a "$OUT/log.txt"
  # Contract: hidden during the slide (not composited with its window after the fade-out) or exactly with it.
  if [ "${4:-0}" -lt 2 ]; then pass "$1: the title bar was hidden during the slide (${4:-0} visible samples with bar and window after the fade-out; decided by SF layer: absent ${14:-0}, alpha<0.05 ${15:-0}, not visible ${16:-0}, shown ${17:-0})"
  elif [ "${9:-0}" -gt 4 ]; then fail "$1: the title bar was misplaced - ${9} px off its window across the slide (bar-$3.txt)"
  elif [ "$5" -gt 4 ]; then fail "$1: the title bar stayed visible and trailed its window by ${5} px along the slide (bar-$3.txt)"
  else pass "$1: the title bar stayed exactly with its window ($4 samples, within $5 px)"; fi
  [ "${6:-0}" -gt 0 ] || return 0
  case $3 in
    hidden) [ "$7" = 0 ] && pass "$1: the bar went with its window" || fail "$1: the bar stayed after its window left - composited in $7 of $6 samples after the end" ;;
    shown) if [ "$8" != 1 ]; then fail "$1: the window arrived without its bar (last sample after the end has none)"
      elif [ "${11:-0}" -lt 1 ]; then echo "NOTE $1: bar probe can't tell where the bar landed (no sample with both 300 ms after the end)" | tee -a "$OUT/log.txt"
      elif [ "${12:-0}" -gt 4 ] || [ "${13:-0}" -gt 4 ]; then fail "$1: the bar landed off its window (vertical ${12} px, slide axis ${13} px, limit 4; bar-$3.txt)"
      else pass "$1: the bar faded back in at its window (${11} samples, vertical ${12} px, slide axis ${13} px)"; fi ;;
  esac
}
ends() { sh_ "grep -c \"PowosPageSlide.*end (\" /data/local/tmp/fd-log.txt"; }

key=$(hcall apps.list "[]" "l=>(l.find(a=>/^a:$PKG\\//.test(a.key))||{}).key||'ERR not in the list'")
case $key in a:$PKG/*) ;; *) fail "Calculator's key: $key" ;; esac
# The main log rotates in seconds (256 KiB, OplusTouch spam): a `logcat -d` after the fact found nothing. Capture the
# tags from the launch on, on the phone, bounded (timeout); hiddenapi denials log under the app's process name.
sh_ "rm -f /data/local/tmp/fd-log.txt; (timeout 240 logcat -T 1 -v time -s PowosWindowFrames PowosWindowFrame PowosFreeform PowosRunning PowosPageSlide com.powos.app:W </dev/null >/data/local/tmp/fd-log.txt 2>&1 &)"
r=$(hcall apps.launch "['$key']" "()=>'ok'"); [ "$r" = ok ] || fail "apps.launch: $r"
sleep 2.5; chk launch
id=$(hcall windows.list "[]" "l=>(l.find(w=>w.pkg==='$PKG')||{id:'none'}).id"); echo "window $id" | tee -a "$OUT/log.txt"
if [ "$id" = none ]; then
  # The bug of 2026-10-23: a floating Calculator that windows.list didn't have (no page, never hidden) - the evidence.
  # No single quotes inside sh_ (it wraps in su -c '...'): grep -E 'a|b' there ended the quote, piped all into "mode".
  sh_ "tail -40 /data/local/tmp/fd-log.txt; am stack list | grep -m3 -e calculator -e mode" >"$OUT/missing.txt"
  kg | grep -q true && { echo "ENV: phone locked mid-run (keyguard)" | tee -a "$OUT/log.txt"; exit 5; }
  fail "no Calculator in windows.list ($(vis)) - see missing.txt"
fi
[ "$(vis)" = visible=true ] || fail "Calculator's window isn't showing ($(vis))"
B1=$(bounds); echo "bounds on page 1: $B1" | tee -a "$OUT/log.txt"
P1=$(hcall store.get "['home.windows']" "m=>m&&m['$id']"); echo "stored page id: $P1" | tee -a "$OUT/log.txt"
[ -n "$P1" ] && [ "$P1" != undefined ] && [ "$P1" != null ] || fail "the window got no page (home.windows has no $id)"
"$T/shot.sh" "$OUT/1-open-page1.png"; pass "opened on page 1, stored on page id $P1"

# The window slid with the page (PageSlide.kt, one leash transaction per frame): its swipe's PowosPageSlide end line
# says it landed, after how long and how many frames moved; under 40 frames/s over the swipe it lagged the finger.
slid() {
  local l ms fr; sleep 0.5
  l=$(sh_ "grep PowosPageSlide /data/local/tmp/fd-log.txt | grep -F \"end (\" | tail -1")
  echo "slide $1: ${l:-none}" >>"$OUT/log.txt"
  [ "$l" != "$SLID" ] && [ -n "$l" ] || { kg | grep -q true && { echo "ENV: phone locked mid-run (keyguard)" | tee -a "$OUT/log.txt"; exit 5; }; fail "$1: the window didn't slide with the page (no PowosPageSlide end line)"; }
  SLID=$l
  # The lag's parts (PageSlide.kt): how long the windows stood still for their leashes, how late home's moves and
  # its settle came - each is how far the windows trail the page.
  echo "$1 timing: $(echo "$l" | sed -n 's/.*\(leash after.*\)/\1/p')" | tee -a "$OUT/log.txt"
  case $l in *"(landed)"*) ;; *) fail "$1: the slide didn't land: $l" ;; esac
  ms=$(echo "$l" | sed -n 's/.* after \([0-9]*\) ms: \([0-9]*\) frames.*/\1/p'); fr=$(echo "$l" | sed -n 's/.* ms: \([0-9]*\) frames.*/\1/p')
  [ -n "$ms" ] && [ -n "$fr" ] && [ "$ms" -gt 0 ] || fail "$1: unreadable slide line: $l"
  fps_gate "$1" "$fr" "$ms" 40
}
SLID=

E0=$(ends); swipe -1; chk swipe2
slid "swipe to page 2"
flash "swipe to page 2" "$E0"
barcheck "swipe to page 2" - hidden
"$T/shot.sh" "$OUT/2-page2-hidden.png"
[ "$(onpage)" = 1 ] && [ "$(vis)" = visible=false ] && [ "$(away)" = true ] && pass "swiped to page 2: hidden" \
  || fail "on page 2: page $(onpage), $(vis), away=$(away); $(ctx)"

swipe 1; chk swipe1
slid "swipe back to page 1"
sleep 2; barcheck "swipe back to page 1" - shown
"$T/shot.sh" "$OUT/3-page1-back.png"
B2=$(bounds); echo "bounds back on page 1: $B2" | tee -a "$OUT/log.txt"
[ "$(onpage)" = 0 ] && [ "$(vis)" = visible=true ] && [ "$(away)" = false ] || fail "back on page 1: page $(onpage), $(vis), away=$(away); $(ctx)"
[ "$B2" = "$B1" ] && pass "swiped back to page 1: shown at the same bounds" || fail "back on page 1 at $B2, opened at $B1"

# Its app opened while page 2 shows: the window comes to page 2 (home stays there).
swipe -1; chk swipe2b
[ "$(onpage)" = 1 ] && [ "$(vis)" = visible=false ] || fail "page 2 again: page $(onpage), $(vis); $(ctx)"
r=$(hcall apps.launch "['$key']" "()=>'ok'"); [ "$r" = ok ] || fail "apps.launch (from page 2): $r"
sleep 1.8; chk relaunch
"$T/shot.sh" "$OUT/4-opened-on-page2.png"
P2=$(hcall store.get "['home.windows']" "m=>m&&m['$id']")
[ "$(onpage)" = 1 ] && [ "$(vis)" = visible=true ] && [ "$P2" != "$P1" ] && pass "opened again on page 2: moved there (page id $P2)" \
  || fail "opened again from page 2: page $(onpage), $(vis), page id $P2 (was $P1); $(ctx)"

# Survives home's app restarting: page 1 (it hides), the app killed, home back - still page 2's.
hemit system.home null; chk home1
[ "$(vis)" = visible=false ] || fail "page 1 after the move: $(vis)"
sh_ "kill \$(pidof com.powos.app)"; t=0
until [ "$(CDP_TIMEOUT_S=8 "$T/cdp.sh" eval home 'window.__powosAlive === true' 2>/dev/null | tr -d '\r' | tail -1)" = true ] || [ $t -ge 12 ]; do sleep 3; t=$((t + 1)); done
sleep 2; chk restart
# Home's pages come back in two steps (the layout, then the pages live windows are on: ui/desktops.ts startDesktops, after
# the store is read). A swipe in between (1024 07:28: page 0 after it, no turn) is no product claim: wait for the pages.
t=0; until [ "$(npages)" -ge 3 ] 2>/dev/null || [ $t -ge 10 ]; do sleep 1; t=$((t + 1)); done; sleep 1
n=$(npages); P3=$(hcall store.get "['home.windows']" "m=>m&&m['$id']")
"$T/shot.sh" "$OUT/5-after-restart-page1.png"
[ "$P3" = "$P2" ] && [ "$(vis)" = visible=false ] && pass "after the app restarted: still page id $P3, hidden on page 1" \
  || fail "after the app restarted: page id $P3 (want $P2), $(vis), page $(onpage); $(ctx)"
swipe -1; chk swipe2c
"$T/shot.sh" "$OUT/6-after-restart-page2.png"
[ "$(onpage)" = 1 ] && [ "$(vis)" = visible=true ] && pass "after the restart, page 2 shows it" || fail "after the restart on page 2: page $(onpage), $(vis); $(ctx)"
echo "all passed; artefacts: $OUT"
