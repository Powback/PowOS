#!/bin/bash
# logcat-dup-tag: the last spec for a tag wins, so these read only W lines.
lines=$("$adb" shell "logcat -d -T '$since' -s PowosPopups:I PowosPopups:W" | grep popup)
sh_ "logcat -t \"$MARK\" -s PowosPanelLift:I Other:D PowosPanelLift:W" | tail -5
