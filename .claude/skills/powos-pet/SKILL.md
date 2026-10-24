---
name: powos-pet
description: Load when changing or debugging the PowOS pet (shell/ui/pet*.tsx, pet.css, apps/pet, `powos pet`, PetOverlay.kt) or its movement (petphys.ts, petai.ts, petmove.ts, petperch.ts) - architecture, the body interface, physics/pathing tuning, review renders, and pitfalls already hit.
---

## Quick recipe
- Files: `shell/ui/pet.tsx`, `petbody.tsx`, `pet.css`, `apps/pet` (SpacetimeDB module `local-pet`), `lib/apps/powos-pet`
  (CLI), `system/PetOverlay.kt`; movement: `shell/ui/{petphys,petai,petmove,petperch}.ts`.
- Build/regen bindings after a schema change: `apps/vendor.sh pet`; publish: `apps/install.sh pet publish --note "..."`
  (vendor + publish together, else home shows a DataView decode error - see the powos-data skill).
- Check: states - `shell/dev/petshots.sh [OUT]` (per-state close-up + rest check, running animations must be 0);
  movement - `node --test shell/test/petphys.test.ts`, `shell/dev/petrec.mjs` (frame strip + per-frame displacement +
  rAF at rest). Whole shell: `shell/dev/gate.sh --tree`; contact sheets: `shell/dev/sheet.mjs`. Device (read-only):
  `tools/phone/cdp.sh eval home '<js>'` on `.pet`/`window.__pet` - never force/goto the live pet.
- Land/ship: commit, rebase, push origin, `tools/phone/ship.sh request --note "..."`.
- Friction: `tools/agents/friction add --area <pet|pet-physics> --kind <...> "<title>" --repro "<cmd>"`.

## powos-pet


**Off by default since 2026-10-22 (the user's call):** the module's `enabled` (`powos pet on|off`, Settings > Style >
Pet). Off, `PetSwitch` renders nothing (no element, timer, rAF, physics) and turns the over-apps window off; renders and
the gate turn it on with `window.__pet.on(true)`.

## Architecture
- **local.pet** (apps/pet): SpacetimeDB module `local-pet`. Table `pet` (row 0: name, mood + mood_until, energy/fed, xp/level,
  overlay, goto_target/goto_say/goto_at) and `said` (last 50 lines). Reducers say, set_mood, feed, cheer, rename, hush,
  set_overlay, goto. Times are Unix ms (u64 -> bigint in JS). The shell reads it through shell/vendor/local-pet.js (bindings
  generated into apps/pet/ui/bindings and bundled by `apps/vendor.sh pet`; regenerate after every schema change).
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
- Shipping an APK from a stale worktree wiped everyone's newer shell pushes (the install resets every override). ship-apk
  now refuses anything but origin's tip and re-pushes shell files committed during the build (handbook Shipping).
- "The old orange smiley": the v2 body was there; an 82% accent fill in Matte Black (orange accent) looked like v1. Check the
  phone's theme (read --color-* over CDP) and render in it.
- Overlay never showed: a small window's own insets have no status bar, so `!isVisible(statusBars())` called every app full
  screen. Full screen comes from ShadeHost.statusBarShown.
- Module columns added but the module not republished (twice): home showed `Offset is outside the bounds of the DataView`
  and the pet lost its data. Vendor + publish together (powos-data skill: `apps/install.sh pet publish --note`).
- A pushed file importing a file not on the phone (404) kills home; push every new import with it.
- Inbox: `powos comms inbox --agent pet` and `watch` both CONSUME it - look with `inbox --peek`, keep what you consume.
- The mock home's joined tiles: an edge under another tile isn't a floor (petperch trims it).

## Review and test (all in the repo)
- States: `shell/dev/petshots.sh [OUT]` (env PET_THEME=matte|gruvbox|kanagawa, PET_STATES, PET_SCALE, PET_PERCH) - a close-up per
  state + OUT/sheet.png, and each state's rest check (running animations must be 0). Review hooks in the page
  (headless only; on the live page only `.edges()`, read-only): `window.__pet.force(state)`, `.perch(key, fx)`,
  `.goto(where, say)`, `.edges()`.
- Movement (this skill's pet-physics section): `shell/dev/petrec.mjs` (frame strip + per-frame displacement + rAF at rest).
- Whole shell renders: `shell/dev/gate.sh --shots DIR`; contact sheets of two runs: `shell/dev/sheet.mjs`.
- Gate: `shell/dev/gate.sh --tree`; ship: commit, rebase, push origin, `tools/phone/ship.sh request --note "..."`.
- Review upload: `tools/phone/adb.sh push FILE /data/local/tmp/`, then `tools/phone/root.sh` a script that moves it to
  /data/powos/root/home/powos/pet-review/<step>/ and chowns it to the app's uid. Mail the manager and read its answer as the
  session user: `tools/phone/user.sh SCRIPT` with `powos comms send manager "..." --from pet`, then
  `powos comms watch --agent pet --timeout 2400` (one held call; it consumes - keep its output).
- Device (read-only): `tools/phone/cdp.sh eval home '<js>'` on `.pet` (outerHTML, getComputedStyle fill, data-state);
  `tools/phone/adb.sh shell "dumpsys window windows | grep -A30 'PowOS pet}'; logcat -d | grep PowosPet"`;
  `tools/phone/cpu.sh 60` for CPU; a screencap only after one `tools/phone/idle.sh --wait 120 MAX_S`.

## pet-physics


# The pet's movement - what's known

## Architecture (one position source)
- petphys.ts: pure, no DOM. Fixed DT 1/120 s. step(pet, input, world): carry by its ground rect (<= CARRY 6 px a
  step; a jump > LOST 180 px or a gone rect drops it), back into a shrunk screen (CLAMP 4 px a step), run accel/
  friction, jump (coyote 0.09 s, buffer 0.11 s, cut x0.45 on release), wall jump (held into the wall = climbing jump,
  vx x0.3; else a kick with a 0.07 s steering lock), down-through, gravity (x1.6 falling), X then Y, swept landings.
  World: tiles + pill are ONE-WAY floors (jump up through, land on tops); their sides are walls only at FEET height
  (t+2 .. b-10) - home's tiles sit 8 px apart, full-body walls trapped it; screen sides are walls, its foot a floor,
  the status-bar line a ceiling. MAX_STEP bounds one step (the tests' no-teleport assert).
- petai.ts: the planner presses buttons only. Dijkstra over surfaces; every candidate hop (auto/full jump, drop,
  down-through, standing jump up a tile side, run + climb up the SCREEN side) is PLAYED in a copy of the world with
  the same HopDriver it uses live, so routes only hold hops that land. planner() is a generator (a yield per hop);
  the live Driver runs it in 3 ms slices while the pet already heads the goal's way. A hop ending elsewhere ->
  replan from where it stands (5x), then give up; a route > 20 s is dropped (petmove). offFloor(): the floor is never
  a perch - landing there it goes to the nearest surface (pill preferred).
- petmove.ts: the page side. rAF only while moving: steps at DT, at most 2 steps a frame (a long frame slows it, never
  a catch-up jump), draws interpolated: ONE transform translate3d + scale on .pet (origin at the feet), left/top
  pinned 0 (.pet.phys). Stops after 3 frames atRest() (rect drift < 0.5 px tolerated) or 30 frames still. pause()
  while hidden (drawer/panel/shade): a panel taking home's tiles away used to drop it unseen. Rects from
  petperch.edges(false) for 450 ms after each wake/layout event, cached otherwise.
- petperch.ts: the world rules. Tiles of the page showing + the pill ("bar"); a tile too high for the head under the
  status bar is kept and stood on lower (top = minTop); edges covered by another tile are trimmed; lifted (dragged)
  tiles neither count nor trim.

## Tuning (64 px pet; k = size/64 scales lengths)
runMax 330, runAcc 3600, turnAcc 6400, friction 4400, airAcc 2600, gravity 5200, fallMult 1.6, jumpH 280 (variable),
maxFall 1900, wallSlide 220, wjVx 300, wjVy 1300. Squash spring k 420 / damping 18, clamp +-0.25; landing kick from
impact speed, take-off kick 2.6.

## Pitfalls already hit
- Teleport: a fall animated by transform then handed over to left/top (+ the CSS left/top glide) = the jump the user
  saw. Never two position sources; the old path lives on only behind powos.pet.physics=off.
- Inline left/top left over from the old path doubled the place (off screen): pin left/top 0 in physics mode.
- Stretching: a keyframe scale stacked on the body's own squash. One squash source, clamped.
- UI lag on every move: nativeglass.ts's MutationObserver measured all glass for each style write. The pet carries
  data-glass-ignore; any new per-frame inline-style animation needs it too. Pet on its own layer (will-change).
- Planner hitch (5-61 ms on the phone): never plan in one frame - slice it.
- Agents' CDP checks opening the drawer/AI page during a recording changed the world; CDP on live pages is read-only.
- screenrecord needs su; pick the display with dumpsys SurfaceFlinger --display-id (cover = the 2nd, 404 CSS px).

## Commands
- Tests: node --test shell/test/petphys.test.ts (sim() asserts MAX_STEP and the 25% scale every step; real-home
  layouts: pill -> top tile, today -> performance, off the floor from each corner).
- Headless real page: docker run --rm --platform linux/arm64 --shm-size 512m -v "$PWD/shell:/shell:ro"
  -v "$PWD/shell/dev/petrec.mjs:/usr/src/app/petrec.mjs:ro" -v "$OUT:/out" -w /usr/src/app --entrypoint node
  zenika/alpine-chrome:with-puppeteer petrec.mjs (frames + report.json; idle rAF must be 0 from pet code;
  PET_PERF=1: native glass on, rAF by file + main-thread time per climb; PET_PHYS=off compares the old path).
- Device, read-only: `tools/phone/cdp.sh eval home '<expr>'`: __pet.edges(), localStorage powos.pet.perch/physics,
  .pet classes. Never force/goto the live pet.
