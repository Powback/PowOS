---
name: powos-pet
description: Load when changing or debugging the PowOS pet (shell/ui/pet*.tsx, pet.css, apps/pet, `powos pet`, system/PetOverlay.kt) - its architecture, the body interface, review renders and the mistakes already made.
---

## Architecture
- **local.pet** (apps/pet): SpacetimeDB module `local-pet`. Table `pet` (row 0: name, mood + mood_until, energy/fed, xp/level,
  overlay, goto_target/goto_say/goto_at) and `said` (last 50 lines). Reducers say, set_mood, feed, cheer, rename, hush,
  set_overlay, goto. Times are Unix ms (u64 -> bigint in JS). The shell reads it through shell/vendor/local-pet.js (bindings
  bundled from apps/pet/ui/bindings; regenerate after every schema change, see VERSIONS).
- **CLI** lib/apps/powos-pet (`powos pet say|mood|feed|name|status|log|hush|goto|overlay`): reducers over the HTTP API with
  the CLI's spacetime token. Deployed by powos-deploy.sh (unit units/phone/pet-cli.json).
- **Shell layer** shell/ui/pet.tsx: `Pet` mounts only while local.pet is in the registry (installedApps). The state is a computed
  over live data: spool agents (agents.ts useAgents), the work board (powos-agents `work`), ai.mail (deploy notes = from
  "deploy"), window errors, battery, night/idle, chat. Priority: forced > listening > module mood > happy > worried > looking >
  hungry > eating > working > sleepy > idle. Bubbles: say(); deploy notes and agent mail as they arrive; manager replies
  nobody saw. Tap = talk in place (dictation through bar.tsx's re-export -> askQueued); bubble tap -> openAssistant();
  long press -> openPanel("ai") or page -1. PetOver = the same body in the overlay window (app.tsx mode "petover").
- **assistant.ts**: openAssistant({listen, autosend, text, context}) and askQueued (PowosAiChat.send drops sends mid-turn).
- **Overlay** system/PetOverlay.kt: TYPE_STATUS_BAR_SUB_PANEL 84 dp window; hidden on home/keyguard/shade/assist/IME/full
  screen; native drag + glide to a side, 10 s peek (half off-screen, 70%); tap = assistant, hold = ask about this screen.

## The body (shell/ui/petbody.tsx)
`<PetBody handle={ref}/>` -> `BodyHandle { push(vx,vy) (clamped +-5), squash(0..1), stretch(0..1), look(x,y|null), blink(), pulse() }`.
A spring rim of 10 points drawn as one path; rAF only while it settles; eyes on their own composited layer. States are CSS on
`.pet[data-state]` (pet.css): a pose on `.pet-inner` eased once, a finite move on `.pet-body`, face parts toggled. Fill is
`--pet-fill`: a quiet tint (accent hue in the foreground, oklab) - never the raw accent.

## Pitfalls (all happened)
- Shipping an APK from a stale worktree: ship-apk resets every shell override after install, so an old build wipes everyone's
  newer shell work. Ship only from the origin tip with origin's ship-apk.
- "The old orange smiley": the v2 body was there; an 82% accent fill in Matte Black (orange accent) looked like v1. Check the
  phone's theme (read --color-* over CDP) and render in it.
- Overlay never showed: a small window's own insets have no status bar, so `!isVisible(statusBars())` called every app full
  screen. Full screen comes from ShadeHost.statusBarShown.
- Module columns added but the module not republished: the shell's bindings expect them; republish with `powos app install`.
- A pushed file importing a file not on the phone (404) kills home; push every new import with it.
- Inbox: `powos comms inbox --agent pet` CLEARS it - read with `--peek` or `watch` first.
- The mock home's joined tiles: an edge under another tile isn't a floor (petperch trims it).

## Review and test (all in the repo)
- States: `shell/dev/petshots.sh [OUT]` (env PET_THEME=matte|gruvbox|kanagawa, PET_STATES, PET_SCALE, PET_PERCH) - a close-up per
  state + OUT/sheet.png, and each state's rest check (running animations must be 0). Review hooks in the page:
  `window.__pet.force(state)`, `.perch(key, fx)`, `.goto(where, say)`, `.edges()`.
- Movement (powos-pet-physics's): `shell/dev/petrec.mjs` (frame strip + per-frame displacement + rAF at rest).
- Whole shell renders: `shell/dev/gate.sh --shots DIR`; contact sheets of two runs: `shell/dev/sheet.mjs`.
- Gate: `shell/dev/gate.sh --tree`; ship: commit, rebase, push origin, `shell/push.sh --vpn --note "..." <files>`.
- Review upload: `tools/phone/adb.sh push FILE /data/local/tmp/`, then `tools/phone/root.sh` a script that moves it to
  /data/powos/root/home/powos/pet-review/<step>/ and chowns it to the app's uid. Mail the manager and read its answer as the
  session user: `tools/phone/user.sh SCRIPT` with `powos comms send manager "..." --from pet`, then
  `powos comms watch --agent pet --timeout 2400` (one held call; `comms inbox` without --peek CLEARS it).
- Device (read-only): `tools/phone/cdp.sh eval home '<js>'` on `.pet` (outerHTML, getComputedStyle fill, data-state);
  `tools/phone/adb.sh shell "dumpsys window windows | grep -A30 'PowOS pet}'; logcat -d | grep PowosPet"`;
  `tools/phone/cpu.sh 60` for CPU; a screencap only after one `tools/phone/idle.sh --wait 120 MAX_S`.
