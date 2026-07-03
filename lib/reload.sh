#!/bin/bash
# reload.sh - dead-simple "apply my local PowOS changes to this machine".
# Auto-finds your source checkout, remembers it, and hot-applies live (no reboot).
# The point: you never have to remember paths or flags — just `powos reload`.
#
#   powos reload            Apply local script/config changes LIVE (no reboot)
#   powos reload --pull     git pull the checkout first, then apply
#   powos reload --build    Full local image build + bootc switch (base/pkg changes)
#   powos reload --where    Just print which source it will use
#   powos reload /path      Use (and remember) a specific checkout
#
# First run auto-detects ~/PowOS (and friends) and saves it, so after that it's
# literally just `powos reload`. Run it as your normal user — it sudo's only the
# privileged apply step itself.
set -uo pipefail
source "${POWOS_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/common.sh"
POWOS_TAG=reload

# Invoking user's home even under sudo, so detection + memory find ~/PowOS.
reload_home() {
    if [[ -n "${SUDO_USER:-}" ]]; then getent passwd "$SUDO_USER" | cut -d: -f6
    else echo "$HOME"; fi
}
RELOAD_MEMORY="${POWOS_DEV_SRC_FILE:-$(reload_home)/.config/powos/dev-src}"

reload_valid() { [[ -n "$1" && -f "$1/bin/powos" && -f "$1/Containerfile" ]]; }

reload_find() {
    local explicit="${1:-}" H c s
    H="$(reload_home)"
    if [[ -n "$explicit" ]]; then
        reload_valid "$explicit" && { ( cd "$explicit" && pwd ); return 0; }
        perr "Not a PowOS checkout: $explicit"; return 1
    fi
    # remembered
    if [[ -f "$RELOAD_MEMORY" ]]; then s="$(cat "$RELOAD_MEMORY" 2>/dev/null)"; reload_valid "$s" && { echo "$s"; return 0; }; fi
    # env override
    reload_valid "${POWOS_DEV_SRC:-}" && { ( cd "$POWOS_DEV_SRC" && pwd ); return 0; }
    # common checkouts (prefer a git checkout over the bundled src)
    for c in "$H/PowOS" "$H/powos" "$H/src/PowOS" "$H/Projects/PowOS" "$PWD"; do
        [[ -d "$c/.git" ]] && reload_valid "$c" && { ( cd "$c" && pwd ); return 0; }
    done
    # last resort: bundled source if it's a real git repo
    [[ -d /var/lib/powos/src/.git ]] && reload_valid /var/lib/powos/src && { echo /var/lib/powos/src; return 0; }
    return 1
}

reload_remember() { mkdir -p "$(dirname "$RELOAD_MEMORY")" 2>/dev/null && echo "$1" > "$RELOAD_MEMORY" 2>/dev/null || true; }

# Changes to these paths are BAKED AT IMAGE BUILD TIME — `update self` can't
# hot-apply them, so they need a full build + switch (+reboot) to take effect.
RELOAD_NEEDS_BUILD_RE='^(Containerfile|lib/dracut/|config/bootc/|build/)'
RELOAD_APPLIED="${POWOS_DEV_APPLIED_FILE:-$(reload_home)/.config/powos/dev-applied}"

# Files changed in the checkout since the last successful reload: committed diff
# (last-applied..HEAD) ∪ uncommitted working tree. Prints repo-relative paths.
reload_changed_files() {
    local src="$1" last=""
    [[ -d "$src/.git" ]] || return 0
    [[ -f "$RELOAD_APPLIED" ]] && last="$(cat "$RELOAD_APPLIED" 2>/dev/null)"
    {
        git -C "$src" status --porcelain 2>/dev/null | sed 's/^...//'
        if [[ -n "$last" ]] && git -C "$src" cat-file -e "$last" 2>/dev/null; then
            git -C "$src" diff --name-only "$last" HEAD 2>/dev/null
        fi
    } | sort -u | sed '/^$/d'
}
reload_needs_build() { reload_changed_files "$1" | grep -qE "$RELOAD_NEEDS_BUILD_RE"; }
reload_mark_applied() { [[ -d "$1/.git" ]] && git -C "$1" rev-parse HEAD 2>/dev/null > "$RELOAD_APPLIED" 2>/dev/null || true; }

cmd_reload() {
    local do_pull=0 do_build=0 where=0 force_live=0 explicit=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pull)     do_pull=1 ;;
            --build)    do_build=1 ;;
            --live)     force_live=1 ;;
            --where)    where=1 ;;
            -h|--help)  sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; return 0 ;;
            -*)         perr "Unknown flag: $1 (try: --pull --build --where)"; return 1 ;;
            *)          explicit="$1" ;;
        esac
        shift
    done

    local src
    if ! src="$(reload_find "$explicit")"; then
        perr "Couldn't find your PowOS source checkout."
        perr "Point me at it once and I'll remember it forever:"
        perr "  powos reload ~/path/to/PowOS"
        return 1
    fi
    reload_remember "$src"
    (( where )) && { pok "Local source: $src"; return 0; }

    if (( do_pull )) && [[ -d "$src/.git" ]]; then
        plog "Pulling latest in $src…"
        git -C "$src" pull --rebase 2>&1 | tail -2 || pwarn "git pull had issues (continuing with what's there)."
    fi

    # Auto-detect whether the local changes actually need a full build.
    if (( ! do_build && ! force_live )) && reload_needs_build "$src"; then
        pwarn "These changes are baked at build time — a live apply WON'T pick them up:"
        reload_changed_files "$src" | grep -E "$RELOAD_NEEDS_BUILD_RE" | sed 's/^/    • /'
        echo "    (Containerfile / dracut / kernel-args need a full image build + reboot.)"
        if confirm "Build the image locally + switch now?"; then
            do_build=1
        else
            pwarn "Applying only the hot-reloadable parts; the above wait for 'powos reload --build'."
        fi
    fi

    if (( do_build )); then
        plog "Full local image build + switch from $src…"
        POWOS_BUILD_CONTEXT="$src" source "${POWOS_LIB:-/usr/lib/powos}/build-image.sh"
        POWOS_BUILD_CONTEXT="$src" cmd_build_image --switch
        local rc=$?
        (( rc == 0 )) && reload_mark_applied "$src"
        return $rc
    fi

    plog "Applying $src live (no reboot)…"
    if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
        powos update self --from "$src"
    else
        sudo powos update self --from "$src"   # only the apply needs root
    fi
    reload_mark_applied "$src"
    pok "Live. For base/package changes use: powos reload --build"
}
