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
reload_mark_applied() { [[ -d "$1/.git" ]] && git -C "$1" rev-parse HEAD > "$RELOAD_APPLIED" 2>/dev/null || true; }

# After a successful live apply, act on change-types that a file copy alone
# doesn't finish: systemd units (daemon-reload/restart), distrobox.ini
# (re-assemble), overlays/sources (rebuild). Each is an opt-in prompt.
# Call BEFORE reload_mark_applied so the change list is still accurate.
reload_post_apply() {
    local changed; changed="$(reload_changed_files "$1")"
    [[ -n "$changed" ]] || return 0

    if grep -qE '^systemd/.*\.(service|timer|socket)$' <<<"$changed"; then
        plog "systemd units changed → daemon-reload"
        sudo systemctl daemon-reload 2>/dev/null || true
        local units u; units=$(grep -oE 'powos-[a-z-]+\.(service|timer|socket)' <<<"$changed" | sort -u | tr '\n' ' ')
        if [[ -n "$units" ]] && confirm "Restart changed units? ($units)"; then
            for u in $units; do sudo systemctl restart "$u" 2>/dev/null && pok "restarted $u" || pwarn "couldn't restart $u"; done
        fi
    fi
    if grep -qE '^containers/distrobox\.ini$' <<<"$changed" && confirm "distrobox.ini changed — re-assemble containers now?"; then
        powos containers assemble || pwarn "assemble reported issues."
    fi
    if grep -qE '^(overlays|sources)/' <<<"$changed" && confirm "overlays/sources changed — rebuild overlays now?"; then
        powos update overlays || pwarn "overlay rebuild reported issues."
    fi
}

# SAFETY #1: never apply a file with a syntax error — that can brick the CLI
# live. bash -n every changed shell file, py_compile every changed .py. Returns
# non-zero (and prints the errors) if anything is broken.
reload_syntax_check() {
    local src="$1" bad=0 f err; err="$(mktemp)"
    while IFS= read -r f; do
        [[ -f "$src/$f" ]] || continue
        case "$f" in
            *.sh|bin/powos|bin/powos-boot|bin/pinstall|bin/premove)
                bash -n "$src/$f" 2>"$err" || { perr "shell syntax error in $f:"; sed 's/^/      /' "$err"; bad=1; } ;;
            *.py)
                python3 -m py_compile "$src/$f" 2>"$err" || { perr "python syntax error in $f:"; sed 's/^/      /' "$err"; bad=1; } ;;
        esac
    done < <(reload_changed_files "$src")
    rm -f "$err"
    return "$bad"
}

# SAFETY #2: snapshot the live CLI, apply, then smoke-test that `powos` still
# runs. If the applied version is broken, restore the snapshot — atomically, in
# ONE root shell (so it's a single sudo prompt and can't half-apply). Exit codes:
# 0 = applied OK · 42 = was broken, restored · other = update self failed.
reload_apply_live() {
    local runner=(sudo bash); [[ ${EUID:-$(id -u)} -eq 0 ]] && runner=(bash)
    "${runner[@]}" -s -- "$1" <<'ROOT'
set -uo pipefail
src="$1"; bk="/run/powos/reload-backup.$$"
mkdir -p "$bk"
cp -a /usr/bin/powos "$bk/powos" 2>/dev/null || true
cp -a /usr/lib/powos "$bk/lib"   2>/dev/null || true
powos update self --from "$src"; rc=$?
[[ $rc -ne 0 ]] && { rm -rf "$bk"; exit "$rc"; }
if ! /usr/bin/powos version >/dev/null 2>&1 && ! /usr/bin/powos help >/dev/null 2>&1; then
    cp -a "$bk/powos" /usr/bin/powos 2>/dev/null || true
    [[ -d "$bk/lib" ]] && cp -a "$bk/lib/." /usr/lib/powos/ 2>/dev/null || true
    rm -rf "$bk"; exit 42
fi
rm -rf "$bk"
ROOT
}

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

    # SAFETY: refuse to apply anything with a syntax error (would brick the CLI).
    if ! reload_syntax_check "$src"; then
        perr "Refusing to apply until the syntax errors above are fixed."
        return 1
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
    reload_apply_live "$src"; local rc=$?
    if [[ $rc -eq 42 ]]; then
        perr "The applied CLI failed to run — I restored the previous version."
        perr "Fix the error in $src, then 'powos reload' again."
        return 1
    elif [[ $rc -ne 0 ]]; then
        perr "update self failed (rc=$rc)."; return "$rc"
    fi
    reload_post_apply "$src"      # systemd reload / distrobox reassemble / overlay rebuild
    reload_mark_applied "$src"
    pok "Live & verified. For base/package changes: powos reload --build"
}
