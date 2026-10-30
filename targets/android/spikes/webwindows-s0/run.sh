#!/bin/bash
# Pushes s0.jar and runs it as shell, then pulls the logs/dumps/PNGs to build/out-<TAG>.
#   run.sh mirror [extraFlags]          U1/R1: mirror vs copy; A's surface null / unread / 1x1 / hidden
#   run.sh ime <extraFlags> <policy>    U3/R3: tap the page's text field on A; policy 0 LOCAL, 1 FALLBACK_DISPLAY, 2 HIDE
# extraFlags (hex) are added to both displays' VIRTUAL_DISPLAY flags, e.g. 0x1c00 = TRUSTED|OWN_DISPLAY_GROUP|ALWAYS_UNLOCKED
# (needed while the phone's own screen is off: VDs in the default group follow it to OFF).
# Env: TAG (output dir name), S0_ENV (env for the phone side: S0_SHORT=1 stops after p6, S0_POKE=0 no user activity).
set -euo pipefail
cd "$(dirname "$0")"
ADB=../../../../tools/phone/adb.sh
TAG=${TAG:-$1}
$ADB push build/s0.jar /data/local/tmp/s0.jar >/dev/null
$ADB shell 'rm -rf /data/local/tmp/s0; '"${S0_ENV:-}"' CLASSPATH=/data/local/tmp/s0.jar app_process /system/bin S0 '"$*"' 2>&1' | tee build/run-$TAG.txt
rm -rf build/out-$TAG; mkdir -p build/out-$TAG
$ADB shell 'cd /data/local/tmp/s0 && tar cf - .' | tar xf - -C build/out-$TAG || true
$ADB shell 'rm -rf /data/local/tmp/s0 /data/local/tmp/s0.jar'
