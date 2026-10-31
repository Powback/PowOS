---
name: powos-data
description: Use for the PowOS phone's SpacetimeDB (modules, vendored bindings, decode errors, bindings-check, publishing), inter-agent comms (powos comms send/watch/inbox, the work board, agentsd, agent-mail), or PowOS AI's chat (manager rendering, tool steps, choice/present cards, the AI page).
---

## Quick recipe
- Files: `apps/<app>/src/lib.rs` (the STDB module), `shell/vendor/<db>.js`+`.d.ts`+`VERSIONS`, `shell/apps/stdb.ts`;
  comms: `lib/ai/comms/{comms.sh,comms-mcp.py}`, `lib/ai/agents/{powos-agents-cli,powos-agentsd}`,
  `lib/ai/manager/manager.py`, Kotlin `AgentMail.kt`; chat rendering: `shell/ui/{rich,chat,powai}.tsx`.
- Things to try reach the user as the manager's chat message: comms tool `present_try {title, items: [{id, line, do?}]}`
  (one per ship, board task ids + their --try lines) -> manager.py emits a ```try block -> `shell/ui/trycard.tsx` draws
  works / still broken (do: done / can't) and records it on the task (bridge ai.verdict + mail naming the task).
- Build/regen bindings: `apps/vendor.sh <app>` (must reproduce committed vendor files byte-for-byte; commit, then push).
- Check (no device needed first): `tools/phone/bindings-check.sh --no-publish`; tier-1
  `python3 test/tier1/test-{comms,comms-fulltext,manager,agents,board-truth}.py` and `bash test/tier1/test-bindings-check.sh` (bindings-check is .sh only). Device:
  `tools/phone/verify/board-state.sh` (board states); phone reads STDB live over adb.
- Publish a module change: `ADB="docker exec powos-vadb adb" apps/install.sh <app> publish --note "plain words"`
  (additive columns need `#[default(...)]`) — ships WITH its re-vendored bindings, same commit. lib/ai (comms,
  manager) reaches the phone via `PATH="$PWD/tools/phone/bin:$PATH" targets/android/rooted/rooted.sh deploy --note "..."`.
- Land: `tools/agents/land.sh "msg" -- <paths> --ship "..."` (schema changes to apps/agents also need a publish).
- Friction: `tools/agents/friction add --area <stdb|comms|chat> --kind <...> "<title>" --repro "<cmd>"`.

### stdb
- Module-only manifest template: `apps/agents/powos-app.json` (no UI/backend, f157).

### comms
- Mac agentsd: copy to `~/.claude/hooks/powos-agents/`, then kill its pid. `rooted.sh` plain `adb` needs the `PATH="$PWD/tools/phone/bin:$PATH"` prefix above.

## stdb



# The phone's SpacetimeDB

## What runs
- One server per device: `spacetimedb-standalone` 2.12.0 at 127.0.0.1:3410 (unit dev.powos.spacetimedb, data
  /var/lib/powos/stdb). Its port is locked to the PowOS app's uid; root inside PowOS reaches it too. The client SDK
  is vendored at the same version (shell/vendor/spacetimedb.js); bump both together (targets/android/pkgs/spacetimedb-bin).
- Every PowOS app is a database. The shell vendors three (shell/vendor/VERSIONS, the "generated" lines = the list
  every tool reads):
  | vendor file | database | source | shell users |
  |---|---|---|---|
  | local-pet.js | local-pet | apps/pet | ui/pet.tsx (pet, said) |
  | powos-agents.js | powos-agents | apps/agents (no UI: bindings in out/bindings) | ui/pet.tsx, ui/powai.tsx (work), ui/units.tsx (unit) |
  | powos-registry.js | powos-registry | apps/registry (no powos-app.json; published by lib/apps/powos-app) | apps/registry.ts (app, widget) |
- Apps' islands (local-lights, local-shopping, ...) bring their own bindings in their UI (`powos app build`), not vendored.
- Live schema: `curl http://127.0.0.1:3410/v1/database/<db>/schema?version=9` (tables[].name,
  typespace.types[product_type_ref].Product.elements[].name.some). Installed apps: /home/powos/.local/share/powos/apps/<id>/current.

## Decode-error signature
`rejection (vendor/spacetimedb.js:19): Offset is outside the bounds of the DataView` in shell-errors.log (home) means
a table's bindings have more columns than the server's rows (BSATN is positional). On 2026-10-21 this happened twice:
local-pet's `overlay` and then the `goto_*` columns were added to the bindings but the module was never published.
It recurs on every page load, because the initial subscription fails. It is not a power-loss or reconnect fault.

## The guard (shell/apps/stdb.ts)
- The builder's public `dbConnectionCtor` is wrapped so `createWSFn` returns a socket whose onmessage runs in a try. A throw
  goes to `undecodable()`. It drops that connection, fetches the server schema, and compares it with
  `builder().remoteModule.tables` (column = columnMetadata.name ?? key). It then reports
  `stdb: <db>: a message didn't decode (...) - bindings stale for <table> (bindings: ...; server: ...): not subscribed`
  via `__powosBoot.report` (shell-errors), sets `stale`, and reconnects in 3 s. useRows/watchRows skip stale tables.
- Stale lasts until the entry is dropped (page hidden 5 s). A replaced connection's callbacks are ignored (`mine(c)`).

## bindings-check (tools/phone/bindings-check.sh + .mjs)
- Run by shell/push.sh --vpn (schemas read in its one phone call) and ship-apk (after the install). Standalone it makes one
  adb call. `--remote-cmd` prints the phone-side command.
- The bindings checked are the ones the phone runs: the pushed files, then overrides, then the installed APK's shell, then shell/vendor.
- Per database: `ok`; `absent` (not checked); `ahead` (the bindings add tables or trailing columns): if
  apps/<app>/powos-app.json + module exist and `apps/vendor.sh <app> --out tmp` is byte-identical to the bindings, publish
  (`apps/install.sh <app> publish`); else refuse with the fix. `differs` (any other shape, e.g. the phone's module is newer):
  refuse, never publish. `--no-publish` refuses on ahead too. Test hooks: BINDINGS_ADB / BINDINGS_VENDOR / BINDINGS_PUBLISH.

## Codegen gap: a struct used ONLY as a reducer param
- A `#[derive(SpacetimeType)] struct Foo{...}` that's used only as a reducer argument (never also a table column)
  may not round-trip through `spacetimedb-cli generate --lang typescript`: the Rust side builds fine, but
  `apps/vendor.sh`'s esbuild step fails ("No matching export") because the generated `*_reducer.ts` imports `Foo`
  from `./types`, while that same generation run's `types.ts` never defines it. Reproduced against apps/registry
  (`creation_begin`); apps/sketch's `ViewIn`/`StrokeIn` structs work fine as table-column types, so this is specific
  to reducer-only structs. Workaround: avoid the struct-only-param shape entirely (e.g. fold the extra value into an
  existing string param instead of adding a struct arg) and verify any new reducer-param struct with a real
  `apps/vendor.sh <app>` build before relying on it (friction f137).

## Commands
- Regenerate bindings: `apps/vendor.sh <app>` (apps/build.sh in the rust container, then esbuild of the bindings'
  index.ts, spacetimedb external). It reproduces the committed files byte for byte. Commit them, then push `vendor/<db>.js`.
- Publish a module: `ADB="docker exec powos-vadb adb" apps/install.sh <app> publish --note "plain words"` (a hot swap;
  additive columns need `#[default(...)]`); for module-only apps use `publish`, not `install` (f155).
- Check: `tools/phone/bindings-check.sh --no-publish`; tier-1: `bash test/tier1/test-bindings-check.sh`.
- Row peek on the phone (root.sh script): `curl -s -X POST -d "SELECT * FROM pet" http://127.0.0.1:3410/v1/database/local-pet/sql`.
- Inside PowOS, avoid `journalctl` and `/logs` endpoints in root.sh scripts; they hung for minutes.

## Latest hand-off (App API)
- State (29c3ca50, on origin, NOT on the phone yet - ships + verify were paused): "+ add app" in apps/app-api. Drafts
  in STATE/drafts/ (never specs/) via tools/app-api/appcap_add.py: one normalize() + appcap_validate; routes /drafts,
  /draft, /installed, /draft/import|installed|add|discard; /call draft:true = appcap_run --draft (dry run only).
  Origin "drafted" + S3; /enable on a write promotes it. Shell: host.askAssistant/androidApps/appLinks (apps/stdb.ts);
  Kotlin apps.links (shell/AppLinks.kt, base.apk manifest parse, nothing fired). Tests: test/tier1/test-appcap-add.py.
- Deploy (the ship service does NOT do these): 1) ship.sh resume (APK + shell); 2) PATH=$PWD/tools/phone/bin:$PATH
  targets/android/rooted/rooted.sh deploy --note "..." then restart the app-api service; 3) apps/build.sh app-api &&
  apps/install.sh app-api install --note "...". Then e2e job 20261024-034701-19743 (e2e-appapi --round add-app).
- Gotchas: the runtime is capped at 48 MB (never run a model in it). A PowOS app's tables/reducers come from its OWN db
  only (layer separation). Unverified: AppLinks on a real APK, STDB HTTP sql/call bodies, the PowOS AI hand-off.
  App UI tsc: a temp tsconfig mapping preact -> shell/node_modules/preact.

## comms



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

## chat


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
`present_try {title, items:[{id, line, do?}]}` is a third: ```try + {"title":..,"items":[..]} (trycard.tsx, registered
in rich.tsx `blocks`).
So any consumer of the stream gets it (the KDE plasmoid shows it as code). Only these names are blocks
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

- Black flash on send = PowosAiActivity started (ai.send's recents arg true -> keepInRecents). app.tsx imports
  assist.tsx in every mode, so assist registers setAskContext(withScreen, true) on Assist's mount, never at import.
  Check: tools/phone/verify/ai-send-flash.sh (events log wm_create_activity/new_intent + black frames).
  Its "the field isn't showing" (rc 5) of 2026-10-23 was the check, not the page: it ran right after sketch-canvas.sh
  had rotated the screen, home was still booting (widgets empty plates in the screencap) and the one swipe didn't land.
  The check now swipes the lock face, waits for home's field, retries the swipe. A rc-5 "isn't showing": read the
  page over CDP (`.ai-screen .ai-compose textarea`) and the run's design-qa screencap before touching powai.tsx.
- Wide = the whole conversation (powai.tsx History, no "earlier" fold; narrow keeps Earlier): the newest 20 exchanges,
  20 more when a top sentinel comes within 600 px (IntersectionObserver, root = the pane). `.ai-view.wide > .ai-talk`
  is flex column-reverse around one `.ai-talk-in` (margin-bottom auto = short content sits on top): it opens at the
  newest, stays there while a reply streams, holds still when older ones arrive - no scroll JS. Its scrollTop is 0 at
  the bottom, negative upward. Device: ai-wide.sh checks no fold + |scrollTop| < 4 (BOARD_TASK= picks the task).
  The history list is ONE `.tile` (`.chat.ai-history-list.tile`: one native blur region, its messages soft fills on
  it). Bare, its messages sat on the wallpaper, unreadable over a bright one (59bbb41's regression). ai-wide.sh fails
  on any .msg in the talk pane without a frosted tile behind it (under glass-native the fill is background-IMAGE,
  backgroundColor is transparent).

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
