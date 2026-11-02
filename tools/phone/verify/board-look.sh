#!/bin/bash
# lanes: emu phone
# board-look.sh <case> [--round R]: small on-device checks of board tasks fixed in code (batch 66ce2612), each a
# read-only CDP measurement of what the user asked for on the real phone, unfolded, plus the e2e step screenshot.
# Opens surfaces by code (openPanel / the AI page), changes no setting; e2e-lib's setup/restore, touch abort (exit 3)
# and pill guard apply. Cases:
#   launcher-rows  (launcher-dock-only-on-the-app-grid-never-in-the, ef608c18): the unfolded launcher's app grid rows
#                  sit >= 24 px apart (a tile's foot to the next row's top) - launcher-fit-check.js LR1 on the device;
#   ai-board       (ai-page-work-board-adhd-friendly-grouped-by-what, 9b5162fc): the unfolded AI page has the work
#                  column left (.ai-left: ring, To do, By area, Working now, Recently done - in that order, whichever
#                  have content) and the chat right at ~44% (.ai-right); a plan card in the chat shows its title once
#                  and no faded peek.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/e2e-lib.sh"
CASE=${1:-}; shift || true
case "$CASE" in launcher-rows|ai-board) ;; *) echo "usage: board-look.sh launcher-rows|ai-board [--round R]"; exit 2 ;; esac
e2e_args "$@"
e2e_init "look-$CASE"
e2e_setup inner

# grid_gap <page>: the smallest gap between the open app grid's rows on that page, "none" without an open grid.
GAP='(()=>{const g=document.querySelector(".drawer-page > .drawer-list:not(.drawer-folders) > .grid");if(!g)return "none";
const t=[...g.querySelectorAll(":scope > .app")].map(e=>e.getBoundingClientRect()).filter(r=>r.height>0);
const rows=[...new Set(t.map(r=>Math.round(r.top)))].sort((a,b)=>a-b);if(rows.length<2)return "one-row";
let m=1e9;for(let i=1;i<rows.length;i++){const foot=Math.max(...t.filter(r=>Math.round(r.top)===rows[i-1]).map(r=>r.bottom));m=Math.min(m,rows[i]-foot)}
return String(Math.round(m*10)/10)+" rows="+rows.length+" wide="+!!document.querySelector(".home.wide")})()'

if [ "$CASE" = launcher-rows ]; then
  ev 'importShim("./state.ts").then(s=>{s.openPanel("apps");return "ok"})' >/dev/null; sleep 1.5; chk launcher
  step launcher "the unfolded launcher's app grid (opened by code: the row spacing is what's checked)"
  g=; pg=
  for p in pull home; do v=$("$T/cdp.sh" eval "$p" "$GAP" 2>/dev/null | tr -d '"\\\r' | tail -1); log "$p: $v"
    case $v in [0-9]*) g=$v; pg=$p; break ;; esac; done
  if [ -z "$g" ]; then fail "no open app grid with two rows on the pull or home page"
  else gap=${g%% *}
    awk -v x="$gap" 'BEGIN{exit !(x >= 23.5)}' && pass "rows $gap px apart ($pg: $g)" || fail "rows only $gap px apart, want 24 ($pg: $g)"
  fi
  back 1
fi

if [ "$CASE" = ai-board ]; then
  setpage -1; sleep 1.5; chk "ai page"
  step ai-page "the unfolded PowOS AI page: the work board left, the chat right"
  f=$(ev '(()=>{const l=document.querySelector(".ai-left"),r=document.querySelector(".ai-right");if(!l||!r)return JSON.stringify({l:!!l,r:!!r});
  const a=l.getBoundingClientRect(),b=r.getBoundingClientRect(),txt=l.innerText||"";
  const at=["To do","By area","Working now","Recently done"].map(w=>[w,txt.indexOf(w)]);
  const c=r.querySelector(".present");
  return JSON.stringify({l:true,r:true,left:a.left<b.left,share:Math.round(b.width/(a.width+b.width)*100),ring:!!l.querySelector("svg circle, .ring, [class*=ring]"),at,
  plan:c?{titles:(c.querySelector("h1,h2,h3,.present-title")?1:0)+0,dup:(()=>{const h=c.querySelector("h1,.present-title");return h?(c.textContent.split(h.textContent.trim()).length-1):0})(),fade:!!c.querySelector(".present-peek")}:null})})()')
  log "facts: $f"
  python3 - "$f" <<'PY' > "$OUT/ai.txt"
import json, sys
try: f = json.loads(sys.argv[1])
except Exception: print("FAIL no answer from the AI page: " + sys.argv[1][:200]); sys.exit()
bad = []
if not (f.get("l") and f.get("r")): bad.append("no .ai-left/.ai-right (not the unfolded AI page?)")
else:
    if not f["left"]: bad.append("the work column isn't left of the chat")
    if not 38 <= f["share"] <= 50: bad.append(f"chat takes {f['share']}% (want ~44)")
    seen = [i for w, i in f["at"] if i >= 0]
    if seen != sorted(seen): bad.append(f"sections out of order: {f['at']}")
    if not any(i >= 0 for w, i in f["at"]): bad.append("none of To do / By area / Working now / Recently done shown")
    p = f.get("plan")
    if p and (p["dup"] > 1 or p["fade"]): bad.append(f"plan card: title x{p['dup']}, fade {p['fade']}")
print(("FAIL " + "; ".join(bad)) if bad else f"PASS chat {f['share']}%, sections {f['at']}, ring {f['ring']}, plan {f.get('plan')}")
PY
  r=$(cat "$OUT/ai.txt"); case $r in PASS*) pass "${r#PASS }" ;; *) fail "${r#FAIL }" ;; esac
fi

e2e_finish
