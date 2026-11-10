#!/bin/bash
# one spec per tag: Tag:I already includes W and E.
lines=$("$adb" shell "logcat -d -T '$since' -s PowosPopups:I" | grep popup)
sh_ "logcat -d -s PowosWindowResize:I PowosWindowDrag:I PowosFreeform:W" | tail -6
