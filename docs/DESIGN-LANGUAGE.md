# PowOS shell: design language

These rules apply to every page of the phone shell (home, drawer, search, PowOS AI, assist, shade, control
center, switcher, lock face, PowOS app pages, widgets), folded and unfolded. Tokens live in `shell/theme.css`.
How the shell is built is in [`shell/DESIGN.md`](../shell/DESIGN.md). Renders for checking a change come from
`shell/dev/gate.sh --shots DIR`.

## 1. Less is more

If in doubt, take it out. Default to calm.

- **Reduce.** A change removes elements, layers, surfaces or effects instead of adding them. Before adding a
  surface, plate, wrapper, shadow or effect, ask whether the same can be done with less. Usually it can, by
  deleting something.
- No decoration that carries no content: no plates behind icons, no double backgrounds, no ornamental layers.

## 2. One material

Every surface is the same material: the **reference**.

The reference was locked on 2026-10-21 from PowOS AI's page as the user approved it at 08:55 on Nord ("the
current blur effect looks really nice"): strong even frost, cool tint, a light top edge, and the compose pill.
Its commit is `912a284` + `3b9b5a3` (liquid refraction off) on `worktree-powos-multiplatform`.

| token | value | what |
|---|---|---|
| `--glass-base` | foreground 18% into background | the tint's colour (from the active theme only) |
| `--glass-tint` | 32% (40% light) under `html.glass-native` | how much tint |
| `--glass-dim` | 16% | extra tint for surfaces carrying text |
| `--text-fill` | `--glass-base` at tint + dim (48%) | **the reference fill** |
| `--glass-veil` | `rgb(0 0 0 / 20%)` (light: `rgb(255 255 255 / 8%)`) | the lock frost's brightness, under the tint |
| `--glass-blur-native` | 140px | compositor blur radius (it blurs at about 0.15-0.3 of this) |
| `--glass-blur` | 28px | CSS/picture blur (lock face, popovers) |
| `--lift` | `--lift-edge` (inset 0 1px 0 white 7%) + `--lift-shadow` | a surface's light top edge and soft shadow |
| `--radius` / pill | 12px / 20px | the radius scale: 12 for surfaces, 20 for pills and round controls, 8 inside a surface |
| `--gap` / `--edge` | 8px / 12px | spacing between surfaces / from the screen edge |

Don't tune blur strength or tint without a reason you can measure (contrast, a frame time, a user report).

- A **surface** is `.tile`: the fill plus `--lift`. A surface inside a surface is only `--soft-fill`.
- A **sheet** (`.tile.sheet`) is anything over home's own content: a widget's screen, an app's page, the
  picker, a menu, a popover. It gets the reference fill. Under a page-sized sheet, home's content fades out and
  is hidden, so only the frosted wallpaper is behind it. Small popovers (`.pop`) blur what is under them.
- A **pill** (`.tile.pill`) is the one text-entry component: home's search and PowOS AI's compose. It is the
  same material, 20px round, with a field that grows to 3 rows and the mic on the right. Only the placeholder
  differs.
- **No hard borders, ever.** No 1px outlines, no divider lines. Rows are separated by spacing. OWL `border`
  renders as a lifted soft surface, and a coloured border as a soft ring of that colour.
- **No page-wide dims.** No scrim colour behind sheets, and no darkened page under a panel.

## 3. Wallpaper behind every page

The wallpaper shows behind every page, frosted. Surfaces appear only where they carry content: the dock is
bare icons, and the search pill floats. The drawer's frost runs to the screen's foot.

- Home's glass is the compositor's live blur (`html.glass-native`, `ui/nativeglass.ts`). The compositor blurs
  only what is under the window (the wallpaper), never home's own tiles. That is why sheets hide home's
  content instead of blurring it.
- Windows over apps (shade, switcher) have the host blur behind them, and their surfaces only tint. The
  assistant is tinted only, because it draws on the app under it.
- Liquid glass (refraction at the edges, native) stays off by default. It may come back only as a very faint
  edge effect, never in the middle, after a reviewed contact sheet.

## 4. Colour

Colours come from the active theme only: `--color-*`, `--glass-*`, `--soft-fill`. No raw colours in
components. `shell/dev/lint-style.sh` (part of the gate) fails a raw colour, border or box-shadow outside the
tokens.

## 5. Text contrast >= 4.5:1

Text needs at least 4.5:1 contrast (3:1 when large) against what is actually drawn behind it.

- Secondary text is `--color-muted`: the theme's foreground at 84%, never the theme's own grey.
- Hierarchy comes from size and weight, not from dim opacities.
- `gate.sh --shots` measures each text's contrast against the rendered frost (`report.json`).

## 6. Motion tied to the finger

Motion follows the finger. Only `--p`, transforms and opacity move during a swipe, with springs on release.

- No reloads, no flashes, no blank frames, no jumps when the keyboard comes up.
- The pill grows upward over home without moving anything else.
- Changing the theme crossfades.

## 7. One assistant, one conversation, one chat surface

- **One conversation:** the manager's (PowOS AI's chat). Every "ask the AI" entry point feeds that conversation.
  None of them starts a thread of its own.
- **One chat UI:** the home search pill's chat mode. Typing searches. Asking turns the drawer into the chat, in
  place.
  - Everything that opens "the assistant" opens this surface (`shell/ui/assistant.ts`
    `openAssistant({listen, autosend, text, context})`): the side button, a bubble's expand, PowOS AI's pill.
  - There is no other compose field, and no "open ↗" to a separate chat app.
- **PowOS AI's page** (left of home) shows that conversation's history and the work board. It is not a chat of
  its own: its pill opens the one surface.
- **The pet** is the assistant's face and its notifier:
  - A tap makes it listen in place. A small bubble shows the live transcript, then the reply in a few lines. A
    tap on the bubble opens the chat surface.
  - Its look comes from live state only: working, looking at you, worried, sleepy, hungry.
  - While the chat surface is open, it sits by the pill.
  - With the surface closed, it speaks only in short bubbles: 3-6 s, one at a time, batched. They carry deploy
    notes, agents' mail, and replies nobody was looking at. A bubble's "more" opens the AI page, and so does a
    long press on the pet.
- **Calm:** the pet is still at rest. It plays one short animation per state change and runs no timers while
  hidden.
