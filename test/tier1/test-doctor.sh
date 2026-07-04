#!/bin/bash
# shellcheck disable=SC2016,SC2317
# (assertions are single-quoted on purpose — check() eval's them later. SC2317:
#  shadow functions look "unreachable" to shellcheck but are called via seams.)
# test-doctor.sh - Tier-1 unit tests for `powos doctor`, the AI boot debugger.
#
# Runs on any box (Git Bash on Windows OR real Linux, no root, no real disks) by
# shadowing every external tool (journalctl/systemctl/dmesg/lsblk/findmnt/blkid/
# mount/umount) and every AI/network seam with bash functions. Covers the parts
# where a bug would be dangerous or embarrassing:
#   - bundle assembly includes every required section
#   - --target auto selects a NON-live disk and mounts it READ-ONLY (+ unmounts)
#   - credential resolution tries 4 sources in order and stops at the first hit
#   - --offline saves a bundle + prints re-run instructions, makes NO AI call
#   - secrets are NEVER printed
#   - --dry-run performs zero mounts and zero AI calls
#   - --help exits 0
#
# Usage:  bash test/tier1/test-doctor.sh
#   Docker: docker exec powos bash /test/tier1/test-doctor.sh

set -uo pipefail

LIB="/usr/lib/powos/doctor.sh"
if [[ ! -f "$LIB" ]]; then
    LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" && pwd)/doctor.sh"
fi

PASS=0; FAIL=0
ok()   { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL - $1"; FAIL=$((FAIL+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 (expected: $2)"; fi; }

echo "== Sourcing doctor lib: $LIB =="
# shellcheck disable=SC1090
source "$LIB" || { echo "cannot source lib"; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export DOC_LOG_DIR="$WORK/log"
export DOC_RUN_DIR="$WORK/run"
export DOC_AI_SESSION_DIR="$WORK/sessions"
export DOC_TS="20260704-000000"      # deterministic bundle name

# Neutralise the network + real credential locations so nothing escapes the box.
# These are exported so re-sourcing the lib (reload_lib) keeps the test values
# (the lib reads them via ${VAR:-default}).
export DOC_LIVE_CRED_FILE="$WORK/none-live"
export DOC_HOME_CRED_FILE="$WORK/none-home"
export DOC_BACKUP_CRED_FILE="$WORK/none-backup"
unset ANTHROPIC_API_KEY 2>/dev/null || true

# Re-source the lib to restore its REAL functions after a test has shadowed a
# lib-internal one. (Shadowing overwrites the original, so `unset -f` would
# leave nothing behind — only a reload brings the real implementation back.)
reload_lib() { source "$LIB"; doc_network_ok() { return 1; }; }
doc_network_ok() { return 1; }

# ── Bundle assembly ───────────────────────────────────────────────
echo "== Bundle assembly includes every section =="

# Shadow every collector with a distinctive sentinel.
doc_cmd_cmdline()          { echo "SENT_CMDLINE rd.powos.ramboot=1"; }
doc_cmd_journal_current()  { echo "SENT_JOURNAL_CURRENT"; }
doc_cmd_journal_previous() { echo "SENT_JOURNAL_PREV"; }
doc_cmd_failed_units()     { echo "SENT_FAILED_UNIT.service"; }
doc_cmd_dmesg()            { echo "SENT_DMESG_ERR"; }
doc_collect_powos_state()  { echo "SENT_POWOS_STATE"; }
doc_collect_esp_counter()  { echo "SENT_ESP_COUNTER"; }

DOC_TARGET=""
bundle_file=$(doc_write_bundle)
bundle=$(cat "$bundle_file")

check "bundle file lands at deterministic path" \
    '[[ "$bundle_file" == "$DOC_LOG_DIR/doctor-20260704-000000.log" ]]'
check "section: /proc/cmdline header present"   'echo "$bundle" | grep -q -- "----- /proc/cmdline -----"'
check "section: current boot journal (-b)"      'echo "$bundle" | grep -q "journalctl -b"'
check "section: previous failed boot (-b -1)"   'echo "$bundle" | grep -q "journalctl -b -1"'
check "section: failed units"                   'echo "$bundle" | grep -q "systemctl --failed"'
check "section: dmesg errors"                   'echo "$bundle" | grep -qi "dmesg"'
check "section: PowOS runtime state"            'echo "$bundle" | grep -q "/run/powos"'
check "section: ESP self-heal counter"          'echo "$bundle" | grep -q "ESP self-heal counter"'
check "cmdline collector content captured"      'echo "$bundle" | grep -q "SENT_CMDLINE"'
check "prev-boot collector content captured"    'echo "$bundle" | grep -q "SENT_JOURNAL_PREV"'
check "failed-units collector content captured" 'echo "$bundle" | grep -q "SENT_FAILED_UNIT.service"'
check "state collector content captured"        'echo "$bundle" | grep -q "SENT_POWOS_STATE"'
check "no target section without --target"      '! echo "$bundle" | grep -q "Target install"'

# ── PowOS runtime state collection (real files) ───────────────────
echo "== PowOS runtime state reads /run/powos files =="
reload_lib   # restore the real collectors (bundle test shadowed them)
mkdir -p "$DOC_RUN_DIR"
echo "POWOS_RAMBOOT_MODE=usb" > "$DOC_RUN_DIR/ramboot-state"
echo '{"consecutive_failures":3}' > "$DOC_RUN_DIR/layer-sync-status.json"
state_out=$(doc_collect_powos_state)
check "state collector shows ramboot-state"     'echo "$state_out" | grep -q "POWOS_RAMBOOT_MODE=usb"'
check "state collector shows layer-sync-status" 'echo "$state_out" | grep -q "consecutive_failures"'

# ── --target auto: non-live disk, mounted READ-ONLY, then unmounted ──
echo "== --target auto selects a non-live disk, mounts ro, unmounts =="

MOUNT_LOG="$WORK/mount.log"; : > "$MOUNT_LOG"
findmnt() { echo "/dev/sdb2"; }          # live root is on /dev/sdb
lsblk()   {
    # doc_list_partitions calls: lsblk -pnro NAME,TYPE
    cat <<'LSBLK'
/dev/sda1 part
/dev/sda2 part
/dev/sdb1 part
/dev/sdb2 part
LSBLK
}
blkid() {
    # emulate `blkid -o value -s LABEL <dev>` / `-s PARTLABEL <dev>`
    case "${!#}" in
        /dev/sda2) echo "PowOS" ;;   # the broken internal install
        *)         echo "" ;;
    esac
}
mount()  { echo "mount $*" >> "$MOUNT_LOG"; return 0; }
umount() { echo "umount $*" >> "$MOUNT_LOG"; return 0; }

DOC_DRY_RUN=0
target_dev=$(doc_find_target_auto)
check "auto picks internal /dev/sda2 (not live)" '[[ "$target_dev" == "/dev/sda2" ]]'
check "auto never picks the live device /dev/sdb" '[[ "$target_dev" != /dev/sdb* ]]'

DOC_TARGET="auto"
tgt_out=$(doc_collect_target)
check "target mounted read-only (ro flag)"      'grep -q "mount -o ro /dev/sda2" "$MOUNT_LOG"'
check "target was unmounted afterward"          'grep -q "umount " "$MOUNT_LOG"'
check "target collection reports the device"    'echo "$tgt_out" | grep -q "target device: /dev/sda2"'

unset -f findmnt lsblk blkid mount umount

# ── Credential resolution: order + stop-at-first-hit ──────────────
echo "== Credential resolution tries 4 sources in order, stops at first hit =="

CRED_LOG="$WORK/cred.log"

# All four shadowed to RECORD their call and return miss by default.
doc_creds_from_target() { echo "target" >> "$CRED_LOG"; return 1; }
doc_creds_from_live()   { echo "live"   >> "$CRED_LOG"; return 1; }
doc_creds_from_backup() { echo "backup" >> "$CRED_LOG"; return 1; }
doc_creds_from_prompt() { echo "prompt" >> "$CRED_LOG"; return 1; }

# (a) target wins → live/backup/prompt must NOT be consulted.
: > "$CRED_LOG"
doc_creds_from_target() { echo "target" >> "$CRED_LOG"; DOC_AI_CRED="x"; return 0; }
src=$(doc_resolve_ai_creds)
check "first source (target) wins"              '[[ "$src" == "target" ]]'
check "stops at target: live never called"      '! grep -q "^live$" "$CRED_LOG"'
check "stops at target: backup never called"    '! grep -q "^backup$" "$CRED_LOG"'
check "stops at target: prompt never called"    '! grep -q "^prompt$" "$CRED_LOG"'

# (b) target misses, live wins → backup/prompt not consulted, order preserved.
: > "$CRED_LOG"
doc_creds_from_target() { echo "target" >> "$CRED_LOG"; return 1; }
doc_creds_from_live()   { echo "live"   >> "$CRED_LOG"; DOC_AI_CRED="x"; return 0; }
src=$(doc_resolve_ai_creds)
check "falls through to live when target misses" '[[ "$src" == "live" ]]'
check "target consulted before live"             '[[ "$(head -1 "$CRED_LOG")" == "target" ]]'
check "backup not called once live hits"         '! grep -q "^backup$" "$CRED_LOG"'
check "prompt not called once live hits"         '! grep -q "^prompt$" "$CRED_LOG"'

# (c) only backup has creds → tries target, live, backup in that order.
: > "$CRED_LOG"
doc_creds_from_live()   { echo "live"   >> "$CRED_LOG"; return 1; }
doc_creds_from_backup() { echo "backup" >> "$CRED_LOG"; DOC_AI_CRED="x"; return 0; }
src=$(doc_resolve_ai_creds)
check "falls through to backup"                  '[[ "$src" == "backup" ]]'
check "order target,live,backup preserved"       '[[ "$(tr "\n" "," < "$CRED_LOG")" == "target,live,backup," ]]'

# (d) nothing resolves → non-zero, empty source.
: > "$CRED_LOG"
doc_creds_from_backup() { echo "backup" >> "$CRED_LOG"; return 1; }
src=$(doc_resolve_ai_creds); rc=$?
check "no source → resolver fails"               '[[ $rc -ne 0 ]]'
check "no source → empty output"                 '[[ -z "$src" ]]'

reload_lib   # restore the real doc_creds_from_* (the secret test needs them)
DOC_TARGET=""; DOC_TARGET_MP=""   # so real doc_creds_from_target misses cleanly

# ── Real live-cred reader + secret never printed ──────────────────
echo "== Secret is never printed =="

FAKE_KEY="sk-ant-FAKE-PLANTED-SECRET-do-not-leak-0000"
echo "$FAKE_KEY" > "$DOC_LIVE_CRED_FILE"

# Resolver output (source name) must never contain the secret. Capture in a
# subshell only for the output assertions.
res_out=$(doc_resolve_ai_creds)
check "resolver reports source 'live'"           '[[ "$res_out" == "live" ]]'
check "resolver output does NOT contain secret"  '! echo "$res_out" | grep -q "$FAKE_KEY"'

# Run it again in the CURRENT shell (no command substitution) so we can inspect
# the side effect: the secret loaded into DOC_AI_CRED but never echoed.
DOC_AI_CRED=""
doc_resolve_ai_creds >/dev/null 2>&1
check "secret WAS loaded (into DOC_AI_CRED)"      '[[ "$DOC_AI_CRED" == "$FAKE_KEY" ]]'

# Exercise the full --ai path with a mocked invoke; assert the whole transcript
# never leaks the key. Run in the current shell (redirect to a file, not $(...))
# so the ANTHROPIC_API_KEY export is observable.
AI_LOG="$WORK/ai.log"; : > "$AI_LOG"
doc_network_ok()  { return 0; }
doc_ai_invoke()   { echo "invoke $*" >> "$AI_LOG"; }   # records argv, not env
bundle_file=$(doc_write_bundle)
DOC_AI=1; DOC_OFFLINE=0; DOC_DRY_RUN=0
doc_run_ai "$bundle_file" > "$WORK/airun.out" 2>&1
full_out=$(cat "$WORK/airun.out")
check "full --ai transcript never prints secret" '! echo "$full_out" | grep -q "$FAKE_KEY"'
check "invoke argv never carries the secret"     '! grep -q "$FAKE_KEY" "$AI_LOG"'
check "secret exported to env for the client"    '[[ "${ANTHROPIC_API_KEY:-}" == "$FAKE_KEY" ]]'
check "AI actually invoked when creds+network ok" '[[ -s "$AI_LOG" ]]'
rm -f "$DOC_LIVE_CRED_FILE"
unset ANTHROPIC_API_KEY

# ── Session continuation (--continue vs fresh) ────────────────────
echo "== --ai continues a prior doctor session, else starts fresh =="

: > "$AI_LOG"
mkdir -p "$DOC_AI_SESSION_DIR"
# No session file yet → fresh --session.
DOC_AI_CRED="dummy"; DOC_AI=1
DOC_LIVE_CRED_FILE="$WORK/none-live2"     # force creds via the resolver seam
doc_creds_from_live() { DOC_AI_CRED="dummy"; return 0; }
b2=$(doc_write_bundle); : > "$AI_LOG"
doc_run_ai "$b2" >/dev/null 2>&1
check "fresh run uses --session (no prior)"      'grep -q -- "--session $DOC_SESSION_NAME" "$AI_LOG"'
# Now a session file exists → --continue.
echo '{}' > "$DOC_AI_SESSION_DIR/$DOC_SESSION_NAME.json"
: > "$AI_LOG"
doc_run_ai "$b2" >/dev/null 2>&1
check "second run uses --continue (prior exists)" 'grep -q -- "--continue" "$AI_LOG"'
rm -f "$DOC_AI_SESSION_DIR/$DOC_SESSION_NAME.json"
reload_lib   # restore real doc_creds_from_live

# ── --offline: bundle saved, instructions printed, NO AI call ─────
echo "== --offline saves bundle + prints re-run steps, makes no AI call =="

: > "$AI_LOG"
doc_ai_invoke() { echo "invoke $*" >> "$AI_LOG"; }
b3=$(doc_write_bundle)
off_out=$(DOC_OFFLINE=1 doc_run_ai "$b3" 2>&1)
check "offline makes NO AI call"                 '[[ ! -s "$AI_LOG" ]]'
check "offline prints the bundle path"           'echo "$off_out" | grep -qF "$b3"'
check "offline prints how to re-run"             'echo "$off_out" | grep -q "powos ai --agent health"'

# ── --dry-run: zero mounts, zero AI calls ─────────────────────────
echo "== --dry-run performs zero mounts and zero AI calls =="

: > "$MOUNT_LOG"; : > "$AI_LOG"
findmnt() { echo "/dev/sdb2"; }
lsblk()   { printf '/dev/sda2 part\n'; }
blkid()   { echo "PowOS"; }
mount()   { echo "mount $*" >> "$MOUNT_LOG"; return 0; }
umount()  { echo "umount $*" >> "$MOUNT_LOG"; return 0; }
doc_ai_invoke() { echo "invoke $*" >> "$AI_LOG"; }
doc_network_ok() { return 0; }
doc_creds_from_live() { DOC_AI_CRED="dummy"; return 0; }

dry_out=$(cmd_doctor --ai --target auto --dry-run 2>&1)
check "dry-run: no mount performed"              '[[ ! -s "$MOUNT_LOG" ]]'
check "dry-run: no AI invoke performed"          '[[ ! -s "$AI_LOG" ]]'
check "dry-run: announces plan-only"             'echo "$dry_out" | grep -qi "dry-run"'
check "dry-run: still writes a bundle"           'echo "$dry_out" | grep -q "Diagnostic bundle written"'
unset -f findmnt lsblk blkid mount umount
reload_lib   # restore real doc_creds_from_live / doc_ai_invoke

# ── status / help exit 0 (no games --help exit-1 bug) ─────────────
echo "== status / help / --help exit 0 =="

cmd_doctor --help >/dev/null 2>&1
check "--help exits 0"                           '[[ $? -eq 0 ]]'
cmd_doctor -h >/dev/null 2>&1
check "-h exits 0"                               '[[ $? -eq 0 ]]'
cmd_doctor help >/dev/null 2>&1
check "help exits 0"                             '[[ $? -eq 0 ]]'
cmd_doctor status >/dev/null 2>&1
check "status exits 0"                           '[[ $? -eq 0 ]]'
cmd_doctor --bogus >/dev/null 2>&1
check "unknown option exits 1"                   '[[ $? -eq 1 ]]'

# ── Summary ───────────────────────────────────────────────────────
echo
echo "== Results: $PASS passed, $FAIL failed =="
[[ $FAIL -eq 0 ]]
