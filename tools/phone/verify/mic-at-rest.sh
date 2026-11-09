#!/bin/bash
# lanes: phone
# mic-at-rest.sh (board mic-recording-glow-shows-on-when-the-mic-isn-t-a; the user: "Mic/recording glow shows on when
# the mic isn't actually capturing"): run in an idle window (nobody dictating), read only. Android's mic glow and
# PowOS's recording ring both follow the app's RECORD_AUDIO op, so: PASS = com.powos.app holds no running RECORD_AUDIO
# now AND every capture session in AudioService's recording log was closed again, none open longer than MAX_S (120 s;
# e197e232: the Linux bridge used to hold VOICE_RECOGNITION open whenever the audio socket was up). Exit 3 when the
# app is in the foreground with the AI page dictating (can't tell rest from use).
set -u
cd "$(dirname "$0")/../../.." || exit 5
A=tools/phone/adb.sh; MAX_S=${MAX_S:-120}
ops=$($A shell 'dumpsys appops --package com.powos.app --op RECORD_AUDIO' 2>&1 | tr -d '\r') || { echo "SKIP: ENV: dumpsys appops failed"; exit 5; }
[ -n "$ops" ] || { echo "SKIP: ENV: no appops answer"; exit 5; }
run=$(grep -iE 'Running start|running=true|\(running\)' <<<"$ops" | head -2)
log=$($A shell 'dumpsys audio' 2>&1 | tr -d '\r' | sed -n '/recording activity received/,/^$/p' | grep 'pack:com.powos.app')
echo "mic-at-rest: $(grep -c . <<<"$log") PowOS recording events in AudioService's log"
long=$(python3 -c "$(cat <<'PY'
import sys,re,datetime
mx=int(sys.argv[1]); open_={}; out=[]
for l in sys.stdin:
    m=re.match(r"(\d\d-\d\d \d\d:\d\d:\d\d):(\d+) rec (\w+) riid:(\d+)",l.strip())
    if not m: continue
    t=datetime.datetime.strptime("2026-"+m[1],"%Y-%m-%d %H:%M:%S"); ev,r=m[3],m[4]
    if ev in("start","update"): open_.setdefault(r,t)
    elif ev in("stop","release") and r in open_:
        d=(t-open_.pop(r)).total_seconds()
        if d>mx: out.append(f"riid {r} open {int(d)} s")
for r,t in open_.items(): out.append(f"riid {r} opened {t:%H:%M:%S}, never stopped")
print("; ".join(out))
PY
)" "$MAX_S" <<<"$log")
[ -n "$run" ] && { echo "FAIL: com.powos.app holds the mic right now with nobody dictating: $run"; exit 1; }
[ -n "$long" ] && { echo "FAIL: PowOS mic capture held past ${MAX_S} s / never closed: $long"; exit 1; }
echo "PASS: mic at rest - no running RECORD_AUDIO for com.powos.app, every capture closed within ${MAX_S} s (the glow has nothing to show)"
