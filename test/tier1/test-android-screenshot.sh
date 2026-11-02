#!/bin/bash
# test-android-screenshot.sh - `powos android screenshot` captures the display that is on and in use.
#
# The bug: lib/android.sh ran `screencap` without -d, which takes the FIRST display - on the OnePlus Open the
# inner screen (4630946704981769859), black whenever the phone is folded and the cover (4630946316123810436) is
# the one in use. These run the real picker on dumpsys lines captured from the Open, and the real screenshot verb
# against a fake adb, asserting the id it passes to `screencap -d`.
#
# Usage:  bash test/tier1/test-android-screenshot.sh

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PASS=0; FAIL=0
ok()  { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL - $1 (got '$2')"; FAIL=$((FAIL+1)); }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# shellcheck source=/dev/null
source "$ROOT/lib/android.sh"

INNER=4630946704981769859 COVER=4630946316123810436
# dumpsys lines as the Open prints them: $1 wakefulness, $2 inner state, $3 cover state, $4 focused logical id
dump() {
    printf '  mWakefulness=%s\n  mTopFocusedDisplayId=%s\n' "$1" "$4"
    printf '  DisplayDeviceInfo{"Built-in Screen": uniqueId="local:%s", 2268 x 2440, modeId 1, state %s, committedState %s}\n' "$INNER" "$2" "$2"
    printf '  DisplayDeviceInfo{"Built-in Screen": uniqueId="local:%s", 1116 x 2484, modeId 4, state %s, committedState %s}\n' "$COVER" "$3" "$3"
    printf '    mDisplayId=0\n    mPrimaryDisplayDevice=Built-in Screen(local:%s)\n' "$([ "$2" = ON ] && echo $INNER || echo $COVER)"
    printf '    mDisplayId=2\n    mPrimaryDisplayDevice=Built-in Screen(local:%s)\n' "$([ "$2" = ON ] && echo $COVER || echo $INNER)"
}
expect() { local got; got=$(dump "$2" "$3" "$4" "$5" | _android_display_pick); [[ "$got" == "$6" ]] && ok "$1" || bad "$1" "$got"; }

expect "folded: the cover"                         Awake OFF ON  0 "$COVER"
expect "unfolded: the inner screen"                Awake ON  OFF 0 "$INNER"
expect "both on, focus on the cover (logical 2)"   Awake ON  ON  2 "$COVER"
expect "both on, focus on the inner (logical 0)"   Awake ON  ON  0 "$INNER"
expect "both on, focus on a virtual display: first on" Awake ON ON 7 "$INNER"
expect "asleep: off, never a black capture"        Asleep OFF ON 0 "off Asleep"
expect "awake but no display on"                   Awake OFF OFF 0 "off no-display-on"

# The verb end to end: a fake adb answers dumpsys (folded) and records the screencap call.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/adb" <<FAKE
#!/bin/bash
case "\$*" in
  *get-state*) echo device ;;
  *exec-out*screencap*) echo "\$*" > "$TMP/call"; printf 'PNG' ;;
  *shell*dumpsys*) printf '%s\n' "\$(cat "$TMP/dump")" ;;
esac
FAKE
chmod +x "$TMP/bin/adb"
dump Awake OFF ON 0 > "$TMP/dump"
out=$(PATH="$TMP/bin:$PATH" cmd_android screenshot "$TMP/s.png" 2>&1)
call=$(cat "$TMP/call" 2>/dev/null)
[[ "$call" == *"screencap -d $COVER -p"* && "$out" == "$TMP/s.png" ]] && ok "screenshot passes -d <cover> when folded" || bad "screenshot passes -d <cover> when folded" "$call / $out"
dump Asleep OFF ON 0 > "$TMP/dump"; rm -f "$TMP/call"
PATH="$TMP/bin:$PATH" cmd_android screenshot "$TMP/s2.png" >/dev/null 2>&1 && bad "asleep: refuses" "rc 0" || ok "asleep: refuses"
[[ -e "$TMP/call" ]] && bad "asleep: no capture taken" "captured" || ok "asleep: no capture taken"

echo ""
echo "== Results: $PASS passed, $FAIL failed =="
[[ $FAIL == 0 ]]
