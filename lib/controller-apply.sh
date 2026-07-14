#!/bin/bash
# controller-apply.sh - reapply saved PowOS controller deadzone(s) on joystick
# hotplug. This is the "permanent" half of `powos controller`: the udev rule
# 60-powos-controller.rules starts powos-controller@<node>.service on every
# joystick plug-in, which runs this with the event node as its argument.
#
#   controller-apply.sh <event-node>   reapply for one node (e.g. event2)
#   controller-apply.sh                 reapply for every connected joystick
#
# Kept tiny: it just sources controller.sh (pure function defs) and calls the
# shared low-level apply helpers. Runs as root under systemd, so it always has
# write access to /dev/input/eventN.
set -uo pipefail

# shellcheck source=/dev/null
source "${POWOS_LIB:-/usr/lib/powos}/controller.sh"

node="${1:-}"
node="${node##*/}"   # tolerate a /dev/input/eventN path or bare eventN

if [[ -n "$node" ]]; then
    _ctrl_apply_node "$node"
else
    _ctrl_apply_all
fi
