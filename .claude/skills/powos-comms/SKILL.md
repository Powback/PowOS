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
- Notes only for what the user can see. Refactors/lint/tooling: `--silent` instead of `--note` on shell/push.sh,
  tools/phone/ship-apk.sh, targets/android/install-app.sh, rooted.sh, targets/android/tools/deploy-note.sh.
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
- Live state (shell/agents.ts boardState): a `working` row SAYS "working" (lit dot) only while a live agent holds it -
  agentsd's agent row field `work` = the task id, set from the agent's own Bash `task set <id> --step/--progress/
  --plan/--commit` (work_of(); assigning with --owner/--note claims nothing), cleared by `task done <id>` or
  `queue.sh add .. <id>`; else a live agent whose role == owner and holds nothing. Live = working|needs_you, heard
  < 30 min. Otherwise "awaiting check" (QUEUED_STEP), "stalled" (started, no activity 20 min; one setTimeout to the
  boundary, useStallClock) or "queued". `work` rides the spool/mirror JSON only (STDB's AgentRow ignores it: no
  schema change). Mac deploy = copy powos-agentsd to ~/.claude/hooks/powos-agents/ + kill its pid (next hook restarts).
  Device check: tools/phone/verify/board-state.sh.
- A schema change ships as: apps/build.sh agents; apps/vendor.sh agents (shell/vendor/powos-agents.js; the .d.ts is
  generic); `ADB="docker exec powos-vadb adb" apps/install.sh agents publish --note/...`; shell/push.sh
  vendor/powos-agents.js (bindings-check must say "matches"). A server with MORE columns than the shell's bindings
  breaks decoding too (seen with local-pet), so publish + push together.
- Rust limits: tools/lint/rust-complexity.sh [--report|--prune] agents (cognitive 10, 60 lines, 4 args, nesting 3);
  sync() is split into sync_agents/tasks/asks/ring/messages; JSON columns go through json_list().
- Tests: test/tier1/test-agents-board.py (stand-in STDB HTTP server modelling the reducers), test-agents.py.

## Pitfalls seen
- Shell gate under Mac load (~25): every page "not ready" - retry with READY_MS=60000 GATE_WIDGETS=0, never --force.
- The worktree has no shell/node_modules: push.sh skips tsc; symlink another worktree's for `tsc --noEmit -p .`.
