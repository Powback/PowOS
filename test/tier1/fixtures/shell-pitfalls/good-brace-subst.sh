#!/bin/bash
q() { echo "$1"; }
log() { echo "$*"; }
L='l.map(n=>({key:n.key,time:n.time}))'
log "after: listed=$(q "$L")"
v="$(q "{a,b}")"
log "x=$(q '{a,b}')"
log "y=$(q "{a}") z=${v:-{a,b}}"
read -r a <<<"$(js "{a,b}")"
