#!/bin/bash
# lib/devices/deploy.sh <ssh-target> [name] [kind] [blocker.service...] (from a dev machine): install or update the
# PowOS device agent on a Linux PowOS device as a systemd --user unit, with its unit record in units.d (the record is
# units/<host>/powos-deviced.json in this repo). Keeps the device's identity, peers and TLS key (state dir untouched).
#   lib/devices/deploy.sh powos@192.168.50.58 "Desk" desktop llama-swap.service powmap-scan.service
# Undo: the record's remove.stop + remove.commands.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
T=${1:?usage: deploy.sh <ssh-target> [name] [kind] [blocker.service...]}; NAME=${2:-}; KIND=${3:-}; shift $(( $# < 3 ? $# : 3 ))
REC=$(ls "$here"/../../units/*/powos-deviced.json 2>/dev/null | head -1)
blockers=$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "$@")
cfg=$(python3 -c 'import json,sys; n,k,b=sys.argv[1:4]; d={"sleep_blockers": json.loads(b)}; n and d.update(name=n); k and d.update(kind=k); print(json.dumps(d))' "$NAME" "$KIND" "$blockers")
ssh -o BatchMode=yes "$T" 'mkdir -p ~/.local/lib/powos/devices ~/.config/systemd/user ~/.config/powos/units.d'
scp -q "$here/powos-deviced" "$T:.local/lib/powos/devices/powos-deviced"
scp -q "$here/powos-deviced.service" "$T:.config/systemd/user/powos-deviced.service"
[ -n "$REC" ] && scp -q "$REC" "$T:.config/powos/units.d/powos-deviced.json"
ssh -o BatchMode=yes "$T" "chmod +x ~/.local/lib/powos/devices/powos-deviced && printf '%s\n' '$cfg' > ~/.config/powos/deviced.json &&
  systemctl --user daemon-reload && systemctl --user enable powos-deviced.service >/dev/null 2>&1 &&
  systemctl --user restart powos-deviced.service && sleep 2 && systemctl --user is-active powos-deviced.service &&
  python3 ~/.local/lib/powos/devices/powos-deviced info"
