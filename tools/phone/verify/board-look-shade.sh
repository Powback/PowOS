#!/bin/bash
# lanes: phone
# board-look-shade.sh <case> [--round R]: on-device checks of the shade / control center / lock / AI-chat board tasks
# (board-look.sh's structure, its own file so the two don't conflict). Real injected swipes and taps through e2e-lib's
# helpers only (touch abort exit 3, pill guard, restore); facts read over read-only CDP from the shade / lock / home
# pages. A setting a case changes (the "open where the finger starts" toggle, the CC quick-launch row) is read first and
# put back in the EXIT trap. No injected notifications, no typing, no games. Cases:
#   shade-nav     (shade-streamlined-no-drawer-panel-cc-floats-on-t, 7486fb6c S9): with the shade down, a home swipe, a
#                 switcher swipe (held) and a sideways swipe along the bar each shut it - home's page, launcher and the
#                 app in front unchanged, NavGesture logs "over PowOS's shade"; a bottom-left / bottom-right corner swipe
#                 over it opens no AI / apps panel. Unfolded, then folded (cover screen forced, reset at the end).
#   shade-anchor  (shade-and-control-center-open-where-your-finger, ea525870): toggle on (Settings > style > alignment,
#                 set by code, restored): a pull from home near the foot opens the content low (data-anchored, around
#                 the finger); a status-bar pull opens at the top as with the toggle off.
#   cc-ql-x       (control-center-quick-launch-the-x-removes-an-app, 883746f9): CC edit mode, a tap on the last
#                 quick-launch app's X removes it (row + store); a held press let go on another X keeps it; the row is
#                 put back as it was.
#   lock-strip    (lock-screen-no-brown-strip-at-the-bottom-notific, 288670ef + b7a159bb): read-only on the lock page
#                 (rendered while unlocked): --lock-lift registered (no --lift on the root), cards keep a shadow, each
#                 card has its notification's icon. The unlock slide / AOD look is a SKIP: showing the lock face needs
#                 the phone locked (power key) and woken by script - against the never-wake rule on the live phone.
#   cc-design     (shade-control-center-design-gaps, a56c3c40): CC opened by a status-bar pull: its categories arrive
#                 with their own cc-subs-in animation; the panel paints no blur/tint of its own (THE backdrop: the
#                 scrim's), --shade-blur-native = --backdrop-blur-native.
#   ai-keyboard   (one-search-bar-everywhere-it-changes-role-per-pa, e5826cd7 + c5f34ade): folded, a tap in the AI
#                 page's bar raises the keyboard: tabs (.ai-segs) hidden, the bar sits on the keyboard (no gap, not
#                 behind it), the page not scrolled; unfolded, the chat's last line ends >= ~16 px above the bar.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/e2e-lib.sh"
CASES="shade-nav shade-anchor cc-ql-x lock-strip cc-design ai-keyboard"
CASE=${1:-}; shift || true
case " $CASES " in *" $CASE "*) [ -n "$CASE" ] ;; *) false ;; esac || { echo "usage: board-look-shade.sh ${CASES// /|} [--round R]"; exit 2; }
[ "${POWOS_DEVICE:-phone}" = emu ] && [ "$CASE" != lock-strip ] && { echo "SKIP: $CASE needs the phone's shade host and fold states"; exit 3; }
e2e_args "$@"
e2e_init "look-shade-$CASE"
e2e_setup inner

# --- this file's helpers -------------------------------------------------------------------------------------------
sev() { ev "$1" shade; }
shown() { sev 'String(!!document.querySelector(".notif-panel.shown"))'; }
# spt <js element on the shade page>: its centre in screen px (the shade window's frame added), none/off.
spt() { local o ox=0 oy=0; o=$(wframe "PowOS shade"); [ -n "$o" ] && { set -- "$1" $o; ox=$2; oy=$3; }
  ev "(()=>{const e=($1);if(!e)return 'none';const r=e.getBoundingClientRect(),d=devicePixelRatio;if(r.width<2||r.height<2)return 'off';return Math.round((r.x+r.width/2)*d+$ox)+' '+Math.round((r.y+r.height/2)*d+$oy)})()" shade; }
# mark <n>: a line in logcat to read this step's gesture lines after (logs <n>: NavGesture / CornerPull / Shade since it).
mark() { sh_ "log -t PowosVerify look-shade-$1" >/dev/null; }
logs() { sh_ "logcat -d -t 800 -s PowosVerify:I PowosNavGesture:I PowosCornerPull:I PowosShade:I" | sed -n "/look-shade-$1\$/,\$p" | tail -n +2; }
# pullbar <x fraction> <what>: a status-bar pull down at that x; waits for the shade.
pullbar() { swipe $((W * $1 / 100)) 6 $((W * $1 / 100)) $((H / 2)) 280 "$2" || return 1; sleep 1.4; chk "$2"; }
shut() { [ "$(shown)" = true ] && { back 1.2; [ "$(shown)" = true ] && { sh_ "cmd statusbar collapse"; sleep 1; }; }; true; }
# Case-owned restore (settings this case changed), run before e2e-lib's: trap keeps e2e_abort's rc.
case_restore() { :; }
trap 'rc=$?; case_restore; (exit $rc); e2e_abort' EXIT
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

# --- shade-nav ------------------------------------------------------------------------------------------------------
# state: home's page, launcher open, PowOS AI page / panel shown, the app in front - what must not move under the shade.
navstate() { echo "page=$(hpage) open=$(isopen) top=$(sh_ "dumpsys activity activities | grep -m1 topResumedActivity" | grep -oE '[a-zA-Z0-9_.]+/[a-zA-Z0-9_.]+' | head -1) pull=$(ev 'String(!!document.querySelector(".pull.shown, .pull-panel.shown, .launcher.shown"))' pull)"; }
navone() { # navone <slug> <what> <gesture fn>
  local s0 s1 lg
  shut; pullbar 30 "the shade, pulled from the status bar" || return
  [ "$(shown)" = true ] || { step "$1" "$2"; fail "the shade didn't open from the status bar - the swipe not tried"; return; }
  s0=$(navstate); mark "$1"; "$3"; sleep 1.6; chk "$1"
  step "$1" "$2"
  s1=$(navstate); lg=$(logs "$1"); log "before: $s0 | after: $s1"; log "logs: $(echo "$lg" | tr '\n' '|' | cut -c1-600)"
  local bad=""
  [ "$(shown)" = false ] || bad="$bad; the shade is still down"
  [ "$s0" = "$s1" ] || bad="$bad; under it changed ($s0 -> $s1)"
  case $1 in corner*) grep -qE 'corner pull: (open|let go .*-> open)' <<<"$lg" && bad="$bad; a corner panel opened over the shade" ;;
    *) grep -q "over PowOS's shade" <<<"$lg" || bad="$bad; NavGesture didn't take it as the shade's swipe (no 'over PowOS's shade' log)" ;; esac
  [ -z "$bad" ] && pass "shade shut, nothing under it moved ($s1)" || fail "${bad#; }"
}
g_home() { swipe $((W / 2)) $((H - 3)) $((W / 2)) $((H * 55 / 100)) 180 "home swipe over the shade"; }
g_switch() { mdown $((W / 2)) $((H - 3)) "switcher swipe" || return; mpath $((W / 2)) $((H - 3)) $((W / 2)) $((H * 72 / 100)) 12; sleep 0.7; mup $((W / 2)) $((H * 72 / 100)); }
g_side() { swipe $((W * 30 / 100)) $((H - 3)) $((W * 72 / 100)) $((H - 5)) 220 "sideways along the bar over the shade"; }
g_cornl() { swipe $((W * 4 / 100)) $((H - 3)) $((W * 14 / 100)) $((H * 60 / 100)) 320 "bottom-left corner swipe over the shade"; }
g_cornr() { swipe $((W * 96 / 100)) $((H - 3)) $((W * 86 / 100)) $((H * 60 / 100)) 320 "bottom-right corner swipe over the shade"; }
if [ "$CASE" = shade-nav ]; then
  for fold in inner cover; do
    [ $fold = cover ] && { setfold cover || break; }
    navone "home-$fold" "$fold: the shade down, a home swipe from the bar: it shuts, home stays as it was" g_home
    navone "switch-$fold" "$fold: the shade down, a held switcher swipe: it shuts, no switcher under it" g_switch
    navone "side-$fold" "$fold: the shade down, a sideways swipe along the bar: it shuts, no quick switch" g_side
    navone "cornerl-$fold" "$fold: the shade down, a bottom-left corner swipe: no PowOS AI panel over it" g_cornl
    navone "cornerr-$fold" "$fold: the shade down, a bottom-right corner swipe: no apps panel over it" g_cornr
  done
  shut
fi

# --- shade-anchor ---------------------------------------------------------------------------------------------------
TOPJS='(()=>{const p=document.querySelector(".notif-panel.shown"),c=p&&p.querySelector(":scope > .panel-body > *");if(!c)return "none";return Math.round(c.getBoundingClientRect().top)+" "+p.hasAttribute("data-anchored")+" "+innerHeight})()'
if [ "$CASE" = shade-anchor ]; then
  ANC0=$(sev 'String(localStorage.getItem("powos.align.anchor"))'); log "the toggle at the start: '$ANC0'"
  case $ANC0 in null|""|on) ;; *) fail "the toggle couldn't be read ($ANC0) - nothing changed"; e2e_finish; exit 0 ;; esac
  case_restore() { [ -n "${ANC0:-}" ] || return 0; local v=; [ "$ANC0" = on ] && v=on
    sev "importShim('./ui/align.ts').then(A=>{A.anchorPull.value='$v';return 'ok'})" >/dev/null; shut
    log "toggle back to '${v:-off}': $(sev 'String(localStorage.getItem("powos.align.anchor"))')"; ANC0=; }
  shut; pullbar 30 "status-bar pull (toggle as found)"; base=$(sev "$TOPJS"); log "toggle as found, status-bar pull: $base"; shut
  r=$(sev "importShim('./ui/align.ts').then(A=>{A.anchorPull.value='on';return localStorage.getItem('powos.align.anchor')})"); log "toggle on: $r"
  p=$(freept "" 0 0 .15 .65); log "low spot on home: $p"
  if [ "$p" = none ] || [ -z "$p" ]; then step low "toggle on, a pull from home near the foot"; fail "no empty spot low on home's page for a pull"
  else set -- $p; x=$1; y=$2; y2=$((y + H / 7)); [ $y2 -gt $((H * 93 / 100)) ] && y2=$((H * 93 / 100))
    swipe "$x" "$y" "$x" "$y2" 260 "pull from home at y=$y"; sleep 1.4; chk low
    step low "toggle on: a pull from home at $((y * 100 / H))% of the height opens the shade around the finger"
    lo=$(sev "$TOPJS"); log "low pull: $lo"
    set -- $lo; if [ "$1" = none ]; then fail "the low pull opened no shade ($lo)"
    else lt=$1; la=$2; ih=$3; fy=$(awk -v y="$y" -v H="$H" -v ih="$ih" 'BEGIN{print int(y/H*ih)}'); bt=${base%% *}
      [ "$la" = true ] && [ "$lt" -gt $((${bt:-0} + 40)) ] && [ "$lt" -le $((fy + 8)) ] && pass "content from $lt (top pull $bt), finger at $fy css px, data-anchored" ||
        fail "low pull: content top $lt (status-bar pull $bt), finger at $fy, anchored=$la - want anchored, below the top and by the finger"
    fi
    shut
  fi
  pullbar 70 "status-bar pull (toggle on)"
  step top "toggle on: a status-bar pull still opens at the top"
  tp=$(sev "$TOPJS"); log "status-bar pull, on: $tp"; set -- $tp
  [ "$1" != none ] && [ "${base%% *}" != none ] && [ $(( $1 - ${base%% *} )) -le 4 ] && [ $(( ${base%% *} - $1 )) -le 4 ] && pass "top pull at $1 as with it off (${base%% *})" ||
    fail "status-bar pull with the toggle on opens at $tp, off at $base"
  shut; case_restore
fi

# --- cc-ql-x --------------------------------------------------------------------------------------------------------
KEYS='[...document.querySelectorAll(".cc3-launchers .cc3-grid:not(.cc3-spare) [data-key]")].map(e=>e.dataset.key).join(",")'
STORED='importShim("./bridge.ts").then(B=>B.powos.store.get("controls.launchers")).then(v=>JSON.stringify(v===undefined?null:v))'
if [ "$CASE" = cc-ql-x ]; then
  QL0=$(sev "$STORED"); log "quick-launch row stored at the start: $QL0"
  case $QL0 in null|\[*) ;; *) fail "the stored row couldn't be read ($QL0) - nothing changed"; e2e_finish; exit 0 ;; esac
  case_restore() { [ -n "${QL0:-}" ] || return 0
    sev "Promise.all([importShim('./bridge.ts'),importShim('./ui/launchers.tsx'),importShim('./ui/ccexpand.ts')]).then(async([B,L,X])=>{await B.powos.store.set('controls.launchers',$QL0);L.loadLaunchers();X.ccEditing.value=false;return 'ok'})" >/dev/null
    sleep 0.6; log "row put back: $(sev "$STORED") (was $QL0)"; QL0=; shut; }
  shut; pullbar 85 "status-bar pull on the right: the control center"
  sev "importShim('./ui/ccexpand.ts').then(X=>{X.ccEditing.value=true;return 'ok'})" >/dev/null; sleep 0.8
  k0=$(sev "$KEYS"); log "row in edit mode: $k0"
  IFS=, read -r -a ks <<<"$k0"; n=${#ks[@]}
  if [ "$n" -lt 2 ]; then step edit "CC edit mode"; fail "fewer than two quick-launch apps on the row ($k0) - nothing to remove safely"
  else
    k=${ks[$((n - 1))]}; k2=${ks[0]}
    xp=$(spt "document.querySelector('.cc3-launchers .cc3-grid:not(.cc3-spare) [data-key=\"$k\"] .cc3-badge')")
    step edit "CC edit mode: the quick-launch row with its X's ($k0)"
    case $xp in none|off|"") fail "no X on $k ($xp)" ;;
      *) set -- $xp; tap "$1" "$2" "the X on $k"; sleep 1.2; chk x
         step removed "after a tap on $k's X"
         k1=$(sev "$KEYS"); st=$(sev "$STORED"); log "row: $k1 | stored: $st"
         ! grep -q "\"$k\"" <<<"$st" && [[ ",$k1," != *",$k,"* ]] && pass "$k off the row and the store" || fail "a tap on $k's X left it: row $k1, stored $st" ;;
    esac
    xp2=$(spt "document.querySelector('.cc3-launchers .cc3-grid:not(.cc3-spare) [data-key=\"$k2\"] .cc3-badge')")
    case $xp2 in none|off|"") note "no X on $k2 for the hold check ($xp2)" ;;
      *) set -- $xp2; press "$1" "$2" 700 "a held press on $k2's X, let go in place"; sleep 1.2; chk hold
         step held "after a held press let go on $k2's X"
         k3=$(sev "$KEYS"); [[ ",$k3," == *",$k2,"* ]] && pass "$k2 kept (a lift's release is no remove)" || fail "a held press let go removed $k2 (row $k3)" ;;
    esac
  fi
  QLSAVE=$QL0; case_restore
  step readded "the quick-launch row put back as found"
  now=$(sev "$STORED"); [ "$now" = "$QLSAVE" ] && pass "row stored as at the start ($now)" || fail "row stored $now, at the start $QLSAVE"
fi

# --- lock-strip -----------------------------------------------------------------------------------------------------
if [ "$CASE" = lock-strip ]; then
  step lock "read-only: the lock page (rendered under home while unlocked) - its cards' material"
  f=$(ev '(()=>{const r=document.documentElement,cs=getComputedStyle(r),n=[...document.querySelectorAll(".lock-note")];
  return JSON.stringify({n:n.length,lift:cs.getPropertyValue("--lock-lift").trim(),oldLift:r.style.getPropertyValue("--lift"),
  cards:n.map(c=>{const s=getComputedStyle(c);return {shadow:s.boxShadow,icon:!!c.querySelector("img,svg,.notif-glyph,[class*=glyph],[class*=icon]")}})})})()' lock)
  log "lock facts: $f"
  python3 - "$f" <<'PY' > "$OUT/lock.txt"
import json, sys
try: f = json.loads(sys.argv[1])
except Exception: print("FAIL no answer from the lock page: " + sys.argv[1][:200]); sys.exit()
bad = []
if f["lift"] != "0": bad.append(f"--lock-lift reads '{f['lift']}' (want 0: registered, initial 0)")
if f["oldLift"]: bad.append(f"the root still sets --lift={f['oldLift']} (the theme's shadow token wiped)")
if f["n"] == 0: print("ENV no notification cards on the lock page - card shadow/icon not judged" + (("; " + "; ".join(bad)) if bad else "")); sys.exit()
ns = [i for i, c in enumerate(f["cards"]) if c["shadow"] in ("none", "")]
if ns: bad.append(f"cards {ns} have no shadow")
ni = [i for i, c in enumerate(f["cards"]) if not c["icon"]]
if ni: bad.append(f"cards {ni} have no icon")
print(("FAIL " + "; ".join(bad)) if bad else f"PASS {f['n']} cards, each with a shadow and an icon; --lock-lift registered")
PY
  r=$(cat "$OUT/lock.txt"); case $r in PASS*) pass "${r#PASS }" ;; ENV*) note "${r#ENV }"; NSKIP=$((NSKIP + 1)); _res SKIP "${r#ENV }" ;; *) fail "${r#FAIL }" ;; esac
  NSKIP=$((NSKIP + 1)); _res SKIP "unlock slide (blur stays with the cards, no strip) and AOD not driven: the lock face only shows on a locked phone, and locking + waking it by script breaks the never-wake rule on the live phone - see the gate's lock-unlock-glass-folded/unfolded"
fi

# --- cc-design ------------------------------------------------------------------------------------------------------
if [ "$CASE" = cc-design ]; then
  shut; pullbar 85 "status-bar pull on the right: the control center"
  # Read at once: the categories' entry animations are running now.
  f=$(sev '(()=>{const p=document.querySelector(".notif-panel.shown");if(!p)return JSON.stringify({p:false});const cs=getComputedStyle(p),rc=getComputedStyle(document.documentElement);
  const cats=[...p.querySelectorAll(".cc3-sec, .cc-cell-subs, .cc-subs > .cc-sub")].filter(e=>e.getBoundingClientRect().height>0);
  return JSON.stringify({p:true,bf:cs.backdropFilter||cs.webkitBackdropFilter||"none",bg:cs.backgroundColor,bgi:cs.backgroundImage,
  shade:rc.getPropertyValue("--shade-blur-native").trim(),back:rc.getPropertyValue("--backdrop-blur-native").trim(),
  cats:cats.length,anim:cats.filter(e=>getComputedStyle(e).animationName==="cc-subs-in").length,
  running:cats.filter(e=>e.getAnimations().some(a=>a.playState==="running"||a.playState==="pending")).length})})()')
  step cc "the control center just opened: its categories arriving, the panel on THE backdrop"
  log "cc facts: $f"
  python3 - "$f" <<'PY' > "$OUT/cc.txt"
import json, sys
try: f = json.loads(sys.argv[1])
except Exception: print("FAIL no answer from the shade page: " + sys.argv[1][:200]); sys.exit()
if not f.get("p"): print("FAIL the control center didn't open"); sys.exit()
bad = []
if f["cats"] == 0: bad.append("no categories (.cc3-sec / .cc-cell-subs) shown")
elif f["anim"] < f["cats"]: bad.append(f"{f['cats'] - f['anim']} of {f['cats']} categories arrive without cc-subs-in")
if f["bf"] != "none": bad.append(f"the panel has its own backdrop-filter {f['bf']}")
if f["bg"] != "rgba(0, 0, 0, 0)" or f["bgi"] != "none": bad.append(f"the panel paints its own tint {f['bg']} {f['bgi']}")
if f["shade"] != f["back"]: bad.append(f"--shade-blur-native {f['shade']} isn't THE backdrop's {f['back']}")
print(("FAIL " + "; ".join(bad)) if bad else f"PASS {f['cats']} categories with cc-subs-in ({f['running']} still animating at the read); one backdrop ({f['back']}), no panel blur/tint")
PY
  r=$(cat "$OUT/cc.txt"); case $r in PASS*) pass "${r#PASS }" ;; *) fail "${r#FAIL }" ;; esac
  shut
fi

# --- ai-keyboard ----------------------------------------------------------------------------------------------------
AIBAR='document.querySelector(".home > .bar[data-role=ai] textarea")'
CLEAR='(()=>{const pill=document.querySelector(".bar[data-role] .bar-pill")||document.querySelector(".bar .bar-pill"),sc=[...document.querySelectorAll(".ai-page-chat")].find(e=>e.getBoundingClientRect().height>0);
if(!pill||!sc)return JSON.stringify({pill:!!pill,sc:!!sc});const p=pill.getBoundingClientRect(),s=sc.getBoundingClientRect();
const leaves=[...sc.querySelectorAll("*")].filter(e=>!e.children.length&&(e.textContent||"").trim()).map(e=>e.getBoundingClientRect()).filter(r=>r.height>0&&r.bottom<=s.bottom+1&&r.top<s.bottom&&r.left<p.right&&r.right>p.left);
return JSON.stringify({pill:true,sc:true,pillTop:Math.round(p.top),last:leaves.length?Math.round(Math.max(...leaves.map(r=>r.bottom))):null,n:leaves.length})})()'
if [ "$CASE" = ai-keyboard ]; then
  # Unfolded first (e2e_setup's inner screen): the last message above the bar.
  setpage -1; sleep 1.5; chk "ai page"
  step ai-unfolded "unfolded PowOS AI page: the chat's last line above the bar"
  c=$(ev "$CLEAR"); log "unfolded clear: $c"
  python3 - "$c" <<'PY' > "$OUT/ai1.txt"
import json, sys
try: f = json.loads(sys.argv[1])
except Exception: print("FAIL no answer: " + sys.argv[1][:200]); sys.exit()
if not (f.get("pill") and f.get("sc")): print(f"FAIL no bar pill / visible chat ({f})"); sys.exit()
if f["last"] is None: print("ENV the chat shows no text over the bar's span"); sys.exit()
gap = f["pillTop"] - f["last"]
print((f"PASS the last line ends {gap} px above the bar" if gap >= 12 else f"FAIL the last line ends {gap} px from the bar's top (want >= 16)"))
PY
  r=$(cat "$OUT/ai1.txt"); case $r in PASS*) pass "${r#PASS }" ;; ENV*) note "${r#ENV }" ;; *) fail "${r#FAIL }" ;; esac
  # Folded: the keyboard up from a tap in the bar.
  if setfold cover; then
    setpage -1; sleep 1.5; chk "ai page folded"
    bp=$(pt "$AIBAR"); log "the bar's field: $bp"
    case $bp in none|off|"") step ai-folded "folded PowOS AI page"; fail "no AI bar field on the folded AI page ($bp)" ;;
      *) set -- $bp; tap "$1" "$2" "the AI page's bar field"; sleep 1.8; chk keyboard
         step ai-keyboard "folded: a tap in the AI bar - keyboard up, tabs hidden, the bar on the keyboard"
         im=$(ime); k=$(ev '(()=>{const r=document.documentElement,kb=parseFloat(r.style.getPropertyValue("--inset-keyboard")||getComputedStyle(r).getPropertyValue("--inset-keyboard"))||0,segs=document.querySelector(".ai-screen.stacked > .ai-segs"),pill=document.querySelector(".home > .bar[data-role=ai] .bar-pill"),pr=pill&&pill.getBoundingClientRect();
         return JSON.stringify({kb,segs:segs?getComputedStyle(segs).display:"absent",focus:document.activeElement&&document.activeElement.matches(".home > .bar[data-role=ai] textarea"),pillBottom:pr?Math.round(pr.bottom):null,ih:innerHeight,scroll:Math.round((document.scrollingElement||document.body).scrollTop+(visualViewport?visualViewport.offsetTop:0))})})()')
         log "keyboard: $im | $k"
         python3 - "$k" "$im" <<'PY' > "$OUT/ai2.txt"
import json, sys
try: f = json.loads(sys.argv[1])
except Exception: print("FAIL no answer: " + sys.argv[1][:200]); sys.exit()
if "mInputShown=true" not in sys.argv[2] or f["kb"] <= 0: print(f"FAIL the keyboard isn't up ({sys.argv[2]}, --inset-keyboard {f['kb']})"); sys.exit()
bad = []
if f["segs"] not in ("none", "absent"): bad.append(f"the tabs show (display {f['segs']})")
if f["pillBottom"] is None: bad.append("no bar pill")
else:
    gap = (f["ih"] - f["kb"]) - f["pillBottom"]
    if gap < -2: bad.append(f"the bar is {-gap} px behind the keyboard")
    elif gap > 40: bad.append(f"a {gap} px gap between the bar and the keyboard")
if f["scroll"] > 2: bad.append(f"the page scrolled up {f['scroll']} px")
print(("FAIL " + "; ".join(bad)) if bad else f"PASS tabs {f['segs']}, the bar {(f['ih'] - f['kb']) - f['pillBottom']} px over the keyboard, page not scrolled, field focused {f['focus']}")
PY
         r=$(cat "$OUT/ai2.txt"); case $r in PASS*) pass "${r#PASS }" ;; *) fail "${r#FAIL }" ;; esac
         back 1; ev 'document.activeElement&&document.activeElement.blur&&document.activeElement.blur(),"ok"' >/dev/null ;;
    esac
  fi
fi

case_restore
e2e_finish
