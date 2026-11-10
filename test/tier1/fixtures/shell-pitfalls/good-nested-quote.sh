#!/bin/bash
# lint fixture: none of these is a hit
sh_() { "$A" shell "su -c '$*'" 2>/dev/null | tr -d '\r'; }
live=$(sh_ "tail -n +1 $HY | grep -a \"window task $N live\" | tail -1")
irq() { sh_ "awk '\''/touch-0/{s+=\$2} END{print s}'\'' /proc/interrupts"; }
sh_ "input tap $(awk -v a="$1" 'BEGIN{print int(a+(2-a)*3)}') 10"
"$A" shell "su -c 'cat /proc/interrupts' | grep touch"
"$A" shell "su -c 'echo hi'; echo 'local'"
"$A" shell 'su -c "grep x /tmp/f"'
sh_ 'dumpsys window'
sh_ "grep 'a' f" # lint-ok: fixture escape
