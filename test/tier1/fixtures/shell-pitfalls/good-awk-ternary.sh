#!/bin/bash
# lint fixture: none of these is a hit
desk_top() { awk '{t=$2-$1} END{printf "%d", (t>0?t:0)}' "$1"; }
awk '{print (n<2)?"few":"many"}' /dev/null
awk '{print $1 > "/tmp/out"}' /dev/null
awk '/a>b?/{print "x ? y > z"}' /dev/null
awk '{print $1 > "/tmp/out"; y = t>0?t:0}' /dev/null
printf '%s\n' "a>b ? c : d"
awk 'BEGIN{t=1; printf("%d\n", t>0?t:0)}'
