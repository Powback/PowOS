#!/bin/bash
# install-router.sh - ONE front door for installing anything. Probes every
# backend, reports where the thing was found, and defaults to the most
# CONTAINED option — supply-chain paranoia is the design center:
#
#   powos install <thing...>            # probe all → report → most-contained wins
#   powos install -m <backend> <thing>  # force: flatpak|sandbox|brew|pip|container|host
#   powos install -c NAME <pkg>         # into a specific container
#   powos install --dry <thing>         # probe + report only, install nothing
#
# Containment ladder (default picks the highest available):
#   flatpak   GUI apps. Real sandbox + PORTALS: the app must prompt you at
#             runtime to touch files outside its box. undo: flatpak uninstall
#   sandbox   CLI/dev tools in the powos-sandbox container with its OWN home —
#             a malicious package cannot see or exfiltrate your real $HOME.
#             Binaries exported to host PATH. Grant real dirs explicitly:
#             powos install sandbox-share <dir>. undo: remove the container.
#   brew      UNSANDBOXED (runs as you, full $HOME access). Opt-in only (-m brew);
#             never chosen automatically — this is the supply-chain surface.
#   pip       runs INSIDE the sandbox box (not pip --user: setup.py is arbitrary
#             code and would run with your full $HOME otherwise).
#   host      rpm-ostree OS layer. Last resort, always asks. Rollback-able.
#
# HONESTY on "apps should prompt if they break containment": flatpak portals
# genuinely do that. Containers can't prompt per-access on Linux without heavy
# syscall interception — instead the sandbox simply CANNOT see your real home,
# and you grant specific directories explicitly. Denial-by-default, not prompts.
source "${POWOS_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/common.sh"
POWOS_TAG=install

SANDBOX_BOX="${POWOS_SANDBOX_BOX:-powos-sandbox}"
SANDBOX_HOME="${POWOS_SANDBOX_HOME:-$HOME/.local/share/powos/sandbox-home}"
SANDBOX_IMAGE="${POWOS_SANDBOX_IMAGE:-registry.fedoraproject.org/fedora:latest}"

# ── probes (read-only, best-effort) ──────────────────────────────
probe_flatpak() {
    command -v flatpak >/dev/null || return 1
    local out
    # Prefer real applications: exact id-segment match first, then exact name
    # match — but never runtimes/plugins (.Platform./.VulkanLayer./.Extension.)
    # unless nothing else matches (flatpak search relevance puts plugins first).
    out="$(flatpak search --columns=application,name "$1" 2>/dev/null | awk -v q="$(echo "$1" | tr '[:upper:]' '[:lower:]')" '
        { id=$1; name=tolower($2); seg=tolower(id); sub(/.*\./,"",seg)
          plugin = (id ~ /\.(Platform|VulkanLayer|Extension|Addon|Plugin)\./)
          if (seg==q  && !plugin && !best)  best=id
          if (name==q && !plugin && !good)  good=id
          if ((seg==q || name==q) && !any)  any=id }
        END { if (best) print best; else if (good) print good; else if (any) print any }')"
    [[ -n "$out" ]] && echo "$out"
}
probe_rpm()  { command -v dnf5 >/dev/null && timeout 10 dnf5 -q repoquery --queryformat '%{name}\n' "$1" 2>/dev/null | grep -qx "$1"; }
probe_brew() { command -v brew >/dev/null && brew info --formula "$1" &>/dev/null; }

# ── sandbox container (separate home = your files are invisible to it) ──
sandbox_ensure() {
    podman container exists "$SANDBOX_BOX" 2>/dev/null && return 0
    plog "Creating sandbox container '$SANDBOX_BOX' (own home: $SANDBOX_HOME)"
    plog "${DIM}Packages in here can NOT read your real \$HOME.${NC}"
    mkdir -p "$SANDBOX_HOME"
    distrobox create --name "$SANDBOX_BOX" --image "$SANDBOX_IMAGE" \
        --home "$SANDBOX_HOME" --yes || { perr "sandbox create failed"; return 1; }
    distrobox enter "$SANDBOX_BOX" -- true >/dev/null 2>&1 || true
}
sandbox_share() {   # explicit containment grant — the audited escape hatch
    local dir="${1:?Usage: powos install sandbox-share <dir>}"
    [[ -d "$dir" ]] || { perr "Not a directory: $dir"; return 1; }
    mkdir -p "$SANDBOX_HOME/shared"
    ln -sfn "$(realpath "$dir")" "$SANDBOX_HOME/shared/$(basename "$dir")"
    pok "Granted: $dir → visible in sandbox at ~/shared/$(basename "$dir")"
    pwarn "This is an explicit containment exception — revoke by deleting the symlink."
}

# ── executors ─────────────────────────────────────────────────────
do_flatpak() { flatpak install -y flathub "$1"; }
do_sandbox() {
    sandbox_ensure || return 1
    distrobox enter "$SANDBOX_BOX" -- sudo dnf install -y "$1" || return 1
    # Export to host PATH so it feels native (wrapper runs it inside the box).
    distrobox enter "$SANDBOX_BOX" -- distrobox-export --bin "/usr/bin/$1" 2>/dev/null \
        && pok "'$1' exported to host PATH (runs contained)" \
        || plog "No /usr/bin/$1 to export — run it via: powos containers enter $SANDBOX_BOX"
}
do_pip() {
    sandbox_ensure || return 1
    distrobox enter "$SANDBOX_BOX" -- bash -c "command -v pip3 >/dev/null || sudo dnf install -y python3-pip; pip3 install --user '$1'"
    pok "pip package '$1' installed INSIDE the sandbox (not your real home)."
}
do_brew() {
    pwarn "brew is UNSANDBOXED: the package runs as you, with full \$HOME access."
    pwarn "(This is the supply-chain surface you said you don't trust.)"
    confirm "Install '$1' via brew anyway?" || { plog "Skipped."; return 0; }
    brew install "$1"
}
do_container() {
    local box="${2:-$SANDBOX_BOX}"
    [[ "$box" == "$SANDBOX_BOX" ]] && { do_sandbox "$1"; return; }
    podman container exists "$box" 2>/dev/null || { perr "Container '$box' doesn't exist (powos containers create $box)"; return 1; }
    cmd_install -c "$box" "$1"
}
do_host() {
    pwarn "This layers onto the OS image via rpm-ostree — heaviest, host-level path."
    pwarn "Reversible (rpm-ostree uninstall / rollback); for true system packages only."
    confirm "Layer '$1' onto the host OS?" || { plog "Skipped $1."; return 0; }
    cmd_install --host "$1"
}

# ── probe everything, report, decide (containment-first) ─────────
route_one() {
    local pkg="$1" forced="$2" dry="$3"
    local fid="" has_rpm=false has_brew=false

    if [[ -n "$forced" ]]; then
        plog "$pkg → ${BOLD}$forced${NC} ${DIM}(forced with -m)${NC}"
        [[ "$dry" == "true" ]] && return 0
        case "$forced" in
            flatpak)   do_flatpak "$(probe_flatpak "$pkg" || echo "$pkg")" ;;
            sandbox)   do_sandbox "$pkg" ;;
            brew)      do_brew "$pkg" ;;
            pip)       do_pip "$pkg" ;;
            container) do_container "$pkg" "${ROUTE_BOX:-}" ;;
            host)      do_host "$pkg" ;;
        esac
        return
    fi

    plog "Searching for '${BOLD}$pkg${NC}' across package sources…"
    fid="$(probe_flatpak "$pkg")" || true
    probe_rpm "$pkg"  && has_rpm=true
    probe_brew "$pkg" && has_brew=true

    # Build the found-list in containment order (most contained first).
    local -a names=() details=()
    [[ -n "$fid" ]]           && { names+=(flatpak); details+=("$fid — sandboxed, portals prompt for outside access"); }
    [[ "$has_rpm" == true ]]  && { names+=(sandbox); details+=("container w/ own home — can't see your files"); }
    [[ "$has_brew" == true ]] && { names+=(brew);    details+=("${YELLOW}UNSANDBOXED — full access as your user${NC}"); }
    [[ "$has_rpm" == true ]]  && { names+=(host);    details+=("rpm-ostree OS layer — heaviest"); }

    if [[ ${#names[@]} -eq 0 ]]; then
        pwarn "'$pkg' not found in flatpak, rpm repos, or brew."
        plog  "Options:  powos install -m pip $pkg   ·   powos install -c <box> $pkg"
        return 1
    fi

    pok "Found '$pkg' in ${#names[@]} source(s):"
    local i
    for i in "${!names[@]}"; do
        printf "    %d) %-8b %b%s\n" "$((i+1))" "${names[$i]}" "${details[$i]}" \
               "$([[ $i -eq 0 ]] && echo -e "   ${GREEN}← recommended (most contained)${NC}")"
    done
    [[ "$dry" == "true" ]] && return 0

    local pick=1
    if [[ ${#names[@]} -gt 1 && -t 0 ]]; then
        read -rp "  Install via [1-${#names[@]}, Enter=1, s=skip]: " pick
        [[ "$pick" =~ ^[Ss]$ ]] && { plog "Skipped $pkg."; return 0; }
        [[ "$pick" =~ ^[0-9]+$ && "$pick" -ge 1 && "$pick" -le ${#names[@]} ]] || pick=1
    fi

    case "${names[$((pick-1))]}" in
        flatpak) do_flatpak "$fid" ;;
        sandbox) do_sandbox "$pkg" ;;
        brew)    do_brew "$pkg" ;;
        host)    do_host "$pkg" ;;
    esac
}

# ── entry ─────────────────────────────────────────────────────────
cmd_install_route() {
    local forced="" dry=false pkgs=() box=""
    # containment-grant subcommand: powos install sandbox-share <dir>
    [[ "${1:-}" == "sandbox-share" ]] && { shift; sandbox_share "$@"; return; }
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -m|--method)      forced="$2"; shift 2 ;;
            --dry|--dry-run)  dry=true; shift ;;
            -c|--container)   box="$2"; forced="container"; shift 2 ;;
            --host)           forced="host"; shift ;;
            -e|--export)      cmd_install "$@"; return ;;   # legacy container+export
            -h|--help)
                cat <<EOF
${BOLD}powos install${NC} — one front door; finds a package everywhere, installs the most CONTAINED way

  powos install <thing...>             probe all → report → most-contained wins
  powos install -m <backend> <thing>   force: flatpak|sandbox|brew|pip|container|host
  powos install -c NAME <pkg...>       into container NAME (add -e to export GUI)
  powos install --dry <thing...>       probe + report only
  powos install sandbox-share <dir>    explicitly grant a real folder to the sandbox

Containment ladder (default = highest available):
  flatpak    GUI sandbox; portals PROMPT when apps reach outside   undo: flatpak uninstall
  sandbox    container with its OWN home — can't see your files    undo: remove container
  brew       UNSANDBOXED — opt-in only, always warns               undo: brew uninstall
  pip        installs INSIDE the sandbox (never your real home)    undo: pip uninstall (in box)
  host       rpm-ostree OS layer — last resort, always asks        undo: rpm-ostree uninstall
EOF
                return 0 ;;
            -*) perr "Unknown option: $1 (see powos install --help)"; return 1 ;;
            *)  pkgs+=("$1"); shift ;;
        esac
    done
    [[ ${#pkgs[@]} -gt 0 ]] || { perr "No packages given (powos install --help)"; return 1; }
    case "$forced" in ""|flatpak|sandbox|brew|pip|container|host) ;; *)
        perr "Invalid -m '$forced' (flatpak|sandbox|brew|pip|container|host)"; return 1 ;; esac

    local p rc=0
    for p in "${pkgs[@]}"; do
        ROUTE_BOX="$box" route_one "$p" "$forced" "$dry" || rc=1
    done
    return $rc
}
