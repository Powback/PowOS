#!/bin/bash
# lanes: phone
# tools/phone/verify/speech-test.sh [text] [mode]: plays a synthesized phrase through the app's GPU dictation
# (bridge speech.test, no mic) and checks the transcript has its words. Exit 0 = heard, 1 = not.
# mode: gpu (default) | fallback | down (powos-voice skill, "Testing without the mic").
set -uo pipefail
cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
text=${1:-"Remind me to call Mats about the GPU server tomorrow."}
mode=${2:-gpu}
tmp=$HOME/.cache/powos-speech-test; mkdir -p "$tmp"
say -v Albert -o "$tmp/t.aiff" "$text" && afconvert -f WAVE -d LEI16@16000 -c 1 "$tmp/t.aiff" "$tmp/t.wav" || exit 1
tools/phone/adb.sh push "$tmp/t.wav" /data/local/tmp/speech-t.wav >/dev/null || exit 1
tools/phone/adb.sh shell 'su -c "d=/data/data/com.powos.app/files/speech-test; u=\$(stat -c %u /data/data/com.powos.app); mkdir -p \$d; cp /data/local/tmp/speech-t.wav \$d/t.wav; chown -R \$u:\$u \$d"'
tools/phone/adb.sh logcat -c
tools/phone/cdp.sh eval home "(()=>{window.PowosHost.postMessage(JSON.stringify([910001,'speech.test',JSON.stringify(['t.wav','$mode'])]));return 1})()" >/dev/null
sleep 15
log=$(tools/phone/adb.sh shell 'logcat -d -v time' | grep -E "/speech|test \(" )
echo "$log" | grep -E "test \(|dropped Whisper junk" | tail -5
got=$(echo "$log" | grep -o 'test ([a-z]*): ".*"' | tail -1)
# The phrase's key words, not exact text (Whisper writes numbers and punctuation its own way).
if echo "$got" | grep -qiE "mat+[sz]" && echo "$got" | grep -qi "server"; then echo "speech-test: OK $got"; exit 0; fi
echo "speech-test: FAILED (heard: ${got:-nothing})"; exit 1
