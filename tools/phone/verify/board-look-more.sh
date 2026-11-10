#!/bin/bash
# lanes: phone
# board-look-more.sh <case> [--round R]: more on-device checks of board tasks fixed in code, one case per task, each
# proving its line in the device-checks list (board-look.sh's structure, its own file: e2e-lib setup/restore, touch
# abort (exit 3), pill guard, one e2e step screenshot per look). Input only through e2e-lib (tap/swipe/mdown/mpath/mup);
# what a case changes (a setting, an open surface, a stubbed bridge call, an app it started) is saved first and put back
# in the EXIT trap, also on an abort. Never a game, never a key into a terminal, no fake notifications. Cases:
#   assist-circle   (assist-overlay-the-circle-drawing-clears-after-y, 6aefb2ff): the side-button overlay shown by
#                   `su -c cmd voiceinteraction show` (no power button), a circle drawn with an injected finger above its
#                   panel -> the stroke and the "circled" chip; a question put in its field and sent -> the circle, chip
#                   and cut-out thumbnail clear and the question carried the circled part. The send is caught in the
#                   overlay page (ai.send stubbed, put back): nothing reaches the user's real conversation, so "the answer
#                   used it" is proven as "the question carried it";
#   ai-overlay-dock (ai-overlay-launcher-s-ai-page-no-dock-showing-fu, f6746074): the launcher's AI page opened by code
#                   (openPanel("ai")), the side button's overlay summoned over it: no dock (.dock/.dock-tray) visible on
#                   home's page or in the overlay; the AI page's one bar spans its column;
#   search-setting  (settings-search-as-bar-or-dock-button-folded-unf, 793865e6): Settings > style, unfolded then
#                   folded: this screen's "unfolded search" / "folded search" picked "dock button" and "bar" with real
#                   taps -> home's search follows at once (the dock's button and no bar, or the bar and no button), the
#                   other screen's spot untouched; both spots put back. A pick that would drop the grid's search widget
#                   (docked on both screens) is left out (NOTE);
#   cc-quick-pages  (control-center-add-quick-page-list-real-settings, 793865e6): the control center pulled down, edit
#                   mode by state: the "add quick page" row lists this device's own settings pages (quickpage.pages,
#                   needs the APK with QuickPageCatalog) - the same set minus the ones already on the row, each with its
#                   own picture (an img / one-colour mask), not one shared gear. Read only: nothing added;
#   rec-light       (recording-light-a-ring-around-the-camera-when-th, eee8f5a0): the camera app started (am start
#                   STILL_IMAGE_CAMERA) -> a green ring (data-kind camera) on the camera cutout in the status chrome,
#                   unfolded (inner) then folded (cover); the camera's task closed -> the ring gone. Then the mic: the
#                   system's speech input (RECOGNIZE_SPEECH, another app) opened -> an orange ring (data-kind mic) while
#                   Android has its RECORD_AUDIO running, folded then unfolded; closed -> off once the mic rests;
#   term-remote     (native-terminals-rebuilt-on-powterm-s-code-fit-w, 179a9012 + 050a553d): a REMOTE host's session
#                   opened view-only (never a local tmux session, never taken over; every write to it dropped and
#                   counted): the WebGL renderer, a monospace face, an injected 4-row drag scrolls its scrollback 4 rows
#                   and writes nothing;
#   health-page     (health-opening-it-asks-for-health-connect-access, 5dd8cc66): Health Connect's link read
#                   (health.status, no prompt); linked -> the Health app's page opened by code (no widget needed) shows
#                   today's figures or its calm empty line, no grant note; not linked -> NOTE (opening would put the
#                   system's grant dialog up: the user's to answer).
#   needs-me        (what-needs-me-discord-whatsapp-gmail-in-one-widg, v2 history): read only - the What needs me widget
#                   on home (found by its own .nm-title; none placed: its page opened by code instead, closed after)
#                   renders rows (live or kept past ones, each whole inside the tile, a replied one marked) or its calm
#                   empty line ("Nothing needs you" / the notification-access note) - never a blank tile or raw marks.
#                   Nothing tapped, sent, marked read or dismissed.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/e2e-lib.sh"
CASES="assist-circle ai-overlay-dock search-setting cc-quick-pages rec-light term-remote health-page needs-me"
CASE=${1:-}; shift || true
case " $CASES " in *" $CASE "*) [ -n "$CASE" ] ;; *) false ;; esac || { echo "usage: board-look-more.sh ${CASES// /|} [--round R]"; exit 2; }
[ "${POWOS_DEVICE:-phone}" = emu ] && [ "$CASE" != health-page ] && [ "$CASE" != needs-me ] && { echo "SKIP: $CASE needs the phone (side button overlay, fold states, camera, hosts)"; exit 3; }
e2e_args "$@"
e2e_init "look-more-$CASE"
if [ "${POWOS_DEVICE:-phone}" = emu ]; then e2e_setup; else e2e_setup inner; fi

# --- this file's helpers -------------------------------------------------------------------------------------------
verdict() { case $1 in PASS*) pass "${1#PASS }" ;; FAIL*) fail "${1#FAIL }" ;; NOTE*) note "${1#NOTE }" ;; *) fail "no answer from the page: ${1:0:200}" ;; esac; }
sev() { ev "$1" shade; }
aev() { ev "$1" assist; }
shown() { sev 'String(!!document.querySelector(".notif-panel.shown"))'; }
pullbar() { swipe $((W * $1 / 100)) 6 $((W * $1 / 100)) $((H / 2)) 280 "$2" || return 1; sleep 1.4; chk "$2"; }
shut() { [ "$(shown)" = true ] && { back 1.2; [ "$(shown)" = true ] && { sh_ "cmd statusbar collapse"; sleep 1; }; }; true; }
spt() { local o ox=0 oy=0; o=$(wframe "PowOS shade"); [ -n "$o" ] && { set -- "$1" $o; ox=$2; oy=$3; }
  ev "(()=>{const e=($1);if(!e)return 'none';const r=e.getBoundingClientRect(),d=devicePixelRatio;if(r.width<2||r.height<2)return 'off';return Math.round((r.x+r.width/2)*d+$ox)+' '+Math.round((r.y+r.height/2)*d+$oy)})()" shade; }
avis() { aev 'document.visibilityState'; }
ashow() { sh_ "cmd voiceinteraction show" >/dev/null; sleep 2.2; chk "the side button overlay"; }
ahide() { sh_ "cmd voiceinteraction hide" >/dev/null; sleep 1; }
# setfold <cover|inner>: the fold state forced (e2e_restore resets it), W H DENS read again.
setfold() {
  local s=3 t=0 WH; [ "$1" = cover ] && s=0
  FORCED=1; device_state_set "$s"; sleep 2.5; chk "fold $1"
  while :; do WH=$(sh_ "wm size" | sed -nE 's/.*(Override|Physical) size: ([0-9]+)x([0-9]+).*/\2 \3/p' | tail -1); W=${WH% *}; H=${WH#* }
    { [ "$1" = cover ] && [ "${W:-9999}" -lt 2000 ]; } || { [ "$1" = inner ] && [ "${W:-0}" -gt 2000 ]; } && break
    t=$((t + 1)); [ $t -gt 12 ] && { fail "the $1 screen didn't come on ($WH)"; return 1; }; sleep 1; done
  DENS=$(sh_ "wm density" | grep -oE '[0-9]+' | tail -1)
  sh_ "am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null"; sleep 1.5; chk "home $1"
  log "$1: ${W}x${H} @${DENS}"
}

# What a case changed, put back (idempotent; the EXIT trap runs it before e2e-lib's own restore).
AOPEN=; ASTUB=; LAI=; SS0=; SCR=; CCED=; CAMT0=; CAMON=; TERMID=; HOPEN=; NOPEN=
more_restore() {
  [ -n "$ASTUB" ] && { aev 'importShim("./bridge.ts").then(B=>{if(window.__dcSend){B.powos.ai.send=window.__dcSend;delete window.__dcSend}return "ok"})' >/dev/null; ASTUB=; log "ai.send put back in the overlay"; }
  [ -n "$AOPEN" ] && { ahide; AOPEN=; log "side button overlay hidden"; }
  [ -n "$LAI" ] && { ev 'importShim("./state.ts").then(s=>{s.drawer.value=0;return "ok"})' >/dev/null; sh_ "input keyevent 111" >/dev/null; LAI=; log "launcher AI page closed"; }
  [ -n "$SCR" ] && { ev 'importShim("./screens.ts").then(Sc=>{Sc.screens.value=[];return "ok"})' >/dev/null; SCR=; log "Settings closed"; }
  [ -n "$SS0" ] && { local m=${SS0%|*} u=${SS0#*|}
    ev "importShim('./state.ts').then(S=>{S.searchSpot.mobile.value='$m';S.searchSpot.unfolded.value='$u';return S.searchSpot.mobile.value+'|'+S.searchSpot.unfolded.value})" >/dev/null
    log "search spots back to folded $m, unfolded $u"; SS0=; }
  [ -n "$CCED" ] && { sev "importShim('./ui/ccexpand.ts').then(X=>{X.ccEditing.value=false;return 'ok'})" >/dev/null; shut; CCED=; log "CC edit mode left, shade shut"; }
  [ -n "$CAMON" ] && { camclose; CAMON=; }
  [ -n "$TERMID" ] && { ev 'Promise.all([importShim("./state.ts"),importShim("./bridge.ts")]).then(([S,B])=>{S.closeSession();if(window.__dcWrite){B.powos.term.write=window.__dcWrite;delete window.__dcWrite}return "ok"})' >/dev/null; TERMID=; log "terminal view closed, term.write put back"; }
  [ -n "$NOPEN" ] && { ev 'importShim("./apps/pages.ts").then(P=>{P.closeApp();return "ok"})' >/dev/null; NOPEN=; log "What needs me page closed"; }
  [ -n "$HOPEN" ] && { ev 'importShim("./apps/pages.ts").then(P=>{P.closeApp();return "ok"})' >/dev/null; HOPEN=; log "Health page closed"; }
  return 0
}
trap 'rc=$?; more_restore; (exit $rc); e2e_abort' EXIT

# --- assist-circle --------------------------------------------------------------------------------------------------
LINE='(()=>(document.querySelector(".crop-stroke polyline")?.getAttribute("points")??"").split(" ").filter(Boolean).length)()'
CHIP='String(/circled/.test(document.querySelector(".assist-attach")?.textContent??""))'
if [ "$CASE" = assist-circle ]; then
  AOPEN=1; ashow
  v=$(avis); log "overlay page: $v"
  if [ "$v" != visible ]; then step overlay "the side button overlay summoned by cmd voiceinteraction show"; fail "the overlay didn't show (page: $v)"
  else
    p=$(aev '(()=>{const p=document.querySelector(".assist-panel"),d=devicePixelRatio;if(!p)return "none";const r=p.getBoundingClientRect();return Math.round(r.top*d)+" "+Math.round(innerWidth*d)})()'); log "panel top / width (device px): $p"
    set -- $p
    if [ "$1" = none ] || [ "${1:-0}" -lt 400 ] 2>/dev/null; then step overlay "the side button overlay"; fail "no room above the overlay's panel to circle ($p)"
    else
      top=$1; cx=$(($2 / 2)); r=$((top / 4)); [ $r -gt $(($2 / 5)) ] && r=$(($2 / 5)); cy=$((top / 2 + top / 10))
      # A finger's circle: down at the top of the ring, round it in 28 moves (one adb call), up where it began.
      pts=$(awk -v cx=$cx -v cy=$cy -v r=$r 'BEGIN{for(i=1;i<=28;i++){a=i/28*6.2832; printf "%d %d\n", cx+r*sin(a), cy-r*cos(a)}}')
      if mdown "$cx" $((cy - r)) "the circle's start"; then
        c=""; while read -r x y; do c="$c input motionevent MOVE $x $y;"; done <<<"$pts"; sh_ "$c"
        mup "$cx" $((cy - r)); log "circle drawn: centre $cx,$cy r $r"
      fi
      sleep 1.2; chk circle
      step circled "a circle drawn above the overlay's panel with the finger"
      n=$(aev "$LINE"); ch=$(aev "$CHIP"); log "stroke points $n, circled chip $ch"
      [ "${n:-0}" -gt 3 ] 2>/dev/null && [ "$ch" = true ] && pass "the circle drawn ($n points) and the 'circled' chip up" || fail "after the circle: $n stroke points, circled chip $ch"
      busy=$(aev 'importShim("./state.ts").then(S=>{const c=S.chat.peek();return String(!!c.busy&&!Array.isArray(c.queued))})')
      if [ "$busy" = true ]; then note "the manager is mid-turn on a host without a queue: a send would wait in the page's queue and reach the real chat later - not sent"
      else
        ASTUB=1
        aev 'importShim("./bridge.ts").then(B=>{window.__dcSent=[];if(!window.__dcSend)window.__dcSend=B.powos.ai.send;B.powos.ai.send=(t)=>(window.__dcSent.push(String(t)),Promise.resolve());return "ok"})' >/dev/null
        aev '(()=>{const f=document.querySelector("form.assist-ask textarea");if(!f)return "none";f.value="what is this?";f.dispatchEvent(new Event("input",{bubbles:true}));document.querySelector(".assist-ask").dispatchEvent(new Event("submit",{bubbles:true,cancelable:true}));return "ok"})()' >/dev/null
        sleep 4; chk sent
        step sent "a question sent from the overlay (caught before the real chat)"
        r=$(aev "(()=>{const s=window.__dcSent||[],n=$LINE,ch=$CHIP==='true',crop=!!document.querySelector('.assist-shot.crop'),bad=[];
if(!s.length)return 'FAIL nothing reached ai.send in 4 s';
if(!/the part of the screen I circled/.test(s[0]))bad.push('the question went without the circled part');
if(n)bad.push('the circle still drawn ('+n+' points)');if(ch)bad.push('the circled chip still there');if(crop)bad.push('the head still shows the cut-out');
return (bad.length?'FAIL '+bad.join('; '):'PASS circle, chip and cut-out cleared; the question carried the circled part')+' | sent '+s[0].length+' chars'})()")
        log "after send: $r"; verdict "$r"
      fi
    fi
  fi
  more_restore
fi

# --- ai-overlay-dock ------------------------------------------------------------------------------------------------
DOCKS='(()=>[...document.querySelectorAll(".dock, .dock-tray")].filter(d=>{const b=d.getBoundingClientRect(),c=getComputedStyle(d);return b.width>0&&b.height>0&&b.bottom>0&&b.top<innerHeight&&b.right>0&&b.left<innerWidth&&c.visibility!=="hidden"&&+c.opacity>0}).map(d=>String(d.className).trim()).join(", ")||"none")()'
if [ "$CASE" = ai-overlay-dock ]; then
  LAI=1; ev 'importShim("./state.ts").then(s=>{s.openPanel("ai");return "ok"})' >/dev/null; sleep 1.6; chk "launcher AI page"
  k=$(ev 'importShim("./state.ts").then(s=>s.pullKind.value+" drawer="+s.drawer.value)'); log "launcher: $k"
  step ai-launcher "the launcher's AI page opened by code"
  AOPEN=1; ashow
  step overlay "the side button over the launcher's AI page"
  d1=$(ev "$DOCKS"); av=$(avis); d2=none; [ "$av" = visible ] && d2=$(aev "$DOCKS")
  bar=$(ev '(()=>{const b=document.querySelector(".bar[data-role=ai] .pill")||document.querySelector(".bar[data-role=ai]");if(!b)return "none";const r=b.getBoundingClientRect(),c=b.closest(".ai-right, .drawer-page, .launcher-frame, .home");const w=c?c.getBoundingClientRect().width:innerWidth;return Math.round(r.width)+" of "+Math.round(w)})()')
  log "home page docks: $d1 | overlay ($av) docks: $d2 | AI bar: $bar"
  bad=""; [ "$d1" = none ] || bad="$bad; home's page shows a dock ($d1)"; [ "$d2" = none ] || bad="$bad; the overlay shows a dock ($d2)"
  case $k in ai*) ;; *) bad="$bad; the launcher's AI page wasn't up ($k)" ;; esac
  [ -z "$bad" ] && pass "no dock showing (home page, overlay $av); AI bar $bar" || fail "${bad#; } | AI bar $bar"
  more_restore
fi

# --- search-setting -------------------------------------------------------------------------------------------------
SPOTS='importShim("./state.ts").then(S=>S.searchSpot.mobile.value+"|"+S.searchSpot.unfolded.value)'
HOMESEARCH='(()=>{const v=e=>{if(!e)return false;const b=e.getBoundingClientRect();return b.width>2&&b.height>2&&getComputedStyle(e).visibility!=="hidden"};return "dock="+v(document.querySelector(".home > .dock .dock-search, .home .dock .app.dock-search"))+" bar="+v(document.querySelector(".home > .bar"))})()'
segpt() { pt "(e=>(e&&e.scrollIntoView({block:'center'}),e))([...document.querySelectorAll('[data-setting=\"$1\"] .scr-seg button')].find(b=>b.textContent.trim()==='$2'))"; }
if [ "$CASE" = search-setting ]; then
  s0=$(ev "$SPOTS"); log "search spots at the start (folded|unfolded): $s0"
  case $s0 in dock\|*|bar\|*) SS0=$s0 ;; *) fail "the search spots couldn't be read ($s0) - nothing changed"; e2e_finish; exit 0 ;; esac
  widget=$(hcall home.get "[]" "h=>String(h.items.some(i=>i.key==='panel:search'))"); log "the grid's search widget on home: $widget"
  for fold in inner cover; do
    [ $fold = cover ] && { setfold cover || break; }
    mode=unfolded; label="unfolded search"; [ $fold = cover ] && { mode=mobile; label="folded search"; }
    cur=$(ev "importShim('./state.ts').then(S=>S.searchSpot.$mode.value)")
    # The other choice first, then back to the one found (the trap puts the stored values back regardless).
    opts=("dock button" "bar"); [ "$cur" = dock ] && opts=("bar" "dock button")
    for opt in "${opts[@]}"; do want=bar; [ "$opt" = "dock button" ] && want=dock
      now=$(ev "$SPOTS"); other=${now#*|}; [ $mode = unfolded ] && other=${now%|*}
      if [ "$want" = dock ] && [ "$other" = dock ] && [ "$widget" = true ]; then note "$label -> dock button left out: docked on both screens drops the grid's search widget (layout change)"; continue; fi
      SCR=1; ev 'importShim("./screens.ts").then(Sc=>{Sc.screens.value=["settings","style"];return "ok"})' >/dev/null; sleep 1.5; chk settings
      p=$(segpt "$label" "$opt"); sleep 0.6; p=$(segpt "$label" "$opt")
      case $p in none|off|"") step "pick-$fold" "Settings > style: $label"; fail "no '$opt' on '$label' ($p) - not shipped?"; break ;; esac
      set -- $p
      # Where the tap goes (11-02 FAIL: taps changed nothing, no 'search placement' log): the DOM hit at the point and
      # whether any pointer event reached the page, so a native surface over home tells apart from a dead button.
      hit=$(ev "(()=>{const d=devicePixelRatio,e=document.elementFromPoint($1/d,$2/d);window.__ssHits=0;if(!window.__ssHook){window.__ssHook=1;document.addEventListener('pointerdown',()=>window.__ssHits++,true)}return e?(e.tagName+'.'+String(e.className).slice(0,40)+' '+(e.textContent||'').trim().slice(0,20)):'nothing'})()")
      log "hit at $1,$2: $hit"
      # 11-02 FAIL (cover-bar): the hit was IMG.task-shot - the switcher layer was up over Settings after the fold, the
      # tap opened the user's Chrome task, and the next step's tap went to Chrome (a false PASS). The switcher put away
      # (logged: a fold that leaves it up is worth seeing) and never a tap that isn't on the choice's button.
      case $hit in BUTTON*) ;; *)
        sw=$(ev 'importShim("./ui/recents.tsx").then(R=>{const o=!!document.querySelector(".recents.open");R.recentsHome();return String(o)})')
        note "$label: '$hit' over the '$opt' button (switcher open: $sw) - switcher put away, tap point read again"; sleep 1.2
        p=$(segpt "$label" "$opt"); set -- $p
        hit=$(ev "(()=>{const d=devicePixelRatio,e=document.elementFromPoint($1/d,$2/d);window.__ssHits=0;return e?(e.tagName+'.'+String(e.className).slice(0,40)+' '+(e.textContent||'').trim().slice(0,20)):'nothing'})()")
        log "hit at $1,$2 after: $hit" ;; esac
      case $hit in BUTTON*) ;; *) step "$fold-$want" "$fold: Settings > style > $label = $opt"; fail "$fold: '$hit' covers the '$opt' button at $1,$2 - not tapped"
        ev 'importShim("./screens.ts").then(Sc=>{Sc.screens.value=[];return "ok"})' >/dev/null; SCR=; continue ;; esac
      top=$(sh_ "dumpsys activity activities | grep -m1 topResumedActivity" | grep -oE '[a-zA-Z0-9_.]+/[a-zA-Z0-9_.]+' | head -1)
      case $top in com.powos.app/*) ;; *) step "$fold-$want" "$fold: Settings > style > $label = $opt"; fail "$fold: $top is on top, not PowOS's home - not tapped"
        ev 'importShim("./screens.ts").then(Sc=>{Sc.screens.value=[];return "ok"})' >/dev/null; SCR=; continue ;; esac
      tap "$1" "$2" "$label: $opt"; sleep 0.8; chk pick
      log "pointerdowns that reached home's page: $(ev 'String(window.__ssHits)')"
      "$T/shot.sh" --phone "$PDIR/$fold-$want-settings.png" >/dev/null 2>&1 || true   # Settings still open: the evidence
      after=$(ev "$SPOTS"); ev 'importShim("./screens.ts").then(Sc=>{Sc.screens.value=[];return "ok"})' >/dev/null; SCR=; sleep 1.2
      step "$fold-$want" "$fold: Settings > style > $label = $opt, then home"
      hs=$(ev "$HOMESEARCH"); log "$label=$opt: spots $now -> $after, home $hs"
      ms=${after%|*}; [ $mode = unfolded ] && ms=${after#*|}
      os=${after#*|}; [ $mode = unfolded ] && os=${after%|*}
      bad=""; [ "$ms" = "$want" ] || bad="$bad; spot is $ms, not $want"; [ "$os" = "$other" ] || bad="$bad; the other screen's spot changed $other -> $os"
      if [ "$want" = dock ]; then [ "$hs" = "dock=true bar=false" ] || bad="$bad; home: $hs (want the dock's button, no bar)"
      else [ "$hs" = "dock=false bar=true" ] || bad="$bad; home: $hs (want the bar, no dock button)"; fi
      [ -z "$bad" ] && pass "$fold: $label = $opt -> home's search $hs at once" || fail "$fold: $label = $opt:${bad#;}"
    done
  done
  more_restore
  sleep 1; e=$(ev "$SPOTS"); [ "$e" = "$s0" ] && pass "search spots back as found ($e)" || fail "search spots $e, at the start $s0"
fi

# --- cc-quick-pages -------------------------------------------------------------------------------------------------
if [ "$CASE" = cc-quick-pages ]; then
  shut; pullbar 85 "status-bar pull on the right: the control center"
  if [ "$(shown)" != true ]; then step cc "the control center"; fail "the control center didn't come down"
  else
    host=$(CDP_TIMEOUT_S=20 sev 'importShim("./bridge.ts").then(B=>B.powos.quickpage&&B.powos.quickpage.pages?B.powos.quickpage.pages().then(l=>JSON.stringify((l||[]).map(q=>[q.action,q.label,!!q.icon,!!q.mono]))):"none")')
    log "quickpage.pages: ${host:0:600}"
    CCED=1; sev "importShim('./ui/ccexpand.ts').then(X=>{X.ccEditing.value=true;return 'ok'})" >/dev/null; sleep 1.2
    sev '(e=>(e&&e.scrollIntoView({block:"center"}),"ok"))(document.querySelector(".cc3-quickpages"))' >/dev/null; sleep 0.8
    step cc-edit "CC edit mode: the add quick page row"
    row=$(sev '(()=>{const g=document.querySelector(".cc3-quickpages");if(!g)return "none";const on=[...document.querySelectorAll(".cc3-launchers .cc3-grid:not(.cc3-spare) [data-key]")].map(e=>e.dataset.key);
return JSON.stringify({on,items:[...g.querySelectorAll(".cc3-t")].map(b=>{const c=b.querySelector(".cc3-chip"),i=c&&c.querySelector(":scope > img"),m=c&&c.querySelector(":scope > .qp-mono");
return [(b.getAttribute("aria-label")||"").replace(/^add quick page /,""),i?"img":m?"mono":c&&c.querySelector(":scope > svg")?"glyph":"none",i?i.src.length+":"+i.src.slice(-24):m?(m.style.getPropertyValue("--qp-mask")||"").slice(-24):""]})})})()')
    log "picker: ${row:0:800}"
    r=$(python3 - "$host" "$row" <<'PY'
import json, sys
h, r = sys.argv[1], sys.argv[2]
if h == "none": print("FAIL this APK has no quickpage.pages (the device's own list): the row is the built-in list - needs the APK with QuickPageCatalog"); sys.exit()
try: pages = json.loads(h); row = json.loads(r)
except Exception: print("FAIL unreadable: host " + h[:120] + " | row " + r[:120]); sys.exit()
if not pages: print("FAIL quickpage.pages answered an empty list"); sys.exit()
on = {k[3:] for k in row["on"] if k.startswith("qp:")}
want = [p[1].lower() for p in pages if p[0] not in on]
got = [i[0].lower() for i in row["items"]]
bad = []
if sorted(want) != sorted(got): bad.append(f"the row lists {got[:12]}, the device's pages not on the row are {want[:12]}")
# A page with no icon of its own gets its MDI glyph (quickpage.tsx QUICK_GLYPH - the spec's "its page's picture or
# glyph, never the Settings gear"): a glyph counts (11-02 FAIL counted it as none). Only no face at all fails.
own = [i for i in row["items"] if i[1] in ("img", "mono")]
faced = [i for i in row["items"] if i[1] in ("img", "mono", "glyph")]
if len(faced) < len(row["items"]): bad.append(f"{len(row['items']) - len(faced)} of {len(row['items'])} items without a picture or glyph: {[i[0] for i in row['items'] if i[1] not in ('img','mono','glyph')][:8]}")
ch = [i[0] for i in row["items"] if i[0].lower().startswith("complete action") or i[0].lower().startswith("open with")]
if ch: bad.append(f"the system chooser offered as a page: {ch} (QuickPageCatalog.chooser)")
pics = {i[2] for i in own}
if len(own) > 2 and len(pics) <= 1: bad.append("every item shows the same picture")
print(("FAIL " + "; ".join(bad)) if bad else f"PASS {len(got)} of the device's {len(pages)} pages offered ({len(on)} on the row), {len(own)} with their own picture ({len(pics)} different), {len(faced) - len(own)} with their glyph")
PY
)
    verdict "$r"
  fi
  more_restore
fi

# --- rec-light ------------------------------------------------------------------------------------------------------
REC='(()=>{const r=document.querySelector(".status-rec-ring"),d=document.querySelector(".status-rec-dot");if(r){const b=r.getBoundingClientRect();return "ring "+r.dataset.kind+" at "+Math.round(b.left+b.width/2)+","+Math.round(b.top+b.height/2)+" size "+Math.round(b.width)+" in "+innerWidth+"x"+innerHeight}return d?"dot "+d.dataset.kind:"none"})()'
# recread: the recording light on every shell page up now ("<page>: <ring|dot|none>", the first lit one, else the last).
# Only the status chrome's pages (mode=statusbar) and home's: a hidden surface page (shade, pull) can hold CDP 120 s.
recread() { local pg v out="none (no statusbar/home page)"; for pg in $("$T/cdp.sh" pages 2>/dev/null | awk '$1=="statusbar"||$1=="home"{print $1}' | sort -u); do
    v=$(CDP_TIMEOUT_S=15 ev "$REC" "$pg"); case $v in ring*|dot*) echo "$pg: $v"; return ;; esac; out="$pg: $v"; done; echo "$out"; }
# micrun: the packages Android has RECORD_AUDIO running for now (dumpsys appops), space-separated; empty: the mic rests.
micparse() { python3 -c 'import sys,re
pkg=None; out=[]
for l in sys.stdin:
    m=re.match(r"\s*Package (\S+):",l)
    if m: pkg=m[1]; continue
    if pkg and re.search(r"Running start|running=true|\(running\)",l,re.I) and pkg not in out: out.append(pkg)
print(" ".join(out))'; }
micrun() { sh_ "dumpsys appops --op RECORD_AUDIO" | micparse; }
# micwait <on|off> <secs>: micrun, polled ON THE PHONE (one adb call, every 0.5 s) until RECORD_AUDIO runs (on) / rests
# (off) or <secs> passed - the last dump's answer. The Mac-side loop (an adb call + a CDP read per 0.7 s tick, ~5-8 s
# each at Mac load) took rec-light's mic half past its 420 s budget (11-09 23:52, killed at "cover mic before").
micwait() { local w=1; [ "$1" = off ] && w=0
  sh_ "e=\$((\$(date +%s) + $2)); while :; do o=\$(dumpsys appops --op RECORD_AUDIO); r=0; echo \"\$o\" | grep -qiE \"Running start|running=true|[(]running[)]\" && r=1; [ \$r = $w ] && break; [ \$(date +%s) -ge \$e ] && break; sleep 0.5; done; echo \"\$o\"" | micparse; }
# recwait <mic|off> <secs>: the recording light polled IN THE PAGE (one CDP eval, every 0.2 s) until it shows the mic
# (a ring/dot of kind mic) / is off, or <secs> passed: the status chrome's page waited on, home's then read once.
# Answers like recread ("<page>: <ring|dot|none>"); for off, the first page still lit.
recwait() { local pg v out="none (no statusbar/home page)" t=$2
  for pg in $("$T/cdp.sh" pages 2>/dev/null | awk '$1=="statusbar"||$1=="home"{print $1}' | sort -u -r); do
    v=$(CDP_TIMEOUT_S=$((t + 15)) ev "new Promise(res=>{const f=()=>$REC,end=Date.now()+$t*1000,g=()=>{const v=f(),lit=/^(ring|dot)/.test(v);if(('$1'==='off'?!lit:/^(ring|dot) mic/.test(v))||Date.now()>end)res(v);else setTimeout(g,200)};g()})" "$pg")
    t=0; out="$pg: $v"
    case $1:$v in mic:ring\ mic*|mic:dot\ mic*|off:ring*|off:dot*) break ;; esac
  done; echo "$out"; }
# camclose: the camera's tasks (any not there at the start of the case) closed.
camclose() { local id pkg vis; while read -r id pkg vis; do [ -n "$id" ] || continue
    grep -q "^$id " <<<"$CAMT0" || { sh_ "am stack remove $id"; log "closed task $id ($pkg): the camera this case started"; }; done <<<"$(tasks)"; sleep 2; }
if [ "$CASE" = rec-light ]; then
  for fold in inner cover; do
    [ $fold = cover ] && { setfold cover || break; }
    r0=$(recread); log "$fold before: $r0"
    case $r0 in *ring*|*dot*) note "$fold: a recording light already on before the camera ($r0) - something else uses camera/mic" ;; esac
    CAMT0=$(tasks); CAMON=1; sh_ "am start -a android.media.action.STILL_IMAGE_CAMERA >/dev/null"; sleep 5; chk camera
    top=$(sh_ "dumpsys activity activities | grep -m1 topResumedActivity" | grep -oE '[a-zA-Z0-9_.]+/[a-zA-Z0-9_.]+' | head -1)
    step "camera-$fold" "$fold: the camera app started (STILL_IMAGE_CAMERA): $top"
    r1=$(recread); log "$fold with the camera: $r1"
    case $r1 in *"ring camera at"*) pass "$fold: green ring on the cutout ($r1)" ;; *) fail "$fold: no camera ring with $top in front ($r1)" ;; esac
    camclose; CAMON=; sleep 2; chk "camera closed"
    step "closed-$fold" "$fold: the camera closed"
    r2=$(recread); log "$fold after: $r2"
    case $r2 in *ring*|*dot*) fail "$fold: the light still on after the camera closed ($r2)" ;; *) pass "$fold: light off once the camera stopped" ;; esac
  done
  more_restore
fi
if [ "$CASE" = rec-light ]; then
  # The mic (orange), any app: the system's speech-input activity (RECOGNIZE_SPEECH, Google's on this phone) listens
  # the moment it opens - another app's real capture, seen through AppOps (WATCH_APPOPS) or, non-root, AudioManager's
  # anonymous recording callback. Android's own RECORD_AUDIO "running" state is the truth the ring is held to: on while
  # it runs, off once it stopped (the mic-at-rest rule). Nothing is said to it; its task is closed after.
  MICAPP=$(sh_ "cmd package resolve-activity --brief -a android.speech.action.RECOGNIZE_SPEECH" | tail -1)
  log "speech input: $MICAPP"
  for fold in cover inner; do
    [ $fold = inner ] && { setfold inner || break; }
    case $MICAPP in */*) ;; *) note "mic: no speech-input activity on the phone ($MICAPP) - not checked"; break ;; esac
    m0=$(micrun); r0=$(recread); log "$fold mic before: $r0 (running: $m0)"
    [ -n "$m0" ] && { note "$fold: something already records ($m0) - mic not checked"; continue; }
    case $r0 in *ring*|*dot*) fail "$fold: a recording light on with nothing recording ($r0)" ;; esac
    CAMT0=$(tasks); CAMON=1; sh_ "am start -n $MICAPP -a android.speech.action.RECOGNIZE_SPEECH >/dev/null"
    seen=; ran=$(micwait on 8); r1=$(recwait mic $([ -n "$ran" ] && echo 4 || echo 1))
    case $r1 in *"ring mic"*|*"dot mic"*) seen=$r1 ;; esac
    chk mic; step "mic-$fold" "$fold: speech input open ($MICAPP), recording: ${ran:-none}"
    log "$fold with the mic: ${seen:-$r1} (android running: ${ran:-none})"
    if [ -n "$seen" ]; then pass "$fold: orange ring while ${ran:-an app} records ($seen)"
    elif [ -n "$ran" ]; then fail "$fold: $ran recorded (RECORD_AUDIO running) but no mic ring ($r1)"
    else note "$fold: $MICAPP never started recording (no RECORD_AUDIO running) - mic not checked"; fi
    camclose; CAMON=; chk "mic closed"
    off=; m2=$(micwait off 6); r2=
    [ -z "$m2" ] && { r2=$(recwait off 4); case $r2 in *ring*|*dot*) ;; *) off=1 ;; esac; }
    step "mic-closed-$fold" "$fold: speech input closed"
    if [ -n "$off" ]; then pass "$fold: light off once the mic stopped"
    elif [ -n "$m2" ]; then note "$fold: RECORD_AUDIO still running after the close ($m2)"
    else fail "$fold: the light still on after the mic stopped ($r2)"; fi
  done
  more_restore
fi

# --- term-remote ----------------------------------------------------------------------------------------------------
if [ "$CASE" = term-remote ]; then
  ev 'importShim("./bridge.ts").then(B=>{B.powos.ai.sessions();return "ok"})' >/dev/null; sleep 3
  pick=$(ev 'importShim("./ui/terms.tsx").then(T=>{const me=T.localHost(),r=T.sessions.value.filter(s=>s.host&&s.host!==me&&s.host!=="local");return r.length?r[0].host+" "+r[0].name+" ("+r.length+" remote of "+T.sessions.value.length+", this host "+(me||"?")+")":"none ("+T.sessions.value.length+" sessions, this host "+(me||"?")+")"})')
  log "remote session: $pick"
  case $pick in none*|""|ERR*|cdp*) step term "a remote host's session"; note "no remote host session listed ($pick): not measured - never a local tmux session" ;;
  *) set -- $pick; host=$1; name=$2; [[ $host$name =~ ^[A-Za-z0-9_.:-]+$ ]] || { fail "odd session name ($pick)"; e2e_finish; exit 0; }
    TERMID="at-work:$host:$name"
    # Every write to that session dropped and counted (view-only must write nothing; never typed into).
    ev "importShim('./bridge.ts').then(B=>{window.__dcWrote=[];if(!window.__dcWrite)window.__dcWrite=B.powos.term.write;const w=window.__dcWrite;B.powos.term.write=(i,d)=>i==='$TERMID'?(window.__dcWrote.push(atob(d)),Promise.resolve()):w(i,d);return 'ok'})" >/dev/null
    ev "importShim('./state.ts').then(S=>{S.openSession('$name',null,undefined,{host:'$host',local:false});return 'ok'})" >/dev/null
    for _ in 1 2 3 4 5 6 7 8; do sleep 1; [ "$(ev '!!document.querySelector(".session-term .xterm-screen")')" = true ] && break; done; sleep 2; chk term
    step term "$host's session $name opened view-only"
    f=$(ev "Promise.all([importShim('./ui/terminal.tsx'),importShim('./state.ts')]).then(([T,S])=>{const t=T.terminalFor('$TERMID'),el=document.querySelector('.session-term');if(!t||!el)return JSON.stringify({open:false});
const scr=el.querySelector('.xterm-screen'),cv=el.querySelector('.xterm-screen canvas'),cover=el.querySelector('.term-cover'),d=devicePixelRatio,b=(cover||el).getBoundingClientRect();
return JSON.stringify({open:true,write:!!S.sessionView.value?.write,renderer:T.rendererFor?T.rendererFor('$TERMID'):(cv&&!el.querySelector('.xterm-rows')?.children.length?'canvas?':'dom'),canvas:!!cv,
font:String(t.options.fontFamily),cell:scr.offsetHeight/t.rows,rows:t.rows,base:t.buffer.active.baseY,vy:t.buffer.active.viewportY,cover:!!cover,x:Math.round((b.left+b.width/2)*d),y:Math.round((b.top+b.height/3)*d),bottom:Math.round(b.bottom*d),d})})")
    log "terminal facts: $f"
    eval "$(python3 - "$f" <<'PY'
import json, sys, shlex
try: f = json.loads(sys.argv[1])
except Exception: f = {"open": False}
o = lambda k, v: print(f"{k}={shlex.quote(str(v))}")
o("OPEN", f.get("open")); o("WR", f.get("write")); o("REN", f.get("renderer")); o("FONT", f.get("font", "")); o("BASE", f.get("base", 0)); o("VY", f.get("vy", 0))
o("TX", f.get("x", 0)); o("TY", f.get("y", 0)); o("TB", f.get("bottom", 0)); o("CELL", round(f.get("cell", 0) * f.get("d", 1)))
PY
)"
    if [ "$OPEN" != True ]; then fail "the session view didn't open ($f)"
    else
      [ "$WR" = False ] || fail "the session opened for writing, not view-only"
      [ "$REN" = webgl ] && pass "the WebGL renderer draws it" || fail "renderer: $REN (want webgl)"
      first=${FONT%%,*}; case $FONT in *monospace*) pass "font: $FONT (first: $first)" ;; *) fail "font family $FONT has no monospace" ;; esac
      if [ "${BASE:-0}" -lt 4 ] 2>/dev/null || [ "${CELL:-0}" -lt 4 ]; then note "scrollback $BASE lines, cell $CELL px: too little history for a 4-row drag - not measured"
      else
        y1=$((TY + 4 * CELL + 2)); [ $y1 -ge "$TB" ] && y1=$((TB - 4))
        if mdown "$TX" "$TY" "a 4-row drag on the view"; then mpath "$TX" "$TY" "$TX" "$y1" 8; sleep 0.6; mup "$TX" "$y1"; fi
        sleep 0.8; chk drag
        step drag "a 4-row drag down on the view-only session"
        a=$(ev "importShim('./ui/terminal.tsx').then(T=>{const t=T.terminalFor('$TERMID');return t?String(t.buffer.active.viewportY)+' wrote '+JSON.stringify((window.__dcWrote||[]).join('')).slice(0,80):'gone'})")
        log "after the drag: viewportY $a (before $VY)"; vy1=${a%% *}; moved=$((VY - ${vy1:-$VY}))
        [ "$moved" = 4 ] && pass "a 4-row drag scrolled 4 rows ($VY -> $vy1)" || fail "a 4-row drag scrolled $moved rows ($VY -> $vy1)"
        case $a in *'wrote ""'*) pass "nothing written to the session" ;; *) fail "the drag wrote to the view-only session: ${a#* wrote }" ;; esac
      fi
    fi ;;
  esac
  more_restore
fi

# --- health-page ----------------------------------------------------------------------------------------------------
if [ "$CASE" = health-page ]; then
  st=$(hcall health.status "[]" "v=>JSON.stringify(v)"); log "health.status: $st"
  linked=$(python3 -c 'import json,sys
try: s=json.loads(sys.argv[1]); print("yes" if s.get("state")=="ok" and s.get("granted") else "no:"+str(s.get("state")))
except Exception: print("unreadable")' "$st")
  case $linked in
    yes)
      HOPEN=1; ev 'importShim("./apps/pages.ts").then(P=>{P.openApp("local.health");return "ok"})' >/dev/null; sleep 4; chk health
      step health "the Health app's page opened by code (linked)"
      r=$(ev '(()=>{const e=document.querySelector(".app-screen[data-app=\"local.health\"]");if(!e)return "FAIL the Health page did not open";const t=(e.innerText||"").replace(/\s+/g," ").trim();
const figs=[...e.querySelectorAll("section.tile")].filter(s=>/[0-9]/.test(s.innerText||"")).length;const what=" | "+figs+" figure tiles, text \""+t.slice(0,120)+"\"";
if(/Allow PowOS to read/.test(t))return "FAIL linked but the page asks for the grant"+what;
if(/needs an update|has no Health Connect|can.t reach Health Connect/.test(t))return "FAIL a Health Connect note on a linked phone"+what;
if(figs)return "PASS today/week figures shown"+what;
if(/Nothing from today yet/.test(t))return "PASS linked, nothing today: the plain empty line"+what;
if(/Syncing/.test(t))return "NOTE still syncing after 4 s"+what;
return "FAIL linked, neither figures nor the empty line"+what})()')
      log "health page: $r"; verdict "$r" ;;
    no:*) step health "Health Connect not linked"; note "Health Connect not linked (${linked#no:}): opening the page puts the system's grant dialog up - the user's to answer, not opened" ;;
    *) step health "Health Connect's state"; fail "health.status unreadable ($st)" ;;
  esac
  more_restore
fi

# --- needs-me -------------------------------------------------------------------------------------------------------
# The rows' check, in the page: each row whole inside [root] (a tile's box, or the page), no markdown marks, a replied
# row carrying its mark; else the calm empty line. Read only.
NM_LOOK='(root,where)=>{const t=(root.innerText||"").replace(/\s+/g," ").trim();const rows=[...root.querySelectorAll(".nm-row")];
const past=rows.filter(r=>r.hasAttribute("data-past")).length,rep=rows.filter(r=>r.hasAttribute("data-replied"));
const what=" | "+where+": "+rows.length+" rows ("+past+" past, "+rep.length+" replied), text \""+t.slice(0,120)+"\"";
if(/\*\*|`|\]\(/.test(t))return "FAIL markdown shown as marks"+what;
if(rep.some(r=>!r.querySelector(".nm-replied")))return "FAIL a replied row without its mark"+what;
if(rows.length){if(where==="tile"){const b=root.getBoundingClientRect();const cut=rows.filter(r=>r.getBoundingClientRect().bottom>b.bottom+0.5).length;if(cut)return "FAIL "+cut+" row(s) cut by the tile"+what}return "PASS rows shown"+what}
if(/Nothing needs you|Allow (PowOS )?notification access|Update PowOS/.test(t))return "PASS the calm empty state"+what;
return "FAIL neither rows nor the empty line"+what}'
if [ "$CASE" = needs-me ]; then
  r=$(ev '(()=>{const look='"$NM_LOOK"';const h=document.querySelector(".page:not(.away) .nm-title")||document.querySelector(".nm-title");if(!h)return "none";const tile=h.closest("[data-key]")||h.parentElement.parentElement;return look(tile,"tile")})()')
  if [ "$r" = none ]; then
    NOPEN=1; ev 'importShim("./apps/pages.ts").then(P=>{P.openApp("local.needs-me");return "ok"})' >/dev/null; sleep 3; chk needs-me
    step needs-me "no What needs me widget on home: its page opened by code"
    r=$(ev '(()=>{const look='"$NM_LOOK"';const e=document.querySelector(".app-screen[data-app=\"local.needs-me\"]");if(!e)return "FAIL the What needs me page did not open (not installed?)";return look(e,"page")})()')
  else step needs-me "the What needs me widget on home"; fi
  log "needs-me: $r"; verdict "$r"
  more_restore
fi

more_restore
e2e_finish
