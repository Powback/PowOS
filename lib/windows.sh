#!/bin/bash
# windows.sh - bare-metal Windows from a VIRTUAL-DISK FILE (docs/WINDOWS.md,
# revised design: no real partitions for Windows, ever).
#
# Windows lives in ONE file on the POWOS-GAMES NTFS partition:
#
#   <POWOS-GAMES>/PowOS-Windows/windows.vhdx   (thin/dynamic, canonical)
#
# and bare-metal boots via Windows NATIVE VHD BOOT: bootmgr on the (shared)
# PowOS ESP mounts the file and boots the OS inside it. No partition table
# changes, no carve step, one blast radius: the file.
#
# ── Windows-exposure recap ─────────────────────────────────────────
# A metal Windows session sees EXACTLY:
#   1. its own file-internal volumes (ESP/MSR/C: inside windows.vhdx),
#   2. the POWOS-GAMES host volume (by design — it carries the image and
#      shared game assets),
#   3. the shared ESP's boot files,
#   and NOTHING else: the btrfs partitions carry letterless Linux GPT type
#   GUIDs and are invisible. The ESP is SHARED with PowOS — which is why
#   `install` takes a mandatory ESP backup and `finalize` prints the
#   one-line restore.
#
# ── Hibernation policy (the file edition of the hiberfile asymmetry) ─
# winresume CANNOT read a hiberfil.sys inside a VHD/VHDX — a native-VHD
# metal boot therefore ALWAYS COLD-BOOTS. Windows hibernation is a
# VM-MODE-ONLY feature: a VM-hibernated image resumed in the VM is correct
# (same virtual hardware); the same image booted on metal makes Windows
# prompt-discard the resume image (session lost, no corruption). Encoded:
#   - switch (metal): warn + confirm when the image is/may be hibernated,
#   - vm: resuming a VM-hibernated image is fine, never refused for that.
#
# ── Image format lifecycle (three masters to satisfy) ──────────────
#   (a) bootmgr native boot     → needs VHD or VHDX (fixed or dynamic),
#   (b) safe qemu read-write    → raw is bulletproof; qemu's vhdx driver
#                                 works but is less battle-tested,
#   (c) thin on NTFS            → sparse raw / dynamic VHDX.
# Chosen: INSTALL onto a raw SPARSE temp image (windows.raw — qemu raw is
# the most reliable format for Setup's heavy I/O), then `finalize` converts
# with `qemu-img convert -O vhdx -o subformat=dynamic` (thin AND native-
# bootable) and deletes the raw. Steady-state VM sessions attach the VHDX
# read-write through qemu's vhdx driver (maturity caveat: it is the least
# exercised of the three; if it misbehaves, the `--fixed-vhd` escape hatch
# converts to a fixed-subformat VHD instead — bootmgr's oldest, safest
# native-boot format — created sparse so NTFS still stores only used
# blocks; qemu reads/writes VHD (vpc) very reliably).
#
# EXPERIMENTAL: everything hardware-facing is TODO(hw). Destructive paths
# are gated behind plan display + confirmations and fully skipped under
# --dry-run (lib/install-system.sh run_step discipline).
#
# NOTE: this file is SOURCED into the powos CLI — it must NOT execute
# set -e/-u/pipefail at file top level. Defensive ${var:-} defaults instead.

# ── Presentation ──────────────────────────────────────────────────
WIN_RED=$'\033[0;31m'; WIN_GREEN=$'\033[0;32m'; WIN_YELLOW=$'\033[0;33m'
WIN_CYAN=$'\033[0;36m'; WIN_BOLD=$'\033[1m'; WIN_DIM=$'\033[2m'; WIN_NC=$'\033[0m'

win_log()  { echo -e "${WIN_CYAN}[windows]${WIN_NC} $*"; }
win_ok()   { echo -e "${WIN_GREEN}[windows]${WIN_NC} $*"; }
win_warn() { echo -e "${WIN_YELLOW}[windows]${WIN_NC} $*"; }
win_err()  { echo -e "${WIN_RED}[windows]${WIN_NC} $*" >&2; }
win_step() { echo; echo -e "${WIN_BOLD}── $* ──${WIN_NC}"; }

# ── Globals (set by cmd_windows option parsing) ───────────────────
WIN_DRY_RUN=${WIN_DRY_RUN:-0}
WIN_ASSUME_YES=${WIN_ASSUME_YES:-0}
WIN_ISO=""                  # --iso for install
WIN_RAM="8G"                # VM RAM (install + vm)
WIN_CPUS="4"                # VM vCPUs
WIN_REBOOT_FALLBACK=0       # --reboot: plain reboot if hibernate unavailable
WIN_INTERACTIVE=0           # --interactive: no autounattend.xml
WIN_USERNAME="powos"        # unattended: local admin account name
WIN_PASSWORD="powos"        # unattended: account password (default gets a loud warning)
WIN_LOCALE="en-US"          # unattended: Windows display/system locale
WIN_KEYBOARD="en-US"        # unattended: keyboard/input locale
WIN_PRODUCT_KEY=""          # unattended: optional product key (keyless is the default)
WIN_EDITION="Windows 11 Pro"  # unattended: /IMAGE/NAME for keyless edition selection
WIN_WITH_STEAM=0            # --with-steam: best-effort silent Steam install
WIN_SIZE_GB=256             # --size: image MAX size in GB (thin — grows with use)
WIN_FIXED_VHD=0             # --fixed-vhd: escape hatch (fixed VHD instead of dynamic VHDX)
WIN_BACKEND="vhd"           # --backend: 'vhd' (image file on POWOS-GAMES, default)
                            # or 'partition' (dedicated WIN-ESP + POWOS-WIN — Windows
                            # sees plain metal: native speed + real hibernation)

# ── ISO acquisition (fetch-iso / slim) knobs ──────────────────────
WIN_DEST=""                 # fetch-iso: --dest override for the downloaded ISO
WIN_HASH=""                 # fetch-iso: --hash expected SHA-256 (abort on mismatch)
WIN_SLIM=0                  # --slim: chain the debloat pass after a fetch/install
WIN_FETCH=0                 # install --fetch: acquire the ISO first, then install
WIN_OUT=""                  # slim: --out override for the slimmed ISO
WIN_FETCHED_ISO=""          # set by win_fetch_iso to the produced ISO (install --fetch)

# ── Steam / shared-library preinstall knobs (mirror lib/games.sh) ──
WIN_GAMES_LETTER="G"        # install: stable Windows drive letter for POWOS-GAMES
WIN_STEAM_AUTOSTART=0       # --steam-autostart: add Steam to the Windows Run key
WIN_NO_GAMES=0              # --no-games: skip the Steam/shared-library first-logon
WIN_GAMES_LABEL="POWOS-GAMES"      # NTFS label matched (never a drive letter!)
WIN_UNATTEND_LABEL="POWOSUNAT"     # FAT label of the unattend volume (<=11 chars)
WIN_STEAM_LIB_SUBDIR="SteamLibrary"   # shared library dir on POWOS-GAMES (matches
                                      # lib/games.sh gms_steam_layout: <root>/SteamLibrary)
# Official Steam bootstrapper (Valve CDN). Same trust discipline as the ISO:
# ONLY the official source, never a third-party mirror. Valve does not publish a
# pinned hash (the bootstrapper self-updates in place), so we sanity-check SHAPE.
WIN_STEAM_CDN_URL="https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe"
WIN_STEAM_SETUP_NAME="SteamSetup.exe"

WIN_IMAGE_SUBDIR="PowOS-Windows"   # directory on POWOS-GAMES holding the image
WIN_RUNDIR="${WIN_RUNDIR:-/run/powos/windows}"
WIN_LAYER_SYNC="/usr/lib/powos/ramfs/layer-sync.py"

# Declarative config file. Public schema is WINDOWS_*; mapped onto the WIN_*
# knobs above so the on-disk file stays decoupled from internals. Precedence:
#     built-in default  <  $WIN_CONFIG file  <  CLI flag
# (win_load_config runs BEFORE flag parsing in cmd_windows, so flags win.)
WIN_CONFIG="${WIN_CONFIG:-/etc/powos/windows.conf}"
WIN_CONFIG_LOADED=""        # set to the path once a config is applied (plan display)

# Unattend-volume teardown state (set by win_install, read by the trap).
WIN_TD_UNATTEND_MNT=""

# OVMF (UEFI firmware) search paths — same candidates as lib/vm.sh.
WIN_OVMF_CODE_CANDIDATES=(
    /usr/share/edk2/ovmf/OVMF_CODE.fd
    /usr/share/edk2/x64/OVMF_CODE.4m.fd
    /usr/share/OVMF/OVMF_CODE.fd
    /usr/share/qemu/OVMF_CODE.fd
)
WIN_OVMF_VARS_CANDIDATES=(
    /usr/share/edk2/ovmf/OVMF_VARS.fd
    /usr/share/edk2/x64/OVMF_VARS.4m.fd
    /usr/share/OVMF/OVMF_VARS.fd
    /usr/share/qemu/OVMF_VARS.fd
)

# ── run_step / confirm (install-system.sh discipline) ─────────────
# Executes a (destructive) command unless dry-run. Always echoes it first.
win_run_step() {
    local desc="${1:-}"; shift
    echo -e "  ${WIN_DIM}\$ $*${WIN_NC}"
    if [[ ${WIN_DRY_RUN:-0} -eq 1 ]]; then
        win_warn "dry-run: skipped ($desc)"
        return 0
    fi
    "$@"
}

# win_confirm "prompt" [expected] — if expected is given the user must type it
# exactly. Typed gates protect data-destroying operations (rollback overwrites
# the image) and must NEVER be satisfiable by --yes alone.
win_confirm() {
    local prompt="${1:-Proceed?}" expected="${2:-}"
    if [[ ${WIN_ASSUME_YES:-0} -eq 1 ]]; then
        if [[ -n "$expected" ]]; then
            win_err "--yes does not satisfy a typed confirmation."
            win_err "Run this command interactively and type: $expected"
            return 1
        fi
        win_warn "--yes: auto-confirming: $prompt"
        return 0
    fi
    local answer
    if [[ -n "$expected" ]]; then
        read -r -p "$prompt " answer
        [[ "$answer" == "$expected" ]]
    else
        read -r -p "$prompt [y/N] " answer
        [[ "$answer" =~ ^[Yy]$ ]]
    fi
}

# ── Environment seams (functions so tests can shadow them) ────────
win_require_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        win_err "This needs root:  sudo powos windows ${1:-}"
        return 1
    fi
}

win_require_efi() {
    if [[ ! -d /sys/firmware/efi ]]; then
        win_err "Not booted in UEFI mode — BootNext needs UEFI."
        return 1
    fi
    if ! command -v efibootmgr &>/dev/null; then
        win_err "efibootmgr not found (install efibootmgr)."
        return 1
    fi
}

# Is $1 a block device? Wrapped so tests can stub it ([[ -b ]] can't be mocked).
win_is_block() { [[ -b "$1" ]]; }

win_find_first_existing() {
    local f
    for f in "$@"; do [[ -f "$f" ]] && { echo "$f"; return 0; }; done
    return 1
}

# ── ISO-acquisition seams (functions so tests can shadow them) ────
# Every network / probing tool is wrapped so tier-1 tests replace it with a
# bash stub — NOTHING here is ever executed for real in the test suite.

# SHA-256 of a file. Echoes the lowercase 64-hex digest (sha256sum's first
# field). Seam: tests shadow it to return a deterministic digest.
win_sha256() {
    local h _
    read -r h _ < <(sha256sum "${1:?}" 2>/dev/null) || return 1
    [[ -n "$h" ]] && echo "$h"
}

# Byte size of a file (stat). Seam so tests can assert the >3GB sanity gate
# without conjuring multi-GB files.
win_file_size_bytes() { stat -c %s "${1:?}" 2>/dev/null; }

# Filesystem signature of a file via blkid (iso9660 / udf for a real ISO).
# Seam so the "looks like an ISO" sanity check is mockable.
win_iso_fstype() { blkid -o value -s TYPE "${1:?}" 2>/dev/null; }

# TRUST MODEL — read this before touching the download path:
# We NEVER download a prebuilt / third-party Windows image (unverifiable, and a
# redistribution problem). We download the OFFICIAL Microsoft ISO and verify it.
# The download is done by `mido` (https://github.com/ElliotKillick/Mido) — a
# self-contained, auditable POSIX-sh reimplementation of Fido that drives
# Microsoft's OWN public download endpoint (the same API the
# microsoft.com/software-download page uses) to obtain a genuine, unmodified
# Windows 11 ISO. We call mido if present; we do NOT vendor it, and we NEVER
# fetch-and-run foreign executable code. Absent mido, we refuse to improvise a
# downloader and print the official manual route instead.
#
# Seam: tests shadow this whole function; the body below never runs under test.
win_fetch_official_iso() {
    local dest="${1:?}"
    if command -v mido &>/dev/null; then
        local dir; dir=$(dirname "$dest")
        # mido writes Win11_*.iso into its cwd; run it there then rename.
        win_run_step "download official Windows 11 ISO (mido → official MS API)" \
            bash -c "cd \"$dir\" && mido win11" || return 1
        [[ ${WIN_DRY_RUN:-0} -eq 1 ]] && return 0
        local f newest=""
        for f in "$dir"/Win11*.iso "$dir"/*.iso; do
            [[ -e "$f" ]] || continue
            [[ "$f" == "$dest" ]] && { newest="$dest"; continue; }
            newest="$f"
        done
        [[ -n "$newest" && "$newest" != "$dest" ]] && mv "$newest" "$dest"
        [[ -e "$dest" ]] && return 0
        return 1
    fi
    win_err "No supported downloader found (mido is absent)."
    win_err "mido — https://github.com/ElliotKillick/Mido — is the auditable POSIX-sh"
    win_err "reimplementation of Fido that drives Microsoft's OFFICIAL download API."
    win_err "Install it, or download the ISO yourself from the official page:"
    win_err "  https://www.microsoft.com/software-download/windows11"
    win_err "then run:  powos windows install --iso <that.iso>"
    return 1
}

# Download the OFFICIAL Steam bootstrapper into $1 (Valve CDN). Same trust
# discipline as the ISO: official source only. Valve ships no pinned hash (the
# ~4MB bootstrapper updates in place and self-updates on first launch), so we
# verify SHAPE — a small PE — and print the computed SHA-256 for the record.
# Seam: tests shadow it.
win_fetch_steam_setup() {
    local dest="${1:?}"
    win_run_step "download official Steam installer (Valve CDN)" \
        curl -fsSL -o "$dest" "$WIN_STEAM_CDN_URL" || return 1
    [[ ${WIN_DRY_RUN:-0} -eq 1 ]] && return 0
    local sz; sz=$(win_file_size_bytes "$dest")
    if [[ -z "$sz" || "$sz" -lt 1000000 || "$sz" -gt 20000000 ]]; then
        win_err "SteamSetup.exe size looks wrong (${sz:-0} bytes) — refusing it."
        return 1
    fi
    win_log "SteamSetup.exe SHA-256 (for your records): $(win_sha256 "$dest")"
    return 0
}

# Parent whole-disk of a partition node.
win_parent_disk() {
    local pk
    pk=$(lsblk -no PKNAME "${1:?}" 2>/dev/null | head -1)
    [[ -n "$pk" ]] && echo "/dev/$pk"
}

# Trailing digit run of a partition node = its partition number.
win_part_number() {
    local digits="${1##*[!0-9]}"
    [[ -n "$digits" ]] && echo "$digits"
}

# ── Volume / path resolution ──────────────────────────────────────
# POWOS-GAMES mountpoint: the image lives on it. Required for everything.
win_games_mount() {
    local dev mnt
    dev=$(blkid -L POWOS-GAMES 2>/dev/null || true)
    [[ -z "$dev" ]] && return 1
    mnt=$(findmnt -n -o TARGET -S "$dev" 2>/dev/null | head -1)
    [[ -z "$mnt" ]] && return 1
    echo "$mnt"
}

# Unmount the games volume for a switch. If it's held by the systemd mount unit
# lib/games.sh installs (var-mnt-games.mount), stop THAT so the unit state stays
# consistent and it doesn't auto-remount after resume; otherwise plain umount.
# Returns the status of whichever unmount it performed (non-zero = still held).
win_unmount_games() {
    local mnt="$1" unit
    unit=$(systemd-escape -p --suffix=mount "$mnt" 2>/dev/null || true)
    if [[ -n "$unit" ]] && systemctl -q is-active "$unit" 2>/dev/null; then
        systemctl stop "$unit"
    else
        umount "$mnt"
    fi
}

# POWOS-DATA mountpoint: snapshots + ESP backups live on it.
win_data_mount() {
    local dev mnt
    dev=$(blkid -L POWOS-DATA 2>/dev/null || true)
    [[ -z "$dev" ]] && return 1
    mnt=$(findmnt -n -o TARGET -S "$dev" 2>/dev/null | head -1)
    [[ -z "$mnt" ]] && return 1
    echo "$mnt"
}

# Snapshots + ESP backups are stored on POWOS-DATA (btrfs), NOT beside the
# image on POWOS-GAMES: POWOS-DATA is letterless/invisible to Windows, so a
# rogue or compromised metal session can never damage its own restore
# points or the ESP backups. (Beside-the-image would be Windows-writable.)
# Default home for fetched ISOs: on POWOS-DATA (btrfs, letterless/invisible to
# Windows, and persistent) — beside snapshots + ESP backups. --dest overrides.
win_iso_dir() {
    local mnt; mnt=$(win_data_mount) || return 1
    echo "$mnt/windows/iso"
}
win_snapshot_dir() {
    local mnt; mnt=$(win_data_mount) || return 1
    echo "$mnt/windows/snapshots"
}
win_backup_dir() {
    local mnt; mnt=$(win_data_mount) || return 1
    echo "$mnt/windows"
}

# Canonical container extension / qemu format (dynamic VHDX by default,
# fixed VHD with the --fixed-vhd escape hatch — see the header rationale).
win_image_ext()  { [[ ${WIN_FIXED_VHD:-0} -eq 1 ]] && echo "vhd" || echo "vhdx"; }
win_qemu_fmt()   { [[ ${WIN_FIXED_VHD:-0} -eq 1 ]] && echo "vpc" || echo "vhdx"; }

win_image_dir()  {
    local games; games=$(win_games_mount) || return 1
    echo "$games/$WIN_IMAGE_SUBDIR"
}
win_raw_path()   {
    local dir; dir=$(win_image_dir) || return 1
    echo "$dir/windows.raw"
}
win_canon_path() {
    local dir; dir=$(win_image_dir) || return 1
    echo "$dir/windows.$(win_image_ext)"
}

# The REAL PowOS ESP (the ONLY real block device Windows ever sees, at
# install time, for its native-boot files). Read from the mounted system.
win_powos_esp() {
    local src
    src=$(findmnt -n -o SOURCE /boot/efi 2>/dev/null | head -1)
    [[ "$src" == /dev/* ]] && { echo "$src"; return 0; }
    return 1
}
win_esp_mountpoint() {
    local esp="${1:?}" mnt
    mnt=$(findmnt -n -o TARGET -S "$esp" 2>/dev/null | head -1)
    [[ -n "$mnt" ]] && echo "$mnt"
}

# Is the image file open by anything (qemu, qemu-nbd, ...)? rc 0 = IN USE.
# fuser -s: silent, exit 0 when at least one process has it open.
win_image_in_use() {
    fuser -s "${1:?}" 2>/dev/null
}

# ── Guards ────────────────────────────────────────────────────────
# Flush RAM overlay → USB, then stop the sync daemon. A failed flush means
# unsynced changes WOULD BE LOST across the switch — hard abort.
win_guard_layer_sync() {
    win_log "Flushing RAM overlay to USB (layer-sync --sync-now)…"
    if ! win_run_step "flush RAM overlay to custom layer" \
            python3 "$WIN_LAYER_SYNC" --sync-now; then
        win_err "layer-sync flush FAILED — refusing to switch."
        win_err "Unsynced RAM changes would be lost. Check: powos sync status"
        return 1
    fi
    if ! win_run_step "stop layer-sync daemon" \
            systemctl stop powos-layer-sync.service; then
        win_err "Could not stop powos-layer-sync.service — refusing to switch"
        win_err "(a sync racing the hibernation write risks a torn custom layer)."
        return 1
    fi
    return 0
}

win_guard_image_free() {
    local img="${1:?}"
    if win_image_in_use "$img"; then
        win_err "$img is OPEN by another process (qemu / qemu-nbd?)."
        win_err "Two writers on one image guarantee corruption. Close the VM first."
        return 1
    fi
    return 0
}

# Hibernation state INSIDE the image: present|absent|unknown.
# Root-gated best effort via qemu-nbd (read-only attach, probe NTFS
# partitions inside the file for hiberfil.sys). Heavy — every failure path
# answers an honest "unknown"; callers warn on unknown.
win_image_hibernated() {
    local img="${1:?}"
    if [[ ${WIN_DRY_RUN:-0} -eq 1 || ${EUID:-$(id -u)} -ne 0 ]] \
        || ! command -v qemu-nbd &>/dev/null; then
        echo "unknown"; return 0
    fi
    local nbd="/dev/nbd7" state="unknown" mp part
    modprobe nbd max_part=8 2>/dev/null || true
    if qemu-nbd --read-only -c "$nbd" "$img" 2>/dev/null; then
        partprobe "$nbd" 2>/dev/null || true
        sleep 1
        mp=$(mktemp -d)
        for part in "${nbd}"p*; do
            [[ -b "$part" ]] || continue
            [[ "$(blkid -o value -s TYPE "$part" 2>/dev/null)" == "ntfs" ]] || continue
            if mount -o ro "$part" "$mp" 2>/dev/null; then
                if [[ -e "$mp/hiberfil.sys" ]]; then state="present"; else state="absent"; fi
                umount "$mp" 2>/dev/null || true
                [[ "$state" == "present" ]] && break
            fi
        done
        rmdir "$mp" 2>/dev/null || true
        qemu-nbd -d "$nbd" 2>/dev/null || true
    fi
    echo "$state"
}

# ── Firmware boot entry lookup (boot-manager.sh pattern, sed-free) ─
# Find the 4-hex boot id whose entry label matches $1 (regex, case-insensitive)
# in efibootmgr output $2. Echoes e.g. "0003"; rc 1 if not found.
win_find_boot_entry() {
    local re="${1:?}" out="${2:-}" line
    line=$(echo "$out" | grep -iE "^Boot[0-9A-Fa-f]{4}\*?[[:space:]].*${re}" | head -1)
    [[ -z "$line" ]] && return 1
    line="${line#Boot}"
    echo "${line:0:4}"
}

# Human label of boot id $1 in efibootmgr output $2 (for messages).
win_boot_entry_label() {
    local id="${1:?}" out="${2:-}" line
    line=$(echo "$out" | grep -iE "^Boot${id}\*?[[:space:]]" | head -1)
    [[ -z "$line" ]] && return 1
    line="${line#Boot${id}}"; line="${line#\*}"
    line="${line#"${line%%[![:space:]]*}"}"
    echo "${line%%$'\t'*}"
}

# ══════════════════════════════════════════════════════════════════
#  Pure command builders
# ══════════════════════════════════════════════════════════════════

# PURE: ESP backup pipeline (display + docs; execution is inline so the
# pipeline components stay mockable). $1 = ESP mountpoint, $2 = out file.
win_build_esp_backup_cmd() {
    printf "tar -C '%s' -cf - . | zstd -q -f -o '%s'" "${1:?}" "${2:?}"
}

# PURE: the ESP restore one-liner (printed by finalize; run it if a Windows
# update ever damages the shared ESP). $1 = backup file, $2 = ESP mountpoint.
win_build_esp_restore_cmd() {
    printf "zstd -dc '%s' | tar -C '%s' -xf -" "${1:?}" "${2:?}"
}

# PURE: emit the QEMU command line.
# AHCI, NOT virtio — identical storage stack VM ↔ metal (docs/WINDOWS.md):
# what Setup installs in the VM must boot unmodified on metal.
#
# Args: disk_file disk_format esp_dev iso ram cpus ovmf_code ovmf_vars [unattend_img]
#   disk_format  raw during install, vhdx (or vpc for --fixed-vhd) for VM mode
#   esp_dev      "" to omit — install-only: the REAL PowOS ESP as a raw 2nd
#                disk so Setup's first-logon bcdboot can lay native-boot files
#   iso          "" to omit (VM mode boots the installed image directly)
#   unattend_img "" to omit (--interactive, and always in VM mode)
#
# discard=unmap + detect-zeroes=unmap keep the image file THIN: guest TRIM
# and zero-writes punch holes in the sparse raw / dynamic VHDX.
win_build_qemu_cmd() {
    local disk="${1:?}" fmt="${2:?}" esp="${3:-}" iso="${4:-}"
    local ram="${5:?}" cpus="${6:?}" ovmf_code="${7:?}" ovmf_vars="${8:?}"
    local unattend="${9:-}"
    local -a cmd=(
        qemu-system-x86_64
        -enable-kvm
        -machine "q35,smm=on"
        -cpu host
        -smp "$cpus"
        -m "$ram"
        -drive "if=pflash,format=raw,readonly=on,file=${ovmf_code}"
        -drive "if=pflash,format=raw,file=${ovmf_vars}"
        -drive "file=${disk},format=${fmt},if=none,id=windisk,discard=unmap,detect-zeroes=unmap"
        -device "ahci,id=ahci"
        -device "ide-hd,drive=windisk,bus=ahci.0"
    )
    if [[ -n "$esp" ]]; then
        cmd+=(
            -drive "file=${esp},format=raw,if=none,id=espdisk"
            -device "ide-hd,drive=espdisk,bus=ahci.1"
        )
    fi
    if [[ -n "$iso" ]]; then
        cmd+=( -drive "file=${iso},media=cdrom,readonly=on" )
    fi
    if [[ -n "$unattend" ]]; then
        cmd+=(
            -drive "file=${unattend},format=raw,if=none,id=unattend"
            -device "ide-hd,drive=unattend,bus=ahci.2"
        )
    fi
    cmd+=(
        -boot "menu=on"
        -netdev "user,id=net0"
        -device "virtio-net-pci,netdev=net0"
        -usb -device usb-tablet
        -display "gtk,gl=on" -device virtio-vga-gl
    )
    # Plain space-join: no arg contains spaces (vm.sh pattern), stays eval-safe.
    printf '%s ' "${cmd[@]}"
    echo
}

# PURE: XML-escape a value for use in element content ('&' first, or the
# escapes themselves would get re-escaped).
win_xml_escape() {
    local s="${1-}"
    # Replacements are QUOTED so they stay literal on every bash version
    # (bash 5.2's patsub_replacement gives an unquoted '&' special meaning).
    s=${s//&/"&amp;"}
    s=${s//</"&lt;"}
    s=${s//>/"&gt;"}
    s=${s//\"/"&quot;"}
    s=${s//\'/"&apos;"}
    printf '%s' "$s"
}

# PURE: loose product-key shape check (XXXXX-XXXXX-XXXXX-XXXXX-XXXXX).
# Callers WARN on mismatch, never fail — OEM/volume formats vary.
win_validate_product_key() {
    [[ "${1:-}" =~ ^[A-Za-z0-9]{5}(-[A-Za-z0-9]{5}){4}$ ]]
}

# PURE: emit a complete autounattend.xml for a ZERO-TOUCH Windows Setup run.
#
# Args: username password [locale] [keyboard] [product_key] [edition]
#       [with_steam] [vhd_bcd_path]
#   product_key  "" = keyless (DEFAULT, fully supported: unactivated with a
#                watermark only; digital licenses re-activate online)
#   edition      /IMAGE/NAME when keyless (default "Windows 11 Pro")
#   with_steam   "1" appends a best-effort silent Steam install
#   vhd_bcd_path the image path INSIDE its host volume, backslash form,
#                default \PowOS-Windows\windows.vhdx (matches win_canon_path)
#
# ASCII only, well-formed; user values XML-escaped; placeholders substituted
# with bash parameter expansion, never sed (vm.sh pattern).
win_build_autounattend() {
    local user pass locale kbd pkey edition steam vhdpath games_setup ulabel
    user=$(win_xml_escape "${1:?win_build_autounattend: username required}")
    pass=$(win_xml_escape "${2:?win_build_autounattend: password required}")
    locale=$(win_xml_escape "${3:-en-US}")
    kbd=$(win_xml_escape "${4:-en-US}")
    pkey=$(win_xml_escape "${5:-}")
    edition=$(win_xml_escape "${6:-Windows 11 Pro}")
    steam="${7:-0}"
    vhdpath=$(win_xml_escape "${8:-\\PowOS-Windows\\windows.vhdx}")
    games_setup="${9:-0}"                              # 1 = inject the Steam/library first-logon
    ulabel=$(win_xml_escape "${10:-POWOSUNAT}")        # FAT label of the unattend volume

    # Optional <Key>: only when the user supplied one. Keyless default keeps
    # WillShowUI=OnError so Setup never prompts either way.
    local keyblock=""
    [[ -n "$pkey" ]] && keyblock="<Key>${pkey}</Key>"

    # Optional best-effort Steam install (order 10). Needs network during
    # first logon; Steam self-updates on first launch. %TEMP% (cmd
    # expansion) keeps bash and PowerShell dollar signs out of the XML.
    # Optional games/Steam first-logon block. Runs a generated PowerShell
    # script (powos-first-logon.ps1, dropped on the unattend volume by
    # win_install) that: gives POWOS-GAMES a STABLE drive letter matched by NTFS
    # LABEL (letters are unpredictable pre-boot — the old blocker), preinstalls
    # Steam OFFLINE from the unattend volume (CDN fallback), and seeds the SHARED
    # library so ONE installed game serves both OSes (mirror of
    # `powos games steam-setup`). The '&amp;' is the XML-escaped PowerShell call
    # operator (the CommandLine is element content; only '&' must be escaped).
    local gamesblock=""
    if [[ "$games_setup" == "1" ]]; then
        local gb
        gb=$(cat <<'GAMESEOF'
        <SynchronousCommand wcm:action="add">
          <Order>10</Order>
          <Description>PowOS: assign POWOS-GAMES a stable letter, preinstall Steam, seed the shared library</Description>
          <CommandLine>cmd /c powershell -ExecutionPolicy Bypass -Command "$u=(Get-Volume -FileSystemLabel '__POWOS_UNATTEND_LABEL__' -ErrorAction SilentlyContinue).DriveLetter; if ($u) { &amp; ($u + ':\powos-first-logon.ps1') }"</CommandLine>
        </SynchronousCommand>
GAMESEOF
)
        gamesblock=${gb//__POWOS_UNATTEND_LABEL__/"$ulabel"}
    fi

    local steamblock=""
    if [[ "$steam" == "1" ]]; then
        steamblock=$(cat <<'STEAMEOF'
        <SynchronousCommand wcm:action="add">
          <Order>10</Order>
          <Description>PowOS (BEST EFFORT): silent Steam install (needs network)</Description>
          <CommandLine>cmd /c powershell -ExecutionPolicy Bypass -Command "Invoke-WebRequest -Uri 'https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe' -OutFile '%TEMP%\SteamSetup.exe'; Start-Process -Wait -FilePath '%TEMP%\SteamSetup.exe' -ArgumentList '/S'"</CommandLine>
        </SynchronousCommand>
STEAMEOF
)
    fi

    local xml
    xml=$(cat <<'XMLEOF'
<?xml version="1.0" encoding="utf-8"?>
<!--
  autounattend.xml (generated by: powos windows install)
  Zero-touch Windows Setup into the PowOS virtual-disk file.
  The VM's disk 0 IS the (empty) image file; the REAL PowOS ESP rides
  along as disk 1 for the native-boot files; every reference below is
  deterministic. Setup never shows a disk picker.
-->
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <SetupUILanguage>
        <UILanguage>__POWOS_LOCALE__</UILanguage>
      </SetupUILanguage>
      <InputLocale>__POWOS_KEYBOARD__</InputLocale>
      <SystemLocale>__POWOS_LOCALE__</SystemLocale>
      <UILanguage>__POWOS_LOCALE__</UILanguage>
      <UserLocale>__POWOS_LOCALE__</UserLocale>
    </component>
    <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <!--
        LabConfig bypasses: the QEMU install VM has no TPM and no Secure
        Boot, and Windows 11 Setup hard-refuses to install without them.
        These registry switches gate Setup only; bare-metal boots of the
        finished install are unaffected.
      -->
      <RunSynchronous>
        <RunSynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Path>cmd /c reg add HKLM\SYSTEM\Setup\LabConfig /v BypassTPMCheck /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>2</Order>
          <Path>cmd /c reg add HKLM\SYSTEM\Setup\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>3</Order>
          <Path>cmd /c reg add HKLM\SYSTEM\Setup\LabConfig /v BypassRAMCheck /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add">
          <Order>4</Order>
          <Path>cmd /c reg add HKLM\SYSTEM\Setup\LabConfig /v BypassCPUCheck /t REG_DWORD /d 1 /f</Path>
        </RunSynchronousCommand>
      </RunSynchronous>
      <!--
        Disk 0 is the EMPTY image file: Setup creates the whole internal
        layout (ESP + MSR + C:) inside it. Wiping disk 0 is safe BY
        CONSTRUCTION - it is the file. The REAL PowOS ESP is disk 1 and is
        not referenced by this DiskConfiguration at all.
        TODO(hw): verify the VM enumerates the image as disk 0 and the ESP
        as disk 1 (AHCI port order says yes); the mandatory ESP backup
        taken before launch covers the failure case.
      -->
      <DiskConfiguration>
        <Disk wcm:action="add">
          <DiskID>0</DiskID>
          <WillWipeDisk>true</WillWipeDisk>
          <CreatePartitions>
            <CreatePartition wcm:action="add">
              <Order>1</Order>
              <Type>EFI</Type>
              <Size>300</Size>
            </CreatePartition>
            <CreatePartition wcm:action="add">
              <Order>2</Order>
              <Type>MSR</Type>
              <Size>16</Size>
            </CreatePartition>
            <CreatePartition wcm:action="add">
              <Order>3</Order>
              <Type>Primary</Type>
              <Extend>true</Extend>
            </CreatePartition>
          </CreatePartitions>
          <ModifyPartitions>
            <ModifyPartition wcm:action="add">
              <Order>1</Order>
              <PartitionID>1</PartitionID>
              <Format>FAT32</Format>
              <Label>WINESP</Label>
            </ModifyPartition>
            <ModifyPartition wcm:action="add">
              <Order>2</Order>
              <PartitionID>3</PartitionID>
              <Format>NTFS</Format>
              <Label>Windows</Label>
            </ModifyPartition>
          </ModifyPartitions>
        </Disk>
      </DiskConfiguration>
      <ImageInstall>
        <OSImage>
          <!--
            Keyless installs must still be zero-touch: without a product key,
            multi-edition ISOs show an edition picker, so the edition is
            selected explicitly by image name here.
          -->
          <InstallFrom>
            <MetaData wcm:action="add">
              <Key>/IMAGE/NAME</Key>
              <Value>__POWOS_EDITION__</Value>
            </MetaData>
          </InstallFrom>
          <!-- Partition 3 = the Primary partition created above (C:). -->
          <InstallTo>
            <DiskID>0</DiskID>
            <PartitionID>3</PartitionID>
          </InstallTo>
          <InstallToAvailablePartition>false</InstallToAvailablePartition>
        </OSImage>
      </ImageInstall>
      <UserData>
        <!--
          User-supplied media and license; PowOS ships no Microsoft bits.
          Installing KEYLESS is fully supported: Windows runs unactivated
          (watermark + personalization lock only), machines with a digital
          license auto-activate online, and a key can be added any time in
          Settings. WillShowUI OnError keeps Setup from ever prompting.
        -->
        <AcceptEula>true</AcceptEula>
        <ProductKey>
          __POWOS_KEYBLOCK__
          <WillShowUI>OnError</WillShowUI>
        </ProductKey>
      </UserData>
    </component>
  </settings>
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <ComputerName>POWOS-WIN</ComputerName>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <InputLocale>__POWOS_KEYBOARD__</InputLocale>
      <SystemLocale>__POWOS_LOCALE__</SystemLocale>
      <UILanguage>__POWOS_LOCALE__</UILanguage>
      <UserLocale>__POWOS_LOCALE__</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>
      <UserAccounts>
        <LocalAccounts>
          <LocalAccount wcm:action="add">
            <Name>__POWOS_USER__</Name>
            <DisplayName>__POWOS_USER__</DisplayName>
            <Group>Administrators</Group>
            <Password>
              <Value>__POWOS_PASS__</Value>
              <PlainText>true</PlainText>
            </Password>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>
      <AutoLogon>
        <!-- One automatic logon so FirstLogonCommands run unattended. -->
        <Enabled>true</Enabled>
        <LogonCount>1</LogonCount>
        <Username>__POWOS_USER__</Username>
        <Password>
          <Value>__POWOS_PASS__</Value>
          <PlainText>true</PlainText>
        </Password>
      </AutoLogon>
      <!--
        FirstLogonCommands replace the manual powos-windows-postinstall.cmd
        run (that script remains the fallback artifact for interactive
        installs).
        Command 1 (powercfg /h on) is HARMLESS on metal: native-VHD boots
        always cold-boot because winresume cannot read a hiberfil inside a
        VHD - but it matters for VM-mode hibernation, which IS supported.
        Command 2 (HiberbootEnabled=0, Fast Startup off) still matters on
        metal: Fast Startup would leave the file-internal NTFS and the
        POWOS-GAMES host volume dirty.
        Command 3 (RealTimeIsUniversal) SUPERSEDES the Linux-side
        set-local-rtc approach for this flow: both OSes agree the RTC is
        UTC and neither fights over it.
        Commands 6-9 are the NATIVE-BOOT SELF-REGISTRATION (zero-touch;
        Linux cannot write a BCD, so Windows registers itself): mount the
        REAL ESP (attached as disk 1), lay bootmgr + BCD onto it with
        bcdboot, then repoint the BCD at the image file. vhd=[locate]
        makes bootmgr SEARCH every volume at boot for the path - no
        drive-letter assumption survives into metal boots, where the file
        sits on POWOS-GAMES.
        TODO(hw): mountvol /S mounts "the" EFI system partition; with two
        ESPs visible (file-internal + real) verify it picks the REAL one,
        else pin disk 1 via a diskpart script.
        NOTE: the firmware NVRAM entry can NOT be created from inside the
        VM (it has its own NVRAM) - `powos windows finalize` creates it
        host-side with efibootmgr.
      -->
      <FirstLogonCommands>
        <SynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Description>PowOS: hibernation on (VM-mode sessions; metal always cold-boots)</Description>
          <CommandLine>powercfg /h on</CommandLine>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>2</Order>
          <Description>PowOS: Fast Startup off (keeps NTFS clean for PowOS)</Description>
          <CommandLine>reg add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power" /v HiberbootEnabled /t REG_DWORD /d 0 /f</CommandLine>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>3</Order>
          <Description>PowOS: read the RTC as UTC (agrees with PowOS)</Description>
          <CommandLine>reg add HKLM\SYSTEM\CurrentControlSet\Control\TimeZoneInformation /v RealTimeIsUniversal /t REG_DWORD /d 1 /f</CommandLine>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>4</Order>
          <Description>PowOS: Return to PowOS desktop shortcut</Description>
          <CommandLine>cmd /c &gt;"C:\Users\Public\Desktop\Return to PowOS.cmd" echo shutdown /r /fw /t 0</CommandLine>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>5</Order>
          <Description>PowOS: restart apps after sign-in</Description>
          <CommandLine>reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v RestartApps /t REG_DWORD /d 1 /f</CommandLine>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>6</Order>
          <Description>PowOS: mount the REAL ESP (disk 1) at S:</Description>
          <CommandLine>mountvol S: /S</CommandLine>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>7</Order>
          <Description>PowOS: lay native-boot files + BCD onto the real ESP</Description>
          <CommandLine>bcdboot C:\Windows /s S: /f UEFI</CommandLine>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>8</Order>
          <Description>PowOS: BCD device = the VHD file (drive-letter independent)</Description>
          <CommandLine>bcdedit /store S:\EFI\Microsoft\Boot\BCD /set {default} device vhd=[locate]__POWOS_VHDPATH__</CommandLine>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>9</Order>
          <Description>PowOS: BCD osdevice = the VHD file</Description>
          <CommandLine>bcdedit /store S:\EFI\Microsoft\Boot\BCD /set {default} osdevice vhd=[locate]__POWOS_VHDPATH__</CommandLine>
        </SynchronousCommand>
__POWOS_GAMESBLOCK__
__POWOS_STEAMBLOCK__
      </FirstLogonCommands>
    </component>
  </settings>
</unattend>
XMLEOF
)
    # Replacements are QUOTED: bash 5.2's patsub_replacement would otherwise
    # expand a '&' inside them (e.g. in an escaped password) to the matched
    # pattern. Quoting keeps the replacement literal on every bash version.
    xml=${xml//__POWOS_USER__/"$user"}
    xml=${xml//__POWOS_PASS__/"$pass"}
    xml=${xml//__POWOS_LOCALE__/"$locale"}
    xml=${xml//__POWOS_KEYBOARD__/"$kbd"}
    xml=${xml//__POWOS_EDITION__/"$edition"}
    xml=${xml//__POWOS_KEYBLOCK__/"$keyblock"}
    xml=${xml//__POWOS_VHDPATH__/"$vhdpath"}
    xml=${xml//__POWOS_GAMESBLOCK__/"$gamesblock"}
    xml=${xml//__POWOS_STEAMBLOCK__/"$steamblock"}
    # Blank placeholder lines (games/steam disabled) leave an empty line each —
    # harmless in XML; keep them out so a disabled block is truly invisible.
    printf '%s\n' "$xml"
}

# PURE: emit the Windows-side post-install .cmd (plain cmd.exe batch, CRLF).
# The FALLBACK artifact for --interactive installs (unattended installs
# apply all of this via FirstLogonCommands). Run ONCE in Windows, elevated.
# The shortcut uses `shutdown /r /fw` (reboot to firmware menu); the better
# one-shot is `bcdedit /set {fwbootmgr} bootsequence {PowOS-entry-GUID}`,
# addable once the PowOS entry GUID is known.
win_build_postinstall_cmd() {
    local body
    body=$(cat <<'CMDEOF'
@echo off
rem powos-windows-postinstall.cmd -- run ONCE in Windows, from an ELEVATED prompt.
rem Generated by: powos windows finalize
rem (Unattended installs already did all of this at first logon.)
rem
rem 1) Hibernation ON: used by VM-mode sessions. Metal native-VHD boots
rem    always cold-boot (winresume cannot read a hiberfil inside a VHD).
powercfg /h on
rem
rem 2) Fast Startup OFF: it leaves NTFS partially-hibernated (dirty), which
rem    forces PowOS to mount shared volumes read-only or not at all.
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power" /v HiberbootEnabled /t REG_DWORD /d 0 /f
rem
rem 3) "Return to PowOS" desktop shortcut (firmware boot-menu fallback).
rem    Better one-shot, once the PowOS firmware entry GUID is known:
rem      bcdedit /set {fwbootmgr} bootsequence {PowOS-GUID}
>"%USERPROFILE%\Desktop\Return to PowOS.cmd" echo shutdown /r /fw /t 0
rem
rem NEVER initialize disks in Disk Management: the volumes without drive
rem letters are PowOS. You only ever see C: and POWOS-GAMES.
echo Done: hibernation on, Fast Startup off, Return-to-PowOS shortcut created.
pause
CMDEOF
)
    # cmd.exe wants CRLF line endings — emit them explicitly.
    local line
    while IFS= read -r line; do printf '%s\r\n' "$line"; done <<< "$body"
}

# PURE: emit a Steam libraryfolders.vdf that registers the SHARED library.
# Same SHAPE as lib/games.sh's gms_vdf_add_library output; the reciprocal
# Windows-side twin. index "0" is Steam's own install dir, index "1" is the
# shared <letter>:\SteamLibrary — the EXACT folder gms_steam_layout creates on
# the Linux side (<POWOS-GAMES root>/SteamLibrary), so one installed game serves
# both OSes. VDF escapes backslashes ("G:\\SteamLibrary").
#
# RECIPROCAL-ASYMMETRY NOTE (deliberate, do not "fix"): the Linux side symlinks
# steamapps/compatdata + shadercache onto btrfs because Proton prefixes/caches
# corrupt on NTFS. Windows Steam has no Proton and never uses that state, so the
# Windows side touches ONLY the library folder — it must never create or
# reference that Linux-only state. (Guard-tested: it appears nowhere here.)
#
# Args: letter [library_subdir]   (deterministic → inherently idempotent)
win_steam_libraryfolders_vdf() {
    local letter="${1:?win_steam_libraryfolders_vdf: drive letter required}"
    local sub="${2:-SteamLibrary}"
    local libpath="${letter}:\\\\${sub}"          # → G:\\SteamLibrary
    local steampath='C:\\Program Files (x86)\\Steam'
    cat <<VDFEOF
"libraryfolders"
{
	"0"
	{
		"path"		"${steampath}"
		"label"		""
		"apps"
		{
		}
	}
	"1"
	{
		"path"		"${libpath}"
		"label"		""
		"apps"
		{
		}
	}
}
VDFEOF
}

# PURE: emit the first-logon PowerShell script (powos-first-logon.ps1). Dropped
# on the unattend volume by win_install and invoked once by the games block in
# the autounattend. Three jobs, all keyed off the NTFS LABEL (never a drive
# letter — unpredictable pre-boot, the historical blocker):
#   1. give POWOS-GAMES a STABLE letter (default G:) via Add-PartitionAccessPath,
#   2. install Steam OFFLINE from the preloaded SteamSetup.exe (CDN fallback),
#   3. seed the SHARED libraryfolders.vdf (win_steam_libraryfolders_vdf).
# Only the library folder is added; the Linux-only Proton state is never
# referenced (see win_steam_libraryfolders_vdf's asymmetry note).
#
# Args: games_label games_letter [unattend_label] [steam_autostart] [setup_name] [lib_subdir]
win_build_steam_firstlogon_ps1() {
    local glabel gletter ulabel autostart setupname libsub vdf
    glabel="${1:-POWOS-GAMES}"
    gletter="${2:-G}"
    ulabel="${3:-POWOSUNAT}"
    autostart="${4:-0}"
    setupname="${5:-SteamSetup.exe}"
    libsub="${6:-SteamLibrary}"
    vdf=$(win_steam_libraryfolders_vdf "$gletter" "$libsub")

    # Optional: a console-like autostart (Steam on the Run key). Kept minimal —
    # no Big Picture forcing. Empty string when disabled.
    local autostartblock=""
    if [[ "$autostart" == "1" ]]; then
        autostartblock='reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v Steam /t REG_SZ /d "\"C:\Program Files (x86)\Steam\Steam.exe\" -silent" /f'
    fi

    local ps
    ps=$(cat <<'PS1EOF'
# powos-first-logon.ps1  (generated by: powos windows install)
# Runs ONCE at first logon in the install session. Makes the installed Windows
# arrive with POWOS-GAMES on a STABLE letter and Steam already pointed at the
# shared library — the Windows twin of `powos games steam-setup`.
$ErrorActionPreference = 'SilentlyContinue'

# 1) STABLE letter by LABEL (letters are not predictable before boot).
$want = '__POWOS_GLETTER__'
$vol = Get-Volume -FileSystemLabel '__POWOS_GLABEL__'
if ($vol -and -not $vol.DriveLetter) {
    $part = Get-Partition | Where-Object {
        ($_ | Get-Volume).FileSystemLabel -eq '__POWOS_GLABEL__'
    } | Select-Object -First 1
    if ($part) { Add-PartitionAccessPath -InputObject $part -AccessPath ($want + ':\') }
}

# 2) Install Steam. Prefer the OFFLINE bootstrapper preloaded on the unattend
#    volume (no network); fall back to the official CDN only if it is absent.
$steamExe = 'C:\Program Files (x86)\Steam\Steam.exe'
if (-not (Test-Path $steamExe)) {
    $setup = $null
    $uv = Get-Volume -FileSystemLabel '__POWOS_ULABEL__'
    if ($uv -and $uv.DriveLetter) {
        $cand = ($uv.DriveLetter + ':\__POWOS_SETUPNAME__')
        if (Test-Path $cand) { $setup = $cand }
    }
    if (-not $setup) {
        $setup = "$env:TEMP\__POWOS_SETUPNAME__"
        Invoke-WebRequest -Uri '__POWOS_STEAMURL__' -OutFile $setup
    }
    if (Test-Path $setup) { Start-Process -Wait -FilePath $setup -ArgumentList '/S' }
}

# 3) Seed the SHARED library into Steam's master libraryfolders.vdf. Same
#    <letter>:\SteamLibrary folder the Linux side creates, so a game installed
#    from either OS is visible to the other. Add ONLY the library folder — the
#    Linux-only Proton state is never created or referenced from Windows.
$cfgDir = 'C:\Program Files (x86)\Steam\config'
New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null
$vdf = @'
__POWOS_VDF__
'@
Set-Content -Path (Join-Path $cfgDir 'libraryfolders.vdf') -Value $vdf -Encoding ascii

__POWOS_AUTOSTART__
PS1EOF
)
    # Substitute placeholders with bash parameter expansion (never sed). Quoted
    # replacements stay literal on bash 5.2 (patsub_replacement '&' guard).
    ps=${ps//__POWOS_GLETTER__/"$gletter"}
    ps=${ps//__POWOS_GLABEL__/"$glabel"}
    ps=${ps//__POWOS_ULABEL__/"$ulabel"}
    ps=${ps//__POWOS_SETUPNAME__/"$setupname"}
    ps=${ps//__POWOS_STEAMURL__/"$WIN_STEAM_CDN_URL"}
    ps=${ps//__POWOS_VDF__/"$vdf"}
    ps=${ps//__POWOS_AUTOSTART__/"$autostartblock"}
    printf '%s\n' "$ps"
}

# PURE: the curated appx / provisioned-package identifiers the slim pass
# removes. MIRRORS ntdevlabs/tiny11builder's curation (the REFERENCE) —
# reviewed and PINNED by us right here; NEVER downloaded-and-executed. These are
# consumer bloat ONLY.
#
# CRITICAL anti-cheat safety (see docs/PROBLEM.md): bare-metal Windows exists
# SOLELY to run kernel anti-cheat titles (EAC/BattlEye). A strip that breaks
# them defeats the entire purpose. So this list contains NOTHING the servicing
# or security stack needs — no Windows Update / servicing stack, no .NET, no VC
# runtime (Microsoft.VCLibs), no Defender. That invariant is guard-tested.
# Xbox pieces are included with CAUTION (overlay + store app only); the Xbox
# Identity Provider is deliberately KEPT — multiplayer titles sign in through it.
win_slim_package_list() {
    cat <<'PKGS'
Clipchamp.Clipchamp
Microsoft.BingNews
Microsoft.BingWeather
Microsoft.BingSearch
Microsoft.GetHelp
Microsoft.Getstarted
Microsoft.MicrosoftOfficeHub
Microsoft.MicrosoftSolitaireCollection
Microsoft.People
Microsoft.PowerAutomateDesktop
Microsoft.Todos
Microsoft.WindowsAlarms
Microsoft.WindowsCommunicationsApps
Microsoft.WindowsFeedbackHub
Microsoft.WindowsMaps
Microsoft.WindowsSoundRecorder
Microsoft.ZuneMusic
Microsoft.ZuneVideo
Microsoft.YourPhone
Microsoft.GamingApp
Microsoft.Xbox.TCUI
Microsoft.XboxGamingOverlay
Microsoft.XboxGameOverlay
Microsoft.XboxSpeechToTextOverlay
MicrosoftTeams
MicrosoftCorporationII.MicrosoftFamily
Microsoft.Windows.Copilot
Microsoft.Copilot
Microsoft.WidgetsPlatformRuntime
Microsoft.Windows.DevHome
PKGS
}

# PURE: default output path for a slim pass — beside the source, "-slim" tag.
win_slim_default_out() {
    local src="${1:?}"
    case "$src" in
        *.iso|*.ISO) echo "${src%.*}-slim.iso" ;;
        *)           echo "${src}-slim.iso" ;;
    esac
}

# ══════════════════════════════════════════════════════════════════
#  create — the virtual disk file (NO partitioning, ever)
# ══════════════════════════════════════════════════════════════════
win_create() {
    win_step "Create the Windows virtual disk (EXPERIMENTAL — TODO(hw))"

    if [[ ${WIN_DRY_RUN:-0} -eq 0 ]]; then
        win_require_root "create" || return 1
    fi
    if ! [[ "${WIN_SIZE_GB:-}" =~ ^[0-9]+$ ]] || (( WIN_SIZE_GB < 40 )); then
        win_err "--size must be a whole number of GB, at least 40 (got: '${WIN_SIZE_GB:-}')."
        return 1
    fi

    local games
    games=$(win_games_mount) || {
        win_err "POWOS-GAMES is not mounted — the Windows image lives on it."
        win_err "Mount it first:  powos games mount"
        win_err "(No POWOS-GAMES partition? Re-burn the USB with --games-gb N.)"
        return 1
    }
    local dir="$games/$WIN_IMAGE_SUBDIR"
    local raw="$dir/windows.raw" canon="$dir/windows.$(win_image_ext)"

    if [[ -e "$canon" ]]; then
        win_err "A Windows image already exists: $canon"
        win_err "Boot it:  powos windows   (metal)  /  powos windows vm"
        return 1
    fi
    if [[ -e "$raw" ]]; then
        win_err "An installation image already exists: $raw"
        win_err "Continue with:  powos windows install --iso <path>"
        win_err "(or finish a completed install:  powos windows finalize)"
        return 1
    fi

    win_step "Plan"
    echo "  Image file : $raw"
    echo "  Max size   : ${WIN_SIZE_GB}G  (THIN: sparse file — actual usage grows with use)"
    echo "  Lifecycle  : raw (install target) → finalize converts to"
    echo "               windows.$(win_image_ext) (native-bootable, stays thin)"
    echo "  No partitions are created or modified — Windows lives in this file."
    echo
    win_confirm "Create the image file?" || {
        win_log "Aborted. Nothing was changed."
        return 1
    }

    win_run_step "create image directory" mkdir -p "$dir" || return 1
    win_run_step "create sparse raw image (${WIN_SIZE_GB}G max)" \
        truncate -s "${WIN_SIZE_GB}G" "$raw" || return 1

    win_step "Done"
    win_ok "Image file ready (0 bytes used until Windows writes)."
    echo "  Next step — run Windows Setup (your own ISO) into it:"
    echo
    echo -e "    ${WIN_BOLD}powos windows install --iso /path/to/Win11.iso${WIN_NC}"
    echo "  No ISO yet? Download + verify the official one (optionally slim it):"
    echo -e "    ${WIN_BOLD}powos windows fetch-iso [--slim]${WIN_NC}   or   ${WIN_BOLD}install --fetch [--slim]${WIN_NC}"
    echo "  (A slimmed/tiny11-sized install pairs well with --fixed-vhd.)"
    echo
}

# ══════════════════════════════════════════════════════════════════
#  install — Windows Setup in QEMU: disk 0 = the file, disk 1 = REAL ESP
# ══════════════════════════════════════════════════════════════════

# Teardown for the unattend volume (trap-safe, best-effort).
win_install_teardown() {
    if [[ -n "${WIN_TD_UNATTEND_MNT:-}" ]]; then
        umount "$WIN_TD_UNATTEND_MNT" 2>/dev/null
        rmdir "$WIN_TD_UNATTEND_MNT" 2>/dev/null
        WIN_TD_UNATTEND_MNT=""
    fi
    return 0
}

# Root-gated ESP backup: tar the shared ESP's contents to POWOS-DATA before
# Windows ever touches it. MANDATORY — install refuses to proceed without
# it, because Setup's first-logon bcdboot writes onto the REAL ESP and this
# backup is the one-restore-away safety net.
# Executed inline (not via bash -c) so tar/zstd stay test-mockable.
win_backup_esp() {
    local src="${1:?}" out="${2:?}"
    echo -e "  ${WIN_DIM}\$ $(win_build_esp_backup_cmd "$src" "$out")${WIN_NC}"
    if [[ ${WIN_DRY_RUN:-0} -eq 1 ]]; then
        win_warn "dry-run: skipped (ESP backup)"
        return 0
    fi
    if ! tar -C "$src" -cf - . | zstd -q -f -o "$out"; then
        win_err "ESP backup FAILED."
        return 1
    fi
    if [[ ! -s "$out" ]]; then
        win_err "ESP backup file is empty: $out"
        return 1
    fi
    win_ok "ESP backed up: $out"
    return 0
}

win_install() {
    win_step "Install Windows into the image (EXPERIMENTAL — TODO(hw))"

    # --fetch convenience: acquire the OFFICIAL ISO first (optionally --slim it),
    # then install the result. win_fetch_iso reports the produced ISO path in
    # WIN_FETCHED_ISO (the slim output when slimmed).
    if [[ ${WIN_FETCH:-0} -eq 1 && -z "$WIN_ISO" ]]; then
        win_log "--fetch: acquiring the official Windows ISO before installing…"
        win_fetch_iso || { win_err "fetch-iso failed — not installing."; return 1; }
        WIN_ISO="${WIN_FETCHED_ISO:-}"
        if [[ -z "$WIN_ISO" ]]; then
            win_err "fetch-iso did not yield an ISO path."
            return 1
        fi
        win_ok "Installing from the fetched ISO: $WIN_ISO"
    fi

    if [[ -z "$WIN_ISO" ]]; then
        win_err "A user-supplied Windows ISO is required:"
        win_err "  powos windows install --iso /path/to/Win11.iso"
        win_err "  powos windows install --fetch   (download the official ISO first)"
        win_err "(PowOS ships no Microsoft bits — your ISO, your license.)"
        return 1
    fi
    if [[ ${WIN_DRY_RUN:-0} -eq 0 && ! -f "$WIN_ISO" ]]; then
        win_err "ISO not found: $WIN_ISO"
        return 1
    fi

    # --slim with a directly-supplied --iso: the --fetch path already slims its
    # download, but a user-provided ISO would otherwise be installed FULL while
    # the help/plan imply it was slimmed. Debloat it here so --slim always means
    # slim, whatever the ISO source.
    if [[ ${WIN_SLIM:-0} -eq 1 && ${WIN_FETCH:-0} -ne 1 ]]; then
        local _slimout
        _slimout=$(win_slim_default_out "$WIN_ISO")
        win_log "--slim: debloating $WIN_ISO → $_slimout"
        win_slim_iso "$WIN_ISO" "$_slimout" || { win_err "slim failed — not installing."; return 1; }
        WIN_ISO="$_slimout"
    fi

    local games
    games=$(win_games_mount) || {
        win_err "POWOS-GAMES is not mounted — mount it first:  powos games mount"
        return 1
    }
    local dir="$games/$WIN_IMAGE_SUBDIR"
    local raw="$dir/windows.raw" canon="$dir/windows.$(win_image_ext)"
    if [[ -e "$canon" ]]; then
        win_err "Windows is already installed ($canon)."
        win_err "Boot it:  powos windows  /  powos windows vm"
        win_err "To reinstall: snapshot/remove the image, then powos windows create."
        return 1
    fi
    if [[ ! -e "$raw" ]]; then
        win_err "No installation image found. Create it first:"
        win_err "  powos windows create [--size N]"
        return 1
    fi
    win_guard_image_free "$raw" || return 1

    # The REAL PowOS ESP: the ONLY real block device the VM gets — Setup's
    # first-logon bcdboot lays the native-boot files onto it.
    local esp esp_mnt
    esp=$(win_powos_esp) || {
        win_err "Could not identify the PowOS ESP (nothing mounted at /boot/efi)."
        win_err "The install VM needs it (as a 2nd disk) for the native-boot files."
        return 1
    }
    esp_mnt=$(win_esp_mountpoint "$esp") || {
        win_err "Could not resolve the ESP mountpoint for backup."
        return 1
    }

    # Backup destination on POWOS-DATA.
    local bdir bfile
    bdir=$(win_backup_dir) || {
        win_err "POWOS-DATA is not mounted — the mandatory ESP backup lives on it."
        return 1
    }
    bfile="$bdir/esp-backup-$(date +%Y%m%d-%H%M%S).tar.zst"

    win_step "Plan"
    echo "  ISO (user-supplied): $WIN_ISO"
    echo "  Disk 0 (target):     $raw  (raw sparse file — Setup creates its own"
    echo "                       internal ESP+MSR+C: layout inside it)"
    echo "  Disk 1 (REAL):       $esp  — the shared PowOS ESP, the ONLY real"
    echo "                       device Windows sees; needed for metal boot files"
    echo "  ESP backup (FIRST):  $bfile"
    echo "                       (mandatory — install aborts if it fails)"
    [[ -n "$WIN_CONFIG_LOADED" ]] && \
        echo "  Config:              $WIN_CONFIG_LOADED (WINDOWS_* defaults; flags override)"
    echo "  VM:                  ${WIN_RAM} RAM, ${WIN_CPUS} vCPUs, OVMF, AHCI, boot menu on"
    if [[ ${WIN_INTERACTIVE:-0} -eq 1 ]]; then
        echo "  Unattend:            no (--interactive: you click through Setup yourself)"
    else
        echo "  Unattend:            ZERO-TOUCH — autounattend.xml on a 64MiB FAT volume"
        echo "                       (disk 2); wipes DISK 0 ONLY (the file), installs,"
        echo "                       then self-registers native boot (mountvol S: /S;"
        echo "                       bcdboot C:\\Windows /s S: /f UEFI; bcdedit device/"
        echo "                       osdevice vhd=[locate]\\${WIN_IMAGE_SUBDIR}\\windows.$(win_image_ext))"
        echo "                       account '${WIN_USERNAME}', edition '${WIN_EDITION}',"
        echo "                       locale ${WIN_LOCALE}, keyboard ${WIN_KEYBOARD}"
        if [[ -n "$WIN_PRODUCT_KEY" ]]; then
            echo "                       product key: supplied"
            if ! win_validate_product_key "$WIN_PRODUCT_KEY"; then
                win_warn "Product key does not look like XXXXX-XXXXX-XXXXX-XXXXX-XXXXX —"
                win_warn "proceeding anyway (OEM/volume formats vary), but double-check it."
            fi
        else
            echo "                       product key: none (keyless install — Windows runs"
            echo "                       unactivated; digital licenses re-activate online)"
        fi
        if [[ ${WIN_NO_GAMES:-0} -eq 0 ]]; then
            echo "                       Games: POWOS-GAMES pinned to ${WIN_GAMES_LETTER}: (matched by"
            echo "                       LABEL), Steam PREINSTALLED offline, shared library"
            echo "                       ${WIN_GAMES_LETTER}:\\${WIN_STEAM_LIB_SUBDIR} seeded (one install serves both OSes)"
            [[ ${WIN_STEAM_AUTOSTART:-0} -eq 1 ]] && \
                echo "                       Steam autostart: on (Run key)"
        elif [[ ${WIN_WITH_STEAM:-0} -eq 1 ]]; then
            echo "                       Steam: BEST-EFFORT CDN silent install at first logon"
        fi
        if [[ "$WIN_PASSWORD" == "powos" ]]; then
            win_warn "DEFAULT PASSWORD 'powos' in use for the Windows account!"
            win_warn "Change it in Windows after first logon, or pass --password now."
        fi
    fi
    echo

    # Native VHD boot prefers a FIXED VHD; a small (slim/tiny11) install makes
    # that practical up front — a dynamic VHDX balloons toward its full --size
    # on the first metal boot (docs/PROBLEM.md cost note 1).
    local _small=0
    [[ ${WIN_SLIM:-0} -eq 1 ]] && _small=1
    if [[ $_small -eq 0 && ${WIN_DRY_RUN:-0} -eq 0 && -f "$WIN_ISO" ]]; then
        local _isz; _isz=$(win_file_size_bytes "$WIN_ISO" 2>/dev/null || echo 0)
        [[ -n "$_isz" && "$_isz" -gt 0 && "$_isz" -lt 4294967296 ]] && _small=1
    fi
    [[ $_small -eq 1 ]] && win_fixed_vhd_hint

    if [[ ${WIN_DRY_RUN:-0} -eq 1 ]]; then
        win_warn "dry-run: stopping before the ESP backup and VM launch. Nothing was changed."
        return 0
    fi

    win_require_root "install" || return 1
    local t req_tools=(qemu-system-x86_64 tar zstd)
    [[ ${WIN_INTERACTIVE:-0} -eq 0 ]] && req_tools+=(mkfs.vfat truncate)
    for t in "${req_tools[@]}"; do
        command -v "$t" &>/dev/null || { win_err "Required tool missing: $t"; return 1; }
    done
    if ! win_is_block "$esp"; then
        win_err "$esp is not a block device."
        return 1
    fi

    # OVMF firmware (vm.sh candidates) + per-run writable NVRAM copy.
    local ovmf_code src_vars ovmf_vars
    ovmf_code=$(win_find_first_existing "${WIN_OVMF_CODE_CANDIDATES[@]}") || {
        win_err "OVMF UEFI firmware not found. Install edk2-ovmf."; return 1
    }
    src_vars=$(win_find_first_existing "${WIN_OVMF_VARS_CANDIDATES[@]}") || {
        win_err "OVMF_VARS template not found (edk2-ovmf)."; return 1
    }
    ovmf_vars="${WIN_RUNDIR}/install_VARS.fd"

    win_confirm "Back up the ESP and boot Windows Setup?" || {
        win_log "Aborted. Nothing was changed."
        return 1
    }

    mkdir -p "$WIN_RUNDIR" "$bdir" || return 1
    [[ -f "$ovmf_vars" ]] || cp "$src_vars" "$ovmf_vars" || return 1

    # ── 1. MANDATORY ESP backup — strictly BEFORE anything touches it ──
    win_backup_esp "$esp_mnt" "$bfile" || {
        win_err "Refusing to continue without an ESP backup."
        return 1
    }

    # ── 2. Unmount the ESP: the VM gets it raw; a host rw-mount racing
    #      guest writes is the classic mounted-disk corruption (vm.sh rule).
    win_run_step "unmount host ESP ($esp_mnt)" umount "$esp_mnt" || {
        win_err "Could not unmount $esp_mnt — refusing to hand a mounted"
        win_err "filesystem to the VM."
        return 1
    }

    trap 'win_install_teardown' EXIT INT TERM

    # ── 3. Unattend volume: a tiny FAT disk carrying autounattend.xml, and
    #      (unless --no-games) the Steam first-logon script + preloaded
    #      SteamSetup.exe. The FAT volume carries an NTFS-style LABEL so the
    #      first-logon PowerShell can find both it and POWOS-GAMES by label. ──
    local unattend_img=""
    local games_setup=0 steam_arg="$WIN_WITH_STEAM"
    if [[ ${WIN_NO_GAMES:-0} -eq 0 ]]; then
        games_setup=1        # the ps1 owns Steam (offline preinstall + CDN fallback)
        steam_arg=0          # …so do NOT also inject the CDN inline Steam block
    fi
    if [[ ${WIN_INTERACTIVE:-0} -eq 0 ]]; then
        local xml ump vhdpath
        vhdpath="\\${WIN_IMAGE_SUBDIR}\\windows.$(win_image_ext)"
        xml=$(win_build_autounattend "$WIN_USERNAME" "$WIN_PASSWORD" \
                "$WIN_LOCALE" "$WIN_KEYBOARD" "$WIN_PRODUCT_KEY" \
                "$WIN_EDITION" "$steam_arg" "$vhdpath" \
                "$games_setup" "$WIN_UNATTEND_LABEL")
        unattend_img="${WIN_RUNDIR}/unattend.img"
        win_run_step "create unattend volume (64MiB, sparse)" \
            truncate -s 64M "$unattend_img" || { trap - EXIT INT TERM; win_install_teardown; return 1; }
        win_run_step "format + label unattend volume (FAT '$WIN_UNATTEND_LABEL')" \
            mkfs.vfat -n "$WIN_UNATTEND_LABEL" "$unattend_img" >/dev/null || { trap - EXIT INT TERM; win_install_teardown; return 1; }
        local ump_dir
        ump_dir=$(mktemp -d) || { trap - EXIT INT TERM; win_install_teardown; return 1; }
        WIN_TD_UNATTEND_MNT="$ump_dir"
        win_run_step "mount unattend volume" \
            mount -o loop "$unattend_img" "$ump_dir" || { trap - EXIT INT TERM; win_install_teardown; return 1; }
        echo -e "  ${WIN_DIM}\$ (write) ${ump_dir}/autounattend.xml${WIN_NC}"
        if ! printf '%s\n' "$xml" > "$ump_dir/autounattend.xml"; then
            win_err "Could not write autounattend.xml."
            trap - EXIT INT TERM; win_install_teardown; return 1
        fi
        # Steam + shared-library first-logon payload (default; --no-games skips).
        if [[ $games_setup -eq 1 ]]; then
            local ps1
            ps1=$(win_build_steam_firstlogon_ps1 "$WIN_GAMES_LABEL" \
                    "$WIN_GAMES_LETTER" "$WIN_UNATTEND_LABEL" \
                    "$WIN_STEAM_AUTOSTART" "$WIN_STEAM_SETUP_NAME" \
                    "$WIN_STEAM_LIB_SUBDIR")
            echo -e "  ${WIN_DIM}\$ (write) ${ump_dir}/powos-first-logon.ps1${WIN_NC}"
            printf '%s\n' "$ps1" > "$ump_dir/powos-first-logon.ps1" || \
                win_warn "Could not write the Steam first-logon script — continuing."
            # Preload the OFFICIAL Steam bootstrapper onto the volume (best
            # effort — first logon falls back to the CDN if this is absent).
            win_fetch_steam_setup "$ump_dir/$WIN_STEAM_SETUP_NAME" || \
                win_warn "Steam preload failed — first logon will use the CDN fallback."
        fi
        win_run_step "unmount unattend volume" umount "$ump_dir" || { trap - EXIT INT TERM; win_install_teardown; return 1; }
        WIN_TD_UNATTEND_MNT=""
        rmdir "$ump_dir" 2>/dev/null || true
    fi

    # ── 4. Launch Setup ──
    local qemu_cmd
    qemu_cmd=$(win_build_qemu_cmd "$raw" raw "$esp" "$WIN_ISO" \
                                  "$WIN_RAM" "$WIN_CPUS" \
                                  "$ovmf_code" "$ovmf_vars" "$unattend_img")
    if [[ ${WIN_INTERACTIVE:-0} -eq 1 ]]; then
        win_ok "Launching Windows Setup (interactive — click through it in the VM)…"
    else
        win_ok "Launching Windows Setup (unattended — watch it install itself)…"
    fi
    echo -e "  ${WIN_DIM}${qemu_cmd}${WIN_NC}"
    eval "$qemu_cmd"
    local vmrc=$?

    trap - EXIT INT TERM
    win_install_teardown

    # ── 5. Remount the ESP on the host (best effort). ──
    win_run_step "remount host ESP" mount "$esp" "$esp_mnt" || \
        win_warn "Could not remount $esp at $esp_mnt — remount it manually."

    if [[ $vmrc -ne 0 ]]; then
        win_warn "QEMU exited with status $vmrc."
    fi
    win_step "Next steps"
    echo "  1. If Setup finished (Windows reached the desktop in the VM):"
    echo -e "       ${WIN_BOLD}powos windows finalize${WIN_NC}"
    echo "     converts raw → windows.$(win_image_ext) (thin, native-bootable), verifies"
    echo "     the ESP boot files, and creates the host firmware entry."
    echo "  2. Then switch with:  powos windows"
    echo
    echo "  ESP restore (if Windows ever damages the shared ESP):"
    echo "    $(win_build_esp_restore_cmd "$bfile" "$esp_mnt")"
    return 0
}

# ══════════════════════════════════════════════════════════════════
#  finalize — raw→VHDX conversion, ESP verification, firmware entry
# ══════════════════════════════════════════════════════════════════
win_finalize() {
    win_step "Finalize the Windows install (EXPERIMENTAL — TODO(hw))"

    local games
    games=$(win_games_mount) || {
        win_err "POWOS-GAMES is not mounted — mount it first:  powos games mount"
        return 1
    }
    local dir="$games/$WIN_IMAGE_SUBDIR"
    local raw="$dir/windows.raw" canon="$dir/windows.$(win_image_ext)"

    if [[ ${WIN_DRY_RUN:-0} -eq 0 ]]; then
        win_require_root "finalize" || return 1
        win_require_efi || return 1
    fi

    # ── 1. Pending raw → container conversion ──────────────────────
    if [[ -e "$canon" ]]; then
        win_ok "Container image present: $canon (conversion already done)."
        if [[ -e "$raw" ]]; then
            win_warn "Stale $raw still present — remove it once you've verified"
            win_warn "the converted image boots:  rm '$raw'"
        fi
    elif [[ -e "$raw" ]]; then
        win_guard_image_free "$raw" || return 1
        # Dynamic VHDX: thin on NTFS AND native-bootable by bootmgr.
        # --fixed-vhd: fixed-subformat VHD (vpc) — bootmgr's oldest, safest
        # native-boot format; qemu-img writes it sparse so NTFS still only
        # stores used blocks. See the header rationale.
        if [[ ${WIN_FIXED_VHD:-0} -eq 1 ]]; then
            win_run_step "convert raw → fixed VHD (sparse on disk)" \
                qemu-img convert -O vpc -o subformat=fixed "$raw" "$canon" || return 1
        else
            win_run_step "convert raw → dynamic VHDX (thin, native-bootable)" \
                qemu-img convert -O vhdx -o subformat=dynamic "$raw" "$canon" || return 1
        fi
        if [[ ${WIN_DRY_RUN:-0} -eq 0 && ! -s "$canon" ]]; then
            win_err "Conversion produced no output — keeping $raw."
            return 1
        fi
        win_run_step "delete the raw install image" rm -f "$raw" || true
        win_ok "Converted: $canon"
    else
        win_err "No Windows image found under $dir."
        win_err "Run:  powos windows create   then   powos windows install --iso <path>"
        return 1
    fi

    # ── 2. Verify the ESP gained the native-boot files ─────────────
    # BCD is binary; presence of EFI/Microsoft/Boot/BCD + bootmgfw.efi is
    # the testable proxy for "bcdboot ran and the BCD points at
    # vhd=[locate]" (Setup's first-logon self-registration).
    local esp esp_mnt
    esp=$(win_powos_esp) || {
        win_err "Could not identify the PowOS ESP (nothing mounted at /boot/efi)."
        return 1
    }
    esp_mnt=$(win_esp_mountpoint "$esp") || {
        win_err "ESP is not mounted — mount it (e.g. at /boot/efi) and re-run."
        return 1
    }
    if [[ ${WIN_DRY_RUN:-0} -eq 1 ]]; then
        win_warn "dry-run: skipping ESP boot-file verification."
    elif [[ -e "$esp_mnt/EFI/Microsoft/Boot/BCD" && -e "$esp_mnt/EFI/Microsoft/Boot/bootmgfw.efi" ]]; then
        win_ok "ESP carries EFI/Microsoft/Boot (BCD + bootmgfw.efi)."
    else
        win_err "ESP is missing EFI/Microsoft/Boot/BCD or bootmgfw.efi."
        win_err "The install's first-logon self-registration did not complete —"
        win_err "boot the VM once more (powos windows vm) and let first logon"
        win_err "finish, or run bcdboot manually inside Windows."
        return 1
    fi

    # ── 3. Host-side firmware entry ────────────────────────────────
    # bcdboot inside the VM wrote the ESP FILES, but it can NOT create the
    # host's NVRAM entry — the VM has its own NVRAM. Create it here.
    local disk pnum efi_out entry_id
    disk=$(win_parent_disk "$esp" || true)
    pnum=$(win_part_number "$esp" || true)
    if [[ -z "$disk" || -z "$pnum" ]]; then
        win_err "Could not derive disk/partition number from $esp."
        return 1
    fi
    efi_out=$(efibootmgr 2>/dev/null || true)
    entry_id=$(win_find_boot_entry "windows|microsoft" "$efi_out" || true)
    if [[ -n "$entry_id" ]]; then
        win_ok "Firmware entry already exists: Boot${entry_id} ($(win_boot_entry_label "$entry_id" "$efi_out" || echo Windows))"
    else
        win_run_step "create firmware boot entry (ESP: $disk part $pnum)" \
            efibootmgr -c -d "$disk" -p "$pnum" -L "Windows Boot Manager" \
                -l '\EFI\Microsoft\Boot\bootmgfw.efi' || {
            win_err "efibootmgr -c failed."
            return 1
        }
        if [[ ${WIN_DRY_RUN:-0} -eq 0 ]]; then
            efi_out=$(efibootmgr 2>/dev/null || true)
            entry_id=$(win_find_boot_entry "windows|microsoft" "$efi_out" || true)
            if [[ -z "$entry_id" ]]; then
                win_err "Created the entry but 'powos boot windows' cannot resolve it."
                win_err "Inspect with: efibootmgr -v"
                return 1
            fi
            win_ok "Verified: 'powos boot windows' resolves Boot${entry_id}."
        fi
    fi

    # ── 4. Fallback .cmd for interactive installs ──────────────────
    local script target="$dir/powos-windows-postinstall.cmd"
    script=$(win_build_postinstall_cmd)
    if [[ ${WIN_DRY_RUN:-0} -eq 1 ]]; then
        win_warn "dry-run: would write the fallback post-install script to $target"
    elif printf '%s' "$script" > "$target"; then
        win_log "Fallback post-install script (interactive installs): $target"
    else
        win_warn "Could not write $target — not fatal (unattended installs don't need it)."
    fi

    # ── 5. ESP restore one-liner ───────────────────────────────────
    local bdir latest=""
    bdir=$(win_backup_dir 2>/dev/null || true)
    if [[ -n "$bdir" ]]; then
        local f
        for f in "$bdir"/esp-backup-*.tar.zst; do
            [[ -e "$f" ]] && latest="$f"   # glob sorts: last = newest timestamp
        done
    fi
    win_step "Done"
    if [[ -n "$latest" ]]; then
        echo "  If a Windows update ever damages the shared ESP, restore it with:"
        echo -e "    ${WIN_BOLD}$(win_build_esp_restore_cmd "$latest" "$esp_mnt")${WIN_NC}"
    else
        win_warn "No ESP backup found under ${bdir:-<POWOS-DATA>/windows} — one is taken"
        win_warn "automatically by 'powos windows install'."
    fi
    echo -e "  Switch with:  ${WIN_BOLD}powos windows${WIN_NC}"
}

# ══════════════════════════════════════════════════════════════════
#  the switch — powos windows (no subcommand): metal COLD boot
# ══════════════════════════════════════════════════════════════════
win_switch() {
    echo
    echo -e "${WIN_YELLOW}${WIN_BOLD}╔══════════════════════════════════════════════════════════════╗${WIN_NC}"
    echo -e "${WIN_YELLOW}${WIN_BOLD}║  EXPERIMENTAL: bare-metal OS switch (PowOS → Windows)        ║${WIN_NC}"
    echo -e "${WIN_YELLOW}${WIN_BOLD}║  TODO(hw): not yet validated on real hardware                ║${WIN_NC}"
    echo -e "${WIN_YELLOW}${WIN_BOLD}╚══════════════════════════════════════════════════════════════╝${WIN_NC}"
    echo

    if [[ ${WIN_DRY_RUN:-0} -eq 0 ]]; then
        win_require_root "" || return 1
    fi
    win_require_efi || return 1

    local games
    games=$(win_games_mount) || {
        win_err "POWOS-GAMES is not mounted — the Windows image lives on it."
        win_err "Mount it first:  powos games mount"
        return 1
    }
    local dir="$games/$WIN_IMAGE_SUBDIR"
    local raw="$dir/windows.raw" canon="$dir/windows.$(win_image_ext)"
    if [[ ! -e "$canon" ]]; then
        if [[ -e "$raw" ]]; then
            win_err "The image is still raw ($raw) — native boot needs the container."
            win_err "Finish it first:  powos windows finalize"
        else
            win_err "No Windows image found — set it up first:  powos windows create"
        fi
        return 1
    fi

    # ── Guards (all enforced, none advisory) ──────────────────────
    win_guard_image_free "$canon" || return 1

    # Hibernation-inside-the-image policy (metal): metal native-VHD boots
    # ALWAYS COLD-BOOT — winresume cannot read a hiberfil inside a VHD. If a
    # VM session left a hibernation image, metal Windows will prompt to
    # DISCARD it (that VM session is lost; no corruption). Warn before the
    # confirmation gate so the user decides informed.
    local hstate
    hstate=$(win_image_hibernated "$canon")
    case "$hstate" in
        absent)
            win_log "No hibernation image inside the file — clean cold boot." ;;
        present)
            win_warn "The image holds a VM-hibernated Windows session. A METAL boot"
            win_warn "cold-boots and Windows will prompt to DISCARD that session"
            win_warn "(resume it instead with: powos windows vm)." ;;
        *)
            win_warn "Could not determine the image's hibernation state. If a VM"
            win_warn "session was hibernated inside it, a metal boot discards it." ;;
    esac

    # Firmware entry must exist before we flush anything.
    local efi_out entry_id label
    efi_out=$(efibootmgr 2>/dev/null || true)
    entry_id=$(win_find_boot_entry "windows|microsoft" "$efi_out" || true)
    if [[ -z "$entry_id" ]]; then
        win_err "No Windows firmware boot entry found."
        win_err "Create it with:  powos windows finalize"
        return 1
    fi
    label=$(win_boot_entry_label "$entry_id" "$efi_out" || echo "Windows Boot Manager")
    win_log "Firmware entry: Boot${entry_id} (${label})"

    echo
    echo "  Plan: flush layer-sync → stop daemon → unmount POWOS-GAMES →"
    echo "        BootNext Boot${entry_id} → sync → hibernate PowOS"
    echo "  Metal Windows always COLD-BOOTS (native-VHD design; hibernation is"
    echo "  a VM-mode feature). Coming back: the 'Return to PowOS' shortcut."
    echo
    win_confirm "Switch to Windows now?" || {
        win_log "Aborted. Nothing was changed."
        return 1
    }

    # Flush + stop layer-sync — a failure here is a hard abort (see guard).
    win_guard_layer_sync || return 1

    # Unmount POWOS-GAMES: PowOS hibernates with its mounts FROZEN, and the
    # metal Windows session writes this NTFS volume (it hosts the image).
    # A frozen rw-mount under another OS's writes = corruption on resume —
    # the one rule that keeps switching safe, file edition. Refuse if busy.
    # Stop the games mount unit if that's how it's mounted (clean unit state,
    # and no auto-remount after resume); fall back to a plain umount otherwise.
    win_run_step "unmount POWOS-GAMES ($games)" \
        win_unmount_games "$games" || {
        win_err "Could not unmount $games (busy?) — refusing to switch."
        win_err "Close whatever uses it, or inspect:  fuser -vm '$games'"
        return 1
    }

    win_run_step "set one-shot BootNext (Boot${entry_id})" \
        efibootmgr --bootnext "$entry_id" || {
        win_err "Failed to set BootNext."
        return 1
    }
    win_run_step "flush filesystem buffers" sync

    if win_run_step "hibernate PowOS (S4 — PowOS session preserved)" systemctl hibernate; then
        # On a working setup we never get here awake; under dry-run we do.
        win_ok "Hibernate requested. Windows cold-boots from the image file."
        return 0
    fi

    # ── Hibernate failed: explain exactly what's missing ──────────
    echo
    win_err "systemctl hibernate FAILED. Likely causes (docs/HIBERNATION.md):"
    win_err "  • no swap sized ≥ RAM on the USB (S4 writes the whole session there)"
    win_err "  • no resume= kernel argument pointing at that swap"
    win_err "  • kernel lockdown / secure boot restrictions"
    echo
    win_warn "Fallback: a PLAIN REBOOT into Windows loses the live PowOS session,"
    win_warn "but nothing else — layer-sync already flushed all changes to USB."
    if [[ ${WIN_REBOOT_FALLBACK:-0} -eq 1 ]]; then
        win_run_step "reboot into Windows (BootNext is set)" systemctl reboot
        return $?
    fi
    if [[ ${WIN_ASSUME_YES:-0} -eq 1 ]]; then
        win_log "Not rebooting automatically (--yes given without --reboot)."
        win_log "Re-run with --reboot, or:  systemctl reboot   (BootNext is already set)"
        return 1
    fi
    local ans
    read -r -p "Plain reboot into Windows instead? [y/N] " ans
    if [[ "$ans" =~ ^[Yy]$ ]]; then
        win_run_step "reboot into Windows (BootNext is set)" systemctl reboot
        return $?
    fi
    win_log "Not rebooting. BootNext is set — the NEXT reboot lands in Windows;"
    win_log "clear it with:  efibootmgr --delete-bootnext"
    return 1
}

# ══════════════════════════════════════════════════════════════════
#  snapshots — file-level: zstd copy of the image
#  (Future work: differencing-VHDX children would make snapshots instant
#   and rollback = drop-the-child; today's whole-file zstd copy is simple,
#   format-agnostic and restore-proof.)
# ══════════════════════════════════════════════════════════════════

# Shared pre-flight: image exists and nothing has it open.
win_snapshot_preflight() {
    local canon
    canon=$(win_canon_path 2>/dev/null || true)
    if [[ -z "$canon" ]]; then
        win_err "POWOS-GAMES is not mounted — mount it first:  powos games mount"
        return 1
    fi
    if [[ ! -e "$canon" ]]; then
        local raw; raw=$(win_raw_path 2>/dev/null || true)
        if [[ -n "$raw" && -e "$raw" ]]; then
            win_err "The image is still raw (unfinalized) — run: powos windows finalize"
        else
            win_err "No Windows image found ($canon)."
        fi
        return 1
    fi
    win_guard_image_free "$canon" || return 1
    echo "$canon"
}

win_snapshot() {
    win_step "Snapshot the Windows image (zstd copy)"
    if [[ ${WIN_DRY_RUN:-0} -eq 0 ]]; then
        win_require_root "snapshot" || return 1
    fi

    local img
    img=$(win_snapshot_preflight) || return 1

    local sdir
    sdir=$(win_snapshot_dir) || {
        win_err "POWOS-DATA is not mounted — snapshots live on it"
        win_err "(<POWOS-DATA>/windows/snapshots; invisible to Windows by design)."
        return 1
    }
    local name="${1:-$(date +%Y%m%d-%H%M%S)}"
    local out="$sdir/${name}.$(win_image_ext).zst"
    if [[ ${WIN_DRY_RUN:-0} -eq 0 && -e "$out" ]]; then
        win_err "Snapshot already exists: $out (pick another name)"
        return 1
    fi

    echo "  Source:      $img"
    echo "  Destination: $out"
    echo "  (whole-file compress — minutes, not instant; differencing-VHDX"
    echo "   snapshots are future work)"
    echo
    win_run_step "create snapshot directory" mkdir -p "$sdir" || return 1
    win_run_step "snapshot image → ${name}.$(win_image_ext).zst" \
        zstd -q -f "$img" -o "$out" || {
        win_err "Snapshot failed."
        return 1
    }
    win_ok "Snapshot '${name}' done."
    return 0
}

win_snapshots() {
    win_step "Windows snapshots"
    local sdir
    sdir=$(win_snapshot_dir 2>/dev/null || true)
    if [[ -z "$sdir" || ! -d "$sdir" ]]; then
        echo "  (none — POWOS-DATA unmounted or no snapshots taken yet)"
        echo "  Take one with:  sudo powos windows snapshot [name]"
        return 0
    fi
    local found=0 f
    for f in "$sdir"/*.zst; do
        [[ -e "$f" ]] || continue
        found=1
        ls -lh "$f" 2>/dev/null | while read -r l; do echo "  $l"; done
    done
    if [[ $found -eq 0 ]]; then
        echo "  (none yet in $sdir)"
        echo "  Take one with:  sudo powos windows snapshot [name]"
    else
        echo
        echo "  Restore with:  sudo powos windows rollback <name>"
    fi
    return 0
}

win_rollback() {
    win_step "Roll back the Windows image to a snapshot (OVERWRITES it)"
    local name="${1:-}"
    if [[ -z "$name" ]]; then
        win_err "Usage:  powos windows rollback <name>"
        win_snapshots
        return 1
    fi
    if [[ ${WIN_DRY_RUN:-0} -eq 0 ]]; then
        win_require_root "rollback" || return 1
    fi

    local img
    img=$(win_snapshot_preflight) || return 1

    local sdir snap
    sdir=$(win_snapshot_dir) || {
        win_err "POWOS-DATA is not mounted — cannot reach the snapshots."
        return 1
    }
    snap="$sdir/${name}.$(win_image_ext).zst"
    if [[ ! -f "$snap" ]]; then
        if [[ ${WIN_DRY_RUN:-0} -eq 1 ]]; then
            win_warn "dry-run: snapshot file not found ($snap) — showing the plan anyway."
        else
            win_err "Snapshot not found: $snap"
            win_snapshots
            return 1
        fi
    fi

    echo
    echo -e "  ${WIN_RED}${WIN_BOLD}THIS OVERWRITES the Windows image ($img)${WIN_NC}"
    echo -e "  ${WIN_RED}with snapshot '${name}'. Everything newer than it is LOST.${WIN_NC}"
    echo
    win_confirm "Type the snapshot name to confirm the rollback:" "$name" || {
        win_log "Confirmation failed — aborting. Nothing was changed."
        return 1
    }

    # Decompress-replace. No process may hold the image (guarded above), and
    # a live metal session is impossible while PowOS runs on this machine.
    win_run_step "restore ${name} → image" \
        zstd -d -q -f "$snap" -o "$img" || {
        win_err "Restore FAILED — the image may be in a partial state."
        win_err "Do NOT boot Windows; retry the rollback or restore another snapshot."
        return 1
    }
    win_ok "Rolled back to '${name}'."
    return 0
}

# ══════════════════════════════════════════════════════════════════
#  vm — the SAME image as a KVM guest (no reboot)
# ══════════════════════════════════════════════════════════════════
win_vm() {
    win_step "Boot the Windows image as a KVM guest"

    local games
    games=$(win_games_mount) || {
        win_err "POWOS-GAMES is not mounted — mount it first:  powos games mount"
        return 1
    }
    local dir="$games/$WIN_IMAGE_SUBDIR"
    local raw="$dir/windows.raw" canon="$dir/windows.$(win_image_ext)"
    if [[ ! -e "$canon" ]]; then
        if [[ -e "$raw" ]]; then
            win_err "The image is still raw — finish the install first:"
            win_err "  powos windows finalize"
        else
            win_err "No Windows image found — set it up first:  powos windows create"
        fi
        return 1
    fi
    win_guard_image_free "$canon" || return 1
    # A live METAL session cannot be detected from here — and does not need
    # to be: PowOS running on this machine means metal Windows is not, and
    # the image lives on this USB, so no other machine can be booting it.

    # VM-hibernated image resumed in the VM = SAME virtual hardware = the
    # correct, supported resume path. Never refused here (only metal boots
    # discard it — see win_switch).
    local hstate
    hstate=$(win_image_hibernated "$canon")
    case "$hstate" in
        present) win_log "VM-hibernated session found — the VM will resume it (correct hardware match)." ;;
        absent)  win_log "No hibernated session — Windows cold-boots in the VM." ;;
        *)       win_log "Hibernation state unknown — a VM boot resumes or cold-boots safely either way." ;;
    esac

    # OVMF + per-VM writable NVRAM (separate from the install VM's).
    local ovmf_code src_vars ovmf_vars
    ovmf_code=$(win_find_first_existing "${WIN_OVMF_CODE_CANDIDATES[@]}") || {
        if [[ ${WIN_DRY_RUN:-0} -eq 1 ]]; then ovmf_code="<OVMF_CODE.fd>"; else
            win_err "OVMF UEFI firmware not found. Install edk2-ovmf."; return 1; fi
    }
    src_vars=$(win_find_first_existing "${WIN_OVMF_VARS_CANDIDATES[@]}") || {
        if [[ ${WIN_DRY_RUN:-0} -eq 1 ]]; then src_vars="<OVMF_VARS.fd>"; else
            win_err "OVMF_VARS template not found (edk2-ovmf)."; return 1; fi
    }
    ovmf_vars="${WIN_RUNDIR}/vm_VARS.fd"

    # qemu's vhdx driver is the least battle-tested piece here (see the
    # header rationale); if it misbehaves, recreate the image with
    # --fixed-vhd (qemu's 'vpc' driver is rock solid).
    local qemu_cmd
    qemu_cmd=$(win_build_qemu_cmd "$canon" "$(win_qemu_fmt)" "" "" \
                                  "$WIN_RAM" "$WIN_CPUS" "$ovmf_code" "$ovmf_vars" "")

    win_step "Plan"
    echo "  Image:    $canon ($(win_qemu_fmt), read-write)"
    echo "  VM:       ${WIN_RAM} RAM, ${WIN_CPUS} vCPUs, OVMF, AHCI (same stack as metal)"
    echo "  The VM boots the image's INTERNAL boot files — the real ESP is not"
    echo "  attached (it is only ever needed at install time)."
    echo
    echo -e "  ${WIN_DIM}${qemu_cmd}${WIN_NC}"
    echo

    if [[ ${WIN_DRY_RUN:-0} -eq 1 ]]; then
        win_warn "--dry-run: not launching."
        return 0
    fi

    win_require_root "vm" || return 1
    command -v qemu-system-x86_64 &>/dev/null || {
        win_err "qemu not installed (dnf install qemu-kvm edk2-ovmf)."; return 1
    }
    win_confirm "Launch the Windows VM now?" || {
        win_log "Aborted."
        return 1
    }
    mkdir -p "$WIN_RUNDIR"
    [[ -f "$ovmf_vars" ]] || cp "$src_vars" "$ovmf_vars" || return 1

    win_ok "Launching Windows VM…"
    eval "$qemu_cmd"
    return $?
}

# ══════════════════════════════════════════════════════════════════
#  fetch-iso — download + verify the OFFICIAL Microsoft Windows 11 ISO
# ══════════════════════════════════════════════════════════════════
#
# Trust model (encoded, non-negotiable): official MS ISO + verify. We NEVER
# fetch a prebuilt / third-party image (unverifiable + redistribution) and we
# NEVER fetch-and-run foreign executable code. At most we fetch DATA. The
# download itself is a mockable seam (win_fetch_official_iso, mido-backed).

# Print a small hint to prefer --fixed-vhd when the install is small (tiny11-
# style). Native VHD boot prefers a FIXED VHD; a dynamic VHDX balloons toward
# its full --size on the first metal boot (docs/PROBLEM.md). No-op if already
# --fixed-vhd. Shared by fetch/slim/install output.
win_fixed_vhd_hint() {
    [[ ${WIN_FIXED_VHD:-0} -eq 1 ]] && return 0
    win_warn "This looks like a SMALL (tiny11-style) install."
    win_log  "Consider --fixed-vhd: native VHD boot prefers a FIXED VHD (a dynamic"
    win_log  "VHDX expands toward its full --size on the first metal boot; a small"
    win_log  "install makes a fixed VHD practical up front — docs/PROBLEM.md)."
    return 0
}

win_fetch_iso() {
    win_step "Fetch the official Windows 11 ISO (EXPERIMENTAL — TODO(hw))"
    win_log "TRUST MODEL: this downloads the OFFICIAL Microsoft ISO (via mido, which"
    win_log "drives Microsoft's own download API) and VERIFIES it. PowOS never"
    win_log "downloads a prebuilt or third-party Windows image."

    # Destination: --dest wins; else <POWOS-DATA>/windows/iso/ (persistent,
    # letterless/invisible to Windows).
    local dest="$WIN_DEST"
    if [[ -z "$dest" ]]; then
        local idir
        idir=$(win_iso_dir) || {
            win_err "POWOS-DATA is not mounted and no --dest given."
            win_err "Mount POWOS-DATA, or pass:  powos windows fetch-iso --dest /path/Win11.iso"
            return 1
        }
        dest="$idir/Win11.iso"
    fi

    # Record the eventual product path up front so `install --fetch` can consume
    # it even under --dry-run (slim output when slimming).
    if [[ ${WIN_SLIM:-0} -eq 1 ]]; then
        WIN_FETCHED_ISO=$(win_slim_default_out "$dest")
    else
        WIN_FETCHED_ISO="$dest"
    fi

    win_step "Plan"
    echo "  Source:      official Microsoft download API (mido / Fido approach)"
    echo "  Destination: $dest"
    [[ -n "$WIN_HASH" ]] && echo "  Verify:      SHA-256 == $WIN_HASH (abort on mismatch)" \
                         || echo "  Verify:      print computed SHA-256 (verify vs Microsoft yourself)"
    [[ ${WIN_SLIM:-0} -eq 1 ]] && echo "  Then:        --slim → $WIN_FETCHED_ISO"
    echo

    if [[ ${WIN_DRY_RUN:-0} -eq 1 ]]; then
        win_warn "dry-run: stopping before the download. Nothing was changed."
        return 0
    fi

    win_require_root "fetch-iso" || return 1
    win_confirm "Download the official Windows 11 ISO now?" || {
        win_log "Aborted. Nothing was changed."
        return 1
    }

    win_run_step "create ISO directory" mkdir -p "$(dirname "$dest")" || return 1
    win_fetch_official_iso "$dest" || {
        win_err "Download failed."
        return 1
    }

    # ── Sanity: exists, non-trivial size (>3GB), looks like an ISO ──
    if [[ ! -e "$dest" ]]; then
        win_err "Expected ISO not found after download: $dest"
        return 1
    fi
    local sz; sz=$(win_file_size_bytes "$dest")
    if [[ -z "$sz" || "$sz" -lt 3221225472 ]]; then
        win_err "Downloaded file is implausibly small (${sz:-0} bytes; expected >3GB)."
        win_err "Treating it as a failed/partial download — refusing it."
        return 1
    fi
    local ft; ft=$(win_iso_fstype "$dest")
    case "$ft" in
        iso9660|udf) win_ok "Looks like an ISO (fs signature: $ft)." ;;
        "")          win_warn "Could not probe the ISO filesystem signature (blkid unavailable)." ;;
        *)           win_err "File does not look like an ISO (signature: $ft) — refusing it."
                     return 1 ;;
    esac

    # ── Integrity: hash verification is the gate before anything downstream ──
    local computed; computed=$(win_sha256 "$dest")
    if [[ -n "$WIN_HASH" ]]; then
        local want="${WIN_HASH,,}" got="${computed,,}"
        if [[ "$want" != "$got" ]]; then
            win_err "SHA-256 MISMATCH — refusing this download (NOT proceeding to slim/install)."
            win_err "  expected: $want"
            win_err "  computed: $got"
            win_err "Delete $dest and retry, or double-check the --hash you supplied."
            return 1
        fi
        win_ok "SHA-256 verified: $got"
    else
        win_warn "No --hash supplied. Computed SHA-256 of the download:"
        echo    "    $computed"
        win_warn "VERIFY this against Microsoft's published hash before trusting the ISO."
        win_warn "(Microsoft publishes ISO hashes on the software-download page and in"
        win_warn " the Volume Licensing / eval portals — compare, don't assume.)"
    fi

    win_ok "ISO ready: $dest"

    # ── Optional: chain into the slim pass (only after a verified download) ──
    if [[ ${WIN_SLIM:-0} -eq 1 ]]; then
        # Honor --out when given (the help advertises it generically); else the
        # default <dest>-slim.iso.
        local out; out="${WIN_OUT:-$(win_slim_default_out "$dest")}"
        win_slim_iso "$dest" "$out" || return 1
        WIN_FETCHED_ISO="$out"
        win_fixed_vhd_hint
    fi

    echo
    echo -e "  Next:  ${WIN_BOLD}sudo powos windows create${WIN_NC}  then"
    echo -e "         ${WIN_BOLD}sudo powos windows install --iso $WIN_FETCHED_ISO${WIN_NC}"
    return 0
}

# ══════════════════════════════════════════════════════════════════
#  slim — tiny11-STYLE debloat, done NATIVELY on Linux with wimlib
# ══════════════════════════════════════════════════════════════════
#
# NO Windows, NO DISM, NO running tiny11builder. We operate on the ISO's
# sources/install.wim with wimlib and repack a bootable UEFI ISO with xorriso.
# The removal list (win_slim_package_list) mirrors ntdevlabs/tiny11builder's
# curation — reviewed and pinned by us, NEVER downloaded-and-executed.
#
# EXPERIMENTAL / TODO(hw): the slim path MUST be validated by actually
# installing the slimmed image and RUNNING an anti-cheat title (EAC/BattlEye)
# before it is trusted — a strip that breaks anti-cheat defeats the whole
# reason bare-metal Windows exists (docs/PROBLEM.md).
#
# ── Slim tool seams: each wraps ONE external tool through win_run_step, so
#    --dry-run skips them all AND tier-1 tests replace the binary with a stub. ─
win_iso_extract() {   # $1 = src iso, $2 = dest dir (xorriso osirrox)
    win_run_step "extract ISO contents ($1 → $2)" \
        xorriso -osirrox on -indev "$1" -extract / "$2"
}
win_iso_build() {     # $1 = src tree, $2 = out iso (bootable UEFI, xorriso)
    win_run_step "repack bootable UEFI ISO ($2)" \
        xorriso -as mkisofs -iso-level 3 -R -J \
            -e efi/microsoft/boot/efisys.bin -no-emul-boot \
            -o "$2" "$1"
}
win_wim_mount() {     # $1 = install.wim, $2 = mountpoint (image 1, read-write)
    win_run_step "mount install.wim read-write" \
        wimlib-imagex mountrw "$1" 1 "$2"
}
win_wim_unmount() {   # $1 = mountpoint (commit changes back into the wim)
    win_run_step "commit + unmount install.wim" \
        wimlib-imagex unmount "$1" --commit
}
win_wim_rebuild() {   # $1 = install.wim (recompress, drop freed space)
    win_run_step "rebuild install.wim (recompress, reclaim freed space)" \
        wimlib-imagex optimize "$1"
}
# PURE: the LabConfig install-bypass .reg (Windows-registry export syntax). The
# SAME TPM/SecureBoot/RAM/CPU bypass INTENT as the autounattend's RunSynchronous
# LabConfig block — noted so the overlap is obvious: the autounattend gates the
# QEMU VM install; this gates a bare-metal Setup run launched from slimmed media.
win_slim_bypass_reg() {
    cat <<'REGEOF'
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\SYSTEM\Setup\LabConfig]
"BypassTPMCheck"=dword:00000001
"BypassSecureBootCheck"=dword:00000001
"BypassRAMCheck"=dword:00000001
"BypassCPUCheck"=dword:00000001
REGEOF
}

win_wim_inject_bypass() {   # $1 = mounted wim root (offline registry edit)
    # hivexregedit edits the offline SYSTEM hive without booting Windows. Piped
    # inline (not via win_run_step) so the .reg reaches its stdin AND the tool
    # stays directly test-mockable; honors --dry-run like win_backup_esp.
    local root="${1:?}"
    echo -e "  ${WIN_DIM}\$ hivexregedit --merge --prefix HKLM\\SYSTEM ${root}/Windows/System32/config/SYSTEM${WIN_NC}"
    if [[ ${WIN_DRY_RUN:-0} -eq 1 ]]; then
        win_warn "dry-run: skipped (LabConfig bypass registry)"
        return 0
    fi
    win_slim_bypass_reg | hivexregedit --merge --prefix 'HKEY_LOCAL_MACHINE\SYSTEM' \
        "$root/Windows/System32/config/SYSTEM"
}

win_slim_iso() {
    local src="${1:?win_slim_iso: source ISO required}"
    local out="${2:?win_slim_iso: output ISO required}"

    win_step "Slim the Windows ISO (tiny11-style, wimlib — EXPERIMENTAL, TODO(hw))"

    # LOUD anti-cheat warning — printed every run (even --dry-run).
    win_warn "╔══════════════════════════════════════════════════════════════════╗"
    win_warn "║  ANTI-CHEAT SAFETY: bare-metal Windows exists ONLY to run kernel  ║"
    win_warn "║  anti-cheat games (EAC / BattlEye — docs/PROBLEM.md). This slim   ║"
    win_warn "║  pass KEEPS Windows Update / the servicing stack, .NET, the VC    ║"
    win_warn "║  runtime and the security stack. Do NOT extend the removal list   ║"
    win_warn "║  with anything anti-cheat needs — a strip that breaks EAC/BattlE- ║"
    win_warn "║  ye defeats the entire purpose. VALIDATE by actually installing + ║"
    win_warn "║  running an anti-cheat title before trusting a slimmed image.     ║"
    win_warn "╚══════════════════════════════════════════════════════════════════╝"

    if [[ ${WIN_DRY_RUN:-0} -eq 0 && ! -f "$src" ]]; then
        win_err "Source ISO not found: $src"
        return 1
    fi

    win_step "Plan"
    echo "  Source:   $src"
    echo "  Output:   $out"
    echo "  Method:   xorriso extract → wimlib mount install.wim → remove appx +"
    echo "            Edge/OneDrive setup → inject bypass registry → rebuild wim →"
    echo "            xorriso repack (bootable UEFI). No Windows, no DISM."
    echo "  Removing $(win_slim_package_list | grep -c .) provisioned packages (see win_slim_package_list)."
    echo

    if [[ ${WIN_DRY_RUN:-0} -eq 1 ]]; then
        win_warn "dry-run: stopping before extraction. Nothing was changed."
        return 0
    fi

    local t
    for t in xorriso wimlib-imagex; do
        command -v "$t" &>/dev/null || { win_err "Required tool missing: $t"; return 1; }
    done
    win_confirm "Build the slimmed ISO now?" || { win_log "Aborted."; return 1; }

    local work mnt
    work=$(mktemp -d) || return 1
    mnt=$(mktemp -d) || { rmdir "$work" 2>/dev/null; return 1; }
    local wim="$work/sources/install.wim"

    # 1. Extract the ISO tree.
    win_iso_extract "$src" "$work" || { win_err "ISO extraction failed."; return 1; }
    # 2. Mount install.wim read-write.
    win_wim_mount "$wim" "$mnt" || { win_err "wimlib mount failed."; return 1; }
    # 3. Remove the curated provisioned appx packages.
    local pkg
    while IFS= read -r pkg; do
        [[ -z "$pkg" ]] && continue
        win_run_step "remove provisioned appx: $pkg" \
            rm -rf "$mnt/Program Files/WindowsApps/${pkg}"* \
                   "$mnt/Windows/SystemApps/${pkg}"*
    done < <(win_slim_package_list)
    # 4. Remove Edge + OneDrive setup (not appx — setup binaries).
    win_run_step "remove Microsoft Edge setup" \
        rm -rf "$mnt/Program Files (x86)/Microsoft/Edge"* \
               "$mnt/Windows/System32/MicrosoftEdge"*
    win_run_step "remove OneDrive setup" \
        rm -f "$mnt/Windows/System32/OneDriveSetup.exe" \
              "$mnt/Windows/SysWOW64/OneDriveSetup.exe"
    # 5. Inject the install bypass registry (LabConfig parity).
    win_wim_inject_bypass "$mnt" || win_warn "Bypass registry injection reported an error."
    # 6. Commit + unmount, then rebuild (recompress) the wim.
    win_wim_unmount "$mnt" || { win_err "wimlib commit/unmount failed."; return 1; }
    win_wim_rebuild "$wim" || win_warn "install.wim rebuild reported an error (non-fatal)."
    # 7. Repack a bootable UEFI ISO.
    win_iso_build "$work" "$out" || { win_err "ISO repack failed."; return 1; }

    rm -rf "$work" 2>/dev/null; rmdir "$mnt" 2>/dev/null || true
    win_ok "Slimmed ISO written: $out"
    win_fixed_vhd_hint
    return 0
}

# CLI wrapper: powos windows slim <src.iso> [--out PATH]
win_slim_cmd() {
    local src="${1:-}"
    if [[ -z "$src" ]]; then
        win_err "Usage:  powos windows slim <src.iso> [--out PATH]"
        return 1
    fi
    if [[ ${WIN_DRY_RUN:-0} -eq 0 && ! -f "$src" ]]; then
        win_err "ISO not found: $src"
        return 1
    fi
    if [[ ${WIN_DRY_RUN:-0} -eq 0 ]]; then
        win_require_root "slim" || return 1
    fi
    local out="${WIN_OUT:-$(win_slim_default_out "$src")}"
    win_slim_iso "$src" "$out"
}

# ══════════════════════════════════════════════════════════════════
#  status
# ══════════════════════════════════════════════════════════════════
win_status() {
    win_step "Windows on PowOS — status (virtual-disk file design)"

    local games dir raw canon
    games=$(win_games_mount 2>/dev/null || true)
    echo
    if [[ -z "$games" ]]; then
        echo -e "  POWOS-GAMES : ${WIN_YELLOW}not mounted${WIN_NC} — the image lives on it"
        echo "                (mount it:  powos games mount)"
        echo
        echo -e "  Next step   : mount POWOS-GAMES, then ${WIN_BOLD}powos windows status${WIN_NC}"
        return 0
    fi
    echo "  POWOS-GAMES : mounted at $games"
    dir="$games/$WIN_IMAGE_SUBDIR"
    raw="$dir/windows.raw"; canon="$dir/windows.$(win_image_ext)"

    local have_canon=0 have_raw=0
    [[ -e "$canon" ]] && have_canon=1
    [[ -e "$raw" ]] && have_raw=1
    if [[ $have_canon -eq 1 ]]; then
        echo -e "  Image       : ${WIN_GREEN}present${WIN_NC}  $canon"
        local used=""
        used=$(du -h "$canon" 2>/dev/null | while read -r a _; do echo "$a"; break; done)
        [[ -n "$used" ]] && echo "                used on disk: $used (thin file — grows with use)"
        if win_image_in_use "$canon"; then
            echo -e "                ${WIN_YELLOW}OPEN by a process (VM running?)${WIN_NC}"
        fi
        local hstate; hstate=$(win_image_hibernated "$canon")
        case "$hstate" in
            present) echo "  Hibernated  : yes, INSIDE the image (resume with: powos windows vm;"
                     echo "                a metal boot discards that session)" ;;
            absent)  echo "  Hibernated  : no" ;;
            *)       echo -e "  Hibernated  : unknown ${WIN_DIM}(root + qemu-nbd needed to probe;${WIN_NC}"
                     echo -e "                ${WIN_DIM}metal boots always cold-boot regardless)${WIN_NC}" ;;
        esac
    elif [[ $have_raw -eq 1 ]]; then
        echo -e "  Image       : ${WIN_YELLOW}raw install image${WIN_NC}  $raw"
        echo "                (conversion pending: powos windows finalize)"
    else
        echo -e "  Image       : ${WIN_YELLOW}none${WIN_NC}"
    fi

    # Firmware entry (efibootmgr scan; absent on non-UEFI / test machines).
    local entry_id="" efi_out=""
    if command -v efibootmgr &>/dev/null && [[ -d /sys/firmware/efi ]]; then
        efi_out=$(efibootmgr 2>/dev/null || true)
        entry_id=$(win_find_boot_entry "windows|microsoft" "$efi_out" || true)
        if [[ -n "$entry_id" ]]; then
            echo -e "  Boot entry  : ${WIN_GREEN}Boot${entry_id}${WIN_NC} ($(win_boot_entry_label "$entry_id" "$efi_out" || echo Windows))"
        else
            echo -e "  Boot entry  : ${WIN_YELLOW}none${WIN_NC} (efibootmgr found no Windows entry)"
        fi
    else
        echo -e "  Boot entry  : unknown ${WIN_DIM}(no UEFI/efibootmgr here)${WIN_NC}"
    fi

    # Snapshots
    local sdir count=0 f
    sdir=$(win_snapshot_dir 2>/dev/null || true)
    if [[ -n "$sdir" && -d "$sdir" ]]; then
        for f in "$sdir"/*.zst; do [[ -e "$f" ]] && count=$((count+1)); done
        echo "  Snapshots   : $count ($sdir)"
    else
        echo "  Snapshots   : 0 (POWOS-DATA unmounted or none taken)"
    fi

    # What comes next?
    echo
    if [[ $have_canon -eq 0 && $have_raw -eq 0 ]]; then
        echo -e "  Next step   : ${WIN_BOLD}sudo powos windows create${WIN_NC}"
        echo -e "                need an ISO?  ${WIN_BOLD}sudo powos windows fetch-iso [--slim]${WIN_NC}"
    elif [[ $have_canon -eq 0 ]]; then
        echo -e "  Next step   : ${WIN_BOLD}sudo powos windows install --iso <path>${WIN_NC}"
        echo -e "                (or ${WIN_BOLD}--fetch${WIN_NC} to download the official ISO first)"
        echo -e "                then  ${WIN_BOLD}sudo powos windows finalize${WIN_NC}"
    elif [[ -z "$entry_id" ]]; then
        echo -e "  Next step   : ${WIN_BOLD}sudo powos windows finalize${WIN_NC}  (firmware entry missing)"
    else
        echo -e "  Ready       : metal (cold boot):  ${WIN_BOLD}sudo powos windows${WIN_NC}"
        echo -e "                same instance, VM:  ${WIN_BOLD}sudo powos windows vm${WIN_NC}"
    fi
    return 0
}

# ── Usage / dispatch ──────────────────────────────────────────────
win_usage() {
    cat << EOF
powos windows — bare-metal Windows from a virtual-disk FILE (docs/WINDOWS.md)

Windows lives in <POWOS-GAMES>/PowOS-Windows/windows.vhdx and metal-boots
via Windows native VHD boot. No real partitions are ever created for it.
Metal boots always COLD-BOOT (hibernation is a VM-mode-only feature).

Usage: powos windows [<command>] [options]

Commands:
  (none)              THE SWITCH: guards → layer-sync flush → unmount games
                      → BootNext → hibernate PowOS; Windows cold-boots
  status              Image, hibernation state, boot entry, snapshots
  fetch-iso           Download + verify the OFFICIAL Microsoft Win11 ISO
                      (--dest, --hash, --slim). Never a third-party image
  slim <src.iso>      tiny11-style debloat via wimlib (--out). EXPERIMENTAL:
                      keeps the anti-cheat/servicing stack; VALIDATE first
  create              Create the thin image file (no partitioning at all)
  install --iso PATH  Run YOUR Windows ISO's Setup in QEMU into the file;
                      the REAL PowOS ESP rides along (2nd disk, backed up
                      first) for the native-boot files. ZERO-TOUCH default.
                      Steam is PREINSTALLED and the shared POWOS-GAMES library
                      seeded (--no-games to skip). Use --fetch [--slim] to
                      download the official ISO in the same step
  finalize            Convert raw → VHDX (thin, native-bootable), verify the
                      ESP boot files, create the host firmware entry
  snapshot [name]     zstd copy of the image → POWOS-DATA/windows/snapshots
  snapshots           List snapshots
  rollback <name>     Decompress-replace the image (typed confirmation)
  vm                  Boot the SAME image as a KVM guest (VM-hibernation OK)

Options:
  --dry-run           Show every action, change NOTHING
  --yes               Skip y/N confirmations (typed gates still refuse)
  --config PATH       read defaults from PATH (default: /etc/powos/windows.conf;
                      WINDOWS_* keys; flags below always override the file)
  --backend MODE      'vhd' (default: image file on POWOS-GAMES — one blast
                      radius, retrofits any USB) or 'partition' (dedicated
                      WIN-ESP + POWOS-WIN — native speed + real hibernation,
                      needs a burn-time --windows-gb tail)
  --iso PATH          install: the user-supplied Windows ISO (required)
  --fetch             install: download the official ISO first, then install
  --dest PATH         fetch-iso: where to save the ISO (default: on POWOS-DATA)
  --hash SHA256       fetch-iso: expected SHA-256; ABORT on mismatch
  --slim              fetch-iso/install: tiny11-style debloat the ISO first
  --out PATH          slim: output ISO path (default: <src>-slim.iso)
  --games-letter L    install: stable Windows letter for POWOS-GAMES (default: G)
  --steam-autostart   install: add Steam to the Windows Run key (console-like)
  --no-games          install: skip the Steam preinstall + shared-library seeding
  --size N            create: image MAX size in GB (default: 256; thin file)
  --fixed-vhd         use a fixed-subformat VHD instead of dynamic VHDX
                      (escape hatch, or a small/slim install; native VHD boot
                      prefers fixed)
  --ram SIZE          VM RAM (default: 8G)
  --cpus N            VM vCPUs (default: 4)
  --interactive       install: no autounattend.xml — click through Setup
  --username NAME     install: local admin account (default: powos)
  --password PW       install: account password (default: powos — CHANGE IT)
  --locale LL-CC      install: Windows locale (default: en-US)
  --keyboard LL-CC    install: keyboard/input locale (default: en-US)
  --edition NAME      install: image name for keyless installs
                      (default: "Windows 11 Pro")
  --product-key KEY   install: embed a product key (default: keyless)
  --with-steam        install: best-effort silent Steam install at first logon
  --reboot            switch: if hibernate fails, plain-reboot into Windows
  -h, --help          This help

EXPERIMENTAL — TODO(hw): none of the hardware paths are validated yet.
PowOS ships no Microsoft bits: you supply the ISO and the license.
EOF
}

# Apply declarative defaults from $WIN_CONFIG (if present & readable) onto the
# WIN_* knobs. Only the documented WINDOWS_* keys are honored; they're declared
# local here so a sourced file cannot leak names into the caller's scope. Blank
# or absent keys fall through to whatever the caller already set (the built-in
# default at call time), so this sits strictly between default and CLI flag.
win_load_config() {
    local cfg="$WIN_CONFIG"
    [[ -r "$cfg" ]] || return 0
    local WINDOWS_ISO="" WINDOWS_EDITION="" WINDOWS_SIZE_GB="" \
          WINDOWS_FIXED_VHD="" WINDOWS_USERNAME="" WINDOWS_PASSWORD="" \
          WINDOWS_LOCALE="" WINDOWS_KEYBOARD="" WINDOWS_PRODUCT_KEY="" \
          WINDOWS_WITH_STEAM="" WINDOWS_RAM="" WINDOWS_CPUS="" WINDOWS_BACKEND=""
    # shellcheck disable=SC1090
    if ! source "$cfg" 2>/dev/null; then
        win_warn "Could not parse $cfg — ignoring it (using defaults/flags)."
        return 0
    fi
    [[ -n "$WINDOWS_ISO"         ]] && WIN_ISO="$WINDOWS_ISO"
    [[ -n "$WINDOWS_EDITION"     ]] && WIN_EDITION="$WINDOWS_EDITION"
    [[ -n "$WINDOWS_SIZE_GB"     ]] && WIN_SIZE_GB="$WINDOWS_SIZE_GB"
    [[ -n "$WINDOWS_FIXED_VHD"   ]] && WIN_FIXED_VHD="$WINDOWS_FIXED_VHD"
    [[ -n "$WINDOWS_USERNAME"    ]] && WIN_USERNAME="$WINDOWS_USERNAME"
    [[ -n "$WINDOWS_PASSWORD"    ]] && WIN_PASSWORD="$WINDOWS_PASSWORD"
    [[ -n "$WINDOWS_LOCALE"      ]] && WIN_LOCALE="$WINDOWS_LOCALE"
    [[ -n "$WINDOWS_KEYBOARD"    ]] && WIN_KEYBOARD="$WINDOWS_KEYBOARD"
    [[ -n "$WINDOWS_PRODUCT_KEY" ]] && WIN_PRODUCT_KEY="$WINDOWS_PRODUCT_KEY"
    [[ -n "$WINDOWS_WITH_STEAM"  ]] && WIN_WITH_STEAM="$WINDOWS_WITH_STEAM"
    [[ -n "$WINDOWS_RAM"         ]] && WIN_RAM="$WINDOWS_RAM"
    [[ -n "$WINDOWS_CPUS"        ]] && WIN_CPUS="$WINDOWS_CPUS"
    [[ -n "$WINDOWS_BACKEND"     ]] && WIN_BACKEND="$WINDOWS_BACKEND"
    WIN_CONFIG_LOADED="$cfg"
}

# ══════════════════════════════════════════════════════════════════
# PARTITION BACKEND  (WINDOWS_BACKEND=partition)
# ──────────────────────────────────────────────────────────────────
# Windows lives in a DEDICATED WIN-ESP + POWOS-WIN pair carved from the
# burn-time unallocated tail (build/install-to-usb.sh --windows-gb). Windows
# sees plain metal → native disk speed and REAL hibernation (seamless resume
# across switches), while the GPT type-GUID exposure contract keeps every
# PowOS/Linux partition invisible to it (type 8300 = no drive letter). Its own
# WIN-ESP means Windows Update never touches PowOS's loader.
#
# Trade vs the 'vhd' backend: needs unallocated space (no retrofit of a full
# USB without repartitioning), and switching is one file → not a single blast
# radius. Snapshots use ntfsclone (used-blocks) instead of a whole-file copy.
#
# WARNING: the functions below are REAL and DESTRUCTIVE — win_part_create runs
# `parted mkpart` / `mkfs.vfat` / `mkfs.ntfs` / `sgdisk` against a real disk.
# They are gated by win_run_step (dry-run) + confirmation like the installer,
# but they are NOT no-op stubs. EXPERIMENTAL / TODO(hw): validate on a VM /
# spare disk before trusting the partition backend.
# ══════════════════════════════════════════════════════════════════
# ── Partition-backend constants ───────────────────────────────────
WIN_ESP_LABEL="WIN-ESP"          # dedicated Windows ESP (FAT32, GPT type EF00)
WIN_WIN_LABEL="POWOS-WIN"        # Windows C: (NTFS, GPT type 0700)
WIN_ESP_SIZE_MIB=512             # WIN-ESP size
WIN_MIN_WIN_MIB=8192             # refuse to carve POWOS-WIN smaller than this

# ── Partition-backend discovery (mirrors lib/games.sh, kept local) ─
# The PowOS-owned disk: the disk holding POWOS-DATA (ramboot/live), else the
# disk backing the running root (installed). Returns 1 if undeterminable.
win_part_disk() {
    local part pk src base
    part=$(blkid -L POWOS-DATA 2>/dev/null || true)
    if [[ -n "$part" ]]; then
        pk=$(lsblk -no PKNAME "$part" 2>/dev/null | head -1)
        [[ -n "$pk" ]] && { echo "/dev/$pk"; return 0; }
    fi
    src=$(findmnt -n -o SOURCE / 2>/dev/null || true)
    if [[ "$src" == /dev/* ]]; then
        base=$(lsblk -no PKNAME "$src" 2>/dev/null | head -1)
        [[ -n "$base" ]] && { echo "/dev/$base"; return 0; }
    fi
    return 1
}

win_esp_part() { blkid -L "$WIN_ESP_LABEL" 2>/dev/null; }   # WIN-ESP device or empty
win_win_part() { blkid -L "$WIN_WIN_LABEL" 2>/dev/null; }   # POWOS-WIN device or empty

win_dev_size() { lsblk -dn -o SIZE "${1:?}" 2>/dev/null | head -1 | tr -d '[:space:]'; }

# Is POWOS-WIN currently mounted? rc 0 = mounted.
win_win_mounted() { findmnt -n -S "${1:?}" &>/dev/null; }

# Largest free block on $1: prints "START END SIZE" (MiB, suffix stripped).
# START/END may be fractional — hand them back to parted verbatim. (Mirror of
# gms_free_block / isv_free_block.)
win_part_free_block() {
    local disk="${1:?}"
    parted "$disk" unit MiB print free 2>/dev/null | awk '
        /Free Space/ {
            s=$1; e=$2; sz=$3
            gsub("MiB","",s); gsub("MiB","",e); gsub("MiB","",sz)
            if (sz+0 > max) { max=sz+0; start=s; end=e }
        }
        END { if (max > 0) printf "%s %s %d\n", start, end, max }'
}

# Re-read the partition table + ensure device nodes exist. (Mirror gms_settle.)
win_part_settle() {
    local dev="$1"
    partprobe "$dev" 2>/dev/null || true
    command -v udevadm &>/dev/null && udevadm settle 2>/dev/null || true
    partx -a "$dev" 2>/dev/null || true
    partx -u "$dev" 2>/dev/null || true
    sleep 1
}

# Resolve a partition on $1 by GPT partlabel $2 (blkid, robust vs. enumeration
# order). (Mirror gms_part_by_partlabel.)
win_part_by_partlabel() {
    local dev="$1" want="$2" part
    while read -r part; do
        win_is_block "$part" || continue
        [[ "$(blkid -o value -s PARTLABEL "$part" 2>/dev/null)" == "$want" ]] || continue
        echo "$part"; return 0
    done < <(lsblk -ln -o PATH "$dev" 2>/dev/null | tail -n +2)
    return 1
}

win_last_partition() { lsblk -ln -o PATH "${1:?}" 2>/dev/null | tail -1; }

# Safety gate before formatting a fallback-selected partition (GPT numbering
# gaps mean "last row" can be a PRE-EXISTING partition). (Mirror
# gms_verify_new_partition.)
win_verify_new_partition() {
    local part="$1" expect_mib="${2:-}" sig size_b size_mib diff
    sig=$(blkid -o value -s TYPE "$part" 2>/dev/null || true)
    if [[ -n "$sig" ]]; then
        win_err "SAFETY ABORT: fallback-selected $part already holds a filesystem"
        win_err "($sig) — it is NOT the partition just created. Nothing was formatted."
        return 1
    fi
    if [[ -n "$expect_mib" ]]; then
        size_b=$(lsblk -bnd -o SIZE "$part" 2>/dev/null | head -1 | tr -d '[:space:]')
        if [[ "$size_b" =~ ^[0-9]+$ ]]; then
            size_mib=$(( size_b / 1048576 ))
            diff=$(( size_mib - expect_mib )); (( diff < 0 )) && diff=$(( -diff ))
            if (( diff > 64 )); then
                win_err "SAFETY ABORT: $part is ${size_mib}MiB but should be ~${expect_mib}MiB."
                return 1
            fi
        fi
    fi
    return 0
}

# Set a GPT type code on a partition via sgdisk (best-effort — preserves the
# exposure contract: EF00 WIN-ESP + 0700 POWOS-WIN are Windows-visible; every
# other PowOS partition keeps type 8300 and stays letterless/invisible, and we
# NEVER touch those). $1 disk, $2 part, $3 code, $4 human description.
win_set_part_type() {
    local disk="$1" part="$2" code="$3" desc="$4" pnum
    pnum=$(win_part_number "$part")
    if [[ -z "$pnum" ]]; then
        win_warn "Could not derive partition number of $part — GPT type left as-is."
        return 0
    fi
    if command -v sgdisk &>/dev/null; then
        win_run_step "set GPT type ${code} (${desc})" \
            sgdisk -t "${pnum}:${code}" "$disk" || \
            win_warn "sgdisk failed — fix later: sgdisk -t ${pnum}:${code} $disk"
    else
        win_warn "sgdisk not installed — set the GPT type later so the exposure"
        win_warn "contract holds:  sgdisk -t ${pnum}:${code} $disk"
    fi
}

# hiberfil.sys state on POWOS-WIN: present|absent|unknown. Root-gated ro probe
# (mirror of win_image_hibernated, but a real partition). A present hiberfile
# means the volume is FROZEN (Windows hibernation / Fast Startup) — the one
# safety rule: never write it, never resume it under different hardware.
win_win_hibernated() {
    local part="${1:?}"
    if [[ ${WIN_DRY_RUN:-0} -eq 1 || ${EUID:-$(id -u)} -ne 0 ]]; then
        echo "unknown"; return 0
    fi
    local mp state="unknown"
    mp=$(mktemp -d)
    if mount -o ro "$part" "$mp" 2>/dev/null; then
        [[ -e "$mp/hiberfil.sys" ]] && state="present" || state="absent"
        umount "$mp" 2>/dev/null || true
    fi
    rmdir "$mp" 2>/dev/null || true
    echo "$state"
}

# ── ntfsclone snapshot pipelines (inline so tar/zstd/ntfsclone stay mockable) ─
# Save: used-blocks image of POWOS-WIN, zstd-compressed, onto POWOS-DATA.
win_ntfsclone_save() {
    local dev="$1" out="$2"
    echo -e "  ${WIN_DIM}\$ ntfsclone --save-image --output - $dev | zstd -q -f -o $out${WIN_NC}"
    if [[ ${WIN_DRY_RUN:-0} -eq 1 ]]; then
        win_warn "dry-run: skipped (ntfsclone snapshot)"; return 0
    fi
    if ! ntfsclone --save-image --output - "$dev" | zstd -q -f -o "$out"; then
        win_err "ntfsclone/zstd snapshot FAILED (is POWOS-WIN clean and unmounted?)."
        return 1
    fi
    [[ -s "$out" ]] || { win_err "Snapshot file is empty: $out"; return 1; }
    return 0
}
# Restore: decompress the used-blocks image straight back onto POWOS-WIN.
win_ntfsclone_restore() {
    local snap="$1" dev="$2"
    echo -e "  ${WIN_DIM}\$ zstd -dc $snap | ntfsclone --restore-image --overwrite $dev -${WIN_NC}"
    if [[ ${WIN_DRY_RUN:-0} -eq 1 ]]; then
        win_warn "dry-run: skipped (ntfsclone restore)"; return 0
    fi
    if ! zstd -dc "$snap" | ntfsclone --restore-image --overwrite "$dev" -; then
        win_err "Restore FAILED — POWOS-WIN may be in a partial state."
        win_err "Do NOT boot Windows; retry the rollback or restore another snapshot."
        return 1
    fi
    return 0
}

# ══════════════════════════════════════════════════════════════════
#  partition: create — carve WIN-ESP + POWOS-WIN from the unallocated tail
# ══════════════════════════════════════════════════════════════════
win_part_create() {
    win_step "Create the Windows partitions — WIN-ESP + POWOS-WIN (EXPERIMENTAL — TODO(hw))"

    if [[ ${WIN_DRY_RUN:-0} -eq 0 ]]; then
        win_require_root "create" || return 1
    fi

    # Exactly one of each in the world (resolved by label everywhere).
    local existing
    existing=$(win_win_part || true)
    if [[ -n "$existing" ]]; then
        win_err "A $WIN_WIN_LABEL partition already exists: $existing"
        win_err "Boot it:  powos windows  (metal)  /  powos windows vm"
        win_err "To reinstall: snapshot it, delete both partitions, then create again."
        return 1
    fi
    existing=$(win_esp_part || true)
    if [[ -n "$existing" ]]; then
        win_err "A $WIN_ESP_LABEL partition already exists ($existing) but no POWOS-WIN."
        win_err "Finish the install:  powos windows install --iso <path>"
        return 1
    fi

    local disk
    disk=$(win_part_disk) || {
        win_err "Could not determine the PowOS-owned disk (no POWOS-DATA, root is an overlay)."
        return 1
    }
    if ! win_is_block "$disk" \
       || [[ "$(lsblk -dn -o TYPE "$disk" 2>/dev/null | head -1 | tr -d '[:space:]')" != "disk" ]]; then
        win_err "$disk is not a whole-disk block device."
        return 1
    fi

    local t missing=()
    for t in parted sgdisk mkfs.vfat mkfs.ntfs; do
        command -v "$t" &>/dev/null || missing+=("$t")
    done
    if [[ ${WIN_DRY_RUN:-0} -eq 0 && ${#missing[@]} -gt 0 ]]; then
        win_err "Missing required tools: ${missing[*]}  (mkfs.ntfs ships in ntfsprogs/ntfs-3g)."
        return 1
    fi

    # The unallocated TAIL reserved at burn time (install-to-usb.sh --windows-gb).
    local fb_start fb_end fb_size
    read -r fb_start fb_end fb_size <<< "$(win_part_free_block "$disk")"
    if [[ -z "$fb_start" || -z "$fb_end" ]]; then
        win_err "No unallocated free space on $disk for the Windows partitions."
        win_err "The 'partition' backend carves WIN-ESP + POWOS-WIN from a reserved tail."
        win_err "Re-burn the USB reserving one:"
        win_err "    install-to-usb.sh --windows-gb N"
        win_err "(or use the default 'vhd' backend, which needs no tail)."
        return 1
    fi
    local need_mib=$(( WIN_ESP_SIZE_MIB + WIN_MIN_WIN_MIB ))
    if (( fb_size < need_mib )); then
        win_err "Free block is only ${fb_size}MiB — need >= ${need_mib}MiB for WIN-ESP"
        win_err "(512MiB) plus a usable POWOS-WIN. Re-burn with a bigger --windows-gb."
        return 1
    fi

    # WIN-ESP first (512MiB from the block start), POWOS-WIN the rest to the end.
    # LC_ALL=C: parted needs a period decimal separator, never a comma.
    local esp_start="$fb_start" esp_end win_start win_end win_size_mib
    esp_end=$(LC_ALL=C awk -v s="$fb_start" -v z="$WIN_ESP_SIZE_MIB" 'BEGIN{printf "%.2f", s + z}')
    win_start="$esp_end"; win_end="$fb_end"
    win_size_mib=$(LC_ALL=C awk -v s="$win_start" -v e="$win_end" 'BEGIN{printf "%d", e - s}')

    win_step "Plan"
    echo "  Disk:       $disk"
    echo "  Free tail:  ${fb_start} -> ${fb_end} MiB (${fb_size} MiB)"
    echo "  WIN-ESP:    ${esp_start} -> ${esp_end} MiB (512MiB, FAT32, GPT type EF00, label $WIN_ESP_LABEL)"
    echo "  POWOS-WIN:  ${win_start} -> ${win_end} MiB (${win_size_mib} MiB, NTFS, GPT type 0700, label $WIN_WIN_LABEL)"
    echo "  Exposure:   EF00 + 0700 are Windows-visible BY DESIGN. Every PowOS/Linux"
    echo "              partition keeps its type (8300 = letterless, invisible) — this"
    echo "              command only creates in free space and NEVER touches them."
    echo
    echo -e "  ${WIN_DIM}Current layout:${WIN_NC}"
    lsblk -o NAME,SIZE,FSTYPE,LABEL "$disk" 2>/dev/null | awk '{print "    " $0}'
    echo

    win_confirm "Carve WIN-ESP + POWOS-WIN on $disk?" || {
        win_log "Aborted. Nothing was changed."
        return 1
    }

    # Dry-run: print the exact command sequence, change NOTHING (resolving live
    # devices here would point at existing partitions — mirror games/create).
    if [[ ${WIN_DRY_RUN:-0} -eq 1 ]]; then
        win_run_step "create WIN-ESP (${esp_start}MiB -> ${esp_end}MiB)" \
            parted -s "$disk" mkpart "$WIN_ESP_LABEL" fat32 "${esp_start}MiB" "${esp_end}MiB"
        win_run_step "format FAT32 (label $WIN_ESP_LABEL)" \
            mkfs.vfat -F 32 -n "$WIN_ESP_LABEL" "<new WIN-ESP>"
        win_run_step "set GPT type EF00 (EFI System — visible to Windows)" \
            sgdisk -t "N:EF00" "$disk"
        win_run_step "create POWOS-WIN (${win_start}MiB -> ${win_end}MiB)" \
            parted -s "$disk" mkpart "$WIN_WIN_LABEL" ntfs "${win_start}MiB" "${win_end}MiB"
        win_run_step "format NTFS (label $WIN_WIN_LABEL)" \
            mkfs.ntfs -f -L "$WIN_WIN_LABEL" "<new POWOS-WIN>"
        win_run_step "set GPT type 0700 (Microsoft basic data — visible to Windows)" \
            sgdisk -t "N:0700" "$disk"
        win_warn "dry-run complete — nothing was changed."
        return 0
    fi

    # ── WIN-ESP ──
    win_run_step "create WIN-ESP (${esp_start}MiB -> ${esp_end}MiB)" \
        parted -s "$disk" mkpart "$WIN_ESP_LABEL" fat32 "${esp_start}MiB" "${esp_end}MiB" || {
        win_err "parted mkpart WIN-ESP failed — nothing was formatted."; return 1
    }
    win_part_settle "$disk"
    local esp_dev used_fb=0
    esp_dev=$(win_part_by_partlabel "$disk" "$WIN_ESP_LABEL")
    if [[ -z "$esp_dev" ]]; then esp_dev=$(win_last_partition "$disk"); used_fb=1; fi
    if [[ -z "$esp_dev" ]] || ! win_is_block "$esp_dev"; then
        win_err "WIN-ESP created but its device node was not found."; return 1
    fi
    (( used_fb == 1 )) && { win_verify_new_partition "$esp_dev" "$WIN_ESP_SIZE_MIB" || return 1; }
    win_run_step "format FAT32 (label $WIN_ESP_LABEL)" \
        mkfs.vfat -F 32 -n "$WIN_ESP_LABEL" "$esp_dev" || {
        win_err "mkfs.vfat failed — format $esp_dev manually."; return 1
    }
    win_set_part_type "$disk" "$esp_dev" EF00 "EFI System — visible to Windows"

    # ── POWOS-WIN ──
    win_run_step "create POWOS-WIN (${win_start}MiB -> ${win_end}MiB)" \
        parted -s "$disk" mkpart "$WIN_WIN_LABEL" ntfs "${win_start}MiB" "${win_end}MiB" || {
        win_err "parted mkpart POWOS-WIN failed. WIN-ESP was created; re-run once you"
        win_err "have made room, or delete WIN-ESP and start over."; return 1
    }
    win_part_settle "$disk"
    local win_dev used_fb2=0
    win_dev=$(win_part_by_partlabel "$disk" "$WIN_WIN_LABEL")
    if [[ -z "$win_dev" ]]; then win_dev=$(win_last_partition "$disk"); used_fb2=1; fi
    if [[ -z "$win_dev" ]] || ! win_is_block "$win_dev"; then
        win_err "POWOS-WIN created but its device node was not found."; return 1
    fi
    (( used_fb2 == 1 )) && { win_verify_new_partition "$win_dev" "$win_size_mib" || return 1; }
    win_run_step "format NTFS (label $WIN_WIN_LABEL)" \
        mkfs.ntfs -f -L "$WIN_WIN_LABEL" "$win_dev" || {
        win_err "mkfs.ntfs failed — format $win_dev manually."; return 1
    }
    win_set_part_type "$disk" "$win_dev" 0700 "Microsoft basic data — visible to Windows"

    win_step "Done"
    win_ok "WIN-ESP ($esp_dev) + POWOS-WIN ($win_dev) ready."
    echo "  Next — run Windows Setup (your own ISO) onto them:"
    echo
    echo -e "    ${WIN_BOLD}powos windows install --iso /path/to/Win11.iso${WIN_NC}"
    echo
}

# ══════════════════════════════════════════════════════════════════
#  partition: install — Windows Setup in QEMU onto the REAL partitions
# ══════════════════════════════════════════════════════════════════
# No shared-ESP backup is needed here (WIN-ESP is dedicated to Windows). MVP:
# the real POWOS-WIN + WIN-ESP are attached to QEMU directly as AHCI disks
# (identical stack VM<->metal). TODO(hw): the ideal is a dm-linear synthetic
# whole disk [fake GPT][WIN-ESP][POWOS-WIN] so Setup lays its own ESP/MSR/C:
# onto the real partitions through the mapping; the direct-attach path here is
# EXPERIMENTAL and unvalidated (the whole partition backend is TODO(hw)).
win_part_install() {
    win_step "Install Windows onto WIN-ESP + POWOS-WIN (EXPERIMENTAL — TODO(hw))"

    if [[ -z "$WIN_ISO" ]]; then
        win_err "A user-supplied Windows ISO is required:"
        win_err "  powos windows install --iso /path/to/Win11.iso"
        win_err "(PowOS ships no Microsoft bits — your ISO, your license.)"
        return 1
    fi
    if [[ ${WIN_DRY_RUN:-0} -eq 0 && ! -f "$WIN_ISO" ]]; then
        win_err "ISO not found: $WIN_ISO"; return 1
    fi

    local esp_dev win_dev
    esp_dev=$(win_esp_part || true)
    win_dev=$(win_win_part || true)
    if [[ -z "$esp_dev" || -z "$win_dev" ]]; then
        win_err "WIN-ESP and/or POWOS-WIN not found — create them first:"
        win_err "  powos windows create"
        return 1
    fi
    # Neither may be mounted or otherwise open (a host rw-mount racing guest
    # writes is the classic mounted-disk corruption).
    if win_win_mounted "$win_dev" || win_win_mounted "$esp_dev"; then
        win_err "WIN-ESP/POWOS-WIN is mounted — unmount before handing it to the VM."
        return 1
    fi
    win_guard_image_free "$win_dev" || return 1
    win_guard_image_free "$esp_dev" || return 1

    # OVMF firmware + a per-run writable NVRAM copy (same as the vhd backend).
    local ovmf_code src_vars ovmf_vars
    ovmf_code=$(win_find_first_existing "${WIN_OVMF_CODE_CANDIDATES[@]}") || {
        if [[ ${WIN_DRY_RUN:-0} -eq 1 ]]; then ovmf_code="<OVMF_CODE.fd>"; else
            win_err "OVMF UEFI firmware not found. Install edk2-ovmf."; return 1; fi
    }
    src_vars=$(win_find_first_existing "${WIN_OVMF_VARS_CANDIDATES[@]}") || {
        if [[ ${WIN_DRY_RUN:-0} -eq 1 ]]; then src_vars="<OVMF_VARS.fd>"; else
            win_err "OVMF_VARS template not found (edk2-ovmf)."; return 1; fi
    }
    ovmf_vars="${WIN_RUNDIR}/part_install_VARS.fd"

    win_step "Plan"
    echo "  ISO (user-supplied): $WIN_ISO"
    echo "  Disk 0 (POWOS-WIN):  $win_dev  (real NTFS partition — Windows C:)"
    echo "  Disk 1 (WIN-ESP):    $esp_dev  (real FAT32 partition — Windows boot files)"
    echo "  No shared-ESP backup needed: WIN-ESP is dedicated to Windows."
    echo "  VM:                  ${WIN_RAM} RAM, ${WIN_CPUS} vCPUs, OVMF, AHCI (same stack as metal)"
    if [[ ${WIN_INTERACTIVE:-0} -eq 1 ]]; then
        echo "  Unattend:            no (--interactive: click through Setup yourself)"
    else
        echo "  Unattend:            ZERO-TOUCH autounattend.xml (disk 2, 64MiB FAT)"
        echo "                       account '${WIN_USERNAME}', edition '${WIN_EDITION}'"
        if [[ "$WIN_PASSWORD" == "powos" ]]; then
            win_warn "DEFAULT PASSWORD 'powos' in use — change it after first logon or pass --password."
        fi
    fi
    win_warn "TODO(hw): direct partition attach is EXPERIMENTAL; native-boot"
    win_warn "self-registration onto WIN-ESP is finished by 'powos windows finalize'."
    echo

    if [[ ${WIN_DRY_RUN:-0} -eq 1 ]]; then
        # Show the exact QEMU shape, launch nothing.
        local qdry
        qdry=$(win_build_qemu_cmd "$win_dev" raw "$esp_dev" "$WIN_ISO" \
                                  "$WIN_RAM" "$WIN_CPUS" "$ovmf_code" "$ovmf_vars" \
                                  "<unattend.img>")
        echo -e "  ${WIN_DIM}${qdry}${WIN_NC}"
        win_warn "dry-run: not launching. Nothing was changed."
        return 0
    fi

    win_require_root "install" || return 1
    local t req_tools=(qemu-system-x86_64)
    [[ ${WIN_INTERACTIVE:-0} -eq 0 ]] && req_tools+=(mkfs.vfat truncate)
    for t in "${req_tools[@]}"; do
        command -v "$t" &>/dev/null || { win_err "Required tool missing: $t"; return 1; }
    done
    if ! win_is_block "$win_dev" || ! win_is_block "$esp_dev"; then
        win_err "WIN-ESP/POWOS-WIN are not both block devices."; return 1
    fi

    win_confirm "Boot Windows Setup against the real partitions?" || {
        win_log "Aborted. Nothing was changed."; return 1
    }
    mkdir -p "$WIN_RUNDIR" || return 1
    [[ -f "$ovmf_vars" ]] || cp "$src_vars" "$ovmf_vars" || return 1

    # Unattend volume (reuses the shared autounattend generator).
    local unattend_img="" ump_dir=""
    trap 'win_install_teardown' EXIT INT TERM
    if [[ ${WIN_INTERACTIVE:-0} -eq 0 ]]; then
        local xml vhdpath="\\${WIN_IMAGE_SUBDIR}\\windows.$(win_image_ext)"
        xml=$(win_build_autounattend "$WIN_USERNAME" "$WIN_PASSWORD" \
                "$WIN_LOCALE" "$WIN_KEYBOARD" "$WIN_PRODUCT_KEY" \
                "$WIN_EDITION" "$WIN_WITH_STEAM" "$vhdpath")
        unattend_img="${WIN_RUNDIR}/unattend.img"
        win_run_step "create unattend volume (64MiB, sparse)" \
            truncate -s 64M "$unattend_img" || { trap - EXIT INT TERM; win_install_teardown; return 1; }
        win_run_step "format unattend volume (FAT)" \
            mkfs.vfat "$unattend_img" >/dev/null || { trap - EXIT INT TERM; win_install_teardown; return 1; }
        ump_dir=$(mktemp -d) || { trap - EXIT INT TERM; win_install_teardown; return 1; }
        WIN_TD_UNATTEND_MNT="$ump_dir"
        win_run_step "mount unattend volume" \
            mount -o loop "$unattend_img" "$ump_dir" || { trap - EXIT INT TERM; win_install_teardown; return 1; }
        printf '%s\n' "$xml" > "$ump_dir/autounattend.xml" || {
            win_err "Could not write autounattend.xml."; trap - EXIT INT TERM; win_install_teardown; return 1; }
        win_run_step "unmount unattend volume" umount "$ump_dir" || { trap - EXIT INT TERM; win_install_teardown; return 1; }
        WIN_TD_UNATTEND_MNT=""; rmdir "$ump_dir" 2>/dev/null || true
    fi

    local qemu_cmd
    qemu_cmd=$(win_build_qemu_cmd "$win_dev" raw "$esp_dev" "$WIN_ISO" \
                                  "$WIN_RAM" "$WIN_CPUS" "$ovmf_code" "$ovmf_vars" "$unattend_img")
    win_ok "Launching Windows Setup onto the real partitions…"
    echo -e "  ${WIN_DIM}${qemu_cmd}${WIN_NC}"
    eval "$qemu_cmd"; local vmrc=$?
    trap - EXIT INT TERM
    win_install_teardown
    (( vmrc != 0 )) && win_warn "QEMU exited with status $vmrc."

    win_step "Next steps"
    echo "  If Setup finished (Windows reached the desktop in the VM):"
    echo -e "    ${WIN_BOLD}powos windows finalize${WIN_NC}"
    echo "  registers the WIN-ESP firmware boot entry and verifies the boot files."
    return 0
}

# ══════════════════════════════════════════════════════════════════
#  partition: finalize — WIN-ESP firmware entry + boot-file verification
# ══════════════════════════════════════════════════════════════════
win_part_finalize() {
    win_step "Finalize the Windows install (partition backend — TODO(hw))"

    if [[ ${WIN_DRY_RUN:-0} -eq 0 ]]; then
        win_require_root "finalize" || return 1
        win_require_efi || return 1
    fi

    local esp_dev win_dev
    esp_dev=$(win_esp_part || true)
    win_dev=$(win_win_part || true)
    if [[ -z "$esp_dev" || -z "$win_dev" ]]; then
        win_err "WIN-ESP and/or POWOS-WIN not found — run 'powos windows create' first."
        return 1
    fi

    # Verify WIN-ESP carries the native-boot files (BCD + bootmgfw.efi). Binary
    # BCD → presence is the testable proxy that Setup's bcdboot ran.
    if [[ ${WIN_DRY_RUN:-0} -eq 1 ]]; then
        win_warn "dry-run: skipping WIN-ESP boot-file verification."
    else
        local mp ok=0
        mp=$(mktemp -d)
        if mount -o ro "$esp_dev" "$mp" 2>/dev/null; then
            [[ -e "$mp/EFI/Microsoft/Boot/BCD" && -e "$mp/EFI/Microsoft/Boot/bootmgfw.efi" ]] && ok=1
            umount "$mp" 2>/dev/null || true
        fi
        rmdir "$mp" 2>/dev/null || true
        if (( ok == 1 )); then
            win_ok "WIN-ESP carries EFI/Microsoft/Boot (BCD + bootmgfw.efi)."
        else
            win_err "WIN-ESP is missing EFI/Microsoft/Boot/BCD or bootmgfw.efi."
            win_err "Setup did not finish laying boot files — re-run Setup, or run"
            win_err "bcdboot C:\\Windows /s <WIN-ESP> /f UEFI inside Windows."
            return 1
        fi
    fi

    # Host firmware entry pointing at WIN-ESP's bootmgfw (the VM couldn't create
    # it — it has its own NVRAM). Mirror of win_finalize.
    local disk pnum efi_out entry_id
    disk=$(win_parent_disk "$esp_dev" || true)
    pnum=$(win_part_number "$esp_dev" || true)
    if [[ -z "$disk" || -z "$pnum" ]]; then
        win_err "Could not derive disk/partition number from $esp_dev."; return 1
    fi
    efi_out=$(efibootmgr 2>/dev/null || true)
    entry_id=$(win_find_boot_entry "windows|microsoft" "$efi_out" || true)
    if [[ -n "$entry_id" ]]; then
        win_ok "Firmware entry already exists: Boot${entry_id} ($(win_boot_entry_label "$entry_id" "$efi_out" || echo Windows))"
    else
        win_run_step "create firmware boot entry (WIN-ESP: $disk part $pnum)" \
            efibootmgr -c -d "$disk" -p "$pnum" -L "Windows Boot Manager" \
                -l '\EFI\Microsoft\Boot\bootmgfw.efi' || {
            win_err "efibootmgr -c failed."; return 1
        }
    fi

    win_step "Done"
    win_ok "Windows (partition backend) is ready."
    echo -e "  Switch with:  ${WIN_BOLD}powos windows${WIN_NC}   (metal — Windows keeps its OWN hibernation)"
    echo -e "  Or run as a guest:  ${WIN_BOLD}powos windows vm${WIN_NC}"
}

# ══════════════════════════════════════════════════════════════════
#  partition: snapshots — ntfsclone (used-blocks) of POWOS-WIN → POWOS-DATA
# ══════════════════════════════════════════════════════════════════
# Shared pre-flight: POWOS-WIN exists, is not mounted, and is not frozen
# (hibernated/dirty). ntfsclone on a live or dirty volume corrupts. Echoes the
# device on success.
win_part_snapshot_preflight() {
    local win_dev
    win_dev=$(win_win_part || true)
    if [[ -z "$win_dev" ]]; then
        win_err "No POWOS-WIN partition found — nothing to snapshot."
        return 1
    fi
    if win_win_mounted "$win_dev"; then
        win_err "POWOS-WIN is MOUNTED — unmount it first (ntfsclone needs it quiescent)."
        return 1
    fi
    local hs; hs=$(win_win_hibernated "$win_dev")
    if [[ "$hs" == "present" ]]; then
        win_err "POWOS-WIN is HIBERNATED/dirty (hiberfil.sys present) — its filesystem"
        win_err "state is frozen. Boot Windows and fully shut it down first (Fast"
        win_err "Startup off), then snapshot."
        return 1
    fi
    [[ "$hs" == "unknown" ]] && win_warn "Could not confirm POWOS-WIN is clean (root needed) — ntfsclone will refuse a dirty volume."
    echo "$win_dev"
}

win_part_snapshot() {
    win_step "Snapshot POWOS-WIN (ntfsclone used-blocks image, zstd)"
    if [[ ${WIN_DRY_RUN:-0} -eq 0 ]]; then
        win_require_root "snapshot" || return 1
    fi

    local win_dev
    win_dev=$(win_part_snapshot_preflight) || return 1

    local sdir
    sdir=$(win_snapshot_dir) || {
        win_err "POWOS-DATA is not mounted — snapshots live on it"
        win_err "(<POWOS-DATA>/windows/snapshots; invisible to Windows by design)."
        return 1
    }
    local name="${1:-$(date +%Y%m%d-%H%M%S)}"
    local out="$sdir/${name}.ntfsclone.zst"
    if [[ ${WIN_DRY_RUN:-0} -eq 0 && -e "$out" ]]; then
        win_err "Snapshot already exists: $out (pick another name)"; return 1
    fi

    echo "  Source:      $win_dev (POWOS-WIN)"
    echo "  Destination: $out"
    echo "  (used-blocks clone — minutes, not instant; only allocated blocks are read)"
    echo
    win_run_step "create snapshot directory" mkdir -p "$sdir" || return 1
    win_ntfsclone_save "$win_dev" "$out" || return 1
    win_ok "Snapshot '${name}' done."
}

win_part_snapshots() {
    win_step "Windows snapshots (partition backend)"
    local sdir
    sdir=$(win_snapshot_dir 2>/dev/null || true)
    if [[ -z "$sdir" || ! -d "$sdir" ]]; then
        echo "  (none — POWOS-DATA unmounted or no snapshots taken yet)"
        echo "  Take one with:  sudo powos windows snapshot [name]"
        return 0
    fi
    local found=0 f
    for f in "$sdir"/*.ntfsclone.zst; do
        [[ -e "$f" ]] || continue
        found=1
        ls -lh "$f" 2>/dev/null | while read -r l; do echo "  $l"; done
    done
    if [[ $found -eq 0 ]]; then
        echo "  (none yet in $sdir)"
        echo "  Take one with:  sudo powos windows snapshot [name]"
    else
        echo
        echo "  Restore with:  sudo powos windows rollback <name>"
    fi
}

win_part_rollback() {
    win_step "Roll back POWOS-WIN to a snapshot (OVERWRITES it)"
    local name="${1:-}"
    if [[ -z "$name" ]]; then
        win_err "Usage:  powos windows rollback <name>"
        win_part_snapshots
        return 1
    fi
    if [[ ${WIN_DRY_RUN:-0} -eq 0 ]]; then
        win_require_root "rollback" || return 1
    fi

    local win_dev
    win_dev=$(win_part_snapshot_preflight) || return 1

    local sdir snap
    sdir=$(win_snapshot_dir) || {
        win_err "POWOS-DATA is not mounted — cannot reach the snapshots."; return 1
    }
    snap="$sdir/${name}.ntfsclone.zst"
    if [[ ! -f "$snap" ]]; then
        if [[ ${WIN_DRY_RUN:-0} -eq 1 ]]; then
            win_warn "dry-run: snapshot file not found ($snap) — showing the plan anyway."
        else
            win_err "Snapshot not found: $snap"; win_part_snapshots; return 1
        fi
    fi

    echo
    echo -e "  ${WIN_RED}${WIN_BOLD}THIS OVERWRITES POWOS-WIN ($win_dev)${WIN_NC}"
    echo -e "  ${WIN_RED}with snapshot '${name}'. Everything newer than it is LOST.${WIN_NC}"
    echo
    win_confirm "Type the snapshot name to confirm the rollback:" "$name" || {
        win_log "Confirmation failed — aborting. Nothing was changed."; return 1
    }
    win_ntfsclone_restore "$snap" "$win_dev" || return 1
    win_ok "Rolled back POWOS-WIN to '${name}'."
}

# ══════════════════════════════════════════════════════════════════
#  partition: vm — the SAME partitions as a KVM guest (no reboot)
# ══════════════════════════════════════════════════════════════════
# REFUSES a hibernated POWOS-WIN: resuming a hibernation image under the VM's
# different virtual hardware bluescreens/corrupts — this IS the frozen-volume
# rule for the partition backend. MVP attaches the real partitions directly;
# TODO(hw): a dm-linear synthetic disk [fake GPT][WIN-ESP][POWOS-WIN] is the
# ideal (Windows sees one disk, identical to metal).
win_part_vm() {
    win_step "Boot POWOS-WIN as a KVM guest (partition backend — TODO(hw))"

    local esp_dev win_dev
    esp_dev=$(win_esp_part || true)
    win_dev=$(win_win_part || true)
    if [[ -z "$esp_dev" || -z "$win_dev" ]]; then
        win_err "WIN-ESP and/or POWOS-WIN not found — set it up first:"
        win_err "  powos windows create && powos windows install --iso <path>"
        return 1
    fi
    if win_win_mounted "$win_dev" || win_win_mounted "$esp_dev"; then
        win_err "WIN-ESP/POWOS-WIN is mounted — unmount before booting the VM."
        return 1
    fi
    win_guard_image_free "$win_dev" || return 1
    win_guard_image_free "$esp_dev" || return 1

    # Frozen-volume rule: a hibernated Windows must NOT resume on VM hardware.
    local hs; hs=$(win_win_hibernated "$win_dev")
    case "$hs" in
        present)
            win_err "POWOS-WIN is HIBERNATED — refusing to start the VM."
            win_err "Resuming a metal-hibernated Windows on the VM's different virtual"
            win_err "hardware bluescreens or corrupts it. Boot it bare-metal instead:"
            win_err "  powos windows        (resumes its own session on real hardware)"
            return 1 ;;
        absent)  win_log "POWOS-WIN is not hibernated — safe to boot in the VM." ;;
        *)       win_warn "Could not confirm POWOS-WIN's hibernation state (root needed)."
                 win_warn "If Windows was hibernated on metal, do NOT resume it here." ;;
    esac

    local ovmf_code src_vars ovmf_vars
    ovmf_code=$(win_find_first_existing "${WIN_OVMF_CODE_CANDIDATES[@]}") || {
        if [[ ${WIN_DRY_RUN:-0} -eq 1 ]]; then ovmf_code="<OVMF_CODE.fd>"; else
            win_err "OVMF UEFI firmware not found. Install edk2-ovmf."; return 1; fi
    }
    src_vars=$(win_find_first_existing "${WIN_OVMF_VARS_CANDIDATES[@]}") || {
        if [[ ${WIN_DRY_RUN:-0} -eq 1 ]]; then src_vars="<OVMF_VARS.fd>"; else
            win_err "OVMF_VARS template not found (edk2-ovmf)."; return 1; fi
    }
    ovmf_vars="${WIN_RUNDIR}/part_vm_VARS.fd"

    # Disk 0 = POWOS-WIN (C:), disk 1 = WIN-ESP (its bootmgr, so OVMF boots it).
    local qemu_cmd
    qemu_cmd=$(win_build_qemu_cmd "$win_dev" raw "$esp_dev" "" \
                                  "$WIN_RAM" "$WIN_CPUS" "$ovmf_code" "$ovmf_vars" "")

    win_step "Plan"
    echo "  POWOS-WIN: $win_dev (raw, read-write)  — Windows C:"
    echo "  WIN-ESP:   $esp_dev (raw)  — bootmgr the guest firmware boots"
    echo "  VM:        ${WIN_RAM} RAM, ${WIN_CPUS} vCPUs, OVMF, AHCI (same stack as metal)"
    win_warn "TODO(hw): direct partition attach; a dm-linear synthetic disk is the ideal."
    echo
    echo -e "  ${WIN_DIM}${qemu_cmd}${WIN_NC}"
    echo

    if [[ ${WIN_DRY_RUN:-0} -eq 1 ]]; then
        win_warn "--dry-run: not launching."; return 0
    fi

    win_require_root "vm" || return 1
    command -v qemu-system-x86_64 &>/dev/null || {
        win_err "qemu not installed (dnf install qemu-kvm edk2-ovmf)."; return 1
    }
    win_confirm "Launch the Windows VM now?" || { win_log "Aborted."; return 1; }
    mkdir -p "$WIN_RUNDIR"
    [[ -f "$ovmf_vars" ]] || cp "$src_vars" "$ovmf_vars" || return 1
    win_ok "Launching Windows VM…"
    eval "$qemu_cmd"
    return $?
}

# ══════════════════════════════════════════════════════════════════
#  partition: the switch — powos windows: metal boot (SEAMLESS RESUME)
# ══════════════════════════════════════════════════════════════════
win_part_switch() {
    echo
    echo -e "${WIN_YELLOW}${WIN_BOLD}╔══════════════════════════════════════════════════════════════╗${WIN_NC}"
    echo -e "${WIN_YELLOW}${WIN_BOLD}║  EXPERIMENTAL: bare-metal OS switch (PowOS → Windows)        ║${WIN_NC}"
    echo -e "${WIN_YELLOW}${WIN_BOLD}║  partition backend — TODO(hw), not yet validated            ║${WIN_NC}"
    echo -e "${WIN_YELLOW}${WIN_BOLD}╚══════════════════════════════════════════════════════════════╝${WIN_NC}"
    echo

    if [[ ${WIN_DRY_RUN:-0} -eq 0 ]]; then
        win_require_root "" || return 1
    fi
    win_require_efi || return 1

    local esp_dev win_dev
    esp_dev=$(win_esp_part || true)
    win_dev=$(win_win_part || true)
    if [[ -z "$esp_dev" || -z "$win_dev" ]]; then
        win_err "No Windows partitions found — set it up first:  powos windows create"
        return 1
    fi
    win_guard_image_free "$win_dev" || return 1

    # Firmware entry must exist before we flush anything.
    local efi_out entry_id label
    efi_out=$(efibootmgr 2>/dev/null || true)
    entry_id=$(win_find_boot_entry "windows|microsoft" "$efi_out" || true)
    if [[ -z "$entry_id" ]]; then
        win_err "No Windows firmware boot entry found."
        win_err "Create it with:  powos windows finalize"
        return 1
    fi
    label=$(win_boot_entry_label "$entry_id" "$efi_out" || echo "Windows Boot Manager")
    win_log "Firmware entry: Boot${entry_id} (${label})"

    echo
    echo "  Plan: flush layer-sync → stop daemon → unmount shared NTFS →"
    echo "        BootNext Boot${entry_id} → sync → hibernate PowOS"
    echo "  Windows sees PLAIN METAL here, so its OWN hibernation works:"
    echo "  this is the SEAMLESS-RESUME path (unlike the vhd backend's cold boot)."
    echo
    win_confirm "Switch to Windows now?" || {
        win_log "Aborted. Nothing was changed."; return 1
    }

    # Flush + stop layer-sync — a failure here is a hard abort.
    win_guard_layer_sync || return 1

    # Unmount the shared games NTFS (POWOS-GAMES) if mounted: PowOS hibernates
    # with its mounts frozen, and Windows writes that shared volume. A frozen
    # rw-mount under another OS's writes = corruption (the one rule). POWOS-WIN
    # itself is Windows-owned and never mounted by PowOS across a switch.
    local games
    games=$(win_games_mount 2>/dev/null || true)
    if [[ -n "$games" ]]; then
        win_run_step "unmount shared NTFS ($games)" win_unmount_games "$games" || {
            win_err "Could not unmount $games (busy?) — refusing to switch."
            win_err "Close whatever uses it, or inspect:  fuser -vm '$games'"
            return 1
        }
    fi

    win_run_step "set one-shot BootNext (Boot${entry_id})" \
        efibootmgr --bootnext "$entry_id" || {
        win_err "Failed to set BootNext."; return 1
    }
    win_run_step "flush filesystem buffers" sync

    if win_run_step "hibernate PowOS (S4 — PowOS session preserved)" systemctl hibernate; then
        win_ok "Hibernate requested. Windows boots from its own partitions and, if it"
        win_ok "was hibernated, RESUMES its own session (seamless — the metal payoff)."
        return 0
    fi

    echo
    win_err "systemctl hibernate FAILED. Likely causes (docs/HIBERNATION.md):"
    win_err "  • no swap sized >= RAM (S4 writes the whole session there)"
    win_err "  • no resume= kernel argument pointing at that swap"
    win_err "  • kernel lockdown / secure boot restrictions"
    echo
    win_warn "Fallback: a PLAIN REBOOT into Windows loses the live PowOS session,"
    win_warn "but nothing else — layer-sync already flushed all changes to USB."
    if [[ ${WIN_REBOOT_FALLBACK:-0} -eq 1 ]]; then
        win_run_step "reboot into Windows (BootNext is set)" systemctl reboot
        return $?
    fi
    if [[ ${WIN_ASSUME_YES:-0} -eq 1 ]]; then
        win_log "Not rebooting automatically (--yes without --reboot)."
        win_log "Re-run with --reboot, or:  systemctl reboot   (BootNext is already set)"
        return 1
    fi
    local ans
    read -r -p "Plain reboot into Windows instead? [y/N] " ans
    if [[ "$ans" =~ ^[Yy]$ ]]; then
        win_run_step "reboot into Windows (BootNext is set)" systemctl reboot
        return $?
    fi
    win_log "Not rebooting. BootNext is set — the NEXT reboot lands in Windows;"
    win_log "clear it with:  efibootmgr --delete-bootnext"
    return 1
}

# ══════════════════════════════════════════════════════════════════
#  partition: status
# ══════════════════════════════════════════════════════════════════
win_part_status() {
    win_step "Windows on PowOS — status (dedicated-partition backend)"
    echo

    local disk
    disk=$(win_part_disk 2>/dev/null || true)
    if [[ -z "$disk" ]]; then
        echo -e "  PowOS disk  : ${WIN_YELLOW}not identified${WIN_NC} (no POWOS-DATA; root is an overlay)"
    else
        echo "  PowOS disk  : $disk"
    fi

    local esp_dev win_dev
    esp_dev=$(win_esp_part 2>/dev/null || true)
    win_dev=$(win_win_part 2>/dev/null || true)

    if [[ -n "$esp_dev" ]]; then
        echo -e "  WIN-ESP     : ${WIN_GREEN}present${WIN_NC}  $esp_dev ($(win_dev_size "$esp_dev"))"
    else
        echo -e "  WIN-ESP     : ${WIN_YELLOW}none${WIN_NC}"
    fi

    if [[ -n "$win_dev" ]]; then
        echo -e "  POWOS-WIN   : ${WIN_GREEN}present${WIN_NC}  $win_dev ($(win_dev_size "$win_dev"))"
        if win_win_mounted "$win_dev"; then
            echo -e "                ${WIN_YELLOW}MOUNTED${WIN_NC} at $(findmnt -n -o TARGET -S "$win_dev" | head -1)"
        fi
        local hs; hs=$(win_win_hibernated "$win_dev")
        case "$hs" in
            present) echo "  Hibernated  : yes — Windows has a saved session (metal boot RESUMES it;"
                     echo "                do NOT 'powos windows vm' or snapshot until it's shut down)" ;;
            absent)  echo "  Hibernated  : no" ;;
            *)       echo -e "  Hibernated  : unknown ${WIN_DIM}(root needed to probe POWOS-WIN)${WIN_NC}" ;;
        esac
    else
        echo -e "  POWOS-WIN   : ${WIN_YELLOW}none${WIN_NC}"
    fi

    # Firmware entry.
    local entry_id="" efi_out=""
    if command -v efibootmgr &>/dev/null && [[ -d /sys/firmware/efi ]]; then
        efi_out=$(efibootmgr 2>/dev/null || true)
        entry_id=$(win_find_boot_entry "windows|microsoft" "$efi_out" || true)
        if [[ -n "$entry_id" ]]; then
            echo -e "  Boot entry  : ${WIN_GREEN}Boot${entry_id}${WIN_NC} ($(win_boot_entry_label "$entry_id" "$efi_out" || echo Windows))"
        else
            echo -e "  Boot entry  : ${WIN_YELLOW}none${WIN_NC} (efibootmgr found no Windows entry)"
        fi
    else
        echo -e "  Boot entry  : unknown ${WIN_DIM}(no UEFI/efibootmgr here)${WIN_NC}"
    fi

    # Snapshots (ntfsclone images share the vhd snapshot dir on POWOS-DATA).
    local sdir count=0 f
    sdir=$(win_snapshot_dir 2>/dev/null || true)
    if [[ -n "$sdir" && -d "$sdir" ]]; then
        for f in "$sdir"/*.ntfsclone.zst; do [[ -e "$f" ]] && count=$((count+1)); done
        echo "  Snapshots   : $count ($sdir)"
    else
        echo "  Snapshots   : 0 (POWOS-DATA unmounted or none taken)"
    fi

    echo
    if [[ -z "$win_dev" && -z "$esp_dev" ]]; then
        echo -e "  Next step   : ${WIN_BOLD}sudo powos windows create${WIN_NC}"
        echo -e "                (needs a burn-time unallocated tail: install-to-usb.sh --windows-gb N)"
    elif [[ -z "$win_dev" ]]; then
        echo -e "  Next step   : ${WIN_BOLD}sudo powos windows install --iso <path>${WIN_NC}"
    elif [[ -z "$entry_id" ]]; then
        echo -e "  Next step   : ${WIN_BOLD}sudo powos windows finalize${WIN_NC}  (firmware entry missing)"
    else
        echo -e "  Ready       : metal (seamless resume):  ${WIN_BOLD}sudo powos windows${WIN_NC}"
        echo -e "                same instance, VM:        ${WIN_BOLD}sudo powos windows vm${WIN_NC}"
    fi
}

cmd_windows() {
    # Reset per-invocation state (the lib is sourced into a fresh CLI process,
    # but be defensive — tests call cmd_windows repeatedly).
    WIN_DRY_RUN=0; WIN_ASSUME_YES=0; WIN_ISO=""
    WIN_REBOOT_FALLBACK=0; WIN_RAM="8G"; WIN_CPUS="4"
    WIN_INTERACTIVE=0; WIN_USERNAME="powos"; WIN_PASSWORD="powos"
    WIN_LOCALE="en-US"; WIN_KEYBOARD="en-US"
    WIN_PRODUCT_KEY=""; WIN_EDITION="Windows 11 Pro"; WIN_WITH_STEAM=0
    WIN_SIZE_GB=256; WIN_FIXED_VHD=0; WIN_CONFIG_LOADED=""; WIN_BACKEND="vhd"
    WIN_DEST=""; WIN_HASH=""; WIN_SLIM=0; WIN_FETCH=0; WIN_OUT=""; WIN_FETCHED_ISO=""
    WIN_GAMES_LETTER="G"; WIN_STEAM_AUTOSTART=0; WIN_NO_GAMES=0

    # --config PATH may point at an alternate file; honor it before the load so
    # the file's values seed the knobs, then the main loop lets flags override.
    local _ci _cj
    for (( _ci=1; _ci<=$#; _ci++ )); do
        case "${!_ci}" in
            --config)   _cj=$((_ci+1)); WIN_CONFIG="${!_cj:-$WIN_CONFIG}" ;;
            --config=*) WIN_CONFIG="${!_ci#--config=}" ;;
        esac
    done
    win_load_config

    local args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)      WIN_DRY_RUN=1; shift ;;
            --yes|-y)       WIN_ASSUME_YES=1; shift ;;
            --config)       shift 2 ;;   # already applied by the pre-scan above
            --config=*)     shift ;;
            --iso)          WIN_ISO="${2:-}"; shift 2 ;;
            --fetch)        WIN_FETCH=1; shift ;;
            --dest)         WIN_DEST="${2:-}"; shift 2 ;;
            --hash)         WIN_HASH="${2:-}"; shift 2 ;;
            --slim)         WIN_SLIM=1; shift ;;
            --out)          WIN_OUT="${2:-}"; shift 2 ;;
            --games-letter) WIN_GAMES_LETTER="${2:-G}"; shift 2 ;;
            --steam-autostart) WIN_STEAM_AUTOSTART=1; shift ;;
            --no-games)     WIN_NO_GAMES=1; shift ;;
            --size)         WIN_SIZE_GB="${2:-256}"; shift 2 ;;
            --fixed-vhd)    WIN_FIXED_VHD=1; shift ;;
            --backend)      WIN_BACKEND="${2:-vhd}"; shift 2 ;;
            --ram)          WIN_RAM="${2:-8G}"; shift 2 ;;
            --cpus)         WIN_CPUS="${2:-4}"; shift 2 ;;
            --interactive)  WIN_INTERACTIVE=1; shift ;;
            --username)     WIN_USERNAME="${2:-powos}"; shift 2 ;;
            --password)     WIN_PASSWORD="${2:-powos}"; shift 2 ;;
            --locale)       WIN_LOCALE="${2:-en-US}"; shift 2 ;;
            --keyboard)     WIN_KEYBOARD="${2:-en-US}"; shift 2 ;;
            --edition)      WIN_EDITION="${2:-Windows 11 Pro}"; shift 2 ;;
            --product-key)  WIN_PRODUCT_KEY="${2:-}"; shift 2 ;;
            --with-steam)   WIN_WITH_STEAM=1; shift ;;
            --reboot)       WIN_REBOOT_FALLBACK=1; shift ;;
            -h|--help)      win_usage; return 0 ;;
            *)              args+=("$1"); shift ;;
        esac
    done

    if [[ "$WIN_BACKEND" != "vhd" && "$WIN_BACKEND" != "partition" ]]; then
        win_err "Unknown WINDOWS_BACKEND '$WIN_BACKEND' — use 'vhd' or 'partition'."
        return 1
    fi

    local sub="${args[0]:-}"

    # ISO acquisition (fetch-iso / slim) is about MEDIA, not the on-disk backend
    # — handle it the same regardless of --backend.
    case "$sub" in
        fetch-iso)  win_fetch_iso; return ;;
        slim)       win_slim_cmd "${args[1]:-}"; return ;;
    esac

    # The 'partition' backend has its own implementation of every subcommand
    # (dedicated WIN-ESP + POWOS-WIN instead of a file on POWOS-GAMES).
    if [[ "$WIN_BACKEND" == "partition" ]]; then
        case "$sub" in
            "")             win_part_switch ;;
            status)         win_part_status ;;
            create)         win_part_create ;;
            install)        win_part_install ;;
            finalize)       win_part_finalize ;;
            snapshot)       win_part_snapshot "${args[1]:-}" ;;
            snapshots|list) win_part_snapshots ;;
            rollback)       win_part_rollback "${args[1]:-}" ;;
            vm)             win_part_vm ;;
            help)           win_usage ;;
            *)              win_err "Unknown windows command: $sub"; win_usage; return 1 ;;
        esac
        return
    fi

    case "$sub" in
        "")             win_switch ;;
        status)         win_status ;;
        create)         win_create ;;
        install)        win_install ;;
        finalize)       win_finalize ;;
        snapshot)       win_snapshot "${args[1]:-}" ;;
        snapshots|list) win_snapshots ;;
        rollback)       win_rollback "${args[1]:-}" ;;
        vm)             win_vm ;;
        help)           win_usage ;;
        *)              win_err "Unknown windows command: $sub"; win_usage; return 1 ;;
    esac
}
