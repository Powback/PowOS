#!/bin/bash
# lint fixture: no pipefail, so a SIGPIPEd producer never decides the status
set -u
if adb shell dumpsys power | grep -q 'mWakefulness=Awake'; then echo awake; fi
