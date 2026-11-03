#!/bin/bash
# hosts/gpu-195/gpu-fan/install.sh - install + enable powos-gpu-fan (fan curve + power cap) on an NVIDIA PowOS host.
# Run as root from a PowOS checkout:  sudo bash hosts/gpu-195/gpu-fan/install.sh      (idempotent)
#   --remove   stop, disable and delete it; the fans go back to the vBIOS curve, power limits to default
# /usr/local (= /var/usrlocal on Bazzite/rpm-ostree) and /etc persist across rpm-ostree updates and reboots.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
[[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }

if [[ "${1:-}" == "--remove" ]]; then
    systemctl disable --now powos-gpu-fan.service || true
    rm -f /usr/local/bin/powos-gpu-fan /etc/systemd/system/powos-gpu-fan.service /etc/powos/units.d/gpu-fan.json
    systemctl daemon-reload
    echo "removed; fans on the vBIOS curve"
    exit 0
fi

install -D -m 755 "$HERE/powos-gpu-fan" /usr/local/bin/powos-gpu-fan
install -D -m 644 "$HERE/powos-gpu-fan.service" /etc/systemd/system/powos-gpu-fan.service
install -D -m 644 "$REPO/units/gpu-195/gpu-fan.json" /etc/powos/units.d/gpu-fan.json
systemctl daemon-reload
systemctl enable powos-gpu-fan.service
systemctl restart powos-gpu-fan.service
sleep 6
systemctl --no-pager --lines=8 status powos-gpu-fan.service || true
/usr/bin/python3 /usr/local/bin/powos-gpu-fan status
