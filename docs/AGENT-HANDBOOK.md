# Agent handbook: how the PowOS phone pieces connect

Read this first; it replaces digging through the code. Keep it current when you learn something an agent had to dig
for (one line each). Cross-cutting rules live HERE once; expert skills (.claude/skills/powos-*) link to them.

## Which expert owns what
Route work to the owner's SKILL, not to a long-lived agent: each task is a FRESH agent that loads the owner's skill
(.claude/skills/<owner>/SKILL.md + .claude/agents/<owner>.md), does that one task, writes what it learned into the
skill, and exits (see Efficiency). The Skill tool's catalog is fixed at session start, so it can't see a worktree
`tools/agents/worktree.sh new` just created in THIS session - it errors "Unknown skill" or lists only other
worktrees' scoped variants even though the new worktree has an identical SKILL.md; `Read` the file directly
(`.claude/skills/<owner>/SKILL.md`) instead of waiting on the Skill tool (friction f143). Changing another owner's file: message the owner (with numbers), or make the
minimal change and tell them. Default subagent model is **Sonnet**; reach for Opus only for hard debugging (a root
cause that resists two Sonnet passes), not routine work - it costs more and the context budget below is the same
either way. Keep briefs SHORT: point at this handbook and the owner's skill rather than re-explaining what they
already cover; a brief that restates handbook/skill content is itself a hand-off that will drift from the source.

| area | agent (skill of the same name) |
|---|---|
| app drawer / launcher panel, its drag + fade, recents row, A-Z bar, search pill spacing | powos-drawer |
| look and feel: design language, theme tokens, shade + notifications, control center, contrast, review renders | powos-design |
| the pet's body, states, bubbles, local.pet app + `powos pet`, pet-over-apps window | powos-pet |
| the pet's movement: petphys/petai/petmove/petperch, its frame cost | powos-pet-physics |
| dictation: Speech.kt, GpuSpeech.kt, dictation.ts, push-to-talk, side button | powos-speech |
| idle CPU, frames at rest, nativeglass.ts cost, profiling tools (cpu.sh, cdp.sh, idle-sample.sh) | powos-perf |
| GPU servers gpu-195 / .58, llm.pow / stt.pow / voiceagent.pow, model loads, benches | powos-gpu-servers |
| home widgets: shell panels, OWL (.owl), app islands (Lights), preview tool, widget gesture ownership | powos-widgets |
| edge gestures, Quick Tools, corner pull-ups over apps, overlay window hosts, home pull -> shade | powos-gestures |
| inter-agent comms (`powos comms`, MCP), manager inbox, agentsd, agent-mail notifications | powos-comms |
| SpacetimeDB modules, vendored bindings, shell/apps/stdb.ts, bindings-check, publishes | powos-stdb |
| games: Steam/Proton/FEX on the phone, Broforce checks, xwayland-kgsl, phone kernel build/test boot/flash/rollback | powos-games |
| swipe home, recents switcher, NavGesture/RecentsTransition, page-after-home, wallpaper capture | powos-switcher |
| native bridge security: PowosHost/Native/Boot, ShellOrigin, iframes, bridge-check.sh | powos-bridge-security |
| PowOS AI's chat: rich messages, present/present_choices, PowosAiChat items | powos-chat |
| on-device verification (journeys, frame-stepping, idle CPU samples, Broforce), closing board items with evidence | powos-verify |
| the desktop shell: powos-shell (Plasma host), hosts/desktop.ts, mode=desktop, dev/phone.sh | powos-desktop |
| other shell (web UI) work no expert owns | powos-shell-dev |
| other Android app (Kotlin) work no expert owns | powos-android-dev |

## Efficiency (the user, 2026-10-22: "insanely inefficient" - measured: 534k context per call, 13% of tokens
## waiting on the phone, 48% of commits process tooling; `tools/agents/efficiency.py` measures it, targets in its doc)
- ONE task per agent run: pick up, ship the slice, put what you learned into your skill (facts, <=100 lines, no
  history), the open rest into the board task's note, exit. Never stay alive waiting for mail, a window or a review.
  Tasks are scoped to ~5 min: one finding or one fix; leftovers go to a fresh agent via the hand-off (`.claude/hooks/
  agent-notices.py` reminds at 4 min, then every call past 5 - `tools/agents/efficiency.py` flags agents over 5 min).
  Context budgets are now MECHANICAL, not something to self-police: **hand back by 120k, never resume an agent past
  150k.** `.claude/hooks/agent-notices.py` reads your own transcript on every tool call and reminds you on your next
  tool result - once per 20k over 120k, then on EVERY call once you're over 150k - so you don't have to track the
  number yourself; the coordinator session gets the exact same reminder. A hand-back note is <=400 words: what's
  done, what's left, the exact next command, and a **"Friction & missing info" list** (below) - not a transcript
  (nofate/br goliath: restarting from a note around there cut cost per match from $1.57 to $0.62).
  `tools/agents/efficiency.py` flags any agent whose calls went past 150k (`over_budget`) in its per-agent report and
  in its misses.
- Land with ONE call: `tools/agents/land.sh "msg" -- <paths> [--task <id> --step "..."] [--ship "note"] [--queue
  <check args>]` commits your paths, rebases once and pushes, moves the board task, requests a ship and queues a
  phone/emulator check - then END YOUR TURN. It replaces the old five-call recipe (commit, rebase, push, task set,
  ship request, queue add separately) that drove 122 git-sync calls + 73 commit/push in 4h (efficiency.py). Never
  `idle.sh --wait`, sleep, `until` loops, run ship-apk.sh/push.sh yourself, or re-read a verify-queue/ship result
  yourself - the PostToolUse hook (.claude/hooks/agent-notices.py) puts new comms mail, finished verify-queue
  results and ship results on your next tool result once, instead of you polling for them.
- Caps: tool output over ~8k chars goes to a file with a 3k head kept inline - read the file for the rest only if
  the head isn't enough (on nofate/br's trial, results over 8k were 23% of all result text, and agents read past
  the head in only 22% of cases: most of that was wasted context). A background job's output rides on your next
  tool result too (the PostToolUse hook, above), capped at ~2.5k chars per job. Scripts that wait on the phone
  via `idle.sh --wait` (ship-apk.sh, perf-window.sh, journey.sh, window-lock.sh) chunk it at ~4 min per call and
  print a progress line between chunks, instead of holding one Bash call past the model's 5-min prompt-cache
  window - follow that pattern for any new wait, never pass `idle.sh --wait` a multi-minute budget directly.
- Read narrowly (grep, then `sed -n a,b`); never re-read a file you read. Change code with targeted edits (Edit), not
  whole-file heredocs.
- Git: rebase only right before you commit/push, not before every command. Commit subject <= 72 chars, a short body.
- Tracked files under the gitignored `.claude/` (skills): `git add` refuses them; `git commit -m ... -- <path>` works.
- Never edit a shell script while it runs (a build, the runner): bash reads it as it goes, so an insert shifts it and the rest runs garbage (the 2026-10-23 kernel build died at its last steps). Wait, or edit a copy.
- Gates queue: 2 agent gates at once (niced), a 3rd waits for a slot; the ship's (GATE_PRIORITY=ship) never waits.
- No new process tooling (locks, gates, wrappers, handbook rules) unless something actually broke; say what broke.
- Messages: shipped results or blockers only, one line.
- Never ship a UI control whose backend isn't installed (manager, 2026-10-22: a "test now" button shipped before its APK
  bridge): gate it on the bridge capability (feature-detect the method) so it stays hidden until the APK lands.
- A task is DONE the moment it's shipped and checked (manager, 2026-10-22): never leave it at "3/3 working". If the
  device check is its last proof, queue it with `queue.sh add --close` so the pass closes the task (The work board).
- One task per piece of work (manager, 2026-10-22): before adding a board task, search the board
  (`powos agents task list`, grep the title) and reuse the manager's existing one with `task set`; create one only
  when none exists.
- Board wording (manager, 2026-10-22): notes are plain words for the user, no commit hashes; status `waiting` only for
  something the USER must do (it shows as a Needs-you card), never for a queued check or another agent.
- Worktrees: `tools/agents/worktree.sh new <name>` (origin tip, shared node_modules), `done <name>` once pushed (refuses
  unpushed/uncommitted work), `list`. Never leave a merged worktree behind. It exists only on
  `origin/worktree-powos-multiplatform`, not on `master` (friction f132) - from a bare master checkout (or anywhere
  outside a PowOS worktree), bootstrap it first: `cd ~/Projects/PowOS && git fetch origin worktree-powos-multiplatform
  && git show origin/worktree-powos-multiplatform:tools/agents/worktree.sh | bash -s new <name>` (the `cd` matters:
  the piped script resolves its own repo from `$PWD`, not from a `git -C` on the `show` half alone - run from
  elsewhere and it fails "not a git repository").

## Overhead lessons (nofate/br, SpaceTimeAI)
- Cost is dominated by re-reading context, not by doing the work - every call pays again for everything already
  said, so the fix is always "say it fewer times," not "think harder."
- Restart from a short note around 120k-150k context, not a live hand-off (nofate goliath: $1.57 -> $0.62/match).
- Notes (mail, finished checks, ship results) ride on the NEXT tool result (the PostToolUse hook) instead of a
  poll or a wait.
- One `tools/agents/land.sh` call instead of a commit/rebase/push/task/ship/queue sequence.
- Waits are capped (~4 min/call) and resumable, never a single call held for an hour.
- Routine, high-volume agents use a cheaper model; save the expensive one for judgment calls.

**Hand-off (2026-10-24, the three pieces above):**
- The hook (`.claude/hooks/agent-notices.py`, PostToolUse, project `.claude/settings.json`) reads three LOCAL
  files only - no adb, no network - so it stays fast and safe on every call: your comms inbox
  (`~/.local/state/powos/comms/agents/<role>/inbox`, role = `COMMS_AGENT_ID`/`POWOS_AGENTS_ROLE`/your worktree's
  basename - a git-worktree agent has neither env var set by default, friction f135), finished verify-queue jobs
  whose `from=` is your worktree root, and ship results whose `who=` is your worktree's basename (both fields
  exist already in queue.sh/ship.sh, undocumented until now - friction f139). Dedup state:
  `~/.cache/powos-agent-notices/<worktree>.json`.
- `land.sh` validates a path via `git status --porcelain --ignored=matching` (plain `--porcelain` hides an
  ignored-but-meant-to-be-tracked new file, e.g. under `.claude/`) and stages with `git add -f` for the same
  reason. One retry on a push race only; a real rebase conflict aborts and keeps your commit local.
- Caps: only perf-window.sh and journey.sh needed chunking (window-lock.sh/ship-apk.sh/edge.sh already chunked,
  at 180s/600s/180s - lowered ship-apk.sh's to 240s). `idle.sh` itself is still unbounded if called directly
  with a large budget - chunk at the call site, following window-lock.sh's loop.

## The work board: nothing falls through (the user, 2026-10-23: "30 tasks show working, 4 agents run")
- Each task's state is COMPUTED from facts (`task list` and the AI page; lib/ai/agents/powos-agents-cli truth(),
  shell/agents.ts boardState): `working` only while a live agent holds it (its own `task set <id> --step/--progress/
  --plan/--commit`; `--owner` claims nothing), `awaiting-check` (a phone check queued), `no-check` (nobody on it, no
  check queued, but a FAIL/INVALID/SKIP, an unclosed pass or a pushed fix), `stalled` (nothing: it needs an owner),
  `blocked` (blocked/waiting + the note as the reason), `done`. The status column is only what someone typed.
- Claim by moving: the first thing a fresh agent does is `task set <id> --owner <expert> --step "<what now>"`. A
  subagent's role is "general-purpose", so the owner-role fallback rarely finds it - the --step claim is what counts.
- Done = its phone check PASSED on a shipped build (the module's work_set refuses anything else). Queue the last proof
  with `queue.sh add --close <task> <check>` (the pass closes it); a task no device check can prove closes with
  `task done <id> --no-check "<why>"` (docs, Mac tooling with a tier-1 test). Never report "done" for pushed/queued.
- Facts: the verify queue writes each queued job and result to the module's work_check rows (`powos agents check
  set`); the Mac's sweeper (launchd com.powos.board-sweep, tools/agents/board-sweep.sh, every 30 min: each digest wakes the coordinator for a full turn) re-syncs the
  whole queue dir (`check scan` -> `check sync`) and runs `powos agents sweep` on the phone.
- The sweep mails the coordinator ("coder") ONE digest: orphans (stalled, no-check: FAILs nobody picked up),
  blocked-without-reason, user asks with no task, new or recurring friction - only what's new or changed since the
  last pass (state ~/.local/state/powos/board-sweep.json on the phone). The coordinator staffs each item: an owner +
  a fresh agent that claims it. `tools/agents/board-sweep-deploy.sh run` sweeps now; `status` shows its log.
- Queued phone checks: at most ONE watcher per job (no duplicate until-loops on the same log). If the checks need more than ~10 min (a ship plus a free window), don't idle: hand back with the job ids and what each one proves; whoever continues reads the results (2026-10-23: one agent ran 5 watchers on one job, and another woke 8+ times waiting, wait/poll at 18%).
- Before EVERY SendMessage that adds work, check the agent's context in the last task notification (subagent_tokens / efficiency.py): past 150k, hand the work to a fresh agent instead (2026-10-23: I gave a 289k agent an urgent regression anyway).
- Never resume (SendMessage) an agent whose context is past 150k (`tools/agents/efficiency.py`'s `over_budget`): start a
  fresh one with its last report (including its Friction & missing info list) as the brief. Resuming the 365k games
  agent for a kernel fix cost ~58 Mtok in 4 h.
- User asks: the manager records every user turn (asks.jsonl + the user_ask table) and gets its id with the turn; it
  links the task it makes (`task add ... --ask <id>`) or marks it not work (`ask none <id> --reason`).
  `powos agents ask list --untracked` = asks with no task.
- Mac: `python3 lib/ai/agents/powos-agents-cli task list --state stalled` (it runs on the phone's board). Never
  delete tasks to tidy the board (`task rm` is for a mistake/duplicate you made).

## Friction: log it before you work around it
- Hit a refusal, a broken or flaky tool, an unclear rule, something slow? FIRST `tools/agents/friction add --area
  <ship|gate|verify|board|comms|permissions|worktree|phone|apk|...> --kind <refused|broken-tool|flaky-check|
  unclear-rule|slow|other> "<title, one line>" --repro "<command or steps>" --details -` (stdin: what you did, saw,
  expected, how you got around it; `--evidence <log>`). On the phone: `powos friction add`. --repro is required.
- The same area + kind + title (numbers and hashes ignored) counts up instead of adding a row. `friction list` (most
  frequent first), `friction show <id>`, `friction fix <id> --commit <sha>` once fixed for good - it reopens if it
  happens again.
- Logged by the tools themselves: ship failures/refusals (ship.sh), shell gate failures at Mac load >= 12 (gate.sh),
  INVALID/SKIP checks (queue.sh), permission refusals of an agent's tool call (powos-agentsd, from the hook).
- Triage: the sweep's digest lists new/recurring friction by count; the coordinator turns the top ones into fixes.
- **Every hand-back does a full review of its own friction, before handing back, not just when something broke
  outright.** Go back over the task and ask: which tool fought me, which check misled me, which piece of info did I
  have to dig for that should have been one lookup? Log each one with `friction add` as you find it - a tool that
  refused or was flaky is `--kind refused`/`broken-tool`/`flaky-check`; a piece of info that should have been in a
  skill, this handbook, or a command's `--help` but wasn't (or was wrong/stale) is `--kind unclear-rule`, area = the
  skill/doc/command it belongs in; something that took far longer than it should is `--kind slow`.
- Your hand-back note ends with a **"Friction & missing info" list**: one line per item - what fought you, the
  friction id you logged it under, and where the info should have lived (skill name, handbook section, or "`<cmd>
  --help`"). The list is a summary of friction you ALREADY logged with `friction add`, not a substitute for logging
  it - log first, then list what you logged. Nothing to report = say so ("none this task"), don't skip the section.

## Retro after every agent (the user, 2026-10-24: "remove all future friction the agent encountered")
- When an agent hands back, run `tools/agents/retro.py <agent-id> [--json]` on its transcript before staffing
  the next piece of work - it digests what got in that agent's way in <=60 lines: permission refusals, tool
  errors grouped by cause, retries/loops, information hunts (a read/grep/find run before the first edit, a
  file re-read 3+ times - these are a missing skill/handbook line), waits/long sleeps, checks that misled it
  (a FAIL later called "not a real failure"), and the friction it logged itself (+ whether already fixed).
  The agent-id is the transcript's filename minus `agent-`/`.jsonl` (same id efficiency.py's by_agent uses).
- `tools/agents/retro.py --since 4h --all` digests every agent finished in the window, ranked by tokens
  wasted, for a periodic sweep instead of a per-agent one.
- `tools/agents/retro-apply.md` is the procedure: a short Haiku/Sonnet agent reads the digest, makes the
  small doc/skill fixes itself, and logs everything else as a friction cluster (`tools/agents/friction add`)
  rather than patching code inline - never a long-lived agent for this.
- Never print a transcript's raw tokens or secrets; `retro.py` redacts known secret shapes - if you extend it,
  keep that.

## Reaching the phone (OnePlus Open, rooted)
- `tools/phone/adb.sh <adb args>`: adb over the VPN (powos-vadb's server, 10.13.13.7:5555) from any session.
  Files you push must be under `$HOME` (Colima shares only the home directory). After a Colima restart powos-vadb may
  be stopped: `docker start powos-vadb`.
- `tools/phone/root.sh <script>`: run a local bash script as root INSIDE PowOS (chroot of /data/powos/root).
- `tools/phone/user.sh <script>`: the same as the session user powos (its comms inbox, spacetime token, `powos ...`).
  One-liners as the session user: `tools/phone/adb.sh shell su -c "sh /data/powos/powos-run.sh '<cmd>'"`.
  NEVER `sudo` through powos-run.sh: it pops a password dialog on the user's screen.
- Screencaps: ONLY `tools/phone/shot.sh OUT.png [--all]` (never a bare `screencap`). It takes the display that is ON
  (cover folded, inner unfolded), refuses when the screen is off (exit 3, never wakes it) and flags an all-black
  result (exit 4, with the likely reason: a FLAG_SECURE window, or a window still at alpha 0). The black caps of
  2026-10-22: `screencap` without -d takes the FIRST display = the inner screen, black while folded; a hard-coded
  cover id is black while unfolded; and a capture after the screen dozed is black. On-phone scripts: pick the ON id
  from `dumpsys display` (DisplayDeviceInfo ... state ON), as tools/phone/verify/gest.sh does.
- `tools/phone/idle.sh` -> `idle=<s> screen=<Awake|Dozing|Asleep> act=<s>` (idle = seconds since a touch-panel IRQ;
  act = lastUserActivity, NOT a user signal). Drive the phone (input, screenrecord, journeys, session-restarting
  installs) only at idle>=120 and screen=Awake. Never wake the screen with key events (refused - don't route around it).
  To WAIT: `tools/phone/idle.sh --wait IDLE_S MAX_S` (one held call; the waiting runs on the phone; exit 1 = timeout).
  It also returns at once when the screen is off (fine for installs); for work that needs the screen on (recordings,
  journeys, CDP idle samples, screencaps) use `AWAKE_ONLY=1 tools/phone/idle.sh --wait 120 MAX_S` (waits through doze,
  never wakes it).
  `idle.sh --wait` itself is unbounded if given a large budget directly - chunk at the CALL SITE, one call at most
  ~240s, with a progress line printed between chunks (never hold one Bash call past the model's 5-min prompt-cache
  window). Chunking callers: `ship-apk.sh` (240s), `window-lock.sh`/`edge.sh` (180s), `perf-window.sh`, `journey.sh`.
  Any new wait helper follows the same pattern (friction f136).
- WebView devtools: `tools/phone/cdp.sh pages | eval <page> '<js>' | idle [secs] [page] | raster [secs]` (forwards
  the app's devtools socket again each call - the pid changes per install - and runs tools/phone/cdp.ts in
  powos-vadb's network; page = home/"" , lock, shade, assist, ...). READ-ONLY on live pages (see Rules).
- Logs: `tools/phone/adb.sh shell logcat -d -v time | grep <Tag>`; crashes `logcat -b crash`. App tags: PowosRecents,
  PowosGlassBlur, PowosBackdrop, PowosLiquidGlass, speech, PowosNavGesture, PowosSwitcher, PowosShell, PowosEdge,
  PowosPet. Batch several commands into ONE adb.sh call.
- Other tools: `tools/phone/cpu.sh` (per-process CPU), `idle-sample.sh` (perf), `review-image.sh FILE...` (review
  images -> /home/powos/design-qa/), `app-src.sh pull|push <app>` (a phone app's sources), `bindings-check.sh`,
  `bridge-check.sh`, `tools/phone/record/run.sh <tag>` (swipe-home recording), `tools/phone/verify/` (journeys,
  frames, edge.sh, Broforce). Every helper an agent relies on lives in the repo, never in ~/.cache or job tmp (Rules).

## Shipping
- Correlation fields an agent can read directly, no board query needed: a queued verify job's `from=` is the
  worktree root that queued it, and a ship request's `who=` is the worktree's basename - both already written by
  `tools/phone/verify/queue.sh`'s `add()` and `tools/phone/ship.sh`'s `request()`/`done_req()`. The PostToolUse hook
  (`.claude/hooks/agent-notices.py`) uses them to match finished jobs/ships back to the worktree that caused them
  (friction f139).
- **Agents never ship themselves.** Land with `tools/agents/land.sh "msg" -- <paths> --ship "plain words for the
  user"` (Efficiency, above) and END YOUR TURN - nothing else. That one call does what used to be spelled out here
  step by step: commit by pathspec, rebase once, push to origin/worktree-powos-multiplatform, then
  `tools/phone/ship.sh request --note "..."` (or `--silent` with no `--ship`). One ship service (launchd
  `com.powos.ship-runner`, unit ship-runner-mac, its own checkout
  .claude/worktrees/ship-runner) ships origin's TIP in two parts: push.sh of exactly the shell files that differ
  from what's live 10 s after the last commit, also while an APK is out; and, when Kotlin/APK inputs changed since the
  installed build, ship-apk.sh 60 s after it, beside the loop in its own checkout (ship-runner-apk). The notes of what
  each part makes visible go in ONE notification. `ship.sh status` shows requests, what's live and
  the last ships; a failed ship mails coder and waits for a fix on origin. ship-apk.sh and push.sh refuse to run
  outside the service; `--direct` (from origin's tip, logged to ~/.cache/powos-ship-queue/direct.log) is only for an
  emergency the user asked for. Why: per-agent ships raced (2026-10-23: ~6 APKs + ~15 pushes a night; an APK from an
  older tip twice wiped newer shell pushes). Hold all ships (a recovery on the phone): `ship.sh pause` - nothing new
  starts, a ship not yet installing is killed with its whole tree (lock freed, requests kept), an install in flight
  finishes; `ship.sh resume`. Remove it: `tools/phone/ship-deploy.sh remove`. Test: tools/phone/ship-queue-test.sh. What the service runs is below.
- Notes are only for what the user can SEE. A change they can't (refactor, lint, tooling, "behaviour unchanged")
  ships with `--silent` instead of `--note` (ship.sh request, and what it runs: shell/push.sh, ship-apk.sh, install-app.sh, deploy-note.sh): no
  notification, only a line in comms' quiet log (`powos comms quiet`).
### Shell (web) files (what the service runs: `shell/push.sh --vpn --note "..." <files relative to shell/>`)
- push.sh refuses any file that isn't byte-for-byte origin's version: a file is pushed whole, so a stale copy of a
  shared file (shell.css, gesture.ts, theme.css) from your tree overwrites another agent's newer push (16:24: the
  drawer fell apart into one column). Never `--force` past that; rebase and push again.
- It also refuses a file whose live copy on the phone is from a commit your HEAD lacks (phone's files/shell-commits.txt): "<file> on the phone is from <sha> (newer than your base): rebase first".
- The gate (shell/dev/gate.sh: tsc + every page booted headless) runs on what the phone will serve: the installed
  APK's own shell + the phone's current overrides + your files. It refuses only failures your push ADDS. It also
  refuses when a page names a local file (href/src, "./ui/x.css") or imports a module the phone won't have: push a
  file with everything it imports or names, in ONE push. Never bypass the gate.
- Then the bindings check (see SpacetimeDB below) in the same phone call.
- `shell/push.sh --errors [N]` = the phone's shell errors; `--reset [files]` removes overrides. A page that fails to
  boot within 2 min of a push is rolled back by the app and the manager told.
### APK (what the service runs)
- `tools/phone/ship-apk.sh --note "plain words"` is the ONLY way to build+install (never build-app.sh + install by
  hand), run by the ship service. It always re-executes origin's copy of itself, then: REFUSES (exit 3) unless HEAD == origin's tip and contains
  the last installed commit; takes the cross-agent lock (~/.cache/powos-ship.lock); runs the gate on HEAD's own shell
  (refuses if it doesn't load); builds (build-app.sh refuses a dirty shell/ or targets/android/app); waits for a free
  phone with `idle.sh --wait 60` in 10-min chunks (up to SHIP_WAIT_MIN=60, holding while ~/.cache/powos-verify.lock
  exists; no window = exit 4, APK kept, nothing installed); snapshots the installed APK + its exact overrides
  (tools/phone/ship-guard.sh; none = exit 3); RESETS ALL shell overrides BEFORE the install (pages that boot on the new
  APK with old overrides die, and a dead page never reloads: APK 29878476, 2026-10-23); installs; bindings-check; ONE
  push of every shell file origin's tip has differently from the APK's own assets/shell; then every page (home, shade,
  assist: window.__powosAlive) must boot within 2 min, else the WHOLE snapshot is restored (overrides off, previous APK
  `install -r -d`, its overrides back) and coder told (exit 6); prints versionCode + any crash. `--now` skips the wait: only with `--direct`, when the user asked for an immediate install.
- Those newer shell files are gated BEFORE the install, at origin's tip (`push.sh --pre-gate`; fails = no install, exit 3), and pushed seconds after the install with `--pre-gated=<stamp>` (only that file set at that tree); a different set (origin moved) is gated after (tools/phone/ship-order-test.sh).
- The build is warm: build-app.sh builds in `powos-gradle-warm` (targets/android/tools/warm-builder.sh, unit
  units/mac/gradle-warm-mac.json), a long-lived builder whose Gradle daemon stays up, building every worktree from one
  rsync'd copy in /work (shared incremental state) - 6-11 s for a Kotlin or shell change, from any worktree, against
  ~8 min cold (2026-10-22). Missing, stopped or failing, it falls back to android-app-dev's cold
  `make build` by itself (`POWOS_COLD_BUILD=1` forces cold). Its own Gradle home and build dirs; android-app-dev's
  other projects keep the cold path. `warm-builder.sh stop` removes it; it ends itself after 6 h without a build.
- So: an install wipes every override that isn't committed on origin. Uncommitted or unpushed shell pushes are lost
  by design. Recognise it: right after an install your change is gone on the phone -> check it is on origin, then
  push it again from the tip.
- Kotlin: compile before you push it to origin - a committed but uncompiled Kotlin change on the tip fails EVERY
  agent's next ship: `tools/phone/compile-check.sh` (your worktree, a throwaway builder; never touches the shared APK
  output, safe while a ship runs; prints the compiler's errors, exit 0 = compiles). Found someone else's broken tip? Tell its author/the coordinator with
  the compiler error; don't ship around it.
### PowOS (Linux) side
- lib/ai (manager, comms): `PATH="$PWD/tools/phone/bin:$PATH" targets/android/rooted/rooted.sh deploy --note "..."`
  (rooted.sh calls plain adb; tools/phone/bin/adb routes it through adb.sh over the VPN). Other PowOS files through the deploy
  scripts (targets/android/rooted/powos-deploy.sh) as registered units (`powos units`, units/<host>/*.json); never
  unmanaged host installs.
- PowOS apps: `powos app new|build|install|ui|publish|dev` (lib/apps/powos-app), run inside PowOS; the repo's apps/*
  with apps/build.sh + `apps/install.sh <app> [install|publish|ui] --note "..."`.

## The emulator lane: first for window and app checks, the phone only for hardware
- Window, app, home and shell checks go to the EMULATOR first: `tools/phone/verify/queue.sh add --dev emu <task>
  <check> [args]` runs at once (no free-phone window, no ship wait beyond its own build), against an arm64 Android 16
  AVD shaped like the Open's inner screen (2268x2440, 442 dpi) with PowOS as a privileged system app + the recents
  overlay, as on the phone. The result goes onto the board task like a phone check ("emulator PASS: ..."); while the
  phone (the board) is unreachable it waits in ~/.cache/powos-verify-queue/emu/pending/. `queue.sh list` shows the lane.
- The phone (no `--dev`) only for what needs its hardware or Linux session: games, Steam, fps/frame pacing, the fold
  and cover screen, the kernel, Linux windows (kate, ffplay, Plasma), speech, real touch timing. `--dev emu` refuses
  games/Steam/fps/fold/kernel checks by filename AND refuses any check whose own `# lanes:` marker (below) says
  "phone" only, even when the filename doesn't give it away (launch-window.sh's Steam stage).
- `--dev auto` picks the lane for you and never errors either way: emu when the check's `# lanes:` header line (its
  first ~6 lines) says "emu" (no condition) or "emu?" AND the run was TOLD, not guessed, to be Android-only (a literal
  `--android-only`, or window-max.sh's STAGE being calc/video) with no Linux app/stage named anywhere in the command;
  else phone. `queue.sh add --dev auto <task> tools/phone/verify/window-max.sh calc` picks emu; the same check with
  `kate` picks phone; a check with no marker at all (something outside this table) always picks phone.
- Every check under `tools/phone/verify/` that gets queued directly carries a `# lanes: emu|emu?|phone [...]` header
  line (its 2nd line) that `--dev auto`/`--dev emu` read: `emu` = runs on the emulator as queued, no condition; `emu?`
  = only for an explicitly Android-only invocation; `phone` = never (Linux session, physical hardware, or a
  lane-only mechanism, e.g. the status pill, that the emulator lane doesn't have). Internal libraries (`e2e-lib.sh`,
  `bf-lib.sh`, `window-lock.sh`, `kwin-up.sh`, `linux-win-lib.sh`), the on-phone companions of a Mac-side check
  (`*-phone.sh`, `gest.sh`, `owed.sh`), ad-hoc root snippets (`sf-latency.sh`) and non-check tools (`queue.sh`,
  `queue-emu.sh`, `e2e-queue.sh`, `runner-deploy.sh`) aren't queued directly and carry no marker.
- `--android-only` (e2e-lib.sh's `e2e_args`, and added individually to resize-probe.sh, window-scroll.sh and
  window-rec.sh) skips or substitutes a check's Linux-only steps instead of failing them: e2e-desktop.sh's part 1
  notes (not fails) past Kate-from-search and Dolphin/Gwenview; resize-probe.sh/window-scroll.sh drop Kate (and
  window-scroll.sh's Steam) from their `--apps` default; window-rec.sh's `--app calc --two` opens Chrome instead of
  Kate as the second window (Chrome IS on the emulator's `google_apis` image, confirmed by `pm list packages`).
  window-max.sh needs no flag - its STAGE argument (calc/video vs kate/ffplay) already says which lane.
- The classification below is every check under `tools/phone/verify/` that is queued directly (`queue.sh add <task>
  <this> ...`), one row each, with its lane and why. Proven on the emulator with real PASS output (2026-10-24):
  `resize-probe.sh --apps calc`, `window-scroll.sh --android-only`, `e2e-desktop.sh --part 2 --of 3` and
  `--part 1 --of 3 --android-only`. Three bugs this pass also fixed and re-proved on the emulator lane (none in
  window Kotlin - check-script timing/robustness only): `float-desktops.sh` (a `device_state` OPENED race - the
  emulator's software renderer can take longer than 2 s to commit the state, same class of lag as the maximise/restore
  content delay below), `panel-lift.sh` (its PanelLift logcat line was read from a long-cleared buffer the emulator's
  noisier logcat - far more Choreographer/Skia lines under software rendering - could roll past before the read; now
  read from a time-mark instead), and `window-max.sh`'s post-restore content retry budget (doubled for the emulator).

| Check | Lane | Why |
|---|---|---|
| *(runs on the emulator as it is queued)* |  |  |
| `add-app.sh` | emu + phone | the + app sheet (edit mode) - Android UI only |
| `ai-send-flash.sh` | emu + phone | PowOS AI page send/flash animation - web shell only |
| `ai-wide.sh` | emu + phone | PowOS AI page on the wide/unfolded layout - web shell, device_state-simulated |
| `app-api.sh` | emu + phone | the App API app's own UI - an installed PowOS app, no Linux |
| `app-frost.sh` | emu + phone | home's frost/glass material - compositor blur, Android only |
| `assist-freeze.sh` | emu + phone | the assist overlay - an Android VoiceInteractionService session |
| `az-scrub.sh` | emu + phone | the drawer's A-Z scrub bar - web shell only |
| `board-state.sh` | emu + phone | the AI page's board rendering - web shell only |
| `cc-toprow.sh` | emu + phone | control centre's top row - web shell only |
| `chat-polish.sh` | emu + phone | chat bubbles/markdown rendering - web shell only |
| `composer.sh` | emu + phone | the chat composer - web shell only |
| `cpu-sample.sh` | emu + phone | reads /proc stat over adb root - no app dependency at all |
| `dock-taskbar.sh` | emu + phone | Calculator in the dock-as-taskbar - Android app window only |
| `e2e-appapi.sh` | emu + phone | the App API + Hue widgets journey - an installed PowOS app and web shell, no Linux app anywhere |
| `edge-more.sh` | emu + phone | edge-gesture handles - Android input injection only |
| `edge.sh` | emu + phone | edge-gesture handles - Android input injection only |
| `fetch-logo.sh` | emu + phone | an app icon fetch - web shell only |
| `float-desktops.sh` | emu + phone | floating windows across home's pages (Calculator only) - needed a retry loop for `device_state`'s OPENED commit, which can lag past 2 s on the emulator's software renderer (fixed, proven) |
| `float-reopen.sh` | emu + phone | reopening a floating Android window from recents - no Linux |
| `float-touch.sh` | emu + phone | touch routing into a floating Android window - no Linux |
| `folder-clip.sh` | emu + phone | an app-library folder morph - web shell only (filename false-matched the old unbounded "fold" HW regex; fixed) |
| `home-select.sh` | emu + phone | edit mode's selection rectangle - web shell only |
| `hue-link.sh` | emu + phone | the Hue pairing link flow - web shell + network, no Linux |
| `icon-hues.sh` | emu + phone | themed app icon colours - web shell only |
| `icon-norm.sh` | emu + phone | icon normalisation - web shell only |
| `launch-paths.sh` | emu + phone | every Android launch path (apps.launch, am start, recents) - WM state via device_state, no cover-screen pixels inspected |
| `lights-popup.sh` | emu + phone | the Lights popup, forced to the inner screen like float-desktops.sh - web shell only |
| `nav-strip.sh` | emu + phone | the gesture-nav black-strip check - Android/web shell only |
| `overlay-reload.sh` | emu + phone | a shell-file hot reload - web shell only |
| `owed-checks.sh` | emu + phone | home's tiles, Lights popup, control centre, AI page - the "ON display" adapts to whichever is on, no cover-screen content read |
| `panel-lift.sh` | emu + phone | home's panels lifted above a Calculator window - the PanelLift logcat line is now read from a time-mark instead of a long-cleared buffer, which the emulator's noisier logcat (more Choreographer/Skia lines) could roll past before the read (fixed) |
| `prompt-glyph.sh` | emu + phone | a chat prompt glyph - web shell only |
| `pullup-stage2.sh` | emu + phone | the drawer's second pull-up stage - web shell only |
| `running-dot.sh` | emu + phone | the dock's running-app dot - web shell only |
| `search-dock.sh` | emu + phone | the dock's search pill - web shell only |
| `shade-overpull.sh` | emu + phone | the shade's over-pull - web shell only |
| `shade-panel.sh` | emu + phone | the shade panel - web shell only |
| `shade-wide.sh` | emu + phone | the shade on the wide layout - web shell only |
| `sketch-canvas.sh` | emu + phone | the sketch app canvas - an Android app, no Linux |
| `sketch-rotate.sh` | emu + phone | the sketch app rotate gesture - Android app, no Linux |
| `sketch-zoom.sh` | emu + phone | the sketch app zoom gesture - Android app, no Linux |
| `unfolded-checks.sh` | emu + phone | the owed unfolded-home batch - device_state-simulated inner screen, same as e2e_setup; filename matched the old unbounded "fold" HW regex (fixed) |
| `wide-home.sh` | emu + phone | the unfolded wide-home layout - device_state-simulated, web shell only |
| `window-chrome.sh` | emu + phone | a floating window's chrome (bar/grip) on Calculator - Android app only |
| `window-live.sh` | emu + phone | a floating window's live content follow, on Calculator only (E2E_APPS has no Linux entry) |
| *(runs on the emulator only for an Android-only invocation - `--android-only` or, for window-max.sh, its STAGE)* |  |  |
| `e2e-desktop.sh` | emu? + phone | `--android-only` skips part 1's Kate-from-search and Dolphin/Gwenview steps (a NOTE, not a FAIL); parts 2 (Calculator) and 3 (Chrome + drawer) need no Linux at all even without the flag - **proven: `--part 1 --android-only` and `--part 2`** |
| `resize-probe.sh` | emu? + phone | its own `--apps` picks the app; `--apps calc` (or the new `--android-only`, same as `--apps "calc chrome"`) stays Android-only; default includes Kate (phone only) - **proven: `--apps calc`** |
| `window-max.sh` | emu? + phone | its STAGE picks the lane by construction: `calc`/`video` are Android apps (Chrome IS on the emulator's image), `kate`/`ffplay` need the Linux session - **proven: `calc`** |
| `window-rec.sh` | emu? + phone | `--app calc --two --android-only` opens Chrome instead of Kate as the second window; `--app kate`, or `--two` without the flag, still need Kate |
| `window-scroll.sh` | emu? + phone | same `--apps` split as resize-probe.sh (`--android-only` = `--apps "calc chrome"`, drops Kate and Steam) - **proven: `--android-only`** |
| *(phone only - Linux session, physical hardware, or a lane-only mechanism the emulator doesn't have)* |  |  |
| `bf-checker.sh` .. `bf-window.sh` (16 scripts) | phone only | Broforce run/measurement - phone hardware/GPU driver (queue.sh's HW_ONLY) |
| `desk-probe.sh` | phone only | mostly Calculator, but one Dolphin section at the end - not split yet |
| `float-windows.sh` | phone only | opens Dolphin/Kate as part of its run |
| `fold-launch.sh` | phone only | a Steam game launched folded/unfolded - hardware fold + Steam |
| `fold.sh` | phone only | the hinge's CLOSED state = the physical cover screen, a second display the emulator doesn't have |
| `journey.sh` | phone only | runs gest.sh - cover-screen gesture journeys, a second physical display the emulator doesn't have |
| `keyboard.sh` | phone only | the keyboard over a Linux (Wayland) text field - needs the session |
| `launch-front.sh` | phone only | a PowOS (Linux) app's window coming to front - needs the session |
| `launch-window.sh` | phone only | stage 1 is Steam's cold-start launch window - phone hardware/GPU driver (not caught by the filename-based HW_ONLY check; its own marker is) |
| `lib-install.sh` | phone only | deploys lib/ files onto the phone's Linux rootfs - not on the emulator |
| `linux-dock.sh` | phone only | Dolphin in the dock/switcher - needs the session |
| `linux-float.sh` | phone only | Linux apps floating via KWin - needs the session |
| `linux-look.sh` | phone only | Linux apps' size/theme (Breeze dark) - needs the session |
| `linux-session.sh` | phone only | a KWin session restart - needs the session |
| `linux-touch.sh` | phone only | taps into Kate/Dolphin content - needs the session |
| `mc-launch.sh` | phone only | Minecraft via a launcher - Steam/game, phone hardware (queue.sh's HW_ONLY) |
| `one-title-bar.sh` | phone only | KWin's "decor" title bar on Linux windows - needs the session |
| `pill-stop.sh` | phone only | the phone lane's status pill + runner pause/resume - the emulator lane has no pill (queue-emu.sh) |
| `pkg-install.sh` | phone only | installs rootfs packages (pacman) into the Linux session - not on the emulator |
| `plasma-app.sh` | phone only | Plasma as a drawer app/backend (KSycoca) - needs the session |
| `plasma-modes.sh` | phone only | Plasma MODE (plasma\|shell\|together) - needs the session |
| `plasma-notify.sh` | phone only | Plasma notifications via powos-plasma-bridge - needs the session |
| `plasma-transparent.sh` | phone only | the Linux desktop app's transparency over the wallpaper - needs the session |
| `speech-test.sh` | phone only | real GPU dictation through the mic pipeline; kept phone-only (not attempted on the emulator) |
| `steam-input.sh`, `steam-pipe-probe.sh`, `steam-tap.sh` | phone only | Steam hardware/IPC/Linux rootfs (queue.sh's HW_ONLY) |
| `steam-install.sh` | phone only | installs the Steam package into the Linux rootfs - not on the emulator (queue.sh's HW_ONLY) |
| `td-launch.sh` | phone only | Teardown via Steam - Steam/game, phone hardware (queue.sh's HW_ONLY) |
| `test-now.sh` | phone only | the phone lane's status pill while "test now" runs - no pill on the emulator lane |

- Any check runs unchanged against it by hand: `POWOS_DEVICE=emu LOCK_HELD=1 tools/phone/verify/window-max.sh calc`
  (adb.sh, cdp.sh, idle.sh, shot.sh, root.sh follow POWOS_DEVICE). `tools/emu/emu.sh start|stop|status|reset|install`;
  `create` once (~10 min), `remove` to drop it (unit units/mac/emu-mac.json, ~13.7 GB with the system image; refuses
  below 25 GB free). The Calculator there is a test window client under the Calculator's package (tools/emu/testwin).
- Not on the emulator: the Linux session (rootfs 6+ GB unpacked, KWin on KGSL/Turnip; no room in the 12 GB budget),
  OnePlus framework behaviour (OxygenOS's flexible windows, its 31-float blur regions), real fps, the physical cover
  screen, the mic. A PASS there is not a PASS for those.
- How emu.sh works (hand-off): AVD powos-open (~/.android/avd, android-36 google_apis arm64, serial emulator-5584),
  headless, software GL, started from snapshot `powos-ready` with nothing saved on stop. `start` = boot or reuse,
  restart if Android is wedged/offline (cmd package fails), build origin's tip if the emulator runs another commit
  (warm builder PUBLISH=0, never android-app-dev/output; commit in /data/local/tmp/powos-emu-commit), grants, then
  wait for home's `window.__powosAlive`. `create` re-makes everything (~10 min): sdkmanager runs in the
  android-builder image (the Mac has no Java), su from tools/emu/su.c (NDK in powos-gradle-warm), priv-app +
  allowlist + recents RRO on remounted /system, persist.powos.root=1, freeform on, SELinux permissive, test client.
  Real size ~14.4 GB: the emulator forces 4 GB RAM into the snapshot. adb waits are bounded (120 s). The phone may
  also be on the Mac's USB: always `adb -s emulator-5584`. Logs: ~/.cache/powos-emu/emulator.log,
  ~/.cache/powos-verify-queue/emu/runner.log.

## Where things live
- Shell: shell/ (Preact+TS). Pages = modes (`index.html?mode=lock|shade|assist|glasses`, home = no mode). Bridge
  JS<->Kotlin: shell/bridge.ts + shell/types.ts (events list); Kotlin side ShellBridge.kt.
- Page store: `powos.store.set(name, value)` writes files/shell-data/<name>.json; ShellBridge JSON-quotes a string
  value. Pass the value itself, never `JSON.stringify(x)` (that stores a quoted string; speech.json held one and the
  app silently used its default, 64a2468).
- Theme/material: shell/theme.css tokens (`--glass-*`, `--lift*`, `.tile`, `.surface`); design rules
  docs/DESIGN-LANGUAGE.md (rule 1: less is more, reduce complexity).
- Glass: CSS frost picture shell/ui/glass.ts (lock face); live compositor blur for home shell/ui/nativeglass.ts ->
  GlassBlur.kt (SurfaceFlinger blur regions); liquid refraction LiquidGlass.kt + WallpaperBackdrop.kt (OFF by default).
- Widgets: shell built-ins (shell/ui panels), OWL widgets (.owl: evaluated by the Kotlin engine, drawn by
  shell/ui/owl.tsx from the trees it sends), PowOS-app islands (apps' ui/widgets). See EVERY widget at every size:
  `shell/dev/preview.sh` (or `powos app preview <dir|file.owl|id>`) - details in the powos-widgets skill; the gate runs
  it (--fast) when a push touches what draws widgets.
- Speech: one shared recognizer (targets/android/app .../ui/Speech.kt), bridge events speech.state/done/permission.
- Assist overlay: VoiceInteractionService session (PowosAssistSession.kt) hosting shell mode=assist.
- Deploy notes/errors to the user: deploy notes = targets/android/tools/deploy-note.sh -> notification; shell errors
  are captured in shell/index.html (boot.report) and sent to the manager; manager mail = ai.mail events.
- Agents/board: `powos agents task list|add|done`, spool /run/powos-app/agents (agentsd).
- In the shell, deploy notes and agents' mail to the user both arrive as "ai.mail" (AgentMail[], deploy notes `from: "deploy"`);
  the page's own errors are window error/unhandledrejection events (index.html's boot.report also keeps them in window.__powosBoot.errors).
- SpacetimeDB: a shell layer that needs a PowOS app's tables vendors its bindings (`apps/vendor.sh <app>` ->
  shell/vendor/<db>.js + .d.ts + a line in vendor/VERSIONS) and reads them with useDb/useRows from shell/apps/stdb.ts
  (example: shell/ui/pet.tsx). A MODULE CHANGE ships with its re-vendored bindings AND a publish
  (`apps/install.sh <app> publish --note "..."`). Changed the module without republishing = home can't decode the
  table: shell-errors shows `Offset is outside the bounds of the DataView` (vendor/spacetimedb.js) or
  `stdb: <db>: ... bindings stale for <table>`. push.sh and ship-apk run tools/phone/bindings-check.sh (one phone
  call): bindings ahead of the live module are published from this commit's module, anything else refuses with the
  fix. Details: powos-stdb skill.
- GPU box 192.168.50.195: voice stack units (hosts/gpu-195/, units/gpu-195/), voiceagent.pow; plan docs/GPU-SERVERS-PLAN.md.

## Native/hidden-API work (learned the hard way)
- android.os.FileObserver can't share a folder: inotify gives one descriptor per inode, the last observer started gets
  every event and any one's stopWatching ends all (logout requests were lost that way). Watch a folder others may
  watch (the run dir, shell-data) through engine `andro.marchy.DirWatch`.
- Check an OEM framework call's real shape BEFORE coding against it: pull `/system/framework/framework.jar` with
  adb.sh, unzip classes*.dex, `dexdump -d` it in powos-vadb (`/opt/android-sdk/build-tools/35.0.0/dexdump`). OxygenOS 16
  differs from AOSP: `SurfaceControl.Transaction.setBlurRegions` takes 31 floats per region (AOSP 10 + blur colour +
  OPlus params) - a wrong array length aborts the whole app in JNI (home crash-looped). Encode through the framework's
  own class (BackgroundBlurDrawable.BlurRegion.toFloatArray) instead of building layouts by hand.
- A hidden field/method is denied SILENTLY to runCatching code: grep logcat for "hiddenapi: ... denied" (tag = the
  process name, com.powos.app) and add the class prefix to HiddenApi.kt (Configuration.windowConfiguration, 2026-10-23).
- PowOS holds READ_FRAME_BUFFER (signature|recents) through the recents role: `IWindowManager.mirrorWallpaperSurface`
  + `ScreenCapture.captureLayers` work, but a mirror is boundless - pass a source crop or SF answers BAD_VALUE (-22).
- Screenshots: two displays - `screencap -d <id>` with an id from `dumpsys SurfaceFlinger --display-id` (the cover
  screen was the 2nd one listed); a bare screencap picks one and may be the dark inner panel.
- Measuring: `dumpsys gfxinfo com.powos.app reset` / summary (per-window frames, janky %, GPU percentiles);
  per-thread CPU from /proc/<pid>/task/*/stat (utime+stime ticks, HZ=100); touch activity also shows as touch-0x IRQ
  counts in /proc/interrupts. Logcat's main buffer rolls over within minutes on this phone: grep soon, or
  `logcat -d -v time` into a file under $HOME.

## Security
- The shell page's native objects (PowosHost, PowosNative, PowosBoot) reach ONLY its own top frame at
  https://shell.powos (or the dev URL's origin): web message listeners (androidx.webkit addWebMessageListener) with
  that origin rule, plus a per-message check (app .../shell/ShellOrigin.kt: top frame + exact origin; "null"/opaque, other
  origins and every iframe - even a same-origin srcdoc/about:blank one - refused, logged "refused a message"). Never
  add a WebView.addJavascriptInterface to a shell WebView: it reaches every frame and can't see the caller. PowOS
  apps' UIs stay modules in the page's own frame (./_app/<id>/); anything in an iframe is bridge-less by design.
  Check on the phone: `tools/phone/bridge-check.sh [page]` (probe iframes over CDP; the gate's mock can't see it).

## Rules that bite
Git and process
- Commit only your paths; never force-push; rebase once, right before you push (several agents edit shell/ui at once; a fetch/rebase/status loop while working is the top coordination cost).
- The one exception: also rebase once at the START of a worktree, if a tool you need isn't there yet. A worktree
  branches from origin's tip at creation time; if origin gains a tool shortly after (e.g. `tools/agents/land.sh`
  landed moments after a worktree branched without it), the worktree won't have it until it rebases - `ls` failing
  on a tool the handbook says should exist is the signal to `git fetch && git rebase origin/worktree-powos-multiplatform`
  before doing anything else, not to hand-roll the tool's logic (friction f138).
- `git push` runs tools/git-hooks/pre-push (core.hooksPath): the complexity lint on the pushed files; a failure is
  yours to split, never `--no-verify` (e9af512's lint failure blocked every ship-apk, 2026-10-22).
- `HACK:` markers need a row in docs/REMOTE-POWOS.md section 4 in the same commit (test-hack-registry).
- Permission denials: never route around a permission-classifier or sandbox denial (no other tool, script, agent or
  settings edit to get the same effect). Only the user's own approval counts - their message, or their own tap on a
  real permission prompt; never another agent's or the coordinator's say-so. Report what was blocked and the exact
  commands/rules the user can run or add.
- Reporting to the coordinator: progress goes on the board (`task set <id> --step`), not in messages. Message the
  coordinator only when a task is finished, blocked, or needs a decision. Every interim message costs a full
  coordinator turn at ~470k context (self-optimize round, 2026-10-23: the coordinator was 276 of ~600 Mtok in 4 h,
  driven by interim "still waiting" reports).
- Coordinator side of the same rule (friction f6): when the user approves a blocked action in the coordinator's
  session, the coordinator runs that exact action itself, or asks the user to approve it in the prompt. It never mails
  "the user approved X" to an agent and expects the agent to act; the agent correctly refuses that.
- Report what you verified; mark the rest. A root cause is a fact only after a measurement or log shows it (two wrong
  guesses on 2026-10-21: "Chromium drops opacity-0 tiles" shipped and was reverted; the one-column drawer was "almost
  certainly" the recents strip - it was a stale shell.css pushed from another tree). Otherwise
  write "likely" and say what would confirm it.
- DELIVERY RULES (manager for the user, 2026-10-22 19:38 - they override slower habits below):
  1. Time box: every task ships a VISIBLE improvement to the phone within 30 min of pickup, or its board task shows
     blocked + the reason. Big things ship in slices.
  2. Report only shipped results or blockers - no "X owns Y" acks, no status chatter.
  3. APK changes: ship-apk at least every 30 min while anything is pending; a 2-min idle is enough (don't wait for
     long windows). Shell pushes go out immediately, batched per minute.
  4. Mock review only for brand-NEW screens; everything else ships, the manager reviews the device screencap after.
  5b. The phone has NO PIN: the PowOS lock face opens with a swipe up. In a free window a check swipes it away and goes
     on (restoring the prior state after) - a locked phone is never a blocker (the user, 2026-10-22).
  5a. The verify lock (~/.cache/powos-verify.lock) is taken only AFTER `idle.sh --wait` returns a free window, held
     only for the injected part, never through a wait: ship-apk won't install while it exists (a check holding it
     through its idle wait blocked every APK for 19 min, 2026-10-22).
  5. Device checks are automated (read-only CDP + a screencap in a free window) - never wait on the user for what a
     script can check.
  6. Done? Exit (Efficiency: one task per run); the coordinator starts a fresh agent for the next unowned task.
- Speed (manager, 2026-10-22): experts work IN PARALLEL - never wait behind another expert's task unless you touch
  the same files. Bug fixes (alignment, scrolling, clipping, errors) SHIP as soon as they're gated and checked on the
  device - send a screencap after, no mock review; only NEW designs (layouts, new UI) wait for the manager's mock OK.
  Batch your shell pushes (each push reloads pages: churn and CPU).
- Report progress on your board task as you go (the user watches it on the AI page): when you start, set the plan
  (`powos agents task set <t> --plan "a; b; c"` or `--progress 0/N`); at each step `--progress k/N --step "what now"`;
  link commits (`--commit <sha>`, or mention the task id in the message) and review images (`--image <path>`).
  `powos agents help` has the flags. Own what you take: `task set <t> --owner <your expert name>` (powos-widgets,
  powos-design...).
- A task waiting on the user gets a `--note` that is the ACTION, in plain imperative words ("Pull down on home to try
  the single shade", "Plug the phone into the Mac for the kernel test"), never a status ("in installed APK; user to
  try in edit mode"). The AI page shows the note as the card's action line (manager, 2026-10-22).
- `shell/.gitignore` ignores `node_modules` (no trailing slash) so a SYMLINKED shell/node_modules (from another
  worktree, for tsc) is ignored too; `node_modules/` matched only a directory and the link made the tree dirty for
  build-app.sh. Write ignore rules that match a symlink when one may be linked.
Pipeline scripts (bash)
- The Mac's bash is 3.2: no `declare -A`, guard empty arrays under `set -u` (`${a[@]+"${a[@]}"}`).
- Under `set -e` + `pipefail` a command that "fails" normally ends the whole script: `grep` with no match (exit 1)
  inside `x=$(... | grep ...)` aborted ship-apk before its post-install checks (72d60d5), and `idle.sh --wait`'s timeout
  exit 1 aborted it mid-wait (a39e103). Add `|| true` (or `if ...; then`) where "no match"/"not yet" is a normal
  outcome, and test that path, not just the happy one.
- Under `set -o pipefail`, `cmd | grep -q pattern` can flake FAIL even when `cmd` actually produced a match: once
  `grep -q` finds it, it exits before reading the rest of the pipe, and the upstream writer can get SIGPIPE and
  report that as the pipeline's exit status instead of `cmd`'s real one. Use `grep -q pattern <<<"$(cmd)"` (command
  substitution finishes first) or `cmd | grep pattern >/dev/null` (no early exit) instead (friction f141).
- Never edit a script while a run is executing it: bash reads the file as it goes, so the running copy executes a
  mix (a build script crashed mid-run that way). Edit in your worktree, let the run finish, then commit. ship-apk.sh
  runs origin's copy from a temp file, so a ship in progress is not affected by later commits to it.
The phone
- NEVER poll the phone in a loop (no 10 s / 60 s adb checks, no "until idle" loops from the Mac): each call is a new VPN
  connection and keeps the phone's radio awake - agents' polling was most of its WireGuard traffic and CPU, and the
  battery ran flat on 2026-10-21 with several agents polling all afternoon. Wait for an EVENT: comms mail
  (`powos comms watch`, wait_for_message), a push/ship result, shell-error mail; or make ONE check when you need it.
  A check that needs a free phone goes on `tools/phone/verify/queue.sh` (Efficiency), not a wait of yours. Batch commands into one adb call. Keep
  phone-side loops bounded and kill your probes (a stuck `tr` loop once ran at 100%).
- Battery: NO battery-based rules - neither for agents' work nor in the product (the user's call, 2026-10-21 10:01).
  The product behaves the same at any battery level unless the user asks otherwise (Android's own battery saver
  switching compositor blur off is Android's, not ours). Not polling is about not wasting the phone, not battery level.
- CDP on the LIVE pages is READ-ONLY: read state, computed styles, rects. Never set signals, CSS variables, classes,
  inject DOM or call actions that change what the user sees (2026-10-21: checks that set the drawer's --p and opened
  panels showed the drawer and the AI page opening on the user's screen, in a recording too). To exercise UI, use the
  headless gate (shell/dev/gate.sh --shots / --tree) or a separate offscreen page; on the phone only in a free window
  (after `idle.sh --wait`), restored in the same call. In such a free window you may close TRANSIENT UI yourself
  before a test (home's edit mode, an open drawer, a menu or sheet - Back or the page's own exit), never settings or
  home's layout (the user, 2026-10-22: "you could have just left it yourself").
- Never drive real devices (lights, Hue, anything physical) without the user's say: a test once changed a real room
  light. Test with mock data (preview data/*.json) or stubbed reducers/handlers.
- Headless passing is not the device working: the gate's mock and Chromium differ from the phone's WebView (a drawer
  strip passed headless and broke on the device). After a push or install, check the change on the device (read-only
  CDP of the computed layout, logcat, or a screencap in a free window) before reporting it done.
- Review images (contact sheets, before/after, pet steps) go to the PHONE before you push, so the manager can look
  first: `tools/phone/review-image.sh FILE...` (-> /home/powos/design-qa/; pet: /home/powos/pet-review/ via adb.sh +
  root.sh, chown 10359:10359).
- The assist overlay's circle-to-select + crop flow is core, never "chrome": never remove it.
Rendering cost (0 frames at rest)
- Every page at rest: 0 frames, 0 paints, 0 rAF (`tools/phone/cdp.sh idle`; the gate's idle check headless). An
  endless CSS animation = 60 frames/s plus a compositor blur pass each.
- nativeglass.ts's MutationObserver re-measures glass on style/class writes to surfaces or their ancestors: a new
  per-frame inline-style animation (the pet's transform) must carry `data-glass-ignore` / stay outside surfaces, or
  each frame triggers a glass measure (43b9dc3).
- A custom property set per frame (--p, --fade) must be registered `inherits: false` (@property): an inherited one
  restyles every descendant (all app cells, widgets) each frame. Animate transform/opacity only, never layout.
The Mac
- The Mac's disk filled on 2026-10-21 (0.5 GB free: Colima's VM got I/O errors, every container and agent died). The
  watchdog (PowStation/scripts/disk-watchdog.sh, cron every 10 min) mails the manager below 15 GB and deletes files
  older than 3 days in agents' scratch caches (~/.cache/powos-gate, powos-preview, powos-perf, drawer-perf, petwork,
  ...). So scripts, probes and tools you rely on belong in the repo (commit them), never only in ~/.cache or job tmp;
  scratch output there is disposable. Never prune the Docker build cache; clean up worktrees/outputs you created.
- Gate timing on a loaded Mac: `READY_MS=30000` (ship-apk's default); a single flaky "not ready" - rerun before
  blaming your change.
Comms
- How a Mac worktree agent learns its own comms role (`COMMS_AGENT_ID` is only set by `powos ai`'s
  `comms_export_identity`, which a `tools/agents/worktree.sh`-created agent never goes through): resolve it as
  `${COMMS_AGENT_ID:-$POWOS_AGENTS_ROLE}`, else fall back to the worktree's basename (friction f135).
- `powos comms watch` and `inbox` (without `--peek`) CONSUME the messages: a crash or a cut-off output after the read
  loses them. Look with `inbox --peek`; when you consume, use `--json` and keep the output (append it to a file under
  $HOME) before acting. Bodies are delivered whole - never `head`/`cut`/first-line a message you will act on.
