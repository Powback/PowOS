#!/bin/bash
# lanes: emu phone
# Native settings search must open Android's page, without changing any setting.
set -euo pipefail
cd "$(dirname "$0")/../../.."
. tools/phone/verify/e2e-lib.sh
. tools/phone/verify/window-lock.sh
window_lock native-settings-search 120
export CDP_TIMEOUT_S=30
OUT=$HOME/.cache/powos-verify/native-settings-search-$(date +%m%d-%H%M%S)
mkdir -p "$OUT"
top=$(sh_ 'dumpsys activity activities | grep -m1 topResumedActivity')
top_task=$(sed -nE 's/.* t([0-9]+)\}.*/\1/p' <<<"$top")
case "$top" in *HomeShell*|*HomeDesktop*|*PowosLock*|"") top_task= ;; esac
restore() {
  sh_ 'am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null' >/dev/null || true
  ev 'importShim("./state.ts").then(s=>{s.closeDrawer();s.query.value="";return "restored"})' >/dev/null || true
  [ -z "$top_task" ] || hcall tasks.open "[$top_task]" "()=>\"ok\"" >/dev/null || true
  [ "${LOCK_HELD:-0}" = 1 ] || rmdir "$L" 2>/dev/null || true
}
trap restore EXIT
sh_ 'am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null' >/dev/null
r=$(ev '(async()=>{const s=await importShim("./state.ts"),q=await importShim("./search.ts");s.goHome();s.drawer.value=1;s.query.value="vpn";for(let i=0;i<60;i++){if(q.searchResults.value.some(r=>r.id==="android-settings:settings:VPN_SETTINGS"))return "found";await new Promise(r=>setTimeout(r,100))}return "missing"})()')
[ "$r" = found ] || { echo "FAIL: native VPN search $r"; exit 1; }
tools/phone/shot.sh "$OUT/vpn-search.png" >/dev/null
ev 'importShim("./search.ts").then(q=>{q.openSearchResult(q.searchResults.value.find(r=>r.id==="android-settings:settings:VPN_SETTINGS"));return "opened"})' >/dev/null
sleep 2
r=$(sh_ 'dumpsys activity activities | grep -E "topResumedActivity|mResumedActivity"')
echo "$r"
[[ "$r" == *com.android.settings* ]] || { echo 'FAIL: Android settings is not foreground'; exit 1; }
# Confirm the action actually launched, not merely the generic Settings root.
r=$(sh_ 'dumpsys activity activities | grep "act=android.settings.VPN_SETTINGS"')
[ -n "$r" ] || { echo 'FAIL: VPN settings intent not in activity stack'; exit 1; }
tools/phone/shot.sh "$OUT/vpn-page.png" >/dev/null
echo "PASS: native VPN result opens Android settings; screenshots $OUT"
