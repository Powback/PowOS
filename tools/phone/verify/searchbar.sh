#!/bin/bash
# lanes: emu phone
# needs: ship:shell
# SP1/SE1 (the user 11-23): home -> search reuses home's bar (same nodes, home's face, no animation in), and the search's
# edit menu ("show as dock button") only in edit mode - the gate's dev/searchbar-check.js, run in the live home page,
# with the screen in use (folded or unfolded). Restores home (drawer closed, edit mode off, menu closed) on exit.
set -euo pipefail
cd "$(dirname "$0")/../../.."
. tools/phone/verify/e2e-lib.sh
. tools/phone/verify/window-lock.sh
window_lock searchbar 90
export CDP_TIMEOUT_S=30
OUT=$HOME/.cache/powos-verify/searchbar-$(date +%m%d-%H%M%S)
mkdir -p "$OUT"
restore() {
  ev 'Promise.all([importShim("./state.ts"),importShim("./ui/searchwidget.tsx")]).then(([s,w])=>{w.spotMenu.value=null;s.editing.value=false;s.searchTry.value="";s.closeDrawer();return "restored"})' >/dev/null || true
  [ "${LOCK_HELD:-0}" = 1 ] || rm -rf "$L"
}
trap restore EXIT
sh_ 'am start -W -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null' >/dev/null
ev 'importShim("./state.ts").then(s=>{s.goHome();return "home"})' >/dev/null
code=$(sed 's/^export async function/async function/' shell/dev/searchbar-check.js)
label=$(ev 'innerWidth>=700?"unfolded":"folded"' | tr -d '"')
r=$(ev "(async()=>{$code;return JSON.stringify([...(await barPersists('$label')),...(await editOnly('$label'))])})()")
echo "searchbar ($label): $r"
tools/phone/shot.sh "$OUT/home-$label.png" >/dev/null || true
[ "$r" = '[]' ] || { echo "FAIL: search bar ($label): $r"; exit 1; }
echo "PASS: home -> search keeps the bar (same nodes, no animation); its edit menu only in edit mode ($label); shot $OUT"
