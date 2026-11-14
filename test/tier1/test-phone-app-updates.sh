#!/usr/bin/env bash
# The phone's updates on the Linux side (11-14, razr: the desktop's update widget said "not a bootc deployment" and
# there was no way to update from it). A phone updates through the PowOS app; the app publishes its state in
# run/powos-updates.json and takes android-request's "update". Checked here:
#   1. lib/phone-app-updates.sh (`powos update status|now` on a phone): the state read back, a run asked for through
#      android-request (or the file it writes), refusals for an older app and a rooted phone;
#   2. the widget's data source (com.powos.updates statusCmd): on a phone it carries the app's state + powos-core, off
#      a phone those sections stay empty (the bootc path unchanged);
#   3. powos-core ships the widgets, so a fixed widget reaches a phone without a new base image.
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
pass=0; fail=0
ok()  { echo "  PASS: $*"; pass=$((pass+1)); }
bad() { echo "  FAIL: $*"; fail=$((fail+1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
S=$ROOT/lib/phone-app-updates.sh
mkdir -p "$T/run" "$T/bin"
cat > "$T/bin/android-request" <<'X'
#!/bin/sh
echo "$*" >> "$REQLOG"
X
cat > "$T/bin/pacman" <<'X'
#!/bin/sh
[ "$*" = "-Q powos-core" ] && echo "powos-core 3600.gabc-1"
X
chmod +x "$T/bin/"*
export REQLOG=$T/req.log
run() { env PATH="$T/bin:$PATH" POWOS_APP_RUN="$T/run" sh "$S" "$@"; }

# 1. status / now
out=$(run status 2>&1); rc=$?
[ "$rc" = 3 ] && ok "no state from the app: exit 3" || bad "no state: rc $rc ($out)"
now=$(( $(date +%s) * 1000 - 2 * 3600 * 1000 ))
printf '{"checking":false,"checked":%s,"error":null,"summary":"PowOS is up to date","app":"3.41.7","shell":"0123abcde","rooted":false,"via":"app","waiting":["the app: tap the PowOS update notification to install it"]}' "$now" > "$T/run/powos-updates.json"
out=$(run status)
for want in "app: *3.41.7" "home screen: *0123abcde" "linux: *powos-core 3600.gabc-1" "last check: *2h ago" "result: *PowOS is up to date" "waiting: *the app: tap"; do
  echo "$out" | grep -q "$want" && ok "status says /$want/" || bad "status lacks /$want/: $out"
done
[ "$(run status --json)" = "$(cat "$T/run/powos-updates.json")" ] && ok "status --json is the app's state as is" || bad "status --json differs"

out=$(run now 2>&1); rc=$?
{ [ "$rc" = 3 ] && [ ! -s "$REQLOG" ]; } && ok "an app without the update verb: exit 3, nothing asked" || bad "older app: rc $rc, asked: $(cat "$REQLOG" 2>/dev/null)"
printf 'wifi-panel\nopen\nupdate\n' > "$T/run/android-request.verbs"
out=$(run now); rc=$?
{ [ "$rc" = 0 ] && [ "$(cat "$REQLOG")" = "update now" ]; } && ok "now asks the app: android-request update now" || bad "now: rc $rc, asked '$(cat "$REQLOG" 2>/dev/null)' ($out)"
# Without the helper on PATH: the request file itself, as the helper writes it.
rm "$T/bin/android-request"; : > "$REQLOG"
env PATH="$T/bin:/usr/bin:/bin" POWOS_APP_RUN="$T/run" sh "$S" now >/dev/null
[ "$(cat "$T/run/android-request" 2>/dev/null)" = "update now" ] && ok "no helper: run/android-request = 'update now'" || bad "no helper: $(cat "$T/run/android-request" 2>/dev/null)"
sed -i.bak 's/"via":"app"/"via":"ship"/' "$T/run/powos-updates.json"
out=$(run now 2>&1); rc=$?
[ "$rc" = 4 ] && ok "a rooted phone: exit 4 (the ship service updates it)" || bad "rooted now: rc $rc ($out)"
run status | grep -q "ship service" && ok "rooted status names the ship service" || bad "rooted status: $(run status)"
sed -i.bak 's/"via":"ship"/"via":"app"/' "$T/run/powos-updates.json"

# `powos update status|now` on a phone go to the script (bin/powos's phone branch).
grep -q 'status) shift; sh "$POWOS_LIB/phone-app-updates.sh" status' "$ROOT/bin/powos" && grep -q 'now) sh "$POWOS_LIB/phone-app-updates.sh" now' "$ROOT/bin/powos" \
  && ok "powos update status|now -> phone-app-updates.sh on a phone" || bad "bin/powos doesn't route status/now on a phone"

# 2. the widget's data source, run as the widget runs it (its JS string evaluated by node), the platform file faked.
QML=$ROOT/desktop/plasmoid/com.powos.updates/contents/ui/main.qml
if command -v node >/dev/null; then
  cmd=$(node -e '
    const q = require("fs").readFileSync(process.argv[1], "utf8");
    const m = q.match(/readonly property string statusCmd:\n([\s\S]*?"\n)\n/);
    if (!m) process.exit(1);
    const srcDir = "/nonexistent";
    process.stdout.write(eval(m[1]));' "$QML") || bad "statusCmd not found in main.qml"
  cat > "$T/bin/powos" <<X
#!/bin/sh
[ "\$*" = "update status --json" ] && exec env POWOS_APP_RUN="$T/run" sh "$S" status --json
[ "\$1" = version ] && echo "PowOS version 3600"
X
  chmod +x "$T/bin/powos"
  section() { awk -v a="$2" -v b="$3" '$0==a{on=1;next} $0==b{on=0} on' <<<"$1" | sed '/^$/d'; }
  echo phone > "$T/platform"
  out=$(env PATH="$T/bin:$PATH" sh -c "${cmd//\/etc\/powos\/platform/$T/platform}" 2>/dev/null)
  [ "$(section "$out" __PLATFORM__ __PHONE__)" = phone ] && ok "widget source: the platform" || bad "widget source platform: $(section "$out" __PLATFORM__ __PHONE__)"
  [ "$(section "$out" __PHONE__ __CORE__)" = "$(cat "$T/run/powos-updates.json")" ] && ok "widget source: the app's state on a phone" || bad "widget source phone: $(section "$out" __PHONE__ __CORE__)"
  [ "$(section "$out" __CORE__ __VER__)" = "powos-core 3600.gabc-1" ] && ok "widget source: powos-core" || bad "widget source core: $(section "$out" __CORE__ __VER__)"
  echo desktop > "$T/platform"
  out=$(env PATH="$T/bin:$PATH" sh -c "${cmd//\/etc\/powos\/platform/$T/platform}" 2>/dev/null)
  { [ -z "$(section "$out" __PHONE__ __CORE__)" ] && [ -z "$(section "$out" __CORE__ __VER__)" ] && echo "$out" | grep -q '^__BOOTC__$'; } \
    && ok "widget source off a phone: no phone sections, the bootc path still there" || bad "widget source off a phone: $out"
  # The widget reads the phone and doesn't call a phone "not a bootc deployment".
  grep -q 'root.onPhone ? root.phoneLine()' "$QML" && ok "widget's line on a phone is the app's state" || bad "widget still shows the bootc line on a phone"
  grep -q 'runner.connectSource("powos update now' "$QML" && ok "widget's update now asks the app" || bad "widget has no phone update action"
else
  echo "  skip: no node (widget data source)"
fi

# 3. powos-core carries the widgets (QML only) to /usr/share/plasma/plasmoids: its PKGBUILD staged and package() run as
#    makepkg runs it (test-powos-core-claude-login.sh's way; a claude-login stand-in).
mkdir -p "$T/cl/dist" && echo 'x' > "$T/cl/dist/cli.js" && echo 'x' > "$T/cl/dist/index.js"
bash "$ROOT/test/tier1/fixtures/fake-composed.sh" "$T/comp"  # powos-core needs the composed build (test-powos-core-composed.sh)
if POWOS_CORE_COMPOSED="$T/comp" CLAUDE_LOGIN_DIR="$T/cl" CLAUDE_LOGIN_NO_CLONE=1 POWOS_CORE_STAGE="$T/w" "$ROOT/targets/android/build-powos-core.sh" > "$T/stage.log" 2>&1; then
  mkdir -p "$T/srcdir" "$T/pkgdir"
  tar -C "$T/srcdir" -xf "$T/w/powos-src.tar"; tar -C "$T/srcdir" -xf "$T/w/claude-login.tar"; tar -C "$T/srcdir" -xf "$T/w/composed.tar"; cp "$T/w/phone-files.sh" "$T/srcdir/"
  ( srcdir=$T/srcdir pkgdir=$T/pkgdir; . "$T/w/PKGBUILD" && package ) > "$T/pkg.log" 2>&1 || bad "package() failed: $(tail -3 "$T/pkg.log")"
  W=$T/pkgdir/usr/share/plasma/plasmoids/com.powos.updates
  { [ -s "$W/contents/ui/main.qml" ] && [ -s "$W/metadata.json" ]; } && ok "powos-core ships com.powos.updates to /usr/share/plasma/plasmoids" \
    || bad "powos-core doesn't ship the widgets (a phone keeps its base image's)"
else
  bad "build-powos-core.sh didn't stage: $(tail -3 "$T/stage.log")"
fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
