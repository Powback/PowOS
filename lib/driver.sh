#!/bin/bash
# driver.sh - switch the NVIDIA driver *channel* by rebasing to a different
# published image tag. Fork-agnostic: it reads the repo from the currently
# booted bootc image and swaps only the tag, so it works for any fork.
#
#   powos driver status              # current channel / image
#   powos driver stable              # -> :nvidia-open           (tested drivers)
#   powos driver testing             # -> :nvidia-open-testing   (newest drivers)
#
# Notes / honesty:
#   - Switching applies on the NEXT reboot; the old deployment stays as rollback.
#   - Only meaningful on a registry-tracked install (after `bootc switch` to a
#     ghcr image). A local/oci origin can't derive a repo — it'll tell you.
#   - Private images need `powos registry login` first, or the pull 401s.
#   - This is the installed-system counterpart to `powos base` (USB layer variants).
set -uo pipefail
source "${POWOS_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/common.sh"
POWOS_TAG=driver


# Booted image reference (bare registry ref, or an oci:/… path we can't rebase).
# Uses rpm-ostree (works without root; newer bootc's `status` requires root).
drv_current_ref() {
    rpm-ostree status --json 2>/dev/null | python3 -c '
import json, sys
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
ref = ""
for dep in d.get("deployments", []):
    if dep.get("booted"):
        ref = dep.get("container-image-reference") or ""
        break
for pre in ("ostree-unverified-registry:", "ostree-image-signed:",
            "ostree-unverified-image:", "ostree-remote-image:"):
    if ref.startswith(pre):
        ref = ref[len(pre):]; break
if "://" in ref:          # ostree-remote-image: <remote>:docker://<ref>, or docker://<ref>
    ref = ref.split("://", 1)[1]
print(ref)' 2>/dev/null
}

# channel name -> image tag
drv_tag_for() {
    case "$1" in
        stable)  echo "nvidia-open" ;;
        testing) echo "nvidia-open-testing" ;;
        *)       return 1 ;;
    esac
}

drv_channel_of_tag() {
    case "$1" in
        nvidia-open)         echo "stable" ;;
        nvidia-open-testing) echo "testing" ;;
        *)                   echo "$1" ;;
    esac
}

cmd_driver_status() {
    local ref tag
    ref="$(drv_current_ref)"
    echo -e "${BOLD}NVIDIA driver channel${NC}"
    if [[ -z "$ref" ]]; then
        pwarn "Couldn't read the booted image (old bootc? not bootc?)."; return 0
    fi
    tag="${ref##*:}"
    echo "  image:   $ref"
    echo "  channel: $(drv_channel_of_tag "$tag")"
    if command -v nvidia-smi >/dev/null 2>&1; then
        echo "  driver:  $(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)"
    fi
    echo "  switch:  powos driver stable | powos driver testing"
}

cmd_driver_switch() {
    local channel="$1" tag ref repo target
    tag="$(drv_tag_for "$channel")" || { perr "Unknown channel '$channel' (use: stable|testing)"; return 1; }
    ref="$(drv_current_ref)"
    if [[ -z "$ref" || "$ref" != *"/"*":"* || "$ref" == oci:* ]]; then
        perr "Current install isn't tracking a registry image ('$ref')."
        perr "First point it at your image, e.g.:"
        perr "  powos registry login ghcr.io   # if private"
        perr "  sudo bootc switch ghcr.io/<you>/powos:nvidia-open"
        return 1
    fi
    repo="${ref%:*}"; repo="${repo%@*}"
    target="$repo:$tag"
    if [[ "$ref" == "$target" ]]; then
        pok "Already on '$channel' ($target)."; return 0
    fi
    plog "Switching driver channel → $channel"
    plog "  $ref"
    plog "  → $target"
    if ! sudo bootc switch "$target"; then
        perr "bootc switch failed. If it 401'd, run: powos registry login ghcr.io"
        return 1
    fi
    pok "Staged. Review with 'sudo bootc status', then reboot to apply."
    pok "Old deployment stays as rollback (pick it at the boot menu if needed)."
    read -rp "Reboot now? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] && sudo systemctl reboot
}

cmd_driver() {
    local sub="${1:-status}"; shift || true
    case "$sub" in
        status|"")        cmd_driver_status ;;
        stable|testing)   cmd_driver_switch "$sub" ;;
        *) perr "Usage: powos driver {status|stable|testing}"; return 1 ;;
    esac
}
