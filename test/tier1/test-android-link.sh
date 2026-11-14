#!/bin/bash
# test-android-link.sh - `powos android` finds its adb link without root (lib/android.sh _android_pick / link).
#
# The bug (razr no-root log, 11-14): lib/android.sh only knew rooted mode's 127.0.0.1:5555, so on a phone without
# root `powos android screenshot` said "rooted mode only" although Wireless debugging was on - the Linux side got no
# port or key from the app, and its adb has no mDNS under fakechroot. The app (AdbLink.java) now writes run/adb-link
# (AdbLinkTest pins these exact lines) and takes "adb-link [pair|keep on|off]" requests. These run the real picker and
# verbs against a fake adb and a fake app (android-request), and check rooted mode is unchanged (the control).
#
# Usage:  bash test/tier1/test-android-link.sh

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PASS=0; FAIL=0
ok()  { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL - $1 (got '$2')"; FAIL=$((FAIL+1)); }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export XDG_RUNTIME_DIR="$TMP/run" ANDROID_LINK_WAIT_S=2 ANDROID_PAIR_WAIT_S=3
mkdir -p "$TMP/run" "$TMP/bin"
RUN=$TMP/run

# shellcheck source=/dev/null
source "$ROOT/lib/android.sh"

# The fake adb: devices that answer "device" are listed in $TMP/up (one serial per line); `connect H:P` brings H:P up
# when it is in $TMP/listening (adbd's real port); every call is logged.
cat > "$TMP/bin/adb" <<FAKE
#!/bin/bash
echo "\$*" >> "$TMP/adb.log"
case "\$*" in
  "-s "*" get-state") grep -qx "\$2" "$TMP/up" 2>/dev/null && echo device || { echo "error: device '\$2' not found" >&2; exit 1; } ;;
  "connect "*) [ -e "$TMP/needpair" ] && [ ! -e "$TMP/paired" ] && { echo "failed to authenticate"; exit 1; }
            grep -qx "\$2" "$TMP/listening" 2>/dev/null && echo "\$2" >> "$TMP/up" ;;
  "pair "*) echo "\$2 \$3" > "$TMP/paired"; echo "Successfully paired" ;;
  *exec-out*screencap*) echo "\$*" > "$TMP/shot"; printf PNG ;;
  *shell*dumpsys*power*) printf '  mWakefulness=Awake\n  mTopFocusedDisplayId=0\n  DisplayDeviceInfo{"x": uniqueId="local:1", 1 x 1, modeId 1, state ON, committedState ON}\n' ;;
  *) : ;;
esac
FAKE
# The fake app: what AdbLink does for each request ($TMP/port: adbd's port it finds now; $TMP/pairport: the dialog's).
cat > "$TMP/bin/android-request" <<FAKE
#!/bin/bash
echo "\$*" >> "$TMP/requests"
case "\$*" in
  "adb-link") sleep 1; { echo "package com.powos.app"; echo "wireless \$(cat "$TMP/wireless" 2>/dev/null || echo on)"; echo "keep off"
               [ -s "$TMP/port" ] && echo "connect 127.0.0.1:\$(cat "$TMP/port")"; } > "$RUN/adb-link" ;;
  "adb-link pair") echo "127.0.0.1:\$(cat "$TMP/pairport") 482913" > "$RUN/adb-pair" ;;
esac
FAKE
chmod +x "$TMP/bin/adb" "$TMP/bin/android-request"
export PATH="$TMP/bin:$PATH"
reset() { rm -f "$TMP/wireless" "$TMP/needpair" "$TMP/up" "$TMP/listening" "$TMP/requests" "$TMP/adb.log" "$TMP/port" "$TMP/paired" "$RUN/adb-link" "$RUN/adb-pair"
          printf 'wifi-panel\nopen\nadb-link\n' > "$RUN/android-request.verbs"; }
link() { printf 'package com.powos.app\nwireless %s\nkeep on\n%s' "$1" "${2:+connect 127.0.0.1:$2
}" > "$RUN/adb-link"; touch -t 202001010000 "$RUN/adb-link"; }

# 1. Control: rooted mode - 127.0.0.1:5555 answers, it is used, the app is never asked.
reset; echo 127.0.0.1:5555 > "$TMP/up"; link on 39715; echo 127.0.0.1:39715 > "$TMP/listening"
got=$(_android_pick); [[ "$got" == 127.0.0.1:5555 ]] && ok "rooted: 127.0.0.1:5555" || bad "rooted: 127.0.0.1:5555" "$got"
[[ ! -e "$TMP/requests" ]] && ok "rooted: no request to the app" || bad "rooted: no request to the app" "$(cat "$TMP/requests")"

# 2. No root: the app's port on file is connected and used.
reset; link on 39715; echo 127.0.0.1:39715 > "$TMP/listening"
got=$(_android_pick); [[ "$got" == 127.0.0.1:39715 ]] && ok "no root: the app's Wireless debugging port" || bad "no root: the app's Wireless debugging port" "$got"
grep -qx "connect 127.0.0.1:39715" "$TMP/adb.log" && ok "no root: adb connect to it" || bad "no root: adb connect to it" "$(cat "$TMP/adb.log")"

# 3. After a reboot / Wi-Fi change: the port on file is dead; the app is asked once and the new port is used.
reset; link on 39715; echo 41001 > "$TMP/port"; echo 127.0.0.1:41001 > "$TMP/listening"
got=$(_android_pick); [[ "$got" == 127.0.0.1:41001 ]] && ok "moved port: asked the app, reconnected" || bad "moved port: asked the app, reconnected" "$got"
[[ "$(cat "$TMP/requests" 2>/dev/null)" == adb-link ]] && ok "moved port: one 'adb-link' request" || bad "moved port: one 'adb-link' request" "$(cat "$TMP/requests" 2>/dev/null)"

# 4. --no-refresh (status): never asks the app.
reset; link on 39715
_android_pick --no-refresh >/dev/null && bad "--no-refresh: dead port is no link" "linked" || ok "--no-refresh: dead port is no link"
[[ ! -e "$TMP/requests" ]] && ok "--no-refresh: no request" || bad "--no-refresh: no request" "$(cat "$TMP/requests")"

# 5. The verbs go through the link (screenshot, input, logcat, settings).
reset; link on 39715; echo 127.0.0.1:39715 > "$TMP/listening"
out=$(cmd_android screenshot "$TMP/s.png" 2>&1)
[[ "$(cat "$TMP/shot" 2>/dev/null)" == "-s 127.0.0.1:39715 exec-out screencap -d 1 -p" && "$out" == "$TMP/s.png" ]] &&
    ok "screenshot over the link" || bad "screenshot over the link" "$(cat "$TMP/shot" 2>/dev/null) / $out"
cmd_android input tap 10 20 >/dev/null 2>&1; grep -qx -- "-s 127.0.0.1:39715 shell input tap 10 20" "$TMP/adb.log" && ok "input over the link" || bad "input over the link" "$(tail -1 "$TMP/adb.log")"
cmd_android settings get global adb_wifi_enabled >/dev/null 2>&1; grep -qx -- "-s 127.0.0.1:39715 shell settings get global adb_wifi_enabled" "$TMP/adb.log" && ok "settings over the link" || bad "settings over the link" "$(tail -1 "$TMP/adb.log")"
cmd_android logcat >/dev/null 2>&1; grep -qx -- "-s 127.0.0.1:39715 logcat -d -t 200" "$TMP/adb.log" && ok "logcat over the link" || bad "logcat over the link" "$(tail -1 "$TMP/adb.log")"

# 6. No link: says why, in words.
reset
out=$(cmd_android screenshot "$TMP/x.png" 2>&1) && bad "unlinked: refuses" "rc 0" || ok "unlinked: refuses"
[[ "$out" == *"powos android link"* ]] && ok "unlinked: points at powos android link" || bad "unlinked: points at powos android link" "$out"
reset; link off; echo off > "$TMP/wireless"
out=$(cmd_android running 2>&1); [[ "$out" == *"Wireless debugging is off"* ]] && ok "wireless off: says so" || bad "wireless off: says so" "$out"
reset; rm -f "$RUN/android-request.verbs"
out=$(cmd_android running 2>&1); [[ "$out" == *"update"* ]] && ok "old app: says to update it" || bad "old app: says to update it" "$out"

# 7. powos android link: pairs with the code from the app's notification, connects, grants, keeps.
reset; touch "$TMP/needpair"; echo 37001 > "$TMP/pairport"; echo 41001 > "$TMP/port"; echo 127.0.0.1:41001 > "$TMP/listening"
out=$(cmd_android link 2>&1); rc=$?
[[ $rc == 0 && "$out" == *"linked (127.0.0.1:41001)"* ]] && ok "link: linked" || bad "link: linked" "rc $rc: $out"
[[ "$(cat "$TMP/paired" 2>/dev/null)" == "127.0.0.1:37001 482913" ]] && ok "link: adb pair with the app's port + code" || bad "link: adb pair with the app's port + code" "$(cat "$TMP/paired" 2>/dev/null)"
[[ ! -e "$RUN/adb-pair" ]] && ok "link: the code file is deleted" || bad "link: the code file is deleted" "kept"
grep -qx -- "-s 127.0.0.1:41001 shell pm grant com.powos.app android.permission.WRITE_SECURE_SETTINGS" "$TMP/adb.log" &&
    ok "link: WRITE_SECURE_SETTINGS granted" || bad "link: WRITE_SECURE_SETTINGS granted" "$(grep grant "$TMP/adb.log")"
grep -qx "adb-link keep on" "$TMP/requests" && ok "link: the app keeps it" || bad "link: the app keeps it" "$(cat "$TMP/requests")"

# 8. powos status's line (lib/phone.sh) sees the no-root link.
reset; link on 39715; echo 127.0.0.1:39715 > "$TMP/listening"
# shellcheck source=/dev/null
source "$ROOT/lib/phone.sh"
[[ "$(_phone_adb_state)" == device ]] && ok "phone status: device over the link" || bad "phone status: device over the link" "$(_phone_adb_state)"

echo ""
echo "test-android-link: $PASS passed, $FAIL failed"
[[ $FAIL == 0 ]]
