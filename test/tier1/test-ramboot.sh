#!/bin/bash
# shellcheck disable=SC2016,SC2034
# test-ramboot.sh - Tier-1 unit tests for `powos ramboot` (lib/ramboot.sh).
#
# Runs on any Linux box AND in Git Bash (no root, no real disks, no /proc/*
# semantics) by shadowing the external tools and the live-system seams
# (rb_cmdline / rb_ram_total_kib / rb_os_size_kib / rb_is_installed /
# rb_karg_tool / rb_find_esp / rb_require_root) with bash functions.
#
# Covers the parts where a bug would be dangerous or user-visible: karg parsing,
# RAM-fit math, refusal on the USB live model, the exact kargs enable/disable
# emit, self-heal counter reset (a real temp file), status rendering per mode,
# dry-run gating of every mutating call, and --help exit code.
#
# It does NOT (cannot) validate the real copy-to-tmpfs boot — that needs the
# QEMU/hardware checklist. See the CONTRACT block in lib/ramboot.sh.
#
# Usage:  bash test/tier1/test-ramboot.sh
#   Docker: docker exec powos bash /test/tier1/test-ramboot.sh

set -uo pipefail

# Locate the lib relative to this test, or the installed path.
LIB="/usr/lib/powos/ramboot.sh"
if [[ ! -f "$LIB" ]]; then
    LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" && pwd)/ramboot.sh"
fi

PASS=0; FAIL=0
ok()   { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL - $1"; FAIL=$((FAIL+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 (expected: $2)"; fi; }

echo "== Sourcing ramboot lib: $LIB =="
# shellcheck disable=SC1090
source "$LIB" || { echo "cannot source lib"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

reset_globals() { RB_DRY_RUN=0; RB_ASSUME_YES=0; RB_RAM=""; }

# ── Karg parsing (each mode from a mocked cmdline) ────────────────
echo "== Karg parsing =="

check "installed mode detected" \
    '[[ "$(rb_mode_from_cmdline "ro quiet rd.powos.ramboot.installed=1 rd.powos.ramsize=20G")" == "installed" ]]'
check "usb mode detected" \
    '[[ "$(rb_mode_from_cmdline "ro quiet rd.powos.ramboot=1 rd.powos.ramsize=8G")" == "usb" ]]'
check "off when no ramboot karg" \
    '[[ "$(rb_mode_from_cmdline "ro quiet root=LABEL=x")" == "off" ]]'
# The installed karg must NOT be misread as the usb auto karg.
check "installed karg not mistaken for usb" \
    '[[ "$(rb_mode_from_cmdline "rd.powos.ramboot.installed=1")" == "installed" ]]'
check "ramsize parsed from cmdline" \
    '[[ "$(rb_ramsize_from_cmdline "ro rd.powos.ramsize=20G quiet")" == "20G" ]]'
check "ramsize empty when unset" \
    '[[ -z "$(rb_ramsize_from_cmdline "ro quiet")" ]]'

# ── State-file parsing ────────────────────────────────────────────
echo "== State-file parsing =="

cat > "$TMP/state" <<'EOF'
POWOS_RAMBOOT=1
POWOS_RAMBOOT_MODE=installed-copy
POWOS_RAMBOOT_ATTEMPTS=2
POWOS_RAM_SIZE=20G
EOF
check "reads POWOS_RAMBOOT_MODE"      '[[ "$(rb_state_field "$TMP/state" POWOS_RAMBOOT_MODE)" == "installed-copy" ]]'
check "reads POWOS_RAMBOOT_ATTEMPTS"  '[[ "$(rb_state_field "$TMP/state" POWOS_RAMBOOT_ATTEMPTS)" == "2" ]]'
check "missing field returns nonzero" '! rb_state_field "$TMP/state" NOPE'

RB_STATE_FILE="$TMP/state"
check "active mode from state file"   '[[ "$(rb_active_mode)" == "installed-copy" ]]'
RB_STATE_FILE="$TMP/does-not-exist"
check "active mode off when no state" '[[ "$(rb_active_mode)" == "off" ]]'

# ── meminfo parsing ───────────────────────────────────────────────
echo "== meminfo parsing =="
MEMINFO=$'MemTotal:       32768000 kB\nMemFree:  10000000 kB\nMemAvailable: 20000000 kB'
check "MemTotal parsed (KiB)" '[[ "$(rb_meminfo_total_kib "$MEMINFO")" == "32768000" ]]'

# ── RAM-fit math (fits / doesn't-fit tiers) ───────────────────────
echo "== RAM-fit math =="
# Constants: safety + headroom are each 4 GiB (4*1048576 KiB).
GIB=1048576
# Tier A: 8 GiB OS, 32 GiB RAM → fits comfortably.
check "8G OS in 32G RAM fits"        'rb_fits $((8*GIB)) $((32*GIB))'
# Tier B: 8 GiB OS, 10 GiB RAM → 8+4 reserve = 12 > 10 → does NOT fit.
check "8G OS in 10G RAM does NOT fit" '! rb_fits $((8*GIB)) $((10*GIB))'
# Tier C: exactly on the boundary (mem == os + safety) → strict '>' fails.
check "boundary (os+safety == mem) does NOT fit" '! rb_fits $((8*GIB)) $((12*GIB))'
# Default size = min(os+headroom, mem-safety).
# 8G OS, 32G RAM: want=12G, cap=28G → 12G (in KiB).
check "default ram = os+headroom when it fits under cap" \
    '[[ "$(rb_default_ram_kib $((8*GIB)) $((32*GIB)))" == "$((12*GIB))" ]]'
# 20G OS, 26G RAM: want=24G, cap=22G → capped to 22G.
check "default ram capped to mem-safety" \
    '[[ "$(rb_default_ram_kib $((20*GIB)) $((26*GIB)))" == "$((22*GIB))" ]]'
check "KiB→GiB floor"                '[[ "$(rb_kib_to_gib_floor $((12*GIB + 500)))" == "12" ]]'

# ── Size normalisation / conversion ───────────────────────────────
echo "== Size string handling =="
check "bare number → NG"     '[[ "$(rb_normalize_size 20)"   == "20G" ]]'
check "lowercase g → NG"     '[[ "$(rb_normalize_size 20g)"  == "20G" ]]'
check "M passes through"     '[[ "$(rb_normalize_size 512M)" == "512M" ]]'
check "garbage rejected"     '! rb_normalize_size "big"'
check "20G → KiB"            '[[ "$(rb_size_to_kib 20G)" == "$((20*GIB))" ]]'
check "512M → KiB"           '[[ "$(rb_size_to_kib 512M)" == "$((512*1024))" ]]'

# ── Self-heal counter reads ───────────────────────────────────────
echo "== Self-heal counter =="
check "missing counter file → 0" '[[ "$(rb_read_attempts "$TMP/nope")" == "0" ]]'
echo "2" > "$TMP/attempts"
check "counter file read"        '[[ "$(rb_read_attempts "$TMP/attempts")" == "2" ]]'
printf '3\n' > "$TMP/attempts2"
check "counter ignores newline"  '[[ "$(rb_read_attempts "$TMP/attempts2")" == "3" ]]'

# ── enable refuses on the USB live model ──────────────────────────
echo "== enable refuses on USB model =="
reset_globals
# USB model: active mode says usb.
cat > "$TMP/usb-state" <<'EOF'
POWOS_RAMBOOT_MODE=usb
EOF
RB_STATE_FILE="$TMP/usb-state"
rb_cmdline() { echo "ro quiet rd.powos.ramboot=1"; }
rb_have_powos_data() { return 0; }
out=$(rb_enable 2>&1); rc=$?
check "enable exits nonzero on USB model" '[[ $rc -ne 0 ]]'
check "enable says already runs from RAM" 'echo "$out" | grep -qi "already runs from RAM"'
unset -f rb_cmdline rb_have_powos_data
RB_STATE_FILE="$TMP/does-not-exist"

# ── enable sets the right kargs (rpm-ostree) ──────────────────────
echo "== enable sets kargs via rpm-ostree =="
reset_globals; RB_ASSUME_YES=1
# Not the USB model; installed; big RAM; small OS; rpm-ostree present.
rb_cmdline() { echo "ro quiet root=LABEL=x"; }
rb_have_powos_data() { return 1; }
rb_is_installed() { return 0; }
rb_require_root() { return 0; }
rb_ram_total_kib() { echo $((32*GIB)); }
rb_os_size_kib()   { echo $((8*GIB));  }
rpm-ostree() { echo "$*" >> "$TMP/ro.log"; }
: > "$TMP/ro.log"
out=$(rb_enable 2>&1); rc=$?
check "enable succeeds on installed system"        '[[ $rc -eq 0 ]]'
check "rpm-ostree appended the installed karg" \
    'grep -q -- "kargs --append-if-missing=rd.powos.ramboot.installed=1" "$TMP/ro.log"'
check "rpm-ostree set ramsize (default 12G)" \
    'grep -q -- "--append=rd.powos.ramsize=12G" "$TMP/ro.log"'
check "USB auto karg rd.powos.ramboot=1 is NEVER emitted" \
    '! grep -Eq -- "(^| )rd.powos.ramboot=1( |$)" "$TMP/ro.log"'

# --ram override honoured (and validated against the cap).
: > "$TMP/ro.log"
reset_globals; RB_ASSUME_YES=1; RB_RAM=20G
out=$(rb_enable 2>&1); rc=$?
check "--ram override sets requested size"  'grep -q -- "--append=rd.powos.ramsize=20G" "$TMP/ro.log"'

# --ram that exceeds the safe cap is refused.
: > "$TMP/ro.log"
reset_globals; RB_ASSUME_YES=1; RB_RAM=64G   # cap = 32-4 = 28G
out=$(rb_enable 2>&1); rc=$?
check "--ram over cap refused"       '[[ $rc -ne 0 ]]'
check "over-cap refusal ran no tool" '[[ ! -s "$TMP/ro.log" ]]'

# ── enable refuses when the OS doesn't fit ────────────────────────
echo "== enable refuses when OS doesn't fit =="
reset_globals; RB_ASSUME_YES=1
rb_ram_total_kib() { echo $((10*GIB)); }
rb_os_size_kib()   { echo $((8*GIB));  }
: > "$TMP/ro.log"
out=$(rb_enable 2>&1); rc=$?
check "no-fit refuses"           '[[ $rc -ne 0 ]]'
check "no-fit message shown"     'echo "$out" | grep -qi "will not fit"'
check "no-fit ran no karg tool"  '[[ ! -s "$TMP/ro.log" ]]'
# restore a fitting RAM for later tests
rb_ram_total_kib() { echo $((32*GIB)); }
rb_os_size_kib()   { echo $((8*GIB));  }

# ── enable dry-run performs ZERO mutating calls ───────────────────
echo "== enable dry-run mutates nothing =="
reset_globals; RB_DRY_RUN=1
: > "$TMP/ro.log"
out=$(rb_enable 2>&1); rc=$?
check "dry-run enable succeeds"        '[[ $rc -eq 0 ]]'
check "dry-run enable ran NO karg tool" '[[ ! -s "$TMP/ro.log" ]]'
check "dry-run announces no change"    'echo "$out" | grep -qi "nothing was changed"'
unset -f rpm-ostree rb_cmdline rb_have_powos_data rb_is_installed rb_require_root rb_ram_total_kib rb_os_size_kib

# ── enable via bootc when rpm-ostree is absent ────────────────────
echo "== enable falls back to bootc =="
reset_globals; RB_ASSUME_YES=1
rb_cmdline() { echo "ro quiet root=LABEL=x"; }
rb_have_powos_data() { return 1; }
rb_is_installed() { return 0; }
rb_require_root() { return 0; }
rb_ram_total_kib() { echo $((32*GIB)); }
rb_os_size_kib()   { echo $((8*GIB));  }
bootc() { echo "$*" >> "$TMP/bootc.log"; }
: > "$TMP/bootc.log"
out=$(rb_enable 2>&1); rc=$?
check "bootc path succeeds"          '[[ $rc -eq 0 ]]'
check "bootc appended installed karg" 'grep -q -- "kargs --append-if-missing rd.powos.ramboot.installed=1" "$TMP/bootc.log"'

# ── disable removes the kargs ─────────────────────────────────────
echo "== disable removes kargs =="
reset_globals
: > "$TMP/bootc.log"
out=$(rb_disable 2>&1); rc=$?
check "disable succeeds"             '[[ $rc -eq 0 ]]'
check "disable deletes installed karg" 'grep -q -- "--delete-if-present rd.powos.ramboot.installed=1" "$TMP/bootc.log"'
check "disable deletes ramsize"        'grep -q -- "--delete-if-present rd.powos.ramsize" "$TMP/bootc.log"'

# disable dry-run mutates nothing.
reset_globals; RB_DRY_RUN=1
: > "$TMP/bootc.log"
out=$(rb_disable 2>&1); rc=$?
check "disable dry-run runs no tool"  '[[ ! -s "$TMP/bootc.log" ]]'
unset -f bootc rb_cmdline rb_have_powos_data rb_is_installed rb_require_root rb_ram_total_kib rb_os_size_kib

# ── reset removes the counter file (real temp file) ───────────────
echo "== reset clears the self-heal counter =="
mkdir -p "$TMP/esp/powos"
echo "3" > "$TMP/esp/powos/ramboot-attempts"
rb_find_esp() { echo "$TMP/esp"; }
rb_require_root() { return 0; }

# dry-run must NOT remove the file.
reset_globals; RB_DRY_RUN=1
rb_reset >/dev/null 2>&1
check "reset dry-run keeps counter file" '[[ -f "$TMP/esp/powos/ramboot-attempts" ]]'

# real run removes it.
reset_globals
rb_reset >/dev/null 2>&1
check "reset removes counter file"       '[[ ! -f "$TMP/esp/powos/ramboot-attempts" ]]'

# reset with no file is a clean no-op success.
reset_globals
rb_reset >/dev/null 2>&1; rc=$?
check "reset with no counter is success" '[[ $rc -eq 0 ]]'
unset -f rb_find_esp rb_require_root

# ── status renders each mode ──────────────────────────────────────
echo "== status renders each mode =="
rb_ram_total_kib() { echo $((32*GIB)); }
rb_os_size_kib()   { echo $((8*GIB));  }
rb_find_esp() { echo "$TMP/esp"; }
mkdir -p "$TMP/esp/powos"; echo "0" > "$TMP/esp/powos/ramboot-attempts"

# usb model
cat > "$TMP/st-usb" <<'EOF'
POWOS_RAMBOOT_MODE=usb
EOF
RB_STATE_FILE="$TMP/st-usb"
rb_cmdline() { echo "ro rd.powos.ramboot=1 rd.powos.ramsize=8G"; }
out=$(rb_status 2>&1)
check "status usb: shows USB live model" 'echo "$out" | grep -qi "USB live model"'
check "status usb: nothing to enable"    'echo "$out" | grep -qi "Nothing to enable"'

# installed-copy active
cat > "$TMP/st-inst" <<'EOF'
POWOS_RAMBOOT_MODE=installed-copy
EOF
RB_STATE_FILE="$TMP/st-inst"
rb_cmdline() { echo "ro rd.powos.ramboot.installed=1 rd.powos.ramsize=20G"; }
out=$(rb_status 2>&1)
check "status installed: shows copy-to-tmpfs" 'echo "$out" | grep -qi "installed copy-to-tmpfs"'
check "status installed: offers disable"      'echo "$out" | grep -qi "ramboot disable"'

# off / disk-backed
RB_STATE_FILE="$TMP/none"
rb_cmdline() { echo "ro quiet root=LABEL=x"; }
out=$(rb_status 2>&1)
check "status off: disk-backed"          'echo "$out" | grep -qi "disk-backed"'
check "status off: offers enable"        'echo "$out" | grep -qi "ramboot enable"'
check "status off: reports RAM fit"      'echo "$out" | grep -qi "fits"'

# self-heal backed-off state
echo "3" > "$TMP/esp/powos/ramboot-attempts"
out=$(rb_status 2>&1)
check "status shows auto-skip after max attempts" 'echo "$out" | grep -qi "Auto-skipped"'
unset -f rb_cmdline rb_ram_total_kib rb_os_size_kib rb_find_esp

# ── cmd_ramboot dispatch / --help ─────────────────────────────────
echo "== dispatch and --help =="
cmd_ramboot --help >/dev/null 2>&1
check "bare --help exits 0"      '[[ $? -eq 0 ]]'
cmd_ramboot help >/dev/null 2>&1
check "help subcommand exits 0"  '[[ $? -eq 0 ]]'
cmd_ramboot -h >/dev/null 2>&1
check "-h exits 0"               '[[ $? -eq 0 ]]'
cmd_ramboot bogus >/dev/null 2>&1
check "unknown subcommand exits 1" '[[ $? -eq 1 ]]'
cmd_ramboot enable --bogus-opt >/dev/null 2>&1
check "unknown option exits 1"     '[[ $? -eq 1 ]]'

# ── Summary ───────────────────────────────────────────────────────
echo
echo "== Results: $PASS passed, $FAIL failed =="
[[ $FAIL -eq 0 ]]
