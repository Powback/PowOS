#!/bin/bash
# mobile.sh - PowOS Mobile Mode
#
# Copy OS layers to RAM so USB can be unplugged.
# Everything enabled by default, user can disable what they don't need.
#
# Commands:
#   powos mobile              - Enable mobile mode (copy to RAM)
#   powos mobile -c           - Customize what to include
#   powos mobile status       - Show current mode
#   powos mobile disable      - Return to USB-backed mode

set -euo pipefail

# Colors
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
NC=$'\033[0m'

# Paths
STATE_DIR="${POWOS_STATE_DIR:-/run/powos}"
# USB data partition mount point. The dracut module bind-mounts it at
# /run/powos/usb-layers (the old /mnt/powos-usb default never existed).
USB_MOUNT="${POWOS_USB_MOUNT:-/run/powos/usb-layers}"
USB_LAYERS="${USB_MOUNT}/layers"
# Mobile staging lives ON the USB data partition, NOT in tmpfs:
# everything under /run vanishes at the reboot this feature requires, so a
# future dracut consumer must be able to find the staged layer, state, and
# exclusions on persistent storage.
MOBILE_DIR="${USB_MOUNT}/mobile"
MOBILE_LAYER="${MOBILE_DIR}/layer"
MOBILE_STATE="${MOBILE_DIR}/state"
MOBILE_EXCLUDE="${MOBILE_DIR}/exclude"

# ═══════════════════════════════════════════════════════════════════
# Package & Category Detection (from rpm, not hardcoded)
# ═══════════════════════════════════════════════════════════════════

# Get all installed packages with their groups
get_packages_with_groups() {
    if command -v rpm &>/dev/null; then
        # RPM-based (Fedora/Bazzite)
        rpm -qa --qf '%{NAME}\t%{GROUP}\t%{SIZE}\n' 2>/dev/null | sort
    elif command -v dpkg-query &>/dev/null; then
        # Debian-based (fallback)
        dpkg-query -W -f='${Package}\t${Section}\t${Installed-Size}\n' 2>/dev/null | sort
    else
        echo "unknown"
    fi
}

# Get unique categories from installed packages
get_categories() {
    if command -v rpm &>/dev/null; then
        rpm -qa --qf '%{GROUP}\n' 2>/dev/null | sort -u | grep -v "^(none)$" || true
    elif command -v dpkg-query &>/dev/null; then
        dpkg-query -W -f='${Section}\n' 2>/dev/null | sort -u || true
    fi
}

# Get packages in a specific category
get_packages_in_category() {
    local category="$1"
    if command -v rpm &>/dev/null; then
        rpm -qa --qf '%{NAME}\t%{GROUP}\t%{SIZE}\n' 2>/dev/null | \
            awk -F'\t' -v cat="$category" '$2 == cat {print $1}'
    fi
}

# Get size of a category (sum of package sizes)
get_category_size() {
    local category="$1"
    if command -v rpm &>/dev/null; then
        rpm -qa --qf '%{GROUP}\t%{SIZE}\n' 2>/dev/null | \
            awk -F'\t' -v cat="$category" '$1 == cat {sum += $2} END {print sum+0}'
    else
        echo "0"
    fi
}

# Get total size of all packages
get_total_size() {
    if command -v rpm &>/dev/null; then
        rpm -qa --qf '%{SIZE}\n' 2>/dev/null | awk '{sum += $1} END {print sum+0}'
    else
        echo "0"
    fi
}

# Get files for a package
get_package_files() {
    local pkg="$1"
    if command -v rpm &>/dev/null; then
        rpm -ql "$pkg" 2>/dev/null || true
    elif command -v dpkg &>/dev/null; then
        dpkg -L "$pkg" 2>/dev/null || true
    fi
}

# ═══════════════════════════════════════════════════════════════════
# Size Formatting
# ═══════════════════════════════════════════════════════════════════

format_size() {
    local bytes="$1"
    if [[ $bytes -ge 1073741824 ]]; then
        echo "$(( bytes / 1073741824 )).$(( (bytes % 1073741824) * 10 / 1073741824 )) GB"
    elif [[ $bytes -ge 1048576 ]]; then
        echo "$(( bytes / 1048576 )) MB"
    elif [[ $bytes -ge 1024 ]]; then
        echo "$(( bytes / 1024 )) KB"
    else
        echo "$bytes B"
    fi
}

# ═══════════════════════════════════════════════════════════════════
# RAM Detection
# ═══════════════════════════════════════════════════════════════════

get_total_ram() {
    awk '/MemTotal/ {print $2 * 1024}' /proc/meminfo
}

get_available_ram() {
    awk '/MemAvailable/ {print $2 * 1024}' /proc/meminfo
}

# ═══════════════════════════════════════════════════════════════════
# Exclusion Management
# ═══════════════════════════════════════════════════════════════════

load_exclusions() {
    if [[ -f "$MOBILE_EXCLUDE" ]]; then
        cat "$MOBILE_EXCLUDE"
    fi
}

save_exclusions() {
    local exclusions="$1"
    if ! mkdir -p "$(dirname "$MOBILE_EXCLUDE")" 2>/dev/null; then
        echo -e "${RED}Error: cannot save exclusions - USB not mounted at $USB_MOUNT?${NC}" >&2
        return 1
    fi
    echo "$exclusions" > "$MOBILE_EXCLUDE"
}

is_excluded() {
    local item="$1"
    local exclusions
    exclusions=$(load_exclusions)
    echo "$exclusions" | grep -qx "$item" 2>/dev/null
}

# ═══════════════════════════════════════════════════════════════════
# Mobile Mode State
# ═══════════════════════════════════════════════════════════════════

get_mobile_state() {
    if [[ -f "$MOBILE_STATE" ]]; then
        cat "$MOBILE_STATE"
    else
        echo "disabled"
    fi
}

set_mobile_state() {
    local state="$1"
    if ! mkdir -p "$(dirname "$MOBILE_STATE")" 2>/dev/null; then
        echo -e "${YELLOW}Warning: cannot write mobile state - USB not mounted at $USB_MOUNT?${NC}" >&2
        return 1
    fi
    echo "$state" > "$MOBILE_STATE"
}

# "staged" means files were copied but mobile mode is NOT active (live
# remount / boot integration is not implemented). Both states count as
# "already set up" for enable/disable purposes.
is_mobile_enabled() {
    local state
    state=$(get_mobile_state)
    [[ "$state" == "enabled" || "$state" == "staged" ]]
}

# ═══════════════════════════════════════════════════════════════════
# Interactive Menu
# ═══════════════════════════════════════════════════════════════════

show_menu() {
    # Check for dialog/whiptail
    local dialog_cmd=""
    if command -v dialog &>/dev/null; then
        dialog_cmd="dialog"
    elif command -v whiptail &>/dev/null; then
        dialog_cmd="whiptail"
    fi

    if [[ -n "$dialog_cmd" ]]; then
        show_dialog_menu "$dialog_cmd"
    else
        show_simple_menu
    fi
}

show_dialog_menu() {
    local dialog_cmd="$1"
    local checklist_items=()
    local exclusions
    exclusions=$(load_exclusions)

    echo -e "${CYAN}Loading package categories...${NC}" >&2

    # Get categories and build checklist
    while IFS= read -r category; do
        [[ -z "$category" ]] && continue

        local size_bytes
        size_bytes=$(get_category_size "$category")
        local size_fmt
        size_fmt=$(format_size "$size_bytes")

        # Check if excluded
        local state="on"
        if echo "$exclusions" | grep -qx "category:$category" 2>/dev/null; then
            state="off"
        fi

        # Shorten category name for display
        local display_name="${category##*/}"  # Take last part of path
        [[ -z "$display_name" ]] && display_name="$category"

        checklist_items+=("$category" "$display_name ($size_fmt)" "$state")
    done < <(get_categories)

    # Show dialog
    local result
    result=$($dialog_cmd --checklist "Mobile Mode - Select categories to include\n\nUse SPACE to toggle, ENTER to confirm" \
        20 70 12 "${checklist_items[@]}" 3>&1 1>&2 2>&3) || return 1

    # Convert result to exclusions (what's NOT selected)
    local new_exclusions=""
    while IFS= read -r category; do
        [[ -z "$category" ]] && continue
        if ! echo "$result" | grep -q "\"$category\""; then
            new_exclusions+="category:$category"$'\n'
        fi
    done < <(get_categories)

    save_exclusions "$new_exclusions"
    return 0
}

show_simple_menu() {
    # Fallback text-based menu
    local exclusions
    exclusions=$(load_exclusions)

    echo -e "${BOLD}${CYAN}Mobile Mode - Category Selection${NC}"
    echo "════════════════════════════════════════════════════════"
    echo ""
    echo "Select categories to EXCLUDE from mobile mode."
    echo "(Everything is included by default)"
    echo ""

    local i=1
    local -A cat_map

    while IFS= read -r category; do
        [[ -z "$category" ]] && continue

        local size_bytes
        size_bytes=$(get_category_size "$category")
        local size_fmt
        size_fmt=$(format_size "$size_bytes")

        local status="[✓]"
        if echo "$exclusions" | grep -qx "category:$category" 2>/dev/null; then
            status="[ ]"
        fi

        # Shorten for display
        local display_name="${category##*/}"
        [[ -z "$display_name" ]] && display_name="$category"

        printf "  %s %2d) %-30s %s\n" "$status" "$i" "$display_name" "$size_fmt"
        cat_map[$i]="$category"
        ((i++))
    done < <(get_categories)

    echo ""
    echo "Commands: <number> toggle, 'a' all on, 'n' none, 'd' done, 'q' quit"
    echo ""

    while true; do
        read -p "Choice: " choice

        case "$choice" in
            q|Q)
                return 1
                ;;
            d|D)
                return 0
                ;;
            a|A)
                save_exclusions ""
                echo "All categories enabled."
                show_simple_menu
                return $?
                ;;
            n|N)
                local all_excluded=""
                while IFS= read -r category; do
                    [[ -z "$category" ]] && continue
                    all_excluded+="category:$category"$'\n'
                done < <(get_categories)
                save_exclusions "$all_excluded"
                echo "All categories disabled."
                show_simple_menu
                return $?
                ;;
            [0-9]*)
                if [[ -n "${cat_map[$choice]:-}" ]]; then
                    local category="${cat_map[$choice]}"
                    if echo "$exclusions" | grep -qx "category:$category" 2>/dev/null; then
                        # Remove from exclusions
                        exclusions=$(echo "$exclusions" | grep -vx "category:$category" || true)
                        echo "Enabled: $category"
                    else
                        # Add to exclusions on its OWN line. load_exclusions
                        # strips the trailing newline, so a plain += would glue
                        # the new entry onto the last one
                        # ("category:Gamescategory:Office") and break grep -qx.
                        if [[ -n "$exclusions" ]]; then
                            exclusions+=$'\n'
                        fi
                        exclusions+="category:$category"
                        echo "Disabled: $category"
                    fi
                    save_exclusions "$exclusions"
                else
                    echo "Invalid choice"
                fi
                ;;
            *)
                echo "Invalid choice"
                ;;
        esac
    done
}

# ═══════════════════════════════════════════════════════════════════
# Copy to RAM
# ═══════════════════════════════════════════════════════════════════

copy_layers_to_ram() {
    local exclusions
    exclusions=$(load_exclusions)

    echo -e "${BOLD}${CYAN}Staging OS files for mobile mode...${NC}"
    echo "Target: $MOBILE_LAYER (on the USB data partition)"
    echo ""

    # Create mobile layer directory (lives on the USB data partition so it
    # survives the reboot this feature needs)
    if ! mkdir -p "$MOBILE_LAYER" 2>/dev/null; then
        echo -e "${RED}Error: cannot create $MOBILE_LAYER - USB not mounted at $USB_MOUNT?${NC}"
        return 1
    fi

    # Get list of categories to include
    local included_categories=()
    while IFS= read -r category; do
        [[ -z "$category" ]] && continue
        if ! echo "$exclusions" | grep -qx "category:$category" 2>/dev/null; then
            included_categories+=("$category")
        fi
    done < <(get_categories)

    # Calculate total size
    local total_size=0
    for category in "${included_categories[@]}"; do
        local cat_size
        cat_size=$(get_category_size "$category")
        total_size=$((total_size + cat_size))
    done

    echo "Categories to copy: ${#included_categories[@]}"
    echo "Total size: $(format_size $total_size)"
    echo ""

    # Check RAM
    local available
    available=$(get_available_ram)
    local needed=$((total_size + 1073741824))  # Add 1GB buffer

    if [[ $needed -gt $available ]]; then
        echo -e "${RED}Not enough RAM!${NC}"
        echo "  Need: $(format_size $needed)"
        echo "  Available: $(format_size $available)"
        echo ""
        echo "Try excluding some categories with: powos mobile -c"
        return 1
    fi

    # Copy files for each included category
    local copied=0
    local fail_count=0
    for category in "${included_categories[@]}"; do
        local display_name="${category##*/}"
        [[ -z "$display_name" ]] && display_name="$category"

        echo -ne "  ${display_name}: "

        # Get packages in this category and copy their files.
        # rpm -ql lists BOTH directories and files:
        #  - directories are just created (never cp'd: `cp -a dir existing/`
        #    would copy INTO it and nest duplicate trees)
        #  - files are copied to their exact target path
        while IFS= read -r pkg; do
            [[ -z "$pkg" ]] && continue
            while IFS= read -r file; do
                [[ -z "$file" ]] && continue
                [[ ! -e "$file" ]] && continue

                if [[ -d "$file" && ! -L "$file" ]]; then
                    if ! mkdir -p "$MOBILE_LAYER$file" 2>/dev/null; then
                        fail_count=$((fail_count + 1))
                    fi
                else
                    local dir
                    dir=$(dirname "$file")
                    if ! mkdir -p "$MOBILE_LAYER$dir" 2>/dev/null; then
                        fail_count=$((fail_count + 1))
                        continue
                    fi
                    if ! cp -a "$file" "$MOBILE_LAYER$file" 2>/dev/null; then
                        fail_count=$((fail_count + 1))
                    fi
                fi
            done < <(get_package_files "$pkg")
        done < <(get_packages_in_category "$category")

        local cat_size
        cat_size=$(get_category_size "$category")
        copied=$((copied + cat_size))
        echo -e "${GREEN}done${NC} ($(format_size $cat_size))"
    done

    echo ""
    if [[ $fail_count -gt 0 ]]; then
        echo -e "${YELLOW}Warning: $fail_count file(s)/dir(s) failed to copy.${NC}"
        echo "The staged layer is incomplete - do not rely on it."
    fi
    echo -e "${GREEN}✓ Staged $(format_size $copied) to $MOBILE_LAYER${NC}"

    [[ $fail_count -eq 0 ]]
}

# ═══════════════════════════════════════════════════════════════════
# Remount Overlayfs
# ═══════════════════════════════════════════════════════════════════

remount_with_mobile() {
    echo -e "${CYAN}Remounting with mobile layer...${NC}"

    # This is the tricky part - need to insert mobile layer
    # For now, we'll note that this requires root and possibly
    # stopping services

    # Check if we can remount
    if [[ $EUID -ne 0 ]]; then
        echo -e "${YELLOW}Note: Remounting requires root.${NC}"
        echo "Run: sudo powos mobile enable"
        return 1
    fi

    # The mobile layer should be inserted between upper and lower layers
    # New stack: upper (RAM writes) + mobile (RAM copy) + USB layers

    # For a live remount, we may need to:
    # 1. Sync any pending writes
    # 2. Remount overlay with new lowerdir

    # NOT IMPLEMENTED: the overlay stack is untouched. Do NOT set state to
    # "enabled" here - that previously made the tooling claim the USB was
    # safe to unplug while custom/updates/base lowerdirs still lived on it.
    echo -e "${YELLOW}Live remount not yet implemented (WIP).${NC}"
    echo "Files are staged at: $MOBILE_LAYER"
    echo "There is no boot integration for this layer yet either, so mobile"
    echo "mode is NOT active - the OS still runs from USB-backed layers."

    set_mobile_state "staged"
    return 0
}

remount_without_mobile() {
    echo -e "${CYAN}Returning to USB-backed mode...${NC}"

    if [[ $EUID -ne 0 ]]; then
        echo -e "${YELLOW}Note: Remounting requires root.${NC}"
        return 1
    fi

    # Remove the staged mobile layer
    if [[ -d "$MOBILE_LAYER" ]]; then
        rm -rf "$MOBILE_LAYER"
        echo "Removed staged mobile layer ($MOBILE_LAYER)"
    fi

    set_mobile_state "disabled"
    return 0
}

# ═══════════════════════════════════════════════════════════════════
# Main Commands
# ═══════════════════════════════════════════════════════════════════

mobile_status() {
    echo -e "${BOLD}${CYAN}Mobile Mode Status${NC}"
    echo "════════════════════════════════════════"
    echo ""

    local state
    state=$(get_mobile_state)

    case "$state" in
        staged)
            echo -e "Mode: ${YELLOW}Staged (NOT active)${NC}"
            echo "OS files have been copied for mobile mode, but live remount /"
            echo "boot integration is not implemented yet (WIP)."
            echo -e "${RED}USB is still required - do NOT unplug it.${NC}"
            ;;
        enabled)
            # Legacy state from older builds that set "enabled" without ever
            # remounting. Never claim the OS is fully in RAM.
            echo -e "Mode: ${YELLOW}Marked enabled (UNVERIFIED)${NC}"
            echo "Live remount is not implemented in this build; this state is"
            echo "stale. Assume the OS still runs from USB-backed layers."
            echo -e "${RED}Do NOT unplug the USB.${NC}"
            ;;
        *)
            echo -e "Mode: ${YELLOW}Normal (USB-backed)${NC}"
            echo "USB required for full functionality."
            ;;
    esac
    echo ""

    # USB and sync status
    echo -e "${CYAN}Sync:${NC}"
    if [[ -d "${USB_LAYERS%/layers}" ]] && mountpoint -q "${USB_LAYERS%/layers}" 2>/dev/null; then
        echo -e "  USB: ${GREEN}Connected${NC} - changes syncing to USB"
    else
        echo -e "  USB: ${YELLOW}Disconnected${NC} - changes queued in RAM"
        echo "       (Will sync automatically when USB reconnects)"
    fi
    echo ""

    # RAM info
    local total_ram available_ram
    total_ram=$(get_total_ram)
    available_ram=$(get_available_ram)
    echo "RAM:"
    echo "  Total:     $(format_size $total_ram)"
    echo "  Available: $(format_size $available_ram)"
    echo ""

    # OS size
    local os_size
    os_size=$(get_total_size)
    echo "OS Size: $(format_size $os_size)"
    echo ""

    # Exclusions
    local exclusions
    exclusions=$(load_exclusions)
    if [[ -n "$exclusions" ]]; then
        echo "Excluded categories:"
        echo "$exclusions" | sed 's/^category:/  - /' | grep -v "^$" || true
    else
        echo "All categories included."
    fi
    echo ""

    # Mobile layer (staged on the USB data partition)
    if [[ -d "$MOBILE_LAYER" ]]; then
        local mobile_size
        mobile_size=$(du -sb "$MOBILE_LAYER" 2>/dev/null | cut -f1)
        echo "Staged mobile layer: $(format_size ${mobile_size:-0}) at $MOBILE_LAYER"
    fi
}

mobile_exclude() {
    # Add categories/packages to exclusion list
    local items=("$@")
    local exclusions
    exclusions=$(load_exclusions)

    for item in "${items[@]}"; do
        if ! echo "$exclusions" | grep -qx "category:$item" 2>/dev/null; then
            # Append on its own line: load_exclusions strips the trailing
            # newline, so add the separator explicitly or entries get glued
            # together ("category:Gamescategory:Office").
            if [[ -n "$exclusions" ]]; then
                exclusions+=$'\n'
            fi
            exclusions+="category:$item"
            echo "Excluded: $item"
        fi
    done

    save_exclusions "$exclusions"
}

mobile_include() {
    # Remove categories/packages from exclusion list
    local items=("$@")
    local exclusions
    exclusions=$(load_exclusions)

    for item in "${items[@]}"; do
        exclusions=$(echo "$exclusions" | grep -vx "category:$item" || true)
        echo "Included: $item"
    done

    save_exclusions "$exclusions"
}

mobile_include_all() {
    save_exclusions ""
    echo "All categories included."
}

mobile_exclude_all() {
    local all_excluded=""
    while IFS= read -r category; do
        [[ -z "$category" ]] && continue
        all_excluded+="category:$category"$'\n'
    done < <(get_categories)
    save_exclusions "$all_excluded"
    echo "All categories excluded."
}

mobile_list_categories() {
    local exclusions
    exclusions=$(load_exclusions)

    echo -e "${BOLD}${CYAN}Package Categories${NC}"
    echo "════════════════════════════════════════"
    echo ""

    while IFS= read -r category; do
        [[ -z "$category" ]] && continue

        local size_bytes
        size_bytes=$(get_category_size "$category")
        local size_fmt
        size_fmt=$(format_size "$size_bytes")

        local status="${GREEN}[✓]${NC}"
        if echo "$exclusions" | grep -qx "category:$category" 2>/dev/null; then
            status="${DIM}[ ]${NC}"
        fi

        local display_name="${category##*/}"
        [[ -z "$display_name" ]] && display_name="$category"

        printf "  %b %-35s %s\n" "$status" "$display_name" "$size_fmt"
    done < <(get_categories)

    echo ""

    # Show totals
    local total=0
    local included=0
    while IFS= read -r category; do
        [[ -z "$category" ]] && continue
        local cat_size
        cat_size=$(get_category_size "$category")
        total=$((total + cat_size))
        if ! echo "$exclusions" | grep -qx "category:$category" 2>/dev/null; then
            included=$((included + cat_size))
        fi
    done < <(get_categories)

    echo "Total: $(format_size $total)"
    echo "Selected: $(format_size $included)"
}

mobile_enable() {
    local customize=false
    local force=false

    # Parse args
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -c|--customize)
                customize=true
                shift
                ;;
            -f|--force)
                force=true
                shift
                ;;
            *)
                shift
                ;;
        esac
    done

    if is_mobile_enabled && [[ "$force" != true ]]; then
        echo -e "${YELLOW}Mobile mode already enabled.${NC}"
        echo "Run 'powos mobile disable' first, or use --force"
        return 0
    fi

    # Show menu if customizing (interactive)
    if [[ "$customize" == true ]]; then
        if ! show_menu; then
            echo "Cancelled."
            return 0
        fi
    fi

    # Copy layers
    if ! copy_layers_to_ram; then
        return 1
    fi

    # Remount (WIP: currently only records the staged state, see above)
    remount_with_mobile

    echo ""
    echo -e "${YELLOW}${BOLD}Mobile mode is NOT active - this feature is WIP.${NC}"
    echo -e "${RED}Do NOT unplug the USB: the OS still runs from USB-backed layers.${NC}"
    echo ""
    echo "OS files were staged to $MOBILE_LAYER for a future"
    echo "boot integration. Run 'powos mobile disable' to free that space."
}

mobile_disable() {
    if ! is_mobile_enabled; then
        echo -e "${YELLOW}Mobile mode not enabled.${NC}"
        return 0
    fi

    remount_without_mobile

    echo ""
    echo -e "${GREEN}Returned to normal (USB-backed) mode.${NC}"
}

# ═══════════════════════════════════════════════════════════════════
# CLI Entry Point
# ═══════════════════════════════════════════════════════════════════

cmd_mobile() {
    local action="${1:-}"
    shift || true

    case "$action" in
        ""|enable)
            mobile_enable "$@"
            ;;
        -c|--customize)
            mobile_enable --customize "$@"
            ;;
        status|st)
            mobile_status
            ;;
        disable|off)
            mobile_disable
            ;;
        categories|cats|list)
            mobile_list_categories
            ;;
        exclude)
            if [[ $# -eq 0 ]]; then
                echo "Usage: powos mobile exclude <category>..."
                echo "Use 'powos mobile categories' to see available categories"
                return 1
            fi
            mobile_exclude "$@"
            ;;
        include)
            if [[ $# -eq 0 ]]; then
                echo "Usage: powos mobile include <category>..."
                echo "Use 'powos mobile categories' to see available categories"
                return 1
            fi
            mobile_include "$@"
            ;;
        include-all|all)
            mobile_include_all
            ;;
        exclude-all|none)
            mobile_exclude_all
            ;;
        help|--help|-h)
            echo "PowOS Mobile Mode"
            echo ""
            echo "Copy OS layers to RAM so USB can be unplugged."
            echo "By default, everything is included."
            echo ""
            echo "Usage: powos mobile [command] [args]"
            echo ""
            echo "Commands:"
            echo "  (none)              Enable mobile mode (copy to RAM)"
            echo "  -c, --customize     Interactive menu to customize"
            echo "  status              Show current mobile mode status"
            echo "  disable             Return to USB-backed mode"
            echo ""
            echo "Category Management (non-interactive):"
            echo "  categories          List all categories with sizes"
            echo "  exclude <cat>...    Exclude categories from mobile"
            echo "  include <cat>...    Include categories in mobile"
            echo "  include-all         Include all categories (default)"
            echo "  exclude-all         Exclude all categories"
            echo ""
            echo "Examples:"
            echo "  powos mobile                    # Enable with current settings"
            echo "  powos mobile -c                 # Interactive customization"
            echo "  powos mobile categories         # List categories"
            echo "  powos mobile exclude Games      # Exclude Games category"
            echo "  powos mobile include-all        # Reset to include everything"
            echo "  powos mobile enable             # Then enable mobile mode"
            echo ""
            echo "LLM/Script Usage:"
            echo "  powos mobile exclude-all"
            echo "  powos mobile include 'System Environment/Base'"
            echo "  powos mobile include 'User Interface/Desktops'"
            echo "  powos mobile enable"
            ;;
        *)
            echo "Unknown command: $action"
            echo "Run 'powos mobile help' for usage"
            return 1
            ;;
    esac
}

# Allow sourcing or direct execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cmd_mobile "$@"
fi
