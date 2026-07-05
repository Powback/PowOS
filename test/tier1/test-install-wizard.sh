#!/bin/bash
# shellcheck disable=SC2016,SC2034
# (assertions are single-quoted on purpose — check() eval's them later; the
#  IWZ_*/POWOS_* globals are read inside those eval'd strings.)
#
# test-install-wizard.sh - Tier-1 unit tests for the guided install wizard.
#
# Runs on ANY box (Git Bash on Windows OR real Linux) with no root and no real
# disks: every external tool (openssl, lspci, hostnamectl, chpasswd, useradd,
# systemctl, powos, ...) is shadowed by a bash function. Covers the parts a bug
# would make dangerous or embarrassing:
#   - iwz_build_installer_args flag mapping + the erase-confirmation gate
#   - install.conf write/read round-trip
#   - password is HASHED, never stored plaintext
#   - powos-firstboot-apply calls the right command per key AND deletes the
#     config (it holds a hash) at the end
#   - dry-run performs ZERO mutations
#   - UI backend selection (gui / tui / read)
#
# Usage:  bash test/tier1/test-install-wizard.sh
#   Docker: docker exec powos bash /test/tier1/test-install-wizard.sh

set -uo pipefail

# Locate the lib + firstboot bin relative to this test, or the installed paths.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="/usr/lib/powos/install-wizard.sh"
[[ -f "$LIB" ]] || LIB="$(cd "$HERE/../../lib" && pwd)/install-wizard.sh"
FB="/usr/bin/powos-firstboot-apply"
[[ -f "$FB" ]] || FB="$(cd "$HERE/../../bin" && pwd)/powos-firstboot-apply"

PASS=0; FAIL=0
ok()   { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL - $1"; FAIL=$((FAIL+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 (expected: $2)"; fi; }

echo "== Sourcing wizard lib: $LIB =="
# shellcheck disable=SC1090
source "$LIB" || { echo "cannot source wizard lib"; exit 1; }
echo "== Sourcing firstboot applier: $FB =="
# shellcheck disable=SC1090
source "$FB"  || { echo "cannot source firstboot applier"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

reset_iwz() {
    IWZ_DRY_RUN=0; IWZ_DISK=""; IWZ_GAMES_DISK=""; IWZ_MODE="whole-disk"; IWZ_ROOT_GB="auto"
    IWZ_GAMES_GB="auto"; IWZ_WINDOWS_GB="auto"; IWZ_FS="btrfs"
    IWZ_GPU_FLAVOR="nvidia-open"; IWZ_HOSTNAME="powos"; IWZ_USERNAME="powos"
    IWZ_PASSWORD_HASH=""; IWZ_SSH_ENABLE=0; IWZ_SSH_KEY=""; IWZ_RAMBOOT="off"
    IWZ_AI_PROVIDER="none"; IWZ_AI_KEY=""; IWZ_RESTORE_URL=""
    IWZ_CONFIG_PATH="$TMP/install.conf"
}

# ── iwz_build_installer_args — flag mapping ───────────────────────
echo "== Installer-arg mapping =="

reset_iwz
IWZ_DISK="/dev/sdz"; IWZ_MODE="whole-disk"; IWZ_FS="btrfs"
IWZ_GAMES_GB="512"; IWZ_WINDOWS_GB="0"
ARGS=$(iwz_build_installer_args)
check "whole-disk: --disk carried"        'echo "$ARGS" | grep -q -- "--disk /dev/sdz"'
check "whole-disk: --whole-disk emitted"  'echo "$ARGS" | grep -q -- "--whole-disk"'
check "whole-disk: erase gate emitted"    'echo "$ARGS" | grep -q -- "--i-understand-data-loss"'
check "whole-disk: --yes emitted"         'echo "$ARGS" | grep -q -- "--yes"'
check "whole-disk: --fs btrfs"            'echo "$ARGS" | grep -q -- "--fs btrfs"'
check "whole-disk: --shared-gb from games" 'echo "$ARGS" | grep -q -- "--shared-gb 512"'
check "whole-disk: --windows-gb carried"  'echo "$ARGS" | grep -q -- "--windows-gb 0"'
check "whole-disk: no --alongside"        '! echo "$ARGS" | grep -q -- "--alongside"'

reset_iwz
IWZ_DISK="/dev/nvme0n1"; IWZ_MODE="alongside"; IWZ_FS="ext4"
IWZ_GAMES_GB="auto"; IWZ_WINDOWS_GB="auto"
ARGS=$(iwz_build_installer_args)
check "alongside: --alongside emitted"    'echo "$ARGS" | grep -q -- "--alongside"'
check "alongside: NO erase gate"          '! echo "$ARGS" | grep -q -- "--i-understand-data-loss"'
check "alongside: NO --whole-disk"        '! echo "$ARGS" | grep -q -- "--whole-disk"'
check "alongside: --fs ext4"              'echo "$ARGS" | grep -q -- "--fs ext4"'
check "alongside: auto sizes pass through" 'echo "$ARGS" | grep -q -- "--shared-gb auto" && echo "$ARGS" | grep -q -- "--windows-gb auto"'
check "alongside: still --yes"            'echo "$ARGS" | grep -q -- "--yes"'

# ── Separate games disk → --games-disk flag mapping ───────────────
echo "== Separate games disk flag mapping =="

reset_iwz
IWZ_DISK="/dev/nvme0n1"; IWZ_MODE="whole-disk"; IWZ_GAMES_DISK=""
ARGS=$(iwz_build_installer_args)
check "no games disk → NO --games-disk emitted"  '! echo "$ARGS" | grep -q -- "--games-disk"'

reset_iwz
IWZ_DISK="/dev/nvme0n1"; IWZ_MODE="whole-disk"; IWZ_GAMES_DISK="/dev/nvme1n1"
ARGS=$(iwz_build_installer_args)
check "separate games disk → --games-disk emitted" 'echo "$ARGS" | grep -q -- "--games-disk /dev/nvme1n1"'

reset_iwz
IWZ_DISK="/dev/nvme0n1"; IWZ_MODE="whole-disk"; IWZ_GAMES_DISK="/dev/nvme0n1"
ARGS=$(iwz_build_installer_args)
check "games disk == PowOS disk → NO --games-disk" '! echo "$ARGS" | grep -q -- "--games-disk"'

# ── Password is hashed, never plaintext ───────────────────────────
echo "== Password hashing (no plaintext leak) =="

openssl() {
    # Shadow real openssl so the test is deterministic everywhere.
    if [[ "${1:-}" == "passwd" ]]; then echo '$6$mocksalt$MOCKHASHvalue1234567890'; fi
}
reset_iwz
IWZ_PASSWORD_HASH="$(iwz_hash_password 'SuperSecret123')"
check "hash uses SHA-512 crypt (id 6)"    '[[ "$IWZ_PASSWORD_HASH" == \$6\$* ]]'
check "plaintext never becomes the hash"  '[[ "$IWZ_PASSWORD_HASH" != *SuperSecret123* ]]'

IWZ_DISK="/dev/sdz"; IWZ_HOSTNAME="rig"; IWZ_USERNAME="pow"
iwz_write_config "$TMP/pw.conf"
check "written config contains NO plaintext" '! grep -q "SuperSecret123" "$TMP/pw.conf"'
check "written config contains the hash"     'grep -q "MOCKHASHvalue" "$TMP/pw.conf"'
unset -f openssl

# ── Config write/read round-trip ──────────────────────────────────
echo "== Config write/read round-trip =="

reset_iwz
IWZ_DISK="/dev/sdX"; IWZ_MODE="alongside"; IWZ_ROOT_GB="200"; IWZ_GAMES_GB="256"
IWZ_WINDOWS_GB="64"; IWZ_FS="ext4"; IWZ_GPU_FLAVOR="amd"; IWZ_HOSTNAME="battlestation"
IWZ_USERNAME="neo"; IWZ_PASSWORD_HASH='$6$abc$defGHI'; IWZ_SSH_ENABLE=1
IWZ_SSH_KEY="ssh-ed25519 AAAAKEYDATA neo@rig"; IWZ_RAMBOOT="installed"
IWZ_AI_PROVIDER="claude"; IWZ_AI_KEY="sk-test-123"; IWZ_RESTORE_URL="git@example.com:me/state.git"
iwz_write_config "$TMP/rt.conf"

# Read back by sourcing (this is exactly how firstboot + install-system read it).
(
    # shellcheck disable=SC1090
    source "$TMP/rt.conf"
    [[ "$ISV_DISK" == "/dev/sdX" ]] &&
    [[ "$ISV_MODE" == "alongside" ]] &&
    [[ "$ISV_ROOT_GB" == "200" ]] &&
    [[ "$ISV_GAMES_GB" == "256" ]] &&
    [[ "$ISV_WINDOWS_GB" == "64" ]] &&
    [[ "$ISV_FS" == "ext4" ]] &&
    [[ "$POWOS_GPU_FLAVOR" == "amd" ]] &&
    [[ "$POWOS_HOSTNAME" == "battlestation" ]] &&
    [[ "$POWOS_USERNAME" == "neo" ]] &&
    [[ "$POWOS_PASSWORD_HASH" == '$6$abc$defGHI' ]] &&
    [[ "$POWOS_SSH_ENABLE" == "1" ]] &&
    [[ "$POWOS_SSH_KEY" == "ssh-ed25519 AAAAKEYDATA neo@rig" ]] &&
    [[ "$POWOS_RAMBOOT" == "installed" ]] &&
    [[ "$POWOS_AI_PROVIDER" == "claude" ]] &&
    [[ "$POWOS_AI_KEY" == "sk-test-123" ]] &&
    [[ "$POWOS_RESTORE_URL" == "git@example.com:me/state.git" ]]
)
check "every key round-trips through source" '[[ $? -eq 0 ]]'

# The hash + SSH key survive quoting verbatim (no $-expansion, spaces intact).
check "hash with \$ survives quoting"        'grep -q "POWOS_PASSWORD_HASH='\''\$6\$abc\$defGHI'\''" "$TMP/rt.conf"'

# iwz_load_config maps the file back into IWZ_* globals.
reset_iwz
iwz_load_config "$TMP/rt.conf" >/dev/null 2>&1
check "iwz_load_config restores IWZ_MODE"    '[[ "$IWZ_MODE" == "alongside" ]]'
check "iwz_load_config restores IWZ_AI_KEY"  '[[ "$IWZ_AI_KEY" == "sk-test-123" ]]'

# IWZ_GAMES_DISK round-trips through write → source → load.
reset_iwz
IWZ_DISK="/dev/nvme0n1"; IWZ_GAMES_DISK="/dev/nvme1n1"
iwz_write_config "$TMP/gd.conf"
check "config carries ISV_GAMES_DISK"        'grep -q "ISV_GAMES_DISK=.\{0,\}/dev/nvme1n1" "$TMP/gd.conf"'
reset_iwz
iwz_load_config "$TMP/gd.conf" >/dev/null 2>&1
check "iwz_load_config restores IWZ_GAMES_DISK" '[[ "$IWZ_GAMES_DISK" == "/dev/nvme1n1" ]]'

# ── Dry-run gates every mutation ──────────────────────────────────
echo "== Dry-run zero-mutation gate =="

SENTINEL=0
danger() { SENTINEL=1; }

reset_iwz; IWZ_DRY_RUN=1; SENTINEL=0
iwz_run_step "would mutate" danger >/dev/null 2>&1
check "dry-run does NOT run destructive cmd" '[[ $SENTINEL -eq 0 ]]'

reset_iwz; IWZ_DRY_RUN=0; SENTINEL=0
iwz_run_step "really run" danger >/dev/null 2>&1
check "non-dry-run DOES run cmd"             '[[ $SENTINEL -eq 1 ]]'

# The config write, when routed through iwz_run_step under dry-run, writes NO
# file — proving the wizard's commit step mutates nothing in dry-run.
reset_iwz; IWZ_DRY_RUN=1
rm -f "$TMP/dry.conf"
iwz_run_step "write config" iwz_write_config "$TMP/dry.conf" >/dev/null 2>&1
check "dry-run: install.conf NOT written"    '[[ ! -f "$TMP/dry.conf" ]]'

reset_iwz; IWZ_DRY_RUN=0
iwz_run_step "write config" iwz_write_config "$TMP/wet.conf" >/dev/null 2>&1
check "non-dry-run: install.conf written"    '[[ -f "$TMP/wet.conf" ]]'

# ── GPU auto-detect default (lspci) ───────────────────────────────
echo "== GPU flavor auto-detect =="

lspci() { echo "01:00.0 VGA compatible controller: NVIDIA Corporation GA104"; }
check "NVIDIA → nvidia-open default"  '[[ "$(iwz_detect_gpu_flavor)" == "nvidia-open" ]]'
lspci() { echo "07:00.0 VGA compatible controller: Advanced Micro Devices Radeon"; }
check "AMD/Radeon → amd"              '[[ "$(iwz_detect_gpu_flavor)" == "amd" ]]'
lspci() { echo "00:02.0 VGA compatible controller: Intel Corporation UHD Graphics"; }
check "Intel → intel"                 '[[ "$(iwz_detect_gpu_flavor)" == "intel" ]]'
lspci() { echo "00:1f.0 ISA bridge: nothing graphical here"; }
check "unknown → nvidia-open default" '[[ "$(iwz_detect_gpu_flavor)" == "nvidia-open" ]]'
unset -f lspci

# ── UI backend selection ──────────────────────────────────────────
echo "== UI backend selection =="

unset IWZ_UI_FORCE 2>/dev/null || true
# GUI: kdialog present (as a function → command -v finds it) AND a display.
kdialog() { :; }
DISPLAY=":0"
unset WAYLAND_DISPLAY 2>/dev/null || true
check "gui when kdialog + DISPLAY"   '[[ "$(iwz_detect_ui)" == "gui" ]]'
unset -f kdialog
unset DISPLAY

# TUI: whiptail present, no gui.
whiptail() { :; }
check "tui when whiptail, no gui"    '[[ "$(iwz_detect_ui)" == "tui" ]]'
unset -f whiptail

# read: nothing present. Empty PATH hides any host kdialog/whiptail/dialog
# binaries; no functions are defined and DISPLAY is unset.
check "read when no gui/tui backend" \
    '[[ "$(PATH="" ; unset DISPLAY WAYLAND_DISPLAY 2>/dev/null; iwz_detect_ui)" == "read" ]]'

# IWZ_UI_FORCE overrides everything (used by these very tests elsewhere).
check "IWZ_UI_FORCE overrides detection" '[[ "$(IWZ_UI_FORCE=tui iwz_detect_ui)" == "tui" ]]'

# ── Firstboot applier: per-key command dispatch + config deletion ─
echo "== Firstboot apply (full config) =="

CALLS="$TMP/calls.log"
: > "$CALLS"
hostnamectl() { echo "hostnamectl $*" >> "$CALLS"; return 0; }
useradd()     { echo "useradd $*" >> "$CALLS"; return 0; }
chpasswd()    { cat >/dev/null 2>&1; echo "chpasswd $*" >> "$CALLS"; return 0; }
id()          { return 1; }   # user "does not exist" → triggers useradd
getent()      { echo "x:x:1000:1000:x:$TMP/home:/bin/bash"; return 0; }
systemctl()   { echo "systemctl $*" >> "$CALLS"; return 0; }
powos()       { echo "powos $*" >> "$CALLS"; return 0; }
chown()       { return 0; }

# Build a full config the applier will consume.
POWOS_INSTALL_CONF="$TMP/fb.conf"
POWOS_AI_CONF_DIR="$TMP/ai"
cat > "$POWOS_INSTALL_CONF" <<EOF
POWOS_HOSTNAME='testhost'
POWOS_USERNAME='testuser'
POWOS_PASSWORD_HASH='\$6\$salt\$hashvalue'
POWOS_SSH_ENABLE='1'
POWOS_SSH_KEY='ssh-ed25519 AAAAKEY tester@box'
POWOS_RAMBOOT='installed'
POWOS_AI_PROVIDER='claude'
POWOS_AI_KEY='sk-fb-999'
POWOS_RESTORE_URL='git@example.com:me/state.git'
EOF

fb_main >/dev/null 2>&1

check "hostnamectl set-hostname called"   'grep -q "hostnamectl set-hostname testhost" "$CALLS"'
check "useradd creates the user"          'grep -q "useradd .*testuser" "$CALLS"'
check "chpasswd -e sets hashed password"  'grep -q "chpasswd -e" "$CALLS"'
check "sshd enabled when SSH_ENABLE=1"    'grep -q "systemctl enable --now sshd" "$CALLS"'
check "SSH authorized key written"        'grep -q "ssh-ed25519 AAAAKEY tester@box" "$TMP/home/.ssh/authorized_keys"'
check "ramboot enable called via powos"   'grep -q "powos ramboot enable" "$CALLS"'
check "restore: backup setup called"      'grep -q "powos backup setup git@example.com:me/state.git" "$CALLS"'
check "restore: backup pull called"       'grep -q "powos backup pull" "$CALLS"'
check "AI provider config written"        'grep -q "AI_DEFAULT_CLIENT=\"claude\"" "$TMP/ai/provider.conf"'
check "AI key stored"                     'grep -q "sk-fb-999" "$TMP/ai/credentials.conf"'
check "install.conf DELETED after apply"  '[[ ! -f "$POWOS_INSTALL_CONF" ]]'

# ── Firstboot applier: minimal config leaves optional tools alone ─
echo "== Firstboot apply (minimal config) =="

: > "$CALLS"
POWOS_INSTALL_CONF="$TMP/fb-min.conf"
POWOS_AI_CONF_DIR="$TMP/ai-min"
cat > "$POWOS_INSTALL_CONF" <<EOF
POWOS_HOSTNAME='minihost'
POWOS_USERNAME='mini'
POWOS_PASSWORD_HASH='\$6\$s\$h'
POWOS_SSH_ENABLE='0'
POWOS_SSH_KEY=''
POWOS_RAMBOOT='off'
POWOS_AI_PROVIDER='none'
POWOS_AI_KEY=''
POWOS_RESTORE_URL=''
EOF

fb_main >/dev/null 2>&1

check "minimal: hostname still applied"       'grep -q "hostnamectl set-hostname minihost" "$CALLS"'
check "minimal: RAM boot NOT triggered"       '! grep -q "ramboot enable" "$CALLS"'
check "minimal: no backup/restore triggered"  '! grep -q "backup" "$CALLS"'
check "minimal: no AI provider.conf written"  '[[ ! -f "$TMP/ai-min/provider.conf" ]]'
check "minimal: sshd not enabled"             '! grep -q "enable --now sshd" "$CALLS"'
check "minimal: install.conf deleted"         '[[ ! -f "$POWOS_INSTALL_CONF" ]]'

# Missing config: applier is a no-op and returns success (idempotent boots).
POWOS_INSTALL_CONF="$TMP/does-not-exist.conf"
fb_main >/dev/null 2>&1
check "missing config → clean no-op"          '[[ $? -eq 0 ]]'

unset -f hostnamectl useradd chpasswd id getent systemctl powos chown

# ── Summary ───────────────────────────────────────────────────────
echo
echo "== Results: $PASS passed, $FAIL failed =="
[[ $FAIL -eq 0 ]]
