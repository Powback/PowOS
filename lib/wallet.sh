#!/bin/bash
# wallet.sh - answer "who is asking for my KDE wallet password, and why".
#
# THE COMPLAINT THIS EXISTS FOR: the kwallet prompt says essentially nothing.
# It does not name the application, the command, or the secret being read, so a
# password dialog appears out of nowhere and the only honest response is to
# guess. That is a bad security prompt — a dialog you cannot attribute is a
# dialog you cannot make a real decision about, and users learn to click
# through it, which is exactly the habit an attacker needs.
#
# kwalletd6 does know the answer: apps pass an `appid` when they open a wallet,
# and `users(wallet)` lists the current holders. It just never surfaces it.
#
#   powos wallet            Status + WHY it keeps prompting
#   powos wallet who        Who currently holds the wallet open
#   powos wallet watch      Live: print each new holder as it appears
#   powos wallet why        Explain the prompting root cause in detail
#
# NOTE: sourced into bin/powos — must NOT set -e/-u/pipefail at top level.

source "${POWOS_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/common.sh" 2>/dev/null || {
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'
    CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; NC=$'\033[0m'
    plog()  { echo -e "${CYAN}[wallet]${NC} $*"; }
    pok()   { echo -e "${GREEN}[wallet]${NC} $*"; }
    pwarn() { echo -e "${YELLOW}[wallet]${NC} $*"; }
    perr()  { echo -e "${RED}[wallet]${NC} $*" >&2; }
}
POWOS_TAG=wallet

WAL_SVC="org.kde.kwalletd6"
WAL_OBJ="/modules/kwalletd6"
WAL_IFACE="org.kde.KWallet"

# ── D-Bus helpers ─────────────────────────────────────────────────────────

wal_have_bus() { [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]] || [[ -S "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/bus" ]]; }

wal_running() {
    command -v qdbus6 >/dev/null 2>&1 || command -v qdbus >/dev/null 2>&1 || return 1
    wal_qdbus org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.NameHasOwner "$WAL_SVC" 2>/dev/null | grep -qi true
}

wal_qdbus() {
    if command -v qdbus6 >/dev/null 2>&1; then qdbus6 "$@"
    elif command -v qdbus >/dev/null 2>&1; then qdbus "$@"
    else return 127; fi
}

wal_call() { wal_qdbus "$WAL_SVC" "$WAL_OBJ" "${WAL_IFACE}.$@" 2>/dev/null; }

wal_wallets()      { wal_call wallets; }
wal_is_open()      { wal_call isOpen "$1" 2>/dev/null | grep -qi true; }
wal_users()        { wal_call users "$1"; }

# ── Root-cause detection ──────────────────────────────────────────────────

# Is this session an AUTOLOGIN session? That is the usual reason the wallet
# never auto-unlocks: pam_kwallet5 derives the wallet key from the password you
# type at login, and an autologin session never types one. kwalletd still
# starts (session auto_start) but has nothing to unlock WITH, so every access
# prompts. It is not a misconfiguration — it is inherent.
wal_autologin_active() {
    local f
    for f in /etc/plasmalogin.conf /etc/plasmalogin.conf.d/*.conf \
             /etc/sddm.conf /etc/sddm.conf.d/*.conf; do
        [[ -r "$f" ]] || continue
        grep -qE '^\s*User\s*=\s*\S' "$f" 2>/dev/null && { printf '%s' "$f"; return 0; }
    done
    return 1
}

# Does the DM's PAM stack capture a password for the wallet at auth time?
# `session ... auto_start` alone only STARTS kwalletd; without the auth-phase
# line there is no key material, so the wallet stays locked.
wal_pam_auth_line() {
    local f
    for f in /etc/pam.d/plasmalogin /usr/lib/pam.d/plasmalogin \
             /etc/pam.d/sddm /usr/lib/pam.d/sddm; do
        [[ -r "$f" ]] || continue
        grep -qE '^\s*-?auth\s+optional\s+pam_kwallet' "$f" && { printf '%s' "$f"; return 0; }
    done
    return 1
}

# ── Reporting ─────────────────────────────────────────────────────────────

# Map a kwallet appid to something a human can act on. appid is whatever the
# app passed to open() — often the binary name, sometimes a friendly string.
wal_resolve_appid() {
    local app="$1" pids
    pids=$(pgrep -x -- "$app" 2>/dev/null | head -3 | tr '\n' ' ')
    [[ -z "$pids" ]] && pids=$(pgrep -f -- "$app" 2>/dev/null | head -3 | tr '\n' ' ')
    if [[ -n "$pids" ]]; then
        local p
        for p in $pids; do
            printf '      pid %-7s %s\n' "$p" "$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | cut -c1-90)"
        done
    else
        printf '      %s\n' "${DIM}(no running process matches this appid — it may have exited)${NC}"
    fi
}

wal_who_cmd() {
    if ! wal_running; then
        pwarn "kwalletd6 is not running on this session's bus."
        plog  "Nothing holds a wallet open, so nothing should be prompting."
        return 0
    fi
    local w any=false
    while read -r w; do
        [[ -n "$w" ]] || continue
        local state="closed"; wal_is_open "$w" && state="OPEN"
        echo -e "  ${BOLD}$w${NC}  ($state)"
        local u
        while read -r u; do
            [[ -n "$u" ]] || continue
            any=true
            echo -e "    ${CYAN}$u${NC}"
            wal_resolve_appid "$u"
        done < <(wal_users "$w")
    done < <(wal_wallets)
    $any || plog "No application currently holds a wallet open."
}

wal_why_cmd() {
    echo -e "${BOLD}Why the wallet keeps asking${NC}"
    echo    "════════════════════════════════════════"
    local auto pam
    auto="$(wal_autologin_active || true)"
    pam="$(wal_pam_auth_line || true)"

    if [[ -n "$auto" ]]; then
        echo -e "  ${YELLOW}●${NC} Autologin is configured (${auto})."
        echo -e "    pam_kwallet derives the wallet key from the password you TYPE at"
        echo -e "    login. An autologin session never types one, so kwalletd starts"
        echo -e "    but has no key — the wallet stays locked and every access prompts."
        echo -e "    ${DIM}This is inherent to autologin, not a misconfiguration.${NC}"
    else
        echo -e "  ${GREEN}●${NC} No autologin detected — the login password can unlock the wallet."
    fi

    if [[ -n "$pam" ]]; then
        echo -e "  ${GREEN}●${NC} PAM auth-phase kwallet line present (${pam})."
    else
        echo -e "  ${YELLOW}●${NC} No auth-phase pam_kwallet line found."
        echo -e "    A ${BOLD}session ... auto_start${NC} line alone only STARTS kwalletd;"
        echo -e "    without the auth phase there is no key material to unlock with."
    fi

    echo
    echo -e "  ${BOLD}Options${NC}"
    echo -e "    • Blank the wallet password (KDE Wallet Manager → change password"
    echo -e "      to empty). It then opens without prompting. Trade-off: the wallet"
    echo -e "      is no longer protected by a passphrase at rest."
    echo -e "    • Stop using autologin, so the typed password unlocks the wallet."
    echo -e "    • If nothing you care about stores secrets there, disable KWallet"
    echo -e "      (System Settings → KDE Wallet → uncheck Enable)."
    echo -e "    • Find the culprit first: ${BOLD}powos wallet watch${NC}"
    echo
}

wal_status_cmd() {
    echo -e "${BOLD}KDE Wallet${NC}"
    echo    "════════════════════════════════════════"
    if ! command -v qdbus6 >/dev/null 2>&1 && ! command -v qdbus >/dev/null 2>&1; then
        pwarn "qdbus not available — cannot query kwalletd."
        return 1
    fi
    if ! wal_have_bus; then
        pwarn "No session D-Bus. Run this inside your desktop session."
        return 1
    fi
    if wal_running; then
        echo -e "  Daemon:   ${GREEN}●${NC} kwalletd6 running"
    else
        echo -e "  Daemon:   ${DIM}○ not running${NC}"
    fi
    local w
    while read -r w; do
        [[ -n "$w" ]] || continue
        local state="closed"; wal_is_open "$w" && state="${GREEN}open${NC}"
        echo -e "  Wallet:   $w ($state)"
    done < <(wal_wallets)
    echo
    wal_why_cmd
    echo -e "  ${DIM}powos wallet who    — who holds it open right now${NC}"
    echo -e "  ${DIM}powos wallet watch  — catch the next thing that asks${NC}"
}

# Poll users() and report holders as they APPEAR. Polling rather than signals
# because kwalletd emits no "someone is prompting" signal — the dialog is
# raised inside kwalletd itself, so the only externally observable event is a
# new appid showing up in users() once the user answers.
wal_watch_cmd() {
    local interval="${1:-1}"
    wal_running || { pwarn "kwalletd6 not running — nothing to watch."; return 1; }
    plog "Watching for wallet access (Ctrl-C to stop)…"
    plog "${DIM}A new holder appears here the moment you answer a prompt.${NC}"
    echo
    local seen=" "
    while true; do
        local w u
        while read -r w; do
            [[ -n "$w" ]] || continue
            while read -r u; do
                [[ -n "$u" ]] || continue
                case "$seen" in
                    *" ${w}/${u} "*) continue ;;
                esac
                seen="$seen${w}/${u} "
                echo -e "  $(date '+%H:%M:%S')  ${BOLD}${u}${NC}  ${DIM}(wallet: $w)${NC}"
                wal_resolve_appid "$u"
            done < <(wal_users "$w")
        done < <(wal_wallets)
        sleep "$interval"
    done
}

wal_help() {
    cat <<EOF
${BOLD}powos wallet${NC} — find out what is asking for your KDE wallet password

The kwallet prompt does not name the application, the command, or the secret
it wants. This tells you.

  powos wallet          Status, plus WHY it keeps prompting
  powos wallet who      Which apps hold a wallet open right now, with PIDs
                          and full command lines
  powos wallet watch    Live — prints each new holder the moment it appears,
                          so you can catch whatever raised the last dialog
  powos wallet why      Just the root-cause explanation
  powos wallet help     This text

${BOLD}The usual cause${NC}: pam_kwallet derives the wallet key from the password you
TYPE at login. With autologin you never type one, so kwalletd starts with no
key, the wallet stays locked, and every single access prompts. That is
inherent to autologin — see 'powos wallet why' for the options.

Must run inside your desktop session (it needs the session D-Bus).
EOF
}

cmd_wallet() {
    local sub="${1:-status}"; shift 2>/dev/null || true
    case "$sub" in
        status|"")      wal_status_cmd ;;
        who|holders)    wal_who_cmd ;;
        watch|monitor)  wal_watch_cmd "$@" ;;
        why|explain)    wal_why_cmd ;;
        help|-h|--help) wal_help ;;
        *) perr "Unknown: powos wallet $sub"; wal_help; return 1 ;;
    esac
}
