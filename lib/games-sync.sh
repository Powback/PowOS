#!/bin/bash
# games-sync.sh - Sync game data (saves, mods, configs) between PowOS devices
#
# Transport: rsync over SSH — handles large files, resumes interrupted transfers,
#            never executes remote code (read-only SSH on the pull side).
#
# Config:    ~/.config/powos/games-sync.conf  (key=value, parsed safely)
# State:     ~/.config/powos/games-sync-state/<device>.last  (timestamp files)
#
# Designed for the main-PC ↔ Steam Deck use-case but works for any pair of
# PowOS (or plain Linux/SteamOS) devices reachable over SSH.
#
# Entry point: cmd_games_sync "$@"   (called from lib/games.sh cmd_games)
#
# NOTE: sourced into bin/powos — must NOT set -e/-u/pipefail at top level.

source "${POWOS_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/common.sh" 2>/dev/null || {
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'
    CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; NC=$'\033[0m'
    plog()  { echo -e "${CYAN}[games-sync]${NC} $*"; }
    pok()   { echo -e "${GREEN}[games-sync]${NC} $*"; }
    pwarn() { echo -e "${YELLOW}[games-sync]${NC} $*"; }
    perr()  { echo -e "${RED}[games-sync]${NC} $*" >&2; }
}
POWOS_TAG=games-sync

# ── Config paths ──────────────────────────────────────────────────────────────

GSY_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/powos"
GSY_CONFIG_FILE="$GSY_CONFIG_DIR/games-sync.conf"
GSY_STATE_DIR="$GSY_CONFIG_DIR/games-sync-state"

# Default Steam path — overridable via config
GSY_STEAM_DIR="${GSY_STEAM_DIR:-$HOME/.local/share/Steam}"

# ── Presentation helpers ──────────────────────────────────────────────────────

gsy_step() { echo; echo -e "${BOLD}── $* ──${NC}"; }
gsy_ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
gsy_skip() { echo -e "  ${DIM}·${NC} $* ${DIM}(skipped)${NC}"; }

# ── Config ───────────────────────────────────────────────────────────────────

# Safely load a KEY=value or KEY="value" line from a plain config file.
# The file is NEVER sourced — only individual key lookups are performed to
# avoid executing arbitrary code from a user-editable file.
gsy_config_get() {
    local file="$1" key="$2" default="${3:-}" line val
    [[ -f "$file" ]] || { echo "$default"; return 0; }
    line=$(grep -m1 "^${key}=" "$file" 2>/dev/null) || { echo "$default"; return 0; }
    val="${line#*=}"
    val="${val%\"}"   # strip trailing "
    val="${val#\"}"   # strip leading "
    echo "$val"
}

# Parse the [devices] section: lines of the form
#   NAME HOST [USER] [STEAM_PATH]
# Lines starting with # are comments.
gsy_list_devices() {
    [[ -f "$GSY_CONFIG_FILE" ]] || return 0
    local in_devices=0
    while IFS= read -r line; do
        # strip leading whitespace
        line="${line#"${line%%[![:space:]]*}"}"
        [[ -z "$line" || "$line" == '#'* ]] && continue
        if [[ "$line" == '[devices]' ]]; then in_devices=1; continue; fi
        if [[ "$line" == '['*']' ]]; then in_devices=0; continue; fi
        [[ $in_devices -eq 1 ]] && echo "$line"
    done < "$GSY_CONFIG_FILE"
}

# Find a device entry by name; prints "HOST USER STEAM_DIR" or returns 1.
gsy_device_info() {
    local want="$1"
    while IFS= read -r entry; do
        local name host user steam
        read -r name host user steam <<< "$entry"
        [[ "$name" == "$want" ]] || continue
        echo "${host:-$name} ${user:-powos} ${steam:-~/.local/share/Steam}"
        return 0
    done < <(gsy_list_devices)
    return 1
}

# ── Save-path discovery ───────────────────────────────────────────────────────

# Paths that are worth syncing across devices.
# We do NOT sync the full steamapps (game files) by default — they are large
# and most devices install games fresh anyway. Users opt in with --apps.
gsy_local_sync_sources() {
    local steam="$GSY_STEAM_DIR"

    # Steam Cloud save data (the most portable and important data to sync).
    # Path: ~/.local/share/Steam/userdata/<numeric-steam-id>/
    # Each sub-directory is per-user; typically only one account on a PC.
    echo "${steam}/userdata" "Steam save data"

    # Proton/WINE save data that lives OUTSIDE the prefix (some games write to
    # the Linux XDG dirs even under Proton, e.g. via Steam Play file redirect).
    echo "${HOME}/.local/share/Steam/steamapps/compatdata" "Proton prefixes (saves inside)"

    # Common game save dirs outside Steam:
    #   ~/.config/ — Godot games, Unity games that respect XDG
    #   ~/.local/share/ (non-Steam dirs only)
    # We scope to well-known game sub-directories to avoid syncing everything.
    # Users can extend this list via the config file.
}

# Paths that mod managers write to on the local machine.
gsy_local_mod_sources() {
    # Nexus Mods App (native Linux, v0.11+)
    echo "$HOME/.local/share/NexusMods.App" "Nexus Mods App profile + cache"
    # MO2 via Wine/Proton — lives in the prefix or wherever it was installed.
    # We don't know the exact path without inspecting; skip unless configured.
}

# ── Remote SSH helpers ────────────────────────────────────────────────────────

# Build the base SSH command with options suitable for bulk transfers:
#   -q          quiet (suppress banner noise)
#   -o …        non-interactive, skip host-key prompting
gsy_ssh_opts() {
    echo "-q -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"
}

# Test SSH reachability; returns 0 if the host responds, 1 otherwise.
gsy_ssh_test() {
    local host="$1" user="$2"
    # shellcheck disable=SC2086
    ssh $(gsy_ssh_opts) "${user}@${host}" true 2>/dev/null
}

# Expand ~ in a remote path by asking the remote shell (one cheap echo call).
gsy_remote_expand() {
    local host="$1" user="$2" path="$3"
    # If there is no ~ to expand, return as-is to avoid the SSH round-trip.
    [[ "$path" == *'~'* ]] || { echo "$path"; return 0; }
    # shellcheck disable=SC2086
    ssh $(gsy_ssh_opts) "${user}@${host}" "echo $path" 2>/dev/null || echo "$path"
}

# Run rsync from/to a remote, with good defaults for game data:
#   --archive        : preserve timestamps, permissions, symlinks, etc.
#   --compress       : worthwhile for save files (small text/binary)
#   --partial        : keep partially-transferred files to resume
#   --progress       : show per-file progress
#   --exclude caches : skip shader cache, download cache, tmp files
#
# $1 = SRC    $2 = DST    $3... = extra rsync options
gsy_rsync() {
    local src="$1" dst="$2"; shift 2

    local cache_excludes=(
        --exclude='__pycache__'
        --exclude='*.tmp'
        --exclude='steamcmd/'
        --exclude='appcache/'
        --exclude='depotcache/'
        --exclude='logs/'
        --exclude='*.log'
        # Shader cache is GPU-specific — never worth syncing
        --exclude='shadercache/'
    )

    rsync \
        --archive \
        --compress \
        --partial \
        --human-readable \
        "${cache_excludes[@]}" \
        "$@" \
        "$src" "$dst"
}

# ── Core push / pull ──────────────────────────────────────────────────────────

# Push local game data to a remote device.
#   $1 = device name (must exist in config)
#   GSY_DRY_RUN, GSY_WHAT
gsy_push() {
    local device="$1"

    local info host remote_user remote_steam
    if ! info=$(gsy_device_info "$device"); then
        perr "Unknown device '$device'. Add it with:  powos games sync add-device $device <host>"
        return 1
    fi
    read -r host remote_user remote_steam <<< "$info"

    plog "Pushing to $device ($remote_user@$host)…"

    # Connectivity check
    if ! gsy_ssh_test "$host" "$remote_user"; then
        perr "Cannot reach $remote_user@$host — check SSH connectivity."
        return 1
    fi

    local remote_steam_real
    remote_steam_real=$(gsy_remote_expand "$host" "$remote_user" "$remote_steam")

    local rsync_flags=()
    [[ ${GSY_DRY_RUN:-0} -eq 1 ]] && rsync_flags+=(--dry-run --itemize-changes)
    [[ ${GSY_VERBOSE:-0} -eq 1 ]] && rsync_flags+=(--progress)

    local ok=0

    case "${GSY_WHAT:-saves}" in
        saves|all)
            gsy_step "Steam save data"
            local steam_userdata="$GSY_STEAM_DIR/userdata"
            if [[ -d "$steam_userdata" ]]; then
                local remote_dst="${remote_user}@${host}:${remote_steam_real}/userdata/"
                if gsy_rsync "$steam_userdata/" "$remote_dst" \
                        "${rsync_flags[@]}" --mkpath 2>&1; then
                    gsy_ok "Steam userdata → $device"
                else
                    pwarn "rsync failed for Steam userdata (continuing)"
                    ok=1
                fi
            else
                gsy_skip "Steam userdata not found at $steam_userdata"
            fi
            ;;&  # fall-through to mods if GSY_WHAT=all
        mods|all)
            gsy_step "Mod manager data"
            while read -r mod_path mod_label; do
                [[ -z "$mod_path" ]] && continue
                # Expand ~ if present (gsy_local_mod_sources uses $HOME, so
                # ~ should not appear, but be safe).
                mod_path="${mod_path/#\~/$HOME}"
                if [[ -d "$mod_path" ]]; then
                    local mod_base
                    mod_base="$(basename "$mod_path")"
                    local remote_mod="${remote_user}@${host}:${HOME}/.local/share/${mod_base}/"
                    if gsy_rsync "$mod_path/" "$remote_mod" \
                            "${rsync_flags[@]}" --mkpath 2>&1; then
                        gsy_ok "$mod_label → $device"
                    else
                        pwarn "rsync failed for $mod_label (continuing)"
                        ok=1
                    fi
                else
                    gsy_skip "$mod_label not found at $mod_path"
                fi
            done < <(gsy_local_mod_sources)
            ;;
    esac

    if [[ $ok -eq 0 ]]; then
        gsy_record_sync "$device" "push"
        [[ ${GSY_DRY_RUN:-0} -eq 0 ]] && pok "Push to $device complete."
    else
        pwarn "Push to $device completed with errors — check output above."
    fi
    return $ok
}

# Pull game data FROM a remote device.
#   $1 = device name
gsy_pull() {
    local device="$1"

    local info host remote_user remote_steam
    if ! info=$(gsy_device_info "$device"); then
        perr "Unknown device '$device'. Add it with:  powos games sync add-device $device <host>"
        return 1
    fi
    read -r host remote_user remote_steam <<< "$info"

    plog "Pulling from $device ($remote_user@$host)…"

    if ! gsy_ssh_test "$host" "$remote_user"; then
        perr "Cannot reach $remote_user@$host — check SSH connectivity."
        return 1
    fi

    local remote_steam_real
    remote_steam_real=$(gsy_remote_expand "$host" "$remote_user" "$remote_steam")

    local rsync_flags=()
    [[ ${GSY_DRY_RUN:-0} -eq 1 ]] && rsync_flags+=(--dry-run --itemize-changes)
    [[ ${GSY_VERBOSE:-0} -eq 1 ]] && rsync_flags+=(--progress)

    local ok=0

    case "${GSY_WHAT:-saves}" in
        saves|all)
            gsy_step "Steam save data"
            local remote_src="${remote_user}@${host}:${remote_steam_real}/userdata/"
            local local_dst="$GSY_STEAM_DIR/userdata/"
            mkdir -p "$local_dst"
            if gsy_rsync "$remote_src" "$local_dst" "${rsync_flags[@]}" 2>&1; then
                gsy_ok "$device → Steam userdata"
            else
                pwarn "rsync failed for Steam userdata (continuing)"
                ok=1
            fi
            ;;&
        mods|all)
            gsy_step "Mod manager data"
            while read -r mod_path mod_label; do
                [[ -z "$mod_path" ]] && continue
                mod_path="${mod_path/#\~/$HOME}"
                local mod_base
                mod_base="$(basename "$mod_path")"
                local remote_mod="${remote_user}@${host}:${HOME}/.local/share/${mod_base}/"
                local local_mod="$HOME/.local/share/${mod_base}/"
                mkdir -p "$local_mod"
                if gsy_rsync "$remote_mod" "$local_mod" "${rsync_flags[@]}" 2>&1; then
                    gsy_ok "$device → $mod_label"
                else
                    gsy_skip "$mod_label not found on $device (or rsync failed)"
                fi
            done < <(gsy_local_mod_sources)
            ;;
    esac

    if [[ $ok -eq 0 ]]; then
        gsy_record_sync "$device" "pull"
        [[ ${GSY_DRY_RUN:-0} -eq 0 ]] && pok "Pull from $device complete."
    fi
    return $ok
}

# ── State tracking ────────────────────────────────────────────────────────────

# Record a successful sync event for a device.
#   $1 = device name   $2 = direction (push|pull)
gsy_record_sync() {
    local device="$1" direction="$2"
    [[ ${GSY_DRY_RUN:-0} -eq 1 ]] && return 0
    mkdir -p "$GSY_STATE_DIR"
    local state_file="$GSY_STATE_DIR/${device}.last"
    printf '%s\nDIRECTION=%s\nDATE=%s\n' \
        "$(date +%s)" "$direction" "$(date -Iseconds)" \
        > "$state_file"
}

# Print the last sync time for a device, or "never".
gsy_last_sync() {
    local device="$1"
    local state_file="$GSY_STATE_DIR/${device}.last"
    [[ -f "$state_file" ]] || { echo "never"; return 0; }
    # Read safely — never source
    local ts dir date_str
    ts=$(grep -m1 "^[0-9]" "$state_file" 2>/dev/null) || ts=""
    date_str=$(grep -m1 "^DATE=" "$state_file" 2>/dev/null) || date_str=""
    date_str="${date_str#DATE=}"
    echo "${date_str:-$ts}"
}

# ── Device management ─────────────────────────────────────────────────────────

# Add a device entry to the config file.
#   $1 = NAME   $2 = HOST   $3 = USER (optional)   $4 = STEAM_PATH (optional)
gsy_add_device() {
    local name="$1" host="${2:-$1}" user="${3:-}" steam="${4:-}"

    if [[ -z "$name" ]]; then
        perr "Usage:  powos games sync add-device NAME [HOST] [USER] [STEAM_PATH]"
        return 1
    fi

    # Check for duplicates
    if gsy_device_info "$name" &>/dev/null; then
        perr "Device '$name' already exists. Edit $GSY_CONFIG_FILE to change it."
        return 1
    fi

    mkdir -p "$GSY_CONFIG_DIR"
    # Append a [devices] section if the file is new; otherwise append to it.
    if [[ ! -f "$GSY_CONFIG_FILE" ]]; then
        printf '# PowOS games-sync config\n# Generated by: powos games sync add-device\n\n[devices]\n' \
            > "$GSY_CONFIG_FILE"
    elif ! grep -q '^\[devices\]' "$GSY_CONFIG_FILE" 2>/dev/null; then
        printf '\n[devices]\n' >> "$GSY_CONFIG_FILE"
    fi

    # Build the entry line
    local entry="$name $host"
    [[ -n "$user" ]] && entry+=" $user"
    [[ -n "$steam" ]] && entry+=" $steam"

    # Insert after the [devices] header
    # Using awk to append after the [devices] line (works even if devices
    # section is at the end of the file).
    local tmp
    tmp=$(mktemp)
    awk -v entry="$entry" '
        /^\[devices\]/ { print; print entry; next }
        { print }
    ' "$GSY_CONFIG_FILE" > "$tmp" && mv "$tmp" "$GSY_CONFIG_FILE"

    pok "Added device: $entry"
    plog "Test connectivity: ssh ${user:-powos}@$host true"
}

# ── Status ────────────────────────────────────────────────────────────────────

gsy_status() {
    echo -e "${BOLD}${CYAN}Game Sync Status${NC}"
    echo "════════════════════════════════════════"

    local steam="$GSY_STEAM_DIR"
    echo
    echo -e "${CYAN}Local Steam:${NC}"
    if [[ -d "$steam/userdata" ]]; then
        local user_count save_size
        user_count=$(find "$steam/userdata" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
        save_size=$(du -sh "$steam/userdata" 2>/dev/null | cut -f1 || echo "?")
        echo -e "  Userdata: ${GREEN}$user_count account(s)${NC}, ${save_size}"
    else
        echo -e "  Userdata: ${YELLOW}not found${NC} (expected at $steam/userdata)"
    fi

    # Mod manager installs
    local nma_path="$HOME/.local/share/NexusMods.App"
    if [[ -d "$nma_path" ]]; then
        local nma_size
        nma_size=$(du -sh "$nma_path" 2>/dev/null | cut -f1 || echo "?")
        echo -e "  Nexus Mods App: ${GREEN}installed${NC} (${nma_size})"
    fi

    echo
    echo -e "${CYAN}Known devices:${NC}"
    local count=0
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        local name host user steam_path last
        read -r name host user steam_path <<< "$entry"
        last=$(gsy_last_sync "$name")
        local status_str
        # Quick connectivity check (non-blocking, timeout=3s)
        if ssh -q -o BatchMode=yes -o ConnectTimeout=3 \
                "${user:-powos}@${host:-$name}" true 2>/dev/null; then
            status_str="${GREEN}● reachable${NC}"
        else
            status_str="${YELLOW}○ unreachable${NC}"
        fi
        echo -e "  ${BOLD}$name${NC}  ($host)"
        echo -e "    Status: $status_str"
        echo "    Last sync: $last"
        count=$((count + 1))
    done < <(gsy_list_devices)

    if [[ $count -eq 0 ]]; then
        echo -e "  ${DIM}No devices configured.${NC}"
        echo
        echo "  Add a device:"
        echo "    powos games sync add-device steamdeck steamdeck.local deck"
        echo "    powos games sync add-device mypc 192.168.1.10 powos"
    fi
    echo
}

# ── Usage ─────────────────────────────────────────────────────────────────────

gsy_usage() {
    cat << 'EOF'
powos games sync — sync game saves, mods and configs between devices

Transfers game data (Steam saves, mod profiles) between PowOS devices
over SSH + rsync. Designed for the main-PC ↔ Steam Deck workflow.

Usage: powos games sync <command> [options]

Commands:
  status                    Show local save data, known devices, last sync times
  add-device NAME [HOST]    Register a sync peer (HOST defaults to NAME)
  list-devices              List configured devices
  push [--to NAME]          Send local data → remote device
  pull [--from NAME]        Receive data ← remote device

Push/pull options:
  --to / --from NAME        Target device (required if >1 device configured)
  --what saves|mods|all     What to sync (default: saves)
                              saves  Steam userdata only
                              mods   Mod manager profiles (Nexus Mods App, etc.)
                              all    Both saves and mods
  --dry-run                 Show what would transfer, change nothing
  --verbose                 Show per-file rsync progress

Setup flow:
  1. powos games sync add-device steamdeck steamdeck.local deck
  2. powos games sync push --to steamdeck --what all --dry-run  # preview
  3. powos games sync push --to steamdeck --what all            # do it

Prerequisites:
  - SSH access to the remote device (key-based auth recommended):
      ssh-copy-id deck@steamdeck.local
  - The remote device must have rsync installed.
  - Steam save data lives at ~/.local/share/Steam/userdata/ on both sides.

Config file: ~/.config/powos/games-sync.conf
  Override defaults per-machine:
    GSY_STEAM_DIR=/var/mnt/games/steam   # non-default Steam location

  Device entries are in a [devices] section:
    [devices]
    steamdeck  steamdeck.local  deck  ~/.local/share/Steam
    mypc       192.168.1.10     powos ~/.local/share/Steam
EOF
}

# ── Entry point ────────────────────────────────────────────────────────────────

cmd_games_sync() {
    # Global option defaults (exported so gsy_push/gsy_pull can read them)
    GSY_DRY_RUN=0
    GSY_VERBOSE=0
    GSY_WHAT=saves

    local sub="${1:-status}"; shift 2>/dev/null || true

    case "$sub" in
        # ── add-device NAME [HOST] [USER] [STEAM_PATH] ──────────────────
        add-device|add)
            # All remaining positional args belong to gsy_add_device.
            gsy_add_device "$@"
            return
            ;;

        # ── list-devices ────────────────────────────────────────────────
        list-devices|list)
            echo -e "${BOLD}Configured devices${NC}"
            echo "────────────────────"
            local count=0
            while IFS= read -r entry; do
                [[ -z "$entry" ]] && continue
                echo "  $entry"
                count=$((count + 1))
            done < <(gsy_list_devices)
            [[ $count -eq 0 ]] && echo "  (none — run: powos games sync add-device NAME HOST)"
            return
            ;;

        # ── status ──────────────────────────────────────────────────────
        status|st)
            gsy_status
            return
            ;;

        # ── help ────────────────────────────────────────────────────────
        help|-h|--help)
            gsy_usage
            return
            ;;

        # ── push / pull: parse remaining options ─────────────────────────
        push|pull)
            local target_device=""

            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --dry-run)      GSY_DRY_RUN=1; shift ;;
                    --verbose|-v)   GSY_VERBOSE=1; shift ;;
                    --what)         GSY_WHAT="${2:-saves}"; shift 2 ;;
                    --to|--from)    target_device="${2:-}"; shift 2 ;;
                    -h|--help)      gsy_usage; return 0 ;;
                    -*)             perr "Unknown option: $1"; gsy_usage; return 1 ;;
                    *)              # bare device name
                                    [[ -z "$target_device" ]] && target_device="$1"
                                    shift ;;
                esac
            done

            case "$GSY_WHAT" in
                saves|mods|all) ;;
                *) perr "--what must be saves, mods, or all"; return 1 ;;
            esac

            # Auto-select device when exactly one is configured
            if [[ -z "$target_device" ]]; then
                local all_devices
                all_devices=$(gsy_list_devices)
                local dev_count
                dev_count=$(echo "$all_devices" | grep -c . 2>/dev/null || echo 0)
                if [[ "$dev_count" -eq 1 ]]; then
                    target_device=$(echo "$all_devices" | awk 'NR==1{print $1}')
                else
                    local flag="--to"; [[ "$sub" == pull ]] && flag="--from"
                    perr "Specify a device with $flag NAME"
                    [[ "$dev_count" -gt 0 ]] && \
                        perr "Known: $(echo "$all_devices" | awk '{print $1}' | tr '\n' ' ')"
                    return 1
                fi
            fi

            if [[ "$sub" == push ]]; then
                gsy_push "$target_device"
            else
                gsy_pull "$target_device"
            fi
            ;;

        *)
            perr "Unknown games sync command: $sub"
            echo
            gsy_usage
            return 1
            ;;
    esac
}
