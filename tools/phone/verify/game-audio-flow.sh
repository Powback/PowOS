#!/bin/bash
# lanes: phone
# game-audio-flow.sh: verify-queue job for board task no-game-audio-per-game-audio-group-loopback-drop. Starts Broforce
# (APP, default 274190) the way the drawer does, waits 40 s into the game, dumps its audio-group graph and measures
# the sound stage by stage (game-audio-flow-phone.sh: game output, loopback output, a test tone into the group sink),
# then stage D on the Android side (game-audio-android.py: the PowOS app's AAudio track in AudioFlinger - frames consumed
# across the run, underruns, L/R/VS gain - plus STREAM_MUSIC volume and the bridge's logcat), then closes the game it
# started (Steam stays resident). rc = the flow check's (0 = sound reaches the loopback output); the D verdict is printed.
cd "$(dirname "$0")/../../.." || exit 3
tools/phone/user.sh tools/phone/verify/bf-start.sh || { echo "FAIL setup: bf-start"; exit 3; }
sleep 40
tools/phone/user.sh tools/phone/verify/game-audio-graph-phone.sh
D=$(mktemp -d); app=$(tools/phone/adb.sh shell pidof com.powos.app | tr -d '\r' | awk '{print $1}')
tools/phone/adb.sh shell dumpsys media.audio_flinger >"$D/af1" 2>&1
tools/phone/user.sh tools/phone/verify/game-audio-flow-phone.sh; rc=$?
tools/phone/adb.sh shell dumpsys media.audio_flinger >"$D/af2" 2>&1
tools/phone/adb.sh shell dumpsys audio >"$D/audio" 2>&1
python3 tools/phone/verify/game-audio-android.py "${app:-none}" "$D/af1" "$D/af2" "$D/audio"
echo "D logcat (bridge):"; tools/phone/adb.sh shell 'logcat -d -s AndromarchyAudio:* | tail -12' | sed 's/^/   /'
rm -rf "$D"
tools/phone/user.sh tools/phone/verify/bf-stop.sh
echo "RESULT game-audio-flow rc=$rc"; exit $rc
