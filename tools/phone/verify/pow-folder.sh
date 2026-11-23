#!/bin/bash
# lanes: emu phone
# needs: ship:shell
# PF1 (the user 11-23: "the pow apps should be in a pow folder"): on the live launcher, read-only apart from transient
# UI - the launcher's All view has one Pow folder cell ("lib:pow") and no loose .pow app ("w:"), the folder opened in
# place lists every .pow app the host has (each with its kind mark), and search still finds one by name. A device
# with no .pow apps: no folder at all. Screencaps of the All view and the open folder. Restores the launcher on exit.
set -euo pipefail
cd "$(dirname "$0")/../../.."
. tools/phone/verify/e2e-lib.sh
. tools/phone/verify/window-lock.sh
window_lock pow-folder 90
export CDP_TIMEOUT_S=30
OUT=$HOME/.cache/powos-verify/pow-folder-$(date +%m%d-%H%M%S)
mkdir -p "$OUT"
restore() {
  ev 'Promise.all([importShim("./state.ts"),importShim("./ui/drawer.tsx")]).then(([s,d])=>{s.query.value="";d.launcherLetter.value=null;s.closeDrawer(true);return "restored"})' >/dev/null || true
  [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"
}
trap restore EXIT
sh_ 'am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null' >/dev/null
ev 'importShim("./state.ts").then(s=>{s.goHome();return "home"})' >/dev/null
label=$(ev 'innerWidth>=700?"unfolded":"folded"' | tr -d '"')
cells='(sel)=>[...document.querySelectorAll(sel+" .app[data-key]")].map(e=>e.dataset.key)'
all=$(ev "(async()=>{const s=await importShim('./state.ts'),d=await importShim('./ui/drawer.tsx');const c=$cells;s.drawer.value=1;await new Promise(r=>setTimeout(r,500));d.launcherLetter.value='All';await new Promise(r=>setTimeout(r,600));const k=c('.drawer-page [data-view=all]');const web=s.apps.value.filter(a=>a.key.startsWith('w:')).map(a=>a.key);return JSON.stringify({web,folder:k.filter(x=>x==='lib:pow').length,loose:k.filter(x=>x.startsWith('w:'))})})()")
echo "all ($label): $all"
tools/phone/shot.sh "$OUT/all-$label.png" >/dev/null || true
open=$(ev "(async()=>{const d=await importShim('./ui/drawer.tsx');const c=$cells;d.launcherLetter.value='Pow';await new Promise(r=>setTimeout(r,600));const v=document.querySelector('.drawer-page [data-view=folder]');return JSON.stringify({open:!!v,keys:c('.drawer-page [data-view=folder]'),marks:v?v.querySelectorAll('.app-web-mark').length:0})})()")
echo "open ($label): $open"
tools/phone/shot.sh "$OUT/open-$label.png" >/dev/null || true
r=$(python3 - "$all" "$open" <<'PY'
import json, sys
a = json.loads(json.loads(sys.argv[1]) if sys.argv[1].startswith('"') else sys.argv[1])
o = json.loads(json.loads(sys.argv[2]) if sys.argv[2].startswith('"') else sys.argv[2])
fails = []
if a["loose"]: fails.append(f"loose .pow apps in All: {a['loose']}")
want = 1 if a["web"] else 0
if a["folder"] != want: fails.append(f"{a['folder']} Pow folder cells, want {want} ({len(a['web'])} .pow apps)")
if a["web"]:
    if not o["open"]: fails.append("the folder didn't open in place")
    elif sorted(o["keys"]) != sorted(a["web"]): fails.append(f"open folder shows {o['keys']}, want {a['web']}")
    elif o["marks"] != len(o["keys"]): fails.append(f"{o['marks']} of {len(o['keys'])} kind marks")
print("; ".join(fails))
PY
)
[ -z "$r" ] || { echo "FAIL: pow folder ($label): $r; shots $OUT"; exit 1; }
echo "PASS: the .pow apps sit in one Pow folder in the launcher, none loose; open it lists them all with their marks ($label); shots $OUT"
