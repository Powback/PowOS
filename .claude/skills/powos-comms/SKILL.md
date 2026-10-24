---
name: powos-comms
description: Use when working on PowOS inter-agent comms - `powos comms` (send/watch/inbox/read/notify/quiet), the comms MCP tools, the work board (`powos agents task`, the agents module's `work` table), silent deploys, the manager's inbox injection (manager.py --once-inbox / live), powos-agentsd and the agents module's message feed, or the phone's agent-mail notifications. The model, the truncation pitfalls, deploy and tests.
---

# PowOS comms: how it works and what bites

## Model
- Daemonless spool: `$COMMS_ROOT` (default `${XDG_STATE_HOME:-~/.local/state}/powos/comms`), one inbox per role:
  `agents/<role>/inbox/<ts>-<priority>-<id>.json` = `{id, from, to, kind, priority, ts, iso, body[, result]}`,
  written tmp + rename (atomic), FIFO by filename. Same code for MCP (stdio JSON-RPC, no argv) and CLI (any argv).
- `_deliver()` also: on a phone (`POWOS_PLATFORM=phone` or /etc/powos/platform) touches
  `$XDG_RUNTIME_DIR/agent-wake/<role>-<ms>` (the app runs the manager's `--once-inbox` turn), and drops a
  `message` record in the Agents queue (`POWOS_AGENTS_QUEUE` / /dev/shm/powos-agents-$USER) for powos-agentsd.
- notify (`notify_user`, `powos comms notify`) -> user inbox + `$XDG_RUNTIME_DIR/agent-mail/*.json`
  `{id, from, text, priority, time}` -> AgentMail.kt posts the notification; `{"op":"read","ids":[..]}` marks read.
- Manager: `take_inbox()` drains its inbox into turn texts
  `[inbox message from agent 'X' (P)]: <body>\n\nHandle this: ...`; live mode polls it 1 s, `--once-inbox` joins all
  with `\n\n`; `--json-events` emits `{"kind":"inbox","text":...}` which PowosAiChat shows as a note.

## Role resolution for a Mac worktree agent
- `COMMS_AGENT_ID` is only set by `comms_export_identity` when `powos ai` launches a role; a Claude Code agent
  started via `tools/agents/worktree.sh` (not through `powos ai`) gets neither it nor `POWOS_AGENTS_ROLE`. Resolve
  its comms role as `${COMMS_AGENT_ID:-$POWOS_AGENTS_ROLE}`, else fall back to the worktree's basename (friction
  f135; also in AGENT-HANDBOOK.md's Comms section).

## CLI facts
- `watch` and `inbox` (without `--peek`) CONSUME the messages; a crash or a cut-off output after the read loses them.
  Use `--peek` to look; consume with `--json` into a file you keep (handbook, Comms).
- `--json` (inbox/watch): one JSON object per message per line, the exact stored body. Text form: header
  `• [prio] from X (kind) at ISO [id ID]`, then every body line indented 4 spaces (strip 4 to recover).
- `send <to> -` / `notify -`: body from stdin; only ONE trailing newline is dropped. `send <to> -- -text`: a body
  starting with `-` (the app's inline reply uses `--`).

## The 10 truncation/corruption points fixed (b1329eb) - don't reintroduce
1. comms-mcp `_agents_note` body[:400]  2. agentsd `clean(body, 280)` (one line)  3. agents module `cut(body, 280)`
4. shell .ag-msg nowrap/ellipsis with no tap-to-open  5. PowosAiChat.inboxLine first line .take(140)
6. AgentMail BigText > Android's 5 KiB MAX_CHARSEQUENCE_LENGTH silently dropped (now capped with "N more - tap")
7. locale-dependent stdio: ASCII locale crashed inbox/watch AFTER draining; latin-1 mis-decoded MCP input
8. `notify -` .strip()  9. `_fmt_msgs` indented only the first body line  10. reply starting with `-` = argparse error.
Display-only caps that are fine: manager `_tool_hint` (120), `_result_text` (160), `_result_out` (2000) - tool
output, not messages. agentsd still scrubs secret-shaped strings (deliberate).

## Deploy
- lib/ai -> phone: `targets/android/rooted/rooted.sh deploy --note "..."` (pushes comms-mcp.py, lib/ai/manager,
  lib/ai/agents, plus everything else rooted needs; powos-deploy.sh installs to /data/powos/root/usr/lib/powos/ai/).
  It calls a bare `adb`: run it as `PATH="$PWD/tools/phone/bin:$PATH" targets/android/rooted/rooted.sh deploy ...`
  (tools/phone/bin/adb execs adb.sh with canonical paths - a `..` path "rooted/../session/..." failed "cannot stat").
- The phone's manager runs one process per chat turn, so a deploy takes effect next turn (no restart).
- Agents module changes need an STDB module publish (not done by rooted.sh deploy).
- The Mac's agentsd: copy lib/ai/agents/powos-agentsd AND powos-agents-cli (its refusal friction calls the sibling) to
  ~/.claude/hooks/powos-agents/, then kill its pid ($TMPDIR/powos-agents-$USER/in/pid; the next hook restarts it).
- Verify with ONE batched adb call (md5sum the installed files). Never poll.

## Tests
python3 test/tier1/test-comms-fulltext.py   # 10 KB unicode/quotes/$/CRLF round-trip: CLI, MCP stdio, manager, phone files
python3 test/tier1/test-comms.py; python3 test/tier1/test-manager.py; python3 test/tier1/test-agents.py
(`just test` / run-all.sh needs bash 4: CI/Linux; the Mac's bash 3.2 can't run run-all.sh.)
Shell tsc: a fresh worktree has no shell/node_modules - the gate skips tsc; symlink another worktree's
(`ln -s <other>/shell/node_modules shell/`; .gitignore's `node_modules` ignores the link, so the tree stays clean).

## Mail notifications on the phone (AgentMail.kt)
- notify -> `$XDG_RUNTIME_DIR/agent-mail/*.json` -> AgentMail posts it (channel per priority: urgent/high/normal/low,
  versioned ids; urgent repeats within 10 min per sender collapse silently). Stored in files/powos-ai/agent-mail.json
  until read; read = tap/reply/mark read/swipe, synced both ways with comms (`powos comms read --agent user <ids>`).
- Android caps notification text at 5 KiB (MAX_CHARSEQUENCE_LENGTH) silently: collapsed = firstLine(), expanded =
  expanded() (<= 4.9 KiB + "N more characters - tap to read it all"); the tap opens the stored mail WHOLE in the chat
  (AgentMail.opened -> PowosAiChat.mail). Inline reply runs `powos comms send <agent> -- <text>`.
- Deploy notes arrive as mail `from: "deploy"`, low priority, `--batch deploy` (2 min window: one notification).

## Silent deploys (fb1ae36)
- Notes only for what the user can see. Refactors/lint/tooling: `--silent` instead of `--note` on tools/phone/ship.sh request, targets/android/install-app.sh, rooted.sh, targets/android/tools/deploy-note.sh.
- Silent = `powos comms notify --silent`: no inbox, no agent-mail, no feed row; one JSON line in
  `$COMMS_ROOT/quiet.log` (last 500), read with `powos comms quiet [-n N]`. push manifest carries "silent":true.
- The app needs nothing for it (it only notifies from comms mail). apps/install.sh still needs --note (the phone's
  `powos app --note` path). ship-apk's post-install re-push is always silent.

## The work board (`powos agents task`, lib/ai/agents/powos-agents-cli)
- Rows: agents module (apps/agents) table `work`, over STDB HTTP (127.0.0.1:3410, token ~/.config/spacetime/cli.toml).
  Off the phone the CLI relays to the phone (remote(), HACK via powos-vadb); POWOS_AGENTS_REMOTE=0 disables.
- Reducers: work_set(id,title,owner,status,note,project) - "" keeps a field; work_track(id, progress_done,
  progress_total, step, steps, commits, images) writes the progress columns WHOLE (the CLI computes them from the
  row); work_drop(id). Statuses working|blocked|waiting|done.
- Progress columns (after `project`, all #[default]): progress_done/progress_total u32 (0/0 = no bar), step, steps
  (JSON [{text, state: done|current|next}]), commits (JSON [{sha(12), subject}]), images (JSON [path]), activity u64
  (0 on old rows -> use updated). "" = empty list. TS client keys: progressDone/progressTotal (camelCase).
- CLI: `task add|new <title> [--id --owner --project --status --note]`, `task set <t> --progress N/M --step TEXT
  --plan "a; b; c" --commit SHA... --image PATH... --image-rm PATH... --owner E`, `task done <t>`,
  `task list [--all --json --project P --unowned --owner E]`, `task rm`, `task infer`.
  - --step: the old current becomes done; a planned step of that text becomes current, else inserted before nexts.
  - Count follows the steps unless --progress set it (explicit wins); done fills the bar.
  - Commits are resolved in the CALLER's git repo before the relay (resolve_commits), plus commits of the last 30
    days whose message mentions the task id.
- Owners: experts take tasks with `--owner <expert>`; `--unowned` = owner "" or the generic "coder".
- Task keys (find()): exact id, or WHOLE title words matching one open task (else one task at all). Refused: an
  id-shaped key (one token with '-') that isn't an id (suggests prefix matches), a key of only status words, >1 match.
  Why: a games agent took `task list | grep .. | grep -o '^[^ ]*'` = the STATUS column, ran `task set working --step`,
  and the old substring match wrote its step + owner onto the one open task with "working" in its title. Scripts get
  ids from `task list --json`, never the text columns. Fixing a wrong step: no CLI verb rewrites steps; call
  work_set/work_track whole via the installed CLI module as the session user (tools/phone/user.sh).
- lib/ai CLI changes reach the phone via rooted.sh deploy (ship.sh ships only shell + APK). The Mac has no `powos`:
  run `python3 lib/ai/agents/powos-agents-cli task ...` (it relays argv to the phone's CLI, whose find() decides).
- Truth (2026-10-23, board-truth): `task list` and the AI page show a COMPUTED state per task - CLI truth() and
  shell/agents.ts boardState, the same rule: working (a live agent's `work` == the id - agentsd work_of(), from its own
  Bash `task set <id> --step/--progress/--plan/--commit`, cleared by `task done`/`queue.sh add .. <id>` - or a live
  agent whose role == owner holding nothing; live = working|needs_you heard < 30 min), else awaiting-check (a
  work_check row queued/running; the step marker QUEUED_STEP before a sync), no-check (a result FAIL/INVALID/SKIP/
  PASS/none or commits linked), stalled (nothing), blocked (blocked|waiting + note), done. Holders come from the spool:
  `$XDG_RUNTIME_DIR/agents/state.json` + `mirror/*.json` (the Mac's agents; POWOS_AGENTS_SPOOLS overrides in tests).
  `task list --json` adds truth/why; `--state S`; `--raw` the typed status. No 20-min stall timer any more.
- Tables beside `work` (apps/agents, additive: `work` itself unchanged, so old shells still decode it):
  work_check (job pk, task idx, name, state queued|running|PASS|FAIL|SKIP|INVALID|none, line, at, need, shipped):
  check_set(json) from queue.sh (add: queued; result: before the step/close), check_sync(json array) from the Mac
  sweeper (drops queued rows the queue no longer has; results kept 14 d, the task's latest always); `none` =
  `--no-check` reason. friction (id f<N>, key area|kind|norm(title) idx, title/details/repro/evidence/by, count,
  first/last, status open|fixed, fix_commit/fix_note/fixed_at, reopened): friction_add(json) dedupes on key (norm:
  lower case, words with a digit -> '#'), a fixed one logged again reopens; friction_fix(id, sha, note). user_ask (id,
  at, text, by, task, none): user_ask_add(json) from manager.py's _ask_turn (each user turn; also
  $session_store/asks.jsonl, `ask sync` replays it), user_ask_link(id, task, none). Reducers take JSON strings: the
  Rust lint's 4-arg limit.
- The done rule lives IN work_set (may_close): status -> done needs the task's latest PASS|FAIL|none check to be a
  PASS with shipped=true, or none. The queue's --close path writes check_set PASS first (queue.sh board()).
- Sweeper: Mac launchd com.powos.board-sweep (tools/agents/board-sweep.sh, every 600 s, unit board-sweep-mac): origin's
  CLI `check scan` of ~/.cache/powos-verify-queue (queued *.job, done/*.log last line PASS|FAIL|SKIP|INVALID; shipped
  = the job's need is in ship live/installed like queue.sh shipped()) -> one user.sh call: `check sync` + `powos agents
  sweep`. sweep: orphans (stalled|no-check|blocked "no reason given", past a 10-min grace), untracked asks (> 10 min),
  open friction whose count rose -> ONE `powos comms send coder -` digest, only items whose signature changed (state
  file ~/.local/state/powos/board-sweep.json). `--dry-run` prints, mails nothing, keeps the state.
  `check sync` also closes a task whose latest result is a shipped PASS of a `--close` job (the scan's "close") when the
  task wasn't touched > 5 min after it: an older runner copy's close was refused (no check row yet).
- Auto friction: ship.sh mail() on FAILED/REFUSED; gate.sh fail at 1-min load >= 12 (background, the Mac CLI relay);
  queue.sh SKIP/INVALID; agentsd refusal() on PostToolUseFailure whose `error` matches REFUSAL (once/h per role+tool+
  hint; the sibling powos-agents-cli or POWOS_AGENTS_CLI). Mac: tools/agents/friction = the CLI's `friction`.
- Relayed off the phone, stdin and files are read on the caller's side first (inline_stdin: `--details -`, `ask add -`,
  `check sync <file>`), since remote() passes argv only.
  Device check: tools/phone/verify/board-state.sh (states working / awaiting check / no check / stalled).
- A schema change ships as: apps/build.sh agents; apps/vendor.sh agents (shell/vendor/powos-agents.js; the .d.ts is
  generic); `ADB="docker exec powos-vadb adb" apps/install.sh agents publish --note/...`; shell/push.sh
  vendor/powos-agents.js (bindings-check must say "matches"). A server with MORE columns than the shell's bindings
  breaks decoding too (seen with local-pet), so publish + push together.
- Rust limits: tools/lint/rust-complexity.sh [--report|--prune] agents (cognitive 10, 60 lines, 4 args, nesting 3);
  sync() is split into sync_agents/tasks/asks/ring/messages; JSON columns go through json_list().
- Tests: test/tier1/test-agents-board.py (stand-in STDB HTTP server modelling the reducers), test-agents.py,
  test-board-truth.py (truth, done rule, check scan, sweep digest/no-repeat, friction dedupe/reopen, agentsd
  refusal, manager ask turn).

## Pitfalls seen
- Shell gate under Mac load (~25): every page "not ready" - retry with READY_MS=60000 GATE_WIDGETS=0, never --force.
- The worktree has no shell/node_modules: push.sh skips tsc; symlink another worktree's for `tsc --noEmit -p .`.

## Latest hand-off (board CLI)
Added `task merge <dup>... --into <task> [--note]` and `task dupes` to `powos-agents-cli` (CLI-only, no module
schema change): merge copies title/note/open-steps/commits/images onto the target, marks dups done ("merged into
<id>") with a check_set(none) so the done-rule needs no phone check; `find()` now accepts a unique id PREFIX,
listing candidates on ambiguity instead of refusing blind. Friction f75 fixed. New friction worth checking before
your next board-CLI task: f90 (a directory-scoped skill can't load until its worktree exists - `cat` the SKILL.md
of a sibling worktree instead), f93 (test-agents-board.py's `FakeStdb.clock` is class-level, not reset per test -
derive timestamps from a row you just created, never hardcode small literals), f96 (no friction-id lookup besides
`friction list --all`), f100 (both CLAUDE.md copies, ~18k tokens, load every turn regardless of relevance).
