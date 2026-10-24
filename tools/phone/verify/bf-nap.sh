# lanes: phone
# bf-nap.sh <secs> <touch irq count>: (on the phone, adb shell; bf-pacing.sh) wait <secs> s in ONE adb call, printing
# "touched" and returning at once when the touch-panel IRQs move from <count> (the user is back). bf-pacing's waits were
# a 5 s sleep + an adb call each, ~8 s per "5 s": a 45 s settle took 68 s and the check ran out of its 300 s budget.
end=$(( $(date +%s) + ${1:-5} ))
while [ "$(date +%s)" -lt $end ]; do
  [ "$(awk '/touch-0/{s+=$2+$3+$4+$5+$6+$7+$8+$9} END{print s}' /proc/interrupts)" != "${2:-}" ] && { echo touched; exit 0; }
  sleep 1
done
echo slept
