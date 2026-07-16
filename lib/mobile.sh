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
# USB staging dir for potential future boot integration (not used for live mode).
MOBILE_DIR="${USB_MOUNT}/mobile"
MOBILE_LAYER="${MOBILE_DIR}/layer"
MOBILE_STATE="${MOBILE_DIR}/state"
MOBILE_EXCLUDE="${MOBILE_DIR}/exclude"

# Live-mode paths (runtime, in /run — lost on reboot by design).
# The tmpfs is mounted here; bind-mount record tracks which paths are live.
MOBILE_RAM_DIR="${STATE_DIR}/mobile-ram"
MOBILE_BIND_RECORD="${STATE_DIR}/mobile-bind-record"

# Top-level directories that are safe to bind-mount over.
# Excluded (never bind):
#   /proc /sys /dev /run /tmp  — virtual/runtime filesystems
#   /home                      — user data
#   /mnt /media                — removable media mount points
#   /boot                      — boot partition
#   /etc                       — live auth/service config (bind risks breakage)
#   /var                       — mixed runtime state and data
# On modern Fedora/Bazzite /bin, /lib, /lib64, /sbin are symlinks into /usr,
# so binding /usr covers them automatically.
BIND_SAFE_TOPLEVEL=( /usr /opt /libexec )

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

is_mobile_enabled() {
    # Mobile is truly active only when bind mounts are in place.
    # The state file persists across reboots but the bind record lives in /run
    # (lost on reboot). Trust the bind record over the state file.
    [[ -f "$MOBILE_BIND_RECORD" ]]
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

# ─── internal: copy selected RPM-category files to a given destination dir ────
# dest_dir must already exist or be creatable.
# Returns: 0 on success, non-zero if copy was incomplete.
# Prints progress; caller sets up tmpfs / staging dir first.
_copy_categories_to_dir() {
    local dest_dir="$1"
    local exclusions
    exclusions=$(load_exclusions)

    # Enumerate included categories
    local included_categories=()
    while IFS= read -r category; do
        [[ -z "$category" ]] && continue
        if ! echo "$exclusions" | grep -qx "category:$category" 2>/dev/null; then
            included_categories+=("$category")
        fi
    done < <(get_categories)

    echo "Categories to copy: ${#included_categories[@]}"
    echo ""

    # Copy files for each included category.
    # rpm -ql lists BOTH directories and regular files:
    #  - directories: mkdir -p (never cp'd — cp -a dir existing/ would nest)
    #  - files/symlinks: copied to exact target path under dest_dir
    local copied=0
    local fail_count=0
    for category in "${included_categories[@]}"; do
        local display_name="${category##*/}"
        [[ -z "$display_name" ]] && display_name="$category"
        echo -ne "  ${display_name}: "

        while IFS= read -r pkg; do
            [[ -z "$pkg" ]] && continue
            while IFS= read -r file; do
                [[ -z "$file" ]] && continue
                [[ ! -e "$file" ]] && continue

                if [[ -d "$file" && ! -L "$file" ]]; then
                    if ! mkdir -p "${dest_dir}${file}" 2>/dev/null; then
                        fail_count=$((fail_count + 1))
                    fi
                else
                    local dir
                    dir=$(dirname "$file")
                    if ! mkdir -p "${dest_dir}${dir}" 2>/dev/null; then
                        fail_count=$((fail_count + 1))
                        continue
                    fi
                    if ! cp -a "$file" "${dest_dir}${file}" 2>/dev/null; then
                        fail_count=$((fail_count + 1))
                    fi
                fi
            done < <(get_package_files "$pkg")
        done < <(get_packages_in_category "$category")

        local cat_size
        cat_size=$(get_category_size "$category")
        copied=$((copied + cat_size))
        echo -e "${GREEN}done${NC} ($(format_size "$cat_size"))"
    done

    echo ""
    if [[ $fail_count -gt 0 ]]; then
        echo -e "${YELLOW}Warning: $fail_count file(s)/dir(s) failed to copy.${NC}"
    fi
    echo -e "${GREEN}✓ Copied $(format_size "$copied") to ${dest_dir}${NC}"

    [[ $fail_count -eq 0 ]]
}

# ─── calculate selected-category total size (bytes) ──────────────────────────
calculate_mobile_size() {
    local exclusions
    exclusions=$(load_exclusions)
    local total=0
    while IFS= read -r category; do
        [[ -z "$category" ]] && continue
        if ! echo "$exclusions" | grep -qx "category:$category" 2>/dev/null; then
            total=$((total + $(get_category_size "$category")))
        fi
    done < <(get_categories)
    echo "$total"
}

# ─── mount a tmpfs sized for the mobile RAM layer ────────────────────────────
# $1 = size in bytes (tmpfs will be sized at 120% of this)
create_mobile_tmpfs() {
    local size_bytes="$1"
    # 20% headroom over the RPM-reported size (actual on-disk may differ)
    local tmpfs_size=$(( size_bytes * 12 / 10 ))
    [[ $tmpfs_size -lt 67108864 ]] && tmpfs_size=67108864  # 64 MB floor

    mkdir -p "$MOBILE_RAM_DIR"
    if mountpoint -q "$MOBILE_RAM_DIR" 2>/dev/null; then
        echo -e "${YELLOW}tmpfs already mounted at $MOBILE_RAM_DIR${NC}"
        return 0
    fi
    if ! mount -t tmpfs -o "size=${tmpfs_size}" tmpfs "$MOBILE_RAM_DIR"; then
        echo -e "${RED}Failed to mount tmpfs at $MOBILE_RAM_DIR${NC}"
        return 1
    fi
    echo "Mounted ${tmpfs_size}-byte tmpfs at $MOBILE_RAM_DIR"
}

# ─── copy selected categories into the RAM tmpfs ─────────────────────────────
copy_to_mobile_tmpfs() {
    echo -e "${BOLD}${CYAN}Copying OS files to RAM...${NC}"
    echo "Target: $MOBILE_RAM_DIR (tmpfs)"
    echo ""
    _copy_categories_to_dir "$MOBILE_RAM_DIR"
}

# ─── bind-mount populated safe dirs from tmpfs over system paths ──────────────
#
# DESIGN: overlayfs `mount -o remount,lowerdir=…` is rejected by the kernel
# (EINVAL) — you cannot add lowerdirs to a live overlayfs. Per-directory bind
# mounts are the only way to serve specific paths from RAM without a reboot.
#
# For each directory in BIND_SAFE_TOPLEVEL that is populated in the tmpfs,
# we bind-mount the tmpfs copy over the system path. The system path was
# previously served by the overlayfs (custom:updates:base lowerdir stack on
# USB); after the bind it is served from RAM. The overlayfs upper layer (RAM
# writes) is also in RAM already, so it is not lost — but it IS hidden by
# the bind. Writes to bound paths after enabling mobile mode go to the tmpfs
# (RAM) and are not persisted to the overlayfs upper or the USB.
do_live_binds() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}Root required for bind mounts.${NC}" >&2
        echo "Run: sudo powos mobile enable" >&2
        return 1
    fi

    local bound=()
    for safe_dir in "${BIND_SAFE_TOPLEVEL[@]}"; do
        local src="${MOBILE_RAM_DIR}${safe_dir}"
        [[ -d "$src" ]] || continue        # not populated in tmpfs — skip
        [[ -d "$safe_dir" ]] || continue   # target doesn't exist on system — skip
        if mountpoint -q "$safe_dir" 2>/dev/null; then
            echo -e "${YELLOW}  Skipping $safe_dir (already a mountpoint)${NC}"
            continue
        fi
        if mount --bind "$src" "$safe_dir"; then
            echo -e "  ${GREEN}✓${NC} Bound $safe_dir from RAM"
            bound+=("$safe_dir")
        else
            echo -e "  ${RED}✗${NC} Failed to bind $safe_dir" >&2
        fi
    done

    if [[ ${#bound[@]} -eq 0 ]]; then
        echo -e "${YELLOW}No directories were bound (nothing safe to bind in tmpfs).${NC}"
        echo "Mobile mode is NOT active."
        return 1
    fi

    # Record active binds for cleanup
    printf '%s\n' "${bound[@]}" > "$MOBILE_BIND_RECORD"
    echo ""
    echo -e "${GREEN}${#bound[@]} path(s) now served from RAM: ${bound[*]}${NC}"
    return 0
}

# ─── undo live bind mounts and free the tmpfs ────────────────────────────────
undo_live_binds() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}Root required to unmount binds.${NC}" >&2
        return 1
    fi

    local paths=()
    if [[ -f "$MOBILE_BIND_RECORD" ]]; then
        while IFS= read -r path; do
            [[ -n "$path" ]] && paths+=("$path")
        done < "$MOBILE_BIND_RECORD"
    fi

    # Unmount binds in reverse order (deepest first, though typically /usr etc are flat)
    local failed=0
    for (( i=${#paths[@]}-1; i>=0; i-- )); do
        local p="${paths[$i]}"
        if mountpoint -q "$p" 2>/dev/null; then
            if umount "$p" 2>/dev/null; then
                echo -e "  ${GREEN}✓${NC} Unbound $p"
            else
                echo -e "  ${YELLOW}⚠${NC} Could not unmount $p (busy?)" >&2
                failed=$((failed + 1))
            fi
        fi
    done

    rm -f "$MOBILE_BIND_RECORD"

    # Unmount the tmpfs (only possible once all binds from it are gone)
    if mountpoint -q "$MOBILE_RAM_DIR" 2>/dev/null; then
        if umount "$MOBILE_RAM_DIR" 2>/dev/null; then
            echo -e "  ${GREEN}✓${NC} Freed mobile RAM tmpfs"
            rmdir "$MOBILE_RAM_DIR" 2>/dev/null || true
        else
            echo -e "  ${YELLOW}⚠${NC} tmpfs still busy (lazy unmount scheduled)" >&2
            umount --lazy "$MOBILE_RAM_DIR" 2>/dev/null || true
        fi
    fi

    [[ $failed -eq 0 ]]
}

# Keep this for potential future boot-integration (USB staging), not called
# by the live flow anymore.
copy_layers_to_ram() {
    echo -e "${BOLD}${CYAN}Staging OS files to USB for boot integration...${NC}"
    echo "Target: $MOBILE_LAYER (on the USB data partition)"
    echo ""
    if ! mkdir -p "$MOBILE_LAYER" 2>/dev/null; then
        echo -e "${RED}Error: cannot create $MOBILE_LAYER - USB not mounted at $USB_MOUNT?${NC}"
        return 1
    fi
    _copy_categories_to_dir "$MOBILE_LAYER"
}

# ═══════════════════════════════════════════════════════════════════
# Remount Overlayfs
# ═══════════════════════════════════════════════════════════════════

remount_with_mobile() {
    echo -e "${CYAN}Activating live bind mounts...${NC}"
    if ! do_live_binds; then
        return 1
    fi
    set_mobile_state "live"
}

remount_without_mobile() {
    echo -e "${CYAN}Releasing live bind mounts...${NC}"
    undo_live_binds
    set_mobile_state "disabled"
}

# ═══════════════════════════════════════════════════════════════════
# Main Commands
# ═══════════════════════════════════════════════════════════════════

mobile_status() {
    echo -e "${BOLD}${CYAN}Mobile Mode Status${NC}"
    echo "════════════════════════════════════════"
    echo ""

    # Ground truth: is the bind record present and do the mounts exist?
    local live=false
    if [[ -f "$MOBILE_BIND_RECORD" ]]; then
        # Verify at least one bind is still mounted
        while IFS= read -r path; do
            if [[ -n "$path" ]] && mountpoint -q "$path" 2>/dev/null; then
                live=true
                break
            fi
        done < "$MOBILE_BIND_RECORD"
    fi

    # The state file persists across reboots; detect stale "live" state.
    local state
    state=$(get_mobile_state)
    if [[ "$state" == "live" && "$live" == false ]]; then
        # Bind mounts did not survive reboot (tmpfs and /run are transient).
        echo -e "Mode: ${YELLOW}Inactive (did not survive reboot)${NC}"
        echo "Mobile mode was active before reboot but the RAM tmpfs and bind"
        echo "mounts are gone. Run 'powos mobile enable' to re-activate."
        echo -e "${RED}USB paths are in use. Do not unplug.${NC}"
        # Auto-correct stale state
        set_mobile_state "disabled" 2>/dev/null || true
    elif [[ "$live" == true ]]; then
        echo -e "Mode: ${GREEN}● LIVE — OS paths served from RAM${NC}"
        echo ""
        echo "Active bind mounts (paths now in RAM):"
        while IFS= read -r path; do
            [[ -z "$path" ]] && continue
            if mountpoint -q "$path" 2>/dev/null; then
                echo -e "  ${GREEN}✓${NC} $path"
            else
                echo -e "  ${YELLOW}?${NC} $path (unmounted?)"
            fi
        done < "$MOBILE_BIND_RECORD"
        echo ""
        echo -e "${GREEN}USB data partition can be unplugged for bound paths.${NC}"
        echo "NOTE: /etc and /var are still USB-backed. Writes to bound paths"
        echo "go to RAM only — they are not persisted to USB."
    else
        echo -e "Mode: ${YELLOW}Normal (USB-backed)${NC}"
        echo "USB required — run 'sudo powos mobile enable' to activate."
    fi
    echo ""

    # USB and sync status
    echo -e "${CYAN}Sync:${NC}"
    if [[ -d "${USB_LAYERS%/layers}" ]] && mountpoint -q "${USB_LAYERS%/layers}" 2>/dev/null; then
        echo -e "  USB: ${GREEN}Connected${NC}"
    else
        echo -e "  USB: ${YELLOW}Disconnected${NC}"
    fi
    echo ""

    # RAM info
    local total_ram available_ram
    total_ram=$(get_total_ram)
    available_ram=$(get_available_ram)
    echo "RAM:"
    echo "  Total:     $(format_size "$total_ram")"
    echo "  Available: $(format_size "$available_ram")"
    if mountpoint -q "$MOBILE_RAM_DIR" 2>/dev/null; then
        local ram_used
        ram_used=$(du -sb "$MOBILE_RAM_DIR" 2>/dev/null | cut -f1 || echo 0)
        echo "  Mobile RAM layer: $(format_size "${ram_used:-0}")"
    fi
    echo ""

    # OS size
    local os_size
    os_size=$(get_total_size)
    echo "OS Size: $(format_size "$os_size")"
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

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -c|--customize) customize=true; shift ;;
            -f|--force)     force=true;     shift ;;
            *)              shift ;;
        esac
    done

    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}Mobile mode enable requires root.${NC}"
        echo "Run: sudo powos mobile enable"
        return 1
    fi

    if is_mobile_enabled && [[ "$force" != true ]]; then
        echo -e "${YELLOW}Mobile mode is already active.${NC}"
        echo "Run 'sudo powos mobile disable' first, or use --force to re-enable."
        return 0
    fi

    # Customize category selection interactively
    if [[ "$customize" == true ]]; then
        if ! show_menu; then
            echo "Cancelled."
            return 0
        fi
    fi

    # ── Step 1: calculate required size and check RAM ─────────────────────────
    echo -e "${BOLD}${CYAN}Enabling mobile mode (live bind mounts)...${NC}"
    echo ""
    local total_size
    total_size=$(calculate_mobile_size)
    local needed=$(( total_size + 1073741824 ))  # +1 GiB headroom
    local available
    available=$(get_available_ram)

    echo "OS content to copy: $(format_size "$total_size")"
    echo "RAM available:       $(format_size "$available")"
    echo ""

    if [[ $needed -gt $available ]]; then
        echo -e "${RED}Not enough RAM.${NC}"
        echo "  Need:      $(format_size "$needed") (content + 1 GiB buffer)"
        echo "  Available: $(format_size "$available")"
        echo "Try excluding categories: powos mobile -c"
        return 1
    fi

    # ── Step 2: create tmpfs ──────────────────────────────────────────────────
    if ! create_mobile_tmpfs "$total_size"; then
        return 1
    fi

    # ── Step 3: copy OS files from merged view into tmpfs ────────────────────
    if ! copy_to_mobile_tmpfs; then
        umount "$MOBILE_RAM_DIR" 2>/dev/null || true
        return 1
    fi

    # ── Step 4: bind-mount from tmpfs over USB-backed system paths ───────────
    if ! remount_with_mobile; then
        umount "$MOBILE_RAM_DIR" 2>/dev/null || true
        return 1
    fi

    echo ""
    echo -e "${GREEN}${BOLD}Mobile mode ACTIVE.${NC}"
    echo "Bound OS paths are now served from RAM."
    echo "Note: /etc and /var are still USB-backed (not bound)."
    echo "Run 'sudo powos mobile disable' to return to normal mode."
}

mobile_disable() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}Mobile mode disable requires root.${NC}"
        echo "Run: sudo powos mobile disable"
        return 1
    fi

    if ! is_mobile_enabled; then
        echo -e "${YELLOW}Mobile mode is not active.${NC}"
        # Clean up stale state file if needed
        local state
        state=$(get_mobile_state)
        [[ "$state" != "disabled" ]] && set_mobile_state "disabled" 2>/dev/null || true
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
