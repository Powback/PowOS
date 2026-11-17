#!/bin/bash
# hosts/gpu-195/display-gpu/install.sh - make Proton/DXVK games on gpu-195 render on the GPU that drives the monitor,
# without a per-game launch option. Run as the desktop user (powos) on gpu-195, from the PowOS checkout. No sudo.
#
#   bash hosts/gpu-195/display-gpu/install.sh            derive the display GPU, write the env file, register the unit
#   bash hosts/gpu-195/display-gpu/install.sh --dry-run  print what it would write; writes nothing
#   bash hosts/gpu-195/display-gpu/install.sh --remove   delete the env file, unregister the unit
#
# Why: with two identical RTX 3090s DXVK picked GPU1 (02:00.0) while the monitor hangs off GPU0 (01:00.0); every
# frame then crossed GPUs (NVKMS PRIME import error, dxvk-submit stuck in the kernel). The launch option
# DXVK_FILTER_DEVICE_UUID=<display GPU> fixed it per game; this sets the same variable for the whole user session.
#
# How: ~/.config/environment.d/60-powos-display-gpu.conf (systemd-environment-d-generator). The user manager reads
# it at start and on `systemctl --user daemon-reload`; Plasma's plasmashell and every app it launches (Steam runs as
# app-steam@<id>.service) inherit it, and pressure-vessel passes DXVK_* through to Proton (the same as the launch
# option, which also only sets the env in front of the whole Steam Linux Runtime command). A per-game launch option
# `DXVK_FILTER_DEVICE_UUID=... %command%` still wins: it is set later, in front of that game's command.
#
# The UUID is derived, never hardcoded: the one PCI device whose DRM connector reports `connected` -> its NVIDIA UUID
# (nvidia-smi; for NVIDIA the Vulkan deviceUUID DXVK matches is the same 16 bytes). No connected display, displays
# on two GPUs, or no UUID for it = a clear error and nothing written. Re-run after moving the monitor to another card.
#
# Not covered: vkd3d-proton (DX12) has no UUID filter, only VKD3D_FILTER_DEVICE_NAME (both cards share a name) and
# VKD3D_VULKAN_DEVICE (an enumeration index, not an identity), so DX12 games keep their default (docs/GPU-SERVERS-PLAN.md).
# AI containers are unaffected: rootless podman/CDI containers do not inherit the session env, and only DXVK reads it.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
SYSFS="${POWOS_SYSFS:-/sys}"                     # tests point these at a fake tree / stub tools
NVIDIA_SMI="${NVIDIA_SMI:-nvidia-smi}"
IP="${POWOS_IP:-ip}"
HOST_IP=192.168.50.195                          # gpu-195 only (its hostname is the generic "powos")
ENV_DIR="$HOME/.config/environment.d"
ENV_FILE="$ENV_DIR/60-powos-display-gpu.conf"
UNIT="$REPO/units/gpu-195/display-gpu-env.json"
mode="${1:-install}"

die() { echo "display-gpu: $*" >&2; exit 1; }

if [[ "$mode" == --remove ]]; then
    rm -f "$ENV_FILE"
    python3 "$REPO/lib/apps/powos-units" unregister display-gpu-env || true
    echo "removed $ENV_FILE; takes effect after the next Plasma login (or systemctl --user daemon-reload) + a full Steam restart"
    exit 0
fi
[[ "$mode" == install || "$mode" == --dry-run ]] || die "usage: install.sh [--dry-run|--remove]"

"$IP" -4 -o addr show | grep -q " $HOST_IP/" || die "not gpu-195 (no $HOST_IP here); this default is for gpu-195 only"

# Display GPU: PCI devices behind connected DRM connectors (card<N>-<connector>/status).
pcis=()
for status in "$SYSFS"/class/drm/card*-*/status; do
    [[ -f "$status" && "$(cat "$status")" == connected ]] || continue
    conn="$(basename "$(dirname "$status")")"
    pci="$(basename "$(readlink -f "$SYSFS/class/drm/${conn%%-*}/device")")"
    [[ " ${pcis[*]-} " == *" $pci "* ]] || pcis+=("$pci")
done
(( ${#pcis[@]} > 0 )) || die "no connected display found under $SYSFS/class/drm; plug the monitor in and re-run"
(( ${#pcis[@]} == 1 )) || die "displays on more than one GPU (${pcis[*]}); ambiguous, not guessing"
pci="${pcis[0]}"

# nvidia-smi prints 00000000:01:00.0, sysfs 0000:01:00.0: compare bus:device.function, case-insensitive.
want="$(tr 'A-F' 'a-f' <<<"${pci#*:}")"
uuid=""
while IFS=, read -r bus id; do
    bus="$(tr 'A-F' 'a-f' <<<"${bus// /}")"
    [[ "${bus#*:}" == "$want" ]] && uuid="${id// /}"
done < <("$NVIDIA_SMI" --query-gpu=pci.bus_id,uuid --format=csv,noheader)
[[ -n "$uuid" ]] || die "nvidia-smi lists no GPU at $pci (the display GPU)"
hex="$(tr -d -- '-' <<<"${uuid#GPU-}" | tr 'A-F' 'a-f')"
[[ "$hex" =~ ^[0-9a-f]{32}$ ]] || die "unexpected UUID '$uuid' for $pci"

content="# Managed by PowOS hosts/gpu-195/display-gpu/install.sh (unit display-gpu-env); remove: install.sh --remove.
# DXVK renders on the display GPU $pci ($uuid). A per-game launch option overrides this.
DXVK_FILTER_DEVICE_UUID=$hex"

if [[ "$mode" == --dry-run ]]; then
    echo "display GPU: $pci $uuid"
    echo "would write $ENV_FILE:"
    echo "$content"
    echo "would register $UNIT"
    exit 0
fi
mkdir -p "$ENV_DIR"
printf '%s\n' "$content" > "$ENV_FILE.new" && mv "$ENV_FILE.new" "$ENV_FILE"
python3 "$REPO/lib/apps/powos-units" register "$UNIT"
echo "wrote $ENV_FILE (DXVK_FILTER_DEVICE_UUID=$hex, display GPU $pci)"
echo "takes effect for Steam started after the next Plasma login (or: systemctl --user daemon-reload, then quit Steam fully and start it again); running games are untouched"
