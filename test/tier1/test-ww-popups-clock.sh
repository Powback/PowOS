#!/bin/bash
# test-ww-popups-clock.sh: tools/phone/verify/ww-popups.sh always ends in a verdict inside its budget (11-08 16:46: its
# menu-bar scan took ~11 s a tap, two X reads over user.sh each, and the queue killed it at 300 s with no verdict; the
# kill then printed "xargs: /bin/echo: terminated with signal 13" from a `comm | xargs` in its exit trap).
# The check runs here against a fake phone (idle/user/root/adb/cdp stubs; each X read sleeps like user.sh's round trip):
#   - Steam's window found, no tap opens a menu, WWP_BUDGET_S=6: rc 1 with "scan stopped: the run's 6s clock ran out"
#     well under the budget, and the step it stopped at;
#   - a long clock: the scan ends with the diagnosis verdict ("no tap ... opened a menu (N taps; KWin touch lines ...");
#   - no `| xargs` left in it (comments aside); menus() reads named steamwebhelper windows too (no "has no name" filter).
set -u
src=$(cd "$(dirname "$0")/../.." && pwd)
fails=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); [ -n "${2:-}" ] && echo "$2" | sed 's/^/       /'; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/tools/verify"
cp "$src/tools/phone/verify/ww-popups.sh" "$src/tools/phone/verify/ww-lib.sh" "$W/tools/verify/"
F=$W/tools
cat > "$F/idle.sh" <<'S'
#!/bin/bash
echo "idle=999 screen=Awake act=0"
S
cat > "$F/user.sh" <<'S'
#!/bin/bash
f=$(cat "$1")
case $f in
  *"pacman -Q kwin"*) echo "kwin 6.7.5-3.74" ;;
  *"pgrep -fc"*) echo 0 ;;
  *"xwininfo -root -tree"*) echo "0x300003d 0 0 1135 1364" ;;
  *"xwininfo -root -children"*) sleep "${FAKE_X_S:-0.3}" ;;   # menus(): none open, ever
esac
S
cat > "$F/root.sh" <<'S'
#!/bin/bash
f=$(cat "$1"); case $f in *"wc -l"*) echo 10 ;; *"grep -ac"*) echo 3 ;; esac
S
cat > "$F/adb.sh" <<'S'
#!/bin/bash
[ "$1" = exec-out ] && exit 0
case "$*" in *date*) echo "11-08 16:46:00.000" ;; *"input tap"*) echo "$*" >> "$FAKE_TAPS" ;; esac
S
cat > "$F/cdp.sh" <<'S'
#!/bin/bash
e=$3
case $e in
  *webwindows.list*steam*) echo '"w1"' ;;
  *webwindows.list*) echo '"ok"' ;;
  *webwindow-body.live*) echo '"live"' ;;
  *webwindow-body*) echo '"478 497 1613 1862"' ;;
  *elementFromPoint*) echo '""' ;;
  *) echo '""' ;;
esac
S
chmod +x "$F"/*.sh "$F/verify/ww-popups.sh"
export FAKE_TAPS=$W/taps OUT=$W/out
: > "$FAKE_TAPS"
t0=$SECONDS
out=$(FAKE_X_S=1 WWP_BUDGET_S=6 timeout 60 bash "$F/verify/ww-popups.sh" 2>&1); rc=$?
el=$((SECONDS - t0))
if [ $rc = 1 ] && echo "$out" | grep -q "^FAIL scan stopped: the run's 6s clock ran out at the tap at [0-9]*,[0-9]*" && [ $el -le 20 ]; then
  ok "a slow scan ends itself: rc 1, the step it stopped at, ${el}s"
else bad "a slow scan didn't end in its own verdict (rc $rc, ${el}s)" "$out"; fi
echo "$out" | grep -q "signal 13" && bad "SIGPIPE noise in the run's output" "$out"
: > "$FAKE_TAPS"
out=$(FAKE_X_S=0 WWP_BUDGET_S=120 timeout 90 bash "$F/verify/ww-popups.sh" 2>&1); rc=$?
n=$(wc -l < "$FAKE_TAPS")
if [ $rc = 1 ] && echo "$out" | grep -q "^FAIL no tap on Steam's menu bar opened a menu ($n taps; KWin touch lines 3, app popup lines 0" && [ "$n" -ge 10 ]; then
  ok "no menu: a diagnosis verdict after the whole scan ($n taps, taps reached KWin)"
else bad "no-menu verdict wrong (rc $rc, $n taps)" "$out"; fi
grep -n '| *xargs' "$src/tools/phone/verify/ww-popups.sh" | grep -vE '^[0-9]+:[[:space:]]*#' | grep -v '`| xargs`' | grep -q . &&
  bad "ww-popups.sh pipes into xargs again" || ok "no xargs pipes"
grep -A1 '^menus()' "$src/tools/phone/verify/ww-popups.sh" | grep -q 'has no name' && bad "menus() still drops named windows" || ok "menus() reads named menus too"
[ $fails = 0 ]
