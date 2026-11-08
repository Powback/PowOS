#!/bin/bash
# lanes: phone
# game-audio-flow.sh: verify-queue job for board task no-game-audio-per-game-audio-group-loopback-drop. Starts Broforce
# (APP, default 274190) the way the drawer does, waits 40 s into the game, dumps its audio-group graph and measures
# the sound stage by stage (game-audio-flow-phone.sh: game output, loopback output, a test tone into the group sink),
# then closes the game it started (Steam stays resident). rc = the flow check's (0 = sound reaches the loopback output).
cd "$(dirname "$0")/../../.." || exit 3
tools/phone/user.sh tools/phone/verify/bf-start.sh || { echo "FAIL setup: bf-start"; exit 3; }
sleep 40
tools/phone/user.sh tools/phone/verify/game-audio-graph-phone.sh
tools/phone/user.sh tools/phone/verify/game-audio-flow-phone.sh; rc=$?
tools/phone/user.sh tools/phone/verify/bf-stop.sh
echo "RESULT game-audio-flow rc=$rc"; exit $rc
