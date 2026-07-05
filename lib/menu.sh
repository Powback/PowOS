#!/bin/bash
# menu.sh - `powos menu`: a discoverable, categorized TTY menu that dispatches
# to the real commands. whiptail if present, plain numbered fallback otherwise.
#
# Bare `powos` stays exactly as-is (prints usage) for scripts; this is the
# opt-in guided front door.
set -uo pipefail
source "${POWOS_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/common.sh"
POWOS_TAG=menu

# PURE mapping: a menu choice tag → the `powos` sub-command argv (as a string).
# Kept side-effect-free so it can be unit-tested without an interactive run.
menu_action() {
    case "$1" in
        # Status & health
        status)       echo "status" ;;
        health)       echo "health" ;;
        # Update
        update)       echo "update" ;;
        upgrade)      echo "upgrade --check" ;;
        # Edit & push (the self dev loop)
        self-status)  echo "self status" ;;
        self-test)    echo "self test" ;;
        self-pull)    echo "self pull" ;;
        self-push)    echo "self push" ;;
        # Backup & restore
        backup)       echo "backup status" ;;
        backup-push)  echo "backup push" ;;
        backup-pull)  echo "backup pull" ;;
        # Games & Windows
        games)        echo "games status" ;;
        windows)      echo "windows status" ;;
        # Recovery
        doctor)       echo "doctor" ;;
        rollback)     echo "rollback" ;;
        *) return 1 ;;
    esac
}

# Present a menu of tag/label pairs; print the chosen tag. whiptail → numbered.
menu_pick() {
    local prompt="$1"; shift
    if command -v whiptail >/dev/null 2>&1; then
        whiptail --title "PowOS" --menu "$prompt" 20 74 12 "$@" 3>&1 1>&2 2>&3
        return
    fi
    echo >&2; echo -e "${BOLD}$prompt${NC}" >&2
    local -a tags=() labels=()
    while [[ $# -gt 0 ]]; do tags+=("$1"); labels+=("${2:-}"); shift 2; done
    local i
    for i in "${!tags[@]}"; do printf '  %2d) %s\n' "$((i+1))" "${labels[$i]}" >&2; done
    local sel
    read -r -p "  Choose [1-${#tags[@]}]: " sel || return 1
    [[ "$sel" =~ ^[0-9]+$ ]] || return 1
    (( sel >= 1 && sel <= ${#tags[@]} )) || return 1
    printf '%s\n' "${tags[$((sel-1))]}"
}

# Run `powos <args…>` via the resolved binary, then pause.
menu_run() {
    local bin; bin="$(command -v powos 2>/dev/null || echo powos)"
    echo -e "\n${CYAN}\$ powos $*${NC}\n"
    "$bin" "$@"
    echo
    read -r -p "Press Enter to return to the menu… " _ || true
}

# Dispatch a chosen tag through the pure map, then execute it.
menu_dispatch() {
    local tag="$1" action
    action="$(menu_action "$tag")" || { perr "no action for '$tag'"; return 1; }
    # Intentional word-split: "self status" → two args.
    # shellcheck disable=SC2086
    menu_run $action
}

cmd_menu() {
    while true; do
        local cat
        cat="$(menu_pick "PowOS — guided menu (Ctrl-C to quit)" \
            status   "Status & health" \
            update   "Update PowOS" \
            self     "Edit, test & push PowOS" \
            backup   "Backup & restore" \
            gaming   "Games & Windows" \
            recovery "Recovery & rollback" \
            quit     "Quit")" || return 0
        case "$cat" in
            ""|quit) return 0 ;;
            status)
                local t; t="$(menu_pick "Status & health" \
                    status "Full system status" \
                    health "Health check" \
                    back "‹ Back")" || continue
                [[ "$t" == back ]] && continue
                menu_dispatch "$t" ;;
            update)
                local t; t="$(menu_pick "Update PowOS" \
                    update "Check for updates" \
                    upgrade "Check base OS update" \
                    back "‹ Back")" || continue
                [[ "$t" == back ]] && continue
                menu_dispatch "$t" ;;
            self)
                local t; t="$(menu_pick "Edit, test & push PowOS" \
                    self-status "Source status (baked commit, edits)" \
                    self-test "Apply local edits to this system (transient)" \
                    self-pull "Safe pull from upstream" \
                    self-push "Commit & push local changes" \
                    back "‹ Back")" || continue
                [[ "$t" == back ]] && continue
                menu_dispatch "$t" ;;
            backup)
                local t; t="$(menu_pick "Backup & restore" \
                    backup "Backup status" \
                    backup-push "Push to cloud" \
                    backup-pull "Pull from cloud" \
                    back "‹ Back")" || continue
                [[ "$t" == back ]] && continue
                menu_dispatch "$t" ;;
            gaming)
                local t; t="$(menu_pick "Games & Windows" \
                    games "Games storage status" \
                    windows "Windows (VHD) status" \
                    back "‹ Back")" || continue
                [[ "$t" == back ]] && continue
                menu_dispatch "$t" ;;
            recovery)
                local t; t="$(menu_pick "Recovery & rollback" \
                    doctor "Boot diagnostics (powos doctor)" \
                    rollback "Layer rollback options" \
                    back "‹ Back")" || continue
                [[ "$t" == back ]] && continue
                menu_dispatch "$t" ;;
        esac
    done
}
