#!/bin/bash
# lanes: emu phone
# board-look-home.sh <case> [--round R]: on-device checks of home / AI page / launcher board tasks fixed in code, each
# proving its line in the device-checks list (board-look.sh's structure: e2e-lib setup/restore, touch abort (exit 3),
# pill guard, one e2e step screenshot). Read-only CDP measures of the user's real layout; what a case changes (edit
# mode, the AI page's tab, the rs render-scan meter, the open launcher) is saved first and put back in a trap - also on
# an abort. No widget is moved or resized; edit mode is entered and left by state, with no change in it. Cases:
#   home-merge   (folded-portrait-home-stuck-in-desktop-landscape, 39d1478b): folded, every pair of stacked widgets on
#                home - equal width (same columns) renders merged (both .joined, faces meet), unequal stays separate
#                (the normal gap); in edit mode each widget with one above has its edit pill clear of that widget;
#   ai-views     (ai-page-chat-agents-and-devices-views-use-the-pr, 05589a95 + 0302594a): unfolded AI page - Agents:
#                glass rows (.aip-area.tile), <= two lines, the plan bar under a title that gets the row; Devices: host
#                cards (.ai-unit-card glass), no old boxed list; Chat: bubbles/plan cards on the rows' glass, answer chips
#                12px corners, a plan card's peek with no fade mask;
#   health-tile  (health-opening-it-asks-for-health-connect-access, 5dd8cc66): Health Connect's link state read first
#                (health.status, no prompt); linked + nothing today -> "Nothing today" filling the tile, figures when
#                there is data, not linked -> "Connect Health";
#   render-scan  (render-scanner-react-scan-style-in-the-perf-reco, c920f0f2): the meter's rs on (store perf.meter) ->
#                the render overlay up on the shade, launcher pull, lock, switcher (when its page is up) and AI overlay
#                pages, outlining renders; the meter put back;
#   launcher-in  (launcher-design-gaps, a7b9ba39): the launcher opened by code animates in from closed (its frame/clip
#                --p sampled every frame for 300 ms: in-between values, not 0 -> 1 in one frame); no "No folders yet"
#                page (with no folders, no 2nd page at all).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/e2e-lib.sh"
CASES="home-merge ai-views health-tile render-scan launcher-in"
CASE=${1:-}; shift || true
case " $CASES " in *" $CASE "*) [ -n "$CASE" ] ;; *) false ;; esac || { echo "usage: board-look-home.sh ${CASES// /|} [--round R]"; exit 2; }
e2e_args "$@"
e2e_init "look-$CASE"
case $CASE in ai-views) e2e_setup inner ;; *) e2e_setup ;; esac

# verdict <"PASS ..."|"FAIL ..."|other>: a pass/fail line from a page's answer.
verdict() { case $1 in PASS*) pass "${1#PASS }" ;; FAIL*) fail "${1#FAIL }" ;; *) fail "no answer from the page: ${1:0:200}" ;; esac; }

# What a case changed, put back (idempotent; the EXIT trap runs it before e2e-lib's own restore).
EDITING=; AISCR0=; METER0=; LOPEN=
look_restore() {
  [ -n "$EDITING" ] && { ev 'importShim("./state.ts").then(s=>{s.selected.value=null;s.editing.value=false;return "ok"})' >/dev/null; EDITING=; log "edit mode left"; }
  [ -n "$AISCR0" ] && { ev "importShim('./state.ts').then(s=>{s.aiScreen.value='$AISCR0';return 'ok'})" >/dev/null; log "AI page tab back to $AISCR0"; AISCR0=; }
  [ -n "$METER0" ] && { ev "importShim('./bridge.ts').then(b=>b.powos.store.set('perf.meter',$METER0)).then(()=>'ok')" >/dev/null; log "perf.meter back to $METER0"; METER0=; }
  [ -n "$LOPEN" ] && { back 1; LOPEN=; log "launcher closed (Back)"; }
  return 0
}
trap 'rc=$?; look_restore; (exit $rc); e2e_abort' EXIT

if [ "$CASE" = home-merge ]; then
  # Folded (the task's portrait home): the cover state forced, handed back to the hinge by e2e_restore (FORCED).
  case $(device_state_set 0) in SKIP*) log "no cover screen on this lane: home as it is" ;; *) FORCED=1; sleep 2.5; chk fold ;; esac
  step home-folded "folded home, the user's layout as it is (read only)"
  # Pairs from home.get's cells (any page), faces from the DOM: stacked boxed tiles that touch (A's foot on B's row).
  PAIRS='importShim("./bridge.ts").then(b=>b.powos.home.get()).then(h=>{const boxed=i=>i.kind!=="app"&&i.kind!=="folder";
const it=h.items.filter(i=>boxed(i)&&i.cell),gap=parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--gap"))||8;
const el=k=>document.querySelector(`.home-tile[data-key="${CSS.escape(k)}"]`),face=t=>(t.querySelector(":scope > .tile")||t).getBoundingClientRect();
const out={eq:[],un:[],bad:[]};
for(const a of it)for(const b of it){if(a===b||a.page!==b.page||a.cell.y+a.cell.h!==b.cell.y)continue;
 if(a.cell.x+a.cell.w<=b.cell.x||b.cell.x+b.cell.w<=a.cell.x)continue;
 const ta=el(a.key),tb=el(b.key);if(!ta||!tb)continue;const fa=face(ta),fb=face(tb),between=Math.round(fb.top-fa.bottom);
 const n=(a.name||a.kind)+"/"+(b.name||b.kind);
 if(a.cell.x===b.cell.x&&a.cell.w===b.cell.w){out.eq.push(n);
  if(!(ta.classList.contains("joined")&&tb.classList.contains("joined")))out.bad.push(n+": equal width, not merged");
  else if(Math.abs(between)>1)out.bad.push(n+": equal width, "+between+" px between the faces")}
 else{out.un.push(n);if(Math.abs(between-gap)>1.5)out.bad.push(n+": unequal, "+between+" px between the faces, not the gap "+gap)}}
if(!out.eq.length&&!out.un.length)return "NOTE no stacked widgets on home to compare";
return (out.bad.length?"FAIL ":"PASS ")+(out.bad.length?out.bad.join("; ")+" | ":"")+"equal "+out.eq.length+" ["+out.eq.join(", ")+"], unequal "+out.un.length+" ["+out.un.join(", ")+"]"})'
  r=$(ev "$PAIRS"); log "merge: $r"
  case $r in NOTE*) note "${r#NOTE }" ;; *) verdict "$r" ;; esac
  chk "edit mode"
  # Edit mode by state, nothing moved: each widget with a tile above selected in turn, its pill against that tile.
  EDITING=1; ev 'importShim("./state.ts").then(s=>{s.editing.value=true;return "ok"})' >/dev/null; sleep 1.2
  PILL='(async()=>{const S=await importShim("./state.ts"),{powos}=await importShim("./bridge.ts"),h=await powos.home.get();
const boxed=i=>i.kind!=="app"&&i.kind!=="folder",it=h.items.filter(i=>i.cell),wait=ms=>new Promise(r=>setTimeout(r,ms));
const el=k=>document.querySelector(`.home-tile[data-key="${CSS.escape(k)}"]`),face=t=>(t.querySelector(":scope > .tile")||t).getBoundingClientRect();
const res=[],bad=[];
for(const b of it.filter(boxed)){const ups=it.filter(a=>a!==b&&a.page===b.page&&a.cell.y+a.cell.h===b.cell.y&&a.cell.x<b.cell.x+b.cell.w&&b.cell.x<a.cell.x+a.cell.w);
 if(!ups.length)continue;if(res.length>=6)break;
 S.selected.value=b.key;let p=null;for(let i=0;i<20&&!p;i++){await wait(50);p=el(b.key)?.querySelector(".tile-actions")}
 const n=b.name||b.kind;if(!p){bad.push(n+": no edit pill when selected");continue}
 const pr=p.getBoundingClientRect();
 for(const a of ups){const ta=el(a.key);if(!ta)continue;const f=face(ta);
  if(pr.top<f.bottom-0.5&&pr.bottom>f.top&&pr.left<f.right&&pr.right>f.left)bad.push(n+": pill (top "+Math.round(pr.top)+") over "+(a.name||a.kind)+" (ends "+Math.round(f.bottom)+")")}
 res.push(n)}
S.selected.value=null;
if(!res.length&&!bad.length)return "NOTE no widget with a tile above it";
return (bad.length?"FAIL "+bad.join("; ")+" | ":"PASS ")+"pills checked on "+res.length+": "+res.join(", ")})()'
  r=$(ev "$PILL"); log "pills: $r"
  step edit-mode "edit mode entered by state (no change made); pills checked per widget"
  case $r in NOTE*) note "${r#NOTE }" ;; *) verdict "$r" ;; esac
  look_restore; sleep 0.8
  [ "$(isediting)" = false ] && pass "edit mode left" || fail "home still in edit mode after leaving it"
fi

if [ "$CASE" = ai-views ]; then
  AISCR0=$(ev 'importShim("./state.ts").then(s=>String(s.aiScreen.value))'); [[ $AISCR0 =~ ^[a-z]+$ ]] || AISCR0=chat
  setpage -1; sleep 1.5; chk "ai page"
  tab() { ev "importShim('./state.ts').then(s=>{s.aiScreen.value='$1';return 'ok'})" >/dev/null; sleep 1.5; }
  tab fleet; [ "$(ev '!!document.querySelector(".ai-screen .ai-right .ag-row")')" = true ] || tab agents
  step ai-agents "the unfolded AI page's Agents tab"
  ROWBG=$(ev 'getComputedStyle(document.querySelector(".ai-screen .ai-right .ag-row")||document.body).backgroundColor')
  r=$(ev '(()=>{const R=".ai-screen .ai-right",rows=[...document.querySelectorAll(R+" .ag-rows .ag-row")];if(!rows.length)return "FAIL no agent rows on the Agents tab";
const bad=[],nm=r=>r.textContent.trim().slice(0,30);let bars=0;
if(document.querySelector(R+" .fl-card, "+R+" .fl-mgr"))bad.push("old agent cards still drawn");
for(const r of rows){const b=r.getBoundingClientRect();if(!r.matches(".aip-area.tile"))bad.push(nm(r)+": not a glass row");
 if(b.height>84)bad.push(nm(r)+": "+Math.round(b.height)+" px tall");
 const bar=r.querySelector(".aip-bar"),t=r.querySelector(".ag-row-title");if(bar&&t){bars++;const tb=t.getBoundingClientRect(),bb=bar.getBoundingClientRect();
  if(bb.top<tb.bottom-1)bad.push(nm(r)+": bar beside the title");if(tb.width<b.width*0.45)bad.push(nm(r)+": title "+Math.round(tb.width)+" of "+Math.round(b.width)+" px")}}
return (bad.length?"FAIL "+bad.join("; "):"PASS")+" | "+rows.length+" rows, "+bars+" with a bar"})()')
  log "agents: $r"; verdict "$r"
  chk devices; tab devices
  step ai-devices "the AI page's Devices tab"
  r=$(ev '(()=>{const R=".ai-screen .ai-right";if(!document.querySelector(R+" .ai-devices"))return "FAIL the Devices view did not draw";
const all=document.querySelectorAll(R+" .ai-devices .ai-unit-card").length,glass=document.querySelectorAll(R+" .ai-devices .ai-unit-card.aip-area.tile").length;
const bad=[];if(!glass)bad.push("no host card on the glass");if(glass<all)bad.push((all-glass)+" host cards not glass");if(document.querySelector(R+" .ai-work-list"))bad.push("the old boxed list");
return (bad.length?"FAIL "+bad.join("; "):"PASS")+" | "+glass+" glass host cards"})()')
  log "devices: $r"; verdict "$r"
  chk chat; tab chat
  step ai-chat "the AI page's Chat tab (the user's real conversation, read only)"
  r=$(ev "(()=>{const R='.ai-screen .ai-right .ai-chat-in',row='$ROWBG',bad=[],seen=[];
for(const s of ['.msg.assistant','.present']){const e=document.querySelector(R+' '+s);if(!e)continue;seen.push(s);const bg=getComputedStyle(e).backgroundColor;if(bg!==row)bad.push(s+' '+bg+', not the rows glass '+row)}
const c=document.querySelector(R+' .choice-opt');if(c){seen.push('chips');const rr=getComputedStyle(c).borderTopLeftRadius;if(rr!=='12px')bad.push('chip corners '+rr)}
for(const k of document.querySelectorAll(R+' .present .present-peek')){const c=getComputedStyle(k),m=c.maskImage||c.webkitMaskImage||'none';if(m!=='none')bad.push('a plan card peek faded out ('+m.slice(0,40)+')')}
if(!seen.length)return 'NOTE the chat has no manager bubble, card or chips to measure';
return (bad.length?'FAIL '+bad.join('; '):'PASS')+' | measured '+seen.join(', ')})()")
  log "chat: $r"
  case $r in NOTE*) note "${r#NOTE }" ;; *) verdict "$r" ;; esac
fi

if [ "$CASE" = health-tile ]; then
  st=$(hcall health.status "[]" "v=>JSON.stringify(v)"); log "health.status: $st"
  step home-health "home with the Health widget (read only)"
  r=$(ev "importShim('./bridge.ts').then(b=>b.powos.home.get()).then(h=>{const st=(()=>{try{return JSON.parse('${st//\'/}')}catch(e){return null}})();
const it=h.items.find(i=>i.kind==='panel'&&String(i.name||'').startsWith('app:local.health'));if(!it)return 'NOTE no Health widget on home';
const t=document.querySelector('.home-tile[data-key=\"'+CSS.escape(it.key)+'\"]');if(!t)return 'FAIL the Health widget item has no tile';
const box=t.getBoundingClientRect(),txt=(t.innerText||'').replace(/\\s+/g,' ').trim();
const linked=!!st&&st.state==='ok'&&(st.granted||[]).length>0;
const words=[...t.querySelectorAll('div')].find(d=>/^(Nothing ?today|Connect ?Health)$/.test((d.innerText||'').replace(/\\s+/g,' ').trim()));
const fill=words?Math.round(words.getBoundingClientRect().width/box.width*100):0,num=/[0-9]/.test(txt);
const what='linked '+linked+', tile '+Math.round(box.width)+'x'+Math.round(box.height)+', text \"'+txt.slice(0,60)+'\"';
if(!st)return 'FAIL health.status unreadable | '+what;
if(!linked)return (/Connect ?Health/.test(txt)?'PASS not linked: Connect Health':'FAIL not linked but no Connect Health')+' | '+what;
if(/Connect ?Health/.test(txt))return 'FAIL linked but still asks to Connect Health | '+what;
if(/Nothing ?today/.test(txt))return (fill>=70?'PASS Nothing today fills '+fill+'% of the tile':'FAIL Nothing today only '+fill+'% of the tile width')+' | '+what;
return (num?'PASS figures shown':'FAIL linked, neither figures nor Nothing today')+' | '+what})")
  log "health: $r"
  case $r in NOTE*) note "${r#NOTE }" ;; *) verdict "$r" ;; esac
fi

if [ "$CASE" = render-scan ]; then
  METER0=$(ev 'importShim("./bridge.ts").then(b=>b.powos.store.get("perf.meter")).then(v=>JSON.stringify(v??null))')
  case $METER0 in null|\{*) ;; *) METER0=; fail "perf.meter unreadable - rs not touched"; e2e_finish; exit 0 ;; esac
  log "perf.meter at start: $METER0"
  ev 'importShim("./bridge.ts").then(b=>b.powos.store.set("perf.meter",{on:true,renders:true})).then(()=>"ok")' >/dev/null; sleep 2
  # A re-render on each surface with its own real data (no made-up items): the shade/lock list again, the launcher opened.
  ev 'importShim("./bridge.ts").then(b=>b.powos.notifications.list()).then(l=>{window.__powosHost.emit("notifications.changed",l);return "ok"})' shade >/dev/null
  ev 'importShim("./bridge.ts").then(b=>b.powos.notifications.list()).then(l=>{window.__powosHost.emit("notifications.changed",l);return "ok"})' lock >/dev/null
  chk launcher; LOPEN=1; ev 'importShim("./state.ts").then(s=>{s.openPanel("apps");return "ok"})' >/dev/null; sleep 1.5
  step rs-on "rs on (perf.meter {on, renders}): the render overlay on every surface page; the launcher opened by code"
  pages=$("$T/cdp.sh" pages 2>/dev/null | awk '{print $1}' | tr '\n' ' '); log "pages: $pages"
  PROBE='importShim("./ui/renderoverlay.ts").then(O=>"on="+O.overlayOn()+" outlined="+O.overlayOutlined()+" canvas="+document.querySelectorAll("html > canvas").length).catch(e=>"err "+e)'
  for s in shade pull lock recents assist; do
    case " $pages " in *" $s "*) ;; *) note "$s: its page isn't up now (opened on demand) - not measured"; continue ;; esac
    v=$(ev "$PROBE" "$s"); log "$s: $v"
    case $v in on=true*canvas=[1-9]*) case $v in *outlined=0*) pass "$s: overlay up ($v), nothing re-rendered there yet" ;; *) pass "$s: overlay up and outlining ($v)" ;; esac ;;
      *) fail "$s: no render overlay with rs on ($v)" ;; esac
  done
  look_restore; sleep 1.5
  v=$(ev "$PROBE" shade); log "shade after restore: $v"
  case $METER0 in *'"on":true'*) note "rs was on at the start: left on" ;; *) case $v in on=false*) pass "rs back off: shade overlay gone" ;; *) fail "rs restored but the shade overlay is still up ($v)" ;; esac ;; esac
fi

if [ "$CASE" = launcher-in ]; then
  [ "$(isopen)" = true ] && { back 1; }
  # A sampler on both pages that can show the launcher (home in place, the pull overlay), then the open by code.
  SAMP='(()=>{const out=[];window.__lkIn=out;let t0=0,n=0;const f=()=>{const e=document.querySelector(".launcher-frame")||document.querySelector(".launcher-clip");
const p=e?parseFloat(getComputedStyle(e).getPropertyValue("--p"))||0:-1;const now=performance.now();if(!t0&&p>0.001)t0=now;if(t0)out.push([Math.round(now-t0),Math.round(p*1000)/1000]);
if((!t0||now-t0<300)&&++n<240)requestAnimationFrame(f)};requestAnimationFrame(f);return "ok"})()'
  ev "$SAMP" home >/dev/null; ev "$SAMP" pull >/dev/null
  chk launcher; LOPEN=1; ev 'importShim("./state.ts").then(s=>{s.openPanel("apps");return "ok"})' >/dev/null; sleep 1.5
  step launcher-open "the launcher opened by code (a tap's open): its frame/clip --p sampled every frame"
  for pg in home pull; do
    v=$(ev 'JSON.stringify(window.__lkIn||null)' "$pg"); log "$pg samples: ${v:0:400}"
    python3 - "$pg" "$v" <<'PY' > "$OUT/lk-$pg.txt"
import json, sys
pg, raw = sys.argv[1], sys.argv[2]
try: s = json.loads(raw)
except Exception: s = None
if not s: print("NONE"); sys.exit()
mid = [p for t, p in s if 0.05 < p < 0.95 and t <= 300]
first = s[0][1]
if mid: print(f"PASS {pg}: opens over {len(mid)} in-between frames in 300 ms (first {first}, at 300 ms {s[-1][1]})")
else: print(f"FAIL {pg}: popped - first frame at --p {first}, no in-between value in 300 ms: {s[:6]}")
PY
    r=$(cat "$OUT/lk-$pg.txt"); [ "$r" = NONE ] || { verdict "$r"; got=1; }
  done
  [ -n "${got:-}" ] || fail "the launcher's frame never left --p 0 on home or the pull page"
  r=$(ev '(()=>{const t=document.body.innerText||"",pages=document.querySelectorAll(".drawer-page").length,folders=document.querySelectorAll(".drawer-page .folder, .drawer-folders .folder").length;
return (/No folders yet/.test(t)||document.querySelector(".folder-empty")?"FAIL a No folders yet line":"PASS no No folders yet")+" | drawer pages "+pages+", folder cards "+folders})()')
  v=$(ev '/No folders yet/.test(document.body.innerText||"")' pull); [ "$v" = true ] && r="FAIL a No folders yet line on the pull page | $r"
  log "folders: $r"; verdict "$r"
fi

look_restore
e2e_finish
