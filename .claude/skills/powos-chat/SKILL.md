---
name: powos-chat
description: Use when changing PowOS AI's chat - how the manager's messages render (tool steps, choice cards, presentations, Markdown), the manager's present/present_choices tools, its event stream, or the phone's PowosAiChat items.
---

# PowOS AI's chat: how a manager turn becomes what the user sees

## The path
1. The phone (PowosAiChat.kt) runs one turn per message inside PowOS: `powos manager --once-stdin --json-events`
   (lib/ai/manager/manager.sh -> manager.py over `claude -p --input-format stream-json`).
2. manager.py normalizes claude's stream to one JSON event per line: `assistant {text}`, `tool_use {name, hint}`,
   `tool_result {ok, text (160 chars, one line: the terminal's), out (2 KB, lines kept: the chat's)}`, `turn_done`,
   `inbox`, `session`.
3. PowosAiChat.kt keeps items (User / Assistant / Tool{name,hint,ok,out} / Note, last 300, a JSON-lines file) and
   hands them to the shell as `ai.chat` / `ai.changed` (types.ts ChatItem). Unknown event kinds are dropped - a new
   kind needs an APK; a new block inside assistant text does not.
4. The shell renders: chat.tsx (the drawer's chat, the one chat surface) and powai.tsx (the AI page's latest turn +
   history) both go through ui/rich.tsx: `Thread` folds consecutive tool items into one `ToolRun`, `Said` splits an
   assistant text into prose (Markdown via md.ts) and blocks.

## The fenced-block protocol (manager.py `_rich_block`)
The comms MCP has `present_choices {question, options[2-8], multi}` and `present {title, format md|html, body}` -
registered only when COMMS_AGENT_ID=manager (the only stream a chat renders). The tool itself just answers the model
("end your turn"); manager.py, on seeing the tool_use, emits an extra assistant event whose text is
    ```choices            or        ```present
    {one JSON line}                 {"title":..,"format":..,"body":..}   (body capped at 64 KB)
    ```                             ```
So any consumer of the stream gets it (the KDE plasmoid shows it as code). Only these two names are blocks
(rich.tsx BLOCK); every other fence is code inside the prose. Tools named present / present_choices are hidden from
tool runs (shownElsewhere). AskUserQuestion is disallowed for the manager (--disallowedTools): headless, nobody can
answer it.
A choice tap = askQueued(option) (multi: joined ", "); "other…" = openAssistant + focus the pill. A card counts as
answered when a user item follows it (Thread passes `reply`); then only the question stays.

## Security
- Android injects the app's JavaScript bridge into EVERY frame, iframes included. HTML presentations therefore get
  `sandbox=""` (no scripts) + a CSP meta (`default-src 'none'; img-src https: data:; style-src 'unsafe-inline'`).
  The theme's text colour is injected as values (the frame can't read the shell's tokens); no color-scheme (a
  mismatching one paints an opaque canvas).
- md.ts escapes everything first; links only http(s) (opened outside via apps/native.ts openLink, data-link), images
  only https/data:image. Test it with hostile input (`<script>`, `javascript:` links) after any change.

## Shipping and what bit
- The gate (shell/dev/gate.sh) refuses a push when a local file a page names (html href/src, a script's "./ui/x.css")
  isn't in what the phone will serve: an index.html override once named ui/rich.css before rich.css was there. Push a
  page with what it names, in one push.
- An APK install resets every override (handbook Shipping): only what is on origin survives it.
- Before pushing, compare the installed APK's shell (~/.cache/powos-gate/installed/<key>/shell) with yours.
- manager.py / comms-mcp.py reach the phone only through `targets/android/rooted/rooted.sh deploy --note ".."` (with
  `PATH="$PWD/tools/phone/bin:$PATH"` so its plain adb goes over the VPN; it installs lib/ai/manager since a27042e). Check inside PowOS:
  `tools/phone/root.sh` a script that greps /usr/lib/powos/ai/manager/manager.py and runs comms-mcp.py tools/list with
  COMMS_AGENT_ID=manager.
- No endless animation (the compositor re-blurs every frame): a running step is a still accent dot.

## Tests
- `python3 test/tier1/test-manager.py` (RichBlockTests), `python3 test/tier1/test-comms.py` (PresentTests).
- Shell: link node_modules into your worktree's shell/ (`ln -s <other>/shell/node_modules shell/`; ignored by
  .gitignore, so ship-apk's clean-tree check is fine), then
  `shell/node_modules/.bin/tsc --noEmit -p shell` and
  `SHOTS_ONLY='^(chat|chat-open|ai-chat|present|present-md|present-html)$' shell/dev/gate.sh --tree --shots DIR`
  (sample conversations: CHAT_SAMPLE / PRESENT_SAMPLE in shell/dev/shots.mjs). Read the PNGs and report.json's
  lowContrast. The headless font has no bold face: check bold on the phone.

## The AI page (shell/ui/powai.tsx) - v2, approved 2026-10-22
- Order: NeedsYou (status "waiting" rows only, 3 cards + "N more"; the note is the action line, written as an
  imperative by the agent) -> Earlier (folded "earlier · N") -> Now (the last exchange: asked + SentImages, ToolRun,
  Said of the trailing assistant items, Queued) -> board tile (Work, Units, Agents) -> AtWork -> FromAgents.
- Done / skip on a needs-you card post "Done: <action> (task <id>)" / "Skip for now: ..." through askQueued: the page's
  SpacetimeDB connection is not a reporter, so it can't call work_set. The card hides locally until `updated` changes.
- Work: "working" rows only; blocked -> folded "paused · N"; done in 24 h -> folded "done recently · N"; grouped by
  project only past 6 (GROUP_OVER). No chips, no status text. Owner on every row ("free" for "" or the catch-all
  "coder"). Tracked rows (progressTotal/step/commits): a 3 px bar, the step, "N/M · K commits · 2h ago"; a tap opens
  steps (✓ done / filled dot now / ring next - drawn in CSS, a font drew "●" as an orange emoji), commit subjects only
  (never hashes), review images. Columns (comms expert's f3ad83d): progressDone/progressTotal, step, steps (JSON
  [{text,state}]), commits (JSON [{sha,subject}]), images (JSON [path]), activity (ms; 0 -> updated). Optional in
  WorkRow, so an older binding still compiles. Board CLI: `powos agents task set <t> --plan "a; b" --step x
  --progress 3/10 --commit SHA --image PATH`; a --step that isn't a plan item is inserted as current. Write a row's
  whole history directly with the work_track reducer (the CLI's `call`) when the CLI's merge gets it wrong.
- Renders: scenes ai-v2, ai-v2-actions, ai-v2-open, ai-v2-calm, progress, progress-open, queued, queued-ai, kbd-*,
  mail in shots.mjs, from shell/dev/sample-board.json (the live board, ages as offsets; refresh it from
  `powos agents task list --all --json` inside PowOS). shots.mjs serves /_qa/ from shell/dev/.qa/ (untracked: remove
  it before ship-apk - build-app refuses untracked files under shell/).
- Wide (page >= 700 CSS px: unfolded 821, a desktop window; powai.tsx useWide = ResizeObserver on .ai-screen, never the
  device): `.ai-screen.wide` is a grid - header across, left `.ai-talk` (Earlier + Now, <= 70ch) with the pill under
  it, right `.ai-side` (NeedsYou, board, AtWork, FromAgents) the full height; each its own `.ai-scroll`.
- ONE component for every AI surface: powai.tsx `AiView` (header + one column / two panes by its own width + pill) is
  the page (PowAiPage), home's AI pull-up panel (home.tsx) and the pull-up over apps (pull.tsx, mode=pull). Never mount
  AiHeader/AiContent elsewhere. Wide CSS is `.ai-view.wide`; a narrow panel uses home's bar as its pill (pill={false}),
  a wide one its own (the bar hidden). Shots: ai-panel-wide, pull-ai-wide. Task rows: bar + "N/M · step" ABOVE the
  title, then "owner · K commits · ago" (rich.css .ai-item-row grid). AiContent's
  `part` ("talk" | "side") renders a pane; none = the one column (folded, the pull-up and drawer panels). Toggling
  remounts the panes (open rows close) - only on fold/unfold. Shots: scene ai-wide (WIDE_SIZES adds a 1600x1000
  window; a scene's 6th field = its sizes). Device: tools/phone/verify/ai-wide.sh (inner screen forced, read-only CDP).
- shot.sh/gate.sh --shots DIR must be under $HOME (Colima shares only home; /tmp gives EACCES on /out).
- Contrast: text on the AI page's frost reads ~4.0-4.4 over a bright wallpaper even in foreground - that's the frost
  (design owns it, token level); don't fix per text. Folds on the wallpaper get --on-wallpaper + --label-shadow.

## Test now (queued phone checks) and the live board
- A row whose step is exactly "phone check queued" (tools/phone/verify/queue.sh QUEUED_STEP; powai.tsx QUEUED_STEP) gets a
  quiet "test now" under it, the header "test all"; the tap calls powos.ai.verifyGo(id|"all") (bridge verify.go,
  VerifyRun.kt: writes PowOS's /tmp/powos-verify-go; the Mac's runner takes it within 5 s). "testing… don't touch the
  phone" until the step changes (or 20 min). Result steps "verify PASS: .." -> "check passed", "verify FAIL rc=N: .."
  -> "check failed: <line>" + the last design-qa/verify-*.png inline. An older APK: "test now needs the newer app".
- The header says "checks paused · resume" instead of "test all" while checks are queued and the runner is paused
  (the pill's tap) or silent (no beat for 45 s): powai.tsx asks powos.ai.verifyState() every 15 s while shown
  (VerifyRun.state -> "verify.state" {state, age}); the tap is verifyGo("all"), which ends the pause. A host without
  verify.state never answers: nothing shows.
- The board went stale after edits: a socket Doze cut silently stays "connected". stdb.ts checkAlive(db, query): one
  more subscription when the board comes into sight; not applied in 4 s -> a new connection. Scenes: test-now,
  test-now-testing.

## Queued messages (one queue for every chat)
- The app owns it: PowosAiChat.send while busy appends to `queued` (id, text, prompt) instead of dropping; at turn end
  the next one runs before the inbox's turn; `ai.chat` carries `queued`, `ai.unqueue(id)` takes one back. Lost on an
  app restart (in memory).
- assistant.ts: `waiting` (computed: the host's queue, else the page's own `pageQueue` for an older APK with no
  `queued` field), `unqueue(id)` (negative ids = page queue). The AI page's field goes through askQueued too.
- Rendered by rich.tsx Queued: right-aligned words, no bubble yet, "queued" + x. Checked on the phone: 3 sends during
  a 40 s turn, the x removed #3 (never sent), #2 ran as its own turn.

## Keyboard / nav padding (shell.css)
- The page's insets come from the host as --inset-bottom (nav ~16 px folded) and --inset-keyboard (app.tsx applyInsets,
  per page, also the assist page). The pill sits var(--pill-foot) (6 px) above the keyboard plus its own foot: .home
  padding, .ai-compose margin, and html[data-mode=assist] .assist padding all add it. The gap under the IME's keys
  belongs to the keyboard app. Mock a keyboard in shots: E.emit('system.insets', {..., keyboard: 330}).

## Agent mail cards (rich.tsx MailCard)
- PowosAiChat turns an inbox event into a note "mail from <agent>: <body>" (often "coder: coder: ..."). mailOf()
  parses it; chat.tsx and powai.tsx render non-error mail notes as MailCard: folded = who + first plain sentence
  (hex 7-40 tokens and "(hash)" groups stripped, leading "ack -" dropped); open = md() of mailMd(): status words
  SHIPPED / IN PROGRESS / BLOCKED / DONE / NEXT / WAITING anywhere -> "##### " headers, " - " runs -> a list,
  design-qa paths removed from the text and shown as /_qa/ thumbnails. No time: notes carry none.

## Image routes in ShellHost (security boundary: bridge-security rules apply)
- /_qa/<name>: /home/powos/design-qa review images (work board --image). /_shared/<name>: the images sent to the
  manager - the app's own filesDir/run/powos-ai-shared, which PowOS sees as /run/powos-app/powos-ai-shared (side
  button screen-*.jpg, circled part screen-*.png, live-*.jpg, shares under their display name).
- Both through QaFiles.resolve(dir, raw): raw = url.encodedPath after the prefix, NEVER decoded (so %2F/%2e%2e can't
  form a path); ^[A-Za-z0-9._-]+\.(png|jpg)$ and no ".."; canonicalFile (symlinks followed) must have the dir itself as
  parent. Different dirs never cross.
- /_qa/: PowOS's files are labelled system_data_root_file, which the app may not read -> QaFiles.sync(cache) is one
  fixed root command copying the folder's regular png/jpg files (no symlinks) into cacheDir/qa (at most every 5 s);
  no request name ever enters a shell string. /_shared/ is the app's own dir: read directly, no root.
- Tests: QaFilesTest (8: traversal, encoded, types, missing, symlink out, shared dir, command has no name). Run them
  like compile-check.sh but with `:app:testDebugUnitTest --tests dev.omalauncher.shell.QaFilesTest`; results in
  targets/android/app/app/build/test-results/testDebugUnitTest/. "Timeout waiting to lock journal cache" = another
  build holds gradle: retry, it's not a code error.
- Page side: qaUrl() and sentImages() accept only the same names. sentImages(text) finds
  /run/powos-app/powos-ai-shared/<name> in the STORED user text (the side button's context lines name them), so the
  history keeps them; "the part of the screen I circled: <path>" -> only that one. A missing one says "image no longer
  available" only after some /_shared/ image loaded this session (an older APK has no route: show nothing).
- Device probe (read-only): tools/phone/cdp.sh eval home with a sync XMLHttpRequest per URL -> 200 / 404.

## Device checks that worked
- Screencap: `tools/phone/adb.sh exec-out "screencap -d 4630946316123810436 -p" > file.png` (cover screen; adb.sh pull
  into a dir that doesn't exist yet fails). AI page: home, then `input swipe 120 1300 1000 1300 250`. cdp.sh eval
  does not await promises (an async IIFE returns {}). A pushed module shows on the live page only after its reload
  (the page picks it up later; never force a reload while the user is on it).
- ship-apk can wait silently for a long time behind other agents' ships (empty output); check the installed build's
  lastUpdateTime against your commit before concluding it's missing, and whether another agent's build from origin's
  tip already carries your commit ("already shipped").
