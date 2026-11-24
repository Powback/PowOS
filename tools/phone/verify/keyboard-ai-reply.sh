#!/bin/bash
# lanes: phone
# needs: ship:apk
# keyboard-ai-reply.sh (Mac side, board kb-ai-reply): the swipe keyboard's AI reply button end to end on PowOS's side,
# without touching the screen: PowOS's keyboard AI provider (system/KeyboardAiProvider.kt) called from adb's shell uid
# (admitted like the keyboard: it can screencap anyway) with `content call`, exactly the calls the keyboard makes -
# probe, capture (whatever is on screen in the runner's free window, kept in PowOS's memory only), drafts with a
# canned voice note's transcript, release. PASS = a capture path (root/accessibility/live), a shot, >= 2 variations
# from PowOS AI, and the shot gone after release (drafts then answers "expired"). Also logs the installed keyboard's
# version (the build with the button). A secure focused window answers "secure": SKIP (exit 2), not a failure.
# No input injected, nothing opened or closed, nothing written outside PowOS's memory.
set -u
cd "$(dirname "$0")/../../.." || exit 1
call() { # method json-arg -> the answer's json
    tools/phone/adb.sh shell "content call --uri content://com.powos.app.keyboardai --method $1 --arg '$2'" 2>&1 |
        sed -n 's/.*json=\(.*\)}]$/\1/p' | tail -1
}
kv=$(tools/phone/adb.sh shell "dumpsys package com.swipekeyboard | grep -m1 versionCode" 2>&1 | tr -s ' ')
echo "keyboard:$kv"
p=$(call probe '{}')
echo "probe: $p"
grep -q '"ok":true' <<<"$p" || { echo "FAIL: probe: $p"; exit 1; }
c=$(call capture '{"imeTop":0,"screenH":0}')
echo "capture: $c"
grep -q '"error":"secure"' <<<"$c" && { echo "SKIP: the focused window is secure"; exit 2; }
shot=$(sed -n 's/.*"shot":"\([^"]*\)".*/\1/p' <<<"$c")
[ -n "$shot" ] || { echo "FAIL: capture: $c"; exit 1; }
# The canned voice note: what the keyboard sends after transcribing a held button.
t0=$(date +%s)
d=$(call drafts "{\"shot\":\"$shot\",\"transcript\":\"say I am running ten minutes late\",\"text\":\"\",\"app\":\"com.google.android.apps.messaging\",\"hint\":\"Text message\",\"inputType\":131137,\"n\":3,\"avoid\":[]}")
echo "drafts ($(( $(date +%s) - t0 )) s): $d"
call release "{\"shot\":\"$shot\"}" >/dev/null
gone=$(call drafts "{\"shot\":\"$shot\",\"transcript\":\"\",\"n\":1}")
fail=
grep -q '"ok":true' <<<"$d" || fail="$fail drafts-failed"
n=$(grep -o '"variations":\[[^]]*\]' <<<"$d" | grep -o '","' | wc -l | tr -d ' ')
[ "${n:-0}" -ge 1 ] || fail="$fail variations<2"
grep -q '"error":"expired"' <<<"$gone" || fail="$fail shot-kept-after-release($gone)"
[ -n "$fail" ] && { echo "FAIL:$fail"; exit 1; }
echo "PASS: probe + capture ($(sed -n 's/.*"via":"\([^"]*\)".*/\1/p' <<<"$c")) + $((n + 1)) drafts from a canned voice note; the shot is dropped on release"
