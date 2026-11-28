#!/bin/bash
here=$(cd "$(dirname "$0")" && pwd); . "$here/base.sh"
irq() { sh_ "awk '\''/touch-0/{print \$2}'\'' /proc/interrupts"; }
us() { "$A" shell "$(su_q "$*")"; }
us "echo '\''x'\''"
