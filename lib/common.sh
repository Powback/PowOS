#!/bin/bash
# common.sh - shared helpers for PowOS lib/*.sh. Source this instead of
# re-declaring colors and log functions in every file:
#
#   source "${POWOS_LIB:-/usr/lib/powos}/common.sh"
#   POWOS_TAG=cuda        # sets the [tag] prefix for plog/pok/pwarn/perr
#
#   plog "building…"      ->  [cuda] building…      (cyan)
#   pok  "done"           ->  [cuda] done           (green)
#   pwarn "heads up"      ->  [cuda] heads up        (yellow)
#   perr "broke"          ->  [cuda] broke           (red, to stderr)
#   need_root || return   ->  errors + fails if not root
#   confirm "Reboot?"     ->  y/N prompt, true on yes
#
# Idempotent: safe to source multiple times.
[[ -n "${_POWOS_COMMON_SH:-}" ]] && return 0
_POWOS_COMMON_SH=1

# ANSI-C quoting ($'...') stores real ESC bytes, so these render correctly via
# echo -e / printf AND inside `cat` heredocs. A plain '\033[..' literal only
# works with echo -e/printf and leaks raw \033 when emitted through cat.
# works with echo -e/printf and leaks raw \033 through cat).
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'
CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; NC=$'\033[0m'

plog()  { echo -e "${CYAN}[${POWOS_TAG:-powos}]${NC} $*"; }
pok()   { echo -e "${GREEN}[${POWOS_TAG:-powos}]${NC} $*"; }
pwarn() { echo -e "${YELLOW}[${POWOS_TAG:-powos}]${NC} $*"; }
perr()  { echo -e "${RED}[${POWOS_TAG:-powos}]${NC} $*" >&2; }

need_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || { perr "${1:-This} needs root — re-run with sudo."; return 1; }; }
confirm()   { local a; read -rp "${1:-Proceed?} [y/N] " a; [[ "$a" =~ ^[Yy]$ ]]; }

# ── sysext unmerge / remerge dance ──────────────────────────────────
# Merged systemd-sysext extensions sit as a read-only overlay on /usr,
# causing EROFS for rpm-ostree apply-live, bootc usr-overlay, and cp
# into /usr. These helpers bracket any /usr-writing operation:
#
#   sysext_unmerge_if_needed   # saves state, unmerges if extensions active
#   <do your /usr writes>
#   sysext_remerge_if_needed   # re-merges if we unmerged earlier
#
# Safe to call even when no extensions are merged (no-op). State is
# tracked via _POWOS_SYSEXT_WAS_MERGED so nested calls are idempotent.

sysext_unmerge_if_needed() {
    _POWOS_SYSEXT_WAS_MERGED=""
    local merged
    merged=$(systemd-sysext status 2>/dev/null | awk '$1=="/usr"{print $2}')
    if [[ -n "$merged" && "$merged" != "none" ]]; then
        plog "Unmerging systemd-sysext extensions for /usr write access…"
        sudo systemd-sysext unmerge 2>/dev/null || true
        _POWOS_SYSEXT_WAS_MERGED=1
    fi
}

sysext_remerge_if_needed() {
    # Re-merge if we unmerged, OR if any extensions exist on disk (a fresh
    # bootc usr-overlay also silently drops merged sysexts).
    if [[ -n "${_POWOS_SYSEXT_WAS_MERGED:-}" ]] || [[ -n "$(ls -A /var/lib/extensions 2>/dev/null)" ]]; then
        if sudo systemd-sysext refresh 2>/dev/null; then
            pok "systemd-sysext extensions re-merged."
        else
            pwarn "sysext refresh failed — run 'sudo systemd-sysext refresh' manually."
        fi
    fi
    _POWOS_SYSEXT_WAS_MERGED=""
}
