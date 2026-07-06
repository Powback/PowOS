#!/bin/bash
# test-installer-variant.sh - Tier-1 static checks for the LEAN INSTALLER build
# variant + the boot/SELinux fixes. These are grep-level assertions over the
# source of truth (Containerfile, kargs.d, build-iso.sh) — they can run on any
# box (Git Bash included), no root, no build. They CANNOT prove the image boots
# to the wizard (that needs the QEMU checklist); they DO pin that the wiring is
# present and that the LIVE path stays intact.
#
# Usage:  bash test/tier1/test-installer-variant.sh
#   Docker: docker exec powos bash /powos/test/tier1/test-installer-variant.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)"
[[ -f "$ROOT/Containerfile" ]] || ROOT="/var/lib/powos/src"

CF="$ROOT/Containerfile"
KARGS_DIR="$ROOT/config/bootc/kargs.d"
INSTALLER_TOML="$ROOT/config/bootc/installer/50-powos-installer.toml"
CONSOLE_TOML="$KARGS_DIR/45-powos-console.toml"
BUILD="$ROOT/build/build-iso.sh"

PASS=0; FAIL=0
ok()   { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL - $1"; FAIL=$((FAIL+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 (expected: $2)"; fi; }

echo "== installer kargs.d (installer variant only) =="
check "installer toml exists (staged outside kargs.d)" '[[ -f "$INSTALLER_TOML" ]]'
check "installer kargs carry powos.install=1" 'grep -q "powos.install=1" "$INSTALLER_TOML"'
check "installer kargs force multi-user.target" 'grep -q "systemd.unit=multi-user.target" "$INSTALLER_TOML"'
check "installer kargs raise audit backlog" 'grep -q "audit_backlog_limit" "$INSTALLER_TOML"'
# Only the active `kargs =` line matters (comments legitimately mention ramboot
# to explain WHY it is absent).
check "installer kargs line does NOT bake ramboot" \
    '! grep "^kargs" "$INSTALLER_TOML" | grep -q "rd.powos.ramboot=1"'
check "installer toml is NOT under kargs.d (live never picks it up)" \
    '[[ ! -f "$KARGS_DIR/50-powos-installer.toml" ]]'

echo "== default kargs.d does NOT bake ramboot (scope-B: ramboot is opt-in) =="
# The default image — flashed to USB or installed — must boot a normal disk root.
# RAM boot hangs the boot on real hardware, so it is a `powos ramboot enable`
# opt-in and must NOT be baked into any file the default image picks up.
check "no default kargs.d file bakes rd.powos.ramboot=1" \
    '! grep -rq "rd.powos.ramboot=1" "$KARGS_DIR"'
check "old 50-powos-ramboot.toml is gone from kargs.d" \
    '[[ ! -f "$KARGS_DIR/50-powos-ramboot.toml" ]]'

echo "== console ordering (both variants) =="
check "console kargs.d exists" '[[ -f "$CONSOLE_TOML" ]]'
check "console kargs makes tty0 the last/primary console" 'grep -q "console=tty0" "$CONSOLE_TOML"'
# The console file must sort BEFORE the installer 50- file so tty0 lands after
# bib's console=ttyS0 but our own kargs stay after that — 45- < 50-.
check "console file sorts before the 50- kargs files" \
    '[[ "$(basename "$CONSOLE_TOML")" < "50-powos-installer.toml" ]]'

echo "== Containerfile installer wiring =="
check "Containerfile declares POWOS_INSTALLER arg" 'grep -q "ARG POWOS_INSTALLER" "$CF"'
check "Containerfile installs installer kargs when installer" \
    'grep -q "50-powos-installer.toml" "$CF"'
check "Containerfile masks firstboot-disk in installer variant" \
    'grep -q "systemctl mask powos-firstboot-disk.service" "$CF"'
check "Containerfile stages installer kargs outside kargs.d" \
    'grep -q "COPY config/bootc/installer/" "$CF"'

echo "== Containerfile SELinux hygiene (both variants) =="
check "Containerfile masks setroubleshootd" 'grep -q "systemctl mask setroubleshootd.service" "$CF"'
check "Containerfile relabels files with restorecon" 'grep -q "restorecon -RF /usr /etc /var" "$CF"'

echo "== build-iso.sh installer path =="
check "build-iso.sh has installer-usb mode" 'grep -q "installer-usb" "$BUILD"'
check "build-iso.sh passes POWOS_INSTALLER=1 build-arg" 'grep -q "POWOS_INSTALLER=1" "$BUILD"'
check "build-iso.sh produces powos-installer.raw" 'grep -q "powos-installer.raw" "$BUILD"'
check "build-iso.sh keeps the live raw name" 'grep -q "RAW_NAME=\"powos.raw\"" "$BUILD"'

echo ""
echo "== Results: $PASS passed, $FAIL failed =="
[[ $FAIL -eq 0 ]]
