#!/bin/bash
q() { echo "$1"; }
log() { echo "$*"; }
log "after: listed=$(q "l.map(n=>({key:n.key,time:n.time}))")"
echo "x=`q "{a,b}"`"
