#!/bin/bash
# lanes: phone
# tools/phone/verify/auto-app-permissions.sh: apps PowOS adds itself get their permissions (the user 11-25: "the apps
# added automatically dont have microphone permissions etc"; docs/WEB_WINDOWS.md "Web app permissions",
# targets/android/README.md "PowOS's keyboard").
#   1. rooted: the swipe keyboard holds RECORD_AUDIO (system/AutoGrants.kt, pm grant after install);
#   2. voiceagent.pow as a web app (WebAppActivity, opened as the launcher's web window does): it loads on https (a
#      secure context: PowCa/WebAppTls), the page asks for the mic, PowOS's dialog is answered "Allow" (and Android's
#      own if PowOS lacked the mic), and the capture track is "live". Only what it opened is closed (its task, BACK);
#      the site's grant stays as the user would have given it (revoke: the app's menu on the launcher).
# Exit 0 PASS, 1 FAIL, 3 no free window.
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd); A=$here/adb.sh
OUT=${OUT:-$HOME/.cache/powos-verify/auto-app-permissions-$(date +%m%d-%H%M%S)}; mkdir -p "$OUT"
. "$(dirname "$0")/window-lock.sh"
window_lock auto-app-permissions.sh 120 || exit 3
fails=()
su_() { "$A" shell "su -c '$*'" </dev/null 2>/dev/null | tr -d '\r'; }

# 1. The keyboard's mic (rooted phones only: without root it asks at first use, MicPermissionActivity).
if [ "$(su_ id -u)" = 0 ]; then
  kb=$("$A" shell "dumpsys package com.swipekeyboard | grep -m1 'android.permission.RECORD_AUDIO: granted='" | tr -d '\r ')
  echo "keyboard: ${kb:-not installed}"
  case "$kb" in *granted=true*) ;; *) fails+=("keyboard: RECORD_AUDIO not granted ($kb)") ;; esac
else
  echo "keyboard: not rooted - skipped (it asks at first use)"
fi

# 2. voiceagent.pow as a web app.
URL=http://voiceagent.pow/
su_ "am start -n com.powos.app/dev.omalauncher.shell.WebAppActivity -a android.intent.action.VIEW -d $URL -f 0x10080000" >/dev/null
page=
for _ in $(seq 1 20); do
  sleep 1
  page=$("$here/cdp.sh" pages 2>/dev/null | grep -oE 'https?://voiceagent\.pow/[^ ]*' | head -1)
  [ -n "$page" ] && break
done
echo "page: ${page:-none}"
case "$page" in https://*) ;; *) fails+=("voiceagent.pow didn't open on https (got '${page:-no page}'): no secure context, no mic") ;; esac
# cdp.sh prints a string result JSON-quoted ("asking"); unquoted here, so the compares below see the bare value. The
# 11-25 run compared '"asking"' with asking, left the tap loop at once (PowOS's dialog sat there untapped, webapp.png)
# and failed "mic capture is '"asking"'".
ev() { "$here/cdp.sh" eval voiceagent.pow/ "$1" 2>&1 | tail -1 | tr -d '\r' | sed -E 's/^"(.*)"$/\1/'; }
echo "secure: $(ev 'String(window.isSecureContext) + " " + typeof navigator.mediaDevices')"
ev 'window.__aapMic = "asking"; navigator.mediaDevices.getUserMedia({ audio: true }).then((s) => { window.__aapStream = s; window.__aapMic = s.getAudioTracks()[0].readyState; }, (e) => { window.__aapMic = "error " + e.name; }); "asked"' >/dev/null
# PowOS's dialog ("Allow"), then Android's if PowOS lacked the mic ("While using the app" / "Allow"): tapped where
# uiautomator says the button is. Only buttons of those two dialogs (package com.powos.app / the permission controller).
tap_allow() {
  "$A" shell "uiautomator dump /data/local/tmp/aap-ui.xml >/dev/null 2>&1; cat /data/local/tmp/aap-ui.xml; rm -f /data/local/tmp/aap-ui.xml" | tr -d '\r' > "$OUT/ui.xml"
  python3 - "$OUT/ui.xml" <<'PY'
import re, sys
x = open(sys.argv[1], errors="replace").read()
for m in re.finditer(r'<node [^>]*>', x):
    n = m.group(0)
    t = re.search(r' text="([^"]*)"', n); p = re.search(r' package="([^"]*)"', n); b = re.search(r' bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', n)
    if not (t and p and b): continue
    if p.group(1) not in ("com.powos.app", "com.android.permissioncontroller", "com.google.android.permissioncontroller"): continue
    if t.group(1).strip().lower() in ("allow", "while using the app", "only this time"):
        x1, y1, x2, y2 = map(int, b.groups()); print((x1 + x2) // 2, (y1 + y2) // 2, t.group(1)); break
PY
}
for _ in 1 2 3; do
  sleep 2
  got=$(ev 'window.__aapMic')
  [ "$got" = asking ] || break
  xy=$(tap_allow)
  [ -n "$xy" ] || { echo "no Allow button on screen yet"; continue; }
  echo "tap: $xy"
  "$A" shell "input tap $(echo "$xy" | awk '{print $1, $2}')" >/dev/null
done
sleep 2
mic=$(ev 'window.__aapMic')
echo "mic: $mic"
[ "$mic" = live ] || fails+=("voiceagent.pow: mic capture is '$mic', not live")
"$here/shot.sh" "$OUT/webapp.png" >/dev/null 2>&1
ev '(window.__aapStream?.getTracks() ?? []).forEach((t) => t.stop()); "stopped"' >/dev/null
"$A" shell "logcat -d -v time | grep -E 'PowosWebApp|PowosWebPerms|PowosWebTls|PowosAutoGrants' | tail -8" | tr -d '\r'
# Close only what this opened: its task is in front, BACK finishes it (no history).
"$A" shell input keyevent KEYCODE_BACK >/dev/null

if [ ${#fails[@]} -eq 0 ]; then echo "PASS: keyboard mic + voiceagent.pow mic in its web app ($OUT)"; exit 0; fi
printf 'FAIL: %s\n' "${fails[@]}"; echo "out: $OUT"; exit 1
