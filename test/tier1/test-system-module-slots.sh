#!/bin/bash
# test-system-module-slots.sh - the system module always ships the recents slot (the PowOS shade lives on it).
# Runs targets/android/system-module/slots-test.sh (no phone, no docker, no APK).
#
# Usage:  bash test/tier1/test-system-module-slots.sh
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec bash "$ROOT/targets/android/system-module/slots-test.sh"
