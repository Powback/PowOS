# Version-proof gaming fixes (2026-11-07)

Board task `gaming-fixes-version-independent-stack-on-latest`. User, 11-07: "we should just always have latest?" /
"or make sure our fixes are version independent or whatever?"

## What "latest" means per layer

| layer | who updates it | what we pin |
|---|---|---|
| Steam client (native ARM64, `steamrtarm64/`) | Valve, self-update | nothing: `/usr/bin/steam` fetches it once from the `steam_client_linuxarm64` manifest, then Steam updates itself |
| Proton Experimental (ARM64), SteamLinuxRuntime_4-arm64, Steam's FEX tool (appid 3127680) | Valve, via Steam | nothing; our overlays/fixes into them are below |
| Steam x86 bootstrap (`pkgs/steam`, `steam_1.0.0.87.tar.gz`) | us | 1.0.0.87 = newest on repo.steampowered.com stable (listing 11-07: .84, .85, .87). Only the `STEAM_X86=1` fallback uses it |
| FEX (`pkgs/fex-emu`) | us | **FEX-2611** (was 2610), monthly tags |
| Turnip (`pkgs/vulkan-freedreno-kgsl`) | us | **Mesa main 3a2cd129** (11-07) + the lfdevs fork's Turnip delta (was the fork's own tree eb3e7fd4 of 10-29) |
| Xwayland (`pkgs/xwayland-kgsl`), KWin (`pkgs/kwin`) | us | xwayland-24.1.13 + lfdevs 0001-0004, KWin 6.7.5 (the rootfs's Plasma). Not moved here: they follow the rootfs/Plasma version (BUILD_ON_ROOTFS) |

So "always latest" holds for everything Valve ships; for what we build, the pins move on purpose (bumped once now),
and every fix is either independent of the version or says loudly that it no longer applies.

## Rules every fix follows now

- **Detect by capability, never by version or path.** ARM64 Proton = a `proton` script with Wine's
  `files/lib/wine/aarch64-windows` (any name, Experimental preferred); the ARM64 runtime = the newest
  `SteamLinuxRuntime_<n>-arm64` with `_v2-entry-point`; Valve's FEX tool = the `steamapps/common` dir with
  `fex-compat-tool` (`pkgs/steam/powos_steam_tools.py`, shared by the gate, powos-steam-compat, powos-steam-fixes).
- **Binary overlays only over the exact upstream file they were made from**, re-checked on every launch (so after a
  Proton update they go back in by themselves when we have a build for it), else upstream's file stays.
- **Fail loudly, run stock.** A fix that can't apply says `fix X not applied: <reason + what to run>` and the game
  starts unpatched. `/usr/bin/steam` runs `powos-steam-fixes --quiet` at each Steam start (no Steam running; prints
  only misses, prefixed `steam:`); the report is kept in `~/.cache/powos/steam-fixes/status.json`.
- **Patches against source fail the build by name** when they no longer fit or upstream already has them (dry-run
  with `-N` / `.rej` check); a patch upstream took is dropped with a note in the PKGBUILD.
- **Options we set in someone else's config are checked against that version**: FEX options/thunks at FEX's build
  (`fex-options-check.py` vs `Config.json.in`/`ThunksDB.json`), and at runtime against Valve's FEX binary
  (`FEX_<NAME>` literal) and Turnip's `TU_DEBUG` flag table.

## Inventory

| fix | what it's tied to | version-independent now? | how it fails |
|---|---|---|---|
| **Patches against a fixed source** | | | |
| KWin 0001-0060 (Anland backend, window tasks, ...) | KWin 6.7.5 tarball (rootfs Plasma) | no - tied to the Plasma the rootfs ships, on purpose (BUILD_ON_ROOTFS) | build stops on a non-applying patch |
| Xwayland 0001-0004 (lfdevs KGSL) + 0005-0015 (ours) | `xwayland-24.1.13` tag | no - lfdevs's KGSL series is on 24.1 | build stops: `patch ... FAILED` / `.rej` check |
| Turnip 0000 (lfdevs fork delta: KGSL knl, devices, X11 WSI) | Mesa main 3a2cd129 | stacked on upstream main now; regenerate when the fork changes Turnip paths (recipe in PKGBUILD) | dry-run first: `patch 0000... does not apply to Mesa <sha>: rebase it, or drop it` |
| Turnip 0001 RB_CCU_CNTL BR-only, 0002 IOCOHERENT trust | Mesa main | applied unchanged on 3a2cd129 | same |
| ~~Turnip 0003 NUMNONPOSVAR~~ | - | **dropped**: upstream 2fae1d0d is in main | - |
| FEX 0001 exec by path, 0003 futex_waitv probe | FEX-2611 tag | applied unchanged on 2611 | `.rej` check stops the build |
| ~~FEX 0002 thunkgen LLVM 23~~ | - | **dropped**: FEX-2611 guards `clearStatCache()` itself | - |
| FEX Config.json / thunks.json keys | FEX's option names | yes: `fex-options-check.py` at every build | build stops: `fex option X not in FEX-<v>` |
| FEX Config.json `RootFS=.../Fedora_44` | the RootFS image name | no (a new RootFS image needs Config.json edited) | FEX can't find its RootFS (loud) |
| **Overlays into Steam / Proton / Valve's FEX** | | | |
| `kernelbase.dll` KEY_WOW64_32KEY direct open (ARM64 Proton) | sha256 of Valve's kernelbase.dll of experimental-11.0-20261027b | per-build table (`OVERLAYS`, one row per Valve build), re-checked every launch; a Proton update to a known build re-applies by itself; `.valve` refreshed | `fix kernelbase-wow32 not applied: Proton ... has a Valve build (sha) we have no overlay for; Valve's file stays. Make one: PROTON_VERSION=<v> targets/android/steam/proton-overlay/build.sh` (tag derived from Proton's version) |
| futex_waitv FEX build over Valve's tool (`steam/fex-compat-tool`, manual) | Valve's FEX commit 37265b1 (FEX-2607-76) | no (must match Valve's FEX<->FEXServer protocol); install.sh refuses another commit | now reported: `fix fex-futex-waitv not applied: Steam updated its FEX tool to <v> and put Valve's FEX back: rebuild with COMMIT=...` |
| ARM64 launch gate `powos-proton-arm64` (evaluator skip + overlay) | was `Proton Experimental (ARM64)` + `SteamLinuxRuntime_4-arm64` by name | yes: Proton/runtime by capability (renamed Proton, runtime 5 found) | no ARM64 Proton/runtime: `fix arm64-gate not applied: ...`; powos-steam-compat maps "arm64" to Valve's tool instead |
| `user_settings.py` in every Proton (evaluator skip, xalia off, Mono anon cache off) | any dir with a `proton` script; our header line | yes; its skip key includes Proton's `version`, so an update re-runs the evaluator once | user's own file left alone; report lists Protons still without it |
| `sitecustomize.py` (x86: evaluator skip in Valve's fex-compat-tool) | argv shape `fex-compat-tool run ... proton run iscriptevaluator.exe` | mostly: matched by basename + argv, any version | does nothing (stock); reported if fex-compat-tool stops being Python or PYTHONPATH lost it |
| FEX ThunksDB.json into compatdata (`POWOS_FEX_VULKAN_THUNK=1`, off) | pressure-vessel's loader paths | path list covers both layouts; off by default | no thunk = FEX's x86 Turnip (works, slower) |
| `guestos/fex-mesa` -> FEX RootFS | the first `RootFS/*/` | yes (glob) | - |
| sysvipc shim preload | Linux SysV IPC ABI | yes | - |
| reg_guard (registry restore after f2fs NUL loss) | `WINE REGISTRY Version 2` header | yes now: any `Version <n>` (a header bump no longer reads as "broken") | - |
| **Launch-option / env injections** | | | |
| `steam-env` FEX_THUNKCONFIG | Valve's FEX reading `FEX_THUNKCONFIG` | checked against Valve's FEX binary each Steam start | `fix fex-env FEX_THUNKCONFIG not applied: Valve's FEX <v> doesn't know ...` |
| `steam-env` TU_DEBUG=noubwc | Turnip's flag table | checked against `/usr/lib/libvulkan_freedreno.so` | `fix turnip TU_DEBUG=noubwc not applied: ... renamed or dropped upstream` |
| `steam-env` MESA_EXTENSION_OVERRIDE=+GL_ARB_buffer_storage, MONO_DISABLE_SHM=1, PYTHONPATH | Mesa/Mono env names (stable for years) | yes (an unknown name is ignored; harmless once upstream fixes it) | - |
| `STEAM_COMPAT_FEX_CONFIG` (TSOEnabled, Multiblock, ThunksDB_GL/Vulkan) | FEX option names | checked by fex-options-check (scans `steam`) | build-time message |
| `-cef-disable-gpu-sandbox` | CEF switch name | yes (unknown switch ignored) | GPU process dies -> no UI (visible) |
| unity-screen launch option (Unity/Unreal at container size) | engine files (`*_Data`, UE layout) + Unity player args | yes (engine detected by files, args stable across Unity versions) | no size / no python: game starts unchanged |
| powos-steam-compat tool mapping (`proton-experimental-arm64`, `proton_experimental`) | Steam's internal compat tool names | no - a Valve rename would map games to an unknown tool | Steam falls back to its default tool (not reported yet) |
| steam locales (LOCPATH) | host glibc version (cache dir per version) | yes | pv-locale-gen's own fallback |
| Steam ARM64 client fetch | manifest key `bins_linuxarm64_linuxarm64` | only on first run | `steam: Valve's linuxarm64 manifest has no client` |

## Tests (tier1)

- `test/tier1/test-steam-version-proof.py`: each fix against two upstream "versions" - Proton discovery (renamed,
  x86-only, gate excluded, runtime 4 -> 5), the kernelbase overlay over Valve build A then a Proton update to B (stays
  stock + says so, launch still runs) then a row for B (goes back in by itself, `.valve` = B), FEX env options vs
  two FEX binaries, TU_DEBUG vs two Turnip builds, Steam restoring Valve's FEX, fex-compat-tool no longer Python,
  `fex-options-check.py` vs two FEX source trees (a renamed option fails).
- `test-steam-compat.sh`: + renamed ARM64 Proton and SteamLinuxRuntime_5-arm64 still map to the gate.
- `test-steam-iscript-skip.py`: the gate overlay tests read the table from `powos_steam_tools.py`.

## Not done here

- No scheduled re-check, timer or daemon (needs the user's OK): fixes are checked at each Steam start and launch.
- The futex_waitv FEX tool build stays manual (`steam/fex-compat-tool`); upstream FEX-2611 still lacks the probe
  (0003 applies unchanged), so Valve's tool will too.
- KWin/Xwayland stay on the rootfs's Plasma/Xwayland; moving them is a rootfs bump.
