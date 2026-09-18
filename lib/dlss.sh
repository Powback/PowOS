#!/bin/bash
# dlss.sh - NVIDIA DLSS on Linux: transformer presets (DLSS 4) and layer-wide
# Neural Rendering (DLSS 5 NR).
#
# Why one Vulkan layer covers every game: on Linux DXVK translates D3D9/10/11 and
# VKD3D-Proton translates D3D12, so EVERY DirectX game is already Vulkan by the
# time it presents. One implicit layer therefore reaches DX9 through DX12 plus
# native Vulkan with no per-game setup. The Windows tooling cannot be ported —
# DLSS5-Feeder depends on the Windows Vulkan loader reading ReShade's layer out of
# the registry, which Proton's winevulkan does not do.
#
#   powos dlss status         # what works, what is blocked, and why
#   powos dlss doctor         # run the pipeline and report where it breaks
#   powos dlss runtime import <path>   # verify + install nvngx_dlssnr.dll by hash
#   powos dlss runtime list   # installed runtimes, hashes, target GPU
#   powos dlss nr install     # build + install the NR Vulkan layer (per-user)
#   powos dlss nr enable|disable [<appid>]
#   powos dlss4 preset <j|k|l|m>       # force a DLSS 4 transformer preset
#
# CONSTRAINTS (be honest — this is the part that matters):
#   - NR costs roughly 50-60% of your frame rate. NVIDIA's own 616.64 notes say so.
#   - NR is EXPERIMENTAL on Linux. Open reports against this exact route include
#     Xid 31 GPU MMU faults and Xid 69 + black screen on Blackwell.
#   - Super Resolution and Frame Generation can NEVER be made universal: they need
#     per-frame motion vectors and depth from the engine. Only NR can be applied
#     layer-wide, because a synthesised DLSS contract (optical-flow motion vectors,
#     null depth, UseAutoMask) is enough for it. Do not promise SR/FG here.
#   - The driver/runtime pairing decides everything and is not predictable. On
#     Windows 616.64 a consumer scored 0/300 evaluates; the same build scored
#     300/300 on 616.56, crashing inside NVIDIA's own nvngx_dlssnr.dll. Linux is a
#     different driver branch, so `doctor` MEASURES instead of assuming.
#   - MULTI-SWAPCHAIN GAMES ARE NOT SERVED YET. The helper builds one neural
#     context for whichever swapchain asks first. GTA V Enhanced presents six
#     (Rockstar launcher, Steam overlay, then the game), the launcher wins, and
#     every frame from the game's real swapchain is then rejected — observed
#     live: ~3300 frames submitted, 0 composed. There is no knob to pin it, and
#     restarting the helper to rebind does NOT help: it re-binds the launcher
#     and yanks the transport out from under the running game. Prefer a
#     single-swapchain title until upstream can select a swapchain.
#   - PowOS ships NO NVIDIA binaries and NO layer binaries. nvngx_dlssnr.dll is
#     NVIDIA's and is not in any public driver package (verified against the
#     official 616.92 Windows package by filename and exact size). The layer is
#     AGPL-3.0. Both are fetched or built per-machine — your hardware, your files.
set -uo pipefail
source "${POWOS_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/common.sh"
POWOS_TAG=dlss

# Per-machine state. NOT ~/.config/powos — lib/backup.sh git-commits that tree to
# the backup remote, and a 158 MB DLL must never land in a git repo.
DLSS_CACHE_DIR="${DLSS_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/powos/dlss}"
DLSS_RUNTIME_DIR="${DLSS_RUNTIME_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/dlssnr/binaries}"
DLSS_LAYER_SRC="${DLSS_LAYER_SRC:-$DLSS_CACHE_DIR/DLSS5VKLayer}"
DLSS_LAYER_REPO="${DLSS_LAYER_REPO:-https://github.com/bmitch87/DLSS5VKLayer}"
# Per-user manifest dir: writing here avoids /usr entirely, so no
# sysext_unmerge_if_needed dance is needed (see common.sh).
DLSS_LAYER_MANIFEST_DIR="${DLSS_LAYER_MANIFEST_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/vulkan/implicit_layer.d}"
# The shim's env sentinel dir. bin/powos-game-shim sources <appid>.env before
# exec'ing the game, so arming the layer needs no launch-option writer of our own
# (mods_set_launch_options CLOBBERS LaunchOptions and harness_setup_shim PREPENDS
# to it — they already fight; a third writer would make it worse).
DLSS_SHIM_ENV_DIR="${DLSS_SHIM_ENV_DIR:-/run/powos/verify}"

# The NVIDIA-signed NR runtime for RTX 50 (Blackwell, sm_120), build 310.8.0.0.
# Corroborated across several independent projects. A PATCHED runtime has a
# different hash AND fails NGX's own Authenticode check with 0xBAD00002
# HashMismatch on RTX 50 — so on Blackwell the plain build is the only one that
# works, and this hash is how we prove we have it.
DLSS_NR_SHA256_RTX50="e16bcf15e16e13f527491cdf7845b2fe6521a738d8f7c9c721866a8496e1fc8e"
DLSS_NR_SIZE_RTX50=165840496

# ── capability probes ────────────────────────────────────────────────────
# One fact per function, each env-overridable, so tier-1 tests can mock them
# (same seam as gpu_dgpu_bdf in lib/gpu.sh).

# Working NVIDIA driver on the host. Same idiom as cuda_host_driver_ok.
dlss_driver_ok() { command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; }

dlss_gpu_name() {
    [[ -n "${POWOS_DLSS_GPU_NAME:-}" ]] && { echo "$POWOS_DLSS_GPU_NAME"; return; }
    nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1
}

dlss_driver_version() {
    [[ -n "${POWOS_DLSS_DRIVER_VER:-}" ]] && { echo "$POWOS_DLSS_DRIVER_VER"; return; }
    nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1
}

# Is this an RTX 50-series (Blackwell) card? The shipped NR model is hard-locked
# to it — on RTX 40 and older it fails with 0xBAD00001 on "feature 18 create",
# and only a community FP16 rebuild runs there.
dlss_gpu_is_blackwell() { [[ "$(dlss_gpu_name)" == *"RTX 50"* ]]; }

# The driver's wine-side NGX bridge. Proton loads nvngx.dll from here; the NR
# helper additionally needs _nvngx.dll SYMLINKED NEXT TO ITSELF — having it only
# in system32, or only pointed at by NVIDIA_WINE_DLL_DIR, yields 0xBAD00001.
dlss_nvidia_wine_dir() {
    [[ -n "${POWOS_DLSS_WINE_DIR:-}" ]] && { echo "$POWOS_DLSS_WINE_DIR"; return; }
    local d
    for d in /usr/lib64/nvidia/wine /usr/lib/nvidia/wine; do
        [[ -f "$d/_nvngx.dll" ]] && { echo "$d"; return 0; }
    done
    return 1
}

# The NATIVE NGX library, which must be discoverable by the system loader.
#
# Deliberately NOT `ldconfig -p | grep -q`: this file runs under `set -o pipefail`
# and `grep -q` exits on its first match, SIGPIPE-ing ldconfig, so that pipeline
# returns 141 *depending on scheduling*. It reported "libnvidia-ngx.so not in
# ldconfig" on a machine that plainly had it. Capture, then pattern-match.
dlss_native_ngx_ok() {
    case "${POWOS_DLSS_NATIVE_NGX:-}" in
        1)  return 0 ;;
        "") ;;
        *)  return 1 ;;
    esac
    local out
    out="$(ldconfig -p 2>/dev/null)" || return 1
    [[ "$out" == *libnvidia-ngx.so* ]]
}

dlss_nr_runtime_path() { echo "$DLSS_RUNTIME_DIR/nvngx_dlssnr.dll"; }
dlss_nr_runtime_present() { [[ -f "$(dlss_nr_runtime_path)" ]]; }

# SHA-256 of a file (lowercase 64-hex). Seam: tests shadow it. Mirrors win_sha256.
dlss_sha256() {
    local h _
    read -r h _ < <(sha256sum "${1:?}" 2>/dev/null) || return 1
    [[ -n "$h" ]] && echo "$h"
}

# Does the installed runtime match the known-good RTX 50 build?
dlss_nr_runtime_verified() {
    dlss_nr_runtime_present || return 1
    [[ "$(dlss_sha256 "$(dlss_nr_runtime_path)")" == "$DLSS_NR_SHA256_RTX50" ]]
}

dlss_layer_installed() {
    compgen -G "$DLSS_LAYER_MANIFEST_DIR/VK_LAYER_NV_dlssnr*.json" >/dev/null 2>&1
}

# A competing manifest elsewhere is a real hazard: the layer's own installer warns
# that the user tree, system tree, tarball and RPM all claim the same manifest and
# "the loader reads whichever it finds first".
dlss_layer_conflicts() {
    local d
    for d in /usr/share/vulkan/implicit_layer.d /etc/vulkan/implicit_layer.d; do
        compgen -G "$d/VK_LAYER_NV_dlssnr*.json" >/dev/null 2>&1 && echo "$d"
    done
    return 0
}

# Proton must bundle DXVK-NVAPI. Valve's stock Proton and Proton Experimental are
# explicitly NOT supported by the NR helper because they do not ship that stack.
dlss_proton_dir() {
    [[ -n "${POWOS_DLSS_PROTON:-}" ]] && { echo "$POWOS_DLSS_PROTON"; return; }
    local compat found=""
    for compat in "${XDG_DATA_HOME:-$HOME/.local/share}/Steam/compatibilitytools.d" \
                  "$HOME/.steam/root/compatibilitytools.d" \
                  /usr/share/steam/compatibilitytools.d; do
        [[ -d "$compat" ]] || continue
        # proton-cachyos first (the reference platform), then newest GE-Proton.
        found="$(find "$compat" -maxdepth 1 -type d \( -iname '*cachyos*' \) 2>/dev/null | sort -V | tail -1)"
        [[ -n "$found" ]] && { echo "$found"; return 0; }
        found="$(find "$compat" -maxdepth 1 -type d -name 'GE-Proton*' 2>/dev/null | sort -V | tail -1)"
        [[ -n "$found" ]] && { echo "$found"; return 0; }
    done
    return 1
}

# ── status ───────────────────────────────────────────────────────────────

cmd_dlss_status() {
    echo -e "${BOLD}NVIDIA DLSS${NC}"
    echo    "════════════════════════════════════════"

    local mark_ok="${GREEN}●${NC}" mark_no="${RED}○${NC}" mark_warn="${YELLOW}◐${NC}"
    local gpu ver wine_dir

    if ! dlss_driver_ok; then
        echo -e "  Driver:        $mark_no no working NVIDIA driver (nvidia-smi sees no GPU)"
        echo
        pwarn "DLSS needs the NVIDIA driver. Nothing below can work without it."
        return 0
    fi

    gpu="$(dlss_gpu_name)"; ver="$(dlss_driver_version)"
    echo -e "  GPU:           $mark_ok $gpu"
    echo -e "  Driver:        $mark_ok $ver"

    # DLSS 4 — official, no blockers.
    wine_dir="$(dlss_nvidia_wine_dir || true)"
    if [[ -n "$wine_dir" ]]; then
        echo -e "  DLSS 4 SR:     $mark_ok nvngx.dll present  ${DIM}$wine_dir${NC}"
        if [[ -f "$wine_dir/nvngx_dlssg.dll" ]]; then
            echo -e "  DLSS 4 FG:     $mark_ok nvngx_dlssg.dll present"
        else
            echo -e "  DLSS 4 FG:     $mark_warn nvngx_dlssg.dll absent — no frame generation"
        fi
    else
        echo -e "  DLSS 4 SR:     $mark_no no nvngx.dll — driver ships no wine NGX bridge"
    fi

    if dlss_native_ngx_ok; then
        echo -e "  Native NGX:    $mark_ok libnvidia-ngx.so discoverable"
    else
        echo -e "  Native NGX:    $mark_warn libnvidia-ngx.so not in ldconfig — NR init will fail"
    fi

    # DLSS 5 NR.
    echo
    echo -e "  ${BOLD}Neural Rendering (DLSS 5)${NC}"
    if dlss_gpu_is_blackwell; then
        echo -e "  Hardware:      $mark_ok RTX 50-series (FP8 tensor cores)"
    else
        echo -e "  Hardware:      $mark_warn not RTX 50 — the shipped model is Blackwell-locked"
        echo -e "                 ${DIM}fails 0xBAD00001 on feature-18 create; needs an FP16 rebuild${NC}"
    fi

    if dlss_nr_runtime_verified; then
        echo -e "  NR runtime:    $mark_ok verified  ${DIM}sha256 ${DLSS_NR_SHA256_RTX50:0:12}…${NC}"
    elif dlss_nr_runtime_present; then
        echo -e "  NR runtime:    $mark_warn present but UNRECOGNISED hash"
        echo -e "                 ${DIM}a patched runtime fails Authenticode (0xBAD00002) on RTX 50${NC}"
        echo -e "                 ${DIM}powos dlss runtime list${NC}"
    else
        echo -e "  NR runtime:    $mark_no nvngx_dlssnr.dll absent"
        echo -e "                 ${DIM}powos dlss runtime import <dir-with-the-dll>${NC}"
    fi

    if dlss_layer_installed; then
        echo -e "  Vulkan layer:  $mark_ok installed  ${DIM}$DLSS_LAYER_MANIFEST_DIR${NC}"
        local conflict; conflict="$(dlss_layer_conflicts)"
        [[ -n "$conflict" ]] && {
            echo -e "  ${YELLOW}conflict:${NC}      a second manifest exists in $conflict"
            echo -e "                 ${DIM}the loader reads whichever it finds first — remove one${NC}"
        }
    else
        echo -e "  Vulkan layer:  $mark_no not installed  ${DIM}powos dlss nr install${NC}"
    fi

    local proton; proton="$(dlss_proton_dir || true)"
    if [[ -n "$proton" ]]; then
        echo -e "  Proton:        $mark_ok $(basename "$proton")"
    else
        echo -e "  Proton:        $mark_no no GE-Proton or proton-cachyos found"
        echo -e "                 ${DIM}stock Proton/Experimental lack DXVK-NVAPI and will not work${NC}"
    fi

    echo
    # Next step — computed from state, like win_status's tail.
    if ! dlss_nr_runtime_verified; then
        echo -e "  ${BOLD}Next:${NC} powos dlss runtime import <path>   ${DIM}(supply NVIDIA's NR runtime)${NC}"
    elif ! dlss_layer_installed; then
        echo -e "  ${BOLD}Next:${NC} powos dlss nr install"
    else
        echo -e "  ${BOLD}Next:${NC} powos dlss doctor   ${DIM}(measure whether this driver works)${NC}"
    fi
    echo -e "  ${DIM}NR costs ~50-60% fps and is experimental. SR/FG stay per-game by design.${NC}"
    echo
}

# ── runtime import ───────────────────────────────────────────────────────

# Read a PE file's machine type. Mirrors asi_pe_arch; duplicated rather than
# sourced because lib/mods/asi.sh carries a lot of unrelated RAGE-game state.
dlss_pe_arch() {
    python3 - "$1" <<'PY'
import sys, struct
try:
    with open(sys.argv[1], "rb") as fh:
        head = fh.read(4096)
    if head[:2] != b"MZ":
        print("notpe"); sys.exit(0)
    e = struct.unpack_from("<I", head, 0x3C)[0]
    if head[e:e+4] != b"PE\0\0":
        print("notpe"); sys.exit(0)
    m = struct.unpack_from("<H", head, e+4)[0]
    print({0x8664: "x64", 0x14C: "x86", 0xAA64: "arm64"}.get(m, "other:%x" % m))
except Exception:
    print("error")
PY
}

# Does the PE carry an embedded Authenticode signature? NGX validates it and
# refuses feature 18 with 0xBAD00002 if the file was patched after signing, so a
# missing certificate table is a hard "this will not work".
dlss_pe_signed() {
    python3 - "$1" <<'PY'
import sys, struct
try:
    with open(sys.argv[1], "rb") as fh:
        head = fh.read(4096)
    e = struct.unpack_from("<I", head, 0x3C)[0]
    magic = struct.unpack_from("<H", head, e + 24)[0]
    base = e + 24 + (112 if magic == 0x20b else 96)
    _rva, size = struct.unpack_from("<II", head, base + 4 * 8)
    sys.exit(0 if size > 0 else 1)
except Exception:
    sys.exit(1)
PY
}

cmd_dlss_runtime_import() {
    local src="${1:-}"
    if [[ -z "$src" ]]; then
        perr "Usage: powos dlss runtime import <file-or-directory>"
        perr "Supply NVIDIA's nvngx_dlssnr.dll. PowOS ships no NVIDIA binaries."
        return 1
    fi
    # Accept either the DLL itself or a directory containing it.
    local dll="$src"
    [[ -d "$src" ]] && dll="$src/nvngx_dlssnr.dll"
    if [[ ! -f "$dll" ]]; then
        perr "Not found: $dll"
        return 1
    fi

    local arch size sum
    arch="$(dlss_pe_arch "$dll")"
    [[ "$arch" == "x64" ]] || { perr "Not a 64-bit Windows DLL (arch: $arch) — refusing."; return 1; }
    if ! dlss_pe_signed "$dll"; then
        perr "No embedded Authenticode signature."
        perr "NGX validates the signature and will refuse feature 18 (0xBAD00002)."
        return 1
    fi

    size="$(stat -c%s "$dll" 2>/dev/null || echo 0)"
    sum="$(dlss_sha256 "$dll")"

    # Hash is the gate. A match proves the file is bit-identical to the known-good
    # NVIDIA-signed build, which is the only one that works on Blackwell.
    if [[ "$sum" == "$DLSS_NR_SHA256_RTX50" ]]; then
        pok "SHA-256 verified: the NVIDIA-signed 310.8.0.0 RTX 50 build."
    else
        pwarn "UNRECOGNISED runtime — this is not the known-good RTX 50 build."
        pwarn "  expected: $DLSS_NR_SHA256_RTX50  (${DLSS_NR_SIZE_RTX50} bytes)"
        pwarn "  supplied: $sum  ($size bytes)"
        pwarn "Community FP16 rebuilds for RTX 20/30/40 have different hashes and, on"
        pwarn "an RTX 50 card, fail Authenticode with 0xBAD00002. Import anyway only if"
        pwarn "you know which build this is."
        confirm "Import this unrecognised runtime?" || { plog "Aborted."; return 0; }
    fi

    mkdir -p "$DLSS_RUNTIME_DIR"
    install -m 0644 "$dll" "$(dlss_nr_runtime_path)" || { perr "Install failed."; return 1; }
    pok "Installed: $(dlss_nr_runtime_path)"
    plog "Next: powos dlss nr install"
}

cmd_dlss_runtime_list() {
    echo -e "${BOLD}DLSS runtimes${NC}"
    echo    "════════════════════════════════════════"
    if ! dlss_nr_runtime_present; then
        echo -e "  ${DIM}no NR runtime installed${NC}"
        echo -e "  ${DIM}powos dlss runtime import <path>${NC}"
        echo
        return 0
    fi
    local p sum size
    p="$(dlss_nr_runtime_path)"
    sum="$(dlss_sha256 "$p")"; size="$(stat -c%s "$p" 2>/dev/null || echo 0)"
    printf "  %-22s %s\n" "nvngx_dlssnr.dll" "$size bytes"
    printf "  %-22s %s\n" "sha256" "$sum"
    if [[ "$sum" == "$DLSS_NR_SHA256_RTX50" ]]; then
        printf "  %-22s %s\n" "identified" "NVIDIA-signed 310.8.0.0 — RTX 50 (sm_120)"
    else
        printf "  %-22s %s\n" "identified" "UNKNOWN build — not the RTX 50 reference hash"
    fi
    echo
}

# ── NR layer install ─────────────────────────────────────────────────────

# Build deps, installed INSIDE a throwaway container — never layered onto the
# host. On a bootc image layering ~15 build-time packages costs a reboot and then
# has to be carried forever, for tools nothing needs at runtime.
#
# This list is NOT the upstream README's; each addition below it was found by a
# failing build, so do not "tidy" them away:
#   gcc-c++ libstdc++-devel   64-bit bits/c++config.h — the .i686 set alone
#                             fails the native target
#   libstdc++-static glibc-static  the CLI tools link with -static
#   libXi-devel libX11-devel  layer_linux/src/hotkey.cpp needs
#                             X11/extensions/XInput2.h
# The 32-bit layer is MANDATORY, not optional: 32-bit games load the 32-bit
# layer, and the build drives native/linux32/windows targets together.
DLSS_BUILD_DEPS="clang llvm meson ninja-build git pkgconf-pkg-config
gcc-c++ libstdc++-devel libstdc++-static glibc-static
mingw64-gcc-c++ qt6-qtbase-devel
libXi-devel libX11-devel libXext-devel libXrandr-devel libXfixes-devel
glibc-devel.i686 libstdc++-devel.i686 libgcc.i686 libatomic.i686
glslang vulkan-headers"

# Pin the build container to the HOST's Fedora release. A newer glibc in the
# container produces binaries the host loader refuses; older is safe but the
# layer links against the host Vulkan loader and Qt, so matching is correct.
dlss_build_image() {
    [[ -n "${POWOS_DLSS_BUILD_IMAGE:-}" ]] && { echo "$POWOS_DLSS_BUILD_IMAGE"; return; }
    local ver
    ver="$(. /etc/os-release 2>/dev/null && echo "${VERSION_ID:-}")"
    echo "registry.fedoraproject.org/fedora:${ver:-latest}"
}

cmd_dlss_nr_install() {
    dlss_driver_ok || { perr "No working NVIDIA driver — fix that first."; return 1; }

    if ! dlss_nr_runtime_verified; then
        if dlss_nr_runtime_present; then
            pwarn "The installed NR runtime is not the known-good build; continuing anyway."
        else
            perr "No NR runtime. Without nvngx_dlssnr.dll the layer installs but stays inert."
            perr "  powos dlss runtime import <path>"
            return 1
        fi
    fi

    if ! command -v podman >/dev/null 2>&1; then
        perr "podman not found (should ship with PowOS) — needed for the container build."
        return 1
    fi

    mkdir -p "$DLSS_CACHE_DIR"
    if [[ -d "$DLSS_LAYER_SRC/.git" ]]; then
        plog "Updating $DLSS_LAYER_SRC…"
        git -C "$DLSS_LAYER_SRC" pull --ff-only || pwarn "Pull failed; building the existing checkout."
    else
        plog "Cloning $DLSS_LAYER_REPO (AGPL-3.0)…"
        git clone --depth 1 "$DLSS_LAYER_REPO" "$DLSS_LAYER_SRC" || { perr "Clone failed."; return 1; }
    fi

    # Build INSIDE a container so the host never gains build-time packages. The
    # first cut of this told the user to rpm-ostree install ~20 packages and
    # reboot; on a bootc image that is a bad trade for tools nothing needs at
    # runtime. Verified: the container-built .so resolves entirely against host
    # libraries and needs at most GLIBC_2.38 against a host 2.43.
    local img; img="$(dlss_build_image)"
    local script="$DLSS_LAYER_SRC/.powos-dlss-build.sh"
    {
        echo "set -e"
        echo "dnf -y install $(echo "$DLSS_BUILD_DEPS" | tr '\n' ' ') >/dev/null"
        echo "cd /src && tools/meson-build.sh"
    } > "$script"

    plog "Building in $img (native + 32-bit layers + the Windows NGX helper)…"
    if ! podman run --rm -v "$DLSS_LAYER_SRC":/src:Z -w /src "$img" bash /src/.powos-dlss-build.sh; then
        perr "Build failed. Deps used:"
        echo "$DLSS_BUILD_DEPS" | sed 's/^/    /'
        return 1
    fi

    # install.sh wants a STAGED package tree (it checks for root/usr), not the
    # raw build dir — so stage a tarball first. Building in-container too, since
    # make-dist needs the same toolchain.
    plog "Staging a distributable package…"
    {
        echo "set -e"
        echo "dnf -y install tar gzip >/dev/null"
        echo "cd /src && ./packaging/make-dist.sh tar"
    } > "$script"
    podman run --rm -v "$DLSS_LAYER_SRC":/src:Z -w /src "$img" bash /src/.powos-dlss-build.sh >/dev/null \
        || { perr "make-dist failed."; return 1; }

    local staged
    staged="$(find "$DLSS_LAYER_SRC/dist" -maxdepth 1 -type d -name 'dlssnr-[0-9]*-linux-*' 2>/dev/null | sort -V | tail -1)"
    [[ -n "$staged" ]] || { perr "No staged package under $DLSS_LAYER_SRC/dist."; return 1; }

    # Per-user install: no root, no /usr write, so no sysext unmerge dance.
    plog "Installing per-user from $(basename "$staged") (no root; /usr untouched)…"
    ( cd "$staged" && ./install.sh --user ) || { perr "install.sh --user failed."; return 1; }

    local conflict; conflict="$(dlss_layer_conflicts)"
    [[ -n "$conflict" ]] && {
        pwarn "A system-wide manifest also exists in: $conflict"
        pwarn "The Vulkan loader reads whichever it finds first — remove one."
    }

    pok "Layer installed."
    plog "Next: powos dlss doctor   (measures whether THIS driver actually evaluates)"
}

# ── per-game NR, without touching game files ─────────────────────────────
#
# The rule that shapes all of this: NOTHING is written into steamapps/common.
# OptiScaler is a DLL proxy, so it has to be somewhere the game's loader looks —
# but the prefix's system32 is such a place, and a prefix is Steam-generated
# compatdata, not game data. Steam's "verify integrity" only checks
# steamapps/common, and a game update never rewrites a prefix.
#
# It masquerades as winmm.dll rather than dxgi.dll because DXVK already owns
# dxgi in the prefix; displacing that would take DXVK out of the pipeline.
# winmm is a wine stub OptiScaler chain-loads.
#
# The override is set once per Proton via user_settings.py, which Proton imports
# and applies to EVERY game it runs — so there are no per-game launch options.
# "n,b" is native-then-builtin, so it is inert in any prefix where no native
# winmm.dll was placed: other games on the same Proton are unaffected.

DLSS_OPTI_DIR="${DLSS_OPTI_DIR:-$DLSS_CACHE_DIR/optiscaler}"

dlss_steam_root() {
    local s
    for s in "${XDG_DATA_HOME:-$HOME/.local/share}/Steam" "$HOME/.steam/steam" "$HOME/.steam/root"; do
        [[ -d "$s/steamapps" ]] && { echo "$s"; return 0; }
    done
    return 1
}

# Qualifying games, as "<appid>|<name>". A game qualifies when it ships an
# upscaler runtime: OptiScaler hooks that call, so without one there is nothing
# to hook. Read from appmanifests so the appid comes with it.
dlss_games_scan() {
    local root lib manifest appid installdir gdir
    root="$(dlss_steam_root)" || return 0
    lib="$root/steamapps"
    {
        for manifest in "$lib"/appmanifest_*.acf; do
            [[ -f "$manifest" ]] || continue
            appid="$(basename "$manifest" | tr -dc '0-9')"
            installdir="$(grep -m1 '"installdir"' "$manifest" 2>/dev/null | cut -d'"' -f4)"
            [[ -n "$installdir" ]] || continue
            gdir="$lib/common/$installdir"
            [[ -d "$gdir" ]] || continue
            # Proton/runtime entries are not games.
            [[ "$installdir" == Proton* || "$installdir" == SteamLinuxRuntime* ]] && continue
            if find "$gdir" -maxdepth 4 \( -iname 'nvngx_dlss.dll' -o -iname 'libxess.dll' \
                 -o -iname 'amd_fidelityfx*dx12.dll' -o -iname 'ffx_fsr2*dx12*.dll' \) \
                 2>/dev/null | grep -q .; then
                echo "$appid|$installdir"
            fi
        done
    }
}

dlss_prefix_sys32() {
    local root; root="$(dlss_steam_root)" || return 1
    echo "$root/steamapps/compatdata/${1:?}/pfx/drive_c/windows/system32"
}

# Which Proton a prefix was built with. Read from a builtin DLL's symlink target
# rather than parsing config.vdf: the link is what the prefix actually uses, and
# it is right even when CompatToolMapping is empty (Steam's default picks one).
dlss_proton_of_prefix() {
    local sys32="$1" tgt
    for f in version.dll winhttp.dll wininet.dll; do
        tgt="$(readlink "$sys32/$f" 2>/dev/null)" && [[ -n "$tgt" ]] && {
            echo "${tgt%%/files/*}"; return 0
        }
    done
    return 1
}

# Proton applies this to every game it runs: no per-game launch options.
dlss_write_user_settings() {
    local proton="$1" f="$1/user_settings.py"
    [[ -d "$proton" ]] || return 1
    if [[ -f "$f" ]] && ! grep -q 'powos dlss' "$f" 2>/dev/null; then
        pwarn "  $proton/user_settings.py exists and is not ours — leaving it alone"
        pwarn "  add manually:  \"WINEDLLOVERRIDES\": \"winmm=n,b\""
        return 0
    fi
    cat > "$f" <<'PYEOF_INNER'
# Written by powos dlss. Proton imports this and applies it to EVERY game it
# runs, which is why no per-game launch options are needed.
#
# winmm rather than dxgi: DXVK owns dxgi.dll in the prefix and overriding it
# would displace DXVK itself. "n,b" is native-then-builtin, so this is inert in
# any prefix where no native winmm.dll was placed.
user_settings = {
    "WINEDLLOVERRIDES": "winmm=n,b",
}
PYEOF_INNER
    plog "  override set on $(basename "$proton")"
}

dlss_on_one() {
    local appid="$1" name="$2" sys32 runtime proton
    sys32="$(dlss_prefix_sys32 "$appid")" || return 1
    runtime="$(dlss_nr_runtime_path)"
    [[ -f "$runtime" ]] || { perr "No NR runtime — powos dlss runtime import <path>"; return 1; }
    [[ -d "$DLSS_OPTI_DIR" ]] || { perr "No OptiScaler payload at $DLSS_OPTI_DIR"; return 1; }

    if [[ ! -d "$sys32" ]]; then
        pwarn "$name: no prefix yet — run the game once, then re-run this"
        return 1
    fi
    plog "$name"

    # winmm.dll in a prefix is a SYMLINK into Proton's read-only install, so it
    # must be replaced, not written through. Keep the target to restore on `off`.
    if [[ -L "$sys32/winmm.dll" ]]; then
        readlink "$sys32/winmm.dll" > "$sys32/.powos-winmm-orig"
    elif [[ ! -f "$sys32/.powos-winmm-orig" ]]; then
        # Not a symlink (a previous run replaced it, or Proton copied it), so
        # derive the builtin's path from a sibling that IS still a link.
        local sib l
        for sib in version.dll winhttp.dll wininet.dll dbghelp.dll; do
            l="$(readlink "$sys32/$sib" 2>/dev/null)" || continue
            [[ -n "$l" ]] && { echo "${l%/*}/winmm.dll" > "$sys32/.powos-winmm-orig"; break; }
        done
    fi
    rm -f "$sys32/winmm.dll"
    cp -a "$DLSS_OPTI_DIR/OptiScaler.dll"       "$sys32/winmm.dll"
    cp -a "$DLSS_OPTI_DIR/nvngx.dll_dlssnr.dll" "$sys32/"
    cp -a "$DLSS_OPTI_DIR/OptiScaler.ini"       "$sys32/"
    cp -a "$DLSS_OPTI_DIR/OptiScaler"           "$sys32/" 2>/dev/null

    # Hard-link the 166 MB model: one inode however many games use it.
    rm -f "$sys32/nvngx_dlssnr.dll"
    ln "$runtime" "$sys32/nvngx_dlssnr.dll" 2>/dev/null \
        || cp -a "$runtime" "$sys32/nvngx_dlssnr.dll"

    sed -i '/^\[DlssNr\]/,/^\[/{s/^Enabled=auto/Enabled=true/}' "$sys32/OptiScaler.ini"

    proton="$(dlss_proton_of_prefix "$sys32")" && dlss_write_user_settings "$proton"
    pok "  on"
}

dlss_off_one() {
    local appid="$1" name="$2" sys32 orig
    sys32="$(dlss_prefix_sys32 "$appid")" || return 1
    [[ -f "$sys32/nvngx_dlssnr.dll" || -f "$sys32/.powos-winmm-orig" ]] || return 1
    rm -f "$sys32/nvngx_dlssnr.dll" "$sys32/nvngx.dll_dlssnr.dll" "$sys32/OptiScaler.ini"
    rm -rf "$sys32/OptiScaler"
    rm -f "$sys32/winmm.dll"
    # Put wine's builtin back. Leaving winmm.dll ABSENT is worse than leaving
    # ours in place: any game that actually calls into winmm then fails to start.
    # Three sources, in order of trust, because `on` cannot always capture the
    # symlink (if winmm.dll was already a regular file, there was none to read).
    orig="$(cat "$sys32/.powos-winmm-orig" 2>/dev/null)"
    if [[ -z "$orig" ]]; then
        # A sibling builtin's target names the exact Proton this prefix uses.
        local sib l
        for sib in version.dll winhttp.dll wininet.dll dbghelp.dll; do
            l="$(readlink "$sys32/$sib" 2>/dev/null)" || continue
            [[ -n "$l" ]] && { orig="${l%/*}/winmm.dll"; break; }
        done
    fi
    if [[ -n "$orig" && -e "$orig" ]]; then
        ln -s "$orig" "$sys32/winmm.dll"
    else
        pwarn "  could not restore winmm.dll — Proton recreates it on next launch"
    fi
    rm -f "$sys32/.powos-winmm-orig"
    pok "off: $name"
}

cmd_dlss_on() {
    local target="${1:---all}" appid name n=0
    if [[ "$target" == "--all" ]]; then
        while IFS='|' read -r appid name; do
            [[ -n "$appid" ]] || continue
            dlss_on_one "$appid" "$name" && n=$((n+1))
        done < <(dlss_games_scan)
        pok "Neural Rendering on for $n game(s)."
    else
        while IFS='|' read -r appid name; do
            [[ "${name,,}" == *"${target,,}"* ]] && { dlss_on_one "$appid" "$name"; return $?; }
        done < <(dlss_games_scan)
        perr "No upscaler game matches '$target' (powos dlss games)"; return 1
    fi
    echo
    plog "No launch options needed — the override is set on the Proton itself."
    plog "Games never launched have no prefix yet; run them once, then 'powos dlss on'."
}

cmd_dlss_off() {
    local target="${1:---all}" appid name proton root
    if [[ "$target" == "--all" ]]; then
        while IFS='|' read -r appid name; do
            [[ -n "$appid" ]] || continue
            dlss_off_one "$appid" "$name" || true
        done < <(dlss_games_scan)
        # Drop our overrides too, but never someone else's file.
        root="$(dlss_steam_root)" || return 0
        for proton in "$root/steamapps/common"/Proton*/ "$HOME/.steam/root/compatibilitytools.d"/*/; do
            [[ -f "$proton/user_settings.py" ]] || continue
            grep -q 'powos dlss' "$proton/user_settings.py" 2>/dev/null && {
                rm -f "$proton/user_settings.py"; plog "override removed from $(basename "${proton%/}")"; }
        done
        pok "Neural Rendering off."
    else
        while IFS='|' read -r appid name; do
            [[ "${name,,}" == *"${target,,}"* ]] && { dlss_off_one "$appid" "$name"; return 0; }
        done < <(dlss_games_scan)
        perr "No match for '$target'"; return 1
    fi
}

cmd_dlss_games() {
    echo -e "${BOLD}Games that can take Neural Rendering${NC}"
    echo    "════════════════════════════════════════"
    local appid name sys32 n=0 on=0
    while IFS='|' read -r appid name; do
        [[ -n "$appid" ]] || continue
        n=$((n+1)); sys32="$(dlss_prefix_sys32 "$appid")"
        if [[ -f "$sys32/nvngx_dlssnr.dll" ]]; then
            printf "  ${GREEN}●${NC} %-38s ${DIM}on${NC}\n" "$name"; on=$((on+1))
        elif [[ -d "$sys32" ]]; then
            printf "  ${DIM}○${NC} %-38s ${DIM}off${NC}\n" "$name"
        else
            printf "  ${DIM}○${NC} %-38s ${DIM}never launched (no prefix)${NC}\n" "$name"
        fi
    done < <(dlss_games_scan)
    echo
    echo -e "  ${DIM}$n game(s) qualify, $on on. Nothing is written to steamapps/common.${NC}"
    echo -e "  ${BOLD}powos dlss on${NC} [game|--all]   ${BOLD}powos dlss off${NC} [game|--all]"
    echo
}


# ── doctor: measure, never assume ────────────────────────────────────────

cmd_dlss_doctor() {
    echo -e "${BOLD}DLSS doctor${NC}"
    echo    "════════════════════════════════════════"
    local fails=0

    dlss_driver_ok      || { perr "No working NVIDIA driver."; fails=$((fails+1)); }
    dlss_native_ngx_ok  || { perr "libnvidia-ngx.so not discoverable by the loader."; fails=$((fails+1)); }
    dlss_nvidia_wine_dir >/dev/null || { perr "No _nvngx.dll (driver wine NGX bridge)."; fails=$((fails+1)); }
    dlss_nr_runtime_present || { perr "No nvngx_dlssnr.dll — neural processing cannot run."; fails=$((fails+1)); }
    dlss_layer_installed || { perr "Vulkan layer not installed (powos dlss nr install)."; fails=$((fails+1)); }

    local proton; proton="$(dlss_proton_dir || true)"
    [[ -n "$proton" ]] || { perr "No DXVK-NVAPI-bearing Proton (GE-Proton / proton-cachyos)."; fails=$((fails+1)); }

    local conflict; conflict="$(dlss_layer_conflicts)"
    [[ -n "$conflict" ]] && pwarn "Duplicate layer manifest in $conflict — loader order is undefined."

    if [[ $fails -gt 0 ]]; then
        echo
        perr "$fails blocking problem(s) — not running the smoke test."
        return 1
    fi

    # The helper's own diagnostics, then the real gate: does an evaluate succeed
    # on THIS driver? The Windows data shows the same consumer scoring 0/300 and
    # 300/300 on adjacent drivers, so this number is the only honest answer.
    if command -v dlssnr-helper >/dev/null 2>&1; then
        plog "dlssnr-helper doctor:"
        dlssnr-helper doctor 2>&1 | sed 's/^/    /'
        plog "Starting helper…"
        dlssnr-helper start 2>&1 | sed 's/^/    /' || pwarn "helper start reported non-zero."
        plog "Helper status:"
        dlssnr-helper status 2>&1 | sed 's/^/    /'
    else
        pwarn "dlssnr-helper not on PATH — add ~/.local/bin to PATH (install.sh --user)."
        fails=$((fails+1))
    fi

    echo
    if [[ $fails -eq 0 ]]; then
        pok "Plumbing is complete."
        plog "Now measure a real evaluate — the layer ships a smoke test:"
        echo "    powos dlss nr smoke"
        plog "Anything short of an all-pass evaluate count is a FAILURE, not a warning."
    else
        pwarn "$fails problem(s) above."
    fi
    [[ $fails -eq 0 ]]
}

# Drive the layer's own smoke.exe under Proton and report the evaluate count.
cmd_dlss_nr_smoke() {
    local smoke="$DLSS_LAYER_SRC/build/windows/windows/smoke.exe"
    local helper="$DLSS_LAYER_SRC/build/windows/windows/dlssnr_helper.exe"
    [[ -f "$smoke" ]] || { perr "No smoke.exe — run 'powos dlss nr install' first."; return 1; }

    local proton; proton="$(dlss_proton_dir)" || { perr "No suitable Proton."; return 1; }
    local prefix="${XDG_DATA_HOME:-$HOME/.local/share}/dlssnr/prefix"
    mkdir -p "$prefix"

    plog "Running the NR smoke test under $(basename "$proton")…"
    # PROTON_ENABLE_NVAPI is required for the NGX path; VKLayer_DLSS5 arms the
    # layer (it stays inert otherwise, which is the safe default).
    DLSSNR_HELPER_EXE="$helper" \
    DLSSNR_VERBOSE=1 \
    WINEPREFIX="$prefix/pfx" \
    PROTON_ENABLE_NVAPI=1 \
    STEAM_COMPAT_DATA_PATH="$prefix" \
    STEAM_COMPAT_CLIENT_INSTALL_PATH="${STEAM_COMPAT_CLIENT_INSTALL_PATH:-$HOME/.steam/steam}" \
    VKLayer_DLSS5=1 \
    DLSSNR_SMOKE_FRAMES="${DLSSNR_SMOKE_FRAMES:-5}" \
        "$proton/proton" run "$smoke" 2>&1 | sed 's/^/    /'

    echo
    plog "Helper log: ${XDG_STATE_HOME:-$HOME/.local/state}/dlssnr/helper.log"
}

# ── enable / disable ─────────────────────────────────────────────────────

cmd_dlss_nr_enable() {
    dlss_layer_installed || { perr "Layer not installed — powos dlss nr install"; return 1; }
    local appid="${1:-}"

    if [[ -z "$appid" ]]; then
        # Session-wide: environment.d applies at next login and reaches native
        # games as well as Steam ones.
        local conf="${XDG_CONFIG_HOME:-$HOME/.config}/environment.d/powos-dlssnr.conf"
        mkdir -p "$(dirname "$conf")"
        {
            echo "# Written by powos dlss nr enable."
            echo "VKLayer_DLSS5=1"
            # Pins layer order so NR composes correctly alongside Smooth Motion.
            echo 'VK_INSTANCE_LAYERS=VK_LAYER_NV_dlssnr:VK_LAYER_NV_present'
        } > "$conf"
        pok "Armed session-wide: $conf"
        pwarn "Takes effect at your NEXT LOGIN (environment.d is read at session start)."
        plog  "For one game right now, without logging out: powos dlss nr enable <appid>"
        return 0
    fi

    # Per-game: reuse the existing game shim's env sentinel. bin/powos-game-shim
    # sources this before exec'ing the game, so we never touch LaunchOptions.
    if [[ ! -d "$DLSS_SHIM_ENV_DIR" ]]; then
        sudo mkdir -p "$DLSS_SHIM_ENV_DIR" || { perr "Cannot create $DLSS_SHIM_ENV_DIR"; return 1; }
        sudo chown "$(id -u):$(id -g)" "$DLSS_SHIM_ENV_DIR" 2>/dev/null || true
    fi
    local env_file="$DLSS_SHIM_ENV_DIR/${appid}.env"
    {
        echo "export VKLayer_DLSS5=1"
        echo "export VK_INSTANCE_LAYERS=VK_LAYER_NV_dlssnr:VK_LAYER_NV_present"
    } > "$env_file" || { perr "Cannot write $env_file"; return 1; }
    pok "Armed for appid $appid: $env_file"
    plog "The game must launch through powos-game-shim (powos mods verify setup wires it)."
}

cmd_dlss_nr_disable() {
    local appid="${1:-}"
    if [[ -n "$appid" ]]; then
        rm -f "$DLSS_SHIM_ENV_DIR/${appid}.env" && pok "Disarmed appid $appid."
        return 0
    fi
    rm -f "${XDG_CONFIG_HOME:-$HOME/.config}/environment.d/powos-dlssnr.conf"
    pok "Disarmed session-wide (effective next login)."
    command -v dlssnr-helper >/dev/null 2>&1 && dlssnr-helper stop >/dev/null 2>&1
    plog "The layer is inert without VKLayer_DLSS5=1, so games present normally again."
}

# ── DLSS 4 presets (official, no blockers) ───────────────────────────────

# Transformer presets. J/K are the DLSS 4 transformer models; L/M are DLSS 4.5.
dlss_preset_code() {
    case "${1,,}" in
        j) echo "0xA" ;;   # DLSS 4 transformer
        k) echo "0xB" ;;   # DLSS 4 transformer, latest
        l) echo "0xC" ;;   # DLSS 4.5
        m) echo "0xD" ;;   # DLSS 4.5, latest
        *) return 1 ;;
    esac
}

cmd_dlss4_preset() {
    local want="${1:-}"
    local code
    code="$(dlss_preset_code "$want")" || {
        perr "Usage: powos dlss4 preset <j|k|l|m>"
        perr "  j,k = DLSS 4 transformer   l,m = DLSS 4.5"
        return 1
    }
    echo -e "${BOLD}DLSS 4 preset ${want^^}${NC}"
    echo
    echo "Add to a game's Steam launch options:"
    echo
    echo "    DXVK_NVAPI_DRS_ngx_dlss_sr_override_render_preset_selection=$code \\"
    echo "    DXVK_NVAPI_SET_NGX_DEBUG_OPTIONS=DLSSIndicator=1024,DLSSGIndicator=2 %command%"
    echo
    plog "DLSSIndicator draws an on-screen overlay naming the preset that ACTUALLY loaded"
    plog "— use it to verify rather than assuming the override took."
    plog "This changes the upscaler model only. It does not add frame generation."
}

# ── dispatch ─────────────────────────────────────────────────────────────

cmd_dlss_nr() {
    local sub="${1:-}"; shift || true
    case "$sub" in
        install)          cmd_dlss_nr_install "$@" ;;
        enable|on)        cmd_dlss_nr_enable "$@" ;;
        disable|off)      cmd_dlss_nr_disable "$@" ;;
        smoke|test)       cmd_dlss_nr_smoke "$@" ;;
        *) perr "Unknown: powos dlss nr $sub"; perr "Try: install | enable | disable | smoke"; return 1 ;;
    esac
}

cmd_dlss_runtime() {
    local sub="${1:-list}"; shift || true
    case "$sub" in
        import|add)   cmd_dlss_runtime_import "$@" ;;
        list|ls)      cmd_dlss_runtime_list "$@" ;;
        *) perr "Unknown: powos dlss runtime $sub"; perr "Try: import | list"; return 1 ;;
    esac
}

cmd_dlss4() {
    local sub="${1:-}"; shift || true
    case "$sub" in
        preset)  cmd_dlss4_preset "$@" ;;
        *) perr "Unknown: powos dlss4 $sub"; perr "Try: preset <j|k|l|m>"; return 1 ;;
    esac
}

cmd_dlss_usage() {
    cat <<EOF
${BOLD}powos dlss${NC} — NVIDIA DLSS on Linux

  powos dlss status                Capability report: what works, what is blocked
  powos dlss doctor                Check the pipeline and say where it breaks
  powos dlss runtime import <path> Verify + install NVIDIA's nvngx_dlssnr.dll
  powos dlss runtime list          Installed runtimes with hashes
  powos dlss nr install            Build + install the NR Vulkan layer (per-user)
  powos dlss nr smoke              Run the layer's smoke test; report evaluates
  powos dlss nr enable [<appid>]   Arm NR session-wide, or for one Steam appid
  powos dlss nr disable [<appid>]  Disarm
  powos dlss4 preset <j|k|l|m>     DLSS 4 transformer preset launch options

One Vulkan layer covers DX9-DX12 and native Vulkan, because DXVK and
VKD3D-Proton already make every DirectX game Vulkan before it presents.

${BOLD}Honesty:${NC} Neural Rendering costs ~50-60% fps and is experimental — Xid
faults and black screens are reported on Blackwell/Linux. Super Resolution and
Frame Generation cannot be made universal: they need engine motion vectors and
depth, so they stay per-game. PowOS ships no NVIDIA binaries; you supply the
runtime from hardware you own.
EOF
}

cmd_dlss() {
    local sub="${1:-status}"; shift || true
    case "$sub" in
        status|info)      cmd_dlss_status "$@" ;;
        on|enable)        cmd_dlss_on "$@" ;;
        off|disable)      cmd_dlss_off "$@" ;;
        games|list)       cmd_dlss_games "$@" ;;
        doctor|check)     cmd_dlss_doctor "$@" ;;
        runtime|runtimes) cmd_dlss_runtime "$@" ;;
        nr|neural)        cmd_dlss_nr "$@" ;;
        dlss4|4)          cmd_dlss4 "$@" ;;
        help|-h|--help)   cmd_dlss_usage ;;
        *) perr "Unknown: dlss $sub"; cmd_dlss_usage; return 1 ;;
    esac
}
