#!/bin/bash
# shellcheck disable=SC2016,SC2034
# (assertions are single-quoted on purpose — check() eval's them later; the
#  GMS_* globals are read inside those eval'd strings, not statically.)
# test-games.sh - Tier-1 unit tests for the shared games partition (lib/games.sh).
#
# Runs on any box (no root, no real disks — including Git Bash on Windows) by
# shadowing the external tools (parted/blkid/lsblk/mkfs.ntfs/sgdisk/systemctl)
# with bash functions, exactly like test-install-system.sh. Nothing here ever
# touches a block device, mount, or systemd unit. The only real filesystem use
# is plain dirs/symlinks inside a mktemp sandbox (steam-layout tests).
#
# Usage:  bash test/tier1/test-games.sh
#   Docker: docker exec powos bash /test/tier1/test-games.sh

set -uo pipefail

# Locate the lib relative to this test, or the installed path.
LIB="/usr/lib/powos/games.sh"
if [[ ! -f "$LIB" ]]; then
    LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" && pwd)/games.sh"
fi

PASS=0; FAIL=0
ok()   { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL - $1"; FAIL=$((FAIL+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 (expected: $2)"; fi; }

echo "== Sourcing games lib: $LIB =="
# shellcheck disable=SC1090
source "$LIB" || { echo "cannot source lib"; exit 1; }

# The lib is sourced into bin/powos — it must never flip shell options on us.
check "sourcing does not enable errexit" '[[ $- != *e* ]]'

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

reset_gms() { GMS_DRY_RUN=0; GMS_ASSUME_YES=0; GMS_SIZE_GB=""; GMS_WHOLE=0; GMS_DISK=""; }

# Symlink capability probe: on Git Bash (MSYS) native symlinks need Developer
# Mode; without them we skip only the strict link assertions.
case "$(uname -s 2>/dev/null)" in
    MSYS*|MINGW*|CYGWIN*) export MSYS=winsymlinks:nativestrict ;;
esac
mkdir -p "$TMP/probe-target"
SYMLINKS_OK=0
if ln -s "$TMP/probe-target" "$TMP/probe-link" 2>/dev/null && [[ -L "$TMP/probe-link" ]]; then
    SYMLINKS_OK=1
fi

# ── Free-block parsing (parted output) ────────────────────────────
echo "== Free-block parsing =="

parted() {
    # Emulate `parted <dev> unit MiB print free` with two free blocks.
    cat <<'PARTED'
Model: Fake Disk (scsi)
Disk /dev/sdz: 500000MiB
Number  Start      End        Size       Type     File system  Flags
        1.00MiB    2.00MiB    1.00MiB             Free Space
 1      2.00MiB    202.00MiB  200.00MiB  primary  fat32        boot, esp
 2      202.00MiB  120000MiB  119798MiB  primary  ntfs
        120000MiB  500000MiB  380000MiB           Free Space
PARTED
}
read -r fb_start fb_end fb_size <<< "$(gms_free_block /dev/sdz)"
check "largest free block start (120000)" '[[ "$fb_start" == "120000" ]]'
check "largest free block end (500000)"   '[[ "$fb_end" == "500000" ]]'
check "largest free block size (380000)"  '[[ "$fb_size" == "380000" ]]'
unset -f parted

# ── Bounding math ─────────────────────────────────────────────────
# The new partition must be bounded INSIDE the free block: end = start+size,
# never a disk-end-relative spec (100% / -NMiB) and never past the block end.
echo "== Bounding math (gms_part_bounds) =="

out=$(gms_part_bounds 120000 500000 102400)
check "start preserved, end = start+size"    '[[ "$out" == "120000.00 222400.00" ]]'
out=$(gms_part_bounds 1.02 500 100)
check "fractional free-block start handled"  '[[ "$out" == "1.02 101.02" ]]'
out=$(gms_part_bounds 100 1000 900)
check "exact fit ends at the block end"      '[[ "$out" == "100.00 1000.00" ]]'
out=$(gms_part_bounds 100 100000 200)
check "end bounded by size, not by disk end" '[[ "$out" == "100.00 300.00" ]]'
check "does not fit → refused"               '! gms_part_bounds 100 1000 901 >/dev/null'
check "zero size → refused"                  '! gms_part_bounds 100 1000 0 >/dev/null'

# ── create: refuse if POWOS-GAMES already exists ──────────────────
echo "== create: refuse if POWOS-GAMES already exists =="

parted()    { :; }
mkfs.ntfs() { :; }
lsblk()     { :; }
blkid() {
    case "$*" in
        *"-L POWOS-GAMES"*) echo "/dev/sdz9"; return 0 ;;
    esac
    return 1
}
reset_gms
out=$(cmd_games create --size 10 --disk /dev/sdz 2>&1); rc=$?
check "second POWOS-GAMES refused (rc != 0)" '[[ $rc -ne 0 ]]'
check "names the existing device"            'echo "$out" | grep -q "already exists: /dev/sdz9"'
unset -f parted mkfs.ntfs lsblk blkid

# ── create: refuse if the free block is too small ─────────────────
echo "== create: refuse if free block too small =="

parted() {
    cat <<'PARTED'
Disk /dev/sdz: 20000MiB
Number  Start     End       Size      Type     File system  Flags
 1      1.00MiB   10000MiB  9999MiB   primary  btrfs
        10000MiB  20000MiB  10000MiB           Free Space
PARTED
}
mkfs.ntfs()    { :; }
blkid()        { return 1; }   # no existing POWOS-GAMES
lsblk()        { case "$*" in *"-dn -o TYPE"*) echo "disk" ;; *) echo "" ;; esac; }
gms_is_block() { return 0; }

reset_gms
out=$(cmd_games create --size 20 --disk /dev/sdz 2>&1); rc=$?   # 20GB > 10000MiB free
check "too-small free block refused"       '[[ $rc -ne 0 ]]'
check "explains available vs needed"       'echo "$out" | grep -q "Not enough free space"'

parted() { echo "Disk /dev/sdz: 20000MiB"; }   # no free block at all
reset_gms
out=$(cmd_games create --size 20 --disk /dev/sdz 2>&1); rc=$?
check "no free block at all → refused"     '[[ $rc -ne 0 ]]'
unset -f parted mkfs.ntfs blkid lsblk gms_is_block

# ── create: --dry-run executes ZERO mutating calls ────────────────
echo "== create: dry-run executes zero mutating calls =="

MUT_CALLS=()
parted() {
    case "$*" in
        *"print free"*)   # read-only planning call — allowed
            cat <<'PARTED'
Disk /dev/sdz: 500000MiB
Number  Start      End        Size       Type     File system  Flags
 1      1.00MiB    100000MiB  99999MiB   primary  btrfs
        100000MiB  500000MiB  400000MiB           Free Space
PARTED
            ;;
        *) MUT_CALLS+=("parted $*") ;;   # mkpart etc. = mutation
    esac
}
mkfs.ntfs()    { MUT_CALLS+=("mkfs.ntfs $*"); }
sgdisk()       { MUT_CALLS+=("sgdisk $*"); }
partprobe()    { MUT_CALLS+=("partprobe $*"); }
udevadm()      { MUT_CALLS+=("udevadm $*"); }
partx()        { MUT_CALLS+=("partx $*"); }
blkid()        { return 1; }
lsblk()        { case "$*" in *"-dn -o TYPE"*) echo "disk" ;; *) echo "" ;; esac; }
gms_is_block() { return 0; }

reset_gms
cmd_games create --size 100 --disk /dev/sdz --dry-run > "$TMP/create-dry.out" 2>&1; rc=$?
check "dry-run create succeeds"              '[[ $rc -eq 0 ]]'
check "ZERO mutating tool invocations"       '[[ ${#MUT_CALLS[@]} -eq 0 ]]'
check "plan: mkpart bounded inside free block (100GB → 202400.00MiB)" \
    'grep -q "mkpart POWOS-GAMES ntfs 100000.00MiB 202400.00MiB" "$TMP/create-dry.out"'
check "plan: mkfs.ntfs with the label"       'grep -q "mkfs.ntfs -f -L POWOS-GAMES" "$TMP/create-dry.out"'
check "plan: GPT type 0700 (Windows-visible)" 'grep -q "0700" "$TMP/create-dry.out"'
check "no disk-end-relative specs (100% / -NMiB)" \
    '! grep "mkpart" "$TMP/create-dry.out" | grep -Eq "100%|-[0-9]+MiB"'
unset -f parted mkfs.ntfs sgdisk partprobe udevadm partx blkid lsblk gms_is_block

# ── create --whole: fill the free block ───────────────────────────
echo "== create --whole: fills the disk's free space =="

MUT_CALLS=()
parted() {
    case "$*" in
        *"print free"*)   # free block 100000 → 500000 (400000 MiB)
            cat <<'PARTED'
Disk /dev/sdz: 500000MiB
Number  Start      End        Size       Type     File system  Flags
 1      1.00MiB    100000MiB  99999MiB   primary  btrfs
        100000MiB  500000MiB  400000MiB           Free Space
PARTED
            ;;
        *) MUT_CALLS+=("parted $*") ;;
    esac
}
mkfs.ntfs()    { MUT_CALLS+=("mkfs.ntfs $*"); }
sgdisk()       { MUT_CALLS+=("sgdisk $*"); }
partprobe()    { MUT_CALLS+=("partprobe $*"); }
udevadm()      { MUT_CALLS+=("udevadm $*"); }
partx()        { MUT_CALLS+=("partx $*"); }
blkid()        { return 1; }
lsblk()        { case "$*" in *"-dn -o TYPE"*) echo "disk" ;; *) echo "" ;; esac; }
gms_is_block() { return 0; }

# --whole flag is parsed into GMS_WHOLE.
reset_gms
cmd_games create --whole --disk /dev/sdz --dry-run > "$TMP/whole-dry.out" 2>&1; rc=$?
check "--whole dry-run create succeeds"       '[[ $rc -eq 0 ]]'
check "--whole: ZERO mutating tool calls"     '[[ ${#MUT_CALLS[@]} -eq 0 ]]'
check "--whole: partition fills the free block (100000→500000)" \
    'grep -q "mkpart POWOS-GAMES ntfs 100000.00MiB 500000.00MiB" "$TMP/whole-dry.out"'
check "--whole: no disk-end-relative specs (100% / -NMiB)" \
    '! grep "mkpart" "$TMP/whole-dry.out" | grep -Eq "100%|-[0-9]+MiB"'

# --size and --whole are mutually exclusive.
reset_gms
out=$(cmd_games create --whole --size 100 --disk /dev/sdz --dry-run 2>&1); rc=$?
check "--size + --whole → refused"            '[[ $rc -ne 0 ]]'
check "explains mutual exclusion"             'echo "$out" | grep -qi "mutually exclusive"'

# Neither --size nor --whole → the classic required-size error.
reset_gms
out=$(cmd_games create --disk /dev/sdz --dry-run 2>&1); rc=$?
check "neither --size nor --whole → refused"  '[[ $rc -ne 0 ]]'
check "still names --size as required"        'echo "$out" | grep -q -- "--size"'

unset -f parted mkfs.ntfs sgdisk partprobe udevadm partx blkid lsblk gms_is_block

# ── Partition located by PARTLABEL, not lsblk order ───────────────
echo "== Partition located by partlabel, not lsblk order =="

lsblk() { [[ "$*" == *"-o PATH"* ]] && printf '/dev/sdz\n/dev/sdz1\n/dev/sdz5\n/dev/sdz2\n'; }
blkid() {
    # emulate `blkid -o value -s PARTLABEL <part>` (label lives on sdz5,
    # which is NOT the last row lsblk prints)
    case "${!#}" in
        /dev/sdz5) echo "POWOS-GAMES" ;;
        *)         echo "" ;;
    esac
}
gms_is_block() { return 0; }
check "finds POWOS-GAMES by partlabel"      '[[ "$(gms_part_by_partlabel /dev/sdz POWOS-GAMES)" == "/dev/sdz5" ]]'
check "lsblk order would have picked sdz2"  '[[ "$(gms_last_partition /dev/sdz)" == "/dev/sdz2" ]]'
check "missing label returns empty"         '[[ -z "$(gms_part_by_partlabel /dev/sdz NOPE)" ]]'
unset -f lsblk blkid gms_is_block

# ── Fallback format guard ─────────────────────────────────────────
# "Last partition" fallback must never format a pre-existing partition.
echo "== Fallback format guard =="

blkid() { echo "ntfs"; }   # existing filesystem signature
check "existing signature → refuse to format" '! gms_verify_new_partition /dev/sdz3 1000 2>/dev/null'

blkid() { echo ""; }
lsblk() { echo $(( 1000 * 1048576 )); }   # emulate `lsblk -bnd -o SIZE` (bytes)
check "clean signature + matching size → allowed" 'gms_verify_new_partition /dev/sdz3 1000 2>/dev/null'

lsblk() { echo $(( 5000 * 1048576 )); }
check "size far off → refuse"                '! gms_verify_new_partition /dev/sdz3 1000 2>/dev/null'
unset -f blkid lsblk

# ── Default disk resolution ───────────────────────────────────────
echo "== Default disk (PowOS-owned) resolution =="

findmnt() { echo "/dev/nvme0n1p3"; }              # installed system
lsblk()   { [[ "$*" == *PKNAME* ]] && echo "nvme0n1"; }
check "installed system → root disk"        '[[ "$(gms_default_disk)" == "/dev/nvme0n1" ]]'

findmnt() { echo "overlay"; }                     # ramboot/live system
blkid()   { case "$*" in *"-L POWOS-DATA"*) echo "/dev/sdb2" ;; *) return 1 ;; esac; }
lsblk()   { [[ "$*" == *PKNAME* ]] && echo "sdb"; }
check "ramboot/live → POWOS-DATA disk"      '[[ "$(gms_default_disk)" == "/dev/sdb" ]]'

findmnt() { echo "overlay"; }
blkid()   { return 1; }
lsblk()   { :; }
check "nothing resolvable → fails"          '! gms_default_disk >/dev/null'
unset -f findmnt blkid lsblk

# ── Mount unit generator (pure) ───────────────────────────────────
echo "== Mount unit generator =="

unit=$(gms_mount_unit_content)
check "Type=ntfs3 (kernel driver, not FUSE)" 'grep -q "^Type=ntfs3$" <<< "$unit"'
check "windows_names option present"         'grep -q "windows_names" <<< "$unit"'
check "Where=/var/mnt/games (bazzite /mnt)"  'grep -q "^Where=/var/mnt/games$" <<< "$unit"'
check "What= resolves by label"              'grep -q "^What=/dev/disk/by-label/POWOS-GAMES$" <<< "$unit"'
check "uid/gid mapped to the user"           'grep -q "uid=1000,gid=1000" <<< "$unit"'
check "auto-mounts on boot"                  'grep -q "WantedBy=local-fs.target" <<< "$unit"'

# ── mount: --dry-run executes zero mutating calls ─────────────────
echo "== mount: dry-run executes zero mutating calls =="

MUT_CALLS=()
systemctl() { MUT_CALLS+=("systemctl $*"); }
mkdir()     { MUT_CALLS+=("mkdir $*"); }
blkid()     { echo "/dev/sdz4"; }
reset_gms
cmd_games mount --dry-run > "$TMP/mount-dry.out" 2>&1; rc=$?
check "dry-run mount succeeds"               '[[ $rc -eq 0 ]]'
check "zero systemctl/mkdir invocations"     '[[ ${#MUT_CALLS[@]} -eq 0 ]]'
check "unit file write skipped"              'grep -q "dry-run: skipped" "$TMP/mount-dry.out"'
check "unit content shown in the plan"       'grep -q "Type=ntfs3" "$TMP/mount-dry.out"'
unset -f systemctl mkdir blkid

# ── libraryfolders.vdf editing (pure) ─────────────────────────────
echo "== libraryfolders.vdf pure editing =="

VDF_SAMPLE=$(cat <<'VDF'
"libraryfolders"
{
	"contentstatsid"		"-8985240316123456789"
	"0"
	{
		"path"		"/home/powos/.local/share/Steam"
		"label"		""
		"apps"
		{
			"228980"		"453243"
		}
	}
}
VDF
)
new=$(gms_vdf_add_library "$VDF_SAMPLE" "/var/mnt/games/SteamLibrary"); rc=$?
check "vdf edit succeeds"                    '[[ $rc -eq 0 ]]'
check "new library block gets next index (1)" 'grep -q "^	\"1\"$" <<< "$new"'
check "new path present"                     'grep -q "\"/var/mnt/games/SteamLibrary\"" <<< "$new"'
check "existing library entry preserved"     'grep -q "/home/powos/.local/share/Steam" <<< "$new"'
check "existing apps block preserved"        'grep -q "\"228980\"" <<< "$new"'
check "still exactly one top-level close"    '[[ $(grep -c "^}" <<< "$new") -eq 1 ]]'

again=$(gms_vdf_add_library "$new" "/var/mnt/games/SteamLibrary")
check "idempotent: path already present → unchanged" '[[ "$again" == "$new" ]]'

third=$(gms_vdf_add_library "$new" "/other/lib")
check "next index after 0,1 is 2"            'grep -q "^	\"2\"$" <<< "$third"'

check "malformed input → nonzero rc (never written)" \
    '! gms_vdf_add_library "not a vdf at all" "/x" >/dev/null'

# ── Steam library layout (tmpdir, real dirs/symlinks) ─────────────
echo "== Steam library layout (compatdata/shadercache on native FS) =="

mnt="$TMP/mnt"; native="$TMP/native"
if [[ $SYMLINKS_OK -eq 1 ]]; then
    gms_steam_layout "$mnt" "$native" 2>/dev/null; rc=$?
    check "layout succeeds"                  '[[ $rc -eq 0 ]]'
    check "SteamLibrary/steamapps created"   '[[ -d "$mnt/SteamLibrary/steamapps" ]]'
    check "native compatdata created"        '[[ -d "$native/compatdata" ]]'
    check "native shadercache created"       '[[ -d "$native/shadercache" ]]'
    check "compatdata is a symlink to native FS" \
        '[[ -L "$mnt/SteamLibrary/steamapps/compatdata" && "$(readlink "$mnt/SteamLibrary/steamapps/compatdata")" == "$native/compatdata" ]]'
    check "shadercache is a symlink to native FS" \
        '[[ -L "$mnt/SteamLibrary/steamapps/shadercache" && "$(readlink "$mnt/SteamLibrary/steamapps/shadercache")" == "$native/shadercache" ]]'
    gms_steam_layout "$mnt" "$native" 2>/dev/null
    check "layout is idempotent"             '[[ $? -eq 0 ]]'

    # An EMPTY real dir (Steam pre-created it) is replaced by the symlink.
    mnt2="$TMP/mnt2"; native2="$TMP/native2"
    command mkdir -p "$mnt2/SteamLibrary/steamapps/compatdata"
    gms_steam_layout "$mnt2" "$native2" 2>/dev/null
    check "empty real dir replaced with symlink" '[[ -L "$mnt2/SteamLibrary/steamapps/compatdata" ]]'
else
    echo "  skip - native symlinks unavailable here (Git Bash without Developer"
    echo "         Mode) — symlink-shape assertions skipped, refusal test still runs."
fi

# A NON-EMPTY real dir means someone's prefixes live there: must refuse
# (no symlink support needed to verify the refusal).
mnt3="$TMP/mnt3"; native3="$TMP/native3"
command mkdir -p "$mnt3/SteamLibrary/steamapps/compatdata"
touch "$mnt3/SteamLibrary/steamapps/compatdata/prefix-contents"
check "non-empty real compatdata → refuse (never orphan prefixes)" \
    '! gms_steam_layout "$mnt3" "$native3" 2>/dev/null'

# ── steam-setup guards ────────────────────────────────────────────
echo "== steam-setup guards =="

findmnt() { return 0; }            # pretend /var/mnt/games is mounted
gms_steam_running() { return 0; }  # pretend Steam is running
reset_gms
out=$(cmd_games steam-setup 2>&1); rc=$?
check "refuses while Steam runs"             '[[ $rc -ne 0 ]]'
check "says to close Steam first"            'echo "$out" | grep -qi "close Steam"'
unset -f findmnt
gms_steam_running() { pgrep -x steam &>/dev/null; }   # restore the real check

# ── README generation (pure) ──────────────────────────────────────
echo "== GAMES-README generation =="

readme=$(gms_games_readme)
check "explains the Windows drive letter"    'grep -qi "drive letter" <<< "$readme"'
check "names the SteamLibrary path"          'grep -q "SteamLibrary" <<< "$readme"'
check "same games serve both OSes"           'grep -qi "both operating systems" <<< "$readme"'
check "warns about Fast Startup/hibernation" 'grep -qi "fast startup" <<< "$readme"'
check "warns to leave the symlinks alone"    'grep -qi "leave them alone" <<< "$readme"'

# ── resize: pure helpers ─────────────────────────────────────────
echo "== resize: gms_adjacent_free_block (pure) =="

# Partition 2 ends at 120000MiB; adjacent free block starts at 120000MiB.
parted() {
    cat <<'PARTED'
Model: Fake Disk (scsi)
Disk /dev/sdz: 500000MiB
Number  Start      End        Size       Type     File system  Flags
 1      1.00MiB    102400MiB  102399MiB  primary  fat32        boot, esp
 2      102400MiB  120000MiB  17600MiB   primary  ntfs
        120000MiB  500000MiB  380000MiB           Free Space
PARTED
}
read -r adj_s adj_e adj_sz <<< "$(gms_adjacent_free_block /dev/sdz 2)"
check "adjacent free block start" '[[ "$adj_s" == "120000" ]]'
check "adjacent free block end"   '[[ "$adj_e" == "500000" ]]'
check "adjacent free block size"  '[[ "$adj_sz" == "380000" ]]'

# No adjacent free block (partition is at the disk end).
parted() {
    cat <<'PARTED'
Disk /dev/sdz: 120000MiB
Number  Start      End        Size       Type     File system  Flags
 1      1.00MiB    120000MiB  119999MiB  primary  ntfs
PARTED
}
out=$(gms_adjacent_free_block /dev/sdz 1)
check "no adjacent free block → empty output" '[[ -z "$out" ]]'
unset -f parted

# ── resize: gms_part_start / gms_part_end ────────────────────────
echo "== resize: gms_part_start / gms_part_end (pure) =="

parted() {
    cat <<'PARTED'
Disk /dev/sdz: 500000MiB
Number  Start      End        Size       Type
 1      1.00MiB    102400MiB  102399MiB  primary
 3      120000MiB  300000MiB  180000MiB  primary
PARTED
}
check "gms_part_start finds partition 3"  '[[ "$(gms_part_start /dev/sdz 3)" == "120000" ]]'
check "gms_part_end finds partition 3"    '[[ "$(gms_part_end /dev/sdz 3)" == "300000" ]]'
check "gms_part_start: non-existent part → empty" '[[ -z "$(gms_part_start /dev/sdz 9)" ]]'
unset -f parted

# ── resize: refusal paths ─────────────────────────────────────────
echo "== resize: refusal paths =="

# Missing --size.
reset_gms
out=$(cmd_games resize 2>&1); rc=$?
check "resize without --size → refused"   '[[ $rc -ne 0 ]]'
check "error mentions --size"             'echo "$out" | grep -q -- "--size"'

# No POWOS-GAMES partition found.
blkid()   { return 1; }
reset_gms
out=$(cmd_games resize --size 512 2>&1); rc=$?
check "resize: no partition → refused"    '[[ $rc -ne 0 ]]'
unset -f blkid

# Partition is mounted.
blkid()   { case "$*" in *"-L POWOS-GAMES"*) echo "/dev/sdz2"; return 0 ;; *) return 1 ;; esac; }
lsblk()   { case "$*" in *PKNAME*) echo "sdz" ;; *"-dn -o TYPE"*) echo "disk" ;;
             *"-bnd -o SIZE"*) echo $(( 200 * 1024 * 1048576 )) ;; *) echo "" ;; esac; }
findmnt() { case "$*" in *"-S /dev/sdz2"*) echo "/var/mnt/games" ;; *) return 1 ;; esac; }
gms_is_block() { return 0; }
reset_gms
out=$(cmd_games resize --size 400 2>&1); rc=$?
check "resize: partition mounted → refused" '[[ $rc -ne 0 ]]'
check "resize: mentions unmount"            'echo "$out" | grep -qi "mount"'
unset -f blkid lsblk findmnt gms_is_block

# Shrink without --yes is refused.
blkid()   { case "$*" in *"-L POWOS-GAMES"*) echo "/dev/sdz2"; return 0 ;; *) return 1 ;; esac; }
lsblk()   { case "$*" in *PKNAME*) echo "sdz" ;; *"-dn -o TYPE"*) echo "disk" ;;
             *"-bnd -o SIZE"*) echo $(( 500 * 1024 * 1048576 )) ;; *) echo "" ;; esac; }
findmnt() { return 1; }   # not mounted
gms_is_block() { return 0; }
reset_gms
out=$(cmd_games resize --size 200 2>&1); rc=$?   # shrink: 500→200GB, no --yes
check "shrink without --yes → refused"      '[[ $rc -ne 0 ]]'
check "shrink error mentions --yes"         'echo "$out" | grep -q "\-\-yes"'
unset -f blkid lsblk findmnt gms_is_block

# Grow: not enough adjacent free space.
blkid()   { case "$*" in *"-L POWOS-GAMES"*) echo "/dev/sdz2"; return 0 ;; *) return 1 ;; esac; }
lsblk()   { case "$*" in *PKNAME*) echo "sdz" ;; *"-dn -o TYPE"*) echo "disk" ;;
             *"-bnd -o SIZE"*) echo $(( 200 * 1024 * 1048576 )) ;; *) echo "" ;; esac; }
findmnt() { return 1; }
gms_is_block() { return 0; }
parted() {
    # Partition 2 ends at 204800MiB; only 10 MiB free adjacent — not enough to grow by 300 GB.
    cat <<'PARTED'
Disk /dev/sdz: 204810MiB
Number  Start      End        Size       Type     File system  Flags
 1      1.00MiB    102400MiB  102399MiB  primary  fat32
 2      102400MiB  204800MiB  102400MiB  primary  ntfs
        204800MiB  204810MiB  10MiB              Free Space
PARTED
}
reset_gms
out=$(cmd_games resize --size 500 2>&1); rc=$?   # grow: 200→500GB, only 10MiB free
check "grow: insufficient adjacent free space → refused" '[[ $rc -ne 0 ]]'
check "grow: error mentions free space"     'echo "$out" | grep -qi "free space"'
unset -f blkid lsblk findmnt gms_is_block parted

# Already at the requested size → no-op, success.
blkid()   { case "$*" in *"-L POWOS-GAMES"*) echo "/dev/sdz2"; return 0 ;; *) return 1 ;; esac; }
lsblk()   { case "$*" in *PKNAME*) echo "sdz" ;;
             *"-bnd -o SIZE"*) echo $(( 512 * 1024 * 1048576 )) ;; *) echo "" ;; esac; }
findmnt() { return 1; }
gms_is_block() { return 0; }
reset_gms
out=$(cmd_games resize --size 512 2>&1); rc=$?
check "resize to current size → 0 (no-op)"   '[[ $rc -eq 0 ]]'
check "resize to current size → says already" 'echo "$out" | grep -qi "already"'
unset -f blkid lsblk findmnt gms_is_block

# ── resize: dry-run shows plan for grow ───────────────────────────
echo "== resize: dry-run plan (grow) =="

MUT_CALLS=()
blkid()      { case "$*" in *"-L POWOS-GAMES"*) echo "/dev/sdz2"; return 0 ;; *) return 1 ;; esac; }
lsblk()      { case "$*" in *PKNAME*) echo "sdz" ;;
               *"-bnd -o SIZE"*) echo $(( 200 * 1024 * 1048576 )) ;; *) echo "" ;; esac; }
findmnt()    { return 1; }
gms_is_block() { return 0; }
ntfsresize() { MUT_CALLS+=("ntfsresize $*"); }
ntfsfix()    { MUT_CALLS+=("ntfsfix $*"); }
parted() {
    case "$*" in
        *"print free"*)
            cat <<'PARTED'
Disk /dev/sdz: 700000MiB
Number  Start      End        Size       Type     File system  Flags
 1      1.00MiB    102400MiB  102399MiB  primary  fat32
 2      102400MiB  204800MiB  102400MiB  primary  ntfs
        204800MiB  700000MiB  495200MiB           Free Space
PARTED
            ;;
        *) MUT_CALLS+=("parted $*") ;;
    esac
}
reset_gms
cmd_games resize --size 500 --disk /dev/sdz --dry-run > "$TMP/resize-dry.out" 2>&1; rc=$?
check "resize dry-run succeeds (grow)"               '[[ $rc -eq 0 ]]'
check "dry-run: zero mutating tool calls"            '[[ ${#MUT_CALLS[@]} -eq 0 ]]'
check "dry-run: mentions parted resizepart"          'grep -qi "parted.*resizepart" "$TMP/resize-dry.out"'
check "dry-run: mentions ntfsresize"                 'grep -qi "ntfsresize" "$TMP/resize-dry.out"'
check "dry-run: shows GROW operation"                'grep -qi "grow" "$TMP/resize-dry.out"'
unset -f blkid lsblk findmnt gms_is_block ntfsresize ntfsfix parted

# ── resize: ntfsfix failure aborts shrink ─────────────────────────
echo "== resize: ntfsfix failure aborts shrink =="

ntfsfix_rc=1   # global to control mock return code
MUT_CALLS=()
blkid()      { case "$*" in *"-L POWOS-GAMES"*) echo "/dev/sdz2"; return 0 ;; *) return 1 ;; esac; }
lsblk()      { case "$*" in *PKNAME*) echo "sdz" ;;
               *"-bnd -o SIZE"*) echo $(( 500 * 1024 * 1048576 )) ;; *) echo "" ;; esac; }
findmnt()    { return 1; }
gms_is_block() { return 0; }
ntfsfix()    { return $ntfsfix_rc; }
ntfsresize() { MUT_CALLS+=("ntfsresize $*"); }
parted()     { :; }
reset_gms
out=$(cmd_games resize --size 200 --yes 2>&1); rc=$?
check "shrink: ntfsfix failure → refused (rc != 0)" '[[ $rc -ne 0 ]]'
check "shrink: ntfsresize never called after ntfsfix failure" '[[ ${#MUT_CALLS[@]} -eq 0 ]]'
unset -f blkid lsblk findmnt gms_is_block ntfsfix ntfsresize parted

# ── Summary ───────────────────────────────────────────────────────
echo
echo "== Results: $PASS passed, $FAIL failed =="
[[ $FAIL -eq 0 ]]
