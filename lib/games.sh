#!/bin/bash
# games.sh - powos games: first-class shared games partition (POWOS-GAMES)
#
# One NTFS partition, label POWOS-GAMES, shared by BOTH PowOS and Windows:
# the same installed games serve both OSes (docs/WINDOWS.md, "Games
# partition"). It can be created two ways:
#
#   - at USB burn time:      install-to-usb.sh --games-gb N  (already exists)
#   - on a running system:   powos games create --size N     (this file)
#
# The second path matters for INSTALLED systems (PowOS on an internal SSD):
# the USB is unplugged after installing, so existing installs add the games
# partition as an update — carved out of free space on the PowOS-owned disk.
#
# Exposure contract (docs/WINDOWS.md): this partition is DELIBERATELY visible
# to Windows — GPT type 0700 (Microsoft basic data) so Windows assigns it a
# drive letter. Every other PowOS partition stays hidden (Linux type GUID).
#
# Entry point: cmd_games "$@"
#
# NOTE: this file is SOURCED into bin/powos — it must NOT set -e/-u/pipefail
# at top level (that would change the whole CLI's shell options).
#
# SAFETY: destructive operations are gated behind gms_run_step() + an explicit
# confirmation, and skipped entirely under --dry-run. The partition is bounded
# INSIDE the largest free block (never parted's 100% / negative offsets, which
# measure from the end of the DISK — see isv_free_block in install-system.sh).

# ── Presentation ──────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

gms_log()  { echo -e "${CYAN}[games]${NC} $*"; }
gms_ok()   { echo -e "${GREEN}[games]${NC} $*"; }
gms_warn() { echo -e "${YELLOW}[games]${NC} $*"; }
gms_err()  { echo -e "${RED}[games]${NC} $*" >&2; }
gms_step() { echo; echo -e "${BOLD}── $* ──${NC}"; }

# ── Globals (set by option parsing) ───────────────────────────────
GMS_DRY_RUN=0          # 1 = print destructive actions, never execute
GMS_ASSUME_YES=0       # 1 = skip y/N confirmations (scripting)
GMS_SIZE_GB=""         # requested partition size (whole GB)
GMS_DISK=""            # explicit target disk override

GMS_LABEL="POWOS-GAMES"
GMS_MOUNTPOINT="/var/mnt/games"          # bazzite: /mnt is a symlink → /var/mnt
GMS_UNIT_NAME="var-mnt-games.mount"      # systemd-escape of the mountpoint
GMS_UNIT_PATH="/etc/systemd/system/var-mnt-games.mount"
GMS_NATIVE_ROOT="/var/lib/powos/steam-native"   # btrfs home for Proton state
# Microsoft basic data GPT type GUID (sgdisk code 0700)
GMS_MSDATA_GUID="ebd0a0a2-b9e5-4433-87c0-68b6b72699c7"

# gms_run_step "description" cmd args...
# Executes a (destructive) command unless dry-run. Always echoes it first.
gms_run_step() {
    local desc="$1"; shift
    echo -e "  ${DIM}\$ $*${NC}"
    if [[ $GMS_DRY_RUN -eq 1 ]]; then
        gms_warn "dry-run: skipped ($desc)"
        return 0
    fi
    "$@"
}

# gms_write_file "description" /dest/path   (content on stdin)
# Same dry-run gating as gms_run_step, for file writes.
gms_write_file() {
    local desc="$1" dest="$2"
    echo -e "  ${DIM}\$ write $dest${NC}"
    if [[ $GMS_DRY_RUN -eq 1 ]]; then
        gms_warn "dry-run: skipped ($desc)"
        cat > /dev/null   # drain stdin
        return 0
    fi
    cat > "$dest"
}

gms_confirm() {
    local prompt="$1"
    if [[ $GMS_ASSUME_YES -eq 1 ]]; then
        gms_warn "--yes: auto-confirming: $prompt"
        return 0
    fi
    local answer
    read -r -p "$prompt [y/N] " answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

# Is $1 a block device? Wrapped so tests can stub it ([[ -b ]] can't be
# mocked, and unit tests run where /dev/sdX doesn't exist).
gms_is_block() { [[ -b "$1" ]]; }

gms_steam_running() { pgrep -x steam &>/dev/null; }

# Home directory of the invoking user (steam-setup runs under sudo, but the
# Steam config lives in the real user's home).
gms_user_home() {
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6
    else
        echo "$HOME"
    fi
}

# ── Disk discovery ────────────────────────────────────────────────
# Which physical disk backs the running PowOS root? (installed systems)
gms_root_disk() {
    local src base
    src=$(findmnt -n -o SOURCE / 2>/dev/null || true)
    [[ "$src" == /dev/* ]] || return 0   # "overlay" on ramboot tells us nothing
    base=$(lsblk -no PKNAME "$src" 2>/dev/null | head -1)
    [[ -n "$base" ]] && echo "/dev/$base"
}

# Disk holding the POWOS-DATA partition (ramboot/live systems).
gms_data_disk() {
    local part pk
    part=$(blkid -L POWOS-DATA 2>/dev/null || true)
    [[ -n "$part" ]] || return 0
    pk=$(lsblk -no PKNAME "$part" 2>/dev/null | head -1)
    [[ -n "$pk" ]] && echo "/dev/$pk"
}

# The PowOS-owned disk: the disk backing the root filesystem, or — on a
# ramboot/live system where root is an overlay — the POWOS-DATA disk.
gms_default_disk() {
    local d
    d=$(gms_root_disk)
    [[ -n "$d" ]] && { echo "$d"; return 0; }
    d=$(gms_data_disk)
    [[ -n "$d" ]] && { echo "$d"; return 0; }
    return 1
}

# ── Pure helpers (unit-testable, no side effects) ─────────────────
# Largest free block on a disk: prints "START END SIZE" (MiB, suffix stripped).
# START/END may be fractional (e.g. 1.02) — pass them back to parted verbatim.
# (Model: isv_free_block in install-system.sh.)
gms_free_block() {
    local disk="${1:?gms_free_block: disk argument required}"
    parted "$disk" unit MiB print free 2>/dev/null | awk '
        /Free Space/ {
            s=$1; e=$2; sz=$3
            gsub("MiB","",s); gsub("MiB","",e); gsub("MiB","",sz)
            if (sz+0 > max) { max=sz+0; start=s; end=e }
        }
        END { if (max > 0) printf "%s %s %d\n", start, end, max }'
}

# PURE: bound the new partition INSIDE the free block.
#   $1 = free-block start (MiB, may be fractional)
#   $2 = free-block end   (MiB)
#   $3 = requested size   (MiB, integer)
# Prints "START END" (both fractional-safe) or returns 1 if it doesn't fit.
# CRITICAL: END is start+size, never past the free block's end and never a
# disk-end-relative spec (100% / -NMiB) — on a common Windows layout a
# recovery partition sits AFTER the free block; disk-end offsets would
# overlap it (this exact bug class was fixed in the installer).
gms_part_bounds() {
    local fb_start="$1" fb_end="$2" want_mib="$3"
    # LC_ALL=C: parted needs a period decimal separator, never a comma.
    LC_ALL=C awk -v s="$fb_start" -v e="$fb_end" -v w="$want_mib" 'BEGIN {
        avail = e - s
        if (w + 0 <= 0)  exit 1
        if (avail < w)   exit 1
        printf "%.2f %.2f\n", s, s + w
    }'
}

# Resolve a partition on $1 by its GPT partition label ($2). Reads the label
# with blkid (straight from disk) rather than lsblk udev columns, which are
# empty where udev hasn't populated them. (Model: isv_part_by_partlabel.)
gms_part_by_partlabel() {
    local dev="$1" want="$2" part
    while read -r part; do
        gms_is_block "$part" || continue
        [[ "$(blkid -o value -s PARTLABEL "$part" 2>/dev/null)" == "$want" ]] || continue
        echo "$part"; return 0
    done < <(lsblk -ln -o PATH "$dev" 2>/dev/null | tail -n +2)
    return 1
}

gms_last_partition() {
    lsblk -ln -o PATH "$1" 2>/dev/null | tail -1
}

# Safety gate before formatting a partition selected by the "last partition"
# FALLBACK (GPT fills numbering gaps, so lsblk's last row can be a
# PRE-EXISTING partition). Returns non-zero — caller must NOT format — if the
# partition carries any filesystem signature or its size is off.
# (Mirror of isv_verify_new_partition.)
gms_verify_new_partition() {
    local part="$1" expect_mib="${2:-}"
    local sig
    sig=$(blkid -o value -s TYPE "$part" 2>/dev/null || true)
    if [[ -n "$sig" ]]; then
        gms_err "SAFETY ABORT: fallback-selected partition $part already contains a"
        gms_err "filesystem ($sig) — it is NOT the partition that was just created."
        gms_err "Nothing was formatted. Inspect the disk with: lsblk -f"
        return 1
    fi
    if [[ -n "$expect_mib" ]]; then
        local size_b size_mib diff
        size_b=$(lsblk -bnd -o SIZE "$part" 2>/dev/null | head -1 | tr -d '[:space:]')
        if [[ "$size_b" =~ ^[0-9]+$ ]]; then
            size_mib=$(( size_b / 1048576 ))
            diff=$(( size_mib - expect_mib )); (( diff < 0 )) && diff=$(( -diff ))
            if (( diff > 64 )); then   # tolerance for alignment rounding
                gms_err "SAFETY ABORT: $part is ${size_mib}MiB but the partition just"
                gms_err "created should be ~${expect_mib}MiB. Refusing to format it."
                return 1
            fi
        else
            gms_warn "Could not read the size of $part to double-check it —"
            gms_warn "proceeding on the (clean) filesystem-signature check alone."
        fi
    fi
    return 0
}

# Re-read the partition table and ensure device nodes exist before we
# reference them. (Model: isv_settle.)
gms_settle() {
    local dev="$1"
    partprobe "$dev" 2>/dev/null || true
    if command -v udevadm &>/dev/null; then
        udevadm settle 2>/dev/null || true
    fi
    partx -a "$dev" 2>/dev/null || true
    partx -u "$dev" 2>/dev/null || true
    sleep 1
}

# PURE: the systemd mount unit for the games partition.
#   - by-label What= : survives device renumbering (sdb2 → sdc2)
#   - Type=ntfs3     : in-kernel NTFS driver (fast, no FUSE userspace)
#   - windows_names  : refuses filenames Windows can't read — REQUIRED, this
#                      library is shared with a real Windows install; a single
#                      Linux-legal name (trailing dot, ':', '?') would be
#                      unopenable from the Windows side.
#   - uid/gid=1000   : NTFS has no POSIX owners; map everything to the user.
gms_mount_unit_content() {
    cat <<'EOF'
[Unit]
Description=PowOS shared games partition (POWOS-GAMES, NTFS)
# Generated by: powos games mount

[Mount]
What=/dev/disk/by-label/POWOS-GAMES
Where=/var/mnt/games
Type=ntfs3
Options=uid=1000,gid=1000,noatime,windows_names

[Install]
WantedBy=local-fs.target
EOF
}

# PURE: append a library entry to Steam's libraryfolders.vdf.
#   $1 = existing vdf text     $2 = library path to add
# Prints the new text. Idempotent: if the path is already present, prints the
# input unchanged. Returns 2 if the text doesn't look like a vdf (no closing
# brace) — caller must NOT write in that case.
#
# The next index is max(existing numeric block keys)+1; existing entries are
# preserved byte-for-byte (Steam normalizes the file on next run anyway, but
# we never want to be the ones who mangled it).
gms_vdf_add_library() {
    local vdf="$1" libpath="$2"
    awk -v libpath="$libpath" '
        {
            lines[NR] = $0
            # Numeric library-block keys are lines that are exactly "N"
            # (key-value lines like "228980" "123..." have two tokens and
            # do not match).
            if ($0 ~ /^[ \t]*"[0-9]+"[ \t]*$/) {
                n = $0; gsub(/[^0-9]/, "", n)
                if (n + 0 >= nextidx) nextidx = n + 1
            }
            if (index($0, "\"path\"") && index($0, "\"" libpath "\"")) present = 1
            if ($0 ~ /^[ \t]*\}[ \t]*$/) lastclose = NR
        }
        END {
            if (present) { for (i = 1; i <= NR; i++) print lines[i]; exit 0 }
            if (!lastclose) exit 2   # not a vdf we understand — do not touch
            for (i = 1; i < lastclose; i++) print lines[i]
            printf "\t\"%d\"\n", nextidx
            print  "\t{"
            printf "\t\t\"path\"\t\t\"%s\"\n", libpath
            print  "\t\t\"label\"\t\t\"\""
            print  "\t\t\"apps\""
            print  "\t\t{"
            print  "\t\t}"
            print  "\t}"
            for (i = lastclose; i <= NR; i++) print lines[i]
        }' <<< "$vdf"
}

# Create the shared-library skeleton + the native-FS symlinks. Testable with
# a plain tmpdir — only mkdir/ln, no devices.
#   $1 = mount root (the NTFS partition)   $2 = native (btrfs) root
#
# THE CRITICAL TRICK — why compatdata/shadercache are symlinks:
# Proton prefixes are little Wine filesystems full of symlinks, fifos, case
# tricks and POSIX permission semantics that NTFS cannot represent; a prefix
# on NTFS corrupts subtly or refuses to start (this is the same caveat the
# installer prints: "keep compatdata/prefixes on the NATIVE filesystem").
# Shader caches are hot small-file churn — also terrible on ntfs3. So the
# game FILES live on NTFS (shared with Windows, which keeps its own prefixes
# and caches anyway), while Linux-only state lives on btrfs and is symlinked
# into the library where Steam expects it.
gms_steam_layout() {
    local mnt="$1" native="$2" d link target
    mkdir -p "$mnt/SteamLibrary/steamapps" || return 1
    mkdir -p "$native/compatdata" "$native/shadercache" || return 1
    for d in compatdata shadercache; do
        link="$mnt/SteamLibrary/steamapps/$d"
        target="$native/$d"
        if [[ -L "$link" ]]; then
            # Already a symlink — repoint only if it points elsewhere.
            [[ "$(readlink "$link")" == "$target" ]] && continue
            rm -f "$link" || return 1
        elif [[ -d "$link" ]]; then
            # A REAL directory on NTFS. Empty → replace with the symlink.
            # Non-empty → someone already has prefixes/caches in there;
            # refuse rather than orphan (or destroy) them.
            if [[ -n "$(ls -A "$link" 2>/dev/null)" ]]; then
                gms_err "$link is a non-empty real directory on NTFS."
                gms_err "Move its contents to $target and re-run steam-setup."
                return 1
            fi
            rmdir "$link" || return 1
        fi
        ln -s "$target" "$link" || return 1
    done
    return 0
}

# PURE: the README dropped at the partition root for the Windows side.
gms_games_readme() {
    cat <<'EOF'
POWOS-GAMES — shared games partition
====================================

This NTFS partition is shared between PowOS (Linux) and Windows.
The same installed games serve both operating systems.

On Windows
----------
 - This partition appears as a normal drive letter (e.g. E:).
 - In Steam: Settings > Storage > Add Drive, then pick
       <letter>:\SteamLibrary
   Games installed into it by either OS show up in both.

On PowOS
--------
 - Mounted at /var/mnt/games (systemd unit var-mnt-games.mount).
 - The Steam library is /var/mnt/games/SteamLibrary
   (wired up by: sudo powos games steam-setup).
 - Inside steamapps/, "compatdata" and "shadercache" are symlinks to the
   native Linux filesystem — Proton prefixes cannot live on NTFS. From
   Windows they look like broken shortcuts: LEAVE THEM ALONE. Windows keeps
   its own prefixes and shader caches, so it never needs them.

Rules that keep this partition healthy
--------------------------------------
 - In Windows, disable Fast Startup and hibernation:
       powercfg.exe /hibernate off
   A hibernated Windows leaves NTFS dirty; PowOS then refuses to write it.
 - Never "initialize" or format unreadable disks in Disk Management —
   anything Windows cannot read here is a PowOS partition, on purpose.
EOF
}

# ── powos games status ────────────────────────────────────────────
gms_status() {
    gms_step "POWOS-GAMES status"

    local part
    part=$(blkid -L "$GMS_LABEL" 2>/dev/null || true)
    if [[ -z "$part" ]]; then
        echo "  Partition:  not found (no LABEL=$GMS_LABEL anywhere)"
        echo
        echo "  Create it on this machine's PowOS disk:"
        echo "      sudo powos games create --size 512          # size in GB"
        echo "      sudo powos games create --size 512 --dry-run  # plan only"
        echo
        echo "  (New USBs can get it at burn time instead: install-to-usb.sh --games-gb N)"
        return 1
    fi

    local size mounted parttype disk pk
    size=$(lsblk -dno SIZE "$part" 2>/dev/null | head -1 | tr -d '[:space:]')
    mounted=$(findmnt -n -o TARGET -S "$part" 2>/dev/null | head -1)
    pk=$(lsblk -no PKNAME "$part" 2>/dev/null | head -1)
    disk="${pk:+/dev/$pk}"

    echo "  Partition:  $part${disk:+ (on $disk)}"
    echo "  Size:       ${size:-?}"
    echo "  Mounted:    ${mounted:-not mounted}"

    # GPT type: must be Microsoft basic data or Windows won't letter it.
    parttype=$(lsblk -no PARTTYPE "$part" 2>/dev/null | head -1 | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
    if [[ "$parttype" == "$GMS_MSDATA_GUID" ]]; then
        echo -e "  GPT type:   ${GREEN}sane${NC} (Microsoft basic data — visible to Windows, by design)"
    elif [[ -z "$parttype" ]]; then
        echo "  GPT type:   unknown (could not read PARTTYPE)"
    else
        local pnum="${part##*[!0-9]}"
        echo -e "  GPT type:   ${YELLOW}$parttype${NC} — not Microsoft basic data;"
        echo "              Windows may show it as RAW/unlettered. Fix:"
        echo "                  sudo sgdisk -t ${pnum:-N}:0700 ${disk:-<disk>}"
    fi

    echo
    echo -e "  ${BOLD}Mount unit${NC} ($GMS_UNIT_NAME)"
    if [[ -f "$GMS_UNIT_PATH" ]]; then
        local enabled="?" active="?"
        if command -v systemctl &>/dev/null; then
            enabled=$(systemctl is-enabled "$GMS_UNIT_NAME" 2>/dev/null || echo "disabled")
            active=$(systemctl is-active "$GMS_UNIT_NAME" 2>/dev/null || echo "inactive")
        fi
        echo "    Unit:     present ($GMS_UNIT_PATH)"
        echo "    State:    $enabled / $active"
    else
        echo "    Unit:     not installed — run: sudo powos games mount"
    fi

    echo
    echo -e "  ${BOLD}Steam wiring${NC}"
    local lib="$GMS_MOUNTPOINT/SteamLibrary"
    if [[ -d "$lib/steamapps" ]]; then
        local wired="yes" d
        for d in compatdata shadercache; do
            [[ -L "$lib/steamapps/$d" ]] || wired="no"
        done
        echo "    Library:  $lib"
        echo "    Native symlinks (compatdata/shadercache): $wired"
        local vdf; vdf="$(gms_user_home)/.local/share/Steam/config/libraryfolders.vdf"
        if [[ -f "$vdf" ]] && grep -Fq "\"$lib\"" "$vdf" 2>/dev/null; then
            echo "    Registered in libraryfolders.vdf: yes"
        else
            echo "    Registered in libraryfolders.vdf: no — run: sudo powos games steam-setup"
        fi
    else
        echo "    Not set up — run: sudo powos games steam-setup"
    fi
    return 0
}

# ── powos games create ────────────────────────────────────────────
gms_create() {
    gms_step "Create the $GMS_LABEL shared partition"

    if ! [[ "$GMS_SIZE_GB" =~ ^[0-9]+$ ]] || (( GMS_SIZE_GB < 1 )); then
        gms_err "Required: --size N (whole GB, e.g. --size 512)"
        return 1
    fi
    local want_mib=$(( GMS_SIZE_GB * 1024 ))

    local t missing=()
    for t in parted blkid lsblk mkfs.ntfs; do
        command -v "$t" &>/dev/null || missing+=("$t")
    done
    if (( ${#missing[@]} > 0 )); then
        gms_err "Missing required tools: ${missing[*]}"
        gms_err "(mkfs.ntfs ships in ntfsprogs / ntfs-3g)"
        return 1
    fi

    # There must be exactly one POWOS-GAMES in the world — mounts and Steam
    # wiring resolve it by label, so a second one would be ambiguous.
    local existing
    existing=$(blkid -L "$GMS_LABEL" 2>/dev/null || true)
    if [[ -n "$existing" ]]; then
        gms_err "A $GMS_LABEL partition already exists: $existing"
        gms_err "Refusing to create a second one. See: powos games status"
        return 1
    fi

    # Target disk: --disk override, else the PowOS-owned disk (root disk on
    # installed systems, POWOS-DATA disk on ramboot/live systems).
    local disk="$GMS_DISK" how="--disk override"
    if [[ -z "$disk" ]]; then
        disk=$(gms_default_disk) || true
        how="PowOS-owned disk, auto-detected"
        if [[ -z "$disk" ]]; then
            gms_err "Could not determine the PowOS-owned disk (root is an overlay"
            gms_err "and no POWOS-DATA partition was found)."
            gms_err "Pass it explicitly: powos games create --size N --disk /dev/sdX"
            return 1
        fi
    fi
    if ! gms_is_block "$disk" \
       || [[ "$(lsblk -dn -o TYPE "$disk" 2>/dev/null | head -1 | tr -d '[:space:]')" != "disk" ]]; then
        gms_err "$disk is not a whole-disk block device (expected e.g. /dev/sda,"
        gms_err "/dev/nvme0n1 — not a partition)."
        return 1
    fi

    # Largest free block; the new partition is bounded INSIDE it.
    local fb_start fb_end fb_size
    read -r fb_start fb_end fb_size <<< "$(gms_free_block "$disk")"
    if [[ -z "$fb_start" || -z "$fb_end" ]]; then
        gms_err "No free space found on $disk."
        gms_err "Shrink a partition first (Windows: Disk Management), or re-burn"
        gms_err "the USB with:  install-to-usb.sh --games-gb $GMS_SIZE_GB"
        return 1
    fi
    local bounds p_start p_end
    if ! bounds=$(gms_part_bounds "$fb_start" "$fb_end" "$want_mib"); then
        gms_err "Not enough free space: largest free block is ${fb_size} MiB,"
        gms_err "but ${GMS_SIZE_GB}GB needs ${want_mib} MiB. Reduce --size."
        return 1
    fi
    read -r p_start p_end <<< "$bounds"

    gms_step "Plan"
    echo "  Disk:        $disk ($how)"
    echo "  Free block:  ${fb_start} → ${fb_end} MiB (${fb_size} MiB)"
    echo "  Partition:   ${p_start} → ${p_end} MiB (${GMS_SIZE_GB}GB, NTFS, label $GMS_LABEL)"
    echo "  GPT type:    0700 (Microsoft basic data — VISIBLE to Windows, by design)"
    echo
    echo -e "  ${DIM}Current layout:${NC}"
    lsblk -o NAME,SIZE,FSTYPE,LABEL "$disk" 2>/dev/null | awk '{print "    " $0}'
    echo

    if [[ $GMS_DRY_RUN -eq 0 ]]; then
        if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
            gms_err "Creating partitions needs root:  sudo powos games create --size $GMS_SIZE_GB"
            return 1
        fi
        gms_confirm "Create the ${GMS_SIZE_GB}GB $GMS_LABEL partition on $disk?" || {
            gms_log "Aborted. Nothing was changed."
            return 1
        }
    fi

    gms_run_step "create partition (${p_start}MiB → ${p_end}MiB)" \
        parted -s "$disk" mkpart "$GMS_LABEL" ntfs "${p_start}MiB" "${p_end}MiB" || {
        gms_err "parted mkpart failed — nothing was formatted."
        return 1
    }

    if [[ $GMS_DRY_RUN -eq 1 ]]; then
        # mkpart was skipped — resolving a live device here would show an
        # EXISTING partition in the plan. Print placeholders instead.
        gms_run_step "format NTFS (label $GMS_LABEL)" \
            mkfs.ntfs -f -L "$GMS_LABEL" "<new $GMS_LABEL partition>"
        gms_run_step "set GPT type 0700 (Microsoft basic data)" \
            sgdisk -t "N:0700" "$disk"
        gms_warn "dry-run complete — nothing was changed."
        return 0
    fi

    gms_settle "$disk"

    # Locate the new partition by GPT partlabel (robust vs. device
    # enumeration order); fall back to "last partition" ONLY behind the
    # signature/size verification — never format a guess.
    local part used_fallback=0
    part=$(gms_part_by_partlabel "$disk" "$GMS_LABEL")
    if [[ -z "$part" ]]; then
        part=$(gms_last_partition "$disk")
        used_fallback=1
    fi
    if [[ -z "$part" ]] || ! gms_is_block "$part"; then
        gms_err "Partition created but its device node was not found."
        gms_err "Format it manually:  mkfs.ntfs -f -L $GMS_LABEL <partition>"
        return 1
    fi
    if [[ $used_fallback -eq 1 ]]; then
        gms_warn "Partlabel lookup failed; fallback selected $part — verifying it."
        gms_verify_new_partition "$part" "$want_mib" || return 1
    fi
    gms_log "New partition: $part"

    gms_run_step "format NTFS (label $GMS_LABEL)" \
        mkfs.ntfs -f -L "$GMS_LABEL" "$part" || {
        gms_err "mkfs.ntfs failed — format $part manually:"
        gms_err "    mkfs.ntfs -f -L $GMS_LABEL $part"
        return 1
    }

    # Exposure contract (docs/WINDOWS.md): 0700 = Microsoft basic data, so
    # Windows assigns a drive letter. Best-effort: without it the partition
    # still works on PowOS, but Windows may show it as un-lettered RAW.
    local pnum="${part##*[!0-9]}"
    if command -v sgdisk &>/dev/null && [[ -n "$pnum" ]]; then
        gms_run_step "set GPT type 0700 (visible to Windows — by design)" \
            sgdisk -t "${pnum}:0700" "$disk" || \
            gms_warn "sgdisk failed — fix later: sgdisk -t ${pnum}:0700 $disk"
    else
        gms_warn "sgdisk not available — set the GPT type later so Windows"
        gms_warn "letters the partition:  sgdisk -t ${pnum:-N}:0700 $disk"
    fi

    gms_ok "$GMS_LABEL ready: $part (${GMS_SIZE_GB}GB NTFS)"
    gms_log "Next:  sudo powos games mount        # mount at $GMS_MOUNTPOINT"
    gms_log "Then:  sudo powos games steam-setup  # wire the shared Steam library"
}

# ── powos games mount ─────────────────────────────────────────────
gms_mount() {
    gms_step "Install the games mount unit"

    local unit
    unit=$(gms_mount_unit_content)
    echo -e "  ${DIM}$GMS_UNIT_PATH:${NC}"
    printf '%s\n' "$unit" | awk '{print "    " $0}'
    echo

    local part
    part=$(blkid -L "$GMS_LABEL" 2>/dev/null || true)
    if [[ -z "$part" ]]; then
        if [[ $GMS_DRY_RUN -eq 1 ]]; then
            gms_warn "No $GMS_LABEL partition found (continuing — dry-run)."
        else
            gms_err "No $GMS_LABEL partition found. Create it first:"
            gms_err "    sudo powos games create --size N"
            return 1
        fi
    fi

    if [[ $GMS_DRY_RUN -eq 0 && ${EUID:-$(id -u)} -ne 0 ]]; then
        gms_err "Installing a mount unit needs root:  sudo powos games mount"
        return 1
    fi

    gms_run_step "create mountpoint $GMS_MOUNTPOINT" mkdir -p "$GMS_MOUNTPOINT" || return 1
    gms_write_file "write $GMS_UNIT_NAME" "$GMS_UNIT_PATH" <<< "$unit" || return 1
    gms_run_step "reload systemd" systemctl daemon-reload || return 1
    gms_run_step "enable + start $GMS_UNIT_NAME" systemctl enable --now "$GMS_UNIT_NAME" || {
        gms_err "Mount failed. Common cause: the NTFS is dirty (Windows Fast"
        gms_err "Startup / hibernation). Fix in Windows: powercfg.exe /hibernate off,"
        gms_err "then shut down fully. Details: journalctl -u $GMS_UNIT_NAME"
        return 1
    }

    if [[ $GMS_DRY_RUN -eq 1 ]]; then
        gms_warn "dry-run complete — nothing was changed."
        return 0
    fi
    if findmnt -n "$GMS_MOUNTPOINT" &>/dev/null; then
        gms_ok "$GMS_LABEL mounted at $GMS_MOUNTPOINT (auto-mounts on boot)."
    else
        gms_warn "Unit enabled but $GMS_MOUNTPOINT is not mounted yet —"
        gms_warn "check: systemctl status $GMS_UNIT_NAME"
    fi
}

# ── powos games steam-setup ───────────────────────────────────────
gms_steam_setup() {
    gms_step "Wire Steam to the shared games library"

    local mnt="$GMS_MOUNTPOINT" native="$GMS_NATIVE_ROOT"
    local libpath="$mnt/SteamLibrary"

    if ! findmnt -n "$mnt" &>/dev/null; then
        if [[ $GMS_DRY_RUN -eq 1 ]]; then
            gms_warn "$mnt is not mounted (continuing — dry-run)."
        else
            gms_err "$mnt is not mounted. Run first:  sudo powos games mount"
            return 1
        fi
    fi

    # Steam rewrites libraryfolders.vdf from memory on exit — editing it
    # while Steam runs means our change is silently clobbered.
    if gms_steam_running; then
        gms_err "Steam is running — close Steam first."
        gms_err "(Steam rewrites its library config on exit and would undo this.)"
        return 1
    fi

    if [[ $GMS_DRY_RUN -eq 0 && ${EUID:-$(id -u)} -ne 0 ]]; then
        gms_err "Needs root (writes under /var/lib/powos and the NTFS root):"
        gms_err "    sudo powos games steam-setup"
        return 1
    fi

    local uid="${SUDO_UID:-1000}" gid="${SUDO_GID:-1000}"

    gms_step "Library layout (game files on NTFS, Proton state on btrfs)"
    gms_run_step "create SteamLibrary + native compatdata/shadercache symlinks" \
        gms_steam_layout "$mnt" "$native" || return 1
    # Only the NATIVE side gets chown — the NTFS side is uid-mapped by the
    # mount options (chown on ntfs3 with uid= would just fail).
    gms_run_step "own the native Proton state (uid $uid)" \
        chown -R "$uid:$gid" "$native" || return 1

    gms_step "Register the library with Steam"
    local home vdf
    home=$(gms_user_home)
    vdf="$home/.local/share/Steam/config/libraryfolders.vdf"
    if [[ ! -f "$vdf" ]]; then
        # Never guess the vdf format from nothing — one manual step instead.
        gms_warn "No Steam library config found at:"
        gms_warn "    $vdf"
        gms_log  "Add the library manually (one step): open Steam →"
        gms_log  "Settings → Storage → Add Drive → pick $libpath"
    else
        local cur new
        cur=$(cat "$vdf")
        if new=$(gms_vdf_add_library "$cur" "$libpath"); then
            if [[ "$new" == "$cur" ]]; then
                gms_ok "Library already registered in libraryfolders.vdf."
            else
                gms_run_step "back up libraryfolders.vdf" \
                    cp "$vdf" "${vdf}.powos-bak" || return 1
                gms_write_file "update libraryfolders.vdf" "$vdf" <<< "$new" || return 1
                gms_ok "Library registered (backup: ${vdf}.powos-bak)."
            fi
        else
            gms_err "$vdf does not look like a library config — NOT touching it."
            gms_log "Add the library manually: Steam → Settings → Storage → Add Drive"
        fi
    fi

    gms_step "Windows-side README"
    gms_write_file "write GAMES-README.txt" "$mnt/GAMES-README.txt" \
        <<< "$(gms_games_readme)" || \
        gms_warn "Could not write $mnt/GAMES-README.txt (non-fatal)."

    if [[ $GMS_DRY_RUN -eq 1 ]]; then
        gms_warn "dry-run complete — nothing was changed."
        return 0
    fi
    echo
    gms_ok "Steam wiring done."
    echo "  PowOS:    start Steam — the '$libpath' library is available;"
    echo "            install games into it. Proton prefixes + shader cache"
    echo "            live on btrfs ($native) via symlinks."
    echo "  Windows:  the partition gets a drive letter; add <letter>:\\SteamLibrary"
    echo "            in Windows Steam (Settings > Storage > Add Drive)."
    echo "            Full notes: GAMES-README.txt at the partition root."
}

# ── powos games resize ────────────────────────────────────────────
gms_resize() {
    gms_err "Not implemented: resizing an NTFS partition in place is the"
    gms_err "riskiest disk operation there is, and we won't pretend otherwise."
    gms_log "Create the partition at the size you need (powos games create --size N),"
    gms_log "or back up its contents, delete it, and re-create it bigger."
    return 1
}

# ── Usage / entry ─────────────────────────────────────────────────
gms_usage() {
    cat << EOF
powos games — shared games partition (POWOS-GAMES) for PowOS + Windows

One NTFS partition both OSes use: the same installed games serve both.
Deliberately visible to Windows (drive letter); everything else PowOS
owns stays hidden. Works on live-USB and installed (internal-SSD) systems.

Usage: powos games <command> [options]

Commands:
  status                 Show partition / mount / Steam-wiring state
  create --size N        Create the partition (N GB) on the PowOS-owned disk
  mount                  Install + enable the systemd mount ($GMS_MOUNTPOINT)
  steam-setup            Shared Steam library + native-FS Proton-state symlinks
  resize                 Not implemented (create at the size you need)

Options:
  --size N               Partition size in GB (create; required)
  --disk /dev/sdX        Target disk override (create; default: PowOS disk)
  --dry-run              Show every action but change NOTHING
  --yes                  Skip y/N confirmations (scripting)
  -h, --help             This help

Typical flow on an existing install:
  sudo powos games create --size 512
  sudo powos games mount
  sudo powos games steam-setup

Windows side: the partition appears as a drive letter; add
<letter>:\\SteamLibrary in Windows Steam. See GAMES-README.txt on the
partition (written by steam-setup).
EOF
}

cmd_games() {
    local sub="${1:-status}"; shift 2>/dev/null || true
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) GMS_DRY_RUN=1; shift ;;
            --yes|-y)  GMS_ASSUME_YES=1; shift ;;
            --size)    GMS_SIZE_GB="${2:-}"; shift 2 ;;
            --disk)    GMS_DISK="${2:-}"; shift 2 ;;
            -h|--help) gms_usage; return 0 ;;
            *)         gms_err "Unknown option: $1"; gms_usage; return 1 ;;
        esac
    done
    case "$sub" in
        status)            gms_status ;;
        create)            gms_create ;;
        mount)             gms_mount ;;
        steam-setup|steam) gms_steam_setup ;;
        resize)            gms_resize ;;
        help|-h|--help)    gms_usage ;;
        *)                 gms_err "Unknown games command: $sub"; gms_usage; return 1 ;;
    esac
}
