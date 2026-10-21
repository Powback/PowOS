---
name: powos-pet-physics
description: Load before changing how the PowOS pet moves (shell/ui/petphys.ts, petai.ts, petmove.ts, petperch.ts, the movement in pet.tsx) - the controller's design, tuning, world rules, the pitfalls already hit, and the test/recording/perf commands.
---

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
- Device, read-only: adb forward tcp:9333 localabstract:webview_devtools_remote_<pid>, then bun cdp.ts index.html
  '<expr>' in the powos-vadb network; __pet.edges(), localStorage powos.pet.perch/physics, .pet classes.
