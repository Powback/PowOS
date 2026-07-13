#!/bin/bash
# mods/modlist.sh - PowOS automated-modlist installer (Wabbajack, native).
#
# This is the general foundation for "install a whole curated modlist in one
# shot" — the class of thing Star Wars Genesis (Starfield), Fallout London,
# Tale of Two Wastelands lists, Tuxborn, Nordic Souls, etc. all are. They are
# NOT special snowflakes: every one is a Wabbajack modlist — a .wabbajack file
# that, when replayed, downloads a few hundred Nexus mods, binary-patches them,
# and lays down a *portable Mod Organizer 2* tree you then run the game through
# via a script extender (SFSE/SKSE/F4SE) under Proton.
#
# So we don't hard-code Genesis (or any single list). We wrap the engine that
# replays ANY Wabbajack list on Linux, and everything Genesis-shaped just works.
#
# ─── Why Jackify's engine, and NOT Wine/Bottles ──────────────────────────────
# The old PowOS modding path ran Windows managers (Vortex) inside a Bottles
# Flatpak. That has been slow and flaky in practice. The Linux mod scene long
# ago moved off "Wabbajack-under-Wine": the reliable, Steam-Deck-proven path is
# a NATIVE engine (no Wine for the install step) that produces the MO2 tree on
# disk, then runs the *game* through native Steam + Proton (GE-Proton).
#
# Jackify (github.com/Omni-guides/Jackify) is that tool. It ships a self-
# contained native binary, `jackify-engine`, bundled inside its AppImage. We
# drive that binary directly — its front-end `--cli` is an interactive text
# menu and can't be scripted, but the engine underneath has a clean headless
# interface (source-verified against jackify-engine v0.7.x):
#
#     jackify-engine install --show-file-progress \
#         { -m <Author/Name machineURL> | -w <path.wabbajack> } \
#         -o <install-dir> -d <downloads-dir>
#     jackify-engine list-modlists --show-all-sizes --show-machine-url
#
#   Required env for every engine call:
#     NEXUS_API_KEY=<key>                        (we already store this)
#     DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1    (engine is self-contained .NET)
#
# The engine only lays the MO2 tree on disk. Wiring it into Steam (non-Steam
# shortcut + Proton version + launch options + prefix) is a separate step; we
# reuse Jackify's own `configure-modlist` for that (it's the tested code path)
# with an interactive fallback for the couple of prompts it still emits.
#
# Everything here is per-user and immutable-OS friendly: no rpm-ostree layer,
# no Bottles, no sudo (except the shared protontricks Flatpak, handled in
# install.sh). State lives under ~/.local/state/powos/modlist.

set -uo pipefail
source "${POWOS_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/..}/common.sh" 2>/dev/null || {
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'
    CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; NC=$'\033[0m'
    plog()  { echo -e "${CYAN}[modlist]${NC} $*"; }
    pok()   { echo -e "${GREEN}[modlist]${NC} $*"; }
    pwarn() { echo -e "${YELLOW}[modlist]${NC} $*"; }
    perr()  { echo -e "${RED}[modlist]${NC} $*" >&2; }
}
[[ -z "${BOLD:-}" ]] && BOLD=$'\033[1m'
[[ -z "${DIM:-}"  ]] && DIM=$'\033[2m'
[[ -z "${NC:-}"   ]] && NC=$'\033[0m'
POWOS_TAG=modlist

# mods_nexus_key / mods_setup_steam_userid / mods_ensure_protontricks live in
# install.sh. bin/powos sources install.sh before us for the `mods` command, so
# they're in scope. Guard anyway for direct sourcing (unit tests).
if ! declare -F mods_nexus_key >/dev/null 2>&1; then
    source "$(dirname "${BASH_SOURCE[0]}")/install.sh" 2>/dev/null || true
fi

# ─── Constants ───────────────────────────────────────────────────────────────
MODLIST_STATE_DIR="${MODLIST_STATE_DIR:-$HOME/.local/state/powos/modlist}"
MODLIST_JACKIFY_DIR="${MODLIST_JACKIFY_DIR:-$MODLIST_STATE_DIR/jackify}"
MODLIST_APPIMAGE_URL="${MODLIST_APPIMAGE_URL:-https://github.com/Omni-guides/Jackify/releases/latest/download/Jackify.AppImage}"

# Where installed modlists and the shared download cache live. A modlist is
# 30–250 GB installed plus a similar download cache — put both somewhere with
# room. Default under $HOME (biggest disk on a PowOS box); override per-install.
MODLIST_BASE="${MODLIST_BASE:-$HOME/Games/Modlists}"
MODLIST_DOWNLOADS_DIR="${MODLIST_DOWNLOADS_DIR:-$MODLIST_BASE/Downloads}"

# GE-Proton: Jackify auto-selects the best Proton it can FIND but never installs
# one. We bootstrap it into Steam's compatibilitytools.d. Default = latest;
# override with --proton <tag> for lists that pin a specific version.
MODLIST_COMPAT_DIR="${MODLIST_COMPAT_DIR:-$HOME/.steam/root/compatibilitytools.d}"
MODLIST_GE_PROTON_TAG="${MODLIST_GE_PROTON_TAG:-latest}"

MODLIST_UA="powos-modlist/0.1"

# ─── Jackify engine bootstrap ────────────────────────────────────────────────
# We download the AppImage once and *extract* it (./Jackify.AppImage
# --appimage-extract), rather than running it mounted. Extraction needs no FUSE
# kernel mount (good on locked-down/immutable bases) and hands us the engine
# binary + the Python front-end without a second download. We then run the
# engine binary directly for installs and the extracted AppRun for configure.

_modlist_engine_bin() {
    # Located after extraction. The engine ships at opt/jackify-engine/ in
    # current AppImages (was opt/jackify/engine/ historically) — try both fast
    # paths, then fall back to a search so upstream layout changes don't break us.
    local d="$MODLIST_JACKIFY_DIR/squashfs-root" p
    for p in "$d/opt/jackify-engine/jackify-engine" "$d/opt/jackify/engine/jackify-engine"; do
        [[ -x "$p" ]] && { echo "$p"; return 0; }
    done
    find "$d" -type f -name 'jackify-engine' -perm -u+x 2>/dev/null | head -1
}

_modlist_apprun() {
    echo "$MODLIST_JACKIFY_DIR/squashfs-root/AppRun"
}

modlist_ensure_jackify() {
    if [[ -x "$(_modlist_engine_bin 2>/dev/null)" ]]; then
        return 0
    fi
    mkdir -p "$MODLIST_JACKIFY_DIR"
    local appimage="$MODLIST_JACKIFY_DIR/Jackify.AppImage"

    if [[ ! -f "$appimage" ]] || (( $(stat -c %s "$appimage" 2>/dev/null || echo 0) < 100000000 )); then
        plog "Downloading Jackify engine (~290 MiB, one-time)…"
        plog "  ${DIM}$MODLIST_APPIMAGE_URL${NC}"
        if ! curl -fL -sS "$MODLIST_APPIMAGE_URL" -o "$appimage"; then
            perr "Jackify download failed. Check network."
            return 1
        fi
        local size; size=$(stat -c %s "$appimage" 2>/dev/null || echo 0)
        if (( size < 100000000 )); then
            perr "Downloaded file is only $size bytes — not the AppImage. Aborting."
            rm -f "$appimage"; return 1
        fi
    fi
    chmod +x "$appimage"

    plog "Extracting engine from AppImage…"
    # --appimage-extract writes squashfs-root/ into CWD; do it inside our dir.
    rm -rf "$MODLIST_JACKIFY_DIR/squashfs-root"
    if ! ( cd "$MODLIST_JACKIFY_DIR" && "$appimage" --appimage-extract >/dev/null 2>&1 ); then
        # Some minimal userlands can't self-extract; fall back to extract-and-run
        # for the engine copy step (needs FUSE, which PowOS has).
        perr "AppImage self-extract failed. Trying extract-and-run fallback…"
        if ! ( cd "$MODLIST_JACKIFY_DIR" && "$appimage" --appimage-extract-and-run --version >/dev/null 2>&1 ); then
            perr "Could not unpack Jackify. Is FUSE available? (fusermount present)"
            return 1
        fi
    fi

    local eng; eng="$(_modlist_engine_bin)"
    if [[ -z "$eng" || ! -x "$eng" ]]; then
        perr "jackify-engine binary not found after extraction."
        perr "  Looked under: $MODLIST_JACKIFY_DIR/squashfs-root/opt/jackify/engine/"
        return 1
    fi
    chmod +x "$eng" 2>/dev/null || true
    pok "Jackify engine ready: ${DIM}$eng${NC}"
}

# Run the engine with the env it needs. Args are passed straight through.
# NEXUS_API_KEY is sourced from the PowOS-managed key (powos setup nexus).
#
# CRITICAL: run from a safe, local CWD. jackify-engine walks its working
# directory on startup; if the CWD is the user's HOME (or anything containing a
# slow/dead network mount — SMB/NFS/sshfs), that walk stalls in uninterruptible
# IO and the whole command hangs indefinitely. Observed 2026-07-07: a CIFS
# ~/NAS automount wedged `list-modlists` for 12+ minutes deep in cifs_readdir
# (kernel stack: SMB2_query_directory → wait_for_response). The state dir is
# guaranteed local (btrfs), so we cd there before exec. Set
# MODLIST_ENGINE_TIMEOUT to also bound the call (used for the gallery listing;
# left unset for installs, which legitimately run for hours).
_modlist_engine() {
    local eng; eng="$(_modlist_engine_bin)" || { perr "engine missing"; return 1; }
    local key; key="$(mods_nexus_key)" || return 1
    local safe="$MODLIST_STATE_DIR"; mkdir -p "$safe"
    local -a bound=()
    [[ -n "${MODLIST_ENGINE_TIMEOUT:-}" ]] && bound=(timeout "$MODLIST_ENGINE_TIMEOUT")
    ( cd "$safe" && exec env DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1 \
        NEXUS_API_KEY="$key" "${bound[@]}" "$eng" "$@" )
}

# ─── GE-Proton bootstrap ─────────────────────────────────────────────────────
# Jackify ranks GE-Proton >= 10 highest but installs nothing. We drop a
# GE-Proton build into ~/.steam/root/compatibilitytools.d so Steam (and hence
# Jackify's configure step) can select it. Idempotent.
modlist_ge_proton_installed() {
    [[ -d "$MODLIST_COMPAT_DIR" ]] || return 1
    find "$MODLIST_COMPAT_DIR" -maxdepth 1 -type d -name 'GE-Proton*' 2>/dev/null | grep -q .
}

# Resolve a GE-Proton release tag ("latest" or e.g. "GE-Proton10-34") to its
# x86_64 tarball download URL via the GitHub API.
_modlist_ge_proton_url() {
    local tag="$1" api
    if [[ "$tag" == "latest" ]]; then
        api="https://api.github.com/repos/GloriousEggroll/proton-ge-custom/releases/latest"
    else
        api="https://api.github.com/repos/GloriousEggroll/proton-ge-custom/releases/tags/$tag"
    fi
    curl -sS -H "User-Agent: $MODLIST_UA" "$api" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for a in d.get("assets", []):
    n = a.get("name", "")
    # Want the x86_64 desktop tarball, not the aarch64 one.
    if n.endswith(".tar.gz") and "aarch64" not in n:
        print(a["browser_download_url"]); break
'
}

modlist_install_ge_proton() {
    local tag="${1:-$MODLIST_GE_PROTON_TAG}"
    if [[ "$tag" == "latest" ]] && modlist_ge_proton_installed; then
        pok "GE-Proton already present: $(find "$MODLIST_COMPAT_DIR" -maxdepth 1 -type d -name 'GE-Proton*' -printf '%f ' 2>/dev/null)"
        return 0
    fi
    mkdir -p "$MODLIST_COMPAT_DIR"
    plog "Resolving GE-Proton ($tag)…"
    local url; url="$(_modlist_ge_proton_url "$tag")"
    [[ -z "$url" ]] && { perr "Could not resolve GE-Proton tarball for tag '$tag'."; return 1; }

    # If we asked for a specific tag and it's already extracted, skip.
    local basetag; basetag="$(basename "$url")"; basetag="${basetag%.tar.gz}"
    if [[ -d "$MODLIST_COMPAT_DIR/$basetag" ]]; then
        pok "$basetag already installed."
        return 0
    fi

    plog "Downloading $basetag (~400 MiB)…"
    local tmp; tmp="$(mktemp -d)"
    if ! curl -fL -sS "$url" -o "$tmp/geproton.tar.gz"; then
        perr "GE-Proton download failed."; rm -rf "$tmp"; return 1
    fi
    plog "Extracting into $MODLIST_COMPAT_DIR…"
    if ! tar -xzf "$tmp/geproton.tar.gz" -C "$MODLIST_COMPAT_DIR"; then
        perr "GE-Proton extraction failed."; rm -rf "$tmp"; return 1
    fi
    rm -rf "$tmp"
    pok "GE-Proton installed: $basetag  ${DIM}(restart Steam to see it)${NC}"
}

# ─── Modlist reference resolution ────────────────────────────────────────────
# Turn whatever the user passed into engine flags, WITHOUT any per-list special-
# casing. Accepts, in priority order:
#   1. a local .wabbajack file path            → -w <path>
#   2. an http(s) URL ending in .wabbajack     → download, then -w <path>
#   3. an "Author/Name" machineURL             → -m <Author/Name>
#   4. a bare name (e.g. "tuxborn")            → fuzzy-match the gallery, -m
# Prints the two engine args ("-w /path" or "-m Author/Name") on success.
_modlist_resolve_ref() {
    local ref="$1"

    # 1. Local .wabbajack file.
    if [[ -f "$ref" && "$ref" == *.wabbajack ]]; then
        printf -- '-w\n%s\n' "$ref"; return 0
    fi

    # 2. URL to a .wabbajack.
    if [[ "$ref" =~ ^https?:// ]]; then
        if [[ "$ref" == *.wabbajack || "$ref" == *.wabbajack\?* ]]; then
            mkdir -p "$MODLIST_DOWNLOADS_DIR"
            local out="$MODLIST_DOWNLOADS_DIR/$(basename "${ref%%\?*}")"
            plog "Fetching modlist file → $out" >&2
            if ! curl -fL -sS "$ref" -o "$out"; then
                perr "Download of .wabbajack failed."; return 1
            fi
            printf -- '-w\n%s\n' "$out"; return 0
        fi
        perr "URL doesn't point at a .wabbajack file: $ref" >&2
        perr "  Genesis-style setup.exe downloaders aren't a .wabbajack — grab the" >&2
        perr "  list from the Wabbajack gallery (see 'powos mods modlist search') or" >&2
        perr "  point me at the actual .wabbajack file." >&2
        return 1
    fi

    # 3. Explicit machineURL "Author/Name".
    if [[ "$ref" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
        printf -- '-m\n%s\n' "$ref"; return 0
    fi

    # 4. Bare name → fuzzy-match the online gallery's machineURLs.
    plog "Resolving '$ref' against the Wabbajack gallery…" >&2
    local matches
    matches="$(_modlist_gallery_raw 2>/dev/null | awk -F' - ' -v q="$(echo "$ref" | tr 'A-Z' 'a-z')" '
        { line=tolower($0); mu=$NF }
        index(line, q) > 0 { print mu }' | sort -u)"
    local n; n="$(printf '%s\n' "$matches" | grep -c . )"
    if [[ "$n" -eq 1 ]]; then
        printf -- '-m\n%s\n' "$(printf '%s' "$matches" | head -1)"; return 0
    elif [[ "$n" -gt 1 ]]; then
        perr "'$ref' matches multiple lists — pick one (Author/Name):" >&2
        printf '    %s\n' $matches >&2
        return 1
    fi
    perr "No gallery modlist matches '$ref'." >&2
    perr "  • List what's available:  powos mods modlist search [game]" >&2
    perr "  • Or pass a .wabbajack file / its Author/Name machineURL directly." >&2
    return 1
}

# Raw gallery lines from the engine. Cached 6h — the gallery is large and rarely
# changes within a session, and list-modlists hits the network each time.
_modlist_gallery_raw() {
    local cache="$MODLIST_STATE_DIR/gallery.txt"
    if [[ -f "$cache" ]] && [[ $(( $(date +%s) - $(stat -c %Y "$cache" 2>/dev/null || echo 0) )) -lt 21600 ]]; then
        cat "$cache"; return 0
    fi
    modlist_ensure_jackify >&2 || return 1
    mkdir -p "$MODLIST_STATE_DIR"
    # Bound the gallery query (belt-and-suspenders alongside the safe CWD) so a
    # slow gallery server or stalled mount can't hang discovery forever. Strip
    # the engine's progress preamble ("Loading…", "Loaded N lists", "Showing…")
    # so the cache holds only real "Name - Game - Size - Author/Name" rows.
    if MODLIST_ENGINE_TIMEOUT="${MODLIST_GALLERY_TIMEOUT:-300}" \
        _modlist_engine list-modlists --show-all-sizes --show-machine-url 2>/dev/null \
        | grep -E ' - [A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' > "$cache.tmp"; then
        mv "$cache.tmp" "$cache"; cat "$cache"
    else
        rm -f "$cache.tmp"
        if [[ -f "$cache" ]]; then
            pwarn "Gallery refresh failed/timed out — using cached list." >&2
            cat "$cache"  # stale is better than nothing
        else
            perr "Could not fetch the modlist gallery (engine timed out or errored)." >&2
            return 1
        fi
    fi
}

# ─── Commands ────────────────────────────────────────────────────────────────

# powos mods modlist search [game]
#   List installable Wabbajack modlists (optionally filtered by game substring).
modlist_search_cmd() {
    POWOS_MODS_LAST_VERB="modlist search"
    local filter="${1:-}"
    modlist_ensure_jackify || return 1
    plog "Available Wabbajack modlists${filter:+ matching '$filter'}:"
    echo
    local raw; raw="$(_modlist_gallery_raw)" || { perr "Could not fetch gallery."; return 1; }
    if [[ -n "$filter" ]]; then
        printf '%s\n' "$raw" | grep -i -- "$filter" || { pwarn "No lists match '$filter'."; return 1; }
    else
        printf '%s\n' "$raw"
    fi
    echo
    plog "Install one with:  ${BOLD}powos mods modlist install <Author/Name>${NC}"
}

# powos mods modlist install <ref> [flags]
#   The main event. ref = .wabbajack file | URL | Author/Name | bare name.
modlist_install_cmd() {
    POWOS_MODS_LAST_VERB="modlist install"
    local ref="" name="" install_dir="" downloads_dir="$MODLIST_DOWNLOADS_DIR"
    local proton_tag="$MODLIST_GE_PROTON_TAG" do_steam=true resolution=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)          name="$2"; shift 2 ;;
            --install-dir)   install_dir="$2"; shift 2 ;;
            --downloads-dir) downloads_dir="$2"; shift 2 ;;
            --proton)        proton_tag="$2"; shift 2 ;;
            --resolution)    resolution="$2"; shift 2 ;;
            --no-steam)      do_steam=false; shift ;;   # skip Steam/Proton wiring
            -*)              perr "Unknown flag: $1"; return 1 ;;
            *)               if [[ -z "$ref" ]]; then ref="$1"; else perr "Unexpected arg: $1"; return 1; fi; shift ;;
        esac
    done
    [[ -z "$ref" ]] && { perr "Usage: powos mods modlist install <.wabbajack | URL | Author/Name | name> [flags]"; return 1; }

    # Preconditions the whole flow depends on.
    mods_nexus_key >/dev/null || {
        perr "No Nexus API key. Run: ${BOLD}powos setup nexus${NC}  (Premium gives fully-automated downloads)."
        return 1
    }
    modlist_ensure_jackify || return 1

    # Resolve the reference into engine flags.
    local rflag rval
    { read -r rflag; read -r rval; } < <(_modlist_resolve_ref "$ref") || return 1
    [[ -z "${rflag:-}" || -z "${rval:-}" ]] && { perr "Could not resolve modlist reference '$ref'."; return 1; }

    # Derive a Steam-shortcut / folder name if not given.
    if [[ -z "$name" ]]; then
        case "$rflag" in
            -m) name="${rval##*/}" ;;                      # "Author/Name" → Name
            -w) name="$(basename "${rval%.wabbajack}")" ;; # file stem
        esac
    fi
    [[ -z "$install_dir" ]] && install_dir="$MODLIST_BASE/$name"
    mkdir -p "$install_dir" "$downloads_dir"

    cat <<EOF

${BOLD}Modlist install plan${NC}
  Source:     $rflag $rval
  Name:       $name
  Install to: $install_dir
  Downloads:  $downloads_dir
  Steam+Proton wiring: $([ "$do_steam" = true ] && echo "yes (GE-Proton $proton_tag)" || echo "no (--no-steam)")

EOF
    plog "This downloads hundreds of mods (tens–hundreds of GB) and can take a"
    plog "long while. A Nexus ${BOLD}Premium${NC} account makes it hands-off; free accounts"
    plog "get rate-limited and may need manual clicks. Leave it running."
    echo

    # Bootstrap GE-Proton up front so it's ready for the configure step and the
    # (long) download isn't wasted if Proton turns out to be missing.
    if $do_steam; then
        modlist_install_ge_proton "$proton_tag" || {
            pwarn "GE-Proton bootstrap failed — continuing the install, but you'll"
            pwarn "need a Proton before the game runs. Retry: powos mods modlist proton"
        }
    fi

    # ── The heavy lift: replay the list into a portable MO2 tree ──
    plog "Running jackify-engine (download + install)…"
    plog "  ${DIM}Progress streams below; safe to leave unattended.${NC}"
    if ! _modlist_engine install --show-file-progress "$rflag" "$rval" \
            -o "$install_dir" -d "$downloads_dir"; then
        perr "Modlist install failed (engine returned nonzero)."
        perr "  Re-running with the same --install-dir resumes; it won't re-download"
        perr "  what's already in $downloads_dir."
        return 1
    fi
    pok "Modlist files installed to $install_dir"

    # Find the MO2 the engine produced (needed for the Steam AppID lookup).
    local mo2_exe
    mo2_exe="$(find "$install_dir" -maxdepth 3 -iname 'ModOrganizer.exe' -type f 2>/dev/null | head -1)"
    [[ -z "$mo2_exe" ]] && pwarn "ModOrganizer.exe not found under $install_dir (list may use a different layout)."

    if ! $do_steam; then
        pok "Done (files only). Wire it into Steam later with:"
        echo "    powos mods modlist configure \"$name\" --install-dir \"$install_dir\""
        return 0
    fi

    # ── Wire into Steam + Proton via Jackify's own configure path ──
    modlist_configure_cmd "$name" \
        --install-dir "$install_dir" \
        --downloads-dir "$downloads_dir" \
        ${mo2_exe:+--mo2-exe "$mo2_exe"} \
        ${resolution:+--resolution "$resolution"} \
        --auto
}

# powos mods modlist configure <name> --install-dir <dir> [flags]
#   Create/refresh the non-Steam shortcut + Proton + launch options for an
#   already-installed list. Delegates to Jackify's tested configure-modlist.
#   Jackify's CLI still emits a couple of (Y/n) prompts (TTW/VNV/JContainers
#   fixes, resolution). In --auto we feed safe defaults; otherwise we hand the
#   terminal to Jackify so YOU answer.
modlist_configure_cmd() {
    POWOS_MODS_LAST_VERB="modlist configure"
    local name="${1:-}"; shift || true
    [[ -z "$name" ]] && { perr "Usage: powos mods modlist configure <name> --install-dir <dir>"; return 1; }
    local install_dir="" downloads_dir="$MODLIST_DOWNLOADS_DIR" mo2_exe="" resolution="" auto=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --install-dir)   install_dir="$2"; shift 2 ;;
            --downloads-dir) downloads_dir="$2"; shift 2 ;;
            --mo2-exe)       mo2_exe="$2"; shift 2 ;;
            --resolution)    resolution="$2"; shift 2 ;;
            --auto)          auto=true; shift ;;
            *)               perr "Unknown flag: $1"; return 1 ;;
        esac
    done
    [[ -z "$install_dir" ]] && install_dir="$MODLIST_BASE/$name"
    [[ -d "$install_dir" ]] || { perr "Install dir not found: $install_dir"; return 1; }
    modlist_ensure_jackify || return 1
    [[ -z "$mo2_exe" ]] && mo2_exe="$(find "$install_dir" -maxdepth 3 -iname 'ModOrganizer.exe' -type f 2>/dev/null | head -1)"
    [[ -z "$resolution" ]] && resolution="$(_modlist_detect_resolution)"

    local key; key="$(mods_nexus_key)" || return 1
    local apprun; apprun="$(_modlist_apprun)"

    local -a cfg=(--cli configure-modlist
        --modlist-name "$name"
        --install-dir "$install_dir"
        --download-dir "$downloads_dir"
        --resolution "$resolution"
        --skip-confirmation)
    [[ -n "$mo2_exe" ]] && cfg+=(--mo2-exe-path "$mo2_exe")

    plog "Configuring Steam shortcut + Proton for '$name'…"
    pwarn "Steam may restart during this step."
    echo

    # Same safe-CWD rule as the engine — Jackify's front-end enumerates drives.
    mkdir -p "$MODLIST_STATE_DIR"
    if $auto; then
        # Non-interactive best-effort: feed 'y' to any residual yes/no prompt
        # (the TTW/VNV/JContainers fixes SHOULD be applied). Bounded so a stuck
        # prompt doesn't hang forever. A timeout here still leaves the mods
        # installed — the user can re-run configure interactively.
        if ( cd "$MODLIST_STATE_DIR" && DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1 \
                NEXUS_API_KEY="$key" timeout 600 bash -c 'yes | "$@"' _ "$apprun" "${cfg[@]}" ); then
            pok "'$name' is set up. Launch Steam → run '$name' (it opens Mod Organizer 2)."
        else
            pwarn "Auto-configure didn't complete cleanly. Finish it interactively:"
            echo   "    powos mods modlist configure \"$name\" --install-dir \"$install_dir\""
            pwarn "(The mods are installed; this only wires up the Steam launcher.)"
            return 1
        fi
    else
        # Hand the TTY to Jackify so the user answers its prompts directly.
        ( cd "$MODLIST_STATE_DIR" && DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1 \
            NEXUS_API_KEY="$key" "$apprun" "${cfg[@]}" )
        pok "Configure finished. Launch '$name' from Steam."
    fi
}

# Best-effort desktop resolution → "WxH". Falls back to 1920x1080.
_modlist_detect_resolution() {
    local r=""
    if command -v kscreen-doctor >/dev/null 2>&1; then
        r="$(kscreen-doctor -o 2>/dev/null | grep -oE '[0-9]{3,5}x[0-9]{3,5}' | head -1)"
    fi
    if [[ -z "$r" ]] && command -v xrandr >/dev/null 2>&1; then
        r="$(xrandr 2>/dev/null | awk '/\*/{print $1; exit}')"
    fi
    echo "${r:-1920x1080}"
}

# powos mods modlist proton [tag]  — (re)install GE-Proton.
modlist_proton_cmd() {
    POWOS_MODS_LAST_VERB="modlist proton"
    modlist_install_ge_proton "${1:-$MODLIST_GE_PROTON_TAG}"
}

# powos mods modlist list  — installed lists on this machine.
modlist_list_cmd() {
    POWOS_MODS_LAST_VERB="modlist list"
    echo -e "${BOLD}Installed modlists${NC}  ${DIM}($MODLIST_BASE)${NC}"
    echo "════════════════════════════════════════"
    local found=false d
    if [[ -d "$MODLIST_BASE" ]]; then
        while IFS= read -r d; do
            [[ -z "$d" ]] && continue
            local mo2; mo2="$(find "$d" -maxdepth 3 -iname 'ModOrganizer.exe' -type f 2>/dev/null | head -1)"
            [[ -z "$mo2" ]] && continue
            found=true
            local sz; sz="$(du -sh "$d" 2>/dev/null | cut -f1)"
            printf "  %-28s ${GREEN}installed${NC}  ${DIM}%s${NC}\n" "$(basename "$d")" "${sz:-?}"
        done < <(find "$MODLIST_BASE" -mindepth 1 -maxdepth 1 -type d ! -name Downloads 2>/dev/null)
    fi
    $found || echo -e "  ${DIM}(none yet — powos mods modlist install <ref>)${NC}"
}

# powos mods modlist status  — is the toolchain ready?
modlist_status_cmd() {
    POWOS_MODS_LAST_VERB="modlist status"
    local ok=true
    printf "  jackify engine:   "
    if [[ -x "$(_modlist_engine_bin 2>/dev/null)" ]]; then echo "installed"; else echo "not installed"; ok=false; fi
    printf "  GE-Proton:        "
    if modlist_ge_proton_installed; then
        echo "$(find "$MODLIST_COMPAT_DIR" -maxdepth 1 -type d -name 'GE-Proton*' -printf '%f ' 2>/dev/null)"
    else echo "none  ${DIM}(powos mods modlist proton)${NC}"; ok=false; fi
    printf "  native Steam:     "
    if [[ -d "$HOME/.steam/steam" ]]; then echo "yes"; else echo "MISSING (Jackify needs native Steam)"; ok=false; fi
    printf "  protontricks:     "
    if flatpak info com.github.Matoking.protontricks >/dev/null 2>&1 || command -v protontricks >/dev/null 2>&1; then
        echo "yes"; else echo "missing  ${DIM}(powos mods setup <game> installs it)${NC}"; fi
    printf "  nexus key:        "
    if mods_nexus_key >/dev/null 2>&1; then echo "saved"; else echo "MISSING (powos setup nexus)"; ok=false; fi
    echo
    $ok && pok "Ready to install modlists." || pwarn "Some prerequisites are missing (see above)."
}

# powos mods modlist uninstall <name>  — remove an installed list's files.
modlist_uninstall_cmd() {
    POWOS_MODS_LAST_VERB="modlist uninstall"
    local name="${1:?Usage: powos mods modlist uninstall <name> [--purge-downloads]}"
    local purge=false; [[ "${2:-}" == "--purge-downloads" ]] && purge=true
    local dir="$MODLIST_BASE/$name"
    [[ -d "$dir" ]] || { perr "No installed modlist named '$name' at $dir."; return 1; }
    plog "Removing $dir …"
    rm -rf "$dir" && pok "Removed '$name'."
    if $purge; then
        pwarn "Purging shared downloads too ($MODLIST_DOWNLOADS_DIR) — this affects ALL lists."
        rm -rf "$MODLIST_DOWNLOADS_DIR" && pok "Downloads cache cleared."
    fi
    pwarn "The Steam shortcut (if any) isn't auto-removed — delete '$name' from Steam manually."
}

# ─── Standalone Mod Organizer 2 (portable, native Proton — no Bottles) ────────
# For MANUAL modlists (Fallout London's GOG path, hand-built TTW, or just
# organizing mods yourself) you want MO2 without a whole Wabbajack list. We
# install the official portable MO2 and launch it through GE-Proton in its own
# prefix via a plain wrapper — the same reliable primitive Steam uses, minus the
# Bottles sandbox that's been flaky. The wrapper is a real Linux executable, so
# it plugs straight into `powos mods installed / launch / uninstall`.
MO2_DIR="${MO2_DIR:-$HOME/Games/ModOrganizer2}"
MO2_WRAPPER="${MO2_WRAPPER:-$HOME/.local/bin/mod-organizer-2}"
MO2_PREFIX="${MO2_PREFIX:-$MO2_DIR/prefix}"
MO2_DESKTOP="${MO2_DESKTOP:-$HOME/.local/share/applications/mod-organizer-2.desktop}"

_mo2_release_asset() {
    # The main portable 7z is `Mod.Organizer-<ver>.7z` — NOT -pdbs/-src/-uibase.
    curl -sS -H "User-Agent: $MODLIST_UA" \
        "https://api.github.com/repos/ModOrganizer2/modorganizer/releases/latest" \
    | python3 -c '
import json, re, sys
d = json.load(sys.stdin)
for a in d.get("assets", []):
    n = a.get("name", "")
    if re.fullmatch(r"Mod\.Organizer-[0-9.]+\.7z", n):
        print(a["browser_download_url"]); break
'
}

mo2_install() {
    if [[ -f "$MO2_DIR/ModOrganizer.exe" ]]; then
        pok "Mod Organizer 2 already installed at $MO2_DIR."
    else
        local url; url="$(_mo2_release_asset)"
        [[ -z "$url" ]] && { perr "Couldn't find the MO2 portable 7z on GitHub."; return 1; }
        mkdir -p "$MO2_DIR"
        local tmp; tmp="$(mktemp -d)"
        plog "Downloading Mod Organizer 2 ($(basename "$url"))…"
        if ! curl -fL -sS "$url" -o "$tmp/mo2.7z"; then
            perr "MO2 download failed."; rm -rf "$tmp"; return 1
        fi
        plog "Extracting to $MO2_DIR…"
        if ! 7z x -y -o"$MO2_DIR" "$tmp/mo2.7z" >/dev/null; then
            perr "7z extraction failed."; rm -rf "$tmp"; return 1
        fi
        rm -rf "$tmp"
        [[ -f "$MO2_DIR/ModOrganizer.exe" ]] || { perr "ModOrganizer.exe missing after extract."; return 1; }
        pok "MO2 extracted."
    fi

    modlist_install_ge_proton "$MODLIST_GE_PROTON_TAG" \
        || pwarn "GE-Proton not installed — MO2 won't launch until it is (powos mods modlist proton)."

    mo2_write_wrapper
    mo2_write_desktop
    pok "Mod Organizer 2 installed."
    plog "  Launch:  powos mods launch mod-organizer-2   ${DIM}(or the KDE menu entry)${NC}"
    plog "  Runs under GE-Proton in its own prefix ($MO2_PREFIX) — no Steam shortcut needed."
}

mo2_write_wrapper() {
    mkdir -p "$(dirname "$MO2_WRAPPER")"
    cat > "$MO2_WRAPPER" <<EOF
#!/bin/bash
# powos: Mod Organizer 2 launcher — runs MO2.exe under GE-Proton (no Bottles).
set -uo pipefail
MO2_DIR="${MO2_DIR}"
PREFIX="${MO2_PREFIX}"
COMPAT="${MODLIST_COMPAT_DIR}"
EOF
    cat >> "$MO2_WRAPPER" <<'EOF'
# Newest GE-Proton in compatibilitytools.d.
PROTON="$(find "$COMPAT" -maxdepth 1 -type d -name 'GE-Proton*' 2>/dev/null | sort -V | tail -1)/proton"
if [[ ! -x "$PROTON" ]]; then
    echo "mod-organizer-2: no GE-Proton found in $COMPAT. Run: powos mods modlist proton" >&2
    exit 1
fi
mkdir -p "$PREFIX"
export STEAM_COMPAT_DATA_PATH="$PREFIX"
export STEAM_COMPAT_CLIENT_INSTALL_PATH="${STEAM_COMPAT_CLIENT_INSTALL_PATH:-$HOME/.steam/steam}"
# Detach — MO2 owns its own event loop.
setsid nohup "$PROTON" run "$MO2_DIR/ModOrganizer.exe" "$@" >/dev/null 2>&1 < /dev/null &
disown
EOF
    chmod +x "$MO2_WRAPPER"
    case ":$PATH:" in
        *:"$(dirname "$MO2_WRAPPER")":*) : ;;
        *) pwarn "  Add $(dirname "$MO2_WRAPPER") to PATH to run 'mod-organizer-2' directly." ;;
    esac
}

mo2_write_desktop() {
    mkdir -p "$(dirname "$MO2_DESKTOP")"
    cat > "$MO2_DESKTOP" <<EOF
[Desktop Entry]
Type=Application
Name=Mod Organizer 2
GenericName=Mod Manager
Comment=Mod Organizer 2 (portable) under GE-Proton — for manual modlists
Exec=$MO2_WRAPPER
Icon=applications-games
Terminal=false
Categories=Game;Utility;
StartupNotify=true
StartupWMClass=ModOrganizer.exe
EOF
    update-desktop-database "$(dirname "$MO2_DESKTOP")" 2>/dev/null || true
}

mo2_uninstall() {
    plog "Removing standalone Mod Organizer 2…"
    rm -f "$MO2_WRAPPER" "$MO2_DESKTOP"
    if [[ -d "$MO2_DIR" ]]; then
        pwarn "Deleting $MO2_DIR (includes its Wine prefix and any mods staged there)."
        rm -rf "$MO2_DIR"
    fi
    update-desktop-database "$(dirname "$MO2_DESKTOP")" 2>/dev/null || true
    pok "Mod Organizer 2 uninstalled."
}

modlist_help() {
    cat <<EOF
${BOLD}powos mods modlist${NC} — install whole Wabbajack modlists, natively

The one-command path for big curated lists: ${DIM}Star Wars Genesis (Starfield),
Fallout London, Tale of Two Wastelands lists, Tuxborn, Nordic Souls, …${NC} — any
Wabbajack list. No Wine, no Bottles: a native engine lays down Mod Organizer 2,
then the game runs through Steam + GE-Proton.

  ${BOLD}search${NC} [game]                 List installable modlists (from the gallery).
  ${BOLD}install${NC} <ref> [flags]         Install a list. <ref> can be:
                                   • a .wabbajack file path
                                   • an https URL to a .wabbajack
                                   • an Author/Name machineURL (from 'search')
                                   • a bare name (fuzzy-matched in the gallery)
       flags: --name <n>  --install-dir <d>  --downloads-dir <d>
              --proton <GE-ProtonXX-YY|latest>  --resolution <WxH>  --no-steam
  ${BOLD}configure${NC} <name> --install-dir <d>
                                   (Re)wire the Steam shortcut + Proton for a
                                   list whose files are already installed.
  ${BOLD}list${NC}                          Modlists installed on this machine.
  ${BOLD}status${NC}                        Show whether the toolchain is ready.
  ${BOLD}proton${NC} [tag]                  Install GE-Proton (default: latest).
  ${BOLD}uninstall${NC} <name> [--purge-downloads]
                                   Delete an installed list's files.

Prereqs (checked by 'status'): native Steam, a Nexus API key (${BOLD}powos setup
nexus${NC}; Premium = hands-off downloads), GE-Proton (auto-installed), and the
game itself installed via Steam.

Examples:
  powos mods modlist status
  powos mods modlist search starfield
  powos mods modlist install Tuxborn/Tuxborn
  powos mods modlist install ~/Downloads/StarWarsGenesis.wabbajack --name "Star Wars Genesis"
EOF
}

# powos mods modlist — dispatch.
modlist_dispatch() {
    local sub="${1:-help}"; shift || true
    case "$sub" in
        install)                      modlist_install_cmd "$@" ;;
        configure|config)             modlist_configure_cmd "$@" ;;
        search|gallery|available)     modlist_search_cmd "$@" ;;
        list|ls|installed)            modlist_list_cmd ;;
        status|check|doctor)          modlist_status_cmd ;;
        proton|ge-proton)             modlist_proton_cmd "$@" ;;
        uninstall|remove|rm)          modlist_uninstall_cmd "$@" ;;
        help|--help|-h|"")            modlist_help ;;
        *) perr "Unknown: powos mods modlist $sub"; modlist_help; return 1 ;;
    esac
}
