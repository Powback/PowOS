#!/bin/bash
# lanes: phone
# nonroot-appmaking.sh (gh#13, board no-root-phone-making-a-powos-app-widget-end-to-e; the owner 11-10: "make sure the
# app and widget creation etc works properly with the nonrooted version" + "what about the webapps with spacetimedb
# etc?"): the whole making flow on the UNROOTED phone (the razr fold, the Mac's own adb: RAZR=<serial>, default the
# mdns name adb-ZY22MQL54Q), each step run inside PowOS's image exactly as the PowOS app runs a guest program
# (run-as com.powos.app + liblotfixrun.so -c, SessionService.guestProcess's environment):
#   base     the image's base holds what making apps needs (spacetime, bun; phone-base-sync.py names nothing missing)
#   widget   a UI-only island (no module): build --ui, install into files/apps (home's edit sheet lists it), remove
#   preview  `powos app preview` (a widget's .preview/ sheets) - known gap without docker: reported, not failed
#   new      powos app new (module + page + widget)
#   module   build the Rust module: with the dev pack's toolchain (TOOLCHAIN=1 = the operator's yes to adding the pack,
#            ~0.3 GB once) or a builder (`powos app builder` set in the image); otherwise NEEDS-TOOLCHAIN
#   install  module published to the device's SpacetimeDB, the UI in files/apps, powos-registry lists the app
#   stdb     a reducer call lands in the table; a subscription sees it live; an anonymous identity can't write the
#            table by SQL (one DB per app: other apps go through reducers/subscriptions/appcap only); the registry
#            itself can't be written by SQL either
#   persist  the row survives SpacetimeDB's restart (RESTART=1: force-stops PowOS and starts it again = an app +
#            session restart; default off - it ends the user's session)
#   appapi   the App API (3411) answers through the private loopback socket
#   edit     a page edit -> `powos app ui` -> the installed bundle has it (the shell hot-reloads files/apps); a module
#            edit -> `powos app publish` -> the data is kept
#   cleanup  both removed again (app, widget, the app's database)
# Prints "CASE <name> PASS|FAIL|NEEDS-BASE|NEEDS-TOOLCHAIN|GAP <detail>" per step, then a verdict. PROBE=1: only the
# read-only probe (base + capabilities), nothing created.
# Exit 0 = every case passed; 1 = a FAIL; 5 = SKIP (no razr / rooted / PowOS image not installed) or only NEEDS-*.
# Queue: tools/phone/verify/nonroot-appmaking.sh (from the Mac; not the rooted verify queue - like nonroot-ports.sh).
set -u
ADB=${ADB:-$HOME/Library/Android/sdk/platform-tools/adb}
S=${RAZR:-$("$ADB" devices | awk '/adb-ZY22MQL54Q.*device$/{print $1; exit}')}
[ -n "$S" ] || { echo "SKIP: ENV: the razr isn't on the Mac's adb (adb mdns services)"; exit 5; }
sh_() { perl -e 'alarm 900; exec @ARGV' "$ADB" -s "$S" shell "$@" | tr -d '\r'; }
[ "$(sh_ 'su -c id 2>/dev/null | grep -c uid=0')" = 1 ] && { echo "SKIP: $S is rooted - this check is for the unrooted path"; exit 5; }
LIBDIR=$(sh_ 'cmd package path com.powos.app' | sed -n 's#^package:\(.*\)/base.apk$#\1/lib/arm64#p' | head -1)
[ -n "$LIBDIR" ] || { echo "SKIP: ENV: PowOS isn't installed on $S"; exit 5; }
sh_ "run-as com.powos.app test -x files/rootfs/usr/bin/powos" || { echo "SKIP: ENV: PowOS's Linux image isn't installed on $S"; exit 5; }

# The in-image part (bash, in PowOS's image): pushed to the app's files/tmp, removed afterwards.
read -r -d '' INNER <<'IN'
set -u
ID=local.nrcheck W=local.nrcheck-w D=/tmp/nrcheck DW=/tmp/nrcheck-w
APPS=$HOME/.local/share/powos/apps
c() { echo "CASE $1 $2 ${3:-}"; }
stdb=$(command -v spacetime || true)
miss=""; [ -f /usr/lib/powos/phone-base-sync.py ] && miss=$(python3 /usr/lib/powos/phone-base-sync.py 2>/dev/null | tr '\n' ' ')
if [ -n "$stdb" ] && command -v bun >/dev/null && [ -z "$miss" ]; then c base PASS "spacetime + bun in the base"
else c base NEEDS-BASE "spacetime: ${stdb:-missing}; base-sync names: ${miss:-n/a (powos-core without phone-base-sync.py)} - powos update (the base step)"; fi
powos app check 2>&1 | sed -n '1,7s/^/  check: /p'
[ "${PROBE:-0}" = 1 ] && exit 0
cleanup() { powos app remove "$ID" --data >/dev/null 2>&1; powos app remove "$W" >/dev/null 2>&1; rm -rf "$D" "$DW"; }
cleanup

# widget: a UI-only island
mkdir -p "$DW/ui/widgets"
printf '{ "id": "%s", "name": "NR check widget", "version": "0.1.0", "ui": { "dir": "out/ui/" }, "module": null,\n  "widgets": [ { "id": "main", "name": "NR check", "kind": "island", "entry": "widgets/main.js", "size": "2x2", "minSize": "2x1" } ] }\n' "$W" > "$DW/powos-app.json"
echo 'export default function () { return <div style={{ padding: 8 }}>nrcheck widget</div>; }' > "$DW/ui/widgets/main.tsx"
if out=$(powos app install "$DW" 2>&1) && [ -f "$APPS/$W/current/ui/widgets/main.js" ]; then c widget PASS "built + installed into files/apps"
else c widget FAIL "$(echo "$out" | tail -2 | tr '\n' ' ')"; fi
if out=$(powos app preview "$DW" 2>&1); then c preview PASS "sheets in $DW/out/preview"
else c preview GAP "$(echo "$out" | tail -1) (gh#13 W3: no .preview without docker)"; fi

# new -> module -> install
if out=$(powos app new nrcheck --name "NR check" --dir "$D" 2>&1); then c new PASS "$D"; else c new FAIL "$out"; fi
[ "${TOOLCHAIN:-0}" = 1 ] && export POWOS_APP_ADD_TOOLCHAIN=1
t0=$(date +%s)
if out=$(powos app build "$D" </dev/null 2>&1); then c module PASS "built in $(( $(date +%s) - t0 )) s ($(powos app builder 2>&1 | head -1))"
elif echo "$out" | grep -q "needs a toolchain"; then c module NEEDS-TOOLCHAIN "dev pack not added (TOOLCHAIN=1 adds it) and no builder"
else c module FAIL "$(echo "$out" | tail -3 | tr '\n' ' ')"; fi
if [ -z "$stdb" ]; then
  for k in install stdb persist edit; do c $k NEEDS-BASE "no SpacetimeDB in this image's base"; done
elif [ ! -f "$D/out/module.wasm" ]; then
  for k in install stdb persist edit; do c $k NEEDS-TOOLCHAIN "no module.wasm"; done
else
  DB=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["module"]["database"])' "$D/powos-app.json")
  q() { spacetime sql -s http://127.0.0.1:3410 "$@" 2>&1; }
  if out=$(powos app install "$D" 2>&1) && q powos-registry "SELECT id FROM app WHERE id = '$ID'" | grep -q "$ID" &&
     [ -d "$APPS/$ID/current" ]; then c install PASS "DB $DB published, UI in files/apps, registry lists $ID"
  else c install FAIL "$(echo "$out" | tail -2 | tr '\n' ' ')"; fi
  # live subscription + reducer
  sub=/tmp/nrcheck.sub; rm -f "$sub"
  ( spacetime subscribe -s http://127.0.0.1:3410 "$DB" "SELECT * FROM entry" -n 2 -t 20 -y > "$sub" 2>&1 & )
  sleep 2
  spacetime call -s http://127.0.0.1:3410 "$DB" add '"nrcheck-row"' >/dev/null 2>&1
  sleep 3
  rows=$(q "$DB" "SELECT text FROM entry")
  anon=$(spacetime sql --anonymous -s http://127.0.0.1:3410 "$DB" "INSERT INTO entry (id, text, done, at, module) VALUES (999, 'x', false, '2026-11-10T00:00:00Z', 'x')" 2>&1)
  reg=$(spacetime sql --anonymous -s http://127.0.0.1:3410 powos-registry "DELETE FROM app WHERE id = '$ID'" 2>&1)
  if echo "$rows" | grep -q nrcheck-row && grep -q nrcheck-row "$sub" 2>/dev/null &&
     ! q "$DB" "SELECT id FROM entry WHERE id = 999" | grep -qw 999 && q powos-registry "SELECT id FROM app WHERE id = '$ID'" | grep -q "$ID"
  then c stdb PASS "reducer -> table, subscription live, anonymous SQL writes refused (app DB + registry)"
  else c stdb FAIL "rows: $(echo "$rows" | tr '\n' ' ' | head -c 120) sub: $(head -c 160 "$sub" 2>/dev/null | tr '\n' ' ') anon: $(echo "$anon $reg" | head -c 160)"; fi
  echo "$D" > /tmp/nrcheck.persist
  # edit -> rebuild -> live update (UI), and a module republish keeps the data
  echo 'export const nrcheckEdit = "nrcheck-edit";' >> "$D/ui/pages/main.tsx"   # an entry's export survives bundling
  sed -i 's/^version = "0.1.0"/version = "0.1.1"/' "$D/module/Cargo.toml"
  if powos app ui "$D" >/dev/null 2>&1 && grep -rqs nrcheck-edit "$APPS/$ID/current/ui" &&
     powos app publish "$D" >/dev/null 2>&1 && q "$DB" "SELECT text FROM entry" | grep -q nrcheck-row
  then c edit PASS "page edit live in files/apps; module republished, data kept"
  else c edit FAIL "ui/publish after an edit"; fi
fi
IN
read -r -d '' AFTER <<'IN'
set -u
D=$(cat /tmp/nrcheck.persist 2>/dev/null)
if [ -n "$D" ]; then
  DB=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["module"]["database"])' "$D/powos-app.json")
  for i in $(seq 1 60); do spacetime sql -s http://127.0.0.1:3410 "$DB" "SELECT text FROM entry" 2>/dev/null | grep -q nrcheck-row && break; sleep 2; done
  spacetime sql -s http://127.0.0.1:3410 "$DB" "SELECT text FROM entry" 2>/dev/null | grep -q nrcheck-row &&
    echo "CASE persist PASS the row is back after PowOS + its session restarted" || echo "CASE persist FAIL no row after the restart"
fi
r=$(curl -s -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:3411/ 2>/dev/null)
case $r in 2*|4*) echo "CASE appapi PASS 127.0.0.1:3411 answers ($r) over the private socket" ;;
  *) [ -n "$(command -v spacetime)" ] && echo "CASE appapi FAIL no answer on 3411 ($r)" || echo "CASE appapi NEEDS-BASE the App API starts with the image's services ($r)" ;; esac
powos app remove local.nrcheck --data >/dev/null 2>&1; powos app remove local.nrcheck-w >/dev/null 2>&1
rm -rf /tmp/nrcheck /tmp/nrcheck-w /tmp/nrcheck.sub /tmp/nrcheck.persist
[ -e "$HOME/.local/share/powos/apps/local.nrcheck" ] || [ -e "$HOME/.local/share/powos/apps/local.nrcheck-w" ] &&
  echo "CASE cleanup FAIL an app dir is left" || echo "CASE cleanup PASS app, widget and the app's database removed"
IN

# One guest run: the script on run-as's stdin (nothing written to the phone), lotfix runs bash with the session's env.
guest() {
  printf '%s\n' "$2" | perl -e 'alarm 900; exec @ARGV' "$ADB" -s "$S" shell -T "run-as com.powos.app env L=$LIBDIR PROBE=${PROBE:-0} TOOLCHAIN=${TOOLCHAIN:-0} sh -c '
    F=/data/user/0/com.powos.app/files; R=\$F/run
    export ARCH_ROOTFS=\$F/rootfs XDG_RUNTIME_DIR=\$R ARCH_EXCLUDE_EXTRA=\$R:/storage:/sdcard:\$F/widgets:\$F/apps TERM=dumb \
      LANG=en_US.UTF-8 ANDROMARCHY_UID=\$(id -u) ANDROMARCHY_GID=\$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=\$R/bus HOME=/root \
      POWOS_LOOPBACK_DIR=\$R/loopback POWOS_LOOPBACK_PORTS=3410,3411,5037,loopback POWOS_LOOPBACK_PRELOAD=\$L/libpowosloopback.so
    exec \$L/liblotfixrun.so -c \"bash -s\"'" | tr -d '\r'
}

out=$(guest main "$INNER"); echo "$out"
if [ "${PROBE:-0}" != 1 ]; then
  if [ "${RESTART:-0}" = 1 ] && grep -q '^CASE stdb PASS' <<<"$out"; then
    sh_ 'am force-stop com.powos.app; monkey -p com.powos.app -c android.intent.category.HOME 1 >/dev/null 2>&1' >/dev/null
    sleep 20
  elif ! grep -q '^CASE stdb PASS' <<<"$out"; then :
  else echo "CASE persist GAP RESTART=1 restarts PowOS (ends the session) - not run"; fi
  out2=$(guest after "$AFTER"); echo "$out2"; out="$out"$'\n'"$out2"
fi
cases=$(grep '^CASE ' <<<"$out")
n() { grep -c "^CASE [a-z]* $1" <<<"$cases"; }
summary="$(n PASS) pass, $(n FAIL) fail, $(n NEEDS-BASE) need the base update, $(n NEEDS-TOOLCHAIN) need the toolchain, $(n GAP) known gaps"
[ "$(n FAIL)" -gt 0 ] && { echo "FAIL: $summary"; exit 1; }
[ "${PROBE:-0}" = 1 ] && { echo "PROBE: $summary"; exit 0; }
[ "$(n NEEDS-BASE)" -gt 0 ] || [ "$(n NEEDS-TOOLCHAIN)" -gt 0 ] && { echo "SKIP: $summary"; exit 5; }
echo "PASS: $summary"
