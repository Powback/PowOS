#!/bin/bash
# mods/deploy.sh — Overlayfs deployment for the native PowOS mod manager.
#
# Mounts an overlayfs where the game dir is the bottom (read-only) layer,
# staged mod dirs are stacked above in priority order, and a scratch upper
# layer catches runtime writes. The game sees the merged view.
#
# Mount methods (in priority order):
#   1. powos-mods-mount (scoped sudoers helper) — real kernel mount, visible
#      system-wide, survives Steam restarts, works with pressure-vessel.
#      Uses /run/powos-mods (root-owned tmpfs, auto-clean on reboot).
#   2. fuse-overlayfs — persistent FUSE daemon, no root needed, ~2x I/O.
#      Uses /tmp/powos-mods (user-writable).
#
# Requires: core.sh sourced first (manifest helpers, game dir resolution).

set -uo pipefail

# Mount base differs by method:
#   kernel → /run/powos-mods  (root-owned, constructed by the helper)
#   fuse   → /tmp/powos-mods  (user-writable, no root needed)
MODS_MOUNT_BASE_KERNEL="/run/powos-mods"
MODS_MOUNT_BASE_FUSE="${MODS_MOUNT_BASE:-/tmp/powos-mods}"
MODS_MOUNT_HELPER="${MODS_MOUNT_HELPER:-/usr/lib/powos/powos-mods-mount}"

# ── mount method detection ──────────────────────────────────────────────

mods_deploy_method() {
    # Check sudoers helper first
    if [[ -x "$MODS_MOUNT_HELPER" ]] && sudo -n "$MODS_MOUNT_HELPER" check 2>/dev/null; then
        echo "kernel"
        return 0
    fi

    # Check fuse-overlayfs
    if command -v fuse-overlayfs &>/dev/null; then
        echo "fuse"
        return 0
    fi

    perr "No overlay method available."
    perr "Run: powos mods setup   (configures sudoers mount helper)"
    perr "  or: sudo dnf install fuse-overlayfs   (FUSE fallback)"
    return 1
}

# ── overlay paths ───────────────────────────────────────────────────────
# These return the EXPECTED paths. For kernel method, the helper constructs
# the actual dirs under /run/powos-mods. For fuse, we create them ourselves.

_mods_mount_base() {
    local method
    method="$(mods_deploy_method 2>/dev/null)" || method="fuse"
    case "$method" in
        kernel) echo "$MODS_MOUNT_BASE_KERNEL" ;;
        *)      echo "$MODS_MOUNT_BASE_FUSE" ;;
    esac
}

_mods_mount_dir()  { echo "$(_mods_mount_base)/$1"; }
_mods_merged_dir() { echo "$(_mods_mount_base)/$1/merged"; }
_mods_upper_dir()  { echo "$(_mods_mount_base)/$1/upper"; }
_mods_work_dir()   { echo "$(_mods_mount_base)/$1/work"; }

# ── mount ───────────────────────────────────────────────────────────────

mods_deploy_mount() {
    local game="$1"

    # Check Flatpak Steam
    mods_check_steam_flatpak || return 1

    mods_load_game_conf "$game" || return 1

    # ASI games don't use overlays
    if [[ "${GAME_BACKEND:-}" == "asi" ]]; then
        plog "ASI game — no overlay needed (mods are direct file drops)."
        return 0
    fi

    local game_dir
    game_dir="$(mods_game_dir "$GAME_APPID")" || {
        perr "Game not installed (appid $GAME_APPID). Install it via Steam first."
        return 1
    }

    local merged; merged="$(_mods_merged_dir "$game")"
    if mountpoint -q "$merged" 2>/dev/null; then
        plog "Already mounted at $merged"
        return 0
    fi

    # Get enabled staging dirs in priority order
    local staging_dirs
    staging_dirs="$(mods_manifest_enabled_staging_dirs "$game")" || {
        perr "No enabled mods to deploy."
        return 1
    }

    if [[ -z "$staging_dirs" ]]; then
        perr "No enabled mods with valid staging dirs."
        return 1
    fi

    # Build lowerdir string: highest-priority mod first (leftmost wins),
    # pristine game dir last (bottom layer).
    local lowerdir=""
    while IFS= read -r dir; do
        [[ -z "$dir" ]] && continue
        lowerdir="${lowerdir:+$lowerdir:}$dir"
    done <<< "$staging_dirs"
    lowerdir="${lowerdir}:${game_dir}"

    # Check lowerdir string length
    local opts_len=${#lowerdir}
    if (( opts_len > 3800 )); then
        pwarn "lowerdir string is ${opts_len} chars (limit ~4096). Consider pre-merge staging for >30 mods."
    fi

    # Detect method and mount
    local method
    method="$(mods_deploy_method)" || return 1

    case "$method" in
        kernel)
            plog "Mounting overlay (kernel, via mount helper)..."
            # New interface: helper takes slug + lowerdir, constructs everything else
            sudo "$MODS_MOUNT_HELPER" mount "$game" "$lowerdir" || {
                perr "Kernel overlay mount failed."
                return 1
            }
            ;;
        fuse)
            local upper; upper="$(_mods_upper_dir "$game")"
            local work; work="$(_mods_work_dir "$game")"
            merged="$(_mods_merged_dir "$game")"
            mkdir -p "$merged" "$upper" "$work"

            plog "Mounting overlay (fuse-overlayfs)..."
            fuse-overlayfs \
                -o "lowerdir=${lowerdir},upperdir=${upper},workdir=${work}" \
                "$merged" || {
                perr "fuse-overlayfs mount failed."
                return 1
            }
            ;;
    esac

    mods_manifest_set_deploy_state "$game" "true"
    pok "Overlay mounted at $merged"
    plog "Game will see modded files when launched via powos-game-shim."
}

# ── unmount ─────────────────────────────────────────────────────────────

mods_deploy_unmount() {
    local game="$1"
    local merged; merged="$(_mods_merged_dir "$game")"

    if ! mountpoint -q "$merged" 2>/dev/null; then
        plog "Not mounted."
        mods_manifest_set_deploy_state "$game" "false" 2>/dev/null
        return 0
    fi

    local method
    method="$(mods_deploy_method 2>/dev/null)" || method="fuse"

    case "$method" in
        kernel)
            # New interface: helper takes slug only
            sudo "$MODS_MOUNT_HELPER" umount "$game" || {
                perr "Unmount failed. Game may be running — close it first."
                return 1
            }
            ;;
        fuse)
            fusermount3 -u "$merged" 2>/dev/null \
                || fusermount -u "$merged" 2>/dev/null \
                || umount "$merged" 2>/dev/null || {
                perr "Unmount failed. Game may be running — close it first."
                return 1
            }
            ;;
    esac

    mods_manifest_set_deploy_state "$game" "false"
    pok "Overlay unmounted. Game directory is pristine."
}

# ── refresh (clear upper layer) ─────────────────────────────────────────

mods_deploy_refresh() {
    local game="$1"
    local upper; upper="$(_mods_upper_dir "$game")"
    local merged; merged="$(_mods_merged_dir "$game")"

    if mountpoint -q "$merged" 2>/dev/null; then
        mods_deploy_unmount "$game" || return 1
    fi

    if [[ -d "$upper" ]]; then
        rm -rf "$upper"
        mkdir -p "$upper"
        plog "Upper layer cleared."
    fi

    mods_deploy_mount "$game"
}

# ── Steam launch options ───────────────────────────────────────────────

mods_deploy_set_steam_launch() {
    local game="$1"
    mods_load_game_conf "$game" || return 1

    local shim="/usr/lib/powos/powos-game-shim"
    # Fall back to dev source tree
    if [[ ! -f "$shim" ]]; then
        shim="${POWOS_SRC:-/var/lib/powos/src}/bin/powos-game-shim"
    fi
    if [[ ! -f "$shim" ]]; then
        shim="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../bin/powos-game-shim"
    fi

    if [[ ! -f "$shim" ]]; then
        pwarn "powos-game-shim not found. Set Steam launch options manually:"
        pwarn "  powos-game-shim %command%"
        return 0
    fi

    local launch_opts="$shim %command%"
    plog "Setting Steam launch options for appid $GAME_APPID..."
    mods_set_launch_options "$GAME_APPID" "$launch_opts" || {
        pwarn "Could not auto-set launch options. Set manually in Steam:"
        pwarn "  $launch_opts"
    }
}

# ── deploy command (high-level) ─────────────────────────────────────────

mods_deploy_cmd() {
    local game="${1:?Usage: powos mods deploy <game>}"
    local refresh=false

    if [[ "${2:-}" == "--refresh" ]]; then
        refresh=true
    fi

    if $refresh; then
        mods_deploy_refresh "$game"
    else
        mods_deploy_mount "$game"
    fi

    # Offer to set Steam launch options
    local merged; merged="$(_mods_merged_dir "$game")"
    if mountpoint -q "$merged" 2>/dev/null; then
        plog "To activate, set Steam launch options to:"
        plog "  ${BOLD}powos-game-shim %command%${NC}"
        plog "Or run: ${BOLD}powos mods deploy $game --steam${NC}"
    fi
}

mods_undeploy_cmd() {
    local game="${1:?Usage: powos mods undeploy <game>}"
    mods_deploy_unmount "$game"
    plog "To restore Steam launch options, remove powos-game-shim from the game's properties."
}
