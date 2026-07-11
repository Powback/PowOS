# PowOS AI-Managed Modding — Spec & Constraints

> **Purpose:** capture what we can and can't automate for game modding through
> the Nexus Mods App (NMA) **and** Vortex-in-Bottles, so future sessions don't
> re-discover the same dead-ends. Update as either CLI's surface changes.

**Status (2026-07-07):**
  - **NMA path** (Cyberpunk 2077, Stardew Valley only): partial automation.
    Agent discovers, selects, dispatches downloads. User still clicks
    **Install** in the GUI for the last step.
  - **Vortex path** (every other Nexus-tracked game, ~150 titles): FULL
    automation. Vortex has a real CLI — `vortex -i nxm://...` downloads AND
    installs a mod without any GUI click. This is the primary path for
    Bethesda titles, BG3, Witcher 3, Starfield, etc.

---

## 1. Goal

An AI agent (`powos ai --agent modder`) should take a plain-language modding
request ("install these 27 Cyberpunk graphics mods, put them in my Graphics
group") and finish the job without the user touching the mouse — including
picking correct file variants (HD vs SD, ESL vs ESM, patch vs main), respecting
group placement, and running the deploy.

The user should still be able to see each mod on its Nexus page from inside the
manager (update badges, changelog, endorse button, etc.), so:

**We WILL NOT lose the mod-page association.** No raw-zip downloads through
`loadout install -f <zip>` — that path adds the mod as a "Local File" with no
link back to Nexus. Losing that breaks update tracking, endorsement, and the
whole reason to use a mod manager over `unzip`.

---

## 1b. Manager routing

Not every game is covered by every manager. The agent picks based on which
manager owns that title:

  | Game | Manager |
  |------|---------|
  | Cyberpunk 2077 | Vortex *(preferred: click-free -i CLI)* or NMA |
  | Stardew Valley | NMA (only manager that ships an extension for it today) |
  | Skyrim (LE / SE / AE / VR) | Vortex |
  | Fallout 3 / NV / 4 / 76 | Vortex |
  | Starfield | Vortex |
  | Baldur's Gate 3 | Vortex |
  | Witcher 3 | Vortex |
  | Oblivion / Oblivion Remastered | Vortex |
  | Morrowind | Vortex |
  | Kingdom Come: Deliverance | Vortex |
  | Elden Ring / DS1-3 / Sekiro | Vortex |
  | Monster Hunter World / Rise | Vortex |
  | Mount & Blade: Bannerlord | Vortex |
  | Mass Effect LE | Vortex |
  | GTA V (Enhanced `gta5enhanced` / Legacy `gta5`) | Vortex *(Nexus assets only — see note)* |
  | Red Dead Redemption 2 | Vortex *(Nexus assets only — see note)* |
  | X-COM / everything else Nexus tracks | Vortex |

**RAGE-engine games (GTA V, RDR2) are a special case.** Vortex only manages
the *Nexus-hosted* layer (texture packs, Lenny's Mod Loader add-ons). The core
loaders — Script Hook V / Script Hook RDR2, the ASI loader, Lenny's Mod Loader,
ENB, ReShade — are distributed **off-Nexus** and drop straight into the game
folder; no manager installs them. `powos mods setup gta|rdr2` sets the
`dinput8=n,b` override Script Hook needs under Proton. For photorealism on
Linux, **vkBasalt** (native Vulkan post-processing, `ENABLE_VKBASALT=1`) is the
cleanest, ban-safe first move. GTA V Enhanced ships BattlEye — **story mode
only**; RDR2 single-player has no kernel anti-cheat. GTA V **Enhanced and
Legacy are separate Nexus catalogs** and do not share mods.

**FiveM (GTA V) / RedM (RDR2) are multiplayer clients, not graphics loaders** —
they connect to online servers and block client-side graphics mods. Never route
a single-player "make it look better" request to them.

Both managers install into their own worlds — you can have both running,
but only one at a time can own `x-scheme-handler/nxm`. **Vortex takes the
handler on install** (its coverage is ~75× wider than NMA's, and its `-i`
CLI closes the click-through gap NMA has). For Cyberpunk specifically,
Vortex's Cyberpunk 2077 extension is mature and supports REDmod, RED4ext,
CET, ArchiveXL — the whole framework stack. Use NMA for CP2077 only if
you prefer its Linux-native UI. Flip via `xdg-mime default
nexus-mods-app.desktop x-scheme-handler/nxm`. See `powos mods vortex
handler` for the current owner.

---

## 2. Vortex-in-Bottles pipeline

Since NMA only covers two titles, Vortex is the actual workhorse. Vortex is
Windows-only, but it runs cleanly inside a Bottles Flatpak wine prefix. Its
NSIS installer's silent (`/S`) mode is **unreliable headless** — under a
display-less Wine prefix it extracts its payload to `%TEMP%` but never copies
to the install dir (it still tries to open a window; `xrandr` fails), exiting
0 with nothing installed. Since electron-builder installers are just 7z
self-extractors, PowOS instead pulls `$PLUGINSDIR/app-64.7z` straight out of
the `.exe` with host `7z` and unpacks it into `C:\Vortex` — deterministic, no
Wine, no display (diagnosed & fixed 2026-07-11). `.NET Desktop 6` is an
optional dependency (Vortex self-installs it on first GUI run if absent).

**Install pipeline** (`powos mods install vortex`):

  1. `flatpak install --system flathub com.usebottles.bottles` (if missing)
  2. `flatpak override --user … --filesystem=~/.steam …` and other Steam
     library paths — otherwise Vortex can't reach Steam games from inside
     the sandbox.
  3. `bottles-cli new --bottle-name PowosVortex --environment application
     --arch win64` — dedicated sandbox, not shared with any other bottle.
  4. `bottles-cli shell -b PowosVortex -i "winetricks -q dotnetdesktop6
     corefonts"` — installs .NET Desktop 6 into the bottle's Wine env.
     (Bottles CLI has no first-class dependency verb yet; winetricks
     inside the bottle shell is the workaround.)
  5. `curl -L github.com/Nexus-Mods/Vortex/releases/download/vN/vortex-setup-N.exe`
  6. `7z e vortex-setup-N.exe '$PLUGINSDIR/*.7z'` then `7z x app-64.7z -o…/drive_c/Vortex`
     — direct payload extract (the headless NSIS `/S` install is broken; see
     above). Falls back to the old `bottles-cli run … /S /D=C:\Vortex` only if
     no host `7z` is available.
  7. Write `~/.local/bin/vortex` wrapper — dispatches to
     `bottles-cli run -b PowosVortex -e Vortex.exe -a "…"`, detached via
     `setsid nohup` so `xdg-open` returns immediately.
  8. Write two `.desktop` files:
     - `vortex-mod-manager.desktop` (menu launcher)
     - `vortex-nxm-handler.desktop` (`MimeType=x-scheme-handler/nxm`,
       `Exec=vortex -i %u`)
  9. `xdg-mime default vortex-nxm-handler.desktop x-scheme-handler/nxm`
     — unconditionally by default. Vortex covers ~150 games and NMA only 2,
     so Vortex-owns-nxm is the sensible default. Pass `--no-default` to
     leave whatever handler was there in place.

**Post-install CLI** (`powos mods vortex …`):

  | Verb | What it runs |
  |------|--------------|
  | `install` | The full pipeline above |
  | `uninstall` | Remove bottle dir + wrapper + .desktop + icon + state, restore nxm:// |
  | `run [args…]` | `vortex …` (GUI when no args) |
  | `url <nxm-url>` | `vortex -i <url>` — download+install one mod |
  | `bulk <game> <mod-ids…>` | Nexus API → primary MAIN file per id → `vortex -i` each |
  | `get <state.path>` | `vortex -g <path>` — read Vortex state |
  | `set <path>=<val>` | `vortex -s` (state-corrupting; guarded) |
  | `install-dotnet` | Rerun step 4 if .NET install failed |
  | `set-default-handler` | Set Vortex as system nxm:// default |
  | `handler` | `xdg-mime query default x-scheme-handler/nxm` |
  | `health-check` | Verify bottle + exe + wrapper + .desktop files |

**Vortex.exe CLI vocabulary** (Vortex 2.2.0):

  - `-i <url>` — download **and install** from URL (nxm:// works)
  - `-d <url>` — download only
  - `--game <id>` — launch with a game activated
  - `--profile <id>` — activate a profile at launch
  - `-g <path>` — print state at a path (JSON dot-notation)
  - `-s <path>=<v>` — write state (dangerous)
  - `--user-data <dir>` — override state dir
  - `--start-minimized`, `--inspector`, `--max-memory <MB>`

That `-i` verb is what makes Vortex agent-friendly in a way NMA isn't: the
"click Install" step is baked into the CLI itself.

---

## 4. What works today (`powos mods` verbs)

  | Verb | Effect | GUI must be… |
  |------|--------|--------------|
  | `powos mods info <game> <mod-id>` | Mod summary JSON | any state |
  | `powos mods files <game> <mod-id>` | File list (categories, IDs) | any state |
  | `powos mods changelog <game> <mod-id>` | Per-version changelog | any state |
  | `powos mods download-link <game> <mod-id> <file-id>` | Signed nxm:// (Premium) | any state |
  | `powos mods install <game> <ids…>` | BULK: dispatch nxm:// per mod | running (for auto-install) |
  | `powos mods install-file <game> <mod-id> <file-id>` | Specific variant | running |
  | `powos mods install-collection <slug>` | Full collection | closed |
  | `powos mods setup <game>` | protontricks + WINEDLLOVERRIDES | Steam closed |
  | `powos mods loadouts` | List loadouts | closed |
  | `powos mods deploy <game>` | `loadout synchronize` | closed |
  | `powos setup nexus` | Save API key to `~/.config/powos/nexus.key` | — |

**Discovery.** The agent has full read access to Nexus's REST API and picks
files intelligently (MAIN + primary preferred, HD vs SD by user's VRAM, etc.).

**Download.** `protocol-invoke -u nxm://<game>/mods/<id>/files/<fid>` dispatched
to the running NMA GUI. Bare URLs work — NMA uses its stored OAuth internally
(discovered 2026-07-07). Mod lands in Library and preserves the mod-page link.

**Everything past download.** User still has to press **Install** per mod in
the NMA GUI. That's the gap.

---

## 5. What NMA's CLI is missing

Confirmed by reading `LoadoutManagementVerbs.cs`, `ProtocolVerbs.cs`,
`Verbs.cs` in `NexusMods.Collections/`. The current CLI vocabulary:

  - `loadout install -l <loadout> -f <file> -n <name>` — takes a **raw
    archive**, adds it to the library, installs to loadout. **Rejects** `.nx`
    (NMA's internal archive format that's already in the Library dir).
  - `loadout synchronize -l <loadout>` — deploys to disk.
  - `install-collection -s <slug> -r <rev> -l <loadout>` — whole collections.
  - `loadout groups list` / `loadout group list` — read groups (no create/move).
  - `loadout group items delete` — delete items from a group.
  - `loadouts list`, `loadout reindex`, `loadout revert`, `loadout revisions`.

**Missing verbs (the actual blockers):**

  1. `library install -i <library-item-id> -l <loadout> [-n <name>] [-g <group>]`
     — install a Library item (already downloaded via nxm://) into a loadout,
     preserving the Nexus mod-page link.
  2. `loadout group create -l <loadout> -n <name>` — create a custom group.
  3. `loadout group move -l <loadout> -i <item> -g <group>` — move an item
     between groups (My Mods → Graphics, etc.).
  4. `library list -l <loadout>` — list items in the Library (JSON out).

Without (1), we can't finish the pipeline programmatically without going
through raw-zip (which we've ruled out). Without (2)/(3), we can't do group
placement even if (1) existed.

---

## 6. Options for closing the NMA gap

**Ranked by how good the outcome is, worst to best.**

### A. Do nothing (current state)
Agent dispatches nxm://, user clicks Install per mod in the GUI. Simple; keeps
the mod-page link. Group placement always manual. This is what the user is
willing to live with today.

### B. Wait for upstream NMA
Nexus's roadmap includes richer CLI verbs. If we file issues for (1)/(2)/(3)
and they land, we get full automation for free. Slow, no guarantees.

### C. Upstream PR
Fork `Nexus-Mods/NexusMods.App`, implement the four missing verbs in the
existing `Verbs` DI-module pattern, PR. Realistic scope — the abstractions
(`ILibraryService`, `ILoadoutManager`, `LoadoutItemGroup` entity type) already
exist; adding CLI wrappers around them is maybe 200 LOC in C#.

### D. Patch our own AppImage
Same code changes, but build a fork we ship as `NexusModsApp.AppImage` from
PowOS's own release pipeline. Fastest to land for us; makes us the maintainer
of a soft fork. Not worth it unless upstream refuses (C).

### E. Direct MnemonicDB writes (rejected)
Skip NMA and mutate its RocksDB via `mods datamodel` or a custom .NET tool.
Fragile: NMA's schema is versioned and changes between releases. Would break
on every NMA update. **Not doing this.**

**Recommended path: A now, C in the medium term.** Ship the current state as
"agent handles discovery + selection + download + queue; you click Install".
File the upstream issue. If Nexus stalls, PR it.

---

## 7. Group placement — the deeper NMA problem

The user asked for mods to auto-drop into a "Graphics" group they created
manually in the GUI. That's currently GUI-only. Even if we solve (1) above,
(2)/(3) are needed for group placement.

The GUI does this via `LoadoutItemGroup` entity transactions in MnemonicDB.
Adding CLI verbs is a straightforward mapping — but until they land, group
placement stays manual. That's the honest state.

---

## 8. What the agent SHOULD keep doing

Despite the gap, the agent adds real value in the 90% that IS scriptable:

  1. **Resolve fuzzy references.** "That HD Reworked mod" → correct mod-id via
     Nexus REST + web search. The user shouldn't have to hand-type mod-ids.
  2. **Pick file variants intelligently.** MAIN+primary by default; HD vs SD
     based on user's VRAM and target resolution; ESL vs ESM based on load-order
     philosophy; framework-mod prerequisites in dependency order.
  3. **Bulk dispatch.** 27 nxm:// URLs in 27 seconds (1s rate limit each).
  4. **Explain choices.** "Picked HD (not Ultra HD) to leave VRAM headroom for
     CET overlays." One line per mod.
  5. **Framework ordering.** For Cyberpunk: RED4ext → REDscript → CET →
     ArchiveXL → TweakXL → content mods.
  6. **Setup boilerplate.** protontricks, WINEDLLOVERRIDES, Steam launch
     options. All headless.
  7. **Verify state after.** `powos mods loadouts`, deploy status,
     `pgrep NMA` — surface errors clearly instead of hanging.

That's genuinely useful. The last-click gap is a real limitation but it's not
a reason to abandon the mostly-automated flow.

---

## 9. Non-goals

  - **Full offline modding.** Nexus's REST API is the source of truth for file
    metadata; we won't cache/mirror it.
  - **Vortex-on-Wine automation.** Vortex has better CLI on Windows but is a
    step back on Linux (Wine dependency, no native pipeline). Not investing.
  - **NMA GUI replacement.** We're wrapping NMA, not replacing it. The GUI's
    conflict-resolution UI, load-order editor, and update badges are all
    valuable — we're adding CLI on top, not underneath.

---

## 10. Decisions log

  - **2026-07-07 — Rejected raw-zip pipeline.** `loadout install -f <zip>`
    works but drops the Nexus mod-page link. User: "if you add it as a zip we
    lose the whole connection to the original mod page and everything, its
    fucked." Confirmed by reading `LoadoutManagementVerbs.InstallMod` — it
    calls `libraryService.AddLocalFile()`, which creates a `LocalFile`
    entity with no `NexusModsMod` back-reference.
  - **2026-07-07 — Bare nxm:// URLs work.** No `?key=&expires=&user_id=`
    needed. NMA uses stored OAuth internally.
  - **2026-07-07 — GUI-lock detection via RocksDB LOCK.** `pgrep -f` was
    catching agent processes whose prompt text mentions the AppImage path.
    Switched to `fuser` on `MnemonicDB.rocksdb/LOCK`.
  - **2026-07-07 — Group placement is not CLI-doable in NMA.** Confirmed by
    exhaustive scan of `Verbs.cs` files. Marked as upstream-blocker.
  - **2026-07-07 — Added Vortex-in-Bottles as the primary path.** NMA covers
    only Cyberpunk + Stardew Valley; Vortex covers everything else Nexus
    tracks. Vortex's `-i nxm://` gives full agent automation (no click
    step), which NMA doesn't have. Implemented via Bottles Flatpak +
    NSIS silent install; `.NET Desktop 6` installed via winetricks inside
    the bottle shell (Bottles CLI has no dependency verb yet).

---

## 11. Open questions

  - Does the running NMA GUI auto-install mods that arrive via
    `protocol-invoke`, or does it just queue them to the Library? The user's
    observation ("I have to press the install button") suggests queue-only.
    If there's a settings toggle for auto-install, wire it on during
    `powos mods setup <game>`.
  - Is there a `~/.local/share/NexusMods.App/settings/` JSON we can flip to
    change that behavior? Worth an evening of source reading.
  - Post-download hook / IPC socket? NMA's process might listen on one we
    can send "install everything in Library not yet in Loadout" over.
