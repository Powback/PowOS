#!/bin/bash
# lanes: emu? phone
# e2e-desktop.sh --round R --part 1|2|3 [--of 3] [--android-only]: the unfolded home used like a user, for the
# manager's review. --android-only (the emulator lane, no KWin/Kate/Plasma): skips Kate-from-search and Dolphin/
# Gwenview in part 1 (a NOTE, not a FAIL); parts 2 (Calculator only) and 3 (Chrome - on the emulator's image too -
# plus the drawer/edit mode) need no Linux session and run unchanged.
# (board manager-end-to-end-user-journeys-on-the-phone-qa; e2e-lib.sh has the rules: screenshots + steps.txt in
# /home/powos/design-qa/e2e-desktop/<round>/, never the verify pill, only its own windows closed, layout untouched).
# Queue it (tools/phone/verify/e2e-queue.sh queues a whole round: the 3 parts of this one, then e2e-appapi.sh).
#   part 1 apps:    Chrome from the drawer, Kate from search, Calculator and Dolphin from the dock (each put away in
#                   the dock after its look: a floating window covers the drawer), an image from Dolphin (KIO's open,
#                   what Dolphin does: Gwenview), Gwenview and Dolphin closed by their title bars' close button
#   part 2 windows: Calculator from the dock - dragged by its bar, resized by its grip (4 frames mid-drag), minimised
#                   and restored from the dock, pages swiped beside it, moved to page 2 and back over the screen's
#                   edge, reopened from recents, the shade pulled over it and pushed away, closed by its bar
#   part 3 home:    scrolling inside a window (Chrome) down and up, the drawer's two-stage pull-up (the drawer; pulled
#                   further: search + keyboard), edit mode entered (a hold on empty space) and left (Back)
# Exit: 0 (FAIL lines = a FAIL); 3 a real touch / no window (re-queued); 5 can't run.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/e2e-lib.sh"
e2e_args "$@"; [ "$LAST" = 1 ] && LAST=3
e2e_init desktop
e2e_setup inner
CALC=${TEST_APP:-com.oneplus.calculator} CHROME=com.android.chrome
IMG=/usr/share/wallpapers/Next/contents/images/1440x2960.png

step start "the unfolded home, page 1 (the journey found home on page index $PAGE0; -1 = PowOS AI's)"
note "found home on page index $PAGE0 (-1 = PowOS AI's page), ${W}x${H}; the journey runs from page 1 and goes back there at the end"

# The drawer by a swipe up from empty space in home's right half (the left half's pull is PowOS AI's panel when the
# pull-up corners are on: from the centre, 02-drawer got the AI panel, round 1); 0 when it opened.
open_drawer() {
  local p; p=$(freept "" 0 0 .54); [ "$p" != none ] && [ -n "$p" ] || { fail "no empty spot on home to swipe up from"; return 1; }
  set -- $p; swipe "$1" "$2" "$1" $(($2 - H * 30 / 100)) 250 "up from empty space (the drawer)" || return 1
  sleep 1.2; chk drawer; [ "$(isopen)" = true ]
}
# dock_tap <key prefix> <name>: a real tap on its dock cell (read over CDP).
dock_tap() { local p; p=$(pt "$(dockel "$1")"); case $p in none|off|"") fail "no dock cell for $2 ($p)"; return 1 ;; esac
  set -- $p "$2"; tap "$1" "$2" "$3's dock cell"; }
# put_away <window key> <dock key prefix> <name>: a dock tap on the focused window's app minimises it.
put_away() {
  local wl='l=>JSON.stringify(l.map(w=>({id:w.id,pkg:w.pkg,app:w.app,min:w.minimised,away:w.away,b:w.bounds})))'
  local before after; before=$(hcall windows.list "[]" "$wl")
  dock_tap "$2" "$3" || return 1; sleep 1.8; chk "minimise $3"
  after=$(hcall windows.list "[]" "$wl")
  note "windows.list before the dock tap: $before"; note "windows.list after: $after"
  step "$4" "$3 put away: a tap on its dock cell while its window is in front"
  local m; m=$(win "$1" minimised)
  [ "$m" = true ] && pass "$3 minimised into the dock" || fail "$3 after a dock tap on it in front: minimised=$m (windows.list before: $before; after: $after; WindowFrames log: $(sh_ "logcat -d | grep -E \"minimise task|can.t minimise\" | tail -3" | tr "\n" "~"))"
}
# closebar <task> <name> <slug>: its title bar's close button, a real tap.
closebar() {
  local p; p=$(closebtn "$1"); [ -n "$p" ] || { fail "$2 has no title bar to close it by"; return 1; }
  set -- "$1" "$2" "$3" $p; tap "$4" "$5" "$2's close button" || return 1; sleep 2; chk "close $2"
  step "$3" "$2 closed by its title bar's close button"
  [ -z "$(tasks | grep "^$1 ")" ] && pass "$2's window (task $1) is gone" || fail "$2's task $1 is still there after its close button"
}
floating() { # <task> <name>: a window smaller than the screen
  local b; b=$(tbounds "$1"); set -- "$1" "$2" $b
  [ $# -ge 6 ] && [ $(($5 - $3)) -lt $((W * 9 / 10)) ] && [ $(($5 - $3)) -gt 200 ]
}

# Chrome from the drawer: its A-Z cell (the letter bar's C first when it's off screen). Split out of part1() to
# keep it under the length budget (test-complexity.sh) - same steps, same CH global part2/part3 read.
part1_chrome() {
  if open_drawer; then
    step drawer "the drawer, pulled up from home"
    pass "the drawer opened"
    local cel="document.querySelector('.drawer .drawer-list .grid.az .app[data-key^=\"a:$CHROME/\"]')" p
    inlist() { ev "(()=>{const e=$cel,l=document.querySelector('.drawer .drawer-list');if(!e||!l)return 'none';const r=e.getBoundingClientRect(),q=l.getBoundingClientRect();return String(r.top>=q.top&&r.bottom<=q.bottom&&r.bottom<=innerHeight)})()"; }
    if [ "$(inlist)" != true ]; then
      p=$(pt "[...document.querySelectorAll('.drawer .letter-bar span')].find(s=>s.textContent==='C')")
      case $p in none|off|"") note "no letter bar C ($p)" ;; *) set -- $p; tap "$1" "$2" "the letter bar's C"; sleep 1 ;; esac
    fi
    p=$(pt "$cel")
    if [ "$(inlist)" = true ] && [ "$p" != off ]; then
      step drawer-chrome "Chrome's cell in the drawer's A-Z list"
      set -- $p; tap "$1" "$2" "Chrome in the drawer"; sleep 3; chk chrome
      CH=$(waitwin $CHROME 8)
      step chrome "Chrome opened from the drawer"
      [ "$CH" != none ] && floating "$CH" Chrome && pass "Chrome opened as a floating window (task $CH)" || fail "Chrome from the drawer: window $CH, bounds $(tbounds "$CH")"
      [ "$(isopen)" = false ] || fail "the drawer is still up behind Chrome"
      [ "$CH" != none ] && put_away $CHROME "a:$CHROME/" Chrome chrome-away
    else
      fail "Chrome's drawer cell isn't on screen ($p)"; back
    fi
  else fail "a swipe up from empty space didn't open the drawer"; fi
}
# Kate from search: the pill's field (focused before anything is typed - never into a terminal). --android-only:
# no Linux session on this lane - skipped, a NOTE not a FAIL. Split out of part1() to keep it under the length
# budget (test-complexity.sh) - same steps, same KT global.
part1_search_kate() {
  if [ "$ANDROID_ONLY" = 1 ]; then
    skip_linux search-kate "Kate from search (needs the Linux session)"
    return
  fi
  local f; f=$(pt "document.querySelector('.home > .bar textarea')")
  case $f in none|off|"") fail "no search pill on home ($f)" ;; *)
    set -- $f; tap "$1" "$2" "the search pill"; sleep 1.2; chk pill
    if [ "$(ev "document.activeElement&&document.activeElement.matches('.home > .bar textarea')?'yes':'no'")" = yes ] &&
       sh_ "dumpsys window | grep -m1 mCurrentFocus" | grep -q "com.powos.app"; then
      sh_ "input text kate"; sleep 1.5; chk typed
      step search-kate "\"kate\" typed into the search pill: the results"
      p=$(pt "document.querySelector('.drawer-list.results .app[data-key=\"l:org.kde.kate\"]')")
      case $p in none|off|"") fail "no Kate in the search results ($p)"; back; back ;; *)
        pass "Kate in the search results"
        set -- $p; tap "$1" "$2" "Kate in the results"
        KT=$(waitwin l:org.kde.kate 30); chk kate; sleep 2
        step kate "Kate opened from search"
        [ "$KT" != none ] && floating "$KT" Kate && pass "Kate opened as a floating window (task $KT)" || fail "Kate from search: window $KT, bounds $(tbounds "$KT")"
        [ "$(ev 'importShim("./state.ts").then(m=>JSON.stringify(m.query.value))')" = '""' ] || note "the search text stayed after the launch"
        [ "$KT" != none ] && put_away l:org.kde.kate l:org.kde.kate Kate kate-away ;;
      esac
    else
      step search "the search pill tapped"; fail "the search pill didn't take the focus - nothing typed"; back
    fi ;;
  esac
}
# Calculator from the dock (Android, every lane); Dolphin + the image it opens (Gwenview) need the Linux session -
# --android-only skips them, a NOTE not a FAIL. Split out of part1() to keep it under the length budget - same
# steps, same CT/DT/GT globals part2/part3 read.
part1_dock_and_image() {
  dock_tap "a:$CALC/" Calculator && { sleep 2.5; chk calc
    CT=$(waitwin $CALC 6); step calculator "Calculator opened from the dock"
    [ "$CT" != none ] && floating "$CT" Calculator && pass "Calculator opened as a floating window (task $CT)" || fail "Calculator from the dock: window $CT"
    [ "$CT" != none ] && put_away $CALC "a:$CALC/" Calculator calculator-away; }
  if [ "$ANDROID_ONLY" = 1 ]; then
    skip_linux dolphin "Dolphin from the dock, and an image opened from it (Gwenview) - needs the Linux session"
  else
  dock_tap l:org.kde.dolphin Dolphin && {
    DT=$(waitwin l:org.kde.dolphin 30); chk dolphin; sleep 2
    step dolphin "Dolphin opened from the dock"
    [ "$DT" != none ] && floating "$DT" Dolphin && pass "Dolphin opened as a floating window (task $DT)" || fail "Dolphin from the dock: window $DT"; }

  if [ "${DT:-none}" != none ]; then
    local before; before=$(tasks)
    log "open $IMG via kioclient exec (Dolphin's open)"
    us "setsid -f kioclient exec $IMG >/tmp/e2e-kio.log 2>&1 </dev/null" >/dev/null
    GT=$(waitwin l:org.kde.gwenview 25); chk gwenview; sleep 2
    step image "an image opened from Dolphin: the image viewer (Gwenview)"
    [ "$GT" != none ] && floating "$GT" Gwenview && pass "the image opened in a floating Gwenview window (task $GT)" || fail "the image from Dolphin: Gwenview window $GT ($(us 'tail -2 /tmp/e2e-kio.log' | tr '\n' ' '))"
    [ "$GT" != none ] && closebar "$GT" Gwenview image-closed
    closebar "$DT" Dolphin dolphin-closed
  fi
  fi
}
part1() {
  part1_chrome
  part1_search_kate
  part1_dock_and_image
}

part2() {
  dock_tap "a:$CALC/" Calculator || return
  sleep 2.5; chk calc; CT=$(waitwin $CALC 6)
  step calculator "Calculator opened from the dock"
  [ "$CT" != none ] && floating "$CT" Calculator && pass "Calculator floats (task $CT, $(tbounds "$CT"))" || { fail "no floating Calculator ($CT)"; return; }

  # Drag by the title bar.
  local b0 b1 p x y i dx=$(dp 120) dy=$(dp 60); b0=$(tbounds "$CT"); p=$(barpt "$CT")
  # The product stops a window's bottom at home's bottom bar (WindowFrame.moved, by design): a 70%-tall window has
  # ~65 px of room down, so dragging down 165 "failed" by exactly the clamp. With less room than the drag, go UP.
  local dock room; dock=$(pt "$(dockel "a:$CALC/")"); set -- $b0; room=$(( ${dock#* } - ${4:-0} ))
  if [ -n "${dock#* }" ] && [ "$room" -lt $((dy * 2)) ] 2>/dev/null; then dy=$((-dy)); fi
  # Same for sideways: a window opened right of centre (side docks, r4: 776..2136 of 2268) dragged right ended past the
  # screen edge (2467), its grip off screen and the resize below tapped nothing. Go left when the right has no room.
  [ $((W - ${3:-0})) -lt $((dx * 2)) ] && dx=$((-dx))
  if [ -n "$p" ]; then set -- $p; x=$1; y=$2
    if mdown $x $y "Calculator's title bar"; then
      mpath $x $y $((x + dx)) $((y + dy)) 6
      sleep 0.3; mup $((x + dx)) $((y + dy)); sleep 1.2; chk drag
      b1=$(tbounds "$CT"); step dragged "Calculator dragged by its title bar ($dx,$dy px)"
      set -- $b0 $b1
      [ $# -ge 8 ] && [ $((($5 - $1) * ${dx#-} / dx)) -ge $((${dx#-} * 7 / 10)) ] && [ $((($6 - $2) * ${dy#-} / dy)) -ge $((${dy#-} * 5 / 10)) ] && pass "it moved with the finger: $b0 -> $b1" || fail "dragged $dx,$dy: $b0 -> $b1"
    fi
  else fail "no title bar on Calculator's window"; fi

  # Resize by the grip, 4 frames while the finger is down.
  local g; g=$(wframe "PowOS window grip $CT}")
  if [ -n "$g" ]; then set -- $g; x=$((($1 + $3) / 2)); y=$((($2 + $4) / 2))
    b0=$(tbounds "$CT"); set -- $b0; local w0=$(($3 - $1)) wl=$(($3 - $1)) wi grow=0 mono=1
    if mdown $x $y "Calculator's grip"; then
      for i in 1 2 3 4; do
        mmove $((x + $(dp 40) * i)) $((y + $(dp 30) * i)); sleep 0.7
        set -- $(tbounds "$CT"); wi=$(($3 - $1))
        step "resize-$i" "resizing by the grip, finger still down: frame $i of 4 (window $wi px wide)"
        [ $wi -gt $w0 ] && grow=$((grow + 1)); [ $wi -lt $wl ] && mono=0; wl=$wi
        note "mid-drag frame $i: $wi px wide (started $w0)"
      done
      mup $((x + $(dp 160))) $((y + $(dp 120))); sleep 1.5; chk resize
      b1=$(tbounds "$CT"); set -- $b1; local w1=$(($3 - $1))
      step resized "the grip let go: Calculator's new size"
      [ $w1 -gt $w0 ] && pass "resized: $w0 -> $w1 px wide" || fail "the grip didn't resize it ($w0 -> $w1)"
      [ $grow -ge 2 ] && [ $mono = 1 ] && pass "live: it grew while the finger moved ($grow of 4 frames bigger)" || fail "not live: $grow of 4 mid-drag frames bigger (monotonic=$mono)"
    fi
  else fail "no grip on Calculator's window"; fi

  # Minimise and restore from the dock.
  b0=$(tbounds "$CT")
  dock_tap "a:$CALC/" Calculator && { sleep 1.8; chk min
    step minimised "a dock tap on Calculator (in front): minimised"
    [ "$(win $CALC minimised)" = true ] && [ "$(tvis "$CT")" = false ] && pass "minimised into the dock" || fail "after the dock tap: minimised=$(win $CALC minimised), visible=$(tvis "$CT")"; }
  dock_tap "a:$CALC/" Calculator && { sleep 1.8; chk restore
    step restored "another dock tap: Calculator restored"
    [ "$(win $CALC minimised)" = false ] && [ "$(tvis "$CT")" = true ] && [ "$(tbounds "$CT")" = "$b0" ] && pass "restored where it was ($b0)" || fail "restored: minimised=$(win $CALC minimised), at $(tbounds "$CT") (was $b0)"; }

  # Pages swiped beside it.
  local d=$((W * 35 / 100)) pg0; pg0=$(hpage)
  p=$(freept "$(tbounds "$CT")" -1 "$d")
  if [ "$p" != none ] && [ -n "$p" ]; then set -- $p; x=$1; y=$2; local to=$((x - d)); [ $to -lt 20 ] && to=20
    [ $((x - to)) -lt $((d * 2 / 3)) ] && fail "the swipe beside the window had only $((x - to)) px of room (want $d): a check limit, not the page swipe"
    swipe $x $y $to $y 250 "beside the window to the next page" && { sleep 1.5; chk page2
      step page2 "a swipe beside the window: the next page (the window stays on its own page)"
      [ "$(hpage)" = $((pg0 + 1)) ] && [ "$(tvis "$CT")" = false ] && pass "page $((pg0 + 2)) shows, Calculator hidden with its page" || fail "after the swipe: page $(hpage) (from $pg0), Calculator visible=$(tvis "$CT")"
      p=$(freept "" 1 "$d"); set -- $p; x=$1; y=$2; to=$((x + d)); [ $to -gt $((W - 20)) ] && to=$((W - 20))
      swipe $x $y $to $y 250 "back to the window's page" && { sleep 1.5; chk page1
        step page1 "swiped back: the window's page, the window as it was"
        [ "$(hpage)" = "$pg0" ] && [ "$(tvis "$CT")" = true ] && [ "$(tbounds "$CT")" = "$b0" ] && pass "back on page $((pg0 + 1)), Calculator shown at $b0" || fail "back: page $(hpage), visible=$(tvis "$CT"), at $(tbounds "$CT") (was $b0)"; }; }
  else fail "no empty spot beside the window to swipe from"; fi

  # Moved to page 2 over the screen's right edge, and back over the left.
  edge() { # <to x> <slug> <what> <want page>
    local p; p=$(barpt "$CT"); [ -n "$p" ] || { fail "no title bar to drag"; return 1; }; set -- "$@" $p
    mdown $5 $6 "Calculator's title bar" || return 1
    mpath $5 $6 $1 $6 8
    sleep 0.3; mup $1 $6; sleep 2; chk "$2"
    step "$2" "$3"
    [ "$(hpage)" = "$4" ] && [ "$(tvis "$CT")" = true ] && pass "home and the window on page $(($4 + 1)) together" || fail "dropped at the edge: home page $(hpage) (want $4), Calculator visible=$(tvis "$CT")"
  }
  edge $((W - 12)) to-page2 "Calculator dragged onto the screen's right edge: it and home go to the next page" $((pg0 + 1)) &&
    edge 12 to-page1 "and onto the left edge: back to the first page" "$pg0"

  # Reopened from recents (the switcher): a real tap on its card.
  b0=$(tbounds "$CT"); sh_ "input keyevent KEYCODE_APP_SWITCH"; sleep 2; chk switcher
  step recents "the switcher (recents) over the window"
  p=$(pt "document.querySelector('.recents.open .task[data-task=\"$CT\"] .task-shot')")
  case $p in none|off|"") fail "the switcher shows no card for Calculator ($p)"; back ;; *)
    pass "Calculator's card in the switcher"
    set -- $p; tap "$1" "$2" "Calculator's card" && { sleep 2; chk reopen
      step reopened "Calculator reopened from its card"
      local gh; gh=$(ev "document.querySelector('.recents-expand,.recents.open')?'ghost':'clean'")
      [ "$(tvis "$CT")" = true ] && [ "$(tbounds "$CT")" = "$b0" ] && pass "back where it was ($b0)" || fail "reopened: visible=$(tvis "$CT"), at $(tbounds "$CT") (was $b0)"
      [ "$gh" = clean ] && pass "no switcher layer or grown card left behind" || fail "the switcher's layer / grown card stays behind the window"; } ;;
  esac

  # The shade over the window.
  local S=$((H / 100)) X=$((W * 8 / 10)) q
  if mdown $X 8 "the status bar (the shade)"; then
    mpath $X 8 $X $((8 + 40 * S)) 14; mup $X $((8 + 40 * S)); sleep 1.5; chk shade
    q=$(ev 'getComputedStyle(document.querySelector(".notif-panel")).getPropertyValue("--q").trim()' shade)
    step shade "the shade pulled down over the window"
    awk -v q="$q" 'BEGIN{exit !(q > 0.5)}' && pass "the shade is open (q $q) over Calculator" || fail "the shade didn't open over the window (q $q)"
    local e; e=$(ev 'String(Math.round(document.querySelector(".notif-panel").getBoundingClientRect().bottom*devicePixelRatio))' shade)
    [ "${e:-0}" -gt $((10 * S)) ] 2>/dev/null || e=$((H / 2))
    if mdown $((W / 2)) $((e - 6 * S)) "the shade's lower edge"; then
      mpath $((W / 2)) $((e - 6 * S)) $((W / 2)) $((e - 26 * S)) 10; mup $((W / 2)) $((e - 26 * S)); sleep 1.5; chk shade-up
    fi
    q=$(ev 'getComputedStyle(document.querySelector(".notif-panel")).getPropertyValue("--q").trim()' shade)
    awk -v q="$q" 'BEGIN{exit !(q < 0.05)}' || { back 1; q=$(ev 'getComputedStyle(document.querySelector(".notif-panel")).getPropertyValue("--q").trim()' shade); note "pushed up it stayed; Back closed it"; }
    step shade-closed "the shade pushed away: the window again"
    awk -v q="$q" 'BEGIN{exit !(q < 0.05)}' && [ "$(tvis "$CT")" = true ] && pass "the shade is shut, Calculator still there" || fail "after closing the shade: q $q, Calculator visible=$(tvis "$CT")"
  fi
  closebar "$CT" Calculator closed
}

part3() {
  # Scrolling inside a window: Chrome's page, up and down (the touches the app's, not home's).
  dock_tap "a:$CHROME/" Chrome || return
  sleep 3; chk chrome; CH=$(waitwin $CHROME 8)
  step chrome "Chrome opened from the dock"
  [ "$CH" != none ] && floating "$CH" Chrome && pass "Chrome floats (task $CH)" || fail "no floating Chrome ($CH)"
  if [ "$CH" != none ]; then
    local b x y1 y2 u0 u1 u2 pg; b=$(tbounds "$CH"); set -- $b; x=$((($1 + $3) / 2)); y1=$(($2 + ($4 - $2) * 80 / 100)); y2=$(($2 + ($4 - $2) * 35 / 100))
    ui() { sh_ "uiautomator dump /data/local/tmp/e2e-ui.xml >/dev/null 2>&1; md5sum /data/local/tmp/e2e-ui.xml; rm -f /data/local/tmp/e2e-ui.xml" | cut -c1-12; }
    u0=$(ui); pg=$(hpage)
    swipe $x $y1 $x $y2 400 "up inside Chrome's page (scroll down)" && { sleep 1.5; chk scroll1; u1=$(ui)
      step scrolled-down "a swipe up inside Chrome: its page scrolled down"
      [ "$u1" != "$u0" ] && pass "Chrome's content moved" || fail "Chrome's content didn't move (its view tree is the same)"
      [ "$(hpage)" = "$pg" ] && [ "$(isopen)" = false ] && pass "home didn't take it (page $((pg + 1)), drawer shut)" || fail "home took the swipe: page $(hpage), drawer open=$(isopen)"; }
    swipe $x $y2 $x $y1 400 "down inside Chrome's page (scroll up)" && { sleep 1.5; chk scroll2; u2=$(ui)
      step scrolled-up "a swipe down inside Chrome: back up"
      [ "$u2" != "$u1" ] && pass "Chrome's content moved back" || fail "Chrome's content didn't move back"; }
    # Put away, not closed by its bar: the drawer's stages below pull on home, and Chrome left up (its close button
    # under the verify pill, round 1) took both pulls - they started inside its window, so they were Chrome's.
    put_away $CHROME "a:$CHROME/" Chrome chrome-away
  fi

  # The drawer's two stages (pullup-stage2.sh's moves): a plain swipe = the drawer, no keyboard; pulled further and
  # held = the search with the keyboard.
  local X=$((W * 3 / 4)) Y0
  open_drawer || true
  step drawer "stage 1: a plain swipe up - the drawer, no keyboard"
  [ "$(isopen)" = true ] && [ "$(ev "document.activeElement&&document.activeElement.matches('.home > .bar textarea')?'yes':'no'")" = no ] && [[ "$(ime)" == *false* ]] &&
    pass "the drawer is up, the search isn't focused, no keyboard" || fail "stage 1: drawer open=$(isopen), $(ime) (windows now: $(hcall windows.list "[]" "l=>JSON.stringify(l.map(w=>[w.id,w.minimised,w.away,w.bounds]))"); focus: $(sh_ "dumpsys window | grep -m1 mCurrentFocus"))"
  back; back 0.6
  # A spot that is always free (footpt.js: a gap in the dock's or the bottom bar's row, right half - the left half is
  # PowOS AI's pull-up corner, 12:48 round 3): with windows open home had no empty spot above them (freept, 15:11).
  local p2; p2=$(ev "$(cat "$here/footpt.js")"); Y0=0; [ "$p2" != none ] && [ -n "$p2" ] && { set -- $p2; X=$1; Y0=$2; }
  if [ "${Y0:-0}" -gt 0 ] && offpill $X "$Y0" "empty space (the long pull)"; then
    # pullup-stage2.sh's pull: the DOWN and its move past the slop in ONE phone call (a DOWN held until the next adb
    # call is a long press: edit mode, rounds 2-3), then on up to 48 % of the screen, held, let go.
    log "long pull from $X,$Y0 up 48 %"; sh_ "input motionevent DOWN $X $Y0; input motionevent MOVE $X $((Y0 - H * 3 / 100))"
    mpath $X $((Y0 - H * 3 / 100)) $X $((Y0 - H * 48 / 100)) 8; sleep 0.3
    mup $X $((Y0 - H * 48 / 100)); sleep 1.5; chk pull2
    step search "stage 2: pulled further up - the search, with the keyboard"
    [ "$(ev "document.activeElement&&document.activeElement.matches('.home > .bar textarea')?'yes':'no'")" = yes ] && [[ "$(ime)" == *true* ]] &&
      pass "the search is focused and the keyboard is up" || fail "stage 2: search focused=$(ev "document.activeElement&&document.activeElement.matches('.home > .bar textarea')?'yes':'no'"), $(ime)"
    back; back; sleep 0.5
  else step search "stage 2: the long pull"; fail "no empty spot to start the long pull from"; fi

  # Edit mode: a hold on empty space, Back leaves it - the layout untouched.
  local p; p=$(freept "" 0 0)
  if [ "$p" != none ] && [ -n "$p" ]; then set -- $p
    press "$1" "$2" 900 "empty space (edit mode)" && { sleep 1; chk edit
      step edit "a hold on empty space: edit mode"
      [ "$(isediting)" = true ] && pass "edit mode is on" || fail "a hold on empty space didn't enter edit mode"
      back 1; chk edit-off
      step edit-left "Back: edit mode left"
      [ "$(isediting)" = false ] && [ "$(layout)" = "$LAY0" ] && pass "edit mode is off, the layout as it was" || fail "after Back: editing=$(isediting), layout $(layout) (was $LAY0)"; }
  else fail "no empty spot on home to hold"; fi
}

case $PART in 1) part1 ;; 2) part2 ;; 3) part3 ;; *) echo "FAIL: no part $PART"; exit 2 ;; esac
e2e_finish
