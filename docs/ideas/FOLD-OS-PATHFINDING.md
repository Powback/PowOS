# Fold OS pathfinding: ideas nobody has shipped

Status: research and design only, 2026-10-22. Nothing here is built. Question asked: "our UI changes have been pretty
vanilla ... come up with brand new ideas for a phone/desktop fold phone like ours which has never been done before."

The method: design from what only this device + OS has, not from phone conventions.

| asset | what it unlocks |
|---|---|
| near-square 2268x2440 inner screen + 1116x2484 cover, hinge 0-~179° (OnePlus Open never quite reaches 180) | two faces, a continuous analog input, a physical "inside" and "outside" |
| a whole KDE/KWin desktop + Steam/Proton beside Android | a real computer inside the phone, which can run while you don't look at it |
| always-on manager + expert agents that edit and ship the OS live, a work board, comms | the OS has *workers*: they can be visible, located, and reviewable |
| shell = live-reloadable web UI (`shell/`, hot overrides, `shell/push.sh`) | any surface can be swapped, branched or rolled back in seconds |
| root, cgroup v2 freezer (`docs/UNIFIED-SLEEP.md`) | instant freeze/thaw of any app, game or the desktop |
| WebRTC/TURN, LAN streaming, GPU servers (STT, LLMs) | sessions can move between machines; voice and vision are cheap |

## 1. Prior art (what really exists)

Shipping:
- **Samsung Flex Mode** (Z Fold 7, One UI 8): half-folded 75-115°, content top, controls/touchpad bottom; AI results
  in split/floating view. https://en.wikipedia.org/wiki/Samsung_Galaxy_Z_Fold_7 ,
  https://www.tomsguide.com/phones/samsung-phones/one-ui-8-is-coming-with-galaxy-z-fold-7-and-z-flip-7-here-are-all-the-best-new-features
- **OnePlus Open Canvas**: 2 visible apps + 1 off-screen on a virtual strip, 4-finger pinch for all three, 9 presets.
  https://www.androidauthority.com/oneplus-open-canvas-multitasking-3379364 ,
  https://www.trustedreviews.com/explainer/what-is-open-canvas-on-the-oneplus-open-4382484
- **Pixel Fold**: dual-screen interpreter (both screens, two people), rear-camera selfie on cover, dual-screen
  viewfinder. https://developer.android.com/develop/adaptive-apps/guides/foldables/support-foldable-display-modes
- **Surface Duo**: spanning, companion pane (canvas on one screen, tools on the other), dual-screen drag and drop.
  https://learn.microsoft.com/dual-screen/design/companion-pane
- **Huawei Mate XT / XT 2** (tri-fold, HarmonyOS 7): 1/2/3-panel modes, 3-app MultiView, an "intelligent agent"
  framework. https://www.khaleejtimes.com/business/huaweis-new-phone-tablet-hybrid-is-the-only-tri-fold-left-on-the-market-worth-dh10000 ,
  https://www.tuttoandroid.net/news/2026/08/29/huawei-mate-xt-2-design-batteria-harmonyos-1169982/
- **Honor Magic V5 YOYO**: "AI multi-screen interaction" that redistributes content when you unfold; cross-app agent
  tasks (ride hailing). https://www.huaweicentral.com/honor-magic-v5-to-redefine-multitasking-with-an-interactive-ai-feature/amp/
- **Motorola razr / Razr Fold** (2026): Moto AI on the cover (Catch Me Up, Look and Talk by glance, Next Move
  suggestions). https://www.androidcentral.com/apps-software/motorola-moto-ai
- **Android 16 desktop mode / DeX**: desktop windowing on tablets and external monitors; foldables explicitly NOT on
  their own screen. https://www.androidheadlines.com/2025/06/google-explains-why-android-16s-desktop-mode-works-on-tablets-but-not-on-foldables.html
- **Apple foldable / iOS 27** (rumour): iPad-style sidebars when open, widgets that expand full screen.
  https://www.macrumors.com/guide/ios-27-rumors
- **Nothing Essential / Playground**: prompt -> home-screen widget; full-screen apps not yet.
  https://techcrunch.com/2025/09/30/nothing-launches-ai-tool-for-building-mini-apps-using-prompts/
- **Rabbit r1** (LAM, teach mode = recorded macros, rabbitOS 2 "creations"); **Humane AI Pin** (failed).
  https://en.wikipedia.org/wiki/Rabbit_r1
- **Light Phone III**: "tools, not apps", curated. https://en.wikipedia.org/wiki/Light_Phone_III
- **Google Generative UI** (Gemini/AI Mode builds an interface per prompt).
  https://research.google/blog/generative-ui-a-rich-custom-visual-interactive-user-experience-for-any-prompt/

Research:
- **Codex** (Hinckley et al., CHI 2009): dual-screen tablet, postures (hinge angle + orientation) switch contexts.
  https://www.microsoft.com/en-us/research/publication/codex-dual-screen-tablet-computer/
- **Hinge Gestures** (IRIT, 2026 preprint): taps/swipes *on* the hinge, hinge menus beat linear menus.
  https://hal.univ-grenoble-alpes.fr/IRIT-ICI/hal-05572771v1
- **Across-hinge dragging** (Zinck et al., CHI 2023). https://github.com/exii-uw/evaluating-hinge-dragging
- **FoldMe** (TEI 2012): double-sided display, fold gestures reach the back side. https://hci.cs.uni-saarland.de/projects/foldme/
- **PaperPhone** (CHI 2011): bend gestures as input. https://research.cs.queensu.ca/home/audrey/papers/CHI11.Lahey.pdf
- **ManyFold** (2026): data-vis on foldables. https://arxiv.org/pdf/2608.02232
- **Malleable software** (Ink & Switch, 2025): Potluck, Patchwork, Embark. https://www.inkandswitch.com/essay/malleable-software/
- **Gradual generation of UIs for malleable software** (2026). https://arxiv.org/html/2601.17975v1
- Patents on hinge-as-input exist (US10248224B2) but nothing shipped. https://patents.google.com/patent/US10248224

What the field has NOT done (the gaps this doc aims at): the hinge is used as a **discrete mode switch** only (flat /
half / closed), never as a continuous control of the whole UI; AI on foldables is a **chat or a suggestion card**,
never a set of visible workers; nobody runs a **real desktop inside a closed phone**; nobody lets you **see, branch
or rewind the OS itself** because nobody else's OS is being rewritten while you use it.

## 2. The ideas (13 kept from ~30)

Labels: **new** = no shipping or published equivalent found; **rare** = research/concept only or one niche product;
**exists** = shipping elsewhere, our twist is the point. AI = uses the agents as UI; FOLD = uses hinge/two screens.

---

### 1. Agent Presence: a multiplayer OS  [AI] new

Pitch: every agent working on the OS has a live cursor on the exact surface it is changing, like Figma's multiplayer
cursors, but the document is your phone.

Scenario: you ask "make the drawer's search pill sit lower". Ten seconds later a small `drawer` avatar is parked on
the pill itself, with a 1-line caption "editing drawer.tsx · 2 tools". When it ships, the pill crossfades to the new
version and the avatar leaves a fading ring: "changed by drawer · undo". Tap the avatar: its task, last step, and
the diff of that surface only.

Why new: Figma/Docs show human collaborators in documents; Copilot/Devin show agents in a code view. No OS shows its
own builders located on the live UI they edit. Closest: Honor YOYO's on-screen agent (one assistant, no location),
Moto Next Move (suggestions).

Why only PowOS: the agents are real, edit this OS's own files, and agents.ts already streams each agent's current
tool + file (`AgentEvent.hint`); the shell is the same DOM they edit, so file -> surface is a lookup.

Interaction: passive by default (avatars at rest are still, no animation: design rule 6). Tap = details, long press =
"pause this one", swipe the avatar off = "not now, hold the deploy". Unfolded: avatars in place. Folded: the edited
surface may be offscreen -> a slim edge chip pointing where it is.

1-day prototype: `shell/ui/presence.tsx` + a table `file -> selector` (drawer.tsx -> `.launcher`, control.tsx ->
`.cc`, pet*.ts -> `.pet`, ...) in `shell/ui/presence-map.ts`; read `agents.ts` `recent` / agent rows; place a badge
at `getBoundingClientRect()` of the selector; on `shell/push.sh`'s deploy note, ring the surface. Mock events in
`bridge.ts` mock. Gate: `shell/dev/gate.sh --shots`.

Risks: noisy if 6 agents work at once (cap at 3 visible, rest as a "+3" chip); file->surface map rots (generate it
from a `data-src` attribute added at build); must keep 0 frames at rest.

---

### 2. Time Fold: the hinge rewinds the OS  [FOLD, AI] new

Pitch: half-close the phone and the OS scrubs back through its own history; the angle is the time.

Scenario: an agent shipped a new control center and you hate it. Close the phone from 180° toward 120°: the screen
becomes a filmstrip of the shell's last deploys, each a frame of the same screen, sliding with the hinge. Stop at
"yesterday 21:40", open flat again: that version is live. Agents get a board note: "user rolled CC back to 21:40".

Why new: hinge angle has been a mode switch (Flex Mode, Codex postures) or a touch target (Hinge Gestures). Using it
as a continuous time scrubber, over the OS's own versions, has no precedent: no other OS changes often enough to need
it. Closest: macOS Time Machine (files, not UI), git bisect.

Why only PowOS: shell deploys are git commits + `shell/push.sh`; every version can be rendered (`gate.sh --shots`) and
re-pushed in seconds; agents change it daily.

Interaction: trigger = hold the side button + close below 150° (so a normal fold never scrubs). Angle 150->90 maps
to the last N deploys (detent-like snaps per deploy, haptic tick). Open flat = apply, fold shut = cancel. Cover screen
shows the deploy's note ("drawer: pill lower") while you scrub.

1-day prototype: hinge plumbing (see §4 day 0) + `shell/ui/timefold.tsx`: a strip of pre-rendered shots per recent
shell commit (generated by a script `shell/dev/history-shots.sh` that runs `gate.sh --shots` per commit into
`~/.local/share/powos/shell-history/`), scrubbed by `--hinge`; "apply" = a board ask to the manager to re-push that
commit (no new deploy path).

Risks: real rollback must be per-surface, not whole-shell, or it undoes unrelated fixes (v2: per-file revert by the
owning expert); sensor noise near thresholds; not discoverable (teach it once via the pet).

---

### 3. Hinge as a CSS variable: the UI that unfolds with you  [FOLD] rare

Pitch: `--hinge` (0..1) is on `:root` like `--p` for a swipe; every surface morphs continuously with the angle
instead of jumping between "folded" and "unfolded".

Scenario: you open the phone slowly. At 60° the home's two pages fan out like a book's pages, icons slide from the
dock outward; at 100° the bottom half settles into an input deck (keyboard, trackpad, PowOS AI pill) and the top half
into a desktop with windows; flat, it relaxes into one canvas. Every step follows your hand, never a cut.

Why rare: Flex Mode and Surface Duo snap layouts at thresholds; Honor redistributes on unfold (a cut). Continuous
posture-driven layout exists only as research demos. A system-wide developer model where *any* surface can be written
against the angle in CSS is new.

Why only PowOS: one web shell for every surface, motion already modelled as CSS vars (design rule 6), and we own the
sensor path with root.

Interaction: no gestures, the hinge is the gesture. Postures: <30 cover only, 30-150 "deck" (top = content, bottom =
controls), >150 canvas. Semantic zoom: each surface may declare three densities (cover line / deck / canvas).

1-day prototype: day 0 plumbing + `theme.css` `--hinge` and `html[data-posture]`; make 3 surfaces respond: home grid
(page fan), the AI pill (drops to the lower half in deck), the switcher. Dev slider in the mock bridge.

Risks: the inner display may switch on/off at a fixed angle (OnePlus device-state) so the low range may be invisible;
layout thrash at 120 Hz (only transforms/opacity may follow the angle; layout snaps on posture change).

---

### 4. Agents' Room: the closed book keeps working  [AI, FOLD] new

Pitch: when you fold the phone, the inner desktop doesn't sleep: it becomes the agents' workspace, and the cover is
your window into their room.

Scenario: "rebuild the kernel, then test Broforce at 60 fps and tell me". You fold the phone and pocket it. The cover
shows a periscope: a live thumbnail of the inner desktop where an agent is driving a terminal and Steam, with its
step line. You unfold: you are looking over its shoulder at the real desktop; touch anything and the agent yields
("you have the wheel").

Why new: computer-use agents (Operator, Claude computer use) run on remote VMs; nobody runs one on a real desktop
physically inside your own device, with the fold as the boundary between "theirs" and "yours".

Why only PowOS: the Plasma session already runs on the phone; root lets KWin keep a virtual output while the panel
is off; agents already drive the device.

Interaction: fold = hand over; unfold = take back; the cover's thumbnail tap = ask the agent; a hard press on the
cover = stop. Battery/thermal budget shown on the cover.

1-day prototype: KWin virtual output while folded (`kwin_wayland --virtual` / a headless output), exempt the session
from `powos-sleep-gui` while an agent holds it, a cover-home tile showing `spectacle` captures every 5 s + the agent's
step from agents.ts. Agent control can be phase 2.

Risks: thermals and battery in a pocket (hard limits: stop above X °C, Y %); UNIFIED-SLEEP freezes the desktop when
off-screen (needs an "occupied" exemption); privacy if the agent opens your accounts.

---

### 5. Diff Book: two live versions of your OS, one per page  [AI, FOLD] new

Pitch: when an agent proposes a UI change, the left page is today's OS and the right page is the agent's branch,
both live and usable; drag across the crease to merge.

Scenario: "try a calmer notification shade". Two proposals come back. Unfold: left half is your shade, right half is
proposal A running for real (notifications, swipes). Flick the right page like a book page for B. Drag B across the
crease: it merges and ships; the agent gets "user chose B".

Why new: preview deploys (Vercel), Storybook, A/B tests are for developers or are silent. Choosing between live,
running variants of your own OS UI by turning pages is unprecedented.

Why only PowOS: shell variants are just directories; the wide layout is already two halves (`hosts/wide.ts`); agents
can produce branches on demand.

Interaction: unfolded only. Page flip = next variant; crease drag = merge; pinch the crease = side-by-side diff
highlights. Folded: cover shows "2 proposals waiting, open to compare".

1-day prototype: browser/desktop first: a page that loads two shell builds in two sandboxed frames with mock bridges
(no real bridge into a frame: powos-bridge-security), crease drag -> manager ask "ship variant B". Variants = git
branches built into `shell/dev/variants/<name>/`.

Risks: two shells double memory; iframes + native bridge is a security surface (frames must get mock/readonly
bridges); proposals must be scoped to one surface.

---

### 6. Point and Say: reshape any surface where it is  [AI] rare

Pitch: long-press anything on the OS, say what you want it to be, and the owning expert rebuilds that element in
place.

Scenario: long-press the battery tile in control center: it lifts, a thin outline appears, the pill opens with
context "control.tsx · Battery saver tile". You say "show minutes left and what's draining it". An agent takes it;
Agent Presence (#1) shows it on the tile; 3 minutes later the tile changes.

Why rare: Nothing Playground and Google Generative UI create *new* widgets from prompts; Ink & Switch prototypes
edit their own documents. Editing the OS's existing system surfaces in place, routed to an expert that owns that code,
is not shipped anywhere.

Why only PowOS: the handbook already maps surfaces to owners; `openAssistant({context})` exists; agents ship.

Interaction: long-press in edit mode (or two-finger long press anywhere) -> lift + pill. Voice by default.

1-day prototype: `shell/ui/reshape.ts`: capture selector, a crop (snapshot), the source file (from the presence map
in #1) and the owner (handbook table) into `openAssistant({context})`; the manager routes it. No new chat surface.

Risks: vague asks produce churn (the manager confirms scope via `present_choices`); long-press conflicts with existing
gestures (powos-gestures owns the arbitration).

---

### 7. Grown Controls: the OS grows a button for what you keep asking  [AI] rare

Pitch: when you ask the agents for the same thing a third time, the OS proposes a permanent control for it, written
by the agents into the shell.

Scenario: you've said "turn on the GPU speech server" three times this week. The pet offers: "want a tile for that?"
A preview of a new CC member appears; "yes" ships it.

Why rare: iOS Siri Suggestions/Shortcuts suggest existing actions; adaptive-menu research reorders; Rabbit teach mode
records macros. None writes and ships new UI code for the user's habit.

Why only PowOS: the conversation is one log (design rule 7), agents write shell code, CC categories are data.

1-day prototype: `lib/ai` script over the manager's conversation: cluster repeated intents (embedding on llm.pow),
emit a board suggestion; the manager offers it with `present_choices`. UI = existing chat card.

Risks: suggestion spam (max 1/week, dismiss = never for that intent); low precision clustering.

---

### 8. Peek Angle: privacy by how far you open it  [FOLD] rare

Pitch: open the phone a crack and the inner screen shows only what is for your eyes; the more you open, the more
public the layout gets.

Scenario: on a train you open to ~40°, like peeking into a letter: the inner screen shows the full text of the
message and the 2FA code, dim, at the bottom. At 180° the same notification is a calm "Messages · 1".

Why rare: privacy screens (Samsung's pixel-level privacy display) are hardware; Razr cover content is a fixed
subset. Angle-graded disclosure isn't shipped.

Why only PowOS: root over the device-state table (when the inner panel turns on), `--hinge` (#3), our notification
renderer.

1-day prototype: after day 0: `notifications.tsx` reads `--hinge`/posture to choose redaction level; dev slider.

Risks: the inner panel may only light past a fixed angle (needs a device-state override, root); readability at a
narrow angle.

---

### 9. Crease Pocket: a shelf in the hinge  [FOLD] rare

Pitch: drop anything onto the crease line and it stays there, in the hinge, across Android, the desktop, the cover
and every PowOS machine.

Scenario: drag a photo onto the crease: it shrinks into a slim strip in the middle column. Fold the phone: the cover
shows the pocket's items at its edge. On the Mac's PowOS session the same pocket is at its screen edge. Drag out to
use.

Why rare: shelves exist (Samsung Edge panel, macOS Yoink/Dropover); none lives at the physical fold or follows you
across Linux, Android and other machines.

Why only PowOS: `hosts/wide.ts` already reserves a free column between the two pages; store names are shared phone ⇄
desktop; Remote PowOS gives cross-host sync.

1-day prototype: a drop target on the wide layout's middle column (`grid.tsx`/`dockdrop.ts`), items in store
`pocket`, rendered on the cover's home edge.

Risks: across-hinge drags are hard to aim (Zinck CHI 2023): the target must be generous; file vs reference semantics.

---

### 10. Fold to Hand Off: posture moves the session  [FOLD] rare

Pitch: fold the phone during a game and it keeps running on the TV/PC; unfold and it's back in your hands.

Scenario: Broforce on the phone, you get to the couch, fold: the game's process is frozen locally and resumed as a
stream from the PC that has it, or the phone keeps running it and streams to the TV with your controller. Unfold:
the stream stops, the local game thaws at the same frame.

Why rare: Handoff/Steam Remote Play are manual; Samsung's "continue on cover" moves between own screens. Posture as
the trigger for moving a live Linux session between machines is unshipped.

Why only PowOS: cgroup freezer, WebRTC/TURN, PowOS on both ends.

1-day prototype: "phone keeps running, stream out" only: on fold while `steam` unit is foreground and a known sink
is on the LAN, start the existing stream path to that sink instead of freezing (`powos-sleepd` rule).

Risks: true migration (process state between machines) is far off; latency; accidental folds (confirm on the cover).

---

### 11. Hinge Dial: micro-flex as a knob  [FOLD] rare

Pitch: at any held angle, flexing the hinge a few degrees is a relative dial: volume, scrubbing, zoom, a throttle.

Why rare: research uses hinge postures or touches on the hinge; continuous relative hinge input is only in a patent.

Interaction: enabled by holding a finger on the crease (clutch), so walking with the phone never changes volume.
Feasibility hinges on sensor rate and friction (OnePlus "Flexion" hinge is stiff). 1-day: log sensor rate/noise and
a volume demo. Risk: ergonomics; two hands needed.

---

### 12. Threads, not apps  [AI] rare

Pitch: home is a list of things you're doing ("Oslo trip", "drawer bug", "Broforce run"), each holding frozen app
states, files, windows and the agents' tasks for it; apps are just what's inside.

Why rare: KDE Activities, Windows Timeline, Rabbit cards: none is maintained by agents or holds frozen running state.
Why only PowOS: freezer + agents + one board. 1-day: a thread = a board task + frozen window list; render as home
tiles. Risk: becomes a second launcher; heavy.

---

### 13. Stitched Desk: phone and PC as one surface  [FOLD] exists-ish

Pitch: lay the phone next to a PowOS PC; windows slide off one screen edge onto the other, as one desk.

Closest: Hinckley's Stitching (2004), Apple Universal Control, Samsung Flow. Ours would move real Linux windows by
streaming. 1-day: not feasible; listed for completeness. Risk: the hardest one here.

## 3. Ranking

Score = originality (1-5) x feasibility in our stack (1-5).

| # | idea | orig | feas | score | AI | FOLD |
|---|---|---|---|---|---|---|
| 1 | Agent Presence | 4 | 5 | **20** | x | |
| 2 | Time Fold | 5 | 4 | **20** | x | x |
| 3 | Hinge as CSS variable | 4 | 4 | **16** | | x |
| 4 | Agents' Room | 5 | 3 | 15 | x | x |
| 5 | Diff Book | 5 | 3 | 15 | x | x |
| 6 | Point and Say | 3 | 5 | 15 | x | |
| 9 | Crease Pocket | 3 | 5 | 15 | | x |
| 7 | Grown Controls | 4 | 3 | 12 | x | |
| 8 | Peek Angle | 4 | 3 | 12 | | x |
| 11 | Hinge Dial | 3 | 3 | 9 | | x |
| 10 | Fold to Hand Off | 4 | 2 | 8 | | x |
| 12 | Threads | 3 | 2 | 6 | x | |
| 13 | Stitched Desk | 3 | 1 | 3 | | x |

They compose: Presence (#1) is the substrate for Point and Say (#6) and Diff Book (#5); `--hinge` (#3) is the
substrate for Time Fold (#2), Peek (#8) and Hinge Dial (#11). Building #1 and #3 first makes the rest of the list
cheap. Moonshot to keep in view: Agents' Room (#4).

## 4. Top 3: 1-day plans

Each runs in the browser mock first (`shell/dev/gate.sh`), then the phone through the normal queue. Owners per the
handbook: shell work by the owning expert (presence: powos-shell-dev + powos-comms for the agents feed; hinge:
powos-android-dev + powos-gestures; time fold: powos-shell-dev).

### Day 0, shared by #2 and #3: hinge plumbing (half a day)

```
SensorManager TYPE_HINGE_ANGLE (API 30)  ─┐
WindowInfoTracker FoldingFeature posture ─┼─> ShellBridge.kt emit "fold.changed" {angle, posture, display}
DisplayManager (which panel is ON)       ─┘        (throttled: 30 Hz while changing, nothing at rest)
                                                   │
types.ts Bridge: fold.changed event ── bridge.ts mock: a dev slider (keyboard [ / ])
                                                   │
shell/ui/hinge.ts: signal angle -> :root --hinge (0..1), html[data-posture=closed|deck|flat]
```

- First check (read-only, queued): `dumpsys sensorservice | grep -i hinge` and `cmd device_state print-states` on the
  phone: does the Open expose TYPE_HINGE_ANGLE, and at what angle does the inner panel turn on? If no sensor: root
  read of the hall/hinge input node; FoldingFeature alone gives only flat/half-open.
- Unregister the listener when the screen is off; 0 frames at rest holds.

### Top 1: Agent Presence (1 day)

1. `shell/ui/presence-map.ts`: file -> selector for the ~15 main surfaces (from the handbook's owner table).
2. `shell/ui/presence.tsx`: subscribe to `agents.ts` rows + `recent`; for each working agent whose last tool hint is
   an Edit/Write on a mapped file, place an avatar badge (role initial, `.tile` material, no border) at the selector's
   rect; off-screen -> edge chip. Max 3.
3. On a deploy note for a mapped file: a single ring animation on that surface + "changed by <role> · undo" (undo =
   manager ask, no new path).
4. Mock: two fake agents in `bridge.ts` editing `drawer.tsx` and `control.tsx`. Gate shots: home, drawer, CC with
   badges; contrast passes; idle check passes.
Done = renders in gate + one phone screenshot via the verify queue.

### Top 2: Time Fold (1 day, after day 0)

1. `shell/dev/history-shots.sh N`: for the last N commits touching `shell/`, render `gate.sh --shots` of home + CC +
   drawer into `shell-history/<sha>/` with the commit subject; push that folder to the phone's shell-data.
2. `shell/ui/timefold.tsx`: armed by side button held + angle < 150°; maps 150..90° to N frames with a snap + haptic
   per frame; cover/strip shows the subject line; flat = apply, closed = cancel.
3. Apply = a manager ask "revert shell to <sha> for <surface>" on the board, not a direct push (the agents own
   shipping).
4. Mock: slider drives it; gate shot of the scrub state.
Done = scrubbing in the mock and on the phone with real history frames; apply lands as a board item.

### Top 3: Hinge as a CSS variable (1 day, after day 0)

1. `theme.css`: `--hinge` default 1; posture attribute rules.
2. Three surfaces: home pages fan (`transform: rotateY()` per half by `--hinge`, transforms only), AI pill moves to the
   lower half in `deck`, switcher cards tilt like pages. Layout changes only on posture change, never per angle.
3. Measure: frame time while opening at 120 Hz (`tools/phone/cdp.sh raster`), must stay under budget; idle = 0.
4. Gate shots at `--hinge` 0.3 / 0.6 / 1.0.
Done = the three surfaces follow a slow open on the phone with no dropped frames, and nothing moves at rest.

## 5. Open facts to establish first

- Does the OnePlus Open expose `TYPE_HINGE_ANGLE`, at what rate and noise? (blocks #2, #3, #8, #11)
- Can both panels be on at once (a concurrent device state, as Pixel Fold's dual-screen mode)? (blocks the two-face
  variants of #4, #8 and cover-while-open ideas)
- Can KWin keep a virtual output rendering while the inner panel is off, and what does it cost in mW? (#4)
