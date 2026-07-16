# MODDING-V2: Native PowOS Mod Manager

> **Status:** DESIGN (awaiting PM approval before implementation)
>
> **Supersedes:** The wrapper-based approach in `MODDING-SPEC.md`. NMA and Vortex
> are demoted from "the system" to "legacy escape hatches" (kept for migration
> and edge cases, not wrapped as the core).

## Motivation

The current modding system (`lib/mods/`) is 4 independent backends (NMA, Vortex,
ASI, Modlist/Jackify) with no shared state, no post-install validation, and 6
silent failure modes. The user's Cyberpunk 2077 install was destroyed by
bulk-installing 30 mods with no record of what changed and no way to roll back.

This document designs a **native PowOS mod manager** that:
- Owns the mod lifecycle end-to-end (download, stage, deploy, verify, rollback)
- Uses **overlayfs** for zero-risk deployment (game files never modified)
- Talks to the **Nexus Mods API directly** (no NMA/Vortex in the loop)
- Tracks everything in a **single per-game manifest**
- Defines per-game install rules as **data, not code**

---

## 1. Architecture Overview

```
                         ┌──────────────────────┐
                         │    powos mods CLI     │
                         │  (12 unified verbs)   │
                         └──────────┬───────────┘
                                    │
                    ┌───────────────┼───────────────┐
                    │               │               │
              ┌─────▼─────┐  ┌─────▼─────┐  ┌─────▼─────┐
              │  Nexus API │  │  nxm://   │  │  Local    │
              │  (premium) │  │ (free)    │  │  .zip     │
              └─────┬──────┘  └─────┬─────┘  └─────┬────┘
                    │               │               │
                    └───────────────┼───────────────┘
                                    │
                            ┌───────▼───────┐
                            │   STAGING     │
                            │ per-mod dir   │
                            │ (extracted)   │
                            └───────┬───────┘
                                    │ install rules
                                    │ (games.d/<game>.conf)
                            ┌───────▼───────┐
                            │   DEPLOY      │
                            │  overlayfs    │
                            │  mount/merge  │
                            └───────┬───────┘
                                    │
                    ┌───────────────┼───────────────┐
                    │               │               │
              ┌─────▼─────┐  ┌─────▼─────┐  ┌─────▼─────┐
              │ Manifest   │  │ Snapshot  │  │  Verify   │
              │ (.json)    │  │ (rollback)│  │ (harness) │
              └────────────┘  └───────────┘  └───────────┘
```

### Key directories

```
~/.local/state/powos/mods/
├── manifests/
│   ├── cyberpunk2077.json       # per-game manifest (single source of truth)
│   ├── skyrimse.json
│   └── gtav.json
├── staging/
│   ├── cyberpunk2077/
│   │   ├── mod-12345/           # extracted mod files, per nexus mod id
│   │   │   ├── .powos-mod.json  # mod metadata (name, version, nexus id, files list)
│   │   │   └── bin/x64/...      # actual mod files in game-relative paths
│   │   └── mod-67890/
│   └── skyrimse/
│       └── mod-11111/
├── snapshots/
│   ├── cyberpunk2077/
│   │   └── 2026-07-16T14:30:00.json  # file manifest + SHA-256 of touched paths
│   └── skyrimse/
└── cache/
    └── downloads/               # downloaded archives (LRU-pruned)

# The overlay mount at deploy time:
/tmp/powos-mods/<game>/merged/   # the merged view Steam sees
/tmp/powos-mods/<game>/upper/    # scratch writes during gameplay
/tmp/powos-mods/<game>/work/     # overlayfs workdir
```

---

## 2. Overlayfs Deployment Model

### How it works

Instead of copying mod files into the game directory (destructive, irreversible),
we mount an overlayfs where:

- **lowerdir** (bottom, read-only) = pristine game directory
- **lowerdir** (stacked above, per-mod) = staged mod files in priority order
- **upperdir** = scratch layer for runtime writes (shader cache, saves, logs)
- **merged** = what the game process actually sees

```bash
# Example: Cyberpunk 2077 with 3 mods, priority high→low = left→right
mount -t overlay overlay \
  -o lowerdir=/staging/cyber/mod-A:/staging/cyber/mod-B:/staging/cyber/mod-C:/game/install/dir,\
     upperdir=/tmp/powos-mods/cyber/upper,\
     workdir=/tmp/powos-mods/cyber/work \
  /tmp/powos-mods/cyber/merged
```

The game launch command is then rewritten (via Steam launch options) to point at
the merged directory instead of the original.

### Overlayfs variant selection

| Environment | Method | Notes |
|---|---|---|
| PowOS (Bazzite/Fedora) | Kernel overlayfs via `unshare -rm` | Unprivileged user namespaces enabled by default on Fedora. Best performance. |
| Fallback | fuse-overlayfs | ~2x I/O overhead under Wine. Acceptable for light mod sets. |

**Detection at runtime:**
```bash
if unshare -rm mount -t overlay overlay -o lowerdir=/tmp/test1:/tmp/test2 /tmp/test3 2>/dev/null; then
    OVERLAY_METHOD="kernel"
else
    OVERLAY_METHOD="fuse"
fi
```

### Steam integration

**Launch options rewrite:** `powos mods deploy <game>` sets the Steam launch
options for the game to run through a wrapper script:

```bash
# ~/.local/share/powos/mods/launchers/<appid>.sh
#!/bin/bash
# Auto-generated by powos mods deploy — do not edit
GAME_DIR="$1"
MERGED="/tmp/powos-mods/<game>/merged"

# Mount overlay if not already mounted
if ! mountpoint -q "$MERGED"; then
    powos mods _mount <game>
fi

# Launch with merged dir
cd "$MERGED"
exec "$@"
```

Steam launch options: `~/.local/share/powos/mods/launchers/<appid>.sh %command%`

**What stays OFF the overlay:**
- `compatdata/` (Proton prefix) — stays on native btrfs, never overlaid
- `shadercache/` — stays on native btrfs
- Save files — game-specific, documented in `games.d/<game>.conf`

**Steam "Verify Integrity" interaction:** When Steam verifies game files, it
writes pristine files into the merged view. These writes land in the upperdir
(scratch layer), not the lowerdir. The pristine game and staged mods are
untouched. After verify, clear the upperdir to restore the modded state:
`powos mods deploy --refresh <game>`.

### NTFS (POWOS-GAMES partition) caveat

NTFS (ntfs3) is safe as a **read-only lowerdir** (pristine game files). Do NOT
use NTFS as an upperdir — `d_type` support is unreliable, and NTFS semantics
break overlayfs whiteout handling. The upperdir and staging dirs MUST be on a
POSIX filesystem (btrfs, ext4, xfs).

If the game is installed on POWOS-GAMES (NTFS), the overlay works fine — NTFS
is the bottom lowerdir, mod staging is on btrfs, upper is on tmpfs.

### lowerdir string length limit

The kernel `mount()` syscall has a 4096-byte buffer for mount options. With many
mods, the `lowerdir=` string can exceed this. Mitigations (in priority order):

1. **Pre-merge staging:** For games with >~30 mods, hardlink all staged mod
   files into a single merged staging dir (respecting priority order). This
   collapses N lowerdirs into 1.
2. **`fsconfig()` API:** On kernel >= 5.2, use `fsopen`/`fsconfig`/`fsmount`
   syscalls which have no 4096-byte limit. Requires a small C helper or
   Python ctypes wrapper.

---

## 3. Nexus Mods API Integration

### Authentication

```bash
# API key stored at:
~/.config/powos/nexus.key

# Setup:
powos mods setup nexus
# → Opens https://www.nexusmods.com/users/myaccount?tab=api+access
# → User pastes their Personal API Key
# → Stored in nexus.key (chmod 600)
```

### Download flow

**Premium users** (direct API download):
```
1. GET /v1/games/{slug}/mods/{id}/files → file list
2. User selects file (or auto: latest main file)
3. GET /v1/games/{slug}/mods/{id}/files/{fileId}/download_link → CDN URLs
4. curl download → staging/
```

**Free users** (browser handoff):
```
1. GET /v1/games/{slug}/mods/{id}/files → file list (API works fine)
2. Cannot call download_link without key+expires → 403
3. Open browser: https://www.nexusmods.com/{slug}/mods/{id}?tab=files
4. User clicks "Download with Manager" → browser fires nxm:// URL
5. powos mods (registered as nxm:// handler) receives callback with key+expires
6. GET download_link with key+expires → CDN URLs → download
```

The `nxm://` protocol handler is registered via `.desktop` file:
```ini
# ~/.local/share/applications/powos-mods.desktop
[Desktop Entry]
Type=Application
Name=PowOS Mods
Exec=powos mods _nxm_callback %u
MimeType=x-scheme-handler/nxm;
NoDisplay=true
```

### Rate limits

| Tier | Daily | Hourly (after daily exhausted) |
|---|---|---|
| Free | 20,000 | 500 |
| Premium | 20,000 | 500 |

Response headers `X-RL-Daily-Remaining` and `X-RL-Hourly-Remaining` are tracked.
The CLI warns at <100 remaining and refuses requests at 0.

### API helper

```bash
# Reuse from existing install.sh but extract into lib/mods/nexus-api.sh:
nexus_api_get()   # GET with key, rate-limit tracking, retry on 429
nexus_api_files() # List files for a mod
nexus_api_download_link() # Get CDN URL (premium) or open browser (free)
nexus_mod_info()  # Mod metadata (name, version, deps, description)
```

---

## 4. Per-Game Install Rules as Data

### `games.d/<game>.conf`

Instead of game-specific logic scattered across `install.sh`, `vortex.sh`, and
`asi.sh`, each game's mod install rules are declared in a config file:

```bash
# config/mods/games.d/cyberpunk2077.conf
GAME_NAME="Cyberpunk 2077"
GAME_APPID=1091500
GAME_NEXUS_SLUG="cyberpunk2077"

# Framework dependency chain (order matters: installed left-to-right)
# Each entry: nexus_mod_id:required_or_optional
GAME_FRAMEWORKS=(
    "red4ext:2060:required"        # RED4ext (DLL loader)
    "redscript:2880:required"      # REDscript (scripting)
    "cyber-engine-tweaks:107:required"  # CET (Lua scripting)
    "archivexl:4198:required"      # ArchiveXL (archive loading)
    "tweakxl:4197:required"        # TweakXL (tweak overrides)
    "codeware:7587:optional"       # Codeware (framework ext)
    "input-loader:4575:optional"   # Input Loader
)

# Where mod files go (relative to game root)
# Maps archive extension/pattern → target directory
GAME_INSTALL_RULES=(
    "*.archive:archive/pc/mod"
    "*.xl:archive/pc/mod"
    "*.reds:r6/scripts"
    "*.lua:bin/x64/plugins/cyber_engine_tweaks/mods"
    "red4ext/*.dll:red4ext/plugins"
    "bin/x64/*.dll:bin/x64"
    "engine/*.ini:engine"
)

# Files/dirs that should NEVER be on the overlay (stay on native FS)
GAME_EXCLUDE_FROM_OVERLAY=(
    "compatdata"
    "shadercache"
)

# Post-install verification checks
GAME_VERIFY_CHECKS=(
    "file_exists:bin/x64/powrern/red4ext.dll"
    "file_exists:bin/x64/powrern/RED4ext/RED4ext.dll"
    "file_exists:engine/config/base/scripts.ini"
    "dir_not_empty:archive/pc/mod"
)

# Known conflict patterns (mod A + mod B = bad)
GAME_KNOWN_CONFLICTS=(
    "ArchiveXL<4.0:TweakXL>=2.0"   # Version mismatch
)

# Load order tool (optional)
# GAME_LOAD_ORDER_TOOL="loot"  # for Bethesda games
```

```bash
# config/mods/games.d/skyrimse.conf
GAME_NAME="Skyrim Special Edition"
GAME_APPID=489830
GAME_NEXUS_SLUG="skyrimspecialedition"

GAME_FRAMEWORKS=(
    "skse64:30379:required"
    "address-library:32444:required"
)

GAME_INSTALL_RULES=(
    "*.esp:Data"
    "*.esm:Data"
    "*.esl:Data"
    "*.bsa:Data"
    "*.ba2:Data"
    "textures/*:Data/textures"
    "meshes/*:Data/meshes"
    "scripts/*:Data/scripts"
    "SKSE/Plugins/*.dll:Data/SKSE/Plugins"
    "*.ini:Data/SKSE/Plugins"
)

GAME_VERIFY_CHECKS=(
    "file_exists:skse64_loader.exe"
    "dir_not_empty:Data"
)

GAME_LOAD_ORDER_TOOL="loot"
```

```bash
# config/mods/games.d/gtav.conf
GAME_NAME="Grand Theft Auto V"
GAME_APPID=271590
GAME_NEXUS_SLUG="grandtheftauto5"

# RAGE engine: ASI-based, no mod manager
GAME_BACKEND="asi"

GAME_FRAMEWORKS=(
    "script-hook-v:0:required"       # ScriptHookV (id 0 = manual/non-nexus)
    "asi-loader:0:required"          # Ultimate ASI Loader
)

GAME_INSTALL_RULES=(
    "*.asi:."
    "*.dll:."
    "*.rpf:mods/update/x64/dlcpacks"
    "*.xml:."
    "*.ini:."
)

GAME_VERIFY_CHECKS=(
    "file_exists:dinput8.dll"
    "file_exists:ScriptHookV.dll"
    "pe_arch_64:dinput8.dll"
)
```

### Rule resolution

When installing a mod, the system:
1. Extracts the archive to a temp dir
2. Walks the extracted tree
3. Matches each file against `GAME_INSTALL_RULES` (first match wins)
4. Moves matched files into the staging dir with the correct game-relative path
5. Unmatched files: warns but does not fail (may be docs, readmes, etc.)

For RAGE-engine games (`GAME_BACKEND="asi"`), the existing `asi.sh` logic is
used as the backend — overlayfs is optional (ASI mods are inherently file-drop).

---

## 5. Manifest Schema

Single source of truth per game. Location:
`~/.local/state/powos/mods/manifests/<game>.json`

```jsonc
{
  "game": "cyberpunk2077",
  "appid": 1091500,
  "game_dir": "/home/powos/.local/share/Steam/steamapps/common/Cyberpunk 2077",
  "deploy_method": "overlayfs",  // "overlayfs" | "asi" | "direct" (legacy)
  "overlay_mounted": true,
  "last_deployed": "2026-07-16T14:30:00Z",
  "last_verified": "2026-07-16T14:35:00Z",
  "last_verify_result": "pass",  // "pass" | "warn" | "fail"

  "mods": [
    {
      "id": "mod-12345",
      "nexus_mod_id": 12345,
      "nexus_file_id": 67890,
      "name": "Appearance Menu Mod",
      "version": "3.2.1",
      "author": "SomeAuthor",
      "source": "nexus",           // "nexus" | "local" | "nma" | "vortex" | "manual"
      "installed_at": "2026-07-16T14:00:00Z",
      "updated_at": null,
      "enabled": true,
      "priority": 10,              // lower = loads first, higher = wins conflicts
      "staging_dir": "~/.local/state/powos/mods/staging/cyberpunk2077/mod-12345",

      "files": [
        {
          "path": "archive/pc/mod/appearance_menu.archive",
          "sha256": "abc123...",
          "size": 1048576
        },
        {
          "path": "r6/scripts/appearance_menu/init.reds",
          "sha256": "def456...",
          "size": 2048
        }
      ],

      "depends_on": ["mod-2060"],  // RED4ext framework
      "tags": ["ui", "character"],
      "nexus_url": "https://www.nexusmods.com/cyberpunk2077/mods/12345"
    },
    {
      "id": "fw-red4ext",
      "nexus_mod_id": 2060,
      "name": "RED4ext",
      "version": "1.25.1",
      "source": "nexus",
      "installed_at": "2026-07-16T13:50:00Z",
      "enabled": true,
      "priority": 0,               // frameworks get priority 0 (load first)
      "is_framework": true,
      "staging_dir": "~/.local/state/powos/mods/staging/cyberpunk2077/fw-red4ext",
      "files": [ /* ... */ ],
      "depends_on": [],
      "tags": ["framework"]
    }
  ]
}
```

### Manifest invariants

1. **`mods[]` is the truth.** If a mod is in the manifest, it exists in staging.
   If it's not in the manifest, it doesn't exist (even if files are on disk).
2. **`files[]` per mod is exhaustive.** Every file the mod contributes is listed
   with its SHA-256. This enables drift detection.
3. **`priority` determines overlay stacking.** Lower priority = bottom of stack
   (loads first). Higher priority = top (wins file conflicts). Frameworks are
   always priority 0.
4. **`enabled: false`** means the mod's staging dir is excluded from the overlay
   stack at deploy time. Files remain on disk; toggle is instant (remount).
5. **`source`** tracks provenance for the `adopt` verb — mods migrated from NMA
   or Vortex retain their source tag for audit.

---

## 6. Unified CLI Verbs

### Primary verbs

```
powos mods status [game]              Show installed mods, deploy state, health
powos mods install <game> <mod...>    Download + stage + deploy mods
powos mods remove <game> <mod...>     Remove mods from staging + manifest, redeploy
powos mods list [game]                List installed mods (filterable)
powos mods enable <game> <mod...>     Enable disabled mods (redeploy)
powos mods disable <game> <mod...>    Disable mods without removing (redeploy)
powos mods deploy <game>              (Re)mount the overlay from current manifest
powos mods undeploy <game>            Unmount overlay, game returns to pristine
powos mods verify <game>              Run verify checks, report drift/issues
powos mods doctor <game> [--ai]       Deep diagnosis: manifest vs disk, conflicts,
                                      framework versions, load order. --ai for
                                      AI-assisted troubleshooting
powos mods rollback <game>            Restore last snapshot (undeploy + clear upper)
powos mods adopt <game>               Detect existing NMA/Vortex/manual mods,
                                      absorb into manifest
```

### Verb semantics

#### `install`

```bash
powos mods install cyberpunk2077 12345 67890 "Appearance Menu Mod"
#                  ^^game        ^^nexus mod IDs or search terms
```

1. **Resolve** each argument: Nexus mod ID (numeric) → direct lookup. Text →
   search Nexus API → present top 5 matches → user picks.
2. **Check frameworks:** If game has `GAME_FRAMEWORKS`, ensure they're installed
   first. Auto-install required frameworks with confirmation.
3. **Pre-flight:** For each mod, check `GAME_KNOWN_CONFLICTS` against already-
   installed mods. Warn (not block) on conflicts.
4. **Download:** Premium → direct API. Free → open browser, wait for nxm://
   callback. Archive saved to `cache/downloads/`.
5. **Stage:** Extract archive → apply `GAME_INSTALL_RULES` → write files to
   `staging/<game>/mod-<id>/` with correct game-relative paths.
6. **Snapshot:** Record current manifest state + SHA-256 of all files in the
   overlay upper layer → `snapshots/<game>/<timestamp>.json`.
7. **Manifest:** Add mod entry to manifest with files list, SHA-256 hashes.
8. **Deploy:** Remount overlay with new mod in the stack.
9. **Verify:** Run `GAME_VERIFY_CHECKS`. Report pass/warn/fail.

If any step fails, the transaction is unwound: staging dir removed, manifest
unchanged, overlay not remounted. The game directory is never in a half-state.

#### `remove`

1. Record snapshot (pre-remove state).
2. Remove mod's staging dir.
3. Remove mod from manifest.
4. Remount overlay (mod disappears from merged view).
5. Check for orphaned dependencies (framework only needed by removed mod).

#### `enable` / `disable`

Toggle `enabled` in manifest. Remount overlay (disabled mods excluded from
lowerdir list). No files moved or deleted — instant operation.

#### `deploy`

Build the overlay mount from the current manifest:

```bash
# Build lowerdir string from manifest, sorted by priority
lowerdirs=""
for mod in $(jq -r '.mods[] | select(.enabled) | .staging_dir' manifest.json \
             | sort -t: -k2 -n -r); do  # highest priority first (leftmost wins)
    lowerdirs="${lowerdirs:+$lowerdirs:}$mod"
done
lowerdirs="$lowerdirs:$game_dir"  # pristine game is always bottom

mount -t overlay overlay \
    -o "lowerdir=$lowerdirs,upperdir=$upper,workdir=$work" \
    "$merged"
```

Set Steam launch options to use the merged directory.

#### `undeploy`

Unmount overlay. Remove Steam launch options override. Game reverts to pristine.
Staging dirs and manifest are preserved (redeploy is instant).

#### `verify`

1. For each mod in manifest: check that `staging_dir` exists and all files match
   their recorded SHA-256 hashes.
2. Run `GAME_VERIFY_CHECKS` from the game's config.
3. If overlay is mounted: check merged view for expected files.
4. Report: `PASS` (all good), `WARN` (minor drift), `FAIL` (missing files,
   hash mismatches, broken framework chain).
5. **Test harness integration** (coordinate with task-886cdab4): if a headless
   test harness is available, `verify --launch` attempts a test launch:
   ```bash
   # Interface contract with the test harness:
   # Input:  game appid, game dir (or merged dir), timeout
   # Output: exit code (0=launched ok, 1=crash, 2=freeze, 3=error)
   #         stdout: structured log (launch time, crash signature if any)
   powos mods _verify_launch <appid> <merged_dir> --timeout 30
   ```

#### `doctor`

Deep diagnosis that goes beyond `verify`:

1. All `verify` checks.
2. Manifest vs disk drift: files in staging but not in manifest, or vice versa.
3. Framework version compatibility: check framework versions against game version
   (from `GAME_FRAMEWORKS` and Nexus API version info).
4. Known conflict scan: check all installed mod pairs against `GAME_KNOWN_CONFLICTS`.
5. Load order analysis: for Bethesda games with `GAME_LOAD_ORDER_TOOL=loot`, run
   LOOT CLI and report issues.
6. Recent-install bisect suggestion: if game was working N mods ago, suggest
   disabling mods installed after the last known-good snapshot.
7. `--ai` flag: pipe all findings to the health AI agent for natural-language
   diagnosis and repair suggestions.

#### `rollback`

1. List available snapshots for the game.
2. User picks one (default: most recent).
3. Undeploy current overlay.
4. Restore manifest from snapshot.
5. Verify staging dirs match snapshot. If mods were removed since snapshot,
   re-download them (or warn if offline).
6. Redeploy.

#### `adopt`

Migration verb for absorbing existing mods into the native manifest:

```bash
powos mods adopt cyberpunk2077
```

1. **Scan** the game directory for known mod signatures:
   - NMA: check `~/.local/share/NexusModsApp/` for deployment records
   - Vortex: check `~/.var/app/com.usebottles.bottles/.../PowosVortex/` state
   - Manual: diff game dir against Steam's depot manifest (clean file list)
2. **Identify** each mod: match file patterns against `GAME_INSTALL_RULES`,
   cross-reference Nexus API by filename/hash where possible.
3. **Stage:** Copy identified mod files into `staging/<game>/mod-<id>/`.
4. **Manifest:** Create entries with `source: "nma"/"vortex"/"manual"`.
5. **Deploy:** Mount overlay. The original game dir files are now redundant
   (covered by staged copies in the overlay).
6. **Report:** List adopted mods, any unidentified files (manual inspection
   needed).

Adopt is non-destructive — the original game dir is not modified. The overlay
shadows the manually-installed mod files with the staged copies.

---

## 7. Snapshot System

Every state-changing operation (install, remove, enable, disable, rollback)
creates a snapshot before applying changes.

### Snapshot format

```jsonc
// ~/.local/state/powos/mods/snapshots/cyberpunk2077/2026-07-16T14:30:00.json
{
  "timestamp": "2026-07-16T14:30:00Z",
  "operation": "install",           // what triggered this snapshot
  "manifest_before": { /* full manifest copy */ },
  "upper_files": [                  // files in the overlay upper layer
    {
      "path": "engine/config/platform/pc/foo.ini",
      "sha256": "...",
      "size": 1024
    }
  ]
}
```

### Retention

- Keep last 10 snapshots per game (configurable).
- `powos mods rollback <game> --list` shows available snapshots.
- `powos mods rollback <game> --to <timestamp>` picks a specific one.
- Btrfs snapshot optimization: when staging is on btrfs, use `btrfs subvolume
  snapshot` instead of file-level manifests. Check with `stat -f --format=%T`.

---

## 8. Legacy Backend Escape Hatches

NMA and Vortex remain available as escape hatches for:
- FOMOD installers (complex interactive install wizards) — out of scope for v1
- Games not yet defined in `games.d/`
- Users who prefer the GUI experience

```bash
# Legacy access (explicit opt-in):
powos mods legacy nma <game>        # Launch NMA for this game
powos mods legacy vortex <game>     # Launch Vortex for this game
powos mods legacy jackify <list>    # Run a Wabbajack modlist

# After using legacy tools, adopt the results:
powos mods adopt <game>             # Absorb whatever they installed
```

The ASI backend (`lib/mods/asi.sh`) is not "legacy" — RAGE engine games
(GTA V, RDR2) use ASI loaders natively. The ASI backend is integrated as
`GAME_BACKEND="asi"` in the game config. For ASI games, overlayfs is optional
(ASI mods are inherently file-drop), but the manifest and verify systems still
apply.

---

## 9. Implementation Plan

### Phase 1: Foundation (files to create/modify)

| File | Purpose |
|---|---|
| `lib/mods/core.sh` | Manifest CRUD, staging helpers, overlay mount/unmount |
| `lib/mods/nexus-api.sh` | Extracted Nexus API helpers (from install.sh dedup) |
| `lib/mods/deploy.sh` | Overlayfs deployment, Steam launch options |
| `lib/mods/verify.sh` | Verify + doctor engine |
| `lib/mods/snapshot.sh` | Snapshot create/restore/list |
| `lib/mods/adopt.sh` | Migration from NMA/Vortex/manual |
| `config/mods/games.d/*.conf` | Per-game install rules (start with Cyberpunk, Skyrim SE, GTA V) |
| `bin/powos` (mods dispatch) | Rewire verb dispatch to new files |

### Phase 2: Game configs

Priority order based on user's broken install + popularity:
1. Cyberpunk 2077 (motivating case)
2. Skyrim SE / Skyrim AE
3. GTA V / GTA V Enhanced
4. RDR2
5. Fallout 4
6. Starfield
7. Baldur's Gate 3

### Phase 3: Polish

- `powos mods search <game> <query>` — search Nexus from CLI
- `powos mods update <game> [mod]` — check for mod updates via Nexus API
- `powos mods export/import` — share mod lists
- FOMOD support (if needed — complex, may stay out of scope)

### What NOT to build

- **No GUI.** CLI-first. The modder AI agent provides natural language on top.
- **No FOMOD parser in v1.** Interactive mod install wizards are complex XML
  state machines. Escape to NMA/Vortex for FOMOD mods, then `adopt`.
- **No automatic mod update downloads.** Check + notify only. User triggers
  updates explicitly.
- **No Windows support.** PowOS is Linux-only. Proton/Wine handles the games.

---

## 10. `games-sync` Compatibility

The existing `lib/games-sync.sh` syncs mods between devices via rsync. The new
system must not break `powos games sync --what mods`. The sync paths:

| Current path | New path | Migration |
|---|---|---|
| NMA data dir | Still synced (legacy) | No change |
| Vortex bottle | Still synced (legacy) | No change |
| MO2 dir | Still synced (legacy) | No change |
| *NEW:* staging dirs | `~/.local/state/powos/mods/staging/` | Add to sync |
| *NEW:* manifests | `~/.local/state/powos/mods/manifests/` | Add to sync |

The overlay mount is **not** synced (it's ephemeral, rebuilt from staging +
manifest on each device). Snapshots are optionally synced.

---

## 11. Testing Strategy

All testable via bash dry-runs and mock game directories (no GPU needed):

| What | How | Where |
|---|---|---|
| Manifest CRUD | Unit tests with temp dirs | `test/tier1/test-mods-manifest.sh` |
| Install rules resolution | Mock archives + game configs | `test/tier1/test-mods-rules.sh` |
| Overlay mount/unmount | `unshare -rm` in Docker | `test/tier1/test-mods-overlay.sh` |
| Snapshot create/restore | Temp dirs | `test/tier1/test-mods-snapshot.sh` |
| Nexus API | Mock HTTP responses | `test/tier1/test-mods-nexus.sh` |
| Verify checks | Mock game dirs | `test/tier1/test-mods-verify.sh` |
| Adopt (migration) | Mock NMA/Vortex state | `test/tier1/test-mods-adopt.sh` |
| Full integration | Docker compose + mock Steam | `test/tier1/test-mods-e2e.sh` |

Real-hardware validation (Tier 2, manual):
- Launch modded Cyberpunk via overlay on user's machine
- Verify + doctor on a broken install
- Adopt from existing NMA-managed mods
- Test harness integration (coordinate with task-886cdab4)

---

## 12. Open Questions

1. **Steam Deck compatibility:** Does the Steam Deck's Gamescope session handle
   overlayfs-mounted game dirs? Needs hardware testing.
2. **Flatpak Steam:** If Steam is installed as a Flatpak, can it see overlayfs
   mounts outside its sandbox? May need `--filesystem` permissions.
3. **REDmod (Cyberpunk):** REDmod is Cyberpunk's official mod tool that
   recompiles archives. Does it work on an overlay, or does it need direct
   write access to the game dir? If the latter, REDmod runs on the upper layer.
4. **Mod manager state format evolution:** The manifest schema will evolve.
   Include a `"schema_version": 1` field and handle migration in code.

---

## Appendix A: Prior Art

- **[linux-mod-organizer](https://codeberg.org/enoki/linux-mod-organizer):**
  Proof that overlayfs + Proton works. Uses kernel overlayfs via user namespace.
  Confirms lowerdir priority ordering. Documents the `mount()` ARG_MAX issue.
- **[Fluorine-Manager](https://github.com/SulfurNitride/Fluorine-Manager):**
  Another overlayfs mod manager for Linux. Documents the Steam
  `pressure-vessel` namespace conflict and workaround.
- **Mod Organizer 2 (MO2):** Windows-native, uses VFS (virtual filesystem) to
  achieve the same goal — game files never modified. Runs on Linux via Wine but
  VFS doesn't work correctly (the hook DLLs fail in Wine). Overlayfs replaces
  the need for MO2's VFS on Linux.
- **Vortex:** Uses hardlinks for deployment on Windows. On Linux (via Wine in
  Bottles), hardlinks work but are fragile across filesystems. Our overlay
  approach is strictly superior on Linux.

## Appendix B: Nexus API Endpoints Used

```
GET  /v1/users/validate                    → validate API key
GET  /v1/games/{slug}.json                 → game info
GET  /v1/games/{slug}/mods/{id}.json       → mod info (name, version, desc)
GET  /v1/games/{slug}/mods/{id}/files.json → file list
GET  /v1/games/{slug}/mods/{id}/files/{fid}/download_link.json
                                           → CDN URLs (premium or nxm key)
GET  /v1/games/{slug}/mods/updated.json?period=1m
                                           → recently updated mods (for update check)
```

All requests require header: `apikey: <key from ~/.config/powos/nexus.key>`
