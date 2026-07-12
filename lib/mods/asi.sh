#!/bin/bash
# mods/asi.sh - PowOS ASI-plugin manager for RAGE-engine games (GTA V, RDR2).
#
# RAGE games (GTA V Enhanced/Legacy, RDR2) are NOT manager-driven like
# Bethesda/RedEngine titles: there is no Vortex/NMA layer that deploys the
# loader stack on Linux. The de-facto "mod loader" is an ASI loader (Ultimate
# ASI Loader = version.dll/dinput8.dll) that lives in the game's install dir
# and loads *.asi plugins next to it. This subsystem manages that layer:
#
#   fetch  →  arch-verify (reject wrong-bitness DLLs)  →  place in game dir
#          →  record in a manifest  →  detect stale/failed plugins from logs
#
# so the whole thing is a repeatable `powos mods asi …` command instead of a
# pile of hand-copied files. Story-mode only for anti-cheat titles.
#
# Sourced AFTER mods/install.sh, so it reuses: plog/pok/pwarn/perr,
# mods_appid_of, mods_nexus_slug_of, mods_api_get, mods_nexus_key.

# ── paths ────────────────────────────────────────────────────────────────
ASI_STATE_DIR="${ASI_STATE_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/powos/asi}"
ASI_CACHE_DIR="${ASI_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/powos/asi}"

asi_manifest_path() { echo "$ASI_STATE_DIR/$1.json"; }   # $1 = appid

# ── resolve a game's Steam install directory from its appid ──────────────
# Parses libraryfolders.vdf across all Steam libraries, then the appmanifest.
asi_game_dir() {
    local appid="$1"
    python3 - "$appid" "$HOME/.local/share/Steam" "$HOME/.steam/steam" "$HOME/.steam/root" <<'PY'
import sys, os, re
appid = sys.argv[1]
roots = [r for r in sys.argv[2:] if r]
libs = []
for root in roots:
    lf = os.path.join(root, "steamapps", "libraryfolders.vdf")
    if os.path.exists(lf):
        txt = open(lf, encoding="utf-8", errors="ignore").read()
        libs += re.findall(r'"path"\s*"([^"]+)"', txt)
    libs.append(root)
seen = set()
for lib in libs:
    lib = lib.replace("\\\\", "/")
    if lib in seen:
        continue
    seen.add(lib)
    acf = os.path.join(lib, "steamapps", "appmanifest_%s.acf" % appid)
    if os.path.exists(acf):
        t = open(acf, encoding="utf-8", errors="ignore").read()
        m = re.search(r'"installdir"\s*"([^"]+)"', t)
        if m:
            p = os.path.join(lib, "steamapps", "common", m.group(1))
            if os.path.isdir(p):
                print(p)
                sys.exit(0)
sys.exit(1)
PY
}

# ── read a PE file's machine architecture: x64 / x86 / arm64 / other ─────
asi_pe_arch() {
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
except Exception as ex:
    print("error")
PY
}

# Assert a file is a 64-bit PE; error out otherwise. $1=file $2=human label
asi_require_x64() {
    local f="$1" label="${2:-file}" arch
    arch="$(asi_pe_arch "$f")"
    case "$arch" in
        x64) return 0 ;;
        x86) perr "  $label is 32-bit (i386) — RAGE games are 64-bit; refusing to install." ; return 1 ;;
        notpe) perr "  $label is not a Windows PE binary." ; return 1 ;;
        *) perr "  $label has unexpected arch ($arch); refusing." ; return 1 ;;
    esac
}

# ── manifest helpers (jq-free; python for read/modify/write) ─────────────
asi_manifest_upsert() {   # appid name file source arch role
    local appid="$1" name="$2" file="$3" src="$4" arch="$5" role="$6"
    local mf; mf="$(asi_manifest_path "$appid")"
    mkdir -p "$(dirname "$mf")"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    python3 - "$mf" "$appid" "$name" "$file" "$src" "$arch" "$role" "$ts" <<'PY'
import sys, json, os
mf, appid, name, file, src, arch, role, ts = sys.argv[1:9]
data = {"appid": appid, "entries": []}
if os.path.exists(mf):
    try: data = json.load(open(mf))
    except Exception: pass
entries = [e for e in data.get("entries", []) if e.get("file") != file]
entries.append({"name": name, "file": file, "source": src,
                "arch": arch, "role": role, "installed": ts})
data["appid"] = appid
data["entries"] = entries
json.dump(data, open(mf, "w"), indent=2)
PY
}

asi_manifest_remove() {   # appid file
    local mf; mf="$(asi_manifest_path "$1")"
    [[ -f "$mf" ]] || return 0
    python3 - "$mf" "$2" <<'PY'
import sys, json, os
mf, file = sys.argv[1], sys.argv[2]
try: data = json.load(open(mf))
except Exception: sys.exit(0)
data["entries"] = [e for e in data.get("entries", []) if e.get("file") != file]
json.dump(data, open(mf, "w"), indent=2)
PY
}

# ── download helpers ─────────────────────────────────────────────────────
# GitHub: fetch latest release, echo the best asset URL (prefer x64 zip).
asi_github_asset_url() {
    local repo="$1"
    curl -sSL "https://api.github.com/repos/$repo/releases/latest" \
        | python3 -c '
import json, sys
try: d = json.load(sys.stdin)
except Exception: sys.exit(1)
assets = d.get("assets", []) or []
def score(a):
    n = a.get("name", "").lower()
    s = 0
    if n.endswith(".zip"): s += 2
    if n.endswith(".asi") or n.endswith(".dll"): s += 2
    if "x64" in n or "64" in n: s += 1
    return s
assets = [a for a in assets if a.get("browser_download_url")]
if not assets: sys.exit(1)
best = sorted(assets, key=score, reverse=True)[0]
print(best["browser_download_url"])
'
}

# Nexus: resolve a mod-id to its primary MAIN file download URL (Premium).
# $1=game $2=mod-id  → echoes an https CDN URL (spaces %20-encoded).
asi_nexus_file_url() {
    local game="$1" mod_id="$2" slug files file_id link
    slug="$(mods_nexus_slug_of "$game")"
    files="$(mods_api_get "/games/$slug/mods/$mod_id/files.json")" || return 1
    file_id="$(printf '%s' "$files" | python3 -c '
import json, sys
d = json.load(sys.stdin); fs = d.get("files", []) or []
mains = [f for f in fs if f.get("category_id") == 1]
pick = next((f for f in mains if f.get("is_primary")), None)
if not pick and mains: pick = sorted(mains, key=lambda x: x.get("uploaded_timestamp",0), reverse=True)[0]
if not pick and fs: pick = sorted(fs, key=lambda x: x.get("uploaded_timestamp",0), reverse=True)[0]
print(pick["file_id"] if pick else "")
')"
    [[ -z "$file_id" ]] && { perr "  no downloadable file for mod $mod_id."; return 1; }
    link="$(mods_api_get "/games/$slug/mods/$mod_id/files/$file_id/download_link.json")" || return 1
    printf '%s' "$link" | python3 -c '
import json, sys, urllib.parse
d = json.load(sys.stdin)
if not d: sys.exit(1)
uri = d[0]["URI"]
# encode spaces (and other unsafe chars) in the path, keep the query intact
parts = urllib.parse.urlsplit(uri)
path = urllib.parse.quote(parts.path)
print(urllib.parse.urlunsplit((parts.scheme, parts.netloc, path, parts.query, "")))
'
}

# Extract an archive (zip; rar via bsdtar if available) into $2.
asi_extract() {
    local archive="$1" dest="$2"
    mkdir -p "$dest"
    case "$archive" in
        *.zip) unzip -oq "$archive" -d "$dest" ;;
        *.rar|*.7z) if command -v bsdtar >/dev/null 2>&1; then bsdtar -xf "$archive" -C "$dest"
                    else perr "  need bsdtar/unar to extract $(basename "$archive")."; return 1; fi ;;
        *.asi|*.dll) cp "$archive" "$dest/" ;;
        *) if command -v bsdtar >/dev/null 2>&1; then bsdtar -xf "$archive" -C "$dest"; else return 1; fi ;;
    esac
}

# ── install / update the ASI loader (Ultimate ASI Loader, ThirteenAG) ────
# powos mods asi install-loader <game> [proxy]   proxy = version|dinput8 (default version)
asi_install_loader() {
    local game="${1:?Usage: powos mods asi install-loader <game> [version|dinput8]}"
    local proxy="${2:-version}"
    local appid gamedir
    appid="$(mods_appid_of "$game")" || { perr "Unknown game: $game"; return 1; }
    gamedir="$(asi_game_dir "$appid")" || { perr "Can't find install dir for appid $appid (is it installed?)."; return 1; }
    plog "Game dir: ${BOLD}$gamedir${NC}"

    local tmp; tmp="$(mktemp -d "$ASI_CACHE_DIR.XXXXXX" 2>/dev/null || mktemp -d)"
    mkdir -p "$ASI_CACHE_DIR"
    plog "Fetching Ultimate ASI Loader (ThirteenAG, x64)…"
    local url; url="$(asi_github_asset_url "ThirteenAG/Ultimate-ASI-Loader" | grep -i 'x64' | head -1)"
    [[ -z "$url" ]] && url="https://github.com/ThirteenAG/Ultimate-ASI-Loader/releases/latest/download/Ultimate-ASI-Loader_x64.zip"
    curl -sSL -o "$tmp/ual.zip" "$url" || { perr "download failed."; rm -rf "$tmp"; return 1; }
    asi_extract "$tmp/ual.zip" "$tmp/ual" || { rm -rf "$tmp"; return 1; }
    local dll; dll="$(find "$tmp/ual" -maxdepth 2 -iname '*.dll' | head -1)"
    [[ -z "$dll" ]] && { perr "no DLL in loader archive."; rm -rf "$tmp"; return 1; }
    asi_require_x64 "$dll" "ASI loader" || { rm -rf "$tmp"; return 1; }

    local target="$gamedir/$proxy.dll"
    if [[ -e "$target" ]]; then cp -f "$target" "$target.powos-bak" 2>/dev/null; fi
    cp -f "$dll" "$target" || { perr "couldn't write $target"; rm -rf "$tmp"; return 1; }
    asi_manifest_upsert "$appid" "Ultimate ASI Loader" "$proxy.dll" "github:ThirteenAG/Ultimate-ASI-Loader" "x64" "loader"
    rm -rf "$tmp"
    pok "Loader installed → ${BOLD}$proxy.dll${NC} (x64, verified)."
    pwarn "Activate via launch options: ${BOLD}WINEDLLOVERRIDES=\"$proxy=n,b\" %command%${NC}"
    pwarn "(or: powos mods setup $game — sets the full override, Steam must be closed)"
}

# ── add an ASI plugin ────────────────────────────────────────────────────
# powos mods asi add <game> <ref>
#   ref = github:owner/repo | owner/repo | nexus:<mod-id> | <mod-id> | https://…zip|.asi
asi_add() {
    local game="${1:?Usage: powos mods asi add <game> <ref>}"
    local ref="${2:?Usage: powos mods asi add <game> <ref>}"
    local appid gamedir
    appid="$(mods_appid_of "$game")" || { perr "Unknown game: $game"; return 1; }
    gamedir="$(asi_game_dir "$appid")" || { perr "Can't find install dir for appid $appid."; return 1; }

    local tmp; tmp="$(mktemp -d)"; local src url
    case "$ref" in
        github:*|*/*[!0-9]*|*/*)
            local repo="${ref#github:}"
            src="github:$repo"
            plog "Resolving GitHub release for ${BOLD}$repo${NC}…"
            url="$(asi_github_asset_url "$repo")" || { perr "no release asset for $repo."; rm -rf "$tmp"; return 1; }
            ;;
        http*://*)
            src="url:$ref"; url="$ref" ;;
        nexus:*|[0-9]*)
            local mid="${ref#nexus:}"
            src="nexus:$(mods_nexus_slug_of "$game")/$mid"
            plog "Resolving Nexus mod ${BOLD}$mid${NC}…"
            url="$(asi_nexus_file_url "$game" "$mid")" || { rm -rf "$tmp"; return 1; }
            ;;
        *) perr "Unrecognized ref: $ref"; rm -rf "$tmp"; return 1 ;;
    esac

    plog "Downloading…"
    local ext="zip"; case "$url" in *.asi) ext=asi ;; *.rar) ext=rar ;; *.7z) ext=7z ;; esac
    curl -sSL -o "$tmp/dl.$ext" "$url" || { perr "download failed."; rm -rf "$tmp"; return 1; }
    asi_extract "$tmp/dl.$ext" "$tmp/x" || { rm -rf "$tmp"; return 1; }

    local asi; asi="$(find "$tmp/x" -iname '*.asi' | head -1)"
    [[ -z "$asi" ]] && { perr "no .asi found in download."; rm -rf "$tmp"; return 1; }
    asi_require_x64 "$asi" "$(basename "$asi")" || { rm -rf "$tmp"; return 1; }

    # Warn if there's no loader present — the .asi won't load without one.
    if ! find "$gamedir" -maxdepth 1 -iname 'version.dll' -o -iname 'dinput8.dll' 2>/dev/null | grep -q .; then
        pwarn "No ASI loader in game dir yet — run: powos mods asi install-loader $game"
    fi

    local base; base="$(basename "$asi")"
    cp -f "$asi" "$gamedir/$base" || { perr "couldn't write $gamedir/$base"; rm -rf "$tmp"; return 1; }
    asi_manifest_upsert "$appid" "$base" "$base" "$src" "x64" "plugin"
    rm -rf "$tmp"
    pok "Installed ${BOLD}$base${NC} → game dir (x64, verified)."
    plog "Verify after launch with: ${BOLD}powos mods asi check $game${NC}"
}

# ── generic entry point ──────────────────────────────────────────────────
# `powos mods install <rage-game> [refs…]` routes here. Bootstraps the loader
# if missing, then installs each ref as a plugin. This is the "install
# whatever, figure out the backend by game" path — no Vortex, no NMA.
asi_install_generic() {
    local game="$1"; shift || true
    local appid gamedir
    appid="$(mods_appid_of "$game")" || { perr "Unknown game: $game"; return 1; }
    gamedir="$(asi_game_dir "$appid")" || { perr "Can't find install dir for appid $appid (is it installed?)."; return 1; }
    plog "RAGE game → ASI subsystem (game dir: ${BOLD}$gamedir${NC})"

    # Bootstrap a loader if none present — otherwise plugins can't load.
    if ! find "$gamedir" -maxdepth 1 \( -iname 'version.dll' -o -iname 'dinput8.dll' \) 2>/dev/null | grep -q .; then
        plog "No ASI loader present — installing one first…"
        asi_install_loader "$game" || return 1
    fi

    if [[ $# -eq 0 ]]; then
        pok "ASI loader ready for $game. Add a plugin with:"
        plog "  powos mods install $game <github:owner/repo | nexus:<id> | <mod-id> | url>"
        return 0
    fi

    local ref rc=0
    for ref in "$@"; do
        asi_add "$game" "$ref" || rc=1
    done
    return $rc
}

# ── list managed ASI files ───────────────────────────────────────────────
asi_list() {
    local game="${1:?Usage: powos mods asi list <game>}"
    local appid mf; appid="$(mods_appid_of "$game")" || { perr "Unknown game: $game"; return 1; }
    mf="$(asi_manifest_path "$appid")"
    [[ -f "$mf" ]] || { plog "No ASI files managed for $game (appid $appid) yet."; return 0; }
    echo -e "${BOLD}Managed ASI stack — $game (appid $appid)${NC}"
    python3 - "$mf" <<'PY'
import sys, json
d = json.load(open(sys.argv[1]))
for e in d.get("entries", []):
    print("  %-28s %-8s %-10s %s" % (e.get("file",""), e.get("role",""), e.get("arch",""), e.get("source","")))
PY
}

# ── remove a managed ASI file ────────────────────────────────────────────
asi_remove() {
    local game="${1:?Usage: powos mods asi remove <game> <file>}"
    local file="${2:?Usage: powos mods asi remove <game> <file>}"
    local appid gamedir; appid="$(mods_appid_of "$game")" || { perr "Unknown game: $game"; return 1; }
    gamedir="$(asi_game_dir "$appid")" || { perr "Can't find install dir."; return 1; }
    if [[ -e "$gamedir/$file" ]]; then
        mkdir -p "$ASI_CACHE_DIR/removed"
        mv -f "$gamedir/$file" "$ASI_CACHE_DIR/removed/$file.$(date -u +%s)" 2>/dev/null \
            || rm -f "$gamedir/$file"
        pok "Removed $file from game dir (backup in $ASI_CACHE_DIR/removed)."
    else
        pwarn "$file not present in game dir."
    fi
    asi_manifest_remove "$appid" "$file"
}

# ── health / staleness check ─────────────────────────────────────────────
# Reads *.log next to the plugins; an AOB "Pattern not found" / "FATAL" means
# the plugin's signatures don't match the current game build → warn clearly
# instead of leaving the user with a raw in-game "Fatal Error".
asi_check() {
    local game="${1:?Usage: powos mods asi check <game>}"
    local appid gamedir; appid="$(mods_appid_of "$game")" || { perr "Unknown game: $game"; return 1; }
    gamedir="$(asi_game_dir "$appid")" || { perr "Can't find install dir."; return 1; }
    plog "Checking ASI stack in $gamedir …"

    local loader; loader="$(find "$gamedir" -maxdepth 1 \( -iname 'version.dll' -o -iname 'dinput8.dll' \) 2>/dev/null | head -1)"
    if [[ -n "$loader" ]]; then
        local a; a="$(asi_pe_arch "$loader")"
        [[ "$a" == "x64" ]] && pok "Loader: $(basename "$loader") ($a)" || pwarn "Loader: $(basename "$loader") arch=$a — expected x64!"
    else
        pwarn "No ASI loader (version.dll/dinput8.dll) present."
    fi

    local n_asi=0 n_bad=0 f
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        n_asi=$((n_asi+1))
        local a; a="$(asi_pe_arch "$f")"
        [[ "$a" != "x64" ]] && { pwarn "  $(basename "$f"): arch=$a (not x64!)"; n_bad=$((n_bad+1)); }
    done < <(find "$gamedir" -maxdepth 1 -iname '*.asi' 2>/dev/null)

    # Scan logs for signature-scan failures (the classic stale-plugin symptom).
    local log had_fatal=0
    while IFS= read -r log; do
        [[ -z "$log" ]] && continue
        if grep -qiE 'pattern not found|fatal error|signature .* not found' "$log" 2>/dev/null; then
            had_fatal=1
            pwarn "  STALE: $(basename "$log") reports a failed signature scan:"
            grep -iE 'pattern not found|fatal error' "$log" 2>/dev/null | head -2 | sed 's/^/      /'
            pwarn "      → this plugin targets a different game build; needs an author update."
        fi
    done < <(find "$gamedir" -maxdepth 1 -iname '*.log' 2>/dev/null)

    plog "Found $n_asi .asi plugin(s); $n_bad wrong-arch; fatal-log=$had_fatal."
    [[ $n_bad -eq 0 && $had_fatal -eq 0 ]] && pok "ASI stack looks healthy." || \
        pwarn "Issues above — remove stale plugins with: powos mods asi remove $game <file>"
}

asi_help() {
    cat <<EOF
$(echo -e "${BOLD}powos mods asi${NC}") — manage the ASI-loader stack for RAGE games (GTA V, RDR2)

  install-loader <game> [version|dinput8]   Fetch + arch-verify Ultimate ASI
                                            Loader into the game dir (default
                                            proxy: version.dll).
  add <game> <ref>                          Install an .asi plugin. ref =
                                            github:owner/repo | owner/repo |
                                            nexus:<mod-id> | <mod-id> | https URL.
                                            Downloads, verifies it's 64-bit,
                                            places it, records a manifest.
  list <game>                               Show the managed ASI stack.
  remove <game> <file>                      Remove a managed .asi (backs it up).
  check <game>                              Health/staleness check — flags wrong
                                            -arch files and reads *.log for the
                                            "Pattern not found / FATAL" symptom
                                            of a plugin that no longer matches
                                            the current game build.

Notes:
  • Guardrails: 32-bit DLLs/asi's are rejected (RAGE games are 64-bit).
  • Activation is a launch arg you own: WINEDLLOVERRIDES="version=n,b" %command%
  • STORY MODE ONLY on anti-cheat titles (GTA V Enhanced ships BattlEye).
  • One loader only — don't mix version.dll and dinput8.dll.

Examples:
  powos mods asi install-loader gta
  powos mods asi add gta github:Chiheb-Bacha/StraightToStoryMode
  powos mods asi add gta 216
  powos mods asi check gta
EOF
}

asi_dispatch() {
    case "${1:-help}" in
        install-loader|loader)      shift; asi_install_loader "$@" ;;
        add|install)                shift; asi_add "$@" ;;
        list|ls)                    shift; asi_list "$@" ;;
        remove|rm|uninstall)        shift; asi_remove "$@" ;;
        check|health|verify)        shift; asi_check "$@" ;;
        help|--help|-h|"")          asi_help ;;
        *)                          perr "Unknown: powos mods asi $1"; asi_help; return 1 ;;
    esac
}
