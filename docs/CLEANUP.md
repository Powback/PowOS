# PowOS cleanup roadmap (living checklist)

Started 2026-11-24 by the cleanup sweep (board task #51, the user 11-23: "once all the agents are done we should
probably do a sweep and clean up and streamline and lint the code properly"). PowOS is feature complete, so this is
the polish phase. Tick an item in the commit that does it, and add a line under "Done" with the SHA.

Each item: **why** / files / risk / suggested owner (the expert whose skill covers the area). Ordered by value / risk:
cheap and safe first, behaviour-touching refactors last. None of these change what the user sees unless noted.

## Next

- [x] **Python shared module for the `lib/apps/powos-*` and `lib/ai/agents/*` CLIs.** Why: `owner_conf` is pasted into
  powos-rootsh:59, powos-terms:45, powos-agents-cli:2314 and powos-places:112, and the copies have drifted. The
  powos-places copy skips the `$KEY` env override and `/etc/powos/owner.conf`, which looks like a real bug. `token()`
  is byte-identical in powos-agents-cli:188 and powos-pet:59 (and equivalent in powos-progress-cli:43). `http`, `die`
  and `opts` have also forked, with different timeouts and 404 handling. Files: a new `lib/powos_py/common.py`
  installed next to them (Containerfile, the phone's powos-core map, a units claim) plus those CLIs. Risk: medium,
  because the import path has to work on x86, the phone and the Mac. Owner: agents/board expert.
  Done: `lib/powos_py/common.py` holds `owner_conf` and `token`; the six CLIs import it (powos-places now honours
  `$KEY`, /etc/powos/owner.conf, last-wins and quotes; test-places.py pins it). `http`, `die` and `opts` stay per
  tool: their prefixes, timeouts, 404 messages and flag grammars differ on purpose.
- [ ] **Shared `verify/base.sh` for the phone checks.** Why: 52 of 239 `tools/phone/verify/*.sh` paste the same `sh_()`
  line, 27 define `hcall`/`hcall_once` (8 are identical, 16 are forks), and about 78 re-define `chk/fail/pass/log`.
  Only 42 source `e2e-lib.sh`, and there are 10 separate `*-lib.sh` files. Files: tools/phone/verify/*. Risk: medium,
  because e2e-lib's `sh_` tries `sess_sh` first, so collapsing onto it changes behaviour. Start with a thin base that
  has only the identical forms, then add a lint that refuses a re-definition. Owner: powos-phone.
- [ ] **Put `AREAS`, `byArea`, `ago` and the per-app `useApp` into `shell/ui/shared/` (the f179 lib).** Why:
  `apps/{health,pet,powos-progress,sketch}/ui/lib/app.ts` are the same file apart from `DATABASE` and the doc comment.
  `AREAS` is byte-identical in apps/powos-progress/ui/lib/progress.ts:50 and shell/ui/aiboard.tsx:393, and
  progress.ts:54 carries a HACK that asks for this. `areaOf` and `ago` have three different versions. Files: those
  files plus `apps/build.sh` (the `@powos/shared` alias exists). Risk: low for `app.ts`/`AREAS`/`byArea`. `areaOf`
  and `ago` change behaviour, so pick one version and run a design check. Owner: powos-shell.
- [ ] **Run CI's shellcheck over every tracked .sh file, not only bin/, lib/, build/ and sources/ (142 of 773).** Why:
  tools/, targets/ and test/ are never linted. At error level today the only real finding was SC1087 (fixed
  bd11ae5e). The other 43 errors are SC2148: sourced or pushed snippets with no shebang (config/etc/profile.d/*,
  tools/phone/verify/bf-*.sh, *-lib.sh). Add `# shellcheck shell=sh|bash`, but not at line 1 where a header is parsed
  (`# lanes:` in bf-*.sh is read by the queue). vadb-keepalive.sh:11 is a parser false positive and needs a
  disable directive. Files: .github/workflows/build-test-publish.yml, test-complexity.sh's file list, those snippets.
  Risk: low. Owner: tools/CI.
- [ ] **A ratchet for lines over 120 characters.** Why: about 18,100 code lines in 1,641 files are over 120.
  Comment-only lines in bin/, build/, lib/, test/ and tools/emu were reflowed (d9057098); the rest is code. The worst
  files: shell/dev/gate.mjs (2,137 lines), shell/ui/shell.css (567), shots.mjs, WebWindows.kt (412), ShellBridge.kt,
  webwindows.tsx and tools/phone/ship.sh. Reflowing it by hand is churn that conflicts with live work. Instead, add a
  per-file count baseline (like complexity-baseline.json) that only shrinks, and wrap when a file is touched anyway.
  Risk: low. Owner: tools/CI.
- [ ] **Stale docs (trivial renames).** CLAUDE.md:159 still says "(on the integration branch — see above)".
  CLAUDE.md:67 has an empty "Hard rules" heading. AGENT-HANDBOOK.md:190 and :385 give `.claude/worktrees/` runner
  paths, which are now `~/pw`. AGENT-CARD.md:46 says "stale master". powos-phone SKILL.md:115-117 and :207 give
  `.claude/worktrees/verify-runner` (queue.sh:64,73 uses `$POWOS_RUN_ROOT`). ARCHITECTURE.md:227 names
  `extensions/<x>/usr/bin` paths, but the sources are `sources/<x>/build.sh`. README.md:486, REFERENCE-X86.md:680
  and ARCHITECTURE.md:176 hand-list tier-1 tests, which the rule forbids, so point them at run-all.sh.
  BUILD-GUIDE.md:267 links an `overlays/README.md` that doesn't exist. REMOTE-POWOS.md:111 describes `powos hosts`,
  which isn't dispatched. Risk: none. Owner: docs, or whoever touches the file next.
- [ ] **A docs path check.** Why: most of the drift above is a backticked path or verb that no longer exists. A tier-1
  test, like test-cli-arms.sh, would check that every backticked repo path in CLAUDE.md, the handbook, the agent
  card and the skills exists. Risk: low. Owner: tools/CI.
- [ ] **Consolidate the docs.** Why: the agent-process rules are written 3-4 times (CLAUDE.md, AGENT-CARD,
  AGENT-HANDBOOK at 800+ lines with migration history, MAP.md), and CLAUDE.md:1-41 is a verbatim copy of
  docs/projects-CLAUDE.md. There are topic clusters with no single current doc: Windows (WINDOWS, WINDOWS_FIX_PLAN,
  WEB_WINDOWS, REMOTE-WINDOWS, DUAL-BOOT-VM, DUALBOOT-DESKTOP-SPEC), Desktop (DESKTOP-NATIVE, DESKTOP-KWIN-NATIVE,
  DESKTOP-SHELL, DESKTOP-WEB-SHELL, NATIVE-SYSTEM-UI, NATIVE-GLASS), HOMEFS-*, and MODDING-SPEC/-V2. Dated reports sit
  among the reference docs, and naming is mixed (UPPER-KEBAB, lower-kebab, SNAKE). Plan: one current doc per topic,
  a `docs/archive/` folder for history and reports, one naming style. README, ARCHITECTURE and REFERENCE-X86 overlap:
  fold ARCHITECTURE into REFERENCE-X86. Risk: low, but links move, so grep and fix the references. Owner: docs.
- [ ] **Audit lib/mods as a unit.** Why: it has the most dead API surface. `harness_dispatch` (harness.sh:1095; game.sh
  calls `harness_${verb}_cmd` directly), `nexus_key_validate`/`nexus_is_premium`/`nexus_updated_mods`
  (nexus-api.sh:40/52/141), `mods_manifest_read` (core.sh:182), `_mods_mount_dir`/`mods_deploy_set_steam_launch`
  (deploy.sh:60/213) and `mods_vortex_bin`/`mods_loadout_id_for` (install.sh:133/491) are each called by nothing
  (`git grep -nw` shows only the definition). An older dispatch layer was replaced by game.sh's `powos_game_call`
  without pruning. Removing these one by one can orphan helpers further down (`harness_help`, `harness_history_cmd`)
  and trips test-mods-core's help/dispatch invariants, so do it as one pass. Also unreferenced: games-sync.sh
  `gsy_config_get`/`gsy_local_sync_sources`, ai-healer.sh `ollama_generate`, and mobile.sh `is_excluded`,
  `copy_layers_to_ram`, `mobile_usage`, `get_packages_with_groups` (medium confidence: test-mobile.sh sources the
  file). Risk: medium. Owner: powos-games.
- [ ] **powos-cachefs.py:545 `triggered = True` is never read.** The trigger file is meant to force a flush, but the
  loop flushes on its normal path either way. Check whether a trigger-file flush should skip the "nothing dirty"
  shortcut, then fix it or drop the variable. Risk: low, x86 only. Owner: x86/kernel & system.
- [ ] **Shell layout.** `shell/ui` is about 150 flat files plus `shared/`. `shell/apps/` holds shell-side app plumbing
  while `apps/*/ui/lib` holds app code. Group `shell/ui` by surface (home, shade, ai, windows, pet, dock) once the
  window work has settled. Every move is a gate-scope.map and import churn, and moves conflict with live branches,
  so do it in one quiet window. Lib logging helpers also differ per module (`zn_`, `bm_`, `doc_`, `gsy_`, `log_ai`,
  each with its own colour echo); `lib/common.sh` could own them. Risk: medium (churn). Owner: powos-shell.
- [ ] **Wire in or delete `tools/agents/worktree-gc-test.sh`.** It is a self-contained test that no runner calls.
  Move it to test/tier1 so run-all.sh picks it up. Risk: low. Owner: agents/board expert.
- [ ] **Behaviour-level fixes the sweep found but didn't make (no behaviour changes in the sweep).** game-resize.sh
  keeps `BUDGET_S=${BUDGET_S:-300}` and ignores the `QUEUE_BUDGET_S` that queue.sh exports (friction f519): read it
  as the default. controller.sh `_ctrl_cmd_list` inlines the readout awk that the removed `_ctrl_current_pct` had.
  Owner: powos-phone / powos-games.

## Friction (open list on 2026-11-24, 100 items) mapped

- [ ] **Auto-logged ship/verify failures are keyed by SHA, so they never deduplicate.** About 45 of the 100 open items
  are one per ship or check run, for example f49, f446, f315, f335, f471, f479, f478, f296, f511, f385, f254, f416,
  f466-f522 ("ship <sha> FAILED ...") and the "check X was SKIP" family (f320, f518, f482, f484, f454, f448, f517,
  f504, f503, f502, f501, f500, f495, f493, f492, f491, f487, f486, f483, f474, f473, f472, f469, f457, f456, f455,
  f453, f452, f451, f450, f447). Fix: ship.sh and queue.sh log with the failing step/kind in the title and the SHA in
  details, so "device window check: timeout" counts up instead of making a new row. Owner: powos-phone (ship).
- [ ] **Permission-refusal friction is titled with the tool call's description verb, not the command.** f74 "cd",
  f21 "Read", f326 "Inspect", f303 "Check", f442 "ssh", f444 "cat", f207 "Land", f77 "Run", f409 WebFetch, f59
  "mkdir", f485 "Find", f26 "Add", f510, f508, f496, f494, f490, f489, f477, f464, f458 and f449 split one cause
  (agents running outside their allowed tools) into 22 rows. Fix: powos-agentsd keys the title on the first command
  word, and the briefs (agent-brief template) list the allowed tool forms. Owner: agents/board expert.
- [ ] **f30 (x856) gate fails under Mac load.** This is the gate's long-standing flake. The gate now runs on .58 by
  default (POW_JOB_CONTEXT), so recheck the rate since 11-10 and close it with that commit if it has stopped.
  Owner: powos-shell.
- [ ] Single items: f514/f513 (git stash is shared across worktrees: land.sh should tell agents to commit WIP, not
  stash), f521 (fresh worktree has no PowStream native staging; build-inputs-cache), f524/f525/f523 (emulator lane
  builds fail, so the emu checks are INVALID), f515/f509 (NAS `/mnt/nas/cdn/powos` is not writable from the Mac/.58),
  f463/f462 (build slot: gradle journal lock, silent alarm kill), f461 (bin/powos in the retired powos-multiplatform
  tree, `self: command not found`: recheck now that it's main), f519 (above).
- [x] f465 tier1.sh via offload.sh refused outside $HOME: offload.sh was removed in 9fcbf3a3 (tier1 runs through
  tools/jobs/job.sh). The sweep's own tier-1 run from ~/pw/cleanup-sweep on .58 is the evidence.

## Done (the 2026-11-24 sweep)

- [x] Complexity ratchet: 5 budget entries lowered to the measured values (93ce374d).
- [x] Python shared module: `lib/powos_py/common.py` (owner_conf, token) for 6 CLIs; powos-places now honours
  `$POWOS_FILE_PLACES` and the rest of the owner config's rules (66398b00).
- [x] Python lint: ruff F401/F541/F841, 34 findings -> 1 (a6431c6d; the cachefs item above is what remains).
- [x] 49 comment lines over 120 reflowed, and the emu.sh usage range fixed (d9057098; self_push length fix 470b54df).
- [x] shellcheck SC1087 in td-launch-phone.sh (bd11ae5e).
- [x] Dead code: 8 shell exports, 2 controller readouts and 1 verify helper, each with grep proof (fbdc07dd).
- [x] Duplicate `clamp` in petai.ts now comes from petphys.ts (cfd644c8).
- Tier-1 failures that already fail on origin/main (checked on a clean origin checkout, not this sweep's):
  test-check-shell-pitfalls (switcher-canvas-dock.sh:26, ww-keyboard.sh:23 sigpipe), test-noroot-app-base (2
  build-app staging cases), test-ship-pipeline (ship-queue-test rooted-beside-APK cases).
- Clean already: tsc, style lint, design lint, shell complexity lint, cycle lint (2 allow-listed), Kotlin
  compile-check, bash CC/length ratchets, HACK registry (327 markers = 327 rows).
