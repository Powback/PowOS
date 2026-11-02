#!/bin/bash
# The system module always ships the recents slot (PowOS as SystemUI's recents provider: the shade, the switcher, the
# gestures), and can't be built without --priv-app (SystemUI binds only a system package's QUICKSTEP_SERVICE).
# 11-02 05:43: a module built without --slot recents (the slot was opt-in in overlays-disabled/) and the reboot after
# it left OnePlus's launcher as the provider - no PowOS shade, and the ship guard rolled back two good APKs.
#   targets/android/system-module/slots-test.sh     exit 0 = pass (no phone, no docker, no APK needed)
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd) fail=0
no() { echo "FAIL: $*"; fail=1; }
grep -q '<string name="config_recentsComponentName"[^>]*>com\.powos\.app/' "$here/overlays/recents/res/values/config.xml" 2>/dev/null ||
  no "overlays/recents doesn't ship config_recentsComponentName naming com.powos.app"
[ -d "$here/overlays-disabled/recents" ] && no "recents is still in overlays-disabled/ (opt-in again)"
out=$("$here/build-module.sh" --apk /nonexistent.apk 2>&1); rc=$?
{ [ $rc = 2 ] && [[ "$out" == *"needs --priv-app"* ]]; } || no "build-module.sh without --priv-app didn't refuse (rc $rc: $out)"
out=$("$here/build-module.sh" --priv-app --slot recents --apk /nonexistent.apk 2>&1); rc=$?
[[ "$out" == *"no APK at"* ]] || no "--slot recents (already shipped) isn't accepted as before (rc $rc: $out)"
[ $fail = 0 ] && echo "slots-test: pass"
exit $fail
