#!/bin/bash
# reload.sh - dead-simple "apply my local PowOS changes to this machine".
# Auto-finds your source checkout, remembers it, and hot-applies live (no reboot).
# The point: you never have to remember paths or flags — just `powos reload`.
#
#   powos reload            Apply local changes LIVE + PERSISTENT (survives reboot)
#   powos reload --drop     Roll back — remove the overlay, back to the image's CLI
#   powos reload --once     Apply live but ephemeral (cleared on next reboot)
#   powos reload --pull     git pull the checkout first, then apply
#   powos reload --build    Bake into a local image + bootc switch (base/pkg changes)
#   powos reload --where    Print which source it will use
#   powos reload /path      Use (and remember) a specific checkout
#
# On writable /usr (legacy USB overlay) it copies into /usr. On read-only /usr
# (bootc/composefs) it applies via a systemd-sysext overlay — live, no reboot,
# composefs untouched. Persistent by default (/var/lib/extensions, auto-merged at
# boot); --once uses /run (ephemeral). Durable/shippable change → --build.
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

# Warn (and offer to pull) when the checkout is behind its upstream, so a plain
# 'powos reload' never silently applies stale code. Best-effort: a bounded fetch
# that skips cleanly when offline / no remote.
reload_check_behind() {
    local src="$1" up behind
    [[ -d "$src/.git" ]] || return 0
    timeout 8 git -C "$src" fetch --quiet 2>/dev/null || return 0
    up="$(git -C "$src" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)"
    [[ -n "$up" ]] || up="origin/master"
    behind="$(git -C "$src" rev-list --count "HEAD..$up" 2>/dev/null)"
    [[ "$behind" =~ ^[0-9]+$ ]] && (( behind > 0 )) || return 0
    pwarn "Checkout is $behind commit(s) behind $up — plain reload would apply STALE code."
    if confirm "Pull latest first?"; then
        git -C "$src" pull --rebase 2>&1 | tail -3 || \
            pwarn "Pull failed (uncommitted changes?). Commit/stash then retry, or 'powos reload --live' to apply as-is."
    else
        pwarn "Applying your checkout as-is (still $behind behind $up)."
    fi
}

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

# Read-only /usr (bootc/composefs) → can't cp into /usr; use systemd-sysext.
# Writable /usr (legacy RAM-overlay USB install) → direct copy is fine.
reload_usr_ro() {
    findmnt -no OPTIONS /usr 2>/dev/null | grep -qw ro && return 0
    findmnt -no OPTIONS /    2>/dev/null | grep -qw ro && return 0
    return 1
}

# Apply on a read-only /usr the sanctioned way: stage the dev CLI as a
# systemd-sysext extension in /run/extensions (EPHEMERAL — gone on reboot, so it
# never shadows a future image), merge it live, smoke-test, unmerge if broken.
# composefs is never touched. One root shell. Exit: 0 ok · 3 refresh · 4 not
# merged · 42 broken+reverted.
reload_apply_sysext() {
    # $1 = source checkout, $2 = extension base dir:
    #   /run/extensions       ephemeral (default, cleared on reboot)
    #   /var/lib/extensions   persistent (systemd-sysext auto-merges at boot)
    local runner=(sudo bash); [[ ${EUID:-$(id -u)} -eq 0 ]] && runner=(bash)
    "${runner[@]}" -s -- "$1" "${2:-/run/extensions}" <<'ROOT'
set -uo pipefail
src="$1"; ext="$2/powos-dev"
rm -rf "$ext"
mkdir -p "$ext/usr/bin" "$ext/usr/lib/powos" "$ext/usr/lib/extension-release.d"
for b in powos powos-boot pinstall premove; do
    [[ -f "$src/bin/$b" ]] && install -m755 "$src/bin/$b" "$ext/usr/bin/$b"
done
# lib/ maps to /usr/lib/powos/ (dracut is boot-time, not a runtime CLI dep)
rsync -a --exclude 'dracut/' "$src/lib/" "$ext/usr/lib/powos/"
[[ -d "$src/overlays" ]] && rsync -a "$src/overlays/" "$ext/usr/lib/powos/overlays/"
cp -a "$src"/systemd/powos-* "$ext/usr/lib/powos/" 2>/dev/null || true
# ID=_any → matches any base version (survives bootc upgrades)
printf 'ID=_any\n' > "$ext/usr/lib/extension-release.d/extension-release.powos-dev"
# config lives on writable /etc — apply directly, not via sysext
[[ -d "$src/config" ]] && cp -a "$src/config/." /etc/powos/ 2>/dev/null || true
systemd-sysext refresh >/dev/null 2>&1 || { echo "sysext refresh failed" >&2; exit 3; }
systemd-sysext status 2>/dev/null | grep -q powos-dev || { echo "sysext did not merge" >&2; exit 4; }
if ! /usr/bin/powos version >/dev/null 2>&1 && ! /usr/bin/powos help >/dev/null 2>&1; then
    rm -rf "$ext"; systemd-sysext refresh >/dev/null 2>&1 || true
    echo "applied CLI broken — reverted" >&2; exit 42
fi
ROOT
}

reload_drop_sysext() {
    local runner=(sudo bash); [[ ${EUID:-$(id -u)} -eq 0 ]] && runner=(bash)
    "${runner[@]}" -c 'rm -rf /run/extensions/powos-dev /var/lib/extensions/powos-dev; systemd-sysext refresh >/dev/null 2>&1 || true'
    pok "Dropped the powos-dev sysext overlay — back to the image's CLI."
}

cmd_reload() {
    local do_pull=0 do_build=0 where=0 force_live=0 do_drop=0 do_once=0 explicit=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pull)     do_pull=1 ;;
            --build)    do_build=1 ;;
            --live)     force_live=1 ;;
            --drop)     do_drop=1 ;;
            --once)     do_once=1 ;;
            --where)    where=1 ;;
            -h|--help)  sed -n '2,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; return 0 ;;
            -*)         perr "Unknown flag: $1 (try: --pull --build --where)"; return 1 ;;
            *)          explicit="$1" ;;
        esac
        shift
    done

    (( do_drop )) && { reload_drop_sysext; return 0; }

    local src
    if ! src="$(reload_find "$explicit")"; then
        perr "Couldn't find your PowOS source checkout."
        perr "Point me at it once and I'll remember it forever:"
        perr "  powos reload ~/path/to/PowOS"
        return 1
    fi
    reload_remember "$src"
    (( where )) && { pok "Local source: $src"; return 0; }

    (( do_pull )) || reload_check_behind "$src"   # never silently apply stale code

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
        plog "Baking $src into a local image + switch…"
        reload_usr_ro && reload_drop_sysext   # image will carry it; drop overlay so it can't shadow the new base
        POWOS_BUILD_CONTEXT="$src" source "${POWOS_LIB:-/usr/lib/powos}/build-image.sh"
        POWOS_BUILD_CONTEXT="$src" cmd_build_image --switch
        local rc=$?
        (( rc == 0 )) && reload_mark_applied "$src"
        return $rc
    fi

    local rc ro=0 extbase=/var/lib/extensions
    (( do_once )) && extbase=/run/extensions
    if reload_usr_ro; then
        ro=1
        plog "Read-only /usr → systemd-sysext overlay ($([[ $extbase == /var/* ]] && echo 'persistent' || echo 'ephemeral'))…"
        reload_apply_sysext "$src" "$extbase"; rc=$?
    else
        plog "Writable /usr → applying directly (no reboot)…"
        reload_apply_live "$src"; rc=$?
    fi
    case "$rc" in
        0)  : ;;
        42) perr "The applied CLI failed to run — reverted. Fix $src, then 'powos reload' again."; return 1 ;;
        3)  perr "systemd-sysext refresh failed — see 'systemctl status systemd-sysext'."; return 1 ;;
        4)  perr "sysext didn't merge (extension-release mismatch?). Inspect: systemd-sysext status"; return 1 ;;
        *)  perr "apply failed (rc=$rc)."; return "$rc" ;;
    esac
    reload_post_apply "$src"      # systemd reload / distrobox reassemble / overlay rebuild
    reload_mark_applied "$src"
    if (( ro )); then
        if (( do_once )); then
            pok "Live via sysext overlay (ephemeral — cleared on reboot). composefs untouched."
        else
            pok "Live & PERSISTENT — auto-merged on every boot. composefs untouched."
            pok "Roll back: powos reload --drop   ·   Bake into image: powos reload --build"
        fi
    else
        pok "Live & persisted. For base/package changes: powos reload --build"
    fi
}
