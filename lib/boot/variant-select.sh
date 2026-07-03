#!/bin/bash
# variant-select.sh - pick which base variant to boot on THIS machine.
#
# One x86-64 PowOS USB can carry more than one base variant (e.g. an NVIDIA
# build and an AMD/Intel build). At boot we either auto-detect the GPU and pick
# the matching variant, or honor a manual override from the boot menu. This lets
# the same USB boot cleanly on an NVIDIA desktop, an AMD box, and a Steam Deck.
#
# Manual override (boot menu / kernel cmdline):  rd.powos.variant=nvidia|main|auto
#   auto (default) = detect the GPU and choose.
#
# The functions here are pure (all inputs passed in) so they unit-test without
# real hardware. `variant_select_main` wires them to the real cmdline / GPU /
# USB manifest for the dracut boot stage.

# ── Pure decision logic ───────────────────────────────────────────

# Map a detect_gpu() value to a base-variant name.
#   nvidia-*            -> nvidia-open  (open kernel modules; DEFAULT for NVIDIA)
#   amd*, intel, other  -> main         (mesa/open drivers; boots anywhere incl. Deck)
# The closed proprietary NVIDIA driver is the "nvidia" variant — not auto-picked;
# it's chosen explicitly (older Maxwell/Pascal cards) via rd.powos.variant=nvidia.
variant_from_gpu() {
    case "$1" in
        nvidia*) echo "nvidia-open" ;;
        *)       echo "main" ;;
    esac
}

# Is $1 present in the comma-separated available list $2?
variant_available() {
    local want="$1" avail="$2" v
    IFS=',' read -ra _vs <<< "$avail"
    for v in "${_vs[@]}"; do
        [[ "$v" == "$want" ]] && return 0
    done
    return 1
}

# Decide the variant. Echoes "<variant>\t<reason>".
#   $1 override   : "", "auto", or an explicit variant name (from the boot menu)
#   $2 gpu        : detect_gpu() output
#   $3 available  : comma-separated variants actually present on the USB
# Precedence: explicit+available override > GPU auto-detect > first available > main.
variant_select() {
    local override="$1" gpu="$2" available="$3"

    # 1) Explicit manual pick from the boot menu (not "auto").
    if [[ -n "$override" && "$override" != "auto" ]]; then
        if variant_available "$override" "$available"; then
            printf '%s\tmanual override\n' "$override"; return 0
        fi
        # Requested variant isn't on this USB — fall through to auto, but say so.
        local mapped; mapped=$(variant_from_gpu "$gpu")
        if variant_available "$mapped" "$available"; then
            printf '%s\toverride "%s" not on USB; auto-detected\n' "$mapped" "$override"; return 0
        fi
    fi

    # 2) Auto-detect from the GPU.
    local mapped; mapped=$(variant_from_gpu "$gpu")
    if variant_available "$mapped" "$available"; then
        printf '%s\tGPU auto-detect (%s)\n' "$mapped" "$gpu"; return 0
    fi

    # 3) Fallbacks: prefer "main" (open drivers boot anywhere), else first listed.
    if variant_available "main" "$available"; then
        printf 'main\tfallback (no %s variant on USB)\n' "$mapped"; return 0
    fi
    local first="${available%%,*}"
    if [[ -n "$first" ]]; then
        printf '%s\tfallback (only variant on USB)\n' "$first"; return 0
    fi
    printf 'main\tdefault (no variants listed)\n'; return 0
}

# ── Real-input wiring (for the dracut boot stage) ─────────────────

# Read rd.powos.variant= from the kernel cmdline ("" if absent).
variant_cmdline_override() {
    local -a args=()
    read -ra args < /proc/cmdline 2>/dev/null || true
    local arg
    for arg in "${args[@]}"; do
        case "$arg" in
            rd.powos.variant=*) echo "${arg#rd.powos.variant=}"; return 0 ;;
        esac
    done
    echo ""
}

# List variants present on the USB. A variant "X" exists if the USB layers dir
# has a base-X/ directory (or a manifest lists it). $1 = USB layers root.
variant_list_available() {
    local root="${1:-/run/powos-usb-layers/layers}" d name out=""
    for d in "$root"/base-*/; do
        [[ -d "$d" ]] || continue
        name=$(basename "$d"); name="${name#base-}"
        out="${out:+$out,}$name"
    done
    echo "$out"
}

# Full selection using real inputs. Echoes just the chosen variant name.
# Sourceable helpers detect_gpu()/log come from hardware-detect.sh when present.
variant_select_main() {
    local override gpu available
    override=$(variant_cmdline_override)
    if command -v detect_gpu &>/dev/null; then
        gpu=$(detect_gpu 2>/dev/null)
    else
        gpu="${MOCK_HARDWARE:-unknown}"
    fi
    available=$(variant_list_available "${1:-/run/powos-usb-layers/layers}")

    local line variant reason
    line=$(variant_select "$override" "$gpu" "$available")
    variant="${line%%$'\t'*}"; reason="${line#*$'\t'}"
    echo "PowOS: booting variant '$variant' ($reason)" >&2
    echo "$variant"
}
