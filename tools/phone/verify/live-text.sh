#!/bin/bash
# lanes: phone emu
# live-text.sh (board: select-text-in-images-and-the-camera; docs/research/live-text.md): Live Text reads the fixture
# image (targets/android/app/app/src/test/resources/livetext/fixture.png) on the device, through the share sheet's own
# entry point and no touch input, without root:
#  1. the fixture goes to the phone's Pictures and into MediaStore (adb's shell uid can read and grant it);
#  2. LiveTextActivity gets it as ACTION_SEND + EXTRA_STREAM ("Copy text") with the report extra: it logs each read as
#     JSON under the "LiveText" tag and closes itself when done;
#  3. PASS when the device read (ML Kit, offline) has the fixture's lines and finds the phone number, link and email;
#     PowStation's read (PowScan / PaddleOCR-VL on gpu-195) is reported, not judged (it needs LAN/VPN and the pool).
# The fixture is removed from MediaStore at the end.
# Exit 0 PASS, 1 FAIL, 2 SKIP (no device, app without Live Text yet).
set -uo pipefail
cd "$(dirname "$0")/../../.." || exit 1
T=tools/phone
PKG=com.powos.app
ACT=$PKG/dev.omalauncher.livetext.LiveTextActivity
NAME=powos-livetext-fixture.png
FIX=targets/android/app/app/src/test/resources/livetext/fixture.png
sh_() { "$T/adb.sh" shell "$@"; }
skip() { echo "SKIP: live-text: $1"; exit 2; }
fail() { echo "FAIL: live-text: $1"; exit 1; }

sh_ true >/dev/null 2>&1 || skip "device not reachable"
# Read the whole dump into a variable, then match: `sh_ ... | grep -q` under pipefail SIGPIPEs adb when grep leaves at
# the first hit of the long `pm dump`, the pipe returns 141 and the check SKIPped a build that has the activity (11-28).
# resolve-activity alone can't tell: with several SEND image/* targets in the package it answers the ResolverActivity.
pkgdump=$(sh_ "pm dump $PKG" 2>/dev/null || true)
[[ $pkgdump == *livetext.LiveTextActivity* ]] || skip "this app build has no LiveTextActivity yet"

"$T/adb.sh" push "$FIX" "/sdcard/Pictures/$NAME" >/dev/null || fail "push failed"
sh_ "am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d file:///sdcard/Pictures/$NAME" >/dev/null 2>&1
id=
for _ in $(seq 1 20); do
    id=$(sh_ "content query --uri content://media/external/images/media --projection _id --where \"_display_name='$NAME'\"" 2>/dev/null |
        sed -n 's/.*_id=\([0-9]*\).*/\1/p' | tail -1)
    [ -n "$id" ] && break
    sleep 0.5
done
cleanup() { [ -n "$id" ] && sh_ "content delete --uri content://media/external/images/media/$id" >/dev/null 2>&1; sh_ "rm -f /sdcard/Pictures/$NAME" >/dev/null 2>&1; }
trap cleanup EXIT
[ -n "$id" ] || fail "MediaStore didn't index the fixture"

sh_ "logcat -c" >/dev/null 2>&1
sh_ "am start -n $ACT -a android.intent.action.SEND -t image/png --eu android.intent.extra.STREAM content://media/external/images/media/$id --grant-read-uri-permission --ez dev.omalauncher.livetext.REPORT true" >/dev/null ||
    fail "am start refused"

dev='' hq=''
for _ in $(seq 1 90); do
    log=$(sh_ "logcat -d -s LiveText:I" 2>/dev/null)
    dev=$(sed -n 's/.*LiveText: result \({"engine":"device".*\)/\1/p' <<<"$log" | tail -1)
    hq=$(sed -n 's/.*LiveText: result \({"engine":"powstation".*\)/\1/p' <<<"$log" | tail -1)
    [ -n "$dev" ] && [ -n "$hq" ] && break
    sleep 1
done
echo "device:     ${dev:-none}"
echo "powstation: ${hq:-none (not reported within 90 s)}"
[ -n "$dev" ] || fail "no device read logged within 90 s"

python3 - "$dev" "$hq" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
bad = []
if not d.get("ok"): bad.append("device OCR failed")
t = d.get("text", "")
for want in ["Live Text", "22 33 44 55", "powback.com", "hello@powback.com", "Storgata 12"]:
    if want not in t: bad.append(f"text lacks {want!r}")
kinds = {e["kind"] for e in d.get("entities", [])}
for k in ["PHONE", "URL", "EMAIL", "ADDRESS"]:
    if k not in kinds: bad.append(f"no {k} found")
print(f"device read: {d.get('words')} words in {d.get('ms')} ms, entities {sorted(kinds)}")
if sys.argv[2]:
    h = json.loads(sys.argv[2])
    print(f"powstation read: ok={h.get('ok')} {h.get('words')} words in {h.get('ms')} ms (reported, not judged)")
if bad:
    print("FAIL: live-text: " + "; ".join(bad)); sys.exit(1)
print("PASS: live-text: the device read the fixture and found its phone, link, email and address")
PY
