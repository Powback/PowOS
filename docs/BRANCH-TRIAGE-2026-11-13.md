# Branch triage 2026-11-13

Every commit on the 48 remote branches that `git cherry` (patch-id) still showed as not in the integration branch
(`worktree-powos-multiplatform`; since 11-13 `main` is the same target and the only branch). One row per `+` commit.
Decisions: **landed** (cherry-picked onto today's code, checked, landed - sha on the integration branch/main),
**superseded-by** (the same change or intent is already in, under that sha), **dropped** (obsolete, other project, or
scratch - reason given). No branch was deleted; pruning is the coordinator's after review.

Totals: 56 commits - landed 8, superseded 41, dropped 7.

Follow-ups: 88c1527c (gpu-fan power profiles) needs `sudo bash hosts/gpu-195/gpu-fan/install.sh` on gpu-195;
9c431b8b (no-root base catch-up + toolchain) and 9387e617/9d2f683c/e16dc15b need a ship - 9c431b8b's ship request
was refused mid-switch to `main` ("HEAD isn't on origin/main") and must be re-requested.

| branch | commit | decision | reason |
|---|---|---|---|
| worktree-windows-fix-plan | 4d03fed7 | landed 62bd6922 | still valid: queue.sh counted envskip/SKIP results as PASS; conflict with held-screen wl_done resolved |
| agent/qa-perf-verify | 51569456 | landed 9387e617 | e2e own-jobs round fix, rc 3 for interrupted parts, react-scan slowCommits in traces + trace-fields check, util timeout seconds; dropped its ww-stop unfold hunk (superseded by f122ba47 # screen: inner header) and its rec-light poll hunk (board-look-more already reworked to micwait/recwait) |
| agent/prepush-offload | a1cd6899 | dropped | obsolete: offload.sh and its .58 shared.git mirror were removed by 9fcbf3a3 (jobs: one remote path); no push goes there any more |
| agent/nonroot-appmaking | 7ece568f | landed 9c431b8b | gh#13 base catch-up + dev-pack Rust toolchain + UI-only remove were missing; the commit also carried stale reverts of the tools/jobs remote path (gate.sh, tier1.sh, compose.yml, apk-job.sh, CLAUDE.md/HANDBOOK text) - those hunks left out; tier1 x3 + JVM PowosUpdatesTest pass |
| agent/devices-signin | 4ef57f4d | landed e16dc15b | HACK fallback still in fleet_login.py; authority now returns tenant on /auth/check (verified live) |
| agent/devices-signin | 82ec3b0b | landed 9d2f683c | phone-as-approver not in integration; main.tsx conflict with realmAgentOf (2fb2a3e3) resolved; gate 353/0, JVM PowStationTest ok |
| agent/devices-signin | 5b054be7 | landed 9d2f683c | KDoc fix folded into the same landing |
| gpu-195/pool-yield-and-power | 6c8b21f8 | landed 88c1527c | idle power profile not in integration nor on gpu-195 (no /etc/powos/gpu-fan-mode there); needs `sudo bash hosts/gpu-195/gpu-fan/install.sh` on gpu-195 to take effect |
| codex/swift-local-trial | 0eab32b2 | dropped | WIP save of the 10-26 llm-pool/voice-gateway/bench work on gpu-195; that stack now lives in its own repo Powback/local-llm-stack (flash-next.json, strata-voice-aware.py there) - project boundary; not PowOS |
| agent/unity-load | d28fb313 | dropped | two .scratch-ul/ scratch scripts with absolute paths into a removed worktree; not product code |
| agent/taskframe-on | 5e0424e4 | dropped | WIP flipping the Android freeform in-task bar on by default; the window design moved to web windows (WEB_WINDOWS.md, no overlay windows 10-30); unverified flag flip |
| agent/resize-jank-3 | 3fb03d4a | dropped | WIP RS5c follow-up with __rs5Old A/B dev flags in webwindows.tsx/gate.mjs; RS5c landed as 879dd5e5 and LH1 fe1f8965 replaced the per-move mask writes |
| agent/oti-cap | 937af517 | superseded-by 3ae17245 | bf-pacing INPUT=touch\|key\|pad + oti lines landed in bf-60-cap |
| agent/oti-cap | 7ca5b29f | superseded-by 3ae17245 | bf-lib input_inject + bf-checker INPUT landed in bf-60-cap |
| agent/oti-cap | def48b1d | superseded-by 3ae17245 | broforce-fps.md touch-idle section (with RESULTS_PLACEHOLDER) - the landed doc has the measured results |
| agent/noroot-fixes | e6fdb53a | superseded-by b2cb7fca + aed55ab0 | tmux in base, real_command, control dir landed in b2cb7fca; board/no-route + owner-conf links + system-tier message reworked in aed55ab0 (fresh device runs on its own) |
| agent/powauth-devices | 80c75f33 | dropped | documents the PowAuth device-principals/OpenBao plan; owner 11-07 streamline call: not-deployed device layers (PowAuth fork, forwardAuth, claude-auth identity map, OpenBao) stay undeployed and unmerged (11-09: still no PowAuth fork); its unit edit would also mismatch the deployed powos-enroll |
| agent/unity-sync | 9a3e4a4e | superseded-by b472ecca | same doc commit landed (rebased) |
| agent/load-uploads | 9a3e4a4e | superseded-by b472ecca | same commit as unity-sync |
| agent/fex-mono-start | 0ab27b2f | superseded-by 92a3b9a4 | same doc commit landed |
| agent/image-slim | 3f38ae5e | superseded-by 1e0eea03 | same change landed |
| agent/bf-fps-fex | 7ee60928 | superseded-by 712f8571 | same doc commit landed |
| agent/one-bar-reuse | c5a040be | landed 9642f0ec | gate case was never landed; merged beside FX1/IB1 checks, 6/6 one-bar-reuse scenes pass on today's tip (pushed to main: land.sh had switched to main by then) |
| agent/bf-live | c0adadc4 | dropped | 11-03 evidence capture (design-qa png/logs) for xwayland-kgsl 24.1.13-4 DRI3 import refusals; the present path was fixed forward (7cc43709, 24.1.13-8 0013 DRI3 flip on KGSL); stale evidence only |
| agent/worktree-owljar | d801045c | superseded-by 840a5f00 | landed; worktree.sh evolved since (f405 liveness) |
| tile-layout | d99634cd | superseded-by f63e46b9 | same change landed |
| polish1 | e14e20af | superseded-by b1057e94 | same change landed |
| pinch-scale | af2ca644 | superseded-by afd00c8f | same change landed |
| ai-panel | 0be8bdfb | superseded-by 0793443c | same change landed |
| ww-tiles | abc46fc0 | superseded-by bddb4be2 | landed; native tiles later replaced by DOM tiles in ww-element 28001157 |
| ww-pip | 3feb7a8b | superseded-by a356d4f7 | same change landed |
| ww-linux-ime | 1b32f8b3 | superseded-by b12acf75 | same change landed |
| ww-latency | b4cbdf1e | superseded-by 6c967faa | same change landed |
| ww-full | f2758f63 | superseded-by ceb61d3f | landed; native bar code later replaced by ww-element 28001157 |
| ww-element | a34a2e2b | superseded-by 28001157 | same change landed |
| ww-config | c475de59 | superseded-by 2e4c196b | same change landed |
| ue-screen | bbe4a3b6 | superseded-by 0ffd18c3 | Unreal screen size handled by powos-steam-compat's unity-screen wrapper for every Unity/Unreal game (not user_settings.py ini edits); steam is at pkgrel 46 |
| stt-ws | 30a99350 | superseded-by ede163c0 | same change landed |
| split-veil | 27a35b90 | superseded-by df6e2820 | same change landed |
| search-settings | 66612a4d | superseded-by 3e95de3e | same change landed |
| perf-rt | 3275f0cd | superseded-by 5845ec14 | same change landed |
| linux-splash | 778fedd3 | superseded-by 36df40b9 | same change landed |
| linux-csd | a7c508a8 | superseded-by 783abb24 | same change landed |
| handle-desktop | d1943968 | superseded-by 17a445cb | same change landed |
| edit-bar | e878c905 | superseded-by c52413af | same change landed |
| bar-merge | 83eeb85c | superseded-by 2800d804 | landed; native chrome later replaced by ww-element |
| assist-draw | 0025ccd8 | superseded-by 76dd20c6 | same change landed |
| wip/win-verify | ac6b9b0f | superseded-by e64463b8 | landed 31fb1545, reverted e92611b8, relanded combined in e64463b8 |
| wip/win-verify | 91114a1a | superseded-by e64463b8 | landed 22fb8367, reverted 8824cee3, relanded in e64463b8 |
| wip/win-verify | 038c7967 | superseded-by e64463b8 | compile fix folded into e64463b8 |
| agent/shade-film | b571178d | superseded-by 7c5f87fc | same change landed |
| agent/dock-window-menu | 38b36cff | superseded-by add58cfd | landed from this branch |
| ai-page-v2-wip | cb5872b9 | superseded-by baff5955 | WIP start of AI page v2; the finished page landed in baff5955 (no dev/sample-board.json fixture needed) |
| feat/phone-proton | edce7196 | superseded-by 75c16fd8 | same change landed |
| feat/phone-proton | 224f41dd | superseded-by 914a8958 | same change landed |
| feat/phone-proton | 8e6c35d6 | superseded-by a5d8daf5 | same change landed |

## wip/2026-11-10-platform (96b5c471, uncommitted 11-10 work; base ea5dd0d3)

| file | decision | note |
|---|---|---|
| lib/apps/powos-platform | LAND | pass-through commands (down/logs/ps) keep the declared host even when policy is invalid; unreadable model/unknown host fails instead of silently running on the hub |
| test/tier1/test-platform.py | LAND | tests for the above; legacy-model pass-through test now uses a readable model without x-pow |
| docs/PLATFORM.md | LAND | "Placement failure behavior" section |
| units/mac/vm-route-mac.json | LAND | records the 11-10 ping + pow-col0-heal fallback (PowStation 2ba5b78, deployed) |
| units/mac/disk-guard-mac.json | LAND | new unit for the deployed com.powstation.disk-guard daemon (PowStation 2ba5b78); purpose updated for container shedding (PowStation 0a9546a) |
| tools/jobs/compose.yml | SUPERSEDED 1e510228 | main sets `cgroup_parent: nomad.slice` unconditionally (harmless parent dir on the hub) |
| tools/jobs/job.sh | SUPERSEDED 1e510228 | POW_JOB_CGROUP_PARENT plumbing not needed with the unconditional parent |

## Local-only branches (never on GitHub; triaged 11-13)

| branch | commit | decision | note |
|---|---|---|---|
| agent/f206 | a1602416 | LAND 741762b6 | wait-guard refuses file-writing Bash (sed -i, perl -i, cp/mv/rm/ln/tee/patch, git apply, > / >> file, python open 'w') in the shared/runner checkouts for subagents. Adapted: with no `cd X &&` prefix the hook input's own `cwd` decides (was: never), and `--rm` / `format-patch` no longer count as rm / patch; tests added for both |
| agent/land-ship | 6a980e47 | SUPERSEDED 87a3d9a1 | auto ship request for shell/targets/apps/lib/tools/app-api paths + `--no-ship` landed there |
| agent/owl-measure | cb8e60fd | LAND 41f369fa | OWL 9 `measure(text, size, bold)`: TextMetrics (Measure.kt), Host.measure, widgets.metrics bridge call, ShellWidgets/WidgetText, `owl trees` metrics, preview measure pass, 50-weather / 80-system-info / 97-now-playing sized by it, LangTest. Adapted: OWL_FONT stays monospace (HACK kept, registry row updated) because the other ~15 example widgets still count characters at 0.6 em; fontMetrics() measures the face OWL_FONT draws in, so measure() is right in either face and the switch to --font-body is one line once every widget measures; TextMetrics.of split for the detekt complexity limit |
| local-snapshot-1109 | 82a58235 | SUPERSEDED (77 of 96 files identical on main) + LAND 4 | file by file below |
| local-snapshot-1109 | 18604586 | SUPERSEDED d7669b23 | both files identical on main; the enroll unit regenerated now (`pow-compose units`: drops the duplicated `-p powos-enroll` in its stop command) |

82a58235 file by file (the 77 not listed are byte-identical on main: bin/pow-compose, config/*, examples/platform-contract/*,
units/phone/platform-adapter.json and the rest of units/powstation/*):

| file | decision | note |
|---|---|---|
| CLAUDE.md, bin/powos, docs/PLATFORM.md, lib/apps/powos-platform, lib/apps/powos-units, test/tier1/test-platform.py | SUPERSEDED 9a60cf58, d7233a2d, 1d859f24, 24d17470 | main carries the snapshot's content and later work on top |
| config/platform-fleet.json | SUPERSEDED d7669b23 | main adds powos-enroll |
| units/powstation/{android.android-builder, powdash.app, powflix.epg, powstation.authelia}.json | SUPERSEDED d4e66b8d, 117c9bf0, 7d9524aa, 584945fe | regenerated later on main |
| targets/android/rooted/{rooted.sh, powos-deploy.sh} | SUPERSEDED ba93f67e | snapshot's lines are in main's newer versions |
| targets/android/app/engine/src/main/assets/powos-rootfs.sha256 | DROP | a dirty-tree rootfs pin; main pins its own rebuilt base (6ed9d044 and later) |
| units/powstation/rsi-dashboard.app.json | DROP | a local-llm-stack worktree experiment, not in the fleet manifest |
| units/powstation/powcdn.edge.json | LAND (regenerated) | PowCDN is in main's fleet manifest but had no unit record; written fresh by `pow-compose units`, not copied |
| docs/platform-validation.json | LAND | the 11-03 live validation record (10 projects, live registry, CDN, sleep/wake, auth) replaces the 10-26 repo-only one that still listed PowCDN as not implemented |
| docs/projects-CLAUDE.md | LAND (adapted) | its stale "PowCDN publication remains planned" paragraph now says what exists (NAS folder + read-only cdn.pow), in the current CLAUDE.md wording |
| .gitignore | LAND | `backups/` (untracked in the main checkout) stays out of git |
