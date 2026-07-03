#!/bin/bash
# shellcheck disable=SC2016,SC2034
# (assertions are single-quoted on purpose — check() eval's them later; the
#  WIN_* globals are read inside those eval'd strings, not statically.)
# test-windows.sh - Tier-1 unit tests for the virtual-disk Windows lifecycle.
#
# Design under test (docs/WINDOWS.md, revised): Windows lives in ONE file on
# POWOS-GAMES (<games>/PowOS-Windows/windows.vhdx), metal-boots via native
# VHD boot, and NEVER gets real partitions. Metal boots always cold-boot;
# hibernation is a VM-mode-only feature.
#
# Runs on any machine with bash (no root, no real disks, Git Bash OK) by
# shadowing external tools (tar/zstd/qemu/efibootmgr/systemctl/…) with bash
# functions — the test-install-system.sh technique. File operations use real
# temp directories, so create/install/finalize are exercised end to end
# against a fake POWOS-GAMES mount.
#
# It does NOT (and cannot) validate real qemu, bcdboot, or firmware —
# that is the TODO(hw) hardware checklist.
#
# Usage:  bash test/tier1/test-windows.sh

set -uo pipefail

# Locate the lib relative to this test, or the installed path.
LIB="/usr/lib/powos/windows.sh"
if [[ ! -f "$LIB" ]]; then
    LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" && pwd)/windows.sh"
fi

PASS=0; FAIL=0
ok()   { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL - $1"; FAIL=$((FAIL+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 (expected: $2)"; fi; }

echo "== Sourcing windows lib: $LIB =="
# shellcheck disable=SC1090
source "$LIB" || { echo "cannot source lib"; exit 1; }

reset_globals() {
    WIN_DRY_RUN=0; WIN_ASSUME_YES=0; WIN_ISO=""
    WIN_REBOOT_FALLBACK=0; WIN_RAM="8G"; WIN_CPUS="4"
    WIN_INTERACTIVE=0; WIN_USERNAME="powos"; WIN_PASSWORD="powos"
    WIN_LOCALE="en-US"; WIN_KEYBOARD="en-US"
    WIN_PRODUCT_KEY=""; WIN_EDITION="Windows 11 Pro"; WIN_WITH_STEAM=0
    WIN_SIZE_GB=256; WIN_FIXED_VHD=0
    WIN_DEST=""; WIN_HASH=""; WIN_SLIM=0; WIN_FETCH=0; WIN_OUT=""; WIN_FETCHED_ISO=""
    WIN_GAMES_LETTER="G"; WIN_STEAM_AUTOSTART=0; WIN_NO_GAMES=0
}

# Mutating-call recorder: every mock that stands in for a destructive tool
# appends here; dry-run tests assert the file stays EMPTY. Line order in the
# file doubles as a sequence record.
REC=$(mktemp)
rec() { echo "$*" >> "$REC"; }
rec_reset() { : > "$REC"; }
rec_has()   { grep -q "$1" "$REC"; }
rec_empty() { [[ ! -s "$REC" ]]; }
rec_line()  { grep -n "$1" "$REC" | head -1 | cut -d: -f1; }

# ══════════════════════════════════════════════════════════════════
echo "== QEMU command builder (AHCI, not virtio; install vs vm shape) =="
# ══════════════════════════════════════════════════════════════════
# Install shape: disk0 = the raw image FILE, disk1 = the REAL ESP,
# cdrom = ISO, disk2 = unattend volume.
qi=$(win_build_qemu_cmd /games/PowOS-Windows/windows.raw raw /dev/sdz1 /isos/win11.iso \
                        8G 4 /fw/OVMF_CODE.fd /fw/OVMF_VARS.fd /run/powos/windows/unattend.img)

check "disk 0 is the image file, format=raw" \
    'echo "$qi" | grep -q "file=/games/PowOS-Windows/windows.raw,format=raw,if=none,id=windisk"'
check "image drive keeps the file THIN (discard/detect-zeroes unmap)" \
    'echo "$qi" | grep "id=windisk" | grep -q "discard=unmap,detect-zeroes=unmap"'
check "image on the first AHCI port" \
    'echo "$qi" | grep -q "ide-hd,drive=windisk,bus=ahci.0"'
check "disk 1 is the REAL ESP, raw" \
    'echo "$qi" | grep -q "file=/dev/sdz1,format=raw,if=none,id=espdisk"'
check "ESP on the second AHCI port" \
    'echo "$qi" | grep -q "ide-hd,drive=espdisk,bus=ahci.1"'
check "ISO attached as cdrom" \
    'echo "$qi" | grep -q "file=/isos/win11.iso,media=cdrom"'
check "unattend volume on the third AHCI port" \
    'echo "$qi" | grep -q "id=unattend" && echo "$qi" | grep -q "bus=ahci.2"'
check "AHCI controller, NOT virtio (identical stack VM<->metal)" \
    'echo "$qi" | grep -q -- "-device ahci,id=ahci" && ! echo "$qi" | grep -q "virtio-blk"'
check "OVMF pflash pair" \
    'echo "$qi" | grep -q "readonly=on,file=/fw/OVMF_CODE.fd" && echo "$qi" | grep -q "format=raw,file=/fw/OVMF_VARS.fd"'
check "boot menu + KVM" \
    'echo "$qi" | grep -q -- "-boot menu=on" && echo "$qi" | grep -q -- "-enable-kvm"'

# VM shape: just the VHDX — no ESP, no ISO, no unattend.
qv=$(win_build_qemu_cmd /games/PowOS-Windows/windows.vhdx vhdx "" "" \
                        8G 4 /fw/OVMF_CODE.fd /fw/OVMF_VARS.fd "")
check "vm shape: image attached as vhdx" \
    'echo "$qv" | grep -q "file=/games/PowOS-Windows/windows.vhdx,format=vhdx"'
check "vm shape: no real ESP attached" '! echo "$qv" | grep -q "espdisk"'
check "vm shape: no cdrom" '! echo "$qv" | grep -q "cdrom"'
check "vm shape: no unattend volume" '! echo "$qv" | grep -q "unattend"'

# ══════════════════════════════════════════════════════════════════
echo "== ESP backup / restore builders =="
# ══════════════════════════════════════════════════════════════════
bk=$(win_build_esp_backup_cmd /boot/efi "/data/windows/esp-backup-x.tar.zst")
rs=$(win_build_esp_restore_cmd "/data/windows/esp-backup-x.tar.zst" /boot/efi)
check "backup: tar the ESP contents" 'echo "$bk" | grep -q "tar -C ./boot/efi. -cf - ."'
check "backup: compressed to POWOS-DATA" 'echo "$bk" | grep -q "| zstd -q -f -o ./data/windows/esp-backup-x.tar.zst."'
check "restore: decompress from the backup" 'echo "$rs" | grep -q "zstd -dc ./data/windows/esp-backup-x.tar.zst."'
check "restore: untar back onto the ESP" 'echo "$rs" | grep -q "| tar -C ./boot/efi. -xf -"'

# ══════════════════════════════════════════════════════════════════
echo "== autounattend.xml generator (virtual-disk edition) =="
# ══════════════════════════════════════════════════════════════════
xml=$(win_build_autounattend powos powos en-US en-US "" "Windows 11 Pro" 0)

check "XML declaration first" \
    '[[ "$(printf "%s\n" "$xml" | head -1)" == "<?xml version=\"1.0\" encoding=\"utf-8\"?>" ]]'
check "ASCII only" '[[ "$xml" != *[![:ascii:]]* ]]'
check "balanced <settings> tags" \
    '[[ $(echo "$xml" | grep -c "<settings pass=") -eq $(echo "$xml" | grep -c "</settings>") ]]'
check "balanced <component> tags" \
    '[[ $(echo "$xml" | grep -c "<component name=") -eq $(echo "$xml" | grep -c "</component>") ]]'
check "balanced <SynchronousCommand> tags" \
    '[[ $(echo "$xml" | grep -c "<SynchronousCommand") -eq $(echo "$xml" | grep -c "</SynchronousCommand>") ]]'
check "balanced <RunSynchronousCommand> tags" \
    '[[ $(echo "$xml" | grep -c "<RunSynchronousCommand") -eq $(echo "$xml" | grep -c "</RunSynchronousCommand>") ]]'

# LabConfig bypasses (QEMU VM has no TPM/Secure Boot; Win11 Setup refuses).
for bypass in BypassTPMCheck BypassSecureBootCheck BypassRAMCheck BypassCPUCheck; do
    check "LabConfig $bypass present" \
        "echo \"\$xml\" | grep \"$bypass\" | grep -q 'REG_DWORD /d 1'"
done

# Disk 0 = the empty image file: Setup creates the internal layout itself.
check "wipe-disk-0 config (the file, safe by construction)" \
    'echo "$xml" | grep -q "<WillWipeDisk>true</WillWipeDisk>"'
check "targets DiskID 0" 'echo "$xml" | grep -q "<DiskID>0</DiskID>"'
check "creates an internal EFI partition" 'echo "$xml" | grep -q "<Type>EFI</Type>"'
check "creates an internal MSR partition" 'echo "$xml" | grep -q "<Type>MSR</Type>"'
check "installs to the created Primary partition (PartitionID 3)" \
    'echo "$xml" | grep -q "<PartitionID>3</PartitionID>"'
check "InstallToAvailablePartition off (never wander)" \
    'echo "$xml" | grep -q "<InstallToAvailablePartition>false</InstallToAvailablePartition>"'

# Keyless default must still be zero-touch.
check "keyless default: edition selected via /IMAGE/NAME" \
    'echo "$xml" | grep -q "<Key>/IMAGE/NAME</Key>"'
check "keyless default: edition value is Windows 11 Pro" \
    'echo "$xml" | grep -q "<Value>Windows 11 Pro</Value>"'
check "keyless default: ProductKey WillShowUI OnError (never prompts)" \
    'echo "$xml" | grep -q "<WillShowUI>OnError</WillShowUI>"'
check "keyless default: NO product <Key> element (only /IMAGE/NAME MetaData)" \
    '[[ -z "$(echo "$xml" | grep "<Key>" | grep -v "/IMAGE/NAME")" ]]'
check "EULA accepted (zero-touch requires it)" \
    'echo "$xml" | grep -q "<AcceptEula>true</AcceptEula>"'

# OOBE fully skipped.
for oobe in HideEULAPage HideOEMRegistration HideOnlineAccountScreens HideWirelessSetupInOOBE; do
    check "OOBE: $oobe" "echo \"\$xml\" | grep -q \"$oobe\""
done
check "OOBE: ProtectYourPC=3" 'echo "$xml" | grep -q "<ProtectYourPC>3</ProtectYourPC>"'

# Local account + one auto-logon.
check "local account created from username" 'echo "$xml" | grep -q "<Name>powos</Name>"'
check "password embedded" 'echo "$xml" | grep -q "<Value>powos</Value>"'
check "auto-logon exactly once" 'echo "$xml" | grep -q "<LogonCount>1</LogonCount>"'

# FirstLogonCommands: the five config commands + the four native-boot
# self-registration commands (replaces host-side BCD work entirely).
check "FirstLogon: powercfg /h on (VM-mode hibernation; harmless on metal)" \
    'echo "$xml" | grep -q "<CommandLine>powercfg /h on</CommandLine>"'
check "FirstLogon: HiberbootEnabled=0 (Fast Startup off)" \
    'echo "$xml" | grep "HiberbootEnabled" | grep -q "/d 0 /f"'
check "FirstLogon: RealTimeIsUniversal=1 (RTC as UTC)" \
    'echo "$xml" | grep "RealTimeIsUniversal" | grep -q "/d 1 /f"'
check "FirstLogon: Return-to-PowOS shortcut (shutdown /r /fw)" \
    'echo "$xml" | grep "Return to PowOS" | grep -q "shutdown /r /fw /t 0"'
check "FirstLogon: RestartApps=1" \
    'echo "$xml" | grep "RestartApps" | grep -q "/d 1 /f"'
check "native boot: mountvol grabs the real ESP at S:" \
    'echo "$xml" | grep -q "<CommandLine>mountvol S: /S</CommandLine>"'
check "native boot: bcdboot lays boot files on the real ESP" \
    'echo "$xml" | grep -qF "bcdboot C:\Windows /s S: /f UEFI"'
check "native boot: BCD device = vhd=[locate] (drive-letter independent)" \
    'echo "$xml" | grep "{default} device" | grep -qF "vhd=[locate]\PowOS-Windows\windows.vhdx"'
check "native boot: BCD osdevice = vhd=[locate]" \
    'echo "$xml" | grep "{default} osdevice" | grep -qF "vhd=[locate]\PowOS-Windows\windows.vhdx"'
check "exactly 9 FirstLogonCommands by default (5 config + 4 native-boot)" \
    '[[ $(echo "$xml" | grep -c "<SynchronousCommand") -eq 9 ]]'
check "no Steam installer by default" '! echo "$xml" | grep -q "SteamSetup"'

# Hygiene: nothing unexpanded, no bash-$ leakage.
check "no leftover __POWOS_ placeholders" '! echo "$xml" | grep -q "__POWOS_"'
check "no bash-\$ leakage into the XML" '! printf "%s" "$xml" | grep -q "\\\$"'

# XML-escaping of user values (password with & and <).
xml_esc=$(win_build_autounattend 'po&ws' 'p<a&ss>' de-DE de-DE "" "Windows 11 Pro" 0)
check "username &-escaped" 'echo "$xml_esc" | grep -q "<Name>po&amp;ws</Name>"'
check "password <, & and > escaped" \
    'echo "$xml_esc" | grep -q "<Value>p&lt;a&amp;ss&gt;</Value>"'
check "no raw unescaped password in the XML" \
    '! echo "$xml_esc" | grep -qF "p<a&ss>"'
check "locale and keyboard applied" \
    'echo "$xml_esc" | grep -q "<UserLocale>de-DE</UserLocale>" && echo "$xml_esc" | grep -q "<InputLocale>de-DE</InputLocale>"'

# --edition overrides the /IMAGE/NAME value.
xml_ed=$(win_build_autounattend powos powos en-US en-US "" "Windows 11 Home" 0)
check "--edition overrides the image name" \
    'echo "$xml_ed" | grep -q "<Value>Windows 11 Home</Value>"'

# --product-key adds <Key> alongside WillShowUI; XML stays balanced.
xml_key=$(win_build_autounattend powos powos en-US en-US "AAAAA-BBBBB-CCCCC-DDDDD-EEEEE" "Windows 11 Pro" 0)
check "product key embedded as <Key>" \
    'echo "$xml_key" | grep -q "<Key>AAAAA-BBBBB-CCCCC-DDDDD-EEEEE</Key>"'
check "WillShowUI OnError kept alongside the key" \
    'echo "$xml_key" | grep -q "<WillShowUI>OnError</WillShowUI>"'
check "XML with key: <settings> still balanced" \
    '[[ $(echo "$xml_key" | grep -c "<settings pass=") -eq $(echo "$xml_key" | grep -c "</settings>") ]]'

# Loose key-format validation (warn-not-fail lives in the wrapper).
check "well-formed key validates" 'win_validate_product_key "AAAAA-BBBBB-CCCCC-DDDDD-EEEEE"'
check "malformed key fails validation" '! win_validate_product_key "not-a-key"'
check "empty key fails validation" '! win_validate_product_key ""'

# --with-steam: exactly ONE extra best-effort FirstLogonCommand.
xml_steam=$(win_build_autounattend powos powos en-US en-US "" "Windows 11 Pro" 1)
check "--with-steam adds exactly one FirstLogonCommand (10 total)" \
    '[[ $(echo "$xml_steam" | grep -c "<SynchronousCommand") -eq 10 ]]'
check "Steam fetched from the official CDN, installed silently (/S)" \
    'echo "$xml_steam" | grep "SteamSetup" | grep -q "cdn.cloudflare.steamstatic.com" && echo "$xml_steam" | grep "SteamSetup" | grep -q "ArgumentList ./S."'
check "Steam XML: still no bash-\$ leakage (%TEMP%, not \$env:)" \
    '! printf "%s" "$xml_steam" | grep -q "\\\$"'

# Custom container path (--fixed-vhd → .vhd) flows into both BCD commands.
xml_vhd=$(win_build_autounattend powos powos en-US en-US "" "Windows 11 Pro" 0 '\PowOS-Windows\windows.vhd')
check "custom vhd path reaches the BCD device command" \
    'echo "$xml_vhd" | grep "{default} device" | grep -qF "windows.vhd</CommandLine>"'
check "custom vhd path reaches the BCD osdevice command" \
    'echo "$xml_vhd" | grep "{default} osdevice" | grep -qF "windows.vhd</CommandLine>"'

# ══════════════════════════════════════════════════════════════════
echo "== Windows post-install script generator (interactive fallback) =="
# ══════════════════════════════════════════════════════════════════
ps=$(win_build_postinstall_cmd)

check "hibernation enabled (powercfg /h on)" 'echo "$ps" | grep -q "powercfg /h on"'
check "HiberbootEnabled set to 0" \
    'echo "$ps" | grep "HiberbootEnabled" | grep -q "/t REG_DWORD /d 0 /f"'
check "Return-to-PowOS shortcut uses shutdown /r /fw" \
    'echo "$ps" | grep -q "shutdown /r /fw /t 0"'
check "bcdedit fwbootmgr one-shot documented for later" \
    'echo "$ps" | grep -q "bcdedit /set {fwbootmgr} bootsequence"'
check "no bash-\$ leakage into the cmd script" '! printf "%s" "$ps" | grep -q "\\\$"'
# Pure-bash match: Git Bash's grep reads stdin in text mode and eats the CRs.
check "CRLF line endings for cmd.exe" '[[ "$ps" == *$'"'"'\r'"'"'* ]]'

# ══════════════════════════════════════════════════════════════════
echo "== Firmware boot-entry lookup (efibootmgr parsing) =="
# ══════════════════════════════════════════════════════════════════
EFIOUT=$'BootCurrent: 0001\nTimeout: 1 seconds\nBootOrder: 0001,0003,0000\nBoot0000* UiApp\tFvVol(...)\nBoot0001* PowOS\tHD(1,GPT,aaaa)/File(\\EFI\\fedora\\shimx64.efi)\nBoot0003* Windows Boot Manager\tHD(1,GPT,aaaa)/File(\\EFI\\Microsoft\\Boot\\bootmgfw.efi)'

check "finds the Windows entry id (0003)" \
    '[[ "$(win_find_boot_entry "windows|microsoft" "$EFIOUT")" == "0003" ]]'
check "case-insensitive match" \
    '[[ "$(win_find_boot_entry "WINDOWS" "$EFIOUT")" == "0003" ]]'
check "no match returns failure" '! win_find_boot_entry "haiku" "$EFIOUT" >/dev/null'
check "label extraction stops at the device path" \
    '[[ "$(win_boot_entry_label 0003 "$EFIOUT")" == "Windows Boot Manager" ]]'

# ══════════════════════════════════════════════════════════════════
echo "== Typed-confirmation gate =="
# ══════════════════════════════════════════════════════════════════
reset_globals; WIN_ASSUME_YES=1
check "--yes auto-confirms plain y/N prompts" 'win_confirm "go?" >/dev/null 2>&1'
check "--yes does NOT satisfy a typed confirmation (rollback gate)" \
    '! win_confirm "type it:" "base" >/dev/null 2>&1'
reset_globals
check "matching typed confirmation passes" \
    'win_confirm "type it:" "base" >/dev/null 2>&1 <<< "base"'
check "mismatched typed confirmation fails" \
    '! win_confirm "type it:" "base" >/dev/null 2>&1 <<< "wrong"'

# ══════════════════════════════════════════════════════════════════
echo "== create (image file — NO partitioning) =="
# ══════════════════════════════════════════════════════════════════
CR_G=$(mktemp -d)   # fake POWOS-GAMES mount

# POWOS-GAMES not mounted → refuse, point at `powos games mount`.
win_games_mount() { return 1; }
win_require_root() { return 0; }
reset_globals; WIN_ASSUME_YES=1
out=$(win_create 2>&1); rc=$?
check "games unmounted → create refuses" '[[ $rc -ne 0 ]]'
check "…and points at powos games mount" 'echo "$out" | grep -q "powos games mount"'

# Dry-run: plan only, zero mutating calls, no partition tools anywhere.
win_games_mount() { echo "$CR_G"; }
truncate() { rec "truncate $*"; }
mkdir()    { rec "mkdir $*"; }
reset_globals; WIN_DRY_RUN=1; WIN_ASSUME_YES=1
rec_reset
out=$(win_create 2>&1); rc=$?
check "dry-run create succeeds (plan only)" '[[ $rc -eq 0 ]]'
check "plan shows the image path on POWOS-GAMES" \
    'echo "$out" | grep -q "PowOS-Windows/windows.raw"'
check "plan shows the default 256G max (thin)" \
    'echo "$out" | grep -q "256G" && echo "$out" | grep -qi "sparse"'
check "no partition tools involved (parted/sgdisk/mkpart never mentioned)" \
    '! echo "$out" | grep -Eq "parted|sgdisk|mkpart"'
check "dry-run create made ZERO mutating calls" 'rec_empty'

reset_globals; WIN_DRY_RUN=1; WIN_ASSUME_YES=1; WIN_SIZE_GB=512
out=$(win_create 2>&1)
check "--size honored (512G)" 'echo "$out" | grep -q "512G"'

reset_globals; WIN_DRY_RUN=1; WIN_SIZE_GB=10
out=$(win_create 2>&1); rc=$?
check "--size under 40G refused" '[[ $rc -ne 0 ]]'
unset -f truncate mkdir

# REAL create into the temp dir (only file ops — safe): sparse raw appears.
reset_globals; WIN_ASSUME_YES=1; WIN_SIZE_GB=40
out=$(win_create 2>&1); rc=$?
check "real create succeeds" '[[ $rc -eq 0 ]]'
check "raw image file exists" '[[ -f "$CR_G/PowOS-Windows/windows.raw" ]]'

# Existing raw → refuse; existing canonical → refuse.
reset_globals; WIN_ASSUME_YES=1; WIN_SIZE_GB=40
out=$(win_create 2>&1); rc=$?
check "existing raw image → create refuses" \
    '[[ $rc -ne 0 ]] && echo "$out" | grep -q "install --iso"'
rm -f "$CR_G/PowOS-Windows/windows.raw"
: > "$CR_G/PowOS-Windows/windows.vhdx"
reset_globals; WIN_ASSUME_YES=1; WIN_SIZE_GB=40
out=$(win_create 2>&1); rc=$?
check "existing canonical image → create refuses" '[[ $rc -ne 0 ]]'
source "$LIB"

# ══════════════════════════════════════════════════════════════════
echo "== install (disk 0 = file, disk 1 = REAL ESP, mandatory backup) =="
# ══════════════════════════════════════════════════════════════════
IN_G=$(mktemp -d); mkdir -p "$IN_G/PowOS-Windows"; : > "$IN_G/PowOS-Windows/windows.raw"
IN_E=$(mktemp -d); : > "$IN_E/dummy-boot-file"          # fake mounted ESP
IN_D=$(mktemp -d)                                        # fake POWOS-DATA/windows
IN_F=$(mktemp -d); : > "$IN_F/CODE.fd"; : > "$IN_F/VARS.fd"
IN_RUN=$(mktemp -d)
IN_ISO="$IN_F/win11.iso"; : > "$IN_ISO"    # non-dry runs check -f on the ISO

setup_install_mocks() {
    source "$LIB"
    WIN_RUNDIR="$IN_RUN"
    win_games_mount()     { echo "$IN_G"; }
    win_powos_esp()       { echo "/dev/sdz1"; }
    win_esp_mountpoint()  { echo "$IN_E"; }
    win_backup_dir()      { echo "$IN_D"; }
    win_require_root()    { return 0; }
    win_is_block()        { return 0; }
    win_image_in_use()    { return 1; }
    win_find_first_existing() { echo "$IN_F/CODE.fd"; }
    tar()   { rec "tar $*"; printf 'x'; }
    zstd()  { rec "zstd $*"; cat >/dev/null 2>&1 || true; printf 'x' > "${!#}"; }
    mount() { rec "mount $*"; return 0; }
    umount(){ rec "umount $*"; return 0; }
    mkfs.vfat() { rec "mkfs.vfat $*"; }
    truncate()  { rec "truncate $*"; }
    qemu-system-x86_64() { rec "qemu $*"; return 0; }
}

# Dry-run: full plan, ZERO mutating calls.
setup_install_mocks
reset_globals; WIN_DRY_RUN=1; WIN_ISO=/isos/win11.iso
rec_reset
out=$(win_install 2>&1); rc=$?
check "dry-run install succeeds (plan only)" '[[ $rc -eq 0 ]]'
check "plan: disk 0 is the image file" \
    'echo "$out" | grep "Disk 0" | grep -q "windows.raw"'
check "plan: disk 1 is the REAL ESP" \
    'echo "$out" | grep "Disk 1" | grep -q "/dev/sdz1"'
check "plan: mandatory ESP backup announced FIRST" \
    'echo "$out" | grep -q "esp-backup-" && echo "$out" | grep -qi "mandatory"'
check "plan: unattended is the default (autounattend + self-registration)" \
    'echo "$out" | grep -q "autounattend.xml" && echo "$out" | grep -q "bcdboot"'
check "plan: default password gets a loud warning" \
    'echo "$out" | grep -q "DEFAULT PASSWORD"'
check "dry-run install made ZERO mutating calls" 'rec_empty'

# --interactive: no unattend anywhere.
setup_install_mocks
reset_globals; WIN_DRY_RUN=1; WIN_ISO=/isos/win11.iso; WIN_INTERACTIVE=1
rec_reset
out=$(win_install 2>&1); rc=$?
check "--interactive: plan does NOT mention autounattend" \
    '[[ $rc -eq 0 ]] && ! echo "$out" | grep -q "autounattend"'
check "--interactive dry-run made ZERO mutating calls" 'rec_empty'

# Malformed / well-formed product key handling (warn, never fail).
setup_install_mocks
reset_globals; WIN_DRY_RUN=1; WIN_ISO=/isos/win11.iso; WIN_PRODUCT_KEY="not-a-key"
out=$(win_install 2>&1); rc=$?
check "malformed --product-key warns but proceeds" \
    '[[ $rc -eq 0 ]] && echo "$out" | grep -q "does not look like"'
setup_install_mocks
reset_globals; WIN_DRY_RUN=1; WIN_ISO=/isos/win11.iso
WIN_PRODUCT_KEY="AAAAA-BBBBB-CCCCC-DDDDD-EEEEE"
out=$(win_install 2>&1); rc=$?
check "well-formed --product-key: no format warning" \
    '[[ $rc -eq 0 ]] && ! echo "$out" | grep -q "does not look like"'

# Refusals.
setup_install_mocks
reset_globals; WIN_DRY_RUN=1; WIN_ISO=""
out=$(win_install 2>&1); rc=$?
check "install without --iso refuses" \
    '[[ $rc -ne 0 ]] && echo "$out" | grep -q -- "--iso"'

setup_install_mocks
win_games_mount() { local d; d=$(mktemp -d); echo "$d"; }   # empty games: no raw
reset_globals; WIN_DRY_RUN=1; WIN_ISO=/isos/win11.iso
out=$(win_install 2>&1); rc=$?
check "no raw image → install refuses, points at create" \
    '[[ $rc -ne 0 ]] && echo "$out" | grep -q "powos windows create"'

setup_install_mocks
: > "$IN_G/PowOS-Windows/windows.vhdx"
reset_globals; WIN_DRY_RUN=1; WIN_ISO=/isos/win11.iso
out=$(win_install 2>&1); rc=$?
check "canonical image exists → install refuses (already installed)" \
    '[[ $rc -ne 0 ]] && echo "$out" | grep -q "already installed"'
rm -f "$IN_G/PowOS-Windows/windows.vhdx"

# REAL (mocked-tools) run: sequence must be backup → ESP umount → qemu.
setup_install_mocks
reset_globals; WIN_ASSUME_YES=1; WIN_ISO="$IN_ISO"
rec_reset
out=$(win_install 2>&1); rc=$?
check "mocked full install run succeeds" '[[ $rc -eq 0 ]]'
check "ESP backup executed (tar recorded)" 'rec_has "^tar "'
check "ESP backup ordered BEFORE the VM launch" \
    '[[ -n "$(rec_line "^tar ")" && -n "$(rec_line "^qemu ")" && "$(rec_line "^tar ")" -lt "$(rec_line "^qemu ")" ]]'
check "host ESP unmounted before the VM launch" \
    '[[ -n "$(rec_line "^umount $IN_E")" && "$(rec_line "^umount $IN_E")" -lt "$(rec_line "^qemu ")" ]]'
check "qemu got the image file as disk 0" \
    'rec_has "file=$IN_G/PowOS-Windows/windows.raw,format=raw,if=none,id=windisk"'
check "qemu got the REAL ESP as disk 1" \
    'rec_has "file=/dev/sdz1,format=raw,if=none,id=espdisk"'
check "qemu got the unattend volume" 'rec_has "id=unattend"'
check "qemu got the ISO as cdrom" 'rec_has "file=$IN_ISO,media=cdrom"'
check "ESP remounted after the VM exits" 'rec_has "^mount /dev/sdz1 $IN_E"'
check "ESP restore one-liner printed" \
    'echo "$out" | grep -q "zstd -dc" && echo "$out" | grep -q "tar -C"'

# ESP backup failure → hard abort, VM never launches.
setup_install_mocks
zstd() { rec "zstd $*"; return 1; }
reset_globals; WIN_ASSUME_YES=1; WIN_ISO="$IN_ISO"
rec_reset
out=$(win_install 2>&1); rc=$?
check "ESP backup failure → install aborts" '[[ $rc -ne 0 ]]'
check "backup failure → VM never launched" '! rec_has "^qemu "'
check "backup failure → ESP never unmounted" '! rec_has "^umount $IN_E"'

# ESP busy (umount fails) → abort before the VM.
setup_install_mocks
umount() { rec "umount $*"; [[ "${1:-}" == "$IN_E" ]] && return 1; return 0; }
reset_globals; WIN_ASSUME_YES=1; WIN_ISO="$IN_ISO"
rec_reset
out=$(win_install 2>&1); rc=$?
check "ESP umount failure → install aborts before the VM" \
    '[[ $rc -ne 0 ]] && ! rec_has "^qemu "'

unset -f tar zstd mount umount mkfs.vfat truncate qemu-system-x86_64
source "$LIB"

# ══════════════════════════════════════════════════════════════════
echo "== finalize (convert, verify ESP, host-side efibootmgr) =="
# ══════════════════════════════════════════════════════════════════
FN_G=$(mktemp -d); mkdir -p "$FN_G/PowOS-Windows"
FN_E=$(mktemp -d); mkdir -p "$FN_E/EFI/Microsoft/Boot"
: > "$FN_E/EFI/Microsoft/Boot/BCD"; : > "$FN_E/EFI/Microsoft/Boot/bootmgfw.efi"
FN_D=$(mktemp -d); : > "$FN_D/esp-backup-20260701-000000.tar.zst"
FN_FLAG="$FN_D/.entry-created"

setup_finalize_mocks() {
    source "$LIB"
    win_games_mount()    { echo "$FN_G"; }
    win_powos_esp()      { echo "/dev/sdz1"; }
    win_esp_mountpoint() { echo "$FN_E"; }
    win_backup_dir()     { echo "$FN_D"; }
    win_parent_disk()    { echo "/dev/sdz"; }
    win_require_root()   { return 0; }
    win_require_efi()    { return 0; }
    win_image_in_use()   { return 1; }
    qemu-img() { rec "qemu-img $*"; printf 'x' > "${!#}"; }
    efibootmgr() {
        if [[ "$*" == *"-c"* ]]; then rec "efibootmgr $*"; : > "$FN_FLAG"; return 0; fi
        if [[ -e "$FN_FLAG" ]]; then
            printf 'Boot0004* Windows Boot Manager\tHD(1,GPT,aaaa)\n'
        else
            printf 'Boot0001* PowOS\tHD(1,GPT,aaaa)\n'
        fi
    }
}

# Dry-run with a pending raw: plan only, zero mutating calls.
setup_finalize_mocks
: > "$FN_G/PowOS-Windows/windows.raw"; rm -f "$FN_FLAG"
reset_globals; WIN_DRY_RUN=1
rec_reset
out=$(win_finalize 2>&1); rc=$?
check "dry-run finalize succeeds (plan only)" '[[ $rc -eq 0 ]]'
check "dry-run finalize made ZERO mutating calls" 'rec_empty'

# Real (mocked) run: convert → verify → efibootmgr -c host-side.
setup_finalize_mocks
rm -f "$FN_FLAG"
reset_globals; WIN_ASSUME_YES=1
rec_reset
out=$(win_finalize 2>&1); rc=$?
check "finalize succeeds" '[[ $rc -eq 0 ]]'
check "raw converted to dynamic VHDX (thin, native-bootable)" \
    'rec_has "qemu-img convert -O vhdx -o subformat=dynamic"'
check "canonical image exists after conversion" \
    '[[ -f "$FN_G/PowOS-Windows/windows.vhdx" ]]'
check "raw image deleted after conversion" \
    '[[ ! -e "$FN_G/PowOS-Windows/windows.raw" ]]'
check "ESP boot-file verification passed (BCD + bootmgfw.efi proxy)" \
    'echo "$out" | grep -q "EFI/Microsoft/Boot"'
check "firmware entry created HOST-SIDE (VM has its own NVRAM)" \
    'rec_has "efibootmgr -c -d /dev/sdz -p 1 -L Windows Boot Manager"'
check "entry verified to resolve for powos boot windows" \
    'echo "$out" | grep -q "resolves Boot0004"'
check "ESP restore one-liner printed from the newest backup" \
    'echo "$out" | grep "zstd -dc" | grep -q "esp-backup-20260701-000000.tar.zst"'

# --fixed-vhd escape hatch: vpc/fixed conversion, .vhd filename.
setup_finalize_mocks
rm -f "$FN_G/PowOS-Windows/windows.vhdx" "$FN_FLAG"
: > "$FN_G/PowOS-Windows/windows.raw"
reset_globals; WIN_ASSUME_YES=1; WIN_FIXED_VHD=1
rec_reset
out=$(win_finalize 2>&1); rc=$?
check "--fixed-vhd converts to fixed-subformat VHD (vpc)" \
    'rec_has "qemu-img convert -O vpc -o subformat=fixed"'
check "--fixed-vhd canonical file is windows.vhd" \
    '[[ -f "$FN_G/PowOS-Windows/windows.vhd" ]]'
rm -f "$FN_G/PowOS-Windows/windows.vhd"

# ESP missing the Microsoft boot files → refuse with guidance.
setup_finalize_mocks
: > "$FN_G/PowOS-Windows/windows.vhdx"; rm -f "$FN_FLAG"
rm -f "$FN_E/EFI/Microsoft/Boot/BCD"
reset_globals; WIN_ASSUME_YES=1
out=$(win_finalize 2>&1); rc=$?
check "missing EFI/Microsoft on the ESP → finalize refuses" \
    '[[ $rc -ne 0 ]] && echo "$out" | grep -qi "self-registration"'
: > "$FN_E/EFI/Microsoft/Boot/BCD"
rm -f "$FN_G/PowOS-Windows/windows.vhdx"

unset -f qemu-img efibootmgr
source "$LIB"

# ══════════════════════════════════════════════════════════════════
echo "== the switch (metal COLD boot) =="
# ══════════════════════════════════════════════════════════════════
SW_G=$(mktemp -d); mkdir -p "$SW_G/PowOS-Windows"; : > "$SW_G/PowOS-Windows/windows.vhdx"
EFIWIN=$'BootOrder: 0001,0003\nBoot0001* PowOS\tHD(1,GPT,aaaa)\nBoot0003* Windows Boot Manager\tHD(1,GPT,aaaa)/File(\\EFI\\Microsoft\\Boot\\bootmgfw.efi)'

setup_switch_mocks() {
    source "$LIB"
    win_require_root() { return 0; }
    win_require_efi()  { return 0; }
    win_games_mount()  { echo "$SW_G"; }
    win_image_in_use() { return 1; }
    win_image_hibernated() { echo absent; }
    efibootmgr() {
        if [[ "$*" == *"--bootnext"* ]]; then rec "efibootmgr $*"; return 0; fi
        printf '%s\n' "$EFIWIN"
    }
    python3()   { rec "python3 $*"; return 0; }
    systemctl() { rec "systemctl $*"; return 0; }
    sync()      { rec "sync"; return 0; }
    umount()    { rec "umount $*"; return 0; }
}

# Happy path: flush → stop → umount games → bootnext → sync → hibernate.
setup_switch_mocks
reset_globals; WIN_ASSUME_YES=1
rec_reset
out=$(win_switch 2>&1); rc=$?
check "switch succeeds with all guards green" '[[ $rc -eq 0 ]]'
check "cold-boot messaging (no resume wording)" \
    'echo "$out" | grep -qi "COLD-BOOT" && ! echo "$out" | grep -qi "resumes its own session"'
check "layer-sync flushed (--sync-now)" 'rec_has "python3 .*--sync-now"'
check "layer-sync daemon stopped" 'rec_has "systemctl stop powos-layer-sync.service"'
check "POWOS-GAMES unmounted (hosts the image; frozen rw-mount rule)" \
    'rec_has "^umount $SW_G"'
check "games unmounted BEFORE BootNext" \
    '[[ "$(rec_line "^umount $SW_G")" -lt "$(rec_line "efibootmgr --bootnext")" ]]'
check "BootNext set to the Windows entry (0003)" 'rec_has "efibootmgr --bootnext 0003"'
check "hibernate invoked" 'rec_has "systemctl hibernate"'

# Image missing / raw-only.
setup_switch_mocks
win_games_mount() { local d; d=$(mktemp -d); echo "$d"; }
reset_globals; WIN_ASSUME_YES=1
out=$(win_switch 2>&1); rc=$?
check "no image → switch refuses, points at create" \
    '[[ $rc -ne 0 ]] && echo "$out" | grep -q "powos windows create"'

SW_RAWG=$(mktemp -d); mkdir -p "$SW_RAWG/PowOS-Windows"; : > "$SW_RAWG/PowOS-Windows/windows.raw"
setup_switch_mocks
win_games_mount() { echo "$SW_RAWG"; }
reset_globals; WIN_ASSUME_YES=1
out=$(win_switch 2>&1); rc=$?
check "raw-only image → switch refuses, points at finalize" \
    '[[ $rc -ne 0 ]] && echo "$out" | grep -q "finalize"'

# Image in use (qemu/nbd) → hard refuse, nothing flushed.
setup_switch_mocks
win_image_in_use() { return 0; }
reset_globals; WIN_ASSUME_YES=1
rec_reset
out=$(win_switch 2>&1); rc=$?
check "image in use → switch refused" '[[ $rc -ne 0 ]]'
check "in-use refusal happens before any flush" '! rec_has "python3"'

# VM-hibernated image → metal switch WARNS (discard) but proceeds on confirm.
setup_switch_mocks
win_image_hibernated() { echo present; }
reset_globals; WIN_ASSUME_YES=1
rec_reset
out=$(win_switch 2>&1); rc=$?
check "VM-hibernated image → metal switch proceeds after warning" '[[ $rc -eq 0 ]]'
check "…warning says the VM session gets DISCARDED" 'echo "$out" | grep -q "DISCARD"'

# Unknown hibernation state → warn, still confirmable.
setup_switch_mocks
win_image_hibernated() { echo unknown; }
reset_globals; WIN_ASSUME_YES=1
out=$(win_switch 2>&1); rc=$?
check "unknown hibernation state → warn + proceed on confirm" \
    '[[ $rc -eq 0 ]] && echo "$out" | grep -qi "Could not determine"'

# layer-sync failures → abort before games umount / BootNext.
setup_switch_mocks
python3() { rec "python3 $*"; return 1; }
reset_globals; WIN_ASSUME_YES=1
rec_reset
out=$(win_switch 2>&1); rc=$?
check "flush failure → switch aborts" '[[ $rc -ne 0 ]]'
check "flush failure → games never unmounted, BootNext never set" \
    '! rec_has "^umount $SW_G" && ! rec_has "bootnext"'

setup_switch_mocks
systemctl() { rec "systemctl $*"; [[ "${1:-}" == "stop" ]] && return 1; return 0; }
reset_globals; WIN_ASSUME_YES=1
rec_reset
out=$(win_switch 2>&1); rc=$?
check "layer-sync stop failure → switch aborts, no BootNext" \
    '[[ $rc -ne 0 ]] && ! rec_has "bootnext"'

# POWOS-GAMES busy → abort before BootNext.
setup_switch_mocks
umount() { rec "umount $*"; return 1; }
reset_globals; WIN_ASSUME_YES=1
rec_reset
out=$(win_switch 2>&1); rc=$?
check "games umount failure → switch aborts before BootNext" \
    '[[ $rc -ne 0 ]] && ! rec_has "bootnext"'

# No firmware entry → refuse before any flush.
setup_switch_mocks
efibootmgr() { printf 'BootOrder: 0001\nBoot0001* PowOS\tHD(1,GPT,aaaa)\n'; }
reset_globals; WIN_ASSUME_YES=1
rec_reset
out=$(win_switch 2>&1); rc=$?
check "missing Windows boot entry → refuse, suggest finalize" \
    '[[ $rc -ne 0 ]] && echo "$out" | grep -q "finalize"'
check "missing entry → nothing flushed or unmounted" 'rec_empty'

# Hibernate FAILS → explain, offer --reboot fallback.
setup_switch_mocks
systemctl() { rec "systemctl $*"; [[ "${1:-}" == "hibernate" ]] && return 1; return 0; }
reset_globals; WIN_ASSUME_YES=1   # --yes without --reboot: no auto-reboot
rec_reset
out=$(win_switch 2>&1); rc=$?
check "hibernate failure → switch reports failure" '[[ $rc -ne 0 ]]'
check "…explains the swap/resume= prerequisites" 'echo "$out" | grep -q "resume="'
check "…offers the --reboot fallback" 'echo "$out" | grep -q -- "--reboot"'
check "--yes alone does NOT auto-reboot" '! rec_has "systemctl reboot"'

setup_switch_mocks
systemctl() { rec "systemctl $*"; [[ "${1:-}" == "hibernate" ]] && return 1; return 0; }
reset_globals; WIN_ASSUME_YES=1; WIN_REBOOT_FALLBACK=1
rec_reset
out=$(win_switch 2>&1); rc=$?
check "--reboot: plain reboot into Windows after hibernate failure" \
    'rec_has "systemctl reboot"'

# Dry-run switch: full plan, ZERO mutating calls.
setup_switch_mocks
reset_globals; WIN_DRY_RUN=1; WIN_ASSUME_YES=1
rec_reset
out=$(win_switch 2>&1); rc=$?
check "dry-run switch succeeds" '[[ $rc -eq 0 ]]'
check "dry-run switch made ZERO mutating calls" 'rec_empty'

unset -f efibootmgr python3 systemctl sync umount
source "$LIB"

# ══════════════════════════════════════════════════════════════════
echo "== snapshot / rollback (file-level) =="
# ══════════════════════════════════════════════════════════════════
SN_G=$(mktemp -d); mkdir -p "$SN_G/PowOS-Windows"; : > "$SN_G/PowOS-Windows/windows.vhdx"
SN_S=$(mktemp -d)
SN_RAWG=$(mktemp -d); mkdir -p "$SN_RAWG/PowOS-Windows"; : > "$SN_RAWG/PowOS-Windows/windows.raw"

setup_snap_mocks() {
    source "$LIB"
    win_require_root() { return 0; }
    win_games_mount()  { echo "$SN_G"; }
    win_snapshot_dir() { echo "$SN_S"; }
    win_image_in_use() { return 1; }
    zstd()  { rec "zstd $*"; printf 'x' > "${!#}"; }
    mkdir() { rec "mkdir $*"; }
}

# Dry-run snapshot: exact command shown, zero mutating calls.
setup_snap_mocks
reset_globals; WIN_DRY_RUN=1
rec_reset
out=$(win_snapshot base 2>&1); rc=$?
check "dry-run snapshot succeeds (plan only)" '[[ $rc -eq 0 ]]'
check "plan shows the zstd whole-file compress" \
    'echo "$out" | grep "zstd -q -f" | grep -q "windows.vhdx"'
check "snapshot lands on POWOS-DATA (invisible to Windows by design)" \
    'echo "$out" | grep -q "$SN_S/base.vhdx.zst"'
check "differencing-VHDX noted as future work" \
    'echo "$out" | grep -qi "future work"'
check "dry-run snapshot made ZERO mutating calls" 'rec_empty'

# Real (mocked) snapshot.
setup_snap_mocks
reset_globals; WIN_ASSUME_YES=1
rec_reset
out=$(win_snapshot base 2>&1); rc=$?
check "snapshot runs zstd compress" \
    '[[ $rc -eq 0 ]] && rec_has "zstd -q -f $SN_G/PowOS-Windows/windows.vhdx -o $SN_S/base.vhdx.zst"'

# In-use image → refuse.
setup_snap_mocks
win_image_in_use() { return 0; }
reset_globals
rec_reset
out=$(win_snapshot base2 2>&1); rc=$?
check "image in use → snapshot refused" '[[ $rc -ne 0 ]]'
check "in-use snapshot refusal runs nothing" 'rec_empty'

# Raw-only (unfinalized) → refuse.
setup_snap_mocks
win_games_mount() { echo "$SN_RAWG"; }
reset_globals
out=$(win_snapshot base 2>&1); rc=$?
check "raw-only image → snapshot refused (finalize first)" \
    '[[ $rc -ne 0 ]] && echo "$out" | grep -q "finalize"'

# Rollback: typed gate; restore = decompress-replace.
setup_snap_mocks
reset_globals; WIN_DRY_RUN=1; WIN_ASSUME_YES=1
out=$(win_rollback base 2>&1); rc=$?
check "rollback typed gate is NOT satisfied by --yes" '[[ $rc -ne 0 ]]'
setup_snap_mocks
reset_globals; WIN_DRY_RUN=1
out=$(win_rollback base 2>&1 <<< "base"); rc=$?
check "typed snapshot name confirms the rollback (dry-run)" '[[ $rc -eq 0 ]]'
check "restore is decompress-replace onto the image" \
    'echo "$out" | grep "zstd -d -q -f" | grep -q "windows.vhdx"'

unset -f zstd mkdir
source "$LIB"

# ══════════════════════════════════════════════════════════════════
echo "== vm (real now — same image; VM-hibernation is the OK case) =="
# ══════════════════════════════════════════════════════════════════
setup_vm_mocks() {
    source "$LIB"
    win_require_root() { return 0; }
    win_games_mount()  { echo "$SN_G"; }
    win_image_in_use() { return 1; }
    win_image_hibernated() { echo absent; }
    win_find_first_existing() { echo "/fw/OVMF.fd"; }
}

# Dry-run: plan shows the vhdx VM shape.
setup_vm_mocks
reset_globals; WIN_DRY_RUN=1
out=$(win_vm 2>&1); rc=$?
check "vm dry-run succeeds" '[[ $rc -eq 0 ]]'
check "vm attaches the image as vhdx" \
    'echo "$out" | grep -q "windows.vhdx,format=vhdx"'
check "vm does NOT attach the real ESP" '! echo "$out" | grep -q "espdisk"'
check "vm has no cdrom / unattend" \
    '! echo "$out" | grep -q "cdrom" && ! echo "$out" | grep -q "id=unattend"'

# VM-hibernated image: the CORRECT resume path — never refused.
setup_vm_mocks
win_image_hibernated() { echo present; }
reset_globals; WIN_DRY_RUN=1
out=$(win_vm 2>&1); rc=$?
check "VM-hibernated image → vm proceeds (correct hardware match)" \
    '[[ $rc -eq 0 ]] && echo "$out" | grep -qi "resume"'

# In use → refuse.
setup_vm_mocks
win_image_in_use() { return 0; }
reset_globals; WIN_DRY_RUN=1
out=$(win_vm 2>&1); rc=$?
check "image in use → vm refused" '[[ $rc -ne 0 ]]'

# Raw-only → refuse with finalize hint; none → create hint.
setup_vm_mocks
win_games_mount() { echo "$SN_RAWG"; }
reset_globals; WIN_DRY_RUN=1
out=$(win_vm 2>&1); rc=$?
check "raw-only image → vm refused, points at finalize" \
    '[[ $rc -ne 0 ]] && echo "$out" | grep -q "finalize"'
setup_vm_mocks
win_games_mount() { local d; d=$(mktemp -d); echo "$d"; }
reset_globals; WIN_DRY_RUN=1
out=$(win_vm 2>&1); rc=$?
check "no image → vm refused, points at create" \
    '[[ $rc -ne 0 ]] && echo "$out" | grep -q "powos windows create"'

source "$LIB"

# ══════════════════════════════════════════════════════════════════
echo "== slim package list (curation + anti-cheat safety guard) =="
# ══════════════════════════════════════════════════════════════════
PKGLIST=$(win_slim_package_list)
check "package list is non-empty" '[[ -n "$PKGLIST" ]]'
check "removes Clipchamp" 'echo "$PKGLIST" | grep -q "Clipchamp"'
check "removes a Bing app" 'echo "$PKGLIST" | grep -q "Microsoft.Bing"'
check "removes Teams" 'echo "$PKGLIST" | grep -q "MicrosoftTeams"'
check "removes Copilot" 'echo "$PKGLIST" | grep -qi "Copilot"'
check "removes Widgets" 'echo "$PKGLIST" | grep -qi "Widgets"'
# GUARD: nothing anti-cheat / servicing / security depends on may be stripped.
# A break here would defeat the entire reason bare-metal Windows exists.
check "GUARD: no Windows Update / servicing stack in the removal list" \
    '! echo "$PKGLIST" | grep -qiE "windowsupdate|servicing|winsxs"'
check "GUARD: no .NET / NetFx in the removal list" \
    '! echo "$PKGLIST" | grep -qiE "netfx|dotnet|\.net"'
check "GUARD: no VC runtime (VCLibs/vcredist) in the removal list" \
    '! echo "$PKGLIST" | grep -qiE "vclibs|vcredist|vcruntime"'
check "GUARD: no Defender / security stack in the removal list" \
    '! echo "$PKGLIST" | grep -qiE "defender|securityhealth"'
check "GUARD: Xbox Identity Provider is KEPT (multiplayer sign-in)" \
    '! echo "$PKGLIST" | grep -qi "XboxIdentityProvider"'

# ══════════════════════════════════════════════════════════════════
echo "== Steam shared-library generators (mirror lib/games.sh) =="
# ══════════════════════════════════════════════════════════════════
VDF=$(win_steam_libraryfolders_vdf G)
check "vdf points at <letter>:\\SteamLibrary (escaped backslashes)" \
    'echo "$VDF" | grep -qF "G:\\\\SteamLibrary"'
check "vdf keeps Steam's own install dir at index 0" \
    'echo "$VDF" | grep -qF "C:\\\\Program Files (x86)\\\\Steam"'
check "vdf is a well-formed libraryfolders block" \
    'echo "$VDF" | head -1 | grep -q "\"libraryfolders\""'
check "vdf is deterministic / idempotent" \
    '[[ "$(win_steam_libraryfolders_vdf G)" == "$(win_steam_libraryfolders_vdf G)" ]]'
VDF_X=$(win_steam_libraryfolders_vdf X)
check "vdf honors a custom letter" \
    'echo "$VDF_X" | grep -qF "X:\\\\SteamLibrary"'
# GUARD: the Windows side NEVER touches Proton-only state.
check "GUARD: vdf never references compatdata/shadercache" \
    '! echo "$VDF" | grep -qiE "compatdata|shadercache"'

PS1=$(win_build_steam_firstlogon_ps1 POWOS-GAMES G POWOSUNAT 0)
check "ps1: matches POWOS-GAMES by FileSystemLabel (never a drive letter)" \
    'echo "$PS1" | grep -q "FileSystemLabel .POWOS-GAMES."'
check "ps1: assigns the stable letter via Add-PartitionAccessPath" \
    'echo "$PS1" | grep -q "Add-PartitionAccessPath" && echo "$PS1" | grep -qF "G:"'
check "ps1: prefers the OFFLINE SteamSetup.exe from the unattend volume" \
    'echo "$PS1" | grep -q "FileSystemLabel .POWOSUNAT." && echo "$PS1" | grep -q "SteamSetup.exe"'
check "ps1: installs Steam silently (/S)" \
    'echo "$PS1" | grep -q "ArgumentList ./S."'
check "ps1: CDN fallback uses the official Valve URL" \
    'echo "$PS1" | grep -q "cdn.cloudflare.steamstatic.com"'
check "ps1: seeds libraryfolders.vdf with the shared library" \
    'echo "$PS1" | grep -q "libraryfolders.vdf" && echo "$PS1" | grep -qF "G:\\\\SteamLibrary"'
check "ps1: no leftover __POWOS_ placeholders" \
    '! echo "$PS1" | grep -q "__POWOS_"'
# GUARD: compatdata is a Linux-only concern — never referenced on the Windows side.
check "GUARD: ps1 never references compatdata/shadercache" \
    '! echo "$PS1" | grep -qiE "compatdata|shadercache"'
check "ps1: no autostart Run key by default" \
    '! echo "$PS1" | grep -qi "CurrentVersion.\\+Run"'
PS1_AUTO=$(win_build_steam_firstlogon_ps1 POWOS-GAMES G POWOSUNAT 1)
check "ps1: --steam-autostart adds the Run key" \
    'echo "$PS1_AUTO" | grep -qi "CurrentVersion.\\+Run" && echo "$PS1_AUTO" | grep -q "Steam.exe"'
PS1_H=$(win_build_steam_firstlogon_ps1 POWOS-GAMES H POWOSUNAT 0)
check "ps1: custom letter flows through both letter-assign and vdf" \
    'echo "$PS1_H" | grep -qF "H:\\\\SteamLibrary"'

# autounattend games block (default off; on when games_setup=1).
xml_nogames=$(win_build_autounattend powos powos en-US en-US "" "Windows 11 Pro" 0)
check "autounattend: NO games block by default (backward compatible)" \
    '! echo "$xml_nogames" | grep -q "powos-first-logon"'
check "autounattend: still exactly 9 FirstLogonCommands by default" \
    '[[ $(echo "$xml_nogames" | grep -c "<SynchronousCommand") -eq 9 ]]'
xml_games=$(win_build_autounattend powos powos en-US en-US "" "Windows 11 Pro" 0 '\PowOS-Windows\windows.vhdx' 1 POWOSUNAT)
check "autounattend: games block invokes the first-logon ps1 by unattend label" \
    'echo "$xml_games" | grep -q "powos-first-logon.ps1" && echo "$xml_games" | grep -q "FileSystemLabel .POWOSUNAT."'
check "autounattend: games block adds exactly one command (10 total)" \
    '[[ $(echo "$xml_games" | grep -c "<SynchronousCommand") -eq 10 ]]'
check "autounattend: PowerShell call operator is XML-escaped (&amp;)" \
    'echo "$xml_games" | grep -q "&amp;"'
check "autounattend with games: <settings> still balanced" \
    '[[ $(echo "$xml_games" | grep -c "<settings pass=") -eq $(echo "$xml_games" | grep -c "</settings>") ]]'
check "autounattend with games: no leftover placeholders" \
    '! echo "$xml_games" | grep -q "__POWOS_"'

# ══════════════════════════════════════════════════════════════════
echo "== fetch-iso (official MS ISO, verify, optional slim) =="
# ══════════════════════════════════════════════════════════════════
FI_D=$(mktemp -d)    # fake POWOS-DATA/windows/iso parent
FI_DEST="$FI_D/Win11.iso"

setup_fetch_mocks() {
    source "$LIB"
    win_data_mount()   { echo "$FI_D"; }
    win_iso_dir()      { echo "$FI_D/windows/iso"; }
    win_require_root() { return 0; }
    win_fetch_official_iso() { rec "fetch $*"; printf 'x' > "${1}"; return 0; }
    win_file_size_bytes()    { echo 4700000000; }   # ~4.7GB — passes the >3GB gate
    win_iso_fstype()         { echo udf; }
    win_sha256()             { echo "abc123deadbeef"; }
    # slim seams recorded so we can assert slim never runs on a bad download.
    xorriso()        { rec "xorriso $*"; return 0; }
    wimlib-imagex()  { rec "wimlib $*"; return 0; }
    mkdir()          { rec "mkdir $*"; command mkdir "$@" 2>/dev/null; return 0; }
}

# Dry-run: default dest lands under POWOS-DATA/windows/iso; ZERO mutations.
setup_fetch_mocks
reset_globals; WIN_DRY_RUN=1
rec_reset
out=$(win_fetch_iso 2>&1); rc=$?
check "dry-run fetch succeeds (plan only)" '[[ $rc -eq 0 ]]'
check "default dest is under POWOS-DATA/windows/iso" \
    'echo "$out" | grep -q "windows/iso/Win11.iso"'
check "dry-run fetch made ZERO mutating calls" 'rec_empty'

# Missing --hash: prints the computed hash + a verify-it note, still succeeds.
setup_fetch_mocks
reset_globals; WIN_ASSUME_YES=1
rec_reset
out=$(win_fetch_iso 2>&1); rc=$?
check "fetch without --hash succeeds" '[[ $rc -eq 0 ]]'
check "…prints the computed SHA-256" 'echo "$out" | grep -q "abc123deadbeef"'
check "…and a prominent verify-against-Microsoft note" \
    'echo "$out" | grep -qi "VERIFY" && echo "$out" | grep -qi "Microsoft"'
check "fetch actually invoked the (mock) downloader" 'rec_has "^fetch "'

# --hash MATCH: verifies and proceeds.
setup_fetch_mocks
reset_globals; WIN_ASSUME_YES=1; WIN_HASH="ABC123DEADBEEF"    # case-insensitive match
out=$(win_fetch_iso 2>&1); rc=$?
check "matching --hash verifies and succeeds" \
    '[[ $rc -eq 0 ]] && echo "$out" | grep -qi "verified"'

# --hash MISMATCH: aborts, and MUST NOT proceed to slim.
setup_fetch_mocks
reset_globals; WIN_ASSUME_YES=1; WIN_HASH="0000000000000000"; WIN_SLIM=1
rec_reset
out=$(win_fetch_iso 2>&1); rc=$?
check "hash mismatch aborts fetch" '[[ $rc -ne 0 ]]'
check "hash mismatch reports MISMATCH" 'echo "$out" | grep -qi "MISMATCH"'
check "hash mismatch does NOT proceed to slim (no xorriso/wimlib)" \
    '! rec_has "^xorriso " && ! rec_has "^wimlib "'

# Too-small download → rejected as partial.
setup_fetch_mocks
win_file_size_bytes() { echo 1000000; }   # 1MB
reset_globals; WIN_ASSUME_YES=1
out=$(win_fetch_iso 2>&1); rc=$?
check "implausibly small download rejected" \
    '[[ $rc -ne 0 ]] && echo "$out" | grep -qi "small"'

# --slim chains after a verified download (fetch → slim seams run).
setup_fetch_mocks
reset_globals; WIN_ASSUME_YES=1; WIN_SLIM=1; WIN_HASH="abc123deadbeef"
rec_reset
out=$(win_fetch_iso 2>&1); rc=$?
check "verified fetch --slim chains into the slim pipeline" \
    '[[ $rc -eq 0 ]] && rec_has "^xorriso " && rec_has "^wimlib "'
check "fetch --slim reports the slim output path" \
    'echo "$out" | grep -q "Win11-slim.iso"'
check "fetch --slim suggests --fixed-vhd (small install)" \
    'echo "$out" | grep -q -- "--fixed-vhd"'

unset -f win_fetch_official_iso win_file_size_bytes win_iso_fstype win_sha256 xorriso wimlib-imagex mkdir win_data_mount win_iso_dir
source "$LIB"

# ══════════════════════════════════════════════════════════════════
echo "== slim (wimlib pipeline, order, dry-run, anti-cheat warning) =="
# ══════════════════════════════════════════════════════════════════
SL_SRC=$(mktemp); SL_OUT=$(mktemp -u)

setup_slim_mocks() {
    source "$LIB"
    win_require_root() { return 0; }
    xorriso()       { rec "xorriso $*"; return 0; }
    wimlib-imagex() { rec "wimlib $*"; return 0; }
    hivexregedit()  { rec "hivexregedit $*"; return 0; }
    rm()            { rec "rm $*"; return 0; }
    # command -v must find the tools:
    command() { if [[ "$1" == "-v" ]]; then return 0; fi; builtin command "$@"; }
}

# Dry-run: full plan + the anti-cheat WARNING, ZERO mutating calls.
setup_slim_mocks
reset_globals; WIN_DRY_RUN=1
rec_reset
out=$(win_slim_iso "$SL_SRC" "$SL_OUT" 2>&1); rc=$?
check "dry-run slim succeeds (plan only)" '[[ $rc -eq 0 ]]'
check "slim prints the ANTI-CHEAT warning (EAC/BattlEye)" \
    'echo "$out" | grep -qi "ANTI-CHEAT" && echo "$out" | grep -qi "BattlE"'
check "slim notes it KEEPS servicing/.NET/VC/security stack" \
    'echo "$out" | grep -qi "servicing" && echo "$out" | grep -qi "runtime"'
check "slim is marked EXPERIMENTAL / TODO(hw)" \
    'echo "$out" | grep -qi "EXPERIMENTAL"'
check "dry-run slim made ZERO mutating calls" 'rec_empty'

# Real (mocked) run: pipeline in the right order.
setup_slim_mocks
reset_globals; WIN_ASSUME_YES=1
rec_reset
out=$(win_slim_iso "$SL_SRC" "$SL_OUT" 2>&1); rc=$?
check "mocked slim run succeeds" '[[ $rc -eq 0 ]]'
check "slim extracts the ISO with xorriso (osirrox)" 'rec_has "xorriso.*osirrox"'
check "slim mounts install.wim with wimlib (mountrw)" 'rec_has "wimlib mountrw"'
check "slim removes provisioned appx (Clipchamp)" 'rec_has "rm.*Clipchamp"'
check "slim removes Edge + OneDrive setup" 'rec_has "rm.*Edge" && rec_has "rm.*OneDriveSetup"'
check "slim injects the bypass registry (hivexregedit)" 'rec_has "^hivexregedit "'
check "slim commits + unmounts the wim" 'rec_has "wimlib unmount .*--commit"'
check "slim rebuilds (optimize) the wim" 'rec_has "wimlib optimize"'
check "slim repacks a bootable UEFI ISO with xorriso (mkisofs)" 'rec_has "xorriso.*mkisofs"'
# Order: extract BEFORE mount; unmount BEFORE optimize; optimize BEFORE repack.
check "order: xorriso-extract precedes wimlib-mount" \
    '[[ "$(rec_line "xorriso.*osirrox")" -lt "$(rec_line "wimlib mountrw")" ]]'
check "order: wimlib-unmount precedes wimlib-optimize" \
    '[[ "$(rec_line "wimlib unmount")" -lt "$(rec_line "wimlib optimize")" ]]'
check "order: wimlib-optimize precedes xorriso-repack" \
    '[[ "$(rec_line "wimlib optimize")" -lt "$(rec_line "xorriso.*mkisofs")" ]]'

# slim command wrapper: default out path, missing arg.
setup_slim_mocks
reset_globals; WIN_DRY_RUN=1
out=$(win_slim_cmd "$SL_SRC" 2>&1); rc=$?
check "slim wrapper: default out is <src>-slim.iso" \
    '[[ $rc -eq 0 ]] && echo "$out" | grep -q "slim.iso"'
out=$(win_slim_cmd "" 2>&1); rc=$?
check "slim wrapper without a source refuses with usage" \
    '[[ $rc -ne 0 ]] && echo "$out" | grep -q "Usage"'

unset -f xorriso wimlib-imagex hivexregedit rm command win_require_root
source "$LIB"

# ══════════════════════════════════════════════════════════════════
echo "== install: --fetch chains, Steam preinstall, --fixed-vhd hint =="
# ══════════════════════════════════════════════════════════════════
IS_G=$(mktemp -d); mkdir -p "$IS_G/PowOS-Windows"; : > "$IS_G/PowOS-Windows/windows.raw"
IS_E=$(mktemp -d); : > "$IS_E/dummy"
IS_D=$(mktemp -d)
IS_F=$(mktemp -d); : > "$IS_F/CODE.fd"; : > "$IS_F/VARS.fd"
IS_RUN=$(mktemp -d)
IS_ISO="$IS_F/win11.iso"; : > "$IS_ISO"

setup_install2_mocks() {
    source "$LIB"
    WIN_RUNDIR="$IS_RUN"
    win_games_mount()     { echo "$IS_G"; }
    win_powos_esp()       { echo "/dev/sdz1"; }
    win_esp_mountpoint()  { echo "$IS_E"; }
    win_backup_dir()      { echo "$IS_D"; }
    win_require_root()    { return 0; }
    win_is_block()        { return 0; }
    win_image_in_use()    { return 1; }
    win_find_first_existing() { echo "$IS_F/CODE.fd"; }
    win_file_size_bytes() { echo 5000000000; }   # normal (non-slim) ISO ~5GB
    tar()   { rec "tar $*"; printf 'x'; }
    zstd()  { rec "zstd $*"; cat >/dev/null 2>&1 || true; printf 'x' > "${!#}"; }
    mount() { rec "mount $*"; return 0; }
    umount(){ rec "umount $*"; return 0; }
    mkfs.vfat() { rec "mkfsvfat $*"; }
    truncate()  { rec "truncate $*"; }
    qemu-system-x86_64() { rec "qemu $*"; return 0; }
    win_fetch_steam_setup() { rec "steamsetup $*"; printf 'x' > "${1}"; return 0; }
}

# --fetch chains fetch-iso → install (WIN_FETCHED_ISO becomes the install ISO).
setup_install2_mocks
win_fetch_iso() { rec "fetch_iso"; WIN_FETCHED_ISO="$IS_ISO"; return 0; }
reset_globals; WIN_ASSUME_YES=1; WIN_FETCH=1; WIN_ISO=""
rec_reset
out=$(win_install 2>&1); rc=$?
check "install --fetch runs fetch-iso first" 'rec_has "^fetch_iso"'
check "install --fetch then installs the fetched ISO" \
    '[[ $rc -eq 0 ]] && rec_has "file=$IS_ISO,media=cdrom" && echo "$out" | grep -q "fetched ISO"'

# Default install PREINSTALLS Steam: labeled unattend volume + ps1 + SteamSetup.
setup_install2_mocks
reset_globals; WIN_ASSUME_YES=1; WIN_ISO="$IS_ISO"
rec_reset
out=$(win_install 2>&1); rc=$?
check "default install: unattend volume gets the POWOSUNAT label" \
    'rec_has "mkfsvfat.*-n POWOSUNAT"'
check "default install: preloads SteamSetup.exe onto the unattend volume" \
    'rec_has "^steamsetup .*SteamSetup.exe"'
check "default install: plan announces the shared-library seeding" \
    'echo "$out" | grep -q "shared library" && echo "$out" | grep -q "POWOS-GAMES"'
check "default install: writes the first-logon ps1 onto the unattend volume" \
    'echo "$out" | grep -q "powos-first-logon.ps1"'

# --no-games: no Steam preload, no ps1.
setup_install2_mocks
reset_globals; WIN_ASSUME_YES=1; WIN_ISO="$IS_ISO"; WIN_NO_GAMES=1
rec_reset
out=$(win_install 2>&1); rc=$?
check "--no-games skips the Steam preload" '! rec_has "^steamsetup "'

# --fixed-vhd hint fires for a SMALL (slim) install, not for a normal one.
setup_install2_mocks
reset_globals; WIN_DRY_RUN=1; WIN_ISO="$IS_ISO"; WIN_SLIM=1
out=$(win_install 2>&1)
check "small (--slim) install suggests --fixed-vhd" \
    'echo "$out" | grep -q -- "--fixed-vhd" && echo "$out" | grep -qi "small"'
setup_install2_mocks
reset_globals; WIN_DRY_RUN=1; WIN_ISO="$IS_ISO"; WIN_SLIM=1; WIN_FIXED_VHD=1
out=$(win_install 2>&1)
check "…but NOT when --fixed-vhd is already set" \
    '! echo "$out" | grep -qi "looks like a SMALL"'

unset -f tar zstd mount umount mkfs.vfat truncate qemu-system-x86_64 win_fetch_steam_setup win_fetch_iso win_file_size_bytes
source "$LIB"

# ══════════════════════════════════════════════════════════════════
echo "== Dispatch =="
# ══════════════════════════════════════════════════════════════════
out=$(cmd_windows help 2>&1); rc=$?
check "cmd_windows help works" '[[ $rc -eq 0 ]] && echo "$out" | grep -q "powos windows"'
check "help documents the default vhd file design" \
    'echo "$out" | grep -q "virtual-disk FILE"'
check "help documents both backends (vhd default + partition)" \
    'echo "$out" | grep -q -- "--backend" && echo "$out" | grep -q "partition"'
check "help documents fetch-iso" 'echo "$out" | grep -q "fetch-iso"'
check "help documents slim" 'echo "$out" | grep -q -- "slim <src.iso>"'
check "help documents --fetch / --hash / --slim / --no-games" \
    'echo "$out" | grep -q -- "--fetch" && echo "$out" | grep -q -- "--hash" && echo "$out" | grep -q -- "--no-games"'
out=$(cmd_windows bogus-subcommand 2>&1); rc=$?
check "unknown subcommand fails with usage" '[[ $rc -ne 0 ]] && echo "$out" | grep -q "Unknown windows command"'

# fetch-iso / slim dispatch (backend-agnostic — routed before the backend split).
out=$(cmd_windows fetch-iso --dry-run --dest /tmp/x.iso 2>&1); rc=$?
check "dispatch: fetch-iso routes to win_fetch_iso" \
    '[[ $rc -eq 0 ]] && echo "$out" | grep -qi "official Windows 11 ISO"'
out=$(cmd_windows slim 2>&1); rc=$?
check "dispatch: slim without a source shows usage" \
    '[[ $rc -ne 0 ]] && echo "$out" | grep -q "Usage"'
out=$(cmd_windows --backend partition fetch-iso --dry-run --dest /tmp/x.iso 2>&1); rc=$?
check "dispatch: fetch-iso works under --backend partition too" \
    '[[ $rc -eq 0 ]] && echo "$out" | grep -qi "official Windows 11 ISO"'

# ══════════════════════════════════════════════════════════════════
echo "== Config file (WINDOWS_* → WIN_*, precedence default<file<flag) =="
# ══════════════════════════════════════════════════════════════════
CONF=$(mktemp)
cat > "$CONF" <<'EOF'
WINDOWS_EDITION="Windows 11 Home"
WINDOWS_SIZE_GB=128
WINDOWS_USERNAME="alice"
WINDOWS_WITH_STEAM=1
WINDOWS_ISO="/isos/from-config.iso"
EOF

# Direct loader: documented keys land on the WIN_* knobs.
reset_globals; WIN_CONFIG="$CONF"; WIN_CONFIG_LOADED=""
win_load_config
check "config sets edition"         '[[ "$WIN_EDITION" == "Windows 11 Home" ]]'
check "config sets size"            '[[ "$WIN_SIZE_GB" == "128" ]]'
check "config sets username"        '[[ "$WIN_USERNAME" == "alice" ]]'
check "config sets with-steam"      '[[ "$WIN_WITH_STEAM" == "1" ]]'
check "config sets iso"             '[[ "$WIN_ISO" == "/isos/from-config.iso" ]]'
check "config records loaded path"  '[[ "$WIN_CONFIG_LOADED" == "$CONF" ]]'
# A key absent from the file keeps the built-in default.
check "absent key keeps default"    '[[ "$WIN_PASSWORD" == "powos" ]]'

# Missing/unreadable config is a silent no-op that leaves defaults intact.
reset_globals; WIN_CONFIG="/no/such/windows.conf"; WIN_CONFIG_LOADED=""
win_load_config
check "missing config → no-op"       '[[ "$WIN_EDITION" == "Windows 11 Pro" && -z "$WIN_CONFIG_LOADED" ]]'

# End-to-end via cmd_windows: --config seeds the knobs, a flag still wins.
win_status() { return 0; }   # no-op stand-in so dispatch does no disk work
cmd_windows --config "$CONF" --edition "Windows 11 Enterprise" status
check "flag overrides file (edition)"  '[[ "$WIN_EDITION" == "Windows 11 Enterprise" ]]'
check "file overrides default (size)"  '[[ "$WIN_SIZE_GB" == "128" ]]'
check "file value applies w/o flag"    '[[ "$WIN_USERNAME" == "alice" ]]'
rm -f "$CONF"

# ══════════════════════════════════════════════════════════════════
echo "== Backend toggle (WINDOWS_BACKEND vhd|partition) =="
# ══════════════════════════════════════════════════════════════════
win_status() { return 0; }   # vhd no-op stand-in (partition uses win_part_*)

# Default backend is vhd.
cmd_windows status
check "default backend is vhd" '[[ "$WIN_BACKEND" == "vhd" ]]'

# Config selects the partition backend. Its real behavior is covered in the
# "== Partition backend ==" section; here we only verify ROUTING + precedence.
# NOTE: run cmd_windows in the CURRENT shell when asserting WIN_BACKEND — a
# $(...) capture mutates it only in a subshell.
CONF2=$(mktemp); echo 'WINDOWS_BACKEND="partition"' > "$CONF2"
cmd_windows --config "$CONF2" status >/dev/null 2>&1
check "config selects partition backend"          '[[ "$WIN_BACKEND" == "partition" ]]'

# --backend flag overrides the config (partition → vhd here, which runs).
cmd_windows --config "$CONF2" --backend vhd status >/dev/null 2>&1; rc=$?
check "flag overrides config backend (→vhd runs)"  '[[ "$WIN_BACKEND" == "vhd" && $rc -eq 0 ]]'

# --backend can also select partition directly.
cmd_windows --backend partition status >/dev/null 2>&1
check "flag selects partition backend"             '[[ "$WIN_BACKEND" == "partition" ]]'

# An unknown backend is rejected before any dispatch.
out=$(cmd_windows --backend bogus status 2>&1); rc=$?
check "invalid backend rejected"                   '[[ $rc -ne 0 ]] && echo "$out" | grep -q "Unknown WINDOWS_BACKEND"'
rm -f "$CONF2"

# ── Summary ───────────────────────────────────────────────────────
rm -f "$REC"
echo
echo "== Results: $PASS passed, $FAIL failed =="
[[ $FAIL -eq 0 ]]
