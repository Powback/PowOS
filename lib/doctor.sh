#!/bin/bash
# doctor.sh - PowOS AI-native boot debugger.
#
# `powos doctor` diagnoses a broken or failed boot. It runs in one of two roles:
#
#   1. SAFE MODE (on the installed / running system):
#        The system booted, but degraded. Doctor collects THIS boot's logs, the
#        PREVIOUS failed boot, failed units, kernel errors and PowOS state, then
#        (with --ai) hands the bundle to the health AI agent.
#
#   2. LIVE-USB RESCUE (against a broken install on an internal disk):
#        Boot the Live USB, run `powos doctor --target auto`. Doctor finds a
#        PowOS/bootc install on an internal disk (never the live device), mounts
#        it READ-ONLY, and collects ITS journal + config. It never writes to the
#        target and unmounts it on the way out.
#
# Boot integration (the orchestrator wires the service; doctor just provides the
# command). Two kargs signal the boot role:
#   powos.mode=safe     → the boot menu / a service OFFERS `powos doctor`
#   powos.mode=aidebug  → a service AUTO-RUNS `powos doctor --ai`
#
# AI credential resolution tries four sources in order and stops at the first
# hit (see doc_resolve_ai_creds): (1) the TARGET install's stored creds, (2) the
# running/Live system's own creds, (3) cloud backup, (4) prompt. The secret is
# NEVER printed and is handed to the client via the environment, not argv.
#
# Entry point: cmd_doctor "$@"
#
# SOURCED by bin/powos — deliberately NO top-level `set -e/-u/pipefail`: those
# would retroactively flip the whole calling shell into strict mode.

# ── Presentation ──────────────────────────────────────────────────
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'
CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; NC=$'\033[0m'

doc_log()  { echo -e "${CYAN}[doctor]${NC} $*"; }
doc_ok()   { echo -e "${GREEN}[doctor]${NC} $*"; }
doc_warn() { echo -e "${YELLOW}[doctor]${NC} $*"; }
doc_err()  { echo -e "${RED}[doctor]${NC} $*" >&2; }
doc_step() { echo; echo -e "${BOLD}── $* ──${NC}"; }

# ── Global state / overridable seams (tests point these at fixtures) ──
DOC_AI=0                # 1 = hand the bundle to the health AI agent
DOC_OFFLINE=0          # 1 = never touch the network/AI; save bundle + instructions
DOC_DRY_RUN=0          # 1 = plan only: zero mounts, zero AI calls
DOC_TARGET=""          # "" (local), "auto", or /dev/sdX (a broken install)
DOC_TS="${DOC_TS:-}"   # bundle timestamp; --ts / env override keeps tests stable

DOC_LOG_DIR="${DOC_LOG_DIR:-/var/log/powos}"        # where bundles are written
DOC_RUN_DIR="${DOC_RUN_DIR:-/run/powos}"            # PowOS runtime state
DOC_SESSION_NAME="${DOC_SESSION_NAME:-powos-doctor}"
DOC_AI_SESSION_DIR="${DOC_AI_SESSION_DIR:-${AI_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/powos/ai}/sessions}"

# Credential file locations (all overridable for tests; never printed).
DOC_LIVE_CRED_FILE="${DOC_LIVE_CRED_FILE:-/etc/powos/ai/credentials}"
DOC_HOME_CRED_FILE="${DOC_HOME_CRED_FILE:-${HOME:-/root}/.config/powos/ai/credentials}"
DOC_BACKUP_CRED_FILE="${DOC_BACKUP_CRED_FILE:-/var/lib/powos/git/config/ai/credentials}"

# Runtime bookkeeping for the read-only target mount.
DOC_TARGET_MP=""
DOC_TARGET_MOUNTED=0
DOC_AI_CRED=""          # the resolved secret — NEVER echo this
DOC_AI_CRED_SOURCE=""

# doc_run_step "description" cmd args...
# Executes a mutating command (mount / AI call) unless dry-run. Always echoes
# the command first (never the secret — creds travel via the environment).
doc_run_step() {
    local desc="$1"; shift
    echo -e "  ${DIM}\$ $*${NC}"
    if [[ ${DOC_DRY_RUN:-0} -eq 1 ]]; then
        doc_warn "dry-run: skipped ($desc)"
        return 0
    fi
    "$@"
}

# ── Live-system collector seams (shadowed in tests) ───────────────
# Each emits one section's raw text; failures degrade to an empty/noted section.
doc_cmd_cmdline()          { cat /proc/cmdline 2>/dev/null; }
doc_cmd_journal_current()  { journalctl -b --no-pager 2>/dev/null; }
doc_cmd_journal_previous() { journalctl -b -1 --no-pager 2>/dev/null; }
doc_cmd_failed_units()     { systemctl --failed --no-legend --no-pager 2>/dev/null; }
doc_cmd_dmesg()            { dmesg --level=err,warn 2>/dev/null || dmesg 2>/dev/null; }

# PowOS runtime state under /run/powos (ramboot-state, layer-sync-status.json …).
doc_collect_powos_state() {
    local d="$DOC_RUN_DIR" f any=0
    for f in ramboot-state layer-paths layer-sync-status.json rollback-kargs \
             cachefs-status.json sync.lock; do
        if [[ -f "$d/$f" ]]; then
            echo "--- $d/$f ---"
            cat "$d/$f" 2>/dev/null
            echo
            any=1
        fi
    done
    [[ $any -eq 0 ]] && echo "(no PowOS runtime state under $d)"
    return 0
}

# The EFI System Partition mountpoint (where the self-heal counter lives).
doc_find_esp() {
    local m t
    for m in /boot/efi /efi /boot; do
        t=$(findmnt -n -o TARGET "$m" 2>/dev/null | head -1)
        [[ -n "$t" ]] && { echo "$t"; return 0; }
    done
    return 1
}

# The ESP ramboot self-heal counter (>= RB_MAX_ATTEMPTS means ramboot backed off).
doc_collect_esp_counter() {
    local esp f
    if ! esp=$(doc_find_esp); then
        echo "(ESP not found — /boot/efi not mounted?)"
        return 0
    fi
    f="$esp/powos/ramboot-attempts"
    if [[ -f "$f" ]]; then
        echo "attempts: $(tr -dc '0-9' < "$f" 2>/dev/null)  ($f)"
    else
        echo "(no self-heal counter at $f — ramboot not backed off)"
    fi
    return 0
}

# ── Target (broken install) discovery — read-only ─────────────────
# The block device backing the running root (the live device we must exclude).
doc_live_device() { findmnt -n -o SOURCE / 2>/dev/null | head -1; }

# All partition block devices on the box, one per line.
doc_list_partitions() {
    lsblk -pnro NAME,TYPE 2>/dev/null | awk '$2=="part"{print $1}'
}

# Heuristic: is $1 a PowOS/bootc install we can diagnose? (by fs/GPT label)
doc_is_powos_install() {
    local dev="$1" lbl plbl
    lbl=$(blkid -o value -s LABEL "$dev" 2>/dev/null)
    plbl=$(blkid -o value -s PARTLABEL "$dev" 2>/dev/null)
    case "$lbl$plbl" in
        *[Pp]ow[Oo][Ss]*|*POWOS*|*bazzite*|*ostree*) return 0 ;;
    esac
    return 1
}

# Find a PowOS install on an INTERNAL disk that is NOT the live device.
doc_find_target_auto() {
    local live path
    live=$(doc_live_device)
    while read -r path; do
        [[ -z "$path" ]] && continue
        # Skip anything on the live device (partition or whole-disk prefix match).
        [[ -n "$live" && "$path" == "$live"* ]] && continue
        [[ -n "$live" && "$live" == "$path"* ]] && continue
        if doc_is_powos_install "$path"; then
            echo "$path"
            return 0
        fi
    done < <(doc_list_partitions)
    return 1
}

doc_mktemp() { mktemp -d 2>/dev/null || echo "/tmp/powos-doctor-$$"; }

# Mount a target device READ-ONLY. Gated by doc_run_step so --dry-run mounts
# nothing. `ro` is non-negotiable: we NEVER write to a broken install.
doc_mount_target_ro() {
    local dev="$1" mp="$2"
    doc_run_step "mount broken install read-only" mount -o ro "$dev" "$mp"
}

doc_umount_target() {
    [[ ${DOC_TARGET_MOUNTED:-0} -eq 1 ]] || return 0
    if doc_run_step "unmount broken install" umount "$DOC_TARGET_MP"; then
        DOC_TARGET_MOUNTED=0
    fi
}

# Collect logs + config from a broken install, read-only, then unmount.
doc_collect_target() {
    local dev
    if [[ "$DOC_TARGET" == "auto" ]]; then
        if ! dev=$(doc_find_target_auto); then
            echo "(no broken PowOS install found on an internal disk)"
            return 0
        fi
    else
        dev="$DOC_TARGET"
    fi
    echo "target device: $dev"

    DOC_TARGET_MP=$(doc_mktemp)
    if ! doc_mount_target_ro "$dev" "$DOC_TARGET_MP"; then
        echo "(could not mount $dev read-only)"
        return 0
    fi
    # Under dry-run the mount was skipped; there is nothing mounted to read.
    if [[ ${DOC_DRY_RUN:-0} -eq 1 ]]; then
        echo "(dry-run: would collect journal + config from $dev at $DOC_TARGET_MP)"
        return 0
    fi
    DOC_TARGET_MOUNTED=1

    echo "mounted read-only at: $DOC_TARGET_MP"
    echo "--- persistent journal ($DOC_TARGET_MP/var/log/journal) ---"
    ls -1 "$DOC_TARGET_MP/var/log/journal" 2>/dev/null || echo "(no persistent journal)"
    echo "--- PowOS config ($DOC_TARGET_MP/etc/powos) ---"
    ls -1 "$DOC_TARGET_MP/etc/powos" 2>/dev/null || echo "(no /etc/powos)"
    local cfg="$DOC_TARGET_MP/etc/powos/config"
    [[ -f "$cfg" ]] && { echo "--- $cfg ---"; cat "$cfg" 2>/dev/null; }

    doc_umount_target
    return 0
}

# ── Bundle assembly ───────────────────────────────────────────────
doc_timestamp() {
    if [[ -n "${DOC_TS:-}" ]]; then echo "$DOC_TS"; return 0; fi
    date -u +%Y%m%d-%H%M%S 2>/dev/null || echo "unknown"
}

# doc_section "Title" collector args...  → header + collector output + blank line
doc_section() {
    local title="$1"; shift
    echo "----- ${title} -----"
    "$@" 2>/dev/null || echo "(collector failed: $title)"
    echo
}

# Assemble the whole bundle to stdout. Every section carries a distinctive
# header so the AI (and the tests) can find each block.
doc_build_bundle() {
    echo "===== PowOS Doctor Bundle ====="
    echo "generated: $(doc_timestamp)"
    echo "role:      $([[ -n "$DOC_TARGET" ]] && echo "live-usb rescue (target: $DOC_TARGET)" || echo "safe mode (this system)")"
    echo

    doc_section "/proc/cmdline"                              doc_cmd_cmdline
    doc_section "Current boot journal (journalctl -b)"       doc_cmd_journal_current
    doc_section "Previous failed boot (journalctl -b -1)"    doc_cmd_journal_previous
    doc_section "Failed units (systemctl --failed)"          doc_cmd_failed_units
    doc_section "Kernel ring buffer (dmesg errors)"          doc_cmd_dmesg
    doc_section "PowOS runtime state (/run/powos)"           doc_collect_powos_state
    doc_section "ESP self-heal counter"                      doc_collect_esp_counter

    if [[ -n "$DOC_TARGET" ]]; then
        doc_section "Target install (offline diagnosis)"     doc_collect_target
    fi
}

# Write the bundle to $DOC_LOG_DIR/doctor-<ts>.log and echo its path.
doc_write_bundle() {
    local out="$DOC_LOG_DIR/doctor-$(doc_timestamp).log"
    mkdir -p "$DOC_LOG_DIR" 2>/dev/null || true
    doc_build_bundle > "$out" 2>/dev/null
    echo "$out"
}

# ── AI credential resolution ──────────────────────────────────────
# Read a secret file into DOC_AI_CRED WITHOUT echoing it.
doc_read_secret() { tr -d '\r\n' < "$1" 2>/dev/null; }

# (1) The TARGET install's stored creds (its /etc/powos/ai + user ~/.config).
doc_creds_from_target() {
    [[ -n "${DOC_TARGET_MP:-}" ]] || return 1
    local f
    for f in "$DOC_TARGET_MP/etc/powos/ai/credentials" \
             "$DOC_TARGET_MP"/home/*/.config/powos/ai/credentials \
             "$DOC_TARGET_MP"/root/.config/powos/ai/credentials; do
        [[ -f "$f" ]] || continue
        DOC_AI_CRED=$(doc_read_secret "$f")
        [[ -n "$DOC_AI_CRED" ]] && return 0
    done
    return 1
}

# (2) The running / Live system's own creds.
doc_creds_from_live() {
    local f
    for f in "$DOC_LIVE_CRED_FILE" "$DOC_HOME_CRED_FILE"; do
        [[ -f "$f" ]] || continue
        DOC_AI_CRED=$(doc_read_secret "$f")
        [[ -n "$DOC_AI_CRED" ]] && return 0
    done
    if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
        DOC_AI_CRED="$ANTHROPIC_API_KEY"
        return 0
    fi
    return 1
}

# (3) Cloud backup: creds cached in the state repo pulled from the backup remote.
doc_creds_from_backup() {
    [[ -f "$DOC_BACKUP_CRED_FILE" ]] || return 1
    DOC_AI_CRED=$(doc_read_secret "$DOC_BACKUP_CRED_FILE")
    [[ -n "$DOC_AI_CRED" ]] && return 0
    return 1
}

# (4) Prompt the operator (only on a real terminal; never hangs a service).
doc_creds_from_prompt() {
    [[ -t 0 ]] || return 1
    local key=""
    read -r -s -p "Enter AI API key (input hidden): " key
    echo >&2
    [[ -n "$key" ]] || return 1
    DOC_AI_CRED="$key"
    return 0
}

# Try all four sources in order, stop at the first hit. Echoes the SOURCE name
# (never the secret). Returns 1 if none resolved.
doc_resolve_ai_creds() {
    DOC_AI_CRED=""
    DOC_AI_CRED_SOURCE=""
    local src
    for src in target live backup prompt; do
        if "doc_creds_from_$src"; then
            DOC_AI_CRED_SOURCE="$src"
            echo "$src"
            return 0
        fi
    done
    return 1
}

# ── AI diagnosis ──────────────────────────────────────────────────
# Bounded network reachability check — MUST NOT hang.
doc_network_ok() {
    local host="${DOC_AI_HOST:-api.anthropic.com}"
    timeout 3 bash -c "exec 3<>/dev/tcp/${host}/443" 2>/dev/null && return 0
    return 1
}

# Does a prior doctor AI session exist (so we can --continue it)?
doc_session_exists() {
    [[ -f "$DOC_AI_SESSION_DIR/$DOC_SESSION_NAME.json" ]]
}

# The actual health-agent invocation (seam: tests shadow this). The bundle is
# piped in as context; creds are already in the environment (never argv).
doc_ai_invoke() {
    local bundle="$1"; shift
    local prompt
    prompt="Diagnose this PowOS boot failure and give concrete recovery steps. Diagnostic bundle follows:

$(cat "$bundle" 2>/dev/null)"
    if declare -f ai_call >/dev/null 2>&1; then
        printf '%s' "$prompt" | ai_call "$@"
    elif command -v powos >/dev/null 2>&1; then
        printf '%s' "$prompt" | powos ai "$@"
    else
        doc_err "No AI client available (ai_call / powos ai)."
        return 1
    fi
}

# Save the bundle and print exactly how to re-run once network/creds return.
doc_offline_note() {
    local bundle="$1" reason="$2"
    doc_warn "AI diagnosis skipped: $reason"
    echo
    echo "Diagnostic bundle saved:"
    echo "  $bundle"
    echo
    echo "Re-run the AI diagnosis once network + credentials are available:"
    echo "  powos doctor --ai"
    echo "  powos ai --agent health < \"$bundle\""
}

# Hand the bundle to the health agent, or fall back to offline instructions.
doc_run_ai() {
    local bundle="$1"

    if [[ ${DOC_OFFLINE:-0} -eq 1 ]]; then
        doc_offline_note "$bundle" "--offline requested"
        return 0
    fi

    local src
    if ! src=$(doc_resolve_ai_creds); then
        doc_offline_note "$bundle" "no AI credentials found (tried target, live, backup, prompt)"
        return 0
    fi
    doc_log "AI credentials resolved from: $src"

    if ! doc_network_ok; then
        doc_offline_note "$bundle" "no network reachable"
        return 0
    fi

    # Hand the secret to the client via the environment — NEVER on the command
    # line (doc_run_step echoes argv).
    [[ -n "${DOC_AI_CRED:-}" ]] && export ANTHROPIC_API_KEY="$DOC_AI_CRED"

    # Always name the session explicitly. `powos ai --continue` is now
    # per-agent/per-session (resolves the named session's stored UUID), not
    # the client's directory-global most-recent chat — so --continue must be
    # paired with --session to resume THIS doctor session.
    local -a args=(--agent health --session "$DOC_SESSION_NAME")
    if doc_session_exists; then
        args+=(--continue)
        doc_log "Continuing prior doctor session."
    else
        doc_log "Starting a fresh health session ($DOC_SESSION_NAME)."
    fi

    doc_step "Health AI diagnosis"
    doc_run_step "ask the health agent to diagnose the bundle" \
        doc_ai_invoke "$bundle" "${args[@]}"
}

# ── Cleanup ───────────────────────────────────────────────────────
doc_cleanup() {
    doc_umount_target
}

# ── Status / usage ────────────────────────────────────────────────
doc_boot_mode() {
    local cl; cl=$(doc_cmd_cmdline)
    case "$cl" in
        *powos.mode=aidebug*) echo "aidebug (auto-runs: powos doctor --ai)" ;;
        *powos.mode=safe*)    echo "safe (boot menu offers: powos doctor)" ;;
        *)                    echo "normal" ;;
    esac
}

doc_status() {
    echo -e "${BOLD}PowOS Doctor${NC}"
    echo "  Boot role (karg): $(doc_boot_mode)"
    echo "  Bundles dir:      $DOC_LOG_DIR"
    echo "  AI session:       $DOC_SESSION_NAME $(doc_session_exists && echo '(exists — --ai will --continue)' || echo '(none — --ai starts fresh)')"
    echo
    echo "  Diagnose the current/last boot:   powos doctor --ai"
    echo "  Diagnose a broken internal disk:  sudo powos doctor --target auto --ai"
    return 0
}

doc_usage() {
    cat <<EOF
powos doctor — AI-native boot debugger

Diagnose a broken or failed boot. Runs on the installed system (safe mode) or
from the Live USB against a broken install on an internal disk.

Usage:
  powos doctor [--ai] [--target auto|/dev/sdX] [--offline] [--dry-run]
  powos doctor status
  powos doctor help

Options:
  --ai                 Hand the collected bundle to the health AI agent.
  --target auto        Find a broken PowOS install on an internal disk, mount it
                       READ-ONLY, and collect its logs (never the live device).
  --target /dev/sdX    Diagnose a specific device (mounted read-only).
  --offline            Never touch the network/AI: save the bundle and print how
                       to re-run once network/credentials are available.
  --dry-run            Plan only — performs zero mounts and zero AI calls.
  --ts <stamp>         Override the bundle timestamp (for reproducible names).

What gets collected (into $DOC_LOG_DIR/doctor-<ts>.log):
  /proc/cmdline, current boot journal (journalctl -b), the PREVIOUS failed boot
  (journalctl -b -1), failed units (systemctl --failed), dmesg errors, PowOS
  runtime state (/run/powos/*), and the ESP self-heal counter.

AI credentials are resolved in order (first hit wins, secret never printed):
  1. the target install's stored creds   2. this/Live system's creds
  3. cloud backup                         4. prompt

Boot integration (kargs the orchestrator's service reacts to):
  powos.mode=safe     boot menu offers 'powos doctor'
  powos.mode=aidebug  a service auto-runs 'powos doctor --ai'
EOF
    return 0
}

# ── Entry point ───────────────────────────────────────────────────
cmd_doctor() {
    DOC_AI=0; DOC_OFFLINE=0; DOC_DRY_RUN=0; DOC_TARGET=""
    DOC_TARGET_MP=""; DOC_TARGET_MOUNTED=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ai)        DOC_AI=1; shift ;;
            --offline)   DOC_OFFLINE=1; shift ;;
            --dry-run)   DOC_DRY_RUN=1; shift ;;
            --target)    DOC_TARGET="${2:-auto}"; shift 2 ;;
            --target=*)  DOC_TARGET="${1#*=}"; shift ;;
            --ts)        DOC_TS="${2:-}"; shift 2 ;;
            --ts=*)      DOC_TS="${1#*=}"; shift ;;
            status)      doc_status; return 0 ;;
            help|-h|--help) doc_usage; return 0 ;;
            -*)          doc_err "Unknown option: $1"; doc_usage; return 1 ;;
            *)           doc_err "Unknown argument: $1"; doc_usage; return 1 ;;
        esac
    done

    # Freeze the timestamp ONCE so every reference (bundle name + header) agrees.
    [[ -z "${DOC_TS:-}" ]] && DOC_TS=$(date -u +%Y%m%d-%H%M%S 2>/dev/null || echo "unknown")

    # Belt-and-suspenders: unmount the target even on Ctrl-C. Cleared on return.
    trap 'doc_cleanup' EXIT INT TERM

    doc_step "Collecting diagnostics"
    [[ ${DOC_DRY_RUN:-0} -eq 1 ]] && doc_warn "dry-run: no mounts, no AI calls"
    local bundle
    bundle=$(doc_write_bundle)
    doc_ok "Diagnostic bundle written: $bundle"

    if [[ ${DOC_AI:-0} -eq 1 ]]; then
        doc_run_ai "$bundle"
    else
        echo
        echo "Re-run with --ai to have the health agent diagnose it, or:"
        echo "  powos ai --agent health < \"$bundle\""
    fi

    doc_cleanup
    trap - EXIT INT TERM
    return 0
}

# Allow sourcing (bin/powos) or direct execution.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cmd_doctor "$@"
fi
