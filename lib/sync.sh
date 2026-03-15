#!/bin/bash
# sync.sh - PowOS RAM ↔ USB Synchronization
#
# Handles syncing between RAM (where OS runs) and USB (persistent storage).
# Detects conflicts when USB was used on another machine.
#
# Commands:
#   powos sync          - Sync RAM ↔ USB (detect conflicts)
#   powos sync status   - Show sync status
#   powos sync resolve  - Resolve conflicts interactively
#   powos sync force    - Force overwrite (RAM wins or USB wins)

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Paths
STATE_DIR="/run/powos"
USB_MOUNT="${POWOS_USB_MOUNT:-/run/powos/usb}"
SYNC_MARKER="${USB_MOUNT}/.powos-sync"
LAYER_SYNC="/usr/lib/powos/ramfs/layer-sync.py"
CACHEFS_SYNC="/usr/lib/powos/cachefs/cachefs-sync.py"

# Get machine ID
get_machine_id() {
    if [[ -f /etc/machine-id ]]; then
        cat /etc/machine-id
    else
        hostname -s 2>/dev/null || echo "unknown"
    fi
}

MACHINE_ID=$(get_machine_id)

# ═══════════════════════════════════════════════════════════════════
# Sync Marker Management
# ═══════════════════════════════════════════════════════════════════

# Read sync marker from USB
read_sync_marker() {
    if [[ -f "$SYNC_MARKER" ]]; then
        source "$SYNC_MARKER"
        echo "${SYNC_MACHINE_ID:-unknown}"
    else
        echo "none"
    fi
}

# Write sync marker to USB
write_sync_marker() {
    local timestamp=$(date +%s)
    local ram_hash=$(get_ram_state_hash)

    cat > "$SYNC_MARKER" << EOF
# PowOS Sync Marker - DO NOT EDIT
SYNC_MACHINE_ID="$MACHINE_ID"
SYNC_TIMESTAMP="$timestamp"
SYNC_HASH="$ram_hash"
SYNC_DATE="$(date -Iseconds)"
EOF
}

# Get hash of current RAM state (for change detection)
get_ram_state_hash() {
    local hash=""

    # Hash the RAM overlay upper dir: captures additions, removals, and modifications
    if [[ -d /run/powos-overlay/upper ]]; then
        hash=$(find /run/powos-overlay/upper -type f -printf '%p %s %T@\n' 2>/dev/null | md5sum | cut -d' ' -f1)
    fi

    echo "${hash:-0}"
}

# ═══════════════════════════════════════════════════════════════════
# Conflict Detection
# ═══════════════════════════════════════════════════════════════════

# Check if USB was modified by another machine
check_for_conflicts() {
    local last_machine=$(read_sync_marker)

    if [[ "$last_machine" == "none" ]]; then
        # No marker = first sync, no conflict
        echo "none"
        return 0
    fi

    if [[ "$last_machine" == "$MACHINE_ID" ]]; then
        # Same machine, no conflict
        echo "none"
        return 0
    fi

    # Different machine wrote to USB!
    echo "conflict"
    return 1
}

# Get details about the conflict
get_conflict_details() {
    if [[ ! -f "$SYNC_MARKER" ]]; then
        echo "No sync marker found"
        return
    fi

    source "$SYNC_MARKER"

    echo "USB was last modified by:"
    echo "  Machine: ${SYNC_MACHINE_ID:-unknown}"
    echo "  Date:    ${SYNC_DATE:-unknown}"
    echo ""
    echo "This machine: $MACHINE_ID"
}

# Count pending changes in RAM
count_ram_changes() {
    local count=0

    # Check RAM overlay
    if [[ -d /run/powos-overlay/upper ]]; then
        count=$(find /run/powos-overlay/upper -type f 2>/dev/null | wc -l)
    fi

    echo "$count"
}

# ═══════════════════════════════════════════════════════════════════
# USB Detection
# ═══════════════════════════════════════════════════════════════════

is_usb_connected() {
    # Check if USB mount exists and is a mountpoint
    if [[ -d "$USB_MOUNT" ]] && mountpoint -q "$USB_MOUNT" 2>/dev/null; then
        return 0
    fi

    # Also check state file
    if [[ -f "$STATE_DIR/usb-state" ]]; then
        source "$STATE_DIR/usb-state"
        [[ "${USB_STATUS:-}" == "connected" ]] && return 0
    fi

    return 1
}

# ═══════════════════════════════════════════════════════════════════
# Sync Commands
# ═══════════════════════════════════════════════════════════════════

ram_sync_status() {
    echo -e "${BOLD}${CYAN}PowOS Sync Status${NC}"
    echo "════════════════════════════════════════"
    echo ""

    # USB Status
    echo -e "${CYAN}USB Drive:${NC}"
    if is_usb_connected; then
        echo -e "  Status: ${GREEN}● Connected${NC}"
        echo "  Mount:  $USB_MOUNT"
    else
        echo -e "  Status: ${YELLOW}○ Disconnected${NC}"
        echo ""
        echo "  USB is not connected. Work is being stored in RAM."
        echo "  Reconnect USB to sync changes."
        return 0
    fi
    echo ""

    # RAM Changes
    echo -e "${CYAN}RAM Changes:${NC}"
    local ram_changes=$(count_ram_changes)
    if [[ "$ram_changes" -gt 0 ]]; then
        echo -e "  Pending: ${YELLOW}$ram_changes files${NC} to sync to USB"
    else
        echo -e "  Pending: ${GREEN}None${NC}"
    fi
    echo ""

    # Conflict Status
    echo -e "${CYAN}Conflict Detection:${NC}"
    local last_machine=$(read_sync_marker)

    if [[ "$last_machine" == "none" ]]; then
        echo -e "  Status: ${GREEN}Clean${NC} (no previous sync marker)"
    elif [[ "$last_machine" == "$MACHINE_ID" ]]; then
        echo -e "  Status: ${GREEN}Clean${NC} (USB last used by this machine)"
    else
        echo -e "  Status: ${RED}CONFLICT${NC}"
        echo ""
        get_conflict_details | sed 's/^/  /'
        echo ""
        echo "  Run 'powos sync resolve' to handle this."
    fi
    echo ""

    # Last sync time
    if [[ -f "$SYNC_MARKER" ]]; then
        source "$SYNC_MARKER"
        echo -e "${CYAN}Last Sync:${NC}"
        echo "  Time:    ${SYNC_DATE:-unknown}"
        echo "  Machine: ${SYNC_MACHINE_ID:-unknown}"
    fi
}

ram_sync_now() {
    echo -e "${BOLD}${CYAN}Syncing RAM ↔ USB${NC}"
    echo "════════════════════════════════════════"
    echo ""

    # Check USB
    if ! is_usb_connected; then
        echo -e "${YELLOW}USB not connected.${NC}"
        echo "Nothing to sync - your work is safe in RAM."
        echo "Reconnect USB when ready."
        return 0
    fi

    # Check for conflicts
    local conflict_status=$(check_for_conflicts || echo "conflict")

    if [[ "$conflict_status" == "conflict" ]]; then
        echo -e "${RED}CONFLICT DETECTED${NC}"
        echo ""
        get_conflict_details
        echo ""
        echo "The USB was modified by another machine since you last synced."
        echo ""
        echo "Options:"
        echo "  powos sync resolve        # Interactive resolution"
        echo "  powos sync --keep-ram     # Overwrite USB with RAM (lose USB changes)"
        echo "  powos sync --keep-usb     # Overwrite RAM with USB (lose RAM changes)"
        echo "  powos sync --merge        # Try to merge (may have conflicts)"
        return 1
    fi

    # No conflict - do normal sync
    echo "No conflicts detected. Syncing..."
    echo ""

    # Sync layer changes (OS customizations)
    echo "Step 1/3: Syncing OS layer changes..."
    if [[ -x "$LAYER_SYNC" ]]; then
        python3 "$LAYER_SYNC" --sync-now 2>/dev/null || echo "  (layer sync not active)"
    else
        echo "  (layer sync not available)"
    fi

    # Sync CacheFS (user data)
    echo "Step 2/3: Syncing user data..."
    if [[ -x "$CACHEFS_SYNC" ]]; then
        python3 "$CACHEFS_SYNC" --sync-now 2>/dev/null || echo "  (cachefs sync not active)"
    else
        echo "  (cachefs sync not available)"
    fi

    # Update sync marker
    echo "Step 3/3: Updating sync marker..."
    write_sync_marker

    echo ""
    echo -e "${GREEN}✓ Sync complete${NC}"
}

ram_sync_resolve() {
    echo -e "${BOLD}${CYAN}Conflict Resolution${NC}"
    echo "════════════════════════════════════════"
    echo ""

    if ! is_usb_connected; then
        echo "USB not connected. Nothing to resolve."
        return 0
    fi

    local conflict_status=$(check_for_conflicts || echo "conflict")

    if [[ "$conflict_status" != "conflict" ]]; then
        echo -e "${GREEN}No conflicts to resolve.${NC}"
        return 0
    fi

    echo "CONFLICT: USB was modified by another machine."
    echo ""
    get_conflict_details
    echo ""

    echo "What would you like to do?"
    echo ""
    echo "  1) Keep RAM changes (overwrite USB)"
    echo "     Your current session's work wins. USB changes are lost."
    echo ""
    echo "  2) Keep USB changes (reload from USB)"
    echo "     USB changes win. Your current RAM changes are lost."
    echo ""
    echo "  3) Merge (try to combine both)"
    echo "     Attempt to merge. May require manual conflict resolution."
    echo ""
    echo "  4) Show diff (see what's different)"
    echo ""
    echo "  5) Cancel"
    echo ""

    read -p "Choice [1-5]: " choice

    case "$choice" in
        1)
            ram_sync_force_ram
            ;;
        2)
            ram_sync_force_usb
            ;;
        3)
            ram_sync_merge
            ;;
        4)
            ram_sync_show_diff
            ram_sync_resolve  # Ask again
            ;;
        *)
            echo "Cancelled."
            ;;
    esac
}

ram_sync_force_ram() {
    echo ""
    echo -e "${YELLOW}Overwriting USB with RAM changes...${NC}"
    echo "USB changes from the other machine will be LOST."
    echo ""
    read -p "Are you sure? [y/N] " -n 1 -r
    echo

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Cancelled."
        return 0
    fi

    # Force sync RAM to USB
    if [[ -x "$LAYER_SYNC" ]]; then
        python3 "$LAYER_SYNC" --sync-now --force 2>/dev/null || true
    fi

    if [[ -x "$CACHEFS_SYNC" ]]; then
        python3 "$CACHEFS_SYNC" --sync-now --force 2>/dev/null || true
    fi

    # Update marker
    write_sync_marker

    echo -e "${GREEN}✓ USB overwritten with RAM changes${NC}"
}

ram_sync_force_usb() {
    echo ""
    echo -e "${YELLOW}Reloading from USB...${NC}"
    echo "Your current RAM changes will be LOST."
    echo ""
    read -p "Are you sure? [y/N] " -n 1 -r
    echo

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Cancelled."
        return 0
    fi

    # This is trickier - we need to reload from USB
    # For now, just update the marker and let user know to reboot
    echo ""
    echo -e "${YELLOW}Note: Full reload requires reboot.${NC}"
    echo ""
    echo "Your options:"
    echo "  1. Reboot now - cleanly load USB state"
    echo "  2. Continue working - USB marker updated, but RAM still has old changes"
    echo ""

    # Update marker to indicate USB is authoritative
    write_sync_marker

    echo -e "${GREEN}✓ Marked USB as authoritative${NC}"
    echo "Reboot recommended to fully load USB state."
}

ram_sync_merge() {
    echo ""
    echo -e "${CYAN}Attempting to merge...${NC}"
    echo ""

    local ram_upper="/run/powos-overlay/upper"
    local usb_custom="$USB_MOUNT/layers/custom"

    if [[ ! -d "$ram_upper" ]] || [[ ! -d "$usb_custom" ]]; then
        echo -e "${YELLOW}Cannot merge: required paths not available.${NC}"
        echo "  RAM upper:      $ram_upper"
        echo "  USB custom:     $usb_custom"
        return 1
    fi

    echo "Merging USB changes into RAM..."
    echo "RAM files that conflict with USB will be saved with .usb-conflict suffix."
    echo ""

    # Copy USB custom layer into RAM upper:
    #   --backup --suffix=.usb-conflict  : save displaced RAM files so user can review them
    #   No --delete                      : preserve RAM-only files (your custom changes)
    if rsync -av --backup --suffix=.usb-conflict \
            "$usb_custom/" "$ram_upper/"; then

        # Update sync marker to reflect merged state
        write_sync_marker

        echo ""

        # Report any .usb-conflict files that need manual review
        local conflict_count
        conflict_count=$(find "$ram_upper" -name "*.usb-conflict" 2>/dev/null | wc -l)

        if [[ "$conflict_count" -gt 0 ]]; then
            echo -e "${YELLOW}Warning: $conflict_count file(s) had conflicts.${NC}"
            echo "Your original RAM versions were saved as .usb-conflict files:"
            find "$ram_upper" -name "*.usb-conflict" 2>/dev/null | head -20 | sed 's/^/  /'
            echo ""
            echo "Review and remove .usb-conflict copies once you are satisfied."
            echo "Then run 'powos sync --keep-ram' to push the merged result to USB."
        else
            echo -e "${GREEN}✓ Merge complete - no conflicts.${NC}"
        fi

        echo ""
        echo -e "${GREEN}✓ Merge complete${NC}"
    else
        echo ""
        echo -e "${RED}Merge failed.${NC} Check rsync output above."
        return 1
    fi
}

ram_sync_show_diff() {
    echo ""
    echo -e "${CYAN}Differences between RAM and USB:${NC}"
    echo ""

    if [[ -d /run/powos-overlay/upper ]] && [[ -d "$USB_MOUNT" ]]; then
        # Show basic diff
        echo "Files only in RAM (your changes):"
        diff -rq /run/powos-overlay/upper "$USB_MOUNT/layers/custom" 2>/dev/null | grep "Only in /run" | head -20 || echo "  (none or can't compare)"
        echo ""
        echo "Files only on USB (other machine's changes):"
        diff -rq /run/powos-overlay/upper "$USB_MOUNT/layers/custom" 2>/dev/null | grep "Only in $USB_MOUNT" | head -20 || echo "  (none or can't compare)"
        echo ""
        echo "Files that differ:"
        diff -rq /run/powos-overlay/upper "$USB_MOUNT/layers/custom" 2>/dev/null | grep "differ" | head -20 || echo "  (none or can't compare)"
    else
        echo "Cannot compare - paths not available"
    fi
}

# Get detailed diff for AI analysis
get_diff_for_ai() {
    local diff_output=""
    local ram_upper="/run/powos-overlay/upper"
    local usb_custom="$USB_MOUNT/layers/custom"

    if [[ ! -d "$ram_upper" ]] || [[ ! -d "$usb_custom" ]]; then
        echo "Cannot compare - paths not available"
        return 1
    fi

    # Get conflict details
    diff_output+="CONFLICT CONTEXT:\n"
    diff_output+="================\n"
    diff_output+="Current machine: $MACHINE_ID\n"
    if [[ -f "$SYNC_MARKER" ]]; then
        source "$SYNC_MARKER"
        diff_output+="USB last modified by: ${SYNC_MACHINE_ID:-unknown}\n"
        diff_output+="USB last modified at: ${SYNC_DATE:-unknown}\n"
    fi
    diff_output+="\n"

    # Files only in RAM
    diff_output+="FILES ONLY IN RAM (current machine's changes):\n"
    diff_output+="----------------------------------------------\n"
    local ram_only
    ram_only=$(diff -rq "$ram_upper" "$usb_custom" 2>/dev/null | grep "Only in /run" | head -30 || true)
    if [[ -n "$ram_only" ]]; then
        diff_output+="$ram_only\n"
    else
        diff_output+="(none)\n"
    fi
    diff_output+="\n"

    # Files only on USB
    diff_output+="FILES ONLY ON USB (other machine's changes):\n"
    diff_output+="--------------------------------------------\n"
    local usb_only
    usb_only=$(diff -rq "$ram_upper" "$usb_custom" 2>/dev/null | grep "Only in $USB_MOUNT" | head -30 || true)
    if [[ -n "$usb_only" ]]; then
        diff_output+="$usb_only\n"
    else
        diff_output+="(none)\n"
    fi
    diff_output+="\n"

    # Files that differ
    diff_output+="FILES THAT DIFFER:\n"
    diff_output+="------------------\n"
    local differs
    differs=$(diff -rq "$ram_upper" "$usb_custom" 2>/dev/null | grep "differ" | head -30 || true)
    if [[ -n "$differs" ]]; then
        diff_output+="$differs\n"

        # For config files, show actual diff (truncated)
        diff_output+="\nSAMPLE DIFFS (config files):\n"
        while IFS= read -r line; do
            local file1 file2
            file1=$(echo "$line" | sed 's/Files \(.*\) and .* differ/\1/')
            file2=$(echo "$line" | sed 's/Files .* and \(.*\) differ/\1/')

            # Only show diff for small text files
            if [[ -f "$file1" ]] && [[ $(wc -c < "$file1") -lt 10000 ]]; then
                if file "$file1" | grep -q "text"; then
                    diff_output+="\n--- $file1\n+++ $file2\n"
                    diff_output+=$(diff -u "$file1" "$file2" 2>/dev/null | head -50 || true)
                    diff_output+="\n"
                fi
            fi
        done <<< "$differs"
    else
        diff_output+="(none)\n"
    fi

    echo -e "$diff_output"
}

ram_sync_resolve_ai() {
    echo -e "${BOLD}${CYAN}AI-Assisted Conflict Resolution${NC}"
    echo "════════════════════════════════════════"
    echo ""

    if ! is_usb_connected; then
        echo "USB not connected. Nothing to resolve."
        return 0
    fi

    local conflict_status=$(check_for_conflicts || echo "conflict")

    if [[ "$conflict_status" != "conflict" ]]; then
        echo -e "${GREEN}No conflicts to resolve.${NC}"
        return 0
    fi

    # Check if AI is available
    if ! command -v ai_call &>/dev/null; then
        # Try to source the AI module
        if [[ -f /usr/lib/powos/ai/agent.sh ]]; then
            source /usr/lib/powos/ai/agent.sh
        elif [[ -f "$(dirname "${BASH_SOURCE[0]}")/ai/agent.sh" ]]; then
            source "$(dirname "${BASH_SOURCE[0]}")/ai/agent.sh"
        fi
    fi

    if ! command -v ai_interactive &>/dev/null; then
        echo -e "${YELLOW}AI not available. Falling back to manual resolution.${NC}"
        echo ""
        ram_sync_resolve
        return
    fi

    # Show the conflict context first
    echo "Conflict detected. Here's what's different:"
    echo ""
    ram_sync_show_diff
    echo ""
    get_conflict_details
    echo ""

    echo "────────────────────────────────────────"
    echo "Starting AI health agent to help you decide."
    echo ""
    echo "The AI has context about the conflict. Ask it questions like:"
    echo "  - 'What do you recommend?'"
    echo "  - 'What would I lose if I keep RAM?'"
    echo "  - 'Can these changes be merged?'"
    echo ""
    echo "When ready, exit the AI and run one of:"
    echo "  powos sync --keep-ram     # Your current machine wins"
    echo "  powos sync --keep-usb     # Other machine wins"
    echo "  powos sync --merge        # Try to combine both"
    echo "────────────────────────────────────────"
    echo ""

    # Gather context for the AI
    local diff_info
    diff_info=$(get_diff_for_ai)

    # Start interactive session with health:sync flavor, providing context
    # The AI agent system will handle the conversation
    # Later with MCP, the AI will have tools to actually execute resolutions
    ai_interactive --agent health:sync --context "SYNC CONFLICT CONTEXT:

$diff_info

The user needs help deciding how to resolve this sync conflict.
Available resolution commands (user runs these after talking to you):
- powos sync --keep-ram    : Keep current machine's RAM changes, overwrite USB
- powos sync --keep-usb    : Keep USB changes (from other machine), discard RAM
- powos sync --merge       : Try to merge both (may need manual intervention)

Help them understand what each option means for their specific situation."
}

# ═══════════════════════════════════════════════════════════════════
# Main Dispatcher
# ═══════════════════════════════════════════════════════════════════

cmd_sync() {
    local action="${1:-}"
    local use_ai=false

    # Check for --ai flag anywhere in args
    for arg in "$@"; do
        if [[ "$arg" == "--ai" ]] || [[ "$arg" == "-a" ]]; then
            use_ai=true
        fi
    done

    case "$action" in
        ""|now)
            ram_sync_now
            ;;
        status|st)
            ram_sync_status
            ;;
        resolve)
            if [[ "$use_ai" == "true" ]]; then
                ram_sync_resolve_ai
            else
                ram_sync_resolve
            fi
            ;;
        --keep-ram|--ram|--force-ram)
            ram_sync_force_ram
            ;;
        --keep-usb|--usb|--force-usb)
            ram_sync_force_usb
            ;;
        --merge|merge)
            ram_sync_merge
            ;;
        diff|--diff)
            ram_sync_show_diff
            ;;
        help|--help|-h)
            echo "PowOS Sync - RAM ↔ USB Synchronization"
            echo ""
            echo "Usage: powos sync [command] [options]"
            echo ""
            echo "Syncs your work between RAM (where you're working) and USB"
            echo "(persistent storage). Detects conflicts when USB was used"
            echo "on another machine."
            echo ""
            echo "Commands:"
            echo "  (none)        Sync now (detect conflicts first)"
            echo "  status        Show sync status"
            echo "  resolve       Interactive conflict resolution"
            echo "  resolve --ai  AI-assisted conflict resolution"
            echo "  diff          Show differences between RAM and USB"
            echo ""
            echo "Conflict Resolution:"
            echo "  --keep-ram    Overwrite USB with RAM (your work wins)"
            echo "  --keep-usb    Reload from USB (USB wins, reboot needed)"
            echo "  --merge       Try to merge both (manual)"
            echo ""
            echo "Options:"
            echo "  --ai, -a      Use AI to analyze conflicts and recommend action"
            echo ""
            echo "Examples:"
            echo "  powos sync              # Normal sync"
            echo "  powos sync status       # Check if there are conflicts"
            echo "  powos sync resolve --ai # AI helps you decide what to do"
            echo "  powos sync --keep-ram   # Force your changes to USB"
            ;;
        *)
            echo "Unknown command: $action"
            echo "Run 'powos sync help' for usage"
            return 1
            ;;
    esac
}

# Allow sourcing or direct execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cmd_sync "$@"
fi
