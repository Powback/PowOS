#!/bin/bash
# lanes: emu phone
# bar-same-rect.sh (board home-search-bar-sits-at-the-same-height-as-the-m; the user, 11-03: "the same height as the
# manager search bar"): on the device, home's search bar pill and PowOS AI's page chat bar pill must be the same rect
# (x, y, width, height within TOL px). Switches home's page to the AI page and back over CDP (state.ts page -1 / 0,
# like the gate's barFootSame), no touch, restores the page it found. Prints the screen mode (folded/unfolded) - queue
# it once per screen (--screen cover / --screen inner).
set -u
cd "$(dirname "$0")/../../.." || exit 5
TOL=${TOL:-2}
js='(async()=>{const S=await importShim("./state.ts");const old=S.page.value,scr=S.aiScreen?.value;const w=ms=>new Promise(x=>setTimeout(x,ms));
const r=()=>{const p=document.querySelector(".bar[data-role] .bar-pill");if(!p)return null;const b=p.getBoundingClientRect();return [b.left,b.top,b.width,b.height].map(Math.round)};
S.page.value=0;await w(1200);const home=r();if(S.aiScreen)S.aiScreen.value="chat";S.page.value=-1;await w(1200);const ai=r();
S.page.value=old;if(S.aiScreen&&scr)S.aiScreen.value=scr;return JSON.stringify({mode:S.dockMode?.value,home,ai})})()'
out=$(tools/phone/cdp.sh eval home "$js" 2>&1 | tr -d '\\' | tail -1)
echo "bar-same-rect: $out"
python3 - "$TOL" "$out" <<'PY'
import sys,json,re
tol=int(sys.argv[1]); m=re.search(r"\{.*\}",sys.argv[2])
if not m: print("SKIP: ENV: no CDP answer from home"); sys.exit(5)
d=json.loads(m[0]); h,a=d.get("home"),d.get("ai")
if not h or not a: print(f"FAIL: no bar pill on {'home' if not h else 'the AI page'} ({d})"); sys.exit(1)
diff=[f"{k} {x}->{y}" for k,x,y in zip("x y w h".split(),h,a) if abs(x-y)>tol]
if diff: print(f"FAIL [{d.get('mode')}]: the AI page's bar isn't home's rect: "+", ".join(diff)+f" (home {h}, AI {a})"); sys.exit(1)
print(f"PASS [{d.get('mode')}]: home's bar and the AI page's chat bar are the same rect {h} (tol {tol} px)")
PY
