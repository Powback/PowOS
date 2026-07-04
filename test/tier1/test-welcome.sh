#!/bin/bash
# test-welcome.sh - Tier-1 unit tests for bin/powos-welcome (first-run menu).
#
# Runs anywhere bash runs (incl. Git Bash on Windows): every external command
# (powos/sudo/konsole/passwd/kdialog) is shadowed by a recording mock on
# PATH, HOME points into a sandbox, and boot context is injected via
# POWOS_RUN_DIR. No real system calls, no root, no dialogs.
#
# Usage:  bash test/tier1/test-welcome.sh

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="/usr/bin/powos-welcome"
[[ -f "$BIN" ]] || BIN="$REPO/bin/powos-welcome"
DESK="$REPO/desktop/welcome"
[[ -d "$DESK" ]] || DESK="/usr/share/applications"

PASS=0; FAIL=0
ok()   { echo "  ok   - $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL - $1"; FAIL=$((FAIL+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 (expected: $2)"; fi; }

# ── Syntax check ──────────────────────────────────────────────────
echo "== Syntax (bash -n) =="
bash -n "$BIN" && ok "powos-welcome parses" || bad "powos-welcome has syntax errors"
bash -n "${BASH_SOURCE[0]}" && ok "test script parses" || bad "test script has syntax errors"

# ── Sandbox + mocks ───────────────────────────────────────────────
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

MOCK="$TMP/mock/bin"       # mocks WITHOUT kdialog (terminal fallback)
GUIBIN="$TMP/guibin"       # kdialog mock, added to PATH only for GUI tests
LIBDIR="$TMP/powoslib"     # fake POWOS_LIB with all command families
EMPTYLIB="$TMP/emptylib"   # fake POWOS_LIB of an older install (nothing)
RUN_LIVE="$TMP/run-live"   # fake /run/powos of a live/USB boot
RUN_INST="$TMP/run-inst"   # fake /run/powos of an installed machine
CALLS="$TMP/calls.log"

mkdir -p "$MOCK" "$GUIBIN" "$LIBDIR" "$EMPTYLIB" "$RUN_LIVE" "$RUN_INST"
touch "$RUN_LIVE/ramboot-state"
# powos_supports probes lib presence, mirroring bin/powos's on-demand sourcing
touch "$LIBDIR/install-system.sh" "$LIBDIR/games.sh" "$LIBDIR/windows.sh" "$LIBDIR/backup.sh"

cat > "$MOCK/powos" << 'EOF'
#!/bin/bash
echo "powos $*" >> "$CALLS_LOG"
[[ "${1:-}" == "status" ]] && echo "FAKE-POWOS-STATUS"
[[ "${1:-}" == "windows" && "${2:-}" == "status" ]] && echo "FAKE-WIN-STATUS"
# backup-status output is test-controlled; default simulates a fresh machine
[[ "${1:-}" == "backup" && "${2:-}" == "status" ]] && echo "${MOCK_BACKUP_STATUS:-No remote configured}"
exit 0
EOF
cat > "$MOCK/sudo" << 'EOF'
#!/bin/bash
echo "sudo $*" >> "$CALLS_LOG"
exec "$@"
EOF
cat > "$MOCK/konsole" << 'EOF'
#!/bin/bash
echo "konsole $*" >> "$CALLS_LOG"
exit 0
EOF
cat > "$MOCK/passwd" << 'EOF'
#!/bin/bash
echo "passwd $*" >> "$CALLS_LOG"
exit 0
EOF
cat > "$GUIBIN/kdialog" << 'EOF'
#!/bin/bash
echo "kdialog $*" >> "$CALLS_LOG"
exit 0
EOF
chmod +x "$MOCK"/* "$GUIBIN"/*

# run_welcome <home> <live|installed> <libdir> <stdin> [extra args...]
# Terminal-fallback run: no kdialog on PATH, no DISPLAY.
run_welcome() {
    local home="$1" ctx="$2" libdir="$3" input="$4"; shift 4
    local rundir="$RUN_INST"
    [[ "$ctx" == "live" ]] && rundir="$RUN_LIVE"
    mkdir -p "$home"
    printf '%b' "$input" | env \
        HOME="$home" USER=powos LOGNAME=powos \
        POWOS_LIB="$libdir" POWOS_RUN_DIR="$rundir" CALLS_LOG="$CALLS" \
        PATH="$MOCK:$PATH" XDG_CONFIG_HOME= DISPLAY= WAYLAND_DISPLAY= \
        bash "$BIN" "$@" 2>&1
}

# seq_ok "line1" "line2" ... — lines appear in CALLS in this relative order
seq_ok() {
    local prev=0 line n
    for line in "$@"; do
        n="$(grep -nx -- "$line" "$CALLS" | head -1 | cut -d: -f1)"
        [[ -n "$n" && "$n" -gt "$prev" ]] || return 1
        prev=$n
    done
}

# ── --autostart self-disable ──────────────────────────────────────
echo "== --autostart =="

HOME_A="$TMP/home-autostart"
mkdir -p "$HOME_A/.config/powos"
touch "$HOME_A/.config/powos/welcome-done"
: > "$CALLS"
start=$SECONDS
out="$(env HOME="$HOME_A" USER=powos CALLS_LOG="$CALLS" \
        PATH="$GUIBIN:$MOCK:$PATH" DISPLAY=:0 \
        POWOS_LIB="$LIBDIR" POWOS_RUN_DIR="$RUN_LIVE" XDG_CONFIG_HOME= \
        bash "$BIN" --autostart 2>&1)"
rc=$?
dur=$((SECONDS - start))
check "marker present: exits 0"                 '[[ $rc -eq 0 ]]'
check "marker present: fast (<5s)"              '[[ $dur -lt 5 ]]'
check "marker present: silent"                  '[[ -z "$out" ]]'
check "marker present: kdialog NEVER invoked"   '! grep -q "^kdialog" "$CALLS"'

HOME_B="$TMP/home-autostart2"
: > "$CALLS"
out="$(run_welcome "$HOME_B" live "$LIBDIR" "" --autostart)"
rc=$?
check "no marker + no display: exits 0 silently" '[[ $rc -eq 0 && -z "$out" ]]'

# ── Marker path ("Don't show this again") ─────────────────────────
echo "== welcome-done marker =="

HOME_C="$TMP/home-marker"
: > "$CALLS"
out="$(run_welcome "$HOME_C" live "$LIBDIR" "8\n")"
check "marker written under \$HOME/.config/powos" '[[ -f "$HOME_C/.config/powos/welcome-done" ]]'
check "confirms it won't auto-open again"         'grep -q "anytime" <<< "$out"'

# ── Boot-context menus ────────────────────────────────────────────
echo "== live vs installed context =="

HOME_D="$TMP/home-ctx"
out="$(run_welcome "$HOME_D" live "$LIBDIR" "q\n")"
check "live: menu offers Install PowOS to a disk" 'grep -q "Install PowOS to a disk" <<< "$out"'
check "live: no update item"                      '! grep -q "Check for updates" <<< "$out"'
check "live: restore item present"                'grep -q "Restore this machine from cloud backup" <<< "$out"'

out="$(run_welcome "$HOME_D" installed "$LIBDIR" "q\n")"
check "installed: install item hidden"            '! grep -q "Install PowOS to a disk" <<< "$out"'
check "installed: offers Check for updates"       'grep -q "Check for updates" <<< "$out"'
check "installed: restore item present"           'grep -q "Restore this machine from cloud backup" <<< "$out"'

# ── Menu actions dispatch the right commands ──────────────────────
echo "== menu actions (terminal path, mocked argv) =="

HOME_E="$TMP/home-actions"

: > "$CALLS"
run_welcome "$HOME_E" live "$LIBDIR" "3\ny\nq\n" > /dev/null
check "install → sudo powos install-system" 'grep -qx "sudo powos install-system" "$CALLS"'

: > "$CALLS"
# item 4 (games) → confirm → size prompt (512) → quit. `games create` REQUIRES
# --size, so welcome must collect and pass it.
run_welcome "$HOME_E" live "$LIBDIR" "4\ny\n512\nq\n" > /dev/null
check "games → sudo powos games create --size 512" 'grep -qx "sudo powos games create --size 512" "$CALLS"'

: > "$CALLS"
run_welcome "$HOME_E" live "$LIBDIR" "5\ny\nq\n" > /dev/null
# steam-setup needs root (writes native Proton dirs + the user vdf) → sudo.
check "steam → sudo powos games steam-setup" 'grep -qx "sudo powos games steam-setup" "$CALLS"'

: > "$CALLS"
run_welcome "$HOME_E" live "$LIBDIR" "6\nc\nq\n" > /dev/null
check "windows create → sudo powos windows create" 'grep -qx "sudo powos windows create" "$CALLS"'

: > "$CALLS"
out="$(run_welcome "$HOME_E" live "$LIBDIR" "6\ns\nq\n")"
check "windows status → powos windows status"      'grep -qx "powos windows status" "$CALLS"'
check "windows status output shown"                'grep -q "FAKE-WIN-STATUS" <<< "$out"'
check "windows item marked EXPERIMENTAL"           'grep -q "EXPERIMENTAL" <<< "$out"'

: > "$CALLS"
out="$(run_welcome "$HOME_E" live "$LIBDIR" "7\nq\n")"
check "status → powos status"              'grep -qx "powos status" "$CALLS"'
check "status output shown"                'grep -q "FAKE-POWOS-STATUS" <<< "$out"'

: > "$CALLS"
run_welcome "$HOME_E" installed "$LIBDIR" "3\nq\n" > /dev/null
check "installed item 3 → powos update"    'grep -qx "powos update" "$CALLS"'

# Installed-context explainer mentions the free-space caveat
out="$(run_welcome "$HOME_E" installed "$LIBDIR" "4\nn\nq\n")"
check "installed games explainer mentions free space" 'grep -qi "free space" <<< "$out"'

# ── Restore from cloud backup ─────────────────────────────────────
echo "== restore from cloud backup =="

# Fresh machine (mock reports 'No remote configured'): URL prompt, then
# setup → pull → assemble, in that order.
: > "$CALLS"
out="$(run_welcome "$HOME_E" live "$LIBDIR" "2\ny\ngit@example.com:me/state.git\ny\nq\n")"
check "no remote: setup→pull→assemble sequence" 'seq_ok \
    "powos backup status" \
    "powos backup setup git@example.com:me/state.git" \
    "powos backup pull" \
    "powos containers assemble"'
check "restore explainer sells the vision"      'grep -q "YOUR machine in minutes" <<< "$out"'

# Remote already configured: no URL prompt, no setup call — straight to
# pull + assemble offer.
export MOCK_BACKUP_STATUS="  URL: git@example.com:me/state.git"
: > "$CALLS"
out="$(run_welcome "$HOME_E" live "$LIBDIR" "2\ny\ny\nq\n")"
check "remote set: no setup call"          '! grep -q "powos backup setup" "$CALLS"'
check "remote set: no URL prompt"          '! grep -q "Git repository URL" <<< "$out"'
check "remote set: pull then assemble"     'seq_ok "powos backup pull" "powos containers assemble"'

# Declining the container step still pulls, never assembles.
: > "$CALLS"
run_welcome "$HOME_E" live "$LIBDIR" "2\ny\nn\nq\n" > /dev/null
check "assemble declined: pull still runs" 'grep -qx "powos backup pull" "$CALLS"'
check "assemble declined: no assemble"     '! grep -q "powos containers assemble" "$CALLS"'
unset MOCK_BACKUP_STATUS

# Restore also reachable on installed machines
: > "$CALLS"
run_welcome "$HOME_E" installed "$LIBDIR" "2\ny\ngit@example.com:me/state.git\nn\nq\n" > /dev/null
check "installed: restore pull runs"       'grep -qx "powos backup pull" "$CALLS"'

# ── Missing-command degradation (older installs) ──────────────────
echo "== missing-command degradation =="

: > "$CALLS"
out="$(run_welcome "$HOME_E" live "$EMPTYLIB" "4\nq\n")"
rc=$?
check "missing games: update notice shown"  'grep -q "arrives with the next update" <<< "$out"'
check "missing games: powos never invoked"  '! grep -q "powos games" "$CALLS"'
check "missing games: exits cleanly"        '[[ $rc -eq 0 ]]'

: > "$CALLS"
out="$(run_welcome "$HOME_E" live "$EMPTYLIB" "6\nq\n")"
check "missing windows: update notice shown" 'grep -q "arrives with the next update" <<< "$out"'

: > "$CALLS"
out="$(run_welcome "$HOME_E" live "$EMPTYLIB" "2\nq\n")"
check "missing backup: update notice shown"  'grep -q "arrives with the next update" <<< "$out"'
check "missing backup: no backup calls"      '! grep -q "powos backup" "$CALLS"'

# ── Password item ─────────────────────────────────────────────────
echo "== default-password flow =="

HOME_F="$TMP/home-passwd"
: > "$CALLS"
out="$(run_welcome "$HOME_F" live "$LIBDIR" "1\nq\n")"
check "default password flagged (SECURITY)"     'grep -q "SECURITY" <<< "$out"'
check "change runs passwd for user"             'grep -qx "passwd powos" "$CALLS"'
check "password-changed marker written"         '[[ -f "$HOME_F/.config/powos/password-changed" ]]'

out="$(run_welcome "$HOME_F" live "$LIBDIR" "q\n")"
check "after change: SECURITY flag gone"        '! grep -q "SECURITY" <<< "$out"'

# ── Terminal fallback works with kdialog absent ───────────────────
echo "== terminal fallback =="

# All action tests above already ran without kdialog on PATH; assert the
# menu itself rendered and the run exited 0.
out="$(run_welcome "$HOME_E" live "$LIBDIR" "q\n")"
rc=$?
check "no kdialog: menu renders in terminal"   'grep -q "PowOS Welcome" <<< "$out"'
check "no kdialog: exits 0"                    '[[ $rc -eq 0 ]]'

# ── .desktop lint (desktop-file-validate absent on Windows) ───────
echo "== .desktop lint ($DESK) =="

for f in "$DESK"/powos-welcome.desktop "$DESK"/powos-welcome-autostart.desktop "$DESK"/powos-install.desktop; do
    name="$(basename "$f")"
    if [[ ! -f "$f" ]]; then bad "$name missing"; continue; fi
    grep -q '^\[Desktop Entry\]' "$f" && ok "$name: [Desktop Entry] header" || bad "$name: no [Desktop Entry]"
    grep -q '^Type='  "$f" && ok "$name: Type= present"  || bad "$name: Type= missing"
    grep -q '^Name='  "$f" && ok "$name: Name= present"  || bad "$name: Name= missing"
    grep -q '^Exec='  "$f" && ok "$name: Exec= present"  || bad "$name: Exec= missing"
done
grep -q -- '--autostart' "$DESK/powos-welcome-autostart.desktop" 2>/dev/null \
    && ok "autostart entry passes --autostart" || bad "autostart entry lacks --autostart"
grep -q 'sudo powos install-system' "$DESK/powos-install.desktop" 2>/dev/null \
    && ok "install entry launches the real installer" || bad "install entry Exec wrong"

echo
echo "== Results: $PASS passed, $FAIL failed =="
[[ $FAIL -eq 0 ]]
