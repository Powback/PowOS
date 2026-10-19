# PowOS Agents view — design

Status: **Phase 1 built** (2026-10-19): `lib/ai/agents/` (powos-agent-hook, powos-agentsd, powos-agent-ask,
install-hooks.py), `AgentsSpool.kt` + `ShellPanels.kt` on the phone, `shell/agents.ts` + `shell/ui/agents.tsx`. Not
built from Phase 1: the pause gate (a synchronous PreToolUse hook would add a process spawn to every tool call - §5
allows 0 ms), asyncRewake mail delivery, and actions on the Mac's agents (they need the mirror's reverse path).
Approvals (§6) are on the phone only; on timeout (60 s) Claude asks at its terminal.

Problem: from the phone the user can't see which agents are running, their subagents, or what each one is
working on. Today the AI page has "at work" (tmux sessions: a pane title, a spinner glyph, polled every 5 s) and "from
agents" (AgentMail: the last `notify_user` texts). Neither shows the tree, tasks, tool calls, approvals or handoffs.

This is meant to be the first real **Astro + SpacetimeDB** PowOS app. `docs/POWOS-APPS-FEASIBILITY.md` (the app-model
study: Astro + SpacetimeDB, one server per device, tiers) **wasn't in the tree when this was written**. This design
assumes that stack and follows the "one server per device" rule: each device's server owns its own agents and viewers
subscribe to several servers. Nothing is replicated between servers. Once that study lands, check this doc against it.
Where the two disagree, the study wins and this doc gets updated.

---

## 1. Surfaces

### 1.1 Home widget "Agents" (phone home, 4×2 default; 4×1 = count line only)

```
┌ Agents ─────────────────────── 3 running · 1 needs you ┐
│ ● coder    · mac   · hosted widgets (3 sub)      12s   │
│ ◐ manager  · phone · waiting on coder             2m   │
│ ! devops   · phone · approve: rm -rf out/   [needs you]│
│ ○ health   · phone · idle                         1h   │
└────────────────────────────────────────────────────────┘
 ● working  ◐ idle/waiting  ■ blocked (error/limit)  ! needs you
```

- One line per top-level agent: `role · host · current task · last active`. Subagents fold into `(n sub)`.
- Order: needs-you, then working, blocked, idle. At most 4 lines, then `+n more`.
- Tapping a line opens the Agents screen on that agent. Tapping `[needs you]` opens the approval sheet.
- Implementation: a **shell-native** home item (Preact, new `kind: "panel"`, key `agents`), not OWL. The data is
  already in the shell, and an OWL tree would have to be re-sent on every change. Adding a home item kind touches
  `shell/ui/grid.tsx` and `types.ts`, which other work is also editing, so coordinate before landing.

### 1.2 Android notifications

**Ongoing** (channel `powos-agents-live`, IMPORTANCE_LOW, silent, `setOngoing`, `setOnlyAlertOnce`). It exists only
while at least one agent is `working`:

```
PowOS agents · 2 working
coder: hosted widgets · 3 subagents      [Open] [Pause all]
```

- Title: the working count. Text: the busiest agent (most recent activity) and its subagent count.
  Expanded (InboxStyle): one line per working agent.
- It is updated **at most every 5 s**, and only when the rendered text changes. `notify()` with the same text is
  skipped in-app. It is cancelled once everything has been idle for 30 s.

**Approval** (channel `powos-agents-ask`, IMPORTANCE_HIGH, heads-up, CATEGORY_MESSAGE, one per `ask.id`):

```
devops wants to run Bash
rm -rf out/ && ./build.sh                       [Allow] [Deny] [Reply…]
```

- `Allow` / `Deny` are broadcast actions, like `AgentMail.Reply`. They write the decision into the spool
  (`asks/<ask_id>.answer`), and the waiting hook picks it up (§6). `Reply…` is a RemoteInput that sends a
  deny-with-reason, which the agent reads as its instructions.
- If the ask expires (the hook times out and the agent falls back to its own prompt or a safe default), the
  notification is replaced with "expired · decided at the terminal".

**Mail** stays as it is (AgentMail.kt). The Agents view only adds a count to it, and the feed in 1.3.

### 1.3 Agents screen (the shell on the phone: AI page → "Agents"; desktop: same page in a window/plasmoid)

```
┌ Agents ──────────────────────────────── ● live  [⏸ all] ┐
│ ▾ manager (phone) ◐ waiting · "ship widgets" · 2m       │
│   ▾ coder (mac) ● hosted widgets · Edit ShellBridge.kt  │
│       ├ Explore  ● "find FileObserver users"  4 tools   │
│       ├ Plan     ✓ done 1m                              │
│       └ general  ● "survey SpaceTimeAI"      18 tools   │
│ ▸ devops (phone) ! needs you                            │
│ ▸ health (phone) ○ idle 1h                              │
├─ coder ─────────────────────────────────────────────────┤
│ Now: Edit shell/ui/grid.tsx                             │
│ Tasks  ✓ read context  ✓ hooks facts  ● write design    │
│        ○ commit  ○ message manager                      │
│ Tools  Read×6 · Bash×3 · Edit grid.tsx ✓ · Bash ✗ (2s)  │
│ Last report: "design drafted, waiting on survey"        │
│ [Message] [Approve/Deny] [Pause] [Stop]                 │
├─ Comms ─────────────────────────────────────────────────┤
│ 19:02 manager → coder   task: agents view design        │
│ 19:40 coder → manager   report: design + goodies        │
│ 19:41 devops → user     ask: Bash rm -rf out/           │
└─────────────────────────────────────────────────────────┘
```

- The tree is manager → coder (Mac) → subagents, plus every phone agent. The parent link comes from comms
  identity (`COMMS_PARENT_ID`) and from `SubagentStart` (§3).
- Per agent: its task list (done / in progress / open), current step, the last 20 coalesced tool calls, its last
  report, and actions.
- The comms feed shows who handed what to whom: the message table, newest first, the last 50. Tapping an entry
  opens the message body.
- **Desktop:** the same Preact page served from the shell bundle. Phase 1 opens it in a `powos-shell`/WebEngine
  window (DESKTOP-WEB-SHELL.md). Phase 2 is a Plasma widget: a minimal QML plasmoid holding a WebEngineView on
  the same page (or the panel role once powos-shell replaces plasmashell). There is one UI codebase. Only the
  transport adapter differs (§4).
  The existing manager plasmoid (`com.powos.manager`) already has an agent roster with unread badges. Its roster
  pane should become this view, either by embedding the page or by reading the same spool, so the desktop doesn't
  end up with a second, competing agent list.
- The existing "at work" list (tmux) stays as a fallback for agents that have no hooks, such as gemini/ollama
  clients and old sessions. Each entry is marked `· untracked`.

---

## 2. States

| state | set by | meaning |
|---|---|---|
| `working` | UserPromptSubmit, PreToolUse, SubagentStart, PostToolUse | a turn is running |
| `idle` | Stop (and no live subagents), SessionStart | waiting for input/mail |
| `needs_you` | PermissionRequest; Notification `permission_prompt` / `idle_prompt` with an open ask | a human decision blocks it |
| `blocked` | StopFailure, PostToolUseFailure ×3 in a row, rate-limit queue (claude-auth) | stuck on an error/limit |
| `paused` | our pause gate (§6) | held by the user |
| `gone` | SessionEnd, or no event for 15 min plus the pid is dead | kept 1 h, then dropped |

---

## 3. Data model (one schema, two backends)

The same four tables (plus `ask`) exist both as spool JSON and as SpacetimeDB tables, with identical field names
and types. Ids are strings everywhere. Times are Unix ms (`u64`).

```ts
agent {                // one row per Claude session or subagent
  id: string           // "<host>:<session_id>" or "<host>:<session_id>/<agent_id>" for a subagent
  host: string         // "mac" | "phone" | hostname
  role: string         // COMMS_AGENT_ID, else agent_type, else "claude"
  parent: string|null  // agent.id of the parent (subagent: its session; coder: manager via COMMS_PARENT_ID)
  state: "working"|"idle"|"needs_you"|"blocked"|"paused"|"gone"
  title: string        // current task: in-progress TaskUpdate subject > last prompt's first line (≤80 chars)
  step: string         // "Edit grid.tsx" (≤60 chars)
  cwd: string          // folder name only
  pid: u32             // for pause/stop (host-local meaning)
  subs: u16            // live subagent count (denormalized for the widget)
  unread: u16          // comms inbox depth for role
  report: string       // last_assistant_message from Stop/SubagentStop, ≤280 chars
  started: u64; last: u64
  rev: u32             // bumped on every row change; snapshot diffing
}
task  { id: string /*agent.id + "#" + task id*/, agent: string, subject: string(≤100),
        status: "open"|"in_progress"|"done", order: u16, updated: u64 }
event { id: u64 /*per-agent seq*/, agent: string, ts: u64,
        kind: "tool"|"prompt"|"stop"|"sub_start"|"sub_stop"|"notify"|"fail"|"compact",
        name: string /*tool name*/, hint: string(≤60) /*file basename / command head*/,
        ok: bool|null, n: u16 /*coalesced count*/, ms: u32 /*duration*/ }
message { id: string /*comms id*/, from: string, to: string, kind: "message"|"escalate"|"notify"|"ask"|"report",
          priority: string, ts: u64, body: string(≤280 preview), read: bool }
ask   { id: string, agent: string, tool: string, summary: string(≤200), ts: u64, expires: u64,
        answer: "allow"|"deny"|null, reason: string|null, by: string|null }
```

Never stored: full tool inputs/outputs, file contents, transcripts, env, or any token. `hint` is derived by a
fixed whitelist: the basename for file tools, the first 40 chars of `description` (or of `command`, after cutting at
the first `|`/`&&`) for Bash, and the tool name for everything else. Strings matching secret patterns
(`sk-…`, `ghp_…`, `Bearer`, `=…` after `TOKEN|SECRET|KEY|PASSWORD`) are replaced with `…`.

**Bounded history:** each agent keeps a ring of **64 `event` rows**. In the spool that is a fixed array with a head
index. In SpacetimeDB, the insert reducer deletes `seq - 64`. Messages keep the last 200 in total, tasks the last
50 per agent, and `gone` agents are dropped after 1 h along with their events.

**Coalescing:** consecutive tool events from one agent with the same `name` within 10 s collapse into one row
(`n++`, `hint` = latest, `ok` = AND), giving `Read×6`. PreToolUse only updates `agent.step`. The event row is written
on PostToolUse/PostToolUseFailure, or once per `PostToolBatch`, so there is one row per call and never two.

---

## 4. Event flow

```
 claude (any host)
   │ hooks: SessionStart UserPromptSubmit PreToolUse PostToolUse(Failure) PostToolBatch
   │        SubagentStart SubagentStop TaskCreated TaskCompleted Notification PermissionRequest
   │        Stop StopFailure PreCompact SessionEnd       (stdin JSON: session_id, agent_id, agent_type, …)
   ▼
 powos-agent-hook  (one tiny binary/script, async: true for everything except PermissionRequest)
   │ normalize → whitelist/trim → coalesce in a per-session state file → write
   ├─ Phase 1  spool:  $XDG_RUNTIME_DIR/agents/   (tmpfs; phone: /run/powos-app/agents/)
   │            state.json  (agents+tasks+asks, rewritten atomically ≤ 1×/250 ms)
   │            events/<agent>.ring.json   messages.json
   │            └─ FileObserver (one, in the app) → ShellBridge.emit("agents.delta", …) → every page
   │                                              → AgentsNotifier (ongoing + approval notifications)
   └─ Phase 2+ SpacetimeDB `agents` module on that host: http hook → reducer `ingest(batch)`
                └─ shell / plasmoid / notifier subscribe over WebSocket (one per device server)
 comms (lib/ai/comms/comms-mcp.py)
   └─ _deliver() also appends a `message` row (spool: messages.json; later: reducer call) — same hook writer
```

- **Hook config.** On the Mac this goes in `~/.claude/settings.json` (user scope, so every project's sessions are
  covered). It sits next to the existing `PreToolUse: Bash → br-gate.py`, and the two must coexist. On the phone it
  goes in PowOS's own `/etc/powos/claude/settings.json` (rootfs, managed by PowOS), or in `~powos/.claude/settings.json`.
  Prefer **passing `--settings <file>` from `lib/ai/clients/claude.sh` and `manager.py`**, so only PowOS-launched
  agents report and the user's own config is untouched. A coder session the user started by hand on the Mac is
  only covered by the user-scope entry, so that line needs the user's OK.
- **Why `async: true`.** A reporter must never slow a tool call. Async command hooks run in the background, and a
  failed write is lost silently and on purpose. The PermissionRequest hook is the only synchronous one (§6).
- **Hook cost.** Spawning one process per event costs about 5-15 ms on the Mac. On the phone, python3 startup is
  about 60 ms, which is too slow at 10+ events/s, so the hook should be a **small static binary (Rust/Go/C) or a
  POSIX-sh + `jq`-free writer**. The hook appends one line to `$RUN/agents/inbox.jsonl` (O_APPEND, atomic for lines
  under PIPE_BUF) and exits. The single **`powos-agentsd`** folds that log into state and rings, coalescing, with
  250 ms batching. It is not a polling daemon: it blocks on inotify of `inbox.jsonl`, and it exits after 10 min with
  no live agents. The next hook starts it again (with a flock).
  - Alternative with no daemon: the hook folds the state itself under a flock. That is simpler, but costs more per
    event and makes batching harder. Pick it if the daemon looks like overkill once measured.
- **Cross-host (Mac agents on the phone)**
  - Phase 1 (stopgap) uses the same spool format on the Mac. `powos-agentsd --mirror phone` pushes `state.json`
    and the changed rings into the phone's spool at most once a second, and only on change. Transport is
    `adb push` through `powos-vadb`, the same channel the coder already uses to mail the manager.
    `HACK: adb is a dev channel, not a transport; real fix = Phase 2 (phone subscribes to the Mac's agents module).`
  - Phase 2 adds the `agents` module on the Mac's SpacetimeDB (PowStation Docker, `agents.pow`, LAN/WireGuard
    only, not on powback.com). Mac hooks call it, and the phone subscribes to it directly, which removes the mirror.

### The backend swap

The shell talks to one interface, regardless of backend:

```ts
interface AgentsSource { subscribe(onDelta: (d: AgentsDelta) => void): () => void;
                         act(a: AgentAction): Promise<void>; }
type AgentsDelta = { agents?: Agent[]; gone?: string[]; tasks?: Task[]; events?: Event[];
                     messages?: Message[]; asks?: Ask[]; full?: boolean };
```

- `SpoolSource` (Phase 1): `powos.agents.snapshot()` returns `full`, and then `agents.delta` bridge events carry
  only the rows whose `rev` changed. Kotlin diffs `state.json` against the last copy it sent.
- `StdbSource` (Phase 2/3): one `DbConnection` per device server. Each `onInsert/onUpdate/onDelete` maps 1:1 onto
  the same delta shape. The table and field names are the spool's, which is the point of sharing the schema.
- Several sources merge by `agent.id`, which is host-prefixed so ids never collide. Moving a host from spool to
  SpacetimeDB is a config change: `agents.sources = ["spool:phone", "stdb:ws://agents.pow"]`.
- The hook writer is the other half of the swap. `powos-agentsd` gets a second sink (`--sink stdb`) that calls
  `ingest(batch)` with the same batch it would have folded into the spool. The coalescing and ring logic run in the
  module reducer instead.

---

## 5. Performance budget

| item | budget |
|---|---|
| hook wall time (async, off the critical path) | < 15 ms Mac, < 25 ms phone; 0 ms added to tool calls |
| phone CPU while 5 agents work hard (~20 events/s) | < 1 % of one core averaged; no wakelock |
| delta to the shell | ≤ 4 per second (250 ms batch), typically < 1 KB each |
| full snapshot | < 20 KB for 20 agents (64-event rings capped, strings capped) |
| shell when hidden | no work: page hidden → bridge stops emitting `agents.delta` and keeps only a dirty flag; on show → one snapshot |
| widget redraw | only the changed line (signals per agent id, like owl.tsx's per-key trees) |
| ongoing notification | ≤ 1 update / 5 s, skipped if text unchanged |
| polling | none. inotify/FileObserver (spool) or WebSocket push (STDB). The tmux 5 s poll goes away once hooks cover the agents |
| spool storage | tmpfs only (`/run/powos-app`), < 1 MB; nothing written to flash per event |
| STDB on phone | one process, idle when no client; measure RSS before Phase 3 (target < 60 MB) |

**FileObserver.** One observer watches `agents/` (`CLOSE_WRITE | MOVED_TO`), following the HotReload rule that
there is one observer per path per process. `powos-agentsd` writes files via tmp + rename, so each batch produces
exactly one event.

---

## 6. Actions and permissions: what actually reaches an agent

| action | mechanism | honest limits |
|---|---|---|
| **Message** | `powos comms send <role> <text> --from user` (as today). **Delivery to a live Claude Code session:** a `SessionStart`-registered **`asyncRewake`** command hook waits on the role's inbox (inotify; no polling) and exits 2 with the message on stderr. Claude is woken with it as a system reminder. The manager on the phone already gets mail as a real user turn (manager.py stream-json + agent-wake). | asyncRewake delivers a *system reminder*, not a user turn. That's fine for "do X next", but the agent decides. A session without the hook only sees mail when it next calls `read_inbox`. One-shot `--print` agents read it on their next run. |
| **Approve / Deny** | A **`PermissionRequest` command hook** (synchronous). It writes `ask` (spool / reducer), fires the approval notification, then blocks on `asks/<id>.answer` and prints `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"|"deny","message":…}}}`. Its own `timeout` is 300 s. | It only fires when Claude would *ask*. Anything already allowed or denied by rules never shows up. On timeout the hook exits with no decision, so Claude falls back to its normal prompt in the terminal (or a deny in `--print`/`dontAsk`). The default stays safe. Only the user (shell / notification) may answer, never an agent (§7). |
| **Pause** | **Cooperative gate:** a `PreToolUse` hook (sync, fast path: one `stat`) that, while `paused/<agent-id>` exists, blocks until it is removed (≤ 590 s, then returns `permissionDecision: "deny"` with reason "paused by the user; wait or ask"). It holds the agent at the next tool boundary. | It doesn't stop a model call that is already streaming. The turn's text keeps generating until the next tool call. **SIGSTOP** on `pid` (host-local; the Mac needs a tiny local agent) freezes immediately, but the open API stream will likely time out (about 10 min idle), so it's offered only as "Freeze (short)". |
| **Stop** | `SIGINT` to the session pid ends the current turn (like Esc), and the session stays. "End session" sends `SIGTERM`. A Stop hook can't stop an agent from outside: the hook only runs when the agent stops. | Signals are host-local. For the Mac in Phase 1 this needs the mirror's reverse path (an `actions/` spool the Mac's `powos-agentsd` watches, carried by the same adb channel: HACK). In Phase 2 a reducer `act(...)` row is watched by the host's agentsd. |
| **Pause all** | sets the gate for every `working` agent | same limits |

The hook binary must exit 0 silently on any error of its own. A broken reporter must never block or deny a tool.

---

## 7. Who may do what

- **Answers to asks and stop/pause** are user-only. Phase 1: the spool's `asks/` and `paused/` directories are
  writable by the app uid and root only, and the agents' uid (`powos`) can read but not write them. The hook checks
  the answer file's owner. Phase 2: reducers `answer`/`act` check that `ctx.sender` is a user identity, enrolled
  once per device and owned by the user. Agents get a reporter identity that may only call `ingest`. This is the
  same "envelope reducer checks the caller" idea as SpaceTimeAI, scaled down.
- **The module is LAN/WireGuard only** (`agents.pow`, never on powback.com). Rows carry no secrets (§3).
- Agents may read the view (it's useful for the manager), but they write only through the hook.

---

## 8. SpacetimeDB module sketch (Phase 2)

- Tables: `agent`, `task`, `event`, `message`, `ask` (§3), plus private `reporter(identity, host)` and
  `viewer(identity)`.
- Reducers: `ingest(host, batch: Rec[])` folds, coalesces and trims rings in one transaction, so a burst of 50
  hook events becomes one transaction and one delta per subscriber. Also `answer(askId, behavior, reason)`,
  `act(agentId, "pause"|"resume"|"interrupt"|"end"|"message", text)`, and a scheduled `sweep` every 60 s that marks
  agents gone and drops expired rows.
- Subscriptions, phone: `SELECT * FROM agent`, `SELECT * FROM ask WHERE answer IS NULL`, `SELECT * FROM message`
  (capped). It subscribes to `event` and `task` **only for the agent that is open**
  (`WHERE agent = '…'`), so an idle widget gets agent rows only.
- Built from `~/Projects/spacetimedb-astro` (SpacetimeDB 2.x, its `lib/db.ts`: subscription dedup, delta
  application, reconnect with backoff). Use the Preact signals variant instead of React hooks, because the shell is
  Preact. The Mac already runs `clockworklabs/spacetime:v2.10.x` (SpaceTimeAI), so the agents module gets its own
  small container, not a database inside SpaceTimeAI's instance. That keeps the two isolated.
- Phase 3: a SpacetimeDB standalone on the phone (aarch64), started on demand. Phone hooks switch `--sink stdb`
  and the spool is retired.

**Decided 2026-10-19 (manager): each device runs its own SpacetimeDB; the phone never depends on a hub.** The phone's
server exists now (docs/POWOS-APPS-FEASIBILITY.md §8: `127.0.0.1:3410`, the system tier, uid-locked), so Phase 3's
server is there; what remains, as a PowOS app on that runtime (not done yet - the plan):
1. `apps/agents/` like `apps/counter`: a Rust module, database `powos-agents`, with exactly §3's tables (`agent`,
   `task`, `event`, `message`, `ask`) and §8's reducers - the spool schema is the contract, so the shell's
   AgentsSource swap is a backend change only. `powos-app.json` with the Agents widget as `kind: "panel"` for now.
2. `powos-agentsd` keeps writing the spool (the fallback) and also calls `ingest(host, batch)` through one
   long-lived connection (Python: the SpacetimeDB HTTP `call` endpoint with the powos CLI identity is enough for the
   rate here; a WebSocket client only if batches need it). Unreachable server → spool only, nothing lost.
3. The Mac's sessions are mirrored in as rows with `host = "mac"` by the same `ingest` (the adb mirror stays the
   transport); the hub may run its own copy of the module for the desktop.
4. Shell: `AgentsSource` gains a SpacetimeDB implementation on `shell/apps/stdb.ts` (one socket, closed while home
   is hidden); AgentsSpool.kt stays for when the server is down.
5. Idle cost: the database stays loaded while anything subscribes; the supervisor's idle unload applies otherwise
   (each loaded database costs ~145 wakeups/s on the phone, §8 there).

**The work board (2026-10-20).** The per-session `task` rows are each Claude session's own todo list, replaced on
every `sync` and gone with the session, so they can't say "what are we working on" across agents. The module has a
second, durable table for that: `work { id, title, owner, status: working|blocked|waiting|done, note, created,
updated, done }`, written only through `work_set` / `work_drop` (reporters only) by `powos agents task
add|set|done|rm` (lib/ai/agents/powos-agents-cli; the manager's prompt makes it record every handoff). The PowOS AI
page (shell/ui/powai.tsx `Work`) subscribes to it while it shows: one line per open task, newest activity first, the
ones done within a day folded under "done recently". Done rows leave after a week.
HACK: off the phone the CLI runs itself on the phone over powos-vadb; real fix = each host's module + the mirror.

---

## 9. SpaceTimeAI: goodies worth porting

SpaceTimeAI (`~/Projects/SpaceTimeAI`) is a full self-improving agent harness. Running it takes roughly 10
containers on the Mac (SpacetimeDB, web console, control, worker(s), merger, egress, previewer, blobstore,
discord, backup). The agents view should take ideas from it, not run it. Table below. Weight = what the feature
needs in SpaceTimeAI.

SpaceTimeAI measured live on 2026-10-19 (`docker stats`): stdb 1.1 GB, worker 1.0 GB, web (Astro dev) 375 MB, the rest 4-133 MB each. That is about 2.8 GB across 11 containers. The `discord` bridge sat at about 100 % CPU while idle. That is worth a separate look; this doc doesn't touch it.

| # | feature (SpaceTimeAI path) | weight there | verdict | why / how here |
|---|---|---|---|---|
| 1 | **Live session mirror with batching**: events flushed every 500 ms, the typing delta throttled to 200 ms, the delta row deleted at end (`agents/worker/session/run.ts` mirror) | low code; inside the worker | **port now** | This is the same idea as `powos-agentsd`'s 250 ms batch (§4). We skip the typing delta: `step` is enough on a phone. |
| 2 | **Bounded, trimmed views**: feed = last 400 events sliced to 600 chars; traces capped; over 8 KB spills to blobs (`console-views.ts`) | low | **port now** | Becomes the 64-event ring per agent, the field caps (§3), and nothing big stored at all. |
| 3 | **rAF-batched repaint of only the changed views** (`web/src/console/live.ts`) | ~90 lines | **port now** | The shell's per-agent signals plus one repaint per frame. |
| 4 | **Needs you / permission cards** (`core/actions.ts`, `worker/session/bridge.ts`, `views/needs.ts`): idemKey = toolUseID, a deadline that expires to a safe default, a re-check on allow | low (~200 lines) | **port now (idea), different transport** | Ours: a PermissionRequest hook plus the `ask` table and expiry back to the terminal prompt. Keep "nothing undecided runs" and "expires to the safe default". Their bridge polls a cache every 250 ms; ours blocks on inotify / a subscription. |
| 5 | **Read-only shell classifier** (`core/readonly.ts`) | ~50 lines, pure | **port now** | Lets the pause gate and the ask hook wave read-only Bash through, so there are fewer asks on the phone. |
| 6 | **"Allow and remember" → policy row**, deny wins, prefix pattern (`policy`, `console_policies`) | low | **port later** | Phase 1c+: write a Claude Code permission rule (`permissions.allow`) instead of our own policy table, so it stays native. Needs the user's OK per rule. |
| 7 | **Envelope reducer + capability gate** (`core/envelope.ts`) | ~150 lines | **port later (Phase 2), scaled down** | Two capabilities only: reporter (ingest) and user (answer/act). That's all §7 needs. |
| 8 | **Stall detection**: progress, idle calls, remind / redirect (`core/stalls.ts`) | low | **port later** | `blocked` after N failures or no progress, then a "nudge" action that goes via asyncRewake. Cheap once events exist. |
| 9 | **Lease notes = messages into a running session** (`session/inbox.ts` via streaming input) | low | **adopt the idea, ours already exists** | manager.py already injects inbox mail as user turns; asyncRewake covers interactive sessions. The survey suggests SpaceTimeAI's `actionDecide` may not send a late approval as a note. Avoid that gap: a late answer always becomes a comms message. |
| 10 | **Chats / handoffs with hop count, mute guard, per-chat token budget** (`core/chats.ts`, `chat_call`) | medium (~600 lines) | **port the hop guard + feed only** | The comms feed (§1.3) plus a `hops` field on messages, to stop agent ping-pong loops. Leave groups/consults/pins out. |
| 11 | **Budgets / spend per hour** (`core/limits.ts`, `console_spend`) | low | **port later** | The tokens are in claude-auth.pow (`GET /tenants` utilization). Show its numbers in the screen header and don't duplicate accounting. |
| 12 | **Notify queue deduped by notify_sent** (`core/notify.ts`) | low | **port now (idea)** | The approval notification is keyed by `ask.id`, and the ongoing one is updated only when its text changes. |
| 13 | **Terminal console**: Ink status line "N working · N for you", decisions (`web/src/cli/*`, ~285 lines) | small | **port later** | A `powos agents` CLI over the same AgentsSource, for SSH/tmux use. A good fit with the TERMINAL-SURFACES doc. |
| 14 | **Machine enrollment, one-time code** (`core/enroll.ts`) | ~100 lines | **port later (Phase 2/3)** | Enrolling a viewer or reporter identity per device for the agents module. |
| 15 | **Discord Allow/Deny bridge** (`agents/notify/discord.ts`) | tiny container (currently spinning) | **leave out** | Android notification actions do this on the device itself. |
| 16 | Job queue / dispatcher / leases / worker containers | control + worker, ~1 GB | **leave out** | PowOS agents are plain `claude` processes. We observe them; we don't schedule them. |
| 17 | Cage + egress guard (own uid, firewall, default-deny proxy) | 2 containers, medium | **leave out** (here) | It's a security model for untrusted workers, not part of a view. It may be worth its own PowOS doc later. |
| 18 | Pipeline: engineer → checks → preview → review → critic → merge; previewer; merger; multi-repo land | 3 containers, high, Docker socket | **leave out** | Out of scope for seeing what's running. |
| 19 | Code mode (one TS tool over a sandbox) | ~2,300 lines | **leave out** | Unrelated to the view. |
| 20 | Leads with hierarchical memory (Orchestrator / Manager / Owner) | medium | **leave out** | PowOS has its own manager. Its memory isn't part of the view. |
| 21 | Self-improvement loop: friction → lessons / recipes / playbooks, evals, autonomy | medium-high | **port later, friction only** | Hook data already shows denials and failures. A "friction" count per agent is nearly free. Lessons and evals stay in SpaceTimeAI. |
| 22 | Blob store, transcript archive, backups | 2 containers | **leave out** | We never store bodies (§3), so there's nothing to archive. |
| 23 | Schedules (daily review, briefing) | low | **leave out** | Not part of the view. |
| 24 | Console layout: Home / Needs-you cards acted on in place, phone layout (`CONSOLE-REDESIGN.md`) | design | **port now (design)** | Decisions on the card itself, with the "needs you" count first. That matches §1.1/§1.3. |

**Read-only bridge, optional.** SpaceTimeAI's own sessions could show up in the Agents view through a later
`StdbSource` subscribed to the views `agent_traces`, `console_feed` and `needs_you` (an Operator token, read-only).
It would map them onto §3's rows with no new code in SpaceTimeAI. This is **later**, it needs the user's OK, and it
stays read-only.

---

## 10. Phased build plan

| phase | what | needs the user's OK for |
|---|---|---|
| **0** | Land this doc. Agree on the schema (§3) and the surfaces. | this design |
| **1a** | `powos-agent-hook` + `powos-agentsd` (spool sink) in `lib/ai/agents/`. PowOS-launched agents get the hooks via `--settings` (claude.sh, manager.py). comms `_deliver` writes `message` rows. Tests run with a stub claude, like the manager tests. | changing the rootfs on the phone |
| **1b** | Shell: `AgentsSource` + SpoolSource, the Agents screen, and the home panel widget. ShellBridge: an `agents` FileObserver plus `agents.delta`/`agents.snapshot`. AgentsNotifier: ongoing and approval notifications. | a new APK on the phone; touching `grid.tsx`/`types.ts` (others edit them) |
| **1c** | Actions: the PermissionRequest ask hook, the pause gate, SIGINT/SIGTERM, and asyncRewake mail delivery. | **every hook that can block or deny** (ask, pause) |
| **1d** | Mac: user-scope hooks in `~/.claude/settings.json` (next to br-gate) and the adb mirror (HACK). | **editing the Mac's `~/.claude/settings.json`**; the adb mirror |
| **2** | The `agents` SpacetimeDB module on the Mac (its own container, `agents.pow`, LAN only). StdbSource in the shell. The Mac switches to `--sink stdb` and the mirror is deleted. Then the Plasma plasmoid. | a new container on PowStation; the Traefik route |
| **3** | SpacetimeDB on the phone, on demand. Phone switches to `--sink stdb` and the spool is retired. Measure RSS and battery first. | running a server process on the phone |

Phase 1 alone answers the problem: the tree, tasks, steps, approvals and comms on the phone, without polling.
