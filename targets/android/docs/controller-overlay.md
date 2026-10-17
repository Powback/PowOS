# Touch controller overlay — design

On-screen controls for playing PowOS games on the phone, built from small reusable modules, with a per-game
layout that switches itself. Status: design. Cover screen as an input surface: later (see the end).

## Goals

- Play any game by touch: Steam games through Steam Input, non-Steam games through plain gamepad/mouse/keys.
- Modular: every control is one module type with its own settings; layouts are just lists of modules.
- Per game, automatic: the layout follows the focused game; an unknown game gets the default layout.
- Feels native: Android-side multi-touch, haptics, no extra compositor pass, no added latency.

## Architecture

```
 Android app (overlay view over the PowOS surface)            PowOS (rooted session)
 ┌─────────────────────────────────────────────┐   socket    ┌──────────────────────────────┐
 │ touches → module recognizers → Actions ─────┼────────────▶│ powos-padd: virtual          │──▶ Steam Input / SDL games
 │                    │                        │  (gamepad   │ controller (Deck / Xbox)     │
 │                    └─ mouse/keys ───────────┼── state)    └──────────────────────────────┘
 │                       (existing data channel to KWin: nativeSendMouse*/nativeSendKey)       ──▶ desktop / mouse games
 └─────────────────────────────────────────────┘
         ▲ focused window class (steam_app_<id>) from KWin → layout switch
```

Three layers, each replaceable:

1. **Recognizers** (app): turn raw touches inside a module's zone into values — a stick vector, a pressed bit,
   a mouse delta. One per module type.
2. **Actions** (app): where a value goes — gamepad stick/button/trigger, mouse motion/button/wheel, keyboard key,
   or a layout command (switch layer, open editor). A module's output is an action, so any module can drive any
   target: a joystick can be the left stick, the mouse, or WASD.
3. **Sinks**: gamepad actions go to `powos-padd` in PowOS; mouse and key actions use the data channel the app
   already has to KWin (`nativeSendMouseMotion/Button/Scroll`, `nativeSendKey`).

## Modules

Every module has: `id`, `type`, `zone` (rect in screen fractions, so one layout fits folded and unfolded),
`opacity`, `haptics`, `layer` (see Layers), and type-specific settings plus `output` actions.

| type | gesture | settings | typical output |
|---|---|---|---|
| `button` | press/release | shape, label/icon, mode `tap`/`toggle`/`turbo(hz)` | gamepad A, key Space, mouse left |
| `dpad` | 4/8-way from finger position | 4 or 8 way, center deadzone | gamepad d-pad, arrow keys |
| `stick` | drag vector | **fixed** or **dynamic** (centre where the thumb lands, re-centred each touch; optional follow when dragging past the rim), radius, deadzone, response curve, `click_on` double-tap/edge-hold | left/right stick, mouse, WASD |
| `trigger` | analog by vertical drag or press pressure | range, deadzone, or digital | LT/RT |
| `mousepad` | relative motion region | sensitivity, acceleration, tap=click, 2-finger tap=right click, hold=drag, 2-finger scroll | mouse |
| `trackball` | mousepad with inertia: flick to spin, glides with friction, a touch stops it | friction, max speed, spin gain | mouse, right stick (camera) |
| `gyro` | phone motion sensor (not a zone) | enable while: always / held button / stick touched, sensitivity, axes | right stick, mouse, Deck gyro |
| `wheel` | circular drag (radial menu) | 4–8 slots, each an action | weapon/quick menus |
| `layer` | press/hold | `hold` or `toggle` target layer | switch layer |
| `group` | container | moves/resizes its children together | — |

Dynamic sticks are the default for the two thumb halves of the screen: a stick zone is a large invisible
area; the stick appears under the thumb, and fading in a ring shows its centre.

## Layers

A layout has a base layer and optional named layers (e.g. `build`, `drive` in Besiege). A `layer` module
switches them; modules show only on their layer (or `all`). Lets one layout cover a game's different modes
without clutter.

## Layouts and per-game switching

- Stored as JSON, one file per game: `~/.config/powos/controls/<key>.json` in PowOS (so they are backed up with
  PowOS and survive app reinstalls); the app caches them. `<key>` = `steam_<appid>` or the window class for
  non-Steam games; `default.json` for anything else.
- KWin tells the app the focused window's class on every focus change (a small addition to the existing
  KWin→app event stream). Steam games are `steam_app_<appid>` (Besiege: `steam_app_346010`).
- The overlay hides itself for ordinary desktop windows (layout `none`) and shows a small toggle button to
  bring it back.
- Built-in presets: `gamepad` (two dynamic sticks, ABXY, d-pad, bumpers, triggers, start/select),
  `mouse+keys` (trackball + WASD stick + a few keys), `strategy` (trackball + wheel). A new game starts
  from the default; the editor can apply a preset.

```json
{
  "version": 1,
  "name": "Besiege",
  "layers": ["base", "build"],
  "modules": [
    {"id": "move", "type": "stick", "zone": [0, 0.35, 0.5, 1], "mode": "dynamic", "radius": 0.08,
     "deadzone": 0.12, "output": {"gamepad": "left_stick"}},
    {"id": "look", "type": "trackball", "zone": [0.5, 0.2, 1, 1], "friction": 0.92,
     "output": {"mouse": "motion"}},
    {"id": "jump", "type": "button", "zone": [0.86, 0.72, 0.96, 0.8], "label": "A",
     "output": {"gamepad": "a"}},
    {"id": "build", "type": "layer", "zone": [0.02, 0.05, 0.1, 0.11], "mode": "toggle", "target": "build"}
  ]
}
```

## Editor

Entered from a long-press on the overlay toggle. The game stays visible behind it (paused if it pauses on
focus loss).

- Drag to move, corner handles to resize, snap to a grid and to other modules' edges.
- Tap a module → settings sheet for its type (output picker, mode, sensitivity, opacity, haptics) with a live
  test area (the stick vector / mouse delta is shown as you touch it).
- Palette to add modules; duplicate; delete; group.
- Per-layer view; "apply preset"; reset to default.
- Save writes the JSON through to PowOS. Undo within the session.

## powos-padd (virtual controller)

A small daemon in the PowOS session, started with it.

- **Steam Deck controller** (preferred): Steam then uses the Deck's per-game Steam Input configs, community
  layouts, back paddles, trackpads and gyro. Created through InputPlumber's Deck target (already built in
  `out/pkgs`, not yet installed on the phone; it needs `/dev/uhid`), fed by the daemon.
- **Xbox-style pad over uinput** (fallback, and for non-Steam games that only speak XInput/SDL): plain
  `/dev/uinput`, which exists on the phone.
- Wire format app→daemon: a fixed-size state packet (buttons bitmask, 2 sticks, 2 triggers, gyro) on a unix
  socket in the shared run directory, sent on change and at most once per display frame. Latest state wins, so
  a dropped packet never leaves a button stuck; the daemon releases everything when the app disconnects.

## Feel

- Haptic tick on press, on stick deadzone exit and on trackball stop (Android `performHapticFeedback`).
- Touch → controller latency budget: one display frame. Recognizers run on the UI thread's touch callback;
  sending is a single small write.
  Measured 2026-10-17 on the OnePlus Open (overlay button A, 10 taps, Android's touch event time → the report's
  arrival on the Deck controller's hidraw node, both CLOCK_MONOTONIC): mean 11.8 ms, 6.5–17.0 ms, every press and
  release delivered. The touchscreen's own scan latency comes on top. Method: `setprop log.tag.GamepadOverlay DEBUG`
  (logs each down's event time) and a hidraw reader in PowOS timestamping button changes.
- Multi-touch: each pointer is owned by the first module whose zone it lands in (topmost first); it stays
  with that module until it lifts, even when it leaves the zone.
- Controls are translucent by default (opacity per module) and fade further after a few seconds without
  touching them.

## Milestones

1. `powos-padd` with the Xbox uinput pad + overlay with `button`, `dpad`, `stick` (fixed and dynamic),
   `trigger`, hard-coded `gamepad` preset. Besiege and Steam Input see a controller.
2. `mousepad`, `trackball`, `gyro`, actions to mouse/keys.
3. Layout files, per-game switching from KWin's focused window class, presets.
4. Editor.
5. Deck controller through InputPlumber (paddles, trackpads, gyro in Steam Input), layers, `wheel`.
6. Later: the cover screen (both displays on while unfolded) as a second control surface.

## Open questions

- InputPlumber without systemd/D-Bus system bus on the phone: run it as a plain daemon, or drive `/dev/uhid`
  directly from `powos-padd` with the Deck's HID descriptor. Decide when milestone 5 starts; milestone 1 does not
  depend on it.
- Whether Steam on the phone handles a uinput Xbox pad through Steam Input without extra udev rules (no udev
  daemon on Android): verify in milestone 1.
