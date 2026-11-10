#!/bin/bash
# lint fixture: each command below is one nested-quote hit (4)
sh_() { "$A" shell "su -c '$*'" 2>/dev/null | tr -d '\r'; }
live=$(sh_ "tail -n +1 $HY | grep -a 'window task $N live' | tail -1")
irq() { sh_ "awk '/touch-0/{s+=\$2} END{print s}' /proc/interrupts"; }
MARK=$(sh_ "date +'%m-%d %H:%M:%S.000'")
"$A" shell "su -c 'grep 'x' /tmp/f'"
