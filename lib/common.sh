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

# ── Canonical source-checkout resolution ─────────────────────────────────────
# ONE resolver, shared by `powos reload` and `powos self`, so the two halves of
# the dev loop can never disagree about which tree they are editing.
#
# They used to disagree: reload auto-discovered your real checkout while self
# hardcoded /var/lib/powos/src. So `powos self test` and `powos reload` edited
# DIFFERENT trees, and the bundled one silently rotted — it is only refreshed by
# an image rebuild, so a machine that had not rebuilt in days was editing
# days-old code with nothing saying so. `powos self reseed` exists purely to
# paper over that. Resolving through one function removes the class of bug.
#
# Order: explicit arg > remembered (~/.config/powos/dev-src) > $POWOS_DEV_SRC >
# common checkout locations > the bundled /var/lib/powos/src as LAST resort.
# Bundled-last is the important part: it stays available for "no external
# checkout, edit PowOS from inside the image", but stops being the default the
# moment a real checkout exists.

# Invoking user's home even under sudo, so detection + memory find ~/PowOS.
powos_src_home() {
    if [[ -n "${SUDO_USER:-}" ]]; then getent passwd "$SUDO_USER" | cut -d: -f6
    else echo "$HOME"; fi
}

POWOS_SRC_MEMORY="${POWOS_DEV_SRC_FILE:-$(powos_src_home)/.config/powos/dev-src}"

powos_src_valid() { [[ -n "${1:-}" && -f "$1/bin/powos" && -f "$1/Containerfile" ]]; }

powos_src_find() {
    local explicit="${1:-}" H c s
    H="$(powos_src_home)"
    if [[ -n "$explicit" ]]; then
        powos_src_valid "$explicit" && { ( cd "$explicit" && pwd ); return 0; }
        perr "Not a PowOS checkout: $explicit"; return 1
    fi
    if [[ -f "$POWOS_SRC_MEMORY" ]]; then
        s="$(cat "$POWOS_SRC_MEMORY" 2>/dev/null)"
        powos_src_valid "$s" && { echo "$s"; return 0; }
    fi
    powos_src_valid "${POWOS_DEV_SRC:-}" && { ( cd "$POWOS_DEV_SRC" && pwd ); return 0; }
    for c in "$H/PowOS" "$H/powos" "$H/src/PowOS" "$H/Projects/PowOS" "$PWD"; do
        [[ -d "$c/.git" ]] && powos_src_valid "$c" && { ( cd "$c" && pwd ); return 0; }
    done
    [[ -d /var/lib/powos/src/.git ]] && powos_src_valid /var/lib/powos/src && { echo /var/lib/powos/src; return 0; }
    return 1
}

powos_src_remember() {
    mkdir -p "$(dirname "$POWOS_SRC_MEMORY")" 2>/dev/null && \
        echo "$1" > "$POWOS_SRC_MEMORY" 2>/dev/null || true
}

# Loud, non-fatal warning when the resolved tree is behind its upstream. Silent
# staleness is the failure this resolver exists to prevent: a tree can sit N
# commits behind for days and nothing says so until a build ships old code.
# Never fails the caller — a missing remote or no network must not block a build.
powos_src_staleness() {
    local src="${1:-}" ref behind
    [[ -d "$src/.git" ]] || return 0
    ref=$(git -C "$src" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null) || return 0
    [[ -n "$ref" ]] || return 0
    behind=$(git -C "$src" rev-list --count "HEAD..$ref" 2>/dev/null) || return 0
    if [[ "${behind:-0}" -gt 0 ]]; then
        pwarn "$src is $behind commit(s) behind $ref."
        pwarn "  Fetch first, or you will build/ship stale code: git -C $src pull --ff-only"
    fi
    return 0
}
