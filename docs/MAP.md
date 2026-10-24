# Repo map

Built from `git ls-files`, the skills' "Latest hand-off" sections and the handbook. Read this before grepping the
tree cold. Full detail per subsystem lives in the named skill's SKILL.md — load that, not the whole handbook.

## Shell UI (web, Preact+TS)
- `shell/app.tsx`, `shell/state.ts`, `shell/bridge.ts`+`shell/types.ts` — the page, state, Kotlin bridge.
- `shell/ui/*` (85 files) — panels/widgets (drawer, shade, control center, switcher, desktops, nativeglass.ts).
- `shell/ui/shared/` — framework-neutral building blocks a PowOS app's own UI can import too, as `@powos/shared/*` (`apps/build.sh` mounts it read-only + an esbuild alias, `apps/tsconfig.app.json`/an app's own `ui/tsconfig.json` mirror it for `apps/typecheck.sh`); e.g. `pending.tsx` (PendingState/steps, ProgressRing, StepList, optimistic — fixed friction f179, was forked into `apps/app-api`).
- `shell/theme.css`, `shell/DESIGN.md`, `docs/DESIGN-LANGUAGE.md` — material/tokens.
- `shell/dev/gate.sh`, `shell/dev/shot.sh` — headless build-check + renders.
- Build/check: `shell/dev/gate.sh --tree` (tsc + headless boot of every page).
- Ship: `shell/push.sh --vpn --note "..." <files>` (phone), queued device check below.
- Device check: emu/phone — `tools/phone/verify/queue.sh add --dev auto <task> <check.sh>` (most shell-only checks run `emu + phone`, see handbook's lane table).
- Skill: powos-shell (material/shade/CC, drawer, widgets, gestures), powos-windows (switcher), powos-data (chat).

## Android app — Kotlin (windows, system services)
- `targets/android/app/app/` — the Kotlin source (system/WindowFrames.kt, WindowFrame.kt, FreeformTasks.kt,
  shell/GlassBlur.kt, ShellBridge.kt, ShellOrigin.kt, Speech.kt, AppWindows.kt, NavGesture.kt, RecentsTransition).
- `targets/android/app/hidden-stubs/`, `HiddenApi.kt` — hidden-API exemptions.
- Build: warm builder (auto via ship-apk.sh) or cold `make build` (android-app-dev). Compile-only:
  `tools/phone/compile-check.sh` (throwaway builder, never touches shared APK output).
- Ship/install: `tools/phone/ship-apk.sh --note "..."` (ONLY way to build+install; never build-app.sh+install by hand).
- Device check: phone only for hardware/fold/games; most window/app UI checks run emu+phone (see handbook table).
- Skill: powos-windows (windows/recents), powos-shell (widgets, bridge-security), powos-android-dev (unowned Kotlin).

## KWin / Linux packages
- `targets/android/pkgs/kwin/` (PKGBUILD + 0001..00NN patches), `pkgs/steam`, `pkgs/xwayland-kgsl`, `pkgs/breeze`, etc.
- Write a patch: `targets/android/pkgs/kwin/src-tree.sh` (never hand-apply 0001..00NN).
- Reserve a number: `tools/agents/pkg-claim.sh reserve-patch|reserve-pkgrel targets/android/pkgs/kwin`.
- Build: `targets/android/build-pkgs.sh kwin` (inputs/outputs live in shared cache `~/.cache/powos-build-inputs`).
- Install/check: `tools/phone/verify/pkg-install.sh <pkg>` or `kwin-up.sh MIN` (queue ahead of a feature check, same task).
- Skill: powos-windows (KWin patches section, desktop), powos-games.

## Linux session / rooted
- `targets/android/rooted/` (rooted.sh, powos-session.sh, powos-run.sh, powos-deploy.sh) — chroot of `/data/powos/root`.
- `targets/android/session/` (first-session.sh, plasma/*, powos-plasma-bridge, powos-output-scale).
- Deploy: `PATH="$PWD/tools/phone/bin:$PATH" targets/android/rooted/rooted.sh deploy --note "..."` (plain adb needs that PATH prefix).
- Check: phone only — `tools/phone/verify/linux-session.sh`, `kwin-up.sh`, `linux-float.sh`, `linux-touch.sh`.
- Skill: powos-windows, powos-games.

## Verify checks
- `tools/phone/verify/*.sh` (131 scripts), `queue.sh` (the one queue), `e2e-lib.sh`/`bf-lib.sh` (shared helpers).
- Queue a check: `tools/phone/verify/queue.sh add [--dev emu|auto] [--close] <board-task> <script> [args]` (returns at once).
- Build/compile: n/a (bash scripts) — lint with the repo's shellcheck-equivalent if present; no separate build step.
- Check command: the script itself, run through `queue.sh`; never run a device-touching check by hand outside a free window.
- Skill: powos-phone (the how-to: idle windows, journeys, frame-stepping, gesture-monitor dup checks, FAIL reading rules).

## Emulator lane
- `tools/emu/emu.sh` (start|stop|status|reset|create|install|remove), `tools/emu/testwin/` (Calculator test client).
- Build/prep: `tools/emu/emu.sh create` (~10 min, once) then `start` (boots or reuses `powos-ready` snapshot).
- Check: `tools/phone/verify/queue.sh add --dev emu <task> <check> [args]` or `--dev auto` to let lane detection pick;
  run by hand: `POWOS_DEVICE=emu LOCK_HELD=1 tools/phone/verify/<check>.sh ...`.
- Skill: powos-phone (lane table + `# lanes:` header convention), powos-games (what's phone-only: Steam/fold/kernel).

## Ship
- `tools/agents/land.sh "msg" -- <paths> [--task <id> --step "..."] [--ship "note"] [--queue <check args>]` — THE
  one call: commit, rebase, push, move board task, request ship, queue a check. End your turn after it.
- `tools/phone/ship.sh` (request/status/pause/resume/done_req), `shell/push.sh`, `tools/phone/ship-apk.sh`.
- Build: implicit in ship-apk.sh (warm Gradle builder) / push.sh (gate.sh).
- Check: queued automatically by `land.sh --queue`, or `queue.sh add` separately.
- Skill: powos-phone (shipping summary, incl. verify), handbook "Shipping" section (full detail, rarely needs re-reading).

## Board / comms / friction
- `lib/ai/agents/powos-agents-cli`, `powos-agentsd`, `lib/ai/comms/comms.sh`+`comms-mcp.py`, `lib/ai/manager/manager.py`.
- `tools/agents/friction` (CLI), `tools/agents/board-sweep.sh`, `tools/agents/retro.py`.
- Board: `powos agents task add|set|list|done` (phone) / `python3 lib/ai/agents/powos-agents-cli task ...` (Mac relay).
- Comms: `powos comms send|watch|inbox --peek|notify|quiet`.
- Friction: `tools/agents/friction add --area <a> --kind <k> "<title>" --repro "<cmd>" --details -`.
- Check/test: `python3 test/tier1/test-agents.py`, `test-board-truth.py`, `test-comms.py`, `test-comms-fulltext.py`.
- Skill: powos-data.

## App API
- `apps/app-api/` (powos-app.json, ui/lib/{action,add,api,files,recordings,rules,runtime,ui}.tsx), `tools/app-api/`.
- Build: `apps/build.sh app-api`; publish/install: `apps/install.sh app-api install|publish --note "..."`.
- Check: emu+phone — `tools/phone/verify/app-api.sh`, `e2e-appapi.sh`.
- Skill: powos-data (App API hand-off lives there), powos-shell (islands).

## STDB modules
- `apps/<app>/` (Rust module, `src/lib.rs`), `shell/vendor/<db>.js`+`.d.ts`+`VERSIONS`, `shell/apps/stdb.ts`.
- Regenerate bindings: `apps/vendor.sh <app>` (must reproduce committed files byte-for-byte).
- Publish: `ADB="docker exec powos-vadb adb" apps/install.sh <app> publish --note "..."`.
- Check: `tools/phone/bindings-check.sh --no-publish`; tier-1 `test/tier1/test-bindings-check.sh`.
- Skill: powos-data.

## Games / Steam
- `targets/android/steam/` (fex-compat-tool, sysvipc), `targets/android/pkgs/steam`, `targets/android/kernel/`.
- `tools/phone/verify/bf-*.sh` (Broforce suite), `td-launch.sh` (Teardown), `tools/phone/verify/steam-*.sh`.
- Build kernel: `STOCK_BOOT=<img> JOBS=12 ./build-containers-kernel.sh` (~2h); test boot via fastboot (see skill).
- Check: phone only (HW/GPU) — `queue.sh add --close <task> bf-run.sh` / `bf-pacing.sh <mode>` / `td-launch.sh`.
- Skill: powos-games.

## Manager / sandbox
- `lib/ai/manager/manager.py`+`.sh` (chat turns, inbox injection), `lib/ai/sandbox/` (engine/, caps.ts, job.ts, main.ts).
- Build: sandbox is TS (`lib/ai/sandbox/package.json`); no separate compile step noted — runs via manager.
- Check/test: `python3 test/tier1/test-manager.py`.
- Note: the sandbox runtime is capped at 48 MB — never run a model in it (powos-data hand-off).
- Skill: powos-data (manager inbox section); no dedicated sandbox skill — see powos-android-dev/general for gaps.
