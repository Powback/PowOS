#!/bin/bash
# lanes: emu phone
# tools/phone/verify/assist-freeze.sh [N]: the side-button assistant must never freeze the app's UI.
# N times (default 5): shows the assistant the way the side button does (`cmd voiceinteraction show`: the
# VoiceInteraction session, shell mode=assist), runs a dictation in it that falls back to the on-device recognizer
# with a >2 s replay (bridge speech.test, mode fallback, a WAV with 2.5 s of leading silence: the case that froze
# main in AudioFeed.open, ANRs 2026-10-23/24), dismisses it (`cmd voiceinteraction hide`), and meanwhile probes the
# app's MAIN thread every 200 ms (`dumpsys activity service PowosVoiceInteractionService` is answered on main).
# PASS: no new ANR, every dictation ends (its end is posted on main), no probe over idle + 100 ms, no frame over
# 100 ms in gfxinfo (reported per run). Prints one RESULT line. Needs a free window (queue.sh).
set -uo pipefail
cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
n=${1:-5}
tmp=$HOME/.cache/powos-assist-freeze; mkdir -p "$tmp"
step() { echo "== $*"; } # the pill shows the log's last line

step "making the test audio"
say -v Albert -o "$tmp/t.aiff" "Remind me to call Mats about the GPU server tomorrow, and book the train to Bern on Friday." &&
  afconvert -f WAVE -d LEI16@16000 -c 1 "$tmp/t.aiff" "$tmp/v.wav" || { echo "FAIL setup: say/afconvert"; exit 1; }
python3 - "$tmp/v.wav" "$tmp/t.wav" <<'PY' || { echo "FAIL setup: wav"; exit 1; }
import sys, wave
src = wave.open(sys.argv[1]); frames = src.readframes(src.getnframes())
out = wave.open(sys.argv[2], "wb"); out.setnchannels(1); out.setsampwidth(2); out.setframerate(16000)
out.writeframes(b"\0\0" * int(16000 * 2.5) + frames); out.close()
PY
tools/phone/adb.sh push "$tmp/t.wav" /data/local/tmp/assist-freeze.wav >/dev/null || { echo "FAIL setup: push"; exit 1; }
tools/phone/adb.sh shell 'su -c "d=/data/data/com.powos.app/files/speech-test; u=\$(stat -c %u /data/data/com.powos.app); mkdir -p \$d; cp /data/local/tmp/assist-freeze.wav \$d/af.wav; chown -R \$u:\$u \$d"'

# One probe series on the phone: $1 seconds, every 200 ms; prints "max median" of the main thread's answer (ms).
probe() {
  tools/phone/adb.sh shell "end=\$((\$(date +%s)+$1)); while [ \$(date +%s) -lt \$end ]; do s=\$(date +%s%N); timeout 6 dumpsys activity service PowosVoiceInteractionService >/dev/null 2>&1; e=\$(date +%s%N); echo \$(( (e-s)/1000000 )); sleep 0.2; done" |
    tr -d '\r' | sort -n | awk '{a[NR]=$1} END{if(NR==0){print "6000 6000"}else{print a[NR], a[int((NR+1)/2)]}}'
}

anr0=$(tools/phone/adb.sh shell 'su -c "ls /data/anr | wc -l"' | tr -d '\r ')
step "idle baseline"
read -r base_max base_med < <(probe 3)
limit=$((base_med + 100))
echo "idle main-thread probe: max ${base_max} ms, median ${base_med} ms -> limit ${limit} ms"
tools/phone/adb.sh logcat -c
fail=0; worst=0; slowframes=0
for i in $(seq 1 "$n"); do
  step "assist ${i}/${n}: show + dictation fallback"
  tools/phone/adb.sh shell 'dumpsys gfxinfo com.powos.app reset >/dev/null; cmd voiceinteraction show'
  sleep 1.5
  tools/phone/cdp.sh eval assist "(()=>{window.PowosHost.postMessage(JSON.stringify([910002,'speech.test',JSON.stringify(['af.wav','fallback'])]));return 1})()" >/dev/null 2>&1 ||
    tools/phone/cdp.sh eval home "(()=>{window.PowosHost.postMessage(JSON.stringify([910002,'speech.test',JSON.stringify(['af.wav','fallback'])]));return 1})()" >/dev/null
  read -r m1 _ < <(probe 12)
  step "assist ${i}/${n}: dismiss"
  tools/phone/adb.sh shell 'cmd voiceinteraction hide'
  read -r m2 _ < <(probe 2)
  # Frames over 100 ms in this run (gfxinfo's histogram, every window of the app incl. the session's).
  sf=$(tools/phone/adb.sh shell 'dumpsys gfxinfo com.powos.app' | tr -d '\r' | grep -m1 '^HISTOGRAM' |
    tr ' ' '\n' | awk -F'[=m]' '/ms=/{if ($1+0 > 100) s += $3} END{print s+0}')
  m=$((m1 > m2 ? m1 : m2)); [ "$m" -gt "$worst" ] && worst=$m
  slowframes=$((slowframes + sf))
  echo "run $i: main-thread probe max ${m1} ms (shown), ${m2} ms (dismissed); frames >100 ms: ${sf}"
  [ "$m" -gt "$limit" ] && fail=1
  [ "$sf" -gt 0 ] && fail=1
  sleep 1
done
log=$(tools/phone/adb.sh shell 'logcat -d -v time' | tr -d '\r')
ends=$(echo "$log" | grep -c 'test (fallback): ')
replays=$(echo "$log" | grep -o 'falling back to on-device ([^)]*), replaying [0-9]* ms' | grep -o '[0-9]* ms' | tr '\n' ' ')
anr1=$(tools/phone/adb.sh shell 'su -c "ls /data/anr | wc -l"' | tr -d '\r ')
echo "replays: ${replays:-none}; dictations ended: ${ends}/${n}; new ANRs: $((anr1 - anr0))"
[ "$ends" -lt "$n" ] && fail=1
[ "$anr1" -gt "$anr0" ] && fail=1
res="assist x${n}: worst main-thread probe ${worst} ms (idle ${base_med}), frames >100 ms ${slowframes}, dictations ended ${ends}/${n}, new ANRs $((anr1 - anr0))"
if [ "$fail" = 0 ]; then echo "RESULT PASS $res"; exit 0; fi
echo "FAIL RESULT $res"; exit 1
