#!/bin/bash
# mods/vortex.sh - Vortex mod manager on PowOS via Bottles (Flatpak Wine).
#
# Nexus Mods App only officially supports Cyberpunk 2077 and Stardew Valley
# right now. Every other Nexus-tracked game (Skyrim SE/AE, Fallout 4,
# Starfield, BG3, Witcher 3, Oblivion, Morrowind, Fallout NV, …) is
# managed via Vortex — Windows-only but well-behaved under Wine.
#
# Rather than the traditional "add as non-Steam game" dance, we install
# Vortex into a dedicated Bottles Flatpak sandbox with .NET Desktop 6.
# Advantages over Steam+Proton:
#   • no non-Steam Steam-library entry to explain to the user
#   • immutable-OS-friendly (Flatpak, no rpm-ostree layer)
#   • Bottles CLI is scriptable — everything below is headless
#   • the nxm:// handler is a plain .desktop file we write ourselves
#
# Vortex has a real CLI (unlike NMA):
#   Vortex.exe -i <url>           download + install from URL (NXM works!)
#   Vortex.exe -d <url>           download only
#   Vortex.exe --game <id>        launch with a game selected
#   Vortex.exe --profile <id>     launch with a profile activated
#   Vortex.exe -g <state.path>    print state at a path
#   Vortex.exe -s <path>=<value>  write state (dangerous)
#
# That's the whole plumbing needed to make Vortex agent-manageable.

set -uo pipefail

# Self-sufficient fallback: when sourced from install.sh (via bin/powos),
# common.sh has already defined colors + log helpers. When sourced
# directly (for a unit test, or if the dispatcher path changes), fall
# back to inline defs so `set -u` doesn't kill us.
source "${POWOS_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/..}/common.sh" 2>/dev/null || {
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
    CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
    plog()  { echo -e "${CYAN}[vortex]${NC} $*"; }
    pok()   { echo -e "${GREEN}[vortex]${NC} $*"; }
    pwarn() { echo -e "${YELLOW}[vortex]${NC} $*"; }
    perr()  { echo -e "${RED}[vortex]${NC} $*" >&2; }
}
# Even when common.sh loaded, guarantee color vars exist (set -u is unforgiving).
[[ -z "${BOLD:-}" ]] && BOLD='\033[1m'
[[ -z "${DIM:-}"  ]] && DIM='\033[2m'
[[ -z "${NC:-}"   ]] && NC='\033[0m'

# ─── Constants ───────────────────────────────────────────────────────────
VORTEX_BOTTLE_NAME="${VORTEX_BOTTLE_NAME:-PowosVortex}"
VORTEX_FLATPAK_ID="com.usebottles.bottles"
VORTEX_INSTALL_DRIVE_PATH='C:\Vortex'
VORTEX_INSTALLER_URL_TMPL='https://github.com/Nexus-Mods/Vortex/releases/download/v%s/vortex-setup-%s.exe'
VORTEX_DEFAULT_VERSION="${VORTEX_DEFAULT_VERSION:-2.2.0}"
VORTEX_STATE_DIR="${VORTEX_STATE_DIR:-$HOME/.local/state/powos/vortex}"
VORTEX_DESKTOP_DIR="${VORTEX_DESKTOP_DIR:-$HOME/.local/share/applications}"
VORTEX_ICONS_DIR="${VORTEX_ICONS_DIR:-$HOME/.local/share/icons/hicolor/256x256/apps}"
VORTEX_LOCAL_BIN="${VORTEX_LOCAL_BIN:-$HOME/.local/bin}"

# Bottles Flatpak's own writable scratch inside its sandbox. Staging the
# NSIS installer here — instead of /tmp — is the only reliable way to
# pass an .exe into `bottles-cli run`, since Flatpak sandboxes reject
# arbitrary host paths (even /tmp) unless explicitly overridden.
_vortex_bottles_temp() {
    echo "$HOME/.var/app/$VORTEX_FLATPAK_ID/data/bottles/temp"
}

# Bottle drive_c path — where Vortex.exe ends up after install.
# ($VORTEX_BOTTLE_NAME expanded at call time; --user data path is stable.)
_vortex_bottle_dir() {
    echo "$HOME/.var/app/$VORTEX_FLATPAK_ID/data/bottles/bottles/$VORTEX_BOTTLE_NAME"
}

_vortex_exe_path_in_bottle() {
    # NSIS install target: /D=C:\Vortex → drive_c/Vortex/Vortex.exe.
    echo "$(_vortex_bottle_dir)/drive_c/Vortex/Vortex.exe"
}

# ─── Prerequisites ───────────────────────────────────────────────────────

vortex_ensure_bottles() {
    if flatpak info "$VORTEX_FLATPAK_ID" >/dev/null 2>&1; then
        return 0
    fi
    plog "Bottles Flatpak not installed. Installing --user (no sudo)…"

    # Bazzite ships a filtered SYSTEM flathub (whitelist). Bottles is on
    # the whitelist so system install works, but we default to --user
    # because it doesn't need sudo, keeps Vortex fully per-user, and
    # avoids messing with the system stateroot. If flathub isn't
    # registered per-user yet, add it (no sudo needed for --user remote).
    flatpak remote-add --user --if-not-exists flathub \
        https://flathub.org/repo/flathub.flatpakrepo 2>/dev/null || true

    if ! flatpak install -y --user --noninteractive flathub \
            "$VORTEX_FLATPAK_ID" 2>&1 | tail -5; then
        perr "Bottles install failed. Check network + flathub remote."
        perr "  Manual add:  flatpak remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo"
        return 1
    fi
    pok "Bottles installed (--user)."
}

# The Bottles Flatpak defaults to the standard xdg portals. To let Vortex
# see Steam library paths (native + Flatpak Steam) and the user's Downloads
# dir (for staging), grant filesystem overrides once per install.
vortex_grant_filesystem() {
    local paths=(
        "$HOME/.steam"
        "$HOME/.local/share/Steam"
        "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam"
        "xdg-download"
        "xdg-documents"
    )
    local p granted=0
    for p in "${paths[@]}"; do
        if flatpak override --user "$VORTEX_FLATPAK_ID" "--filesystem=$p" 2>/dev/null; then
            granted=$((granted+1))
        fi
    done
    plog "Granted Bottles filesystem access to $granted Steam/download paths."
}

# ─── Bottles wrappers ────────────────────────────────────────────────────

vortex_bcli() {
    # Preferred: run bottles-cli inside the Flatpak. Silent unless failure.
    flatpak run --command=bottles-cli "$VORTEX_FLATPAK_ID" "$@"
}

vortex_bottle_exists() {
    vortex_bcli --json list bottles 2>/dev/null \
        | python3 -c "import json,sys;n='$VORTEX_BOTTLE_NAME';d=json.load(sys.stdin);sys.exit(0 if n in d else 1)" \
        2>/dev/null
}

# Bottles CLI refuses `new` if no "managed" runner is installed, with
# "Missing essential components. Installing… No managed runners found."
# Bottles-cli has NO verb to download runners; only the GUI's first-run
# wizard does it. Workaround: launch the GUI briefly headless into the
# active KDE session, wait until a runner appears in ~/.var/app/.../runners,
# then kill it. Deterministic once we can see a runner file drop.
vortex_bootstrap_runners() {
    local runners_dir="$HOME/.var/app/$VORTEX_FLATPAK_ID/data/bottles/runners"
    # Already have a runner? Nothing to do.
    if [[ -d "$runners_dir" ]] && \
       find "$runners_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | grep -q .; then
        return 0
    fi
    plog "No Bottles runner installed. Kicking the GUI once so it downloads one…"
    plog "  ${DIM}(This is a Bottles CLI limitation — it can't fetch runners itself.)${NC}"

    # Find the KDE session's env from a running plasmashell so the GUI
    # can actually paint (headless-from-ssh but shown-on-user's-screen).
    local plasma_pid dbus display xauth wayland xdg
    plasma_pid="$(pgrep -u "$USER" -x plasmashell | head -1)"
    if [[ -z "$plasma_pid" ]]; then
        perr "No plasmashell running — can't launch Bottles GUI headlessly."
        perr "  Run 'flatpak run $VORTEX_FLATPAK_ID' once from your desktop, close it, and retry."
        return 1
    fi
    dbus=$(tr '\0' '\n' </proc/"$plasma_pid"/environ | grep '^DBUS_SESSION_BUS_ADDRESS=')
    display=$(tr '\0' '\n' </proc/"$plasma_pid"/environ | grep '^DISPLAY=')
    xauth=$(tr '\0' '\n' </proc/"$plasma_pid"/environ | grep '^XAUTHORITY=')
    wayland=$(tr '\0' '\n' </proc/"$plasma_pid"/environ | grep '^WAYLAND_DISPLAY=')
    xdg=$(tr '\0' '\n' </proc/"$plasma_pid"/environ | grep '^XDG_RUNTIME_DIR=')

    env "$dbus" "$display" "$xauth" "$wayland" "$xdg" \
        flatpak run "$VORTEX_FLATPAK_ID" >/tmp/bottles-firstrun.log 2>&1 &
    local gui_pid=$!

    local i
    for i in $(seq 1 60); do
        sleep 5
        if [[ -d "$runners_dir" ]] && \
           find "$runners_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | grep -q .; then
            local names; names="$(find "$runners_dir" -mindepth 1 -maxdepth 1 -type d -printf '%f ' 2>/dev/null)"
            pok "  Runner installed: $names"
            kill "$gui_pid" 2>/dev/null; pkill -f "$VORTEX_FLATPAK_ID" 2>/dev/null || true
            sleep 2
            return 0
        fi
    done

    kill "$gui_pid" 2>/dev/null; pkill -f "$VORTEX_FLATPAK_ID" 2>/dev/null || true
    perr "  Timed out waiting for a runner (5 min). See /tmp/bottles-firstrun.log."
    return 1
}

vortex_create_bottle() {
    if vortex_bottle_exists; then
        pok "Bottle $VORTEX_BOTTLE_NAME already exists."
        return 0
    fi
    vortex_bootstrap_runners || return 1
    plog "Creating Bottles bottle '$VORTEX_BOTTLE_NAME' (win64, application env)…"
    if ! vortex_bcli new \
            --bottle-name "$VORTEX_BOTTLE_NAME" \
            --environment application \
            --arch win64 2>&1 | tail -5; then
        perr "Bottle creation failed."
        return 1
    fi
    pok "Bottle created."
}

# .NET Desktop 6 is required for Vortex 1.8+. Bottles CLI has no first-
# class dependency verb, but its bundled winetricks handles it. We shell
# into the bottle and run winetricks against the bottle's Wine env.
#
# BEWARE: `winetricks -q dotnetdesktop6` prints "ShellExecuteEx failed"
# during install and still exits 0 — the shell-exec chain in Wine hits
# error paths that don't propagate to winetricks' exit code. So we DO
# NOT trust the exit code. Verify by looking for the dotnet host binary
# under the bottle's Program Files after install.
vortex_dotnet_present() {
    local pf="$(_vortex_bottle_dir)/drive_c/Program Files/dotnet"
    [[ -x "$pf/dotnet.exe" ]]
}

vortex_install_dotnet6() {
    if vortex_dotnet_present; then
        pok ".NET Desktop 6 already present in $VORTEX_BOTTLE_NAME."
        return 0
    fi
    plog "Installing .NET Desktop 6 into $VORTEX_BOTTLE_NAME (winetricks, ~5 min)…"
    # Suppress winetricks' constant progress noise; we only care about
    # the final state. `-i` runs a command in the bottle's Wine env
    # with WINEPREFIX etc. preset.
    vortex_bcli shell -b "$VORTEX_BOTTLE_NAME" \
        -i "winetricks -q dotnetdesktop6 corefonts" \
        >/tmp/vortex-dotnet-install.log 2>&1 || true

    if vortex_dotnet_present; then
        pok ".NET Desktop 6 + corefonts installed."
        return 0
    fi
    pwarn ".NET Desktop 6 not detected under Program Files/dotnet after winetricks."
    pwarn "  Vortex will prompt to install .NET on first launch — accept that dialog."
    pwarn "  Log:  /tmp/vortex-dotnet-install.log"
    # NOT fatal — Vortex CAN self-install .NET on first GUI launch. Continue.
    return 0
}

# ─── Vortex installer download + silent install ──────────────────────────

vortex_download_installer() {
    local version="${1:-$VORTEX_DEFAULT_VERSION}" out="$2"
    local url
    url="$(printf "$VORTEX_INSTALLER_URL_TMPL" "$version" "$version")"
    plog "Downloading Vortex v$version (~344 MiB)…"
    plog "  ${DIM}$url${NC}"
    # -sS = silent transfer, still show errors. --progress-bar dumps
    # thousands of bytes of \r-updated progress that fill the caller's
    # stdout buffer with garbage. Better to just print elapsed time at
    # the end.
    local t0=$(date +%s)
    if ! curl -fL -sS "$url" -o "$out"; then
        perr "Vortex installer download failed."
        return 1
    fi
    local elapsed=$(( $(date +%s) - t0 ))
    # Sanity: NSIS-installers are ≥ 100MB. If it's small it's an HTML error page.
    local size; size=$(stat -c %s "$out" 2>/dev/null || stat -f %z "$out" 2>/dev/null || echo 0)
    if (( size < 100000000 )); then
        perr "Downloaded file is only $size bytes — not a real installer. Aborting."
        rm -f "$out"
        return 1
    fi
    pok "Installer downloaded ($((size / 1024 / 1024)) MiB in ${elapsed}s)."
}

vortex_run_installer() {
    local installer="$1"
    plog "Running Vortex installer silently (NSIS /S, dest=$VORTEX_INSTALL_DRIVE_PATH)…"
    plog "  ${DIM}(3–5 min inside Wine; no output unless it fails.)${NC}"
    # NSIS flags: /S = silent, /D=path (must be last, no quotes) = dest.
    # bottles-cli takes program args POSITIONALLY (verified 2026-07-07,
    # bottles-cli v64) — no `-a` flag on this branch. Passing each NSIS
    # switch as its own positional arg.
    if ! vortex_bcli run -b "$VORTEX_BOTTLE_NAME" \
            -e "$installer" \
            "/S" "/D=$VORTEX_INSTALL_DRIVE_PATH" 2>&1 | tail -10; then
        perr "Vortex installer failed inside the bottle."
        return 1
    fi
    # Verify Vortex.exe actually landed.
    local exe; exe="$(_vortex_exe_path_in_bottle)"
    if [[ ! -f "$exe" ]]; then
        # Fall back to searching drive_c — some NSIS releases ignore /D.
        exe="$(find "$(_vortex_bottle_dir)/drive_c" -name 'Vortex.exe' -type f 2>/dev/null | head -1)"
        if [[ -z "$exe" || ! -f "$exe" ]]; then
            perr "Vortex.exe not found under drive_c after install."
            return 1
        fi
        # Record the actual path so the wrapper uses it.
        mkdir -p "$VORTEX_STATE_DIR"
        echo "$exe" > "$VORTEX_STATE_DIR/exe-path"
        pwarn "Vortex installed at non-default path: $exe"
    fi
    pok "Vortex installed."
}

_vortex_exe_path() {
    if [[ -f "$VORTEX_STATE_DIR/exe-path" ]]; then
        cat "$VORTEX_STATE_DIR/exe-path"
    else
        _vortex_exe_path_in_bottle
    fi
}

# ─── Wrapper: /host/bin/vortex → bottles-cli run … ───────────────────────
# Lets the user type `vortex nxm://…` from any shell. Also lets our own
# .desktop files reference a single command.
vortex_write_wrapper() {
    mkdir -p "$VORTEX_LOCAL_BIN"
    local wrapper="$VORTEX_LOCAL_BIN/vortex"
    cat > "$wrapper" <<'EOF'
#!/bin/bash
# powos: Vortex CLI wrapper — dispatches to Bottles.
# Usage:  vortex [Vortex.exe args…]
# Examples:
#   vortex -i "nxm://skyrimspecialedition/mods/12345/files/67890"
#   vortex --game skyrimspecialedition
#   vortex -g "settings.mods.installPath"
set -uo pipefail
BOTTLE="${POWOS_VORTEX_BOTTLE:-PowosVortex}"
FLATPAK="com.usebottles.bottles"
STATE="$HOME/.local/state/powos/vortex"

if [[ -f "$STATE/exe-path" ]]; then
    EXE="$(cat "$STATE/exe-path")"
else
    EXE="$HOME/.var/app/$FLATPAK/data/bottles/bottles/$BOTTLE/drive_c/Vortex/Vortex.exe"
fi

if [[ ! -f "$EXE" ]]; then
    echo "vortex: not installed. Run: powos mods install vortex" >&2
    exit 127
fi

# bottles-cli v64+ takes Vortex-side args as POSITIONAL (after -e).
# Passing them straight through preserves whitespace / URL query
# strings without a re-quote pass.

# Detach — Vortex owns its own event loop; we don't want to block a
# terminal or a xdg-open call from the nxm:// handler.
setsid nohup flatpak run --command=bottles-cli "$FLATPAK" \
    run -b "$BOTTLE" -e "$EXE" "$@" \
    >/dev/null 2>&1 < /dev/null &
disown
EOF
    chmod +x "$wrapper"
    pok "Wrote CLI wrapper: $wrapper"

    # Warn if ~/.local/bin isn't on PATH.
    case ":$PATH:" in
        *:"$VORTEX_LOCAL_BIN":*) : ;;
        *) pwarn "  Add $VORTEX_LOCAL_BIN to PATH to use 'vortex' from the shell." ;;
    esac
}

# ─── Desktop entries: launcher + nxm:// handler ──────────────────────────
vortex_write_desktop_files() {
    mkdir -p "$VORTEX_DESKTOP_DIR" "$VORTEX_ICONS_DIR"

    # Menu launcher
    local launcher="$VORTEX_DESKTOP_DIR/vortex-mod-manager.desktop"
    cat > "$launcher" <<EOF
[Desktop Entry]
Type=Application
Name=Vortex Mod Manager
GenericName=Mod Manager
Comment=Nexus Mods' Vortex, running under Bottles (Wine)
Exec=$VORTEX_LOCAL_BIN/vortex
Icon=vortex-mod-manager
Terminal=false
Categories=Game;Utility;
StartupNotify=true
StartupWMClass=vortex
EOF

    # nxm:// protocol handler — %u passes the URL to `vortex -i <url>`
    local handler="$VORTEX_DESKTOP_DIR/vortex-nxm-handler.desktop"
    cat > "$handler" <<EOF
[Desktop Entry]
Type=Application
Name=Vortex (nxm handler)
Comment=Handle Nexus Mods nxm:// URLs
Exec=$VORTEX_LOCAL_BIN/vortex -i %u
Icon=vortex-mod-manager
Terminal=false
Categories=Network;
MimeType=x-scheme-handler/nxm;x-scheme-handler/nxm-protocol;
NoDisplay=true
EOF

    update-desktop-database "$VORTEX_DESKTOP_DIR" 2>/dev/null || true
    pok "Desktop entries written."
}

vortex_extract_icon() {
    # Vortex's installer drops an icon in the install dir; copy it out.
    local src bottle_c
    bottle_c="$(_vortex_bottle_dir)/drive_c"
    src="$(find "$bottle_c" -name 'vortex.ico' -o -name 'Vortex.png' 2>/dev/null | head -1)"
    if [[ -n "$src" && -f "$src" ]]; then
        # Convert .ico → .png if needed
        case "$src" in
            *.ico) command -v convert >/dev/null 2>&1 \
                     && convert "$src" "$VORTEX_ICONS_DIR/vortex-mod-manager.png" 2>/dev/null \
                     && plog "Icon extracted." ;;
            *.png) cp "$src" "$VORTEX_ICONS_DIR/vortex-mod-manager.png" ;;
        esac
    fi
}

# ─── nxm:// default handler switching ────────────────────────────────────
# Only one app can hold x-scheme-handler/nxm at a time. If NMA is already
# registered, don't clobber it without asking — the user picked NMA for
# a reason (Cyberpunk / SDV). Instead, expose an explicit flip verb.
vortex_set_default_nxm() {
    if xdg-mime default vortex-nxm-handler.desktop x-scheme-handler/nxm 2>/dev/null; then
        pok "nxm:// default handler set to Vortex."
    else
        pwarn "xdg-mime failed to update — set manually with:"
        pwarn "  xdg-mime default vortex-nxm-handler.desktop x-scheme-handler/nxm"
    fi
}

vortex_current_nxm_handler() {
    xdg-mime query default x-scheme-handler/nxm 2>/dev/null
}

# ─── High-level commands ─────────────────────────────────────────────────

# powos mods install vortex [--version <ver>] [--no-default]
#   By default takes over x-scheme-handler/nxm — Vortex covers ~150 games,
#   NMA only 2, so Vortex-as-default is the sensible fallback. Pass
#   --no-default to keep whatever handler is currently registered.
vortex_install_cmd() {
    local version="$VORTEX_DEFAULT_VERSION"
    local take_default=true
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --version)              version="$2"; shift 2 ;;
            --no-default)           take_default=false; shift ;;
            --set-default)          take_default=true; shift ;;   # legacy no-op
            *)                      perr "Unknown flag: $1"; return 1 ;;
        esac
    done

    plog "Vortex install (v$version, via Bottles)"
    vortex_ensure_bottles          || return 1
    vortex_grant_filesystem        || true
    vortex_create_bottle           || return 1
    vortex_install_dotnet6         || pwarn "  Continuing — Vortex may self-install .NET on first run."

    # Stage the installer INSIDE the Bottles Flatpak's data dir. Its
    # sandbox blocks arbitrary host paths (even /tmp) — passing an .exe
    # under /tmp to `bottles-cli run` fails with "Executable file path
    # does not exist or is not accessible by the Flatpak". The temp
    # subdir under bottles' own data is always readable inside the
    # sandbox by design.
    local bottles_temp; bottles_temp="$(_vortex_bottles_temp)"
    mkdir -p "$bottles_temp"
    local installer="$bottles_temp/vortex-setup-$version.exe"
    if [[ ! -f "$installer" ]] || (( $(stat -c %s "$installer" 2>/dev/null || echo 0) < 100000000 )); then
        if ! vortex_download_installer "$version" "$installer"; then
            return 1
        fi
    else
        pok "Installer already cached at $installer (skipping download)."
    fi
    if ! vortex_run_installer "$installer"; then
        return 1
    fi
    # Keep the installer around — Bottles cleans temp itself, and if the
    # user re-runs `install`, we skip the 344 MiB download.

    vortex_extract_icon
    vortex_write_wrapper
    vortex_write_desktop_files

    if $take_default; then
        local cur; cur="$(vortex_current_nxm_handler)"
        if [[ -n "$cur" && "$cur" != "vortex-nxm-handler.desktop" ]]; then
            plog "nxm:// was handled by: $cur — replacing with Vortex."
            plog "  (Undo any time: xdg-mime default $cur x-scheme-handler/nxm)"
        fi
        vortex_set_default_nxm
    else
        plog "Leaving nxm:// handler untouched (--no-default). Current: $(vortex_current_nxm_handler)"
        plog "  Flip to Vortex later:  powos mods vortex set-default-handler"
    fi

    echo
    pok "Vortex installed. Try:"
    echo "  vortex --game skyrimspecialedition        # launch, activate Skyrim SE"
    echo "  vortex -i 'nxm://…'                       # download+install a mod"
    echo "  powos mods vortex url 'nxm://…'           # same, wrapped"
    echo "  powos mods vortex health-check            # verify prefix"
}

vortex_uninstall_cmd() {
    plog "Removing PowOS-managed Vortex install (bottle: $VORTEX_BOTTLE_NAME)…"
    if vortex_bottle_exists; then
        # Bottles has no `delete` CLI verb yet — remove the bottle dir
        # directly. Safe: nothing else owns it.
        local d; d="$(_vortex_bottle_dir)"
        [[ -d "$d" ]] && rm -rf "$d" && plog "  Bottle dir removed."
    fi

    rm -f "$VORTEX_LOCAL_BIN/vortex"
    rm -f "$VORTEX_DESKTOP_DIR/vortex-mod-manager.desktop"
    rm -f "$VORTEX_DESKTOP_DIR/vortex-nxm-handler.desktop"
    rm -f "$VORTEX_ICONS_DIR/vortex-mod-manager.png"
    rm -rf "$VORTEX_STATE_DIR"
    update-desktop-database "$VORTEX_DESKTOP_DIR" 2>/dev/null || true

    # If nxm:// was pointing at us, clear it back to nothing.
    if [[ "$(vortex_current_nxm_handler)" == "vortex-nxm-handler.desktop" ]]; then
        xdg-mime default "" x-scheme-handler/nxm 2>/dev/null || true
    fi

    pok "Vortex uninstalled. Bottles Flatpak left in place (other bottles may use it)."
}

# powos mods vortex run [args…] — plain launch (no CLI args = GUI).
vortex_run_cmd() {
    if [[ ! -x "$VORTEX_LOCAL_BIN/vortex" ]]; then
        perr "Vortex not installed. Run: powos mods install vortex"
        return 1
    fi
    "$VORTEX_LOCAL_BIN/vortex" "$@"
}

# powos mods vortex url <nxm-url>
#   Alias for `vortex -i <url>` — Vortex downloads+installs the mod.
vortex_url_cmd() {
    local url="${1:?Usage: powos mods vortex url <nxm://... URL>}"
    case "$url" in
        nxm://*|nxm-protocol://*) : ;;
        *) perr "Not an nxm:// URL: $url"; return 1 ;;
    esac
    vortex_run_cmd -i "$url"
    pok "Dispatched to Vortex (download + install)."
}

# powos mods vortex bulk <game> <mod-id> [mod-id…]
#   Resolve each mod-id to its primary MAIN file via Nexus REST, then
#   throw `vortex -i nxm://…` at each. Same file-picking logic the
#   NMA path uses — this is what makes agent-driven bulk work.
vortex_bulk_cmd() {
    local game="${1:?Usage: powos mods vortex bulk <game> <mod-id> [mod-id ...]}"
    shift
    local ids=("$@")
    if [[ ${#ids[@]} -eq 0 ]]; then
        while IFS= read -r line; do
            line="${line%%#*}"
            line="$(echo "$line" | tr -d '[:space:]')"
            [[ -n "$line" ]] && ids+=("$line")
        done
    fi
    [[ ${#ids[@]} -eq 0 ]] && { perr "No mod-ids given."; return 1; }

    local slug; slug="$(mods_nexus_slug_of "$game")"
    local key; key="$(mods_nexus_key)" || return 1

    local ok=0 fail=0 mod_id file_id
    for mod_id in "${ids[@]}"; do
        plog "→ mod $mod_id"
        # Resolve primary MAIN file-id from Nexus API.
        file_id="$(curl -sSf -H "apikey: $key" -H "User-Agent: powos-vortex" \
                    "https://api.nexusmods.com/v1/games/$slug/mods/$mod_id/files.json" \
                | python3 -c '
import json, sys
d = json.load(sys.stdin)
files = d.get("files", []) or []
mains = [f for f in files if f.get("category_id") == 1]
picked = None
for f in mains:
    if f.get("is_primary"): picked = f; break
if not picked and mains:
    picked = sorted(mains, key=lambda x: x.get("uploaded_timestamp", 0), reverse=True)[0]
if not picked and files:
    picked = sorted(files, key=lambda x: x.get("uploaded_timestamp", 0), reverse=True)[0]
print(picked["file_id"] if picked else "")
')" || { perr "  files.json fetch failed"; fail=$((fail+1)); continue; }

        if [[ -z "$file_id" ]]; then
            perr "  mod $mod_id: no downloadable file"; fail=$((fail+1)); continue
        fi

        vortex_run_cmd -i "nxm://$slug/mods/$mod_id/files/$file_id"
        pok "  file $file_id dispatched"
        ok=$((ok+1))
        sleep 1  # Nexus rate limit: 600/day Premium, 300/day free.
    done
    pok "Done. $ok ok, $fail failed."
}

# powos mods vortex get <state-path>
vortex_get_cmd() {
    local path="${1:?Usage: powos mods vortex get <state.path>}"
    vortex_run_cmd -g "$path"
}

# powos mods vortex set <state-path>=<value>  — GUARDED (state-corrupting).
vortex_set_cmd() {
    local expr="${1:?Usage: powos mods vortex set <state.path>=<value>}"
    pwarn "vortex -s can corrupt Vortex's state DB if used wrong."
    pwarn "  Doing this because you asked, but read Vortex wiki first."
    vortex_run_cmd -s "$expr"
}

# powos mods vortex install-dotnet   — retry .NET install if first pass failed.
vortex_install_dotnet_cmd() {
    vortex_bottle_exists || { perr "Bottle missing. Run: powos mods install vortex"; return 1; }
    vortex_install_dotnet6
}

# powos mods vortex set-default-handler
vortex_set_default_cmd() {
    vortex_set_default_nxm
}

# powos mods vortex handler   — show who currently owns nxm://
vortex_handler_cmd() {
    local cur; cur="$(vortex_current_nxm_handler)"
    echo "Current nxm:// handler: ${cur:-<none>}"
}

# powos mods vortex health-check   — verify install pieces exist.
vortex_health_cmd() {
    local ok=true
    printf "  bottles flatpak:      "
    if flatpak info "$VORTEX_FLATPAK_ID" >/dev/null 2>&1; then echo "yes"; else echo "MISSING"; ok=false; fi

    printf "  bottle $VORTEX_BOTTLE_NAME: "
    if vortex_bottle_exists; then echo "yes"; else echo "MISSING"; ok=false; fi

    printf "  Vortex.exe:           "
    if [[ -f "$(_vortex_exe_path)" ]]; then echo "yes ($( _vortex_exe_path ))"; else echo "MISSING"; ok=false; fi

    printf "  wrapper:              "
    if [[ -x "$VORTEX_LOCAL_BIN/vortex" ]]; then echo "yes"; else echo "MISSING"; ok=false; fi

    printf "  menu .desktop:        "
    if [[ -f "$VORTEX_DESKTOP_DIR/vortex-mod-manager.desktop" ]]; then echo "yes"; else echo "MISSING"; ok=false; fi

    printf "  nxm .desktop:         "
    if [[ -f "$VORTEX_DESKTOP_DIR/vortex-nxm-handler.desktop" ]]; then echo "yes"; else echo "MISSING"; ok=false; fi

    printf "  nxm:// default:       "
    echo "$(vortex_current_nxm_handler)"

    $ok || return 1
}

# powos mods vortex — dispatch verbs.
vortex_dispatch() {
    POWOS_MODS_LAST_VERB="vortex ${1:-}"
    local sub="${1:-help}"; shift || true
    case "$sub" in
        install)                    vortex_install_cmd "$@" ;;
        uninstall|remove)           vortex_uninstall_cmd "$@" ;;
        run|launch|start)           vortex_run_cmd "$@" ;;
        url|nxm|install-url)        vortex_url_cmd "$@" ;;
        bulk|install-bulk)          vortex_bulk_cmd "$@" ;;
        get)                        vortex_get_cmd "$@" ;;
        set)                        vortex_set_cmd "$@" ;;
        install-dotnet)             vortex_install_dotnet_cmd "$@" ;;
        set-default|set-default-handler) vortex_set_default_cmd ;;
        handler|current-handler)    vortex_handler_cmd ;;
        health|health-check|check)  vortex_health_cmd ;;
        help|--help|-h|"")          vortex_help ;;
        *) perr "Unknown: powos mods vortex $sub"; vortex_help; return 1 ;;
    esac
}

vortex_help() {
    cat <<EOF
${BOLD}powos mods vortex${NC} — Nexus Vortex on PowOS, via Bottles Flatpak

Vortex handles every Nexus-tracked game NMA doesn't yet (Skyrim SE/AE,
Fallout 4, Starfield, BG3, Witcher 3, Oblivion, Fallout NV, Morrowind…).
It runs in a dedicated Wine sandbox — no Steam entry, no ostree layering.

  ${BOLD}install${NC}                        Install Vortex + .NET 6 into bottle.
                                   Takes over nxm:// by default (Vortex
                                   covers ~150 games vs NMA's 2).
                                   [--version 2.2.0] [--no-default]
  ${BOLD}uninstall${NC}                      Remove bottle + wrappers + .desktop files
  ${BOLD}run${NC} [args…]                    Launch Vortex (no args = GUI)
  ${BOLD}url${NC} <nxm://…>                  Download + install a mod (Vortex -i)
  ${BOLD}bulk${NC} <game> <mod-id>…          Resolve MAIN file per mod-id, dispatch each
                                   Reads from stdin if no ids given.
  ${BOLD}get${NC} <state.path>               Print a value from Vortex's state
  ${BOLD}set${NC} <state.path>=<val>         Write a value (DANGEROUS)
  ${BOLD}install-dotnet${NC}                 Re-run .NET 6 install (if first attempt failed)
  ${BOLD}set-default-handler${NC}            Set Vortex as system nxm:// handler
  ${BOLD}handler${NC}                        Show who currently owns nxm://
  ${BOLD}health-check${NC}                   Verify each piece of the install

Under the hood:
  Bottle:     $VORTEX_BOTTLE_NAME (Flatpak $VORTEX_FLATPAK_ID)
  Vortex.exe: $(_vortex_exe_path_in_bottle | sed "s|$HOME|~|")
  Wrapper:    $VORTEX_LOCAL_BIN/vortex
  Handler:    $VORTEX_DESKTOP_DIR/vortex-nxm-handler.desktop
EOF
}
