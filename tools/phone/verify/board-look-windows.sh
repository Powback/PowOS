#!/bin/bash
# lanes: phone
# board-look-windows.sh <case> [--round R]: on-device checks of board tasks about windows, the switcher and split screen
# (fixed in code, gate-proven in the page) - each a real use of the phone where the task is about touch, read-only CDP /
# dumpsys measures otherwise, plus the e2e step screenshots. e2e-lib's rules apply: idle gate, touch abort (exit 3),
# pill guard, everything the case opened closed on exit (Calculator/Chrome tasks it started, Dolphin if it started it),
# the page and layout as they were. Window setup (open / full screen / maximise) is done by code - the touches are
# what each task is about. Cases:
#   tiled-bars    (title-bar-buttons-work-on-tiled-windows, 1d715c7e): Calculator and Chrome full screen, split from the
#                 switcher (icon -> Split screen -> second card -> Split): both windowed with bars, tiled; a tap on
#                 Chrome's minimise puts only Chrome away, Calculator's full screen acts on Calculator, its close only it;
#   max-bar       (maximised-window-s-top-bar-takes-taps, f5d74bb9/7b512860): a maximised Calculator - its merged bar's
#                 title takes a tap (a page pointerdown on it), its minimise button minimises it, a drag on it moves it;
#   switcher-linux (switcher-shows-every-open-window-linux-too, 83159b3d/1e143c8d): maximised Dolphin has a switcher card;
#                 Dolphin full screen (by code), its card tapped -> back full screen; Home from the switcher
#                 -> it leaves full screen;
#   switcher-centre (switcher-opened-over-a-maximised-linux-window-ce): maximised Dolphin, the switcher opened over it
#                 (the overview key): Dolphin's card is the first one and the one in the middle of the screen (it had
#                 centred on Lights, 11-02);
#   split-pair    (multitasking-split-pairs-as-one-app-combined-ico, 9db906b9): Android's split of Calculator + Chrome by
#                 the bridge's tasks.split (the switcher's own call): the switcher shows ONE card for them, one combined
#                 icon holding both icons, stacked folded / side by side unfolded; neither app has its own card;
#   split-lr      (split-screen-side-by-side-left-right-on-the-unfo): unfolded only (SKIP with reason when folded - not
#                 forced open): the same split is left/right: WMShell mIsLeftRightSplit=true and the tasks side by side;
#   term-fill     (phone-terminal-sessions-fill-the-screen-tmux-siz, e47ff321): a PowOS terminal session opened view-only
#                 (a remote host's: capture-pane, no tmux client, nothing typed): the view fills the screen, the grid
#                 fills the view, no empty band at the top;
#   window-page   (a-floating-window-stays-on-its-own-page-when-you, E2E 206 #36): Calculator floating on the page shown,
#                 placed by code 40 px over its page's right edge (under the dock, as the journey left it); a real
#                 swipe beside it to the next page -> nothing of it shows (cut to its page: WWON) and the host's
#                 w.f has it hidden; swiped back -> shown where it was.
#   chrome-size   (chrome-window-renders-at-half-size-content-in-to, FS2): Chrome as a web window - its app's task fills
#                 the window's body (am stack list bounds == the body's size), maximised (by code) too; full screen (the
#                 bar's own host call) -> its task full screen on display 0 at the whole screen's size, never its old
#                 window's size top-left (11-02 21:45: 1154x1538 at 0,197 on 2268x2440, the rest black); back to a
#                 window -> it fills the body again.
#   relaunch      (launching-an-app-that-s-already-running-opens-it): Calculator as a web window, Home pressed, then
#                 Calculator launched again from home's search (a launch, not the dock's taskbar toggle) -> the SAME
#                 window fronts (not minimised, on top), no second window, no second Calculator task.
#   snap-fill     (open-a-window-while-one-is-side-docked-it-takes, asks 1a1a1004151/1a1a10147ea): Calculator as a web
#                 window docked to the left half the user's way - a real drag of its title bar to the screen's left
#                 edge -> it is a lone left half; then Chrome launched (state.launch, the dock/drawer/search path, by
#                 code) -> Chrome opens tiled in the right half: the page's tiling is 2h [Calculator, Chrome].
#   multi-instance (decide-support-multi-instance-windows-where-the + dragging-an-already-open-app-s-icon-out-breaks-t):
#                 Chrome as a web window on the page shown, Calculator's on the next page (so the dock is a taskbar
#                 there - a drop opens a window, never unpins); home turned to that page by code; Chrome's dock icon
#                 held and dragged to the page's middle (input motionevent) -> TWO Chrome windows, one per page, one
#                 more Chrome task (a second instance, not the first window moved).
#   calc-density  (calculator-mis-lays-out-at-certain-window-sizes, ask 1a1a369a6fa): Calculator as a web window (by
#                 code) at its default size, then resized smaller (by code): its activity's reported configuration is
#                 at the screen's density (WindowDpi.SCREEN_DENSITY_APPS: at 294 it sized its text by display 0's 442,
#                 "/ / /" digits and clipped keys) and its sw is the window's width at that density (+-2 dp), each
#                 size's screenshot for the readable digits.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/e2e-lib.sh"
CASE=${1:-}; shift || true
case "$CASE" in tiled-bars|max-bar|switcher-linux|switcher-centre|split-pair|split-lr|term-fill|window-page|chrome-size|relaunch|snap-fill|multi-instance|calc-density) ;;
  *) echo "usage: board-look-windows.sh tiled-bars|max-bar|switcher-linux|switcher-centre|split-pair|split-lr|term-fill|window-page|chrome-size|relaunch|snap-fill|multi-instance|calc-density [--round R]"; exit 2 ;; esac
e2e_args "$@"
e2e_init "lookw-$CASE"
CALC=${TEST_APP:-com.oneplus.calculator} CHROME=com.android.chrome
# The split cases' second app when Chrome is the user's (already has a task); closed on exit like Chrome.
SPLIT_ALT="com.oneplus.note com.oneplus.deskclock"; E2E_APPS="$E2E_APPS|${SPLIT_ALT// /|}"
# The split cases run in the fold the phone is in (split-lr SKIPs folded); the window cases need the unfolded home.
case $CASE in split-pair|split-lr) e2e_setup ;; *) e2e_setup inner ;; esac
# Closed on any exit, on top of e2e_restore: the session view, Linux full screen, the switcher.
OPENED_TERM=0
lookw_cleanup() {
  [ "$OPENED_TERM" = 1 ] && ev 'importShim("./state.ts").then(s=>{s.closeSession();return "ok"})' >/dev/null
  closesw; e2e_abort; closesw
}
# closesw: the switcher closed (Back) when the host says it is up - a case that stops mid-switcher leaves none.
closesw() { local i st; for i in 1 2; do st=$(ev 'importShim("./bridge.ts").then(b=>b.powos.recents.state()).then(s=>String(!!(s&&s.open)))')
  [ "$st" = true ] || return 0; back 1.5; done; }
trap lookw_cleanup EXIT

WW='importShim("./ui/webwindows.tsx")'
# appkey <pkg>: its drawer key ("a:<pkg>/<activity>") and label, "key|label" or "none".
appkey() { ev "importShim('./state.ts').then(s=>{const a=s.apps.value.find(a=>String(a.key).startsWith('a:$1/'));return a?a.key+'|'+a.label:'none'})"; }
# wwopen <pkg>: its web window opened by code on the page shown (setup, not the check); prints "w<id>" or "none".
wwopen() { local k; k=$(appkey "$1"); [ "$k" = none ] && { echo none; return; }
  ev "Promise.all([importShim('./state.ts'),$WW]).then(([s,w])=>w.openWindow('${k%%|*}','${k#*|}',s.pages.value[Math.max(0,s.page.value)])).then(i=>i==null?'none':'w'+i)"; }
# wwstate <w-id>: "open min full max tiled" flags of a web window (1/0), "gone" when it isn't listed.
wwstate() { ev "$WW.then(m=>{const w=m.webWins.value.find(v=>v.id===${1#w});if(!w)return 'gone';return [1,w.minimised?1:0,w.full?1:0,w.restore?1:0,m.tiledOn(w.id)!=null?1:0].join(' ')})"; }
hostfull() { ev "importShim('./bridge.ts').then(b=>b.powos.webwindows.fullScreen(${1#w})).then(String)"; }
hosttowin() { ev "importShim('./bridge.ts').then(b=>b.powos.webwindows.toWindow(${1#w})).then(String)"; }
# btn <w-id> <aria-label>: that title-bar button's centre, "x y" or "".
btn() { wwpt "$1" ".ww-button[aria-label=\"$2\"]"; }
tapat() { local p=$1; [[ $p =~ ^-?[0-9]+\ -?[0-9]+$ ]] || { log "no spot for $2 ($p)"; return 1; }; set -- $p "$2"; tap "$1" "$2" "$3"; }
switcher() { sh_ "input keyevent KEYCODE_APP_SWITCH"; sleep 2; chk switcher; }
# card <task id> <part selector>: that switcher card's part, "x y" / none / off.
card() { pt "document.querySelector('.recents .task[data-task=\"$1\"] $2')"; }
# inview <card element expr>: that switcher card scrolled into the middle of the row first (setup, not the check). The
# switcher opens on the app it was opened over and the rest sit off to the side: pt says "off" for a card that IS
# there (rounds 1102-2003/2005: Chrome's card and maximised Dolphin's both "off", present right of the view). Prints
# "ok"/"none".
inview() { ev "(()=>{const c=($1);if(!c)return 'none';c.scrollIntoView({inline:'center',block:'nearest'});return 'ok'})()"; sleep 1.2; }
wmshell() { local o; o=$(sh_ "dumpsys activity service com.android.systemui WMShell"); [ -n "$o" ] || o=$(sh_ "dumpsys activity service SystemUIService WMShell"); echo "$o"; }

# --- tiled-bars ------------------------------------------------------------------------------------------------
if [ "$CASE" = tiled-bars ]; then
  A1=$(wwopen "$CALC"); sleep 2; A2=$(wwopen "$CHROME"); sleep 3; chk open
  log "windows: Calculator $A1, Chrome $A2"
  if [ "$A1" = none ] || [ "$A2" = none ]; then fail "no web windows for Calculator ($A1) / Chrome ($A2) - web windows off?"
  else
    hostfull "$A1" >/dev/null; sleep 2; hostfull "$A2" >/dev/null; sleep 2.5; chk full
    step full "Calculator and Chrome both full screen (set by code)"
    note "full flags: Calculator $(wwstate "$A1"), Chrome $(wwstate "$A2") (open min full max tiled)"
    T1=$(wwhost "$A1" task); T2=$(wwhost "$A2" task)
    switcher
    # The switcher opens on the last app's card, centred; Calculator's card sits off to the side with its icon off
    # screen (round 1102-1924). Scrolled into the middle by code (setup: the task is the bars, not the scroll).
    ev "(()=>{const c=document.querySelector('.recents .task[data-task=\"$T1\"]');if(!c)return 'none';c.scrollIntoView({inline:'center',block:'nearest'});return 'ok'})()" >/dev/null; sleep 1.2
    step switcher "the switcher over them, Calculator's card in the middle"
    if tapat "$(card "$T1" .task-icon)" "Calculator's card icon (its menu)"; then sleep 1; chk menu
      tapat "$(pt "[...document.querySelectorAll('.recents-menu button')].find(b=>b.textContent.trim()==='Split screen')")" "Split screen" && sleep 1
      inview "document.querySelector('.recents .task[data-task=\"$T2\"]')" >/dev/null
      tapat "$(card "$T2" .task-shot)" "Chrome's card (the second pick)" && sleep 1
      step picked "Calculator and Chrome picked for the split"
      tapat "$(pt "document.querySelector('.recents-banner-go')")" "the banner's Split" || fail "no Split button after two picks"
      sleep 3; chk split
      step tiled "the split of the two full-screen apps"
      s1=$(wwstate "$A1"); s2=$(wwstate "$A2"); b1=$(wwbar "$A1"); b2=$(wwbar "$A2")
      [ "$s1" = "1 0 0 0 1" ] && [ "$s2" = "1 0 0 0 1" ] && [ "$b1" = true ] && [ "$b2" = true ] &&
        pass "both windowed and tiled with title bars (Calculator $s1 bar $b1, Chrome $s2 bar $b2)" ||
        fail "after the split: Calculator $s1 bar $b1, Chrome $s2 bar $b2 (want 1 0 0 0 1, bars true)"
      tapat "$(btn "$A2" Minimise)" "Chrome's minimise" && { sleep 1.5; chk minimise
        step min "Chrome's minimise tapped"; s1=$(wwstate "$A1"); s2=$(wwstate "$A2")
        [ "${s2:2:1}" = 1 ] && [ "${s1:2:1}" = 0 ] && pass "only Chrome minimised (Chrome $s2, Calculator $s1)" || fail "minimise on Chrome: Chrome $s2, Calculator $s1"; }
      tapat "$(btn "$A1" "Full screen")" "Calculator's full screen" && { sleep 2.5; chk max
        step max "Calculator's full screen tapped"; s1=$(wwstate "$A1"); s2=$(wwstate "$A2")
        { [ "${s1:4:1}" = 1 ] || [ "${s1:6:1}" = 1 ]; } && [ "${s2:4:1}" = 0 ] && pass "Calculator went full screen, Chrome didn't (Calculator $s1, Chrome $s2)" || fail "full screen on Calculator: Calculator $s1, Chrome $s2"
        [ "${s1:4:1}" = 1 ] && { hosttowin "$A1" >/dev/null; sleep 2; }; }
      tapat "$(btn "$A1" Close)" "Calculator's close" && { sleep 2.5; chk close
        step close "Calculator's close tapped"; s1=$(wwstate "$A1"); s2=$(wwstate "$A2")
        [ "$s1" = gone ] && [ "$s2" != gone ] && pass "only Calculator closed (Chrome $s2)" || fail "close on Calculator: Calculator $s1, Chrome $s2"; }
    else fail "no icon on Calculator's switcher card (task $T1)"; back 1; fi
  fi
fi

# --- max-bar ---------------------------------------------------------------------------------------------------
if [ "$CASE" = max-bar ]; then
  A1=$(wwopen "$CALC"); sleep 3; chk open
  if [ "$A1" = none ]; then fail "no web window for Calculator"
  else
    ev "$WW.then(m=>{m.toggleMaximise(${A1#w});return 'ok'})" >/dev/null; sleep 1.5; chk maximise
    step maximised "Calculator maximised (by code): its bar merged into the status bar"
    s=$(wwstate "$A1"); [ "${s:6:1}" = 1 ] && pass "maximised ($s)" || fail "not maximised ($s)"
    # A page listener on the bar: a touch that reaches it (not SystemUI's status bar) is seen. Removed after.
    ev "(()=>{const b=document.querySelector('.webwindow[data-wwid=\"${A1#w}\"] .webwindow-title');if(!b)return 'none';window.__mbHits=[];window.__mbOff=(e=>window.__mbHits.push(e.target.className||e.target.tagName));b.addEventListener('pointerdown',window.__mbOff,true);return 'ok'})()" >/dev/null
    tapat "$(wwpt "$A1" .ww-title-label)" "the maximised bar's title" || tapat "$(barpt "$A1")" "the maximised bar's title area"
    sleep 1; chk title; step title "the title on the maximised bar tapped"
    h=$(ev 'JSON.stringify(window.__mbHits||null)')
    [ -n "$h" ] && [ "$h" != "[]" ] && [ "$h" != null ] && pass "the title took the tap (page pointerdown: $h)" || fail "the tap on the title never reached the bar ($h): SystemUI's status bar took it"
    # From the title: a maximised bar's middle is the status bar's (its pull), barpt's quarter point lands there.
    b0=$(wwrect "$A1"); p=$(wwpt "$A1" .ww-title-label); [ -n "$p" ] || p=$(barpt "$A1")
    if [ -n "$p" ]; then set -- $p; x=$1; y=$2; dy=$(dp 160)
      mdown "$x" "$y" "the maximised bar (a drag)" && { mpath "$x" "$y" "$x" $((y + dy)) 8; sleep 0.3; mup "$x" $((y + dy)); }
      sleep 1.5; chk drag; step drag "the maximised bar dragged down ${dy} px"
      b1=$(wwrect "$A1"); s=$(wwstate "$A1")
      [ "$b1" != "$b0" ] && pass "the drag moved it: $b0 -> $b1 ($s)" || fail "the drag on the bar did nothing: $b0 -> $b1 ($s)"
      [ "${s:6:1}" = 1 ] || { ev "$WW.then(m=>{m.toggleMaximise(${A1#w});return 'ok'})" >/dev/null; sleep 1.5; }
    else fail "no bar to drag"; fi
    tapat "$(btn "$A1" Minimise)" "the maximised bar's minimise" && { sleep 1.5; chk minimise
      step min "the maximised bar's minimise tapped"; s=$(wwstate "$A1")
      [ "${s:2:1}" = 1 ] && pass "minimised by its merged bar's button ($s)" || fail "minimise on the maximised bar: $s"; }
    ev "(()=>{const b=document.querySelector('.webwindow[data-wwid=\"${A1#w}\"] .webwindow-title');b&&window.__mbOff&&b.removeEventListener('pointerdown',window.__mbOff,true);return 'ok'})()" >/dev/null
  fi
fi

# --- switcher-linux --------------------------------------------------------------------------------------------
if [ "$CASE" = switcher-linux ]; then
  if grep -qx dolphin <<<"$LIN0"; then note "Dolphin was already running (the user's): case skipped"
  else
    hcall apps.launch "['l:org.kde.dolphin']" "()=>'ok'" >/dev/null
    D=$(waitwin l:org.kde.dolphin 30); chk dolphin; sleep 2
    if [ "$D" = none ]; then fail "Dolphin's window didn't come"
    else
      ev "$WW.then(m=>{m.toggleMaximise(${D#w});return 'ok'})" >/dev/null; sleep 1.5
      switcher; step switcher-max "the switcher with Dolphin maximised"
      cs="[...document.querySelectorAll('.recents .task')].find(c=>/Dolphin/.test(c.querySelector('.task-label')?.textContent||''))"
      inview "$cs" >/dev/null
      c=$(pt "$cs")
      case $c in none|off|"") fail "no switcher card for the maximised Linux window ($c)" ;; *) pass "maximised Dolphin has its switcher card" ;; esac
      back 1.5
      ev "$WW.then(m=>{m.toggleMaximise(${D#w});return 'ok'})" >/dev/null; sleep 1
      # Full screen by code (the host's webwindows.fullScreen, as the other cases' setup): an injected Ctrl+Shift+F
      # goes to the focused window - home's page, not Dolphin's surface in it (round 1102-1927: "1 0 0 0 0").
      hostfull "$D" >/dev/null; sleep 2.5; chk full
      s=$(wwstate "$D"); step full "Dolphin full screen (set by code)"
      if [ "${s:4:1}" != 1 ]; then fail "Dolphin didn't go full screen ($s)"
      else
        switcher; step switcher-full "the switcher over full-screen Dolphin"
        inview "$cs" >/dev/null
        if tapat "$(pt "($cs)?.querySelector('.task-shot')")" "Dolphin's card"; then sleep 2.5; chk card
          step back-full "Dolphin's card tapped"; s=$(wwstate "$D")
          [ "${s:4:1}" = 1 ] && pass "Dolphin came back full screen ($s)" || fail "Dolphin came back NOT full screen ($s)"
          switcher; sh_ "input keyevent KEYCODE_HOME"; sleep 2.5; chk home
          step home "Home from the switcher"; s=$(wwstate "$D")
          [ "${s:4:1}" = 0 ] && pass "Home left full screen ($s)" || fail "after Home Dolphin is still full screen ($s)"
        else fail "no card for full-screen Dolphin"; back 1; fi
      fi
      [ "$(wwstate "$D" | cut -c5)" = 1 ] && { hosttowin "$D" >/dev/null; sleep 1.5; }
    fi
  fi
fi

# --- switcher-centre -------------------------------------------------------------------------------------------
if [ "$CASE" = switcher-centre ]; then
  if grep -qx dolphin <<<"$LIN0"; then note "Dolphin was already running (the user's): case skipped"
  else
    hcall apps.launch "['l:org.kde.dolphin']" "()=>'ok'" >/dev/null
    D=$(waitwin l:org.kde.dolphin 30); chk dolphin; sleep 2
    if [ "$D" = none ]; then fail "Dolphin's window didn't come"
    else
      ev "$WW.then(m=>{m.toggleMaximise(${D#w});return 'ok'})" >/dev/null; sleep 1.5
      s=$(wwstate "$D"); [ "${s:6:1}" = 1 ] || note "Dolphin not maximised after the toggle ($s)"
      switcher; step switcher "the switcher opened over maximised Dolphin"
      # No scroll: what the switcher opened on. The first card, and the card whose middle is nearest the screen's.
      c=$(ev "(()=>{const cs=[...document.querySelectorAll('.recents .task')];const lab=c=>c?.querySelector('.task-label')?.textContent||'?';const mid=cs.map(c=>[c,c.getBoundingClientRect()]).filter(([,b])=>b.width>0).sort((a,b)=>Math.abs(a[1].left+a[1].width/2-innerWidth/2)-Math.abs(b[1].left+b[1].width/2-innerWidth/2))[0];return lab(cs[0])+'|'+(mid?lab(mid[0]):'none')})()")
      log "switcher cards: first|centred = $c"
      case $c in Dolphin*\|Dolphin*) pass "Dolphin's card is first and centred ($c)" ;; *) fail "the switcher opened over maximised Dolphin centred on another card (first|centred: $c)" ;; esac
      back 1.5
      ev "$WW.then(m=>{const w=m.webWins.value.find(v=>v.id===${D#w});w&&w.restore&&m.toggleMaximise(w.id);return 'ok'})" >/dev/null; sleep 1
    fi
  fi
fi

# --- split-pair / split-lr: Android's split of Calculator + Chrome ---------------------------------------------
# startfull <pkg>: its launcher activity started as a full-screen task on the main display; prints the new task id.
startfull() { local c before id; c=$(sh_ "cmd package resolve-activity --brief -c android.intent.category.LAUNCHER $1" | tail -1)
  before=$(tasks); sh_ "am start -W --windowingMode 1 --display 0 -n $c >/dev/null"; sleep 2
  id=$(tasks | while read -r i p v; do grep -q "^$i " <<<"$before" || { grep -q "$1" <<<"$p" && echo "$i"; }; done | head -1)
  echo "${id:-none}"; }
if [ "$CASE" = split-lr ] && [ "$W" -le 2000 ]; then
  step folded "the phone is folded (${W}x${H})"
  note "SKIP: folded - left/right split is the unfolded screen's (not forced open); re-run unfolded"
elif [ "$CASE" = split-pair ] || [ "$CASE" = split-lr ]; then
  # The second app: Chrome unless it already has a task (the user's - am start only brings that one up, no new task,
  # and splitting it would move the user's window), else the first of Notes / Clock with none.
  SECOND=""; for p in $CHROME $SPLIT_ALT; do grep -q " $p/" <<<"$TASKS0" || { SECOND=$p; break; }; done
  [ "$SECOND" = "$CHROME" ] || note "Chrome has the user's task: split with ${SECOND:-nothing} instead"
  T1=$(startfull "$CALC"); T2=none; [ -n "$SECOND" ] && T2=$(startfull "$SECOND"); chk start
  log "tasks: Calculator $T1, ${SECOND:-second app} $T2"
  if [ "$T1" = none ] || [ "$T2" = none ]; then fail "no full-screen tasks for Calculator ($T1) / ${SECOND:-a second app with no task} ($T2)"
  else
    r=$(hcall tasks.split "[$T1,$T2]" "v=>String(v)"); sleep 3; chk split
    step split "Calculator + $SECOND split by Android (tasks.split $T1,$T2: $r)"
    b1=$(tbounds "$T1"); b2=$(tbounds "$T2"); log "bounds: $b1 / $b2"
    shl=$(wmshell | grep -m1 -oE "mIsLeftRightSplit=[a-z]+"); log "WMShell: ${shl:-no mIsLeftRightSplit line}"
    set -- $b1 $b2
    if [ $# -lt 8 ]; then fail "the split didn't come up (bounds '$b1' / '$b2', tasks.split $r)"
    else
      side=0; { [ "$3" -le $(($5 + 2)) ] || [ "$7" -le $(($1 + 2)) ]; } && side=1
      if [ "$CASE" = split-lr ]; then
        [ "$shl" = mIsLeftRightSplit=true ] && [ $side = 1 ] && pass "left/right: $shl, $b1 | $b2" || fail "unfolded split not left/right: ${shl:-no line}, $b1 / $b2"
      else
        switcher; step switcher "the switcher with the split pair"
        f=$(ev "(()=>{const cs=[...document.querySelectorAll('.recents .task')],s=cs.filter(c=>c.querySelector('.task-split'));if(s.length!==1)return JSON.stringify({splits:s.length,cards:cs.map(c=>c.dataset.task)});const c=s[0],g=c.querySelectorAll('.task-head .group-icon'),i=g[0]?[...g[0].querySelectorAll('.task-icon')].map(e=>e.getBoundingClientRect()):[];const own=['$T1','$T2'].filter(t=>cs.some(x=>x!==c&&x.dataset.task===t));return JSON.stringify({splits:1,groups:g.length,icons:i.length,own,beside:i.length===2?i[1].left>=i[0].right-0.5:null,below:i.length===2?i[1].top>=i[0].bottom-0.5:null})})()")
        log "card: $f"
        python3 - "$f" "$W" <<'PY' > "$OUT/pair.txt"
import json, sys
try: f = json.loads(sys.argv[1])
except Exception: print("FAIL no answer from the switcher: " + sys.argv[1][:200]); sys.exit()
wide = int(sys.argv[2]) > 2000
bad = []
if f.get("splits") != 1: bad.append(f"{f.get('splits')} split cards (cards {f.get('cards')})")
else:
    if f["groups"] != 1: bad.append(f"{f['groups']} combined icons on the card")
    if f["icons"] != 2: bad.append(f"the combined icon holds {f['icons']} icons")
    if f["own"]: bad.append(f"the split's apps also have their own cards: {f['own']}")
    want = "beside" if wide else "below"
    if f["icons"] == 2 and not f[want]: bad.append(f"the icons aren't {'side by side' if wide else 'stacked'} ({f})")
print(("FAIL " + "; ".join(bad)) if bad else f"PASS one card, one combined icon of 2, {'side by side' if wide else 'stacked'}")
PY
        r=$(cat "$OUT/pair.txt"); case $r in PASS*) pass "${r#PASS }" ;; *) fail "${r#FAIL }" ;; esac
        back 1
      fi
    fi
  fi
fi

# --- term-fill -------------------------------------------------------------------------------------------------
if [ "$CASE" = term-fill ]; then
  # A remote host's session: view-only there is capture-pane (no tmux client, nothing resized, nothing typed). A local
  # one would attach a (read-only) client to a live tmux session - not done.
  ev 'importShim("./bridge.ts").then(b=>{b.powos.ai.sessions();return "ok"})' >/dev/null; sleep 3
  s=$(ev 'importShim("./ui/terms.tsx").then(t=>{const l=t.localHost(),s=t.sessions.value.find(s=>s.host&&s.host!==l);if(!s)return "none "+t.sessions.value.length;window.__tfS=s;return s.host+":"+s.name})')
  log "session: $s"
  case $s in none*|ERR*|"") step none "no session to open"; note "SKIP: no remote-host session listed (${s:-?}) - a local one would attach a tmux client; not opened" ;; *)
    ev 'importShim("./ui/terms.tsx").then(t=>{t.openTerm(window.__tfS,null);return "ok"})' >/dev/null; OPENED_TERM=1; sleep 4; chk term
    step term "the terminal session $s, view-only"
    # Rows from the xterm itself (terminal.tsx's terminalFor, as the gate's terminal scenes read them): the WebGL
    # renderer (the default) draws to a canvas and has no .xterm-rows DOM; the first row starts at the screen's top.
    g=$(ev 'importShim("./ui/terminal.tsx").then(m=>{const S=window.__tfS,t=m.terminalFor("at-work:"+(S.host??"local")+":"+S.name),v=document.querySelector(".session-screen"),h=document.querySelector(".session-term .term-holder"),scr=h&&h.querySelector(".xterm-screen"),dom=h&&h.querySelector(".xterm-rows");if(!v||!scr||!(t||dom))return JSON.stringify({view:!!v,screen:!!scr,term:!!t});const r=v.getBoundingClientRect(),b=h.getBoundingClientRect(),n=t?t.rows:dom.children.length,cellH=scr.offsetHeight/n,first=(dom&&dom.firstElementChild||scr).getBoundingClientRect();return JSON.stringify({vw:Math.round(r.width),vh:Math.round(r.height),iw:innerWidth,ih:innerHeight,top:Math.round(r.top),rows:n,cellH:Math.round(cellH*10)/10,gridH:scr.offsetHeight,holdH:h.clientHeight,gap:Math.round(first.top-b.top),sw:scr.offsetWidth,hw:Math.round(b.width),renderer:m.rendererFor("at-work:"+(S.host??"local")+":"+S.name)})})')
    log "geometry: $g"
    python3 - "$g" <<'PY' > "$OUT/term.txt"
import json, sys
try: g = json.loads(sys.argv[1])
except Exception: print("FAIL no answer from the session view: " + sys.argv[1][:200]); sys.exit()
if "vw" not in g: print(f"FAIL no session view / terminal ({g})"); sys.exit()
bad = []
if g["vw"] < g["iw"] * 0.97 or g["vh"] < g["ih"] * 0.9: bad.append(f"the view is {g['vw']}x{g['vh']} of {g['iw']}x{g['ih']}")
if not (g["gridH"] <= g["holdH"] + 0.5 and g["gridH"] + g["cellH"] > g["holdH"]): bad.append(f"rows {g['rows']} x {g['cellH']} px don't fill {g['holdH']} px")
if g["sw"] < g["hw"] * 0.9: bad.append(f"the grid is {g['sw']} px of the view's {g['hw']}")
if g["gap"] >= g["cellH"]: bad.append(f"an empty band of {g['gap']} px over the first row")
print(("FAIL " + "; ".join(bad)) if bad else f"PASS fills the screen: view {g['vw']}x{g['vh']} of {g['iw']}x{g['ih']}, {g['rows']} rows fill {g['holdH']} px, top gap {g['gap']} px")
PY
    r=$(cat "$OUT/term.txt"); case $r in PASS*) pass "${r#PASS }" ;; *) fail "${r#FAIL }" ;; esac
    ev 'importShim("./state.ts").then(s=>{s.closeSession();return "ok"})' >/dev/null; OPENED_TERM=0; sleep 1 ;;
  esac
fi

# --- window-page -----------------------------------------------------------------------------------------------
# wfvis <w-id>: the host's view of it - "visible" in the window's w.f entry (webwindows.tsx entry: field 14), 1/0.
wfvis() { ev "$WW.then(m=>{const w=m.webWins.value.find(v=>v.id===${1#w});const e=w&&m.entry(w);return e?e.split(' ')[14]:'none'})"; }
if [ "$CASE" = window-page ]; then
  np=$(ev 'importShim("./state.ts").then(s=>String(s.pages.value.length))'); pg0=$(hpage)
  if [ "${np:-0}" -lt 2 ] 2>/dev/null || [ "$pg0" -ge $((np - 1)) ] 2>/dev/null; then note "home has $np page(s), on page $((pg0 + 1)): no next page to swipe to - case skipped"
  else
    A1=$(wwopen "$CALC"); sleep 3; chk open
    if [ "$A1" = none ]; then fail "no web window for Calculator"
    else
      # Setup by code: 40 px of it over its page's right edge (E2E 206: 553..2127 on a 2087 px page).
      ev "$WW.then(m=>{const e=document.querySelector('.webwindow[data-wwid=\"${A1#w}\"]'),p=e&&e.closest('.page');if(!p)return 'none';const w=m.webWins.value.find(v=>v.id===${A1#w}),s=w.scale||1;m.update(w.id,{x:p.getBoundingClientRect().width-w.w*s+40});return 'ok'})" >/dev/null; sleep 1.5; chk place
      step over-edge "Calculator floating, 40 px past its page's right edge"
      b0=$(tbounds "$A1"); [ "$(tvis "$A1")" = true ] && [ "$(wfvis "$A1")" = 1 ] && pass "shown at $b0 (w.f visible)" || fail "not shown before the swipe: at '$b0', w.f visible=$(wfvis "$A1")"
      d=$((W * 35 / 100)); p=$(freept "$b0" -1 "$d")
      if [ "$p" = none ] || [ -z "$p" ]; then fail "no empty spot beside the window to swipe from"
      else set -- $p; x=$1; y=$2; to=$((x - d)); [ $to -lt 20 ] && to=20
        swipe $x $y $to $y 250 "beside the window to the next page" && { sleep 1.5; chk page2
          step page2 "a swipe beside the window: the next page, the window stays on its own"
          v=$(tvis "$A1"); f=$(wfvis "$A1")
          [ "$(hpage)" = $((pg0 + 1)) ] && [ "$v" = false ] && [ "$f" = 0 ] && pass "page $((pg0 + 2)) shows, Calculator hidden with its page (w.f visible 0)" || fail "after the swipe: page $(hpage) (from $pg0), Calculator shows=$v, w.f visible=$f"
          p=$(freept "" 1 "$d"); set -- $p; x=$1; y=$2; to=$((x + d)); [ $to -gt $((W - 20)) ] && to=$((W - 20))
          swipe $x $y $to $y 250 "back to the window's page" && { sleep 1.5; chk page1
            step page1 "swiped back: the window's page, the window as it was"
            [ "$(hpage)" = "$pg0" ] && [ "$(tvis "$A1")" = true ] && [ "$(tbounds "$A1")" = "$b0" ] && pass "back on page $((pg0 + 1)), Calculator at $b0" || fail "back: page $(hpage), shows=$(tvis "$A1"), at $(tbounds "$A1") (was $b0)"; }; }
      fi
    fi
  fi
fi

# --- chrome-size -----------------------------------------------------------------------------------------------
# tsize <task>: its bounds' size from am stack list, "w h" px, or "".
tsize() { sh_ "am stack list" | grep -E "taskId=$1:" | head -1 | sed -nE 's/.*bounds=\[(-?[0-9]+),(-?[0-9]+)\]\[(-?[0-9]+),(-?[0-9]+)\].*/\1 \2 \3 \4/p' | awk '{print $3-$1, $4-$2}'; }
# tmode <task>: its windowing mode word from dumpsys (fullscreen, freeform, ...), or "".
tmode() { sh_ "dumpsys activity activities" | grep -m1 -E "Task\{[0-9a-f]+ #$1 " | grep -oE 'mode=[a-z-]+' | cut -d= -f2; }
# bsize <l t r b>: "w h". near <w h> <w h>: within 3 px each way.
bsize() { [ -n "$1" ] && { set -- $1; echo "$(($3 - $1)) $(($4 - $2))"; }; }
near() { set -- $1 $2; local a=$1 b=$2 c=$3 d=$4; [ -n "$a" ] && [ -n "$c" ] && [ $((a - c)) -le 3 ] && [ $((c - a)) -le 3 ] && [ $((b - d)) -le 3 ] && [ $((d - b)) -le 3 ]; }
# fills <w-id> <what>: its app's task size == its body's size.
fills() { local t b s; t=$(wwhost "$1" task); b=$(bsize "$(wwbody "$1")"); s=$(tsize "$t")
  near "$s" "$b" && pass "$2: Chrome's task $t is ${s/ /x}, its body ${b/ /x}" || fail "$2: Chrome's task $t is '${s/ /x}', its body '${b/ /x}' - the app doesn't fill its window"; }
if [ "$CASE" = chrome-size ]; then
  A1=$(wwopen "$CHROME"); sleep 4; chk open
  if [ "$A1" = none ]; then fail "no web window for Chrome"
  else
    step window "Chrome as a web window"; fills "$A1" "window"
    ev "$WW.then(m=>{m.toggleMaximise(${A1#w});return 'ok'})" >/dev/null; sleep 2.5; chk maximise
    step maximised "Chrome maximised (by code)"; fills "$A1" "maximised"
    ev "$WW.then(m=>{m.toggleMaximise(${A1#w});return 'ok'})" >/dev/null; sleep 1.5
    t=$(wwhost "$A1" task); hostfull "$A1" >/dev/null; sleep 3; chk full
    step full "Chrome full screen (the bar's host call): a full-screen app on display 0"
    scr=$(sh_ "wm size" | grep -oE '[0-9]+x[0-9]+' | tail -1); s=$(tsize "$t"); m=$(tmode "$t")
    if [ "$(wwhost "$A1" state)" != full ]; then fail "not full screen: state $(wwhost "$A1" state)"
    elif [ "$m" = fullscreen ] && { near "$s" "${scr/x/ }" || near "$s" "${scr#*x} ${scr%x*}"; }; then pass "task $t full screen at ${s/ /x} on a $scr screen"
    else fail "task $t is mode '$m' at '${s/ /x}' on a $scr screen - its old window's size, not the screen"; fi
    hosttowin "$A1" >/dev/null; sleep 3; chk towin
    step back "Chrome back in its window"; fills "$A1" "back in its window"
  fi
fi

# --- relaunch --------------------------------------------------------------------------------------------------
# wwof <key>: the page's windows of app [key] and whether the first is the top-most, "<n> <id> <top 1/0> <min 1/0>".
wwof() { ev "$WW.then(m=>{const l=m.webWins.value,mine=l.filter(w=>w.key==='$1'),w=mine[0];return w?[mine.length,'w'+w.id,l.at(-1)?.id===w.id?1:0,w.minimised?1:0].join(' '):'0'})"; }
ntasks() { tasks | awk -v p="$1" 'index($2,p)==1' | wc -l | tr -d ' '; }
if [ "$CASE" = relaunch ]; then
  K=$(appkey "$CALC"); A1=$(wwopen "$CALC"); sleep 3; chk open
  if [ "$A1" = none ] || [ "$K" = none ]; then fail "no web window for Calculator ($A1, key $K)"
  else
    KEY=${K%%|*}; LABEL=${K#*|}; n0=$(ntasks "$CALC")
    step window "Calculator as a web window ($A1, $n0 Calculator task(s))"
    sh_ "input keyevent KEYCODE_HOME"; sleep 2; chk home
    # RC1: the window is on home, so home is in front already and Home on its main page opens the switcher (by design,
    # home-repeat.sh); Home again closes it. Measured once its layer is down, not through it.
    if [ "$(ev "document.querySelector('.recents')?.classList.contains('shown')?'up':'no'")" = up ]; then
      log "Home on home opened the switcher: Home again"; sh_ "input keyevent KEYCODE_HOME"; sleep 0.5; fi
    [ "$(recentsdown)" = down ] || log "the switcher's layer is still up after ~3 s"
    step home "Home pressed"
    f=$(searchpt)
    case $f in none|off*|"") fail "no search on home ($f)" ;; *)
      set -- $f; tap "$1" "$2" "home's search"; sleep 1.2; chk search
      if [ "$(ev "$SEARCHED")" = yes ] && homefocused; then
        q=$(tr 'A-Z' 'a-z' <<<"${LABEL%% *}" | tr -cd 'a-z0-9'); sh_ "input text ${q:-calc}"; sleep 1.5; chk typed
        p=$(searchresult "$KEY")
        case $p in none|off|"") fail "no Calculator in the search results ($p)"; back; back ;; *)
          set -- $p; tap "$1" "$2" "Calculator in the results (launched again)"; sleep 3; chk relaunch
          step relaunch "Calculator launched again while its window is open"
          o=$(wwof "$KEY"); n1=$(ntasks "$CALC"); set -- $o
          [ "${1:-0}" = 1 ] && [ "${2:-}" = "$A1" ] && [ "${3:-}" = 1 ] && [ "${4:-}" = 0 ] && [ "$n1" = "$n0" ] &&
            pass "the same window $A1 fronts (top, not minimised), one window, $n1 Calculator task(s)" ||
            fail "after the relaunch: windows of it '$o' (want '1 $A1 1 0': count id top minimised), Calculator tasks $n1 (had $n0)" ;;
        esac
      else step search "home's search tapped"; fail "home's search didn't take the focus ($(ev "$SEARCHED"), $(ime))"; back; fi ;;
    esac
  fi
fi

# --- snap-fill -------------------------------------------------------------------------------------------------
# edgept <side>: the tile area's left/right edge middle (device px), where a bar let go snaps to that half.
edgept() { ev "$WW.then(m=>{const a=m.tileArea(),d=devicePixelRatio;return Math.round(('$1'==='left'?a.left+6:a.right-6)*d)+' '+Math.round((a.top+a.bottom)/2*d)})"; }
# wwhalf <w-id>: "e" a lone left half / tiled left, "w" right, "none" otherwise (the ⇄ hint's edge).
wwhalf() { ev "$WW.then(m=>{const w=m.webWins.value.find(v=>v.id===${1#w});return w?String(m.swapEdge(w)):'gone'})"; }
if [ "$CASE" = snap-fill ]; then
  KC=$(appkey "$CHROME")
  if [ "$(ev "$WW.then(m=>String(m.webWins.value.some(w=>w.key.startsWith('a:$CHROME/'))))")" = true ]; then
    note "SKIP: Chrome already has a web window (the user's) - a launch would front it, not open a new one"
  elif [ "$KC" = none ]; then fail "no Chrome in the drawer"
  else
    A1=$(wwopen "$CALC"); sleep 3; chk open
    if [ "$A1" = none ]; then fail "no web window for Calculator ($A1)"
    else
      step window "Calculator as a web window ($A1)"
      b=$(barpt "$A1"); e=$(edgept left)
      if [[ ! $b =~ ^[0-9]+\ [0-9]+$ ]] || [[ ! $e =~ ^[0-9]+\ [0-9]+$ ]]; then fail "no bar ($b) / edge ($e) to drag"
      else
        set -- $b $e; swipe "$1" "$2" "$3" "$4" 900 "Calculator's title bar to the left edge"; sleep 1.5; chk docked
        h=$(wwhalf "$A1"); step docked "Calculator's bar dragged to the left edge (half: $h)"
        if [ "$h" != e ]; then fail "Calculator's bar let go at the left edge is not docked to the left half ($h, state $(wwstate "$A1"))"
        else
          ev "importShim('./state.ts').then(s=>s.launch('${KC%%|*}')).then(()=>'ok')" >/dev/null; sleep 4; chk chrome
          step chrome "Chrome launched with Calculator docked left"
          t=$(ev "Promise.all([importShim('./state.ts'),$WW]).then(([s,m])=>{const p=s.pages.value[Math.max(0,s.page.value)],t=m.tilings.value[p],c=m.webWins.value.find(w=>w.key.startsWith('a:$CHROME/'));return (t?t.layout+' '+t.ids.join(','):'none')+' | '+(c?c.id:'nochrome')})")
          set -- $t
          [ "${1:-}" = 2h ] && [ "${2:-}" = "${A1#w},${4:-x}" ] && pass "Chrome opened tiled in the right half beside Calculator ($t)" ||
            fail "Chrome opened with Calculator docked left: tiling '$t' (want '2h ${A1#w},<chrome> | <chrome>')"
        fi
      fi
    fi
  fi
fi

# --- multi-instance -------------------------------------------------------------------------------------------
# wwpages <key>: the pages of app [key]'s windows, sorted, comma separated.
wwpages() { ev "$WW.then(m=>m.webWins.value.filter(w=>w.key==='$1').map(w=>w.page).sort().join(','))"; }
if [ "$CASE" = multi-instance ]; then
  K=$(appkey "$CHROME"); A1=$(wwopen "$CHROME"); sleep 3; chk open
  P1=$(ev 'importShim("./state.ts").then(s=>String(s.pages.value[s.page.value]))')
  ok=$(ev 'importShim("./state.ts").then(s=>{if(s.page.value+1>=s.pages.value.length)return "no";s.page.value+=1;return "yes"})'); sleep 1.5
  A2=$(wwopen "$CALC"); sleep 3; chk page2
  if [ "$A1" = none ] || [ "$K" = none ] || [ "$ok" != yes ] || [ "$A2" = none ]; then fail "setup: Chrome window $A1 (key $K), next page $ok, Calculator window $A2"
  else
    KEY=${K%%|*}; n0=$(ntasks "$CHROME")
    step setup "Chrome's window $A1 on page $P1, Calculator's $A2 on the next page ($n0 Chrome task(s))"
    d=$(pt "$(dockel "$KEY")")
    case $d in none|off|"") fail "Chrome isn't on the dock ($d)" ;; *)
      set -- $d; X=$1; Y=$2; MX=$(ev 'String(Math.round(innerWidth*devicePixelRatio/2))'); MY=$(ev 'String(Math.round(innerHeight*devicePixelRatio/2))')
      c="input motionevent DOWN $X $Y; sleep 0.9; "; for i in 1 2 3 4 5 6 7 8; do c+="input motionevent MOVE $((X + (MX - X) * i / 8)) $((Y + (MY - Y) * i / 8)); "; done
      log "drag Chrome's dock icon $X,$Y -> $MX,$MY (held 0.9 s)"; sh_ "$c sleep 0.5; input motionevent UP $MX $MY"; sleep 4; chk dragged
      step drag "Chrome's dock icon dragged out onto this page"
      pg=$(wwpages "$KEY"); n1=$(ntasks "$CHROME"); P2=$(ev 'importShim("./state.ts").then(s=>String(s.pages.value[s.page.value]))')
      want=$(printf '%s\n%s\n' "$P1" "$P2" | sort | paste -sd, -)
      [ "$pg" = "$want" ] && [ "$n1" -gt "$n0" ] && pass "two Chrome windows (pages $pg), $n1 Chrome tasks (had $n0): a second instance" ||
        fail "after the drag-out: Chrome windows on pages '$pg' (want '$want'), Chrome tasks $n1 (had $n0)" ;;
    esac
  fi
fi

# --- calc-density ----------------------------------------------------------------------------------------------
# calccfg: Calculator's activity's last reported configuration, "<dpi> <sw dp> <w dp>" or "none".
calccfg() { sh_ "dumpsys activity activities" | awk -v p="$CALC/" 'index($0,"ActivityRecord{") && index($0,p){f=1}
  f && /mLastReportedConfiguration/ {match($0,/ [0-9]+dpi/); dpi=substr($0,RSTART+1,RLENGTH-4)
    match($0,/ sw[0-9]+dp/); sw=substr($0,RSTART+3,RLENGTH-5); match($0,/ w[0-9]+dp/); w=substr($0,RSTART+2,RLENGTH-4)
    print dpi, sw, w; exit}' | grep . || echo none; }
# calcfits <what>: PASS when Calculator's configuration is the screen's density and its width the window display's.
calcfits() { local c scr px; c=$(calccfg); scr=$(sh_ "wm density" | grep -oE '[0-9]+' | tail -1)
  px=$(wwbody "$A1"); [ -n "$px" ] && { set -- $px; px=$(( $3 - $1 )); }; set -- $c
  if [ "$c" = none ]; then fail "$what: no Calculator activity configuration in dumpsys"; return; fi
  if [ "$1" != "$scr" ]; then fail "$what: Calculator at ${1}dpi, the screen's is ${scr}dpi (sw${2}dp w${3}dp) - mixed density, garbled text"
  elif [ -n "$px" ] && [ $(( ${3} - px * 160 / scr )) -gt 2 -o $(( px * 160 / scr - ${3} )) -gt 2 ]; then
    fail "$what: Calculator w${3}dp, its window display is ${px}px = $((px * 160 / scr))dp at ${scr}dpi"
  else pass "$what: Calculator at the screen's ${1}dpi, sw${2}dp w${3}dp (display ${px:-?}px)"; fi; }
if [ "$CASE" = calc-density ]; then
  A1=$(wwopen "$CALC"); sleep 4; chk open
  if [ "$A1" = none ]; then fail "no web window for Calculator"
  else
    step window "Calculator as a web window at its default size"; what="default size" calcfits
    r=$(ev "$WW.then(m=>{const w=m.webWins.value.find(v=>v.id===${A1#w});if(!w)return 'none';const k=w.scale??1;m.placeWindow(w.id,{x:120,y:160,w:Math.round(w.w*k*0.75),h:Math.round(w.h*k*0.8)});return 'ok'})")
    sleep 3; chk resized
    if [ "$r" = ok ]; then step small "Calculator's window resized smaller (by code)"; what="smaller" calcfits
    else fail "Calculator's window $A1 not resized ($r)"; fi
  fi
fi

e2e_finish
