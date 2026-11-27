#!/bin/bash
# lanes: phone
# drops.sh (board: universal-clipboard-across-my-devices, send-to-my-device-from-the-share-sheet; docs/DEVICES.md
# "Clipboard and Send to"): the universal clipboard and Send to my device end to end, through the PowOS app's own entry
# points and no touch input. The other signed-in device is drops-peer.py on the Mac (a test device of the account
# speaking drops through lib/apps/powos-drop, so every leg is sealed by one implementation and opened by the other):
#  1. clip, phone -> peer: KeyboardAiProvider clip.push (the keyboard's call, from adb's shell uid) - the peer opens it;
#  2. clip, peer -> phone: the peer offers one, the app's clip.offered (the keyboard's clipboard panel) shows it opened;
#  3. send text, phone -> peer: the share sheet's target (SendToDeviceActivity, ACTION_SEND + EXTRA_TEXT + the device);
#  4. send a small file, phone -> peer: the same target with EXTRA_STREAM (a file in the app's FileProvider) - the peer
#     opens it, same name, same sha256;
#  5. send text, peer -> phone: DropInbox (polls every 15 s while the screen is on) takes it - it lands in the app's
#     cache/share/drops/<id>/ with the text and the realm no longer holds it. Leaves one "From PowOS verify" notification.
# Each leg's drop is withdrawn/taken at the end, so the owner's other phones don't keep the test clips.
# Exit 0 PASS, 1 FAIL, 2 not judged (SKIP: no phone/root, not joined, shared clipboard off, screen off for leg 5).
# Needs the peer enrolled once by the owner: `tools/phone/verify/drops-peer.py enroll` on the Mac, then approve its code
# (Devices app or `docker exec powos-enroll powos-enroll approve <code> --no-approver`); until then it SKIPs.
set -uo pipefail
cd "$(dirname "$0")/../../.." || exit 1
T=tools/phone
PKG=com.powos.app
N=$(date +%s)$RANDOM
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
peer() { uv run -q --no-project --with cryptography python3 tools/phone/verify/drops-peer.py "$@"; }
adb() { "$T/adb.sh" shell "$@"; }
call() { adb "content call --uri content://$PKG.keyboardai --method $1 --arg '$2'" 2>&1 | sed -n 's/.*json=\(.*\)}]$/\1/p' | tail -1; }
skip() { echo "SKIP: drops: $1"; exit 2; }
fails=()
bad() { echo "  FAILED: $1"; fails+=("$1"); }
ok() { echo "  ok: $1"; }

# --- preconditions
adb true >/dev/null 2>&1 || skip "phone not reachable"
pid=$(adb "su -c 'cat /data/data/$PKG/files/devices/enrollment.json'" 2>/dev/null |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["device"]["id"])' 2>/dev/null)
[ -n "$pid" ] || skip "the PowOS app hasn't joined a PowStation here (or no root to read it)"
# The peer is enrolled once by the owner (drops-peer.py enroll + their approval); the check never enrolls or approves.
[ -s "${DROPS_PEER_DIR:-$HOME/.local/state/powos/verify-drops-peer}/enrollment.json" ] ||
    skip "no test peer yet: the owner runs tools/phone/verify/drops-peer.py enroll on the Mac and approves its code"
peer_id=$(peer id 2>"$tmp/err") || skip "the test peer can't be read: $(tail -1 "$tmp/err")"
echo "phone $pid, peer $peer_id"
sw=$(call clip.switch '{}')
echo "clip.switch: $sw"
grep -q '"on":true' <<<"$sw" || skip "the shared clipboard is off on this phone (or the app answers no clip.switch: $sw)"

# --- 1. clip phone -> peer
r=$(call clip.push "{\"text\":\"powos-verify-clip-up-$N\"}")
echo "clip.push: $r"
cid=$(sed -n 's/.*"clip":{[^}]*"id":"\([^"]*\)".*/\1/p' <<<"$r")
if [ -z "$cid" ]; then bad "clip.push didn't offer the copy ($r)"
else
    got=$(peer clips "$pid" "clip-up-$N" 2>&1)
    grep -q "\"text\": \"powos-verify-clip-up-$N\"" <<<"$got" && ok "phone's copy opened on the peer" || bad "the peer didn't get the phone's clip ($got)"
fi

# --- 2. clip peer -> phone
pc=$(peer clip "powos-verify-clip-down-$N" 2>&1) || bad "the peer couldn't offer a clip ($pc)"
if [ -n "$pc" ]; then
    r=$(call clip.offered '{}')
    echo "clip.offered: ${r:0:300}"
    grep -q "\"text\":\"powos-verify-clip-down-$N\"" <<<"$r" && ok "peer's copy opened in the phone's clipboard panel" || bad "clip.offered doesn't show the peer's clip ($r)"
    peer done "$pc" >/dev/null 2>&1
fi

# --- 3./4. Send to: the share sheet's target, text then a file
adb "am start -W -n $PKG/dev.omalauncher.devices.SendToDeviceActivity -a android.intent.action.SEND -t text/plain --es android.intent.extra.TEXT powos-verify-send-up-$N --es dev.omalauncher.devices.SEND_TO $peer_id" >/dev/null 2>&1
head -c 3000 /dev/urandom | base64 > "$tmp/f"; fsha=$(shasum -a 256 < "$tmp/f" | cut -d' ' -f1)
fname=drops-$N.txt; dir=/data/data/$PKG/cache/share/verify-drops
adb "su -c 'mkdir -p $dir && cat > $dir/$fname && u=\$(stat -c %u /data/data/$PKG) && chown -R \$u:\$u $dir && restorecon -R $dir'" < "$tmp/f" >/dev/null 2>&1
adb "am start -W -n $PKG/dev.omalauncher.devices.SendToDeviceActivity -a android.intent.action.SEND -t application/octet-stream --eu android.intent.extra.STREAM content://$PKG.files/share/verify-drops/$fname --es dev.omalauncher.devices.SEND_TO $peer_id" >/dev/null 2>&1
got=""; for _ in 1 2 3 4 5 6 7 8; do
    sleep 2; got+=$(peer sends "$pid" "$N" 2>&1)$'\n'
    grep -q 'send-up' <<<"$got" && grep -q "$fname" <<<"$got" && break
done
echo "${got:0:600}"
grep -q "\"text\": \"powos-verify-send-up-$N\"" <<<"$got" && ok "shared text sent to the peer and opened" || bad "the share sheet's text never reached the peer in 16 s"
grep -q "\"name\": \"$fname\".*\"sha256\": \"$fsha\"" <<<"$got" && ok "shared file sent to the peer, same name + sha256" || bad "the share sheet's file never reached the peer intact in 16 s"
adb "su -c 'rm -rf $dir'" >/dev/null 2>&1

# --- 5. send peer -> phone (DropInbox)
back=""
if adb "dumpsys power" 2>/dev/null | grep -q 'mWakefulness=Awake'; then
    sid=$(peer send "$pid" "powos-verify-send-down-$N" 2>&1) || bad "the peer couldn't send to the phone ($sid)"
    if [ -n "$sid" ]; then
        st=waiting; for _ in $(seq 1 12); do sleep 4; st=$(peer state "$sid" 2>&1); [ "$st" = gone ] && break; done
        land=$(adb "su -c 'cat /data/data/$PKG/cache/share/drops/$sid/text.txt'" 2>/dev/null)
        if [ "$st" = gone ] && [ "$land" = "powos-verify-send-down-$N" ]; then ok "the phone took the peer's send and opened it (cache/share/drops/$sid)"
        else bad "the phone didn't take the peer's send in 48 s (realm: $st, landed: '${land:0:80}')"; peer done "$sid" >/dev/null 2>&1; fi
    fi
else
    back="the phone's screen is off, so DropInbox doesn't poll (leg 5 not judged)"
fi

if [ ${#fails[@]} -gt 0 ]; then echo "FAIL drops: ${fails[0]}${fails[1]:+ (+$((${#fails[@]} - 1)) more)}"; exit 1; fi
[ -z "$back" ] || skip "legs 1-4 pass; $back"
echo "PASS drops: clips both ways, share-sheet text + file to the peer, the peer's send received + opened on the phone"
