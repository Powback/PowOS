# The pet - PowOS's agents, alive in the UI

Owner of the design: the **manager** (it reviews every step before it reaches the phone). Builder: the pet agent.
Code: `apps/pet` (the `local.pet` app: module + page), `shell/ui/pet.tsx` + `pet.css` (the shell layer),
`lib/apps/powos-pet` (`powos pet`). Rules it lives by: docs/DESIGN-LANGUAGE.md - calm, "less is more", the theme's
tokens only, §7 "One assistant, one conversation, one chat surface" (the pet is the face and the notifier).

## v1 (shipped 2026-10-21)

A sprite floating in a corner of home and PowOS AI's page; states from live data (working, looking at you, worried,
sleepy, hungry, a jump on a task done); bubbles for `powos pet say`, deploy notes, agents' mail, unread replies; tap =
it listens right there (transcript, then the reply in its bubble; the bubble opens the chat); long press = PowOS AI's
panel. `powos pet say|mood|feed|name|status|log|hush`.

## v2 - a creature that lives in the UI

### 1. Body
- A small **procedural** creature: a soft blob (one SVG path from a few control points around a centre) with two
  eyes and a tiny body/feet - no sprite sheet, no emoji smiley. Its fill is the theme's (`--color-accent` mixed toward
  `--color-foreground`), its eyes `--color-background`; a theme change recolours it live.
- **Spring physics**: the body's points are masses on springs around the centre (verlet, fixed 60 Hz step): it
  wobbles when moved, **squashes on landing and stretches when it jumps**, settles back.
- **Eyes track the finger** (pointer anywhere on home while it's awake), with a little lag; pupils clamp inside the
  eye. Blinks are CSS (a scaleY keyframe), never script.
- **Frames only while something moves**: one requestAnimationFrame loop runs while the springs are above an energy
  threshold, a hop is in flight or a finger is down; it stops itself when everything has settled (< 0.05 px for 6
  frames). At rest: 0 frames, 0 timers - idle looks (breathing while asleep, a blink) are finite CSS animations on its
  own layer. No loop at all while the page is hidden.

### 2. Lives IN the UI
- **Perches** on the top edge of a home tile (a widget, a stack) or of the dock; the edges come from grid.tsx's tile
  rects (measured once per layout change, not per frame) - those are its floor.
- **Walks** along a tile's top edge, **hops** between edges (a ballistic arc, squash on take-off and landing); never
  across the middle of the screen without a perch to land on.
- **Shade pulled down**: it ducks under it (hidden while the shade covers its perch). **Chat opens**: it peeks out of
  the search pill (sits on the pill's top edge) - the face of the one chat surface.
- Remembers its perch (in `local.pet`: tile key + x along the edge); a moved/removed tile: the nearest edge.

### 3. System state, physically
| state (live data) | what it does |
|---|---|
| agents working (spool) | carries a tiny glowing parcel toward the board (PowOS AI's side), once per new task, then sits working |
| a deploy lands (deploy note) | hops onto the changed widget/app if it's on screen and taps it, one-line bubble ("Lights got rooms") |
| a task waiting on you / approval / agent mail | turns to face you and waves |
| an error (shell error, failed deploy) | shivers, a worried brow |
| battery < 20% | sleepy, slow; **charging** = eating (a small munch) |
| night (23-7) / long idle | curled asleep on its perch (closed eyes, slow CSS breath, 2 iterations) |
| a task done | a hop |

### 4. Touch
- **Tap** = listens: its mouth and eyes react to the voice level (speech.state's level, when the host sends one), the
  bubble shows the transcript then the reply (as v1).
- **Long press** = PowOS AI's panel. **Drag / fling** anywhere: it flies, lands on the nearest edge below with a
  squash; that's its new perch.

### 5. Phase 2 - over apps
A native overlay window (our priv-app) riding at a screen edge over other apps: the same creature, drawn by the shell
page in a small window. Hold it over an app = "ask about this screen" (the side button's context path).

### 6. Phase 3 - the desktop
The same pet in Plasma (a KWin effect or plasmoid) from the same `local.pet` state.

### 7. State in local.pet
name, mood (+ until), energy, xp/level, **perch** (tile key + offset), **memories** (short facts it shows sometimes:
"you named me Pow on Oct 21"). Additive schema changes only.

## Movement (step e, the platformer) - shell/ui/petphys.ts, petai.ts, petmove.ts
- **One position source**: a fixed-step (120 Hz) controller - gravity, run acceleration/friction, a jump as high as
  it's held, coyote time, a jump buffer, wall slide, wall jump (a climbing jump when held into the wall), down through
  a floor. Tiles and the pill are one-way floors (their sides walls at its feet's height), the screen's sides walls,
  its foot a floor. Per axis, swept: nothing tunnels; a moving rect carries it (capped px a step), one that jumps or
  goes drops it; a smaller screen walks it back in. No step moves it more than petphys.ts MAX_STEP.
- **The planner presses buttons**: routes are hops between surfaces, each one played first in a copy of the world with
  the same physics; live it drives closed-loop and replans from where it is when a hop ends elsewhere.
- **Squash/stretch**: one spring from its real velocity and landings, clamped to +-25%, on the same transform.
- **Frames**: rAF only while it moves (fixed steps, drawn interpolated); at rest none.
- Flag: localStorage `powos.pet.physics` = on/off (`__pet.physics("on")`); pet.tsx PHYSICS_DEFAULT is the default ("on" since 2026-10-21).
- Tests: `node --test shell/test/petphys.test.ts`; in the real page headless: shell/dev/petrec.mjs.

## Steps (each one gated, reviewed by the manager BEFORE it reaches the phone)
1. (a) body + spring physics + eye tracking (still floating where v1 sits) - **0 frames idle**.
2. (b) perching: tile edges as floors, walk, hop, fling, remembered perch; shade/pill behaviour.
3. (c) state behaviours (the table in 3).
4. (d) the overlay over apps.

Review: for each step, screenshots/a short recording go to the manager first (the Mac's mock shell in a headless
browser, and the phone's screen only when the user is idle); push after its approval.

**Perf budget: 0% idle.** Measured each step: the page's running animations (`document.getAnimations()`) and rAF
callbacks at rest = 0; the app's + WebView's CPU with home idle unchanged against the pet hidden.
