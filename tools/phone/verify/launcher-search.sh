#!/bin/bash
# lanes: emu phone
# needs: ship:apps
# Navigation only: settings deep links, provider races, keyboard submit, and real AppAPI catalog.
set -euo pipefail
cd "$(dirname "$0")/../../.."
. tools/phone/verify/e2e-lib.sh
. tools/phone/verify/window-lock.sh
window_lock launcher-search 120
export CDP_TIMEOUT_S=30
OUT=$HOME/.cache/powos-verify/launcher-search-$(date +%m%d-%H%M%S)
mkdir -p "$OUT"
top=$(sh_ 'dumpsys activity activities | grep -m1 topResumedActivity')
top_task=$(sed -nE 's/.* t([0-9]+)\}.*/\1/p' <<<"$top")
case "$top" in *HomeShell*|*HomeDesktop*|*PowosLock*|"") top_task= ;; esac
restore() {
  ev 'Promise.all([importShim("./state.ts"),importShim("./screens.ts"),importShim("./apps/pages.ts")]).then(([s,p,a])=>{s.closeDrawer();p.closeScreens();a.closeApp();return "restored"})' >/dev/null || true
  [ -z "$top_task" ] || hcall tasks.open "[$top_task]" "()=>'ok'" >/dev/null || true
  [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"
}
trap restore EXIT
sh_ 'am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null' >/dev/null
ev 'importShim("./state.ts").then(s=>{s.goHome();return "home"})' >/dev/null
code=$(sed 's/^export async function/async function/' shell/dev/search-check.js)
r=$(ev "(async()=>{$code;return JSON.stringify(await launcherSearchCheck())})()")
echo "search checks: $r"
[ "$r" = '[]' ] || { echo 'FAIL: launcher search navigation'; exit 1; }
ev 'importShim("./state.ts").then(s=>{s.drawer.value=1;s.query.value="dock position";return "search"})' >/dev/null
sleep 1
tools/phone/shot.sh "$OUT/settings-search.png" >/dev/null
r=$(ev '(async()=>{const s=await importShim("./state.ts");const a=await importShim("./apps/pages.ts");if(!a.installedApps.value.some(x=>x.id==="local.app-api"))return "no-app-api";const n=await importShim("./apps/net.ts");const r=await n.net.fetch("local.app-api","http://127.0.0.1:3411/apps");const app=r.json().apps.find(a=>a.enabled&&Object.values(a.actions||{}).some(x=>x.enabled!==false));if(!app)return "empty-catalog";const id=Object.keys(app.actions).find(id=>app.actions[id].enabled!==false);s.query.value=id.replace(/[_.-]/g," ");const q=await importShim("./search.ts");for(let i=0;i<60;i++){const hit=q.searchResults.value.find(r=>r.id===`app-api:${app.app}:${id}`);if(hit){q.openSearchResult(hit);return "opened"}await new Promise(r=>setTimeout(r,100))}return "missing-result"})()')
echo "AppAPI search: $r"
[ "$r" = opened ] || { echo 'FAIL: real AppAPI search'; exit 1; }
r=$(ev '(async()=>{for(let i=0;i<60;i++){if([...document.querySelectorAll(".app-screen button")].some(b=>b.textContent.trim()==="Dry run"))return "expanded";await new Promise(r=>setTimeout(r,100))}return "not-expanded"})()')
[ "$r" = expanded ] || { echo 'FAIL: selected AppAPI action did not expand'; exit 1; }
tools/phone/shot.sh "$OUT/app-api-result.png" >/dev/null
echo "PASS: settings targets, Enter, stale responses and real AppAPI result; shots $OUT"
