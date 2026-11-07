#!/bin/bash
# lanes: phone
# tools/phone/verify/ww-glue.sh: N1 of docs/WEB_WINDOWS.md "Native-glued windows" on the phone - a web window stays glued
# to its page through page switches (the user, 11-07: "the pages should have the windows absolutely glued to them ...
# page switching etc works instantly and 100% natively no race condition in updating window positions"), and a resize
# drops no frames. Needs home unfolded and the user idle 2+ min. With no web window on home's page it opens one itself
# (WW_GLUE_APPS, default Kate then Dolphin: the first the user isn't running, through home's launch path - apps.launch),
# measures on it, and closes it after (its window, and the app when it wasn't running before); never one of the user's.
#
#   ww-glue.sh --dry-run  read-only: what the run would open / measure / close now (no input, nothing opened)
#   ww-glue.sh            two page swipes (there and back) on an empty spot of the page, the slide to PowOS AI's page and
#                         back (N1b: from home's first page a swipe right), then an edge drag of the window
#   ww-glue.sh --read     read-only: the counts so far (no input)
#
# PASS needs, over the swipes:
#   page   every "ww glue: N frames, M off-thread" line (PowosShell, one per motion, ui/webwindows.tsx glueEnd) has M = 0
#          and at least one has N >= 10: no frame of the slide moved the window by a compositor-run animation (each
#          such frame = the app's layer a frame's travel behind its page)
#   host   FrameSync's page-frame lag over the swipes ("pf=a/b/c/d" in the host's "w.f" log, the difference before ->
#          after): reported as the share applied on the draw that shows its page frame (pf0); informative
#   ahead  N2's frame-ahead applies over the run ("ahead=a/b/c/d", FrameSync.ahead): >= 99 % on the draw that shows
#          their frame (a0), when 20+ of them ran (an APK without N2 has none: reported, not failed)
#   resize gfxinfo over the edge drag: janky frames <= 5 % (Android's own frame stats for home's window)
# Steam (informative): KWin's "also draws override-redirect" lines (0062) - its menus drawn into its window.
set -uo pipefail
T=$(cd "$(dirname "$0")/.." && pwd)
. "$T/verify/ww-lib.sh"
adb="$T/adb.sh"
PKG=com.powos.app
fail=0
say() { echo "$*"; }
bad() { echo "FAIL $*"; fail=1; }

pf() { "$adb" shell 'logcat -d -s PowosWebWindows:I' | grep -oE "${1:-pf}=[0-9]+/[0-9]+/[0-9]+/[0-9]+" | tail -1 | cut -d= -f2; }
since=$("$adb" shell 'date +%m-%d\ %H:%M:%S.000' | tr -d '\r')
pf0=$(pf)
ah0=$(pf ahead)

# setup_window: a web window on home's page - the one shown, else one this opens (OPENED, closed on exit).
OPENED="" OPENED_PROC=""   # only an app that wasn't running is ever opened (ww_running), so its process is ours
closeup() { [ -n "$OPENED" ] || return 0
  ww_close "$OPENED"; sleep 1.5
  ww_us "pkill -x '$OPENED_PROC'; true" >/dev/null   # the app this started: its process too
  say "closed $OPENED ($OPENED_PROC): this check opened it"; OPENED=""; }
trap closeup EXIT
setup_window() { local a key why
  rects=$(ev "$WWRECTS")
  [ -n "$rects" ] && [ "$rects" != null ] && { say "a web window on home's page already: $rects"; return 0; }
  ww_ready || { echo "SKIP home has no web windows here (folded, off): nothing to open one on"; exit 3; }
  for a in ${WW_GLUE_APPS:-kate dolphin}; do
    if ww_running "$a"; then say "$a: the user's $a runs - not opened over it"; continue; fi
    key=l:org.kde.$a
    if [ "${DRY:-0}" = 1 ]; then say "dry-run: would open $a ($key) via apps.launch, measure on it, close it after"; return 0; fi
    say "no web window on home's page: opening $a ($key) through home's launch path"
    OPENED_PROC=$a; if why=$(ww_open "$key" 45); then OPENED=$why; sleep 2; else echo "FAIL setup: $why"; exit 1; fi
    rects=$(ev "$WWRECTS")
    [ -n "$rects" ] && [ "$rects" != null ] || { echo "FAIL setup: $a opened as $OPENED but shows on no page on screen"; exit 1; }
    say "opened $OPENED ($a) at $rects"; return 0
  done
  echo "SKIP every candidate app (${WW_GLUE_APPS:-kate dolphin}) is the user's, running now: not opened over"; exit 3; }

if [ "${1:-}" = --dry-run ]; then
  DRY=1; read -r screen < <("$T/idle.sh"); say "phone: $screen"
  setup_window; say "dry-run: then 4 page swipes from an empty spot, an edge drag of the top window, the counts; nothing done"
  exit 0
fi
if [ "${1:-}" != --read ]; then
  "$T/idle.sh" --wait 120 1800 >/dev/null || { echo "SKIP phone busy (not idle 2 min within 30 min)"; exit 3; }
  read -r screen < <("$T/idle.sh")
  case "$screen" in *screen=Awake*) ;; *) echo "SKIP screen not on ($screen)"; exit 3 ;; esac
  setup_window
  # An empty spot of the page, device px (as the gate's homeGesturesScene finds one): never a window, tile or bar.
  at=$(ev "(()=>{const d=devicePixelRatio;for(let y=innerHeight*0.3;y<=innerHeight*0.7;y+=12)for(let x=innerWidth*0.9;x>=innerWidth*0.55;x-=12){const e=document.elementFromPoint(x,y);if(e&&e.closest('.page-track')&&!e.closest('.webwindow,.tile,.home-tile,.app,.panel,.widget,.island,button,a,input,textarea,.bar,.dock,[data-key]'))return Math.round(x*d)+' '+Math.round(y*d)}return ''})()")
  [ -n "$at" ] || { echo "SKIP no empty spot on home's page to swipe from"; exit 3; }
  read -r x y <<<"$at"
  say "swipe from $x,$y (windows at $rects)"
  "$adb" shell "input swipe $x $y $((x - 900)) $y 220"
  sleep 1.5
  "$adb" shell "input swipe $((x - 900)) $y $x $y 220"
  sleep 1.5
  # N1b: on home's first page now, the same swipe right is the slide to PowOS AI's page; then back.
  "$adb" shell "input swipe $((x - 900)) $y $x $y 220"
  sleep 1.5
  "$adb" shell "input swipe $x $y $((x - 900)) $y 220"
  sleep 1.5
  # The resize: the top window's bottom-right grab, 300 px out and back, 1.2 s each, with home's frame stats reset.
  read -r l t r b <<<"$(echo "${rects##*,}")"
  "$adb" shell "dumpsys gfxinfo $PKG reset" >/dev/null
  "$adb" shell "input swipe $((r - 4)) $((b - 4)) $((r - 304)) $((b - 204)) 1200"
  sleep 0.5
  "$adb" shell "input swipe $((r - 304)) $((b - 204)) $((r - 4)) $((b - 4)) 1200"
  sleep 1
  gfx=$("$adb" shell "dumpsys gfxinfo $PKG" | tr -d '\r')
  total=$(echo "$gfx" | grep -m1 'Total frames rendered' | grep -oE '[0-9]+$')
  janky=$(echo "$gfx" | grep -m1 'Janky frames:' | sed -E 's/.*Janky frames: ([0-9]+) \(([0-9.]+)%\).*/\1 \2/')
  p90=$(echo "$gfx" | grep -m1 '90th percentile' | grep -oE '[0-9]+ms')
  say "resize: ${total:-?} frames, janky ${janky:-?} (count %), p90 ${p90:-?}"
  pct=${janky##* }
  [ -n "$pct" ] && awk -v p="$pct" 'BEGIN{exit !(p > 5)}' && bad "resize: ${pct}% janky frames (want <= 5)"
fi

lines=$("$adb" shell "logcat -d -T '$since' -s PowosShell:I" 2>/dev/null | grep -oE 'ww glue: [0-9]+ frames, [0-9]+ off-thread.*' )
say "${lines:-no ww glue lines}"
if [ "${1:-}" != --read ]; then
  [ -n "$lines" ] || bad "page: no \"ww glue\" line over the swipes (an APK without N1, or no window moved)"
  echo "$lines" | awk '/ww glue/ { if ($5 + 0 > 0) bad = 1; if ($3 + 0 >= 10) long = 1 } END { exit !(bad || !long) }' &&
    bad "page: a motion moved the window off the main thread, or none was 10+ frames: $(echo "$lines" | tr '\n' ';')"
fi
pf1=$(pf)
ah1=$(pf ahead)
if [ -n "$ah1" ]; then
  verdict=$(python3 -c "
a=[int(v) for v in ('${ah0:-0/0/0/0}').split('/')]; b=[int(v) for v in '$ah1'.split('/')]; d=[y-x for x,y in zip(a,b)]; n=sum(d)
print('%d %s %.1f' % (n, '/'.join(map(str,d)), 100.0*d[0]/n if n else 0))")
  read -r an ad apct <<<"$verdict"
  say "ahead: $an frame-ahead applies, a0..3 = $ad ($apct% on the draw that shows their frame)"
  # N2's timing (FrameSync): corrections on the prediction's draw / after it, predictions lost to a newer frame, ms from
  # the request to its frame's vsync (lead: under ~0 it can't ride that commit) and from that vsync to the callback.
  say "ahead timing: $("$adb" shell 'logcat -d -s PowosWebWindows:I' | grep -oE 'aheadfix=[0-9/]+ aheadlost=[0-9]+ aheadlead=[-0-9.]+ms aheadfire=[-0-9.]+ms' | tail -1) (totals since the app started)"
  [ "${1:-}" != --read ] && [ "$an" -ge 20 ] && awk -v p="$apct" 'BEGIN{exit !(p < 99)}' && bad "ahead: $apct% on their frame's draw (want >= 99)"
else
  say "ahead: no ahead= counters (an APK without N2)"
fi
if [ -n "$pf0" ] && [ -n "$pf1" ]; then
  python3 -c "
a=[int(v) for v in '$pf0'.split('/')]; b=[int(v) for v in '$pf1'.split('/')]; d=[y-x for x,y in zip(a,b)]; n=sum(d)
print('host: %d applies over the run, pf0..3 = %s (%.0f%% on the draw of their page frame)' % (n, '/'.join(map(str,d)), 100.0*d[0]/n if n else 0))"
fi
probe=$(mktemp -d)/steam-popups.sh
echo 'grep -a "also draws override-redirect" /run/powos-app/hyprland.log | tail -3' > "$probe"
"$T/root.sh" "$probe" 2>/dev/null | grep -v pushed | sed 's/^/steam: /'
rm -rf "$(dirname "$probe")"
[ "$fail" = 0 ] && echo PASS
exit "$fail"
