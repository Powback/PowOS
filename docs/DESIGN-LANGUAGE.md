# PowOS shell: design language

Every page of the phone shell follows these rules, folded (404x899) and unfolded (821x883): home, the launcher,
folders, the shade, the lock face, the switcher, web windows, PowOS AI, the assistant, app pages, settings and
widgets. Home is the reference: when a page and home differ, home wins.

Each rule is one sentence plus the token or function that implements it. Tokens are in `shell/theme.css`. How the
shell is built is in [`shell/DESIGN.md`](../shell/DESIGN.md).

Checks:

- `shell/dev/lint-style.sh` fails the gate on raw colours, borders and shadows.
- `shell/dev/lint-design.sh` fails the gate on monospace UI text, hard-coded blur, off-scale radii (every corner of
  a shorthand), literal easings, status colours outside their tokens, literal durations in home's and the
  launcher's motion, hard lines drawn at `--frame`, and folds or menus on the AI page that pop in
  (`{open && …}` instead of `ui/reveal.tsx` `Reveal` / `usePresence`). For PowOS apps' pages (`apps/*/ui`) it fails
  on inline styles naming the monospace font outside a code style and on transitions with a literal duration.
- The gate's `design-lint-*` runs find pop-ins and monospace text on screen. They fail the gate for the launcher
  (`design-lint-launcher-*`) and are report-only for the other surfaces until their design wave.
- `shell/dev/gate.sh --shots DIR` renders every surface and measures text contrast (`report.json`).

## 1. Less is more

- **Reduce.** A change removes elements, layers or effects instead of adding them. No plate, wrapper, shadow or
  ornament that carries no content.
- **Empty states hide.** A section, list or chip with nothing in it is not drawn: no "Nothing yet" or "No X"
  line. A whole page with nothing in it says so once, in one line. See `aistatus.tsx` (empty sections hide, `quiet`).
- **One row of page dots.** Every page indicator is `ui/pagedots.tsx` `PageDots`; home has one row (the dock has none
  of its own). lint-design blocks a dot row with its own "on" state.
- **One icon shape.** Every app icon is the squircle `--icon-radius` (22%). An irregular icon sits on the one plate,
  `--icon-plate`, and never gets a second plate. See `ui/iconshape.ts`.
- **Rewrites keep every feature.** Before a rewrite lands, list the old code's gestures and features in the commit,
  and keep each one or name its replacement. The gate case for the old behaviour stays.

## 2. One material, one backdrop

- **THE backdrop.** Every surface over the wallpaper or an app uses one blur and one tint:
  `--backdrop-blur-native` (170) and `--backdrop-tint` (black 55%, or the theme's background in light themes). This
  covers home's widgets, the search bar, the launcher, the PowOS AI page and panel, folders, the shade and the
  assistant's panel.
  - `--shade-tint` and `--widget-blur-native` only alias these.
  - No surface names its own blur or tint. See `dev/backdrop-check.js` and commits 3e6e5825 and 160e64ed.
  - A picture blurred in the page (the media card's art, a card's splash) uses the frost's `--glass-blur`.
- **Menus are opaque.** A menu over a page (⋯, a long-press menu, a tile menu) is filled with `--menu-tint` (the
  theme's background at 94%), so nothing underneath reads through it.
- **Sheets hide home.** A page-sized sheet (`.tile.sheet`) fades home's content out, so only the frosted wallpaper
  is behind it. There are no page-wide dims or scrims. See shell.css `html:has(...)`.
- **No hard lines.** Rows are separated by spacing, never by 1px borders or dividers. `--line` is transparent and
  lint-style enforces it.
- **The light top edge.** A surface's only edge is `--lift` (a 7% top edge plus a soft shadow). A window uses
  `--lift-window`, and the focused window `--lift-window-focused`.
- **Liquid glass stays off.** Refraction (`--liquid-*`) may return only as a faint edge effect, and only after a
  reviewed contact sheet.

## 3. Layout

- **16 dp gutters.** Content sits 16 dp from a surface's edge and from the screen's edge: `--edge` (16px), on every
  page. The widget sheet (`widgetsheet.tsx`) and home's grid (`grid.tsx`) read it, and the AI page's `--ais-side` is
  only an alias of it.
- **The radius scale.** Use 8px inside a surface, `--radius` (12px) for surfaces, 20px for pills and buttons, and
  999px or 50% for round shapes. No other radius.
- **Spacing.** `--gap` (8px) goes between surfaces. Hierarchy comes from size and weight, not from boxes.
- **Alignment is a setting.** The launcher, notifications and control center stack from the top, the middle or
  the bottom.
  - It is set per screen, through `ui/align.ts` `alignOf(surface)` and `html[data-align-*]`.
  - Defaults: unfolded bottom, folded top. Notifications default to top on both screens.

## 4. Type and contrast

- **Proportional UI font.** All UI text is `--font-body`, which is the proportional `--font-ui` by default.
  - The font is a theme setting: Settings › Style › Font, "UI (default)" or "Mono" (`ui/uifont.ts`,
    `html[data-font]`). A pick applies at once to every page.
  - Code, terminals (xterm, `TerminalView`) and logs always use the monospace `--font`, whatever the setting
    (`pre`, `code`, `.term`).
  - A UI rule never names `--font`, and never measures text by counting monospace characters (`agents.tsx`
    `charWidth` measures the theme's font).
  - Known exception: OWL widgets (`owl.tsx` `OWL_FONT`) stay monospace until OWL scripts can measure text. They size
    their text by counting characters today.
- **Contrast ≥ 4.5:1.** Text needs 4.5:1 contrast against what is drawn behind it (3:1 for large text). Measure it
  with `gate.sh --shots` (`report.json`).
- **Secondary text** uses `--color-muted`, never a dimmed opacity. Text on the wallpaper uses `--on-wallpaper` with
  `--label-shadow`.
- **Accent text** uses `--accent-text`. A fill (an on tile, a switch) uses `--color-accent`.

## 5. Colour and status

- **Theme tokens only.** Colour comes from `--color-*`, `--glass-*`, `--soft-fill` and `--backdrop-*`. Exceptions
  are listed in `dev/style-allow.txt`.
- **Status colours have one meaning each, on every surface:**

  | state | colour |
  |---|---|
  | working | `--status-working`: the accent, pulsing |
  | awaiting check | `--status-check`: blue |
  | needs you | `--status-needs`: amber, with `--status-on-needs` for text on it |
  | stalled | `--status-stalled`: grey |

  - Red (`--color-red`) means only broken or failed.
  - The tokens are in theme.css. No surface names a status colour of its own.
- **P0/P1 chips.** A task with severity shows one small chip, P0 or P1, before its title, and a task with no severity
  shows none (`aiboard.tsx` `SevChip`, `.ais-sev`).
  - P0 is red.
  - P1 is a neutral chip (the foreground at 22%). It never reuses the needs-you amber.

## 6. Motion: no pop-ins

- **Nothing pops in.** Every appear, disappear, resize and reorder animates. An element is never there in one frame
  and gone in the next.
- **Shared springs only.** Motion uses one spring set in `ui/spring.ts`: `springFast`, `spring` and `springSlow`. In
  CSS these are `--spring-fast`, `--spring` and `--spring-slow`, each paired with its duration (`--spring-fast-ms`,
  `--spring-ms`, `--spring-slow-ms`). Use fast for small things (a fade, a chip), the default for a surface moving,
  and slow for a large or far move. WAAPI uses the same objects (`.easing`, `.ms`). Lists use `notifmotion.ts` (arrivals fade and slide in 30 ms apart, a dismissed item closes its gap,
  "+N more" grows). A fold or a menu uses `ui/reveal.tsx`: `Reveal` grows a fold's body in and out, `usePresence`
  keeps a menu mounted while it leaves. Do not use a local `cubic-bezier()` or ms value.
  - Loops (a pulse, a sweep, a blink) are not motion between states. They keep their own period on `--ambient`.
- **Finger-tied.** During a swipe only `--p`, transforms and opacity move, and the spring runs on release. There are
  no reloads, flashes, blank frames or keyboard jumps.
- **Reduced motion.** Under `prefers-reduced-motion`, everything jumps to its end state. Same code path, no special
  layout.
- **Theme changes crossfade.**

## 7. Touch and haptics

- **Haptics only at commit points.** A haptic fires on lift-out, on a snap (a threshold crossed, a window snapped),
  on a long-press opening, and on push-to-talk start. It never fires on page changes, scrolling or reordering steps.
  - Use `ui/haptics.ts` `tick()` and `confirm()`, plus `panelTicks()` for pulls.
  - Never `navigator.vibrate()` (silent in the phone's WebView): lint-design blocks it outside `ui/haptics.ts`.
- **Long-press opens a menu or edit mode.** A menu shows only what no tab or button already offers.

## 8. One bar, one assistant

- **One search bar, with a role per page.** Home's bar is the launcher's search, the filter on a folder or app list,
  and the PowOS AI page's input to the manager.
  - It changes only its placeholder and glyph, with a crossfade. No page has a compose field of its own.
  - See `ui/bar.tsx` `Bar` and commit ceafb73c.
  - It is the one pill (`.tile.pill`): `--pill-height` (40px), it grows up to 3 rows, and the mic sits on the right.
- **One conversation.** Every "ask the AI" entry point feeds the manager's chat through `ui/assistant.ts`
  `openAssistant()`. There is never a second thread or an "open ↗".
- **The assistant overlay** leaves the screen under it 1:1: no frost or scaling. Only its panel is glass, frosted
  from that same screenshot (`glass.ts`).
- **The pet** is the assistant's face. It is still at rest, plays one animation per state change, and shows bubbles
  for 3-6 s, one at a time.

## 9. Surface patterns

- **Quick pages.** A settings page of any app, opened from search or a tile, is a compact card on the backdrop glass
  (`ui/quickpage.tsx`), `--radius` round, with a small title bar (the app's icon, the page's name, pop-out to a
  window, close). It springs out of what opened it; folded it is a full-width sheet rising from the bottom. It is
  never the whole Settings app.
  - Known exception: Android's native panels (the internet, NFC and Wi-Fi panels, Bluetooth, the volume panel) stay
    Android's own bottom sheets until they are drawn by us.
- **Notifications.** There is one stack per app, newest in full and two strips behind it, then "+N".
  - Conversations sit on top.
  - A swipe on a folded stack dismisses the group, and a swipe in an open group dismisses one card.
- **Control center.** Two slim sliders and eight category tiles (2x4).
  - A tap does the primary action.
  - The chevron or a long press unfolds one category in place.
- **Pull-up corners.** The drawer comes from the right half and PowOS AI from the left half. Both share one panel,
  frost, dismissal and pill (`state.ts` `pullKind`).
