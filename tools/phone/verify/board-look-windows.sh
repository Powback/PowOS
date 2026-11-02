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
#   split-pair    (multitasking-split-pairs-as-one-app-combined-ico, 9db906b9): Android's split of Calculator + Chrome by
#                 the bridge's tasks.split (the switcher's own call): the switcher shows ONE card for them, one combined
#                 icon holding both icons, stacked folded / side by side unfolded; neither app has its own card;
#   split-lr      (split-screen-side-by-side-left-right-on-the-unfo): unfolded only (SKIP with reason when folded - not
#                 forced open): the same split is left/right: WMShell mIsLeftRightSplit=true and the tasks side by side;
#   term-fill     (phone-terminal-sessions-fill-the-screen-tmux-siz, e47ff321): a PowOS terminal session opened view-only
#                 (a remote host's: capture-pane, no tmux client, nothing typed): the view fills the screen, the grid
#                 fills the view, no empty band at the top.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/e2e-lib.sh"
CASE=${1:-}; shift || true
case "$CASE" in tiled-bars|max-bar|switcher-linux|split-pair|split-lr|term-fill) ;;
  *) echo "usage: board-look-windows.sh tiled-bars|max-bar|switcher-linux|split-pair|split-lr|term-fill [--round R]"; exit 2 ;; esac
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
      c=$(pt "[...document.querySelectorAll('.recents .task')].find(c=>/Dolphin/.test(c.querySelector('.task-label')?.textContent||''))")
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
        cs="[...document.querySelectorAll('.recents .task')].find(c=>/Dolphin/.test(c.querySelector('.task-label')?.textContent||''))"
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

e2e_finish
