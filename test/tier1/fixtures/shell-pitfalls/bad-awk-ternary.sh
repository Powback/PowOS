#!/bin/bash
# lint fixture: each command below is one awk-ternary hit (3)
desk_top() { awk '{t=$2-$1} END{printf "%d", t>0?t:0}' "$1"; }
awk -v n=3 '{print n<2?"few":"many"}' /dev/null
awk 'BEGIN{t=1; print t>=0?t:0}'
